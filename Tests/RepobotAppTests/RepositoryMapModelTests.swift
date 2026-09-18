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
      env.repos = (0..<80).map { index in
        var repo = RepoSnapshot(path: "/repos/\(index)")
        repo.originURL = "https://example.test/org/\(index).git"
        repo.branch = "main"; repo.headSHA = "tip"; repo.upstream = "origin/main"
        repo.upstreamSHA = "tip"
        return repo
      }
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
