import Foundation
import Testing
@testable import RepobotCore

struct WatcherReuseTests {
  @Test func testCoverageIgnoresOrderingAndRepositoryContent() {
    var first = RepoSnapshot(path: "/repos/one"); first.gitDirectories = ["/repos/one/.git", "/external"]
    var second = RepoSnapshot(path: "/repos/two"); second.gitDirectories = ["/repos/two/.git"]
    let before = WatcherCoverage(roots: ["/repos"], repos: [first, second])
    first.modified = 4; first.probedAt = Date(); first.gitDirectories.reverse()
    #expect(before == WatcherCoverage(roots: ["/repos"], repos: [second, first]))
    second.gitDirectories.append("/new-common")
    #expect(before != WatcherCoverage(roots: ["/repos"], repos: [first, second]))
  }
  @Test func testUnchangedRediscoveryDoesNotRestartLocalWatcher() async throws {
    let helper = CoreTests(), root = try helper.temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    try await helper.repo(root.appendingPathComponent("repo"))
    let environment = Environment(name: "Fixture", kind: .local, roots: [root.path])
    var config = Configuration(); config.environments = [environment]; config.upstreamCheck = .off
    let store = StateStore(configuration: config, persistence: Persistence(directory: root.appendingPathComponent("cache")))
    let monitor = EnvironmentMonitor(environment: environment, configuration: config, store: store)
    await monitor.start()
    for _ in 0..<500 {
      if await store.snapshot(for: environment.id)?.lastCheckFinishedAt != nil { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    let starts = await monitor.watcherStarts
    #expect(starts > 0)
    await monitor.checkNow(rescan: true)
    await monitor.checkNow(rescan: true)
    #expect(await monitor.watcherStarts == starts)
    await monitor.stop()
  }
}
