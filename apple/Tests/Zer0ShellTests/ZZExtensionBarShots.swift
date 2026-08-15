import AppKit
import SwiftUI
import Testing
import WebKit
import Zer0Core

@testable import Zer0Shell

/// Looking at the row of extension buttons, with a **real extension's real
/// icon** in it.
///
/// This one had to be a harness rather than an assertion, and for a reason
/// stronger than usual. Every other question about the row — what is on it, in
/// what order, whether a missing icon takes it down — is answered by
/// `ExtensionPinTests` without a window. The question this cannot answer is the
/// one ADR-0068 actually rests on: *does a row of somebody else's artwork look
/// like it belongs to this browser*. A stranger's icon at a scale they chose is
/// the easiest thing in a browser to end up looking pasted on, and no assertion
/// can see that.
///
/// It loads whatever is unpacked in the profile on this machine, read-only, and
/// skips when there is nothing there — so it is a real package on a machine that
/// has one and silence on a machine that does not, rather than a fixture
/// pretending to be one.
///
/// Opt-in. See `ZZShotHarness.swift`.
///
///     ZER0_SHOT=1 swift test --filter ZZExtensionBarShots
@MainActor
struct ZZExtensionBarShots {
    /// Where this machine's own extensions are unpacked.
    ///
    /// Read, never written. The point of pointing at it is that the icon in the
    /// picture came out of a package somebody actually installed.
    private var installedElsewhere: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/zer0/extensions")
    }

    /// A model with the real packages copied into a profile of its own.
    ///
    /// Copied rather than opened in place, and the session file is its own, so
    /// nothing here can touch a running browser's state.
    private func modelWithRealExtensions() async throws -> (BrowserModel, [InstalledExtension])? {
        let packages = (try? FileManager.default.contentsOfDirectory(
            at: installedElsewhere,
            includingPropertiesForKeys: nil
        ))?.filter { !$0.lastPathComponent.hasPrefix(".") } ?? []
        guard !packages.isEmpty else { return nil }

        let profile = FileManager.default.temporaryDirectory
            .appending(path: "zer0-extbar-\(UUID().uuidString)")
        let extensions = profile.appending(path: "extensions")
        try FileManager.default.createDirectory(at: extensions, withIntermediateDirectories: true)
        for package in packages {
            try? FileManager.default.copyItem(
                at: package,
                to: extensions.appending(path: package.lastPathComponent)
            )
        }

        let model = BrowserModel(
            storagePath: profile.appending(path: "session.sqlite").path
        )
        model.loadInstalledExtensions()

        // Granted what each asked for, because nothing gets a button until it
        // is running (ADR-0028, ADR-0068).
        for installed in model.installedExtensions {
            let request = model.consentRequest(for: installed)
            await model.applyConsent(defaultConsentDecision(request: request, decidedAtMs: 1_000))
        }
        return (model, model.installedExtensions)
    }

    /// The row on the sidebar's own surface, over a page, in both themes.
    ///
    /// Drawn with the space bar under it, because the whole placement argument
    /// is that these two rows read as one band of furniture at the bottom of the
    /// panel. Seen on its own it proves nothing about that.
    @Test(
        "the extension row, with a real package's icon",
        .disabled(if: ProcessInfo.processInfo.environment["ZER0_SHOT"] == nil)
    )
    func theRowWithARealIcon() async throws {
        guard let (model, installed) = try await modelWithRealExtensions() else {
            Issue.record("no extensions unpacked on this machine — nothing real to render")
            return
        }

        // What the pictures are actually of, printed so the record says which
        // package produced them rather than leaving it to be assumed.
        for ext in installed {
            let action = model.extensions?.action(for: ext.id, tab: model.snapshot.activeTab)
            let icon = action?.icon(for: CGSize(width: 18, height: 18))
            print("""
                [zer0] \(ext.id)
                  name:       \(ext.manifest.name)
                  hasAction:  \(ext.manifest.hasAction)
                  onTheRow:   \(model.pinnedExtensions.contains { $0.id == ext.id })
                  action:     \(action == nil ? "nil" : "yes")
                  label:      \(action?.label ?? "—")
                  badge:      \(action?.badgeText ?? "—")
                  popup:      \(action?.presentsPopup ?? false)
                  icon:       \(icon.map { "\($0.size.width)×\($0.size.height)" } ?? "nil")
                """)
        }

        for dark in [false, true] {
            let shot = Shot(size: CGSize(width: 260, height: 200)) {
                ZStack {
                    // A gradient behind it, so a material has something to be
                    // translucent about and a flat fill cannot pass for one.
                    LinearGradient(
                        colors: dark
                            ? [.black, Color(red: 0.10, green: 0.11, blue: 0.18)]
                            : [.white, Color(red: 0.93, green: 0.93, blue: 0.97)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    VStack {
                        Spacer()
                        ExtensionActionBar(ink: .primary, popoverEdge: .maxX)
                            .padding(.horizontal, Design.Space.snug)
                            .padding(.vertical, Design.Space.tight)
                    }
                    .chromeSurface()
                }
                .environment(model)
                .environment(\.colorScheme, dark ? .dark : .light)
                // An offscreen window never becomes key, so without this every
                // accent and every selected surface rasterises grey and judging
                // one measures nothing.
                .environment(\.controlActiveState, .key)
                .zer0Palette()
            }
            shot.write("extension-bar-\(dark ? "dark" : "light")")
        }
    }
}
