import SwiftUI
import Zer0Core

/// What this browser holds for the extension the current page is a listing for,
/// and the one thing worth offering about it.
///
/// Appears on a Chrome Web Store listing and nowhere else. The alternative is
/// making someone copy a 32-character id out of a URL into a settings field,
/// which is the kind of thing that makes people give up on a browser.
///
/// Since ADR-0062 the page usually carries the offer itself — the store's own
/// greyed-out button is replaced with one of ours. When that worked, this banner
/// stays quiet until there is something to say: two Add buttons on one screen is
/// one too many. When it did not work — the store changed its markup, the script
/// did not run — everything is here instead, which is why it has to know all the
/// same states the button does.
///
/// **It draws; it decides nothing.** The install lives in `BrowserModel`
/// (`extensionFlow`) and the consent sheet is presented by `BrowserView`,
/// because this view is mounted from the page and a decision has to outlive the
/// page. That used to be the other way round, and it was the defect: the moment
/// the package landed on disk the listing stopped being an offer, this view was
/// torn down, and the sheet it was about to present went with it.
struct InstallBanner: View {
    @Environment(BrowserModel.self) private var model
    let extensionId: String
    /// Whether the page it is sitting over already carries our button.
    let pageCarriesTheOffer: Bool

    /// Sizes that belong to this one banner rather than to the whole UI, so
    /// they are named here instead of pretending to be design tokens.
    private enum Metrics {
        /// Wide enough for the offer and its consequence on two lines, narrow
        /// enough to stay a capsule at the foot of the window.
        static let width: CGFloat = 460
        /// Icon, spinner and check share a column, so the headline does not
        /// shift sideways as the phase changes.
        static let iconColumn: CGFloat = 20
        /// Half of `Design.Stroke.hairline`, and one device pixel at @2x. Same
        /// case as the find bar's edge: it closes the capsule against the page
        /// behind it rather than drawing a frame around it.
        static let edge: CGFloat = 0.5
    }

    /// What is on screen, which is either something in flight or what the
    /// machine holds. Derived, never stored: a banner keeping its own copy is
    /// how the page and the browser ended up disagreeing in the first place.
    private enum Phase: Equatable {
        case resting(ExtensionStanding)
        case installing
        case deciding
        case decided(name: String, running: Bool)
        case failed(message: String)
    }

    private var flow: BrowserModel.ExtensionFlow? {
        guard let flow = model.extensionFlow, flow.id == extensionId else { return nil }
        return flow
    }

    private var phase: Phase {
        guard let flow else { return .resting(model.standing(of: extensionId)) }
        switch flow.phase {
        case .installing: return .installing
        case .deciding: return .deciding
        case let .decided(name, running): return .decided(name: name, running: running)
        case let .failed(message): return .failed(message: message)
        }
    }

    /// What the extension calls itself, when it is here to be asked.
    private var name: String {
        model.installedExtensions.first { $0.id == extensionId }?.manifest.name ?? "This extension"
    }

    /// Nothing to say: the page is already carrying the same offer, and nothing
    /// has started.
    private var silent: Bool {
        guard pageCarriesTheOffer else { return false }
        if case .resting = phase { return true }
        return false
    }

    var body: some View {
        Group {
            if silent {
                // Nothing drawn, and nothing mounted either. This view no longer
                // carries out anything — the model does — so there is nothing
                // left for an invisible copy of it to be keeping alive.
                Color.clear.frame(width: 0, height: 0)
            } else {
                banner
            }
        }
    }

    private var banner: some View {
        HStack(spacing: Design.Space.snug) {
            icon

            VStack(alignment: .leading, spacing: Design.Space.line) {
                Text(headline).font(Design.Text.detail.weight(.medium))
                if let detail {
                    Text(detail)
                        .font(Design.Text.label)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: Design.Space.regular)
            action
        }
        .padding(.horizontal, Design.Space.regular)
        .padding(.vertical, Design.Space.snug)
        .frame(maxWidth: Metrics.width)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.quaternary, lineWidth: Metrics.edge))
        // Resting on the page: the same class of thing as the find bar, a
        // strip that appeared, so it takes the same depth.
        .elevation(Design.Elevation.resting)
        .motion(.entrance, value: phase)
    }

    @ViewBuilder
    private var icon: some View {
        switch phase {
        case .installing:
            ProgressView().controlSize(.small).frame(width: Metrics.iconColumn)
        case let .decided(_, running):
            Image(systemName: running ? "checkmark.circle.fill" : "hand.raised.fill")
                .foregroundStyle(running ? Design.Palette.success : Design.Palette.warning)
                .font(.title3)
                .frame(width: Metrics.iconColumn)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Design.Palette.warning)
                .font(.title3)
                .frame(width: Metrics.iconColumn)
        case let .resting(standing):
            restingIcon(standing)
        case .deciding:
            Image(systemName: "puzzlepiece.extension.fill")
                .foregroundStyle(.tint)
                .font(.title3)
                .frame(width: Metrics.iconColumn)
        }
    }

    @ViewBuilder
    private func restingIcon(_ standing: ExtensionStanding) -> some View {
        switch standing {
        case .notInstalled:
            Image(systemName: "puzzlepiece.extension.fill")
                .foregroundStyle(.tint)
                .font(.title3)
                .frame(width: Metrics.iconColumn)
        case .undecided, .grantedNothing:
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(Design.Palette.warning)
                .font(.title3)
                .frame(width: Metrics.iconColumn)
        case .running:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Design.Palette.success)
                .font(.title3)
                .frame(width: Metrics.iconColumn)
        }
    }

    private var headline: String {
        switch phase {
        case let .resting(standing): restingHeadline(standing)
        case .installing: "Downloading…"
        case .deciding: "Decide what it may do"
        case let .decided(name, running):
            running ? "\(name) is ready" : "\(name) was added but is not running"
        case .failed: "Could not install"
        }
    }

    private func restingHeadline(_ standing: ExtensionStanding) -> String {
        switch standing {
        case .notInstalled: "Add this extension to zer0"
        // Offering to add what is already here would be the browser lying about
        // itself, in a second place.
        case .undecided: "\(name) is here and not running"
        case .grantedNothing: "\(name) is added and holding nothing"
        case .running: "\(name) is already added"
        }
    }

    private var detail: String? {
        switch phase {
        case let .resting(standing): restingDetail(standing)
        case .installing: nil
        case .deciding: nil
        case let .decided(_, running):
            running ? "Manage it in Settings." : "Grant it something in Settings to start it."
        case let .failed(message): message
        }
    }

    private func restingDetail(_ standing: ExtensionStanding) -> String? {
        switch standing {
        case .notInstalled: "You will be asked what it may do. Runs on WebKit; some extensions "
            + "will not work."
        case .undecided: "You have not said what it may do yet."
        case .grantedNothing: "You granted it nothing, so it does not run."
        case .running: "Manage it in Settings."
        }
    }

    @ViewBuilder
    private var action: some View {
        switch phase {
        case let .resting(standing):
            restingAction(standing)
        case .installing, .deciding:
            EmptyView()
        case .decided:
            Button("Done") { model.dismissExtensionFlow() }
                .buttonStyle(.borderless)
        case .failed:
            Button("Try Again") { model.beginExtensionFlow(id: extensionId, from: nil) }
                .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private func restingAction(_ standing: ExtensionStanding) -> some View {
        switch standing {
        case .notInstalled:
            Button("Add") { model.beginExtensionFlow(id: extensionId, from: nil) }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
        // The decision it is waiting on, offered where the person is rather
        // than in a settings pane nobody has a reason to open.
        case .undecided:
            Button("Finish Setting Up") { model.beginExtensionFlow(id: extensionId, from: nil) }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
        // Not `DestructiveButton`: the question this needs is already state on
        // the model, because the same question is asked by a button drawn
        // inside the store's page, which cannot host a dialog of its own. One
        // question, one wording, two places it can be raised from.
        case .grantedNothing, .running:
            Button("Remove", role: .destructive) {
                model.askToRemoveExtension(id: extensionId, from: nil)
            }
            .foregroundStyle(Design.Palette.danger)
            .buttonStyle(.borderless)
        }
    }
}
