#if canImport(AppKit)
import AppKit
import SwiftUI
#endif

#if canImport(AppKit)
/// Makes sure the session reaches disk, whatever way the browser goes away.
///
/// `scenePhase` is not enough on macOS: ⌘Q does not reliably deliver a phase
/// change before the process is gone, and a save that runs on a twenty second
/// timer loses everything you did in the last nineteen.
///
/// So there are three lines of defence:
///
/// 1. **Structural changes save immediately**, debounced. Opening a tab is
///    worth writing down; typing in a text field is not.
/// 2. **`applicationWillTerminate`**, which AppKit does guarantee.
/// 3. **A clean-shutdown marker**, so the next launch can tell whether the
///    last one ended properly.
public final class SessionLifecycle: NSObject, NSApplicationDelegate {
    private weak var model: BrowserModel?
    // nonisolated so `deinit` can take the monitor back down; only ever
    // assigned on the main actor, which is where `attach` runs.
    private nonisolated(unsafe) var keyMonitor: Any?

    /// Whether key presses are reaching the keymap at all.
    ///
    /// Exposed only so a test can see it. A keymap that is complete, correct
    /// and unplugged is the defect this whole path was written to fix, and it
    /// is invisible from every other angle.
    var isRoutingKeys: Bool { keyMonitor != nil }

    @MainActor
    public func attach(to model: BrowserModel) {
        self.model = model
        installKeyMonitor()
    }

    /// Route every key press through the core's keymap — and only ever act on
    /// the window it came from.
    ///
    /// A menu item can advertise one chord per command, so wiring shortcuts
    /// through menus alone loses every second chord — ⌘[ and ⌘] for Back and
    /// Forward were bound in the core, tested, and reached nothing — and loses
    /// every command that has no menu item at all.
    ///
    /// The monitor is application-wide, which is the price of that, and for a
    /// day it was also the bug: with Settings in front, ⌘W closed a tab behind
    /// it. Every press now arrives with the role of the window it was sent to,
    /// and browser commands only run for the browser (`WindowRole`).
    ///
    /// Installed here rather than in `BrowserModel.init` on purpose: the tests
    /// build models by the dozen and must not each leave a monitor behind
    /// listening to the whole application.
    @MainActor
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }

        // The closure inherits this method's main-actor isolation, which is
        // what lets it touch the model at all: `NSEvent` is not Sendable, so a
        // nonisolated handler could not carry one across.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let model = self?.model else { return event }

            // A key press carries the window it was dispatched to. The key
            // window is the fallback for the shapes that do not, so an event
            // with no window of its own is never mistaken for the browser.
            let window = event.window ?? NSApp.keyWindow

            switch model.handleKeyDown(
                keyCode: event.keyCode,
                characters: event.charactersIgnoringModifiers ?? "",
                modifiers: event.modifierFlags,
                from: WindowRole(of: window)
            ) {
            // Returning nil swallows the press, which is what keeps a chord
            // from also firing the menu item that advertises it.
            case .handled, .swallowed:
                return nil
            case .passOn:
                return event
            case .closesTheWindow:
                // Not `close()`: `performClose:` is what the standard Close
                // item sends, so a window that wants to object still can.
                window?.performClose(nil)
                return nil
            }
        }
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    public func applicationWillTerminate(_: Notification) {
        // The last chance there is. Everything after this point is gone.
        MainActor.assumeIsolated {
            model?.saveNow(reason: .quitting)
        }
    }

    /// Closing the last window quits, the way a browser should.
    public func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        true
    }

    /// Save before agreeing to quit, not after.
    ///
    /// And ask first when quitting would cost something. A download in flight
    /// dies with the process — `WKDownload` has no way back on the next launch
    /// — so the choice belongs to the person, made before the fact rather than
    /// discovered after it.
    public func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            if let model, model.shouldWarnBeforeQuitting, !confirmStoppingDownloads(model) {
                return .terminateCancel
            }
            model?.saveNow(reason: .quitting)
            return .terminateNow
        }
    }

    /// Says exactly what is about to be lost. "Are you sure?" is not a
    /// warning, it is a speed bump.
    @MainActor
    private func confirmStoppingDownloads(_ model: BrowserModel) -> Bool {
        let running = model.downloadsInFlight
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = running.count == 1
            ? "“\(running[0].filename)” is still downloading"
            : "\(running.count) downloads are still going"
        alert.informativeText = "Quitting stops them. zer0 can't pick them up again "
            + "next time, so they would have to start over."
        alert.addButton(withTitle: "Quit Anyway")
        alert.addButton(withTitle: "Keep Downloading")

        return alert.runModal() == .alertFirstButtonReturn
    }
}
#endif

/// Why a save is happening. Only used for logging, but a failed save with no
/// reason attached is a support ticket nobody can answer.
///
/// Off the `#if` because the model — which both hosts compile — names the
/// reason, and only the AppKit delegate that *triggers* saves on quit is
/// macOS's alone.
public enum SaveReason: String {
    case periodic
    case structuralChange
    case quitting
    case backgrounded
}
