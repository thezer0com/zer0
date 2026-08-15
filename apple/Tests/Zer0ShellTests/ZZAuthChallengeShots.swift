import AppKit
import SwiftUI
import Testing
import Zer0Core

@testable import Zer0Shell

/// Looking at the two screens a server can put in front of somebody, and at the
/// one thing that matters most about them: **they must not look alike.**
///
/// Being asked for a password is routine and gets a panel. Being told a site
/// cannot be shown to be itself is a security decision and gets the whole area
/// (ADR-0016, ADR-0093). If those two read as the same kind of event, the
/// second one gets dismissed the way the first one does, which is the entire
/// failure mode this design exists to avoid — and it is not a thing any
/// assertion can answer.
///
/// Opt-in. See `ZZShotHarness.swift`.
@MainActor
struct ZZAuthChallengeShots {
    /// The window size the author works at.
    private static let window = CGSize(width: 1280, height: 800)

    /// A prompt built the way the core builds one, so the words on the picture
    /// are the real words rather than a second copy written here.
    private func prompt(
        host: String = "staging.example",
        scheme: String = "https",
        realm: String? = "Staging",
        failures: UInt32 = 0,
        proxy: Bool = false
    ) -> AuthPrompt {
        let model = BrowserModel(storagePath: nil)
        let tab = model.snapshot.activeTab!
        model.send(.httpAuthRequested(request: HttpAuthRequest(
            request: 1,
            tab: tab,
            scheme: .basic,
            origin: ReportedOrigin(scheme: scheme, host: host, port: 0),
            realm: realm,
            previousFailures: failures,
            isProxy: proxy,
            askedAtMs: 0
        )))
        return model.pendingHttpAuth!.prompt
    }

    /// The panel over something, so a translucent material has something to be
    /// translucent about.
    private func scene(_ prompt: AuthPrompt, dark: Bool) -> some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.10, green: 0.34, blue: 0.62),
                    Color(red: 0.20, green: 0.20, blue: 0.36),
                    Color(red: 0.94, green: 0.93, blue: 0.90),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Color.black.opacity(0.25)
            AuthChallengeSheet(prompt: prompt, onSignIn: { _, _, _ in }, onCancel: {})
                .zer0Palette()
                .clipShape(RoundedRectangle(cornerRadius: Design.Radius.large))
        }
        .frame(width: Self.window.width, height: Self.window.height)
        .preferredColorScheme(dark ? .dark : .light)
    }

    @Test(
        "the sign-in panel, in both halves and in the shapes that carry a warning",
        .disabled(if: ProcessInfo.processInfo.environment["ZER0_SHOT"] == nil)
    )
    func thePanel() async throws {
        for dark in [false, true] {
            let half = dark ? "dark" : "light"

            for (name, made) in [
                ("plain", prompt()),
                // The realm as a real server sends one, markup and all. What is
                // being looked at is whether it reads as somebody else's text.
                ("realm", prompt(realm: "Staging <b>internal</b> — do not share")),
                // Unencrypted, off loopback: the warning block, and no offer to
                // remember.
                ("insecure", prompt(host: "router.example", scheme: "http")),
                // Loopback: no warning at all, and the offer is back.
                ("loopback", prompt(host: "localhost", scheme: "http")),
                ("retry", prompt(failures: 1)),
                ("proxy", prompt(host: "proxy.corp", proxy: true)),
            ] {
                let shot = Shot(size: Self.window) { scene(made, dark: dark) }
                shot.advance(1.0)
                print(shot.write("auth-panel-\(name)-\(half)"))
            }
        }
    }

    // MARK: - The certificate screen

    private func report(
        host: String,
        hostMatches: Bool = true,
        selfSigned: Bool = true,
        expired: Bool = false
    ) -> CertificateReport {
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        let day: UInt64 = 86_400_000
        return certificateReport(
            host: host,
            port: 0,
            certificate: ReportedCertificate(
                fingerprint: String(repeating: "a1b2", count: 16),
                subject: hostMatches ? host : "not-the-host.example",
                issuer: selfSigned ? "" : "Acme Internal CA",
                covers: hostMatches ? [host] : ["not-the-host.example"],
                notBeforeMs: expired ? 1_577_836_800_000 : now - day,
                notAfterMs: expired ? 1_577_923_200_000 : now + 300 * day,
                selfSigned: selfSigned,
                reachesTrustedAnchor: false,
                hostMatches: hostMatches,
                chainLength: selfSigned ? 1 : 2
            ),
            nowMs: now
        )
    }

    private func failure(_ url: String) -> NavigationError {
        NavigationError(
            kind: .certificateInvalid,
            url: url,
            message: "The certificate for this server is invalid."
        )
    }

    @Test(
        "the certificate screen, with and without a way through",
        .disabled(if: ProcessInfo.processInfo.environment["ZER0_SHOT"] == nil)
    )
    func theCertificateScreen() async throws {
        for dark in [false, true] {
            let half = dark ? "dark" : "light"

            let cases: [(String, String, CertificateReport)] = [
                // Loopback: the one place a way through is offered, and the
                // place to check it is quiet enough not to be the obvious
                // thing to press.
                ("loopback", "https://localhost:8443/", report(host: "localhost")),
                // A public host, self-signed. No button at all, and a sentence
                // saying that is a decision rather than a missing feature.
                ("public", "https://bank.example/", report(host: "bank.example")),
                // The name is wrong: the fault a stranger produces on purpose.
                (
                    "wrong-name", "https://bank.example/",
                    report(host: "bank.example", hostMatches: false)
                ),
                // Two faults at once. What is being looked at is whether the
                // second one is visible without competing with the first.
                (
                    "expired-and-wrong", "https://bank.example/",
                    report(host: "bank.example", hostMatches: false, expired: true)
                ),
                // A private CA, which must not read as "self-signed".
                (
                    "private-ca", "https://staging.corp/",
                    report(host: "staging.corp", selfSigned: false)
                ),
            ]

            for (name, url, made) in cases {
                let shot = Shot(size: Self.window) {
                    NavigationErrorScreen(
                        error: failure(url),
                        certificate: made,
                        onTrust: { _, _ in },
                        retry: {}
                    )
                    .zer0Palette()
                    .frame(width: Self.window.width, height: Self.window.height)
                    .preferredColorScheme(dark ? .dark : .light)
                }
                shot.advance(1.0)
                print(shot.write("auth-cert-\(name)-\(half)"))
            }

            // And the screen as it was before any of this, for the comparison
            // that is the whole argument: one sentence listing what it might
            // be, against a sentence naming what is wrong.
            let before = Shot(size: Self.window) {
                NavigationErrorScreen(error: failure("https://bank.example/"), retry: {})
                    .zer0Palette()
                    .frame(width: Self.window.width, height: Self.window.height)
                    .preferredColorScheme(dark ? .dark : .light)
            }
            before.advance(1.0)
            print(before.write("auth-cert-before-\(half)"))
        }
    }
}
