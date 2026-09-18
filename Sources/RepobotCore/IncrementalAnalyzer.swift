import Foundation

/// Reuses each upstream group's findings until one of its inputs or age boundaries changes.
struct IncrementalAnalyzer {
  private struct ID: Hashable { var environment: UUID; var path: String }
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
    var name: String
    var error: String?
    var status: RepoStatus?
  }
  private var entries: [ID: Entry] = [:]
  private var groups: [String: Set<ID>] = [:]
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
    return a == b
  }
  mutating func analyze(_ snapshots: [EnvironmentSnapshot], configuration config: Configuration,
                        now: Date = Date()) -> WorldSnapshot {
    var dirty = Set(deadlines.filter { $0.value <= now }.keys)
    if configuration != config { dirty.formUnion(groups.keys); configuration = config }
    var present = Set<ID>()
    for env in snapshots {
      for repo in env.repos {
        let id = ID(environment: env.id, path: repo.path)
        present.insert(id)
        let previous = entries[id]
        let input = IdentityInput(repo)
        let key: String
        if let previous, previous.identityInput == input { key = previous.group }
        else { key = Analyzer.repositoryKey(repo, environmentID: env.id); resolvedIdentities += 1 }
        if let previous, previous.group != key {
          groups[previous.group]?.remove(id); dirty.insert(previous.group)
        }
        if previous == nil || previous?.group != key || previous?.name != env.environment.name
          || previous?.error != env.error || !equivalent(previous!.repo, repo) {
          dirty.insert(key)
        }
        groups[key, default: []].insert(id)
        entries[id] = Entry(identityInput: input, group: key, repo: repo,
                            name: env.environment.name, error: env.error, status: previous?.status)
      }
    }
    for id in Set(entries.keys).subtracting(present) {
      if let old = entries.removeValue(forKey: id) {
        groups[old.group]?.remove(id); dirty.insert(old.group)
      }
    }
    for key in dirty {
      deadlines[key] = nil
      guard let ids = groups[key], !ids.isEmpty else { groups[key] = nil; continue }
      var subset: [EnvironmentSnapshot] = []
      var identities: [UUID: [String: String]] = [:]
      for env in snapshots {
        let repos = env.repos.filter { ids.contains(ID(environment: env.id, path: $0.path)) }
        guard !repos.isEmpty else { continue }
        var copy = env; copy.repos = repos; subset.append(copy)
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
    var world = WorldSnapshot()
    world.environments = snapshots; world.generatedAt = now; world.analysisRevision = revision
    for env in snapshots {
      for repo in env.repos {
        let id = ID(environment: env.id, path: repo.path)
        if let status = entries[id]?.status {
          world.clones.append(Clone(environmentID: env.id, repo: repo, status: status))
        }
      }
    }
    return world
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
