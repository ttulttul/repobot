import Foundation

public enum AgentHarness: String, Codable, Sendable, CaseIterable {
  case codex, claude
  public var title: String { self == .codex ? "OpenAI Codex" : "Claude Code" }
  public var homeVariable: String { self == .codex ? "CODEX_HOME" : "CLAUDE_CONFIG_DIR" }
}
public struct AgentProfile: Identifiable, Codable, Sendable, Equatable {
  public var id = UUID()
  public var name: String
  public var harness: AgentHarness
  public var executable = ""
  public var homeDirectory = ""
  public var model = ""
  public init(name: String, harness: AgentHarness) { self.name = name; self.harness = harness }
  public static var defaults: [AgentProfile] {
    [AgentProfile(name: "Codex", harness: .codex), AgentProfile(name: "Claude Code", harness: .claude)]
  }
}
public struct AgentAvailability: Sendable {
  public enum State: String, Sendable { case ready, notInstalled, notLoggedIn, unknown }
  public var state: State
  public var executable: String?
  public var message: String
  public init(_ state: State, executable: String? = nil, message: String) {
    self.state = state; self.executable = executable; self.message = message
  }
}
public enum AgentCLI {
  // Explicit profiles must never silently inherit credentials or another profile's home.
  static let clearedVariables = [
    "CODEX_HOME", "CLAUDE_CONFIG_DIR", "CLAUDE_HOME_DIR", "CLAUDECODE",
    "OPENAI_API_KEY", "CODEX_API_KEY", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN",
    "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN_FILE",
  ]
  public static var searchDirectories: [String] {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return Array(Set((ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
      + ["/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin", home + "/.npm-global/bin", "/usr/bin", "/bin"]))
      .filter { $0.hasPrefix("/") }.sorted()
  }
  public static func executable(for profile: AgentProfile) -> String? {
    let candidates = profile.executable.isEmpty
      ? searchDirectories.map { $0 + "/" + profile.harness.rawValue }
      : [expandedPath(profile.executable)]
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
  }
  public static func environment(for profile: AgentProfile) -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    for key in clearedVariables { env[key] = nil }
    env["PATH"] = searchDirectories.joined(separator: ":")
    let defaultHome = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(profile.harness == .codex ? ".codex" : ".claude").path
    env[profile.harness.homeVariable] = profile.homeDirectory.isEmpty ? defaultHome : expandedPath(profile.homeDirectory)
    return env
  }
  public static func run(
    _ profile: AgentProfile, arguments: [String], directory: URL, input: Data = Data(), timeout: Double = 30,
    onOutput: (@Sendable (Data) -> Void)? = nil, outputFile: URL? = nil
  ) async throws -> CommandResult {
    guard let path = executable(for: profile) else { throw RepobotError.message("\(profile.harness.title) CLI not found") }
    return try await ProcessRunner.run(
      "/bin/sh", ["-c", "cd -- \"$1\" && shift && exec \"$@\"", "repobot-agent", directory.path, path] + arguments,
      input: input, timeout: timeout, onOutput: onOutput, environment: environment(for: profile), outputFile: outputFile)
  }
  public static func availability(_ profile: AgentProfile) async -> AgentAvailability {
    guard let path = executable(for: profile) else { return AgentAvailability(.notInstalled, message: "CLI not installed or executable path is invalid") }
    do {
      let args = profile.harness == .codex ? ["login", "status"] : ["auth", "status", "--json"]
      let result = try await run(profile, arguments: args, directory: FileManager.default.homeDirectoryForCurrentUser, timeout: 15)
      if profile.harness == .claude {
        guard let value = try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any],
          let loggedIn = value["loggedIn"] as? Bool else {
          return AgentAvailability(.unknown, executable: path, message: "Could not read login status; check CLI version in Terminal")
        }
        return AgentAvailability(loggedIn ? .ready : .notLoggedIn, executable: path,
          message: loggedIn ? "Logged in" : "Not logged in")
      }
      let text = (result.text + result.errorText).lowercased()
      if result.status == 0 && text.contains("logged in") {
        return AgentAvailability(.ready, executable: path, message: "Logged in")
      }
      return AgentAvailability(text.contains("not logged in") ? .notLoggedIn : .unknown,
        executable: path, message: text.contains("not logged in") ? "Not logged in" : "Could not verify login; check in Terminal")
    } catch { return AgentAvailability(.unknown, executable: path, message: "Login check failed or timed out") }
  }
  public static func diagnostic(_ text: String) -> String {
    var message = text.split(separator: "\n").filter { $0.lowercased().contains("error") }.suffix(3).joined(separator: "\n")
    if message.isEmpty { return "Check CLI version, account access and model availability in Terminal." }
    for pattern in ["sk-[A-Za-z0-9_-]+", "(?i)Bearer [A-Za-z0-9._-]+", "(?i)(token|api_key|authorization)[=: ]+[^ ,;]+", "://[^/@ ]+:[^/@ ]+@"] {
      message = message.replacingOccurrences(of: pattern, with: "[redacted]", options: .regularExpression)
    }
    return String(message.suffix(1800))
  }
  // The terminal receives the same account home and model as the headless analysis.
  public static func terminalPrefix(_ profile: AgentProfile) throws -> [String] {
    guard let path = executable(for: profile) else { throw RepobotError.message("CLI not installed. Set its executable path in Coding Agents settings.") }
    let env = environment(for: profile)
    return ["/usr/bin/env"] + clearedVariables.flatMap { ["-u", $0] }
      + ["PATH=" + (env["PATH"] ?? ""), profile.harness.homeVariable + "=" + (env[profile.harness.homeVariable] ?? ""), path]
  }
  public static func loginCommand(_ profile: AgentProfile) throws -> String {
    let args = profile.harness == .codex ? ["login"] : ["auth", "login"]
    return try (terminalPrefix(profile) + args).map(shellQuote).joined(separator: " ")
  }
}
