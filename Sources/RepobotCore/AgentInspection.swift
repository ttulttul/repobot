import Foundation

public enum AgentInspection {
  public static func transport(_ target: AgentTarget, context: AgentContext) -> any Transport {
    if target.environment.kind == .local { return LocalTransport() }
    var config = Configuration(); config.sshPath = context.sshPath; config.extraSSHOptions = context.sshOptions
    return SSHTransport(environment: target.environment, configuration: config)
  }
  public static func inspect(
    _ target: AgentTarget, context: AgentContext, operation: String,
    ref: String = "HEAD", path: String = "", query: String = ""
  ) async throws -> String {
    let operations = ["status", "diff", "staged_diff", "upstream_diff", "log", "show", "files", "read", "search", "fingerprint"]
    guard operations.contains(operation), !ref.hasPrefix("-"), !ref.contains(":"),
      ref.count <= 256, !ref.contains(where: { $0.isWhitespace || $0.isNewline }),
      path.utf8.count < 4096, !path.hasPrefix("/"), !path.split(separator: "/").contains(".."),
      !path.split(separator: "/").contains(".git"),
      !path.contains("\0"), query.utf8.count <= 1000 else {
      throw RepobotError.message("Invalid repository inspection request")
    }
    let result = try await transport(target, context: context).run(
      script: script, arguments: [target.repo.path, operation, ref, path, query], timeout: 45)
    guard result.status == 0 else { throw RepobotError.message("Repository inspection failed (\(operation), exit \(result.status)); the copy may be unavailable") }
    let limit = 120_000
    return String(decoding: result.stdout.prefix(limit), as: UTF8.self)
      + (result.stdout.count > limit ? "\n[Output truncated; narrow the request.]" : "")
  }
  public static func refresh(_ context: AgentContext) async -> AgentContext {
    var result = context
    result.generatedAt = Date()
    for index in result.targets.indices {
      let target = result.targets[index]
      do {
        let repos = try await Probe.repos([target.repo.path], upstream: .lsRemote, using: transport(target, context: context))
        guard let repo = repos.first, repo.error == nil else { throw RepobotError.message("Repository probe failed") }
        result.targets[index].repo = repo
        result.targets[index].fingerprint = try await inspect(target, context: context, operation: "fingerprint").trimmingCharacters(in: .whitespacesAndNewlines)
        result.targets[index].inspectionError = nil
      } catch {
        result.targets[index].fingerprint = nil
        result.targets[index].inspectionError = "Could not refresh this copy; its status is last known, not current."
      }
    }
    let snapshots = Dictionary(grouping: result.targets, by: { $0.environment.id }).values.map { targets in
      var snapshot = EnvironmentSnapshot(environment: targets[0].environment)
      snapshot.repos = targets.map { target in
        var repo = target.repo
        if let error = target.inspectionError { repo.error = error }
        return repo
      }
      return snapshot
    }
    let world = Analyzer.analyze(snapshots, configuration: Configuration())
    for index in result.targets.indices {
      if let clone = world.clones.first(where: { $0.id == result.targets[index].id }) { result.targets[index].status = clone.status }
    }
    return result
  }
  public static func ensureUnchanged(_ context: AgentContext) async throws {
    for target in context.targets {
      guard let fingerprint = target.fingerprint, target.inspectionError == nil else {
        throw RepobotError.message("\(target.environment.name) was not inspected successfully. Reanalyze when all copies are available.")
      }
      let current = try await inspect(target, context: context, operation: "fingerprint").trimmingCharacters(in: .whitespacesAndNewlines)
      guard current == fingerprint else {
        throw RepobotError.message("\(target.environment.name): repository state changed since analysis. Reanalyze before executing a resolution.")
      }
      let refreshed = try await Probe.repos([target.repo.path], upstream: .lsRemote, using: transport(target, context: context))
      guard let repo = refreshed.first, repo.error == nil,
        repo.upstreamRemoteTip == target.repo.upstreamRemoteTip,
        repo.upstreamRemoteDeleted == target.repo.upstreamRemoteDeleted,
        !(target.repo.upstreamError == nil && repo.upstreamError != nil) else {
        throw RepobotError.message("\(target.environment.name): upstream changed or could not be rechecked. Reanalyze before executing a resolution.")
      }
    }
  }
  static let script = #"""
  export GIT_OPTIONAL_LOCKS=0 GIT_NO_LAZY_FETCH=1 GIT_TERMINAL_PROMPT=0 GIT_ASKPASS= SSH_ASKPASS= LC_ALL=C
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
  git() { command git -c credential.helper= -c core.askPass= -c core.fsmonitor=false -c core.pager=cat "$@"; }
  cd -- "$1" || exit 2
  git rev-parse --git-dir >/dev/null 2>&1 || exit 3
  operation=$2; ref=$3; file=$4; query=$5
  if [ "$operation" = fingerprint ]; then
    {
      git rev-parse HEAD 2>/dev/null
      git symbolic-ref -q HEAD
      git status --porcelain=v2 -z --untracked-files=all
      git diff --no-ext-diff --no-textconv --binary
      git diff --cached --no-ext-diff --no-textconv --binary
      git for-each-ref --format='%(refname) %(objectname)'
      git ls-files --others --exclude-standard -z | xargs -0 -I{} git hash-object --no-filters -- '{}'
    } | git hash-object --stdin
    exit $?
  fi
  set --
  if [ -n "$file" ]; then set -- "$file"; fi
  case "$operation" in
    status) git status --porcelain=v2 --branch --untracked-files=all | head -c 120001;;
    diff) git diff --no-ext-diff --no-textconv --binary -- "$@" | head -c 120001;;
    staged_diff) git diff --cached --no-ext-diff --no-textconv --binary -- "$@" | head -c 120001;;
    upstream_diff) sha=$(git rev-parse --verify '@{upstream}^{commit}') || exit 4
                   git diff --no-ext-diff --no-textconv "$sha" HEAD -- | head -c 120001;;
    log) sha=$(git rev-parse --verify "$ref^{commit}") || exit 4
         git log --max-count=60 --format='%H %P %cI %s' "$sha" -- | head -c 120001;;
    show) sha=$(git rev-parse --verify "$ref^{commit}") || exit 4
          git show --no-ext-diff --no-textconv --format=fuller --stat --patch "$sha" -- | head -c 120001;;
    files) git ls-files --cached --others --exclude-standard | head -c 120001;;
    read) [ -n "$file" ] || exit 4
          root=$(pwd -P)
          parent=$(dirname -- "$file"); name=$(basename -- "$file")
          cd -- "$parent" || exit 4
          case "$(pwd -P)/" in "$root/"*) ;; *) exit 4;; esac
          [ ! -L "$name" ] && [ -f "$name" ] || exit 4
          head -c 120001 < "$name";;
    search) [ -n "$query" ] || exit 4
            git grep --no-ext-grep -n -I -F -e "$query" -- | head -c 120001;;
    *) exit 4;;
  esac
  """#
}
