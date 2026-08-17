import SwiftUI

// The browser on a phone: one scene, one window. The core's window registry
// answers for this host unchanged, and the session lives where
// `BrowserModel.defaultStoragePath()` puts it — the sandbox's Application
// Support, no different from the macOS arrangement in kind, only in location.
@main
struct Zer0IOSApp: App {
    @State private var model = BrowserModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                // The accent and the three levels of ink, at the root the same
                // way every macOS window dresses itself (ADR-0043). Everything
                // else the palette reaches, it reaches through these.
                .zer0Palette()
                .environment(model)
        }
        .onChange(of: scenePhase) { _, phase in
            // Belt and braces against suspension, the same line the macOS app
            // wears: iOS promises no warning before freezing the process, and
            // the twenty-second periodic saver must not be the thing a
            // suspended run never ran. The reason is shared; only the trigger
            // is this platform's.
            if phase != .active { model.saveNow(reason: .backgrounded) }
        }
    }
}
