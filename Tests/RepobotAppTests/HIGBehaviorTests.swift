import Foundation
import Testing
import UserNotifications
@testable import RepobotApp
@testable import RepobotCore

@MainActor struct HIGBehaviorTests {
  private func temporary() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  @Test func failedConfigurationSaveDoesNotPublishAndRetryIsIdempotent() throws {
    let root = try temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let persistence = Persistence(directory: root)
    let state = AppState(persistence: persistence)
    #expect(state.needsSetup)
    #expect(state.configuration.environments.allSatisfy { $0.roots.isEmpty })
    let savedIDs = state.configuration.environments.map(\.id)
    let configURL = root.appendingPathComponent("config.json")
    try FileManager.default.removeItem(at: configURL)
    try FileManager.default.createDirectory(at: configURL, withIntermediateDirectories: false)
    let environment = Environment(name: "New host", kind: .ssh, roots: ["/repos"])
    #expect(!state.add(environment))
    #expect(state.configuration.environments.map(\.id) == savedIDs)
    #expect(state.error?.contains("Could not save settings") == true)
    try FileManager.default.removeItem(at: configURL)
    #expect(state.add(environment))
    #expect(state.add(environment))
    #expect(state.configuration.environments.filter { $0.id == environment.id }.count == 1)
    #expect(!state.needsSetup)
    let restored = AppState(persistence: persistence)
    #expect(restored.configuration.environments.last?.roots == ["/repos"])
  }

  @Test func failedProfileSaveDoesNotPublishAndRetryIsIdempotent() throws {
    let root = try temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AgentSettingsStore(persistence: Persistence(directory: root))
    let initial = store.profiles
    let file = root.appendingPathComponent("agents.json")
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
    let profile = AgentProfile(name: "Work", harness: .codex)
    #expect(!store.saveProfile(profile))
    #expect(store.profiles == initial)
    #expect(store.error != nil)
    try FileManager.default.removeItem(at: file)
    #expect(store.saveProfile(profile))
    #expect(store.saveProfile(profile))
    #expect(store.profiles.filter { $0.id == profile.id }.count == 1)
    #expect(store.error == nil)
  }

  @Test func staleResultsNeverClaimCurrentAndKeepFullError() {
    for freshness in [RepositoryFreshness(paused: true, pending: false, error: nil),
                      RepositoryFreshness(paused: false, pending: true, error: nil),
                      RepositoryFreshness(paused: false, pending: false, error: "Connection failed")] {
      #expect(!freshness.isCurrent)
      #expect(freshness.summary?.contains("last known state") == true)
    }
    #expect(RepositoryFreshness(paused: false, pending: false, error: nil).isCurrent)
    let failed = RepositoryFreshness(paused: true, pending: true, error: "Connection failed")
    #expect(failed.error == "Connection failed")
  }

  @Test func numericInputRejectsIncompleteEdits() {
    #expect(SettingsNumber.parse("10abc", locale: Locale(identifier: "en_US")) == nil)
    #expect(SettingsNumber.parse("", locale: Locale(identifier: "en_US")) == nil)
    #expect(SettingsNumber.parse("nan", locale: Locale(identifier: "en_US")) == nil)
    #expect(SettingsNumber.parse("12.5", locale: Locale(identifier: "en_US")) == 12.5)
    #expect(SettingsNumber.parse("12,5", locale: Locale(identifier: "de_DE")) == 12.5)
  }

  @Test func revokedNotificationPermissionRetainsUserPreference() throws {
    let root = try temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let state = AppState(persistence: Persistence(directory: root))
    #expect(state.changeConfiguration { $0.notifications = true })
    state.notificationAuthorization = .authorized
    #expect(state.notificationSummary == "Enabled")
    state.notificationAuthorization = .denied
    #expect(state.notificationSummary == "Blocked in System Settings")
    #expect(state.configuration.notifications)
    state.notificationAuthorization = .notDetermined
    #expect(state.notificationSummary == "Permission needed")
  }

  @Test func groupedNotificationReplacesSearchAndShowsEveryAffectedRepository() throws {
    let env = Environment(name: "Local", kind: .local)
    var snapshot = EnvironmentSnapshot(environment: env)
    snapshot.repos = SnapshotList((0..<3).map { RepoSnapshot(path: "/repos/repo-\($0)") })
    var config = Configuration()
    config.environments = [env]
    let world = Analyzer.analyze([snapshot], configuration: config)
    let model = RepositoryMapModel()
    model.update(world)
    model.search = "does not match"
    let ids = Set(world.clones.prefix(2).map(\.id))
    model.show(cloneIDs: ids)
    #expect(model.search.isEmpty)
    #expect(Set(model.visibleGroups.flatMap { $0.rows.map(\.id) }) == ids)
    model.clearNotificationFilter()
    #expect(model.visibleGroups.count == 3)
  }
}
