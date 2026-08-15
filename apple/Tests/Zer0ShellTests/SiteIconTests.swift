import AppKit
import Foundation
import Testing
import Zer0Core

@testable import Zer0Shell

/// Real favicons: what reaches the row, and what must never reach the network.
///
/// The rules themselves are locked in the core, where they belong. These are
/// the shell's half — reading a page's declarations without trusting them, and
/// turning cached bytes into a picture without asking for the same one twice.
@MainActor
struct SiteIconTests {
    private func newModel() -> BrowserModel { BrowserModel(storagePath: nil) }

    /// A real 1×1 PNG. Has to decode, because the point of half of this is
    /// that `NSImage` accepts it.
    private var png: Data {
        Data(base64Encoded: """
        iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==
        """)!
    }

    private func firstSpace(_ model: BrowserModel) -> (SpaceId, String) {
        let space = model.snapshot.spaces[0]
        return (space.id, space.dataStoreId)
    }

    // MARK: - What the page is allowed to tell us

    @Test("a page's declarations are read, sizes and all")
    func declarationsAreRead() async throws {
        let parsed = HostedWebView.candidates(in: [
            ["url": "https://a.com/16.png", "size": NSNumber(value: 16)],
            ["url": "https://a.com/icon.svg", "size": NSNumber(value: 0)],
        ])

        #expect(parsed.count == 2)
        #expect(parsed[0].sizePx == 16)
        // `sizes="any"` and a missing attribute both arrive as zero, and zero
        // is not a size — it is the absence of one, and the core ranks it as
        // such rather than as "smaller than everything".
        #expect(parsed[1].sizePx == nil)
    }

    @Test("nothing usable from the page means nothing is claimed")
    func hostileDeclarationsAreSurvived() async throws {
        // A page can shadow anything in its own world, so every one of these
        // is a real answer `evaluateJavaScript` can hand back. None of them may
        // crash, and none may become a candidate: an empty list is what makes
        // the core fall back to `/favicon.ico`, which is the right guess for a
        // page we could not read.
        #expect(HostedWebView.candidates(in: nil).isEmpty)
        #expect(HostedWebView.candidates(in: "not a list").isEmpty)
        #expect(HostedWebView.candidates(in: [1, 2, 3]).isEmpty)
        #expect(HostedWebView.candidates(in: [["size": NSNumber(value: 32)]]).isEmpty)
        #expect(HostedWebView.candidates(in: [["url": ""]]).isEmpty)
    }

    @Test("an absurd declared size is clamped rather than believed")
    func absurdSizesAreClamped() async throws {
        let parsed = HostedWebView.candidates(in: [
            ["url": "https://a.com/x.png", "size": NSNumber(value: 999_999_999)],
        ])

        #expect(parsed.first?.sizePx == 4096)
    }

    @Test("a page cannot hand us a thousand icons")
    func floodIsCapped() async throws {
        let flood = (0 ..< 5000).map { index in
            ["url": "https://a.com/\(index).png", "size": NSNumber(value: 32)] as [String: Any]
        }

        #expect(HostedWebView.candidates(in: flood).count == 16)
    }

    // MARK: - What reaches the row

    @Test("an icon that arrives replaces the letter")
    func anIconReachesTheRow() async throws {
        let model = newModel()
        let (space, store) = firstSpace(model)

        #expect(model.icon(forHost: "avelino.run") == nil, "nothing has arrived yet")

        model.send(.iconFetched(dataStoreId: store, host: "avelino.run", bytes: png))

        let image = try #require(
            model.icon(forHost: "avelino.run", in: space),
            "the bytes reached the core and never reached the row"
        )
        #expect(image.size.width > 0)
    }

    @Test("a failed fetch leaves the letter rather than blanking the row")
    func aFailureFallsBack() async throws {
        let model = newModel()
        let (_, store) = firstSpace(model)

        model.send(.iconFetchFailed(dataStoreId: store, host: "avelino.run"))

        // Nothing to draw is what puts the badge back. An empty square would be
        // worse than the placeholder it replaced.
        #expect(model.icon(forHost: "avelino.run") == nil)
    }

    @Test("bytes that are not an image never become one")
    func rubbishIsRefused() async throws {
        let model = newModel()
        let (_, store) = firstSpace(model)

        model.send(.iconFetched(
            dataStoreId: store,
            host: "avelino.run",
            bytes: Data("<!DOCTYPE html><html><body>404</body></html>".utf8)
        ))

        #expect(model.icon(forHost: "avelino.run") == nil)
    }

    @Test("one space does not read another space's icons")
    func spacesDoNotShare() async throws {
        let model = newModel()
        let (personal, store) = firstSpace(model)
        model.createSpace(named: "Work")
        let work = model.snapshot.activeSpace

        model.send(.iconFetched(dataStoreId: store, host: "avelino.run", bytes: png))

        #expect(model.icon(forHost: "avelino.run", in: personal) != nil)
        #expect(
            model.icon(forHost: "avelino.run", in: work) == nil,
            "a site visited in one space must still be requested in another"
        )
    }

    @Test("a host with nothing to show asks for nothing")
    func emptyHostsAreSafe() async throws {
        let model = newModel()

        #expect(model.icon(forHost: nil) == nil)
        #expect(model.icon(forHost: "") == nil)
    }

    // MARK: - Not asking the same question twice

    @Test("a site with no icon is asked about once, not once per frame")
    func missesAreNotReAsked() async throws {
        var asked = 0
        let icons = SiteIcons(bytes: { _, _ in
            asked += 1
            return nil
        })

        // Forty rows drawing forty times is one question, not sixteen hundred.
        for _ in 0 ..< 40 {
            _ = icons.image(space: 1, host: "avelino.run", revision: 7)
        }
        #expect(asked == 1)

        // Until the core says something changed, which is what turns a letter
        // into a picture the moment the bytes land.
        _ = icons.image(space: 1, host: "avelino.run", revision: 8)
        #expect(asked == 2)
    }

    @Test("an icon is decoded once and then kept")
    func hitsAreDecodedOnce() async throws {
        let data = png
        var asked = 0
        let icons = SiteIcons(bytes: { _, _ in
            asked += 1
            return data
        })

        _ = icons.image(space: 1, host: "avelino.run", revision: 1)
        for revision in 2 ... 20 {
            _ = icons.image(space: 1, host: "avelino.run", revision: UInt64(revision))
        }

        // An icon does not change while the app is open, so a hit is never
        // re-read and never re-decoded — however many times the revision moves
        // because some *other* site got one.
        #expect(asked == 1)
    }

    @Test("bytes that will not decode are treated as no icon at all")
    func undecodableBytesFallBack() async throws {
        let icons = SiteIcons(bytes: { _, _ in Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) })

        // A truncated PNG passes the core's magic-byte check and still will not
        // draw. `NSImage` returns an object with no size for it, and drawing
        // that is a blank where the letter used to be.
        #expect(icons.image(space: 1, host: "avelino.run", revision: 1) == nil)
    }

    @Test("the same site is one row whatever case it is written in")
    func hostsAreCaseInsensitive() async throws {
        let model = newModel()
        let (_, store) = firstSpace(model)

        model.send(.iconFetched(dataStoreId: store, host: "avelino.run", bytes: png))

        #expect(model.icon(forHost: "AVELINO.RUN") != nil)
    }

    // MARK: - What a badge stands for

    /// A tab on a page, and a conversation about it, in the space you are in.
    private func threadAbout(_ model: BrowserModel, _ url: String) -> BrowserTab {
        model.send(.openTab(space: nil, url: nil, parent: nil))
        let page = model.snapshot.activeTab!
        model.send(.navigationCommitted(tab: page, url: url))
        model.perform(.openChat)
        return model.snapshot.tabs.first { $0.id == model.snapshot.activeTab }!
    }

    private func host(of subject: SiteBadge.Subject) -> String? {
        switch subject {
        case let .site(host, _): host
        case .zer0: nil
        }
    }

    /// The defect, in one sentence: three conversations drew three identical
    /// letters.
    ///
    /// A chat tab's address is `zer0://chat?conversation=7`, so its own host is
    /// `chat` and every thread in the browser badged as a `C`. The anchor is
    /// what a conversation is about (ADR-0060), and it is what the row now says.
    @Test("a conversation wears the site of the page it is about")
    func aConversationWearsTheSiteOfThePageItIsAbout() async throws {
        let model = newModel()
        let chat = threadAbout(model, "https://avelino.run/posts/")

        #expect(model.badge(for: chat) == .site(host: "avelino.run", icon: nil))
        // Named rather than left to the equality above, because this is the
        // symptom somebody reported and the one a regression brings back.
        #expect(host(of: model.badge(for: chat)) != "chat")
    }

    @Test("three conversations about three sites are three different badges")
    func threeConversationsAreThreeDifferentBadges() async throws {
        let model = newModel()
        let sites = ["https://avelino.run/", "https://github.com/avelino", "https://news.ycombinator.com/"]

        let hosts = sites.map { host(of: model.badge(for: threadAbout(model, $0))) }

        #expect(hosts == ["avelino.run", "github.com", "news.ycombinator.com"])
    }

    /// The tab showing a thread has no standing: the anchor does.
    ///
    /// The same thread opens from a different tab and the page it is about does
    /// not change — and a thread outlives every tab that ever showed its page,
    /// which is precisely when reading the host off "whatever is open" would
    /// start answering with somebody else's site.
    @Test("closing the page's tab does not change what the conversation is about")
    func closingThePagesTabDoesNotChangeTheBadge() async throws {
        let model = newModel()
        let chat = threadAbout(model, "https://avelino.run/posts/")
        let page = model.snapshot.tabs.first { $0.url == "https://avelino.run/posts/" }!

        model.send(.closeTab(tab: page.id))

        #expect(host(of: model.badge(for: chat)) == "avelino.run")
    }

    /// A thread typed into the command bar is about no page in particular, and
    /// there is no favicon that would be true for it.
    ///
    /// It wears the browser's own mark — the same one every other `zer0://`
    /// page wears — rather than a letter taken from a host it does not have or
    /// the icon of whatever tab happens to be in front. Both of those would be
    /// the row naming a subject nobody chose (ADR-0018).
    @Test("a conversation about no page wears the browser's own mark")
    func aConversationAboutNoPageWearsTheMark() async throws {
        let model = newModel()
        // The tab this thread is started from has committed nothing, so there is
        // no page to anchor to.
        model.perform(.openChat)
        let chat = model.snapshot.tabs.first { $0.id == model.snapshot.activeTab }!

        #expect(model.badge(for: chat) == .zer0)
    }

    /// The default the exception is an exception to. Everything at an address of
    /// ours is the browser talking about itself, and says so with our mark.
    @Test("every other page of ours wears the browser's own mark")
    func ourOwnPagesWearOurOwnMark() async throws {
        let model = newModel()

        for address in ["zer0://history", "zer0://downloads", "zer0://chat"] {
            model.send(.openTab(space: nil, url: nil, parent: nil))
            let tab = model.snapshot.activeTab!
            model.send(.navigationCommitted(tab: tab, url: address))
            let opened = model.snapshot.tabs.first { $0.id == tab }!

            #expect(model.badge(for: opened) == .zer0, "\(address)")
        }
    }

    @Test("an ordinary tab still wears its own site")
    func anOrdinaryTabStillWearsItsOwnSite() async throws {
        let model = newModel()
        model.send(.openTab(space: nil, url: nil, parent: nil))
        let tab = model.snapshot.activeTab!
        model.send(.navigationCommitted(tab: tab, url: "https://avelino.run/"))

        let opened = model.snapshot.tabs.first { $0.id == tab }!
        #expect(host(of: model.badge(for: opened)) == "avelino.run")
    }

    /// The picture, once the core has one, comes from the anchored page's host
    /// and out of that page's own cookie jar.
    @Test("a conversation draws the icon its page's host was filed under")
    func aConversationDrawsItsPagesIcon() async throws {
        let model = newModel()
        let (_, store) = firstSpace(model)
        let chat = threadAbout(model, "https://avelino.run/posts/")

        #expect(model.badge(for: chat) == .site(host: "avelino.run", icon: nil), "not yet")

        model.send(.iconFetched(dataStoreId: store, host: "avelino.run", bytes: png))

        guard case let .site(host, icon) = model.badge(for: chat) else {
            Issue.record("a conversation about a page stopped standing for that page")
            return
        }
        #expect(host == "avelino.run")
        #expect(icon != nil, "the bytes reached the core and never reached the row")
    }

    /// A conversation in a private window must not become a new route to a
    /// request ADR-0044 forbids.
    ///
    /// It cannot be: reading a badge reads the core's cache and never asks for a
    /// fetch — whether one is ever made is decided when a page declares its
    /// icons, and there the answer for an ephemeral space is no. So the honest
    /// answer here is the letter, and it stays the letter even if bytes are
    /// handed to the core for that jar anyway.
    @Test("a conversation in an ephemeral space names its page and draws no icon")
    func anEphemeralConversationDrawsNoIcon() async throws {
        let model = newModel()
        let store = UUID().uuidString
        model.send(.createSpace(name: "Private", dataStoreId: store, ephemeral: true))
        let chat = threadAbout(model, "https://avelino.run/posts/")

        // It still says which page it is about: the address is a fact, and
        // nothing about it was fetched or written down.
        #expect(model.badge(for: chat) == .site(host: "avelino.run", icon: nil))

        model.send(.iconFetched(dataStoreId: store, host: "avelino.run", bytes: png))

        #expect(
            model.badge(for: chat) == .site(host: "avelino.run", icon: nil),
            "an ephemeral space kept an icon, so this badge is a second way in"
        )
    }
}
