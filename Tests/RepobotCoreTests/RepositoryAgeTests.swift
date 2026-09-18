import Foundation
import Testing
@testable import RepobotCore

struct RepositoryAgeTests {
  private func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }

  @Test func testClockBoundsHandleSkewLatencyAndClockSteps() throws {
    let ahead = try #require(MachineClock(sourceStart: date(1120), sourceEnd: date(1122),
      localStart: date(1000), localEnd: date(1002.2), elapsed: 2.2))
    #expect(ahead.minimumOffset > 119 && ahead.maximumOffset == 121)
    #expect(ahead.isDivergent)
    let behind = try #require(MachineClock(sourceStart: date(880), sourceEnd: date(882),
      localStart: date(1000), localEnd: date(1002.2), elapsed: 2.2))
    #expect(behind.isDivergent && behind.maximumOffset < -5)
    // Slow transport must not be mistaken for a slow clock.
    let delayed = try #require(MachineClock(sourceStart: date(1000), sourceEnd: date(1001),
      localStart: date(1000), localEnd: date(1030), elapsed: 30))
    #expect(!delayed.isDivergent && delayed.isInconclusive)
    // Long probes with short transport delay still provide useful clock bounds.
    let longProbe = try #require(MachineClock(sourceStart: date(1000), sourceEnd: date(1120),
      localStart: date(1000), localEnd: date(1120.2), elapsed: 120.2))
    #expect(!longProbe.isDivergent && !longProbe.isInconclusive)
    #expect(MachineClock(sourceStart: date(1000), sourceEnd: date(999),
      localStart: date(1000), localEnd: date(1002), elapsed: 2) == nil)
    #expect(MachineClock(sourceStart: date(1000), sourceEnd: date(1002),
      localStart: date(1000), localEnd: date(1102), elapsed: 2) == nil)
  }

  @Test func testParsingAgesUsesSourceClockAndLegacyRecordsRemainReadable() throws {
    let fields = ["CLOCKSTART", "2000", "REPO", "/repo", "HEAD", "tip", "main", "0",
      "LAST", "1000", "Old work", "FILEAGE", "1900", "", "AGECLOCK", "2001",
      "END", "/repo", "CLOCKEND", "2002"]
    let data = Data((fields.joined(separator: "\0") + "\0").utf8)
    let repo = try Probe.parse(data, now: date(1002.2), startedAt: date(1000), elapsed: 2.2)[0]
    let age = try #require(repo.age)
    #expect(age.age(of: repo.lastCommitDate) == 1001)
    #expect(age.age(of: try #require(age.newestFileDate)) == 101)
    #expect(age.clock?.isDivergent == true)
    #expect(repo.probedAt == date(1002.2))
    let old = try Probe.parse(Data("REPO\0/old\0END\0/old\0".utf8))[0]
    #expect(old.age == nil)
    #expect(throws: (any Error).self) {
      try Probe.parse(Data("CLOCKSTART\0nan\0".utf8))
    }
  }

  @Test func testNewestFileExcludesMetadataAndSymlinksButIncludesIgnoredFilesAndRefreshesCachedHistory() async throws {
    let helper = CoreTests(), root = try helper.temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = root.appendingPathComponent("repo ' with\nnewline")
    try await helper.repo(repo)
    let tracked = repo.appendingPathComponent("tracked")
    try FileManager.default.setAttributes([.modificationDate: date(1000)], ofItemAtPath: tracked.path)
    try Data("metadata".utf8).write(to: repo.appendingPathComponent(".DS_Store"))
    try Data("metadata".utf8).write(to: repo.appendingPathComponent("._tracked"))
    let outside = root.appendingPathComponent("outside")
    try Data("outside".utf8).write(to: outside)
    try FileManager.default.createSymbolicLink(at: repo.appendingPathComponent("link"), withDestinationURL: outside)
    let ignored = repo.appendingPathComponent("ignored\nfile")
    try Data("ignored".utf8).write(to: ignored)
    try Data("ignored*\n".utf8).write(to: repo.appendingPathComponent(".git/info/exclude"))
    try FileManager.default.setAttributes([.modificationDate: date(2000)], ofItemAtPath: ignored.path)
    var old = try await Probe.repos([repo.path], using: LocalTransport())[0]
    #expect(old.age?.newestFileDate == date(2000))
    #expect(old.age?.fileScanError == nil)
    #expect(old.age?.clock?.isDivergent == false)
    try FileManager.default.setAttributes([.modificationDate: date(3000)], ofItemAtPath: tracked.path)
    let fresh = try await Probe.repos([repo.path], previous: [repo.path: old], using: LocalTransport())[0]
    #expect(fresh.probeFingerprint == old.probeFingerprint)
    #expect(fresh.age?.newestFileDate == date(3000))
    // Custom git dirs inside the work tree must also be pruned.
    try await helper.git(repo, ["init", "--separate-git-dir", repo.appendingPathComponent("metadata").path])
    old = try await Probe.repos([repo.path], using: LocalTransport())[0]
    #expect(old.age?.newestFileDate == date(3000))
    #expect(old.age?.fileScanError == nil)
  }

  @Test func testEmptyWorkingTreeHasNoNewestFile() async throws {
    let helper = CoreTests(), root = try helper.temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    try await helper.git(root, ["init"])
    let repo = try await Probe.repos([root.path], using: LocalTransport())[0]
    #expect(repo.headSHA.isEmpty)
    #expect(repo.age != nil && repo.age?.newestFileDate == nil && repo.age?.fileScanError == nil)
  }

  @Test func testFailedFileScanDoesNotPresentPartialAgesAsComplete() async throws {
    let helper = CoreTests(), root = try helper.temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = root.appendingPathComponent("repo")
    try await helper.repo(repo)
    let transport = try CountingGitTransport(root: root)
    let stat = transport.bin.appendingPathComponent("stat")
    try Data("#!/bin/sh\necho 'Unable to inspect file' >&2\nexit 1\n".utf8).write(to: stat)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stat.path)
    let result = try await Probe.repos([repo.path], using: transport)[0]
    #expect(result.error == nil && !result.headSHA.isEmpty)
    #expect(result.age?.fileScanError != nil)
    #expect(result.age?.newestFileDate == nil)
  }
}
