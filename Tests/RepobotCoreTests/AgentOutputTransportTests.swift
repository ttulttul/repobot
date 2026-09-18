import Darwin
import Foundation
import Testing
@testable import RepobotCore

private final class OutputCount: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  private var tail = Data()
  func add(_ data: Data) {
    lock.lock(); defer { lock.unlock() }
    count += data.count
    tail = Data((tail + data).suffix(5))
  }
  var value: Int { lock.lock(); defer { lock.unlock() }; return count }
  var ending: String { lock.lock(); defer { lock.unlock() }; return String(decoding: tail, as: UTF8.self) }
}
struct AgentOutputTransportTests {
  @Test func testFileStreamingSurvivesSlowConsumerAndDrainsFinalEvent() async throws {
    let root = try CoreTests().temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let output = root.appendingPathComponent("events.jsonl")
    let release = root.appendingPathComponent("continue")
    let recorder = OutputCount()
    let script = """
    [ -f /dev/fd/1 ] || exit 90
    printf 'BEGIN'
    while [ ! -f \(shellQuote(release.path)) ]; do sleep 0.02; done
    dd if=/dev/zero bs=65536 count=256 2>/dev/null
    printf 'DONE\\n'
    printf 'diagnostic\\n' >&2
    exit 7
    """
    let task = Task {
      try await ProcessRunner.run("/bin/sh", ["-c", script], timeout: 15,
        onOutput: { recorder.add($0); Thread.sleep(forTimeInterval: 0.001) }, outputFile: output)
    }
    for _ in 0..<200 {
      if recorder.value >= 5 { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(recorder.value == 5) // Visible while the child is still waiting.
    try Data().write(to: release)
    let result = try await task.value
    #expect(result.status == 7)
    #expect(result.errorText == "diagnostic\n")
    #expect(result.stdout.isEmpty)
    #expect(recorder.value == 5 + 65536 * 256 + 5)
    #expect(recorder.ending == "DONE\n")
    let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
  }
  @Test func testFileStreamingCancellationAndTimeoutStopDescendants() async throws {
    let root = try CoreTests().temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let output = root.appendingPathComponent("events.jsonl")
    let started = Date()
    let task = Task {
      try await ProcessRunner.run("/bin/sh", ["-c", "printf start; sleep 30 & wait"], timeout: 10,
        onOutput: { _ in }, outputFile: output)
    }
    try await Task.sleep(for: .milliseconds(100))
    task.cancel()
    await #expect(throws: (any Error).self) { try await task.value }
    await #expect(throws: (any Error).self) {
      try await ProcessRunner.run("/bin/sh", ["-c", "sleep 30 & wait"], timeout: 0.1,
        onOutput: { _ in }, outputFile: output)
    }
    #expect(Date().timeIntervalSince(started) < 3)
  }
}
