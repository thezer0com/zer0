import SwiftUI
import Zer0Core

/// A server asking who you are.
///
/// # Why this is a panel and the certificate screen is a screen
///
/// They arrive on the same engine callback and they are not the same kind of
/// event. Being asked for a password is **routine** — somebody typed the
/// address of a staging box on purpose and the server wants a name — so it gets
/// a panel over the page it belongs to, and answering it is one of the ordinary
/// things you do while browsing. Being told a site cannot be shown to be itself
/// is a security decision, and ADR-0016 gives that the whole screen.
///
/// Putting them on one surface would either turn a routine request into an
/// alarm or turn an alarm into something you dismiss the way you dismiss a
/// login box. The second is how people learn to click through warnings.
///
/// # What is different from `SitePermissionSheet`
///
/// **Return signs in, and that is deliberate where the camera sheet refuses
/// it.** The two look like the same shape of question and they are not. A
/// camera prompt is raised by a *page*, at a moment the page chose, and a
/// default button there is a keystroke already in flight landing on a camera.
/// This panel is the answer to an address somebody typed, the field has the
/// caret in it, and every password box anybody has ever used submits on Return.
/// Refusing it here would be a rule applied past the reason for it — and
/// AGENTS.md is explicit that a shortcut already in the fingers should do what
/// the fingers expect. Nothing is granted by pressing it: the worst case is a
/// wrong password and the panel coming back.
///
/// **The realm is quoted, not spoken.** `WWW-Authenticate: realm="..."` is
/// written by whoever runs the server and arrives over the network. Measured, it
/// keeps its markup. So it is drawn indented behind a quotation rule, in the
/// secondary colour, never in one of our sentences — the same rule that stops a
/// page's `alert()` text looking like the browser talking (ADR-0075).
struct AuthChallengeSheet: View {
    let prompt: AuthPrompt
    /// `remember` is only ever true when the core said it may be.
    let onSignIn: (_ username: String, _ password: String, _ remember: Bool) -> Void
    let onCancel: () -> Void

    @State private var username = ""
    @State private var password = ""
    @State private var remember = false
    @FocusState private var focus: Field?

    private enum Field: Hashable { case username, password }

    private enum Metrics {
        /// Wide enough that a long origin does not have to truncate, and no
        /// wider: this is a form with two fields in it.
        static let width: CGFloat = 420
        static let mark: CGFloat = 28
        static let markColumn: CGFloat = 36
        /// The quotation rule down the left of the server's own words.
        static let quoteRule: CGFloat = 2
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            question
            Divider().hairline()
            fields
            Divider().hairline()
            footer
        }
        .frame(width: Metrics.width)
        .background(.regularMaterial)
        // A field that opens has the caret in it (AGENTS.md). Without this the
        // first thing somebody types goes nowhere and they have to reach for
        // the mouse to answer a keyboard question.
        .onAppear { focus = .username }
        .onExitCommand(perform: onCancel)
    }

    // MARK: - What is being asked

    private var question: some View {
        HStack(alignment: .top, spacing: Design.Space.snug) {
            // A person, not a padlock. This is somebody being asked to say who
            // they are; a padlock would put it in the same visual family as the
            // certificate screen, which is the one thing it must not read as.
            Image(systemName: "person.badge.key.fill")
                .font(.system(size: Metrics.mark))
                .foregroundStyle(.secondary)
                .frame(width: Metrics.markColumn)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Design.Space.tight) {
                Text(prompt.title)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)

                // Verbatim, in mono, with the scheme: `http://` and `https://`
                // are different sites, and a line naming only the host would
                // hide which one is asking for a password.
                Text(prompt.origin)
                    .font(Design.Text.mono)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                Text(prompt.detail)
                    .font(Design.Text.detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let realm = prompt.realm {
                    serverSays(realm)
                }
                if let note = prompt.proxyNote {
                    alarm(note, symbol: "network.badge.shield.half.filled")
                }
                if let note = prompt.insecureNote {
                    alarm(note, symbol: "lock.open.trianglebadge.exclamationmark")
                }
                if let note = prompt.retryNote {
                    Text(note)
                        .font(Design.Text.label)
                        .foregroundStyle(Design.Palette.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(Design.Space.loose)
    }

    /// The server's own words, drawn as somebody else's.
    ///
    /// Indented behind a rule and introduced by name, so there is no reading of
    /// this block on which the text belongs to zer0. A realm folded into one of
    /// our sentences would be a stranger writing in the browser's voice, which
    /// is the same defect as letting a page's `alert()` look like us.
    private func serverSays(_ realm: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("The server calls this area")
                .font(Design.Text.micro)
                .foregroundStyle(.tertiary)
            Text(realm)
                .font(Design.Text.label)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, Design.Space.tight)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The rule as an overlay rather than as a sibling in an `HStack`.
        // A `RoundedRectangle` beside the text has no intrinsic height, so it
        // grew to whatever was offered and took the whole panel with it — the
        // sheet rendered 800pt tall with 650pt of empty quotation down the
        // middle. As an overlay it is exactly as tall as what it is quoting.
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: Metrics.quoteRule / 2)
                .fill(.quaternary)
                .frame(width: Metrics.quoteRule)
        }
    }

    private func alarm(_ note: String, symbol: String) -> some View {
        Label(note, systemImage: symbol)
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

    private var fields: some View {
        VStack(alignment: .leading, spacing: Design.Space.snug) {
            LabeledContent("Name") {
                TextField("", text: $username)
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .username)
                    .onSubmit { focus = .password }
            }
            LabeledContent("Password") {
                SecureField("", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .password)
                    .onSubmit(submit)
            }

            // Offered only when the core said it may be, and the core says no
            // for three different reasons: a proxy, an unencrypted origin off
            // loopback, and a space that promised to write nothing down. The
            // panel does not work any of those out for itself.
            if prompt.mayRemember {
                Toggle("Remember this sign-in", isOn: $remember)
                    .font(Design.Text.label)
            }
        }
        .padding(Design.Space.loose)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: Design.Space.snug) {
            // Said before the buttons, because it is the part nobody expects:
            // everybody assumes a saved sign-in is per site, and this one is
            // per site per space (ADR-0007, ADR-0064).
            if prompt.mayRemember {
                Text(prompt.scopeNote)
                    .font(Design.Text.label)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: Design.Space.snug) {
                Spacer(minLength: Design.Space.snug)

                // Escape does this too. Cancelling still answers the engine —
                // the server is told nobody answered and the page gets whatever
                // it serves to strangers, which is a page rather than a tab that
                // never finishes loading.
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)

                // Return. See the type documentation for why this sheet has a
                // default action where the camera sheet refuses one.
                Button("Sign In", action: submit)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty)
            }
        }
        .padding(Design.Space.loose)
    }

    private func submit() {
        guard !password.isEmpty else {
            // Return in an empty password field moves the caret there rather
            // than sending an empty answer the server will only refuse.
            focus = .password
            return
        }
        onSignIn(username, password, remember && prompt.mayRemember)
    }
}
