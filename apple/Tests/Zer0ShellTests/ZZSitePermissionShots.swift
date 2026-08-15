import AppKit
import SwiftUI
import Testing
import Zer0Core

@testable import Zer0Shell

/// Looking at the one screen in this browser a hostile page gets to summon.
///
/// Whether it is *correct* is `SitePermissionTests`. Whether it is worth
/// reading in the second and a half somebody gives it is not a thing an
/// assertion can answer, and this is the only way to answer it on a machine
/// with no screen.
///
/// Opt-in. See `ZZShotHarness.swift`.
@MainActor
struct ZZSitePermissionShots {
    /// A prompt built the way the core builds one, so the words on the picture
    /// are the real words rather than a second copy written here.
    private func prompt(
        host: String = "meet.example",
        pageHost: String? = nil,
        capture: CaptureRequest = .cameraAndMicrophone
    ) -> SitePermissionPrompt {
        let model = BrowserModel(storagePath: nil)
        let tab = model.snapshot.activeTab!
        let origin = ReportedOrigin(scheme: "https", host: host, port: 0)
        model.send(.sitePermissionRequested(request: SitePermissionRequest(
            request: 1,
            tab: tab,
            origin: origin,
            pageOrigin: pageHost.map { ReportedOrigin(scheme: "https", host: $0, port: 0) }
                ?? origin,
            capture: capture,
            askedAtMs: 0
        )))
        return model.pendingSitePermission!.prompt
    }

    /// The sheet over something, so a translucent material has something to be
    /// translucent about. A flat colour behind it would make any material look
    /// like a flat colour.
    private func scene(_ prompt: SitePermissionPrompt, dark: Bool) -> some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.10, green: 0.34, blue: 0.62),
                    Color(red: 0.86, green: 0.36, blue: 0.20),
                    Color(red: 0.97, green: 0.95, blue: 0.90),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Color.black.opacity(0.25)
            SitePermissionSheet(
                prompt: prompt,
                onAllow: {},
                onBlock: {},
                onDismiss: {}
            )
            // The window root applies this once, and the accent it sets is what
            // makes the committing button read as the committing button. A
            // harness that left it off would be judging a control the app never
            // draws.
            .zer0Palette()
            .clipShape(RoundedRectangle(cornerRadius: Design.Radius.large))
        }
        .frame(width: 720, height: 520)
        .preferredColorScheme(dark ? .dark : .light)
    }

    @Test(
        "the sheet, in both halves and in all three shapes",
        .disabled(if: ProcessInfo.processInfo.environment["ZER0_SHOT"] == nil)
    )
    func theSheet() async throws {
        for dark in [false, true] {
            let half = dark ? "dark" : "light"

            for (name, capture) in [
                ("camera", CaptureRequest.camera),
                ("microphone", CaptureRequest.microphone),
                ("both", CaptureRequest.cameraAndMicrophone),
            ] {
                let shot = Shot(size: CGSize(width: 720, height: 520)) {
                    scene(prompt(capture: capture), dark: dark)
                }
                shot.advance(1.0)
                print(shot.write("site-permission-\(name)-\(half)"))
            }

            // The one that carries the extra block, and the one worth looking
            // at hardest: the warning must read as a warning without turning
            // the whole sheet into one.
            let embedded = Shot(size: CGSize(width: 720, height: 520)) {
                scene(prompt(host: "ads.example", pageHost: "news.example"), dark: dark)
            }
            embedded.advance(1.0)
            print(embedded.write("site-permission-embedded-\(half)"))
        }
    }
}
