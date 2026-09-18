import CoreGraphics
import Foundation
import IOKit.ps

public enum PowerPolicy {
  public static func multiplier(enabled: Bool, onBattery: Bool, idleSeconds: Double) -> Double {
    enabled && onBattery && idleSeconds >= 300 ? 2 : 1
  }
  static func currentMultiplier(enabled: Bool) -> Double {
    guard enabled, let information = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
      let source = IOPSGetProvidingPowerSourceType(information)?.takeUnretainedValue()
    else { return 1 }
    let idle = CGEventSource.secondsSinceLastEventType(
      .combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!)
    return multiplier(
      enabled: true, onBattery: source as String == kIOPSBatteryPowerValue, idleSeconds: idle)
  }
}
