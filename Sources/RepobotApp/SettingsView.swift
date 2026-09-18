import RepobotCore
import ServiceManagement
import SwiftUI

enum SettingsTab: Hashable { case environments, agents, general }
enum EnvironmentSheet: Identifiable {
  case add, edit(RepobotCore.Environment)
  var id: String {
    switch self { case .add: "add"; case .edit(let env): env.id.uuidString }
  }
}

// Small, aligned rows and focused sheets keep the main preferences window calm.
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
      VStack(alignment: .leading, spacing: 18) { content }.padding(.horizontal, 24).padding(.bottom, 24)
      Divider()
      HStack { Spacer(); actions }.padding(16)
    }.frame(width: 580)
  }
}

struct SettingsView: View {
  @Bindable var state: AppState
  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        tab("Environments", image: "desktopcomputer", selection: .environments)
        tab("Coding Agents", image: "person.crop.circle", selection: .agents)
        tab("Settings", image: "slider.horizontal.3", selection: .general)
      }.padding(10).frame(maxWidth: .infinity).background(.bar)
      Divider()
      switch state.settingsTab {
      case .environments: EnvironmentSettingsView(state: state)
      case .agents: AgentSettingsView(state: state, settings: state.agents)
      case .general: GeneralSettingsView(state: state)
      }
    }.frame(minWidth: 760, minHeight: 540)
      .sheet(item: $state.environmentSheet) { sheet in
        switch sheet {
        case .add: AddEnvironmentView(state: state)
        case .edit(let env): EnvironmentEditor(state: state, environment: env)
        }
      }
  }
  private func tab(_ title: String, image: String, selection: SettingsTab) -> some View {
    let selected = state.settingsTab == selection
    return Button { state.settingsTab = selection } label: {
      VStack(spacing: 6) {
        Image(systemName: image).font(.system(size: 25, weight: .regular))
        Text(title).font(.system(size: 12, weight: selected ? .medium : .regular))
      }.frame(width: 104, height: 60)
        .foregroundStyle(selected ? Color.accentColor : .secondary)
        .background(selected ? Color(nsColor: .controlBackgroundColor) : .clear, in: RoundedRectangle(cornerRadius: 10))
    }.buttonStyle(.plain).accessibilityLabel(title).accessibilityValue(selected ? "Selected" : "")
  }
}

private struct GeneralSettingsView: View {
  @Bindable var state: AppState
  @State private var loginEnabled = SMAppService.mainApp.status == .enabled
  @State private var detail: SettingsDetail?
  var body: some View {
    VStack(alignment: .leading, spacing: 26) {
      PreferenceRow(title: "General") {
        VStack(alignment: .leading, spacing: 12) {
          Toggle("Monitor repositories", isOn: Binding(get: { state.configuration.enabled }, set: {
            state.configuration.enabled = $0; state.save()
          }))
          Toggle("Launch Repobot at login", isOn: $loginEnabled).onChange(of: loginEnabled) { _, enabled in
            do {
              if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
              state.error = "Launch at login: \(error.localizedDescription)"
              loginEnabled = SMAppService.mainApp.status == .enabled
            }
          }
        }
      }
      managed("Checks", summary: "Events with periodic safety checks", detail: .checks)
      managed("Notifications", summary: state.configuration.notifications ? "Enabled" : "Off", detail: .notifications)
      managed("Findings", summary: "Choose what needs your attention", detail: .findings)
      managed("Hidden findings", summary: "\(state.configuration.ignored.count) ignored · \(state.configuration.snoozed.count) snoozed", detail: .hidden)
      managed("SSH", summary: "Use your SSH keys and configuration", detail: .ssh)
      managed("Diagnostics", summary: "Logs and configuration files", detail: .diagnostics)
      if let error = state.error {
        Text(error).font(.caption).foregroundStyle(.red).lineLimit(3).textSelection(.enabled)
      }
      Spacer(minLength: 0)
    }.padding(.horizontal, 32).padding(.top, 34).padding(.bottom, 16)
      .sheet(item: $detail) { SettingsDetailView(state: state, section: $0) }
  }
  private func managed(_ label: String, summary: String, detail: SettingsDetail) -> some View {
    PreferenceRow(title: label) {
      HStack {
        Text(summary).lineLimit(2)
        Spacer(minLength: 12)
        Button("Manage…") { self.detail = detail }.frame(width: 90)
      }
    }
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
  init(state: AppState, section: SettingsDetail) {
    self.state = state; self.section = section
    _draft = State(initialValue: state.configuration)
    _extraOptions = State(initialValue: state.configuration.extraSSHOptions.joined(separator: "\n"))
  }
  var body: some View {
    PreferencesDialog(title: section.rawValue, subtitle: subtitle) {
      fields
      if let error = state.error { Text(error).font(.caption).foregroundStyle(.red).lineLimit(3) }
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
      number("Polling", value: $draft.pollInterval, unit: "seconds")
      number("Safety sweep", value: $draft.safetyInterval, unit: "seconds")
      number("Upstream", value: $draft.upstreamInterval, unit: "seconds")
      PreferenceRow(title: "Method") {
        Picker("Upstream method", selection: $draft.upstreamCheck) {
          Text("Read-only check").tag(UpstreamCheck.lsRemote)
          Text("Fetch (updates tracking refs)").tag(UpstreamCheck.fetch)
          Text("Off").tag(UpstreamCheck.off)
        }.labelsHidden()
      }
      Toggle("Check less often when idle on battery", isOn: $draft.batteryAware)
      if draft.upstreamCheck == .fetch {
        Text("Fetch writes remote-tracking refs in monitored repositories.").font(.caption).foregroundStyle(.orange)
      }
    case .notifications:
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
      TextEditor(text: $extraOptions).font(.system(.body, design: .monospaced)).frame(height: 110)
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
        TextField(title, value: value, format: .number).textFieldStyle(.roundedBorder).frame(width: 76)
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
      Spacer(); Button("Restore", action: restore)
    }
  }
  private func save() {
    let requestNotifications = section == .notifications && draft.notifications && !state.configuration.notifications
    switch section {
    case .checks:
      state.configuration.pollInterval = draft.pollInterval
      state.configuration.safetyInterval = draft.safetyInterval
      state.configuration.upstreamInterval = draft.upstreamInterval
      state.configuration.upstreamCheck = draft.upstreamCheck
      state.configuration.batteryAware = draft.batteryAware
    case .notifications:
      state.configuration.notifications = draft.notifications
      state.configuration.notifyAttention = draft.notifyAttention
      state.configuration.notifyProblem = draft.notifyProblem
      state.configuration.quietHours = draft.quietHours
      state.configuration.quietStart = draft.quietStart
      state.configuration.quietEnd = draft.quietEnd
    case .findings:
      state.configuration.dirtyHours = draft.dirtyHours
      state.configuration.unpushedHours = draft.unpushedHours
      state.configuration.disabledFindings = draft.disabledFindings
      state.configuration.reportStaleBranches = draft.reportStaleBranches
      state.configuration.staleBranchDays = draft.staleBranchDays
    case .hidden:
      state.configuration.ignored = draft.ignored; state.configuration.snoozed = draft.snoozed
    case .ssh:
      state.configuration.sshPath = draft.sshPath
      state.configuration.extraSSHOptions = extraOptions.split(separator: "\n").map(String.init)
    case .diagnostics: state.configuration.debugLogging = draft.debugLogging
    }
    state.save()
    if requestNotifications { state.requestNotifications() }
    if state.error == nil { dismiss() }
  }
}
