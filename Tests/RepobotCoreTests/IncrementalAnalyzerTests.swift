import Foundation
import Testing
@testable import RepobotCore

struct IncrementalAnalyzerTests {
  private func inventory(_ now: Date) -> [EnvironmentSnapshot] {
    (0..<3).map { host in
      var snapshot = EnvironmentSnapshot(environment: Environment(name: "Host \(host)", kind: .local))
      snapshot.repos = SnapshotList((0..<80).map { index in
        var repo = RepoSnapshot(path: "/repos/\(index)")
        repo.originURL = "https://example.test/org/\(index).git"
        repo.branch = "main"; repo.headSHA = "tip"; repo.upstream = "origin/main"
        repo.upstreamSHA = "tip"; repo.probedAt = now
        return repo
      })
      return snapshot
    }
  }
  private func compare(_ world: WorldSnapshot, _ snapshots: [EnvironmentSnapshot],
                       _ config: Configuration, _ now: Date) {
    let expected = Analyzer.analyze(snapshots, configuration: config, now: now)
    #expect(world.clones.map(\.id) == expected.clones.map(\.id))
    #expect(world.clones.map(\.status) == expected.clones.map(\.status))
    #expect(world.clones.map(\.repo) == expected.clones.map(\.repo))
  }
  @Test func testOnlyChangedGroupsAreAnalyzedAndObservationTimesAreIgnored() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var snapshots = inventory(now)
    let config = Configuration()
    var analyzer = IncrementalAnalyzer()
    compare(analyzer.analyze(snapshots, configuration: config, now: now), snapshots, config, now)
    #expect(analyzer.analyzedClones == 240)
    #expect(analyzer.resolvedIdentities == 240)
    let revision = analyzer.revision
    for host in snapshots.indices {
      for index in snapshots[host].repos.indices {
        snapshots[host].repos[index].probedAt = now.addingTimeInterval(5)
        snapshots[host].repos[index].upstreamCheckedAt = now.addingTimeInterval(5)
      }
    }
    compare(analyzer.analyze(snapshots, configuration: config, now: now), snapshots, config, now)
    #expect(analyzer.revision == revision)
    #expect(analyzer.analyzedClones == 240)
    snapshots[1].repos[12].modified = 1
    snapshots[1].repos[12].dirtySince = now
    compare(analyzer.analyze(snapshots, configuration: config, now: now), snapshots, config, now)
    #expect(analyzer.analyzedClones == 243)
    #expect(analyzer.resolvedIdentities == 240)
    // Moving one copy to a different upstream invalidates both old and new groups.
    snapshots[1].repos[12].originURL = "https://example.test/fork/12.git"
    compare(analyzer.analyze(snapshots, configuration: config, now: now), snapshots, config, now)
    #expect(analyzer.analyzedClones == 246)
    #expect(analyzer.resolvedIdentities == 241)
    snapshots[2].repos.remove(at: 12)
    compare(analyzer.analyze(snapshots, configuration: config, now: now), snapshots, config, now)
    snapshots[0].error = "Offline"
    compare(analyzer.analyze(snapshots, configuration: config, now: now), snapshots, config, now)
    snapshots[0].error = nil; snapshots[0].environment.name = "Renamed"
    compare(analyzer.analyze(snapshots, configuration: config, now: now), snapshots, config, now)
  }
  @Test func testAgeSnoozeAndConfigurationChangesMatchFullAnalysis() {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    var snapshots = inventory(start)
    snapshots[0].repos[0].modified = 1
    snapshots[0].repos[0].dirtySince = start
    snapshots[0].repos[1].ahead = 1
    snapshots[0].repos[1].unpushedSince = start
    snapshots[0].repos[2].branchCommitDates = ["old": start]
    var config = Configuration()
    config.dirtyHours = 1; config.unpushedHours = 2
    config.reportStaleBranches = true; config.staleBranchDays = 1
    config.snoozed["\(snapshots[0].id):/repos/0"] = start.addingTimeInterval(1800)
    var analyzer = IncrementalAnalyzer()
    for seconds: Double in [0, 1799, 1800, 3599, 3600, 7200, 86400, 172800] {
      let now = start.addingTimeInterval(seconds)
      compare(analyzer.analyze(snapshots, configuration: config, now: now), snapshots, config, now)
      #expect(analyzer.nextDeadline == nil || analyzer.nextDeadline! > now)
    }
    config.disabledFindings.insert("peer-dirty")
    compare(analyzer.analyze(snapshots, configuration: config, now: start), snapshots, config, start)
  }
  @Test func testStateStorePublishesAgeTransitionsWithoutRepositoryEvents() async throws {
    let root = try CoreTests().temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    var config = Configuration(); config.dirtyHours = 0
    let env = config.environments[0]
    var snapshot = EnvironmentSnapshot(environment: env)
    var repo = RepoSnapshot(path: "/repos/age")
    repo.modified = 1
    snapshot.repos = [repo]
    config.snoozed["\(env.id):\(repo.path)"] = Date().addingTimeInterval(0.2)
    let store = StateStore(configuration: config, persistence: Persistence(directory: root),
                           publicationDelay: .milliseconds(10), persistenceDelay: .seconds(60))
    await store.merge(snapshot)
    let initial = await store.world()
    #expect(initial.clones[0].status.severity == .ok)
    let published = AgePublications()
    let stream = await store.stream()
    let task = Task { for await world in stream { await published.receive(world) } }
    defer { task.cancel() }
    for _ in 0..<200 {
      if await published.attention { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await published.attention)
    await store.flush()
  }
}
private actor AgePublications {
  var attention = false
  func receive(_ world: WorldSnapshot) { attention = world.clones.contains { $0.status.severity >= .attention } }
}
