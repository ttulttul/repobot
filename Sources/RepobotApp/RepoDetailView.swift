import RepobotCore
import SwiftUI

struct RepoDetailView: View {
  @Bindable var state: AppState
  let cloneID: String
  var clone: Clone? { state.world.clones.first { $0.id == cloneID } }
  var body: some View {
    if let clone, let env = state.world.environments.first(where: { $0.id == clone.environmentID })
    {
      let freshness = state.freshness(for: clone)
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          HStack(alignment: .top) {
            Image(
              systemName: !freshness.isCurrent ? freshness.symbol : clone.status.severity >= .attention
                ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
            ).font(.largeTitle).foregroundStyle(
              !freshness.isCurrent ? Color.secondary : clone.status.severity == .problem
                ? .red : clone.status.severity == .attention ? .orange : .green)
            VStack(alignment: .leading) {
              Text(state.headline(for: clone)).font(.title2.bold())
              Text("\(env.environment.name) · \(clone.repo.path)").font(.caption).foregroundStyle(
                .secondary
              ).textSelection(.enabled)
            }
          }
          if let error = freshness.error { OperationErrorView(message: error) }
          if let error = state.error { OperationErrorView(message: error) }
          GroupBox("Branch & upstream") {
            VStack(alignment: .leading, spacing: 8) {
              Text(
                "\(clone.repo.branch ?? "Detached HEAD") → \(clone.repo.upstream ?? "No upstream")"
              ).font(.headline)
              Text("\(clone.repo.ahead) ahead · \(clone.repo.behind) behind (last fetched state)")
              Text("\(clone.repo.headSHA.prefix(10)) · \(clone.repo.lastCommitSubject)")
                .textSelection(.enabled)
              RepositoryAgeView(age: clone.repo.age,
                lastCommitDate: clone.repo.headSHA.isEmpty ? nil : clone.repo.lastCommitDate, detailed: true)
              Text("Checked \(clone.repo.probedAt.formatted(.relative(presentation:.named)))")
                .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
          }
          GroupBox("Working tree") {
            VStack(alignment: .leading, spacing: 6) {
              Text(
                "\(clone.repo.staged) staged · \(clone.repo.modified) modified · \(clone.repo.untracked) untracked · \(clone.repo.conflicted) conflicted"
              )
              ForEach(Array(clone.repo.changedPaths.enumerated()), id: \.offset) { _, path in
                Text(path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
              }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
          }
          let work = Analyzer.workSignals(clone.repo)
          if !work.isEmpty {
            GroupBox("Work on this machine") {
              Text(work.joined(separator: "\n"))
                .frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }
          }
          if !clone.status.peers.isEmpty {
            GroupBox("Other copies") {
              VStack(alignment: .leading, spacing: 10) {
                ForEach(clone.status.peers) { peer in
                  HStack {
                    VStack(alignment: .leading) {
                      Button(peer.environmentName) {
                        if let other = state.world.clones.first(where: { $0.id == peer.id }) {
                          state.showDetail(other)
                        }
                      }.buttonStyle(.link)
                      Text(peer.path).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing) {
                      Text("\(peer.branch ?? "Detached") · \(peer.tip.prefix(8))")
                      Text(peer.text).font(.caption)
                      if let other = state.world.clones.first(where: { $0.id == peer.id }) {
                        RepositoryAgeView(age: other.repo.age,
                          lastCommitDate: other.repo.headSHA.isEmpty ? nil : other.repo.lastCommitDate)
                      }
                    }
                  }
                }
              }.padding(6)
            }
          }
          ForEach(Array(clone.status.findings.enumerated()), id: \.offset) { _, finding in
            VStack(alignment: .leading, spacing: 6) {
              Text(finding.text)
              if let command = finding.command {
                HStack {
                  Text(command).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                  Spacer()
                  Button("Copy") { copyText(command) }.accessibilityLabel("Copy command: " + command)
                }
              }
            }
          }
          let nested = state.world.clones.filter {
            $0.environmentID == clone.environmentID && $0.repo.path.hasPrefix(clone.repo.path + "/")
          }.count
          if nested > 0 || state.configuration.skipsNestedRepositories(clone.id) {
            Toggle(isOn: Binding(get: { state.configuration.skipsNestedRepositories(clone.id) },
                                 set: { state.setSkipsNestedRepositories($0, for: clone) })) {
              VStack(alignment: .leading, spacing: 2) {
                Text("Don’t explore repositories inside this one")
                Text(nested > 0 ? "\(nested) nested \(nested == 1 ? "repository is" : "repositories are") currently monitored as separate work."
                     : "Repositories beneath this folder are not monitored.")
                  .font(.caption).foregroundStyle(.secondary)
              }
            }
          }
          HStack {
            Button("Repository Map…") { state.showRepositoryMap() }
            Button("Ask an agent about these copies…") { state.showAgentReview(clone.status.identity) }
          }
          FlowLayout {
            Button("Open in Terminal") {
              state.openTerminal(env.environment, path: clone.repo.path)
            }
            if env.environment.kind == .local {
              Button("Reveal in Finder") {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: clone.repo.path)
              }
            }
            Button(state.checking ? "Checking…" : "Check Now") { state.check(clone.environmentID) }.disabled(state.checking)
            Menu("Snooze") {
              Button("1 hour") { state.snooze(clone, until: Date().addingTimeInterval(3600)) }
              Button("Until tomorrow") {
                state.snooze(
                  clone,
                  until: Calendar.current.startOfDay(for: Date()).addingTimeInterval(
                    86400 + 8 * 3600))
              }
              Button("Resume warnings") {
                state.resumeWarnings(clone)
              }
            }
            if state.configuration.ignored.contains(clone.id) {
              Button("Restore Warnings") { state.resumeWarnings(clone) }
            } else {
              Button("Ignore Repository") { state.ignore(clone) }
            }
          }
        }.padding(24)
      }.frame(minWidth: 620, minHeight: 460)
    } else {
      ContentUnavailableView(
        "Repository unavailable", systemImage: "folder.badge.questionmark",
        description: Text("It may have moved or its environment was removed."))
    }
  }
}
