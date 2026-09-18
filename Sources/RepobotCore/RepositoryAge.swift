import Foundation

/// Ages use the probed machine's clock, never the receiving Mac's wall clock.
public struct RepositoryAge: Codable, Sendable, Equatable {
  public var measuredAt: Date
  public var newestFileDate: Date?
  public var fileScanError: String?
  public var clock: MachineClock?

  public init(measuredAt: Date, newestFileDate: Date? = nil, fileScanError: String? = nil,
              clock: MachineClock? = nil) {
    self.measuredAt = measuredAt; self.newestFileDate = newestFileDate
    self.fileScanError = fileScanError; self.clock = clock
  }
  public func age(of date: Date) -> TimeInterval { measuredAt.timeIntervalSince(date) }
}

/// The source emits timestamps around the probe. The receiving clock brackets the
/// entire request, so network/queue delay widens the interval rather than causing a
/// false skew warning. `date +%s` has one second of quantization uncertainty.
public struct MachineClock: Codable, Sendable, Equatable {
  public var minimumOffset: TimeInterval
  public var maximumOffset: TimeInterval
  public static let warningThreshold: TimeInterval = 5
  public init?(sourceStart: Date, sourceEnd: Date, localStart: Date, localEnd: Date,
               elapsed: TimeInterval) {
    let localDuration = localEnd.timeIntervalSince(localStart)
    guard localDuration >= 0, elapsed >= 0, abs(localDuration - elapsed) < 1,
          sourceEnd >= sourceStart else { return nil }
    minimumOffset = sourceEnd.timeIntervalSince(localEnd)
    maximumOffset = sourceStart.addingTimeInterval(1).timeIntervalSince(localStart)
    // A clock adjustment during collection makes the measurement inconclusive.
    guard minimumOffset <= maximumOffset else { return nil }
  }
  public var isDivergent: Bool {
    minimumOffset > Self.warningThreshold || maximumOffset < -Self.warningThreshold
  }
  public var isInconclusive: Bool {
    !isDivergent && (minimumOffset < -Self.warningThreshold || maximumOffset > Self.warningThreshold)
  }
}
