import Darwin
import Foundation
import Testing
@testable import RepobotCore

struct CountingGitTransport: Transport {
  let bin: URL, log: URL
  init(root: URL) throws {
    bin = root.appendingPathComponent("tools"); log = root.appendingPathComponent("git-calls")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let realGit = FileManager.default.isExecutableFile(atPath: "/Library/Developer/CommandLineTools/usr/bin/git")
      ? "/Library/Developer/CommandLineTools/usr/bin/git" : "/usr/bin/git"
    let wrapper = "#!/bin/sh\nprintf '%s\\n' \"$*\" >> " + shellQuote(log.path) + "\nexec " + shellQuote(realGit) + " \"$@\"\n"
    try Data(wrapper.utf8).write(to: bin.appendingPathComponent("git"))
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: bin.appendingPathComponent("git").path)
  }
  func run(script: String, arguments: [String], timeout: Double) async throws -> CommandResult {
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = bin.path + ":" + (env["PATH"] ?? "/usr/bin:/bin")
    return try await ProcessRunner.run("/bin/sh", ["-s", "--"] + arguments, input: Data(script.utf8), timeout: timeout, environment: env)
  }
  func invocation(program: String, arguments: [String]) -> (String, [String]) { LocalTransport().invocation(program: program, arguments: arguments) }
  func close() async {}
  func calls() -> [String] { ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
}
@Suite(.serialized) struct ProbePerformanceTests {
  private func cpu(_ who: Int32) -> Double {
    var usage = rusage(); getrusage(who, &usage)
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
  }
  @Test(.enabled(if: ProcessInfo.processInfo.environment["REPOBOT_PROBE_BENCHMARK"] == "1"))
  func realGitWorkloads() async throws {
    let helper = CoreTests(), root = try helper.temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let server = root.appendingPathComponent("server")
    try await helper.repo(server)
    let transport = try CountingGitTransport(root: root)
    var paths: [String] = []
    for index in 0..<12 {
      let clone = root.appendingPathComponent("clone-\(index)")
      try await helper.git(root, ["clone", server.path, clone.path]); paths.append(clone.path)
    }
    var previous = try await Probe.repos(paths, using: transport)
    for upstream in [true, false] {
      let initial = transport.calls().count, start = cpu(RUSAGE_SELF), children = cpu(RUSAGE_CHILDREN), wall = Date()
      let rounds = 5
      for _ in 0..<rounds {
        if upstream { _ = try await Probe.checkUpstreams(previous, method: .lsRemote, using: transport) }
        else { previous = try await Probe.repos(paths, previous: Dictionary(uniqueKeysWithValues: previous.map { ($0.path, $0) }), using: transport) }
      }
      let own = cpu(RUSAGE_SELF) - start, child = cpu(RUSAGE_CHILDREN) - children, elapsed = Date().timeIntervalSince(wall)
      let calls = Array(transport.calls().dropFirst(initial))
      let result: [String: Any] = ["workload": upstream ? "upstream_shared" : "git_unchanged",
        "operations": rounds, "cpu_ms_per_op": (own + child) * 1000 / Double(rounds),
        "wall_ms_per_op": elapsed * 1000 / Double(rounds),
        "counters": ["git_invocations": calls.count, "ls_remote": calls.filter { $0.contains("ls-remote") }.count],
        "app_cpu_ms_per_op": own * 1000 / Double(rounds), "child_cpu_ms_per_op": child * 1000 / Double(rounds)]
      print("REPOBOT_BENCHMARK " + String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
    }
  }
}
