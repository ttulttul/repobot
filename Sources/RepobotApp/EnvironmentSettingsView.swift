import RepobotCore
import SwiftUI

struct EnvironmentSettingsView: View {
  @Bindable var state: AppState
  @State private var selection: UUID?
  @State private var removing = false
  @State private var diagnostics: EnvironmentSnapshot?
  private var selected: RepobotCore.Environment? {
    state.configuration.environments.first { $0.id == selection } ?? state.configuration.environments.first
  }
  var body: some View {
    HStack(spacing: 0) {
      VStack(spacing: 0) {
        List(selection: $selection) {
          ForEach(state.configuration.environments) { env in
            HStack(spacing: 10) {
              Image(systemName: env.kind == .local ? "laptopcomputer" : "desktopcomputer").font(.title2)
              VStack(alignment: .leading, spacing: 4) {
                Text(env.name).fontWeight(.medium)
                Text(env.kind == .local ? "This device" : env.host).font(.caption).foregroundStyle(.secondary).lineLimit(1)
              }
            }.padding(.vertical, 8).tag(env.id)
          }
        }.listStyle(.sidebar)
        Divider()
        HStack {
          Button("Add Environment…") { state.showAdd() }.frame(maxWidth: .infinity)
          Menu {
            Button("Remove environment…", role: .destructive) { removing = true }
              .disabled(selected?.kind != .ssh)
          } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 26)
        }.padding(12)
      }.frame(width: 230)
      Divider()
      if let env = selected {
        detail(env).frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ContentUnavailableView("No environments", systemImage: "desktopcomputer", description: Text("Add a development machine to get started."))
      }
    }
    .sheet(item: $diagnostics) { snapshot in
      PreferencesDialog(title: "Monitoring details", subtitle: snapshot.environment.name) {
        Text(snapshot.mode).font(.headline)
        if let failure = snapshot.watcherFailure {
          Text("Last watcher failure · " + failure.occurredAt.formatted()).font(.subheadline)
          ScrollView { Text(failure.message).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            .frame(maxHeight: 150)
          Text(failure.recoveredAt.map { "Recovered " + $0.formatted() } ?? "Not yet recovered").foregroundStyle(.secondary)
        } else { Text("No watcher failures recorded.").foregroundStyle(.secondary) }
        if let reason = snapshot.lastCheckReason {
          Text("Last check: " + reason)
          if let date = snapshot.lastCheckStartedAt { Text("Started " + date.formatted()).foregroundStyle(.secondary) }
          if let date = snapshot.lastCheckFinishedAt { Text("Finished " + date.formatted()).foregroundStyle(.secondary) }
        }
      } actions: { Button("Done") { diagnostics = nil }.keyboardShortcut(.defaultAction) }
    }
    .onAppear { if selection == nil { selection = state.configuration.environments.first?.id } }
    .alert("Remove \(selected?.name ?? "environment")?", isPresented: $removing) {
      Button("Cancel", role: .cancel) {}
      Button("Remove", role: .destructive) {
        guard let env = selected, env.kind == .ssh else { return }
        state.configuration.environments.removeAll { $0.id == env.id }
        selection = state.configuration.environments.first?.id
        state.save()
      }
    } message: { Text("Repobot will stop monitoring this machine. Its repositories are kept.") }
  }
  private func detail(_ env: RepobotCore.Environment) -> some View {
    let snapshot = state.world.environments.first { $0.id == env.id }
    return VStack(spacing: 24) {
      VStack(spacing: 12) {
        Image(systemName: env.kind == .local ? "laptopcomputer" : "desktopcomputer")
          .font(.system(size: 42, weight: .light)).foregroundStyle(.tint)
        Text(env.name).font(.title2.bold())
      }.padding(.top, 28)
      VStack(alignment: .leading, spacing: 18) {
        PreferenceRow(title: "Connection") {
          Text(env.kind == .local ? "This Mac" : (env.user.isEmpty ? env.host : "\(env.user)@\(env.host)"))
            .lineLimit(2).textSelection(.enabled)
        }
        PreferenceRow(title: "Status") {
          HStack(alignment: .top, spacing: 7) {
            Circle().fill(snapshot?.error != nil || snapshot?.reconnecting == true ? Color.orange : snapshot?.checkProgress != nil ? Color.blue : Color.green)
              .frame(width: 8, height: 8).padding(.top, 4)
            Text(snapshot?.error ?? snapshot?.checkProgress ?? (state.configuration.enabled ? snapshot?.mode ?? "Starting" : "Monitoring paused"))
              .fixedSize(horizontal: false, vertical: true).lineLimit(3).textSelection(.enabled)
          }
        }
        PreferenceRow(title: "Monitoring") {
          Button(snapshot?.reconnecting == true ? "Watcher issue…" : "Details…") { diagnostics = snapshot }
            .disabled(snapshot == nil)
        }
        PreferenceRow(title: "Repositories") { Text("\(snapshot?.repos.count ?? 0) in \(env.roots.count) root folders") }
        PreferenceRow(title: "Last check") {
          Text(snapshot?.checkedAt?.formatted(.relative(presentation: .named)) ?? "Not checked yet").foregroundStyle(.secondary)
        }
      }
      HStack(spacing: 10) {
        Button("Edit…") { state.edit(env) }
        Button("Check Now") { state.check(env.id, rescan: true) }.disabled(state.checking || !state.configuration.enabled)
        Button("Open Terminal") { state.openTerminal(env) }
      }
      if let error = state.error { Text(error).font(.caption).foregroundStyle(.red).lineLimit(3) }
      Spacer(minLength: 0)
    }.padding(.horizontal, 24)
  }
}

private enum EnvironmentDetail: String, Identifiable {
  case roots = "Repository folders", connection = "SSH connection", monitoring = "Monitoring"
  var id: String { rawValue }
}
struct EnvironmentEditor: View {
  @Bindable var state: AppState
  @State var environment: RepobotCore.Environment
  @SwiftUI.Environment(\.dismiss) private var dismiss
  @State private var detail: EnvironmentDetail?
  @State private var error: String?
  var body: some View {
    PreferencesDialog(title: "Edit environment", subtitle: "Choose where Repobot looks for repositories.") {
      PreferenceRow(title: "Name") { TextField("Name", text: $environment.name).textFieldStyle(.roundedBorder) }
      row("Folders", summary: "\(environment.roots.count) repository root folders", destination: .roots)
      if environment.kind == .ssh { row("Connection", summary: environment.host, destination: .connection) }
      row("Monitoring", summary: environment.watchMode == .poll ? "Polling" : "Automatic events and safety checks", destination: .monitoring)
      if let error = error ?? state.error { Text(error).font(.caption).foregroundStyle(.red).lineLimit(3) }
    } actions: {
      Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
      Button("Save") {
        guard !environment.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !environment.roots.isEmpty else {
          error = "Enter a name and at least one repository folder."; return
        }
        state.update(environment)
        if state.error == nil { dismiss() }
      }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
    }.sheet(item: $detail) { EnvironmentDetailView(state: state, environment: $environment, section: $0) }
  }
  private func row(_ title: String, summary: String, destination: EnvironmentDetail) -> some View {
    PreferenceRow(title: title) {
      HStack { Text(summary).lineLimit(2); Spacer(); Button("Manage…") { detail = destination } }
    }
  }
}

private struct EnvironmentDetailView: View {
  @Bindable var state: AppState
  @Binding var environment: RepobotCore.Environment
  let section: EnvironmentDetail
  @SwiftUI.Environment(\.dismiss) private var dismiss
  @State private var draft: RepobotCore.Environment
  @State private var roots: String
  @State private var interval: String
  @State private var status = ""
  @State private var testing = false
  @State private var resetTrust = false
  init(state: AppState, environment: Binding<RepobotCore.Environment>, section: EnvironmentDetail) {
    self.state = state; _environment = environment; self.section = section
    _draft = State(initialValue: environment.wrappedValue)
    _roots = State(initialValue: environment.wrappedValue.roots.joined(separator: "\n"))
    _interval = State(initialValue: environment.wrappedValue.pollInterval.map { String(Int($0)) } ?? "")
  }
  var body: some View {
    PreferencesDialog(title: section.rawValue, subtitle: draft.name) {
      switch section {
      case .roots:
        Text("One folder per line. Repobot looks for repositories inside these folders.").foregroundStyle(.secondary)
        TextEditor(text: $roots).font(.system(.body, design: .monospaced)).frame(height: 160)
          .border(Color.secondary.opacity(0.2))
        if draft.kind == .local {
          Button("Choose folder…") {
            let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
            if panel.runModal() == .OK, let path = panel.url?.path { roots += roots.isEmpty ? path : "\n" + path }
          }
        }
      case .connection:
        field("Host", text: $draft.host)
        field("Username", text: $draft.user)
        PreferenceRow(title: "Port") {
          TextField("Port", value: Binding(get: { draft.port ?? 22 }, set: { draft.port = $0 }), format: .number)
            .textFieldStyle(.roundedBorder).frame(width: 90)
        }
        field("Identity file", text: Binding(get: { draft.identityFile ?? "" }, set: { draft.identityFile = $0.isEmpty ? nil : $0 }))
        Text("Leave the identity file blank to use your SSH configuration.").font(.caption).foregroundStyle(.secondary)
        HStack {
          Button(testing ? "Testing…" : "Test connection") { Task { await test() } }.disabled(testing)
          Spacer()
          Button("Reset host key trust…", role: .destructive) { resetTrust = true }
        }
      case .monitoring:
        PreferenceRow(title: "Watch mode") {
          Picker("Watch mode", selection: $draft.watchMode) {
            Text("Automatic").tag(WatchMode.auto)
            Text("Events").tag(WatchMode.events)
            Text("Polling").tag(WatchMode.poll)
          }.labelsHidden()
        }
        field("Poll seconds", text: $interval)
        Text("Leave blank to use the global polling interval.").font(.caption).foregroundStyle(.secondary)
        PreferenceRow(title: "Upstream") {
          Picker("Upstream", selection: $draft.upstreamCheck) {
            Text("Use global setting").tag(Optional<UpstreamCheck>.none)
            Text("Read-only check").tag(Optional(UpstreamCheck.lsRemote))
            Text("Fetch (updates tracking refs)").tag(Optional(UpstreamCheck.fetch))
            Text("Off").tag(Optional(UpstreamCheck.off))
          }.labelsHidden()
        }
      }
      if !status.isEmpty { Text(status).font(.caption).textSelection(.enabled).lineLimit(4) }
    } actions: {
      Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
      Button("Done") {
        draft.roots = roots.split(separator: "\n").map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !draft.roots.isEmpty else { status = "Choose at least one repository folder."; return }
        if !interval.isEmpty && Double(interval) == nil { status = "Enter a number of seconds."; return }
        if draft.kind == .ssh && (draft.host.isEmpty || !(1...65535).contains(draft.port ?? 22)) {
          status = "Enter a host and a port between 1 and 65535."; return
        }
        draft.pollInterval = Double(interval).map { max(10, $0) }
        environment = draft; dismiss()
      }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(testing)
    }.alert("Remove the trusted host key for \(draft.host)?", isPresented: $resetTrust) {
      Button("Cancel", role: .cancel) {}
      Button("Reset trust", role: .destructive) {
        Task {
          let host = draft.port.map { "[\(draft.host)]:\($0)" } ?? draft.host
          do {
            let result = try await ProcessRunner.run("/usr/bin/ssh-keygen", ["-R", host], timeout: 10)
            status = result.status == 0 ? "Trust reset. Verify the new fingerprint before continuing." : result.errorText
          } catch { status = error.localizedDescription }
        }
      }
    } message: { Text("Only do this after independently verifying why the host’s key changed.") }
  }
  private func field(_ title: String, text: Binding<String>) -> some View {
    PreferenceRow(title: title) { TextField(title, text: text).textFieldStyle(.roundedBorder) }
  }
  private func test() async {
    testing = true; defer { testing = false }
    let transport = SSHTransport(environment: draft, configuration: state.configuration)
    do {
      draft.capabilities = try await Probe.capabilities(using: transport)
      status = "Connected · \(draft.capabilities?.gitVersion ?? "")"
    } catch { status = error.localizedDescription }
    await transport.close()
  }
}
