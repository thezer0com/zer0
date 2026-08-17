#if canImport(AppKit)
import AppKit
#endif
import Foundation
import WebKit

/// Opening the Web Inspector.
///
/// **This is the only file in the shell that speaks SPI, and that is the whole
/// design** (ADR-0067). `WKWebView.isInspectable` is public and makes a view
/// *attachable* — it is what lets Safari's Develop menu reach our pages.
/// Nothing public *opens* the inspector; `_WKInspector` and
/// `WKWebView._inspector` are the only way, and they are underscored.
///
/// Three private calls, not one, and each was measured rather than assumed:
///
/// 1. With only `isInspectable` set, `_WKInspector` exists, `show` returns
///    cleanly, and `isVisible` stays `false` — nothing opens. WebKit gates the
///    *local* inspector on the `developerExtrasEnabled` preference, which has
///    no public spelling either and is only reachable by KVC on
///    `WKPreferences`.
/// 2. With both on, `show` opens it — docked into the SwiftUI view hosting the
///    page, where the next layout pass covers it.
/// 3. `detach` gives it a window of its own, which is the first state a person
///    can actually see.
///
/// So the door is knocked on rather than linked against. Every underscored name
/// below is a string looked up through the Objective-C runtime at the moment it
/// is needed. That matters more than it looks: a private *header* import turns
/// Apple deleting the symbol into a launch failure on somebody's machine, while
/// a runtime lookup turns it into `nil`, which this file can see and say
/// something about. ADR-0001's stated fear of SPI — *"the build passes and
/// Apple's next point update breaks the app with no warning"* — is a fear of
/// link-time coupling, and this has none.
///
/// `SourceRuleTests` keeps it that way: an underscored WebKit spelling anywhere
/// else under `apple/Sources/` fails the suite.
@MainActor
enum WebInspector {
    /// What a press actually did, so the caller can say so.
    enum Outcome {
        case shown
        case hidden
        /// WebKit no longer answers. Safari's Develop menu still reaches the
        /// page, because `isInspectable` is public API and is set on every web
        /// view at birth — which is the route the alert names, and the only one
        /// that can be promised without a private symbol behind it.
        case unavailable
    }

    /// Let the pages built from this configuration be inspected.
    ///
    /// Called where the web view is built, not the first time somebody presses
    /// the shortcut. A preference set after the view exists does not reach the
    /// page it already made, which is why the old code reloaded — and a
    /// shortcut whose visible effect is losing what you had typed is worse than
    /// one that does nothing.
    ///
    /// **The guard is the whole safety of this call, not a formality.**
    /// `setValue(_:forKey:)` on a key that no longer exists raises
    /// `NSUnknownKeyException`, and an Objective-C exception is not something
    /// Swift can catch — it would take the process down, on every tab, at
    /// launch. Asking first turns Apple deleting the preference into a page
    /// that cannot be inspected, which is the whole bargain ADR-0067 struck.
    ///
    /// Silent when it is gone: `toggle` is where that gets noticed and said out
    /// loud, and saying it once per web view created would be a sheet per tab.
    static func allowInspection(of configuration: WKWebViewConfiguration) {
        let preferences = configuration.preferences
        guard preferences.responds(to: Selector((developerExtrasSetter))) else { return }
        // KVC rather than `perform`, because the argument is a `BOOL` and
        // `perform` can only pass objects. KVC finds the underscored accessor
        // the guard just asked about.
        preferences.setValue(true, forKey: developerExtrasKey)
    }

    /// Show the inspector, or put it away if it is already up.
    static func toggle(_ webView: WKWebView) -> Outcome {
        guard let inspector = inspector(for: webView) else { return .unavailable }

        let visible = isVisible(inspector)
        let selector = Selector((visible ? "hide" : "show"))
        guard inspector.responds(to: selector) else { return .unavailable }

        inspector.perform(selector)
        if !visible { detachOnceItIsUp(inspector) }
        return visible ? .hidden : .shown
    }

    /// Put the inspector in a window of its own.
    ///
    /// **Not a preference — without this the inspector opens and cannot be
    /// seen.** WebKit's default is to dock the frontend into the inspected
    /// view's superview, and in this shell that superview belongs to SwiftUI:
    /// measured, the frontend lands inside
    /// `AppKitPlatformViewHost<PlatformViewRepresentableAdaptor<WebViewContainer>>`,
    /// SwiftUI lays the page back over the whole host on the next pass, and
    /// `isVisible` reports `true` over a thing nobody can see. Detached, it is
    /// a real `_WKInspectorWindow` with the page's title on it.
    ///
    /// **Waiting is the whole of it.** `detach` before the frontend exists is a
    /// silent no-op — WebKit has nothing attached to detach yet — and the
    /// inspector then comes up docked and stays there. So this waits for
    /// `isVisible`, which is the same ~150ms the rest of this file talks about,
    /// and then asks.
    ///
    /// It only has to work once per person: WebKit writes the dock side into
    /// the app's user defaults, so every later ⌥⌘I opens detached on its own
    /// and this wait finds it already visible and already out.
    ///
    /// **Bounded by how many times it has looked, not by a clock, and that is
    /// the difference between working and not.** A wall-clock deadline answers
    /// "has a second passed", which on a starved main actor is answered before
    /// the first look: measured under a full test suite, this loop got **one**
    /// look in 15.2 seconds, found the inspector not up yet — it needs about
    /// 150ms — and gave up on it permanently. The inspector then stays docked
    /// behind the page for the rest of the session, which under SwiftUI is
    /// invisible, so ⌥⌘I on a busy machine appears to do nothing at all.
    ///
    /// Counting looks asks the question that is about the inspector rather than
    /// about the machine: has it appeared in the fifty chances it was given.
    /// That is the same second it always was when nothing else is running, and
    /// still fifty real chances when everything is. A bound is still needed —
    /// a wait with no end is how a "temporary" poll becomes a thread that never
    /// stops — and a docked inspector is a bad outcome rather than a broken one.
    ///
    /// One caveat worth writing down, because it cost an afternoon: `detach`
    /// deadlocks when the inspected web view *is* its window's `contentView`,
    /// which is the shape a bare AppKit probe has and is never the shape here.
    /// If a web view is ever hosted without SwiftUI in between, this call is the
    /// first place to look.
    private static func detachOnceItIsUp(_ inspector: NSObject) {
        // Named rather than written inline: a bare "detach" literal here is a
        // selector for a method that exists in this scope, and Swift refuses it
        // in favour of `#selector` — which cannot be written for a method no
        // header declares.
        let selector = Selector((detachSelector))
        guard inspector.responds(to: selector) else { return }

        // **Held weakly, and that is what makes the longer wait safe.** Counting
        // looks rather than seconds means this task can be alive for a while on
        // a busy machine, and the page it belongs to can be closed underneath
        // it. A closed page has no inspector to put in a window, so the honest
        // answer is to stop rather than to send `detach` to whatever is left.
        Task { @MainActor [weak inspector] in
            for _ in 0 ..< looksForTheFrontend {
                guard let inspector else { return }
                if isVisible(inspector) {
                    inspector.perform(selector)
                    return
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    private static let detachSelector = "detach"

    /// Fifty chances at twenty milliseconds: the second this always waited on
    /// an idle machine, expressed as something a busy one cannot take away.
    private static let looksForTheFrontend = 50

    /// Whether the inspector is on screen for this page.
    ///
    /// **Not symmetric, and measured rather than assumed.** `hide` clears this
    /// before it returns; `show` sets it about 150ms later, once WebKit has the
    /// frontend up. So a second press inside that window sees `false` and shows
    /// again, which is a no-op — and every press at human speed toggles. The
    /// alternative, remembering here what we last asked for, would be a second
    /// copy of state that goes wrong the moment somebody closes the inspector
    /// with its own close button.
    static func isShowing(_ webView: WKWebView) -> Bool {
        guard let inspector = inspector(for: webView) else { return false }
        return isVisible(inspector)
    }

    /// The window the inspector is actually in, if it is in one.
    ///
    /// Exists so "the inspector opened" can be checked against something a
    /// person could have seen, rather than against WebKit's opinion of itself.
    /// `isVisible` was `true` in the arrangement where the frontend was buried
    /// under the page and nothing was on screen; a window is not.
    ///
    /// macOS-only because the inspector itself is: on iOS `_WKInspector` does
    /// not exist and `inspector(for:)` answers `nil`, so there is no window to
    /// ask about and no `NSWindow` to name.
    #if canImport(AppKit)
    static func window(for webView: WKWebView) -> NSWindow? {
        guard let inspector = inspector(for: webView),
              let frontend = inspector.value(forKey: "inspectorWebView") as? NSView
        else { return nil }
        return frontend.window
    }
    #endif

    /// `isVisible` is a `BOOL` and so cannot come back through `perform`, which
    /// only returns objects. KVC finds the same getter and boxes it.
    private static func isVisible(_ inspector: NSObject) -> Bool {
        (inspector.value(forKey: "isVisible") as? Bool) ?? false
    }

    /// Whether this WebKit still has an inspector behind the door.
    ///
    /// Read without a web view so a caller can ask before it has one — and so
    /// the test that watches for the symbol disappearing has something to ask.
    /// All three, because `show` opens nothing without the preference: that is
    /// measured, not assumed. Two of three would report an inspector that is
    /// reachable and never appears.
    static var isAvailable: Bool {
        NSClassFromString(inspectorClassName) != nil
            && WKWebView.instancesRespond(to: Selector((inspectorAccessor)))
            && WKPreferences.instancesRespond(to: Selector((developerExtrasSetter)))
    }

    /// The page's inspector, or nil on a WebKit that no longer has one.
    private static func inspector(for webView: WKWebView) -> NSObject? {
        let selector = Selector((inspectorAccessor))
        guard webView.responds(to: selector) else { return nil }
        // A property getter, so the value is not owned here — hence
        // `takeUnretainedValue`.
        return webView.perform(selector)?.takeUnretainedValue() as? NSObject
    }

    /// Spelled as data rather than as code, because the source scanner that
    /// keeps SPI confined to this file reads the shell as text and would
    /// otherwise have to make an exception for the one file allowed to fail it.
    /// Naming them once also means the test below asks about the same strings
    /// this file actually uses, instead of a copy that can drift.
    static let inspectorClassName = "_WKInspector"
    static let inspectorAccessor = "_inspector"
    /// The KVC key, and the underscored accessor KVC resolves it to.
    /// `WKPreferences` publishes neither `developerExtrasEnabled` nor
    /// `setDeveloperExtrasEnabled:`; the pair it really has is
    /// `_developerExtrasEnabled` / `_setDeveloperExtrasEnabled:`, which KVC
    /// finds through its underscore fallback. Both are named because the key is
    /// what is written and the selector is what can be asked about.
    static let developerExtrasKey = "developerExtrasEnabled"
    static let developerExtrasSetter = "_setDeveloperExtrasEnabled:"
}
