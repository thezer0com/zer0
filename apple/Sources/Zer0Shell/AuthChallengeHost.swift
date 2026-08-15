import CryptoKit
import Foundation
import Security
import WebKit
import Zer0Core

/// Every authentication handler the engine has given us and we have not called
/// yet.
///
/// **The one invariant is that each handler is called exactly once**, and the
/// cost of breaking it here is higher than anywhere else in this shell.
/// Measured against a real server: a challenge whose completion handler is
/// never called produces no `didFinish`, no `didFail` and no timeout. The tab
/// sits on a white rectangle for as long as the browser is open, which is the
/// one outcome ADR-0016 exists to make impossible and the one no error screen
/// can catch.
///
/// So the handlers live on the host rather than on the per-tab delegate that
/// received them: a web view can be destroyed while the core is still deciding,
/// and the answer has to survive the view it came from.
@MainActor
final class AuthChallengeLedger {
    typealias Answer = @MainActor (URLSession.AuthChallengeDisposition, URLCredential?) -> Void

    private var outstanding: [UInt64: Answer] = [:]
    /// What somebody typed into the panel, held from the moment they press the
    /// button to the moment the core says to use it.
    ///
    /// This is the only place in the app besides `PasswordHost` where a
    /// password sits still, and it is dropped in the same statement that uses
    /// it. It never goes to the core: `AuthChoice` has three cases and none of
    /// them carries a value, which is what makes "a password cannot reach the
    /// core" structural rather than careful (ADR-0064).
    private var supplied: [UInt64: URLCredential] = [:]
    /// The trust object behind a server-trust challenge, kept only while that
    /// challenge is open.
    private var trusted: [UInt64: SecTrust] = [:]
    /// Monotonic, never reused. An id that came round again would let a stale
    /// answer settle a live question.
    private var nextRequest: UInt64 = 1

    func hold(_ handler: @escaping Answer) -> UInt64 {
        let request = nextRequest
        nextRequest += 1
        outstanding[request] = handler
        return request
    }

    /// Keep the trust object so a `Proceed` can build a credential out of it.
    func hold(trust: SecTrust, for request: UInt64) {
        trusted[request] = trust
    }

    /// Take what was typed, before the core is told anything.
    func supply(_ credential: URLCredential, for request: UInt64) {
        supplied[request] = credential
    }

    /// Answer a password challenge.
    ///
    /// Removing before calling, so a handler cannot run twice even if an answer
    /// somehow arrives twice.
    ///
    /// `.useCredential` with nothing supplied answers `.cancelAuthenticationChallenge`
    /// rather than guessing. That combination should be unreachable — the core
    /// only says `UseCredential` for a panel somebody pressed a button on — and
    /// if it ever happens, refusing is the direction that cannot sign anybody
    /// in as anybody (AGENTS.md: refuse rather than repair).
    func answer(_ request: UInt64, _ decision: AuthDecision) {
        guard let handler = outstanding.removeValue(forKey: request) else { return }
        let credential = supplied.removeValue(forKey: request)
        trusted.removeValue(forKey: request)

        switch decision {
        case .useCredential:
            guard let credential else {
                handler(.cancelAuthenticationChallenge, nil)
                return
            }
            handler(.useCredential, credential)
        case .cancel:
            // Not `performDefaultHandling`: that is the state this browser was
            // in before, where the 401 commits and the person reads the
            // server's refusal bytes as a page.
            handler(.cancelAuthenticationChallenge, nil)
        }
    }

    /// Answer a certificate challenge.
    func answer(_ request: UInt64, _ decision: TrustDecision) {
        guard let handler = outstanding.removeValue(forKey: request) else { return }
        let trust = trusted.removeValue(forKey: request)
        supplied.removeValue(forKey: request)

        switch decision {
        case .proceed:
            guard let trust else {
                handler(.cancelAuthenticationChallenge, nil)
                return
            }
            handler(.useCredential, URLCredential(trust: trust))
        case .refuse:
            // The navigation fails with -1202 a moment later, and the screen
            // ADR-0016 built explains it — now with the facts this challenge
            // measured on the way past.
            handler(.cancelAuthenticationChallenge, nil)
        }
    }

    /// Read by the tests, because "the handler was called" is only half the
    /// claim — the other half is that nothing is left holding a navigation open.
    var outstandingCount: Int { outstanding.count }
    /// Read by the tests to assert that nothing typed outlives the answer.
    var heldCredentialCount: Int { supplied.count }
}

/// What the engine's authentication-method strings mean.
///
/// `NSURLAuthenticationMethod*` is an open set, and a new one must not silently
/// become "ask for a password". Anything unrecognised is
/// `HttpAuthScheme.other`, which the core refuses rather than guesses at.
enum AuthMethod {
    static func scheme(_ method: String) -> HttpAuthScheme {
        switch method {
        case NSURLAuthenticationMethodHTTPBasic: .basic
        case NSURLAuthenticationMethodHTTPDigest: .digest
        case NSURLAuthenticationMethodNTLM: .ntlm
        case NSURLAuthenticationMethodNegotiate: .negotiate
        default: .other
        }
    }
}

/// Reading a certificate chain into the measurements the core decides on.
///
/// **Measurements, never judgements** — the `passwords.rs` rule, and here it is
/// load-bearing for the same reason: whether "expired" and "signed by nobody"
/// are one fault or two is a decision, it belongs in the core where it can be
/// tested without a network, and a `notSecure: Bool` computed here would make
/// that untestable and let the two platforms disagree.
///
/// Everything below is public API. This was measured rather than assumed: the
/// undocumented `TrustResultDetails` keys that `SecTrustCopyResult` returns
/// (`AnchorTrusted`, `SSLHostname`, `TemporalValidity`) do separate the cases,
/// and they are not in any header. ADR-0067 spends this project's one
/// reached-by-name SPI on the Web Inspector; this does not spend a second.
enum CertificateFacts {
    static func measure(_ trust: SecTrust, host: String) -> ReportedCertificate {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first
        else {
            return unreadable()
        }

        let window = validity(of: leaf)
        return ReportedCertificate(
            fingerprint: fingerprint(of: leaf),
            subject: SecCertificateCopySubjectSummary(leaf) as String? ?? "",
            issuer: issuerName(of: chain),
            covers: names(in: leaf),
            notBeforeMs: window.before,
            notAfterMs: window.after,
            // A leaf whose issuer is its own subject. The one fact that tells a
            // development certificate apart from a company's private CA, which
            // reaches no anchor either and did not sign itself.
            selfSigned: isSelfSigned(leaf),
            reachesTrustedAnchor: reachesAnchor(chain, within: window),
            hostMatches: nameMatches(chain, host: host, within: window),
            chainLength: UInt32(chain.count)
        )
    }

    /// What we report when the chain cannot be read at all. Every field says
    /// "we could not tell" rather than "it is fine".
    private static func unreadable() -> ReportedCertificate {
        ReportedCertificate(
            fingerprint: "",
            subject: "",
            issuer: "",
            covers: [],
            notBeforeMs: nil,
            notAfterMs: nil,
            selfSigned: false,
            reachesTrustedAnchor: false,
            hostMatches: false,
            chainLength: 0
        )
    }

    /// SHA-256 of the leaf's DER, lowercase hex. What an exception is pinned
    /// to, so an exception covers the certificate somebody looked at and not
    /// the next one to arrive from that host.
    private static func fingerprint(of certificate: SecCertificate) -> String {
        let der = SecCertificateCopyData(certificate) as Data
        return SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    private static func issuerName(of chain: [SecCertificate]) -> String {
        // The next certificate up, when there is one. For a self-signed leaf
        // there is nobody above it and the leaf's own summary would read as an
        // issuer that vouched for it.
        guard chain.count > 1 else { return "" }
        return SecCertificateCopySubjectSummary(chain[1]) as String? ?? ""
    }

    private static func validity(
        of certificate: SecCertificate
    ) -> (before: UInt64?, after: UInt64?) {
        let oids = [kSecOIDX509V1ValidityNotBefore, kSecOIDX509V1ValidityNotAfter] as CFArray
        guard let values = SecCertificateCopyValues(certificate, oids, nil) as? [String: Any] else {
            return (nil, nil)
        }
        return (
            epochMs(values[kSecOIDX509V1ValidityNotBefore as String]),
            epochMs(values[kSecOIDX509V1ValidityNotAfter as String])
        )
    }

    /// The value is a `CFAbsoluteTime` — seconds since 2001 — which is a
    /// different epoch from the one the core counts in. Measured: an entry read
    /// back `599529600`, which is 2020-01-01 in that epoch and nonsense in any
    /// other.
    private static func epochMs(_ entry: Any?) -> UInt64? {
        guard let entry = entry as? [String: Any],
              let seconds = (entry["value"] as? NSNumber)?.doubleValue
        else { return nil }
        let interval = Date(timeIntervalSinceReferenceDate: seconds).timeIntervalSince1970
        guard interval > 0 else { return nil }
        return UInt64(interval * 1000)
    }

    /// The names the certificate says it covers, as it spells them.
    ///
    /// Reported rather than matched here: whether one of them covers the host
    /// is answered by the platform's own SSL policy in `nameMatches`, which is
    /// the only thing that implements the wildcard rules correctly.
    private static func names(in certificate: SecCertificate) -> [String] {
        guard let values = SecCertificateCopyValues(
            certificate, [kSecOIDSubjectAltName] as CFArray, nil
        ) as? [String: Any],
            let entry = values[kSecOIDSubjectAltName as String] as? [String: Any],
            let rows = entry["value"] as? [[String: Any]]
        else {
            // No SAN. The common name is what an old certificate used, and it
            // is better than saying the certificate covers nothing.
            return (SecCertificateCopySubjectSummary(certificate) as String?).map { [$0] } ?? []
        }
        return rows.compactMap { row in
            // `label` is "DNS Name" or "IP Address"; the value is the name.
            // Anything else in there is a shape nobody types into an address
            // bar, so it is left out rather than drawn as a name.
            guard let label = row["label"] as? String,
                  label == "DNS Name" || label == "IP Address",
                  let value = row["value"] as? String
            else { return nil }
            return value
        }
    }

    private static func isSelfSigned(_ certificate: SecCertificate) -> Bool {
        guard let subject = SecCertificateCopyNormalizedSubjectSequence(certificate) as Data?,
              let issuer = SecCertificateCopyNormalizedIssuerSequence(certificate) as Data?
        else { return false }
        return subject == issuer
    }

    /// Whether the chain reaches a root this machine trusts, **with the dates
    /// taken out of the question**.
    ///
    /// The verify date is pinned to the middle of the leaf's own window on
    /// purpose. Without it an expired certificate fails this check too, and the
    /// screen would tell somebody their certificate is both expired and signed
    /// by a stranger when only the first is true — which is the collapse this
    /// whole file exists to undo.
    private static func reachesAnchor(
        _ chain: [SecCertificate],
        within window: (before: UInt64?, after: UInt64?)
    ) -> Bool {
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(
            chain as CFArray, SecPolicyCreateBasicX509(), &trust
        ) == errSecSuccess, let trust else { return false }
        pin(trust, within: window)
        return SecTrustEvaluateWithError(trust, nil)
    }

    /// Whether the platform accepts this chain for this name, with the anchor
    /// and the dates taken out of the question.
    ///
    /// The chain's own root is installed as the only anchor, so a self-signed
    /// certificate for the right name answers `true` here and a correctly
    /// issued certificate for the wrong name answers `false`. That separation
    /// is the point: measured, a self-signed `localhost` reports a name match
    /// and no anchor, while one for `not-the-host.example` reports neither.
    private static func nameMatches(
        _ chain: [SecCertificate],
        host: String,
        within window: (before: UInt64?, after: UInt64?)
    ) -> Bool {
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(
            chain as CFArray, SecPolicyCreateSSL(true, host as CFString), &trust
        ) == errSecSuccess, let trust, let root = chain.last else { return false }
        SecTrustSetAnchorCertificates(trust, [root] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        pin(trust, within: window)
        return SecTrustEvaluateWithError(trust, nil)
    }

    private static func pin(_ trust: SecTrust, within window: (before: UInt64?, after: UInt64?)) {
        guard let before = window.before, let after = window.after, after > before else { return }
        let middle = Double(before / 2 + after / 2) / 1000
        SecTrustSetVerifyDate(trust, Date(timeIntervalSince1970: middle) as CFDate)
    }
}

/// The panel's question, wrapped so SwiftUI can present it as a sheet.
///
/// `Identifiable` on the request number, so a second challenge replaces the
/// panel rather than SwiftUI reusing the first one's text.
struct PendingAuth: Identifiable {
    let prompt: AuthPrompt
    var id: UInt64 { prompt.request }
}

extension HostedWebView {
    /// A server asking who you are, or a certificate that did not check out.
    ///
    /// Both arrive here, and this method does nothing but tell them apart and
    /// report. Every decision — whether to ask, what the panel says, whether a
    /// certificate may be waved through — is in the core, where it can be
    /// tested without a server and where the Linux host inherits it.
    ///
    /// The completion handler goes into the ledger *first*, before anything can
    /// return early. There is no path out of this method that does not leave
    /// the engine an answer to receive, because the one that did would be a tab
    /// that never loads and never fails.
    func webView(
        _: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @MainActor (
            URLSession.AuthChallengeDisposition, URLCredential?
        ) -> Void
    ) {
        let space = challenge.protectionSpace
        let request = authChallenges.hold(completionHandler)

        if space.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            guard let trust = space.serverTrust else {
                // A trust challenge with no trust object is not one we can
                // measure or pin an exception to. Refuse; the screen says the
                // certificate could not be checked.
                authChallenges.answer(request, TrustDecision.refuse)
                return
            }
            authChallenges.hold(trust: trust, for: request)

            // **The gate, and the reason it is here rather than in the core.**
            //
            // WebKit delivers a server-trust challenge on **every** TLS
            // connection once this method exists, not only on the ones it would
            // have refused — measured, and the measurement cost this browser
            // every https page it had. Without this line `example.com` was
            // reported as a rejected certificate, refused for want of an
            // exception nobody could have made, and failed as
            // `NSURLErrorCancelled`, which ADR-0016 deliberately draws no screen
            // for: a tab that opened, said "New Tab", and stayed white.
            //
            // Whether this machine accepts a chain is a **measurement**, in the
            // same sense every field of `ReportedCertificate` is one, and the
            // only thing holding the answer is the platform's trust store. What
            // to do about a chain it does *not* accept is untouched and is
            // entirely the core's (ADR-0094) — this decides nothing except
            // which challenges are worth asking about.
            //
            // Asking the platform rather than deriving the answer from the
            // facts below is the fail-closed direction, and deliberate: those
            // are measured with the dates pinned and the anchors substituted so
            // that each fault can be named on its own, so a chain that looks
            // clean by all three of them can still be revoked, weakly signed,
            // or short of this OS's certificate-transparency requirement.
            if SecTrustEvaluateWithError(trust, nil) {
                authChallenges.answer(request, TrustDecision.proceed)
                return
            }

            emitAction(.serverTrustRejected(request: ServerTrustRequest(
                request: request,
                tab: tab,
                host: space.host,
                port: UInt32(max(0, space.port)),
                certificate: CertificateFacts.measure(trust, host: space.host)
            )))
            return
        }

        emitAction(.httpAuthRequested(request: HttpAuthRequest(
            request: request,
            tab: tab,
            scheme: AuthMethod.scheme(space.authenticationMethod),
            // Three fields, uninterpreted. Whether `https://x` and
            // `https://x:443` are one origin is decided once, in the core.
            origin: ReportedOrigin(
                scheme: space.protocol ?? "",
                host: space.host,
                port: UInt32(max(0, space.port))
            ),
            // Straight off the wire, and carried as the server's own text.
            realm: space.realm,
            previousFailures: UInt32(max(0, challenge.previousFailureCount)),
            isProxy: space.isProxy(),
            // The core has no clock (ADR-0002).
            askedAtMs: UInt64(Date().timeIntervalSince1970 * 1000)
        )))
    }
}
