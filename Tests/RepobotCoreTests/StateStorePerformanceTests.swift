import Foundation
import Testing
@testable import RepobotCore

struct StateStorePerformanceTests {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["REPOBOT_TEST_STATE_PERFORMANCE"] == "1"))
  func testSavedInventoryPublicationBenchmark() async throws {
    let live = Persistence()
    let config = try #require(try live.load(Configuration.self, from: "config.json"))
    let cached = try #require(try live.loadWorld(configuration: config))
    let root = try CoreTests().temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let disk = Persistence(directory: root)
    let store = StateStore(configuration: config, persistence: disk, cached: cached,
                           publicationDelay: .seconds(60), persistenceDelay: .seconds(60))
    var events = await store.stream().makeAsyncIterator()
    let initial = try #require(await events.next())
    let seed = initial.environments
    #expect(!seed.isEmpty)
    let rounds = 20
    var oldSnapshots = seed
    let oldStart = Date()
    for index in 0..<rounds {
      let host = index % oldSnapshots.count
      oldSnapshots[host].checkProgress = "Checking \(index)"
      try disk.save(Analyzer.analyze(oldSnapshots, configuration: config), to: "baseline.json")
      oldSnapshots[host].checkedAt = Date(timeIntervalSince1970: Double(index))
      try disk.save(Analyzer.analyze(oldSnapshots, configuration: config), to: "baseline.json")
    }
    let oldSeconds = Date().timeIntervalSince(oldStart)
    var newSnapshots = seed
    let baselineAnalyses = await store.analysisCount
    let newStart = Date()
    for index in 0..<rounds {
      let host = index % newSnapshots.count
      newSnapshots[host].checkProgress = "Checking \(index)"
      await store.updateProgress(newSnapshots[host].checkProgress, for: newSnapshots[host].id)
      newSnapshots[host].checkedAt = Date(timeIntervalSince1970: Double(index))
      await store.merge(newSnapshots[host])
    }
    await store.flush()
    let newSeconds = Date().timeIntervalSince(newStart)
    let latest = try #require(await events.next())
    #expect(latest.clones.count == initial.clones.count)
    let analyses = await store.analysisCount - baselineAnalyses
    let writes = await store.cacheWriteCount
    #expect(analyses == 1)
    #expect(writes == 1)
    let oldBytes = try Data(contentsOf: root.appendingPathComponent("baseline.json")).count
    let newBytes = try Data(contentsOf: root.appendingPathComponent("inventory.sqlite")).count
    print("Inventory benchmark: \(initial.clones.count) copies, \(rounds) progress/result pairs; old \(rounds * 2) analyses/saves in \(oldSeconds)s; new \(analyses) analyses and \(writes) saves in \(newSeconds)s; cache \(oldBytes) -> \(newBytes) bytes")
  }

  private func snapshot(_ env: Environment, head: String = "initial") -> EnvironmentSnapshot {
    var snapshot = EnvironmentSnapshot(environment: env)
    var repo = RepoSnapshot(path: "/repos/fixture")
    repo.headSHA = head
    repo.branch = "main"
    snapshot.repos = [repo]
    return snapshot
  }

  @Test func testProgressOnlyUpdatesDoNotAnalyzeOrWriteCache() async throws {
    let root = try CoreTests().temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let config = Configuration()
    let env = config.environments[0]
    let store = StateStore(configuration: config, persistence: Persistence(directory: root),
                           publicationDelay: .seconds(60), persistenceDelay: .seconds(60))
    var events = await store.stream().makeAsyncIterator()
    _ = await events.next()
    await store.merge(snapshot(env))
    await store.flush()
    _ = await events.next()
    let analyses = await store.analysisCount
    let writes = await store.cacheWriteCount
    let persisted = try Data(contentsOf: root.appendingPathComponent("inventory.sqlite"))
    for index in 0..<500 { await store.updateProgress("Checking \(index)", for: env.id) }
    await store.flush()
    let latest = await events.next()
    #expect(latest?.environments[0].checkProgress == "Checking 499")
    #expect(latest?.clones[0].repo.headSHA == "initial")
    #expect(await store.analysisCount == analyses)
    #expect(await store.cacheWriteCount == writes)
    #expect(try Data(contentsOf: root.appendingPathComponent("inventory.sqlite")) == persisted)
  }

  @Test func testBurstCoalescesAndFlushPersistsLatestInventoryAndConfiguration() async throws {
    let root = try CoreTests().temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    var config = Configuration()
    let env = config.environments[0]
    let persistence = Persistence(directory: root)
    let store = StateStore(configuration: config, persistence: persistence,
                           publicationDelay: .seconds(60), persistenceDelay: .seconds(60))
    var events = await store.stream().makeAsyncIterator()
    _ = await events.next()
    let baseline = await store.analysisCount
    for index in 0..<500 {
      await store.updateProgress("Checking \(index)", for: env.id)
      await store.merge(snapshot(env, head: "tip-\(index)"))
    }
    #expect(await store.analysisCount == baseline)
    #expect(await store.cacheWriteCount == 0)
    await store.flush()
    let latest = await events.next()
    #expect(latest?.clones[0].repo.headSHA == "tip-499")
    #expect(await store.analysisCount == baseline + 1)
    #expect(await store.cacheWriteCount == 1)
    #expect(try persistence.loadWorld(configuration: Configuration())?.clones[0].repo.headSHA == "tip-499")
    await store.flush()
    #expect(await store.cacheWriteCount == 1)
    config.environments = []
    await store.updateConfiguration(config)
    #expect(try persistence.loadWorld(configuration: Configuration())?.clones.isEmpty == true)
  }

  @Test func testSustainedUpdatesHaveBoundedPublicationAndSaveDeadlines() async throws {
    let root = try CoreTests().temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let config = Configuration()
    let env = config.environments[0]
    let store = StateStore(configuration: config, persistence: Persistence(directory: root),
                           publicationDelay: .milliseconds(40), persistenceDelay: .milliseconds(100))
    let events = await store.stream()
    let listener = Task { for await _ in events {} }
    defer { listener.cancel() }
    for index in 0..<40 {
      await store.merge(snapshot(env, head: "tip-\(index)"))
      try await Task.sleep(for: .milliseconds(10))
    }
    // A resetting debounce would save nothing until updates stopped.
    #expect(await store.cacheWriteCount >= 2)
    #expect(await store.cacheWriteCount < 15)
    #expect(await store.publicationCount > 1)
    #expect(await store.publicationCount < 30)
    await store.flush()
    #expect(try Persistence(directory: root).loadWorld(configuration: Configuration())?.clones[0].repo.headSHA == "tip-39")
  }

  @Test func testFailedSaveRetainsDirtyDataForRetry() async throws {
    let root = try CoreTests().temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appendingPathComponent("cache")
    try Data("not a directory".utf8).write(to: destination)
    let config = Configuration()
    let store = StateStore(configuration: config, persistence: Persistence(directory: destination),
                           publicationDelay: .seconds(60), persistenceDelay: .seconds(60))
    await store.merge(snapshot(config.environments[0], head: "latest"))
    await store.flush()
    #expect(await store.persistenceError != nil)
    #expect(await store.cacheWriteCount == 0)
    try FileManager.default.removeItem(at: destination)
    await store.flush()
    #expect(await store.persistenceError == nil)
    #expect(try Persistence(directory: destination).loadWorld(configuration: Configuration())?.clones[0].repo.headSHA == "latest")
  }
}

extension StateStorePerformanceTests {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["REPOBOT_TEST_STATE_PERFORMANCE"] == "1"))
  func testSavedInventoryIncrementalBenchmark() throws {
    let disk = Persistence()
    let config = try #require(try disk.load(Configuration.self, from: "config.json"))
    let cached = try #require(try disk.loadWorld(configuration: config))
    var snapshots = cached.environments.filter { !$0.repos.isEmpty }
    #expect(!snapshots.isEmpty)
    guard !snapshots.isEmpty else { return }
    let now = Date(), rounds = 40
    var inputs: [[EnvironmentSnapshot]] = []
    for index in 0..<rounds {
      let host = index % snapshots.count, repo = index % snapshots[host].repos.count
      // Alternating real changes and timestamp-only observations, each published separately.
      snapshots[host].repos[repo].probedAt = now.addingTimeInterval(Double(index))
      if index % 2 == 0 { snapshots[host].repos[repo].modified += 1 }
      inputs.append(snapshots)
    }
    let fullStart = Date()
    let expected = inputs.map { Analyzer.analyze($0, configuration: config, now: now) }
    let fullTime = Date().timeIntervalSince(fullStart)
    var analyzer = IncrementalAnalyzer()
    _ = analyzer.analyze(cached.environments.filter { !$0.repos.isEmpty }, configuration: config, now: now)
    let initialCount = analyzer.analyzedClones, initialIdentities = analyzer.resolvedIdentities
    let incrementalStart = Date()
    let actual = inputs.map { analyzer.analyze($0, configuration: config, now: now) }
    let incrementalTime = Date().timeIntervalSince(incrementalStart)
    for (a, b) in zip(actual, expected) { #expect(a.clones.map(\.status) == b.clones.map(\.status)) }
    #expect(analyzer.resolvedIdentities == initialIdentities)
    print("Incremental benchmark: \(cached.clones.count) copies, \(rounds) separate publications; full \(cached.clones.count * rounds) clone analyses in \(fullTime)s; incremental \(analyzer.analyzedClones - initialCount) clone analyses in \(incrementalTime)s; additional identity resolutions \(analyzer.resolvedIdentities - initialIdentities)")
  }
}
