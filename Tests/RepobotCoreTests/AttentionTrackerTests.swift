import Foundation
import Testing
@testable import RepobotCore

struct AttentionTrackerTests {
  @Test func testIncrementalAttentionMatchesFullTransitionsAcrossMissesAndConfigurationChanges() {
    var config = Configuration(); config.notifications = true; config.quietHours = false
    var env = EnvironmentSnapshot(environment: .local)
    env.repos = SnapshotList((0..<100).map { RepoSnapshot(path: "/repos/\($0)") })
    var analyzer = IncrementalAnalyzer(), tracker = AttentionTracker()
    var previous = analyzer.analyze([env], configuration: config)
    _ = tracker.update(previous)
    for step in 0..<80 {
      let index = step % env.repos.count
      env.repos[index].behind = 1
      var world = analyzer.analyze([env], configuration: config, changes: [
        RepositoryID(environment: env.id, path: env.repos[index].path): RepositoryChange(repo: env.repos[index], position: index)])
      if step % 3 != 0 { continue } // publications replaced before the consumer sees them
      let expected = NotificationTransitions.changed(from: previous, to: world, configuration: config)
      let increased = tracker.update(world)
      let actual = NotificationTransitions.eligible(increased, in: world, configuration: config)
      #expect(actual.mapValues { Set($0.map(\.id)) } == expected.mapValues { Set($0.map(\.id)) })
      #expect(tracker.count == world.attention.count)
      let visited = tracker.visitedClones
      world.environments[0].checkProgress = "Progress only"
      #expect(tracker.update(world).isEmpty)
      #expect(tracker.visitedClones == visited)
      previous = world
    }
    #expect(tracker.visitedClones < 300)
    env.repos = SnapshotList(env.repos.dropFirst(20))
    var world = analyzer.analyze([env], configuration: config)
    _ = tracker.update(world)
    #expect(tracker.count == world.attention.count)
    var replacement = IncrementalAnalyzer()
    world = replacement.analyze([env], configuration: config)
    #expect(tracker.update(world).isEmpty) // no duplicate notices after source replacement
    #expect(tracker.count == world.attention.count)
    config.ignored = Set(world.clones.map(\.id))
    world = replacement.analyze([env], configuration: config)
    #expect(tracker.update(world).isEmpty && tracker.count == 0)
  }
  @Test func testUnverifiedQuietAndDisabledNotificationsStillFilterTransitions() {
    var config = Configuration(); config.notifications = true; config.quietHours = false
    var env = EnvironmentSnapshot(environment: .local)
    var repo = RepoSnapshot(path: "/repo"); repo.behind = 2; repo.awaitingFreshCheck = true
    env.repos = [repo]
    var tracker = AttentionTracker()
    let world = Analyzer.analyze([env], configuration: config)
    let increased = tracker.update(world)
    #expect(NotificationTransitions.eligible(increased, in: world, configuration: config).isEmpty)
    env.repos[0].awaitingFreshCheck = false
    let verified = Analyzer.analyze([env], configuration: config)
    #expect(tracker.update(verified).isEmpty)
    config.quietHours = true; config.quietStart = 0; config.quietEnd = 0
    #expect(NotificationTransitions.eligible(increased, in: verified, configuration: config).isEmpty)
    config.quietHours = false; config.notifications = false
    #expect(NotificationTransitions.eligible(increased, in: verified, configuration: config).isEmpty)
  }
}
