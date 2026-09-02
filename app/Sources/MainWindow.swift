import AppKit
import SwiftUI

struct MainView: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("Hello, world!")
            .font(.largeTitle)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear {
                appDelegate?.reopenMainWindow = { openWindow(id: WindowID.main) }
            }
    }
}

@MainActor
private var appDelegate: AppDelegate? { NSApp.delegate as? AppDelegate }
