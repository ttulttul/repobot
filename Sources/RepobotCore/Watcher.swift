import CoreServices
import Foundation

public enum WatchEvent: Sendable {
  case ready, ping
  case changed(String)
  case rescan
  case limited(String)
  case ended, failed(String)
}
public final class LocalWatcher: @unchecked Sendable {
  private var stream: FSEventStreamRef?
  private let handler: @Sendable (WatchEvent) -> Void
  private let queue = DispatchQueue(label: "Repobot.FSEvents")
  let watchedRoots: [String]
  // FSEvents watches recursively. WatchRoot consumes descriptors for explicit paths;
  // registering every repository and .git under an already watched root exhausts the
  // GUI application's default 256-descriptor limit.
  static func physicalPath(_ path: String) -> String {
    let path = (expandedPath(path) as NSString).standardizingPath
    if let resolved = realpath(path, nil) {
      defer { free(resolved) }
      return String(cString: resolved)
    }
    // Resolve the existing ancestor of a not-yet-created repository too. Foundation
    // may spell existing /private/var paths as /var but leave missing children alone.
    let parent = (path as NSString).deletingLastPathComponent
    guard !parent.isEmpty, parent != path else { return path }
    return (physicalPath(parent) as NSString).appendingPathComponent((path as NSString).lastPathComponent)
  }
  static func compactRoots(_ roots: [String]) -> [String] {
    let paths = Set(roots.filter { !$0.isEmpty }.map {
      physicalPath($0)
    }).sorted { $0.count == $1.count ? $0 < $1 : $0.count < $1.count }
    var result: [String] = []
    for path in paths where !result.contains(where: { $0 == "/" || path.hasPrefix($0 + "/") }) {
      result.append(path)
    }
    return result
  }
  private static func failure(_ operation: String, roots: Int, code: Int32) -> RepobotError {
    var limit = rlimit(); getrlimit(RLIMIT_NOFILE, &limit)
    let detail = code == 0 ? "no errno supplied" : String(cString: strerror(code))
    return .message("Could not \(operation) local filesystem watcher (\(roots) watch roots; file-descriptor limit \(limit.rlim_cur); \(detail), errno \(code))")
  }
  public init(roots: [String], handler: @escaping @Sendable (WatchEvent) -> Void) throws {
    self.handler = handler
    watchedRoots = Self.compactRoots(roots)
    guard !watchedRoots.isEmpty else { throw RepobotError.message("No local filesystem watch roots configured") }
    var context = FSEventStreamContext(
      version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil,
      copyDescription: nil)
    let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
      guard let info else { return }
      let watcher = Unmanaged<LocalWatcher>.fromOpaque(info).takeUnretainedValue()
      let strings = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
      let rescanFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs
        | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
        | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount)
      for i in 0..<count {
        if flags[i] & rescanFlags != 0 { watcher.handler(.rescan) }
        let path = String(cString: strings[i])
        watcher.handler(.changed(path))
      }
    }
    errno = 0
    stream = FSEventStreamCreate(
      nil, callback, &context, watchedRoots as CFArray,
      FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1,
      FSEventStreamCreateFlags(
        kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot))
    guard let stream else {
      throw Self.failure("create", roots: watchedRoots.count, code: errno)
    }
    FSEventStreamSetDispatchQueue(stream, queue)
    errno = 0
    guard FSEventStreamStart(stream) else {
      let code = errno
      FSEventStreamInvalidate(stream)
      FSEventStreamRelease(stream)
      self.stream = nil
      throw Self.failure("start", roots: watchedRoots.count, code: code)
    }
    handler(.ready)
  }
  public func stop() {
    guard let stream else { return }
    FSEventStreamStop(stream)
    FSEventStreamInvalidate(stream)
    queue.sync {}  // Drain callbacks before releasing their unretained context.
    FSEventStreamRelease(stream)
    self.stream = nil
  }
  deinit { stop() }
}
public final class RemoteWatcher: @unchecked Sendable {
  private let task: Task<Void, Never>
  public init(
    transport: any Transport, roots: [String], repos: [String], capabilities: Capabilities,
    handler: @escaping @Sendable (WatchEvent) -> Void
  ) throws {
    let script: String
    let program: String
    let args: [String]
    if capabilities.python {
      program = "python3"
      args = ["-"] + roots + ["--"] + repos
      script = try Scripts.load("watcher.py")
    } else {
      program = "sh"
      args = ["-s", "--"] + roots + repos
      let command =
        capabilities.inotifywait
        ? "inotifywait -q -m -r -e modify,attrib,move,create,delete -- \"$@\""
        : "fswatch -r -- \"$@\""
      script = """
        original=$#
        for path do
            case "$path" in '~') path=$HOME;; '~/'*) path=$HOME/${path#\\~/};; esac
            set -- "$@" "$path"
        done
        shift "$original"
        (while sleep 30; do printf 'PING\\000'; done) &
        ping=$!
        trap 'kill "$ping" 2>/dev/null' EXIT HUP INT TERM
        printf 'READY\\000'
        \(command) | while IFS= read -r line; do printf 'RESCAN\\000'; done
        """
    }
    let (executable, arguments) = transport.invocation(program: program, arguments: args)
    let parser = WatchParser(handler: handler)
    task = Task {
      do {
        let result = try await ProcessRunner.run(
          executable, arguments, input: Data(script.utf8), timeout: 31_536_000,
          onOutput: { parser.receive($0) })
        guard !Task.isCancelled else { return }
        let detail = result.errorText.trimmingCharacters(in: .whitespacesAndNewlines)
        handler(.failed("Remote watcher exited with status \(result.status)"
          + (detail.isEmpty ? "" : ": " + String(detail.suffix(1800)))))
      } catch {
        guard !Task.isCancelled else { return }
        handler(.failed(error.localizedDescription))
      }
    }
  }
  public func stop() { task.cancel() }
  deinit { stop() }
}

// The process runner invokes receive serially on its output-draining worker.
private final class WatchParser: @unchecked Sendable {
  var buffer = Data()
  var pending: String?
  let handler: @Sendable (WatchEvent) -> Void
  init(handler: @escaping @Sendable (WatchEvent) -> Void) { self.handler = handler }
  func receive(_ chunk: Data) {
    buffer.append(chunk)
    while let end = buffer.firstIndex(of: 0) {
      let value = String(decoding: buffer[..<end], as: UTF8.self)
      buffer.removeSubrange(...end)
      if let key = pending {
        handler(key == "CHANGED" ? .changed(value) : .limited(value))
        pending = nil
      } else {
        switch value {
        case "READY": handler(.ready)
        case "PING": handler(.ping)
        case "RESCAN": handler(.rescan)
        case "CHANGED", "LIMIT": pending = value
        default: break
        }
      }
    }
    if buffer.count > 1_048_576 {
      buffer.removeAll()
      pending = nil
      handler(.rescan)
    }
  }
}
