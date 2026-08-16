import Foundation
import JavaScriptCore
import Testing
import WebKit
import Zer0Core

@testable import Zer0Shell

/// A real store listing, and the id it is showing.
private let listingId = "cjpalhdlnbpafiamejdnhcphjbkeiagm"
private let listing = "https://chromewebstore.google.com/detail/ublock-origin/\(listingId)"

@MainActor
private func newModel() -> BrowserModel {
    BrowserModel(storagePath: nil)
}

/// The tab a fresh model opens with. Required rather than defaulted: a test
/// that quietly ran against tab 0 when there was no tab would assert nothing.
@MainActor
private func onlyTab(_ model: BrowserModel) throws -> TabId {
    try #require(model.snapshot.activeTab)
}

@MainActor
private func newHost(_ model: BrowserModel) -> StoreInstallHost {
    // The model is what installs (and declares its runtime at its own door);
    // this core only answers where the store lives, so no runtime is the
    // honest declaration for it.
    StoreInstallHost(model: model, hosts: Zer0.inMemory(
        firstSpaceName: "Personal",
        dataStoreId: UUID().uuidString,
        capabilities: HostCapabilities(extensionRuntime: false)
    ).extensionStoreHosts())
}

/// Where the injected script is allowed to run.
///
/// The script edits the DOM of a page nobody at `zer0` wrote. What keeps that
/// from being a defect is that it runs on the store's hosts and nowhere else,
/// and that the rule for "the store's hosts" is the core's — the same one the
/// installer applies. These hold the JavaScript half of that rule to the Rust
/// half, host by host, because two spellings means the looser one is the one an
/// attacker gets.
@MainActor
struct StoreInstallHostRuleTests {
    /// Runs the guard the script actually carries, in a real JavaScript engine.
    private func guardAccepts(_ host: String) throws -> Bool {
        let core = Zer0.inMemory(
            firstSpaceName: "Personal",
            dataStoreId: UUID().uuidString,
            capabilities: HostCapabilities(extensionRuntime: false)
        )
        let context = try #require(JSContext())
        let source = StoreInstallScript.hostGuard(core.extensionStoreHosts())
        let function = try #require(context.evaluateScript(source))
        let answer = try #require(function.call(withArguments: [host]))
        #expect(context.exception == nil, "guard threw: \(context.exception as Any)")
        return answer.toBool()
    }

    /// What the installer would say about the same host.
    private func coreAccepts(_ host: String) -> Bool {
        let core = Zer0.inMemory(
            firstSpaceName: "Personal",
            dataStoreId: UUID().uuidString,
            capabilities: HostCapabilities(extensionRuntime: false)
        )
        return core.extensionIdForUrl(url: "https://\(host)/detail/name/\(listingId)") != nil
    }

    @Test("the script runs on the hosts the installer trusts")
    func theScriptRunsWhereTheInstallerLooks() throws {
        for host in ["chromewebstore.google.com", "chrome.google.com"] {
            #expect(try guardAccepts(host), "script refuses \(host)")
            #expect(coreAccepts(host), "core refuses \(host)")
        }
    }

    @Test("the script refuses every other origin")
    func theScriptRefusesEveryOtherOrigin() throws {
        // A script leaking onto another origin is worse than a greyed-out
        // button, so this list is the one that matters and it is deliberately
        // full of things that look like the store.
        let strangers = [
            "example.com",
            "avelino.run",
            "localhost",
            "google.com",
            "www.google.com",
            "accounts.google.com",
            "chromewebstore.google.com.evil.io",
            "evil-chromewebstore.google.com",
            "chromewebstore.google.com.attacker.example",
            "notchrome.google.com",
            "chromewebstore.google.co",
            "xn--chromewebstore-example.com",
            "",
        ]
        for host in strangers {
            #expect(try !guardAccepts(host), "script accepts \(host)")
            #expect(!coreAccepts(host), "core accepts \(host)")
        }
    }

    @Test("the two halves of the rule agree about case")
    func theTwoHalvesAgreeAboutCase() throws {
        #expect(try guardAccepts("ChromeWebStore.Google.COM"))
        #expect(coreAccepts("ChromeWebStore.Google.COM"))
    }

    @Test("a subdomain of the store is the store and a lookalike is not")
    func aSubdomainIsTheStoreAndALookalikeIsNot() throws {
        #expect(try guardAccepts("static.chromewebstore.google.com"))
        #expect(try !guardAccepts("evilchromewebstore.google.com"))
    }

    @Test("the script itself refuses to run over plain http")
    func theScriptRefusesPlainHttp() throws {
        let core = Zer0.inMemory(
            firstSpaceName: "Personal",
            dataStoreId: UUID().uuidString,
            capabilities: HostCapabilities(extensionRuntime: false)
        )
        let source = StoreInstallScript.source(hosts: core.extensionStoreHosts())
        // The guard is the first statement and it tests the scheme as well as
        // the host, because over http the host is whatever the network says.
        #expect(source.contains("location.protocol !== \"https:\""))
        let guardOffset = try #require(source.range(of: "isStoreHost(location.hostname)"))
        let domOffset = try #require(source.range(of: "querySelectorAll"))
        #expect(guardOffset.lowerBound < domOffset.lowerBound,
                "the DOM is touched before the host is checked")
    }
}

/// What the page is allowed to say.
@MainActor
struct StoreInstallMessageTests {
    @Test("the id comes from the core's reading of the URL, never from the page")
    func theIdComesFromTheUrl() {
        let model = newModel()
        let host = newHost(model)

        #expect(host.subject(ofFrameAt: listing) == listingId)
        // The same id, planted on a host that is not the store.
        #expect(host.subject(ofFrameAt: "https://evil.example/detail/x/\(listingId)") == nil)
        // The store, over a scheme that authenticates nobody.
        #expect(host.subject(ofFrameAt: "http://chromewebstore.google.com/detail/x/\(listingId)")
            == nil)
        // A store page that is not a listing.
        #expect(host.subject(ofFrameAt: "https://chromewebstore.google.com/category/extensions")
            == nil)
        #expect(host.subject(ofFrameAt: nil) == nil)
    }

    @Test("nothing but the kind is ever read out of a message")
    func nothingButTheKindIsReadOutOfAMessage() throws {
        // The structural half of the rule above. `subject` can only answer from
        // a URL, but that is worth nothing if somebody later adds a second path
        // that reads an id the page put in the body. This is the test that goes
        // red when they do.
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Zer0Shell/StoreInstall.swift")
        let source = try String(contentsOf: path, encoding: .utf8)

        var keys: Set<String> = []
        var rest = Substring(source)
        while let start = rest.range(of: "body[\"") {
            rest = rest[start.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { break }
            keys.insert(String(rest[..<end]))
        }
        #expect(keys == ["kind"], "the message body is read for more than its kind: \(keys)")
    }

    @Test("a message the script does not send is not a message")
    func anUnknownMessageIsNotAMessage() {
        #expect(StoreInstallChannel.message(named: "candidate") == .candidate)
        #expect(StoreInstallChannel.message(named: "adopted") == .adopted)
        #expect(StoreInstallChannel.message(named: "absent") == .absent)
        #expect(StoreInstallChannel.message(named: "press") == .pressed)

        for stranger in ["", "Press", "press ", "install", "uninstall", "remove", "grant"] {
            #expect(StoreInstallChannel.message(named: stranger) == nil, "accepted \(stranger)")
        }
    }
}

/// What the button in the page says, and why.
@MainActor
struct StoreInstallButtonStateTests {
    @Test("the button reflects what this machine holds, not what was last pressed")
    func theButtonSaysWhatThisMachineHolds() {
        let host = newHost(newModel())

        // Not here: the offer. Here and undecided: the decision it is waiting
        // on — which is the state the owner was stuck in, with 1Password
        // installed, holding nothing, and the page still saying "Add to zer0".
        #expect(host.resting(.notInstalled) == .offer)
        #expect(host.resting(.undecided) == .undecided)
        // Here and decided, either way: the useful offer is to take it away.
        #expect(host.resting(.grantedNothing) == .present)
        #expect(host.resting(.running(held: 3, asked: 5, withheld: .somethingProvidable)) == .present)
    }

    @Test("refusing is an outcome and never reported as a failure")
    func refusalIsAnOutcomeAndNotAFailure() {
        // Granting nothing installs the extension and leaves it not running
        // (ADR-0028). All of that was chosen; none of it went wrong. Saying
        // "Could not add" would be the browser calling somebody's answer an
        // error, and it is what the button said before ADR-0069.
        #expect(StoreInstallHost.Outcome.afterDeciding(running: false) == .refused)
        #expect(StoreInstallHost.Outcome.afterDeciding(running: false) != .failed)
        #expect(StoreInstallHost.Outcome.afterDeciding(running: true) == .added)
    }

    @Test("every state the shell can report has words in the page")
    func everyOutcomeHasALabel() throws {
        // The script falls back to "Add to zer0" for anything it does not
        // recognise, which means a new outcome with no label silently offers to
        // install something already installed. Enumerating the cases is what
        // makes that impossible to add quietly.
        let core = Zer0.inMemory(
            firstSpaceName: "Personal",
            dataStoreId: UUID().uuidString,
            capabilities: HostCapabilities(extensionRuntime: false)
        )
        let source = StoreInstallScript.source(hosts: core.extensionStoreHosts())

        for outcome in StoreInstallHost.Outcome.allCases where outcome != .offer {
            #expect(source.contains("\(outcome.rawValue):"),
                    "the page has nothing to say for \(outcome.rawValue)")
        }
        // And the four terminal-ish states read as four different things.
        let labels = ["Add to zer0", "Remove from zer0", "Finish setting up",
                      "Added to zer0", "Added, not running"]
        for label in labels {
            #expect(source.contains(label), "the page cannot say \(label)")
        }
    }

    @Test("what a press does is read from the browser, never from the page")
    func aPressMeansWhatTheBrowserHolds() throws {
        // The page reports that somebody pressed; it does not report what the
        // button was showing. If it did, a page could offer "Remove" over an
        // extension it does not have and get an install out of it, or the other
        // way round. `nothingButTheKindIsReadOutOfAMessage` is the other half.
        let source = try String(contentsOf: storeInstallSource, encoding: .utf8)
        let press = try #require(source.range(of: "case .pressed:"))
        let decision = try #require(source.range(of: "switch model.standing(of: id)"))
        #expect(press.lowerBound < decision.lowerBound)
        #expect(!source.contains("body[\"state\"]"))
    }
}

/// Where the file is, for the tests that read it.
private let storeInstallSource = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Sources/Zer0Shell/StoreInstall.swift")

/// What happens when the store changes its markup.
///
/// The script finds the store's control by the one property that survives
/// translation — it is the page's only disabled button — and that is a property
/// the store can change without telling anyone. So the interesting behaviour is
/// not the happy path, it is what is left when the button cannot be found.
@MainActor
struct StoreInstallFallbackTests {
    @Test("a page still arriving is not yet an answer")
    func silenceWhileLoadingIsNotAnAnswer() throws {
        // While the store is still drawing, "nothing found" is not a finding.
        // Saying `absent` here is what would put the banner on screen and then
        // take it away again a second later.
        let model = newModel()
        let tab = try onlyTab(model)

        model.send(.navigationStarted(tab: tab, url: listing))

        #expect(model.storeControlState(inTab: tab) == .unknown)
    }

    @Test("the script saying there is no button puts the banner back")
    func noButtonMeansTheBannerOffers() throws {
        let model = newModel()
        let tab = try onlyTab(model)

        model.storeControlChanged(tab: tab, to: .absent)
        #expect(model.storeControlState(inTab: tab) == .absent)
    }

    @Test("a page that finished loading in silence is a page with no button")
    func aFinishedPageThatSaidNothingHasNoButton() async throws {
        // The failure this covers is the injection not happening at all — a
        // WebKit change, a script that threw before its first line ran. Nothing
        // is posted, so without this the banner would wait for a message that
        // is never coming and the person would be left with no way to install.
        let model = newModel()
        let tab = try onlyTab(model)
        model.send(.navigationStarted(tab: tab, url: listing))
        #expect(model.storeControlState(inTab: tab) == .unknown)

        model.send(.navigationFinished(tab: tab))

        #expect(model.storeControlState(inTab: tab) == .absent,
                "a finished page that said nothing left the banner waiting forever")
    }

    @Test("the button being adopted is what silences the banner")
    func adoptionSilencesTheBanner() throws {
        let model = newModel()
        let tab = try onlyTab(model)

        model.storeControlChanged(tab: tab, to: .adopted)
        #expect(model.storeControlState(inTab: tab) == .adopted)

        // And it goes back the moment the control stops being there, which is
        // what a single-page navigation to something that is not a listing
        // looks like.
        model.storeControlChanged(tab: tab, to: .absent)
        #expect(model.storeControlState(inTab: tab) == .absent)
    }

    @Test("adoption is answered per tab, not for the window")
    func adoptionIsPerTab() throws {
        let model = newModel()
        let first = try onlyTab(model)
        model.send(.openTab(space: nil, url: nil, parent: nil))
        let second = try onlyTab(model)
        #expect(first != second)

        model.storeControlChanged(tab: first, to: .adopted)
        #expect(model.storeControlState(inTab: first) == .adopted)
        #expect(model.storeControlState(inTab: second) != .adopted,
                "one tab's button answered for another tab")
    }
}

/// Carrying out an install the page asked for.
@MainActor
struct StoreInstallRequestTests {
    /// The measured defect, and the shape of it rather than one symptom.
    ///
    /// The install used to live in `InstallBanner`, which is mounted from the
    /// listing being *offerable*. Downloading the package makes it installed,
    /// so the offer stops existing, so the banner is torn down — taking the
    /// `@State` and the consent sheet it was one frame away from presenting
    /// with it. What the owner saw: 1Password on disk, "You have not said what
    /// it may do yet" in Settings, and a button in the page stuck on "Adding…"
    /// waiting for an outcome that could not arrive.
    ///
    /// So the lock is structural: the sheet is not presented by the view the
    /// listing mounts. Moving it back is the regression, it looks tidier, and
    /// this is what goes red.
    @Test("an install started from the page outlives the offer that started it")
    func anInstallStartedFromThePageSurvivesTheOfferDisappearing() throws {
        let banner = try String(
            contentsOf: shellSource("InstallBanner.swift"),
            encoding: .utf8
        )
        #expect(!banner.contains(".sheet("),
                "the consent sheet is presented by a view the install itself unmounts")
        #expect(!banner.contains("@State"),
                "an install's state in the banner is state the banner can take with it")

        let window = try String(contentsOf: shellSource("BrowserView.swift"), encoding: .utf8)
        #expect(window.contains("ExtensionConsentSheet("),
                "nothing that outlives the listing presents the consent sheet")
    }

    @Test("the banner is mounted for a listing the tab's URL has not caught up with")
    func aFlowInProgressKeepsTheBannerMounted() throws {
        // The store is a single-page app, so a listing reached without loading
        // a document leaves the tab's URL behind what the frame is showing, and
        // `listingExtensionId` with it. The flow is the other way the banner
        // gets mounted, and without it the button in the page would report into
        // a window with nothing listening.
        let window = try String(contentsOf: shellSource("BrowserView.swift"), encoding: .utf8)
        #expect(window.contains("model.listingExtensionId ?? model.unfinishedExtensionFlowId"),
                "the banner is mounted from the listing alone, so a stale URL loses the install")
    }

    @Test("the browser never offers to add something it already has")
    func nothingOffersToAddWhatIsAlreadyInstalled() {
        let model = newModel()
        let host = newHost(model)

        // Nothing is installed in a fresh browser, so the offer stands.
        #expect(model.standing(of: listingId) == .notInstalled)
        #expect(host.resting(model.standing(of: listingId)) == .offer)
        // And the banner's own mount rule keeps saying so: `offeredExtensionId`
        // is the id only while there is something to add.
        #expect(model.offeredExtensionId == nil, "no listing is open")
    }
}

private func shellSource(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/Zer0Shell/\(name)")
}
