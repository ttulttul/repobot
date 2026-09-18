import Foundation

public enum Probe {
  public static func capabilities(using transport: any Transport) async throws -> Capabilities {
    let result = try await transport.run(
      script: Scripts.load("capabilities.sh"), arguments: [], timeout: 20)
    guard result.status == 0 else { throw RepobotError.message(result.errorText) }
    let fields = tokens(result.stdout)
    var c = Capabilities()
    for i in stride(from: 0, to: fields.count - 1, by: 2) {
      let value = fields[i + 1]
      switch fields[i] {
      case "OS": c.os = value
      case "ARCH": c.architecture = value
      case "GIT": c.gitVersion = value
      case "HOME": c.home = value
      case "PYTHON": c.python = true
      case "INOTIFY": c.inotifywait = true
      case "FSWATCH": c.fswatch = true
      case "MAX": c.maxWatches = Int(value) ?? 8192
      case "ROOT": c.suggestedRoots.append(value)
      default: break
      }
    }
    guard !c.gitVersion.isEmpty else {
      throw RepobotError.message("Connected, but git is not installed on this host")
    }
    return c
  }
  public static func discover(roots: [String], using transport: any Transport) async throws
    -> [String]
  {
    var paths = Set<String>()
    for root in roots {
      let result = try await transport.run(
        script: Scripts.load("discover.sh"), arguments: [root], timeout: 60)
      guard result.status == 0 else { throw RepobotError.message(result.errorText) }
      paths.formUnion(tokens(result.stdout).prefix(500))
    }
    return paths.sorted()
  }
  public static func repos(
    _ paths: [String], peers: [String] = [], peerMap: [String: [String]]? = nil,
    upstream: UpstreamCheck = .off, using transport: any Transport
  ) async throws -> [RepoSnapshot] {
    guard !paths.isEmpty else { return [] }
    if upstream != .off {
      let local = try await repos(paths, peers: peers, peerMap: peerMap, using: transport)
      return try await checkUpstreams(local, peers: peers, peerMap: peerMap, method: upstream, using: transport)
    }
    let result = try await transport.run(
      script: Scripts.load("probe.sh"),
      arguments: [upstream.rawValue]
        + paths.flatMap { [$0, (peerMap?[$0] ?? peers).joined(separator: " ")] },
      timeout: max(30, Double(paths.count) * 24))
    guard result.status == 0 else {
      throw RepobotError.message(
        result.errorText.isEmpty ? "Probe exited with status \(result.status)" : result.errorText)
    }
    let repos = try parse(result.stdout)
    guard repos.count == paths.count else {
      throw RepobotError.message("Incomplete probe response")
    }
    return repos
  }
  /// Refresh only server evidence. Local status remains valid until a watcher or sweep refreshes it.
  public static func checkUpstreams(
    _ local: [RepoSnapshot], peers: [String] = [], peerMap: [String: [String]]? = nil,
    method: UpstreamCheck, using transport: any Transport
  ) async throws -> [RepoSnapshot] {
    guard method != .off, !local.isEmpty else { return local }
    let result = try await transport.run(
      script: Scripts.load("upstream.sh"),
      arguments: [method.rawValue] + local.flatMap { [$0.path, ""] },
      timeout: max(30, Double(local.count) * 24))
    guard result.status == 0 else {
      throw RepobotError.message(result.errorText.isEmpty
        ? "Upstream probe exited with status \(result.status)" : result.errorText)
    }
    let fresh = try parse(result.stdout)
    guard fresh.map(\.path) == local.map(\.path) else {
      throw RepobotError.message("Incomplete upstream probe response")
    }
    func sameCheckout(_ a: RepoSnapshot, _ b: RepoSnapshot) -> Bool {
      a.headSHA == b.headSHA && a.branch == b.branch && a.detached == b.detached
        && a.upstream == b.upstream && a.upstreamRef == b.upstreamRef
        && a.trackingRemoteURL == b.trackingRemoteURL
    }
    // Fetch changes local refs; a concurrent branch switch also invalidates the old local facts.
    let refreshPaths = zip(local, fresh).filter { old, new in
      new.error == nil && ((!sameCheckout(old, new)) || (method == .fetch && new.upstreamCheckedAt != nil && new.upstreamError == nil))
    }.map { $0.0.path }
    let refreshed = try await repos(refreshPaths, peers: peers, peerMap: peerMap, using: transport)
    let byPath = Dictionary(uniqueKeysWithValues: refreshed.map { ($0.path, $0) })
    return zip(local, fresh).map { old, new in
      var repo = byPath[old.path] ?? old
      if let error = new.error { repo.error = error; return repo }
      guard sameCheckout(repo, new) else {
        repo.upstreamCheckedAt = new.probedAt
        repo.upstreamError = "Repository changed during the upstream check; check again"
        repo.upstreamUnknownSince = new.probedAt
        repo.upstreamRemoteTip = nil
        repo.upstreamRemoteDeleted = false
        return repo
      }
      repo.upstreamCheckedAt = new.upstreamCheckedAt
      repo.upstreamError = new.upstreamError
      repo.upstreamUnknownSince = new.upstreamError == nil ? nil : old.upstreamUnknownSince ?? new.upstreamUnknownSince
      repo.upstreamRemoteTip = new.upstreamRemoteTip
      repo.upstreamRemoteDeleted = new.upstreamRemoteDeleted
      repo.upstreamGone = new.upstreamRemoteDeleted || (repo.upstream != nil && repo.upstreamSHA == nil)
      return repo
    }
  }
  static func tokens(_ data: Data) -> [String] {
    var result = data.split(separator: 0, omittingEmptySubsequences: false).map {
      String(decoding: $0, as: UTF8.self)
    }
    if result.last == "" { result.removeLast() }
    return result
  }
  private static func redactedRemote(_ value: String) -> String? {
    guard !value.isEmpty else { return nil }
    if var url = URLComponents(string: value), url.scheme != nil, url.host != nil {
      url.user = nil
      url.password = nil
      url.query = nil
      url.fragment = nil
      return url.string
    }
    return value
  }
  public static func parse(_ data: Data, now: Date = Date()) throws -> [RepoSnapshot] {
    let fields = tokens(data)
    var index = 0
    var output: [RepoSnapshot] = []
    var repo: RepoSnapshot?
    func take(_ count: Int) throws -> [String] {
      guard index + count <= fields.count else {
        throw RepobotError.message("Truncated probe response")
      }
      defer { index += count }
      return Array(fields[index..<index + count])
    }
    while index < fields.count {
      let key = try take(1)[0]
      if key == "REPO" {
        guard repo == nil else { throw RepobotError.message("Nested probe record") }
        repo = RepoSnapshot(path: try take(1)[0])
        repo?.probedAt = now
        continue
      }
      guard var r = repo else { throw RepobotError.message("Probe field outside repository") }
      switch key {
      case "HEAD":
        let v = try take(3)
        r.headSHA = v[0] == "(initial)" ? "" : v[0]
        r.detached = v[2] == "1"
        r.branch = r.detached ? nil : v[1]
      case "COUNTS":
        let v = try take(6).map { Int($0) ?? 0 }
        r.ahead = v[0]
        r.behind = v[1]
        r.staged = v[2]
        r.modified = v[3]
        r.untracked = v[4]
        r.conflicted = v[5]
      case "UPSTREAM":
        let v = try take(3)
        r.upstream = v[0].isEmpty ? nil : v[0]
        r.upstreamSHA = v[1].isEmpty ? nil : v[1]
        r.upstreamGone = v[2] == "1"
      case "OP": r.operation = Operation(rawValue: try take(1)[0]) ?? .none
      case "STASH": r.stashCount = Int(try take(1)[0]) ?? 0
      case "ORIGIN": r.originURL = redactedRemote(try take(1)[0])
      case "TRACKING":
        let v = try take(2)
        r.trackingRemoteURL = redactedRemote(v[0])
        r.upstreamRef = v[1].isEmpty ? nil : v[1]
      case "LOCALCOMMITS":
        r.localCommitSHAs = try take(1)[0].split(whereSeparator: { $0.isWhitespace }).map(String.init)
      case "BRANCHWORK":
        let v = try take(4)
        if r.branchWork == nil { r.branchWork = [] }
        r.branchWork?.append(BranchWork(
          name: v[0], upstream: v[1].isEmpty ? nil : v[1],
          ahead: Int(v[2]) ?? 0, behind: Int(v[3]) ?? 0))
      case "SHALLOW": r.shallow = try take(1)[0] == "true"
      case "ROOT": r.rootCommit = try take(1)[0]
      case "LAST":
        let v = try take(2)
        r.lastCommitDate = Date(timeIntervalSince1970: Double(v[0]) ?? 0)
        r.lastCommitSubject = v[1]
      case "BRANCH":
        let v = try take(2)
        r.localBranches[v[0]] = v[1]
      case "BRANCHDATE":
        let v = try take(2)
        r.branchCommitDates[v[0]] = Date(timeIntervalSince1970: Double(v[1]) ?? 0)
      case "LOCK": r.staleLock = try take(1)[0] == "1"
      case "DETACHED": r.detachedCommits = Int(try take(1)[0]) ?? 0
      case "PATH": r.changedPaths.append(try take(1)[0])
      case "GITDIR": r.gitDirectories.append(try take(1)[0])
      case "ERR": r.error = try take(1)[0]
      case "SLOW": r.slow = (Double(try take(1)[0]) ?? 0) > 10
      case "PEER":
        let v = try take(4)
        r.ancestry[v[0]] = Ancestry(relation: v[1], ahead: Int(v[2]) ?? 0, behind: Int(v[3]) ?? 0)
      case "FRESH":
        let v = try take(2)
        r.upstreamCheckedAt = now
        if v[0] == "error" {
          r.upstreamError = v[1]
          r.upstreamUnknownSince = now
        } else if v[0] == "deleted" {
          r.upstreamGone = true
          r.upstreamRemoteDeleted = true
        } else if v[0] == "ok" {
          r.upstreamRemoteTip = v[1]
        }
      case "END":
        guard try take(1)[0] == r.path else {
          throw RepobotError.message("Mismatched probe record")
        }
        output.append(r)
        repo = nil
        continue
      default: throw RepobotError.message("Unknown probe field: \(key)")
      }
      repo = r
    }
    guard repo == nil else { throw RepobotError.message("Unterminated probe record") }
    return output
  }
}
