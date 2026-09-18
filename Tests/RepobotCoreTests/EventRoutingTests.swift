import Foundation
import Testing
@testable import RepobotCore

private final class CapturedEvents: @unchecked Sendable {
  private let lock = NSLock()
  private var events: [WatchEvent] = []
  func receive(_ event: WatchEvent) { lock.withLock { events.append(event) } }
  var value: [WatchEvent] { lock.withLock { events } }
}
struct EventRoutingTests {
  @Test func testIndexedRoutesRespectBoundariesNestedCopiesAndExternalGitDirectories() {
    var cache = RepositoryWatchPaths()
    for path in ["/repos/outer", "/repos/outer/nested", "/repos/other"] {
      var repo = RepoSnapshot(path: path)
      repo.gitDirectories = path.hasSuffix("nested") ? ["/external/vendor/git"] : [path + "/.git"]
      cache.update(repo, local: false)
    }
    #expect(cache.repositories(containing: "/repos/outer/nested/src/file") == ["/repos/outer", "/repos/outer/nested"])
    #expect(cache.repositories(containing: "/external/vendor/git/HEAD") == ["/repos/outer/nested"])
    #expect(!cache.ignores("/external/vendor/git/HEAD", repository: "/repos/outer/nested"))
    #expect(cache.repositories(containing: "/repos/outer-other/file").isEmpty)
    #expect(cache.ignores("/repos/outer/node_modules/file", repository: "/repos/outer"))
    #expect(!cache.ignores("/repos/outer/.git/HEAD", repository: "/repos/outer"))
    #expect(cache.routingLookups < 25)
  }
  @Test func testBurstCoalescesBeforeActorDeliveryAndOverflowRescans() {
    let events = CapturedEvents()
    // Advance each window explicitly; parallel test load must not define burst boundaries.
    let active = WatchEventBatcher(delay: 60) { events.receive($0) }
    active.send(.ready)
    for index in 0..<1000 { active.send(.changed("/repos/\(index % 10)")) }
    active.flush()
    let delivered = events.value.compactMap { event -> [String]? in
      if case .changedPaths(let paths) = event { return paths }; return nil
    }
    #expect(delivered.count == 1 && delivered.first?.count == 10)
    for index in 0..<5000 { active.send(.changed("/overflow/\(index)")) }
    active.flush()
    #expect(events.value.contains { if case .rescan = $0 { return true }; return false })
    active.send(.changed("/after-stop")); active.stop()
    let count = events.value.count
    active.flush()
    #expect(events.value.count == count)
  }
}
