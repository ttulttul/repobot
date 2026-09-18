import RepobotCore
import SwiftUI

struct AgentActivityView: View {
  @Bindable var session: AgentReviewSession
  @State private var follow = true
  @State private var expanded = true
  var body: some View {
    GroupBox {
      DisclosureGroup(isExpanded: $expanded) {
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
              ForEach(session.activity) { event in
                HStack(alignment: .top, spacing: 10) {
                  Image(systemName: symbol(event.kind)).foregroundStyle(event.kind == .error ? .orange : .secondary)
                    .frame(width: 16)
                  VStack(alignment: .leading, spacing: 3) {
                    Text(event.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                      .font(event.kind == .message ? .callout : .caption)
                    Text(event.timestamp.formatted(date: .omitted, time: .standard)).font(.caption2).foregroundStyle(.tertiary)
                  }
                }.frame(maxWidth: .infinity, alignment: .leading).id(event.id)
              }
              Color.clear.frame(height: 1).id("activity-bottom")
            }.padding(10)
          }.frame(height: 220)
            .onChange(of: session.activity) { _, _ in
              if follow { proxy.scrollTo("activity-bottom", anchor: .bottom) }
            }
            .onChange(of: follow) { _, enabled in
              if enabled { proxy.scrollTo("activity-bottom", anchor: .bottom) }
            }
        }
      } label: {
        HStack {
          Label(session.busy ? "Live agent activity" : "Agent activity", systemImage: "text.bubble")
          Spacer()
          Toggle("Follow latest", isOn: $follow).toggleStyle(.checkbox).font(.caption)
          Button("Copy") { copyText(session.activity.map(\.text).joined(separator: "\n\n")) }.font(.caption)
        }
      }
    }
    .onAppear { expanded = session.busy }
    .onChange(of: session.busy) { _, busy in expanded = busy }
  }
  private func symbol(_ kind: AgentActivity.Kind) -> String {
    switch kind { case .message: "text.bubble"; case .tool: "wrench.and.screwdriver"; case .error: "exclamationmark.triangle"; case .status: "circle.dotted" }
  }
}

struct AgentExecutionOutputView: View {
  @Bindable var session: AgentReviewSession
  @State private var follow = true
  var body: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Label(session.executionRunning ? "Live execution output" : "Execution output", systemImage: "terminal")
          Spacer()
          Toggle("Follow latest", isOn: $follow).toggleStyle(.checkbox).font(.caption)
          Button("Copy") { copyText(session.executionOutput) }.disabled(session.executionOutput.isEmpty)
        }
        Text("Respond to permission prompts in Terminal. Exit the agent session there when it finishes, then verify below.")
          .font(.caption).foregroundStyle(.secondary)
        ScrollViewReader { proxy in
          ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 0) {
              Text(session.executionOutput.isEmpty ? "Waiting for Terminal output…" : session.executionOutput)
                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
              Color.clear.frame(height: 1).id("execution-bottom")
            }.padding(10)
          }.frame(height: 260)
            .onChange(of: session.executionOutput) { _, _ in
              if follow { proxy.scrollTo("execution-bottom", anchor: .bottom) }
            }
            .onChange(of: follow) { _, enabled in
              if enabled { proxy.scrollTo("execution-bottom", anchor: .bottom) }
            }
        }
        if let code = session.executionExitCode {
          Text(code == 0 ? "Session ended · repository verification still required" : "Session exited with status \(code) · review the output before continuing")
            .font(.caption).foregroundStyle(code == 0 ? Color.secondary : Color.orange)
        }
      }
    }.task { session.watchExecution() }
  }
}
