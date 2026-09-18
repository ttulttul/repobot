import AppKit
import Foundation
import Observation
import SwiftUI
import Testing
@testable import RepobotApp
@testable import RepobotCore

private final class MapChangeCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  var value: Int { lock.withLock { count } }
  func increment() { lock.withLock { count += 1 } }
}

@MainActor struct RepositoryMapModelTests {
  private func inventory() -> [EnvironmentSnapshot] {
    (0..<3).map { host in
      var env = EnvironmentSnapshot(environment: RepobotCore.Environment(name: "Host \(host)", kind: .local))
      env.checkedAt = Date()
      env.repos = SnapshotList((0..<80).map { index in
        var repo = RepoSnapshot(path: "/repos/\(index)")
        repo.originURL = "https://example.test/org/\(index).git"
        repo.branch = "main"; repo.headSHA = "tip"; repo.upstream = "origin/main"
        repo.upstreamSHA = "tip"
        return repo
      })
      return env
    }
  }
  private func compare(_ model: RepositoryMapModel, _ world: WorldSnapshot) {
    let expected = world.repositories
    #expect(model.visibleGroups.map(\.id) == expected.map(\.id))
    for (actual, expected) in zip(model.visibleGroups, expected) {
      #expect(Set(actual.rows.map(\.id)) == Set(expected.clones.map(\.id)))
      #expect(actual.severity == expected.severity)
      #expect(actual.machineCount == Set(expected.clones.map(\.environmentID)).count)
    }
  }

  @Test func testProgressAndFreshnessDoNotInvalidateListOrRowContent() throws {
    var analyzer = IncrementalAnalyzer()
    var envs = inventory()
    let model = RepositoryMapModel()
    model.update(analyzer.analyze(envs, configuration: Configuration()))
    let group = try #require(model.visibleGroups.first)
    let row = try #require(group.rows.first)
    let listChanges = MapChangeCounter(), contentChanges = MapChangeCounter(), freshnessChanges = MapChangeCounter()
    withObservationTracking { _ = model.visibleGroups; _ = group.rows; _ = group.summary } onChange: { listChanges.increment() }
    withObservationTracking { _ = row.content } onChange: { contentChanges.increment() }
    withObservationTracking { _ = row.checkedAt } onChange: { freshnessChanges.increment() }
    let refreshed = model.refreshedGroups
    for index in 0..<100 {
      envs[0].checkProgress = "Checking \(index)"
      for host in envs.indices {
        for repo in envs[host].repos.indices {
          envs[host].repos[repo].probedAt = Date(timeIntervalSince1970: Double(1_800_000_000 + index))
          envs[host].repos[repo].probeFingerprint = "cache-bookkeeping-\(index)"
        }
      }
      model.update(analyzer.analyze(envs, configuration: Configuration()))
    }
    #expect(model.groupingCount == 1)
    #expect(model.sortingCount == 1)
    #expect(model.filteringCount == 1)
    #expect(model.refreshedGroups == refreshed)
    #expect(listChanges.value == 0)
    #expect(contentChanges.value == 0)
    #expect(freshnessChanges.value == 1)
    #expect(row.clone.repo.probedAt == row.checkedAt)
    #expect(model.progress.messages.first?.text == "Host 0: Checking 99")
    #expect(model.visibleGroups.first === group)
  }

  @Test func testContentMembershipAvailabilityAndFiltersStayCurrent() throws {
    var analyzer = IncrementalAnalyzer()
    var envs = inventory()
    let model = RepositoryMapModel()
    func update() {
      let world = analyzer.analyze(envs, configuration: Configuration())
      model.update(world)
      if model.search.isEmpty && !model.sharedOnly { compare(model, world) }
    }
    update()
    let refreshed = model.refreshedGroups
    let original = try #require(model.visibleGroups.first { $0.id.hasSuffix("/12") })
    envs[0].repos[12].modified = 1
    update()
    #expect(model.refreshedGroups == refreshed + 1)
    #expect(model.groupingCount == 1)
    #expect(model.visibleGroups.contains { $0 === original })
    #expect(original.summary == "Uncommitted work on Host 0")
    envs[1].repos[12].originURL = "https://example.test/fork/12.git"
    update()
    #expect(original.rows.count == 2)
    model.sharedOnly = true
    #expect(!model.visibleGroups.contains { $0.id.contains("/fork/") })
    envs[2].repos.remove(at: 12)
    update()
    #expect(!model.visibleGroups.contains { $0 === original })
    model.sharedOnly = false
    model.search = "renamed"
    #expect(model.visibleGroups.isEmpty)
    envs[0].environment.name = "Renamed"
    update()
    #expect(model.visibleGroups.count == 80)
    envs[0].error = "Offline"
    update()
    let row = try #require(original.rows.first)
    #expect(row.content.unavailable && row.content.unverified)
    #expect(original.summary.contains("could not be checked"))
    envs[0].error = nil
    envs[0].repos[12].awaitingFreshCheck = true
    update()
    #expect(!row.content.unavailable && row.content.unverified)
    #expect(original.summary.contains("pending"))
    envs[0].repos[12].awaitingFreshCheck = false
    update()
    #expect(!row.content.unverified)
    model.search = ""
    update()
    envs.removeAll()
    update()
    #expect(model.visibleGroups.isEmpty)
  }

  @Test func testSnapshotsWithoutRevisionAndReopeningUseCurrentData() {
    var envs = inventory()
    let model = RepositoryMapModel()
    model.update(Analyzer.analyze(envs, configuration: Configuration()))
    envs[0].repos[3].modified = 1
    let world = Analyzer.analyze(envs, configuration: Configuration())
    model.update(world)
    compare(model, world)
    let reopened = RepositoryMapModel()
    reopened.update(world)
    compare(reopened, world)
    #expect(reopened.visibleGroups.map(\.summary) == model.visibleGroups.map(\.summary))
  }

  @Test func testAgeUpdatesDoNotReanalyzeOrInvalidateRepositoryRowsAndClockWarningsCompareHosts() throws {
    var envs = inventory(), analyzer = IncrementalAnalyzer()
    let model = RepositoryMapModel(), configuration = Configuration()
    model.update(analyzer.analyze(envs, configuration: configuration))
    let group = try #require(model.visibleGroups.first { $0.id.hasSuffix("/12") })
    let row = try #require(group.rows.first { $0.clone.environmentID == envs[0].id })
    let contentChanges = MapChangeCounter(), ageChanges = MapChangeCounter()
    withObservationTracking { _ = row.content } onChange: { contentChanges.increment() }
    withObservationTracking { _ = row.age } onChange: { ageChanges.increment() }
    let analyzed = analyzer.analyzedClones, refreshed = model.refreshedGroups
    func sample(_ offset: Double) -> RepositoryAge {
      let date = Date(timeIntervalSince1970: 1000)
      return RepositoryAge(measuredAt: date.addingTimeInterval(offset), newestFileDate: date.addingTimeInterval(-86400),
        clock: MachineClock(sourceStart: date.addingTimeInterval(offset), sourceEnd: date.addingTimeInterval(offset),
          localStart: date, localEnd: date.addingTimeInterval(0.1), elapsed: 0.1))
    }
    envs[0].repos[12].age = sample(4)
    envs[1].repos[12].age = sample(-4)
    model.update(analyzer.analyze(envs, configuration: configuration))
    #expect(analyzer.analyzedClones == analyzed)
    #expect(model.refreshedGroups == refreshed)
    #expect(contentChanges.value == 0 && ageChanges.value == 1)
    #expect(row.age == envs[0].repos[12].age)
    #expect(model.progress.clockMessages.count == 1)
    #expect(model.progress.clockMessages.first?.text.contains("Last measured clocks differ") == true)
    envs[0].repos[12].age = sample(0)
    envs[1].repos[12].age = sample(0)
    model.update(analyzer.analyze(envs, configuration: configuration))
    #expect(model.progress.clockMessages.isEmpty)
    #expect(RepositoryAgeView.describe(86400 * 180) == "6 months ago")
    #expect(RepositoryAgeView.describe(-120) == "2 minutes in the future")
  }

  @Test func testSelectionFollowsSearchAndSurvivesRefreshAndRemoval() throws {
    var envs = inventory(), analyzer = IncrementalAnalyzer()
    let model = RepositoryMapModel()
    func update() { model.update(analyzer.analyze(envs, configuration: Configuration())) }
    update()
    #expect(model.selectedGroupID == model.visibleGroups.first?.id)
    let selected = try #require(model.visibleGroups.first { $0.id.hasSuffix("/12") })
    model.selectedGroupID = selected.id
    envs[0].repos[3].modified = 1 // Reordering should not change selection.
    update()
    #expect(model.selectedGroup === selected)
    model.search = "  EXAMPLE.TEST/ORG/12  "
    #expect(model.visibleGroups.count == 1)
    #expect(model.selectedGroup === selected)
    model.search = "no-such-repository"
    #expect(model.selectedGroupID == nil)
    #expect(model.selectedGroup == nil)
    model.search = "Host 2"
    #expect(model.selectedGroupID == model.visibleGroups.first?.id)
    model.search = ""
    model.selectedGroupID = selected.id
    for host in envs.indices { envs[host].repos.remove(at: 12) }
    update()
    #expect(model.selectedGroupID != selected.id)
    #expect(model.selectedGroupID == model.visibleGroups.first?.id)
    envs.removeAll()
    update()
    #expect(model.selectedGroupID == nil)
  }

  @Test func testOverviewCountsVerifiedCopiesAndStashesWithoutDoubleCountingPushes() throws {
    var envs = inventory(), analyzer = IncrementalAnalyzer()
    let model = RepositoryMapModel()
    envs[0].repos[12].modified = 2
    envs[0].repos[12].ahead = 3
    envs[0].repos[12].stashCount = 2
    envs[0].repos[12].branchWork = [BranchWork(name: "feature", upstream: "origin/feature", ahead: 2, behind: 0)]
    envs[1].repos[12].stashCount = 1
    envs[2].repos[12].modified = 1
    envs[2].repos[12].stashCount = 4
    envs[2].repos[12].awaitingFreshCheck = true
    model.update(analyzer.analyze(envs, configuration: Configuration()))
    let group = try #require(model.visibleGroups.first { $0.id.hasSuffix("/12") })
    #expect(group.name == "12")
    #expect(group.location == "example.test/org")
    #expect(group.overview == .init(changedCopies: 1, pendingPushCopies: 1, stashes: 3, unverifiedCopies: 1))
    envs[2].repos[12].awaitingFreshCheck = false
    model.update(analyzer.analyze(envs, configuration: Configuration()))
    #expect(group.overview == .init(changedCopies: 2, pendingPushCopies: 1, stashes: 7, unverifiedCopies: 0))
    envs[0].error = "Offline"
    model.update(analyzer.analyze(envs, configuration: Configuration()))
    #expect(group.overview == .init(changedCopies: 1, pendingPushCopies: 0, stashes: 5, unverifiedCopies: 1))
  }

  @Test func testChangedRowsOnlyAndMissedPublicationsRecover() throws {
    var envs = inventory(), analyzer = IncrementalAnalyzer()
    let model = RepositoryMapModel()
    let config = Configuration()
    model.update(analyzer.analyze(envs, configuration: config))
    let initial = model.visitedRows
    func change(_ index: Int) -> WorldSnapshot {
      envs[0].repos[index].modified += 1
      let repo = envs[0].repos[index]
      return analyzer.analyze(envs, configuration: config, changes: [
        RepositoryID(environment: envs[0].id, path: repo.path): RepositoryChange(repo: repo, position: index)
      ])
    }
    var world = change(12)
    model.update(world)
    #expect(model.visitedRows - initial == 3)
    compare(model, world)
    let visited = model.visitedRows
    world.environments[0].checkProgress = "Just progress"
    model.update(world)
    #expect(model.visitedRows == visited)
    #expect(model.progress.messages.first?.text == "Host 0: Just progress")
    _ = change(13) // AsyncStream may replace this publication before the UI sees it.
    world = change(14)
    model.update(world)
    #expect(model.visitedRows - visited == 6)
    compare(model, world)
    for index in [12, 13, 14] {
      let group = try #require(model.visibleGroups.first { $0.id.hasSuffix("/\(index)") })
      #expect(group.summary == "Uncommitted work on Host 0")
    }
    let refreshed = model.visitedRows
    world = change(15)
    model.update(world)
    #expect(model.visitedRows - refreshed == 3)
  }

  @Test func testNestedChildrenFilterFindsContainersAndKeepsSkippedOnes() {
    var envs = inventory(), analyzer = IncrementalAnalyzer()
    let config = Configuration(), model = RepositoryMapModel()
    func add(_ path: String, to host: Int) {
      var repo = RepoSnapshot(path: path)
      repo.originURL = "https://example.test/nested\(path).git"; repo.branch = "main"; repo.headSHA = "tip"
      envs[host].repos.append(repo)
    }
    // Host 0 holds an atlas with copies two levels down and a sibling sharing its name prefix.
    for path in ["/repos/atlas", "/repos/atlas/copies/one", "/repos/atlas/copies/two", "/repos/atlas-sibling"] { add(path, to: 0) }
    add("/repos/atlas/copies/one", to: 1)  // Same path on another machine has no parent there.
    model.update(analyzer.analyze(envs, configuration: config))
    let atlas = "\(envs[0].id.uuidString):/repos/atlas"
    #expect(model.nestedCounts == [atlas: 2])
    model.nestedOnly = true
    #expect(model.visibleGroups.count == 1 && model.visibleGroups[0].rows.map(\.id) == [atlas])
    // Once its children are excluded from discovery it must stay findable, to undo the setting.
    envs[0].repos = SnapshotList(envs[0].repos.filter { !$0.path.hasPrefix("/repos/atlas/") })
    model.nestedSkipped = [atlas]
    model.update(analyzer.analyze(envs, configuration: config))
    #expect(model.nestedCounts.isEmpty)
    #expect(model.visibleGroups.count == 1 && model.visibleGroups[0].rows.map(\.id) == [atlas])
    model.nestedSkipped = []
    #expect(model.visibleGroups.isEmpty)
    model.nestedOnly = false
    #expect(model.visibleGroups.count > 80)
  }

  @Test func testHistoryExpiryStructuralChangesAndNewAnalyzerReconcile() {
    var envs = inventory(), analyzer = IncrementalAnalyzer()
    let model = RepositoryMapModel(), config = Configuration()
    model.update(analyzer.analyze(envs, configuration: config))
    let initial = model.visitedRows
    var world = WorldSnapshot()
    for step in 0..<70 {
      envs[0].repos[step].modified = 1
      let repo = envs[0].repos[step]
      world = analyzer.analyze(envs, configuration: config, changes: [
        RepositoryID(environment: envs[0].id, path: repo.path): RepositoryChange(repo: repo, position: step)])
    }
    #expect(world.changes?.history?.count == 64)
    model.update(world)
    #expect(model.visitedRows - initial == 240)
    compare(model, world)
    let visited = model.visitedRows
    envs[0].repos.remove(at: 2)
    _ = analyzer.analyze(envs, configuration: config) // missed structural change
    envs[1].environment.name = "Renamed"
    world = analyzer.analyze(envs, configuration: config, changes: [:])
    model.update(world)
    #expect(model.visitedRows - visited == 239)
    compare(model, world)
    var replacement = IncrementalAnalyzer()
    let beforeReplacement = model.visitedRows
    world = replacement.analyze(envs, configuration: config)
    model.update(world)
    #expect(model.visitedRows - beforeReplacement == 239)
    compare(model, world)
  }

  @Test func testInternalReadsAndBufferedStreamKeepAllChangesIncremental() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    var envs = inventory(), config = Configuration()
    config.environments = envs.map(\.environment)
    let store = StateStore(configuration: config, persistence: Persistence(directory: root),
                           publicationDelay: .seconds(60), persistenceDelay: .seconds(60))
    for env in envs { await store.merge(env) }
    var stream = await store.stream().makeAsyncIterator()
    let model = RepositoryMapModel()
    model.update(try #require(await stream.next()))
    let visited = model.visitedRows
    for step in 0..<6 {
      envs[0].repos[step].modified = step + 1
      await store.merge(envs[0], changedPaths: [envs[0].repos[step].path])
      _ = await store.peerMap(for: envs[1].id) // internal analysis before publication
      if step % 2 == 1 { await store.flush() } // buffer replaces two publications
    }
    let world = try #require(await stream.next())
    model.update(world)
    #expect(model.visitedRows - visited == 18)
    compare(model, world)
    let actual = Dictionary(uniqueKeysWithValues: model.visibleGroups.flatMap(\.rows).map { ($0.id, $0.clone.repo) })
    for clone in world.clones { #expect(actual[clone.id] == clone.repo) }
  }

  @Test func testClosingDetachesHostingTreeEvenWhenWindowRemainsRetained() {
    _ = NSApplication.shared
    var closes = 0
    for _ in 0..<3 {
      let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      weak var weakModel: RepositoryMapModel?
      weak var weakController: NSHostingController<MapLifetimeFixture>?
      autoreleasepool {
        let model = RepositoryMapModel()
        weakModel = model
        let controller = NSHostingController(rootView: MapLifetimeFixture(model: model))
        weakController = controller
        window.contentViewController = controller
      }
      #expect(weakModel != nil)
      let owner = DisposableWindow(window: window) { closes += 1 }
      autoreleasepool { window.close() }
      #expect(owner.window == nil)
      #expect(window.contentViewController == nil)
      #expect(weakController == nil)
      #expect(weakModel == nil)
      owner.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
    }
    #expect(closes == 3)
  }
}

private struct MapLifetimeFixture: View {
  let model: RepositoryMapModel
  var body: some View { Text("\(model.visibleGroups.count) repositories") }
}
