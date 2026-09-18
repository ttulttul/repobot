import Foundation

/// Ignore the monitor's initial report and repeated reports for an unchanged route.
/// Recovery and route/interface changes on an available network warrant a remote check.
struct NetworkCheckPolicy {
  struct State: Equatable, Sendable {
    var available: Bool
    var interfaces: [String]
    var ipv4: Bool
    var ipv6: Bool
    var dns: Bool
  }
  private var previous: State?
  mutating func receive(_ state: State) -> Bool {
    defer { previous = state }
    guard let previous, state.available else { return false }
    return !previous.available || previous != state
  }
}
