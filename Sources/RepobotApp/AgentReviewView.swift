import RepobotCore
import SwiftUI

struct AgentReviewView: View {
  @Bindable var state: AppState
  @State var session: AgentReviewSession
  @State private var confirmExecution = false
  var selectedProfile: AgentProfile? { state.agents.profiles.first { $0.id == session.profileID } }
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        Text("Resolve with a coding agent").font(.title.bold())
        Text(session.repositoryID).font(.caption).textSelection(.enabled)
        Text("The agent examines status, diffs and source across these copies, then proposes resolutions for you to choose. Analysis uses your selected provider and account.")
          .foregroundStyle(.secondary)
        HStack {
          Picker("Agent profile", selection: $session.profileID) {
            Text("Choose an account").tag(Optional<UUID>.none)
            ForEach(state.agents.profiles) { profile in
              Text("\(profile.name) · \(state.agents.availability[profile.id]?.message ?? "Not checked")")
                .tag(Optional(profile.id))
            }
          }.disabled(session.busy)
          Button("Configure agents…") { state.showAgentSettings() }
          Button("Check logins") { Task { await state.agents.refresh() } }.disabled(state.agents.checking)
        }
        HStack {
          TextField("Model ID or alias (blank = harness default)", text: $session.model).disabled(session.busy)
          Button("Use harness default") { session.model = "" }.disabled(session.busy)
        }
        if let profile = selectedProfile, state.agents.availability[profile.id]?.state != .ready {
          Button("Log in / repair in Terminal…") {
            do { state.terminal(try AgentCLI.loginCommand(profile)) }
            catch { session.error = error.localizedDescription }
          }
        }
        HStack {
          Button("Analyze repositories") { session.analyze(state: state) }
            .buttonStyle(.borderedProminent)
            .disabled(session.busy || session.job?.phase == .handedOff || selectedProfile.map { state.agents.availability[$0.id]?.state != .ready } ?? true)
          if session.busy {
            ProgressView().controlSize(.small)
            Button("Cancel") { session.cancel() }
          }
          Text(session.status).font(.caption)
        }
        if let error = session.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        if !session.activity.isEmpty || session.busy {
          AgentActivityView(session: session)
        }
        if session.job?.phase == .handedOff || session.job?.phase == .verified {
          AgentExecutionOutputView(session: session)
          Button("Agent finished — verify repository status") { session.verify(state: state) }
            .disabled(session.busy || session.executionRunning)
        }
        if let job = session.job, let analysis = job.analysis {
          Divider()
          Text("Analysis by \(job.profile.name) · \(job.profile.model.isEmpty ? "harness default model" : job.profile.model)")
            .font(.caption).foregroundStyle(.secondary)
          Text(analysis.summary).textSelection(.enabled)
          ForEach(Array(analysis.limitations.enumerated()), id: \.offset) { _, limitation in
            Label(limitation, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
          }
          ForEach(analysis.problems) { problem in
            GroupBox(problem.title) {
              VStack(alignment: .leading, spacing: 10) {
                Text(problem.explanation).textSelection(.enabled)
                ForEach(Array(problem.evidence.enumerated()), id: \.offset) { _, evidence in
                  Text("• " + evidence).font(.caption).textSelection(.enabled)
                }
                Picker("Resolution", selection: Binding(
                  get: { session.job?.selections[problem.id] ?? "" },
                  set: { session.select(problem: problem.id, option: $0) })) {
                  Text("Leave this problem unchanged").tag("")
                  ForEach(problem.options) { option in Text(option.title).tag(option.id) }
                }.disabled(session.busy || job.phase != .review)
                ForEach(problem.options) { option in
                  DisclosureGroup(option.title + (option.destructive ? " — can discard or rewrite work" : "")) {
                    VStack(alignment: .leading, spacing: 5) {
                      Text(option.explanation)
                      ForEach(Array(option.steps.enumerated()), id: \.offset) { index, step in Text("\(index + 1). \(step)") }
                      ForEach(Array(option.risks.enumerated()), id: \.offset) { _, risk in
                        Text("Risk: " + risk).foregroundStyle(.orange)
                      }
                      Text("Copies: " + option.affectedCloneIDs.compactMap { id in
                        job.context.targets.first { $0.id == id }.map { "\($0.environment.name): \($0.repo.path)" }
                      }.joined(separator: "; ")).font(.caption)
                    }.padding(.vertical, 5).textSelection(.enabled)
                  }
                }
              }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }
          }
          if job.phase == .review && !analysis.problems.isEmpty {
            Button("Execute selected resolutions…") { confirmExecution = true }
              .buttonStyle(.borderedProminent).disabled(session.busy || job.selections.isEmpty)
            Text("Opens the selected agent in Terminal. Its normal permission prompts still apply. Unselected problems are left unchanged.")
              .font(.caption).foregroundStyle(.secondary)
          }
          if let verification = job.verification {
            GroupBox("Verification") { Text(verification).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
          }
        }
      }.padding(24)
    }.frame(minWidth: 800, minHeight: 620)
      .task {
        session.watchExecution()
        await state.agents.refresh()
        if session.profileID == nil, let profile = state.agents.profiles.first(where: { state.agents.availability[$0.id]?.state == .ready }) {
          session.profileID = profile.id; session.model = profile.model
        }
      }
      .onChange(of: session.profileID) { _, id in
        if let profile = state.agents.profiles.first(where: { $0.id == id }) { session.model = profile.model }
      }
      .confirmationDialog("Execute these selected resolutions?", isPresented: $confirmExecution, titleVisibility: .visible) {
        Button("Open agent to execute selections") { session.execute(state: state) }
        Button("Cancel", role: .cancel) {}
      } message: {
        let options = session.job.flatMap { try? AgentWorkflow.selectedOptions($0) } ?? []
        Text(options.map { $0.title + ($0.destructive ? " (destructive; backup required)" : "") }.joined(separator: "\n"))
      }
  }
}
