import Foundation
import Observation
import Testing
@testable import RepobotApp
@testable import RepobotCore

private actor RefreshGate {
  private var continuation: CheckedContinuation<Void, Never>?
  private var released = false
  private(set) var entered = false
  func wait() async {
    entered = true
    if !released { await withCheckedContinuation { continuation = $0 } }
  }
  func release() { released = true; continuation?.resume(); continuation = nil }
}

@MainActor struct AgentReviewSessionTests {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["REPOBOT_TEST_REVIEW_JOB"] != nil))
  func testLiveReviewUsingSavedRequest() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["REPOBOT_TEST_REVIEW_JOB"])
    let request = try AgentFiles.decoder().decode(AgentJob.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    #expect(await AgentCLI.availability(request.profile).state == .ready)
    let root = directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let helper = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("dist/Repobot.app/Contents/MacOS/repobot")
    let session = AgentReviewSession(repositoryID: request.context.repository, base: root, helper: helper)
    session.analyze(profile: request.profile, context: request.context)
    while session.busy {
      withObservationTracking { _ = session.job?.phase; _ = session.job?.context.targets.count } onChange: {}
      try await Task.sleep(for: .milliseconds(100))
    }
    #expect(session.error == nil)
    #expect(session.job?.phase == .review)
    let completed = try #require(session.job)
    let analysis = try #require(completed.analysis)
    try analysis.validate(context: completed.context)
    try await AgentInspection.ensureUnchanged(completed.context)
    print("Live app review: \(completed.context.targets.count) copies, \(analysis.problems.count) proposed problems; repository state unchanged")
  }

  private func context() -> AgentContext {
    let environment = RepobotCore.Environment(name: "Fixture", kind: .local)
    let repo = RepoSnapshot(path: "/fixture/repo")
    return AgentContext(repository: "example.test/repo", targets: [
      AgentTarget(id: "fixture", environment: environment, repo: repo,
                  status: RepoStatus(identity: "example.test/repo", severity: .ok, findings: [], peers: []),
                  fingerprint: nil, inspectionError: nil)
    ], sshPath: "/usr/bin/ssh", sshOptions: [])
  }
  private func directory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("repobot-session-\(UUID())")
  }
  private func awaitRefresh(_ gate: RefreshGate) async throws {
    for _ in 0..<200 {
      if await gate.entered { return }
      try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Refresh did not begin")
  }

  @Test(arguments: AgentHarness.allCases)
  func testObservedJobCanBeReadWhileRefreshSuspends(harness: AgentHarness) async throws {
    let root = directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let gate = RefreshGate()
    let session = AgentReviewSession(repositoryID: "example.test/repo", base: root,
      helper: URL(fileURLWithPath: "/usr/bin/true"), refreshContext: { context in
        await gate.wait()
        var refreshed = context
        refreshed.targets[0].fingerprint = "fresh"
        return refreshed
      }, runAnalysis: { job, _, _, activity in
        activity(AgentActivity(kind: .message, text: "Comparing the copies"))
        #expect(job.phase == .analyzing)
        #expect(job.context.targets[0].fingerprint == "fresh")
        return AgentAnalysis(summary: "Review complete", limitations: [], problems: [])
      })
    session.analyze(profile: AgentProfile(name: "Fixture", harness: harness), context: context())
    try await awaitRefresh(gate)
    // SwiftUI reads these observable properties while the asynchronous refresh
    // is suspended. Holding job's modifying access across await used to abort.
    withObservationTracking {
      #expect(session.job?.phase == .prepared)
      #expect(session.job?.context.targets[0].fingerprint == nil)
      #expect(session.busy)
      session.persist()
    } onChange: {}
    let task = session.task
    await gate.release()
    await task?.value
    #expect(!session.busy)
    #expect(session.task == nil)
    #expect(session.error == nil)
    #expect(session.job?.phase == .review)
    #expect(session.job?.analysis?.summary == "Review complete")
    #expect(session.activity.contains { $0.text == "Comparing the copies" })
    let saved = try AgentFiles.decoder().decode(AgentJob.self, from: Data(contentsOf: try #require(session.directory).appendingPathComponent("job.json")))
    #expect(saved.phase == .review)
    #expect(saved.context.targets[0].fingerprint == "fresh")
  }


  @Test func testActivityIsVisibleWhileAnalysisIsStillRunningAndRestores() async throws {
    let root = directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let gate = RefreshGate()
    let session = AgentReviewSession(repositoryID: "example.test/repo", base: root,
      helper: URL(fileURLWithPath: "/usr/bin/true"), refreshContext: { $0 }, runAnalysis: { _, _, _, activity in
        activity(AgentActivity(id: "partial", kind: .message, text: "Inspecting"))
        activity(AgentActivity(id: "partial", kind: .message, text: "Inspecting the changes"))
        await gate.wait()
        return AgentAnalysis(summary: "Done", limitations: [], problems: [])
      })
    session.analyze(profile: AgentProfile(name: "Fixture", harness: .claude), context: context())
    try await awaitRefresh(gate)
    for _ in 0..<100 {
      if session.activity.contains(where: { $0.text == "Inspecting the changes" }) { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(session.busy)
    #expect(session.job?.analysis == nil)
    #expect(session.activity.filter { $0.id == "partial" }.count == 1)
    #expect(session.activity.contains { $0.text == "Inspecting the changes" })
    let task = session.task
    await gate.release(); await task?.value
    let restored = AgentReviewSession(repositoryID: "example.test/repo", base: root)
    #expect(restored.activity.map(\.id) == session.activity.map(\.id))
    #expect(restored.activity.map(\.text) == session.activity.map(\.text))
    #expect(restored.activity.map(\.kind) == session.activity.map(\.kind))
    #expect(restored.job?.phase == .review)
    for index in 0..<220 { session.record(AgentActivity(kind: .tool, text: "Item \(index)")) }
    #expect(session.activity.count == 200)
  }

  @Test func testExecutionOutputUpdatesBeforeSessionExit() async throws {
    let root = directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = AgentReviewSession(repositoryID: "example.test/repo", base: root)
    var job = AgentJob(profile: AgentProfile(name: "Fixture", harness: .codex), context: context())
    job.phase = .handedOff
    session.job = job
    let jobDirectory = try #require(session.directory)
    let output = jobDirectory.appendingPathComponent("execution-output.txt")
    try AgentFiles.write(Data("Starting…\n".utf8), to: output)
    session.watchExecution()
    for _ in 0..<100 {
      if session.executionOutput.contains("Starting") { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(session.executionRunning)
    #expect(session.executionOutput.contains("Starting"))
    try AgentFiles.write(Data("Changes complete\n".utf8), to: output)
    try AgentFiles.write(Data("7\n".utf8), to: jobDirectory.appendingPathComponent("execution-exit.txt"))
    for _ in 0..<100 {
      if !session.executionRunning { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(!session.executionRunning)
    #expect(session.executionExitCode == 7)
    #expect(session.executionOutput == "Changes complete")
    #expect(session.job?.phase == .handedOff)
    #expect(session.job?.verification == nil)
  }

  @Test func testCancelDuringRefreshDoesNotRunHarness() async throws {
    let root = directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let gate = RefreshGate()
    let session = AgentReviewSession(repositoryID: "example.test/repo", base: root,
      helper: URL(fileURLWithPath: "/usr/bin/true"), refreshContext: { context in
        await gate.wait(); return context
      }, runAnalysis: { _, _, _, _ in
        Issue.record("Cancelled refresh must not launch a coding agent")
        return AgentAnalysis(summary: "Unexpected", limitations: [], problems: [])
      })
    session.analyze(profile: AgentProfile(name: "Fixture", harness: .codex), context: context())
    try await awaitRefresh(gate)
    let task = session.task
    session.cancel()
    await gate.release()
    await task?.value
    #expect(session.job?.phase == .cancelled)
    #expect(!session.busy)
    #expect(session.error == nil)
    #expect(session.job?.analysis == nil)
  }

  @Test func testHarnessFailureIsSavedAndInterruptedReviewDoesNotReplay() async throws {
    let root = directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = AgentReviewSession(repositoryID: "example.test/repo", base: root,
      helper: URL(fileURLWithPath: "/usr/bin/true"), refreshContext: { $0 }, runAnalysis: { _, _, _, _ in
        throw RepobotError.message("Fixture harness failure")
      })
    session.analyze(profile: AgentProfile(name: "Fixture", harness: .codex), context: context())
    await session.task?.value
    #expect(session.job?.phase == .failed)
    #expect(session.error == "Fixture harness failure")
    #expect(!session.busy)
    var interrupted = try #require(session.job)
    interrupted.phase = .prepared
    try AgentFiles.write(interrupted, to: try #require(session.directory).appendingPathComponent("job.json"))
    let restored = AgentReviewSession(repositoryID: "example.test/repo", base: root)
    #expect(restored.job?.phase == .failed)
    #expect(restored.status.contains("interrupted"))
    #expect(restored.task == nil)
  }
}
