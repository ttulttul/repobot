import Foundation

/// What event monitoring costs a Linux machine. inotify spends one watch per directory from a
/// limited per-user budget; FSEvents on macOS has no comparable cost, so Macs are not measured.
public struct WatcherCost: Sendable, Equatable {
  /// inotify watches held, out of fs.inotify.max_user_watches.
  public var handles: Int?, handleLimit: Int?
  /// Percentage of one core. Nil until a rate can be derived from two samples.
  public var cpuPercent: Double?
  public var memoryBytes: Int64?
  public var processes: Int

  public var handlesText: String {
    guard let handles else { return "—" }
    return Self.count(handles) + (handleLimit.map { " of " + Self.count($0) } ?? "") + " inotify watches"
  }
  public var cpuText: String {
    guard let cpuPercent else { return "—" }
    return cpuPercent > 0 && cpuPercent < 0.5 ? "<1%" : "\(Int(cpuPercent.rounded()))%"
  }
  public var memoryText: String { memoryBytes.map(Self.memory) ?? "—" }
  public var handleFraction: Double? {
    guard let handles, let handleLimit, handleLimit > 0 else { return nil }
    return min(1, Double(handles) / Double(handleLimit))
  }

  /// 842, 1.4K, 14K, 524K, 1.2M
  public static func count(_ value: Int) -> String { scaled(Double(value), base: 1000, units: ["", "K", "M", "B"]) }
  /// 512KB, 64MB, 1.2GB
  public static func memory(_ bytes: Int64) -> String {
    scaled(max(0, Double(bytes)) / 1024, base: 1024, units: ["KB", "MB", "GB", "TB"])
  }
  private static func scaled(_ value: Double, base: Double, units: [String]) -> String {
    var value = value, unit = 0
    while value.rounded() >= base && unit < units.count - 1 { value /= base; unit += 1 }
    // One decimal only where it carries information: 1.4K, but 14K and 842.
    let text = unit > 0 && value < 9.95 ? String(format: "%.1f", value) : String(Int(value.rounded()))
    return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + units[unit]
  }
}

/// Cumulative CPU time at a point on the measured machine's own clock.
public struct WatcherCPUReading: Sendable, Equatable {
  public var seconds: Double, at: Double
  public func percent(since previous: WatcherCPUReading?) -> Double? {
    guard let previous, at - previous.at >= 0.2, seconds >= previous.seconds else { return nil }
    return (seconds - previous.seconds) / (at - previous.at) * 100
  }
}

public enum WatcherCostSampler {
  /// Samples the remote watcher's process group over the multiplexed connection.
  public static func remote(
    group: Int32, transport: any Transport, previous: WatcherCPUReading?
  ) async throws -> (WatcherCost, WatcherCPUReading?)? {
    let result = try await transport.run(
      script: try Scripts.load("cost.sh"), arguments: [String(group)], timeout: 10)
    return parse(result.text, previous: previous)
  }
  static func parse(_ text: String, previous: WatcherCPUReading?) -> (WatcherCost, WatcherCPUReading?)? {
    var fields: [String: String] = [:]
    for line in text.split(separator: "\n") {
      let pair = line.split(separator: "=", maxSplits: 1)
      if pair.count == 2 { fields[String(pair[0])] = String(pair[1]) }
    }
    guard let processes = fields["processes"].flatMap(Int.init), processes > 0 else { return nil }
    var reading: WatcherCPUReading?
    if let ticks = fields["ticks"].flatMap(Double.init), let hz = fields["hz"].flatMap(Double.init), hz > 0,
       let uptime = fields["uptime"].flatMap(Double.init) {
      reading = WatcherCPUReading(seconds: ticks / hz, at: uptime)
    }
    let cost = WatcherCost(
      handles: fields["handles"].flatMap(Int.init),
      handleLimit: fields["limit"].flatMap(Int.init),
      cpuPercent: reading?.percent(since: previous),
      memoryBytes: fields["rss"].flatMap(Int64.init), processes: processes)
    return (cost, reading)
  }
}
