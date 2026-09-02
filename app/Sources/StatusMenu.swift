import AppKit
import SwiftUI

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
