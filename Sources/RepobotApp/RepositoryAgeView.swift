import Foundation
import RepobotCore
import SwiftUI

struct RepositoryAgeView: View {
  let age: RepositoryAge?
  let lastCommitDate: Date?
  var detailed = false

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      if let age {
        Text("Last commit: \(lastCommitDate.map { Self.describe(age.age(of: $0)) } ?? "No commits") · Newest file: \(fileAge(age))")
          .font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .help("Ages at the last check, measured using this machine’s own clock. Newest file uses modification time, including ignored files; Git metadata, macOS filesystem metadata, and symlink targets are excluded.")
        if let clock = age.clock {
          if clock.isDivergent {
            Label("Machine clock differs from this Mac by more than 5 seconds", systemImage: "exclamationmark.triangle")
              .font(.caption).foregroundStyle(.orange)
          } else if clock.isInconclusive {
            Label("Clock check inconclusive — connection delay is too large", systemImage: "clock.badge.questionmark")
              .font(.caption).foregroundStyle(.orange)
          }
        } else {
          Text("Clock comparison unavailable").font(.caption).foregroundStyle(.orange)
        }
        if detailed {
          Text("Ages at last check · Measured on the repository’s machine")
            .font(.caption2).foregroundStyle(.secondary)
          if let error = age.fileScanError {
            Text(error).font(.caption).foregroundStyle(.orange)
          }
          if let clock = age.clock {
            Text("Clock offset from this Mac: \(clock.minimumOffset, specifier: "%.1f") to \(clock.maximumOffset, specifier: "%.1f") seconds")
              .font(.caption2).foregroundStyle(.secondary)
          }
        }
      } else {
        Text("Ages unavailable · Awaiting a repository check").font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private func fileAge(_ age: RepositoryAge) -> String {
    if age.fileScanError != nil { return "Unavailable" }
    return age.newestFileDate.map { Self.describe(age.age(of: $0)) } ?? "No files"
  }

  static func describe(_ seconds: TimeInterval) -> String {
    guard seconds.isFinite else { return "Unknown" }
    let value = abs(seconds)
    let amount: Int, unit: String
    if value < 60 { amount = Int(value); unit = "second" }
    else if value < 3600 { amount = Int(value / 60); unit = "minute" }
    else if value < 86400 { amount = Int(value / 3600); unit = "hour" }
    else if value < 86400 * 30 { amount = Int(value / 86400); unit = "day" }
    else if value < 86400 * 365 { amount = Int(value / (86400 * 30)); unit = "month" }
    else { amount = Int(value / (86400 * 365)); unit = "year" }
    let duration = "\(amount) \(unit)\(amount == 1 ? "" : "s")"
    return seconds < -1 ? "\(duration) in the future" : "\(duration) ago"
  }
}
