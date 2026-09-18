import Darwin
import Foundation
import Testing
@testable import RepobotCore

/// Explicit opt-in: reads saved inventory, benchmarks encoders in memory, and registers
/// a temporary local watcher. Does not probe repositories or change the app's cache.
@Suite(.serialized)
struct PerformanceDiagnosticsTests {
  private func cpuSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
      + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
  }
  @Test(.enabled(if: ProcessInfo.processInfo.environment["REPOBOT_TEST_DIAGNOSTICS"] == "1"))
  func testCacheEncodingCPU() throws {
    let world = try #require(try Persistence().loadWorld(configuration: Configuration()))
    let json = JSONEncoder(); json.dateEncodingStrategy = .iso8601
    let plist = PropertyListEncoder(); plist.outputFormat = .binary
    let rounds = 30
    func measure(_ label: String, encode: () throws -> Data) throws {
      _ = try encode() // warm encoder/runtime metadata
      let start = cpuSeconds()
      var bytes = 0
      for _ in 0..<rounds { bytes = try encode().count }
      let milliseconds = (cpuSeconds() - start) * 1000 / Double(rounds)
      print("Cache diagnostic: \(label), \(bytes) bytes, \(milliseconds) ms CPU/encode")
    }
    print("Cache diagnostic inventory: \(world.clones.count) repository copies")
    try measure("current full-world JSON") { try json.encode(world) }
    try measure("environment-only JSON") { try json.encode(world.environments) }
    try measure("environment-only binary plist") { try plist.encode(world.environments) }
    let batch = world.environments.flatMap(\.repos).prefix(4)
    // Serialization only: excludes indexing, transaction management and disk writes.
    try measure("four changed repository records JSON") { try json.encode(Array(batch)) }
  }
  @Test(.enabled(if: ProcessInfo.processInfo.environment["REPOBOT_TEST_DIAGNOSTICS"] == "1"))
  func testConfiguredLocalWatcherRegistration() async throws {
    let world = try #require(try Persistence().loadWorld(configuration: Configuration()))
    let local = try #require(world.environments.first { $0.environment.kind == .local })
    let roots = local.environment.roots + local.repos.map(\.path) + local.repos.flatMap(\.gitDirectories)
    let watcher = try LocalWatcher(roots: roots) { _ in }
    print("Watcher diagnostic: registered \(roots.count) configured/inventory paths successfully in test process")
    watcher.stop()
  }
}

extension PerformanceDiagnosticsTests {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["REPOBOT_TEST_DIAGNOSTICS"] == "1"))
  func testIncrementalPersistenceCPU() throws {
    let config = try Persistence().load(Configuration.self, from: "config.json") ?? Configuration()
    let cached = try #require(try Persistence().loadWorld(configuration: config))
    let root = try CoreTests().temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let disk = Persistence(directory: root), cache = InventoryCache(directory: root)
    var snapshots = cached.environments
    let host = try #require(snapshots.firstIndex { $0.repos.count >= 4 })
    try cache.save(snapshots)
    let initial = cache.encodedRepositories
    var baselineCPU = 0.0, incrementalCPU = 0.0
    let rounds = 30
    for index in 0..<rounds {
      for offset in 0..<4 {
        let repo = (index * 4 + offset) % snapshots[host].repos.count
        snapshots[host].repos[repo].modified += 1
        snapshots[host].repos[repo].probedAt = Date(timeIntervalSince1970: Double(1_800_000_000 + index))
      }
      let fullWorld = Analyzer.analyze(snapshots, configuration: config)
      var start = cpuSeconds()
      try disk.save(fullWorld, to: "baseline.json", prettyPrinted: false)
      baselineCPU += cpuSeconds() - start
      start = cpuSeconds()
      try cache.save(snapshots)
      incrementalCPU += cpuSeconds() - start
    }
    let loaded = try #require(try cache.load())
    #expect(loaded.flatMap(\.repos) == snapshots.flatMap(\.repos))
    #expect(cache.encodedRepositories - initial == rounds * 4)
    print("Persistence checkpoint benchmark: \(cached.clones.count) copies; \(rounds) four-record updates; full JSON \(baselineCPU * 1000 / Double(rounds)) ms CPU/checkpoint; transactional incremental \(incrementalCPU * 1000 / Double(rounds)) ms CPU/checkpoint; encoded records \(cache.encodedRepositories - initial)")
  }
}
