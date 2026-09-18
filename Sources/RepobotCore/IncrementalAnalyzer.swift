import Foundation

/// Reuses each upstream group's findings until one of its inputs or age boundaries changes.
struct IncrementalAnalyzer {
  private typealias ID = RepositoryID
  private struct IdentityInput: Equatable {
    var remote: String?; var root: String
    init(_ repo: RepoSnapshot) {
      remote = repo.trackingRemoteURL ?? repo.originURL
      root = remote?.isEmpty == false ? "" : repo.rootCommit
    }
  }
  private struct Entry {
    var identityInput: IdentityInput
    var group: String
    var repo: RepoSnapshot
    var status: RepoStatus?
  }
  private var entries: [ID: Entry] = [:]
  private var groups: [String: Set<ID>] = [:]
  private var environmentMembers: [UUID: Set<ID>] = [:]
  private struct EnvironmentInput: Equatable { var name: String; var error: String? }
  private var environmentInputs: [UUID: EnvironmentInput] = [:]
  private var environmentOrder: [UUID] = []
  private var positions: [ID: Int] = [:]
  private var clonePositions: [ID: Int] = [:]
  private var world = WorldSnapshot()
  private var initialized = false
  private let source = UUID()
  private var snapshotRevision: UInt64 = 0
  private var changeHistory: [SnapshotChangeStep] = []
  private var historyIndices = 0
  private(set) var examinedRepositories = 0
  private(set) var rebuiltCloneLists = 0
  private var deadlines: [String: Date] = [:]
  private var configuration: Configuration?
  private(set) var revision: UInt64 = 0
  private(set) var analyzedClones = 0
  private(set) var resolvedIdentities = 0
  var nextDeadline: Date? { deadlines.values.min() }

  private func equivalent(_ lhs: RepoSnapshot, _ rhs: RepoSnapshot) -> Bool {
    var a = lhs, b = rhs
    // These are observation times, not evidence of changed repository state.
    a.probedAt = .distantPast; b.probedAt = .distantPast
    a.upstreamCheckedAt = nil; b.upstreamCheckedAt = nil
    a.probeFingerprint = nil; b.probeFingerprint = nil
    return a == b
  }
  mutating func analyze(_ snapshots: [EnvironmentSnapshot], configuration config: Configuration,
                        now: Date = Date(), changes: RepositoryChanges? = nil) -> WorldSnapshot {
    var dirty = Set(deadlines.filter { $0.value <= now }.keys)
    if configuration != config { dirty.formUnion(groups.keys); configuration = config }
    let environments = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0) })
    let order = snapshots.map(\.id)
    var structural = !initialized || order != environmentOrder
    environmentOrder = order
    // Host availability/name changes affect that host's groups, not unrelated hosts.
    for env in snapshots {
      let input = EnvironmentInput(name: env.environment.name, error: env.error)
      if environmentInputs[env.id] != input {
        for id in environmentMembers[env.id] ?? [] {
          if let entry = entries[id] { dirty.insert(entry.group) }
        }
        environmentInputs[env.id] = input
      }
    }
    var delta: RepositoryChanges
    if let changes, initialized { delta = changes }
    else {
      delta = [:]
      var present = Set<ID>()
      for env in snapshots {
        for (position, repo) in env.repos.enumerated() {
          let id = ID(environment: env.id, path: repo.path)
          present.insert(id)
          delta[id] = RepositoryChange(repo: repo, position: position)
        }
      }
      for id in Set(entries.keys).subtracting(present) {
        delta[id] = RepositoryChange(repo: nil, position: 0)
      }
    }
    examinedRepositories += delta.count
    var affected = Set<ID>()
    for (id, change) in delta {
      guard let repo = change.repo, environments[id.environment] != nil else {
        if let previous = entries.removeValue(forKey: id) {
          groups[previous.group]?.remove(id); dirty.insert(previous.group)
          environmentMembers[id.environment]?.remove(id)
          positions[id] = nil; structural = true
        }
        continue
      }
      affected.insert(id)
      let previous = entries[id]
      let input = IdentityInput(repo)
      let key: String
      if let previous, previous.identityInput == input { key = previous.group }
      else { key = Analyzer.repositoryKey(repo, environmentID: id.environment); resolvedIdentities += 1 }
      if let previous, previous.group != key {
        groups[previous.group]?.remove(id); dirty.insert(previous.group)
      }
      if previous == nil || previous?.group != key || !equivalent(previous!.repo, repo) { dirty.insert(key) }
      if previous == nil || previous?.group != key { groups[key, default: []].insert(id) }
      if previous == nil { environmentMembers[id.environment, default: []].insert(id) }
      if positions[id] != change.position { structural = true; positions[id] = change.position }
      entries[id] = Entry(identityInput: input, group: key, repo: repo, status: previous?.status)
    }
    for key in dirty {
      deadlines[key] = nil
      guard let ids = groups[key], !ids.isEmpty else { groups[key] = nil; continue }
      affected.formUnion(ids)
      let members = Dictionary(grouping: ids, by: \.environment)
      var subset: [EnvironmentSnapshot] = []
      var identities: [UUID: [String: String]] = [:]
      for env in snapshots {
        guard let members = members[env.id] else { continue }
        let repos = members.sorted { positions[$0, default: 0] < positions[$1, default: 0] }
          .compactMap { entries[$0]?.repo }
        var copy = env; copy.repos = SnapshotList(repos); subset.append(copy)
        identities[env.id] = Dictionary(uniqueKeysWithValues: repos.map { ($0.path, key) })
      }
      let result = Analyzer.analyze(subset, configuration: config, now: now, identities: identities)
      analyzedClones += result.clones.count
      for clone in result.clones {
        let id = ID(environment: clone.environmentID, path: clone.repo.path)
        entries[id]?.status = clone.status
        if let date = nextChange(clone, configuration: config, now: now) {
          deadlines[key] = min(deadlines[key] ?? .distantFuture, date)
        }
      }
    }
    if !dirty.isEmpty { revision &+= 1 }
    world.environments = snapshots; world.generatedAt = now; world.analysisRevision = revision
    if structural {
      rebuiltCloneLists += 1
      world.clones = []; clonePositions = [:]
      for env in snapshots {
        for repo in env.repos {
          let id = ID(environment: env.id, path: repo.path)
          if let status = entries[id]?.status {
            clonePositions[id] = world.clones.count
            world.clones.append(Clone(environmentID: env.id, repo: repo, status: status))
          }
        }
      }
    } else {
      for id in affected {
        if let index = clonePositions[id], let entry = entries[id], let status = entry.status {
          world.clones[index] = Clone(environmentID: id.environment, repo: entry.repo, status: status)
        }
      }
    }
    let previous = snapshotRevision
    snapshotRevision &+= 1
    let indices = structural ? [] : affected.compactMap { clonePositions[$0] }.sorted()
    if structural { changeHistory.removeAll(); historyIndices = 0 }
    else {
      changeHistory.append(SnapshotChangeStep(previous: previous, revision: snapshotRevision, indices: indices))
      historyIndices += indices.count
      // Bound both tiny-update history and large-update memory, independently of inventory size.
      while changeHistory.count > 64 || historyIndices > 4096 {
        historyIndices -= changeHistory.removeFirst().indices.count
      }
    }
    world.changes = SnapshotChanges(source: source, revision: snapshotRevision, previous: previous,
      structural: structural, indices: indices, history: changeHistory)
    initialized = true
    return world
  }

  func peerMap(for environmentID: UUID, paths: Set<String>? = nil) -> [String: [String]] {
    let ids = paths.map { Set($0.map { ID(environment: environmentID, path: $0) }) }
      ?? environmentMembers[environmentID] ?? []
    var result: [String: [String]] = [:]
    for id in ids {
      guard let entry = entries[id] else { continue }
      result[id.path] = Array(Set((groups[entry.group] ?? []).compactMap { peerID -> String? in
        guard let peer = entries[peerID]?.repo, Analyzer.sameLineOfWork(peer, entry.repo),
              !peer.headSHA.isEmpty, peer.headSHA != entry.repo.headSHA else { return nil }
        return peer.headSHA
      }))
    }
    return result
  }

  private func nextChange(_ clone: Clone, configuration c: Configuration, now: Date) -> Date? {
    if c.ignored.contains(clone.id) { return nil }
    if let until = c.snoozed[clone.id], until > now { return until }
    let r = clone.repo
    var dates: [Date] = []
    func add(_ date: Date) { if date > now { dates.append(date) } }
    func nextAge(_ since: Date) {
      let age = now.timeIntervalSince(since)
      let unit: Double = age < 3600 ? 60 : age < 86400 ? 3600 : 86400
      add(since.addingTimeInterval((floor(max(0, age) / unit) + 1) * unit))
    }
    if r.dirty, let since = r.dirtySince {
      let threshold = since.addingTimeInterval(c.dirtyHours * 3600)
      if threshold > now { add(threshold) } else { nextAge(since) }
    }
    if Analyzer.needsPush(r), let since = r.unpushedSince {
      add(since.addingTimeInterval(c.unpushedHours * 3600))
      if now.timeIntervalSince(since) < 3600 { add(since.addingTimeInterval(3600)) }
      else { nextAge(since) }
    }
    if c.reportStaleBranches {
      for (branch, date) in r.branchCommitDates where branch != r.branch {
        add(date.addingTimeInterval(c.staleBranchDays * 86400))
      }
    }
    return dates.min()
  }
}
