import Foundation

/// Incremental badge counts and severity transitions share the map's revision history.
/// Retained severities survive source changes so reconnects do not repeat notifications.
public struct AttentionTracker {
  private var severities: [String: Severity] = [:]
  private var source: UUID?, revision: UInt64?, analysisRevision: UInt64?
  public private(set) var count = 0
  public private(set) var visitedClones = 0
  public init() {}
  public mutating func update(_ world: WorldSnapshot) -> [Clone] {
    let stamp = world.changes
    if let stamp, stamp.source == source, stamp.revision == revision { return [] }
    let sameSource = stamp != nil && stamp?.source == source
    let indices = sameSource ? revision.flatMap { stamp?.changedIndices(since: $0) } : nil
    defer { source = stamp?.source; revision = stamp?.revision; analysisRevision = world.analysisRevision }
    if indices != nil, let analysisRevision, world.analysisRevision == analysisRevision { return [] }
    let candidates = indices.map { $0.map { world.clones[$0] } } ?? Array(world.clones)
    visitedClones += candidates.count
    var next: [String: Severity] = [:], nextCount = 0
    var increased: [Clone] = []
    for clone in candidates {
      let id = clone.id, severity = clone.status.severity
      let old = severities[id] ?? .ok
      if severity >= .attention && severity > old { increased.append(clone) }
      if indices == nil {
        next[id] = severity
        if severity >= .attention { nextCount += 1 }
      } else {
        if old >= .attention { count -= 1 }
        if severity >= .attention { count += 1 }
        severities[id] = severity
      }
    }
    if indices == nil { severities = next; count = nextCount }
    return increased.sorted {
      $0.status.severity == $1.status.severity ? $0.repo.path < $1.repo.path : $0.status.severity > $1.status.severity
    }
  }
}
