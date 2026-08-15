import AppKit
import SwiftUI
import Testing
import Zer0Core

@testable import Zer0Shell

/// Renders the screens B · Fault actually changed, light and dark, so the
/// adoption can be looked at rather than reasoned about.
///
/// **Opt-in.** `ZER0_SHOT=1 swift test --filter ZZ`. A harness pumps the run
/// loop for tens of seconds and starves the timing tests when it runs by
/// default, so `scripts/check.sh` verifies every case here carries the gate.
///
/// `NSHostingView` + `cacheDisplay` rather than `ImageRenderer`, because
/// `ImageRenderer` does not draw materials — which on the one board that is
/// about a material would be a picture of the wrong thing.
@Suite("ZZ palette adoption shots")
struct ZZPaletteAdoptionShots {
    /// Four levels up is the repo root: `apple/Tests/Zer0ShellTests/<this>`.
    private static let output = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "design/adopted")

    @Test(
        "render the adopted palette",
        .disabled(if: ProcessInfo.processInfo.environment["ZER0_SHOT"] == nil)
    )
    @MainActor
    func renderTheAdoptedPalette() throws {
        try FileManager.default.createDirectory(
            at: Self.output, withIntermediateDirectories: true
        )

        for dark in [false, true] {
            try shoot("01-about", size: CGSize(width: 420, height: 520), dark: dark) {
                AboutView()
            }
            try shoot("02-empty", size: CGSize(width: 620, height: 460), dark: dark) {
                EmptyState(
                    icon: "arrow.down.circle",
                    title: "Nothing downloaded yet",
                    message: "Files you save land in your Downloads folder, and stay listed "
                        + "here with a way back to them."
                ) {
                    Button {} label: { Label("Open Downloads Folder", systemImage: "folder") }
                        .buttonStyle(.bordered)
                }
            }
            try shoot("03-sidebar", size: CGSize(width: 300, height: 560), dark: dark) {
                SidebarSpecimen()
            }
            try shoot("04-rows", size: CGSize(width: 560, height: 420), dark: dark) {
                RowSpecimen()
            }
            try shoot("05-risk", size: CGSize(width: 520, height: 400), dark: dark) {
                RiskSpecimen()
            }
            try shoot("06-type", size: CGSize(width: 560, height: 520), dark: dark) {
                TypeSpecimen()
            }
            // The real screens, not specimens: a pane of settings and the
            // consent sheet, both built the way the app builds them.
            try shoot("07-settings", size: CGSize(width: 900, height: 600), dark: dark) {
                SettingsView().environment(BrowserModel(storagePath: nil))
            }
            try shoot("08-consent", size: CGSize(width: 520, height: 640), dark: dark) {
                ExtensionConsentSheet(
                    request: Self.consentSpecimen,
                    onAdd: { _ in },
                    onCancel: {}
                )
            }
        }
    }

    /// Draw a view offscreen and write it out.
    ///
    /// `controlActiveState: .key` is forced because the test process can never
    /// become the active app, and without it every accent-coloured prominent
    /// button renders grey — which on a board about an accent is exactly the
    /// pixel you came to look at.
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

        // A window, because a material without one has nothing to blend with
        // and because `.withinWindow` is the whole claim on board 03.
        let window = testWindow(host.frame, styleMask: [.borderless])
        window.appearance = host.appearance
        window.contentView = host
        window.displayIfNeeded()

        // Let the layout settle: a material and a hosting view both resolve a
        // frame later than the first pass.
        for _ in 0..<12 {
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
        let file = Self.output.appending(path: "\(name)-\(dark ? "dark" : "light").png")
        try png.write(to: file)
    }
}

// MARK: - Specimens

extension ZZPaletteAdoptionShots {
    /// One tier of each, so the risk ladder can be read top to bottom.
    static let consentSpecimen = ConsentRequest(
        extensionId: "aapbdbdomjkkjkaonfhkkikfgjllcleb",
        extensionName: "Page Translator",
        requests: [
            PermissionRequest(
                key: "<all_urls>", kind: .site, risk: .critical,
                title: "Read and change everything on every site you visit",
                detail: "Including anything you type into a page: passwords, card numbers, "
                    + "messages.",
                defaultGranted: false,
                notProvided: nil
            ),
            PermissionRequest(
                key: "management", kind: .api, risk: .high,
                title: "See, switch off and remove your other extensions",
                detail: "Which extensions you have, and whether they run.",
                defaultGranted: false,
                notProvided: .declined(
                    sentence: "zer0 will not provide this — one extension does not get to "
                        + "switch off another."
                )
            ),
            PermissionRequest(
                key: "history", kind: .api, risk: .high,
                title: "Read your browsing history",
                detail: "Every page you have visited, in every space that is not ephemeral.",
                defaultGranted: false,
                notProvided: .notBuiltYet(
                    sentence: "zer0 does not provide this yet — WebKit does not implement it."
                )
            ),
            PermissionRequest(
                key: "*://*.example.com/*", kind: .site, risk: .moderate,
                title: "Read and change pages on example.com",
                detail: "Only that site. Nothing else you have open is reachable.",
                defaultGranted: true,
                notProvided: nil
            ),
            PermissionRequest(
                key: "storage", kind: .api, risk: .low,
                title: "Store data on this device",
                detail: "Settings and cached translations, kept with the extension.",
                defaultGranted: true,
                notProvided: nil
            ),
        ],
        unreadableHosts: ["file://*/*"]
    )
}


/// The sidebar's surface with a selected row, a companion row and a plain one,
/// which is the whole of what `.selection` used to decide for us.
private struct SidebarSpecimen: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Favorites")
                .sectionHeading()
                .foregroundStyle(.secondary)
                .padding(.horizontal, Design.Space.snug)
                .padding(.bottom, Design.Space.tight)

            row("avelino/zer0", state: .plain)
            row("Inbox (3)", state: .selected)
            row("Linear", state: .companion)
            row("Hacker News", state: .plain)

            Text("Today")
                .sectionHeading()
                .foregroundStyle(.secondary)
                .padding(.horizontal, Design.Space.snug)
                .padding(.top, Design.Space.regular)
                .padding(.bottom, Design.Space.tight)

            row("zer0 — palette exploration", state: .plain)
            row("Color | Apple Design", state: .plain)

            Spacer()

            HStack(spacing: Design.Space.tight) {
                chip("Personal", active: true)
                chip("Work", active: false)
                chip("Throwaway", active: false)
            }
            .padding(Design.Space.snug)
        }
        .padding(.top, Design.Space.loose)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .chromeSurface()
    }

    private enum RowState { case plain, selected, companion }

    private func row(_ title: String, state: RowState) -> some View {
        Text(title)
            .font(Design.Text.rowTitle)
            .foregroundStyle(state == .plain ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .lineLimit(1)
            .padding(.horizontal, Design.Space.tight)
            .padding(.vertical, Design.Space.hair)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                let shape = RoundedRectangle(cornerRadius: Design.Radius.small, style: .continuous)
                switch state {
                case .plain: Color.clear
                case .selected: shape.fill(Design.Palette.selectedRow)
                case .companion: shape.fill(Design.Palette.companionRow)
                }
            }
            .padding(.horizontal, Design.Space.hair)
    }

    private func chip(_ name: String, active: Bool) -> some View {
        Text(name)
            .font(Design.Text.label.weight(active ? .semibold : .regular))
            .foregroundStyle(active ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .padding(.horizontal, Design.Space.tight)
            .padding(.vertical, Design.Space.hair)
            .background { if active { Capsule().fill(Design.Palette.selectedRow) } }
    }
}

/// A title over a supporting line, which is the shape most of this product is
/// made of, at the two ranks it now has.
private struct RowSpecimen: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.snug) {
            Text("List rows")
                .sectionHeading()
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 0) {
                row("zer0-0.1.0-arm64.dmg", "128.4 MB of 240.0 MB", warn: false)
                Divider().hairline().padding(.leading, Design.Space.regular)
                row("annual-report.pdf", "The connection was lost partway through.", warn: true)
                Divider().hairline().padding(.leading, Design.Space.regular)
                row("Rust Programming Language", "doc.rust-lang.org/book/ch04-01.html", warn: false)
            }
            .background(
                Design.Surface.recessed,
                in: RoundedRectangle(cornerRadius: Design.Radius.medium)
            )

            SettingSection(title: "Downloads", footnote: "A file never replaces one already there.") {
                SettingRow(
                    title: "Ask where to save",
                    description: "Otherwise files go straight to the folder above."
                ) {
                    Text("On").font(Design.Text.label).foregroundStyle(.secondary)
                }
            }
        }
        .padding(Design.Space.loose)
    }

    private func row(_ title: String, _ detail: String, warn: Bool) -> some View {
        HStack(alignment: .top, spacing: Design.Space.snug) {
            Image(systemName: warn ? "exclamationmark.triangle" : "arrow.down.circle")
                .font(.title2)
                .foregroundStyle(warn ? AnyShapeStyle(Design.Palette.warning) : AnyShapeStyle(.secondary))
            VStack(alignment: .leading, spacing: Design.Space.line) {
                Text(title).font(Design.Text.rowTitle).lineLimit(1)
                Text(detail)
                    .font(Design.Text.label)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: Design.Space.regular)
        }
        .padding(Design.Space.snug)
    }
}

/// The three status colours where they are a rank rather than a decoration.
private struct RiskSpecimen: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.snug) {
            tier("Critical", "Read and change everything on every site",
                 Design.Palette.danger, 0.08, bordered: true, weight: .semibold)
            tier("High", "Read your browsing history",
                 Design.Palette.warning, 0.07, bordered: false, weight: .medium)
            tier("Moderate", "Store data on this device",
                 nil, 0, bordered: false, weight: .regular)

            HStack(spacing: Design.Space.tight) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Design.Palette.success)
                Text("Extension is running").font(Design.Text.label)
                Spacer()
                Button("Don't Add") {}
                Button("Add Extension") {}.buttonStyle(.borderedProminent)
            }
            .padding(.top, Design.Space.tight)
        }
        .padding(Design.Space.loose)
    }

    private func tier(
        _ name: String, _ what: String, _ hue: Color?, _ alpha: Double,
        bordered: Bool, weight: Font.Weight
    ) -> some View {
        VStack(alignment: .leading, spacing: Design.Space.hair) {
            Text(name)
                .sectionHeading()
                .foregroundStyle(hue ?? Color.secondary)
            Text(what).font(.body.weight(weight))
        }
        .padding(Design.Space.snug)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            let shape = RoundedRectangle(cornerRadius: Design.Radius.medium)
            if let hue { shape.fill(hue.opacity(alpha)) } else { shape.fill(Design.Surface.recessed) }
        }
        .overlay {
            if bordered, let hue {
                RoundedRectangle(cornerRadius: Design.Radius.medium)
                    .strokeBorder(hue.opacity(0.35), lineWidth: Design.Stroke.hairline)
            }
        }
    }
}

/// The scale, top to bottom, so a step that does no work is visible as one.
private struct TypeSpecimen: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.regular) {
            Text("zer0").font(Design.Text.display).tracking(-0.5)
            Text("Nothing downloaded yet").font(Design.Text.emptyTitle)
            Text("Type in the command bar").font(Design.Text.commandInput)
            Text("Ask where to save").font(Design.Text.rowTitle)
            Text("Otherwise files go straight to the folder above.").font(Design.Text.detail)
            Text("avelino/zer0 — pull requests").font(Design.Text.row)
            Text("Section heading").sectionHeading().foregroundStyle(.secondary)
            Text("128.4 MB of 240.0 MB").font(Design.Text.label).foregroundStyle(.secondary)
            Text(verbatim: "*://*.github.com/*").font(Design.Text.mono).foregroundStyle(.secondary)
            Text("⇧⌘J").font(Design.Text.micro).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Design.Space.section)
    }
}
