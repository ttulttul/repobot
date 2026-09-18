import Foundation
import Testing
@testable import RepobotCore

final class ActivityRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var entries: [AgentActivity] = []
  func append(_ event: AgentActivity) { lock.lock(); defer { lock.unlock() }; entries.append(event) }
  var events: [AgentActivity] { lock.lock(); defer { lock.unlock() }; return entries }
}
struct AgentActivityTests {
  private let context = AgentContext(repository: "fixture", targets: [], sshPath: "/usr/bin/ssh", sshOptions: [])
  @Test func testCodexStreamingChunksAndPrivateEvents() throws {
    let recorder = ActivityRecorder()
    let stream = AgentEventStream(context: context, onActivity: recorder.append)
    let records: [[String: Any]] = [
      ["type": "thread.started"],
      ["type": "item.completed", "item": ["type": "reasoning", "text": "private reasoning"]],
      ["type": "item.completed", "item": ["id": "one", "type": "agent_message", "text": "Checking café 🌲"]],
      ["type": "item.started", "item": ["id": "two", "type": "mcp_tool_call", "tool": "inspect_repo"]],
      ["type": "item.completed", "item": ["id": "two", "type": "mcp_tool_call", "tool": "inspect_repo", "status": "completed", "result": "private source"]],
    ]
    let bytes = try records.reduce(into: Data()) { $0 += try JSONSerialization.data(withJSONObject: $1) + Data([10]) }
    // One byte per delivery deliberately splits multibyte characters and records.
    for byte in bytes { stream.receive(Data([byte])) }
    #expect(recorder.events.contains { $0.text == "Checking café 🌲" })
    #expect(recorder.events.last?.text == "Finished: inspect_repo")
    #expect(recorder.events.filter { $0.id == "codex-two" }.count == 2)
    #expect(!recorder.events.contains { $0.text.contains("private") })
    stream.receive(Data("{\"type\":\"error\",\"message\":\"sk-secret123\"}".utf8))
    stream.finish()
    #expect(recorder.events.last?.text == "[redacted]")
  }
  @Test func testClaudePartialMessagesAndStructuredResult() throws {
    let recorder = ActivityRecorder()
    let stream = AgentEventStream(context: context, onActivity: recorder.append)
    func emit(_ object: [String: Any]) throws {
      stream.receive(try JSONSerialization.data(withJSONObject: object) + Data([10]))
    }
    try emit(["type": "stream_event", "event": ["type": "message_start", "message": ["id": "msg1"]]])
    for text in ["Inspecting ", "the changes"] {
      try emit(["type": "stream_event", "event": ["type": "content_block_delta", "index": 0,
        "delta": ["type": "text_delta", "text": text]]])
    }
    #expect(recorder.events.last?.text == "Inspecting the changes")
    #expect(Set(recorder.events.map(\.id)).count == 1)
    try emit(["type": "assistant", "message": ["id": "msg1", "content": [
      ["type": "text", "text": "Inspecting the changes"], ["type": "tool_use", "id": "call1", "name": "inspect_repo", "input": [:]]]]])
    try emit(["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": "call1", "content": "private source"]]]])
    #expect(recorder.events.last?.text == "Finished: inspect_repo")
    try emit(["type": "result", "is_error": false, "structured_output": ["summary": "Done", "limitations": [], "problems": []]])
    let result = try AgentFiles.decoder().decode(AgentAnalysis.self, from: #require(stream.structuredResult))
    #expect(result.summary == "Done")
    #expect(!recorder.events.contains { $0.text.contains("private") })
  }
  @Test func testOversizedRecordIsDroppedAndStreamRecovers() {
    let recorder = ActivityRecorder()
    let stream = AgentEventStream(context: context, onActivity: recorder.append)
    stream.receive(Data(repeating: 65, count: 4_000_001))
    stream.receive(Data("{\"type\":\"error\",\"message\":\"suffix must not parse\"}\n{\"type\":\"thread.started\"}\n".utf8))
    stream.finish()
    #expect(recorder.events.count == 1)
    #expect(recorder.events.first?.text == "Agent session started.")
  }
  @Test func testTerminalRenderingAndBounds() {
    func render(_ text: String) -> String { AgentTerminalOutput.render(Data(text.utf8)) }
    #expect(render("Starting\r\u{1b}[2KDone\n  indented café 🌲\n") == "Done\n  indented café 🌲")
    #expect(render("\u{1b}[31mRed\u{1b}[0m\u{1b}]52;c;secret\u{7}\n") == "Red")
    #expect(render("one\ntwo\u{1b}[1A\r\u{1b}[2KONE") == "ONE\ntwo")
    #expect(render("Bearer abcdef token=secret sk-secret").contains("secret") == false)
    #expect(render(String(repeating: "long line\n", count: 10_000)).count < 48_001)
    #expect(render("\u{1b}[-9223372036854775808Gsafe") == "safe")
  }
}
