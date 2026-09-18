import AppKit

/// A closeable presentation, separate from agent session lifetimes and other retained windows.
@MainActor final class DisposableWindow: NSObject, NSWindowDelegate {
  private(set) var window: NSWindow?
  private var onClose: (() -> Void)?
  init(window: NSWindow, onClose: @escaping () -> Void) {
    self.window = window; self.onClose = onClose
    super.init()
    window.delegate = self
  }
  func windowWillClose(_ notification: Notification) {
    guard let window, notification.object as? NSWindow === window else { return }
    // Removing just the dictionary entry is insufficient if AppKit still retains the window.
    window.contentViewController = nil
    window.contentView = nil
    window.delegate = nil
    self.window = nil
    let callback = onClose
    onClose = nil
    callback?()
  }
}
