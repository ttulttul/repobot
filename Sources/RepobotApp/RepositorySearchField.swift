import SwiftUI

struct RepositorySearchField: NSViewRepresentable {
  @Binding var text: String
  @Binding var focusRequested: Bool
  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeNSView(context: Context) -> NSSearchField {
    let field = NSSearchField()
    field.placeholderString = "Search repositories"
    field.setAccessibilityLabel("Search repositories by name, path, or machine")
    field.delegate = context.coordinator
    field.sendsSearchStringImmediately = true
    return field
  }
  func updateNSView(_ field: NSSearchField, context: Context) {
    context.coordinator.parent = self
    if field.stringValue != text { field.stringValue = text }
    if focusRequested {
      Task { @MainActor in
        guard let window = field.window else { return }
        window.makeFirstResponder(field)
        focusRequested = false
      }
    }
  }
  final class Coordinator: NSObject, NSSearchFieldDelegate {
    var parent: RepositorySearchField
    init(_ parent: RepositorySearchField) { self.parent = parent }
    func controlTextDidChange(_ notification: Notification) {
      guard let field = notification.object as? NSSearchField else { return }
      parent.text = field.stringValue
    }
  }
}
