import Foundation

public struct Persistence: Sendable {
  public static var defaultDirectory: URL {
    if let path = ProcessInfo.processInfo.environment["REPOBOT_SUPPORT_DIRECTORY"], !path.isEmpty {
      return URL(fileURLWithPath: path)
    }
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      "Library/Application Support/Repobot")
  }
  public let directory: URL
  public init(directory: URL = Self.defaultDirectory) { self.directory = directory }
  public func load<T: Decodable>(_ type: T.Type, from name: String) throws -> T? {
    let url = directory.appendingPathComponent(name)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(type, from: Data(contentsOf: url))
  }
  public func loadWorld(configuration: Configuration) throws -> WorldSnapshot? {
    if let snapshots = try InventoryCache(directory: directory).load() {
      return Analyzer.analyze(snapshots, configuration: configuration)
    }
    return try load(WorldSnapshot.self, from: "state.json")
  }
  public func save<T: Encodable>(_ value: T, to name: String, prettyPrinted: Bool = true) throws {
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let encoder = JSONEncoder()
    encoder.outputFormatting = prettyPrinted ? [.prettyPrinted, .sortedKeys] : []
    encoder.dateEncodingStrategy = .iso8601
    let url = directory.appendingPathComponent(name)
    try encoder.encode(value).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
}
public actor StateStore {
  private var snapshots: [UUID: EnvironmentSnapshot] = [:]
  private var positions: [UUID: [String: Int]] = [:]
  private var analysisChanges: RepositoryChanges? = nil
  private var persistenceChanges: RepositoryChanges? = nil
  var examinedAnalysisCount: Int { analyzer.examinedRepositories }
  var examinedPersistenceCount: Int { inventoryCache.examinedRepositories }
  private(set) var mergedRepositoryCount = 0
  private var configuration: Configuration
  private let persistence: Persistence
  private let physicalCacheDirectory: String
  private let inventoryCache: InventoryCache
  var persistedRepositoryCount: Int { inventoryCache.encodedRepositories }
  private var continuations: [UUID: AsyncStream<WorldSnapshot>.Continuation] = [:]
  public private(set) var persistenceError: String?
  private var cachedWorld: WorldSnapshot?
  private var analyzer = IncrementalAnalyzer()
  private var ageTask: Task<Void, Never>?
  private var ageDeadline: Date?
  var analyzedCloneCount: Int { analyzer.analyzedClones }
  var resolvedIdentityCount: Int { analyzer.resolvedIdentities }
  private var analysisDirty = true, cacheDirty = false, publicationPending = false
  private var publicationTask: Task<Void, Never>?, saveTask: Task<Void, Never>?
  private let publicationDelay: Duration, persistenceDelay: Duration
  // Internal counters also let regression tests measure actual work, not wall-clock guesses.
  private(set) var analysisCount = 0, cacheWriteCount = 0, publicationCount = 0
  public init(
    configuration: Configuration, persistence: Persistence = Persistence(),
    cached: WorldSnapshot? = nil, publicationDelay: Duration = .milliseconds(250),
    persistenceDelay: Duration = .seconds(5)
  ) {
    self.configuration = configuration
    self.persistence = persistence
    self.physicalCacheDirectory = LocalWatcher.physicalPath(persistence.directory.path)
    self.inventoryCache = InventoryCache(directory: persistence.directory)
    self.publicationDelay = max(.milliseconds(1), publicationDelay)
    self.persistenceDelay = max(.milliseconds(1), persistenceDelay)
    for snapshot in cached?.environments ?? []
    where configuration.environments.contains(where: { $0.id == snapshot.id }) {
      var snapshot = snapshot
      snapshot.error = nil
      snapshot.mode = "Starting"
      snapshot.reconnecting = false
      snapshot.checkProgress = "Waiting for a fresh check"
      for index in snapshot.repos.indices { snapshot.repos[index].awaitingFreshCheck = true }
      snapshots[snapshot.id] = snapshot
      positions[snapshot.id] = Dictionary(uniqueKeysWithValues: snapshot.repos.enumerated().map { ($0.element.path, $0.offset) })
    }
  }
  public func stream() -> AsyncStream<WorldSnapshot> {
    let id = UUID()
    return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
      continuations[id] = continuation
      continuation.yield(world())
      continuation.onTermination = { @Sendable _ in Task { await self.removeContinuation(id) } }
    }
  }
  private func removeContinuation(_ id: UUID) { continuations[id] = nil }
  public func snapshot(for id: UUID) -> EnvironmentSnapshot? { snapshots[id] }
  public func updateConfiguration(_ value: Configuration) {
    configuration = value
    snapshots = snapshots.filter { id, _ in value.environments.contains { $0.id == id } }
    positions = positions.filter { snapshots[$0.key] != nil }
    analysisChanges = nil; persistenceChanges = nil
    invalidateInventory()
    flush()
  }
  /// Progress is transient UI metadata: no repository analysis or cache write.
  public func updateProgress(_ message: String?, for id: UUID) {
    guard let environment = configuration.environments.first(where: { $0.id == id }) else { return }
    if snapshots[id] == nil { snapshots[id] = EnvironmentSnapshot(environment: environment) }
    guard snapshots[id]?.checkProgress != message else { return }
    snapshots[id]?.checkProgress = message
    if let index = cachedWorld?.environments.firstIndex(where: { $0.id == id }) {
      cachedWorld?.environments[index].checkProgress = message
    }
    schedulePublication()
  }
  /// nil paths reconcile discovery/membership; explicit paths update only a probe batch.
  /// Empty paths publish environment metadata without revisiting repository facts.
  public func merge(_ snapshot: EnvironmentSnapshot, changedPaths: Set<String>? = nil) {
    guard configuration.environments.contains(where: { $0.id == snapshot.id }) else { return }
    let old = snapshots[snapshot.id]
    let oldPositions = positions[snapshot.id] ?? [:]
    var next = snapshot
    var delta: RepositoryChanges = [:]
    if snapshot.error != nil, let old {
      next.repos = old.repos
      next.checkedAt = old.checkedAt
    } else if let changedPaths, let old {
      next.repos = old.repos
      for path in changedPaths {
        // Ordinary probe batches preserve order. Only an unexpected new/moved path
        // needs a lookup and full membership reconciliation.
        guard let index = oldPositions[path], snapshot.repos.indices.contains(index),
              snapshot.repos[index].path == path else {
          merge(snapshot)
          return
        }
        let repo = enriched(snapshot.repos[index], previous: old.repos[index])
        mergedRepositoryCount += 1
        if repo != old.repos[index] {
          next.repos[index] = repo
          delta[RepositoryID(environment: snapshot.id, path: path)] = RepositoryChange(repo: repo, position: index)
        }
      }
    } else {
      var nextPositions: [String: Int] = [:]
      for index in next.repos.indices {
        let path = next.repos[index].path
        let previous = oldPositions[path].flatMap { old?.repos[$0] }
        let repo = enriched(next.repos[index], previous: previous)
        next.repos[index] = repo
        nextPositions[path] = index
        mergedRepositoryCount += 1
        if repo != previous || oldPositions[path] != index {
          delta[RepositoryID(environment: snapshot.id, path: path)] = RepositoryChange(repo: repo, position: index)
        }
      }
      for path in oldPositions.keys where nextPositions[path] == nil {
        delta[RepositoryID(environment: snapshot.id, path: path)] = RepositoryChange(repo: nil, position: 0)
      }
      positions[snapshot.id] = nextPositions
    }
    snapshots[snapshot.id] = next
    analysisChanges?.merge(delta) { _, latest in latest }
    persistenceChanges?.merge(delta) { _, latest in latest }
    invalidateInventory()
  }
  private func enriched(_ input: RepoSnapshot, previous old: RepoSnapshot?) -> RepoSnapshot {
    var repo = input
    if let error = repo.error, var previous = old {
      previous.error = error
      previous.slow = previous.slow || repo.slow
      return previous
    }
    let now = repo.probedAt
    repo.dirtySince = repo.dirty ? old?.dirtySince ?? now : nil
    let sameBranch = old?.branch == repo.branch
    repo.unpushedSince = repo.ahead > 0 ? (sameBranch ? old?.unpushedSince : nil) ?? now : nil
    let sameUpstream = old?.upstream == repo.upstream && old?.originURL == repo.originURL
      && old?.trackingRemoteURL == repo.trackingRemoteURL
    if repo.upstreamCheckedAt == nil && sameUpstream {
      repo.upstreamCheckedAt = old?.upstreamCheckedAt
      repo.upstreamError = old?.upstreamError
      repo.upstreamUnknownSince = old?.upstreamUnknownSince
      repo.upstreamRemoteTip = old?.upstreamRemoteTip
      repo.upstreamRemoteDeleted = old?.upstreamRemoteDeleted ?? false
      repo.upstreamGone = repo.upstreamGone || repo.upstreamRemoteDeleted
    } else if repo.upstreamError != nil {
      repo.upstreamUnknownSince = (sameUpstream ? old?.upstreamUnknownSince : nil) ?? now
    }
    return repo
  }
  public func isCachePath(_ path: String) -> Bool {
    let directory = persistence.directory.path
    return path == directory || path.hasPrefix(directory + "/")
      || path == physicalCacheDirectory || path.hasPrefix(physicalCacheDirectory + "/")
  }
  public func world() -> WorldSnapshot {
    if analysisDirty || cachedWorld == nil || (analyzer.nextDeadline ?? .distantFuture) <= Date() {
      cachedWorld = analyzer.analyze(
        configuration.environments.map { snapshots[$0.id] ?? EnvironmentSnapshot(environment: $0) },
        configuration: configuration, changes: analysisChanges)
      analysisChanges = [:]
      analysisDirty = false
      analysisCount += 1
      scheduleAgeTransition()
    }
    return cachedWorld!
  }
  public func peerMap(for environmentID: UUID, paths: Set<String>? = nil) -> [String: [String]] {
    _ = world()
    return analyzer.peerMap(for: environmentID, paths: paths)
  }
  private func scheduleAgeTransition() {
    let deadline = analyzer.nextDeadline
    guard deadline != ageDeadline else { return }
    ageTask?.cancel()
    ageDeadline = deadline
    guard let deadline else { ageTask = nil; return }
    ageTask = Task { [weak self] in
      do {
        try await Task.sleep(for: .seconds(max(0.001, deadline.timeIntervalSinceNow)))
        await self?.ageTransition()
      } catch {}
    }
  }
  private func ageTransition() {
    guard !Task.isCancelled else { return }
    ageTask = nil
    ageDeadline = nil
    invalidateInventory(persist: false)
  }
  private func invalidateInventory(persist: Bool = true) {
    analysisDirty = true
    schedulePublication()
    if persist { cacheDirty = true; scheduleSave() }
  }
  private func schedulePublication() {
    publicationPending = true
    guard publicationTask == nil else { return }
    let delay = publicationDelay
    publicationTask = Task { [weak self] in
      do {
        try await Task.sleep(for: delay)
        await self?.publishPending(scheduled: true)
      } catch {}
    }
  }
  private func publishPending(scheduled: Bool = false) {
    if scheduled && Task.isCancelled { return }
    publicationTask?.cancel()
    publicationTask = nil
    guard publicationPending else { return }
    publicationPending = false
    guard !continuations.isEmpty else { return }
    let value = world()
    publicationCount += 1
    for continuation in continuations.values { continuation.yield(value) }
  }
  private func scheduleSave() {
    guard saveTask == nil else { return }
    let delay = persistenceDelay
    // First-change deadline, not a debounce: continuous checks cannot starve saves.
    saveTask = Task { [weak self] in
      do {
        try await Task.sleep(for: delay)
        await self?.savePending(scheduled: true)
      } catch {}
    }
  }
  private func savePending(scheduled: Bool = false) {
    if scheduled && Task.isCancelled { return }
    saveTask?.cancel()
    saveTask = nil
    guard cacheDirty else { return }
    let previousError = persistenceError
    do {
      let values = configuration.environments.map { snapshots[$0.id] ?? EnvironmentSnapshot(environment: $0) }
      if try inventoryCache.save(values, changes: persistenceChanges) { cacheWriteCount += 1 }
      cacheDirty = false
      persistenceChanges = [:]
      persistenceError = nil
    } catch {
      persistenceError = error.localizedDescription
      scheduleSave()
    }
    if previousError != persistenceError {
      schedulePublication()
      publishPending()
    }
  }
  /// Commit the latest results on sweep completion, reconfiguration and shutdown.
  public func flush() {
    publishPending()
    savePending()
  }

}
public enum NotificationTransitions {
  public static func changed(
    from old: WorldSnapshot, to new: WorldSnapshot, configuration c: Configuration,
    now: Date = Date()
  ) -> [UUID: [Clone]] {
    guard c.notifications, c.enabled else { return [:] }
    let hour = Calendar.current.component(.hour, from: now)
    if c.quietHours
      && (c.quietStart == c.quietEnd
        || (c.quietStart < c.quietEnd
          ? hour >= c.quietStart && hour < c.quietEnd : hour >= c.quietStart || hour < c.quietEnd))
    {
      return [:]
    }
    let previous = Dictionary(uniqueKeysWithValues: old.clones.map { ($0.id, $0.status.severity) })
    let changes = new.attention.filter { clone in
      guard !new.isUnverified(clone) else {
        return false
      }
      return clone.status.severity > (previous[clone.id] ?? .ok)
        && (clone.status.severity == .problem ? c.notifyProblem : c.notifyAttention)
    }
    return Dictionary(grouping: changes, by: \.environmentID)
  }
}
