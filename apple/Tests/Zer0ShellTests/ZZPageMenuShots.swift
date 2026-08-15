import AppKit
import Foundation
import Testing
import WebKit
import Zer0Core

@testable import Zer0Shell

/// Photographs of the context menu, in each of its contexts and both
/// appearances. ADR-0091.
///
/// **This one cannot use `Shot`.** Every other harness in this suite renders an
/// `NSHostingView` offscreen with `cacheDisplay`, and a menu is not in the view
/// hierarchy at all: it is a window of its own, at a level above everything,
/// put up by AppKit while the main thread is inside a tracking session. There is
/// nothing for `cacheDisplay` to photograph.
///
/// So this shells out to `screencapture`, and it captures **one window id and
/// never the screen**. `screencapture` with no `-l` photographs whatever is in
/// front of the person running it, which on a working machine is their work.
/// The menu's window is found by asking the window server for this process's own
/// windows and taking the topmost, which is the menu by construction: nothing
/// else this process owns is above `NSPopUpMenuWindowLevel`.
///
/// Off by default with every other `ZZ` harness — `ZER0_SHOT=1 swift test
/// --filter ZZPageMenu` — because it puts a real window on screen and takes over
/// the pointer's menu for a moment.
@MainActor
struct ZZPageMenuShots {
    private final class Shooter: PageView {
        /// Where each photograph goes, and what to call it.
        var name = "menu"
        var captured: [String] = []
        var menus = 0
        private weak var openMenu: NSMenu?

        override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
            super.willOpenMenu(menu, with: event)
            captured = menu.items.map { $0.isSeparatorItem ? "———" : $0.title }
            menus += 1

            // Scheduled in `.common` so it runs *inside* the tracking session:
            // a timer in the default mode alone never fires while a menu is up.
            // Held on the view rather than captured by the timer: an `NSMenu`
            // is not `Sendable` and the closure is not on any actor until the
            // hop below, which the compiler is right to refuse. A `@MainActor`
            // class is `Sendable`, so the view carries it across instead.
            openMenu = menu
            let shot = Timer(timeInterval: 0.45, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    ZZPageMenuShots.photograph(self.name)
                    self.openMenu?.cancelTracking()
                }
            }
            RunLoop.main.add(shot, forMode: .common)
        }
    }

    /// The topmost window this process owns, which while a menu is tracking is
    /// the menu.
    private static func menuWindowId() -> CGWindowID? {
        let listed = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]]
        let mine = (listed ?? []).filter {
            ($0[kCGWindowOwnerPID as String] as? pid_t) == ProcessInfo.processInfo.processIdentifier
        }
        // Highest layer wins. `NSPopUpMenuWindowLevel` is 101 and an ordinary
        // window is 0, so this cannot pick the page by mistake.
        let top = mine.max { a, b in
            (a[kCGWindowLayer as String] as? Int ?? 0) < (b[kCGWindowLayer as String] as? Int ?? 0)
        }
        guard (top?[kCGWindowLayer as String] as? Int ?? 0) > 0 else { return nil }
        guard let number = top?[kCGWindowNumber as String] as? Int else { return nil }
        return CGWindowID(number)
    }

    private static func photograph(_ name: String) {
        guard let id = menuWindowId() else {
            print("shot: no menu window for \(name)")
            return
        }
        let directory = ProcessInfo.processInfo.environment["ZER0_SHOT_DIR"]
            ?? NSTemporaryDirectory()
        try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
        let path = (directory as NSString).appendingPathComponent("\(name).png")

        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // `-l` is the whole point: one window id, never the screen.
        capture.arguments = ["-x", "-o", "-l", String(id), path]
        try? capture.run()
        capture.waitUntilExit()
        print("shot: \(path)")
    }

    @Test(
        "the menu on a page, a link, an image and a selection, light and dark",
        .disabled(if: ProcessInfo.processInfo.environment["ZER0_SHOT"] == nil)
    )
    func theMenuInEachOfItsContexts() async throws {
        let server = try await TinyHTTPServer(routes: [
            "/page": .html("""
            <html><body style="font:16px -apple-system;margin:0;padding:0;background:#fff">
            <div style="height:60px"><a id="link" href="/target">a link here</a></div>
            <div style="height:60px"><img id="img" width="40" height="40"
              src="data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"></div>
            <div style="height:60px"><p id="sel">selectable words in a paragraph</p></div>
            <div style="height:60px"><p id="plain">plain page area</p></div>
            </body></html>
            """),
            "/target": .html("<html><body><p>target</p></body></html>"),
        ])
        defer { server.stop() }

        let model = BrowserModel(storagePath: nil)
        model.setSearchTemplate("https://duckduckgo.com/?q={}")
        let tab = try #require(model.snapshot.activeTab ?? model.snapshot.tabs.first?.id)

        let view = Shooter(frame: NSRect(x: 0, y: 0, width: 520, height: 300))
        view.tab = tab
        view.emit = { model.send($0) }
        view.searchEngineName = { model.currentSearchEngineName }

        let window = testWindow(NSRect(x: 80, y: 120, width: 520, height: 300))
        window.contentView?.addSubview(view)
        window.orderFrontRegardless()
        defer { window.close() }

        view.load(URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/page")!))
        #expect(await eventually { !view.isLoading && view.url?.path == "/page" })

        // One context per run, chosen by the environment.
        //
        // Not a loop, and that is a measurement rather than a preference:
        // AppKit swallows a right-click while a menu session is open, and this
        // harness cannot end the session in `willOpenMenu` the way
        // `PageMenuTests` does — the menu has to still be on screen when the
        // photograph is taken. The second gesture in a process never produced a
        // menu. A process per photograph is the honest way around it.
        //
        //   for c in page link image selection; do
        //     for a in light dark; do
        //       ZER0_SHOT=1 ZER0_SHOT_MENU=$c ZER0_SHOT_APPEARANCE=$a swift test …
        //     done
        //   done
        let environment = ProcessInfo.processInfo.environment
        let wanted = environment["ZER0_SHOT_MENU"] ?? "page"
        let suffix = environment["ZER0_SHOT_APPEARANCE"] ?? "light"
        let appearance: NSAppearance.Name = suffix == "dark" ? .darkAqua : .aqua

        do {
            window.appearance = NSAppearance(named: appearance)
            NSApp.appearance = NSAppearance(named: appearance)

            for (element, label, select) in [
                ("plain", "page", false),
                ("link", "link", false),
                ("img", "image", false),
                ("sel", "selection", true),
            ] where label == wanted {
                if select {
                    _ = try? await view.evaluateJavaScript(
                        """
                        (function () {
                          var n = document.getElementById('sel').firstChild;
                          var r = document.createRange();
                          r.setStart(n, 0); r.setEnd(n, 10);
                          var s = getSelection(); s.removeAllRanges(); s.addRange(r);
                          return String(s);
                        })()
                        """
                    )
                }
                view.name = "page-menu-\(label)-\(suffix)"
                // The selection is the first ten characters, so the pointer
                // has to be on those and not on the middle of the paragraph:
                // a menu opened beside a selection is a page menu.
                try await rightClick(element, in: view, window: window, atStart: select)
                print("\(view.name): \(view.captured.joined(separator: " | "))")
            }
        }
    }

    private func rightClick(
        _ id: String,
        in view: Shooter,
        window: NSWindow,
        atStart: Bool = false
    ) async throws {
        let answer = try await view.evaluateJavaScript(
            """
            (function () {
              var r = document.getElementById('\(id)').getBoundingClientRect();
              return [\(atStart ? "r.left + 8" : "r.left + r.width / 2"), r.top + r.height / 2];
            })()
            """
        )
        let pair = try #require(answer as? [Double])
        let before = view.menus
        let event = try #require(
            NSEvent.mouseEvent(
                with: .rightMouseDown,
                // A `WKWebView` is flipped, so its coordinates already run from
                // the top the way the page's do.
                location: view.convert(CGPoint(x: pair[0], y: pair[1]), to: nil),
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )
        )
        view.rightMouseDown(with: event)
        #expect(await eventually { view.menus > before })
        // The tracking session outlives `willOpenMenu`, and the photograph is
        // taken from inside it by the timer above. This waits it out.
        try await Task.sleep(for: .milliseconds(900))
    }
}
