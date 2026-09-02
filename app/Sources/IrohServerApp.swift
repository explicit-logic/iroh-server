import AppKit
import SwiftUI

enum WindowID {
    static let main = "main"
}

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
