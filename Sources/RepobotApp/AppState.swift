import AppKit
import Network
import Observation
import RepobotCore
import ServiceManagement
import SwiftUI
import UserNotifications

@MainActor @Observable final class AppState {
  var configuration: Configuration
  var world: WorldSnapshot
  var attentionCount = 0
  @ObservationIgnored private var attentionTracker = AttentionTracker()
  var error: String?
  var checking = false
  var settingsTab: SettingsTab = .general
  var environmentSheet: EnvironmentSheet?
  var agents = AgentSettingsStore()
  var logs: [String] = []
  @ObservationIgnored let persistence = Persistence()
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
  init() {
    var config = Configuration()
    var cached = WorldSnapshot()
    var failure: String?
    do {
      if let saved = try Persistence().load(Configuration.self, from: "config.json") {
        config = saved
      } else {
        try Persistence().save(config, to: "config.json")
      }
      cached = try Persistence().loadWorld(configuration: config) ?? cached
    } catch {
      failure =
        "Could not load saved data: \(error.localizedDescription). Monitoring is paused. Review settings before saving."
      config.enabled = false
    }
    config.validate()
    configuration = config
    world = cached
    _ = attentionTracker.update(cached)
    attentionCount = attentionTracker.count
    error = failure
    store = StateStore(configuration: config, cached: cached)
  }
  func start() {
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
    configuration.validate()
    let config = configuration
    let previous = reconfigureTask
    reconfigureTask = Task { [weak self] in
      await previous?.value
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
      for env in config.environments {
        let monitor = EnvironmentMonitor(environment: env, configuration: config, store: store)
        monitors[env.id] = monitor
        await monitor.start()
      }
      menuChanged?()
    }
  }
  func save() {
    do {
      try persistence.save(configuration, to: "config.json")
      error = nil
      apply()
    } catch { self.error = "Could not save settings: \(error.localizedDescription)" }
  }
  func toggle() {
    configuration.enabled.toggle()
    save()
  }
  func check(_ id: UUID? = nil, rescan: Bool = false) {
    guard configuration.enabled else { return }
    checking = true
    menuChanged?()
    Task {
      await withTaskGroup(of: Void.self) { group in
        for (key, monitor) in monitors where id == nil || key == id {
          group.addTask { await monitor.checkNow(rescan: rescan) }
        }
      }
      checking = false
      menuChanged?()
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
    streamTask?.cancel()
    pathMonitor.cancel()
    reconnectTask?.cancel()
    reconnectTask = nil
    for monitor in monitors.values { await monitor.stop() }
    if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
  }
  func add(_ environment: RepobotCore.Environment) {
    configuration.environments.append(environment)
    save()
  }
  func update(_ environment: RepobotCore.Environment) {
    if let index = configuration.environments.firstIndex(where: { $0.id == environment.id }) {
      configuration.environments[index] = environment
      save()
    }
  }
  func snooze(_ clone: Clone, until: Date) {
    configuration.snoozed[clone.id] = until
    save()
  }
  func ignore(_ clone: Clone) {
    configuration.ignored.insert(clone.id)
    save()
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
    window.center()
    windows[key] = window
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
  func headline(for clone: Clone) -> String {
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
    show("settings", title: "Repobot Settings", width: 780, height: 560) {
      SettingsView(state: self)
    }
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
  func requestNotifications() {
    Task {
      do {
        let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [
          .alert, .sound,
        ])
        configuration.notifications = granted
        save()
      } catch { self.error = error.localizedDescription }
    }
  }
  func notify(_ increased: [Clone], in new: WorldSnapshot) {
    for (id, clones) in NotificationTransitions.eligible(
      increased, in: new, configuration: configuration)
    {
      let content = UNMutableNotificationContent()
      content.title =
        "\(new.environments.first {$0.id==id}?.environment.name ?? "Environment"): \(clones.count) repos need attention"
      content.body = clones.prefix(3).compactMap { $0.status.findings.first?.text }.joined(
        separator: "\n")
      content.userInfo = ["cloneID": clones[0].id]
      let request = UNNotificationRequest(
        identifier: "repobot-\(id)", content: content, trigger: nil)
      Task { try? await UNUserNotificationCenter.current().add(request) }
    }
  }
}
func copyText(_ text: String) {
  NSPasteboard.general.clearContents()
  NSPasteboard.general.setString(text, forType: .string)
}
