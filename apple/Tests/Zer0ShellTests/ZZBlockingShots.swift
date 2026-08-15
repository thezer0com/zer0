import AppKit
import SwiftUI
import Testing
import Zer0Core

@testable import Zer0Shell

/// Renders the Privacy pane, light and dark, in the three states worth looking
/// at: nothing excepted, a few sites excepted, and a compile that failed.
///
/// A judgement about whether a pane is readable — whether the honesty paragraph
/// is a useful sentence or a wall — cannot be made from source, and this pane
/// grew a long one. So it is looked at.
///
/// **Opt-in.** `ZER0_SHOT=1 swift test --filter ZZBlocking`. A harness pumps the
/// run loop and starves the timing tests when it runs by default, so
/// `scripts/check.sh` verifies every case here carries the gate.
///
/// `NSHostingView` + `cacheDisplay` rather than `ImageRenderer`, which does not
/// draw materials.
@Suite("ZZ blocking shots")
struct ZZBlockingShots {
    /// Four levels up is the repo root: `apple/Tests/Zer0ShellTests/<this>`.
    private static let output = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "design/blocking")

    @Test(
        "render the privacy pane",
        .disabled(if: ProcessInfo.processInfo.environment["ZER0_SHOT"] == nil)
    )
    @MainActor
    func renderThePrivacyPane() async throws {
        try FileManager.default.createDirectory(
            at: Self.output, withIntermediateDirectories: true
        )

        let pane = CGSize(width: 760, height: 900)

        let clean = BrowserModel(storagePath: nil)

        let excepted = BrowserModel(storagePath: nil)
        for host in ["github.com", "figma.com", "my-bank.example.co.uk"] {
            excepted.setBlocking(host: host, blocking: false)
        }

        for (name, model) in [("clean", clean), ("excepted", excepted)] {
            for dark in [false, true] {
                try shoot("privacy-\(name)", size: pane, dark: dark) {
                    ScrollView {
                        PrivacySettings()
                            .environment(model)
                            .padding(Design.Space.loose)
                    }
                }
            }
        }
    }

    /// Draw a view offscreen and write it out.
    ///
    /// `controlActiveState: .key` is forced because the test process can never
    /// become the active app, and without it the switch renders grey — which on
    /// this board is one of the pixels you came to look at.
    @MainActor
    private func shoot(
        _ name: String,
        size: CGSize,
        dark: Bool,
        @ViewBuilder content: () -> some View
    ) throws {
        let root = content()
            .environment(\.controlActiveState, .key)
            .zer0Palette()
            .frame(width: size.width, height: size.height)
            .preferredColorScheme(dark ? .dark : .light)

        let host = NSHostingView(rootView: AnyView(root))
        host.frame = CGRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)

        let window = testWindow(host.frame, styleMask: [.borderless])
        window.appearance = host.appearance
        window.contentView = host
        window.displayIfNeeded()

        // Blocking compiles asynchronously and the row's description is drawn
        // from that state, so a frame taken too early photographs the pane
        // mid-answer. A material and a hosting view also settle late.
        for _ in 0 ..< 30 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            Issue.record("no bitmap rep for \(name)")
            return
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            Issue.record("no png for \(name)")
            return
        }
        try png.write(to: Self.output.appending(path: "\(name)-\(dark ? "dark" : "light").png"))
    }
}
