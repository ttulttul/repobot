import Foundation

public enum Analyzer {
  public static func identity(_ repo: RepoSnapshot) -> String {
    guard var origin = repo.trackingRemoteURL ?? repo.originURL, !origin.isEmpty else {
      return repo.rootCommit.isEmpty ? "unborn:\(repo.path)" : "root:\(repo.rootCommit)"
    }
    if !origin.contains("://"), let colon = origin.firstIndex(of: ":"), !origin.hasPrefix("/") {
      origin = "ssh://" + origin[..<colon] + "/" + origin[origin.index(after: colon)...]
    }
    if let url = URLComponents(string: origin), let host = url.host {
      var path = url.path
      while path.hasSuffix("/") { path.removeLast() }
      if path.hasSuffix(".git") { path.removeLast(4) }
      let defaultPort = (url.scheme == "ssh" && url.port == 22)
        || (url.scheme == "https" && url.port == 443) || (url.scheme == "http" && url.port == 80)
      return host.lowercased() + (defaultPort ? "" : url.port.map { ":\($0)" } ?? "") + path
    }
    if origin.hasSuffix(".git") { origin.removeLast(4) }
    return origin
  }
  public static func analyze(
    _ snapshots: [EnvironmentSnapshot], configuration c: Configuration, now: Date = Date(),
    identities: [UUID: [String: String]] = [:]
  ) -> WorldSnapshot {
    var world = WorldSnapshot()
    world.environments = snapshots
    world.generatedAt = now
    // Resolve identities once; incremental updates should not compare every repo
    // against every unrelated repository on every machine.
    let copies = snapshots.flatMap { env in
      env.repos.map { repo in (environment: env, repo: repo, key: identities[env.id]?[repo.path] ?? repositoryKey(repo, environmentID: env.id)) }
    }
    let groups = Dictionary(grouping: copies, by: { $0.key })
    for env in snapshots {
      for repo in env.repos {
        var findings = perClone(repo, environment: env.environment.name, configuration: c, now: now)
        var peers: [PeerRelation] = []
        let key = identities[env.id]?[repo.path] ?? repositoryKey(repo, environmentID: env.id)
        for copy in groups[key] ?? [] {
          let otherEnv = copy.environment
          let other = copy.repo
          if !(env.id == otherEnv.id && repo.path == other.path) {
            let peerID = "\(otherEnv.id):\(other.path)"
            let name = otherEnv.environment.name
            var text = "Comparison pending"
            let stale = env.error != nil || repo.error != nil || otherEnv.error != nil || other.error != nil
              || repo.awaitingFreshCheck == true || other.awaitingFreshCheck == true
            if stale {
              text = "Last known state; comparison unavailable"
            } else if !sameLineOfWork(repo, other) || repo.detached || other.detached {
              text = "On \(other.branch ?? "detached HEAD")"
              findings.append(
                Finding("peer-branch", .info, "\(name) is on \(other.branch ?? "detached HEAD")"))
            } else {
              if repo.headSHA == other.headSHA && !repo.headSHA.isEmpty {
                text = "Same tip"
              } else {
                let comparison = compare(repo, other)
                let relation = comparison.relation
                let behind = comparison.behind
                let ahead = comparison.ahead
                switch relation {
                case "diverged":
                  text = "Diverged: \(ahead) here, \(behind) there"
                  findings.append(
                    Finding(
                      "peer-diverged", .problem,
                      "\(repo.branch ?? "Branch") has diverged from \(name): \(ahead) commits here, \(behind) there",
                      "git log --oneline --all --graph"))
                case "behind":
                  text = "\(behind) commits behind \(name)"
                  findings.append(
                    Finding(
                      "peer-behind", .attention,
                      "\(name) has \(behind) commits you don’t have here",
                      "git log --oneline --all --graph"))
                case "ahead": text = "\(ahead) commits ahead of \(name)"
                case "same": text = "Same tip"
                default:
                  text = "Different tips; ancestry unknown"
                  findings.append(
                    Finding(
                      "peer-unknown", .info,
                      "\(name) has a different tip; its commits are not available locally to compare"
                    ))
                }
              }
              if text == "Same tip" && !repo.dirty && !other.dirty {
                text = "In sync"
              }
            }
            if !stale {
              let work = workSignals(other)
              if !work.isEmpty { text += " · " + work.joined(separator: " · ") }
              if other.dirty {
                findings.append(Finding(
                  "peer-dirty", .attention,
                  "\(name) has uncommitted changes on \(other.branch ?? "detached HEAD")"))
              }
              if needsPush(other) || (other.branchWork ?? []).contains(where: {
                $0.name != other.branch && $0.ahead > 0
              }) {
                findings.append(Finding(
                  "peer-unpushed", .attention,
                  "\(name) has commits to review for pushing: \(pushSummary(other))"))
              }
              if other.stashCount > 0 {
                findings.append(Finding("peer-stashes", .info, "\(name) has \(other.stashCount) saved stashes"))
              }
              if repo.dirty && other.dirty {
                findings.append(Finding(
                  "peer-work-both", .attention,
                  "Uncommitted work exists here and on \(name); review both copies before switching machines"))
              }
            }
            peers.append(
              PeerRelation(
                id: peerID, environmentName: name, path: other.path, branch: other.branch,
                tip: other.headSHA, text: text, lastActivity: other.lastCommitDate))
          }
        }
        let cloneID = "\(env.id.uuidString):\(repo.path)"
        findings.removeAll { c.disabledFindings.contains($0.id) }
        if c.ignored.contains(cloneID) || (c.snoozed[cloneID] ?? .distantPast) > now {
          findings = []
        }
        findings.sort { $0.severity > $1.severity }
        world.clones.append(
          Clone(
            environmentID: env.id, repo: repo,
            status: RepoStatus(
              identity: key, severity: findings.map(\.severity).max() ?? .ok,
              findings: findings, peers: peers)))
      }
    }
    return world
  }
  public static func repositoryKey(_ repo: RepoSnapshot, environmentID: UUID) -> String {
    let key = identity(repo)
    return key.hasPrefix("unborn:") ? "unborn:\(environmentID):\(repo.path)" : key
  }
  public static func sameLineOfWork(_ a: RepoSnapshot, _ b: RepoSnapshot) -> Bool {
    if let left = a.upstreamRef, let right = b.upstreamRef { return left == right }
    return a.branch == b.branch
  }
  public static func compare(_ repo: RepoSnapshot, _ other: RepoSnapshot) -> Ancestry {
    if repo.headSHA == other.headSHA && !repo.headSHA.isEmpty { return Ancestry(relation: "same") }
    if let direct = repo.ancestry[other.headSHA], direct.relation != "unknown" { return direct }
    if let inverse = other.ancestry[repo.headSHA], inverse.relation != "unknown" {
      return Ancestry(
        relation: inverse.relation == "ahead" ? "behind" : inverse.relation == "behind" ? "ahead" : inverse.relation,
        ahead: inverse.behind, behind: inverse.ahead)
    }
    // The same upstream anchor is an ancestor of both heads. Complete sets above
    // that anchor prove ancestry/divergence even when neither has the other's objects.
    if let anchor = repo.upstreamSHA, !anchor.isEmpty, anchor == other.upstreamSHA,
      repo.behind == 0, other.behind == 0, repo.shallow != true, other.shallow != true,
      let local = repo.localCommitSHAs, let remote = other.localCommitSHAs,
      (repo.headSHA == anchor || local.contains(repo.headSHA)),
      (other.headSHA == anchor || remote.contains(other.headSHA))
    {
      let ahead = Set(local).subtracting(remote).count
      let behind = Set(remote).subtracting(local).count
      return Ancestry(
        relation: ahead == 0 ? (behind == 0 ? "same" : "behind") : behind == 0 ? "ahead" : "diverged",
        ahead: ahead, behind: behind)
    }
    return Ancestry(relation: "unknown")
  }
  public static func needsPush(_ repo: RepoSnapshot) -> Bool {
    repo.ahead > 0 && repo.upstreamRemoteTip != repo.headSHA
  }
  public static func pushSummary(_ repo: RepoSnapshot) -> String {
    var summaries: [String] = []
    if needsPush(repo) {
      summaries.append("\(repo.branch ?? "HEAD"): \(repo.ahead) ahead of last fetched upstream")
    }
    for branch in repo.branchWork ?? [] where branch.name != repo.branch && branch.ahead > 0 {
      summaries.append("\(branch.name): \(branch.ahead) ahead of last fetched upstream")
    }
    return summaries.joined(separator: "; ")
  }
  public static func workSignals(_ repo: RepoSnapshot) -> [String] {
    var signals: [String] = []
    if repo.dirty { signals.append("uncommitted changes") }
    let pushes = pushSummary(repo)
    if !pushes.isEmpty { signals.append(pushes) }
    let unpublished = (repo.branchWork ?? []).filter { $0.upstream == nil }.map(\.name)
    if !unpublished.isEmpty { signals.append("no upstream: " + unpublished.joined(separator: ", ")) }
    if repo.stashCount > 0 { signals.append("\(repo.stashCount) stashes") }
    if repo.detachedCommits > 0 { signals.append("\(repo.detachedCommits) detached commits") }
    return signals
  }
  public static func perClone(
    _ r: RepoSnapshot, environment: String, configuration c: Configuration, now: Date
  ) -> [Finding] {
    var f: [Finding] = []
    let branch = r.branch ?? "HEAD"
    if let error = r.error { return [Finding("probe-error", .attention, error)] }
    if r.operation != .none {
      f.append(
        Finding(
          "operation", .problem, "A \(r.operation.rawValue) is in progress on \(environment)",
          r.operation == .bisect ? "git bisect log" : "git \(r.operation.rawValue) --continue"))
    }
    if r.conflicted > 0 {
      f.append(
        Finding(
          "conflicts", .problem, "\(r.conflicted) files have unresolved conflicts", "git status"))
    }
    if r.ahead > 0 && r.behind > 0 {
      f.append(
        Finding(
          "diverged", .problem,
          "\(branch) has diverged from upstream: \(r.ahead) ahead, \(r.behind) behind",
          "git log --oneline --left-right HEAD...@{upstream}"))
    } else if r.behind > 0 {
      f.append(
        Finding(
          "behind", .attention, "\(branch) is \(r.behind) commits behind upstream",
          "git pull --rebase"))
    }
    if r.upstreamGone {
      f.append(
        Finding(
          "upstream-gone", .attention, "Upstream branch was deleted (merged PR?)", "git branch -vv")
      )
    }
    if r.dirty {
      let age = now.timeIntervalSince(r.dirtySince ?? now)
      let old = age >= c.dirtyHours * 3600
      f.append(
        Finding(
          "dirty", old ? .attention : .info,
          old
            ? "Uncommitted changes for \(ageText(age)) on \(environment)"
            : "Working tree has changes (\(r.staged) staged, \(r.modified) modified, \(r.untracked) untracked)",
          "git status"))
    }
    if needsPush(r) {
      let age = now.timeIntervalSince(r.unpushedSince ?? now)
      f.append(
        Finding(
          "unpushed", age >= c.unpushedHours * 3600 ? .attention : .info,
          "\(r.ahead) commits ahead of last fetched upstream\(age >= 3600 ? " for " + ageText(age) : ""); check before pushing", "git log --oneline @{upstream}..HEAD"))
    }
    for branch in r.branchWork ?? [] where branch.name != r.branch && branch.ahead > 0 {
      f.append(Finding(
        "branch-unpushed", .attention,
        "\(branch.name) has \(branch.ahead) commits ahead of last fetched upstream on \(environment)",
        "git branch -vv"))
    }
    if r.staleLock {
      f.append(
        Finding(
          "lock", .attention,
          "A stale index.lock may block git; check for running Git processes before removing it",
          "ps aux | grep '[g]it'"))
    }
    if r.detached {
      f.append(
        Finding(
          "detached", r.detachedCommits > 0 ? .attention : .info,
          r.detachedCommits > 0
            ? "Detached HEAD with \(r.detachedCommits) commits not on any branch" : "Detached HEAD",
          "git switch -c rescue-work"))
    } else if r.upstream == nil {
      f.append(Finding("no-upstream", .info, "Branch \(branch) has no upstream", "git branch -vv"))
    }
    if r.stashCount > 0 {
      f.append(Finding("stashes", .info, "\(r.stashCount) stashes", "git stash list"))
    }
    if let error = r.upstreamError {
      f.append(
        Finding(
          "upstream-unknown", .info,
          "\(error) since \((r.upstreamUnknownSince ?? now).formatted(date:.omitted,time:.shortened))"
        ))
    }
    if let tip = r.upstreamRemoteTip, let cached = r.upstreamSHA, tip != cached {
      f.append(
        Finding(
          "upstream-moved", .attention,
          "Upstream changed on the server; ahead/behind counts use the last fetch", "git fetch"))
    }
    if r.slow {
      f.append(
        Finding(
          "slow", .info,
          "This repository is slow; automatic probes run on the safety sweep. Consider Git’s untracked cache or fsmonitor."
        ))
    }
    if c.reportStaleBranches {
      let stale = r.branchCommitDates.filter {
        $0.key != r.branch && now.timeIntervalSince($0.value) >= c.staleBranchDays * 86400
      }.keys.sorted()
      if !stale.isEmpty {
        f.append(
          Finding(
            "stale-branches", .info,
            "\(stale.count) inactive \(stale.count == 1 ? "branch has" : "branches have") no commits in \(Int(c.staleBranchDays)) days: \(stale.prefix(5).joined(separator: ", "))",
            "git branch --sort=committerdate"))
      }
    }
    return f
  }
  private static func ageText(_ seconds: Double) -> String {
    if seconds < 60 { return "less than a minute" }
    let unit = seconds >= 86400 ? "day" : seconds >= 3600 ? "hour" : "minute"
    let count = Int(seconds / (seconds >= 86400 ? 86400 : seconds >= 3600 ? 3600 : 60))
    return "\(count) \(unit)\(count == 1 ? "" : "s")"
  }
}
