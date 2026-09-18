import RepobotCore
import ServiceManagement
import SwiftUI

enum SettingsTab: String, Hashable {
  case environments, agents, general
  var title: String { switch self { case .environments: "Environments"; case .agents: "Coding Agents"; case .general: "General" } }
}
enum EnvironmentSheet: Identifiable {
  case add, edit(RepobotCore.Environment)
  var id: String {
    switch self { case .add: "add"; case .edit(let env): env.id.uuidString }
  }
}

// Aligned fields within the focused settings editors.
struct PreferenceRow<Content: View>: View {
  let title: String
  @ViewBuilder var content: Content
  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 18) {
      Text(title + ":").foregroundStyle(.secondary).frame(width: 115, alignment: .trailing)
      content.frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}
struct PreferencesDialog<Content: View, Actions: View>: View {
  let title: String
  let subtitle: String
  @ViewBuilder var content: Content
  @ViewBuilder var actions: Actions
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 8) {
        Text(title).font(.title2.bold())
        if !subtitle.isEmpty { Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
      }.padding(24)
      ScrollView {
        VStack(alignment: .leading, spacing: 18) { content }
          .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.bottom, 24)
      }.frame(maxHeight: 440)
      Divider()
      HStack { Spacer(); actions }.padding(16)
    }.frame(width: 580)
  }
}

struct SettingsView: View {
  @Bindable var state: AppState
  var body: some View {
    TabView(selection: $state.settingsTab) {
      EnvironmentSettingsView(state: state)
        .tabItem { Label("Environments", systemImage: "desktopcomputer") }.tag(SettingsTab.environments)
      AgentSettingsView(state: state, settings: state.agents)
        .tabItem { Label("Coding Agents", systemImage: "person.crop.circle") }.tag(SettingsTab.agents)
      GeneralSettingsView(state: state)
        .tabItem { Label("General", systemImage: "slider.horizontal.3") }.tag(SettingsTab.general)
    }
    .frame(width: 760, height: 500)
    .background(SettingsWindowConfiguration(title: state.settingsTab.title))
    .sheet(item: $state.environmentSheet) { sheet in
      switch sheet {
      case .add: AddEnvironmentView(state: state)
      case .edit(let env): EnvironmentEditor(state: state, environment: env)
      }
    }
    .onChange(of: state.settingsTab) { _, tab in
      UserDefaults.standard.set(tab.rawValue, forKey: "selectedSettingsPane")
    }
  }
}

/// Configure the scene's existing window; never create a second Settings window.
private struct SettingsWindowConfiguration: NSViewRepresentable {
  let title: String
  func makeNSView(context: Context) -> NSView { SettingsWindowAnchor() }
  func updateNSView(_ nsView: NSView, context: Context) {
    (nsView as? SettingsWindowAnchor)?.paneTitle = title
  }
}
private final class SettingsWindowAnchor: NSView {
  var paneTitle = "General" { didSet { configure() } }
  override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); configure() }
  private func configure() {
    guard let window else { return }
    window.title = paneTitle
    window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
    window.standardWindowButton(.zoomButton)?.isEnabled = false
    window.toolbar?.allowsUserCustomization = false
  }
}

private struct GeneralSettingsView: View {
  @Bindable var state: AppState
  @State private var loginEnabled = SMAppService.mainApp.status == .enabled
  @State private var detail: SettingsDetail?
  var body: some View {
    Form {
      Section("Startup & monitoring") {
        Toggle(isOn: Binding(get: { state.configuration.enabled }, set: {
          let enabled = $0
          state.changeConfiguration { $0.enabled = enabled }
        })) {
          VStack(alignment: .leading, spacing: 4) {
            Text("Monitor repositories")
            Text("Continuously watch configured repositories for changes.")
              .font(.callout).foregroundStyle(.secondary)
          }
        }
        .accessibilityLabel("Monitor repositories")
        .accessibilityHint("Continuously watch configured repositories for changes")
        Toggle("Launch Repobot at login", isOn: $loginEnabled)
          .onChange(of: loginEnabled) { _, enabled in
            do {
              if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
              state.error = "Launch at login: \(error.localizedDescription)"
              loginEnabled = SMAppService.mainApp.status == .enabled
            }
          }
      }
      .toggleStyle(.switch)

      Section("Monitoring") {
        destination("Checks", summary: "Events with periodic safety checks", detail: .checks)
        destination("Notifications", summary: state.notificationSummary, detail: .notifications)
        destination("Findings", summary: "Choose what needs your attention", detail: .findings)
        destination("Hidden Findings", summary: "\(state.configuration.ignored.count) ignored · \(state.configuration.snoozed.count) snoozed",
                    detail: .hidden, inlineSummary: true)
      }

      Section("System") {
        destination("SSH", summary: "Uses your SSH keys and configuration", detail: .ssh)
        destination("Diagnostics", summary: "Logs and configuration files", detail: .diagnostics)
      }

      if let error = state.error {
        Section { OperationErrorView(message: error) }
      }
    }
    .formStyle(.grouped)
    .sheet(item: $detail) { SettingsDetailView(state: state, section: $0) }
  }

  private func destination(_ title: String, summary: String, detail: SettingsDetail,
                           inlineSummary: Bool = false) -> some View {
    Button { self.detail = detail } label: {
      HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 4) {
          Text(title).foregroundStyle(.primary)
          if !inlineSummary {
            Text(summary).font(.callout).foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        Spacer(minLength: 12)
        if inlineSummary {
          Text(summary).font(.callout).foregroundStyle(.secondary)
        }
        Image(systemName: "chevron.right")
          .font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
          .accessibilityHidden(true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, 4)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(title)
    .accessibilityValue(summary)
    .accessibilityHint("Opens " + title.lowercased())
  }
}

private enum SettingsDetail: String, Identifiable {
  case checks = "Repository checks", notifications = "Notifications", findings = "Findings"
  case hidden = "Hidden findings", ssh = "SSH", diagnostics = "Diagnostics"
  var id: String { rawValue }
}
private struct SettingsDetailView: View {
  @Bindable var state: AppState
  let section: SettingsDetail
  @SwiftUI.Environment(\.dismiss) private var dismiss
  @State private var draft: Configuration
  @State private var extraOptions: String
  @State private var skipNames: String
  @State private var validationError: String?
  @State private var numericInput: [String: String] = [:]
  init(state: AppState, section: SettingsDetail) {
    self.state = state; self.section = section
    _draft = State(initialValue: state.configuration)
    _skipNames = State(initialValue: state.configuration.effectiveWatchSkipNames.joined(separator: "\n"))
    _extraOptions = State(initialValue: state.configuration.extraSSHOptions.joined(separator: "\n"))
  }
  var body: some View {
    PreferencesDialog(title: section.rawValue, subtitle: subtitle) {
      fields
      if let error = validationError ?? state.error { OperationErrorView(message: error) }
    } actions: {
      Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
      Button("Done") { save() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
    }
  }
  private var subtitle: String {
    switch section {
    case .checks: "Changes are detected automatically. These checks catch anything events miss."
    case .notifications: "Choose when Repobot should interrupt you."
    case .findings: "Tune which repository states need attention."
    case .hidden: "Restore findings you previously ignored or snoozed."
    case .ssh: "Applies to remote environments. Your existing SSH configuration is used automatically."
    case .diagnostics: "Inspect recent activity or open Repobot’s saved configuration."
    }
  }
  @ViewBuilder private var fields: some View {
    switch section {
    case .checks:
      number("Polling", value: $draft.pollInterval, unit: "seconds (minimum 10)")
      number("Safety sweep", value: $draft.safetyInterval, unit: "seconds (minimum 30)")
      number("Upstream", value: $draft.upstreamInterval, unit: "seconds (minimum 60)")
      PreferenceRow(title: "Method") {
        Picker("Upstream method", selection: $draft.upstreamCheck) {
          Text("Read-only check").tag(UpstreamCheck.lsRemote)
          Text("Fetch (updates tracking refs)").tag(UpstreamCheck.fetch)
          Text("Off").tag(UpstreamCheck.off)
        }.labelsHidden()
      }
      Toggle("Check less often when idle on battery", isOn: $draft.batteryAware)
      Divider()
      number("Idle after", value: Binding(get: { draft.effectiveWatchActiveDays }, set: { draft.watchActiveDays = $0 }),
             unit: "days without Git activity (0 watches every repository)")
      Text("On Linux, every watched folder uses one of a limited number of filesystem watches. Idle repositories are still watched for commits, checkouts and fetches, and safety sweeps catch other edits.")
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      VStack(alignment: .leading, spacing: 6) {
        HStack {
          Text("Never watch untracked folders named").font(.headline)
          Spacer()
          Button("Restore Defaults") { skipNames = Configuration.defaultWatchSkipNames.joined(separator: "\n") }
            .disabled(Configuration.normalizedSkipNames(skipNames) == Configuration.defaultWatchSkipNames)
        }
        TextEditor(text: $skipNames).accessibilityLabel("Folder names that are never watched")
          .font(.system(.body, design: .monospaced)).frame(height: 96).border(Color.secondary.opacity(0.2))
        Text("One name per line. Folders that Git ignores are never watched; tracked folders always are.")
          .font(.caption).foregroundStyle(.secondary)
      }
      if draft.upstreamCheck == .fetch {
        Text("Fetch writes remote-tracking refs in monitored repositories.").font(.caption).foregroundStyle(.orange)
      }
    case .notifications:
      if state.notificationAuthorization == .denied {
        Label("Notifications are blocked in System Settings.", systemImage: "bell.slash")
        Button("Open Notification Settings…") { state.openNotificationSettings() }
        Text("Choose Repobot in System Settings → Notifications to allow notifications.").font(.caption).foregroundStyle(.secondary)
      }
      Toggle("Notify when repositories need attention", isOn: $draft.notifications)
      HStack(spacing: 24) {
        Toggle("Attention", isOn: $draft.notifyAttention)
        Toggle("Problems", isOn: $draft.notifyProblem)
      }.disabled(!draft.notifications)
      Divider()
      Toggle("Quiet hours", isOn: $draft.quietHours).disabled(!draft.notifications)
      HStack {
        Stepper("From \(draft.quietStart):00", value: $draft.quietStart, in: 0...23)
        Stepper("Until \(draft.quietEnd):00", value: $draft.quietEnd, in: 0...23)
      }.disabled(!draft.notifications || !draft.quietHours)
    case .findings:
      number("Uncommitted", value: $draft.dirtyHours, unit: "hours before warning")
      number("Unpushed", value: $draft.unpushedHours, unit: "hours before warning")
      Divider()
      ForEach([("stashes", "Saved stashes"), ("no-upstream", "Branches without upstreams"),
               ("peer-dirty", "Changes in other copies"), ("detached", "Detached HEAD")], id: \.0) { id, title in
        Toggle(title, isOn: Binding(get: { !draft.disabledFindings.contains(id) }, set: {
          if $0 { draft.disabledFindings.remove(id) } else { draft.disabledFindings.insert(id) }
        }))
      }
      Toggle("Report stale branches", isOn: $draft.reportStaleBranches)
      number("Stale after", value: $draft.staleBranchDays, unit: "days").disabled(!draft.reportStaleBranches)
    case .hidden:
      if draft.ignored.isEmpty && draft.snoozed.isEmpty {
        Label("No ignored or snoozed repositories", systemImage: "checkmark.circle").foregroundStyle(.secondary)
      } else {
        List {
          ForEach(Array(draft.ignored).sorted(), id: \.self) { id in hiddenRow(id, kind: "Ignored") { draft.ignored.remove(id) } }
          ForEach(draft.snoozed.keys.sorted(), id: \.self) { id in hiddenRow(id, kind: "Snoozed") { draft.snoozed[id] = nil } }
        }.frame(height: 250)
      }
    case .ssh:
      TextField("SSH executable", text: $draft.sshPath).textFieldStyle(.roundedBorder)
      Text("Extra SSH options").font(.headline)
      TextEditor(text: $extraOptions).accessibilityLabel("Extra SSH options").font(.system(.body, design: .monospaced)).frame(height: 110)
        .border(Color.secondary.opacity(0.2))
      Text("One key=value option per line.").font(.caption).foregroundStyle(.secondary)
    case .diagnostics:
      Toggle("Include hostnames in debug logs", isOn: $draft.debugLogging)
      Button("Open configuration folder") { NSWorkspace.shared.open(state.persistence.directory) }
      ScrollView {
        Text(state.logs.isEmpty ? "No diagnostic events yet." : state.logs.joined(separator: "\n"))
          .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading).padding(10)
      }.frame(height: 180).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }
  }
  private func number(_ title: String, value: Binding<Double>, unit: String) -> some View {
    PreferenceRow(title: title) {
      HStack {
        TextField(title, text: Binding(
          get: { numericInput[title] ?? value.wrappedValue.formatted(.number.grouping(.never)) },
          set: { numericInput[title] = $0 }
        )).textFieldStyle(.roundedBorder).frame(width: 76)
        Text(unit).foregroundStyle(.secondary)
      }
    }
  }
  private func hiddenRow(_ id: String, kind: String, restore: @escaping () -> Void) -> some View {
    HStack {
      VStack(alignment: .leading) {
        Text(id.components(separatedBy: ":").dropFirst().joined(separator: ":")).lineLimit(2)
        Text(kind).font(.caption).foregroundStyle(.secondary)
      }
      Spacer(); Button("Restore", action: restore).accessibilityLabel("Restore warnings for " + id.components(separatedBy: ":").dropFirst().joined(separator: ":"))
    }
  }
  private func save() {
    validationError = nil
    var validated = draft
    for (title, text) in numericInput {
      guard let value = SettingsNumber.parse(text), value.isFinite else {
        validationError = "Enter a number for \(title.lowercased())."; return
      }
      switch title {
      case "Polling": validated.pollInterval = value
      case "Safety sweep": validated.safetyInterval = value
      case "Upstream": validated.upstreamInterval = value
      case "Uncommitted": validated.dirtyHours = value
      case "Unpushed": validated.unpushedHours = value
      case "Stale after": validated.staleBranchDays = value
      case "Idle after": validated.watchActiveDays = value
      default: break
      }
    }
    if section == .checks {
      guard validated.pollInterval.isFinite, validated.pollInterval >= 10,
            validated.safetyInterval.isFinite, validated.safetyInterval >= 30,
            validated.upstreamInterval.isFinite, validated.upstreamInterval >= 60 else {
        validationError = "Use at least 10 seconds for polling, 30 for safety sweeps, and 60 for upstream checks."; return
      }
      guard validated.effectiveWatchActiveDays.isFinite, (validated.watchActiveDays ?? 0) >= 0 else {
        validationError = "Idle days must be zero or greater."; return
      }
    }
    if section == .findings {
      guard validated.dirtyHours.isFinite, validated.dirtyHours >= 0, validated.unpushedHours.isFinite, validated.unpushedHours >= 0,
            validated.staleBranchDays.isFinite, validated.staleBranchDays >= 1 else {
        validationError = "Warning ages must be zero or greater; stale branches require at least one day."; return
      }
    }
    let requestNotifications = section == .notifications && validated.notifications
    var next = state.configuration
    switch section {
    case .checks:
      next.pollInterval = validated.pollInterval
      next.safetyInterval = validated.safetyInterval
      next.upstreamInterval = validated.upstreamInterval
      next.upstreamCheck = validated.upstreamCheck
      next.batteryAware = validated.batteryAware
      next.watchActiveDays = validated.watchActiveDays
      let names = Configuration.normalizedSkipNames(skipNames)
      next.watchSkipNames = names == Configuration.defaultWatchSkipNames ? nil : names
    case .notifications:
      next.notifications = validated.notifications
      next.notifyAttention = validated.notifyAttention
      next.notifyProblem = validated.notifyProblem
      next.quietHours = validated.quietHours
      next.quietStart = validated.quietStart
      next.quietEnd = validated.quietEnd
    case .findings:
      next.dirtyHours = validated.dirtyHours
      next.unpushedHours = validated.unpushedHours
      next.disabledFindings = validated.disabledFindings
      next.reportStaleBranches = validated.reportStaleBranches
      next.staleBranchDays = validated.staleBranchDays
    case .hidden:
      next.ignored = validated.ignored; next.snoozed = validated.snoozed
    case .ssh:
      next.sshPath = validated.sshPath
      next.extraSSHOptions = extraOptions.split(separator: "\n").map(String.init)
    case .diagnostics: next.debugLogging = validated.debugLogging
    }
    if state.save(next) {
      if requestNotifications { state.requestNotifications() }
      dismiss()
    }
  }
}

/// Reject incomplete numeric input rather than silently retaining the old setting.
enum SettingsNumber {
  static func parse(_ text: String, locale: Locale = .current) -> Double? {
    let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: locale.decimalSeparator ?? ".", with: ".")
    guard let value = Double(normalized), value.isFinite else { return nil }
    return value
  }
}
