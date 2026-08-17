import AppKit
import SwiftUI
import Zer0Core
import Testing

@testable import Zer0Shell

/// Looking at the two screens an install actually puts in front of somebody:
/// the consent sheet, and the banner that is the fallback when the button in
/// the store's page did not happen.
///
/// Whether they are *correct* is `StoreInstallTests` and
/// `ExtensionConsentTests`. Whether the sheet can name what is asking, and
/// whether two permissions read as two different things, are questions only a
/// rendered frame answers — the placeholder name and the duplicated sentence
/// were both found by looking, and neither was catchable by an assertion.
///
/// Opt-in. See `ZZShotHarness.swift`.
@MainActor
struct ZZExtensionOfferShots {
    /// A request built the way the core builds one, so the words on the picture
    /// are the real words rather than a second copy written here — including a
    /// manifest that declares both storage permissions, which is what drew the
    /// same sentence twice.
    private func request(name: String) -> ConsentRequest {
        let core = Zer0.inMemory(
            firstSpaceName: "Personal",
            dataStoreId: UUID().uuidString,
            capabilities: HostCapabilities(extensionRuntime: false, pagePrinting: false)
        )
        return core.extensionConsentRequest(extension: InstalledExtension(
            id: String(repeating: "a", count: 32),
            path: "/nowhere",
            manifest: ExtensionManifest(
                name: name,
                version: "8.12.30",
                description: nil,
                manifestVersion: 3,
                permissions: [
                    "storage", "unlimitedStorage", "cookies", "contextMenus", "menus", "scripting",
                    // Five off 1Password's own manifest, and the reason they are
                    // here is that between them they carry every state a row can
                    // be in (ADR-0084, ADR-0103). `webRequestAuthProvider` and
                    // `downloads` are provided and keep a switch — the first by
                    // the engine, the second by zer0 itself. `offscreen` and
                    // `notifications` are work nobody has done. `management` and
                    // `privacy` are refused. The four are only telling apart
                    // side by side, which is what this picture is for.
                    "offscreen", "notifications", "webRequestAuthProvider",
                    "downloads", "management", "privacy",
                ],
                hostPermissions: ["<all_urls>"],
                hasAction: true,
                // The consent sheet is drawn before anything is on disk, so
                // there is nothing modified to declare here (ADR-0100).
                compat: nil
            )
        ))
    }

    /// Over something, so a translucent material has something to be
    /// translucent about.
    private func scene(dark: Bool, @ViewBuilder content: () -> some View) -> some View {
        ZStack {
            LinearGradient(
                colors: dark
                    ? [Color(white: 0.16), Color(white: 0.09)]
                    : [Color(white: 0.97), Color(white: 0.88)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            content()
        }
        .preferredColorScheme(dark ? .dark : .light)
    }

    @Test(
        "the consent sheet names what is asking",
        .disabled(if: ProcessInfo.processInfo.environment["ZER0_SHOT"] == nil)
    )
    func theSheetNamesWhatIsAsking() {
        for dark in [false, true] {
            let shot = Shot(size: CGSize(width: 560, height: 700)) {
                scene(dark: dark) {
                    // The real string out of the real package, not a key.
                    ExtensionConsentSheet(
                        request: request(name: "1Password \u{2013} Password Manager"),
                        onAdd: { _ in },
                        onCancel: {}
                    )
                }
            }
            shot.write("consent-sheet-\(dark ? "dark" : "light")")
        }
    }

    @Test(
        "no two rows say the same thing",
        .disabled(if: ProcessInfo.processInfo.environment["ZER0_SHOT"] == nil)
    )
    func noTwoRowsSayTheSameThing() {
        // The whole list rather than the sheet, because the pair that read
        // identically — `storage` and `unlimitedStorage` — are Housekeeping and
        // sit below the fold of a 700pt sheet, which is how they survived.
        for dark in [false, true] {
            let shot = Shot(size: CGSize(width: 520, height: 1240)) {
                scene(dark: dark) {
                    ExtensionConsentSheet(
                        request: request(name: "1Password \u{2013} Password Manager"),
                        onAdd: { _ in },
                        onCancel: {}
                    )
                    .permissionList
                    .frame(width: 480)
                    .background(.regularMaterial)
                }
            }
            shot.write("consent-rows\(dark ? "-dark" : "")")
        }
    }

    /// The Extensions screen, with whatever is unpacked on this machine.
    ///
    /// Both halves of ADR-0084 are only visible here: the sentence one row
    /// prints when its background died, and the block underneath where the
    /// permissions this browser cannot provide say so instead of offering a
    /// switch. Copied into a profile of its own, so nothing here can touch a
    /// running browser's state — the same arrangement as `ZZExtensionBarShots`.
    @Test(
        "what a row says, and what its permissions offer",
        .disabled(if: ProcessInfo.processInfo.environment["ZER0_SHOT"] == nil)
    )
    func theRowAndWhatItHolds() async throws {
        let installedElsewhere = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/zer0/extensions")
        let packages = (try? FileManager.default.contentsOfDirectory(
            at: installedElsewhere,
            includingPropertiesForKeys: nil
        ))?.filter { !$0.lastPathComponent.hasPrefix(".") } ?? []
        guard !packages.isEmpty else {
            Issue.record("no extensions unpacked on this machine — nothing real to render")
            return
        }

        let profile = FileManager.default.temporaryDirectory
            .appending(path: "zer0-extrow-\(UUID().uuidString)")
        let extensions = profile.appending(path: "extensions")
        try FileManager.default.createDirectory(at: extensions, withIntermediateDirectories: true)
        for package in packages {
            try? FileManager.default.copyItem(
                at: package,
                to: extensions.appending(path: package.lastPathComponent)
            )
        }

        let model = BrowserModel(storagePath: profile.appending(path: "session.sqlite").path)
        model.loadInstalledExtensions()
        for installed in model.installedExtensions {
            let request = model.consentRequest(for: installed)
            await model.applyConsent(defaultConsentDecision(request: request, decidedAtMs: 1_000))
        }

        // WebKit fills its error list some time after `load` returns, so a
        // picture taken at once photographs an extension as running seconds
        // before it is reported dead — which is the exact state ADR-0072 exists
        // for and the one this is here to look at. Waited for rather than slept
        // on; if no package on this machine has a broken worker it costs the
        // deadline and the picture is still of a true state.
        _ = await eventually(timeout: .seconds(10)) {
            model.installedExtensions.contains {
                model.extensions?.backgroundContentFailed($0.id) == true
            }
        }

        // Printed so the record says which package produced the picture and what
        // the core thinks of it, rather than leaving both to be assumed.
        for ext in model.installedExtensions {
            let status = ExtensionStatus.of(
                standing: model.standing(of: ext.id),
                backgroundFailed: model.extensions?.backgroundContentFailed(ext.id) == true
            )
            let request = model.consentRequest(for: ext)
            print("""
                [zer0] \(ext.id)
                  name:     \(ext.manifest.name)
                  standing: \(model.standing(of: ext.id))
                  summary:  \(status.summary)
                  not yet:  \(request.requests.filter { if case .notBuiltYet = $0.notProvided { true } else { false } }.map(\.key))
                  refused:  \(request.requests.filter { if case .declined = $0.notProvided { true } else { false } }.map(\.key))
                """)
        }

        for dark in [false, true] {
            let shot = Shot(size: CGSize(width: 720, height: 900)) {
                scene(dark: dark) {
                    ScrollView {
                        // Every row opened, because the permissions block is
                        // half of what this picture is for.
                        ExtensionsView(
                            expanding: Set(model.installedExtensions.map(\.id))
                        )
                        .padding(Design.Space.loose)
                    }
                    .environment(model)
                    .environment(\.controlActiveState, .key)
                    .zer0Palette()
                }
            }
            shot.write("extension-row-\(dark ? "dark" : "light")")
        }
    }

    @Test(
        "the banner says what this browser holds",
        .disabled(if: ProcessInfo.processInfo.environment["ZER0_SHOT"] == nil)
    )
    func theBannerSaysWhatThisBrowserHolds() {
        let model = BrowserModel(storagePath: nil)
        let shot = Shot(size: CGSize(width: 560, height: 120)) {
            scene(dark: false) {
                InstallBanner(
                    extensionId: String(repeating: "a", count: 32),
                    pageCarriesTheOffer: false
                )
                .environment(model)
            }
        }
        shot.write("install-banner-offer")
    }
}
