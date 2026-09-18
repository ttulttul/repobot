import Foundation

public struct AgentTarget: Codable, Sendable, Identifiable {
  public var id: String
  public var environment: Environment
  public var repo: RepoSnapshot
  public var status: RepoStatus
  public var fingerprint: String?
  public var inspectionError: String?
}
public struct AgentContext: Codable, Sendable {
  public var version = 1
  public var repository: String
  public var generatedAt = Date()
  public var targets: [AgentTarget]
  public var sshPath: String
  public var sshOptions: [String]
}
public struct ResolutionOption: Codable, Sendable, Identifiable {
  public var id: String
  public var title: String
  public var explanation: String
  public var steps: [String]
  public var risks: [String]
  public var affectedCloneIDs: [String]
  public var destructive: Bool
}
public struct AgentProblem: Codable, Sendable, Identifiable {
  public var id: String
  public var title: String
  public var explanation: String
  public var evidence: [String]
  public var options: [ResolutionOption]
}
public struct AgentAnalysis: Codable, Sendable {
  public var summary: String
  public var limitations: [String]
  public var problems: [AgentProblem]
  public func validate(context: AgentContext) throws {
    let targets = Set(context.targets.map(\.id))
    guard !summary.isEmpty, problems.count <= 50, Set(problems.map(\.id)).count == problems.count else {
      throw RepobotError.message("Agent returned invalid or duplicate problems")
    }
    for problem in problems {
      guard !problem.id.isEmpty, !problem.title.isEmpty, !problem.options.isEmpty,
        problem.options.count <= 20, Set(problem.options.map(\.id)).count == problem.options.count else {
        throw RepobotError.message("Agent returned invalid resolution options")
      }
      for option in problem.options {
        guard !option.id.isEmpty, !option.title.isEmpty, !option.steps.isEmpty,
          !option.affectedCloneIDs.isEmpty, Set(option.affectedCloneIDs).isSubset(of: targets) else {
          throw RepobotError.message("Agent returned a resolution outside these repository copies")
        }
      }
    }
  }
  public static let schema = #"""
  {"type":"object","additionalProperties":false,"required":["summary","limitations","problems"],"properties":{
    "summary":{"type":"string"},"limitations":{"type":"array","items":{"type":"string"}},
    "problems":{"type":"array","items":{"type":"object","additionalProperties":false,
      "required":["id","title","explanation","evidence","options"],"properties":{
      "id":{"type":"string"},"title":{"type":"string"},"explanation":{"type":"string"},
      "evidence":{"type":"array","items":{"type":"string"}},
      "options":{"type":"array","items":{"type":"object","additionalProperties":false,
        "required":["id","title","explanation","steps","risks","affectedCloneIDs","destructive"],"properties":{
        "id":{"type":"string"},"title":{"type":"string"},"explanation":{"type":"string"},
        "steps":{"type":"array","items":{"type":"string"}},"risks":{"type":"array","items":{"type":"string"}},
        "affectedCloneIDs":{"type":"array","items":{"type":"string"}},"destructive":{"type":"boolean"}
      }}}
    }}}
  }}
  """#
}
public struct AgentJob: Codable, Sendable, Identifiable {
  public enum Phase: String, Codable, Sendable { case prepared, analyzing, review, handedOff, verified, failed, cancelled }
  public var id = UUID()
  public var createdAt = Date()
  public var profile: AgentProfile
  public var context: AgentContext
  public var phase: Phase = .prepared
  public var analysis: AgentAnalysis?
  public var selections: [String: String] = [:]
  public var message = ""
  public var verification: String?
  public init(profile: AgentProfile, context: AgentContext) { self.profile = profile; self.context = context }
}
public enum AgentFiles {
  public static func encoder() -> JSONEncoder {
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; return encoder
  }
  public static func decoder() -> JSONDecoder {
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder
  }
  public static func write(_ data: Data, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
  public static func write<T: Encodable>(_ value: T, to url: URL) throws { try write(encoder().encode(value), to: url) }
}
