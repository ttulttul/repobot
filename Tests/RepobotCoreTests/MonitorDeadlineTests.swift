import Foundation
import Testing
@testable import RepobotCore

struct MonitorDeadlineTests {
  let now = Date(timeIntervalSince1970: 1_800_000_000)
  private func next(busy: Bool = false, events: Bool = true, remote: Bool = false,
                    retryWatcher: Double = 20, retrySweep: Double = -1,
                    heartbeat: Double = 0, battery: Bool = false) -> Date? {
    MonitorDeadline.next(now: now, busy: busy, events: events, remote: remote,
      canRetryWatcher: true, swept: now, upstream: now,
      retrySweep: now.addingTimeInterval(retrySweep), retryWatcher: now.addingTimeInterval(retryWatcher),
      heartbeat: now.addingTimeInterval(heartbeat), interval: events ? 300 : 120,
      upstreamInterval: 300, batteryAware: battery)
  }
  @Test func testIdleEventMonitorSleepsUntilSafetySweep() {
    #expect(next() == now.addingTimeInterval(300))
    #expect(next(busy: true) == nil)
  }
  @Test func testHeartbeatRetryAndPowerDeadlines() {
    #expect(next(remote: true) == now.addingTimeInterval(65))
    #expect(next(busy: true, remote: true, heartbeat: -60) == now.addingTimeInterval(5))
    #expect(next(remote: true, heartbeat: 30) == now.addingTimeInterval(95))
    #expect(next(events: false) == now.addingTimeInterval(20))
    #expect(next(events: false, retryWatcher: 400, battery: true) == now.addingTimeInterval(60))
    #expect(next(events: false, retryWatcher: 400) == now.addingTimeInterval(120))
    #expect(next(retrySweep: 600) == now.addingTimeInterval(600))
  }
  @Test func testRunningMonitorDoesNotWakeEverySecondAndStopCancelsDeadline() async throws {
    let root = try CoreTests().temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    var env = Environment.local; env.roots = [root.path]; env.watchMode = .poll
    var config = Configuration(); config.environments = [env]; config.upstreamCheck = .off
    config.batteryAware = false
    let store = StateStore(configuration: config, persistence: Persistence(directory: root.appendingPathComponent("cache")))
    let monitor = EnvironmentMonitor(environment: env, configuration: config, store: store)
    await monitor.start()
    for _ in 0..<100 {
      if await store.snapshot(for: env.id)?.lastCheckFinishedAt != nil { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    let finished = try #require(await store.snapshot(for: env.id)?.lastCheckFinishedAt)
    #expect(await monitor.scheduledDeadline?.timeIntervalSince(finished) ?? 0 >= 59)
    let firings = await monitor.timerFirings
    try await Task.sleep(for: .milliseconds(1200))
    #expect(await monitor.timerFirings == firings)
    await monitor.stop()
    #expect(await monitor.scheduledDeadline == nil)
  }
}
