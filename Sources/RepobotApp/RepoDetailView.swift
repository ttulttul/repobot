import RepobotCore
import SwiftUI

struct RepoDetailView: View {
  @Bindable var state: AppState
  let cloneID: String
  var clone: Clone? { state.world.clones.first { $0.id == cloneID } }
  var body: some View {
    if let clone, let env = state.world.environments.first(where: { $0.id == clone.environmentID })
    {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          HStack(alignment: .top) {
            Image(
              systemName: clone.status.severity >= .attention
                ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
            ).font(.largeTitle).foregroundStyle(
              clone.status.severity == .problem
                ? .red : clone.status.severity == .attention ? .orange : .green)
            VStack(alignment: .leading) {
              Text(state.headline(for: clone)).font(.title2.bold())
              Text("\(env.environment.name) · \(clone.repo.path)").font(.caption).foregroundStyle(
                .secondary
              ).textSelection(.enabled)
            }
          }
          if let error = env.error {
            Label("Last known state — \(error)", systemImage: "wifi.exclamationmark")
              .foregroundStyle(.orange)
          }
          GroupBox("Branch & upstream") {
            VStack(alignment: .leading, spacing: 8) {
              Text(
                "\(clone.repo.branch ?? "Detached HEAD") → \(clone.repo.upstream ?? "No upstream")"
              ).font(.headline)
              Text("\(clone.repo.ahead) ahead · \(clone.repo.behind) behind (last fetched state)")
              Text("\(clone.repo.headSHA.prefix(10)) · \(clone.repo.lastCommitSubject)")
                .textSelection(.enabled)
              Text(
                "Committed \(clone.repo.lastCommitDate.formatted(.relative(presentation:.named))) · Checked \(clone.repo.probedAt.formatted(.relative(presentation:.named)))"
              ).font(.caption).foregroundStyle(.secondary)
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
                      Text("Last commit \(peer.lastActivity.formatted(.relative(presentation: .named)))").font(
                        .caption2
                      ).foregroundStyle(.secondary)
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
                  Button("Copy") { copyText(command) }
                }
              }
            }
          }
          HStack {
            Button("Repository Map…") { state.showRepositoryMap() }
            Button("Ask an agent about these copies…") { state.showAgentReview(clone.status.identity) }
          }
          HStack {
            Button("Open in Terminal") {
              state.openTerminal(env.environment, path: clone.repo.path)
            }
            if env.environment.kind == .local {
              Button("Reveal in Finder") {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: clone.repo.path)
              }
            }
            Button("Re-check") { state.check(clone.environmentID) }
            Menu("Snooze") {
              Button("1 hour") { state.snooze(clone, until: Date().addingTimeInterval(3600)) }
              Button("Until tomorrow") {
                state.snooze(
                  clone,
                  until: Calendar.current.startOfDay(for: Date()).addingTimeInterval(
                    86400 + 8 * 3600))
              }
              Button("Resume warnings") {
                state.configuration.snoozed[clone.id] = nil
                state.save()
              }
            }
            Button("Ignore repo") { state.ignore(clone) }
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
