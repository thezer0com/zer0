import Foundation
import Security
import Testing
import WebKit
@testable import Zer0Shell
import Zer0Core

/// The engine is always answered, exactly once.
///
/// This is the invariant with the worst failure anywhere in this shell, and it
/// was measured rather than reasoned about: a `didReceive:challenge:` whose
/// completion handler is never called produces **no `didFinish`, no `didFail`
/// and no timeout**. The tab holds a white rectangle for as long as the browser
/// is open, indistinguishable from a slow page, and no error screen can catch
/// it because no error is ever reported.
@MainActor
struct AuthLedgerTests {
    /// One answer reaches the engine, and it carries what was typed.
    @Test("signing in hands the engine the credential and empties the ledger")
    func signingInAnswersOnce() {
        let ledger = AuthChallengeLedger()
        var answers: [(URLSession.AuthChallengeDisposition, URLCredential?)] = []
        let request = ledger.hold { disposition, credential in
            answers.append((disposition, credential))
        }

        ledger.supply(
            URLCredential(user: "alice", password: "hunter2", persistence: .none),
            for: request
        )
        ledger.answer(request, AuthDecision.useCredential)

        #expect(answers.count == 1)
        #expect(answers.first?.0 == .useCredential)
        #expect(answers.first?.1?.user == "alice")
        #expect(ledger.outstandingCount == 0)
        // Nothing typed outlives the answer that used it.
        #expect(ledger.heldCredentialCount == 0)
    }

    @Test("cancelling still answers, so the navigation ends rather than hangs")
    func cancellingStillAnswers() {
        let ledger = AuthChallengeLedger()
        var answers: [URLSession.AuthChallengeDisposition] = []
        let request = ledger.hold { disposition, _ in answers.append(disposition) }

        ledger.answer(request, AuthDecision.cancel)

        #expect(answers == [.cancelAuthenticationChallenge])
        #expect(ledger.outstandingCount == 0)
    }

    /// `performDefaultHandling` is the state this browser was in before, and it
    /// is measurably the wrong answer: the 401 commits and the person reads the
    /// server's refusal bytes as if they were a page.
    @Test("nothing here ever answers with the engine's own default handling")
    func defaultHandlingIsNeverTheAnswer() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/Zer0Shell/AuthChallengeHost.swift"),
            encoding: .utf8
        )
        #expect(
            !source.contains(".performDefaultHandling"),
            "the 401 body is back on screen as a page"
        )
        #expect(
            !source.contains(".rejectProtectionSpace"),
            "a decision about the protocol crept in beside the decision about the person"
        )
    }

    /// The unreachable combination, answered by refusing rather than guessing.
    @Test("a credential that was never supplied cancels rather than being invented")
    func nothingSuppliedCancels() {
        let ledger = AuthChallengeLedger()
        var answers: [(URLSession.AuthChallengeDisposition, URLCredential?)] = []
        let request = ledger.hold { answers.append(($0, $1)) }

        ledger.answer(request, AuthDecision.useCredential)

        #expect(answers.first?.0 == .cancelAuthenticationChallenge)
        #expect(answers.first?.1 == nil)
    }

    @Test("one challenge cannot be answered twice")
    func answeringTwiceCallsTheHandlerOnce() {
        let ledger = AuthChallengeLedger()
        var calls = 0
        let request = ledger.hold { _, _ in calls += 1 }

        ledger.answer(request, AuthDecision.cancel)
        ledger.answer(request, AuthDecision.cancel)
        ledger.answer(request, AuthDecision.useCredential)

        #expect(calls == 1)
    }

    @Test("proceeding on a certificate uses the trust the challenge arrived with")
    func proceedingUsesTheTrust() {
        let ledger = AuthChallengeLedger()
        var answers: [(URLSession.AuthChallengeDisposition, URLCredential?)] = []
        let request = ledger.hold { answers.append(($0, $1)) }
        ledger.hold(
            trust: Certificates.trust([Certificates.selfsigned], host: "localhost"),
            for: request
        )

        ledger.answer(request, TrustDecision.proceed)

        #expect(answers.first?.0 == .useCredential)
        #expect(answers.first?.1 != nil, "proceeding did not hand the engine a trust credential")
    }

    @Test("refusing a certificate answers, so the failure screen gets its turn")
    func refusingACertificateAnswers() {
        let ledger = AuthChallengeLedger()
        var answers: [URLSession.AuthChallengeDisposition] = []
        let request = ledger.hold { disposition, _ in answers.append(disposition) }
        ledger.hold(
            trust: Certificates.trust([Certificates.selfsigned], host: "localhost"),
            for: request
        )

        ledger.answer(request, TrustDecision.refuse)

        #expect(answers == [.cancelAuthenticationChallenge])
        #expect(ledger.outstandingCount == 0)
    }

    /// A trust challenge with nothing to proceed on refuses rather than
    /// building a credential out of nothing.
    @Test("proceeding with no trust object refuses")
    func proceedingWithNothingRefuses() {
        let ledger = AuthChallengeLedger()
        var answers: [URLSession.AuthChallengeDisposition] = []
        let request = ledger.hold { disposition, _ in answers.append(disposition) }

        ledger.answer(request, TrustDecision.proceed)

        #expect(answers == [.cancelAuthenticationChallenge])
    }
}

/// Which certificates reach the core at all.
///
/// **WebKit hands the delegate a server-trust challenge on every TLS
/// connection, not only on the ones it would have refused.** That was measured
/// rather than assumed, and getting it wrong cost this browser every https page
/// it had: `example.com`, with a certificate nothing on earth objects to, was
/// reported to the core as a rejected certificate, refused for want of an
/// exception, and failed as `NSURLErrorCancelled` — which ADR-0016 deliberately
/// draws no screen for. A tab opened, said "New Tab", and stayed white.
///
/// So `Action.serverTrustRejected` has to mean what it is called, and the only
/// thing that can say whether this machine accepts a chain is this machine.
@MainActor
struct ServerTrustGateTests {
    /// A protection space carrying a real `SecTrust`, the way one arrives from
    /// the engine. `serverTrust` is read-only and has no initialiser, so it is
    /// overridden rather than set.
    private final class TrustSpace: URLProtectionSpace, @unchecked Sendable {
        private let trust: SecTrust

        init(host: String, trust: SecTrust) {
            self.trust = trust
            super.init(
                host: host,
                port: 443,
                protocol: "https",
                realm: nil,
                authenticationMethod: NSURLAuthenticationMethodServerTrust
            )
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not decoded") }

        override var serverTrust: SecTrust? { trust }
    }

    /// The engine's side of a challenge. Nothing here is called: the answer
    /// travels back through the completion handler, which is what the ledger
    /// holds.
    private final class Engine: NSObject, URLAuthenticationChallengeSender {
        func use(_: URLCredential, for _: URLAuthenticationChallenge) {}
        func continueWithoutCredential(for _: URLAuthenticationChallenge) {}
        func cancel(_: URLAuthenticationChallenge) {}
    }

    private func challenge(for space: URLProtectionSpace) -> URLAuthenticationChallenge {
        URLAuthenticationChallenge(
            protectionSpace: space,
            proposedCredential: nil,
            previousFailureCount: 0,
            failureResponse: nil,
            error: nil,
            sender: Engine()
        )
    }

    /// A chain this machine accepts: the private-CA leaf, with its own root
    /// installed as the anchor. That is what a public certificate looks like to
    /// `SecTrustEvaluateWithError` — a chain that reaches a root the evaluation
    /// is willing to end at — without needing a network to fetch one.
    private func acceptedTrust() -> SecTrust {
        let trust = Certificates.trust(
            [Certificates.leaf, Certificates.ca], host: "localhost"
        )
        SecTrustSetAnchorCertificates(trust, [Certificates.certificate(Certificates.ca)] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        return trust
    }

    private func hosted(
        _ ledger: AuthChallengeLedger,
        emit: @escaping @MainActor (Action) -> Void
    ) -> HostedWebView {
        HostedWebView(
            tab: TabId(1),
            webView: PageView(frame: .zero, configuration: WKWebViewConfiguration()),
            adoptDownload: { _, _ in },
            permissions: SitePermissionLedger(),
            dialogs: PageDialogLedger(),
            authChallenges: ledger,
            openWindow: { _, _, _ in nil },
            emit: emit
        )
    }

    @Test("a certificate this machine accepts is never reported as rejected")
    func anAcceptedCertificateIsNotReported() throws {
        let ledger = AuthChallengeLedger()
        var reported: [Action] = []
        let view = hosted(ledger) { reported.append($0) }
        var answers: [(URLSession.AuthChallengeDisposition, URLCredential?)] = []

        view.webView(
            view.webView,
            didReceive: challenge(for: TrustSpace(host: "localhost", trust: acceptedTrust()))
        ) { disposition, credential in
            answers.append((disposition, credential))
        }

        #expect(
            !reported.contains { if case .serverTrustRejected = $0 { true } else { false } },
            """
            A certificate this machine accepts was reported to the core as rejected. \
            The core has no exception for it, so it answers Refuse, WebKit fails the \
            navigation as NSURLErrorCancelled, and ADR-0016 draws nothing for a \
            cancellation — which is every https page in this browser opening as a \
            blank tab called "New Tab" with no error on it.
            """
        )
        #expect(answers.count == 1, "the engine was left without an answer")
        #expect(answers.first?.0 == .useCredential)
        #expect(answers.first?.1 != nil, "the connection was not allowed to continue")
        #expect(ledger.outstandingCount == 0)
    }

    /// The other half, and the half ADR-0094 is about: a chain this machine
    /// does not accept still goes to the core with its facts, and nothing is
    /// answered until the core says so.
    @Test("a certificate this machine refuses still reaches the core")
    func aRefusedCertificateStillReachesTheCore() throws {
        let ledger = AuthChallengeLedger()
        var reported: [Action] = []
        let view = hosted(ledger) { reported.append($0) }
        var answered = false

        view.webView(
            view.webView,
            didReceive: challenge(for: TrustSpace(
                host: "localhost",
                trust: Certificates.trust([Certificates.selfsigned], host: "localhost")
            ))
        ) { _, _ in answered = true }

        #expect(
            reported.contains { if case .serverTrustRejected = $0 { true } else { false } },
            "a certificate that did not check out never reached the core, so no screen can say why"
        )
        #expect(!answered, "the shell answered a question that is the core's")
        #expect(ledger.outstandingCount == 1)
    }
}

/// Reading a real chain into the measurements the core decides on.
///
/// Every expectation here was first observed against a live server. The point
/// of the suite is the *separation*: a self-signed certificate for the right
/// name, one for the wrong name, one that expired, and one under a private CA
/// have to come out as four different sets of facts, or the screen collapses
/// back into "this connection isn't private".
@MainActor
struct CertificateFactsTests {
    @Test("a self-signed certificate for the right name says exactly that")
    func selfSignedForTheRightName() {
        let facts = CertificateFacts.measure(
            Certificates.trust([Certificates.selfsigned], host: "localhost"),
            host: "localhost"
        )

        #expect(facts.selfSigned)
        #expect(!facts.reachesTrustedAnchor)
        #expect(facts.hostMatches, "a certificate that does cover localhost read as the wrong name")
        #expect(facts.chainLength == 1)
        #expect(facts.covers.contains("localhost"))
        #expect(facts.notAfterMs != nil)
        #expect(facts.fingerprint.count == 64, "not a SHA-256 in hex: \(facts.fingerprint)")
    }

    @Test("a certificate for another name is the only one that fails the name check")
    func wrongName() {
        let facts = CertificateFacts.measure(
            Certificates.trust([Certificates.wronghost], host: "localhost"),
            host: "localhost"
        )

        #expect(!facts.hostMatches)
        #expect(facts.covers.contains("not-the-host.example"))
        // And the core turns that into the fault that leads.
        let report = certificateReport(host: "localhost", port: 0, certificate: facts, nowMs: nowMs())
        #expect(report.headline.contains("not for localhost"))
    }

    /// The one that would have been wrong without pinning the verify date: an
    /// expired certificate must not also read as unreachable-anchor noise, or
    /// the screen tells somebody two things when one is true.
    @Test("an expired certificate is expired and its dates are readable")
    func expired() {
        let facts = CertificateFacts.measure(
            Certificates.trust([Certificates.expired], host: "localhost"),
            host: "localhost"
        )

        let notAfter = try! #require(facts.notAfterMs)
        #expect(notAfter < nowMs(), "the 2020 certificate did not read as past")
        #expect(facts.hostMatches, "the dates leaked into the name check")

        let report = certificateReport(host: "localhost", port: 0, certificate: facts, nowMs: nowMs())
        #expect(report.faults.contains { fault in
            if case .expired = fault { return true } else { return false }
        })
    }

    /// The row that forced `selfSigned` and `unknownIssuer` apart. A leaf under
    /// a company's own CA reaches no anchor and did **not** sign itself, and
    /// telling somebody their corporate certificate is self-signed would be
    /// telling them something untrue.
    @Test("a leaf under a private CA is not reported as self-signed")
    func privateAuthority() {
        let facts = CertificateFacts.measure(
            Certificates.trust([Certificates.leaf, Certificates.ca], host: "localhost"),
            host: "localhost"
        )

        #expect(!facts.selfSigned)
        #expect(!facts.reachesTrustedAnchor)
        #expect(facts.chainLength == 2)
        #expect(facts.issuer.contains("Acme"), "the issuer was not named: \(facts.issuer)")

        let report = certificateReport(host: "localhost", port: 0, certificate: facts, nowMs: nowMs())
        #expect(report.faults == [CertificateFault.unknownIssuer])
    }

    /// The instrument check. If a certificate that really validates produced
    /// faults, every expectation above would be measuring noise rather than the
    /// thing it names.
    @Test("two different certificates do not share a fingerprint")
    func fingerprintsDiffer() {
        let one = CertificateFacts.measure(
            Certificates.trust([Certificates.selfsigned], host: "localhost"),
            host: "localhost"
        )
        let two = CertificateFacts.measure(
            Certificates.trust([Certificates.expired], host: "localhost"),
            host: "localhost"
        )

        #expect(one.fingerprint != two.fingerprint)
        #expect(!one.fingerprint.isEmpty)
    }

    private func nowMs() -> UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }
}

/// Rules about the two screens that no assertion on a rendered view can make.
@MainActor
struct AuthSourceRuleTests {
    private func source(_ name: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/Zer0Shell/\(name)"),
            encoding: .utf8
        )
    }

    /// The server's realm is drawn as the server's, never folded into one of
    /// our sentences. The core keeps them apart; this is the half that could be
    /// undone in the view by interpolating one into the other.
    @Test("the panel never interpolates the server's realm into a sentence of ours")
    func realmIsNeverOurs() throws {
        let panel = try source("AuthChallengeSheet.swift")
        for spelling in [
            "\\(prompt.realm)",
            "\\(realm)\"",
            "Text(\"Sign in to \\(",
        ] {
            #expect(
                !panel.contains(spelling),
                "a server's own words were put inside one of ours: \(spelling)"
            )
        }
    }

    /// A password must not be able to reach a log, a crash report or a test
    /// failure message on its way past.
    @Test("no password is printed, logged or interpolated on the way to the engine")
    func noPasswordEscapes() throws {
        // Word boundaries, not substrings: the first version of this matched
        // `print(` inside `fingerprint(of:)` and failed on code that records
        // nothing. A rule that cries wolf gets deleted by the next person.
        for file in ["AuthChallengeHost.swift", "AuthChallengeSheet.swift"] {
            let text = try source(file)
            for spelling in ["print", "NSLog", "os_log", "debugPrint", "dump"] {
                #expect(
                    text.range(of: "\\b\(spelling)\\s*\\(", options: .regularExpression) == nil,
                    "\(file) can put what was typed somewhere it is recorded: \(spelling)"
                )
            }
        }
    }

    /// The way through a certificate warning is never the default action.
    ///
    /// The rule ADR-0056 wrote for the camera sheet, applied where it matters
    /// more: a Return already on its way down must not be what waves a
    /// certificate through. Return stays on Try Again.
    @Test("the way past a certificate carries no key equivalent")
    func continuingIsNotOnAKey() throws {
        let screen = try source("BrowserView.swift")
        let button = try #require(
            screen.range(of: "Button(\"Continue to \\(report.host) this time\")")
        )
        let after = screen[button.lowerBound...].prefix(400)
        #expect(
            !after.contains("keyboardShortcut"),
            "a keystroke can wave a certificate through"
        )
        #expect(
            after.contains(".buttonStyle(.link)")
                && after.contains(".foregroundStyle(.secondary)"),
            "the way past a warning became a button as loud as the safe one"
        )
        #expect(
            !after.contains(".borderedProminent"),
            "the way past a warning became the loudest thing on the screen"
        )
    }
}
