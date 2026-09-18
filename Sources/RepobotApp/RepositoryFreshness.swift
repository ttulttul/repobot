import SwiftUI

struct RepositoryFreshness: Equatable {
  let paused: Bool
  let pending: Bool
  let error: String?
  var isCurrent: Bool { !paused && !pending && error == nil }
  var summary: String? {
    if paused { return "Monitoring paused — showing last known state" }
    if error != nil { return "Unavailable — showing last known state" }
    if pending { return "Awaiting fresh check — showing last known state" }
    return nil
  }
  var symbol: String { paused ? "pause.circle" : "clock.badge.exclamationmark" }
}

struct RepositoryFreshnessView: View {
  let freshness: RepositoryFreshness
  var body: some View {
    if let summary = freshness.summary {
      VStack(alignment: .leading, spacing: 6) {
        Label(summary, systemImage: freshness.symbol)
        if let error = freshness.error { Text(error).textSelection(.enabled) }
      }.fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
  }
}

struct OperationErrorView: View {
  let message: String
  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).accessibilityHidden(true)
      Text(message).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
    }.accessibilityElement(children: .combine)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// Keep native buttons at their intrinsic sizes and wrap them on narrower windows.
struct FlowLayout: Layout {
  var spacing: CGFloat = 8
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    positions(width: proposal.width ?? 620, subviews: subviews).size
  }
  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let layout = positions(width: bounds.width, subviews: subviews)
    for (index, point) in layout.points.enumerated() {
      subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
    }
  }
  private func positions(width: CGFloat, subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
    var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
    var points: [CGPoint] = []
    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if x > 0 && x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
      points.append(CGPoint(x: x, y: y))
      x += size.width + spacing; rowHeight = max(rowHeight, size.height)
    }
    return (CGSize(width: width, height: y + rowHeight), points)
  }
}
