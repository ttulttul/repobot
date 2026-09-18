import Foundation
import Testing
@testable import RepobotCore

struct RepositoryMapTests {
  @Test func testIndependentUnpushedCommitsAndForgottenBranch() async throws {
    let helper = CoreTests()
    let root = try helper.temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let server = root.appendingPathComponent("server")
    let mac = root.appendingPathComponent("mac")
    let linux = root.appendingPathComponent("linux")
    try await helper.repo(server)
    for path in [mac, linux] {
      try await helper.git(root, ["clone", server.path, path.path])
      try await helper.git(path, ["config", "user.name", "Fixture"])
      try await helper.git(path, ["config", "user.email", "fixture@example.invalid"])
    }
    try await helper.git(mac, ["commit", "--allow-empty", "-m", "Mac work"])
    try await helper.git(linux, ["commit", "--allow-empty", "-m", "Linux work"])
    var left = try await Probe.repos([mac.path], using: LocalTransport())[0]
    var right = try await Probe.repos([linux.path], using: LocalTransport())[0]
    #expect(left.localCommitSHAs?.count == 1)
    #expect(right.localCommitSHAs?.count == 1)
    #expect(Analyzer.compare(left, right).relation == "diverged")
    #expect(Analyzer.compare(left, right).ahead == 1)
    #expect(Analyzer.compare(left, right).behind == 1)
    // Comparing snapshots did not copy the unpublished objects to the other machine.
    let absent = try await ProcessRunner.run("/usr/bin/git", ["-C", mac.path, "cat-file", "-e", right.headSHA])
    #expect(absent.status != 0)
    var a = EnvironmentSnapshot(environment: Environment(name: "This Mac", kind: .local))
    var b = EnvironmentSnapshot(environment: Environment(name: "Linux box", kind: .ssh))
    a.repos = [left]; b.repos = [right]
    var world = Analyzer.analyze([a, b], configuration: Configuration())
    #expect(world.repositories.count == 1)
    #expect(world.repositories[0].clones.count == 2)
    #expect(world.clones.allSatisfy { $0.status.findings.contains { $0.id == "peer-diverged" } })
    #expect(world.clones[0].status.findings.contains { $0.id == "peer-unpushed" && $0.text.contains("Linux box") })

    // Forgotten work remains visible even after switching to another branch.
    try await helper.git(linux, ["switch", "-c", "forgotten", "--track", "origin/main"])
    try await helper.git(linux, ["commit", "--allow-empty", "-m", "Forgotten change"])
    try await helper.git(linux, ["switch", "-c", "new-task", "origin/main"])
    try Data("unfinished\n".utf8).write(to: linux.appendingPathComponent("tracked"))
    right = try await Probe.repos([linux.path], using: LocalTransport())[0]
    #expect(right.branchWork?.first { $0.name == "forgotten" }?.ahead == 1)
    #expect(Analyzer.workSignals(right).joined().contains("forgotten"))
    b.repos = [right]
    world = Analyzer.analyze([a, b], configuration: Configuration())
    #expect(world.clones[0].status.findings.contains { $0.id == "peer-dirty" })
    #expect(world.clones[0].status.findings.contains { $0.id == "peer-unpushed" && $0.text.contains("forgotten") })

    // Unknown/truncated history is never called divergence.
    right.headSHA = String(repeating: "b", count: 40)
    right.localCommitSHAs = nil
    left.ancestry = [:]
    #expect(Analyzer.compare(left, right).relation == "unknown")
    b.error = "Offline"
    b.repos = [right]
    world = Analyzer.analyze([a, b], configuration: Configuration())
    #expect(!world.clones[0].status.findings.contains { $0.id.hasPrefix("peer-") })
    #expect(world.clones[0].status.peers[0].text.contains("Last known"))
  }

  @Test func testTrackingIdentityBranchAndAncestryBoundaries() {
    var a = RepoSnapshot(path: "/mac/repo")
    var b = RepoSnapshot(path: "/linux/repo")
    a.originURL = "https://github.com/my-fork/project.git"
    a.trackingRemoteURL = "git@GitHub.com:team/project.git"
    b.originURL = "https://github.com:443/team/project.git/"
    #expect(Analyzer.identity(a) == Analyzer.identity(b))
    a.branch = "main"; b.branch = "my-main"
    a.upstreamRef = "refs/heads/main"; b.upstreamRef = "refs/heads/main"
    #expect(Analyzer.sameLineOfWork(a, b))
    a.upstreamSHA = "base"; b.upstreamSHA = "base"
    a.headSHA = "one"; b.headSHA = "two"
    a.localCommitSHAs = ["one"]; b.localCommitSHAs = ["two", "one"]
    #expect(Analyzer.compare(a, b).relation == "behind")
    #expect(Analyzer.compare(a, b).behind == 1)
    b.shallow = true
    #expect(Analyzer.compare(a, b).relation == "unknown")
    b.shallow = false; b.upstreamSHA = "another-base"
    #expect(Analyzer.compare(a, b).relation == "unknown")
    b.upstreamRef = "refs/heads/feature"
    #expect(!Analyzer.sameLineOfWork(a, b))
    a.ahead = 1; a.upstreamRemoteTip = a.headSHA
    #expect(!Analyzer.needsPush(a))
    // Same path on two machines is not an identity for unrelated empty repositories.
    let empty = RepoSnapshot(path: "/home/user/new-project")
    #expect(Analyzer.repositoryKey(empty, environmentID: UUID()) != Analyzer.repositoryKey(empty, environmentID: UUID()))
  }

  @Test func testDifferentBranchesStillSurfaceWorkAndCacheCompatibility() async throws {
    var a = RepoSnapshot(path: "/repo")
    a.originURL = "https://example.test/repo.git"
    a.branch = "main"; a.headSHA = "main-tip"
    var b = a
    b.path = "/other"; b.branch = "feature"; b.headSHA = "feature-tip"
    b.modified = 1; b.ahead = 2; b.stashCount = 1
    var left = EnvironmentSnapshot(environment: Environment(name: "Mac", kind: .local))
    var right = EnvironmentSnapshot(environment: Environment(name: "Linux", kind: .ssh))
    left.repos = [a]; right.repos = [b]
    let world = Analyzer.analyze([left, right], configuration: Configuration())
    let findings = world.clones[0].status.findings.map(\.id)
    #expect(findings.contains("peer-branch"))
    #expect(findings.contains("peer-dirty"))
    #expect(findings.contains("peer-unpushed"))
    #expect(findings.contains("peer-stashes"))
    #expect(!findings.contains("peer-diverged"))
    let root = try CoreTests().temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    var config = Configuration()
    config.environments = [left.environment, right.environment]
    let store = StateStore(configuration: config, persistence: Persistence(directory: root), cached: world)
    let restored = await store.world()
    #expect(restored.environments.allSatisfy { $0.error == nil && $0.checkProgress == "Waiting for a fresh check" })
    #expect(restored.clones.allSatisfy { restored.isUnverified($0) && !restored.isUnavailable($0) })
    #expect(restored.clones.allSatisfy { !$0.status.findings.contains { $0.id.hasPrefix("peer-") } })
    var offline = EnvironmentSnapshot(environment: right.environment)
    offline.error = "SSH unavailable"
    await store.merge(offline)
    let failedRefresh = await store.world()
    #expect(failedRefresh.clones.count == 2)
    #expect(failedRefresh.environments.first { $0.id == right.id }?.repos.first?.modified == 1)
    #expect(failedRefresh.clones.first { $0.environmentID == right.id }.map { failedRefresh.isUnavailable($0) } == true)
    // An actual successful empty discovery can remove the old inventory.
    offline.error = nil
    await store.merge(offline)
    #expect(await store.world().clones.count == 1)
    // Newly added fields are optional so existing saved snapshots still decode.
    let encoded = try JSONEncoder().encode(b)
    var legacy = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    for key in ["trackingRemoteURL", "upstreamRef", "localCommitSHAs", "branchWork"] { legacy.removeValue(forKey: key) }
    let decoded = try JSONDecoder().decode(RepoSnapshot.self, from: JSONSerialization.data(withJSONObject: legacy))
    #expect(decoded.branchWork == nil)
    #expect(decoded.branch == "feature")
  }
}
