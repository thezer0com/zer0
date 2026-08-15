import AppKit
import Foundation
import WebKit
import Zer0Core

/// A tab's web view, and the context menu it puts up.
///
/// The subclass exists for one reason: **`willOpenMenu(_:with:)` is the only
/// route to a `WKWebView`'s context menu on macOS**, and it is an `NSView`
/// method rather than anything on a delegate. Read off this machine's SDK
/// rather than remembered: `WKUIDelegate`'s `contextMenuConfigurationForElement`
/// and its three companions are all `API_AVAILABLE(ios(13.0))`, they answer
/// with a `UIContextMenuConfiguration`, and there is no macOS equivalent
/// anywhere in `WKUIDelegate.h`. `menu(for:)` returns `nil` — measured — because
/// the menu is built in the web content process and arrives afterwards.
///
/// Every view in this browser is one of these, which is the guarantee rather
/// than a rule: `HostedWebView` cannot be handed a `WKWebView` that has no
/// context menu, because its initialiser will not take one.
///
/// See ADR-0091.
///
/// Not `final`, and for a measured reason rather than a taste: the menu this
/// amends is built out of process and then **tracks modally**, so a test that
/// lets one open never returns. Watching `NSMenu.didBeginTrackingNotification`
/// and cancelling from the handler was tried and hangs the same way. The only
/// way to read a real engine-built menu is from inside `willOpenMenu`, and the
/// only way for a test to get in there is to subclass. `PageMenuTests` does.
@MainActor
class PageView: WKWebView {
    /// Which tab this is. Filled in by `HostedWebView`, which is the only thing
    /// that ever builds one of these.
    var tab: TabId?
    /// Where a chosen row goes. The core decides what the row does.
    var emit: (@MainActor (Action) -> Void)?
    /// What Settings calls the configured search engine, or `nil` when the
    /// template is one nobody has a name for.
    var searchEngineName: (@MainActor () -> String?)?

    /// What was under the pointer when this gesture started, and the rows the
    /// core drew for it.
    ///
    /// Set before the engine is ever told about the click, which is what makes
    /// the race impossible rather than unlikely — see `rightMouseDown`.
    private var pending: (target: PageTarget, items: [PageMenuItem])?

    /// Whether the page had already been read when the engine handed a menu
    /// over. Readable so `PageMenuTests` can assert the ordering the whole
    /// design rests on — it is the one property of this class that a screenshot
    /// could never show and an assertion has to.
    var sawTargetBeforeTheMenu: Bool { pending != nil }

    // MARK: - The gesture

    /// `super` cannot be named from inside a closure that captured `self`, so
    /// the forward has to be a method of its own. That is a compiler rule, not
    /// a style choice: the closure spelling is refused outright.
    private func forwardToEngine(_ event: NSEvent) {
        super.rightMouseDown(with: event)
    }

    /// Read the page, *then* let the engine see the click.
    ///
    /// The ordering is the whole design. The engine builds its menu in the web
    /// content process and hands it over asynchronously; the hit test is also
    /// asynchronous. Starting both and hoping the hit test wins would be a race
    /// that is usually fine, and "usually" is what this project has learned not
    /// to build on. Forwarding the event **from inside the hit test's own
    /// completion handler** means the engine has not been asked for a menu yet
    /// when the answer arrives, so `willOpenMenu` cannot run first.
    ///
    /// Measured over eight gestures: eight menus, eight with the hit test
    /// already in hand.
    ///
    /// Replaying a stale event works — measured, a right-click on a text field
    /// forwarded this way still produces the engine's full editing menu,
    /// spelling submenu and all, and the page keeps answering afterwards.
    override func rightMouseDown(with event: NSEvent) {
        pending = nil
        let spot = convert(event.locationInWindow, from: nil)

        evaluateJavaScript(Self.hitTest(at: spot)) { [weak self] result, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let target = self.target(from: result)
                self.pending = (target, pageMenuAdditions(target: target))
                self.forwardToEngine(event)
            }
        }
    }

    /// Amend the menu the engine built.
    ///
    /// Amend rather than replace. The engine's menu carries spelling
    /// corrections, Look Up, Translate, Share, the media items and Picture in
    /// Picture, and rebuilding those by hand would lose real work to gain a
    /// menu that reads the same. What is added here is what was missing, and
    /// what is swapped out is what was measured to be false.
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        defer { super.willOpenMenu(menu, with: event) }
        guard let pending else { return }

        // ADR-0054, one step earlier than the policy delegate. The engine's own
        // link rows would offer to open, download and copy an address inside
        // this browser; the navigation door refuses every one of them, so they
        // are roads that dead-end. A row that cannot act does not earn its
        // place.
        if let link = pending.target.linkUrl, internalClaimsScheme(url: link) {
            for identifier in Self.engineLinkRows {
                if let index = menu.indexOfItem(withIdentifier: identifier) {
                    menu.removeItem(at: index)
                }
            }
            return
        }

        for item in pending.items {
            place(row(for: item, in: pending.target), for: item, in: menu)
        }
    }

    override func didCloseMenu(_ menu: NSMenu, with event: NSEvent?) {
        pending = nil
        super.didCloseMenu(menu, with: event)
    }

    // MARK: - Reading the page

    /// What is under the pointer, asked of the page because there is nowhere
    /// else to ask.
    ///
    /// Written defensively (ADR-0024): a page may have shadowed
    /// `elementFromPoint`, may have no document yet, and may throw from
    /// anything. A script that fails entirely returns nothing at all, which
    /// this reads as "we could not see the page" rather than "there is nothing
    /// there" — and the difference shows up as rows that are absent rather than
    /// rows that are wrong.
    ///
    /// The selection is reported **only when the pointer is on it**, which is
    /// checked against the range's own client rectangles. Without that, a
    /// selection made half a screen away would put "Search for …" on a menu
    /// opened somewhere else — and it would stay there, because a menu drawn
    /// this way never lets the engine clear the selection.
    private static func hitTest(at spot: CGPoint) -> String {
        """
        (function (x, y) {
          try {
            var out = { link: null, image: null, selection: null };
            for (var n = document.elementFromPoint(x, y); n; n = n.parentElement) {
              var tag = (n.tagName || '').toUpperCase();
              if (!out.link && tag === 'A' && n.href) { out.link = String(n.href); }
              if (!out.image && tag === 'IMG' && n.currentSrc) { out.image = String(n.currentSrc); }
            }
            var s = window.getSelection();
            if (s && s.rangeCount && !s.isCollapsed) {
              var rects = s.getRangeAt(0).getClientRects();
              for (var i = 0; i < rects.length; i++) {
                var r = rects[i];
                if (x >= r.left && x <= r.right && y >= r.top && y <= r.bottom) {
                  out.selection = String(s);
                  break;
                }
              }
            }
            return out;
          } catch (e) { return null; }
        })(\(Int(spot.x.rounded())), \(Int(spot.y.rounded())))
        """
    }

    /// Everything in `result` came out of a page, so none of it is trusted: a
    /// non-string is dropped rather than coerced, and an empty one is nothing
    /// rather than an address.
    ///
    /// The two navigation facts are filled in whatever the page said, including
    /// when it said nothing at all. They are the engine's, not the document's,
    /// so a page that cannot be read still gets Back and Forward.
    private func target(from result: Any?) -> PageTarget {
        let found = result as? [String: Any]
        return PageTarget(
            linkUrl: Self.address(found?["link"]),
            imageUrl: Self.address(found?["image"]),
            selection: (found?["selection"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            canGoBack: canGoBack,
            canGoForward: canGoForward
        )
    }

    private static func address(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    // MARK: - Drawing a row

    private func row(for item: PageMenuItem, in target: PageTarget) -> NSMenuItem {
        let row = NSMenuItem(
            title: title(for: item, in: target),
            action: #selector(choosePageMenuRow(_:)),
            keyEquivalent: ""
        )
        row.target = self
        // The item travels back by name rather than by index: a row that
        // outlived its menu would otherwise act on whatever is now in its slot.
        row.representedObject = Box(item: item, target: target)
        if let symbol = Self.symbol(for: item) {
            row.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        return row
    }

    /// Titles, in the platform's own capitalisation, matching the engine's rows
    /// they sit beside.
    private func title(for item: PageMenuItem, in target: PageTarget) -> String {
        switch item {
        case .openLinkInNewTab: "Open Link in New Tab"
        case .openLinkInNewWindow: "Open Link in New Window"
        case .saveLinkedFile: "Download Linked File"
        case .openImageInNewTab: "Open Image in New Tab"
        case .saveImage: "Download Image"
        case .searchForSelection: searchTitle(for: target)
        case .back: "Back"
        case .forward: "Forward"
        }
    }

    /// The engine's row says "Search with Google" whatever Settings names, which
    /// is this interface stating something false. This one names the engine when
    /// the core has a name for it, and says only what it is doing when it does
    /// not — never a vendor nobody chose.
    private func searchTitle(for target: PageTarget) -> String {
        guard let query = pageMenuSearchQuery(target: target) else { return "Search the Web" }
        let shown = query.count > 24 ? query.prefix(24).trimmingCharacters(in: .whitespaces) + "…" : query
        guard let engine = searchEngineName?() else { return "Search for “\(shown)”" }
        return "Search \(engine) for “\(shown)”"
    }

    /// The symbol a row we *added* wears.
    ///
    /// Photographed before this existed: three unadorned rows between "Open
    /// Link" and "Copy Link", both of which the engine gives a symbol. A menu
    /// where half the rows have an icon and half do not reads as broken before
    /// anybody has read a word of it, and no assertion would ever have caught
    /// it.
    ///
    /// `nil` for the four rows that *replace* one of the engine's: those wear
    /// the icon of the row they took the place of, which is the symbol the rest
    /// of the system already uses for that idea. See `place`.
    private static func symbol(for item: PageMenuItem) -> String? {
        switch item {
        // A window with a plus is `macwindow.badge.plus`, which is what the
        // engine puts on the row beside this one; a tab with a plus is the
        // same idea one container down.
        case .openLinkInNewTab, .openImageInNewTab: "plus.rectangle.on.rectangle"
        case .back: "chevron.backward"
        case .forward: "chevron.forward"
        case .openLinkInNewWindow, .saveLinkedFile, .saveImage, .searchForSelection: nil
        }
    }

    /// Carries a chosen row's meaning across `representedObject`, which is
    /// `Any?` and would otherwise take anything at all.
    private final class Box: NSObject {
        let item: PageMenuItem
        let target: PageTarget

        init(item: PageMenuItem, target: PageTarget) {
            self.item = item
            self.target = target
        }
    }

    @objc private func choosePageMenuRow(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? Box, let tab else { return }
        // Nothing is decided here. The core checks the row against the target it
        // was drawn for and turns it into whatever it means.
        emit?(.chosePageMenuItem(tab: tab, item: box.item, target: box.target))
    }

    // MARK: - Where a row goes

    /// Where among the engine's own rows one of ours belongs.
    ///
    /// Platform vocabulary, so it is the host's answer and not the core's: a
    /// `webkit2gtk` menu has entirely different rows to sit beside, and it
    /// inherits *which* rows this browser adds without inheriting where.
    ///
    /// The identifiers are WebKit's, read off a real menu rather than a header —
    /// they are not declared in the public SDK. `menuIdentifiersAreStillWhatWebKitSets`
    /// is what notices if one is ever renamed.
    private enum Placement {
        case replacing(String)
        case before(String)
    }

    private static let engineLinkRows = [
        "WKMenuItemIdentifierOpenLink",
        "WKMenuItemIdentifierOpenLinkInNewWindow",
        "WKMenuItemIdentifierDownloadLinkedFile",
        "WKMenuItemIdentifierCopyLink",
    ]

    private static func placement(of item: PageMenuItem) -> Placement {
        switch item {
        case .openLinkInNewTab: .before("WKMenuItemIdentifierOpenLinkInNewWindow")
        // The engine's row of this name asks through `createWebViewWith` with
        // every window feature unset, and a page that described no window gets
        // a tab (ADR-0075). Measured. So the row said "New Window" and produced
        // a tab, and ours takes its place.
        case .openLinkInNewWindow: .replacing("WKMenuItemIdentifierOpenLinkInNewWindow")
        // Measured to reach nothing at all: neither `didBecome download` nor
        // any delegate this browser has. The same invocation reached
        // `createWebViewWith` for the row beside it, so the instrument works.
        case .saveLinkedFile: .replacing("WKMenuItemIdentifierDownloadLinkedFile")
        case .openImageInNewTab: .before("WKMenuItemIdentifierOpenImageInNewWindow")
        case .saveImage: .replacing("WKMenuItemIdentifierDownloadImage")
        case .searchForSelection: .replacing("WKMenuItemIdentifierSearchWeb")
        // The engine's page menu is one row.
        case .back: .before("WKMenuItemIdentifierReload")
        case .forward: .before("WKMenuItemIdentifierReload")
        }
    }

    /// An anchor that is not there puts the row at the top.
    ///
    /// Position is not a claim, so a row in an unfamiliar place is still true —
    /// which is why this falls back rather than dropping the row. What must
    /// never happen is a *replacement* leaving the engine's row in place beside
    /// ours, and that cannot: `replacing` removes before it inserts.
    private func place(_ row: NSMenuItem, for item: PageMenuItem, in menu: NSMenu) {
        switch Self.placement(of: item) {
        case let .replacing(identifier):
            guard let index = menu.indexOfItem(withIdentifier: identifier) else {
                menu.insertItem(row, at: 0)
                return
            }
            // Wear the icon of the row being replaced. Choosing our own
            // would put two symbols for one idea in one menu, and the engine's
            // is the one the rest of the system uses for it — including on the
            // versions of macOS this was not photographed on.
            row.image = menu.items[index].image
            menu.removeItem(at: index)
            menu.insertItem(row, at: index)

        case let .before(identifier):
            menu.insertItem(row, at: menu.indexOfItem(withIdentifier: identifier) ?? 0)
        }
    }
}

extension NSMenu {
    /// Where a row with this identifier sits, or `nil`.
    ///
    /// `indexOfItem(withIdentifier:)` does not exist on `NSMenu`; only
    /// `NSMenuItem.identifier` does. Written once here rather than at each of
    /// the seven call sites above.
    func indexOfItem(withIdentifier identifier: String) -> Int? {
        items.firstIndex { $0.identifier?.rawValue == identifier }
    }
}
