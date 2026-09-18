import Darwin
import Foundation
import Testing

@testable import RepobotCore

struct CoreTests {
  func temporary() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "repobot-tests-\(UUID())")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    let resolved = realpath(url.path, nil)!
    defer { free(resolved) }
    return URL(fileURLWithPath: String(cString: resolved))
  }
  @discardableResult func git(_ path: URL, _ arguments: [String]) async throws -> String {
    let r = try await ProcessRunner.run("/usr/bin/git", ["-C", path.path] + arguments)
    guard r.status == 0 else { throw RepobotError.message(r.errorText) }
    return r.text.trimmingCharacters(in: .whitespacesAndNewlines)
  }
  func repo(_ url: URL) async throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try await git(url, ["init", "-b", "main"])
    try await git(url, ["config", "user.name", "Fixture"])
    try await git(url, ["config", "user.email", "fixture@example.invalid"])
    try Data("initial\n".utf8).write(to: url.appendingPathComponent("tracked"))
    try await git(url, ["add", "tracked"])
    try await git(url, ["commit", "-m", "Initial commit"])
  }
  @Test func testProbeReadOnlyAndHostilePaths() async throws {
    let root = try temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("repo ' with\ttab\nand newline $(false)")
    try await repo(path)
    try Data("modified\n".utf8).write(to: path.appendingPathComponent("tracked"))
    try Data("new".utf8).write(to: path.appendingPathComponent("untracked\nname"))
    let index = path.appendingPathComponent(".git/index")
    let before = try Data(contentsOf: index)
    let values = try await Probe.repos([path.path], using: LocalTransport())
    expectEqual(values.count, 1)
    expectEqual(values[0].path, path.path)
    expectEqual(values[0].modified, 1)
    expectEqual(values[0].untracked, 1)
    expectEqual(values[0].branch, "main")
    #expect(values[0].changedPaths.contains("tracked"))
    expectEqual(try Data(contentsOf: index), before)
    let found = try await Probe.discover(roots: [root.path], using: LocalTransport())
    expectEqual(found, [path.path])
  }
  @Test func testDiscoveryPruningDepthAndWorktrees() async throws {
    let root = try temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let first = root.appendingPathComponent("one")
    let nested = root.appendingPathComponent("nested/deeper/two")
    let ignored = root.appendingPathComponent("node_modules/hidden")
    try await repo(first)
    try await repo(nested)
    try await repo(ignored)
    let linked = root.appendingPathComponent("linked")
    try await git(first, ["worktree", "add", "-b", "linked", linked.path])
    let found = try await Probe.discover(roots: [root.path], using: LocalTransport())
    expectEqual(Set(found), Set([first.path, nested.path, linked.path]))
    let values = try await Probe.repos([linked.path], using: LocalTransport())
    expectEqual(values[0].branch, "linked")
  }
  @Test func testStagedRenameAndConflictOperation() async throws {
    let root = try temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    try await repo(root)
    try await git(root, ["mv", "tracked", "renamed file"])
    var value = try await Probe.repos([root.path], using: LocalTransport())[0]
    expectEqual(value.staged, 1)
    expectEqual(value.modified, 0)
    try await git(root, ["commit", "-m", "Rename"])
    try await git(root, ["checkout", "-b", "other"])
    try Data("other\n".utf8).write(to: root.appendingPathComponent("renamed file"))
    try await git(root, ["commit", "-am", "Other"])
    try await git(root, ["checkout", "main"])
    try Data("main\n".utf8).write(to: root.appendingPathComponent("renamed file"))
    try await git(root, ["commit", "-am", "Main"])
    _ = try await ProcessRunner.run("/usr/bin/git", ["-C", root.path, "merge", "other"])
    value = try await Probe.repos([root.path], using: LocalTransport())[0]
    expectEqual(value.conflicted, 1)
    expectEqual(value.operation, .merge)
    expectEqual(
      Analyzer.perClone(value, environment: "test", configuration: Configuration(), now: Date())
        .map(\.severity).max(), .problem)
  }
  @Test func testUnbornDetachedAndStaleLock() async throws {
    let root = try temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    try await git(root, ["init", "-b", "main"])
    var r = try await Probe.repos([root.path], using: LocalTransport())[0]
    expectEqual(r.headSHA, "")
    expectEqual(r.branch, "main")
    try await repo(root)
    try await git(root, ["checkout", "--detach"])
    try Data("detached\n".utf8).write(to: root.appendingPathComponent("tracked"))
    try await git(root, ["commit", "-am", "Detached"])
    let lock = root.appendingPathComponent(".git/index.lock")
    try Data().write(to: lock)
    try FileManager.default.setAttributes(
      [.modificationDate: Date().addingTimeInterval(-700)], ofItemAtPath: lock.path)
    r = try await Probe.repos([root.path], using: LocalTransport())[0]
    expectTrue(r.detached)
    expectEqual(r.detachedCommits, 1)
    expectTrue(r.staleLock)
  }
  @Test func testUpstreamFreshnessWithoutFetchAndDeletedBranch() async throws {
    let root = try temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let server = root.appendingPathComponent("server")
    let clone = root.appendingPathComponent("clone")
    try await repo(server)
    try await git(root, ["clone", server.path, clone.path])
    let cached = try await git(clone, ["rev-parse", "origin/main"])
    try Data("new\n".utf8).write(to: server.appendingPathComponent("tracked"))
    try await git(server, ["commit", "-am", "New upstream"])
    let r = try await Probe.repos([clone.path], upstream: .lsRemote, using: LocalTransport())[0]
    expectEqual(r.upstreamSHA, cached)
    expectNotEqual(r.upstreamRemoteTip, cached)
    let after = try await git(clone, ["rev-parse", "origin/main"])
    expectEqual(after, cached)
    try await git(server, ["checkout", "-b", "replacement"])
    try await git(server, ["branch", "-D", "main"])
    let deleted = try await Probe.repos([clone.path], upstream: .lsRemote, using: LocalTransport())[
      0]
    expectTrue(deleted.upstreamGone)
  }
  @Test func testPeerAncestryAndUnknownNotDivergence() async throws {
    let root = try temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    try await repo(root)
    let old = try await git(root, ["rev-parse", "HEAD"])
    try Data("new\n".utf8).write(to: root.appendingPathComponent("tracked"))
    try await git(root, ["commit", "-am", "New"])
    let missing = String(repeating: "a", count: 40)
    var r = try await Probe.repos([root.path], peers: [old, missing], using: LocalTransport())[0]
    expectEqual(r.ancestry[old]?.relation, "ahead")
    expectEqual(r.ancestry[old]?.ahead, 1)
    expectEqual(r.ancestry[missing]?.relation, "unknown")
    r.originURL = "git@GitHub.com:org/repo.git"
    var other = r
    other.path = "/other"
    other.headSHA = missing
    let env = Environment(name: "Here", kind: .local)
    var s = EnvironmentSnapshot(environment: env)
    s.repos = [r, other]
    let world = Analyzer.analyze([s], configuration: Configuration())
    expectFalse(world.clones.contains { $0.status.findings.contains { $0.id == "peer-diverged" } })
    expectEqual(Analyzer.identity(r), "github.com/org/repo")
    other.originURL = "https://someone@github.com/org/repo.git"
    expectEqual(Analyzer.identity(r), Analyzer.identity(other))
  }
  @Test func testConfirmedPeerDivergenceAndExplicitFetch() async throws {
    let root = try temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let server = root.appendingPathComponent("server")
    let clone = root.appendingPathComponent("clone")
    try await repo(server)
    let common = try await git(server, ["rev-parse", "HEAD"])
    try await git(root, ["clone", server.path, clone.path])
    try await git(server, ["commit", "--allow-empty", "-m", "main-only"])
    try await git(server, ["checkout", "-b", "side", common])
    try await git(server, ["commit", "--allow-empty", "-m", "side-only"])
    let side = try await git(server, ["rev-parse", "HEAD"])
    try await git(server, ["checkout", "main"])
    let divergent = try await Probe.repos([server.path], peers: [side], using: LocalTransport())[0]
    #expect(divergent.ancestry[side]?.relation == "diverged")
    #expect(divergent.ancestry[side]?.ahead == 1)
    #expect(divergent.ancestry[side]?.behind == 1)
    let fetched = try await Probe.repos([clone.path], upstream: .fetch, using: LocalTransport())[0]
    #expect(fetched.behind == 1)
    #expect(fetched.upstreamCheckedAt != nil)
  }
  @Test func testStateAgesSuppressionAndPersistence() async throws {
    let root = try temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    var c = Configuration()
    let env = Environment.local
    c.environments = [env]
    let persistence = Persistence(directory: root)
    let store = StateStore(configuration: c, persistence: persistence)
    var snapshot = EnvironmentSnapshot(environment: env)
    var repo = RepoSnapshot(path: "/repo")
    repo.modified = 1
    repo.probedAt = Date().addingTimeInterval(-18000)
    snapshot.repos = [repo]
    await store.merge(snapshot)
    snapshot.repos[0].probedAt = Date()
    await store.merge(snapshot)
    var world = await store.world()
    expectEqual(world.clones[0].repo.dirtySince, repo.probedAt)
    expectEqual(world.clones[0].status.severity, .attention)
    c.snoozed[world.clones[0].id] = Date().addingTimeInterval(3600)
    await store.updateConfiguration(c)
    world = await store.world()
    expectEqual(world.clones[0].status.severity, .ok)
    let cached = try persistence.loadWorld(configuration: Configuration())
    expectEqual(cached?.clones.count, 1)
    snapshot.repos[0].modified = 0
    await store.merge(snapshot)
    world = await store.world()
    expectNil(world.clones[0].repo.dirtySince)
  }
  @Test func testFailedProbePreservesAgesAndFreshnessDoesNotLeakBranches() async throws {
    let root = try temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    var config = Configuration()
    let env = Environment.local
    config.environments = [env]
    let store = StateStore(configuration: config, persistence: Persistence(directory: root))
    var r = RepoSnapshot(path: "/repo")
    r.branch = "main"
    r.modified = 1
    r.ahead = 2
    r.upstream = "origin/main"
    r.upstreamCheckedAt = Date()
    r.upstreamGone = true
    r.upstreamRemoteDeleted = true
    r.probedAt = Date().addingTimeInterval(-18000)
    var s = EnvironmentSnapshot(environment: env)
    s.repos = [r]
    await store.merge(s)
    var failure = RepoSnapshot(path: r.path)
    failure.error = "Timed out"
    failure.slow = true
    s.repos = [failure]
    await store.merge(s)
    var world = await store.world()
    #expect(world.clones[0].repo.dirtySince == r.probedAt)
    #expect(world.clones[0].repo.modified == 1)
    r.upstreamCheckedAt = nil
    r.upstreamGone = false
    r.upstreamRemoteDeleted = false
    s.repos = [r]
    await store.merge(s)
    world = await store.world()
    #expect(world.clones[0].repo.upstreamGone)
    r.branch = "feature"
    r.upstream = "origin/feature"
    r.probedAt = Date()
    s.repos = [r]
    await store.merge(s)
    world = await store.world()
    #expect(!world.clones[0].repo.upstreamGone)
    #expect(world.clones[0].repo.upstreamCheckedAt == nil)
    #expect(world.clones[0].repo.unpushedSince == r.probedAt)
  }
  @Test func testOptionalPowerAndStaleBranchPolicies() {
    #expect(PowerPolicy.multiplier(enabled: true, onBattery: true, idleSeconds: 301) == 2)
    #expect(PowerPolicy.multiplier(enabled: true, onBattery: false, idleSeconds: 301) == 1)
    #expect(PowerPolicy.multiplier(enabled: true, onBattery: true, idleSeconds: 299) == 1)
    var c = Configuration()
    var r = RepoSnapshot(path: "/repo")
    r.branch = "main"
    r.branchCommitDates = ["main": .distantPast, "old-feature": .distantPast]
    #expect(
      !Analyzer.perClone(r, environment: "test", configuration: c, now: Date()).contains {
        $0.id == "stale-branches"
      })
    c.reportStaleBranches = true
    let finding = Analyzer.perClone(r, environment: "test", configuration: c, now: Date()).first {
      $0.id == "stale-branches"
    }
    #expect(finding?.text.contains("1 inactive branch") == true)
  }
  @Test func testShallowCloneIdentityDoesNotRequireVisibleRootsToMatch() async throws {
    let root = try temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let server = root.appendingPathComponent("server")
    let shallow = root.appendingPathComponent("shallow")
    let full = root.appendingPathComponent("full")
    try await repo(server)
    try await git(server, ["commit", "--allow-empty", "-m", "Second"])
    let remote = server.absoluteString
    try await git(root, ["clone", "--depth", "1", remote, shallow.path])
    try await git(root, ["clone", remote, full.path])
    let repos = try await Probe.repos([shallow.path, full.path], using: LocalTransport())
    #expect(repos[0].shallow == true)
    #expect(repos[0].rootCommit != repos[1].rootCommit)
    var snapshot = EnvironmentSnapshot(environment: .local)
    snapshot.repos = SnapshotList(repos)
    let world = Analyzer.analyze([snapshot], configuration: Configuration())
    #expect(world.clones[0].status.peers.count == 1)
    #expect(world.clones[0].status.peers[0].text == "In sync")
  }
  @Test func testNotificationTransitions() {
    var c = Configuration()
    c.notifications = true
    c.quietHours = false
    let env = Environment.local
    var snapshot = EnvironmentSnapshot(environment: env)
    var r = RepoSnapshot(path: "/r")
    r.behind = 2
    snapshot.repos = [r]
    let world = Analyzer.analyze([snapshot], configuration: c)
    expectEqual(
      NotificationTransitions.changed(from: WorldSnapshot(), to: world, configuration: c)[env.id]?
        .count, 1)
    expectTrue(NotificationTransitions.changed(from: world, to: world, configuration: c).isEmpty)
  }
  @Test func testMalformedProtocolAndManualHosts() throws {
    expectThrows(try Probe.parse(Data("REPO\0/r\0HEAD\0".utf8)))
    expectThrows(try Probe.parse(Data("REPO\0/r\0END\0/other\0".utf8)))
    expectEqual(try HostDiscovery.parseManual("ken@server:2222").port, 2222)
    expectEqual(try HostDiscovery.parseManual("ken@[::1]:22").user, "ken")
    expectThrows(try HostDiscovery.parseManual("-oProxyCommand=bad"))
    expectEqual(shellQuote("a'b"), "'a'\\''b'")
  }
  @Test func testTimeoutKillsDescendants() async throws {
    let started = Date()
    do {
      _ = try await LocalTransport().run(script: "sleep 30 & wait", timeout: 0.2)
      Issue.record("Expected command timeout")
    } catch {}
    #expect(Date().timeIntervalSince(started) < 3)
  }
  @Test func testCancelledCommandAndEarlyStdinExit() async throws {
    let task = Task { try await LocalTransport().run(script: "sleep 30", timeout: 40) }
    try await Task.sleep(for: .milliseconds(100))
    task.cancel()
    let started = Date()
    do {
      _ = try await task.value
      Issue.record("Expected cancellation")
    } catch {}
    #expect(Date().timeIntervalSince(started) < 3)
    let result = try await ProcessRunner.run(
      "/usr/bin/true", [], input: Data(repeating: 65, count: 1_000_000))
    #expect(result.status == 0)
  }
  @Test func testTailscaleListingIncludesOfflinePeersWithoutSSH() async throws {
    let root = try temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let cli = root.appendingPathComponent("Tailscale CLI")
    // Documentation-only addresses cannot pass an SSH probe. Both must remain visible.
    let json = #"{"BackendState":"Running","Self":{"HostName":"this-mac"},"Peer":{"a":{"ID":"stable-a","HostName":"Online server","DNSName":"server.tail.example.","TailscaleIPs":["192.0.2.1"],"OS":"linux","Online":true},"b":{"ID":"stable-b","HostName":"Offline mac","TailscaleIPs":["2001:db8::2"],"OS":"macOS","Online":false},"c":{"HostName":"No address"}}}"#
    let script = """
      #!/bin/sh
      [ "$TAILSCALE_BE_CLI" = 1 ] || exit 2
      [ "$#" = 2 ] && [ "$1" = status ] && [ "$2" = --json ] || exit 3
      printf '%s' \(shellQuote(json))
      """
    try script.write(to: cli, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
    let hosts = try await HostDiscovery.loadTailscale(executable: cli.path)
    #expect(hosts.count == 2)
    #expect(hosts[0].nodeID == "stable-a")
    #expect(hosts[0].host == "server.tail.example")
    #expect(hosts[0].online == true)
    #expect(hosts[1].online == false)
    #expect(hosts[1].host == "2001:db8::2")
    #expect(hosts.allSatisfy { $0.banner.isEmpty })
    #expect(throws: (any Error).self) {
      try HostDiscovery.parseTailscale(Data(#"{"BackendState":"NeedsLogin"}"#.utf8))
    }
    #expect(throws: (any Error).self) {
      try HostDiscovery.parseTailscale(Data("invalid JSON".utf8))
    }
    let empty = try HostDiscovery.parseTailscale(Data(#"{"BackendState":"Running","Peer":{}}"#.utf8))
    #expect(empty.isEmpty)
  }
  @Test func testSSHOptionsAcceptSpaces() async throws {
    var env = Environment(name: "fixture", kind: .ssh)
    env.host = "example.invalid"
    let ssh = SSHTransport(
      environment: env, controlDirectory: URL(fileURLWithPath: "/tmp/repobot test"))
    let result = try await ProcessRunner.run(
      "/usr/bin/ssh", ["-G"] + ssh.baseArguments + ["--", ssh.destination])
    #expect(result.status == 0)
    #expect(result.text.contains("/tmp/repobot test/cm-"))
  }
  @Test func testSSHSocketPathBudget() async throws {
    var env = Environment(name: "fixture", kind: .ssh)
    env.host = "example.invalid"
    let normal = SSHTransport(environment: env)
    #expect(normal.controlDirectory.lastPathComponent == ".repobot")
    // Reproduce the reported user's home directory, including SSH's temporary suffix.
    let reported = SSHTransport(
      environment: env, controlDirectory: URL(fileURLWithPath: "/Users/ksimpson/.repobot"))
    #expect(reported.canMultiplex)
    #expect(reported.controlDirectory.path.utf8.count + 62 <= 104)
    for path in [
      "/Users/ksimpson/Library/Application Support/Repobot",
      "/Users/" + String(repeating: "é", count: 25) + "/.repobot",
    ] {
      let long = SSHTransport(environment: env, controlDirectory: URL(fileURLWithPath: path))
      #expect(!long.canMultiplex)
      let result = try await ProcessRunner.run(
        "/usr/bin/ssh", ["-G"] + long.baseArguments + ["--", long.destination])
      #expect(result.status == 0)
      #expect(result.text.contains("controlmaster false"))
      #expect(!result.text.contains("controlpath /"))
    }
  }
  @Test func testNativeMonitorDetectsEditsAndNewClones() async throws {
    let root = try temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let first = root.appendingPathComponent("first")
    try await repo(first)
    var env = Environment.local
    env.roots = [root.path]
    var c = Configuration()
    c.environments = [env]
    c.upstreamCheck = .off
    let store = StateStore(
      configuration: c, persistence: Persistence(directory: root.appendingPathComponent("cache")))
    let monitor = EnvironmentMonitor(environment: env, configuration: c, store: store)
    await monitor.start()
    var world = await store.world()
    for _ in 0..<100 where world.clones.isEmpty || world.clones.contains(where: { world.isUnverified($0) }) {
      try await Task.sleep(for: .milliseconds(100))
      world = await store.world()
    }
    #expect(world.clones.count == 1)
    try Data("edit\n".utf8).write(to: first.appendingPathComponent("tracked"))
    for _ in 0..<100 where !(world.clones.first?.repo.dirty ?? false) {
      try await Task.sleep(for: .milliseconds(100))
      world = await store.world()
    }
    #expect(world.clones.first?.repo.dirty == true)
    let second = root.appendingPathComponent("second")
    try await repo(second)
    for _ in 0..<100 where world.clones.count < 2 {
      try await Task.sleep(for: .milliseconds(100))
      world = await store.world()
    }
    #expect(world.clones.count == 2)
    #expect(world.environments.first?.mode.contains("FSEvents") == true)
    await monitor.stop()
  }
  @Test func testIdleRepositoriesAreHiddenUnlessTheyNeedAttention() throws {
    let now = Date(), day: TimeInterval = 86400
    func clone(commit: Double, file: Double? = nil, branch: Double? = nil, severity: Severity = .ok) -> Clone {
      var repo = RepoSnapshot(path: "/repo")
      repo.lastCommitDate = now.addingTimeInterval(-commit * day); repo.probedAt = now
      repo.age = RepositoryAge(measuredAt: now, newestFileDate: file.map { now.addingTimeInterval(-$0 * day) })
      if let branch { repo.branchCommitDates["feature"] = now.addingTimeInterval(-branch * day) }
      return Clone(environmentID: UUID(), repo: repo, status: RepoStatus(identity: "r", severity: severity, findings: [], peers: []))
    }
    var configuration = Configuration()
    #expect(configuration.hidesFromMenu(clone(commit: 40)))
    #expect(!configuration.hidesFromMenu(clone(commit: 10)))
    #expect(!configuration.hidesFromMenu(clone(commit: 40, file: 2)))       // edited recently
    #expect(!configuration.hidesFromMenu(clone(commit: 40, branch: 3)))     // another branch is active
    #expect(!configuration.hidesFromMenu(clone(commit: 400, severity: .attention)))
    #expect(configuration.hidesFromMenu(clone(commit: 400, severity: .info)))
    #expect(!configuration.hidesFromMenu(Clone(environmentID: UUID(), repo: RepoSnapshot(path: "/unprobed"),
      status: RepoStatus(identity: "u", severity: .ok, findings: [], peers: []))))
    configuration.watchActiveDays = 7
    #expect(configuration.hidesFromMenu(clone(commit: 10)))
    configuration.watchActiveDays = 0
    #expect(!configuration.hidesFromMenu(clone(commit: 400)))
    configuration.watchActiveDays = 30; configuration.hideIdleRepositories = false
    #expect(!configuration.hidesFromMenu(clone(commit: 400)) && configuration.isIdle(clone(commit: 400).repo))
  }
  @Test func testUpstreamBatchesRunConcurrently() async throws {
    #expect(Probe.upstreamConcurrency(cpus: 12, remote: false) == 8)
    #expect(Probe.upstreamConcurrency(cpus: 4, remote: false) == 4)
    #expect(Probe.upstreamConcurrency(cpus: 32, remote: true) == 6)
    #expect(Probe.upstreamConcurrency(cpus: nil, remote: true) == 4)
    let root = try temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    for index in 0..<12 {
      let bare = root.appendingPathComponent("upstream-\(index).git"), clone = root.appendingPathComponent("repos/clone-\(index)")
      try await repo(clone)
      try await git(root, ["init", "-q", "--bare", bare.path])
      try await git(clone, ["remote", "add", "origin", bare.path])
      try await git(clone, ["push", "-q", "-u", "origin", "HEAD"])
    }
    var env = Environment.local
    env.roots = [root.appendingPathComponent("repos").path]
    env.watchMode = .poll
    var c = Configuration()
    c.environments = [env]
    c.upstreamCheck = .lsRemote
    let store = StateStore(configuration: c, persistence: Persistence(directory: root.appendingPathComponent("cache")))
    let transport = CountingTransport()
    let monitor = EnvironmentMonitor(environment: env, configuration: c, store: store, transport: transport)
    await monitor.start()
    var world = await store.world()
    for _ in 0..<200 where world.clones.count < 12 || world.clones.contains(where: { $0.repo.upstreamCheckedAt == nil }) {
      try await Task.sleep(for: .milliseconds(100))
      world = await store.world()
    }
    await monitor.stop()
    #expect(world.clones.count == 12 && world.clones.allSatisfy { $0.repo.upstreamRemoteTip == $0.repo.headSHA && $0.repo.upstreamError == nil })
    // Twelve independent upstreams form three batches of four, all in flight together.
    #expect(transport.counter.peak == min(3, Probe.upstreamConcurrency(cpus: ProcessInfo.processInfo.activeProcessorCount, remote: false)))
  }
  @Test func testWatchEconomySettingsAndGitignoreFixPrompt() throws {
    // Configurations saved before these settings existed must still load.
    var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(Configuration())) as? [String: Any])
    legacy.removeValue(forKey: "watchActiveDays"); legacy.removeValue(forKey: "watchSkipNames")
    var configuration = try JSONDecoder().decode(Configuration.self, from: JSONSerialization.data(withJSONObject: legacy))
    #expect(configuration.effectiveWatchActiveDays == 30)
    #expect(configuration.effectiveWatchSkipNames.contains("__pycache__") && configuration.effectiveWatchSkipNames.contains(".gradle"))
    configuration.watchActiveDays = 0
    #expect(configuration.effectiveWatchActiveDays == 0)
    #expect(Configuration.normalizedSkipNames(" venv \n\nvenv, a/b\n..\n.cache") == ["venv", ".cache"])
    let usage = try JSONDecoder().decode(WatchUsage.self, from: Data(#"""
      {"total":9300,"limit":524288,"dormant":120,"repos":[
        {"path":"/home/k/git/mc-policy-v2","watches":2000,"wanted":7230,"untracked":[{"path":".gradle-docker","directories":4646}]},
        {"path":"/home/k/git/n8n","watches":2000,"wanted":2891,"untracked":[]},
        {"path":"/home/k/git/small","watches":40,"wanted":40,"untracked":[{"path":"tmp","directories":30}]}]}
      """#.utf8))
    #expect(usage.fixable.map(\.path) == ["/home/k/git/mc-policy-v2"])
    var remote = Environment(name: "devbox", kind: .ssh); remote.host = "devbox"; remote.user = "ken"; remote.port = 2222
    let prompt = WatchHygiene.prompt(environment: remote, repository: usage.repos[0], configuration: configuration)
    #expect(prompt.contains("- .gradle-docker/ — 4646 directories"))
    #expect(prompt.contains("'-p' '2222' '--' 'ken@devbox'") && prompt.contains("/home/k/git/mc-policy-v2"))
    #expect(prompt.contains("wait for my approval"))
    let local = WatchHygiene.prompt(environment: .local, repository: usage.repos[0], configuration: configuration)
    #expect(local.contains("current directory") && !local.contains("ssh"))
  }
  @Test func testGitignoreFixScriptStartsAgentInRepositoryWithPrompt() async throws {
    let root = try temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    var profile = AgentProfile(name: "Echo", harness: .claude); profile.executable = "/bin/echo"
    let repository = WatchUsage.Repository(path: root.path, watches: 500, wanted: 500,
      untracked: [WatchUsage.Tree(path: "job'lib", directories: 480)])
    let script = try WatchHygiene.script(profile: profile, environment: .local, repository: repository,
      configuration: Configuration(), directory: root.appendingPathComponent("fix"))
    let result = try await ProcessRunner.run("/bin/sh", [script.path], timeout: 10)
    #expect(result.status == 0 && result.text.contains("- job'lib/ — 480 directories"))
  }
  @Test func testWatcherCostFormattingAndParsing() throws {
    #expect(WatcherCost.count(842) == "842")
    #expect(WatcherCost.count(1_400) == "1.4K")
    #expect(WatcherCost.count(14_000) == "14K")
    #expect(WatcherCost.count(524_288) == "524K")
    #expect(WatcherCost.count(999_999) == "1M")
    #expect(WatcherCost.count(1_048_576) == "1M")
    #expect(WatcherCost.memory(64 * 1024 * 1024) == "64MB")
    #expect(WatcherCost.memory(1_288_490_189) == "1.2GB")
    #expect(WatcherCost.memory(300_000) == "293KB")
    let first = try #require(WatcherCostSampler.parse(
      "processes=1\nticks=100\nhz=100\nrss=67108864\nuptime=50.00\nhandles=14000\nlimit=524288\n", previous: nil))
    #expect(first.0.cpuText == "—" && first.0.memoryText == "64MB")
    #expect(first.0.handlesText == "14K of 524K inotify watches")
    let second = try #require(WatcherCostSampler.parse(
      "processes=1\nticks=106\nhz=100\nrss=67108864\nuptime=52.00\nhandles=14000\nlimit=524288\n", previous: first.1))
    #expect(second.0.cpuText == "3%")
    #expect(WatcherCost(handles: 1, handleLimit: 10, cpuPercent: 0.2, memoryBytes: 1, processes: 1).cpuText == "<1%")
    // A Mac prints nothing (FSEvents is not measured); a vanished watcher has no processes.
    #expect(WatcherCostSampler.parse("", previous: nil) == nil)
    #expect(WatcherCostSampler.parse("processes=0\n", previous: nil) == nil)
  }
  @Test func testPythonMacWatcherOverStdin() async throws {
    let root = try temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    try await repo(root)
    let events = EventRecorder()
    var capabilities = Capabilities()
    capabilities.python = true
    capabilities.os = "Darwin"
    let watcher = try RemoteWatcher(
      transport: LocalTransport(), roots: [root.path], repos: [root.path],
      capabilities: capabilities
    ) { event in Task { await events.add(event) } }
    defer { watcher.stop() }
    for _ in 0..<100 {
      if await events.ready { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    #expect(await events.ready)
    try Data("event\n".utf8).write(to: root.appendingPathComponent("tracked"))
    for _ in 0..<100 {
      if await events.changed { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    #expect(await events.changed)
  }
  @Test func testSubmodulesSkippedAndCredentialsRedacted() async throws {
    let root = try temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let parent = root.appendingPathComponent("parent")
    let source = root.appendingPathComponent("source")
    try await repo(parent)
    try await repo(source)
    try await git(
      parent, ["-c", "protocol.file.allow=always", "submodule", "add", source.path, "module"])
    let found = try await Probe.discover(roots: [root.path], using: LocalTransport())
    #expect(!found.contains(parent.appendingPathComponent("module").path))
    try await git(
      parent, ["remote", "add", "origin", "https://user:secret@example.invalid/org/repo.git"])
    let r = try await Probe.repos([parent.path], using: LocalTransport())[0]
    #expect(r.originURL == "https://example.invalid/org/repo.git")
  }
  @Test(.enabled(if: ProcessInfo.processInfo.environment["REPOBOT_TEST_SSH_PORT"] != nil))
  func testRealSSHProbeAndWatcher() async throws {
    let variables = ProcessInfo.processInfo.environment
    let root = URL(fileURLWithPath: variables["REPOBOT_TEST_SSH_DIRECTORY"]!)
    var env = Environment(name: "SSH fixture", kind: .ssh, roots: ["/repos"])
    env.host = "127.0.0.1"
    env.port = Int(variables["REPOBOT_TEST_SSH_PORT"]!)!
    env.user = "root"
    env.identityFile = root.appendingPathComponent("key").path
    var config = Configuration()
    config.extraSSHOptions = ["UserKnownHostsFile=\(root.path)/known_hosts"]
    let transport = SSHTransport(
      environment: env, configuration: config)
    let hosts = await HostDiscovery.scan([
      DiscoveredHost(
        name: "Fixture", host: "127.0.0.1", address: "127.0.0.1", source: "Manual", os: "Linux",
        port: env.port!)
    ])
    #expect(hosts.count == 1)
    #expect(hosts.first?.banner.hasPrefix("SSH-2.0-") == true)
    let capabilities = try await Probe.capabilities(using: transport)
    let master = try await ProcessRunner.run(
      config.sshPath, transport.baseArguments + ["-O", "check", "--", transport.destination])
    #expect(master.status == 0)
    #expect(master.errorText.contains("Master running"))
    let permissions = try FileManager.default.attributesOfItem(atPath: transport.controlDirectory.path)
    #expect((permissions[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    #expect(capabilities.os == "Linux")
    #expect(capabilities.python)
    let paths = try await Probe.discover(roots: env.roots, using: transport)
    #expect(paths == ["/repos/demo"])
    let before = try await Probe.repos(paths, using: transport)
    #expect(before.count == 1)
    #expect(!before[0].dirty)
    var agentSnapshot = EnvironmentSnapshot(environment: env)
    agentSnapshot.repos = SnapshotList(before)
    let agentWorld = Analyzer.analyze([agentSnapshot], configuration: config)
    let agentContext = await AgentInspection.refresh(AgentWorkflow.context(
      for: agentWorld.repositories[0], world: agentWorld, configuration: config))
    #expect(agentContext.targets[0].inspectionError == nil)
    #expect(try await AgentInspection.inspect(agentContext.targets[0], context: agentContext,
      operation: "read", path: "tracked").contains("initial"))
    try await AgentInspection.ensureUnchanged(agentContext)
    let events = EventRecorder()
    let watcher = try RemoteWatcher(
      transport: transport, roots: env.roots, repos: paths, capabilities: capabilities
    ) { event in Task { await events.add(event) } }
    for _ in 0..<100 {
      if await events.ready { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    #expect(await events.ready)
    let group = try #require(await events.group)
    for _ in 0..<50 where await events.usage == nil { try await Task.sleep(for: .milliseconds(100)) }
    let usage = try #require(await events.usage)
    #expect(usage.total > 0 && usage.limit > usage.total && usage.repos.first?.path == paths[0])
    let (cost, reading) = try #require(try await WatcherCostSampler.remote(group: group, transport: transport, previous: nil))
    #expect(cost.processes == 1)
    #expect((cost.handles ?? 0) > 0 && (cost.handleLimit ?? 0) > (cost.handles ?? 0))
    #expect((cost.memoryBytes ?? 0) > 1_000_000 && cost.cpuPercent == nil && reading != nil)
    let edit = try await transport.run(
      script: "printf 'changed\\n' > /repos/demo/tracked", arguments: [], timeout: 10)
    #expect(edit.status == 0)
    for _ in 0..<100 {
      if await events.changed { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    #expect(await events.changed)
    let after = try await Probe.repos(paths, using: transport)
    #expect(after[0].modified == 1)
    await #expect(throws: (any Error).self) { try await AgentInspection.ensureUnchanged(agentContext) }
    watcher.stop()
    // Killing the local ssh must not strand the remote watcher and its inotify watches.
    var orphans = "unknown"
    for _ in 0..<50 {
      orphans = try await transport.run(
        script: "for p in /proc/[0-9]*; do tr '\\0' ' ' < $p/cmdline 2>/dev/null | grep -q '^python3 - ' && echo $p; done; true",
        arguments: [], timeout: 10).text
      if orphans.isEmpty { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    #expect(orphans.isEmpty)
    await transport.close()
    let trusted = try Data(contentsOf: root.appendingPathComponent("known_hosts"))
    _ = try await ProcessRunner.run(
      "/usr/bin/ssh-keygen",
      ["-q", "-t", "ed25519", "-N", "", "-f", root.appendingPathComponent("wrong-key").path])
    let wrongPublic = try String(
      contentsOf: root.appendingPathComponent("wrong-key.pub"), encoding: .utf8)
    try Data("[127.0.0.1]:\(env.port!) \(wrongPublic)".utf8).write(
      to: root.appendingPathComponent("known_hosts"))
    do {
      _ = try await Probe.capabilities(using: transport)
      Issue.record("Changed host key was accepted")
    } catch {
      #expect(error.localizedDescription.contains("REMOTE HOST IDENTIFICATION HAS CHANGED"))
    }
    try trusted.write(to: root.appendingPathComponent("known_hosts"))
    env.identityFile = root.appendingPathComponent("wrong-key").path
    config.extraSSHOptions.append("IdentitiesOnly=yes")
    let rejected = SSHTransport(
      environment: env, configuration: config)
    let started = Date()
    do {
      _ = try await Probe.capabilities(using: rejected)
      Issue.record("Unauthorized key was accepted")
    } catch { #expect(error.localizedDescription.contains("Permission denied")) }
    #expect(Date().timeIntervalSince(started) < 10)
  }
  @Test func testTransportDrainsLargePipes() async throws {
    let r = try await LocalTransport().run(
      script:
        "i=0; while [ $i -lt 5000 ]; do printf 'stdout data\\n'; printf 'stderr data\\n' >&2; i=$((i+1)); done",
      timeout: 10)
    expectEqual(r.status, 0)
    expectGreaterThan(r.stdout.count, 50000)
    expectGreaterThan(r.stderr.count, 50000)
  }
}

private func expectEqual<T: Equatable>(
  _ a: T, _ b: T, sourceLocation: SourceLocation = #_sourceLocation
) { #expect(a == b, sourceLocation: sourceLocation) }
private func expectNotEqual<T: Equatable>(
  _ a: T, _ b: T, sourceLocation: SourceLocation = #_sourceLocation
) { #expect(a != b, sourceLocation: sourceLocation) }
private func expectGreaterThan<T: Comparable>(
  _ a: T, _ b: T, sourceLocation: SourceLocation = #_sourceLocation
) { #expect(a > b, sourceLocation: sourceLocation) }
private func expectTrue(_ a: Bool, sourceLocation: SourceLocation = #_sourceLocation) {
  #expect(a, sourceLocation: sourceLocation)
}
private func expectFalse(_ a: Bool, sourceLocation: SourceLocation = #_sourceLocation) {
  #expect(!a, sourceLocation: sourceLocation)
}
private func expectNil<T>(_ a: T?, sourceLocation: SourceLocation = #_sourceLocation) {
  #expect(a == nil, sourceLocation: sourceLocation)
}
private func expectThrows<T>(
  _ value: @autoclosure () throws -> T, sourceLocation: SourceLocation = #_sourceLocation
) { #expect(throws: (any Error).self, sourceLocation: sourceLocation) { _ = try value() } }

private actor EventRecorder {
  var ready = false
  var changed = false
  var group: Int32?
  var usage: WatchUsage?
  func add(_ event: WatchEvent) {
    switch event {
    case .group(let value): group = value
    case .usage(let value): usage = value
    case .ready: ready = true
    case .changed, .changedPaths: changed = true
    default: break
    }
  }
}

/// Records how many upstream checks overlap; each is held open long enough to be observed.
private struct CountingTransport: Transport {
  final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private(set) var peak = 0
    func enter() { lock.withLock { current += 1; peak = max(peak, current) } }
    func leave() { lock.withLock { current -= 1 } }
  }
  let counter = Counter()
  let local = LocalTransport()
  func run(script: String, arguments: [String], timeout: Double) async throws -> CommandResult {
    guard arguments.first == UpstreamCheck.lsRemote.rawValue else {
      return try await local.run(script: script, arguments: arguments, timeout: timeout)
    }
    counter.enter()
    defer { counter.leave() }
    try await Task.sleep(for: .milliseconds(300))
    return try await local.run(script: script, arguments: arguments, timeout: timeout)
  }
  func invocation(program: String, arguments: [String]) -> (String, [String]) { local.invocation(program: program, arguments: arguments) }
  func close() async {}
}
