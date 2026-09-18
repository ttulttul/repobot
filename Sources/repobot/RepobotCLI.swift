import Foundation
import RepobotCore

@main struct RepobotCLI {
  static func main() async {
    do { try await run() } catch {
      FileHandle.standardError.write(Data("repobot: \(error.localizedDescription)\n".utf8))
      exit(1)
    }
  }
  static func run() async throws {
    var args = Array(CommandLine.arguments.dropFirst())
    guard let command = args.first else {
      usage()
      return
    }
    args.removeFirst()
    switch command {
    case "agent-mcp":
      guard args.count == 1 else { throw RepobotError.message("Expected an agent context file") }
      try await AgentMCP.serve(manifest: URL(fileURLWithPath: args[0]))
    case "config": try output(Configuration())
    case "discover":
      if args.contains("--hosts") {
        let hosts = args.contains("--scan-lan")
          ? await HostDiscovery.discoverLAN() : try await HostDiscovery.loadTailscale()
        for host in hosts {
          print(
            "\(host.source)\t\(host.host)\t\(host.address)\t\(host.source == "Tailscale" ? (host.online.map { $0 ? "Online" : "Offline" } ?? "Unknown") : host.banner)"
          )
        }
      } else {
        let roots = args.isEmpty ? ["~/git"] : args
        for path in try await Probe.discover(roots: roots, using: LocalTransport()) { print(path) }
      }
    case "probe", "capabilities":
      let upstream: UpstreamCheck = args.contains("--upstream") ? .lsRemote : .off
      args.removeAll { $0 == "--upstream" }
      let destination = args.isEmpty ? "local" : args.removeFirst()
      var env =
        destination == "local" ? Environment.local : try HostDiscovery.parseManual(destination)
      env.roots = args.isEmpty ? ["~/git"] : args
      let transport: any Transport =
        env.kind == .local ? LocalTransport() : SSHTransport(environment: env)
      if command == "capabilities" {
        try output(await Probe.capabilities(using: transport))
      } else {
        let paths = try await Probe.discover(roots: env.roots, using: transport)
        var snapshot = EnvironmentSnapshot(environment: env)
        snapshot.repos = SnapshotList(try await Probe.repos(paths, upstream: upstream, using: transport))
        snapshot.checkedAt = Date()
        snapshot.mode = "CLI"
        try output(Analyzer.analyze([snapshot], configuration: Configuration()))
      }
      await transport.close()
    case "watch":
      var c = Configuration()
      var env = Environment.local
      env.roots = args.isEmpty ? ["~/git"] : args
      c.environments = [env]
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "repobot-cli-\(UUID())")
      let store = StateStore(configuration: c, persistence: Persistence(directory: directory))
      let monitor = EnvironmentMonitor(environment: env, configuration: c, store: store)
      await monitor.start()
      for await world in await store.stream() { try output(world) }
      await monitor.stop()
      try? FileManager.default.removeItem(at: directory)
    case "help", "--help", "-h": usage()
    default: throw RepobotError.message("Unknown command '\(command)'. Run repobot --help.")
    }
  }
  static func output<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(decoding: try encoder.encode(value), as: UTF8.self))
  }
  static func usage() {
    print(
      """
      repobot config                         Print the default configuration as JSON
      repobot discover [root ...]             Find local repositories (default ~/git)
      repobot discover --hosts                List known Tailscale devices (no scanning)
      repobot discover --hosts --scan-lan     Scan the LAN for SSH hosts
      repobot probe local|user@host [roots] [--upstream]
      repobot capabilities local|user@host    Inspect available tools and suggested roots
      repobot watch [root ...]                Stream local monitoring snapshots
      Probes are read-only. --upstream enables read-only ls-remote, never fetch.
      """)
  }
}
