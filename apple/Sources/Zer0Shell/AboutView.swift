import SwiftUI

/// What the program is, which build this is, and what it is licensed under.
///
/// The licence line is not boilerplate here. zer0's own code is MIT, but the
/// engine is not ours: parts of WebKit are LGPL, and that puts obligations on
/// the *binary* which MIT on our source neither creates nor discharges.
/// `docs/licensing.md` is the long version; this screen is the pointer to it,
/// because a wall of licence text in an About panel is read by nobody.
public struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    /// Sizes that belong to this one panel rather than to the whole UI, so they
    /// are named here instead of pretending to be design tokens.
    private enum Metrics {
        /// Narrow on purpose: this window says four short things, and a wide
        /// panel would set them as four lonely lines across a lot of nothing.
        static let width: CGFloat = 340
    }

    public init() {}

    public var body: some View {
        VStack(spacing: Design.Space.loose) {
            // The mark's other home, and the one place it is allowed to be the
            // loudest thing on screen.
            Zer0MarkGlyph(side: Design.Glyph.mark)
                .foregroundStyle(.tint)

            VStack(spacing: Design.Space.tight) {
                Text("zer0")
                    .font(Design.Text.display)
                    // Display sizes set at default tracking read loose: the
                    // system's letter-spacing is tuned for a line of prose at
                    // 13pt, not for four letters at 26. Pulling them together
                    // is what makes a wordmark a mark rather than a word, and
                    // it is the only place in the shell that asks for it.
                    .tracking(-0.5)

                Text(Self.versionLine(from: Bundle.main.infoDictionary))
                    // A build number is a value someone reads back to you, not
                    // prose: monospaced so `1` and `l` cannot be confused, and
                    // selectable because it exists to be pasted into a bug
                    // report.
                    .font(Design.Text.mono)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Text("A browser on WebKit, with everything it decides in a Rust core.")
                .font(Design.Text.detail)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Divider().hairline()

            VStack(spacing: Design.Space.tight) {
                Text("zer0's own code is MIT. The engine is not ours — WebKit is "
                    + "part LGPL, which is why a release carries notices and an "
                    + "offer of source that this line cannot stand in for.")
                    // Not `.tertiary`: this is the one thing this window says
                    // that the menu bar does not, and it should not be the
                    // faintest text on screen.
                    .font(Design.Text.label)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Link("Licences and notices", destination: Self.licensing)
                    .font(Design.Text.label)
                    // A link that is not the accent is not a link. The palette
                    // sets the foreground ladder at the root of the window, and
                    // a `Link` inherits it like any other text — so this window
                    // ended up with its one outbound thing painted the same
                    // near-black as the paragraph above it.
                    .foregroundStyle(.tint)
            }
        }
        .padding(Design.Space.section)
        .frame(width: Metrics.width)
        .background {
            // Esc closes, the way it does everywhere else in this app. A panel
            // you can only dismiss with the mouse breaks the rule for no gain.
            Button("Close", action: { dismiss() })
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    private static let licensing = URL(
        string: "https://github.com/avelino/zer0-browser/blob/main/docs/licensing.md"
    )!

    /// The version, read from the bundle rather than written here a second
    /// time: a number kept in two places is a number that disagrees with
    /// itself. Run straight out of SwiftPM there is no bundle to read, and
    /// saying so is better than printing a version nobody built.
    static func versionLine(from info: [String: Any]?) -> String {
        guard let short = info?["CFBundleShortVersionString"] as? String, !short.isEmpty else {
            return "Development build"
        }
        guard let build = info?["CFBundleVersion"] as? String, !build.isEmpty else {
            return "Version \(short)"
        }
        return "Version \(short) (\(build))"
    }
}
