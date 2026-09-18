import RepobotCore
import SwiftUI

struct RepositoryMapView: View {
  let state: AppState
  let model: RepositoryMapModel
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      RepositoryMapHeader(state: state)
      RepositoryMapFilters(model: model)
      Text("Uncommitted changes, commits ahead of upstream, and stashes show where work remains. A commit’s date does not tell us which machine you last used.")
        .font(.caption).foregroundStyle(.secondary)
      RepositoryMapMonitoringState(state: state)
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          RepositoryMapProgressView(progress: model.progress)
          RepositoryMapList(state: state, model: model)
        }
      }
    }.padding(22).frame(minWidth: 780, minHeight: 540)
  }
}

private struct RepositoryMapHeader: View {
  let state: AppState
  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: 4) {
        Text("Repository Map").font(.title.bold())
        Text("Find work across your configured machines and repository roots.").foregroundStyle(.secondary)
      }
      Spacer()
      Button(state.checking ? "Checking…" : "Refresh all") { state.check(rescan: true) }
        .disabled(state.checking || !state.configuration.enabled)
    }
  }
}
private struct RepositoryMapFilters: View {
  @Bindable var model: RepositoryMapModel
  var body: some View {
    HStack {
      TextField("Search repository or machine", text: $model.search)
      Toggle("Shared across machines", isOn: $model.sharedOnly)
    }
  }
}
private struct RepositoryMapMonitoringState: View {
  let state: AppState
  var body: some View {
    if !state.configuration.enabled {
      Label("Monitoring paused — showing last known state", systemImage: "pause.circle").foregroundStyle(.orange)
    }
  }
}
private struct RepositoryMapProgressView: View {
  let progress: RepositoryMapProgress
  var body: some View {
    ForEach(progress.messages) { message in
      Text(message.text).font(.caption).foregroundStyle(message.warning ? .orange : .secondary)
    }
  }
}
private struct RepositoryMapList: View {
  let state: AppState
  let model: RepositoryMapModel
  var body: some View {
    let groups = model.visibleGroups
    LazyVStack(alignment: .leading, spacing: 16) {
      if groups.isEmpty {
        ContentUnavailableView("No matching repositories", systemImage: "folder",
          description: Text("Add machines and repository roots in Settings, or change the filter."))
      }
      ForEach(groups) { group in RepositoryMapGroupView(state: state, group: group) }
    }
  }
}
private struct RepositoryMapGroupView: View {
  let state: AppState
  let group: RepositoryMapGroup
  var body: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          Text(group.summary).font(.callout).bold()
          Spacer()
          Button("Ask an agent…") { state.showAgentReview(group.id) }
        }
        ForEach(group.rows) { row in
          Divider()
          RepositoryMapRowView(state: state, row: row)
        }
      }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
    } label: {
      HStack {
        Image(systemName: group.severity >= .attention ? "exclamationmark.triangle" : "folder")
          .foregroundStyle(group.severity >= .attention ? .orange : .secondary)
        Text(group.title)
        Spacer()
        Text("\(group.rows.count) copies · \(group.machineCount) machines").font(.caption).foregroundStyle(.secondary)
      }
    }
  }
}
private struct RepositoryMapRowView: View {
  let state: AppState
  let row: RepositoryMapRow
  var body: some View {
    let content = row.content
    let repo = content.repo
    VStack(alignment: .leading, spacing: 5) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 3) {
          Text(content.environmentName).font(.headline)
          Text(repo.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
        Spacer()
        Text("\(repo.branch ?? "Detached HEAD") · \(repo.headSHA.isEmpty ? "No commits" : String(repo.headSHA.prefix(8)))")
          .font(.system(.callout, design: .monospaced))
        Button("Details…") { state.showDetail(row.clone) }
      }
      if content.unverified {
        Text(repo.awaitingFreshCheck == true && !content.unavailable
             ? "Waiting for this copy’s fresh check — showing last known state"
             : "Last known state — current work is unverified").foregroundStyle(.orange)
      }
      let signals = Analyzer.workSignals(repo)
      Text(signals.isEmpty ? "Working tree clean · no pending pushes detected" : signals.joined(separator: " · "))
        .font(.callout)
      if let upstream = repo.upstream {
        Text("Tracks \(upstream) · \(repo.ahead) ahead / \(repo.behind) behind last fetched state")
          .font(.caption).foregroundStyle(.secondary)
      }
      ForEach(content.status.peers) { peer in
        Text("Compared with \(peer.environmentName): \(peer.text)").font(.caption)
      }
      HStack {
        if !repo.headSHA.isEmpty {
          Text("Last commit \(repo.lastCommitDate.formatted(.relative(presentation: .named)))")
        }
        RepositoryMapCheckedTime(row: row)
      }.font(.caption2).foregroundStyle(.secondary)
    }
  }
}
private struct RepositoryMapCheckedTime: View {
  let row: RepositoryMapRow
  var body: some View {
    Text("Checked \(row.checkedAt.formatted(.relative(presentation: .named)))")
  }
}
