import CSQLite
import Foundation
import Testing
@testable import RepobotCore

struct InventoryCacheTests {
  private func fixture(_ count: Int = 20) -> EnvironmentSnapshot {
    var snapshot = EnvironmentSnapshot(environment: .local)
    snapshot.repos = SnapshotList((0..<count).map {
      var repo = RepoSnapshot(path: "/repos/\($0) ' tab\tnewline\n")
      repo.branch = "main"; repo.headSHA = "tip-\($0)"
      repo.probedAt = Date(timeIntervalSince1970: 1000)
      return repo
    })
    return snapshot
  }
  @Test func testIncrementalCheckpointsRoundTripAndDelete() throws {
    let root = try CoreTests().temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = InventoryCache(directory: root)
    var snapshot = fixture()
    #expect(try cache.save([snapshot]))
    #expect(cache.encodedRepositories == 20)
    #expect(try cache.load()?[0].repos == snapshot.repos)
    #expect(try !cache.save([snapshot]))
    snapshot.checkProgress = "Transient progress"
    #expect(try !cache.save([snapshot]))
    snapshot.repos[4].modified = 2
    #expect(try cache.save([snapshot]))
    #expect(cache.encodedRepositories == 21)
    #expect(try cache.load()?[0].repos == snapshot.repos)
    snapshot.environment.name = "Renamed"
    #expect(try cache.save([snapshot]))
    #expect(cache.encodedRepositories == 21)
    #expect(try cache.load()?[0].environment.name == "Renamed")
    snapshot.repos.removeLast()
    #expect(try cache.save([snapshot]))
    #expect(cache.encodedRepositories == 21)
    #expect(try cache.load()?[0].repos == snapshot.repos)
    // Reordering is persisted without losing records or changing their identities.
    snapshot.repos.reverse()
    #expect(try cache.save([snapshot]))
    #expect(try cache.load()?[0].repos == snapshot.repos)
    snapshot.watcherFailure = WatcherFailure(message: "Recorded failure", occurredAt: Date(timeIntervalSince1970: 1000))
    snapshot.watcherFailure?.recoveredAt = Date(timeIntervalSince1970: 1100)
    try cache.save([snapshot])
    #expect(try cache.load()?[0].watcherFailure?.recoveredAt == Date(timeIntervalSince1970: 1100))
    try FileManager.default.removeItem(at: root.appendingPathComponent("inventory.sqlite"))
    #expect(try cache.save([snapshot]))
    #expect(try cache.load()?[0].repos == snapshot.repos)
    #expect(try cache.save([]))
    #expect(try cache.load()?.isEmpty == true)
    let attributes = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("inventory.sqlite").path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
  }
  @Test func testConnectionAndStatementsReusedAcrossDeltaCheckpointsAndFileReplacement() throws {
    let root = try CoreTests().temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = InventoryCache(directory: root)
    var snapshot = fixture()
    try cache.save([snapshot])
    let prepared = cache.preparedStatements
    for index in 1...20 {
      snapshot.repos[4].modified = index
      try cache.save([snapshot], changes: [RepositoryID(environment: snapshot.id, path: snapshot.repos[4].path):
        RepositoryChange(repo: snapshot.repos[4], position: 4)])
    }
    #expect(cache.openedConnections == 1)
    #expect(cache.preparedStatements == prepared)
    #expect(try cache.load()?.first?.repos == snapshot.repos)
    // Atomic replacement with another valid cache must not strand writes on the old inode.
    let replacementRoot = root.appendingPathComponent("replacement")
    try InventoryCache(directory: replacementRoot).save([fixture(1)])
    let destination = root.appendingPathComponent("inventory.sqlite")
    try FileManager.default.removeItem(at: destination)
    try FileManager.default.moveItem(at: replacementRoot.appendingPathComponent("inventory.sqlite"), to: destination)
    snapshot.repos[4].modified = 99
    try cache.save([snapshot], changes: [:])
    #expect(cache.openedConnections == 2)
    #expect(try cache.load()?.first?.repos == snapshot.repos)
  }

  @Test func testLegacyMigrationUsesDatabaseAfterFirstCommit() throws {
    let root = try CoreTests().temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let persistence = Persistence(directory: root)
    var config = Configuration(), snapshot = fixture(2)
    config.environments = [snapshot.environment]
    let legacy = Analyzer.analyze([snapshot], configuration: config)
    try persistence.save(legacy, to: "state.json")
    #expect(try persistence.loadWorld(configuration: config)?.clones.count == 2)
    let original = try Data(contentsOf: root.appendingPathComponent("state.json"))
    let cache = InventoryCache(directory: root)
    snapshot.repos[0].modified = 1
    snapshot.repos[0].dirtySince = Date(timeIntervalSince1970: 1000)
    try cache.save([snapshot])
    let loaded = try #require(try persistence.loadWorld(configuration: config))
    #expect(loaded.clones[0].repo.modified == 1)
    #expect(loaded.clones[0].status.findings.contains { $0.id == "dirty" })
    config.ignored.insert(loaded.clones[0].id)
    #expect(try persistence.loadWorld(configuration: config)?.clones[0].status.findings.isEmpty == true)
    #expect(try Data(contentsOf: root.appendingPathComponent("state.json")) == original)
    // A committed empty database must not resurrect repositories from the legacy file.
    try cache.save([])
    #expect(try persistence.loadWorld(configuration: config)?.clones.isEmpty == true)
  }
  private func sql(_ root: URL, _ command: String) throws {
    var db: OpaquePointer?
    #expect(sqlite3_open(root.appendingPathComponent("inventory.sqlite").path, &db) == SQLITE_OK)
    defer { sqlite3_close(db) }
    guard sqlite3_exec(db, command, nil, nil, nil) == SQLITE_OK else {
      throw RepobotError.message(String(cString: sqlite3_errmsg(db)))
    }
  }
  @Test func testFailedTransactionRetainsPreviousSnapshotAndCanRetry() throws {
    let root = try CoreTests().temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = InventoryCache(directory: root)
    var snapshot = fixture(2)
    try cache.save([snapshot])
    let original = snapshot
    // Fail after the metadata update, while applying a repository update.
    try sql(root, "CREATE TRIGGER fail_update BEFORE INSERT ON repositories BEGIN SELECT RAISE(ABORT, 'simulated write failure'); END")
    snapshot.environment.name = "New name"
    snapshot.repos[0].modified = 3
    #expect(throws: (any Error).self) { try cache.save([snapshot]) }
    #expect(cache.encodedRepositories == 2)
    let afterFailure = try #require(try cache.load()?.first)
    #expect(afterFailure.environment.name == original.environment.name)
    #expect(afterFailure.repos == original.repos)
    try sql(root, "DROP TRIGGER fail_update")
    try cache.save([snapshot])
    #expect(cache.encodedRepositories == 3)
    #expect(try cache.load()?[0].repos == snapshot.repos)
    // Simulates restarting the app with a smaller inventory.
    let restarted = InventoryCache(directory: root)
    snapshot.repos.removeLast()
    try restarted.save([snapshot])
    #expect(try restarted.load()?[0].repos == snapshot.repos)
  }
  @Test func testUncommittedInitializationFallsBackButCorruptionIsReported() throws {
    let root = try CoreTests().temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let persistence = Persistence(directory: root)
    try persistence.save(Analyzer.analyze([fixture(1)], configuration: Configuration()), to: "state.json")
    let file = root.appendingPathComponent("inventory.sqlite")
    try Data().write(to: file)
    #expect(try persistence.loadWorld(configuration: Configuration())?.clones.count == 1)
    try Data("not a database".utf8).write(to: file)
    #expect(throws: (any Error).self) { try persistence.loadWorld(configuration: Configuration()) }
  }
  private func scalar(_ root: URL, _ query: String) throws -> String? {
    var db: OpaquePointer?, statement: OpaquePointer?
    guard sqlite3_open(root.appendingPathComponent("inventory.sqlite").path, &db) == SQLITE_OK else {
      throw RepobotError.message("Test database did not open")
    }
    defer { sqlite3_finalize(statement); sqlite3_close(db) }
    guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
      throw RepobotError.message(String(cString: sqlite3_errmsg(db)))
    }
    guard sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else { return nil }
    return String(cString: value)
  }

  @Test func testFreshnessUpdatesPreservePayloadPrecisionNullsAndRollback() throws {
    let root = try CoreTests().temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = InventoryCache(directory: root)
    var snapshot = fixture(1)
    try cache.save([snapshot])
    let originalPayload = try scalar(root, "SELECT hex(data) FROM repositories")
    let original = snapshot
    snapshot.repos[0].probedAt = Date(timeIntervalSinceReferenceDate: 812345678.123456)
    snapshot.repos[0].upstreamCheckedAt = Date(timeIntervalSinceReferenceDate: 812345678.987654)
    snapshot.environment.name = "Updated metadata"
    try sql(root, "CREATE TRIGGER fail_freshness BEFORE UPDATE OF probed_at ON repositories BEGIN SELECT RAISE(ABORT, 'fixture'); END")
    #expect(throws: (any Error).self) { try cache.save([snapshot]) }
    #expect(cache.freshnessOnlyWrites == 0)
    #expect(try cache.load()?.first?.repos == original.repos)
    #expect(try cache.load()?.first?.environment.name == original.environment.name)
    try sql(root, "DROP TRIGGER fail_freshness")
    try cache.save([snapshot])
    #expect(cache.encodedRepositories == 1)
    #expect(cache.freshnessOnlyWrites == 1)
    #expect(try scalar(root, "SELECT hex(data) FROM repositories") == originalPayload)
    #expect(try cache.load()?.first?.repos == snapshot.repos)
    snapshot.repos[0].upstreamCheckedAt = nil
    try cache.save([snapshot])
    #expect(try cache.load()?.first?.repos == snapshot.repos)
    #expect(cache.encodedRepositories == 1)
    snapshot.repos[0].upstreamError = "Unreachable"
    snapshot.repos[0].upstreamUnknownSince = Date(timeIntervalSince1970: 2000)
    try cache.save([snapshot])
    #expect(cache.encodedRepositories == 2) // Semantic upstream evidence must still update the payload.
    #expect(try cache.load()?.first?.repos == snapshot.repos)
  }

  @Test func testVersionTwoMigrationAndAgeOnlyUpdates() throws {
    let root = try CoreTests().temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    var snapshot = fixture(1)
    let initial = InventoryCache(directory: root)
    try initial.save([snapshot])
    try sql(root, "ALTER TABLE repositories DROP COLUMN age_data; PRAGMA user_version=2;")
    let cache = InventoryCache(directory: root)
    #expect(try cache.load()?.first?.repos == snapshot.repos)
    snapshot.repos[0].age = RepositoryAge(measuredAt: Date(timeIntervalSince1970: 1234.125),
      newestFileDate: Date(timeIntervalSince1970: 1000))
    try cache.save([snapshot])
    #expect(try scalar(root, "PRAGMA user_version") == "3")
    #expect(try cache.load()?.first?.repos == snapshot.repos)
    let originalPayload = try scalar(root, "SELECT hex(data) FROM repositories")
    snapshot.repos[0].age?.measuredAt = Date(timeIntervalSince1970: 1240.375)
    try cache.save([snapshot])
    #expect(cache.encodedRepositories == 1 && cache.freshnessOnlyWrites == 1)
    #expect(try scalar(root, "SELECT hex(data) FROM repositories") == originalPayload)
    #expect(try cache.load()?.first?.repos == snapshot.repos)
  }

  @Test func testVersionOneMigrationIsAtomicAndPreservesInventory() throws {
    let root = try CoreTests().temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    var snapshot = fixture(2)
    snapshot.repos[0].upstreamCheckedAt = Date(timeIntervalSince1970: 999)
    struct LegacyEnvironment: Encodable { var snapshot: EnvironmentSnapshot; var position: Int }
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    func blob<T: Encodable>(_ value: T) throws -> String {
      "X'" + (try encoder.encode(value)).map { String(format: "%02x", $0) }.joined() + "'"
    }
    var metadata = snapshot; metadata.repos = []
    let id = snapshot.id.uuidString
    try sql(root, """
      CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
      CREATE TABLE environments (id TEXT PRIMARY KEY, data BLOB NOT NULL);
      CREATE TABLE repositories (environment TEXT NOT NULL, path TEXT NOT NULL, position INTEGER NOT NULL, data BLOB NOT NULL, PRIMARY KEY(environment, path));
      INSERT INTO metadata VALUES ('complete','1');
      INSERT INTO environments VALUES ('\(id)', \(try blob(LegacyEnvironment(snapshot: metadata, position: 0))));
      PRAGMA user_version=1;
      """)
    for (position, repo) in snapshot.repos.enumerated() {
      try sql(root, "INSERT INTO repositories VALUES ('\(id)', '\(repo.path.replacingOccurrences(of: "'", with: "''"))', \(position), \(try blob(repo)))")
    }
    let cache = InventoryCache(directory: root)
    #expect(try cache.load()?.first?.repos == snapshot.repos)
    try sql(root, "CREATE TRIGGER fail_migration BEFORE INSERT ON repositories BEGIN SELECT RAISE(ABORT, 'fixture'); END")
    #expect(throws: (any Error).self) { try cache.save([snapshot]) }
    #expect(try scalar(root, "PRAGMA user_version") == "1")
    #expect(throws: (any Error).self) { try scalar(root, "SELECT probed_at FROM repositories") }
    #expect(try cache.load()?.first?.repos == snapshot.repos)
    try sql(root, "DROP TRIGGER fail_migration")
    try cache.save([snapshot])
    #expect(try scalar(root, "PRAGMA user_version") == "3")
    #expect(try cache.load()?.first?.repos == snapshot.repos)
    snapshot.repos[0].probedAt = Date(timeIntervalSince1970: 3000)
    try cache.save([snapshot])
    #expect(cache.encodedRepositories == 2)
    #expect(try cache.load()?.first?.repos == snapshot.repos)
  }

  @Test func testInterruptedWriterRecoversPreviousCommittedInventory() async throws {
    let root = try CoreTests().temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = InventoryCache(directory: root)
    let snapshot = fixture(4)
    try cache.save([snapshot])
    let input = """
      PRAGMA cache_size=1;
      PRAGMA synchronous=FULL;
      BEGIN IMMEDIATE;
      UPDATE repositories SET data = data || zeroblob(100000);
      .shell /bin/sleep 60
      """
    do {
      _ = try await ProcessRunner.run("/usr/bin/sqlite3", [root.appendingPathComponent("inventory.sqlite").path],
                                      input: Data(input.utf8), timeout: 0.5)
      Issue.record("Writer unexpectedly completed")
    } catch {
      #expect(error.localizedDescription.contains("timed out"))
    }
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("inventory.sqlite-journal").path))
    let recovered = try InventoryCache(directory: root).load()
    #expect(recovered?.first?.repos == snapshot.repos)
  }

}
