import Foundation
import Observation
import RepobotCore

struct RepositoryMapMachine {
  var name: String
  var unavailable: Bool
  static let unknown = Self(name: "Unknown machine", unavailable: false)
}

@MainActor @Observable final class RepositoryMapRow: Identifiable {
  struct Content: Equatable {
    var repo: RepoSnapshot
    var status: RepoStatus
    var environmentName: String
    var unavailable: Bool
    var unverified: Bool
  }
  let id: String
  @ObservationIgnored private(set) var clone: Clone
  private(set) var content: Content
  private(set) var checkedAt: Date
  var groupID: String { clone.status.identity }
  init(_ clone: Clone, machine: RepositoryMapMachine) {
    id = clone.id; self.clone = clone
    content = Self.content(clone, machine: machine)
    checkedAt = clone.repo.probedAt
  }
  private static func content(_ clone: Clone, machine: RepositoryMapMachine) -> Content {
    var repo = clone.repo
    // Freshness has its own observed value; a fresh check need not redraw the whole row.
    repo.probedAt = .distantPast; repo.upstreamCheckedAt = nil
    repo.probeFingerprint = nil
    return Content(repo: repo, status: clone.status,
                   environmentName: machine.name,
                   unavailable: machine.unavailable || repo.error != nil,
                   unverified: machine.unavailable || repo.error != nil || repo.awaitingFreshCheck == true)
  }
  @discardableResult func update(_ clone: Clone, machine: RepositoryMapMachine, semanticChange: Bool) -> Bool {
    self.clone = clone
    if checkedAt != clone.repo.probedAt { checkedAt = clone.repo.probedAt }
    guard semanticChange else { return false }
    let next = Self.content(clone, machine: machine)
    guard next != content else { return false }
    content = next
    return true
  }
}

@MainActor @Observable final class RepositoryMapGroup: Identifiable {
  let id: String
  private(set) var rows: [RepositoryMapRow] = []
  private(set) var title = ""
  private(set) var severity: Severity = .ok
  private(set) var machineCount = 0
  private(set) var summary = ""
  init(id: String) { self.id = id }
  func setRows(_ next: [RepositoryMapRow]) {
    if rows.map(\.id) != next.map(\.id) { rows = next }
  }
  /// Recompute only this upstream group's presentation when one of its copies changes.
  func refresh() {
    let nextSeverity = rows.map { $0.content.status.severity }.max() ?? .ok
    if severity != nextSeverity { severity = nextSeverity }
    let nextCount = Set(rows.map { $0.clone.environmentID }).count
    if machineCount != nextCount { machineCount = nextCount }
    let nextTitle = id.hasPrefix("root:") || id.hasPrefix("unborn:")
      ? rows.first.map { ($0.content.repo.path as NSString).lastPathComponent } ?? id : id
    if title != nextTitle { title = nextTitle }
    let nextSummary = makeSummary()
    if summary != nextSummary { summary = nextSummary }
  }
  private func makeSummary() -> String {
    let current = rows.filter { !$0.content.unverified }
    if rows.contains(where: { $0.content.status.findings.contains { $0.id == "peer-diverged" } }) {
      return "Copies have diverged — review the commits on both machines."
    }
    let dirty = Set(current.filter { $0.content.repo.dirty }.map { $0.content.environmentName }).sorted()
    if !dirty.isEmpty { return "Uncommitted work on " + dirty.joined(separator: ", ") }
    let work = Set(current.filter { !Analyzer.workSignals($0.content.repo).isEmpty }.map { $0.content.environmentName }).sorted()
    if !work.isEmpty { return "Work to review on " + work.joined(separator: ", ") }
    if rows.contains(where: { $0.content.unavailable }) {
      return "Some copies could not be checked — work there is unverified."
    }
    if current.count != rows.count { return "Checking repository copies — some results are still pending." }
    return "No outstanding work detected. Compare branch and commit below."
  }
  func matches(_ search: String) -> Bool {
    search.isEmpty || id.localizedCaseInsensitiveContains(search) || rows.contains {
      $0.content.repo.path.localizedCaseInsensitiveContains(search)
        || $0.content.environmentName.localizedCaseInsensitiveContains(search)
    }
  }
}

@MainActor @Observable final class RepositoryMapProgress {
  struct Message: Identifiable, Equatable {
    var id: UUID
    var text: String
    var warning: Bool
  }
  private(set) var messages: [Message] = []
  func update(_ world: WorldSnapshot) {
    let next = world.environments.compactMap { env -> Message? in
      if let error = env.error {
        return Message(id: env.id, text: "\(env.environment.name): \(error). Its repository data may be out of date.", warning: true)
      }
      if env.checkedAt == nil {
        return Message(id: env.id, text: "\(env.environment.name): \(env.checkProgress ?? "Waiting for the first repository check")", warning: false)
      }
      if let progress = env.checkProgress { return Message(id: env.id, text: "\(env.environment.name): \(progress)", warning: false) }
      return nil
    }
    if next != messages { messages = next }
  }
}

/// Exists only while the map window is open. Views observe rows, progress and list membership
/// independently; no map view observes AppState.world or calls WorldSnapshot.repositories.
@MainActor @Observable final class RepositoryMapModel {
  var search = "" { didSet { if search != oldValue { filter() } } }
  var sharedOnly = false { didSet { if sharedOnly != oldValue { filter() } } }
  let progress = RepositoryMapProgress()
  private(set) var visibleGroups: [RepositoryMapGroup] = []
  @ObservationIgnored private var rows: [String: RepositoryMapRow] = [:]
  @ObservationIgnored private var groups: [String: RepositoryMapGroup] = [:]
  @ObservationIgnored private var ordered: [RepositoryMapGroup] = []
  @ObservationIgnored private var revision: UInt64?
  @ObservationIgnored private var initialized = false
  @ObservationIgnored private var snapshotSource: UUID?
  @ObservationIgnored private var snapshotRevision: UInt64?
  @ObservationIgnored private(set) var visitedRows = 0
  @ObservationIgnored private(set) var groupingCount = 0
  @ObservationIgnored private(set) var sortingCount = 0
  @ObservationIgnored private(set) var filteringCount = 0
  @ObservationIgnored private(set) var refreshedGroups = 0

  func update(_ world: WorldSnapshot) {
    progress.update(world)
    let stamp = world.changes
    if let stamp, stamp.source == snapshotSource, stamp.revision == snapshotRevision { return }
    let changedIndices: [Int]?
    if initialized, let stamp, stamp.source == snapshotSource, let snapshotRevision {
      changedIndices = stamp.changedIndices(since: snapshotRevision)
    } else { changedIndices = nil }
    let incremental = changedIndices != nil
    let machines = Dictionary(uniqueKeysWithValues: world.environments.map {
      ($0.id, RepositoryMapMachine(name: $0.environment.name, unavailable: $0.error != nil))
    })
    let semanticChange = !initialized || world.analysisRevision == nil || world.analysisRevision != revision
    var structuralChange = false
    var dirty = Set<String>()
    var present = Set<String>()
    let candidates = changedIndices.map { $0.map { world.clones[$0] } } ?? Array(world.clones)
    visitedRows += candidates.count
    for clone in candidates {
      let id = clone.id
      let machine = machines[clone.environmentID] ?? .unknown
      present.insert(id)
      if let row = rows[id] {
        let previousGroup = row.groupID
        if row.update(clone, machine: machine, semanticChange: semanticChange) { dirty.insert(clone.status.identity) }
        if previousGroup != clone.status.identity { structuralChange = true; dirty.insert(previousGroup) }
      } else {
        rows[id] = RepositoryMapRow(clone, machine: machine)
        dirty.insert(clone.status.identity); structuralChange = true
      }
    }
    for id in incremental ? Set<String>() : Set(rows.keys).subtracting(present) {
      if let row = rows.removeValue(forKey: id) { dirty.insert(row.groupID) }
      structuralChange = true
    }
    if structuralChange {
      groupingCount += 1
      let membership = Dictionary(grouping: rows.values, by: \.groupID)
      for id in Set(groups.keys).subtracting(membership.keys) { groups[id] = nil }
      for (id, members) in membership {
        let group = groups[id] ?? RepositoryMapGroup(id: id)
        group.setRows(members.sorted {
          $0.clone.repo.path == $1.clone.repo.path ? $0.id < $1.id : $0.clone.repo.path < $1.clone.repo.path
        })
        groups[id] = group
      }
    }
    var sortNeeded = structuralChange
    for id in dirty {
      guard let group = groups[id] else { continue }
      let previousSeverity = group.severity
      group.refresh(); refreshedGroups += 1
      if previousSeverity != group.severity { sortNeeded = true }
    }
    if sortNeeded {
      sortingCount += 1
      ordered = groups.values.sorted {
        if $0.severity != $1.severity { return $0.severity > $1.severity }
        return $0.id.localizedStandardCompare($1.id) == .orderedAscending
      }
    }
    if sortNeeded || (!search.isEmpty && !dirty.isEmpty) { filter() }
    revision = world.analysisRevision; initialized = true
    snapshotSource = stamp?.source; snapshotRevision = stamp?.revision
  }
  private func filter() {
    filteringCount += 1
    let next = ordered.filter { (!sharedOnly || $0.machineCount > 1) && $0.matches(search) }
    if next.map(\.id) != visibleGroups.map(\.id) { visibleGroups = next }
  }
}
