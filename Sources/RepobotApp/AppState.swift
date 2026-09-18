import AppKit
import Network
import Observation
import RepobotCore
import ServiceManagement
import SwiftUI
import UserNotifications

@MainActor @Observable final class AppState {
  private(set) var configuration: Configuration
  var world: WorldSnapshot
  var attentionCount = 0
  @ObservationIgnored private var attentionTracker = AttentionTracker()
  var error: String?
  var checking = false
  @ObservationIgnored private var checkTask: Task<Void, Never>?
  var settingsTab: SettingsTab = .general
  var environmentSheet: EnvironmentSheet?
  var agents: AgentSettingsStore
  var notificationAuthorization: UNAuthorizationStatus?
  private(set) var needsSetup = false
  @ObservationIgnored private var started = false
  var logs: [String] = []
  @ObservationIgnored let persistence: Persistence
  @ObservationIgnored var store: StateStore
  @ObservationIgnored var monitors: [UUID: EnvironmentMonitor] = [:]
  @ObservationIgnored var streamTask: Task<Void, Never>?
  @ObservationIgnored var reconfigureTask: Task<Void, Never>?
  @ObservationIgnored private var repositoryMapModel: RepositoryMapModel?
  @ObservationIgnored private var repositoryMapWindow: DisposableWindow?
  @ObservationIgnored var windows: [String: NSWindow] = [:]
  @ObservationIgnored var pathMonitor = NWPathMonitor()
  @ObservationIgnored private var networkPolicy = NetworkCheckPolicy()
  @ObservationIgnored private var reconnectTask: Task<Void, Never>?
  @ObservationIgnored private var pendingWake = false
  @ObservationIgnored private var pendingNetwork = false
  @ObservationIgnored var wakeObserver: NSObjectProtocol?
  @ObservationIgnored var menuChanged: (() -> Void)?
  init(persistence: Persistence = Persistence()) {
    self.persistence = persistence
    settingsTab = SettingsTab(rawValue: UserDefaults.standard.string(forKey: "selectedSettingsPane") ?? "") ?? .general
    agents = AgentSettingsStore(persistence: persistence)
    var config = Configuration()
    var cached = WorldSnapshot()
    var failure: String?
    do {
      if let saved = try persistence.load(Configuration.self, from: "config.json") {
        config = saved
      } else {
        config.environments[0].roots = []
        needsSetup = true
        try persistence.save(config, to: "config.json")
      }
      cached = try persistence.loadWorld(configuration: config) ?? cached
    } catch {
      failure =
        "Could not load saved data: \(error.localizedDescription). Monitoring is paused. Review settings before saving."
      config.enabled = false
    }
    needsSetup = config.environments.allSatisfy { $0.roots.isEmpty }
    config.validate()
    configuration = config
    world = cached
    _ = attentionTracker.update(cached)
    attentionCount = attentionTracker.count
    error = failure
    store = StateStore(configuration: config, persistence: persistence, cached: cached)
  }
  func start() {
    started = true
    Task { await refreshNotificationAuthorization() }
    streamTask = Task { [weak self, store] in
      for await value in await store.stream() {
        guard let self else { return }
        let increased = self.attentionTracker.update(value)
        self.notify(increased, in: value)
        let badgeChanged = self.attentionCount != self.attentionTracker.count
        if badgeChanged { self.attentionCount = self.attentionTracker.count }
        self.repositoryMapModel?.update(value)
        self.world = value
        if badgeChanged { self.menuChanged?() }
        if let error = await store.persistenceError {
          self.error = "Could not save state: \(error)"
        }
      }
    }
    apply()
    wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
    ) { [weak self] _ in Task { @MainActor in self?.wake() } }
    pathMonitor.pathUpdateHandler = { [weak self] path in
      let state = NetworkCheckPolicy.State(
        available: path.status == .satisfied,
        interfaces: path.availableInterfaces.filter { path.usesInterfaceType($0.type) }
          .map { "\($0.type):\($0.name):\($0.index)" }.sorted(),
        ipv4: path.supportsIPv4, ipv6: path.supportsIPv6, dns: path.supportsDNS)
      Task { @MainActor in self?.networkChanged(state) }
    }
    pathMonitor.start(queue: DispatchQueue(label: "Repobot.Network"))
  }
  func apply() {
    guard started else { return }
    configuration.validate()
    let config = configuration
    let previousCheck = checkTask
    previousCheck?.cancel()
    let previous = reconfigureTask
    reconfigureTask = Task { [weak self] in
      await previous?.value
      await previousCheck?.value
      guard let self else { return }
      let old = monitors
      monitors = [:]
      for monitor in old.values { await monitor.stop() }
      guard !Task.isCancelled else { return }
      await store.updateConfiguration(config)
      guard config.enabled else {
        menuChanged?()
        return
      }
      for env in config.environments where !env.roots.isEmpty {
        let monitor = EnvironmentMonitor(environment: env, configuration: config, store: store)
        monitors[env.id] = monitor
        await monitor.start()
      }
      menuChanged?()
    }
  }
  /// Persist the proposed value before publishing it or changing monitoring.
  @discardableResult func save(_ proposed: Configuration) -> Bool {
    var next = proposed
    next.validate()
    do {
      try persistence.save(next, to: "config.json")
      configuration = next
      needsSetup = next.environments.allSatisfy { $0.roots.isEmpty }
      error = nil
      apply()
      menuChanged?()
      return true
    } catch {
      self.error = "Could not save settings: \(error.localizedDescription)"
      return false
    }
  }
  @discardableResult func changeConfiguration(_ change: (inout Configuration) -> Void) -> Bool {
    var next = configuration
    change(&next)
    return save(next)
  }
  func toggle() { changeConfiguration { $0.enabled.toggle() } }
  func check(_ id: UUID? = nil, rescan: Bool = false) {
    guard !checking else { return }
    guard configuration.environments.contains(where: { (id == nil || $0.id == id) && !$0.roots.isEmpty }) else {
      showSetup(); return
    }
    checking = true
    menuChanged?()
    let reconfiguration = reconfigureTask
    checkTask = Task {
      defer { checking = false; checkTask = nil; menuChanged?() }
      await reconfiguration?.value
      guard !Task.isCancelled else { return }
      if configuration.enabled {
        let targets = monitors.filter { id == nil || $0.key == id }.map(\.value)
        await withTaskGroup(of: Void.self) { group in
          for monitor in targets { group.addTask { await monitor.checkNow(rescan: rescan) } }
        }
      } else {
        let config = configuration
        let targets = config.environments.filter { (id == nil || $0.id == id) && !$0.roots.isEmpty }
        await withTaskGroup(of: Void.self) { group in
          for environment in targets {
            let monitor = EnvironmentMonitor(environment: environment, configuration: config, store: store)
            group.addTask { await monitor.checkOnce(rescan: rescan) }
          }
        }
      }
    }
  }
  private func networkChanged(_ state: NetworkCheckPolicy.State) {
    let check = networkPolicy.receive(state)
    guard configuration.enabled else { return }
    if !state.available { pendingNetwork = false }
    else if check { pendingNetwork = true; scheduleReconnect() }
  }
  func wake() {
    guard configuration.enabled else { return }
    pendingWake = true
    scheduleReconnect()
  }
  private func scheduleReconnect() {
    guard reconnectTask == nil else { return }
    reconnectTask = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(2)) } catch { return }
      guard let self else { return }
      while !Task.isCancelled && configuration.enabled && (pendingWake || pendingNetwork) {
        let waking = pendingWake
        pendingWake = false; pendingNetwork = false
        let targets = Array(monitors.values)
        // Start together: a slow host must not delay recovery checks on other hosts.
        await withTaskGroup(of: Void.self) { group in
          for monitor in targets {
            group.addTask {
              if waking { await monitor.wake() } else { await monitor.networkChanged() }
            }
          }
        }
        if pendingWake || pendingNetwork { try? await Task.sleep(for: .seconds(2)) }
      }
      reconnectTask = nil
    }
  }
  func stop() async {
    configuration.enabled = false
    reconfigureTask?.cancel()
    await reconfigureTask?.value
    checkTask?.cancel()
    await checkTask?.value
    streamTask?.cancel()
    pathMonitor.cancel()
    reconnectTask?.cancel()
    reconnectTask = nil
    for monitor in monitors.values { await monitor.stop() }
    if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
  }
  @discardableResult func add(_ environment: RepobotCore.Environment) -> Bool {
    changeConfiguration { config in
      if let index = config.environments.firstIndex(where: { $0.id == environment.id }) {
        config.environments[index] = environment
      } else { config.environments.append(environment) }
    }
  }
  @discardableResult func update(_ environment: RepobotCore.Environment) -> Bool { add(environment) }
  @discardableResult func removeEnvironment(_ id: UUID) -> Bool {
    changeConfiguration { $0.environments.removeAll { $0.id == id && $0.kind == .ssh } }
  }
  func snooze(_ clone: Clone, until: Date) {
    changeConfiguration { $0.snoozed[clone.id] = until }
  }
  func resumeWarnings(_ clone: Clone) {
    changeConfiguration { $0.ignored.remove(clone.id); $0.snoozed[clone.id] = nil }
  }
  func ignore(_ clone: Clone) {
    changeConfiguration { $0.ignored.insert(clone.id) }
  }
  func freshness(for clone: Clone) -> RepositoryFreshness {
    RepositoryFreshness(paused: !configuration.enabled, pending: clone.repo.awaitingFreshCheck == true,
      error: clone.repo.error ?? world.environments.first { $0.id == clone.environmentID }?.error)
  }
  func log(_ text: String) {
    logs.append("\(Date().formatted(date:.omitted,time:.standard)) \(text)")
    if logs.count > 200 { logs.removeFirst(logs.count - 200) }
  }
  func show<V: View>(
    _ key: String, title: String, width: CGFloat = 680, height: CGFloat = 580,
    @ViewBuilder content: () -> V
  ) {
    if let window = windows[key] {
      window.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      return
    }
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: width, height: height),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
    )
    window.title = title
    window.contentViewController = NSHostingController(rootView: content())
    window.isReleasedWhenClosed = false
    if !window.setFrameUsingName(key) { window.center() }
    window.setFrameAutosaveName(key)
    windows[key] = window
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
  func headline(for clone: Clone) -> String {
    let freshness = freshness(for: clone)
    if let summary = freshness.summary { return summary }
    if configuration.ignored.contains(clone.id) {
      return "Ignored — monitoring continues without warnings"
    }
    if let until = configuration.snoozed[clone.id], until > Date() {
      return "Snoozed until \(until.formatted(date: .abbreviated, time: .shortened))"
    }
    return clone.status.findings.first?.text
      ?? (clone.repo.dirty ? "Working tree has changes" : "Clean and in sync")
  }
  func showDetail(_ clone: Clone) {
    show(clone.id, title: (clone.repo.path as NSString).lastPathComponent) {
      RepoDetailView(state: self, cloneID: clone.id)
    }
  }
  func showAgentReview(_ repositoryID: String) {
    show("agent-review-" + repositoryID, title: "Agent resolutions", width: 980, height: 800) {
      AgentReviewView(state: self, session: AgentReviewSession(repositoryID: repositoryID))
    }
  }
  func showAgentSettings() {
    settingsTab = .agents
    showSettings()
  }
  func findRepository() {
    showRepositoryMap()
    repositoryMapModel?.focusSearch = true
  }
  func showRepositoryMap() {
    let key = "repository-map"
    if let window = windows[key] {
      window.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      return
    }
    let model = RepositoryMapModel()
    model.update(world)
    repositoryMapModel = model
    show(key, title: "Repository Map", width: 980, height: 720) {
      RepositoryMapView(state: self, model: model)
    }
    guard let window = windows[key] else { return }
    repositoryMapWindow = DisposableWindow(window: window) { [weak self] in
      self?.windows[key] = nil
      self?.repositoryMapModel = nil
      self?.repositoryMapWindow = nil
    }
  }
  func showSettings() {
    // Invoke the Settings scene's own command, including its original target.
    // This keeps AppKit entry points and Command-Comma on the same SwiftUI window.
    NSApp.activate(ignoringOtherApps: true)
    if let item = Self.settingsCommand(in: NSApp.mainMenu), let action = item.action {
      if !NSApp.sendAction(action, to: item.target, from: item) {
        error = "Settings could not be opened. Try Repobot’s Settings command (⌘,)."
      }
    } else {
      error = "Settings could not be opened. Use Repobot’s Settings command (⌘,)."
    }
  }
  static func settingsCommand(in menu: NSMenu?) -> NSMenuItem? {
    for item in menu?.items ?? [] {
      if item.keyEquivalent == ",", item.keyEquivalentModifierMask == .command, item.action != nil { return item }
      if let nested = settingsCommand(in: item.submenu) { return nested }
    }
    return nil
  }
  func showSetup() {
    settingsTab = .environments
    showSettings()
  }
  func showAdd() {
    settingsTab = .environments
    showSettings()
    environmentSheet = .add
  }
  func edit(_ environment: RepobotCore.Environment) {
    settingsTab = .environments
    showSettings()
    environmentSheet = .edit(environment)
  }
  func openTerminal(_ env: RepobotCore.Environment, path: String? = nil) {
    var command: String
    if env.kind == .local {
      command = path.map { "cd -- " + shellQuote($0) } ?? "cd ~"
    } else {
      var args = [configuration.sshPath, "-t"]
      if let port = env.port { args += ["-p", String(port)] }
      if let key = env.identityFile { args += ["-i", expandedPath(key)] }
      for option in configuration.extraSSHOptions { args += ["-o", option] }
      args += ["--", env.user.isEmpty ? env.host : "\(env.user)@\(env.host)"]
      if let path { args.append("cd -- \(shellQuote(path)) && exec \"${SHELL:-/bin/sh}\" -l") }
      command = args.map(shellQuote).joined(separator: " ")
    }
    terminal(command)
  }
  @discardableResult func terminal(_ command: String) -> Bool {
    let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(
      of: "\"", with: "\\\"")
    var error: NSDictionary?
    NSAppleScript(
      source: "tell application \"Terminal\"\nactivate\ndo script \"\(escaped)\"\nend tell")?
      .executeAndReturnError(&error)
    if let error { self.error = "Terminal could not be opened: \(error)"; return false }
    return true
  }
  var notificationSummary: String {
    guard configuration.notifications else { return "Off" }
    switch notificationAuthorization {
    case .denied: return "Blocked in System Settings"
    case .notDetermined: return "Permission needed"
    case .authorized, .provisional, .ephemeral: return "Enabled"
    default: return "Checking permission…"
    }
  }
  func refreshNotificationAuthorization() async {
    notificationAuthorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
  }
  func requestNotifications() {
    Task {
      do {
        _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        await refreshNotificationAuthorization()
      } catch { self.error = "Could not request notification permission: \(error.localizedDescription)" }
    }
  }
  func openNotificationSettings() {
    let id = Bundle.main.bundleIdentifier ?? "com.repobot.app"
    let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=" + id)!
    if !NSWorkspace.shared.open(url) {
      error = "Open System Settings → Notifications → Repobot to change notification permissions."
    }
  }
  func showNotification(_ userInfo: [AnyHashable: Any]) {
    if let ids = userInfo["cloneIDs"] as? [String], ids.count > 1 {
      showRepositoryMap()
      repositoryMapModel?.show(cloneIDs: Set(ids))
    } else if let id = (userInfo["cloneIDs"] as? [String])?.first ?? userInfo["cloneID"] as? String,
              let clone = world.clones.first(where: { $0.id == id }) {
      showDetail(clone)
    } else { showRepositoryMap() }
  }
  func notify(_ increased: [Clone], in new: WorldSnapshot) {
    for (id, clones) in NotificationTransitions.eligible(
      increased, in: new, configuration: configuration)
    {
      let content = UNMutableNotificationContent()
      content.title =
        "\(new.environments.first {$0.id==id}?.environment.name ?? "Environment"): \(clones.count) repos need attention"
      content.body = clones.prefix(3).map { clone in
        "\((clone.repo.path as NSString).lastPathComponent): \(clone.status.findings.first?.text ?? "Needs attention")"
      }.joined(
        separator: "\n")
      if clones.count > 3 { content.body += "\nAnd \(clones.count - 3) more repositories" }
      content.userInfo = ["cloneIDs": clones.map(\.id)]
      let request = UNNotificationRequest(
        identifier: "repobot-\(id)", content: content, trigger: nil)
      Task {
        do { try await UNUserNotificationCenter.current().add(request) }
        catch { self.error = "Could not deliver notification: \(error.localizedDescription)" }
      }
    }
  }
}
func copyText(_ text: String) {
  NSPasteboard.general.clearContents()
  NSPasteboard.general.setString(text, forType: .string)
}
