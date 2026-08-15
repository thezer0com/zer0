import SwiftUI
import Zer0Core

/// Every login zer0 has saved for this space, and a way to take one back.
///
/// **The password is never here, and never one click away.** The list is drawn
/// from the Keychain's attributes, which is the query that cannot raise a
/// dialog and cannot put a secret in memory — the same shape `SecretStore.names()`
/// has and for the same reason (ADR-0064). There is deliberately no "reveal"
/// button: somebody who needs to read a password has Keychain Access, which
/// asks for the login password first, and putting a weaker door beside a
/// stronger one is not a feature.
///
/// Scoped to the space you are in, because a login belongs to an identity
/// rather than to a browser (ADR-0007). A pane that listed every space's logins
/// together would be a pane that shows your work account to somebody looking
/// over your shoulder in your personal one.
struct SavedLoginsSection: View {
    @Environment(BrowserModel.self) private var model

    /// Read once per appearance rather than on every redraw: this is a Keychain
    /// query, and a list that re-queried on each layout pass would ask the
    /// system for the same answer dozens of times to draw one screen.
    @State private var logins: [SavedLogin] = []
    @State private var failure: String?

    var body: some View {
        SettingSection(
            title: "Saved logins",
            footnote: "Saved in your Keychain, one set per space. A space is a separate "
                + "signed-in identity, so the same site can hold two different logins. "
                + "A private space saves none."
        ) {
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(Design.Text.detail)
                    .foregroundStyle(Design.Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            } else if logins.isEmpty {
                empty
            } else {
                list
            }
        }
        .motion(.subtle, value: logins.count)
        .onAppear(perform: reload)
        .onChange(of: model.snapshot.activeSpace) { _, _ in reload() }
    }

    /// The state everybody starts in, and the one that has to explain the
    /// feature rather than apologise for being empty.
    private var empty: some View {
        HStack(alignment: .top, spacing: Design.Space.snug) {
            Image(systemName: "key")
                .font(Design.Text.detail)
                .foregroundStyle(.tertiary)

            Text("Nothing saved yet in \(model.activeSpace?.name ?? "this space"). "
                + "When you sign in somewhere, zer0 offers to remember it — and "
                + "puts it back the next time you put the cursor in the password box.")
                .font(Design.Text.detail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var list: some View {
        VStack(spacing: 0) {
            ForEach(Array(logins.enumerated()), id: \.offset) { index, login in
                row(login)
                if index < logins.count - 1 {
                    Divider().hairline()
                }
            }
        }
    }

    private func row(_ login: SavedLogin) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Design.Space.snug) {
            VStack(alignment: .leading, spacing: Design.Space.line) {
                // The origin, not a prettified host. The exact origin is what
                // the login is keyed by and what tells a lookalike apart from
                // the real thing, so it is what gets shown (ADR-0018).
                Text(login.origin)
                    .font(Design.Text.rowTitle)
                    .textSelection(.enabled)

                Text(login.username)
                    .font(Design.Text.label)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Spacer(minLength: Design.Space.regular)

            Button {
                forget(login)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Forget this login. zer0 will not fill it in again.")
            .accessibilityLabel("Forget \(login.username) on \(login.origin)")
        }
        .padding(.vertical, Design.Space.hair)
    }

    private func reload() {
        guard let store = model.passwordStore, let scope = model.activeSpaceKeychainScope else {
            // No scope is a private space, and a private space has nothing to
            // list rather than something it failed to read.
            logins = []
            failure = nil
            return
        }
        do {
            logins = try store.allLogins(scope: scope)
            failure = nil
        } catch {
            logins = []
            failure = error.localizedDescription
        }
    }

    private func forget(_ login: SavedLogin) {
        guard let store = model.passwordStore, let scope = model.activeSpaceKeychainScope else {
            return
        }
        do {
            try store.forget(login.username, for: login.origin, scope: scope)
            reload()
        } catch {
            failure = error.localizedDescription
        }
    }
}
