import Foundation

public enum WatchMode: String, Codable, Sendable, CaseIterable { case auto, events, poll }
public enum UpstreamCheck: String, Codable, Sendable, CaseIterable { case lsRemote, fetch, off }
public enum Severity: Int, Codable, Sendable, Comparable {
  case ok, info, attention, problem
  public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}
public enum Operation: String, Codable, Sendable {
  case none, merge, rebase
  case cherryPick = "cherry-pick"
  case revert, bisect
}
public struct Capabilities: Codable, Sendable {
  public var os = "", architecture = "", gitVersion = "", home = ""
  public var python = false, inotifywait = false, fswatch = false
  public var maxWatches = 8192
  public var suggestedRoots: [String] = []
  public init() {}
}
public struct Environment: Identifiable, Codable, Sendable, Equatable {
  public enum Kind: String, Codable, Sendable { case local, ssh }
  public var id = UUID()
  public var name: String
  public var kind: Kind
  public var host = "", user = ""
  public var port: Int? = nil
  public var tailscaleNodeID: String? = nil
  public var identityFile: String? = nil
  public var roots: [String]
  public var watchMode: WatchMode = .auto
  public var pollInterval: Double? = nil
  public var upstreamCheck: UpstreamCheck? = nil
  public var capabilities: Capabilities? = nil
  public init(name: String, kind: Kind, roots: [String] = []) {
    self.name = name
    self.kind = kind
    self.roots = roots
  }
  public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
  public static var local: Self { Self(name: "This Mac", kind: .local, roots: ["~/git"]) }
}
public struct RepoSnapshot: Codable, Sendable, Identifiable, Equatable {
  public var id: String { path }
  public var path: String
  public var headSHA = "", branch: String? = nil, detached = false
  public var upstream: String? = nil, upstreamSHA: String? = nil
  public var ahead = 0, behind = 0, upstreamGone = false
  public var staged = 0, modified = 0, untracked = 0, conflicted = 0
  public var operation: Operation = .none
  public var stashCount = 0, detachedCommits = 0
  public var originURL: String? = nil, rootCommit = ""
  public var trackingRemoteURL: String? = nil, upstreamRef: String? = nil
  // Complete list of commits above the cached upstream, only when the probe can bound it.
  public var localCommitSHAs: [String]? = nil
  public var branchWork: [BranchWork]? = nil
  public var shallow: Bool? = nil
  public var lastCommitDate = Date(timeIntervalSince1970: 0), lastCommitSubject = ""
  public var localBranches: [String: String] = [:]
  public var branchCommitDates: [String: Date] = [:]
  public var staleLock = false, slow = false
  public var age: RepositoryAge? = nil
  public var probedAt = Date()
  public var probeFingerprint: String? = nil
  var reusedProbeFacts: Bool? = nil
  public var changedPaths: [String] = []
  public var gitDirectories: [String] = []
  public var error: String? = nil
  // Cached data remains unverified until this repository has been probed this session.
  public var awaitingFreshCheck: Bool? = nil
  public var upstreamRemoteTip: String? = nil, upstreamError: String? = nil
  public var upstreamRemoteDeleted = false
  public var upstreamCheckedAt: Date? = nil, upstreamUnknownSince: Date? = nil
  public var dirtySince: Date? = nil, unpushedSince: Date? = nil
  public var ancestry: [String: Ancestry] = [:]
  public var dirty: Bool { staged + modified + untracked + conflicted > 0 }
  public init(path: String) { self.path = path }
}
public struct BranchWork: Codable, Sendable, Equatable {
  public var name: String
  public var upstream: String?
  public var ahead: Int
  public var behind: Int
}
public struct RepositoryGroup: Identifiable, Sendable {
  public var id: String
  public var clones: [Clone]
  public var severity: Severity { clones.map(\.status.severity).max() ?? .ok }
}
public struct Ancestry: Codable, Sendable, Equatable {
  public var relation: String
  public var ahead: Int
  public var behind: Int
  public init(relation: String, ahead: Int = 0, behind: Int = 0) {
    self.relation = relation
    self.ahead = ahead
    self.behind = behind
  }
}
public struct Finding: Identifiable, Codable, Sendable, Equatable {
  public var id: String
  public var severity: Severity
  public var text: String
  public var command: String?
  public init(_ id: String, _ severity: Severity, _ text: String, _ command: String? = nil) {
    self.id = id
    self.severity = severity
    self.text = text
    self.command = command
  }
}
public struct PeerRelation: Identifiable, Codable, Sendable, Equatable {
  public var id: String
  public var environmentName: String
  public var path: String
  public var branch: String?
  public var tip: String
  public var text: String
  public var lastActivity: Date
}
public struct RepoStatus: Codable, Sendable, Equatable {
  public var identity: String
  public var severity: Severity
  public var findings: [Finding]
  public var peers: [PeerRelation]
}
public struct Clone: Identifiable, Codable, Sendable {
  public var id: String { "\(environmentID.uuidString):\(repo.path)" }
  public var environmentID: UUID
  public var repo: RepoSnapshot
  public var status: RepoStatus
}
public struct WatcherFailure: Codable, Sendable {
  public var message: String
  public var occurredAt: Date
  public var recoveredAt: Date?
  public init(message: String, occurredAt: Date = Date()) {
    self.message = String(message.prefix(2000)); self.occurredAt = occurredAt
  }
}
public struct EnvironmentSnapshot: Identifiable, Codable, Sendable {
  public var id: UUID { environment.id }
  public var environment: Environment
  public var repos: SnapshotList<RepoSnapshot> = []
  public var checkedAt: Date? = nil
  public var error: String? = nil
  public var mode = "Starting"
  public var reconnecting = false
  public var checkProgress: String? = nil
  public var watcherFailure: WatcherFailure? = nil
  public var watcherCoverageWarning: String? = nil
  public var watchUsage: WatchUsage? = nil
  public var lastCheckReason: String? = nil
  public var lastCheckStartedAt: Date? = nil
  public var lastCheckFinishedAt: Date? = nil
  public init(environment: Environment) { self.environment = environment }
}
/// Bounded revision history lets independently buffered consumers catch up without scanning
/// the inventory. A structural change or an expired history still requires reconciliation.
public struct SnapshotChangeStep: Codable, Sendable {
  public var previous: UInt64
  public var revision: UInt64
  public var indices: [Int]
}
public struct SnapshotChanges: Codable, Sendable {
  public var source: UUID
  public var revision: UInt64
  public var previous: UInt64
  public var structural: Bool
  public var indices: [Int]
  public var history: [SnapshotChangeStep]? = nil

  /// Nil means the caller must reconcile; an empty array means no repository changes.
  public func changedIndices(since base: UInt64) -> [Int]? {
    guard !structural, base < revision else { return nil }
    if base == previous { return indices }
    guard let history, let start = history.firstIndex(where: { $0.previous == base }) else { return nil }
    var expected = base, changed = Set<Int>()
    for step in history[start...] {
      guard step.previous == expected else { return nil }
      changed.formUnion(step.indices); expected = step.revision
    }
    return expected == revision ? changed.sorted() : nil
  }
}
public struct WorldSnapshot: Codable, Sendable {
  public var environments: [EnvironmentSnapshot] = []
  public var clones: SnapshotList<Clone> = []
  public var generatedAt = Date()
  public var analysisRevision: UInt64? = nil
  public var changes: SnapshotChanges? = nil
  public init() {}
  public var repositories: [RepositoryGroup] {
    Dictionary(grouping: clones, by: { $0.status.identity }).map {
      RepositoryGroup(id: $0.key, clones: $0.value.sorted { $0.repo.path < $1.repo.path })
    }.sorted {
      if $0.severity != $1.severity { return $0.severity > $1.severity }
      return $0.id.localizedStandardCompare($1.id) == .orderedAscending
    }
  }
  public func isUnavailable(_ clone: Clone) -> Bool {
    clone.repo.error != nil || environments.first(where: { $0.id == clone.environmentID })?.error != nil
  }
  public func isUnverified(_ clone: Clone) -> Bool {
    isUnavailable(clone) || clone.repo.awaitingFreshCheck == true
  }
  public var attention: [Clone] {
    clones.filter { $0.status.severity >= .attention }.sorted {
      if $0.status.severity != $1.status.severity { return $0.status.severity > $1.status.severity }
      return $0.repo.path < $1.repo.path
    }
  }
}
/// Reported by the Linux watcher: where its inotify watches went.
public struct WatchUsage: Codable, Sendable, Equatable {
  public struct Tree: Codable, Sendable, Equatable {
    public var path: String, directories: Int
  }
  public struct Repository: Codable, Sendable, Equatable, Identifiable {
    public var id: String { path }
    public var path: String
    public var watches: Int, wanted: Int
    /// Topmost untracked, not ignored directories and the watches each accounts for.
    public var untracked: [Tree]
    public var untrackedWatches: Int { untracked.reduce(0) { $0 + $1.directories } }
  }
  public var total: Int, limit: Int
  /// Repositories without recent Git activity: Git state is watched, the working tree is not.
  public var dormant: Int
  public var repos: [Repository]
  /// Worth offering a .gitignore fix: many watches, mostly spent on untracked trees.
  public var fixable: [Repository] {
    repos.filter { $0.untrackedWatches >= 100 && $0.untrackedWatches * 2 >= $0.wanted }
  }
}
public struct Configuration: Codable, Sendable, Equatable {
  public var version = 1
  public var environments: [Environment] = [.local]
  public var pollInterval: Double = 60, safetyInterval: Double = 300, upstreamInterval: Double = 300
  public var upstreamCheck: UpstreamCheck = .lsRemote
  public var dirtyHours: Double = 4, unpushedHours: Double = 24
  public var enabled = true, notifications = false, notifyAttention = true, notifyProblem = true
  public var quietStart = 22, quietEnd = 8, quietHours = true
  public var ignored: Set<String> = [], disabledFindings: Set<String> = []
  public var snoozed: [String: Date] = [:]
  public var sshPath = "/usr/bin/ssh", extraSSHOptions: [String] = []
  public var debugLogging = false, batteryAware = false
  public var reportStaleBranches = false
  public var staleBranchDays: Double = 90
  // Optional so configurations saved before these existed still load.
  public var watchActiveDays: Double? = nil
  public var watchSkipNames: [String]? = nil
  public static let defaultWatchActiveDays: Double = 30
  public static let defaultWatchSkipNames = [
    "node_modules", ".venv", "venv", "env", "site-packages", "vendor", "target", "build", "dist",
    ".gradle", "__pycache__", ".tox", ".mypy_cache", ".pytest_cache", ".next", ".cache",
  ]
  /// Repositories without Git activity for this many days get no working-tree watches. 0 watches all.
  public var effectiveWatchActiveDays: Double { max(0, watchActiveDays ?? Self.defaultWatchActiveDays) }
  /// Untracked directories with these names are never watched.
  public var effectiveWatchSkipNames: [String] { watchSkipNames ?? Self.defaultWatchSkipNames }
  public static func normalizedSkipNames(_ text: String) -> [String] {
    var seen = Set<String>()
    return text.split(whereSeparator: { $0.isNewline || $0 == "," })
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty && !$0.contains("/") && $0 != "." && $0 != ".." && seen.insert($0).inserted }
  }
  public init() {}
  public mutating func validate() {
    pollInterval = max(10, pollInterval)
    safetyInterval = max(30, safetyInterval)
    upstreamInterval = max(60, upstreamInterval)
    dirtyHours = max(0, dirtyHours)
    staleBranchDays = max(1, staleBranchDays)
    unpushedHours = max(0, unpushedHours)
    quietStart = min(23, max(0, quietStart))
    quietEnd = min(23, max(0, quietEnd))
  }
}
