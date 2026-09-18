import CSQLite
import Foundation

/// Actor-owned incremental cache. Only repository facts are persisted; findings are rebuilt on load.
/// Every checkpoint (including deletions) is one SQLite transaction. The legacy JSON remains a
/// migration source until the first successful checkpoint, and is never rewritten or removed.
final class InventoryCache {
  private struct Key: Hashable { var environment: String; var path: String }
  private struct Record: Equatable { var repo: RepoSnapshot; var position: Int }
  private var savedRepos: [Key: Record] = [:]
  private var savedEnvironments: [String: Data] = [:]
  private var initialized = false
  private var database: Database?
  private var databaseIdentity: String?
  private var schemaReady = false
  private(set) var openedConnections = 0
  var preparedStatements: Int { database?.preparedStatements ?? 0 }
  private func fileIdentity() -> String? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
          let inode = attributes[.systemFileNumber], let device = attributes[.systemNumber] else { return nil }
    return "\(device):\(inode)"
  }
  private let directory: URL
  private let encoder: JSONEncoder = {
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }()
  private(set) var encodedRepositories = 0
  private(set) var freshnessOnlyWrites = 0
  private func facts(_ repo: RepoSnapshot) -> RepoSnapshot {
    var copy = repo
    copy.probedAt = Date(timeIntervalSinceReferenceDate: 0)
    copy.upstreamCheckedAt = nil
    copy.age = nil
    return copy
  }
  // Reference-date seconds preserve Foundation Date precision, including fractional seconds.
  private func freshness(_ repo: RepoSnapshot) throws -> [Database.Value] {
    [.real(repo.probedAt.timeIntervalSinceReferenceDate),
     repo.upstreamCheckedAt.map { .real($0.timeIntervalSinceReferenceDate) } ?? .null,
     try repo.age.map { .blob(try JSONEncoder().encode($0)) } ?? .null]
  }
  private(set) var examinedRepositories = 0
  init(directory: URL) { self.directory = directory }
  private var url: URL { directory.appendingPathComponent("inventory.sqlite") }

  private struct EnvironmentRecord: Codable {
    var snapshot: EnvironmentSnapshot
    var position: Int
  }
  func load() throws -> [EnvironmentSnapshot]? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    // Opening read/write lets SQLite roll back a hot journal after an interrupted checkpoint.
    let db = try Database(url: url, writable: true)
    try db.execute("BEGIN")
    defer { try? db.execute("COMMIT") }
    // A file left by an interrupted first initialization is not a committed inventory.
    let version = try db.scalar("PRAGMA user_version")
    guard version == "1" || version == "2" || version == "3" else {
      if version == "0" { return nil }
      throw RepobotError.message("Unsupported inventory cache version")
    }
    guard try db.scalar("SELECT value FROM metadata WHERE key = 'complete'") == "1" else { return nil }
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    var records: [EnvironmentRecord] = []
    try db.rows("SELECT data FROM environments") { row in
      records.append(try decoder.decode(EnvironmentRecord.self, from: row.blob(0)))
    }
    records.sort { $0.position < $1.position }
    var repositories: [String: [RepoSnapshot]] = [:]
    let columns = version == "1" ? "" : ", probed_at, upstream_checked_at" + (version == "3" ? ", age_data" : "")
    try db.rows("SELECT environment, data\(columns) FROM repositories ORDER BY position") { row in
      var repo = try decoder.decode(RepoSnapshot.self, from: row.blob(1))
      if version != "1" {
        guard let probedAt = row.real(2) else { throw RepobotError.message("Inventory cache is missing repository freshness") }
        repo.probedAt = Date(timeIntervalSinceReferenceDate: probedAt)
        repo.upstreamCheckedAt = row.real(3).map { Date(timeIntervalSinceReferenceDate: $0) }
        if version == "3", !row.blob(4).isEmpty {
          repo.age = try JSONDecoder().decode(RepositoryAge.self, from: row.blob(4))
        }
      }
      repositories[row.string(0), default: []].append(repo)
    }
    return records.map { record in
      var snapshot = record.snapshot
      snapshot.repos = SnapshotList(repositories[snapshot.id.uuidString] ?? [])
      return snapshot
    }
  }

  /// Returns false when no stored facts changed. Cached baselines advance only after COMMIT.
  @discardableResult func save(_ snapshots: [EnvironmentSnapshot], changes delta: RepositoryChanges? = nil) throws -> Bool {
    if database != nil && databaseIdentity != fileIdentity() {
      // Never keep writing to an unlinked/replaced SQLite inode.
      database = nil; databaseIdentity = nil; schemaReady = false
      initialized = false; savedRepos = [:]; savedEnvironments = [:]
    }
    var environments: [String: Data] = [:]
    var repos: [Key: Record] = [:]
    var removedRepos = Set<Key>()
    let full = !initialized || delta == nil
    for (position, snapshot) in snapshots.enumerated() {
      let id = snapshot.id.uuidString
      var metadata = snapshot; metadata.repos = []
      // Progress is transient and must not be restored as if a probe were still running.
      metadata.checkProgress = nil
      environments[id] = try encoder.encode(EnvironmentRecord(snapshot: metadata, position: position))
      if full {
        for (index, repo) in snapshot.repos.enumerated() {
          repos[Key(environment: id, path: repo.path)] = Record(repo: repo, position: index)
        }
      }
    }
    if full {
      removedRepos = Set(savedRepos.keys).subtracting(repos.keys)
    } else if let delta {
      for (id, change) in delta {
        let key = Key(environment: id.environment.uuidString, path: id.path)
        if let repo = change.repo { repos[key] = Record(repo: repo, position: change.position) }
        else if savedRepos[key] != nil { removedRepos.insert(key) }
      }
    }
    examinedRepositories += repos.count + removedRepos.count
    let changes = repos.filter { savedRepos[$0.key] != $0.value }
    let environmentChanges = environments.filter { savedEnvironments[$0.key] != $0.value }
    let removedEnvironments = Set(savedEnvironments.keys).subtracting(environments.keys)
    if initialized && changes.isEmpty && environmentChanges.isEmpty && removedRepos.isEmpty && removedEnvironments.isEmpty {
      return false
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    if !FileManager.default.fileExists(atPath: url.path) {
      guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
        throw RepobotError.message("Could not create inventory cache")
      }
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    if database == nil {
      database = try Database(url: url, writable: true)
      databaseIdentity = fileIdentity(); openedConnections += 1
    }
    let db = database!
    let version = schemaReady ? "3" : try db.scalar("PRAGMA user_version")
    if !schemaReady {
      guard version == "0" || version == "1" || version == "2" || version == "3" else { throw RepobotError.message("Unsupported inventory cache version") }
      try db.execute("PRAGMA journal_mode=DELETE")
      try db.execute("PRAGMA synchronous=FULL")
    }
    try db.execute("BEGIN IMMEDIATE")
    var committed = false
    defer { if !committed { try? db.execute("ROLLBACK") } }
    if !schemaReady {
      try db.execute("CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
      try db.execute("CREATE TABLE IF NOT EXISTS environments (id TEXT PRIMARY KEY, data BLOB NOT NULL)")
      try db.execute("CREATE TABLE IF NOT EXISTS repositories (environment TEXT NOT NULL, path TEXT NOT NULL, position INTEGER NOT NULL, data BLOB NOT NULL, probed_at REAL NOT NULL, upstream_checked_at REAL, age_data BLOB, PRIMARY KEY(environment, path))")
      if version == "1" {
        // The first checkpoint below replaces the complete inventory in this same transaction.
        // A failed migration rolls back both schema and data; v1 remains readable until commit.
        try db.execute("ALTER TABLE repositories ADD COLUMN probed_at REAL")
        try db.execute("ALTER TABLE repositories ADD COLUMN upstream_checked_at REAL")
      }
      if version == "1" || version == "2" {
        try db.execute("ALTER TABLE repositories ADD COLUMN age_data BLOB")
      }
    }
    if !initialized {
      // Replace an older process's snapshot atomically on our first checkpoint.
      try db.execute("DELETE FROM repositories")
      try db.execute("DELETE FROM environments")
    }
    for key in removedRepos {
      try db.execute("DELETE FROM repositories WHERE environment=? AND path=?", [.text(key.environment), .text(key.path)])
    }
    for id in removedEnvironments { try db.execute("DELETE FROM environments WHERE id=?", [.text(id)]) }
    for (id, data) in environmentChanges {
      try db.execute("INSERT INTO environments VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET data=excluded.data", [.text(id), .blob(data)])
    }
    var encoded = 0, freshnessWrites = 0
    for (key, record) in changes {
      let payload = facts(record.repo)
      if let previous = savedRepos[key], facts(previous.repo) == payload {
        // Position and observation times are small scalar updates, even when a repo is unchanged.
        try db.execute("UPDATE repositories SET position=?, probed_at=?, upstream_checked_at=?, age_data=? WHERE environment=? AND path=?",
          [.integer(record.position)] + (try freshness(record.repo)) + [.text(key.environment), .text(key.path)])
        freshnessWrites += 1
      } else {
        let data = try encoder.encode(payload)
        try db.execute("INSERT INTO repositories (environment, path, position, data, probed_at, upstream_checked_at, age_data) VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT(environment, path) DO UPDATE SET position=excluded.position, data=excluded.data, probed_at=excluded.probed_at, upstream_checked_at=excluded.upstream_checked_at, age_data=excluded.age_data",
          [.text(key.environment), .text(key.path), .integer(record.position), .blob(data)] + (try freshness(record.repo)))
        encoded += 1
      }
    }
    if !initialized {
      try db.execute("INSERT OR REPLACE INTO metadata VALUES ('complete', '1')")
      try db.execute("PRAGMA user_version=3")
    }
    try db.execute("COMMIT")
    committed = true; schemaReady = true
    for key in removedRepos { savedRepos[key] = nil }
    for (key, record) in changes { savedRepos[key] = record }
    savedEnvironments = environments; initialized = true
    encodedRepositories += encoded; freshnessOnlyWrites += freshnessWrites
    return true
  }
}

/// Small synchronous SQLite wrapper; each connection stays on the calling actor/thread.
private final class Database {
  private var handle: OpaquePointer?
  private var statements: [String: OpaquePointer] = [:]
  private(set) var preparedStatements = 0
  enum Value { case text(String), blob(Data), integer(Int), real(Double), null }
  init(url: URL, writable: Bool) throws {
    let flags = writable ? SQLITE_OPEN_READWRITE : SQLITE_OPEN_READONLY
    let result = sqlite3_open_v2(url.path, &handle, flags | SQLITE_OPEN_FULLMUTEX, nil)
    guard result == SQLITE_OK else {
      let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Could not open inventory cache"
      if let handle { sqlite3_close(handle) }; handle = nil
      throw RepobotError.message(message)
    }
    sqlite3_busy_timeout(handle, 1000)
  }
  deinit {
    for statement in statements.values { sqlite3_finalize(statement) }
    if let handle { sqlite3_close(handle) }
  }
  struct Row {
    let statement: OpaquePointer
    func string(_ column: Int32) -> String {
      guard let text = sqlite3_column_text(statement, column) else { return "" }
      return String(cString: text)
    }
    func real(_ column: Int32) -> Double? {
      sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : sqlite3_column_double(statement, column)
    }
    func blob(_ column: Int32) -> Data {
      let size = Int(sqlite3_column_bytes(statement, column))
      guard let bytes = sqlite3_column_blob(statement, column) else { return Data() }
      return Data(bytes: bytes, count: size)
    }
  }
  func execute(_ sql: String, _ values: [Value] = []) throws { try rows(sql, values) { _ in } }
  func scalar(_ sql: String) throws -> String? {
    var result: String?
    try rows(sql) { result = $0.string(0) }
    return result
  }
  func rows(_ sql: String, _ values: [Value] = [], body: (Row) throws -> Void) throws {
    let statement: OpaquePointer
    if let cached = statements[sql] { statement = cached }
    else {
      var prepared: OpaquePointer?
      guard sqlite3_prepare_v2(handle, sql, -1, &prepared, nil) == SQLITE_OK, let prepared else { throw failure() }
      statement = prepared; statements[sql] = statement; preparedStatements += 1
    }
    defer { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    for (offset, value) in values.enumerated() {
      let index = Int32(offset + 1)
      let result: Int32
      switch value {
      case .text(let text): result = sqlite3_bind_text(statement, index, text, -1, transient)
      case .integer(let integer): result = sqlite3_bind_int64(statement, index, Int64(integer))
      case .real(let value): result = sqlite3_bind_double(statement, index, value)
      case .null: result = sqlite3_bind_null(statement, index)
      case .blob(let data):
        result = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), transient) }
      }
      guard result == SQLITE_OK else { throw failure() }
    }
    while true {
      let result = sqlite3_step(statement)
      if result == SQLITE_DONE { return }
      guard result == SQLITE_ROW else { throw failure() }
      try body(Row(statement: statement))
    }
  }
  private func failure() -> RepobotError {
    .message("Inventory cache: " + String(cString: sqlite3_errmsg(handle)))
  }
}
