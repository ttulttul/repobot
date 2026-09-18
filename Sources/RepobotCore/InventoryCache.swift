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
  private let directory: URL
  private let encoder: JSONEncoder = {
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }()
  private(set) var encodedRepositories = 0
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
    guard try db.scalar("PRAGMA user_version") == "1" else {
      if try db.scalar("PRAGMA user_version") == "0" { return nil }
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
    try db.rows("SELECT environment, data FROM repositories ORDER BY position") { row in
      repositories[row.string(0), default: []].append(try decoder.decode(RepoSnapshot.self, from: row.blob(1)))
    }
    return records.map { record in
      var snapshot = record.snapshot
      snapshot.repos = repositories[snapshot.id.uuidString] ?? []
      return snapshot
    }
  }

  /// Returns false when no stored facts changed. Cached baselines advance only after COMMIT.
  @discardableResult func save(_ snapshots: [EnvironmentSnapshot]) throws -> Bool {
    if initialized && !FileManager.default.fileExists(atPath: url.path) {
      initialized = false; savedRepos = [:]; savedEnvironments = [:]
    }
    var environments: [String: Data] = [:]
    var repos: [Key: Record] = [:]
    for (position, snapshot) in snapshots.enumerated() {
      let id = snapshot.id.uuidString
      var metadata = snapshot; metadata.repos = []
      // Progress is transient and must not be restored as if a probe were still running.
      metadata.checkProgress = nil
      environments[id] = try encoder.encode(EnvironmentRecord(snapshot: metadata, position: position))
      for (index, repo) in snapshot.repos.enumerated() {
        repos[Key(environment: id, path: repo.path)] = Record(repo: repo, position: index)
      }
    }
    let changes = repos.filter { savedRepos[$0.key] != $0.value }
    let environmentChanges = environments.filter { savedEnvironments[$0.key] != $0.value }
    let removedRepos = Set(savedRepos.keys).subtracting(repos.keys)
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
    let db = try Database(url: url, writable: true)
    let version = try db.scalar("PRAGMA user_version")
    guard version == "0" || version == "1" else { throw RepobotError.message("Unsupported inventory cache version") }
    try db.execute("PRAGMA journal_mode=DELETE")
    try db.execute("PRAGMA synchronous=FULL")
    try db.execute("BEGIN IMMEDIATE")
    var committed = false
    defer { if !committed { try? db.execute("ROLLBACK") } }
    try db.execute("CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
    try db.execute("CREATE TABLE IF NOT EXISTS environments (id TEXT PRIMARY KEY, data BLOB NOT NULL)")
    try db.execute("CREATE TABLE IF NOT EXISTS repositories (environment TEXT NOT NULL, path TEXT NOT NULL, position INTEGER NOT NULL, data BLOB NOT NULL, PRIMARY KEY(environment, path))")
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
      try db.execute("INSERT OR REPLACE INTO environments VALUES (?, ?)", [.text(id), .blob(data)])
    }
    for (key, record) in changes {
      let data = try encoder.encode(record.repo)
      try db.execute("INSERT OR REPLACE INTO repositories VALUES (?, ?, ?, ?)",
                     [.text(key.environment), .text(key.path), .integer(record.position), .blob(data)])
    }
    try db.execute("INSERT OR REPLACE INTO metadata VALUES ('complete', '1')")
    try db.execute("PRAGMA user_version=1")
    try db.execute("COMMIT")
    committed = true
    savedRepos = repos; savedEnvironments = environments; initialized = true
    encodedRepositories += changes.count
    return true
  }
}

/// Small synchronous SQLite wrapper; each connection stays on the calling actor/thread.
private final class Database {
  private var handle: OpaquePointer?
  enum Value { case text(String), blob(Data), integer(Int) }
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
  deinit { if let handle { sqlite3_close(handle) } }
  struct Row {
    let statement: OpaquePointer
    func string(_ column: Int32) -> String {
      guard let text = sqlite3_column_text(statement, column) else { return "" }
      return String(cString: text)
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
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
    defer { sqlite3_finalize(statement) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    for (offset, value) in values.enumerated() {
      let index = Int32(offset + 1)
      let result: Int32
      switch value {
      case .text(let text): result = sqlite3_bind_text(statement, index, text, -1, transient)
      case .integer(let integer): result = sqlite3_bind_int64(statement, index, Int64(integer))
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
