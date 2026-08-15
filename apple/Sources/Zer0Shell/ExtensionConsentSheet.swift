import SwiftUI
import Zer0Core

/// A consent request waiting to be answered.
///
/// `ConsentRequest` comes from the core and carries no identity, which
/// `.sheet(item:)` needs. Wrapping it here beats a retroactive conformance on
/// a generated type.
struct PendingConsent: Identifiable {
    let request: ConsentRequest
    var id: String { request.extensionId }
}

/// What an extension is asking for, before it gets any of it.
///
/// The sheet holds a draft decision and hands it back on Add. Nothing reaches
/// the extension until then, and closing without adding grants nothing — so
/// the failure mode of someone hitting Escape is an extension that does not
/// run, never one that quietly runs with everything.
///
/// The words on every row come from the core. What is drawn here is order,
/// weight and colour; what is *said* is behaviour, and two platforms must not
/// disagree about what `<all_urls>` costs you.
struct ExtensionConsentSheet: View {
    let request: ConsentRequest
    let onAdd: (ConsentDecision) -> Void
    let onCancel: () -> Void

    @Curves private var motion

    @State private var decision: ConsentDecision
    /// What the list is holding out of view. One value, read once per scroll,
    /// so the fade and the ledge cannot end up disagreeing about whether there
    /// is more.
    @State private var edges = ScrollEdges()

    /// What the list has out of view, in each direction.
    ///
    /// Derived from one scroll geometry rather than measured per row: the
    /// question the affordance answers is "does this go on", and that is the
    /// only thing a geometry can honestly say.
    struct ScrollEdges: Equatable {
        var above = false
        var below = false

        init() {}

        init(offset: CGFloat, visible: CGFloat, total: CGFloat) {
            // Half a point of slack. A resting scroll view reports fractional
            // offsets, and an affordance that blinks on a rounding error is
            // worse than one that never appears.
            above = offset > 0.5
            below = offset + visible < total - 0.5
        }
    }

    /// Sizes that belong to this one sheet rather than to the whole UI, so they
    /// are named here instead of pretending to be design tokens.
    private enum Metrics {
        /// Wide enough for a permission's title and its sentence of
        /// consequence without the sentence wrapping to four lines.
        static let width: CGFloat = 480
        /// A ceiling rather than a height: a small request stays small, and a
        /// large one scrolls instead of running off the screen.
        static let maxHeight: CGFloat = 620
        /// The extension's own symbol, beside the title rather than above it.
        /// Smaller than `Design.Glyph.icon` because it shares a line with a
        /// name instead of heading a screen on its own.
        static let mark: CGFloat = 26
        /// The column the mark sits in, so the name starts on a fixed vertical.
        static let markColumn: CGFloat = 32
        /// The column each row's risk symbol sits in, for the same reason one
        /// step down.
        static let riskColumn: CGFloat = 20
        /// How far the list dissolves at an edge it carries on past.
        ///
        /// Deep enough to swallow a whole line of a row's prose, because the
        /// thing being fixed is a permission guillotined through its middle
        /// against a hard rule: a flat-cut corner reads as a drawing fault,
        /// and a person who reads it as a fault counts what they can see and
        /// stops. Anything shallower leaves the cut edge still legible as a
        /// cut.
        static let fade: CGFloat = 28
    }

    init(
        request: ConsentRequest,
        onAdd: @escaping (ConsentDecision) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.request = request
        self.onAdd = onAdd
        self.onCancel = onCancel
        // The clock belongs to the shell: the core has to stay deterministic.
        _decision = State(initialValue: defaultConsentDecision(
            request: request,
            decidedAtMs: UInt64(Date().timeIntervalSince1970 * 1000)
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            // An extension that asks for nothing has no list, and a scroll
            // region with nothing in it is still a region: two rules with a
            // band of empty between them, which reads as a list that failed
            // to load rather than as a request with nothing in it. The
            // header already says "asks for nothing" and the footer already
            // says what Add will do.
            if hasList {
                Divider().hairline()
                permissions
            }
            ledge
            footer
        }
        .frame(width: Metrics.width)
        .frame(maxHeight: Metrics.maxHeight)
        .background(.regularMaterial)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: Design.Space.snug) {
            // Grey, not the accent. On this sheet colour is the risk grammar —
            // red is critical, orange is your history and your identity — and
            // the accent is what the one committing button wears. A decorative
            // puzzle piece in either of those colours is spending a meaning on
            // an ornament that says only what the sentence beside it already
            // says.
            Image(systemName: "puzzlepiece.extension.fill")
                .font(.system(size: Metrics.mark))
                .foregroundStyle(.secondary)
                .frame(width: Metrics.markColumn)

            VStack(alignment: .leading, spacing: Design.Space.hair) {
                Text(request.extensionName)
                    .font(.title3.weight(.semibold))
                Text(subtitle)
                    .font(Design.Text.detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Design.Space.loose)
    }

    /// Whether there is anything between the header and the footer at all.
    private var hasList: Bool {
        !request.requests.isEmpty || !request.unreadableHosts.isEmpty
    }

    private var subtitle: String {
        request.requests.isEmpty
            ? "asks for nothing. It can be added as it is."
            : "wants the following. Switch off anything you would rather it did not have."
    }

    // MARK: - The list

    private var permissions: some View {
        ScrollView {
            permissionList
        }
        // A request that fits should sit still rather than rubber-band, so the
        // one that does not is the only one that ever moves.
        .scrollBounceBehavior(.basedOnSize)
        // A mask rather than an overlay, so what dissolves is the content and
        // what shows through is the sheet's own material. If it costs a switch
        // in the fading band its click, that is the right price on this screen:
        // a permission you can only half read is not one to answer.
        .mask(fade)
        .onScrollGeometryChange(for: ScrollEdges.self) { geometry in
            ScrollEdges(
                offset: geometry.contentOffset.y + geometry.contentInsets.top,
                visible: geometry.containerSize.height,
                total: geometry.contentSize.height
            )
        } action: { _, now in
            withAnimation(motion.subtle) { edges = now }
        }
    }

    /// The list dissolving into the sheet at an edge it carries on past.
    ///
    /// macOS hides its overlay scrollbars at rest, so a list that is one row
    /// too long looks exactly like a list that is complete — and this one is
    /// counted. The fade is the affordance that is already there before anyone
    /// touches the trackpad, and it is what turns a permission cut in half
    /// against the footer into a permission visibly going somewhere.
    private var fade: some View {
        VStack(spacing: 0) {
            LinearGradient(
                colors: [.black.opacity(edges.above ? 0 : 1), .black],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: Metrics.fade)

            Rectangle().fill(.black)

            LinearGradient(
                colors: [.black, .black.opacity(edges.below ? 0 : 1)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: Metrics.fade)
        }
    }

    /// The rule between the list and the footer, carrying the one glyph that
    /// says the list goes on past it.
    ///
    /// On the boundary rather than floating over the last row: this is a
    /// consent screen, and covering a permission in order to announce that
    /// there are more permissions is not a trade worth making. It is a marker
    /// and not a button — the trackpad, the wheel and Tab all already scroll,
    /// and a third way to do it would be a control competing with the two that
    /// matter on this sheet.
    private var ledge: some View {
        Divider().hairline().overlay(alignment: .center) {
            if edges.below {
                Image(systemName: "chevron.down")
                    .font(Design.Text.micro.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Design.Space.tight)
                    .padding(.vertical, Design.Space.line)
                    .background(.thickMaterial, in: Capsule())
                    .overlay(
                        Capsule().strokeBorder(.separator, lineWidth: Design.Stroke.hairline)
                    )
                    .transition(.opacity)
                    .accessibilityHidden(true)
            }
        }
    }

    /// Split out of the scroll view so it can be rendered on its own.
    /// `ImageRenderer` rasterises a `ScrollView` as an empty box, and a
    /// consent screen nobody can look at is a consent screen nobody checked.
    var permissionList: some View {
        VStack(alignment: .leading, spacing: Design.Space.loose) {
            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                section(group)
            }

            if !request.unreadableHosts.isEmpty {
                unreadable
            }
        }
        .padding(Design.Space.loose)
    }

    private func section(_ group: RiskGroup) -> some View {
        VStack(alignment: .leading, spacing: Design.Space.snug) {
            Text(heading(for: group.risk))
                .sectionHeading()
                .foregroundStyle(tint(for: group.risk))

            VStack(spacing: 0) {
                ForEach(Array(group.items.enumerated()), id: \.offset) { index, item in
                    row(item)
                    if index < group.items.count - 1 {
                        Divider().hairline().padding(.leading, Design.Space.section)
                    }
                }
            }
            .background(background(for: group.risk))
            .overlay(border(for: group.risk))
            .clipShape(RoundedRectangle(cornerRadius: Design.Radius.medium))
        }
    }

    private func row(_ item: PermissionRequest) -> some View {
        HStack(alignment: .top, spacing: Design.Space.snug) {
            Image(systemName: symbol(for: item.risk))
                .foregroundStyle(tint(for: item.risk))
                .font(.body)
                .frame(width: Metrics.riskColumn)

            VStack(alignment: .leading, spacing: Design.Space.line) {
                Text(item.title)
                    .font(titleFont(for: item.risk))
                    .fixedSize(horizontal: false, vertical: true)
                Text(item.detail)
                    .font(Design.Text.label)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Same treatment as a site rule nobody could parse, one block
                // down: stated, and deliberately not switchable. An approval the
                // browser could not act on would be a lie with a control next to
                // it (ADR-0084). The row keeps its risk tier, because what the
                // extension wanted is worth reading even where it cannot have
                // it — this says only that it does not get it here.
                //
                // Two marks for two facts, the same pair the Extensions screen
                // draws (ADR-0103). Exhaustive: a third kind of not-provided
                // breaks this build rather than borrowing one of these.
                if let stated = item.notProvided {
                    switch stated {
                    case let .notBuiltYet(sentence):
                        Label(sentence, systemImage: "circle.dotted")
                            .font(Design.Text.label)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, Design.Space.hair)
                    case let .declined(sentence):
                        Label(sentence, systemImage: "hand.raised")
                            .font(Design.Text.label)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, Design.Space.hair)
                    }
                }
            }

            Spacer(minLength: Design.Space.snug)

            if item.notProvided == nil {
                Toggle("", isOn: binding(for: item))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    // Read aloud, an unlabelled switch next to two lines of prose
                    // is a switch for nothing.
                    .accessibilityLabel(item.title)
            }
        }
        .padding(Design.Space.snug)
    }

    /// Patterns nobody parsed. Listed, and deliberately not switchable: an
    /// approval the browser could not act on would be a lie with a control
    /// next to it.
    ///
    /// Deliberately not a card. Every block above it is a card because every
    /// block above it is a set of things to answer yes or no to; drawn the
    /// same way, at the same gap and in a fill a third of a step lighter, this
    /// one read as a fifth group whose heading had gone missing. A rule and a
    /// note is what it actually is — a footnote to the list, about rules that
    /// never joined it.
    private var unreadable: some View {
        VStack(alignment: .leading, spacing: Design.Space.tight) {
            // The rule is what separates a footnote from the list it is a
            // footnote to. With no list above it there is nothing to separate
            // from, and it would land a second hairline under the header's.
            if !request.requests.isEmpty {
                Divider().hairline()
            }

            // Not a question mark: the unknown *permissions* above wear that,
            // and they are offered. These were not offered at all. The glyph
            // has to carry the difference between "we cannot explain this" and
            // "we struck this out", because the two blocks are otherwise a
            // sentence apart.
            Label(
                "zer0 could not read \(request.unreadableHosts.count) site "
                    + "\(request.unreadableHosts.count == 1 ? "rule" : "rules") this extension "
                    + "asked for, so \(request.unreadableHosts.count == 1 ? "it was" : "they were") "
                    + "not granted.",
                systemImage: "slash.circle"
            )
            .font(Design.Text.label)
            .foregroundStyle(.secondary)

            // One per line, and a step up out of `.tertiary`. Joined, the
            // separator wraps to the end of a line and dangles there; and the
            // faintest type on the sheet is a poor place to put the list of
            // what the browser silently dropped.
            Text(request.unreadableHosts.joined(separator: "\n"))
                .font(Design.Text.mono)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, Design.Space.regular)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(alignment: .center, spacing: Design.Space.regular) {
            Text(consequence)
                .font(Design.Text.label)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: Design.Space.snug)

            Button("Don't Add", role: .cancel, action: onCancel)
                .keyboardShortcut(.cancelAction)

            Button("Add Extension") { onAdd(decision) }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(Design.Space.loose)
        .motion(.subtle, value: consequence)
    }

    /// What Add is about to do, in the present tense, changing as switches
    /// change. A dialog whose consequence only becomes visible afterwards is a
    /// dialog nobody learns anything from.
    private var consequence: String {
        let total = request.requests.count
        let granted = request.requests.filter {
            consentDecisionGrants(decision: decision, kind: $0.kind, key: $0.key)
        }.count

        if total == 0 {
            return "\(request.extensionName) will run."
        }
        if granted == 0 {
            return "Nothing granted. \(request.extensionName) will be added and will not run "
                + "until you give it something."
        }
        if granted < total {
            return "\(request.extensionName) will run holding \(granted) of \(total). "
                + "Whatever it needed from the rest will not work."
        }
        return "\(request.extensionName) will run holding all \(total)."
    }

    // MARK: - Grouping

    private struct RiskGroup {
        let risk: PermissionRisk
        var items: [PermissionRequest]
    }

    /// Runs of equal risk, in the order the core ranked them. Derived rather
    /// than declared, so this never disagrees with the ranking it is drawing.
    private var groups: [RiskGroup] {
        var groups: [RiskGroup] = []
        for item in request.requests {
            if !groups.isEmpty, groups[groups.count - 1].risk == item.risk {
                groups[groups.count - 1].items.append(item)
            } else {
                groups.append(RiskGroup(risk: item.risk, items: [item]))
            }
        }
        return groups
    }

    private func binding(for item: PermissionRequest) -> Binding<Bool> {
        Binding(
            get: { consentDecisionGrants(decision: decision, kind: item.kind, key: item.key) },
            set: { granted in
                decision = consentDecisionSetting(
                    decision: decision,
                    kind: item.kind,
                    key: item.key,
                    granted: granted
                )
            }
        )
    }

    // MARK: - How each tier looks

    private func heading(for risk: PermissionRisk) -> String {
        switch risk {
        case .critical: "Everything you do"
        case .high: "Your browsing and your accounts"
        case .unknown: "zer0 cannot explain these"
        case .moderate: "Real access, and only this much"
        case .low: "Housekeeping"
        }
    }

    private func symbol(for risk: PermissionRisk) -> String {
        switch risk {
        case .critical: "exclamationmark.triangle.fill"
        case .high: "exclamationmark.circle.fill"
        // Hollow, alone among the five. A filled badge is the sheet asserting
        // something; this row is the sheet saying it has nothing to assert.
        case .unknown: "questionmark.circle"
        case .moderate: "info.circle.fill"
        case .low: "checkmark.circle.fill"
        }
    }

    /// Colour here is a claim about how much something costs you, so the tier
    /// where the browser has no claim to make does not get one.
    ///
    /// `unknown` was orange, the same orange as `high`, one alpha point apart
    /// in the fill — which put "this reaches your bank" and "we could not find
    /// out what this is" in the same paint. They are not the same kind of
    /// statement: one is a measured risk, the other is our ignorance, and
    /// painting ignorance a shade of the warning ranks it against a scale
    /// nobody measured it on (ADR-0018). It says what it is in grey, and the
    /// dashed edge below carries what grey cannot.
    private func tint(for risk: PermissionRisk) -> Color {
        switch risk {
        case .critical: Design.Palette.danger
        case .high: Design.Palette.warning
        case .unknown: .secondary
        case .moderate: .secondary
        case .low: .secondary
        }
    }

    /// Only the worst tier gets weight. If every row shouted, none would.
    private func titleFont(for risk: PermissionRisk) -> Font {
        switch risk {
        case .critical: .body.weight(.semibold)
        case .high: .body.weight(.medium)
        case .unknown, .moderate, .low: .body
        }
    }

    private func background(for risk: PermissionRisk) -> some ShapeStyle {
        switch risk {
        case .critical: AnyShapeStyle(Design.Palette.danger.opacity(0.08))
        case .high: AnyShapeStyle(Design.Palette.warning.opacity(0.07))
        // Unfilled, where every other tier is filled: an outline around
        // nothing is the shape of a field left blank, and that is what this
        // group is. It also keeps `unknown` from borrowing the recessed grey
        // that means "known, and bounded" two groups down.
        case .unknown: AnyShapeStyle(Color.clear)
        case .moderate, .low: Design.Surface.recessed
        }
    }

    /// The edge says how sure the sheet is, which is why only two tiers have
    /// one. Solid is drawn around what we know and can price. Dashed is a line
    /// with holes in it, around a statement with holes in it. The tiers in
    /// between are ordinary and need no edge at all.
    @ViewBuilder
    private func border(for risk: PermissionRisk) -> some View {
        switch risk {
        case .critical:
            RoundedRectangle(cornerRadius: Design.Radius.medium)
                .strokeBorder(Design.Palette.danger.opacity(0.35), lineWidth: Design.Stroke.hairline)
        case .unknown:
            RoundedRectangle(cornerRadius: Design.Radius.medium)
                .strokeBorder(
                    .secondary,
                    style: StrokeStyle(
                        lineWidth: Design.Stroke.hairline,
                        dash: [Design.Space.hair, Design.Space.hair]
                    )
                )
        case .high, .moderate, .low:
            EmptyView()
        }
    }
}
