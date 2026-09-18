import Foundation
import Testing
@testable import RepobotCore

struct SelectiveProbeTests {
  @Test func testRefsChangingDuringFullProbeDoNotLeaveReusableFacts() async throws {
    let helper = CoreTests(), root = try helper.temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = root.appendingPathComponent("repo")
    try await helper.repo(repo)
    let transport = try CountingGitTransport(root: root)
    let wrapperURL = transport.bin.appendingPathComponent("git")
    let original = try String(contentsOf: wrapperURL, encoding: .utf8)
    let marker = shellQuote(root.appendingPathComponent("mutated").path)
    let realGit = FileManager.default.isExecutableFile(atPath: "/Library/Developer/CommandLineTools/usr/bin/git")
      ? "/Library/Developer/CommandLineTools/usr/bin/git" : "/usr/bin/git"
    let hook = """
    for arg do
      if [ "$arg" = log ] && [ ! -f \(marker) ]; then
        touch \(marker)
        \(shellQuote(realGit)) -C \(shellQuote(repo.path)) commit --allow-empty -m 'Concurrent commit' >/dev/null
        break
      fi
    done
    """
    try Data(("#!/bin/sh\n" + hook + "\n" + original).utf8).write(to: wrapperURL)
    let mixed = try await Probe.repos([repo.path], using: transport)[0]
    #expect(mixed.probeFingerprint == nil)
    let refreshed = try await Probe.repos([repo.path], previous: [repo.path: mixed], using: transport)[0]
    #expect(refreshed.probeFingerprint != nil && refreshed.lastCommitSubject == "Concurrent commit")
    #expect(refreshed.headSHA != mixed.headSHA)
  }

  @Test func testWorkingEditsReuseHistoryButCommitsStashesAndConfigurationInvalidateIt() async throws {
    let helper = CoreTests(), root = try helper.temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = root.appendingPathComponent("repo")
    try await helper.repo(repo)
    let transport = try CountingGitTransport(root: root)
    var old = try await Probe.repos([repo.path], using: transport)[0]
    #expect(old.probeFingerprint != nil)
    try Data("work\n".utf8).write(to: repo.appendingPathComponent("tracked"))
    let before = transport.calls().count
    var fast = try await Probe.repos([repo.path], previous: [repo.path: old], using: transport)[0]
    #expect(fast.modified == 1 && fast.probeFingerprint == old.probeFingerprint)
    #expect(!transport.calls().dropFirst(before).contains { $0.contains("rev-list --max-parents") })
    let full = try await Probe.repos([repo.path], using: transport)[0]
    fast.probedAt = full.probedAt
    // Measurement times and transport bounds differ between invocations.
    #expect(fast.age?.newestFileDate == full.age?.newestFileDate)
    fast.age = full.age
    #expect(fast == full)
    try await helper.git(repo, ["commit", "-am", "Work"])
    var next = try await Probe.repos([repo.path], previous: [repo.path: fast], using: transport)[0]
    #expect(next.headSHA != fast.headSHA && next.lastCommitSubject == "Work")
    #expect(next.probeFingerprint != fast.probeFingerprint)
    try Data("stash work\n".utf8).write(to: repo.appendingPathComponent("tracked"))
    try await helper.git(repo, ["stash", "push"])
    old = next
    next = try await Probe.repos([repo.path], previous: [repo.path: old], using: transport)[0]
    #expect(next.stashCount == 1 && next.probeFingerprint != old.probeFingerprint)
    try await helper.git(repo, ["stash", "drop"])
    old = next
    next = try await Probe.repos([repo.path], previous: [repo.path: old], using: transport)[0]
    #expect(next.stashCount == 0 && next.probeFingerprint != old.probeFingerprint)
    try await helper.git(repo, ["remote", "add", "origin", "https://example.test/new.git"])
    old = next
    next = try await Probe.repos([repo.path], previous: [repo.path: old], using: transport)[0]
    #expect(next.originURL == "https://example.test/new.git" && next.probeFingerprint != old.probeFingerprint)
    try await helper.git(repo, ["checkout", "--detach"])
    old = next
    next = try await Probe.repos([repo.path], previous: [repo.path: old], using: transport)[0]
    #expect(next.detached && next.probeFingerprint != old.probeFingerprint)
  }

  @Test func testNewPeerObjectsInvalidateAncestryWithoutChangingLocalRefs() async throws {
    let helper = CoreTests(), root = try helper.temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = root.appendingPathComponent("repo"), peer = root.appendingPathComponent("peer")
    try await helper.repo(repo)
    try await helper.git(root, ["clone", repo.path, peer.path])
    try await helper.git(peer, ["config", "user.name", "Fixture"])
    try await helper.git(peer, ["config", "user.email", "fixture@example.invalid"])
    try Data("peer work".utf8).write(to: peer.appendingPathComponent("tracked"))
    try await helper.git(peer, ["commit", "-am", "Peer"])
    let sha = try await helper.git(peer, ["rev-parse", "HEAD"])
    let old = try await Probe.repos([repo.path], peers: [sha], using: LocalTransport())[0]
    #expect(old.ancestry[sha]?.relation == "unknown")
    try await helper.git(repo, ["fetch", "--no-write-fetch-head", peer.path, sha])
    let fresh = try await Probe.repos([repo.path], peers: [sha], previous: [repo.path: old], using: LocalTransport())[0]
    #expect(fresh.headSHA == old.headSHA && fresh.localBranches == old.localBranches)
    #expect(fresh.probeFingerprint != old.probeFingerprint)
    #expect(fresh.ancestry[sha]?.relation == "behind")
  }
}
