import Foundation
import Testing
import WebKit
import Zer0Core

@testable import Zer0Shell

/// Nothing runs on a camera nobody approved.
///
/// Deliberately lopsided, the same way `ExtensionConsentTests` is and for a
/// sharper reason: a site permission prompt is triggered *by the page*, at a
/// moment the page picks, so almost every request the browser ever sees has to
/// be answered without a dialog — and a dialog that stopped appearing would be
/// invisible in exactly the same way as one that started appearing too often.
///
/// What these cannot prove is written down where each one stops. There is no
/// way to construct a `WKSecurityOrigin` (its `init` is unavailable), so the
/// engine's own callback is never driven here; and there is no camera on a
/// machine running this, so "capture stopped" is asserted against the web
/// view's reported state rather than against a stream.
@MainActor
struct SitePermissionTests {
    private func newModel() -> BrowserModel {
        BrowserModel(storagePath: nil)
    }

    private func temporaryDatabase() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("zer0-site-permission-\(UUID().uuidString).sqlite")
            .path
    }

    /// A request the way the delegate would report one, minus the parts only
    /// WebKit can build.
    private func request(
        _ id: UInt64,
        tab: TabId,
        host: String = "meet.example",
        pageHost: String? = nil,
        capture: CaptureRequest = .camera,
        askedAtMs: UInt64 = 1_000_000
    ) -> SitePermissionRequest {
        let origin = ReportedOrigin(scheme: "https", host: host, port: 0)
        return SitePermissionRequest(
            request: id,
            tab: tab,
            origin: origin,
            pageOrigin: pageHost.map { ReportedOrigin(scheme: "https", host: $0, port: 0) }
                ?? origin,
            capture: capture,
            askedAtMs: askedAtMs
        )
    }

    /// Put a handler in the ledger under a known number, and report what it was
    /// told. `nil` means it was never called, which is the failure that leaves a
    /// page spinning forever with nothing on screen.
    private func holdAnswer(_ engine: EngineHost) -> (id: UInt64, answer: () -> WKPermissionDecision?) {
        final class Box: @unchecked Sendable { var value: WKPermissionDecision? }
        let box = Box()
        let id = engine.sitePermissions.hold { box.value = $0 }
        return (id, { box.value })
    }

    // MARK: - Nothing without an answer

    @Test("a page that asks is asked about, and holds nothing while it waits")
    func nothingIsGrantedWithoutAnAnswer() throws {
        let m = newModel()
        let tab = try #require(m.snapshot.activeTab)
        let held = holdAnswer(m.engine)

        m.send(.sitePermissionRequested(request: request(held.id, tab: tab)))

        #expect(m.pendingSitePermission?.prompt.request == held.id)
        #expect(held.answer() == nil, "the page must wait, not be answered by the browser")
        #expect(m.siteGrants.isEmpty)
    }

    @Test("an answer nobody could have given in the time is ignored")
    func aRaceAgainstAKeystrokeChangesNothing() throws {
        let m = newModel()
        let tab = try #require(m.snapshot.activeTab)
        let held = holdAnswer(m.engine)
        // Far in the future, so "now" on the shell's clock is inside the window.
        let asked = UInt64(Date().timeIntervalSince1970 * 1000) + 60_000
        m.send(.sitePermissionRequested(
            request: request(held.id, tab: tab, askedAtMs: asked)
        ))

        m.decideSitePermission(held.id, .allow)

        #expect(held.answer() == nil)
        #expect(m.siteGrants.isEmpty)
        #expect(
            m.pendingSitePermission != nil,
            "the question has to still be on screen, or a race silently answered it"
        )
    }

    @Test("an answer somebody read lands, and reaches the page")
    func anAnswerReachesThePage() throws {
        let m = newModel()
        let tab = try #require(m.snapshot.activeTab)
        let held = holdAnswer(m.engine)
        m.send(.sitePermissionRequested(request: request(held.id, tab: tab)))

        m.decideSitePermission(held.id, .allow)

        #expect(held.answer() == .grant)
        #expect(m.pendingSitePermission == nil)
        #expect(m.siteGrants.count == 1)
        #expect(m.siteGrants.first?.allowed == true)
        #expect(m.siteGrants.first?.origin == "https://meet.example")
    }

    // MARK: - Refusing

    @Test("a refused site is told no without being asked about again")
    func aSecondRequestForSomethingRefusedIsAnsweredWithoutAsking() throws {
        let m = newModel()
        let tab = try #require(m.snapshot.activeTab)
        let first = holdAnswer(m.engine)
        m.send(.sitePermissionRequested(request: request(first.id, tab: tab)))
        m.decideSitePermission(first.id, .block)
        #expect(first.answer() == .deny)

        let second = holdAnswer(m.engine)
        m.send(.sitePermissionRequested(request: request(second.id, tab: tab)))

        #expect(second.answer() == .deny)
        #expect(
            m.pendingSitePermission == nil,
            "a refused site that gets a second dialog is a site that learned to keep asking"
        )
    }

    @Test("closing the sheet tells the page no and writes nothing down")
    func dismissingIsAnAnswerToThePageAndNotToTheLedger() throws {
        let m = newModel()
        let tab = try #require(m.snapshot.activeTab)
        let held = holdAnswer(m.engine)
        m.send(.sitePermissionRequested(request: request(held.id, tab: tab)))

        m.decideSitePermission(held.id, .dismiss)

        #expect(held.answer() == .deny, "a promise nobody settles is worse than a refusal")
        #expect(m.siteGrants.isEmpty, "closing a window is not an instruction")
    }

    @Test("a background tab cannot put a sheet in front of the page you are reading")
    func aBackgroundTabIsRefusedWithoutADialog() throws {
        let m = newModel()
        let background = try #require(m.snapshot.activeTab)
        m.send(.openTab(space: nil, url: nil, parent: nil))
        #expect(m.snapshot.activeTab != background)
        let held = holdAnswer(m.engine)

        m.send(.sitePermissionRequested(request: request(held.id, tab: background)))

        #expect(held.answer() == .deny)
        #expect(m.pendingSitePermission == nil)
    }

    @Test("an origin nobody could read is refused and never written down")
    func anUnreadableOriginIsRefused() throws {
        let m = newModel()
        let tab = try #require(m.snapshot.activeTab)
        let held = holdAnswer(m.engine)
        var hostile = request(held.id, tab: tab)
        // Every local file shares this origin, so a grant to it is a grant to
        // every HTML file on the disk.
        hostile.origin = ReportedOrigin(scheme: "file", host: "", port: 0)

        m.send(.sitePermissionRequested(request: hostile))

        #expect(held.answer() == .deny)
        #expect(m.pendingSitePermission == nil)
        #expect(m.siteGrants.isEmpty)
    }

    @Test("a second question is refused rather than stacked behind the first")
    func questionsAreNotQueued() throws {
        let m = newModel()
        let tab = try #require(m.snapshot.activeTab)
        let first = holdAnswer(m.engine)
        m.send(.sitePermissionRequested(request: request(first.id, tab: tab)))

        let second = holdAnswer(m.engine)
        m.send(.sitePermissionRequested(
            request: request(second.id, tab: tab, capture: .microphone)
        ))

        #expect(second.answer() == .deny)
        #expect(first.answer() == nil)
        #expect(m.pendingSitePermission?.prompt.request == first.id)
    }

    @Test("a tab that closes mid-question does not leave the page waiting forever")
    func aClosingTabStillAnswers() throws {
        let m = newModel()
        let tab = try #require(m.snapshot.activeTab)
        let held = holdAnswer(m.engine)
        m.send(.sitePermissionRequested(request: request(held.id, tab: tab)))

        m.close(tab)

        #expect(held.answer() == .deny)
        #expect(
            m.engine.sitePermissions.outstandingCount == 0,
            "a handler dropped with the web view is a page that spins with no error"
        )
    }

    // MARK: - Taking it back

    @Test("revoking reaches the engine and not just the row")
    func revokingReachesTheEngine() throws {
        let m = newModel()
        let tab = try #require(m.snapshot.activeTab)
        let webView = try #require(m.engine.webView(for: tab))
        m.send(.navigationCommitted(tab: tab, url: "https://meet.example/room/1"))
        let held = holdAnswer(m.engine)
        m.send(.sitePermissionRequested(request: request(held.id, tab: tab)))
        m.decideSitePermission(held.id, .allow)
        let grant = try #require(m.siteGrants.first)

        m.setSitePermission(grant, allowed: false)

        #expect(m.siteGrants.first?.allowed == false)
        // What this proves is that the command reached a real `WKWebView` and
        // that WebKit reports it as not capturing. What it cannot prove is that
        // a *running* stream stops, because there is no camera on a machine
        // running this suite — that half is WebKit's documented contract for
        // `setCameraCaptureState(.none)` and is not observable here.
        #expect(webView.cameraCaptureState == .none)
    }

    @Test("forgetting an answer asks again rather than refusing")
    func forgettingAsksAgain() throws {
        let m = newModel()
        let tab = try #require(m.snapshot.activeTab)
        let held = holdAnswer(m.engine)
        m.send(.sitePermissionRequested(request: request(held.id, tab: tab)))
        m.decideSitePermission(held.id, .allow)
        let grant = try #require(m.siteGrants.first)

        m.forgetSitePermission(grant)
        #expect(m.siteGrants.isEmpty)

        let again = holdAnswer(m.engine)
        m.send(.sitePermissionRequested(request: request(again.id, tab: tab)))
        #expect(again.answer() == nil)
        #expect(m.pendingSitePermission != nil)
    }

    // MARK: - Across a relaunch

    @Test("a refusal survives a relaunch")
    func refusalsSurviveARelaunch() throws {
        let path = temporaryDatabase()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let first = BrowserModel(storagePath: path)
        let tab = try #require(first.snapshot.activeTab)
        let held = holdAnswer(first.engine)
        first.send(.sitePermissionRequested(request: request(held.id, tab: tab)))
        first.decideSitePermission(held.id, .block)
        first.saveNow(reason: .quitting)

        let second = BrowserModel(storagePath: path)
        let restored = try #require(second.siteGrants.first)

        // A refusal that evaporated on quit would come back as "never asked",
        // and the site would get another dialog on the next launch.
        #expect(restored.allowed == false)
        #expect(restored.origin == "https://meet.example")
        #expect(restored.capability == .camera)
    }

    @Test("an ephemeral space writes down nobody who may watch you")
    func anEphemeralSpacePersistsNothing() throws {
        let path = temporaryDatabase()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let first = BrowserModel(storagePath: path)
        let space = first.snapshot.activeSpace
        first.setProfile(space, SpaceProfile(userAgent: nil, ephemeral: true))
        let tab = try #require(first.snapshot.activeTab)
        let held = holdAnswer(first.engine)
        first.send(.sitePermissionRequested(request: request(held.id, tab: tab)))
        first.decideSitePermission(held.id, .allow)
        // It works inside the run — a video call in a throwaway space is still
        // a video call.
        #expect(first.siteGrants.count == 1)
        first.saveNow(reason: .quitting)

        let second = BrowserModel(storagePath: path)

        #expect(
            second.siteGrants.isEmpty,
            "a space that promised to remember nothing wrote down who may watch you"
        )
    }
}

// MARK: - The mapping the engine hands us

/// `WKMediaCaptureType` is an Objective-C enum, so Swift treats it as an open
/// set and a new case would arrive with no name. The pessimistic reading is the
/// only safe one, and it is the one thing about this mapping worth pinning.
@MainActor
struct SiteCaptureMappingTests {
    @Test("every capture type the SDK has maps to what it actually costs you")
    func everyCaptureTypeIsMapped() {
        #expect(SitePermissionDelegate.capture(.camera) == .camera)
        #expect(SitePermissionDelegate.capture(.microphone) == .microphone)
        #expect(SitePermissionDelegate.capture(.cameraAndMicrophone) == .cameraAndMicrophone)
    }
}

// MARK: - The prompt is not a dialog you can answer by accident

/// The two rules that make this sheet different from every other one in the
/// shell are both **absences**, and an assertion cannot observe something that
/// is not there. `SourceRuleTests` established the answer for that shape of
/// rule — read the source and fail on it — and this is that scanner pointed at
/// the one screen a hostile page gets to summon.
@Suite("a page cannot answer its own question")
struct SitePermissionSheetRuleTests {
    private var sheet: SourceScan.Source {
        get throws {
            let file = SourceScan.repoRoot
                .appending(path: "apple/Sources/Zer0Shell/SitePermissionSheet.swift")
            return SourceScan.Source(file: file, text: try String(contentsOf: file, encoding: .utf8))
        }
    }

    /// `.defaultAction` binds Return. On a sheet somebody opened, that is
    /// correct and `ExtensionConsentSheet` uses it. On a sheet a *page* opened,
    /// it is Return saying yes to a camera on behalf of whoever was typing
    /// something else when the page chose to interrupt.
    @Test("neither answer is bound to a key")
    func theSheetHasNoKeyEquivalents() throws {
        let source = try sheet
        var failures: [String] = []

        for spelling in [".defaultAction", ".cancelAction", "keyboardShortcut"] {
            for offset in SourceScan.occurrences(of: spelling, in: source.code) {
                failures.append("""
                    \(source.path):\(source.line(at: offset)): `\(spelling)` on the site
                      permission sheet. This sheet is opened by a page, at a moment the page
                      picks, and both of its buttons write an answer down. A key equivalent here
                      is a keystroke aimed at something else landing on a camera. Escape is
                      handled by `.onExitCommand`, and it gives the transient answer on purpose
                      (ADR-0056).
                    """)
            }
        }

        #expect(failures.isEmpty, "\n\(failures.joined(separator: "\n\n"))")
    }

    /// The half-second the buttons are dead for is the core's number, not this
    /// file's: the core is what actually ignores an early answer, and a shell
    /// with its own literal would either enable a button that does nothing or
    /// disable one for longer than the rule.
    @Test("the settle window comes from the core")
    func theSettleWindowIsNotWrittenHere() throws {
        let source = try sheet

        #expect(
            !SourceScan.occurrences(of: "promptSettleMs()", in: source.code).isEmpty,
            """

            \(source.path): the sheet no longer reads `promptSettleMs()`.
              The window the buttons are dead for has to be the same number the core ignores
              an answer inside, or the two disagree and the disagreement is invisible: a
              button that looks live and does nothing, or one that stays dead after the rule
              has passed (ADR-0056).
            """
        )
    }
}
