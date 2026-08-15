import SwiftUI
import Zer0Core
import Zer0Shell

@main
struct Zer0App: App {
    @State private var model = BrowserModel()
    // AppKit's terminate hooks are the only ones that reliably fire on ⌘Q.
    // scenePhase alone loses whatever happened since the last periodic save.
    @NSApplicationDelegateAdaptor(SessionLifecycle.self) private var lifecycle
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase

    private static let browserWindow = "browser"
    private static let settingsWindow = "settings"
    private static let aboutWindow = "about"

    var body: some Scene {
        WindowGroup(id: Self.browserWindow) {
            BrowserView()
                .frame(minWidth: 860, minHeight: 560)
                // B · Fault, once, at the root — the accent, the three levels
                // of ink and the window's own background. Everything else the
                // palette reaches, it reaches through these (ADR-0043).
                .zer0Palette()
                // These are the windows pages live in, and the only ones
                // browser shortcuts act on. Everything else — Settings, About,
                // whatever comes next — is auxiliary by omission and keeps the
                // standard macOS behaviour for ⌘W and Escape (`WindowRole`).
                // The marker also claims which core window this scene is
                // drawing, which is what makes a press land in it (ADR-0065).
                .browserWindow(model)
                .environment(model)
                .onAppear { lifecycle.attach(to: model) }
                // Follows the Theme setting, which until now wrote a row in
                // SQLite and did nothing else.
                .preferredColorScheme(model.colorScheme)
                // Settings gets its own window rather than a sheet, so it does
                // not hold the browser hostage while you change something.
                .onChange(of: model.showingSettings) { _, showing in
                    guard showing else { return }
                    openWindow(id: Self.settingsWindow)
                    model.showingSettings = false
                }
                // ⌘N and ⇧⌘N decide in the core that a window exists; this is
                // the part that puts a scene on screen for it. Opening the
                // group by its own id makes another copy of itself, and the
                // marker inside claims the identity the core queued (ADR-0065).
                //
                // The guard reads the model rather than the value handed in,
                // and that is the difference between one window and N: SwiftUI
                // runs this in every open `BrowserView`, all with the same new
                // value. Taking the debt first means the rest find nothing owed.
                // Same shape as the Settings line above, and for the same
                // reason.
                .onChange(of: model.windowsToOpen) { _, _ in
                    guard model.windowsToOpen > 0 else { return }
                    model.openedOneWindow()
                    openWindow(id: Self.browserWindow)
                }
        }
        // No title bar: the page starts at the top of the window. Everything
        // the toolbar used to do is a shortcut or a trackpad gesture.
        .windowStyle(.hiddenTitleBar)
        .commands {
            // Every item below takes its shortcut from the core's keymap, so
            // rebinding one updates the menu with it and macOS and Linux never
            // drift apart.
            // AppKit's stock About panel reads its copy out of Info.plist and
            // has no room for the licence line, which for a browser that ships
            // someone else's engine is the part worth saying.
            CommandGroup(replacing: .appInfo) {
                Button("About zer0") { openWindow(id: Self.aboutWindow) }
            }

            CommandGroup(replacing: .appSettings) {
                menu(.showSettings)
                menu(.showExtensions)
            }

            CommandGroup(replacing: .newItem) {
                menu(.newTab)
                menu(.newWindow)
                menu(.newPrivateWindow)
                Divider()
                menu(.closeTab)
                menu(.closeWindow)
                menu(.reopenClosedTab)
                Divider()
                menu(.openLocation)
                Divider()
                menu(.newSpace)
                Divider()
                menu(.savePage)
                menu(.printPage)
            }

            CommandMenu("Navigate") {
                menu(.back)
                menu(.forward)
                Divider()
                menu(.reload)
                menu(.reloadIgnoringCache)
                menu(.stopLoading)
                Divider()
                menu(.nextTab)
                menu(.previousTab)
                menu(.nextSpace)
                menu(.previousSpace)
                Divider()
                menu(.togglePinTab)
                menu(.toggleMuteTab)
                Divider()
                // In the menu that is about the page you are on, because that
                // is what it acts on. Its title names the site, so the item
                // reads as a sentence about *this* page rather than as a
                // global switch that happens to live near one.
                menu(.toggleBlockingHere)
            }

            CommandGroup(replacing: .sidebar) {
                menu(.toggleSidebar)
                Divider()
                menu(.toggleSplitView)
                menu(.focusOtherPane)
                Divider()
                menu(.zoomIn)
                menu(.zoomOut)
                menu(.zoomReset)
            }

            // Where Safari keeps them, and where someone who wants them will
            // look. They answer to their chords either way now, but a shortcut
            // nobody can find is a shortcut only its author has.
            CommandMenu("Develop") {
                menu(.viewSource)
                menu(.toggleDevTools)
            }

            CommandGroup(after: .pasteboard) {
                menu(.copyCurrentUrl)
                Divider()
                menu(.findInPage)
                menu(.findNext)
                menu(.findPrevious)
            }

            CommandGroup(after: .windowList) {
                menu(.showHistory)
                menu(.showDownloads)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // Belt to the delegate's braces: this fires when the app is
            // hidden or the window closes, which is not always a terminate.
            if phase != .active { model.saveNow(reason: .backgrounded) }
        }

        Window("Settings", id: Self.settingsWindow) {
            SettingsView()
                .environment(model)
                .zer0Palette()
                .preferredColorScheme(model.colorScheme)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("About zer0", id: Self.aboutWindow) {
            AboutView()
                .zer0Palette()
                .preferredColorScheme(model.colorScheme)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }

    private func menu(_ command: UiCommand) -> some View {
        CommandMenuItem(command: command).environment(model)
    }
}
