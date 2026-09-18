import Foundation

public struct AgentActivity: Codable, Identifiable, Sendable, Equatable {
  public enum Kind: String, Codable, Sendable { case status, message, tool, error }
  public var id: String
  public var kind: Kind
  public var text: String
  public var timestamp: Date
  public init(id: String = UUID().uuidString, kind: Kind, text: String, timestamp: Date = Date()) {
    self.id = id; self.kind = kind; self.text = String(text.prefix(12_000)); self.timestamp = timestamp
  }
}

// stdout is a JSONL protocol, not a transcript. Ignore prompts, raw tool results,
// authentication metadata and reasoning events; only surface public messages/activity.
public final class AgentEventStream: @unchecked Sendable {
  private let lock = NSLock()
  private var buffer = Data()
  private var droppingLine = false
  private var messageID = "initial"
  private var texts: [String: String] = [:]
  private var toolLabels: [String: String] = [:]
  private var result: Data?
  private let context: AgentContext
  private let onActivity: @Sendable (AgentActivity) -> Void
  public init(context: AgentContext, onActivity: @escaping @Sendable (AgentActivity) -> Void) {
    self.context = context; self.onActivity = onActivity
  }
  public func receive(_ data: Data) {
    lock.lock(); defer { lock.unlock() }
    // Bound even a malformed stream that never emits a newline. Discard an
    // oversized record completely rather than parsing a suffix as a new event.
    for part in data.split(separator: 10, omittingEmptySubsequences: false).enumerated() {
      if part.offset > 0 {
        if !droppingLine { parse(buffer) }
        buffer.removeAll(keepingCapacity: true); droppingLine = false
      }
      if !droppingLine {
        if buffer.count + part.element.count <= 4_000_000 { buffer.append(contentsOf: part.element) }
        else { buffer.removeAll(keepingCapacity: false); droppingLine = true }
      }
    }
  }
  public func finish() {
    lock.lock(); defer { lock.unlock() }
    if !droppingLine { parse(buffer) }
    buffer.removeAll()
  }
  public var structuredResult: Data? {
    lock.lock(); defer { lock.unlock() }; return result
  }
  private func emit(_ kind: AgentActivity.Kind, _ text: String, id: String = UUID().uuidString) {
    guard !text.isEmpty else { return }
    onActivity(AgentActivity(id: id, kind: kind, text: Self.redact(text)))
  }
  public static func redact(_ value: String) -> String {
    var value = value
    for pattern in ["sk-[A-Za-z0-9_-]+", "(?i)Bearer [A-Za-z0-9._-]+", "(?i)(token|api_key|authorization)[=: ]+[^ ,;\\n]+", "://[^/@ ]+:[^/@ ]+@"] {
      value = value.replacingOccurrences(of: pattern, with: "[redacted]", options: .regularExpression)
    }
    return value
  }
  private func tool(_ name: String, arguments: [String: Any]?, id: String, finished: Bool, failed: Bool = false) {
    if name == "StructuredOutput" { emit(.status, "Preparing proposed resolutions…", id: id); return }
    var label = toolLabels[id] ?? name
    if let args = arguments, let cloneID = args["clone_id"] as? String,
       let target = context.targets.first(where: { $0.id == cloneID }) {
      label = "\(target.environment.name) · \(args["operation"] as? String ?? name)"
      if let path = args["path"] as? String, !path.isEmpty { label += " · " + path }
    }
    if toolLabels.count >= 200 { toolLabels.removeAll(keepingCapacity: true) }
    toolLabels[id] = label
    emit(failed ? .error : .tool, (failed ? "Failed: " : finished ? "Finished: " : "Running: ") + label, id: id)
  }
  private func message(_ text: String, id: String) {
    if let data = text.data(using: .utf8),
       let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["problems"] != nil {
      emit(.status, "Proposed resolutions received.", id: id)
    } else { emit(.message, text, id: id) }
  }
  private func parse(_ data: Data) {
    guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let type = value["type"] as? String else { return }
    switch type {
    case "thread.started": emit(.status, "Agent session started.", id: "session-start")
    case "turn.started": emit(.status, "Examining repository copies…", id: "turn-start")
    case "turn.failed", "error":
      let error = value["error"] as? [String: Any]
      emit(.error, error?["message"] as? String ?? value["message"] as? String ?? "Agent reported an error.")
    case "item.started", "item.updated", "item.completed":
      guard let item = value["item"] as? [String: Any], let itemType = item["type"] as? String else { return }
      let id = "codex-" + (item["id"] as? String ?? UUID().uuidString)
      switch itemType {
      case "agent_message": message(item["text"] as? String ?? "", id: id)
      case "mcp_tool_call": tool(item["tool"] as? String ?? "Repository inspection", arguments: item["arguments"] as? [String: Any],
                                  id: id, finished: type == "item.completed", failed: item["status"] as? String == "failed")
      case "command_execution": emit(.tool, (type == "item.completed" ? "Finished: " : "Running: ") + (item["command"] as? String ?? "Command"), id: id)
      case "file_change": emit(.tool, "File changes reported.", id: id)
      default: break
      }
    case "system":
      if value["subtype"] as? String == "init" { emit(.status, "Agent session started.", id: "session-start") }
    case "stream_event":
      guard let event = value["event"] as? [String: Any], let eventType = event["type"] as? String else { return }
      if eventType == "message_start" {
        messageID = (event["message"] as? [String: Any])?["id"] as? String ?? UUID().uuidString
        texts.removeAll(keepingCapacity: true)
      }
      let id = "claude-\(messageID)-\(event["index"] as? Int ?? 0)"
      if eventType == "content_block_start", let block = event["content_block"] as? [String: Any] {
        if block["type"] as? String == "tool_use" {
          tool(block["name"] as? String ?? "Tool", arguments: block["input"] as? [String: Any],
               id: "tool-" + (block["id"] as? String ?? id), finished: false)
        } else if block["type"] as? String == "text" { texts[id] = block["text"] as? String ?? "" }
      }
      if eventType == "content_block_delta", let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta" {
        let text = String(((texts[id] ?? "") + (delta["text"] as? String ?? "")).prefix(12_000))
        texts[id] = text; message(text, id: id)
      }
    case "assistant":
      guard let msg = value["message"] as? [String: Any], let blocks = msg["content"] as? [[String: Any]] else { return }
      let msgID = msg["id"] as? String ?? messageID
      for (index, block) in blocks.enumerated() {
        if block["type"] as? String == "text" {
          message(block["text"] as? String ?? "", id: "claude-\(msgID)-\(index)")
        } else if block["type"] as? String == "tool_use" {
          tool(block["name"] as? String ?? "Tool", arguments: block["input"] as? [String: Any],
               id: "tool-" + (block["id"] as? String ?? "\(msgID)-\(index)"), finished: false)
        }
      }
    case "user":
      // Tool-result bodies can contain source or secrets. Only read completion metadata.
      if let msg = value["message"] as? [String: Any], let blocks = msg["content"] as? [[String: Any]] {
        for block in blocks where block["type"] as? String == "tool_result" {
          if let toolID = block["tool_use_id"] as? String {
            tool("Repository inspection", arguments: nil, id: "tool-" + toolID,
                 finished: true, failed: block["is_error"] as? Bool == true)
          }
        }
      }
    case "result":
      if value["is_error"] as? Bool == true {
        emit(.error, "Agent could not complete the analysis.")
      } else if let structured = value["structured_output"],
                let encoded = try? JSONSerialization.data(withJSONObject: structured), encoded.count < 1_000_000 {
        result = encoded
        emit(.status, "Proposed resolutions received.", id: "result")
      }
    default: break
    }
  }
}
