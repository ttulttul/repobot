import RepobotCore
import SwiftUI

@MainActor @Observable final class AgentSettingsStore {
  private(set) var profiles: [AgentProfile] = []
  var availability: [UUID: AgentAvailability] = [:]
  var checking = false
  var error: String?
  let persistence: Persistence
  init(persistence: Persistence = Persistence()) {
    self.persistence = persistence
    do { profiles = try persistence.load([AgentProfile].self, from: "agents.json") ?? AgentProfile.defaults }
    catch { self.error = "Could not load coding-agent profiles: \(error.localizedDescription)" }
  }
  @discardableResult func save(_ proposed: [AgentProfile]) -> Bool {
    do { try persistence.save(proposed, to: "agents.json"); profiles = proposed; error = nil; return true }
    catch { self.error = "Could not save coding-agent profiles: \(error.localizedDescription)"; return false }
  }
  @discardableResult func saveProfile(_ profile: AgentProfile) -> Bool {
    var proposed = profiles
    if let index = proposed.firstIndex(where: { $0.id == profile.id }) { proposed[index] = profile }
    else { proposed.append(profile) }
    guard save(proposed) else { return false }
    availability[profile.id] = nil
    return true
  }
  @discardableResult func remove(_ id: UUID) -> Bool {
    guard save(profiles.filter { $0.id != id }) else { return false }
    availability[id] = nil
    return true
  }
  func refresh() async {
    guard !checking else { return }
    checking = true
    defer { checking = false }
    for profile in profiles { availability[profile.id] = await AgentCLI.availability(profile) }
  }
  func add(_ harness: AgentHarness) {
    saveProfile(AgentProfile(name: "\(harness.title) account", harness: harness))
  }
}
struct AgentSettingsView: View {
  @Bindable var state: AppState
  @Bindable var settings: AgentSettingsStore
  @State private var selection: UUID?
  @State private var editing: AgentProfile?
  @State private var removing = false
  private var selected: AgentProfile? { settings.profiles.first { $0.id == selection } ?? settings.profiles.first }
  var body: some View {
    HStack(spacing: 0) {
      VStack(spacing: 0) {
        List(selection: $selection) {
          ForEach(settings.profiles) { profile in
            HStack(spacing: 10) {
              Image(systemName: "person.crop.circle").font(.title2)
              VStack(alignment: .leading, spacing: 4) {
                Text(profile.name).fontWeight(.medium).lineLimit(1)
                Text(profile.harness.title).font(.caption).foregroundStyle(.secondary)
              }
              Spacer(minLength: 0)
              if settings.availability[profile.id]?.state == .ready {
                Circle().fill(.green).frame(width: 7, height: 7).accessibilityLabel("Logged in")
              }
            }.padding(.vertical, 8).tag(profile.id)
          }
        }.listStyle(.sidebar)
        Divider()
        HStack {
          Menu("Add Account…") {
            ForEach(AgentHarness.allCases, id: \.self) { harness in
              Button(harness.title) { editing = AgentProfile(name: "\(harness.title) account", harness: harness) }
            }
          }.frame(maxWidth: .infinity)
          Menu {
            Button("Remove profile…", role: .destructive) { removing = true }.disabled(selected == nil)
          } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 26)
        }.padding(12)
      }.frame(width: 230)
      Divider()
      if let profile = selected {
        detail(profile).frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ContentUnavailableView("No coding agents", systemImage: "sparkles", description: Text("Add a Codex or Claude Code account to get started."))
      }
    }
    .onAppear { if selection == nil { selection = settings.profiles.first?.id } }
    .task { await settings.refresh() }
    .sheet(item: $editing) { profile in
      AgentProfileEditor(settings: settings, profile: profile) { selection = $0 }
    }
    .alert("Remove \(selected?.name ?? "profile")?", isPresented: $removing) {
      Button("Cancel", role: .cancel) {}
      Button("Remove", role: .destructive) {
        guard let profile = selected else { return }
        if settings.remove(profile.id) { selection = settings.profiles.first?.id }
      }
    } message: { Text("This removes the Repobot profile. Your CLI login and account files are kept.") }
  }
  private func detail(_ profile: AgentProfile) -> some View {
    let status = settings.availability[profile.id]
    return ScrollView { VStack(spacing: 24) {
      VStack(spacing: 12) {
        Image(systemName: "person.crop.circle").font(.system(size: 48, weight: .light)).foregroundStyle(.tint)
        Text(profile.name).font(.title2.bold())
      }.padding(.top, 28)
      VStack(alignment: .leading, spacing: 18) {
        PreferenceRow(title: "Agent") { Text(profile.harness.title) }
        PreferenceRow(title: "Status") {
          Label(status?.message ?? (settings.checking ? "Checking login…" : "Not checked"),
                systemImage: status?.state == .ready ? "checkmark.circle.fill" : "person.crop.circle.badge.questionmark")
            .foregroundStyle(status?.state == .ready ? .green : .secondary).lineLimit(3)
        }
        PreferenceRow(title: "Model") { Text(profile.model.isEmpty ? "Harness default" : profile.model).lineLimit(2) }
        PreferenceRow(title: "Account") {
          Text(profile.homeDirectory.isEmpty ? "Default CLI account" : profile.homeDirectory)
            .lineLimit(2).truncationMode(.middle).help(profile.homeDirectory)
        }
      }
      HStack(spacing: 10) {
        Button("Edit…") { editing = profile }
        Button(settings.checking ? "Checking…" : "Check Login") { Task { await settings.refresh() } }.disabled(settings.checking)
        Button("Log In / Repair…") {
          do { state.terminal(try AgentCLI.loginCommand(profile)) }
          catch { settings.error = error.localizedDescription }
        }
      }
      Text("Uses your CLI login. Repobot stores profile settings, not credentials.")
        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
      if let error = settings.error ?? state.error { OperationErrorView(message: error) }
      Spacer(minLength: 0)
    }.padding(.horizontal, 24).padding(.bottom, 24) }
  }
}

private struct AgentProfileEditor: View {
  @Bindable var settings: AgentSettingsStore
  @State var profile: AgentProfile
  var saved: (UUID) -> Void
  @SwiftUI.Environment(\.dismiss) private var dismiss
  var body: some View {
    PreferencesDialog(title: "\(profile.harness.title) account", subtitle: "Give this login a name and choose the model used for new tasks.") {
      PreferenceRow(title: "Name") { TextField("Profile name", text: $profile.name).textFieldStyle(.roundedBorder) }
      PreferenceRow(title: "Model") { TextField("Harness default", text: $profile.model).textFieldStyle(.roundedBorder) }
      Text("Leave the model blank to use the CLI’s current default, or enter a model ID or alias.")
        .font(.caption).foregroundStyle(.secondary)
      DisclosureGroup("Advanced Account Settings") {
        VStack(alignment: .leading, spacing: 12) {
          Text(profile.harness.homeVariable).font(.headline)
          TextField("Default account folder", text: $profile.homeDirectory).textFieldStyle(.roundedBorder)
            .accessibilityLabel("CLI account configuration folder")
          Text("A custom folder creates a separate account profile. Use Log In / Repair after saving to sign in.")
            .font(.caption).foregroundStyle(.secondary)
          PreferenceRow(title: "CLI executable") {
            TextField("Detect automatically", text: $profile.executable).textFieldStyle(.roundedBorder)
              .accessibilityLabel("CLI executable path")
          }
        }.padding(.top, 10)
      }
      if let error = settings.error { OperationErrorView(message: error) }
    } actions: {
      Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
      Button("Save") {
        if settings.saveProfile(profile) { saved(profile.id); dismiss(); Task { await settings.refresh() } }
      }.disabled(profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
    }
  }
}
