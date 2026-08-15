import SwiftUI
import Zer0Core

/// A tool the model asked to run, and the answer nobody has given yet.
///
/// The structural twin of `ExtensionConsentSheet`, and held to the same
/// standard, because it is the same problem one step worse: an extension asks
/// once for a static permission, and a tool asks to run *these arguments* — a
/// value nobody has seen until this moment. So the arguments are on screen
/// before anything can be approved, never behind a disclosure somebody has to
/// find (ADR-0050).
///
/// What is said here comes from the core and is separated by who said it.
/// `ours` is what zer0 knows and will put its name to; `theirs` is the server's
/// own sentence about its own tool, drawn as a quotation. Concatenating them
/// would be putting our name on a stranger's claim, which is exactly the
/// evidence ADR-0028 refuses.
struct ToolCallRow: View {
    @Environment(BrowserModel.self) private var model
    let call: ToolCall
    let conversation: ConversationId

    private enum Metrics {
        /// How far the arguments block grows before it scrolls. Tall enough for
        /// a realistic call, short enough that the question above it stays on
        /// screen while the arguments are read.
        static let arguments: CGFloat = 160
        /// The column the risk mark sits in, so every line starts on one
        /// vertical — the same job it does on the consent sheet.
        static let markColumn: CGFloat = 20
    }

    var body: some View {
        switch call.state {
        case .awaitingConsent:
            asking
        case .running:
            settled(
                "Running \(call.invocation.tool)…",
                symbol: "gearshape.2",
                tint: Design.Palette.inkSecondary
            )
        case .completed:
            settled(
                "Ran \(call.invocation.tool).",
                symbol: "checkmark.circle",
                tint: Design.Palette.success
            )
        case .failed:
            settled(
                "\(call.invocation.tool) failed.",
                symbol: "exclamationmark.triangle",
                tint: Design.Palette.warning
            )
        case .refused:
            settled(
                "\(call.invocation.tool) was not run.",
                symbol: "slash.circle",
                tint: Design.Palette.inkSecondary
            )
        case .cancelled:
            settled(
                "\(call.invocation.tool) was stopped.",
                symbol: "stop.circle",
                tint: Design.Palette.inkSecondary
            )
        }
    }

    // MARK: - Waiting on somebody

    private var asking: some View {
        VStack(alignment: .leading, spacing: Design.Space.snug) {
            header
            consequence
            arguments
            choices
        }
        .padding(Design.Space.snug)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Design.Palette.warning.opacity(0.07),
            in: RoundedRectangle(cornerRadius: Design.Radius.medium)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Design.Radius.medium)
                .strokeBorder(
                    Design.Palette.warning.opacity(0.35),
                    lineWidth: Design.Stroke.hairline
                )
        )
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Design.Space.tight) {
            Image(systemName: "hand.raised.fill")
                .font(.body)
                .foregroundStyle(Design.Palette.warning)
                .frame(width: Metrics.markColumn)

            VStack(alignment: .leading, spacing: Design.Space.line) {
                Text("Run \(call.invocation.tool)?")
                    .font(.body.weight(.semibold))
                Text("from \(call.invocation.server)")
                    .font(Design.Text.label)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// What running it costs, in zer0's voice, and what the server says about
    /// itself as a quotation under it.
    ///
    /// When the browser has nothing of its own to say, it says that rather than
    /// promoting the server's sentence into the gap — the tier with no claim to
    /// make does not get one (ADR-0018).
    @ViewBuilder
    private var consequence: some View {
        VStack(alignment: .leading, spacing: Design.Space.tight) {
            Text(disclosure?.ours ?? "zer0 cannot describe what this tool does.")
                .font(Design.Text.detail)
                .fixedSize(horizontal: false, vertical: true)

            if let theirs = disclosure?.theirs, !theirs.isEmpty {
                Text("\(call.invocation.server) describes it as: “\(theirs)”")
                    .font(Design.Text.label)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.leading, Metrics.markColumn + Design.Space.tight)
    }

    /// The part an extension never had: what it will actually be run with.
    ///
    /// Always visible, never behind a disclosure triangle. Approving
    /// `write_file` is not approving `write_file` — it is approving this path,
    /// and a screen that hides the path is asking somebody to consent to a value
    /// they were not shown (ADR-0050).
    private var arguments: some View {
        VStack(alignment: .leading, spacing: Design.Space.hair) {
            Text("Will run with")
                .sectionHeading()
                .foregroundStyle(.secondary)

            ScrollView {
                Text(call.invocation.arguments.isEmpty ? "no arguments" : call.invocation.arguments)
                    .font(Design.Text.mono)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxHeight: Metrics.arguments)
            .scrollBounceBehavior(.basedOnSize)
            .padding(Design.Space.tight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Design.Surface.recessedInner,
                in: RoundedRectangle(cornerRadius: Design.Radius.small)
            )
        }
        .padding(.leading, Metrics.markColumn + Design.Space.tight)
    }

    /// Four answers, and they are not four buttons.
    ///
    /// The two that decide only this call are buttons; the two that are
    /// remembered sit behind a menu, because a standing answer is a different
    /// weight of decision and putting it a click away is the difference between
    /// choosing it and hitting it. "Always allow" is absent entirely unless the
    /// server calls the tool read-only, non-destructive and closed-world — a
    /// server that admits it is destructive does not get to offer the box
    /// (ADR-0050).
    ///
    /// Nothing here takes Return. The composer below owns it, and a consent
    /// card that quietly stole the key somebody is typing with would be the
    /// worst possible place to put a surprise.
    private var choices: some View {
        HStack(spacing: Design.Space.tight) {
            Button("Allow Once") { decide(.once) }
                .buttonStyle(.borderedProminent)

            Button("Not Now") { decide(.refuse) }

            Spacer(minLength: Design.Space.tight)

            Menu("Remember…") {
                if disclosure?.mayBeStanding == true {
                    Button("Always Allow \(call.invocation.tool)") { decide(.always) }
                }
                Button("Never Allow \(call.invocation.tool)") { decide(.never) }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.leading, Metrics.markColumn + Design.Space.tight)
    }

    // MARK: - Settled

    private func settled(_ text: String, symbol: String, tint: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(Design.Text.label)
            .foregroundStyle(tint)
    }

    private var disclosure: ToolDisclosure? {
        model.disclosure(server: call.invocation.server, tool: call.invocation.tool)
    }

    private func decide(_ choice: ConsentChoice) {
        model.send(.decideToolCall(call: call.invocation.id, decision: choice))
    }
}

// MARK: - When it went wrong

/// Why a conversation could not go on, as a screen rather than a log line.
///
/// The categories are the core's, exactly as `NavigationErrorKind` is, and the
/// wording is the shell's. Each one gets a name for what happened rather than
/// for the error that reported it, a sentence somebody can act on, and one
/// action — and for the one failure that is a configuration fault rather than
/// a transient one, that action is the screen that fixes it.
struct ChatErrorNotice: View {
    @Environment(BrowserModel.self) private var model
    let error: ChatError
    let conversation: ConversationId

    var body: some View {
        HStack(alignment: .top, spacing: Design.Space.snug) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(tint)

            VStack(alignment: .leading, spacing: Design.Space.tight) {
                VStack(alignment: .leading, spacing: Design.Space.line) {
                    Text(title)
                        .font(Design.Text.rowTitle)
                    Text(message)
                        .font(Design.Text.label)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                action
            }
        }
        .padding(Design.Space.snug)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: Design.Radius.medium))
        .overlay(
            RoundedRectangle(cornerRadius: Design.Radius.medium)
                .strokeBorder(tint.opacity(0.3), lineWidth: Design.Stroke.hairline)
        )
    }

    /// One useful thing to do, and which one depends on whether this is a fault
    /// or a hiccup.
    ///
    /// `NoProviderConfigured` is the first thing anybody meets, and "try again"
    /// would be advice that cannot work — nothing has been set up, so trying
    /// again fails identically. It goes to the pane that fixes it (ADR-0049).
    @ViewBuilder
    private var action: some View {
        switch error.kind {
        case .noProviderConfigured:
            Button("Set Up a Model") { model.perform(.showSettings) }
                .buttonStyle(.borderedProminent)

        case .notAuthorised:
            Button("Check the Key") { model.perform(.showSettings) }
                .buttonStyle(.borderedProminent)

        case .toolUnavailable, .toolFailed:
            Button("Review Connections") { model.perform(.showSettings) }

        // Transient, every one of them: the thing to do is ask again, and the
        // composer below is already how you do that. A second "Try Again"
        // button beside a focused field would be two ways to do one thing.
        case .rateLimited, .offline, .connectionFailed, .timeout, .contextTooLong,
             .malformedResponse, .providerRefused, .toolLoop, .unknown:
            EmptyView()
        }
    }

    private var tint: Color {
        switch error.kind {
        case .noProviderConfigured, .rateLimited, .offline, .connectionFailed, .timeout,
             .toolUnavailable, .toolLoop:
            Design.Palette.warning
        case .notAuthorised, .contextTooLong, .malformedResponse, .providerRefused, .toolFailed,
             .unknown:
            Design.Palette.danger
        }
    }

    private var symbol: String {
        switch error.kind {
        case .noProviderConfigured: "sparkles"
        case .notAuthorised: "key.slash"
        case .rateLimited: "hourglass"
        case .offline: "wifi.slash"
        case .connectionFailed: "bolt.horizontal.circle"
        case .timeout: "clock.badge.exclamationmark"
        case .contextTooLong: "text.append"
        case .malformedResponse: "questionmark.circle"
        case .providerRefused: "hand.raised.slash"
        case .toolUnavailable: "powerplug"
        case .toolFailed: "wrench.adjustable"
        case .toolLoop: "arrow.triangle.2.circlepath"
        case .unknown: "exclamationmark.triangle"
        }
    }

    private var title: String {
        switch error.kind {
        case .noProviderConfigured: "No model is set up yet"
        case .notAuthorised: "That key was refused"
        case .rateLimited: "Too many questions, too fast"
        case .offline: "You're offline"
        case .connectionFailed: "Couldn't reach the model"
        case .timeout: "The model stopped answering"
        case .contextTooLong: "This conversation is too long"
        case .malformedResponse: "The answer couldn't be read"
        case .providerRefused: "The model declined to answer"
        case .toolUnavailable: "That tool's server isn't connected"
        case .toolFailed: "The tool didn't work"
        case .toolLoop: "This went round in circles"
        case .unknown: "That didn't work"
        }
    }

    private var message: String {
        switch error.kind {
        case .noProviderConfigured:
            "zer0 doesn't have a model to ask yet. Pick one in Settings — a local model "
                + "needs no account and no key."
        case .notAuthorised:
            "The provider would not take the key it was given. It may have been revoked, "
                + "or it may belong to a different provider."
        case .rateLimited:
            "The provider is asking you to slow down. Waiting a moment and asking again "
                + "usually works."
        case .offline:
            "Your Mac isn't connected to the internet, so the model can't be reached."
        case .connectionFailed:
            "The connection was refused or dropped partway. If the model runs on this Mac, "
                + "it may not be running right now."
        case .timeout:
            "The connection was taken and then went quiet. Nothing more arrived."
        case .contextTooLong:
            "There is more here than the model will read at once. Starting a new "
                + "conversation is the way on."
        case .malformedResponse:
            "Something answered, and it wasn't in a shape zer0 could read."
        case .providerRefused:
            "The provider answered, and the answer was a refusal. The model asked for "
                + "may no longer exist."
        case .toolUnavailable:
            "The tool the model asked for belongs to a server that isn't running, so "
                + "nothing was run and nobody was asked."
        case .toolFailed:
            "The tool ran and reported a failure. What it said is in the thread above."
        case .toolLoop:
            "One question spent too many turns calling tools, so zer0 stopped it before "
                + "it spent any more."
        case .unknown:
            // The category is the shell admitting it does not recognise the
            // failure. What the host said is then better than a guess.
            error.detail.isEmpty ? "The answer stopped before it could be shown." : error.detail
        }
    }
}
