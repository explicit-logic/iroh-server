import Foundation
import Testing

/// Guards the bundle settings that are easy to lose in a project regeneration
/// and silently wrong at runtime.
struct BundleConfigurationTests {
    /// §6.2: a regular windowed app with a Dock icon, which keeps running in
    /// the menu bar after its window closes. A stray `LSUIElement` would strip
    /// the Dock icon at runtime without failing the build.
    @Test("app is a regular windowed app, not a menu-bar agent")
    func isRegularApp() throws {
        let info = try #require(Bundle.main.infoDictionary)
        #expect((info["LSUIElement"] as? Bool ?? false) == false)
    }

    @Test("bundle identifier matches the keychain access group and XPC peer requirement")
    func bundleIdentifier() {
        #expect(Bundle.main.bundleIdentifier == "dev.irohserver.app")
    }
}
