import CSQLite
import Foundation
import Testing
@testable import RepobotCore

struct RepositoryDeltaTests {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)
  private func inventory() -> [EnvironmentSnapshot] {
    (0..<3).map { host in
      var env = EnvironmentSnapshot(environment: Environment(name: "Host \(host)", kind: .local))
      env.checkedAt = now
      env.repos = SnapshotList((0..<80).map { index in
        var repo = RepoSnapshot(path: "/repos/\(index)")
        repo.originURL = "https://example.test/org/\(index).git"
        repo.branch = "main"; repo.headSHA = "tip"; repo.upstream = "origin/main"
        repo.upstreamSHA = "tip"; repo.probedAt = now
        return repo
      })
      return env
    }
  }
  private func compare(_ actual: WorldSnapshot, _ config: Configuration, at time: Date? = nil) {
    let expected = Analyzer.analyze(actual.environments, configuration: config, now: time ?? now)
    #expect(actual.clones.map(\.id) == expected.clones.map(\.id))
    #expect(actual.clones.map(\.repo) == expected.clones.map(\.repo))
    #expect(actual.clones.map(\.status) == expected.clones.map(\.status))
  }

  @Test func testSmallBatchesStaySmallThroughStoreAnalyzerAndPersistence() async throws {
    let root = try CoreTests().temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let disk = Persistence(directory: root)
    var envs = inventory(), config = Configuration()
    config.environments = envs.map(\.environment)
    let store = StateStore(configuration: config, persistence: disk,
                           publicationDelay: .seconds(60), persistenceDelay: .seconds(60))
    for env in envs { await store.merge(env) }
    _ = await store.world(); await store.flush()
    let examined = await store.examinedAnalysisCount
    let persisted = await store.examinedPersistenceCount
    let merged = await store.mergedRepositoryCount
    let analyzed = await store.analyzedCloneCount
    for index in 0..<30 {
      let host = index % 3, repo = index % 80
      envs[host].repos[repo].modified += 1
      envs[host].repos[repo].probedAt = now.addingTimeInterval(Double(index))
      await store.merge(envs[host], changedPaths: [envs[host].repos[repo].path])
      compare(await store.world(), config)
      await store.flush()
    }
    #expect(await store.examinedAnalysisCount - examined == 30)
    #expect(await store.examinedPersistenceCount - persisted == 30)
    #expect(await store.mergedRepositoryCount - merged == 30)
    #expect(await store.analyzedCloneCount - analyzed == 90)
    let beforeMetadata = await store.examinedAnalysisCount
    let beforeSave = await store.examinedPersistenceCount
    envs[0].environment.name = "Renamed"
    envs[0].error = "Offline"
    await store.merge(envs[0], changedPaths: [])
    compare(await store.world(), config)
    await store.flush()
    #expect(await store.examinedAnalysisCount == beforeMetadata)
    #expect(await store.examinedPersistenceCount == beforeSave)
    let saved = try #require(try disk.loadWorld(configuration: config))
    #expect(saved.clones.map(\.repo) == (await store.world()).clones.map(\.repo))
    #expect(saved.environments[0].error == "Offline")
  }

  @Test func testDeltaAnalysisMatchesFullForMovesDeletionOrderingAndAge() {
    var envs = inventory(), config = Configuration(), analyzer = IncrementalAnalyzer()
    config.environments = envs.map(\.environment)
    var result = analyzer.analyze(envs, configuration: config, now: now)
    compare(result, config)
    var expectedExamined = analyzer.examinedRepositories
    for step in 0..<10 {
      let old = envs
      var date = now
      switch step {
      case 0: envs[0].repos[12].modified = 1; envs[0].repos[12].dirtySince = now
      case 1: envs[0].repos[12].probedAt = now.addingTimeInterval(5)
      case 2: envs[0].repos[12].originURL = "https://example.test/fork/12.git"
      case 3: envs[1].repos.remove(at: 12)
      case 4: envs[1].repos.reverse()
      case 5: envs[2].environment.name = "Renamed"; envs[2].error = "Offline"
      case 6: config.dirtyHours = 0
      case 7: date = now.addingTimeInterval(7200)
      case 8: envs.removeLast(); config.environments.removeLast()
      default: envs[0].repos.append(RepoSnapshot(path: "/repos/new"))
      }
      func records(_ values: [EnvironmentSnapshot]) -> RepositoryChanges {
        var result: RepositoryChanges = [:]
        for env in values {
          for (index, repo) in env.repos.enumerated() {
            result[RepositoryID(environment: env.id, path: repo.path)] = RepositoryChange(repo: repo, position: index)
          }
        }
        return result
      }
      let previous = records(old), current = records(envs)
      var delta = current.filter { previous[$0.key]?.repo != $0.value.repo || previous[$0.key]?.position != $0.value.position }
      for id in previous.keys where current[id] == nil { delta[id] = RepositoryChange(repo: nil, position: 0) }
      expectedExamined += delta.count
      result = analyzer.analyze(envs, configuration: config, now: date, changes: delta)
      compare(result, config, at: date)
      #expect(analyzer.examinedRepositories == expectedExamined)
      if step <= 2 { #expect(analyzer.rebuiltCloneLists == 1) }
    }
  }

  @Test func testCoalescedDiscoveryAndConfigurationDeletionPersistLatestOrder() async throws {
    let root = try CoreTests().temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let disk = Persistence(directory: root)
    var envs = inventory(), config = Configuration()
    config.environments = envs.map(\.environment)
    let store = StateStore(configuration: config, persistence: disk,
                           publicationDelay: .seconds(60), persistenceDelay: .seconds(60))
    for env in envs { await store.merge(env) }
    _ = await store.world(); await store.flush()
    envs[0].repos[1].modified = 1
    await store.merge(envs[0], changedPaths: [envs[0].repos[1].path])
    envs[0].repos.remove(at: 1)
    envs[0].repos.reverse()
    await store.merge(envs[0])
    var new = RepoSnapshot(path: "/new"); new.probedAt = now
    envs[0].repos.append(new)
    await store.merge(envs[0])
    let world = await store.world()
    compare(world, config)
    await store.flush()
    #expect(try disk.loadWorld(configuration: config)?.clones.map(\.repo) == world.clones.map(\.repo))
    config.environments.remove(at: 1)
    await store.updateConfiguration(config)
    #expect(try disk.loadWorld(configuration: config)?.environments.count == 2)
    compare(await store.world(), config)
  }

  @Test func testFailedDeltaCheckpointRetriesAllPendingChanges() async throws {
    let root = try CoreTests().temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let disk = Persistence(directory: root)
    var env = inventory()[0], config = Configuration()
    config.environments = [env.environment]
    let store = StateStore(configuration: config, persistence: disk,
                           publicationDelay: .seconds(60), persistenceDelay: .seconds(60))
    await store.merge(env); _ = await store.world(); await store.flush()
    var db: OpaquePointer?
    #expect(sqlite3_open(root.appendingPathComponent("inventory.sqlite").path, &db) == SQLITE_OK)
    defer { sqlite3_close(db) }
    #expect(sqlite3_exec(db, "CREATE TRIGGER fail_update BEFORE INSERT ON repositories BEGIN SELECT RAISE(ABORT, 'fixture'); END", nil, nil, nil) == SQLITE_OK)
    env.repos[1].modified = 1
    await store.merge(env, changedPaths: [env.repos[1].path]); await store.flush()
    #expect(await store.persistenceError != nil)
    #expect(try disk.loadWorld(configuration: config)?.clones[1].repo.modified == 0)
    env.repos[2].modified = 2
    await store.merge(env, changedPaths: [env.repos[2].path])
    #expect(sqlite3_exec(db, "DROP TRIGGER fail_update", nil, nil, nil) == SQLITE_OK)
    await store.flush()
    #expect(await store.persistenceError == nil)
    let loaded = try #require(try disk.loadWorld(configuration: config))
    #expect(loaded.clones[1].repo.modified == 1)
    #expect(loaded.clones[2].repo.modified == 2)
  }
}
