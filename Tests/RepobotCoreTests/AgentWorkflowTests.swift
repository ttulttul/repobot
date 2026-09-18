import Foundation
import Testing
@testable import RepobotCore

struct AgentWorkflowTests {
  func fixture() async throws -> (URL, AgentContext) {
    let helper = CoreTests()
    let root = try helper.temporary()
    let repo = root.appendingPathComponent("repo with ' quote")
    try await helper.repo(repo)
    try Data("def widget():\n    return 'new local feature'\n".utf8).write(to: repo.appendingPathComponent("widget.py"))
    let env = Environment(name: "Fixture Mac", kind: .local, roots: [repo.path])
    var snapshot = EnvironmentSnapshot(environment: env)
    snapshot.repos = try await Probe.repos([repo.path], using: LocalTransport())
    let world = Analyzer.analyze([snapshot], configuration: Configuration())
    let group = try #require(world.repositories.first)
    let context = AgentWorkflow.context(for: group, world: world, configuration: Configuration())
    return (root, await AgentInspection.refresh(context))
  }
  func analysis(_ context: AgentContext) -> AgentAnalysis {
    AgentAnalysis(summary: "A local feature needs a home", limitations: [], problems: [
      AgentProblem(id: "feature", title: "Feature on main", explanation: "Review widget", evidence: ["widget.py is untracked"], options: [
        ResolutionOption(id: "branch", title: "Preserve on a feature branch", explanation: "Keep work for review", steps: ["Create a feature branch", "Commit widget"], risks: ["Tests required"], affectedCloneIDs: [context.targets[0].id], destructive: false),
        ResolutionOption(id: "discard", title: "Discard redundant work", explanation: "Only if confirmed redundant", steps: ["Back up work", "Discard widget"], risks: ["Local changes are removed"], affectedCloneIDs: [context.targets[0].id], destructive: true)
      ])])
  }
  @Test func testReadOnlyInspectionAndChangedStateGate() async throws {
    let (root, context) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let target = context.targets[0]
    #expect(target.fingerprint?.isEmpty == false)
    #expect(target.inspectionError == nil)
    try await AgentInspection.ensureUnchanged(context)
    let code = try await AgentInspection.inspect(target, context: context, operation: "read", path: "widget.py")
    #expect(code.contains("new local feature"))
    let index = URL(fileURLWithPath: target.repo.path).appendingPathComponent(".git/index")
    let before = try Data(contentsOf: index)
    for operation in ["status", "diff", "staged_diff", "log", "files", "show"] {
      _ = try await AgentInspection.inspect(target, context: context, operation: operation)
    }
    #expect(try Data(contentsOf: index) == before)
    await #expect(throws: (any Error).self) {
      try await AgentInspection.inspect(target, context: context, operation: "reset")
    }
    await #expect(throws: (any Error).self) {
      try await AgentInspection.inspect(target, context: context, operation: "read", path: "../outside")
    }
    let outside = root.appendingPathComponent("outside")
    try Data("private".utf8).write(to: outside)
    let link = URL(fileURLWithPath: target.repo.path).appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    await #expect(throws: (any Error).self) {
      try await AgentInspection.inspect(target, context: context, operation: "read", path: "link")
    }
    try FileManager.default.removeItem(at: link)
    try Data("different content but still one untracked file".utf8).write(to: URL(fileURLWithPath: target.repo.path).appendingPathComponent("widget.py"))
    await #expect(throws: (any Error).self) { try await AgentInspection.ensureUnchanged(context) }
  }
  @Test func testSelectionsAndProfileIsolation() async throws {
    let (root, context) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    var profile = AgentProfile(name: "Separate Claude", harness: .claude)
    profile.homeDirectory = root.appendingPathComponent("account with space").path
    profile.executable = "/usr/bin/true"
    var job = AgentJob(profile: profile, context: context)
    job.analysis = analysis(context); job.phase = .review
    #expect(throws: (any Error).self) { try AgentWorkflow.selectedOptions(job) }
    job.selections = ["feature": "branch"]
    #expect(try AgentWorkflow.selectedOptions(job).map(\.id) == ["branch"])
    #expect(try AgentWorkflow.executionPrompt(job).contains("unselected options are NOT authorized"))
    let environment = AgentCLI.environment(for: profile)
    #expect(environment["CLAUDE_CONFIG_DIR"] == profile.homeDirectory)
    #expect(environment["CODEX_HOME"] == nil)
    #expect(environment["ANTHROPIC_API_KEY"] == nil)
    #expect(environment["CLAUDE_CODE_OAUTH_TOKEN"] == nil)
    let prefix = try AgentCLI.terminalPrefix(profile)
    #expect(prefix.contains("CLAUDE_CONFIG_DIR=" + profile.homeDirectory))
    let directory = root.appendingPathComponent("job")
    let args = AgentWorkflow.analysisArguments(job, directory: directory, helper: URL(fileURLWithPath: "/helper"))
    #expect(!args.contains("--model"))
    #expect(args.contains("--strict-mcp-config"))
    job.profile.model = "custom-model"
    #expect(AgentWorkflow.analysisArguments(job, directory: directory, helper: URL(fileURLWithPath: "/helper")).contains("custom-model"))
    let script = try AgentWorkflow.executionScript(job, directory: directory)
    let text = try String(contentsOf: script, encoding: .utf8)
    #expect(!text.contains("dangerously"))
    #expect(text.contains("\"$prompt\""))
    job.selections = ["feature": "unknown"]
    #expect(throws: (any Error).self) { try AgentWorkflow.executionPrompt(job) }
    job.analysis?.problems[0].options[0].affectedCloneIDs = ["not-in-context"]
    #expect(throws: (any Error).self) { try job.analysis!.validate(context: context) }
  }
  @Test func testExecutionHandoffQuotesPromptAndKeepsProfile() async throws {
    let (root, context) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let cli = root.appendingPathComponent("fake agent")
    let captured = root.appendingPathComponent("captured")
    let injection = root.appendingPathComponent("must-not-exist")
    let body = """
    #!/bin/sh
    printf '%s\\n' "$CLAUDE_CONFIG_DIR" "$@" > \(shellQuote(captured.path))
    printf 'Working on the fixture\\n'
    sleep 1
    printf 'Finished fixture\\n'
    exit 7
    """
    try body.write(to: cli, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
    var profile = AgentProfile(name: "Work", harness: .claude)
    profile.executable = cli.path; profile.homeDirectory = root.appendingPathComponent("work account").path
    profile.model = "specific-model"
    var job = AgentJob(profile: profile, context: context)
    job.analysis = analysis(context); job.phase = .review
    job.analysis?.summary = "Literal $(touch \(shellQuote(injection.path))) and `echo untrusted`"
    job.selections = ["feature": "branch"]
    let script = try AgentWorkflow.executionScript(job, directory: root.appendingPathComponent("job"))
    let execution = Task { try await ProcessRunner.run("/bin/sh", [script.path]) }
    let jobDirectory = script.deletingLastPathComponent()
    var sawLiveOutput = false
    for _ in 0..<100 {
      let snapshot = try AgentTerminalOutput.read(directory: jobDirectory)
      if snapshot.text.contains("Working on the fixture") && snapshot.exitCode == nil {
        sawLiveOutput = true; break
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(sawLiveOutput)
    let result = try await execution.value
    #expect(result.status == 7)
    let snapshot = try AgentTerminalOutput.read(directory: jobDirectory)
    #expect(snapshot.exitCode == 7)
    #expect(snapshot.text.contains("Finished fixture"))
    let permissions = try FileManager.default.attributesOfItem(atPath: jobDirectory.appendingPathComponent("execution-output.txt").path)
    #expect((permissions[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    let text = try String(contentsOf: captured, encoding: .utf8)
    #expect(text.contains(profile.homeDirectory))
    #expect(text.contains("specific-model"))
    #expect(text.contains("Literal $(touch"))
    #expect(!FileManager.default.fileExists(atPath: injection.path))
    job.phase = .handedOff
    #expect(throws: (any Error).self) { try AgentWorkflow.executionScript(job, directory: root) }
  }
  @Test func testCLIStatusAndMCPProtocol() async throws {
    let (root, context) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let cli = root.appendingPathComponent("fake-cli")
    try "#!/bin/sh\nprintf '%s' '{\"loggedIn\":false}'\n".write(to: cli, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
    var profile = AgentProfile(name: "Fixture", harness: .claude); profile.executable = cli.path
    #expect(await AgentCLI.availability(profile).state == .notLoggedIn)
    try "#!/bin/sh\nprintf '%s' '{\"loggedIn\":true}'\n".write(to: cli, atomically: true, encoding: .utf8)
    #expect(await AgentCLI.availability(profile).state == .ready)
    profile.executable = root.appendingPathComponent("missing").path
    #expect(await AgentCLI.availability(profile).state == .notInstalled)
    let manifest = root.appendingPathComponent("context.json")
    try AgentFiles.write(context, to: manifest)
    let helper = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/repobot")
    let requests: [[String: Any]] = [
      ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [:]],
      ["jsonrpc": "2.0", "id": 2, "method": "tools/list"],
      ["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "inspect_repo", "arguments": ["clone_id": context.targets[0].id, "operation": "read", "path": "widget.py"]]],
      ["jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": ["name": "inspect_repo", "arguments": ["clone_id": "outside", "operation": "read", "path": "widget.py"]]],
    ]
    let input = try requests.reduce(into: Data()) { data, request in data += try JSONSerialization.data(withJSONObject: request) + Data([10]) }
    let response = try await ProcessRunner.run(helper.path, ["agent-mcp", manifest.path], input: input)
    #expect(response.status == 0)
    let messages = try response.text.split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
    #expect(messages.count == 4)
    #expect((messages[2]["result"] as? [String: Any])?["isError"] as? Bool == false)
    #expect((messages[3]["result"] as? [String: Any])?["isError"] as? Bool == true)
    #expect(response.text.contains("new local feature"))
  }
  @Test(.enabled(if: ProcessInfo.processInfo.environment["REPOBOT_TEST_AGENTS"] == "1"))
  func testLiveHarnessAnalysis() async throws {
    let (root, context) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let helper = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/repobot")
    for harness in AgentHarness.allCases {
      let profile = AgentProfile(name: "Live fixture", harness: harness)
      #expect(await AgentCLI.availability(profile).state == .ready)
      let job = AgentJob(profile: profile, context: context)
      let directory = root.appendingPathComponent(harness.rawValue)
      let recorder = ActivityRecorder()
      let result = try await AgentWorkflow.analyze(job, directory: directory, helper: helper, onActivity: recorder.append)
      #expect(recorder.events.contains { $0.kind == .tool })
      #expect(recorder.events.contains { $0.kind == .message })
      print("Live \(harness.rawValue): \(recorder.events.count) activity updates, \(recorder.events.filter { $0.kind == .tool }.count) tool updates")
      try result.validate(context: context)
      let inspected = try String(contentsOf: directory.appendingPathComponent("inspections.jsonl"), encoding: .utf8)
      let calls = try inspected.split(separator: "\n").map {
        try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: String]
      }
      #expect(calls.contains { $0["clone_id"] == context.targets[0].id })
      try await AgentInspection.ensureUnchanged(context)
    }
  }
}
