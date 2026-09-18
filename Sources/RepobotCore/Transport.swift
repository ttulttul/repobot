import CProcess
import Darwin
import Foundation

public struct CommandResult: Sendable {
  public var stdout: Data, stderr: Data
  public var status: Int32
  public var text: String { String(decoding: stdout, as: UTF8.self) }
  public var errorText: String { String(decoding: stderr, as: UTF8.self) }
}
public enum RepobotError: Error, LocalizedError, Sendable {
  case message(String)
  public var errorDescription: String? {
    switch self {
    case .message(let text): text
    }
  }
}
public func shellQuote(_ value: String) -> String {
  "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
public func expandedPath(_ path: String) -> String { (path as NSString).expandingTildeInPath }

// All lifecycle transitions are protected by one lock. Timeouts kill the whole process
// group, including a shell's descendants that may still hold stdout/stderr open.
private final class RunningCommand: @unchecked Sendable {
  let lock = NSLock()
  var pid: pid_t = 0
  var cancelled = false
  var finished = false
  func stop() {
    lock.lock()
    defer { lock.unlock() }
    guard !finished else { return }
    cancelled = true
    if pid > 0 { kill(-pid, SIGKILL) }
  }
}
public enum ProcessRunner {
  public static func run(
    _ executable: String, _ arguments: [String], input: Data = Data(), timeout: Double = 30,
    onOutput: (@Sendable (Data) -> Void)? = nil, environment: [String: String]? = nil,
    outputFile: URL? = nil
  ) async throws -> CommandResult {
    let running = RunningCommand()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .utility).async {
          let output = Pipe()
          let errors = Pipe()
          let stdin = Pipe()
          // Keep Foundation's pipe owners alive until all readers and the child
          // have finished, including in optimized builds.
          defer { withExtendedLifetime((output, errors, stdin)) {} }
          let spool: Int32
          if let outputFile {
            spool = Darwin.open(outputFile.path, O_RDWR | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW, 0o600)
            guard spool >= 0 else {
              continuation.resume(throwing: RepobotError.message("Could not open agent output: " + String(cString: strerror(errno))))
              return
            }
          } else { spool = -1 }
          defer { if spool >= 0 { Darwin.close(spool) } }
          _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
          var env = environment ?? ProcessInfo.processInfo.environment
          env["GIT_NO_LAZY_FETCH"] = "1"
          env["GIT_OPTIONAL_LOCKS"] = "0"
          env["GIT_TERMINAL_PROMPT"] = "0"
          env["LC_ALL"] = "C"
          let argv = ([executable] + arguments).map { strdup($0) } + [nil]
          let envp = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
          defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
          }
          running.lock.lock()
          if running.cancelled {
            running.lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
          }
          let rc = rb_spawn(
            executable, argv, envp, stdin.fileHandleForReading.fileDescriptor,
            spool >= 0 ? spool : output.fileHandleForWriting.fileDescriptor, errors.fileHandleForWriting.fileDescriptor,
            &running.pid)
          running.lock.unlock()
          guard rc == 0 else {
            continuation.resume(throwing: RepobotError.message(String(cString: strerror(rc))))
            return
          }
          try? stdin.fileHandleForReading.close()
          try? output.fileHandleForWriting.close()
          try? errors.fileHandleForWriting.close()
          let timer = DispatchWorkItem { running.stop() }
          DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
          let errBox = DataBox()
          let group = DispatchGroup()
          group.enter()
          DispatchQueue.global().async {
            errBox.data = errors.fileHandleForReading.readDataToEndOfFile()
            group.leave()
          }
          group.enter()
          DispatchQueue.global().async {
            // Avoid SIGPIPE terminating the app if a child rejects stdin early.
            var blocked = sigset_t()
            sigemptyset(&blocked)
            sigaddset(&blocked, SIGPIPE)
            var previous = sigset_t()
            pthread_sigmask(SIG_BLOCK, &blocked, &previous)
            input.withUnsafeBytes { bytes in
              guard let base = bytes.baseAddress else { return }
              var offset = 0
              while offset < bytes.count {
                let count = Darwin.write(
                  stdin.fileHandleForWriting.fileDescriptor, base.advanced(by: offset),
                  bytes.count - offset)
                if count > 0 {
                  offset += count
                } else if count < 0 && errno == EINTR {
                  continue
                } else {
                  break
                }
              }
            }
            try? stdin.fileHandleForWriting.close()
            var pending = sigset_t()
            sigpending(&pending)
            if sigismember(&pending, SIGPIPE) != 0 {
              var received: Int32 = 0
              sigwait(&blocked, &received)
            }
            pthread_sigmask(SIG_SETMASK, &previous, nil)
            group.leave()
          }
          var data = Data()
          var bytes = [UInt8](repeating: 0, count: 65536)
          var readError: Int32 = 0
          let status: Int32
          if spool >= 0 {
            // The agent writes to a regular private file, never to the UI's pipe.
            // pread has an independent offset, so tailing cannot move its writer.
            let exitStatus = ProcessExitStatus()
            let exited = DispatchGroup()
            exited.enter()
            DispatchQueue.global(qos: .utility).async {
              exitStatus.set(Int32(rb_wait(running.pid)))
              exited.leave()
            }
            var offset: off_t = 0
            while true {
              // Observe exit BEFORE reading. Once exited, drain through the final
              // EOF so the last structured-result event cannot be lost.
              let finished = exitStatus.get() != nil
              let count = Darwin.pread(spool, &bytes, bytes.count, offset)
              if count < 0 {
                let code = errno
                if code == EINTR { continue }
                readError = code; running.stop(); break
              }
              if count > 0 {
                offset += off_t(count)
                let chunk = Data(bytes.prefix(count))
                if let onOutput { onOutput(chunk) } else { data.append(chunk) }
              } else if finished { break }
              else { Thread.sleep(forTimeInterval: 0.05) }
            }
            exited.wait()
            status = exitStatus.get() ?? -1
          } else {
            while true {
              let count = Darwin.read(output.fileHandleForReading.fileDescriptor, &bytes, bytes.count)
              if count < 0 {
                let code = errno
                if code == EINTR { continue }
                readError = code; running.stop(); break
              }
              if count == 0 { break }
              let chunk = Data(bytes.prefix(count))
              if let onOutput { onOutput(chunk) } else { data.append(chunk) }
            }
            status = Int32(rb_wait(running.pid))
          }
          group.wait()
          timer.cancel()
          running.lock.lock()
          running.finished = true
          let cancelled = running.cancelled
          running.lock.unlock()
          if readError != 0 {
            continuation.resume(throwing: RepobotError.message("Could not read command output: " + String(cString: strerror(readError))))
          } else if cancelled {
            continuation.resume(
              throwing: RepobotError.message(
                "Command cancelled or timed out after \(Int(timeout)) seconds"))
          } else {
            continuation.resume(
              returning: CommandResult(stdout: data, stderr: errBox.data, status: Int32(status)))
          }
        }
      }
    } onCancel: {
      running.stop()
    }
  }
}
private final class ProcessExitStatus: @unchecked Sendable {
  private let lock = NSLock()
  private var status: Int32?
  func set(_ value: Int32) { lock.lock(); defer { lock.unlock() }; status = value }
  func get() -> Int32? { lock.lock(); defer { lock.unlock() }; return status }
}
private final class DataBox: @unchecked Sendable { var data = Data() }
public protocol Transport: Sendable {
  func run(script: String, arguments: [String], timeout: Double) async throws -> CommandResult
  func invocation(program: String, arguments: [String]) -> (String, [String])
  func close() async
}
public struct LocalTransport: Transport {
  public init() {}
  // Finder-launched apps get Apple's launcher shims on PATH. Prefer the installed
  // standalone tools when a shim would otherwise dispatch through a broken Xcode.
  private var prelude: String {
    """
    if [ "$(command -v git)" = /usr/bin/git ] && [ -x /Library/Developer/CommandLineTools/usr/bin/git ]; then
        PATH="/Library/Developer/CommandLineTools/usr/bin:$PATH"; export PATH
    fi

    """
  }
  public func invocation(program: String, arguments: [String]) -> (String, [String]) {
    (
      "/bin/sh",
      ["-c", prelude + "exec " + ([program] + arguments).map(shellQuote).joined(separator: " ")]
    )
  }
  public func run(script: String, arguments: [String] = [], timeout: Double = 30) async throws
    -> CommandResult
  {
    try await ProcessRunner.run(
      "/bin/sh", ["-s", "--"] + arguments, input: Data((prelude + script).utf8), timeout: timeout)
  }
  public func close() async {}
}
public struct SSHTransport: Transport {
  public let environment: Environment
  public let configuration: Configuration
  public let controlDirectory: URL
  public init(
    environment: Environment, configuration: Configuration = Configuration(),
    controlDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".repobot")
  ) {
    self.environment = environment
    self.configuration = configuration
    self.controlDirectory = controlDirectory
  }
  // OpenSSH expands %C to 40 hex characters and appends a temporary "." plus
  // 16 random characters while creating the master socket. Include the NUL byte.
  public var canMultiplex: Bool {
    controlDirectory.path.utf8.count + "/cm-".utf8.count + 40 + 17 + 1 <= 104
  }
  public var baseArguments: [String] {
    var args = [
      "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o", "StrictHostKeyChecking=accept-new",
      "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=2",
    ]
    if canMultiplex {
      args += [
        "-o", "ControlMaster=auto", "-o", "ControlPersist=10m",
        "-o", "ControlPath=\"\(controlDirectory.path)/cm-%C\"",
      ]
    } else {
      args += ["-o", "ControlMaster=no", "-o", "ControlPersist=no", "-o", "ControlPath=none"]
    }
    if let port = environment.port { args += ["-p", String(port)] }
    if let key = environment.identityFile, !key.isEmpty { args += ["-i", expandedPath(key)] }
    for option in configuration.extraSSHOptions { args += ["-o", option] }
    return args
  }
  public var destination: String {
    environment.user.isEmpty ? environment.host : "\(environment.user)@\(environment.host)"
  }
  public func invocation(program: String, arguments: [String]) -> (String, [String]) {
    (
      configuration.sshPath,
      baseArguments + [
        "--", destination, ([program] + arguments).map(shellQuote).joined(separator: " "),
      ]
    )
  }
  public func run(script: String, arguments: [String] = [], timeout: Double = 30) async throws
    -> CommandResult
  {
    if canMultiplex {
      try FileManager.default.createDirectory(
        at: controlDirectory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      var info = stat()
      guard lstat(controlDirectory.path, &info) == 0,
        (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == geteuid()
      else { throw RepobotError.message("SSH socket directory must be owned by you and must not be a symlink") }
      guard chmod(controlDirectory.path, 0o700) == 0 else {
        throw RepobotError.message("Could not make SSH socket directory private")
      }
    }
    let (path, args) = invocation(program: "sh", arguments: ["-s", "--"] + arguments)
    return try await ProcessRunner.run(path, args, input: Data(script.utf8), timeout: timeout)
  }
  public func close() async {
    guard canMultiplex else { return }
    _ = try? await ProcessRunner.run(
      configuration.sshPath, baseArguments + ["-O", "exit", "--", destination], timeout: 5)
  }
}
public enum Scripts {
  public static func load(_ name: String) throws -> String {
    if let url = Bundle.main.resourceURL?.appendingPathComponent("RepobotCore")
      .appendingPathComponent(name), FileManager.default.fileExists(atPath: url.path)
    {
      return try String(contentsOf: url, encoding: .utf8)
    }
    guard
      let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Resources")
    else { throw RepobotError.message("Missing bundled script \(name)") }
    return try String(contentsOf: url, encoding: .utf8)
  }
}
