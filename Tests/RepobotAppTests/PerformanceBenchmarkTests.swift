import Darwin
import Foundation
import Testing
@testable import RepobotApp
@testable import RepobotCore

/// Fixed synthetic workload; no user inventory, network, Git subprocesses or live cache.
/// Run alone via scripts/benchmark.py; correctness tests never assert noisy timings.
@MainActor struct PerformanceBenchmarkTests {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)
  private func cpu() -> Double {
    var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
      + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
  }
  private func fixture() -> [EnvironmentSnapshot] {
    (0..<3).map { host in
      var environment = RepobotCore.Environment(name: "Host \(host)", kind: .local)
      environment.id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", host + 1))!
      var snapshot = EnvironmentSnapshot(environment: environment)
      snapshot.checkedAt = now
      snapshot.repos = SnapshotList((0..<240).map { index in
        var repo = RepoSnapshot(path: "/benchmark/host-\(host)/repo-\(index)")
        repo.originURL = "https://example.test/org/repo-\(index).git"
        repo.trackingRemoteURL = repo.originURL
        repo.headSHA = String(repeating: "a", count: 40); repo.branch = "main"
        repo.upstream = "origin/main"; repo.upstreamRef = "refs/heads/main"; repo.upstreamSHA = repo.headSHA
        repo.probedAt = now; repo.upstreamCheckedAt = now
        repo.lastCommitSubject = "Fixed benchmark commit"
        repo.localBranches = ["main": repo.headSHA, "feature": repo.headSHA]
        repo.gitDirectories = [repo.path + "/.git"]
        return repo
      })
      return snapshot
    }
  }
  private func report(_ name: String, cpu: Double, wall: Double, rounds: Int, counters: [String: Int]) throws {
    let result: [String: Any] = ["workload": name, "cpu_ms_per_op": cpu * 1000 / Double(rounds),
      "wall_ms_per_op": wall * 1000 / Double(rounds), "operations": rounds, "counters": counters]
    let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    print("REPOBOT_BENCHMARK " + String(decoding: data, as: UTF8.self))
  }
  @Test(.enabled(if: ProcessInfo.processInfo.environment["REPOBOT_BENCHMARK"] == "1"))
  func fixedWorkloads() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("repobot-benchmark-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    var snapshots = fixture(), analyzer = IncrementalAnalyzer()
    let config = Configuration(), model = RepositoryMapModel()
    model.update(analyzer.analyze(snapshots, configuration: config, now: now))
    // Three analysis revisions per delivery reproduces coalesced internal reads and dropped publications.
    func mapStep(_ step: Int) -> WorldSnapshot {
      var world = WorldSnapshot()
      for offset in 0..<3 {
        let index = (step * 3 + offset) % 240
        snapshots[0].repos[index].modified += 1
        let repo = snapshots[0].repos[index]
        world = analyzer.analyze(snapshots, configuration: config, now: now, changes: [
          RepositoryID(environment: snapshots[0].id, path: repo.path): RepositoryChange(repo: repo, position: index)])
      }
      return world
    }
    for step in 0..<10 { model.update(mapStep(step)) }
    let visits = model.visitedRows, rounds = 300
    var mapCPU = 0.0, mapWall = 0.0
    let pipelineCPU = cpu(), pipelineWall = Date()
    for step in 10..<(10 + rounds) {
      let world = mapStep(step)
      let start = cpu(), wall = Date()
      model.update(world)
      mapCPU += cpu() - start; mapWall += Date().timeIntervalSince(wall)
    }
    let totalCPU = cpu() - pipelineCPU, totalWall = Date().timeIntervalSince(pipelineWall)
    #expect(model.visibleGroups.count == 240)
    #expect(model.visibleGroups.flatMap(\.rows).count == 720)
    try report("map_coalesced", cpu: mapCPU, wall: mapWall, rounds: rounds,
               counters: ["visited_rows": model.visitedRows - visits])
    try report("analysis_and_map", cpu: totalCPU, wall: totalWall, rounds: rounds, counters: [:])

    for facts in [false, true] {
      snapshots = fixture()
      let cache = InventoryCache(directory: root.appendingPathComponent(facts ? "facts" : "freshness"))
      try cache.save(snapshots)
      func saveStep(_ step: Int) throws {
        var changes: RepositoryChanges = [:]
        for offset in 0..<4 {
          let index = (step * 4 + offset) % 240
          snapshots[0].repos[index].probedAt = now.addingTimeInterval(Double(step + 1))
          snapshots[0].repos[index].upstreamCheckedAt = now.addingTimeInterval(Double(step + 1))
          if facts { snapshots[0].repos[index].modified += 1 }
          let repo = snapshots[0].repos[index]
          changes[RepositoryID(environment: snapshots[0].id, path: repo.path)] = RepositoryChange(repo: repo, position: index)
        }
        try cache.save(snapshots, changes: changes)
      }
      for step in 0..<10 { try saveStep(step) }
      let encoded = cache.encodedRepositories, examined = cache.examinedRepositories
      let start = cpu(), wall = Date(), rounds = 100
      for step in 10..<(10 + rounds) { try saveStep(step) }
      let elapsedCPU = cpu() - start, elapsedWall = Date().timeIntervalSince(wall)
      #expect(try cache.load()?.flatMap(\.repos) == snapshots.flatMap(\.repos))
      try report(facts ? "persistence_facts" : "persistence_freshness", cpu: elapsedCPU, wall: elapsedWall,
        rounds: rounds, counters: ["encoded_records": cache.encodedRepositories - encoded,
                                  "examined_records": cache.examinedRepositories - examined])
    }
    var paths = RepositoryWatchPaths()
    var repos: [RepoSnapshot] = []
    for index in 0..<240 {
      let directory = root.appendingPathComponent("paths/repo-\(index)/.git")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      var repo = RepoSnapshot(path: directory.deletingLastPathComponent().path)
      repo.gitDirectories = [directory.path]; repos.append(repo)
      paths.update(repo, local: true)
    }
    for repo in repos { paths.update(repo, local: true) }
    let resolutions = paths.resolutions, start = cpu(), wall = Date(), pathRounds = 1000
    for step in 0..<pathRounds {
      for offset in 0..<4 { paths.update(repos[(step * 4 + offset) % repos.count], local: true) }
    }
    let elapsedCPU = cpu() - start, elapsedWall = Date().timeIntervalSince(wall)
    #expect(paths[repos[0].path]?.count == 2)
    try report("watch_paths_unchanged", cpu: elapsedCPU, wall: elapsedWall, rounds: pathRounds,
               counters: ["resolved_paths": paths.resolutions - resolutions])
  }
}
