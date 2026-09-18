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
        if let warning = snapshot.watcherCoverageWarning {
          Text(warning).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
        }
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
        if state.removeEnvironment(env.id) { selection = state.configuration.environments.first?.id }
      }
    } message: { Text("Repobot will stop monitoring this machine. Its repositories are kept.") }
  }
  private func detail(_ env: RepobotCore.Environment) -> some View {
    let snapshot = state.world.environments.first { $0.id == env.id }
    return ScrollView { VStack(spacing: 24) {
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
            Circle().fill(env.roots.isEmpty || !state.configuration.enabled ? Color.secondary : snapshot?.error != nil || snapshot?.reconnecting == true ? Color.orange : snapshot?.checkProgress != nil ? Color.blue : Color.green)
              .frame(width: 8, height: 8).padding(.top, 4)
            Text(env.roots.isEmpty ? "Choose repository folders to begin" : snapshot?.checkProgress ?? (!state.configuration.enabled ? "Monitoring paused" : snapshot?.error ?? snapshot?.mode ?? "Starting"))
              .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
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
      if env.roots.isEmpty {
        Text("Choose a repository folder to start monitoring this Mac.")
          .foregroundStyle(.secondary)
        Button("Choose Repository Folder…") { chooseRoot(for: env) }.buttonStyle(.borderedProminent)
      }
      HStack(spacing: 10) {
        Button("Edit…") { state.edit(env) }
        Button(state.checking ? "Checking…" : "Check Now") { state.check(env.id, rescan: true) }.disabled(state.checking || env.roots.isEmpty)
        Button("Open Terminal") { state.openTerminal(env) }
      }
      if let error = state.error { OperationErrorView(message: error) }
      Spacer(minLength: 0)
    }.padding(.horizontal, 24).padding(.bottom, 24) }
  }
  private func chooseRoot(for environment: RepobotCore.Environment) {
    let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
    panel.allowsMultipleSelection = true; panel.prompt = "Choose"
    if panel.runModal() == .OK {
      var draft = environment; draft.roots = panel.urls.map(\.path)
      state.update(draft)
    }
  }
}

struct EnvironmentEditor: View {
  @Bindable var state: AppState
  @State var environment: RepobotCore.Environment
  @SwiftUI.Environment(\.dismiss) private var dismiss
  @State private var roots: String
  @State private var interval: String
  @State private var port: String
  @State private var status = ""
  @State private var error: String?
  @State private var testing = false
  @State private var testTask: Task<Void, Never>?
  @State private var resetTrust = false
  init(state: AppState, environment: RepobotCore.Environment) {
    self.state = state
    _environment = State(initialValue: environment)
    _roots = State(initialValue: environment.roots.joined(separator: "\n"))
    _port = State(initialValue: environment.port.map(String.init) ?? "")
    _interval = State(initialValue: environment.pollInterval.map { String(Int($0)) } ?? "")
  }
  var body: some View {
    PreferencesDialog(title: "Edit Environment", subtitle: "Changes take effect when you save.") {
      PreferenceRow(title: "Name") { TextField("Name", text: $environment.name).textFieldStyle(.roundedBorder) }
      VStack(alignment: .leading, spacing: 8) {
        Text("Repository Folders").font(.headline)
        Text("One folder per line. Repobot also searches inside these folders.").foregroundStyle(.secondary)
        TextEditor(text: $roots).font(.system(.body, design: .monospaced)).frame(height: 110)
          .accessibilityLabel("Repository root folders").border(Color.secondary.opacity(0.2))
        if environment.kind == .local {
          Button("Choose Folders…") {
            let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
            panel.allowsMultipleSelection = true
            if panel.runModal() == .OK {
              roots = ([roots].filter { !$0.isEmpty } + panel.urls.map(\.path)).joined(separator: "\n")
            }
          }
        }
      }
      if environment.kind == .ssh {
        DisclosureGroup("SSH Connection") {
          VStack(alignment: .leading, spacing: 12) {
            field("Host", text: $environment.host)
            field("Username", text: $environment.user)
            PreferenceRow(title: "Port") {
              TextField("SSH default", text: $port).accessibilityLabel("SSH port, optional")
                .textFieldStyle(.roundedBorder).frame(width: 90)
            }
            field("Identity file", text: Binding(get: { environment.identityFile ?? "" }, set: { environment.identityFile = $0.isEmpty ? nil : $0 }))
            Text("Leave the identity file blank to use your SSH configuration.").font(.caption).foregroundStyle(.secondary)
            HStack {
              Button(testing ? "Testing…" : "Test Connection") { testTask = Task { await test() } }.disabled(testing)
              Spacer()
              Button("Reset Host Key Trust…", role: .destructive) { resetTrust = true }.disabled(testing)
            }
            if !status.isEmpty { Text(status).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
          }.padding(.top, 10)
        }
      }
      DisclosureGroup("Advanced Monitoring") {
        VStack(alignment: .leading, spacing: 12) {
          PreferenceRow(title: "Watch mode") {
            Picker("Watch mode", selection: $environment.watchMode) {
              Text("Automatic").tag(WatchMode.auto); Text("Events").tag(WatchMode.events); Text("Polling").tag(WatchMode.poll)
            }.labelsHidden()
          }
          field("Poll seconds", text: $interval)
          Text("Use at least 10 seconds, or leave blank to use the global interval.").font(.caption).foregroundStyle(.secondary)
          PreferenceRow(title: "Upstream") {
            Picker("Upstream", selection: $environment.upstreamCheck) {
              Text("Use global setting").tag(Optional<UpstreamCheck>.none)
              Text("Read-only check").tag(Optional(UpstreamCheck.lsRemote))
              Text("Fetch (updates tracking refs)").tag(Optional(UpstreamCheck.fetch))
              Text("Off").tag(Optional(UpstreamCheck.off))
            }.labelsHidden()
          }
          if environment.upstreamCheck == .fetch {
            Label("Fetch updates remote-tracking refs in these repositories.", systemImage: "exclamationmark.triangle")
          }
        }.padding(.top, 10)
      }
      if let error = error ?? state.error { OperationErrorView(message: error) }
    } actions: {
      Button("Cancel") { testTask?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
      Button("Save") { save() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(testing)
    }
    .onDisappear { testTask?.cancel() }
    .alert("Remove the trusted host key for \(environment.host)?", isPresented: $resetTrust) {
      Button("Cancel", role: .cancel) {}
      Button("Reset Trust", role: .destructive) {
        guard let trustedEnvironment = connectionDraft(environment) else { return }
        testTask = Task {
          testing = true; defer { testing = false }
          let host = trustedEnvironment.port.map { "[\(trustedEnvironment.host)]:\($0)" } ?? trustedEnvironment.host
          do {
            let result = try await ProcessRunner.run("/usr/bin/ssh-keygen", ["-R", host], timeout: 10)
            status = result.status == 0 ? "Trust reset. Verify the new fingerprint before continuing." : result.errorText
          } catch { self.error = error.localizedDescription }
        }
      }
    } message: { Text("This changes SSH trust immediately, even if you later cancel editing. Only do this after independently verifying why the host’s key changed.") }
  }
  private func field(_ title: String, text: Binding<String>) -> some View {
    PreferenceRow(title: title) { TextField(title, text: text).textFieldStyle(.roundedBorder) }
  }
  private func save() {
    var proposed = environment
    proposed.roots = Array(Set(roots.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })).sorted()
    guard !proposed.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !proposed.roots.isEmpty else {
      error = "Enter a name and at least one repository folder."; return
    }
    if !interval.isEmpty {
      guard let seconds = Double(interval), seconds.isFinite, seconds >= 10 else {
        error = "Enter at least 10 seconds, or leave the polling interval blank."; return
      }
    }
    if proposed.kind == .ssh {
      guard let connection = connectionDraft(proposed) else { return }
      proposed = connection
    }
    proposed.pollInterval = Double(interval)
    if state.update(proposed) { dismiss() }
  }
  private func connectionDraft(_ input: RepobotCore.Environment) -> RepobotCore.Environment? {
    let value = port.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !input.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          value.isEmpty || Int(value).map({ (1...65535).contains($0) }) == true else {
      error = "Enter a host and a port between 1 and 65535, or leave the port blank for your SSH default."
      return nil
    }
    var proposed = input
    proposed.port = Int(value)
    error = nil
    return proposed
  }
  private func test() async {
    guard let testedEnvironment = connectionDraft(environment) else { return }
    testing = true; defer { testing = false }
    let transport = SSHTransport(environment: testedEnvironment, configuration: state.configuration)
    do {
      let capabilities = try await Probe.capabilities(using: transport)
      if !Task.isCancelled { environment.capabilities = capabilities; status = "Connected · " + capabilities.gitVersion }
    } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    await transport.close()
  }
}
