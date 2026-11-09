import Foundation

/// Debug-only launch states for the screenshot script (`-demoScreen editor|suggestions|settings|defaults`).
/// Compiled out of release builds.
enum DemoScreen {
    static var current: String? {
        #if DEBUG
        UserDefaults.standard.string(forKey: "demoScreen")
        #else
        nil
        #endif
    }
}
