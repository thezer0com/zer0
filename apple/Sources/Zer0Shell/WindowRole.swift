import AppKit
import SwiftUI
import Zer0Core

/// Which window a key press came from.
///
/// The key monitor listens to the whole application — it has to, because a menu
/// item can advertise one chord per command and half the keymap has no menu item
/// at all (ADR-0012). What it must not do is act on every window as if it were
/// the browser: with Settings in front, ⌘W closed a tab nobody could see.
///
/// **Auxiliary is the default, and that is the point.** A window is the browser
/// only if it says so. A window added next year inherits standard macOS
/// behaviour rather than the browser's whole keymap, without anybody having to
/// remember this file exists.
public enum WindowRole: Equatable, Sendable {
    /// The window that hosts pages, **and which one of them**.
    ///
    /// It carries the identity because a `Bool` stopped being enough the day
    /// there could be two (ADR-0065). ADR-0053 asked "is this the browser?"
    /// and got the right answer for Settings; asked from the second browser
    /// window it also says yes, and the command then acts on whichever window
    /// the core happened to be pointing at — a tab closing behind another
    /// window, which is the exact failure ADR-0053 exists to prevent, one
    /// dimension along.
    case browser(WindowId)
    /// Settings, About, and anything else with a window of its own.
    case auxiliary

    /// Read from the window itself, not from its title. A title is copy, and
    /// copy gets localised — the day "Settings" is "Ajustes", a check against
    /// the string is a check that silently stops working.
    @MainActor
    public init(of window: NSWindow?) {
        guard let window, let id = BrowserWindows.identity(of: window) else {
            self = .auxiliary
            return
        }
        self = .browser(id)
    }

    /// Which window this press has to act on, or `nil` when it is not a browser
    /// window at all.
    public var windowId: WindowId? {
        switch self {
        case let .browser(id): id
        case .auxiliary: nil
        }
    }
}

/// What a command acts on, which is what decides whether it crosses into a
/// window that is not the browser.
///
/// The rule, in one sentence: **a command crosses only when what it does shows
/// up in front of the person who pressed it.** ⌘, from About puts Settings on
/// screen, so it crosses. ⌘R reloads a page in a window behind the one you are
/// looking at, so it does not — and neither does opening a tab, a space or a
/// find bar you would have to go and look for.
public enum CommandScope: Equatable, Sendable {
    /// It brings a window of its own to the front. It means the same thing
    /// wherever it is pressed, because wherever you press it, you see it happen.
    case opensItsOwnWindow
    /// The page, the tab, the space, or the browser window's own furniture.
    /// Pressed anywhere else it would act on something out of sight.
    case browserWindow
    /// Whatever is in front of you. In the browser that is a tab; in a window
    /// with no tabs in it, it is the window — which is what ⌘W has always meant
    /// on a Mac.
    case frontmost
}

public extension UiCommand {
    /// No `default:` on purpose (ADR-0031): a command added to the core has to
    /// say where it is allowed to land before this compiles. That is what makes
    /// this a rule rather than a list of exceptions somebody has to maintain.
    var scope: CommandScope {
        switch self {
        // The two that open the Settings window, at the pane they name. You
        // press ⌘, in About and Settings arrives in front of you, which is the
        // whole test.
        case .showSettings, .showExtensions:
            .opensItsOwnWindow

        // ⌘N and ⇧⌘N put a browser window in front of you wherever you press
        // them, which is the whole test this rule applies (ADR-0065). Pressed
        // from Settings they are exactly as reasonable as ⌘, is from About.
        case .newWindow, .newPrivateWindow:
            .opensItsOwnWindow

        // ⌘W closes the tab in front, ⇧⌘W closes the window in front, and both
        // mean "whatever I am looking at". From Settings, ⇧⌘W is Settings.
        case .closeTab, .closeWindow:
            .frontmost

        // Pressing an extension's button acts on the page in front of it and
        // opens a popup hanging off a button in that window's own sidebar.
        // Pressed from Settings it would fire at a page you cannot see, out of
        // a button that is not on screen.
        case .runPinnedExtension:
            .browserWindow

        // `openChat` is about the page you are on and opens where that page
        // is, so it needs the browser window in front the same way Reload does.
        //
        // `showHistory` and `showDownloads` sit with it since they became
        // pages rather than panes (ADR-0063). They used to bring a window of
        // their own to the front, which is what earned them the crossing; now
        // they open a tab, and a tab opened from a Settings window is a tab you
        // would have to go and look for.
        case .openChat, .showHistory, .showDownloads,
             .newTab, .reopenClosedTab, .openLocation,
             .back, .forward, .reload, .reloadIgnoringCache, .copyCurrentUrl,
             .nextTab, .previousTab, .selectTab, .togglePinTab, .toggleMuteTab,
             // It acts on the page you are looking at and reloads it to take
             // effect, so pressed from Settings it would silently reload
             // something behind that window. Same reason as Reload itself.
             .toggleBlockingHere,
             // Both are about the browser: one keeps the page in front of you,
             // the other opens a shelf inside the browser's own sidebar.
             // Neither has anything to say from a Settings window.
             .addBookmark, .toggleBookmarks,
             .newSpace, .nextSpace, .previousSpace, .selectSpace,
             .toggleSplitView, .focusOtherPane, .toggleSidebar,
             .savePage, .printPage, .viewSource, .toggleDevTools, .stopLoading,
             .findInPage, .findNext, .findPrevious,
             .zoomIn, .zoomOut, .zoomReset:
            .browserWindow
        }
    }

    /// Whether this command is willing to run for a press that arrived from
    /// `role`.
    func reaches(_ role: WindowRole) -> Bool {
        switch role {
        case .browser: true
        case .auxiliary: scope == .opensItsOwnWindow
        }
    }
}

/// What the shell should do with a press it just handed to the keymap.
///
/// A `Bool` was enough while every window was the browser. It is not enough
/// now: "I did not run it" and "I ran the window's own answer instead" are
/// different outcomes, and so is "I stopped it here so the menu bar could not
/// run it behind your back".
public enum KeyDisposition: Equatable, Sendable {
    /// It was a command, and it ran.
    case handled
    /// Not ours. Give it back to the window it came from.
    case passOn
    /// A browser command, pressed over a window that is not the browser.
    /// Stopped here so nothing further down acts on a window out of sight.
    case swallowed
    /// ⌘W over a window with no tabs in it. The platform's own answer —
    /// `performClose:`, which asks the window first and animates the way every
    /// other Mac window does.
    case closesTheWindow
}

/// The windows that host the browser, and which core window each one is.
///
/// A map rather than a set, because a press has to say *which* browser window
/// it came from (ADR-0065). Weak keys, so a closed window leaves on its own: a
/// table of strong references to dead windows would keep them alive and would
/// answer "browser" for a window that is gone.
@MainActor
enum BrowserWindows {
    private static let known = NSMapTable<NSWindow, WindowIdBox>.weakToStrongObjects()

    /// Which window is next in line for an identity.
    ///
    /// SwiftUI materialises a window some time after the core decided one
    /// exists, and gives us no way to hand a value to the view that will host
    /// it. So the core's id is queued when `OpenBrowserWindow` arrives and
    /// claimed by the first tag to land in a window without one — in order,
    /// because they are opened one at a time.
    private static var pending: [WindowId] = []

    static func expect(_ id: WindowId) { pending.append(id) }

    /// Give this window an identity, taking the one that was queued for it.
    ///
    /// `fallback` is what a window claims when nothing is queued: at launch
    /// there is a window in the core before any `OpenBrowserWindow` was ever
    /// emitted, and that first view has to be somebody.
    @discardableResult
    static func hold(_ window: NSWindow, fallback: WindowId) -> WindowId {
        if let existing = known.object(forKey: window) { return existing.id }
        let id = pending.isEmpty ? fallback : pending.removeFirst()
        known.setObject(WindowIdBox(id), forKey: window)
        return id
    }

    static func release(_ window: NSWindow) { known.removeObject(forKey: window) }

    static func identity(of window: NSWindow) -> WindowId? {
        known.object(forKey: window)?.id
    }

    /// The `NSWindow` a core window is being drawn in, if it is on screen.
    static func window(for id: WindowId) -> NSWindow? {
        guard let keys = known.keyEnumerator().allObjects as? [NSWindow] else { return nil }
        return keys.first { known.object(forKey: $0)?.id == id }
    }

    /// Test seam. `NSMapTable` has no value semantics to reset.
    static func forgetEverything() {
        known.removeAllObjects()
        pending.removeAll()
    }
}

/// `NSMapTable` stores objects, and `WindowId` is a struct.
private final class WindowIdBox {
    let id: WindowId
    init(_ id: WindowId) { self.id = id }
}

public extension View {
    /// Marks the window this view is hosted in as the browser window.
    ///
    /// Applied once, to the scene that hosts pages. Everything else in the app
    /// is auxiliary by omission, which is the safe direction: forgetting this
    /// modifier costs a window its shortcuts, where the opposite mistake costs
    /// somebody the tab they were reading.
    ///
    /// **The model is an argument, not something read from the environment**,
    /// and that is a guarantee rather than a preference (ADR-0066). The marker
    /// rides in a `background`, and a background is a *sibling* of the view it
    /// sits behind rather than a descendant — so `.environment(model)` applied
    /// anywhere inside this chain never reaches it. Reading it from there
    /// trapped on the first layout pass and took the whole app with it before a
    /// window ever appeared. Handed in, there is no lookup left to fail and no
    /// ordering left to remember.
    func browserWindow(_ model: BrowserModel) -> some View {
        background(BrowserWindowMarker(model: model))
    }
}

private struct BrowserWindowMarker: NSViewRepresentable {
    let model: BrowserModel

    func makeNSView(context _: Context) -> NSView { BrowserWindowTag(model: model) }
    func updateNSView(_: NSView, context _: Context) {}
}

/// A tag, not a control. It draws nothing and takes no clicks; the only thing
/// it does is tell the registry which window it landed in — and, since this is
/// the one place that knows a window hosts pages, take the top of that window
/// back off the system (`WindowTop`, ADR-0055).
final class BrowserWindowTag: NSView {
    private let top = WindowTopKeeper()
    private weak var model: BrowserModel?
    private var becameKey: (any NSObjectProtocol)?
    private var willClose: (any NSObjectProtocol)?

    init(model: BrowserModel?) {
        self.model = model
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    /// The identity this window claimed, once it is in one.
    private(set) var windowId: WindowId?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        // The core always has at least one window, so there is always somebody
        // for the first tag at launch to be.
        let fallback = model?.snapshot.keyWindow ?? WindowId(0)
        windowId = BrowserWindows.hold(window, fallback: fallback)
        top.attach(to: window)

        // The core's idea of which window is in front has to follow the
        // platform's, and this is the one place that hears about it. Without
        // it, clicking into a window and then pressing ⌘W would close a tab in
        // whichever window last ran a command.
        becameKey = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let id = self.windowId else { return }
                self.model?.focusWindow(id)
            }
        }
        // The red button, the Window menu, ⇧⌘W falling through to
        // `performClose:` — all of them close the window without the core
        // hearing, which would leave it holding a window full of live tabs
        // nobody can see (ADR-0065).
        willClose = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let id = self.windowId else { return }
                self.model?.windowClosedOnScreen(id)
            }
        }
        if window.isKeyWindow, let id = windowId { model?.focusWindow(id) }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let window, window !== newWindow {
            BrowserWindows.release(window)
            top.detach()
            for observer in [becameKey, willClose].compactMap({ $0 }) {
                NotificationCenter.default.removeObserver(observer)
            }
            becameKey = nil
            willClose = nil
        }
        super.viewWillMove(toWindow: newWindow)
    }

    // Sitting in a `background`, it spans the whole window. A marker that
    // answered a hit test would be a transparent sheet over the page.
    override func hitTest(_: NSPoint) -> NSView? { nil }
}

// MARK: - Which window a view is drawing

private struct BrowserWindowIdKey: EnvironmentKey {
    static let defaultValue: WindowId? = nil
}

public extension EnvironmentValues {
    /// The core window this view is being drawn for.
    ///
    /// `nil` means "whichever the core has in front", which is the right answer
    /// for anything outside a browser window and the only answer available
    /// before the scene has claimed an identity. Everything that draws a page
    /// or a tab list reads this, because with two windows "the active tab" is
    /// a question that needs a window in it (ADR-0065).
    var browserWindowId: WindowId? {
        get { self[BrowserWindowIdKey.self] }
        set { self[BrowserWindowIdKey.self] = newValue }
    }
}

/// Reports which core window it landed in, so the view above it can put that
/// into the environment for everything below.
///
/// A reader rather than an argument because SwiftUI creates the view before the
/// window exists, and `WindowGroup` has no way to hand one down.
public struct BrowserWindowIdentityReader: NSViewRepresentable {
    private let found: (WindowId?) -> Void

    public init(found: @escaping (WindowId?) -> Void) {
        self.found = found
    }

    public func makeNSView(context _: Context) -> NSView { IdentityReader(found: found) }
    public func updateNSView(_: NSView, context _: Context) {}
}

private final class IdentityReader: NSView {
    private let found: (WindowId?) -> Void

    init(found: @escaping (WindowId?) -> Void) {
        self.found = found
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // After the marker, which runs from the same layout pass and is what
        // put the identity in the registry.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            found(window.flatMap { BrowserWindows.identity(of: $0) })
        }
    }

    override func hitTest(_: NSPoint) -> NSView? { nil }
}
