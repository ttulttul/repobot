import Foundation
import Observation
import RepobotCore

typealias AgentAnalysisRunner = @Sendable (AgentJob, URL, URL, @escaping @Sendable (AgentActivity) -> Void) async throws -> AgentAnalysis

@MainActor @Observable final class AgentReviewSession {
  let repositoryID: String
  var profileID: UUID?
  var model = ""
  var job: AgentJob?
  var busy = false
  var status = "Choose an agent profile to examine these repository copies."
  var error: String?
  var task: Task<Void, Never>?
  var activity: [AgentActivity] = []
  var executionOutput = ""
  var executionRunning = false
  var executionExitCode: Int?
  @ObservationIgnored private var executionWatch: Task<Void, Never>?
  @ObservationIgnored private var lastActivitySave = Date.distantPast
  let base: URL
  private let helperOverride: URL?
  private let refreshContext: @Sendable (AgentContext) async -> AgentContext
  private let runAnalysis: AgentAnalysisRunner
  init(
    repositoryID: String,
    base: URL = Persistence.defaultDirectory.appendingPathComponent("agent-reviews"),
    helper: URL? = nil,
    refreshContext: @escaping @Sendable (AgentContext) async -> AgentContext = { await AgentInspection.refresh($0) },
    runAnalysis: @escaping AgentAnalysisRunner = {
      try await AgentWorkflow.analyze($0, directory: $1, helper: $2, onActivity: $3)
    }
  ) {
    self.repositoryID = repositoryID
    self.base = base
    self.helperOverride = helper
    self.refreshContext = refreshContext
    self.runAnalysis = runAnalysis
    // Restore the latest review without rerunning a harness or replaying execution.
    if let dirs = try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) {
      let jobs = dirs.compactMap { directory -> AgentJob? in
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("job.json")) else { return nil }
        return try? AgentFiles.decoder().decode(AgentJob.self, from: data)
      }.filter { $0.context.repository == repositoryID }.sorted { $0.createdAt > $1.createdAt }
      if var saved = jobs.first {
        if saved.phase == .analyzing || saved.phase == .prepared {
          saved.phase = .failed; saved.message = "Previous analysis was interrupted. Analyze again."
        }
        job = saved; profileID = saved.profile.id; model = saved.profile.model
        status = saved.message
        let activityFile = base.appendingPathComponent(saved.id.uuidString).appendingPathComponent("activity.json")
        if let data = try? Data(contentsOf: activityFile), data.count <= 3_000_000,
          let entries = try? AgentFiles.decoder().decode([AgentActivity].self, from: data) {
          activity = Array(entries.suffix(200))
        }
      }
    }
  }
  var directory: URL? { job.map { base.appendingPathComponent($0.id.uuidString) } }
  var helper: URL {
    helperOverride ?? Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("repobot")
  }
  func persist() {
    guard let job, let directory else { return }
    do { try AgentFiles.write(job, to: directory.appendingPathComponent("job.json")) }
    catch { self.error = "Could not save review: \(error.localizedDescription)" }
  }
  func analyze(state: AppState) {
    guard !busy, job?.phase != .handedOff, let profile = state.agents.profiles.first(where: { $0.id == profileID }),
      let group = state.world.repositories.first(where: { $0.id == repositoryID }) else { return }
    var selectedProfile = profile; selectedProfile.model = model
    analyze(profile: selectedProfile, context: AgentWorkflow.context(for: group, world: state.world, configuration: state.configuration))
  }
  func analyze(profile: AgentProfile, context: AgentContext) {
    guard !busy, job?.phase != .handedOff else { return }
    busy = true; error = nil; status = "Refreshing deterministic repository status…"
    activity = []; executionOutput = ""; executionExitCode = nil
    let initialJob = AgentJob(profile: profile, context: context)
    let jobDirectory = base.appendingPathComponent(initialJob.id.uuidString)
    job = initialJob
    record(AgentActivity(kind: .status, text: status))
    persist()
    task = Task { [self] in
      let (events, continuation) = AsyncStream<AgentActivity>.makeStream(bufferingPolicy: .bufferingNewest(256))
      let consume = Task { [weak self] in
        for await event in events { self?.record(event) }
      }
      defer { busy = false; task = nil; saveActivity() }
      var currentJob = initialJob
      do {
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
          throw RepobotError.message("Agent helper is missing. Rebuild the app bundle.")
        }
        // Never hold a modifying access to an @Observable property across await.
        // SwiftUI can read job while inspection suspends, and reading job on the
        // right side of job?.context = ... also violates Swift exclusivity.
        let context = currentJob.context
        let refreshed = await refreshContext(context)
        try Task.checkCancellation()
        currentJob.context = refreshed
        for target in refreshed.targets {
          record(AgentActivity(kind: target.inspectionError == nil ? .status : .error,
            text: "\(target.environment.name): " + (target.inspectionError ?? "Repository status refreshed.")))
        }
        guard refreshed.targets.contains(where: { $0.inspectionError == nil }) else {
          throw RepobotError.message("No repository copies could be inspected. Check the machine connections first.")
        }
        currentJob.phase = .analyzing
        job = currentJob
        status = "Agent is examining the copies and preparing resolutions…"
        persist()
        let result = try await runAnalysis(currentJob, jobDirectory, helper, { continuation.yield($0) })
        continuation.finish()
        await consume.value
        try Task.checkCancellation()
        currentJob.analysis = result; currentJob.phase = .review
        status = result.problems.isEmpty ? "Analysis complete. No resolutions proposed." : "Review the problems and choose a resolution for each one you want to address."
        currentJob.message = status; job = currentJob; persist()
        record(AgentActivity(kind: .status, text: status))
      } catch {
        continuation.finish()
        await consume.value
        currentJob.phase = Task.isCancelled ? .cancelled : .failed
        status = Task.isCancelled ? "Analysis cancelled. No resolution was executed." : "Analysis failed."
        self.error = Task.isCancelled ? nil : error.localizedDescription
        currentJob.message = self.error ?? status; job = currentJob; persist()
        record(AgentActivity(kind: Task.isCancelled ? .status : .error, text: self.error ?? status))
      }
    }
  }
  func record(_ event: AgentActivity) {
    if let index = activity.firstIndex(where: { $0.id == event.id }) {
      activity[index].text = event.text; activity[index].kind = event.kind
    } else {
      activity.append(event)
      if activity.count > 200 { activity.removeFirst(activity.count - 200) }
    }
    if Date().timeIntervalSince(lastActivitySave) > 2 { saveActivity() }
  }
  private func saveActivity() {
    guard let directory else { return }
    do {
      try AgentFiles.write(activity, to: directory.appendingPathComponent("activity.json"))
      lastActivitySave = Date()
    } catch { self.error = "Could not save agent activity: \(error.localizedDescription)" }
  }
  func select(problem: String, option: String) {
    job?.selections[problem] = option.isEmpty ? nil : option
    persist()
  }
  func execute(state: AppState) {
    guard !busy, let job, job.phase == .review else { return }
    busy = true; error = nil; status = "Checking that repository state still matches this analysis…"
    task = Task {
      defer { busy = false; task = nil }
      do {
        _ = try AgentWorkflow.selectedOptions(job)
        guard (await AgentCLI.availability(job.profile)).state == .ready else {
          throw RepobotError.message("This profile is no longer logged in. Repair its login before continuing.")
        }
        try await AgentInspection.ensureUnchanged(job.context)
        try Task.checkCancellation()
        let script = try AgentWorkflow.executionScript(job, directory: directory!)
        guard state.terminal("/bin/sh " + shellQuote(script.path)) else {
          throw RepobotError.message("Could not open Terminal. The selected resolutions were not handed off.")
        }
        self.job?.phase = .handedOff
        status = "Execution opened in Terminal using \(job.profile.name). When the agent finishes, verify the repository status here."
        self.job?.message = status; persist()
        watchExecution()
      } catch { self.error = error.localizedDescription; status = "Execution was not started." }
    }
  }
  func verify(state: AppState) {
    guard !busy, !executionRunning, let job else { return }
    busy = true; error = nil; status = "Re-checking all copies…"
    task = Task {
      defer { busy = false; task = nil }
      let refreshed = await AgentInspection.refresh(job.context)
      guard !Task.isCancelled else { status = "Verification cancelled"; return }
      let report = refreshed.targets.map { target in
        if let error = target.inspectionError { return "\(target.environment.name): \(error)" }
        let work = Analyzer.workSignals(target.repo)
        return "\(target.environment.name) · \(target.repo.branch ?? "Detached HEAD") · \(target.repo.headSHA.prefix(8))\n"
          + (work.isEmpty ? "Working tree clean; no pending work detected." : work.joined(separator: " · "))
      }.joined(separator: "\n\n")
      self.job?.verification = report
      self.job?.phase = refreshed.targets.contains { $0.inspectionError != nil } ? .handedOff : .verified
      status = "Fresh status captured. Review this alongside the agent’s execution report; semantic completion is not assumed."
      self.job?.message = status; persist()
      state.check()
    }
  }
  func watchExecution() {
    guard executionWatch == nil, let directory, job?.phase == .handedOff || job?.phase == .verified,
      FileManager.default.fileExists(atPath: directory.appendingPathComponent("execution-output.txt").path) else { return }
    executionRunning = job?.phase == .handedOff
    executionWatch = Task { [weak self] in
      defer { self?.executionWatch = nil }
      while !Task.isCancelled {
        do {
          let snapshot = try await Task.detached(priority: .utility) {
            try AgentTerminalOutput.read(directory: directory)
          }.value
          guard let self else { return }
          if executionOutput != snapshot.text { executionOutput = snapshot.text }
          executionExitCode = snapshot.exitCode
          if let code = snapshot.exitCode {
            executionRunning = false
            if job?.phase != .verified { status = code == 0
              ? "Agent session ended. Verify the repository status to check the result."
              : "Agent session exited with status \(code). Review its output and verify repository status." }
            return
          }
          if job?.phase == .verified { executionRunning = false; return }
        } catch {
          self?.error = "Could not read live Terminal output: \(error.localizedDescription)"
          self?.executionRunning = false
          return
        }
        do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
      }
    }
  }
  func cancel() { task?.cancel() }
}
