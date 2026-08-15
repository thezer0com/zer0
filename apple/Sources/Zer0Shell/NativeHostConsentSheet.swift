import SwiftUI
import Zer0Core

/// A program an extension asked to start, waiting on an answer.
///
/// **Why there is a second sheet at all**, when `ExtensionConsentSheet` already
/// asked: `nativeMessaging` reads *"Talk to programs installed on this Mac"*,
/// and at install time that is the most that could honestly be said — the
/// registration naming the program belongs to whatever installed the desktop
/// application and may not exist yet. This is the same grant, asked once more
/// at the one moment its object exists (ADR-0105).
///
/// It is closer to `SitePermissionSheet` than to `ExtensionConsentSheet`, and
/// three things follow:
///
/// **Neither answer is bound to Return.** Allow starts a program that runs
/// outside the browser as you. `ExtensionConsentSheet` gives Add
/// `.defaultAction` because somebody went and asked for an extension; nobody
/// asked for this, and the Return already on its way down when a button was
/// pressed must not be the thing that starts a process.
///
/// **Escape answers, and answers nothing down.** The request is being held open
/// while this is on screen, so a sheet that could be dismissed without
/// answering would be an extension waiting for ever. Escape refuses *this*
/// request and writes nothing, so the next press asks again — which is what
/// "not now" means, and is different from Don't Allow, which is recorded and
/// survives a relaunch.
///
/// **The path is the loudest thing on it.** Everything else is a sentence; the
/// program is the fact.
struct PendingNativeHostQuestion: Identifiable, Equatable {
    let pending: BrowserModel.PendingNativeHost
    var id: String { pending.id }
}

struct NativeHostConsentSheet: View {
    let prompt: NativeHostPrompt
    let onAllow: () -> Void
    let onRefuse: () -> Void
    let onDismiss: () -> Void

    /// Sizes belonging to this one sheet rather than to the whole UI.
    private enum Metrics {
        /// Wide enough for a real program path to sit on two lines rather than
        /// five. `/Applications/1Password.app/Contents/Library/LoginItems/…`
        /// is the shape that decided this, measured rather than guessed.
        static let width: CGFloat = 460
        /// The glyph, beside the sentence. The only picture on the sheet.
        static let mark: CGFloat = 30
        static let markColumn: CGFloat = 36
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            question
            Divider().hairline()
            footer
        }
        .frame(width: Metrics.width)
        .background(.regularMaterial)
    }

    // MARK: - The question

    private var question: some View {
        HStack(alignment: .top, spacing: Design.Space.snug) {
            // A terminal rather than a puzzle piece: what is being asked about
            // is a program, and the extension is only the thing asking.
            Image(systemName: "terminal.fill")
                .font(.system(size: Metrics.mark))
                .foregroundStyle(Design.Palette.danger)
                .frame(width: Metrics.markColumn)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Design.Space.tight) {
                Text(prompt.title)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)

                // Verbatim, in mono, selectable, and above the prose. Somebody
                // deciding this needs to be able to copy the path and go look
                // at it, and a path folded into a sentence is a path nobody
                // reads.
                Text(prompt.program)
                    .font(Design.Text.mono)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                Text(prompt.detail)
                    .font(Design.Text.detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Design.Space.loose)
    }

    // MARK: - The answer

    private var footer: some View {
        VStack(alignment: .leading, spacing: Design.Space.snug) {
            // Where the registration came from, before the buttons, because it
            // is the part nobody expects: the program was registered by another
            // browser and this one is borrowing that.
            Text(prompt.provenance)
                .font(Design.Text.label)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(prompt.manifestPath)
                .font(Design.Text.micro)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Design.Space.snug) {
                Spacer(minLength: Design.Space.snug)

                // Neither one is prominent and neither carries a key, for the
                // reason `SitePermissionSheet` gives: both answers are recorded
                // and neither was asked for. The pointer has to be aimed.
                Button("Don't Allow", action: onRefuse)
                Button("Allow", action: onAllow)
            }
        }
        .padding(Design.Space.loose)
        // Esc, and any other way this goes away without a button. The request
        // is refused and nothing is written down, so the next press asks again.
        .onExitCommand(perform: onDismiss)
    }
}
