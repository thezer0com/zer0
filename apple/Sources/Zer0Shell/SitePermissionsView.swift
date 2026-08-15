import SwiftUI
import Zer0Core

/// Everything a site was allowed — or refused — and a way to change your mind.
///
/// A grant nobody can find is a grant nobody can take back, which is the whole
/// reason `ExtensionsView` grew a permissions list. This is the same screen for
/// the other half of the problem, with one thing the extension pane does not
/// have to say: these answers are **per space**, so the same site can appear
/// twice with two different answers, and a row that did not name its space
/// would read as a duplicate.
///
/// Refusals are listed beside grants. A refusal you cannot see is a refusal you
/// cannot undo, and blocking a site by accident on a sheet you did not expect is
/// exactly the mistake this pane exists to be findable after.
struct SitePermissionsSection: View {
    @Environment(BrowserModel.self) private var model

    var body: some View {
        SettingSection(
            title: "Camera and microphone",
            footnote: "Answers are remembered for one space at a time. A space is a separate "
                + "signed-in identity, so the same site can hold the camera in one and not "
                + "in another."
        ) {
            if model.siteGrants.isEmpty {
                empty
            } else {
                list
            }
        }
    }

    /// The state almost everybody is in, and for most people the only state
    /// they will ever see this pane in.
    private var empty: some View {
        HStack(alignment: .top, spacing: Design.Space.snug) {
            Image(systemName: "video.slash")
                .font(Design.Text.detail)
                .foregroundStyle(.tertiary)

            Text("No site has asked for your camera or microphone yet. When one does, zer0 "
                + "asks first — and whatever you answer shows up here.")
                .font(Design.Text.detail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var list: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.siteGrants.enumerated()), id: \.offset) { index, grant in
                row(grant)
                if index < model.siteGrants.count - 1 {
                    Divider().hairline()
                }
            }
        }
    }

    private func row(_ grant: SiteGrant) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Design.Space.snug) {
            VStack(alignment: .leading, spacing: Design.Space.line) {
                Text(grant.origin)
                    .font(Design.Text.rowTitle)
                    .textSelection(.enabled)

                Text("\(name(of: grant.capability)) · \(model.spaceName(grant.space))")
                    .font(Design.Text.label)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: Design.Space.regular)

            // Two states rather than three, and the third — "ask me again" — is
            // the button beside it. A three-way picker would put "forget this"
            // in the same grammar as an answer, and it is not one: it is taking
            // the question back rather than answering it differently.
            Picker("", selection: Binding(
                get: { grant.allowed },
                set: { model.setSitePermission(grant, allowed: $0) }
            )) {
                Text("Allow").tag(true)
                Text("Block").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: Metrics.answer)
            .accessibilityLabel("\(name(of: grant.capability)) on \(grant.origin)")

            Button {
                model.forgetSitePermission(grant)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Forget this answer, so the site is asked again next time")
        }
        .padding(.vertical, Design.Space.hair)
    }

    private func name(of capability: SiteCapability) -> String {
        switch capability {
        case .camera: "Camera"
        case .microphone: "Microphone"
        }
    }

    private enum Metrics {
        /// Wide enough for both words at the segmented control's own type size
        /// without either wrapping to an ellipsis.
        static let answer: CGFloat = 130
    }
}
