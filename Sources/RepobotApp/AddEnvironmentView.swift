import RepobotCore
import SwiftUI

struct AddEnvironmentView: View {
  @Bindable var state: AppState
  @State private var tailscaleHosts: [DiscoveredHost] = []
  @State private var lanHosts: [DiscoveredHost] = []
  @State private var refreshing = false
  @State private var discoveryStatus = ""
  @State private var lanStatus = ""
  private var hosts: [DiscoveredHost] {
    tailscaleHosts + lanHosts.filter { host in
      !tailscaleHosts.contains { $0.host == host.host || $0.address == host.address }
    }
  }
  @State private var scanning = false
  @State private var manual = ""
  @State private var username = NSUserName()
  @State private var key = ""
  @State private var name = ""
  @State private var selected: RepobotCore.Environment?
  @State private var capabilities: Capabilities?
  @State private var roots: Set<String> = []
  @State private var customRoots = ""
  @State private var status = "Select a host or enter its address"
  @State private var fingerprint = ""
  @State private var testing = false
  @State private var checkedSignature = ""
  var signature: String { "\(manual)|\(username)|\(key)" }
  @SwiftUI.Environment(\.dismiss) private var dismiss
  @State private var step = 0
  @State private var connectionTask: Task<Void, Never>?
  @State private var scanTask: Task<Void, Never>?
  @State private var refreshTask: Task<Void, Never>?
  @State private var selectionTask: Task<Void, Never>?
  private var validAddress: Bool { (try? HostDiscovery.parseManual(manual.trimmingCharacters(in: .whitespacesAndNewlines))) != nil }
  var body: some View {
    PreferencesDialog(title: ["Add environment", "Connect to machine", "Repository folders"][step],
                      subtitle: ["Choose a Tailscale device or enter an SSH address.",
                                 "Uses your existing SSH keys and configuration.",
                                 "Choose where Repobot should look for repositories."][step]) {
      if step == 0 {
        HStack {
          Text("Available devices").font(.headline)
          Spacer()
          Button(refreshing ? "Refreshing…" : "Refresh") { refreshTask = Task { await refreshTailscale() } }.disabled(refreshing)
          Menu { Button("Scan local network") { scanLAN() }.disabled(scanning) } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).frame(width: 24).accessibilityLabel("Device discovery options")
        }
        List(hosts) { host in
          Button { select(host) } label: {
            HStack {
              Image(systemName: host.os.lowercased().contains("mac") ? "desktopcomputer" : "server.rack")
              VStack(alignment: .leading, spacing: 3) {
                Text(host.name)
                Text("\(host.source) · \(host.address)").font(.caption).foregroundStyle(.secondary)
              }
              Spacer()
              if selected?.host == host.host { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
              else if host.source == "Tailscale" {
                Text(host.online.map { $0 ? "Online" : "Offline" } ?? "Unknown").font(.caption).foregroundStyle(.secondary)
              }
            }.contentShape(Rectangle()).padding(.vertical, 5)
          }.buttonStyle(.plain)
        }.frame(height: 190)
        TextField("Or enter user@host[:port]", text: $manual).textFieldStyle(.roundedBorder).accessibilityLabel("SSH address")
        if !manual.isEmpty && !validAddress { Text("Enter a host or user@host, with an optional port between 1 and 65535.").font(.caption) }
        Text(scanning ? "Scanning local network…" : !discoveryStatus.isEmpty ? discoveryStatus
             : !lanStatus.isEmpty ? lanStatus : "Tailscale devices appear without scanning.")
          .font(.caption).foregroundStyle(.secondary).lineLimit(3)
      } else if step == 1 {
        PreferenceRow(title: "Host") { Text(manual).textSelection(.enabled) }
        PreferenceRow(title: "Name") { TextField("Machine name", text: $name).textFieldStyle(.roundedBorder) }
        PreferenceRow(title: "Username") { TextField("Username", text: $username).textFieldStyle(.roundedBorder) }
        DisclosureGroup("Advanced SSH Identity") {
          VStack(alignment: .leading, spacing: 10) {
            HStack {
              TextField("Use SSH configuration", text: $key).textFieldStyle(.roundedBorder).accessibilityLabel("SSH identity file")
              Button("Choose…") {
                let panel = NSOpenPanel()
                panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
                panel.showsHiddenFiles = true
                if panel.runModal() == .OK, let path = panel.url?.path { key = path.hasSuffix(".pub") ? String(path.dropLast(4)) : path }
              }.accessibilityLabel("Choose SSH identity file")
            }
            Text("Leave blank to use your existing SSH keys and configuration. Passwords and passphrases are entered only in Terminal.")
              .font(.caption).foregroundStyle(.secondary)
          }.padding(.top, 10)
        }
        HStack {
          if testing { ProgressView().controlSize(.small) }
          Text(status).font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        if capabilities == nil {
          Button("Install key in Terminal…") {
            guard let env = try? HostDiscovery.parseManual(manual.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
            var args = ["ssh-copy-id"]
            if !key.isEmpty { args += ["-i", expandedPath(key) + ".pub"] }
            if let port = env.port { args += ["-p", String(port)] }
            args += ["\(username)@\(env.host)"]
            state.terminal(args.map(shellQuote).joined(separator: " "))
          }
        }
      } else if let capabilities {
        Label("Connected to \(name.isEmpty ? manual : name)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        if !capabilities.suggestedRoots.isEmpty {
          List(capabilities.suggestedRoots, id: \.self) { root in
            Toggle(root, isOn: Binding(get: { roots.contains(root) }, set: {
              if $0 { roots.insert(root) } else { roots.remove(root) }
            }))
          }.frame(height: min(150, CGFloat(capabilities.suggestedRoots.count * 32 + 12)))
        }
        if !fingerprint.isEmpty {
          DisclosureGroup("Trusted Host Key") {
            Text(fingerprint).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
          }
        }
        Text("Additional folders").font(.headline)
        TextField("One folder per line", text: $customRoots, axis: .vertical).accessibilityLabel("Additional repository folders").lineLimit(3...3).textFieldStyle(.roundedBorder)
        if !status.hasPrefix("Connected") { Text(status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
      }
    } actions: {
      Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
      if step > 0 { Button("Back") { step -= 1 }.disabled(testing) }
      Button(step == 2 ? "Add Environment" : testing ? "Connecting…" : "Continue") {
        if step == 0 {
          if let parsed = try? HostDiscovery.parseManual(manual.trimmingCharacters(in: .whitespacesAndNewlines)), manual.contains("@") { username = parsed.user }
          status = "Ready to test the SSH connection"; step = 1
        } else if step == 1 {
          connectionTask = Task { await test(); if !Task.isCancelled && capabilities != nil && checkedSignature == signature { step = 2 } }
        } else { addEnvironment() }
      }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!validAddress || testing)
    }
    .task { await refreshTailscale() }
    .onChange(of: signature) { _, _ in capabilities = nil; fingerprint = "" }
    .onDisappear { connectionTask?.cancel(); scanTask?.cancel(); refreshTask?.cancel(); selectionTask?.cancel() }
  }
  private func addEnvironment() {
    guard var env = selected, checkedSignature == signature, let capabilities else { return }
    env.name = name.isEmpty ? env.host : name
    env.user = username
    env.identityFile = key.isEmpty ? nil : key
    env.roots = Array(Set(Array(roots) + customRoots.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })).sorted()
    env.capabilities = capabilities
    guard !env.roots.isEmpty else { status = "Select at least one root folder"; return }
    if state.add(env) { dismiss() } else { status = state.error ?? "Could not save environment" }
  }
  func select(_ host: DiscoveredHost) {
    let address = host.host.contains(":") ? "[\(host.host)]" : host.host
    manual = host.port == 22 ? address : "\(address):\(host.port)"
    name = host.name
    var env = RepobotCore.Environment(name: host.name, kind: .ssh)
    env.host = host.host
    env.port = host.port
    env.tailscaleNodeID = host.nodeID
    selected = env
    selectionTask?.cancel()
    selectionTask = Task {
      let user = await HostDiscovery.configuredUser(
        for: host.host, sshPath: state.configuration.sshPath)
      guard !Task.isCancelled, selected?.host == host.host else { return }
      username = user
    }
  }
  func refreshTailscale() async {
    guard !refreshing else { return }
    refreshing = true
    defer { refreshing = false }
    do {
      tailscaleHosts = try await HostDiscovery.loadTailscale()
      discoveryStatus = tailscaleHosts.isEmpty ? "No Tailscale devices found." : ""
    } catch {
      tailscaleHosts = []
      discoveryStatus = error.localizedDescription
    }
  }
  func scanLAN() {
    guard !scanning else { return }
    scanning = true
    lanStatus = ""
    scanTask = Task {
      defer { scanning = false }
      async let network = HostDiscovery.discoverLAN()
      let bonjour = await BonjourDiscovery().discover()
      let verifiedBonjour = await HostDiscovery.scan(bonjour)
      let found = await network
      guard !Task.isCancelled else { return }
      lanHosts = found + verifiedBonjour.filter { host in
        !found.contains { $0.host == host.host || $0.address == host.address }
      }
      lanStatus = lanHosts.isEmpty ? "No SSH hosts found on the local network." : ""
      scanning = false
    }
  }
  func test() async {
    let requested = signature
    testing = true
    defer { testing = false }
    var testedTransport: SSHTransport?
    do {
      var env = try HostDiscovery.parseManual(manual.trimmingCharacters(in: .whitespacesAndNewlines))
      if let previous = selected, previous.host == env.host {
        env.tailscaleNodeID = previous.tailscaleNodeID
      }
      // An explicit user@host entry wins until the separate username field is edited.
      if manual.contains("@"), let parsed = manual.split(separator: "@").first,
        username == NSUserName()
      {
        username = String(parsed)
      }
      env.user = username
      env.identityFile = key.isEmpty ? nil : key
      let transport = SSHTransport(environment: env, configuration: state.configuration)
      testedTransport = transport
      let cap = try await Probe.capabilities(using: transport)
      guard !Task.isCancelled, requested == signature else {
        await transport.close()
        return
      }
      selected = env
      capabilities = cap
      checkedSignature = signature
      roots = Set(cap.suggestedRoots.prefix(1))
      status = "Connected as \(env.user) · \(cap.gitVersion) · \(cap.os)"
      let lookup = env.port.map { "[\(env.host)]:\($0)" } ?? env.host
      if let records = try? await ProcessRunner.run(
        "/usr/bin/ssh-keygen", ["-F", lookup], timeout: 5), records.status == 0,
        let fp = try? await ProcessRunner.run(
          "/usr/bin/ssh-keygen", ["-lf", "/dev/stdin"], input: records.stdout, timeout: 5)
      {
        fingerprint = fp.text.trimmingCharacters(in: .whitespacesAndNewlines)
      }
      await transport.close()
    } catch {
      await testedTransport?.close()
      guard !Task.isCancelled, requested == signature else { return }
      capabilities = nil
      status = error.localizedDescription
      state.log(
        state.configuration.debugLogging
          ? status : "SSH connection test failed (host details redacted)")
    }
  }
}
