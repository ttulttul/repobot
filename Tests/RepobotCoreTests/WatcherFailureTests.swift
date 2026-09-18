import Foundation
import Testing
@testable import RepobotCore

private struct FailingWatcherTransport: Transport {
  func run(script: String, arguments: [String], timeout: Double) async throws -> CommandResult {
    throw RepobotError.message("unused")
  }
  func invocation(program: String, arguments: [String]) -> (String, [String]) {
    ("/bin/sh", ["-c", "echo 'fixture: watch limit reached' >&2; exit 7"])
  }
  func close() async {}
}
private actor WatcherFailures {
  var message: String?
  func receive(_ event: WatchEvent) { if case .failed(let text) = event { message = text } }
}
struct WatcherFailureTests {
  @Test func testRemoteExitPreservesStatusAndStderr() async throws {
    let failures = WatcherFailures()
    var capabilities = Capabilities(); capabilities.python = true
    let watcher = try RemoteWatcher(transport: FailingWatcherTransport(), roots: [], repos: [],
                                    capabilities: capabilities) { event in
      Task { await failures.receive(event) }
    }
    defer { watcher.stop() }
    for _ in 0..<200 {
      if await failures.message != nil { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    let message = try #require(await failures.message)
    #expect(message.contains("status 7"))
    #expect(message.contains("fixture: watch limit reached"))
  }
  @Test func testFailureSurvivesCheckpointAndStartupDoesNotRestoreLiveMode() async throws {
    let root = try CoreTests().temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    var config = Configuration()
    var env = config.environments[0]; env.watchMode = .poll
    config.environments = [env]
    let persistence = Persistence(directory: root)
    let store = StateStore(configuration: config, persistence: persistence)
    let monitor = EnvironmentMonitor(environment: env, configuration: config, store: store,
                                     transport: FailingWatcherTransport())
    await monitor.watcherFailed("FSEventStreamStart failed")
    await store.flush()
    let saved = try #require(try persistence.loadWorld(configuration: config))
    #expect(saved.environments[0].watcherFailure?.message == "FSEventStreamStart failed")
    #expect(saved.environments[0].watcherFailure?.recoveredAt == nil)
    #expect(saved.environments[0].reconnecting)
    let restarted = StateStore(configuration: config, persistence: persistence, cached: saved)
    let restored = await restarted.world().environments[0]
    #expect(restored.mode == "Starting")
    #expect(!restored.reconnecting)
    #expect(restored.watcherFailure?.message == "FSEventStreamStart failed")
  }
}
