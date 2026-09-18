import AppKit
import RepobotCore
import SwiftUI
import UserNotifications

@main struct RepobotApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
  var body: some Scene {
    Settings { SettingsView(state: delegate.state) }
      .commands {
        CommandGroup(after: .appSettings) {
          Button("Repository Map…") { delegate.state.showRepositoryMap() }
            .keyboardShortcut("m", modifiers: [.command, .shift])
          Button("Show Repository Menu") { delegate.statusItem?.button?.performClick(nil) }
            .keyboardShortcut("r", modifiers: [.command, .shift])
        }
      }
  }
}
@MainActor final class MenuAction: NSMenuItem {
  let handler: () -> Void
  init(_ title: String, key: String = "", handler: @escaping () -> Void) {
    self.handler = handler
    super.init(title: title, action: #selector(invoke), keyEquivalent: key)
    target = self
  }
  required init(coder: NSCoder) { fatalError("Not used") }
  @objc func invoke() { handler() }
}
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate,
  UNUserNotificationCenterDelegate
{
  let state = AppState()
  var statusItem: NSStatusItem!
  var terminating = false
  private struct Badge: Equatable { var count: Int; var enabled: Bool; var checking: Bool }
  private var badge: Badge?
  private lazy var menuBarGlyph: NSImage? = {
    guard let url = Bundle.main.url(forResource: "MenuBarGlyph", withExtension: "svg"),
      let image = NSImage(contentsOf: url) else { return nil }
    image.size = NSSize(width: 22, height: 22)
    image.isTemplate = true
    image.accessibilityDescription = "Repobot"
    return image
  }()
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    menu.delegate = self
    statusItem.menu = menu
    state.menuChanged = { [weak self] in self?.updateBadge() }
    UNUserNotificationCenter.current().delegate = self
    state.start()
    updateBadge()
    if CommandLine.arguments.contains("--repository-map") { state.showRepositoryMap() }
    if CommandLine.arguments.contains("--settings")
      || (state.configuration.environments.count == 1 && state.world.clones.isEmpty)
    {
      state.showSettings()
    }
  }
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    if !flag { state.showSettings() }
    return true
  }
  func updateBadge() {
    let next = Badge(count: state.attentionCount, enabled: state.configuration.enabled, checking: state.checking)
    guard next != badge else { return }
    let previous = badge
    badge = next
    if previous == nil {
      statusItem.button?.image = menuBarGlyph ?? NSImage(
        systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "Repobot")
    }
    if previous?.count != next.count || previous?.enabled != next.enabled {
      statusItem.button?.title = next.enabled ? (next.count > 0 ? " \(next.count)" : "") : " Paused"
    }
    if previous?.enabled != next.enabled { statusItem.button?.appearsDisabled = !next.enabled }
    if previous?.count != next.count || previous?.checking != next.checking {
      statusItem.button?.toolTip = "Repobot — " + (next.checking ? "Checking repositories… · " : "")
        + "\(next.count) repositories need attention"
    }
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()
    let toggle = MenuAction(
      state.configuration.enabled ? "Repobot — Monitoring On" : "Repobot — Paused"
    ) { [state] in state.toggle() }
    toggle.state = state.configuration.enabled ? .on : .off
    menu.addItem(toggle)
    header(
      "\(state.attentionCount) repos need attention · \(state.world.generatedAt.formatted(.relative(presentation:.named)))",
      to: menu)
    if let error = state.error { header(error, to: menu) }
    menu.addItem(.separator())
    for clone in state.world.attention.prefix(6) {
      menu.addItem(repoItem(clone, includeEnvironment: true))
    }
    if state.attentionCount > 0 { menu.addItem(.separator()) }
    for environment in state.world.environments {
      let clones = state.world.clones.filter { $0.environmentID == environment.id }
      let severity = clones.map(\.status.severity).max() ?? .ok
      let item = NSMenuItem(
        title:
          "\(environment.environment.name)  (\(environment.environment.kind == .local ? Host.current().localizedName ?? "This device" : environment.environment.host))",
        action: nil, keyEquivalent: "")
      item.image = icon(severity, unavailable: environment.error != nil)
      let submenu = NSMenu()
      item.submenu = submenu
      header(
        environment.error
          ?? environment.checkProgress
          ?? "\(environment.mode) · \(environment.checkedAt?.formatted(.relative(presentation:.named)) ?? "Waiting for first check")",
        to: submenu)
      submenu.addItem(
        MenuAction("Open Terminal") { [state] in state.openTerminal(environment.environment) })
      submenu.addItem(.separator())
      for clone in clones.filter({ $0.status.severity >= .attention }).sorted(by: {
        $0.status.severity > $1.status.severity
      }) { submenu.addItem(repoItem(clone)) }
      var included = Set<String>()
      for root in environment.environment.roots {
        header(root, to: submenu)
        let expanded =
          environment.environment.kind == .local
          ? expandedPath(root)
          : root.replacingOccurrences(
            of: "~", with: environment.environment.capabilities?.home ?? "~")
        for clone in clones.filter({
          $0.repo.path == expanded || $0.repo.path.hasPrefix(expanded + "/")
        }).sorted(by: repoSort) where !included.contains(clone.id) {
          submenu.addItem(repoItem(clone))
          included.insert(clone.id)
        }
      }
      for clone in clones.sorted(by: repoSort) where !included.contains(clone.id) {
        submenu.addItem(repoItem(clone))
      }
      if clones.isEmpty { header("No repositories found in configured roots", to: submenu) }
      submenu.addItem(.separator())
      submenu.addItem(
        MenuAction("Rescan for repositories") { [state] in state.check(environment.id, rescan: true)
        })
      submenu.addItem(
        MenuAction("Edit Environment…") { [state] in state.edit(environment.environment) })
      menu.addItem(item)
    }
    menu.addItem(.separator())
    menu.addItem(MenuAction("Repository Map…") { [state] in state.showRepositoryMap() })
    menu.addItem(MenuAction("Add Environment…") { [state] in state.showAdd() })
    menu.addItem(MenuAction("Check Now", key: "r") { [state] in state.check() })
    menu.addItem(MenuAction("Coding Agents…") { [state] in state.showAgentSettings() })
    menu.addItem(MenuAction("Settings…", key: ",") { [state] in state.showSettings() })
    menu.addItem(.separator())
    menu.addItem(MenuAction("Quit", key: "q") { NSApp.terminate(nil) })
  }
  func header(_ text: String, to menu: NSMenu) {
    let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
    item.isEnabled = false
    menu.addItem(item)
  }
  func repoSort(_ a: Clone, _ b: Clone) -> Bool {
    a.status.severity != b.status.severity
      ? a.status.severity > b.status.severity
      : a.repo.path.localizedStandardCompare(b.repo.path) == .orderedAscending
  }
  func repoItem(_ clone: Clone, includeEnvironment: Bool = false) -> NSMenuItem {
    let name = (clone.repo.path as NSString).lastPathComponent
    let env =
      state.world.environments.first { $0.id == clone.environmentID }?.environment.name ?? ""
    let reason = state.headline(for: clone)
    let item = MenuAction("\(name)\(includeEnvironment ? " · " + env : "")    \(reason)") {
      [state] in
      if NSApp.currentEvent?.modifierFlags.contains(.option) == true {
        copyText(clone.repo.path)
      } else {
        state.showDetail(clone)
      }
    }
    item.image = icon(clone.status.severity)
    item.toolTip = clone.repo.path
    return item
  }
  func icon(_ severity: Severity, unavailable: Bool = false) -> NSImage? {
    let name =
      unavailable
      ? "xmark.circle"
      : severity >= .attention ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
    let color: NSColor =
      unavailable
      ? .secondaryLabelColor
      : severity == .problem ? .systemRed : severity == .attention ? .systemYellow : .systemGreen
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(
      .init(paletteColors: [color]))
  }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if terminating { return .terminateNow }
    terminating = true
    Task {
      await state.stop()
      NSApp.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let id = response.notification.request.content.userInfo["cloneID"] as? String
    Task { @MainActor in
      if let clone = state.world.clones.first(where: { $0.id == id }) { state.showDetail(clone) }
    }
    completionHandler()
  }
}
