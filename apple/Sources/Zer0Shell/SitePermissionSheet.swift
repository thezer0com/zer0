import SwiftUI
import Zer0Core

/// A question a page asked, waiting on an answer.
///
/// `SitePermissionPrompt` comes from the core and carries no identity, which
/// `.sheet(item:)` needs. The request number is the identity: it is monotonic
/// and never reused, so a sheet cannot be recycled for the next question and
/// carry the last one's words for a frame.
struct PendingSitePermission: Identifiable {
    let prompt: SitePermissionPrompt
    var id: UInt64 { prompt.request }
}

/// What a page is asking for, before it gets any of it.
///
/// This sheet has one structural difference from `ExtensionConsentSheet`, and
/// everything unusual about it follows from that difference: **the page chose
/// the moment.** An extension dialog arrives at the end of a gesture somebody
/// made. This one can arrive mid-sentence, one frame after a click, on any page
/// in the world. Three things fall out of that.
///
/// **Neither answer is bound to a key.** `ExtensionConsentSheet` gives Add
/// `.defaultAction`, because the person went and asked for an extension. Here,
/// a default button means Return says yes to a camera — and the Return that
/// lands is the one that was already on its way down when the page chose to
/// interrupt. `.cancelAction` is left off for the same reason in the other
/// direction: Don't Allow is a *recorded* refusal, and a recorded answer should
/// cost a deliberate click. Escape is handled by `.onExitCommand` and gives the
/// transient answer, so the key that gets you out of everything else still
/// gets you out of this, and getting out is not an instruction.
///
/// **Both buttons are dead for the first half second.** The core ignores an
/// answer inside `promptSettleMs()` (see `site_permissions::PROMPT_SETTLE_MS`),
/// which is the guarantee; this is what makes the guarantee visible rather than
/// a click that silently does nothing. Nobody who is reading the sheet ever
/// reaches the buttons that fast.
///
/// **It says who asked, not what page you are on.** For an embedded frame those
/// are different sites, and the difference is the whole trick: a sheet over a
/// site you trust, carrying a name you would not have agreed to.
///
/// The words are the core's. What is drawn here is weight, colour and order.
struct SitePermissionSheet: View {
    let prompt: SitePermissionPrompt
    let onAllow: () -> Void
    let onBlock: () -> Void
    let onDismiss: () -> Void

    /// False until the settle window has passed. Not a countdown: a timer drawn
    /// on a consent screen is a thing to watch instead of read.
    @State private var answerable = false

    /// What wakes the buttons up.
    ///
    /// A run-loop timer rather than `.task { try await Task.sleep(...) }`, and
    /// the reason is the one thing that must not go wrong here: if whatever
    /// wakes them never fires, this sheet has two dead buttons on it forever.
    /// A `Timer` on the main run loop is driven by the same thing that draws
    /// the sheet, which means the offscreen harness in `ZZSitePermissionShots`
    /// can watch it happen — and a wake-up nobody has seen is a wake-up nobody
    /// should trust (AGENTS.md).
    ///
    /// It goes on ticking after it has done its job, and that is deliberate
    /// rather than an oversight: cancelling it would be a second mechanism that
    /// can fail, to save one no-op main-thread callback every half second on a
    /// sheet that lives for seconds. Setting an already-true `@State` to true
    /// does not redraw anything.
    ///
    /// Escape is deliberately *not* gated on this. Whatever happens to the
    /// timer, there is always a way out, and the way out answers the page.
    @State private var settle = Timer
        .publish(every: Double(promptSettleMs()) / 1000, on: .main, in: .common)
        .autoconnect()

    /// Sizes that belong to this one sheet rather than to the whole UI, so they
    /// are named here instead of pretending to be design tokens.
    private enum Metrics {
        /// Wide enough for the consequence sentence to sit on two lines rather
        /// than four. Narrower than the extension sheet because there is no
        /// list here — one question, one answer.
        static let width: CGFloat = 420
        /// The glyph, beside the sentence rather than above it. Larger than
        /// `ExtensionConsentSheet`'s puzzle piece because it is the only
        /// picture on the sheet and it carries the whole of "this is a camera".
        static let mark: CGFloat = 30
        /// The column it sits in, so the sentence starts on a fixed vertical.
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
        .onReceive(settle) { _ in answerable = true }
    }

    // MARK: - The question

    private var question: some View {
        HStack(alignment: .top, spacing: Design.Space.snug) {
            // Danger, and there is no second tier on this sheet. A camera and a
            // microphone are the same kind of thing — a live feed of the room
            // you are in — so a scale with one step on it is the honest scale.
            // `ExtensionConsentSheet` ranks five tiers because it is answering
            // about fifty different permissions at once; ranking two things
            // against each other here would only spend a colour saying that one
            // of them matters less, which is not true.
            Image(systemName: symbol)
                .font(.system(size: Metrics.mark))
                .foregroundStyle(Design.Palette.danger)
                .frame(width: Metrics.markColumn)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Design.Space.tight) {
                Text(prompt.title)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)

                // Verbatim, in mono, under the sentence rather than inside it.
                // The scheme is part of it: `http://` and `https://` are
                // different sites and a title that said only the host would
                // hide which one asked.
                Text(prompt.origin)
                    .font(Design.Text.mono)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                Text(prompt.detail)
                    .font(Design.Text.detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let note = prompt.embeddedNote {
                    embedded(note)
                }
            }
        }
        .padding(Design.Space.loose)
    }

    private var symbol: String {
        switch prompt.capture {
        case .camera, .cameraAndMicrophone: "video.fill"
        case .microphone: "mic.fill"
        }
    }

    /// The one thing on this sheet that is allowed to shout, because it is the
    /// one thing a person would otherwise get wrong: the name in the title is
    /// not the site they think they are on.
    private func embedded(_ note: String) -> some View {
        Label(note, systemImage: "exclamationmark.triangle.fill")
            .font(Design.Text.label)
            .foregroundStyle(Design.Palette.warning)
            .fixedSize(horizontal: false, vertical: true)
            .padding(Design.Space.tight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Design.Palette.warning.opacity(0.1),
                in: RoundedRectangle(cornerRadius: Design.Radius.small)
            )
    }

    // MARK: - The answer

    private var footer: some View {
        VStack(alignment: .leading, spacing: Design.Space.snug) {
            // Said before the buttons rather than after, because it is the part
            // that is not obvious: everybody expects a permission to be per
            // site, and this one is per site *per space*.
            Text(prompt.scopeNote)
                .font(Design.Text.label)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Design.Space.snug) {
                Spacer(minLength: Design.Space.snug)

                // **Neither button carries a key.** Not `.cancelAction` on this
                // one and not `.defaultAction` on the other, and that is a
                // deliberate departure from every other sheet in this shell.
                //
                // Both of these answers are written down and both change what
                // the browser does from now on, and the page picked the moment
                // the sheet appeared. A key equivalent on a permanent answer is
                // a keystroke somebody aimed at a text field landing on a
                // camera. So the two recorded answers cost a click each, and
                // the key that is bound is Escape — which gives the *transient*
                // answer, below, because closing a window is not an
                // instruction.
                // **Neither one is the loud one.** Every other pair of buttons
                // in this shell gives the committing side `.borderedProminent`,
                // because in every other case the committing side is what the
                // person came to do. Here the person came to read a page and a
                // script interrupted them, so the loudest thing on a sheet they
                // did not ask for must not be the word yes. Two answers, the
                // same weight, and the pointer has to be aimed at one of them.
                Button("Don't Allow", action: onBlock)
                    .disabled(!answerable)

                Button("Allow", action: onAllow)
                    .disabled(!answerable)
            }
            .motion(.subtle, value: answerable)
        }
        .padding(Design.Space.loose)
        // Esc, and any other way the sheet goes away without a button being
        // pressed. Transient: the page is told no, nothing is written down, and
        // it does not get to ask again until the tab navigates.
        .onExitCommand(perform: onDismiss)
    }
}
