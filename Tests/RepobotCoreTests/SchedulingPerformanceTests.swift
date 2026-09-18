import Darwin
import Foundation
import Testing
@testable import RepobotCore

struct SchedulingPerformanceTests {
  private func cpu() -> Double {
    var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
  }
  private func report(_ name: String, cpu: Double, wall: Double, rounds: Int, counters: [String: Int]) throws {
    let result: [String: Any] = ["workload": name, "operations": rounds,
      "cpu_ms_per_op": cpu * 1000 / Double(rounds), "wall_ms_per_op": wall * 1000 / Double(rounds), "counters": counters]
    print("REPOBOT_BENCHMARK " + String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
  }
  @Test(.enabled(if: ProcessInfo.processInfo.environment["REPOBOT_SCHEDULING_BENCHMARK"] == "1"))
  func pairedReferenceWorkloads() throws {
    let now = Date(timeIntervalSince1970: 1800000000)
    var env = EnvironmentSnapshot(environment: .local), config = Configuration()
    config.notifications = true; config.quietHours = false
    env.repos = SnapshotList((0..<720).map { index in
      var repo = RepoSnapshot(path: "/repos/\(index)")
      repo.originURL = "https://example.test/repo/\(index)"; repo.probedAt = now
      return repo
    })
    var analyzer = IncrementalAnalyzer(), tracker = AttentionTracker()
    var previous = analyzer.analyze([env], configuration: config, now: now)
    _ = tracker.update(previous)
    var fullCPU = 0.0, fullWall = 0.0, deltaCPU = 0.0, deltaWall = 0.0
    let visits = tracker.visitedClones, rounds = 500
    for step in 0..<(rounds + 10) {
      let index = step % 720
      env.repos[index].behind = 1
      let world = analyzer.analyze([env], configuration: config, now: now, changes: [
        RepositoryID(environment: env.id, path: env.repos[index].path): RepositoryChange(repo: env.repos[index], position: index)])
      var expected: [UUID: [Clone]] = [:], actual: [UUID: [Clone]] = [:], count = 0
      func reference() {
        let start = cpu(), wall = Date()
        expected = NotificationTransitions.changed(from: previous, to: world, configuration: config, now: now)
        count = world.clones.reduce(0) { $0 + ($1.status.severity >= .attention ? 1 : 0) }
        if step >= 10 { fullCPU += cpu() - start; fullWall += Date().timeIntervalSince(wall) }
      }
      func incremental() {
        let start = cpu(), wall = Date()
        actual = NotificationTransitions.eligible(tracker.update(world), in: world, configuration: config, now: now)
        if step >= 10 { deltaCPU += cpu() - start; deltaWall += Date().timeIntervalSince(wall) }
      }
      if step % 2 == 0 { reference(); incremental() } else { incremental(); reference() }
      #expect(actual.mapValues { Set($0.map(\.id)) } == expected.mapValues { Set($0.map(\.id)) })
      #expect(tracker.count == count)
      previous = world
    }
    try report("attention_full_reference", cpu: fullCPU, wall: fullWall, rounds: rounds,
               counters: ["clones_counted": rounds * 720])
    try report("attention_incremental", cpu: deltaCPU, wall: deltaWall, rounds: rounds,
               counters: ["clones_visited": tracker.visitedClones - visits - 10])
    var paths = RepositoryWatchPaths()
    for repo in env.repos { paths.update(repo, local: false) }
    var scanCPU = 0.0, indexedCPU = 0.0, scanWall = 0.0, indexedWall = 0.0
    let events = 10000
    for step in 0..<(events + 10) {
      let event = "/repos/\(step % 720)/src/file.swift"
      var expected = Set<String>(), actual = Set<String>()
      func scan() {
        let start = cpu(), wall = Date()
        expected = Set(env.repos.filter { event == $0.path || event.hasPrefix($0.path + "/") }.map(\.path))
        if step >= 10 { scanCPU += cpu() - start; scanWall += Date().timeIntervalSince(wall) }
      }
      func indexed() {
        let start = cpu(), wall = Date()
        actual = paths.repositories(containing: event)
        if step >= 10 { indexedCPU += cpu() - start; indexedWall += Date().timeIntervalSince(wall) }
      }
      if step % 2 == 0 { scan(); indexed() } else { indexed(); scan() }
      #expect(actual == expected)
    }
    try report("event_scan_reference", cpu: scanCPU, wall: scanWall, rounds: events,
               counters: ["repository_comparisons": events * 720])
    try report("event_indexed", cpu: indexedCPU, wall: indexedWall, rounds: events,
               counters: ["path_lookups": paths.routingLookups - 50])
  }
}
