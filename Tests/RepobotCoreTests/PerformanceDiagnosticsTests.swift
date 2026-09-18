import CoreServices
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
    var originalLimit = rlimit(); getrlimit(RLIMIT_NOFILE, &originalLimit)
    // Swift's test runner can raise an inherited soft limit; enforce this inside
    // the opt-in diagnostic to reproduce the GUI budget exactly.
    if let value = ProcessInfo.processInfo.environment["REPOBOT_TEST_FD_LIMIT"], let value = UInt64(value) {
      var requested = originalLimit; requested.rlim_cur = value
      guard setrlimit(RLIMIT_NOFILE, &requested) == 0 else { throw RepobotError.message("Could not set diagnostic descriptor limit") }
    }
    defer { _ = setrlimit(RLIMIT_NOFILE, &originalLimit) }
    var limit = rlimit(); getrlimit(RLIMIT_NOFILE, &limit)
    let descriptorsBefore = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
    errno = 0
    let raw = FSEventStreamCreate(nil, { _, _, _, _, _, _ in }, nil,
      roots.map(expandedPath) as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1,
      FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot))
    let code = errno
    let descriptorsAfter = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
    print("Watcher raw registration: limit \(limit.rlim_cur), success \(raw != nil), errno \(code), descriptors \(descriptorsBefore) -> \(descriptorsAfter)")
    if let raw { FSEventStreamRelease(raw) }
    let watcher = try LocalWatcher(roots: roots) { _ in }
    print("Watcher diagnostic: registered \(roots.count) configured/inventory paths as \(watcher.watchedRoots.count) recursive roots successfully in test process")
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

extension PerformanceDiagnosticsTests {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["REPOBOT_TEST_DIAGNOSTICS"] == "1"))
  func testChangedRecordPipelineCPU() throws {
    let disk = Persistence()
    let config = try #require(try disk.load(Configuration.self, from: "config.json"))
    let cached = try #require(try disk.loadWorld(configuration: config))
    var snapshots = cached.environments
    let root = try CoreTests().temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let scanRoot = root.appendingPathComponent("scan"), deltaRoot = root.appendingPathComponent("delta")
    let scanningCache = InventoryCache(directory: scanRoot), deltaCache = InventoryCache(directory: deltaRoot)
    var scanningAnalyzer = IncrementalAnalyzer(), deltaAnalyzer = IncrementalAnalyzer()
    let now = Date()
    _ = scanningAnalyzer.analyze(snapshots, configuration: config, now: now)
    _ = deltaAnalyzer.analyze(snapshots, configuration: config, now: now)
    try scanningCache.save(snapshots); try deltaCache.save(snapshots)
    let analyzedBefore = deltaAnalyzer.examinedRepositories, persistedBefore = deltaCache.examinedRepositories
    let host = try #require(snapshots.firstIndex { $0.repos.count >= 4 })
    var scanAnalysis = 0.0, deltaAnalysis = 0.0, scanSave = 0.0, deltaSave = 0.0
    let rounds = 30
    for step in 0..<rounds {
      var changes: RepositoryChanges = [:]
      for offset in 0..<4 {
        let index = (step * 4 + offset) % snapshots[host].repos.count
        snapshots[host].repos[index].modified += 1
        snapshots[host].repos[index].probedAt = now
        let repo = snapshots[host].repos[index]
        changes[RepositoryID(environment: snapshots[host].id, path: repo.path)] = RepositoryChange(repo: repo, position: index)
      }
      var start = cpuSeconds()
      let expected = scanningAnalyzer.analyze(snapshots, configuration: config, now: now)
      scanAnalysis += cpuSeconds() - start
      start = cpuSeconds()
      let actual = deltaAnalyzer.analyze(snapshots, configuration: config, now: now, changes: changes)
      deltaAnalysis += cpuSeconds() - start
      #expect(actual.clones.map(\.repo) == expected.clones.map(\.repo))
      #expect(actual.clones.map(\.status) == expected.clones.map(\.status))
      start = cpuSeconds(); try scanningCache.save(snapshots); scanSave += cpuSeconds() - start
      start = cpuSeconds(); try deltaCache.save(snapshots, changes: changes); deltaSave += cpuSeconds() - start
    }
    #expect(deltaAnalyzer.examinedRepositories - analyzedBefore == rounds * 4)
    #expect(deltaCache.examinedRepositories - persistedBefore == rounds * 4)
    #expect(deltaAnalyzer.rebuiltCloneLists == 1)
    #expect(try deltaCache.load()?.flatMap(\.repos) == scanningCache.load()?.flatMap(\.repos))
    let scale = 1000 / Double(rounds)
    print("Changed-record benchmark: \(cached.clones.count) copies, \(rounds) four-record updates; analysis scan \(scanAnalysis * scale) -> delta \(deltaAnalysis * scale) ms CPU/update; persistence scan \(scanSave * scale) -> delta \(deltaSave * scale) ms CPU/checkpoint; examined \(deltaAnalyzer.examinedRepositories - analyzedBefore) analysis and \(deltaCache.examinedRepositories - persistedBefore) persistence records; clone-list builds \(deltaAnalyzer.rebuiltCloneLists)")
  }
}
