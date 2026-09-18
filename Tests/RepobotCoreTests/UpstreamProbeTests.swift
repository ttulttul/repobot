import Foundation
import Testing
@testable import RepobotCore

private actor UpstreamTransport: Transport {
  var localProbes = 0
  var upstreamProbes = 0
  func run(script: String, arguments: [String], timeout: Double) async throws -> CommandResult {
    if script.contains("status --porcelain") { localProbes += 1 }
    else {
      upstreamProbes += 1
      #expect(!script.contains("rev-list"))
      #expect(!script.contains("git log"))
      #expect(!script.contains("git stash"))
      #expect(!script.contains("for-each-ref"))
    }
    return try await LocalTransport().run(script: script, arguments: arguments, timeout: timeout)
  }
  nonisolated func invocation(program: String, arguments: [String]) -> (String, [String]) {
    LocalTransport().invocation(program: program, arguments: arguments)
  }
  func close() async {}
}
struct UpstreamProbeTests {
  @Test func testSharedQueriesStayWithinConfigurationAndFetchStillUpdatesEachCopy() async throws {
    let helper = CoreTests(), root = try helper.temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let server = root.appendingPathComponent("server")
    try await helper.repo(server)
    let transport = try CountingGitTransport(root: root)
    var paths: [String] = []
    for index in 0..<6 {
      let clone = root.appendingPathComponent("clone-\(index)")
      try await helper.git(root, ["clone", server.path, clone.path]); paths.append(clone.path)
    }
    var repos = try await Probe.repos(paths, using: transport)
    let before = transport.calls().count
    let fresh = try await Probe.checkUpstreams(repos, method: .lsRemote, using: transport)
    #expect(fresh.allSatisfy { $0.upstreamRemoteTip == repos[0].headSHA && $0.upstreamError == nil })
    #expect(transport.calls().dropFirst(before).filter { $0.contains("ls-remote") }.count == 1)
    #expect(Probe.upstreamBatches(repos, size: 4) == [paths])
    // Different effective configuration gets its own observation, even with the same URL.
    try await helper.git(URL(fileURLWithPath: paths[0]), ["config", "http.extraHeader", "X-Fixture: different-context"])
    let differing = transport.calls().count
    _ = try await Probe.checkUpstreams(repos, method: .lsRemote, using: transport)
    #expect(transport.calls().dropFirst(differing).filter { $0.contains("ls-remote") }.count == 2)
    try await helper.git(server, ["checkout", "-b", "replacement"])
    try await helper.git(server, ["branch", "-D", "main"])
    let deleted = try await Probe.checkUpstreams(repos, method: .lsRemote, using: transport)
    #expect(deleted.allSatisfy { $0.upstreamRemoteDeleted })
    try await helper.git(server, ["branch", "main"])
    try await helper.git(server, ["checkout", "main"])
    try Data("changed".utf8).write(to: server.appendingPathComponent("tracked"))
    try await helper.git(server, ["commit", "-am", "Advance"])
    repos = try await Probe.checkUpstreams(repos, method: .fetch, using: transport)
    #expect(repos.allSatisfy { $0.behind == 1 && $0.upstreamError == nil })
  }

  @Test func testNarrowCheckPreservesLocalFactsAndRecoversDeletedRemote() async throws {
    let helper = CoreTests(), transport = UpstreamTransport()
    let root = try helper.temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let server = root.appendingPathComponent("server"), clone = root.appendingPathComponent("clone ' tab\tline\n")
    try await helper.repo(server)
    try await helper.git(root, ["clone", server.path, clone.path])
    try Data("local edits".utf8).write(to: clone.appendingPathComponent("tracked"))
    var old = try await Probe.repos([clone.path], using: transport)[0]
    old.dirtySince = Date(timeIntervalSince1970: 100)
    old.ancestry["peer"] = Ancestry(relation: "unknown")
    let index = try Data(contentsOf: clone.appendingPathComponent(".git/index"))
    var fresh = try await Probe.checkUpstreams([old], method: .lsRemote, using: transport)[0]
    #expect(fresh.upstreamRemoteTip == old.headSHA)
    #expect(fresh.upstreamCheckedAt != nil)
    var withoutFreshness = fresh
    withoutFreshness.upstreamRemoteTip = nil; withoutFreshness.upstreamCheckedAt = nil
    #expect(withoutFreshness == old)
    #expect(await transport.localProbes == 1)
    #expect(try Data(contentsOf: clone.appendingPathComponent(".git/index")) == index)
    try await helper.git(server, ["checkout", "-b", "replacement"])
    try await helper.git(server, ["branch", "-D", "main"])
    fresh = try await Probe.checkUpstreams([fresh], method: .lsRemote, using: transport)[0]
    #expect(fresh.upstreamGone && fresh.upstreamRemoteDeleted)
    try await helper.git(server, ["branch", "main"])
    fresh = try await Probe.checkUpstreams([fresh], method: .lsRemote, using: transport)[0]
    #expect(!fresh.upstreamGone && !fresh.upstreamRemoteDeleted)
    try FileManager.default.removeItem(at: server)
    fresh = try await Probe.checkUpstreams([fresh], method: .lsRemote, using: transport)[0]
    #expect(fresh.error == nil && fresh.upstreamError != nil)
    #expect(fresh.modified == old.modified && fresh.dirtySince == old.dirtySince)
    #expect(await transport.localProbes == 1)
    try FileManager.default.removeItem(at: clone)
    fresh = try await Probe.checkUpstreams([fresh], method: .lsRemote, using: transport)[0]
    #expect(fresh.error == "Repository is missing")
  }
  @Test func testFetchAndConcurrentBranchSwitchRefreshLocalFacts() async throws {
    let helper = CoreTests(), transport = UpstreamTransport()
    let root = try helper.temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let server = root.appendingPathComponent("server"), clone = root.appendingPathComponent("clone")
    try await helper.repo(server)
    try await helper.git(root, ["clone", server.path, clone.path])
    let old = try await Probe.repos([clone.path], using: transport)[0]
    try Data("upstream change".utf8).write(to: server.appendingPathComponent("tracked"))
    try await helper.git(server, ["commit", "-am", "New upstream"])
    let checked = try await Probe.checkUpstreams([old], method: .lsRemote, using: transport)[0]
    #expect(checked.behind == 0 && checked.upstreamSHA == old.upstreamSHA)
    #expect(checked.upstreamRemoteTip != old.upstreamSHA)
    #expect(await transport.localProbes == 1)
    let fetched = try await Probe.checkUpstreams([checked], method: .fetch, using: transport)[0]
    #expect(fetched.behind == 1 && fetched.upstreamSHA == checked.upstreamRemoteTip)
    #expect(fetched.upstreamCheckedAt != nil && fetched.upstreamError == nil)
    #expect(await transport.localProbes == 2)
    try await helper.git(clone, ["checkout", "-b", "feature", "--track", "origin/main"])
    let switched = try await Probe.checkUpstreams([fetched], method: .lsRemote, using: transport)[0]
    #expect(switched.branch == "feature" && switched.behind == 0)
    #expect(switched.upstreamRemoteTip == switched.headSHA)
    #expect(await transport.localProbes == 3)
  }
}
