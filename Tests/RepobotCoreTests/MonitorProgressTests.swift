import Foundation
import Testing
@testable import RepobotCore

private actor ProgressTransport: Transport {
  let paths = (0..<12).map { "/repos/repo-\($0)" }
  var discoveryCalls = 0
  var baseBatches = 0
  var basePaths: [[String]] = []
  var upstreamStarted = false
  var releaseBase = false
  var releaseUpstream = false
  var failUpstreamTransport = false
  func allowBase() { releaseBase = true }
  func allowUpstream(fail: Bool = false) { releaseUpstream = true; failUpstreamTransport = fail }
  func run(script: String, arguments: [String], timeout: Double) async throws -> CommandResult {
    if arguments.first == "/repos" {
      discoveryCalls += 1
      return CommandResult(stdout: Data((paths.joined(separator: "\0") + "\0").utf8), stderr: Data(), status: 0)
    }
    let upstream = arguments.first != "off"
    if upstream {
      upstreamStarted = true
      while !releaseUpstream { try await Task.sleep(for: .milliseconds(10)) }
      if failUpstreamTransport { throw RepobotError.message("SSH connection lost") }
    } else {
      baseBatches += 1
      basePaths.append(stride(from: 1, to: arguments.count, by: 2).map { arguments[$0] })
      if baseBatches > 1 {
        while !releaseBase { try await Task.sleep(for: .milliseconds(10)) }
      }
    }
    let records = stride(from: 1, to: arguments.count, by: 2).flatMap { index -> [String] in
      let path = arguments[index]
      var fields = ["REPO", path, "HEAD", "new-tip", "main", "0", "COUNTS", "0", "0", "0", "1", "0", "0",
                    "UPSTREAM", "origin/main", "base", "0", "ORIGIN", "https://example.test/repo.git"]
      if upstream { fields += ["FRESH", "error", "Upstream authentication failed"] }
      return fields + ["END", path]
    }
    return CommandResult(stdout: Data((records.joined(separator: "\0") + "\0").utf8), stderr: Data(), status: 0)
  }
  nonisolated func invocation(program: String, arguments: [String]) -> (String, [String]) {
    ("/usr/bin/false", [])
  }
  func close() async {}
}

struct MonitorProgressTests {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["REPOBOT_TEST_LIVE_MONITORS"] == "1"))
  func testConfiguredMachinesPublishBeforeUpstreamCompletes() async throws {
    let persistence = Persistence()
    var config = try #require(try persistence.load(Configuration.self, from: "config.json"))
    let cached = try persistence.loadWorld(configuration: config)
    // Explicit opt-in live check: read-only, isolated cache and SSH sockets.
    config.upstreamCheck = .lsRemote
    config.enabled = true
    for i in config.environments.indices {
      config.environments[i].upstreamCheck = .lsRemote
      config.environments[i].watchMode = .poll
    }
    let root = URL(fileURLWithPath: "/tmp/rbm-" + UUID().uuidString.prefix(12))
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let store = StateStore(configuration: config, persistence: Persistence(directory: root), cached: cached)
    var monitors: [EnvironmentMonitor] = []
    for env in config.environments {
      let transport: any Transport = env.kind == .local ? LocalTransport()
        : SSHTransport(environment: env, configuration: config, controlDirectory: root.appendingPathComponent("ssh"))
      let monitor = EnvironmentMonitor(environment: env, configuration: config, store: store, transport: transport)
      monitors.append(monitor)
      await monitor.start()
    }
    let started = Date()
    var completed = Set<UUID>()
    var firstProgress = Set<UUID>()
    var reportedAt = Date()
    do {
      while Date().timeIntervalSince(started) < 300 && completed.count < monitors.count {
        for env in config.environments where !completed.contains(env.id) {
          guard let snapshot = await store.snapshot(for: env.id) else { continue }
          if let error = snapshot.error { throw RepobotError.message("Live monitor failed: " + error) }
          let ready = snapshot.repos.filter { $0.awaitingFreshCheck != true }.count
          if ready > 0 && firstProgress.insert(env.id).inserted {
            print("Live monitor \(env.name): first \(ready) results after \(Int(Date().timeIntervalSince(started)))s")
          }
          if Date().timeIntervalSince(reportedAt) >= 15 {
            print("Live progress \(env.name): \(ready)/\(snapshot.repos.count), \(snapshot.repos.filter { $0.error != nil }.count) repo errors, \(snapshot.checkProgress ?? "idle")")
          }
          if snapshot.checkedAt.map({ $0 >= started }) == true {
            completed.insert(env.id)
            print("Live monitor \(env.name): \(ready) repositories checked after \(Int(Date().timeIntervalSince(started)))s; \(snapshot.checkProgress ?? "complete")")
          }
        }
        if Date().timeIntervalSince(reportedAt) >= 15 { reportedAt = Date() }
        try await Task.sleep(for: .milliseconds(250))
      }
      #expect(completed.count == monitors.count)
    } catch {
      for monitor in monitors { await monitor.stop() }
      throw error
    }
    for monitor in monitors { await monitor.stop() }
  }

  @Test func testPartialRefreshAndSlowUpstreamDoNotMarkHostOffline() async throws {
    let root = try CoreTests().temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let transport = ProgressTransport()
    var env = Environment(name: "Available machine", kind: .ssh, roots: ["/repos"])
    env.watchMode = .poll
    env.capabilities = Capabilities()
    var config = Configuration()
    config.environments = [env]
    var cached = EnvironmentSnapshot(environment: env)
    cached.repos = transport.paths.map { path in
      var repo = RepoSnapshot(path: path)
      repo.headSHA = "old-tip"
      return repo
    }
    cached.checkedAt = Date(timeIntervalSince1970: 100)
    let store = StateStore(configuration: config, persistence: Persistence(directory: root),
                           cached: Analyzer.analyze([cached], configuration: config))
    let monitor = EnvironmentMonitor(environment: env, configuration: config, store: store, transport: transport)
    await monitor.start()
    for _ in 0..<200 {
      if await transport.baseBatches >= 2 { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    var world = await store.world()
    #expect(await transport.baseBatches == 2)
    #expect(world.clones.count == 12)
    #expect(world.clones.filter { !world.isUnverified($0) }.count == 8)
    #expect(world.clones.allSatisfy { !world.isUnavailable($0) })
    #expect(world.environments[0].checkProgress == "Checking repositories: 8 of 12")
    #expect(world.clones.filter { $0.repo.awaitingFreshCheck == true }.allSatisfy { $0.repo.headSHA == "old-tip" })
    await transport.allowBase()
    for _ in 0..<200 {
      if await transport.upstreamStarted { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    world = await store.world()
    #expect(await transport.upstreamStarted)
    #expect(world.clones.allSatisfy { !world.isUnverified($0) && $0.repo.modified == 1 })
    #expect(world.environments[0].checkedAt! > cached.checkedAt!)
    #expect(world.environments[0].checkProgress?.hasPrefix("Checking upstreams:") == true)
    await transport.allowUpstream()
    for _ in 0..<200 {
      world = await store.world()
      if world.environments[0].checkProgress == nil { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(world.environments[0].checkProgress == nil)
    #expect(world.clones.allSatisfy { !world.isUnavailable($0) && $0.repo.upstreamError != nil })
    await monitor.stop()
  }

  @Test func testConnectionFailurePreservesFreshInventory() async throws {
    let root = try CoreTests().temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let transport = ProgressTransport()
    await transport.allowBase()
    await transport.allowUpstream(fail: true)
    var env = Environment(name: "Connection drops", kind: .ssh, roots: ["/repos"])
    env.watchMode = .poll
    env.capabilities = Capabilities()
    var config = Configuration()
    config.environments = [env]
    let store = StateStore(configuration: config, persistence: Persistence(directory: root))
    let monitor = EnvironmentMonitor(environment: env, configuration: config, store: store, transport: transport)
    await monitor.start()
    var world = await store.world()
    for _ in 0..<200 {
      world = await store.world()
      if world.environments[0].error != nil { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    let failedBatches = await transport.baseBatches
    try await Task.sleep(for: .milliseconds(1200))
    #expect(await transport.baseBatches == failedBatches)
    #expect(world.environments[0].error == "SSH connection lost")
    #expect(world.environments[0].checkProgress == nil)
    #expect(world.clones.count == 12)
    #expect(world.clones.allSatisfy { world.isUnavailable($0) && $0.repo.headSHA == "new-tip" })
    await monitor.stop()
  }
}

private actor PublishedWorld {
  var latest: WorldSnapshot?
  func receive(_ world: WorldSnapshot) { latest = world }
}

extension MonitorProgressTests {
  @Test(arguments: [false, true])
  func testStreamPublishesPartialResultsAndFlushesOnCompletionOrStop(stopEarly: Bool) async throws {
    let root = try CoreTests().temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let transport = ProgressTransport()
    var env = Environment(name: "Streaming machine", kind: .ssh, roots: ["/repos"])
    env.watchMode = .poll
    env.capabilities = Capabilities()
    var config = Configuration()
    config.environments = [env]
    let store = StateStore(configuration: config, persistence: Persistence(directory: root),
                           publicationDelay: .milliseconds(20), persistenceDelay: .seconds(60))
    let published = PublishedWorld()
    let stream = await store.stream()
    let listener = Task { for await value in stream { await published.receive(value) } }
    defer { listener.cancel() }
    let monitor = EnvironmentMonitor(environment: env, configuration: config, store: store, transport: transport)
    await monitor.start()
    for _ in 0..<200 {
      if let value = await published.latest, value.clones.filter({ !value.isUnverified($0) }).count == 8 { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    let partial = try #require(await published.latest)
    #expect(partial.clones.count == 12)
    #expect(partial.clones.filter { !partial.isUnverified($0) }.count == 8)
    #expect(partial.environments[0].checkProgress == "Checking repositories: 8 of 12")
    #expect(await store.cacheWriteCount == 0)
    if stopEarly {
      await monitor.stop()
      let saved = try #require(try Persistence(directory: root).loadWorld(configuration: Configuration()))
      #expect(saved.clones.filter { !saved.isUnverified($0) }.count == 8)
      #expect(await store.cacheWriteCount == 1)
      return
    }
    await transport.allowBase()
    await transport.allowUpstream()
    for _ in 0..<200 {
      if await store.cacheWriteCount > 0 { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    let saved = try #require(try Persistence(directory: root).loadWorld(configuration: Configuration()))
    #expect(saved.clones.count == 12)
    #expect(saved.environments[0].checkProgress == nil)
    #expect(await store.cacheWriteCount == 1)
    await monitor.stop()
  }
}

extension MonitorProgressTests {
  @Test func testEditsDuringUpstreamQueueOnlyAffectedRepositories() async throws {
    let root = try CoreTests().temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let transport = ProgressTransport()
    await transport.allowBase()
    var env = Environment(name: "Busy machine", kind: .ssh, roots: ["/repos"])
    env.watchMode = .poll; env.capabilities = Capabilities()
    var config = Configuration(); config.environments = [env]
    let store = StateStore(configuration: config, persistence: Persistence(directory: root))
    let monitor = EnvironmentMonitor(environment: env, configuration: config, store: store, transport: transport)
    await monitor.start()
    for _ in 0..<200 {
      if await transport.upstreamStarted { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await transport.upstreamStarted)
    await monitor.repositoryChanged("/repos/repo-3/tracked")
    // Let the normal event debounce expire while the upstream probe remains blocked.
    try await Task.sleep(for: .milliseconds(2200))
    await transport.allowUpstream()
    for _ in 0..<200 {
      if await transport.baseBatches > 2 { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await transport.basePaths.dropFirst(2) == [["/repos/repo-3"]])
    await monitor.stop()
  }
  @Test func testLongUpstreamCheckDoesNotMakeNextSweepImmediatelyOverdue() async throws {
    let root = try CoreTests().temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let transport = ProgressTransport()
    await transport.allowBase()
    var env = Environment(name: "Slow upstream", kind: .ssh, roots: ["/repos"])
    env.watchMode = .poll; env.capabilities = Capabilities(); env.pollInterval = 1.5
    var config = Configuration(); config.environments = [env]; config.batteryAware = false
    let store = StateStore(configuration: config, persistence: Persistence(directory: root))
    let monitor = EnvironmentMonitor(environment: env, configuration: config, store: store, transport: transport)
    await monitor.start()
    for _ in 0..<200 {
      if await transport.upstreamStarted { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await transport.upstreamStarted)
    try await Task.sleep(for: .milliseconds(2200))
    await transport.allowUpstream()
    for _ in 0..<200 {
      if await store.cacheWriteCount > 0 { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    try await Task.sleep(for: .milliseconds(1200))
    #expect(await transport.baseBatches == 2)
    await monitor.stop()
  }
}

extension MonitorProgressTests {
  @Test(arguments: [Environment.Kind.local, .ssh])
  func testNetworkRecoveryCoalescesAndDoesNotRediscoverOrCheckLocal(kind: Environment.Kind) async throws {
    let root = try CoreTests().temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let transport = ProgressTransport()
    await transport.allowBase()
    var env = Environment(name: "Network test", kind: kind, roots: ["/repos"])
    env.watchMode = .poll; env.capabilities = Capabilities()
    var config = Configuration(); config.environments = [env]
    let store = StateStore(configuration: config, persistence: Persistence(directory: root))
    let monitor = EnvironmentMonitor(environment: env, configuration: config, store: store, transport: transport)
    await monitor.start()
    for _ in 0..<200 {
      if await transport.upstreamStarted { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    await monitor.networkChanged()
    await monitor.networkChanged()
    await monitor.watcherFailed("Failure while upstream was checking")
    await transport.allowUpstream()
    let expected = kind == .ssh ? 4 : 2
    for _ in 0..<200 {
      if await transport.baseBatches == expected, await store.cacheWriteCount >= (kind == .ssh ? 2 : 1) { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await transport.discoveryCalls == 1)
    #expect(await transport.baseBatches == expected)
    let world = await store.world()
    #expect(world.environments[0].lastCheckReason == (kind == .ssh ? "Network recovery or route change" : "Startup check"))
    #expect(world.environments[0].watcherFailure?.message == "Failure while upstream was checking")
    await monitor.stop()
  }
}
