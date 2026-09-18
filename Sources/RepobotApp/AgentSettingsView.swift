import RepobotCore
import SwiftUI

@MainActor @Observable final class AgentSettingsStore {
  var profiles: [AgentProfile] = []
  var availability: [UUID: AgentAvailability] = [:]
  var checking = false
  var error: String?
  let persistence = Persistence()
  init() {
    do { profiles = try persistence.load([AgentProfile].self, from: "agents.json") ?? AgentProfile.defaults }
    catch { self.error = "Could not load coding-agent profiles: \(error.localizedDescription)" }
  }
  func save() {
    do { try persistence.save(profiles, to: "agents.json"); error = nil }
    catch { self.error = error.localizedDescription }
  }
  func refresh() async {
    guard !checking else { return }
    checking = true
    defer { checking = false }
    for profile in profiles { availability[profile.id] = await AgentCLI.availability(profile) }
  }
  func add(_ harness: AgentHarness) {
    profiles.append(AgentProfile(name: "\(harness.title) account", harness: harness))
    save()
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
        settings.profiles.removeAll { $0.id == profile.id }
        settings.availability[profile.id] = nil
        selection = settings.profiles.first?.id
        settings.save()
      }
    } message: { Text("This removes the Repobot profile. Your CLI login and account files are kept.") }
  }
  private func detail(_ profile: AgentProfile) -> some View {
    let status = settings.availability[profile.id]
    return VStack(spacing: 24) {
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
      if let error = settings.error ?? state.error { Text(error).font(.caption).foregroundStyle(.red).lineLimit(3) }
      Spacer(minLength: 0)
    }.padding(.horizontal, 24)
  }
}

private struct AgentProfileEditor: View {
  @Bindable var settings: AgentSettingsStore
  @State var profile: AgentProfile
  var saved: (UUID) -> Void
  @SwiftUI.Environment(\.dismiss) private var dismiss
  @State private var advanced = false
  var body: some View {
    PreferencesDialog(title: "\(profile.harness.title) account", subtitle: "Give this login a name and choose the model used for new tasks.") {
      PreferenceRow(title: "Name") { TextField("Profile name", text: $profile.name).textFieldStyle(.roundedBorder) }
      PreferenceRow(title: "Model") { TextField("Harness default", text: $profile.model).textFieldStyle(.roundedBorder) }
      Text("Leave the model blank to use the CLI’s current default, or enter a model ID or alias.")
        .font(.caption).foregroundStyle(.secondary)
      PreferenceRow(title: "CLI account") {
        HStack {
          Text(profile.homeDirectory.isEmpty ? "Default account" : "Custom account folder")
          Spacer(); Button("Manage…") { advanced = true }
        }
      }
      if let error = settings.error { Text(error).font(.caption).foregroundStyle(.red).lineLimit(3) }
    } actions: {
      Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
      Button("Save") {
        if let index = settings.profiles.firstIndex(where: { $0.id == profile.id }) { settings.profiles[index] = profile }
        else { settings.profiles.append(profile) }
        settings.availability[profile.id] = nil
        settings.save()
        if settings.error == nil { saved(profile.id); dismiss(); Task { await settings.refresh() } }
      }.disabled(profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
    }.sheet(isPresented: $advanced) { AgentAccountEditor(profile: $profile) }
  }
}
private struct AgentAccountEditor: View {
  @Binding var profile: AgentProfile
  @SwiftUI.Environment(\.dismiss) private var dismiss
  @State private var home = ""
  @State private var executable = ""
  var body: some View {
    PreferencesDialog(title: "CLI account", subtitle: "Use a separate configuration folder for each login.") {
      Text(profile.harness.homeVariable).font(.headline)
      TextField("Default account folder", text: $home).textFieldStyle(.roundedBorder)
      Text("A custom folder creates a separate account profile. Use Log In / Repair after saving to sign in.")
        .font(.caption).foregroundStyle(.secondary)
      Divider()
      Text("CLI executable").font(.headline)
      TextField("Detect automatically", text: $executable).textFieldStyle(.roundedBorder)
      Text("Leave blank to use the installed \(profile.harness.title) CLI.").font(.caption).foregroundStyle(.secondary)
    } actions: {
      Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
      Button("Done") { profile.homeDirectory = home; profile.executable = executable; dismiss() }
        .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
    }.onAppear { home = profile.homeDirectory; executable = profile.executable }
  }
}
