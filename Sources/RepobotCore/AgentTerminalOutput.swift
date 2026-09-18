import Foundation

public struct AgentTerminalSnapshot: Sendable {
  public var text: String
  public var exitCode: Int?
}
public enum AgentTerminalOutput {
  public static func read(directory: URL) throws -> AgentTerminalSnapshot {
    let output = directory.appendingPathComponent("execution-output.txt")
    var data = Data()
    if FileManager.default.fileExists(atPath: output.path) {
      let handle = try FileHandle(forReadingFrom: output)
      defer { try? handle.close() }
      let size = try handle.seekToEnd()
      let limit: UInt64 = 256_000
      try handle.seek(toOffset: size > limit ? size - limit : 0)
      data = try handle.read(upToCount: Int(limit)) ?? Data()
    }
    let exitCode = (try? String(contentsOf: directory.appendingPathComponent("execution-exit.txt"), encoding: .utf8))
      .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    return AgentTerminalSnapshot(text: render(data), exitCode: exitCode)
  }

  // Render a bounded terminal tail instead of exposing ANSI controls in SwiftUI.
  // Handle the line/cursor rewrites used by interactive CLIs; OSC sequences
  // (titles, hyperlinks, clipboard requests) are never interpreted or displayed.
  public static func render(_ data: Data) -> String {
    var lines: [[Unicode.Scalar]] = [[]]
    var row = 0, column = 0
    var savedRow = 0, savedColumn = 0
    var state = 0, sequence = ""
    func ensureRow() {
      row = min(max(0, row), 399)
      while lines.count <= row { lines.append([]) }
    }
    func nextLine() {
      row += 1; column = 0
      if row >= 400 { lines.removeFirst(); row = 399 }
      ensureRow()
    }
    for scalar in String(decoding: data, as: UTF8.self).unicodeScalars {
      let code = scalar.value
      if state == 3 { // OSC / other string controls: BEL or ST terminates them.
        if code == 7 { state = 0 }
        else if code == 27 { state = 4 }
        continue
      }
      if state == 4 { state = code == 92 ? 0 : 3; continue }
      if state == 1 {
        switch code {
        case 91: state = 2; sequence = ""
        case 93, 80, 94, 95: state = 3
        case 55: savedRow = row; savedColumn = column; state = 0
        case 56: row = savedRow; column = savedColumn; ensureRow(); state = 0
        default: state = 0
        }
        continue
      }
      if state == 2 {
        if code >= 64 && code <= 126 {
          let values = sequence.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
          let first = values.first ?? 0, distance = min(400, max(1, first))
          switch code {
          case 65: row = max(0, row - distance)
          case 66: row += distance; ensureRow()
          case 67: column = min(1000, column + distance)
          case 68: column = max(0, column - distance)
          case 71: column = min(1000, (max(1, first) - 1))
          case 72, 102:
            row = (max(1, first) - 1); column = min(1000, (max(1, values.dropFirst().first ?? 1) - 1)); ensureRow()
          case 74:
            if first == 2 || first == 3 { lines = [[]]; row = 0; column = 0 }
            else if first == 0 {
              ensureRow(); lines[row] = Array(lines[row].prefix(column))
              lines = Array(lines.prefix(row + 1))
            }
          case 75:
            ensureRow()
            if first == 2 { lines[row] = [] }
            else if first == 0 { lines[row] = Array(lines[row].prefix(column)) }
            else if first == 1 {
              for index in 0..<min(column + 1, lines[row].count) { lines[row][index] = " " }
            }
          case 115: savedRow = row; savedColumn = column
          case 117: row = savedRow; column = savedColumn; ensureRow()
          default: break // Colors, modes, visibility and terminal queries.
          }
          state = 0
        } else if sequence.count < 128 { sequence.unicodeScalars.append(scalar) }
        else { state = 0 }
        continue
      }
      switch code {
      case 27: state = 1
      case 10: nextLine()
      case 13: column = 0
      case 8: column = max(0, column - 1)
      case 9: column = min(1000, (column / 8 + 1) * 8)
      case 0..<32, 127: break
      default:
        ensureRow()
        if column < 1000 {
          while lines[row].count <= column { lines[row].append(" ") }
          lines[row][column] = scalar; column += 1
        }
      }
    }
    let text = lines.map { String(String.UnicodeScalarView($0.reversed().drop(while: { $0 == " " }).reversed())) }
      .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    return AgentEventStream.redact(String(text.suffix(48_000)))
  }
}
