import RepobotCore
import SwiftUI

struct RepositoryMapView: View {
  let state: AppState
  let model: RepositoryMapModel

  var body: some View {
    VStack(spacing: 0) {
      RepositoryMapHeader(state: state)
      Divider()
      HSplitView {
        RepositoryMapSidebar(model: model)
          .frame(minWidth: 260, idealWidth: 300, maxWidth: 380)
        Group {
          if let group = model.selectedGroup {
            RepositoryMapGroupView(state: state, group: group).id(group.id)
          } else {
            ContentUnavailableView("No matching repositories", systemImage: "folder",
              description: Text("Change your search or filter, or add repository roots in Settings."))
              .frame(maxWidth: .infinity, maxHeight: .infinity)
          }
        }
        .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
      }
      RepositoryMapProgressView(progress: model.progress)
    }
    .frame(minWidth: 800, minHeight: 540)
  }
}

private struct RepositoryMapHeader: View {
  let state: AppState
  var body: some View {
    HStack {
      Text("Repository Map").font(.title2.bold())
      Spacer()
      if !state.configuration.enabled {
        Label("Monitoring paused · Last known state", systemImage: "pause.circle")
          .font(.callout).foregroundStyle(.orange)
      }
      Button(state.checking ? "Checking…" : "Refresh all") { state.check(rescan: true) }
        .disabled(state.checking || !state.configuration.enabled)
    }.padding(.horizontal, 22).padding(.vertical, 16)
  }
}

private struct RepositoryMapSidebar: View {
  @Bindable var model: RepositoryMapModel
  @FocusState private var searchFocused: Bool

  var body: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 6) {
          Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
          TextField("Search repositories", text: $model.search)
            .textFieldStyle(.plain).focused($searchFocused)
            .help("Search by repository, path, or machine")
          if !model.search.isEmpty {
            Button { model.search = "" } label: {
              Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }.buttonStyle(.plain).help("Clear search").accessibilityLabel("Clear search")
          }
        }
        .padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
        Toggle("Shared across machines", isOn: $model.sharedOnly)
          .toggleStyle(.checkbox).font(.callout)
      }.padding(14)
      Divider()
      List(selection: $model.selectedGroupID) {
        ForEach(model.visibleGroups) { group in
          RepositoryMapListRow(group: group).tag(group.id)
        }
      }
      .listStyle(.sidebar)
      .overlay {
        if model.visibleGroups.isEmpty {
          Text("No results").foregroundStyle(.secondary)
        }
      }
      Divider()
      Text(model.visibleGroups.count == 1 ? "1 repository" : "\(model.visibleGroups.count) repositories")
        .font(.caption).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
    }
    .background {
      Button("Find repository") { searchFocused = true }
        .keyboardShortcut("f", modifiers: .command).hidden()
    }
  }
}

private struct RepositoryMapListRow: View {
  let group: RepositoryMapGroup
  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: group.severity >= .attention ? "exclamationmark.triangle" : "folder")
        .foregroundStyle(group.severity >= .attention ? .orange : .secondary)
        .frame(width: 18).padding(.top, 2)
      VStack(alignment: .leading, spacing: 4) {
        Text(group.name).font(.headline).lineLimit(1).truncationMode(.middle)
        Text(group.location).font(.caption).foregroundStyle(.secondary)
          .lineLimit(1).truncationMode(.middle)
        Text("\(group.rows.count) copies · \(group.machineCount) machines")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 6)
    .help(group.title + "\n" + group.summary)
    .accessibilityElement(children: .combine)
  }
}

private struct RepositoryMapProgressView: View {
  let progress: RepositoryMapProgress
  @State private var expanded = false
  var body: some View {
    let messages = progress.messages + progress.clockMessages
    if !messages.isEmpty {
      Divider()
      DisclosureGroup(isExpanded: $expanded) {
        ScrollView {
          VStack(alignment: .leading, spacing: 6) {
            ForEach(messages) { message in
              Text(message.text).font(.caption).foregroundStyle(message.warning ? .orange : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
          }.padding(.top, 8)
        }.frame(maxHeight: 100)
      } label: {
        let warnings = messages.filter(\.warning).count
        let count = "\(warnings) \(warnings == 1 ? "warning" : "warnings")"
        Label(!progress.clockMessages.isEmpty ? "Clock check needs attention · \(count)"
              : warnings > 0 ? "Monitoring · \(count)" : "Checking repositories…",
              systemImage: warnings > 0 ? "exclamationmark.triangle" : "arrow.triangle.2.circlepath")
          .font(.caption).foregroundStyle(warnings > 0 ? .orange : .secondary)
      }.padding(.horizontal, 22).padding(.vertical, 10)
    }
  }
}

private struct RepositoryMapGroupView: View {
  let state: AppState
  let group: RepositoryMapGroup
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        VStack(alignment: .leading, spacing: 6) {
          Text(group.name).font(.title.bold()).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
          Text(group.location).foregroundStyle(.secondary).textSelection(.enabled)
          Text("\(group.rows.count) copies across \(group.machineCount) machines")
            .font(.callout).foregroundStyle(.secondary)
        }
        VStack(alignment: .leading, spacing: 14) {
          Label(group.summary, systemImage: group.severity >= .attention ? "exclamationmark.triangle" : "folder")
            .font(.headline).fixedSize(horizontal: false, vertical: true)
          HStack(spacing: 0) {
            RepositoryMapMetric(value: group.overview.changedCopies, title: "Copies with changes")
            Divider()
            RepositoryMapMetric(value: group.overview.pendingPushCopies, title: "Copies to push")
            Divider()
            RepositoryMapMetric(value: group.overview.stashes, title: "Stashes across copies")
          }.fixedSize(horizontal: false, vertical: true)
          if group.overview.unverifiedCopies > 0 {
            Label("\(group.overview.unverifiedCopies) copies unverified · Counts include checked copies only",
                  systemImage: "clock.badge.exclamationmark")
              .font(.caption).foregroundStyle(.orange)
          }
          Button("Ask an agent…") { state.showAgentReview(group.id) }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        VStack(alignment: .leading, spacing: 12) {
          HStack {
            Text("Repository copies").font(.headline)
            Spacer()
            Text("Expand to compare").font(.caption).foregroundStyle(.secondary)
          }
          ForEach(group.rows) { row in
            RepositoryMapCopyView(state: state, row: row)
          }
        }
        Text("Ages use each machine’s clock at its last check. Newest file is the latest file modification, including ignored files, excluding Git and macOS filesystem metadata. Checkouts and generated files can make it recent. Push status uses the last fetched upstream.")
          .font(.caption).foregroundStyle(.secondary)
      }.padding(24)
    }
  }
}

private struct RepositoryMapMetric: View {
  let value: Int
  let title: String
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(value, format: .number).font(.title2.weight(.semibold))
      Text(title).font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8)
  }
}

private struct RepositoryMapCopyView: View {
  let state: AppState
  let row: RepositoryMapRow
  @State private var expanded = false

  var body: some View {
    let content = row.content
    let repo = content.repo
    DisclosureGroup(isExpanded: $expanded) {
      VStack(alignment: .leading, spacing: 10) {
        Divider()
        Text(repo.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        Text("\(repo.branch ?? "Detached HEAD") · \(repo.headSHA.isEmpty ? "No commits" : String(repo.headSHA.prefix(8)))")
          .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
        let signals = Analyzer.workSignals(repo)
        Text(signals.isEmpty ? "Working tree clean · no pending pushes detected" : signals.joined(separator: " · "))
          .font(.callout)
        if let upstream = repo.upstream {
          Text("Tracks \(upstream) · \(repo.ahead) ahead / \(repo.behind) behind last fetched state")
            .font(.caption).foregroundStyle(.secondary)
        }
        if !content.status.peers.isEmpty {
          Text("Comparison with other copies").font(.caption.bold())
          ForEach(content.status.peers) { peer in
            Text("\(peer.environmentName): \(peer.text)").font(.caption)
          }
        }
        RepositoryAgeView(age: row.age, lastCommitDate: repo.headSHA.isEmpty ? nil : repo.lastCommitDate, detailed: true)
        RepositoryMapCheckedTime(row: row).font(.caption2).foregroundStyle(.secondary)
        Button("Details…") { state.showDetail(row.clone) }
      }
      .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 10)
    } label: {
      VStack(alignment: .leading, spacing: 5) {
        HStack {
          Text(content.environmentName).font(.headline)
          Spacer()
          Text(repo.branch ?? "Detached HEAD").font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
        if content.unverified {
          Label(content.unavailable ? "Unavailable · Last known state" : "Awaiting fresh check · Last known state",
                systemImage: "clock.badge.exclamationmark")
            .font(.caption).foregroundStyle(.orange)
        } else {
          Text(copySummary).font(.callout).foregroundStyle(.secondary)
        }
        RepositoryMapCopyAge(row: row)
      }.padding(.vertical, 4)
    }
    .padding(12)
    .background(.background, in: RoundedRectangle(cornerRadius: 8))
    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
  }

  private var copySummary: String {
    let repo = row.content.repo
    if repo.conflicted > 0 { return "Unresolved conflicts" }
    if repo.operation != .none { return "\(repo.operation.rawValue.capitalized) in progress" }
    var parts: [String] = []
    if repo.dirty { parts.append("Uncommitted changes") }
    if !Analyzer.pushSummary(repo).isEmpty { parts.append("Pending push") }
    if repo.stashCount > 0 { parts.append("\(repo.stashCount) stashes") }
    if repo.detachedCommits > 0 { parts.append("Detached commits") }
    if (repo.branchWork ?? []).contains(where: { $0.upstream == nil }) { parts.append("Unpublished branches") }
    return parts.isEmpty ? "No outstanding work detected" : parts.joined(separator: " · ")
  }
}

private struct RepositoryMapCopyAge: View {
  let row: RepositoryMapRow
  var body: some View {
    RepositoryAgeView(age: row.age,
      lastCommitDate: row.content.repo.headSHA.isEmpty ? nil : row.content.repo.lastCommitDate)
  }
}

private struct RepositoryMapCheckedTime: View {
  let row: RepositoryMapRow
  var body: some View {
    Text("Checked \(row.checkedAt.formatted(.relative(presentation: .named)))")
  }
}
