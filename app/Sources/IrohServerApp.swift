import AppKit
import SwiftUI

@main
struct IrohServerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Server", id: WindowID.main) {
            MainView()
        }
        .defaultSize(width: 720, height: 460)
        .commands {
            // A windowed app gets ⌘Q for free, and users press it without
            // reading. Rename it so it cannot be mistaken for "stop serving".
            CommandGroup(replacing: .appTermination) {
                Button("Quit (keep sharing)") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q")
            }
        }

        MenuBarExtra("IrohServer", systemImage: "shippingbox") {
            StatusMenu()
        }
    }
}

enum WindowID {
    static let main = "main"
}

struct MainView: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("Hello, world!")
            .font(.largeTitle)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear {
                // `AppDelegate` has no environment of its own, so hand it the
                // one action it needs. The closure stays valid after this
                // window closes, which is exactly when reopen is wanted.
                appDelegate?.reopenMainWindow = { openWindow(id: WindowID.main) }
            }
    }
}

/// Split out of the `MenuBarExtra` scene builder so it can read `openWindow`
/// from the environment; scene builders have no environment of their own.
struct StatusMenu: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("Daemon not connected")
            .foregroundStyle(.secondary)

        Divider()

        Button("Open IrohServer") {
            openWindow(id: WindowID.main)
            NSApp.activate(ignoringOtherApps: true)
        }

        Divider()

        Button("Quit IrohServer (keep sharing)") {
            NSApp.terminate(nil)
        }
    }
}

@MainActor
private var appDelegate: AppDelegate? { NSApp.delegate as? AppDelegate }

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by `MainView` once the scene exists; see the note there.
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
