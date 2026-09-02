import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by `MainView` once the scene exists; see the note in
    /// `MainWindow.swift`.
    var reopenMainWindow: (() -> Void)?

    /// The daemon serves independently of the UI, so the last window closing
    /// is not a reason to exit. The status item remains as proof we are here.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Clicking the Dock icon with no window open reopens the main window —
    /// the reason the Dock icon is kept rather than hidden after a close.
    /// Returning `false` claims the event so AppKit skips its own handling,
    /// which cannot recreate a closed SwiftUI `Window` scene.
    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows: Bool
    ) -> Bool {
        guard !hasVisibleWindows else { return true }
        reopenMainWindow?()
        NSApp.activate(ignoringOtherApps: true)
        return false
    }
}
