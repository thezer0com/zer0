import AppKit
import SwiftUI

/// The visual vocabulary, in one place.
///
/// Every screen pulls its spacing, radius and type from here rather than
/// inventing its own. That consistency is most of what reads as "considered"
/// versus "assembled".
enum Design {
    /// A 4pt rhythm. Everything is a multiple, so nothing lands half a pixel
    /// off from everything else — with one named exception, `line`, which
    /// carries its own reason.
    enum Space {
        static let hair: CGFloat = 4
        static let tight: CGFloat = 8
        static let snug: CGFloat = 12
        static let regular: CGFloat = 16
        static let loose: CGFloat = 24
        static let section: CGFloat = 32

        /// The gap between the two lines of one label: a title and the line
        /// that qualifies it.
        ///
        /// The one value deliberately off the rhythm. Those two lines are one
        /// thing, and at `hair` they separate into two stacked rows instead of
        /// reading as a name with a note under it. Named because it was
        /// already being written by hand as 1, as 2, as 3 and as `hair / 2` —
        /// four values doing one job, which is how a rhythm stops being one.
        static let line: CGFloat = 2
    }

    /// Type scale.
    ///
    /// Built on text styles rather than fixed point sizes, so the whole UI
    /// follows the system's text size instead of staying at 11pt for someone
    /// who cannot read 11pt.
    enum Text {
        /// Sidebar rows, list items: the bulk of the UI.
        static let row = Font.system(.subheadline)
        /// Group headers, metadata, counts.
        static let label = Font.system(.caption)
        /// The smallest thing we are willing to print.
        static let micro = Font.system(.caption2)
        /// Section titles inside a settings pane.
        static let sectionTitle = Font.system(.caption).weight(.semibold)
        /// The command bar's input.
        static let commandInput = Font.system(.title3)
        /// The descriptive line under a label or a title: a sentence rather
        /// than a fragment. One step below body, which is what keeps a
        /// settings screen from reading as a wall of equally weighted prose.
        static let detail = Font.system(.callout)

        /// **The name of a thing in a list**: a suggestion, a tab, a download,
        /// an extension, a history entry. The line you scan for.
        ///
        /// Body rather than `row`, and the reason is arithmetic. On macOS the
        /// whole scale is compressed into 10–13pt: `.subheadline` is 11 and
        /// `.caption` is 10, so a title set in `row` over a detail set in
        /// `label` were **one point apart** and weight was doing all the work
        /// of separating them — badly. Body over caption is 13 against 10,
        /// which is a step you see before you read. The weight is still here
        /// and now it is the second lever rather than the only one.
        ///
        /// The detail line under this is `label` and `.secondary`. Three
        /// levers, in DESIGN.md §5's own order: colour, weight, size.
        static let rowTitle = Font.system(.body).weight(.medium)

        /// **The headline of an empty state.**
        ///
        /// An empty state is a product screen, not an apology (§9) — it is the
        /// first thing anyone sees on a pane, and for most people on most panes
        /// it is the *only* thing they ever see. It was `.title3` medium,
        /// inline, which put it one notch over the sentence beneath it and left
        /// the screen reading as a caption with a picture on top.
        ///
        /// Two steps clear of `detail` beneath it and clear of `rowTitle` in
        /// the list it stands in for, so a full pane and an empty one do not
        /// open at the same volume.
        static let emptyTitle = Font.system(.title2).weight(.semibold)

        /// **The product saying its own name**, on the one screen whose whole
        /// job is to say it. The About panel, under the mark, and nowhere else.
        ///
        /// A display size is a claim on attention, and there are exactly two
        /// places in a browser where nothing else wants it. This is one; the
        /// other is `greeting`. (It used to say "the only thing above
        /// `.title2`", which stopped being true when `greeting` landed —
        /// corrected here rather than left to be discovered.)
        static let display = Font.system(.largeTitle).weight(.bold)

        /// **The line that opens an empty conversation**, on the one screen
        /// that is a canvas with a field on it and nothing else.
        ///
        /// Serif, and it is the only serif in the shell. Every other word in
        /// this browser is interface — a label on a control, a name in a list —
        /// and SF is what interface is set in. A conversation is not interface,
        /// it is writing, and the greeting is the browser saying so before a
        /// single word has been typed. It also does the work an icon used to
        /// do here without spending a picture on it.
        ///
        /// It is worth naming what this is in tension with: §7 commits the
        /// palette to the mark being "cold, geometric", and a serif is neither.
        /// The tension is the point. The mark is the product; the greeting is
        /// the page inviting prose, and the two are allowed to be different
        /// materials.
        /// **Spelled through `.greetingType()`, not as a `Font`**, and that is
        /// the one thing about it worth knowing before changing it.
        ///
        /// It was `.largeTitle` serif, which on macOS is twenty-six points —
        /// the top of a scale the platform compresses into ten to twenty-six,
        /// with nothing above it. In the window this browser is used in, about
        /// fourteen hundred points wide, that line took twelve per cent of the
        /// width and the whole screen read as a component drawn at its own size
        /// and then dropped into a window. A hero line is the one place in this
        /// shell that needs a size the text-style scale does not have.
        ///
        /// So it is a number — and it is **not** the raw point size §12 spends a
        /// section refusing, because it goes through `@ScaledMetric(relativeTo:
        /// .largeTitle)`: it still grows and shrinks with the system text size,
        /// it is still written once, and it is still here rather than at a call
        /// site. `Text.FieldSize` is the same exception made for a different
        /// reason, and that one really does stop following the text size.
        ///
        /// Forty rather than more: at forty, *"Ask about this page."* is about
        /// three hundred and sixty points, which still fits on one line inside
        /// the four-hundred-and-fifty-point column in the narrowest window the
        /// app opens at. Bigger is bigger in one window and two wrapped lines in
        /// the other.
        static let greetingSize: CGFloat = 40

        /// **A string that is a value rather than prose**: a permission key, a
        /// host pattern, a URL shown as a URL, a version number.
        ///
        /// Monospaced because these get compared to each other and retyped into
        /// bug reports, and proportional type makes `l` and `1`, `0` and `O`
        /// the same shape. `micro.monospaced()` was already being written by
        /// hand at three sites; this is that, named, so the fourth site cannot
        /// pick a different size for the same job.
        ///
        /// **Not for numbers that change in place** — a byte count ticking up,
        /// a match counter. Those want `.monospacedDigit()` on whatever token
        /// they already wear, so the digits stop jittering without the label
        /// beside them turning into code.
        static let mono = Font.system(.caption2, design: .monospaced)

        /// Point sizes for `CommandBarField`, which is an `NSTextField` and so
        /// wants a number where everything else takes a `Font`.
        ///
        /// The one place the type scale cannot reach. Named here, beside the
        /// scale they are the exception to, so the two sizes the shell
        /// actually uses are countable and a third cannot appear unnoticed.
        /// Neither follows the system text size: that is the cost of dropping
        /// to AppKit for focus, and it is written down rather than hidden.
        enum FieldSize {
            /// The command bar's own input: a headline you type into.
            static let command: CGFloat = 20
            /// The find bar's input. The command bar's size was taller than the
            /// strip it is drawn in there.
            static let strip: CGFloat = 13
        }
    }

    /// Sizes for a glyph that stands on its own rather than sitting inline
    /// with a line of text.
    ///
    /// Deliberately outside the type scale: a mark is a picture, and a picture
    /// does not need to grow when someone turns their text size up.
    enum Glyph {
        /// The symbol at the head of an empty state, above the text it
        /// introduces.
        static let icon: CGFloat = 34
        /// The mark, on the two screens where it *is* the screen rather than
        /// an ornament on one. Well clear of the floor ADR-0040 settles at 32
        /// rendered pixels, below which the diagonal cut survives only as a
        /// disturbance in the antialiasing.
        static let mark: CGFloat = 72
        /// A glyph that is the whole of a control's label, in a strip sized
        /// for the window's own controls rather than for a line of prose.
        /// There is no text beside it to match, so it is sized to the strip
        /// it sits in. Worn by both symbol systems while the migration runs
        /// (ADR-0116): the sidebar toggle in SF Symbols, the find bar's
        /// buttons in the licensed set.
        static let control: CGFloat = 13
    }

    /// Line weights. Outside the 4pt spacing rhythm on purpose: a stroke is
    /// not a gap, and a 4pt rule would read as a bar.
    enum Stroke {
        /// A border that should be seen and not noticed.
        static let hairline: CGFloat = 1
        /// The line a drag draws where the row is about to land. Heavier than
        /// a border because it is the whole answer to "where does this go".
        static let insertion: CGFloat = 2
    }

    enum Radius {
        static let small: CGFloat = 6
        static let medium: CGFloat = 10
        static let large: CGFloat = 16
    }

    enum Duration {
        /// Fast enough to feel instant, slow enough to be seen.
        static let quick: Double = 0.18
        // There was a `settle` at 0.28 here. Nothing referenced it, and the
        // shell has exactly two curves on purpose (§3): `entrance` for a thing
        // that arrived, `subtle` for a thing that adjusted. A third duration
        // with no consumer is not a spare part, it is the first half of an
        // inconsistency — the next person needing "a bit slower" would have
        // reached for it without knowing what it meant.
        /// How long a notice about something that already happened stays
        /// before it retreats on its own. Long enough to read twice, short
        /// enough that it is gone before it becomes furniture.
        static let linger: Double = 5
    }

    /// Panels arriving on screen come from somewhere, with a little overshoot
    /// so they feel physical rather than switched on.
    ///
    /// Raw. Nothing outside this file spells an animation this way: a curve
    /// written at a call site is a curve that has not been asked what Reduce
    /// Motion wants. `Design.Curve` and `.motion(_:value:)` are the two ways in.
    fileprivate static let entrance = Animation.spring(response: 0.34, dampingFraction: 0.82)
    fileprivate static let subtle = Animation.easeOut(duration: Duration.quick)

    /// Which of the two curves. There are two on purpose (§3) and the choice
    /// between them is not stylistic.
    ///
    /// `CaseIterable` is here for the test, and the test is the point: how many
    /// curves there are is a claim ADR-0046 makes, and a claim needs something
    /// that can disagree with it. Written out by hand in the test it could
    /// not — `[.entrance, .subtle].count == 2` is true of the array, not of
    /// this enum, and a third case left it green.
    enum Curve: CaseIterable {
        /// **Something arrived.** A thing that was not on screen is now on
        /// screen, or a thing changed place.
        case entrance
        /// **Something adjusted.** The thing is already there and only its
        /// state moved.
        case subtle
    }

    /// The two curves, and the transitions that carry a direction, with Reduce
    /// Motion already answered.
    ///
    /// **The rule, decided once here rather than per site: Reduce Motion takes
    /// away travel and overshoot, never feedback.** A panel that arrives still
    /// arrives — it fades up where it is going to live instead of flying there,
    /// and it settles rather than bouncing. A row that lights under the pointer
    /// still lights, at exactly the same speed, because that is an answer to a
    /// gesture rather than a journey; taking it away would make the interface
    /// less responsive for the person who asked for less movement, which is not
    /// what they asked for.
    ///
    /// The consequence worth naming: with Reduce Motion on, `entrance` and
    /// `subtle` become the same curve. That is correct. What separated them was
    /// the overshoot, and the overshoot is the part being declined.
    struct Motion {
        let reduced: Bool

        // There was a `static let full = Motion(reduced: false)` here, for
        // "previews and the harness". Nothing used it: a view gets its answer
        // from `@Curves`, and the tests construct the two states directly
        // because checking both is the whole point of them. Deleted on the same
        // grounds `Duration.settle` was — a spare with no consumer is the first
        // half of an inconsistency, and the next person needing "motion without
        // an environment" would reach for it and stop asking the question this
        // type exists to force.

        func callAsFunction(_ curve: Curve) -> Animation {
            switch curve {
            case .entrance: reduced ? Design.subtle : Design.entrance
            case .subtle: Design.subtle
            }
        }

        var entrance: Animation { self(.entrance) }
        var subtle: Animation { self(.subtle) }

        /// A thing coming in from an edge, which is how it says where it came
        /// from. Under Reduce Motion the edge is dropped and only the fade is
        /// left: it still arrives, it just does not travel to get here.
        func arrival(from edge: Edge) -> AnyTransition {
            reduced ? .opacity : .move(edge: edge).combined(with: .opacity)
        }

        /// A panel called up over the page rather than pushed in from an edge:
        /// the command bar, and nothing else.
        ///
        /// It comes in from just above where it lands, at 97%, anchored to its
        /// own top — which reads as a panel coming forward out of the window
        /// rather than a card sliding down a rail. `Space.snug` of travel and
        /// three points of scale is deliberately small: this opens dozens of
        /// times a day, and anything a person can see twice is something they
        /// will resent by the second week.
        var summoned: AnyTransition {
            guard !reduced else { return .opacity }
            return .scale(scale: 0.97, anchor: .top)
                .combined(with: .offset(y: -Design.Space.snug))
                .combined(with: .opacity)
        }

        /// A row appearing in or leaving a list it belongs to.
        ///
        /// Collapses rather than slides: a list makes room for a row and closes
        /// up after one, and that is the whole of what has to be shown. `.top`
        /// so the row grows out of the gap the list just opened.
        var listRow: AnyTransition {
            reduced
                ? .opacity
                : .scale(scale: 0.94, anchor: .top).combined(with: .opacity)
        }
    }

    /// Recessed fills: the "set back into the window" surface a group of rows
    /// sits on.
    ///
    /// `.quaternary` on its own is heavier than this UI wants, so every group
    /// in the shell had been written as `.quaternary.opacity(0.4)` by hand —
    /// ten times, which is the point at which a system has stopped being one
    /// and the eleventh site writes 0.35.
    enum Surface {
        /// A group of rows on the window's own background: a settings section,
        /// a list treated as one surface, the capsule around a failed address.
        /// **Now the palette's colour, not a fraction of the ink.**
        /// `.quaternary.opacity(0.4)` was a derived value, and what it derived
        /// from moved when the palette landed: with the foreground ladder set
        /// explicitly at the root, `.quaternary` stopped resolving to the
        /// system's near-neutral label colour and started resolving off `ink`,
        /// which is a saturated navy. Every settings group on every pane went
        /// two shades heavier overnight — a real change in weight that nobody
        /// asked for and no token recorded. `PaletteProposals` anticipated
        /// exactly this and stated the two swatches for it.
        static let recessed = AnyShapeStyle(Design.Palette.recessed)

        /// The second level of recess, for a group nested inside a view that
        /// already has one at full strength: an extension row's expanded
        /// permissions. Two fills at full strength stack into a visible step
        /// instead of reading as one surface set back from another, so the
        /// inner one gives way.
        ///
        /// Depth, not rank. The consent sheet's unreadable-hosts note took
        /// this to say "ranked below the groups above", and 0.1 of a
        /// translucent fill is not a rank anyone can see: it read as another
        /// group, missing its heading. Something subordinate rather than
        /// inside needs a different shape, not a lighter one.
        static let recessedInner = AnyShapeStyle(Design.Palette.recessedInner)
    }

    /// Depth, as a scale rather than as one recipe per panel.
    ///
    /// A shadow is earned by distance: only something that has left the
    /// surface it belongs to casts one (§4). Three steps, because the shell
    /// has exactly three distances — resting on the page, floating over it,
    /// and floating over a window dimmed to get out of the way. A fourth would
    /// be a value nobody could tell from its neighbours, which is what seven
    /// unrelated recipes already were.
    ///
    /// Each step darkens as it spreads: further out means a wider and heavier
    /// cast. The radii are their own numbers rather than borrowed spacing
    /// tokens — a shadow radius is a blur, not a gap, and spending
    /// `Space.regular` on one only made it look like it belonged to the
    /// rhythm.
    enum Elevation {
        struct Level {
            let opacity: Double
            let radius: CGFloat
            let y: CGFloat
        }

        /// A strip resting on the page: the find bar, the install banner. It
        /// has left the surface, but only just, so the cast stays tight enough
        /// to read as a lift rather than as a hole.
        static let resting = Level(opacity: 0.18, radius: 12, y: 4)

        /// A panel over the page: the download shelf, the session warning. A
        /// bigger surface needs a bigger cast to separate itself from a page
        /// that can be any colour at all.
        static let floating = Level(opacity: 0.22, radius: 18, y: 8)

        /// A panel over a window that has been dimmed for it: the command bar,
        /// and nothing else. Deepest, because everything behind it has already
        /// stepped back and the panel has to look like the reason why.
        static let overlay = Level(opacity: 0.28, radius: 30, y: 12)
    }

    /// Sizes that belong to a whole pane rather than to one panel inside it.
    enum Pane {
        /// The floor an empty state gets when it sits inside a scrolling pane
        /// instead of filling a window.
        ///
        /// Tall enough that the glyph, the two lines and the action read as a
        /// screen rather than as a squeezed notice; short enough that the
        /// pane's own controls above it stay in view. Every empty state inside
        /// Settings takes it, so none of them can drift forty points away from
        /// the others without the drift being visible here.
        static let emptyStateMinHeight: CGFloat = 220
    }
}

// MARK: - Spelling an animation

/// An override for the system's Reduce Motion setting.
///
/// `\.accessibilityReduceMotion` is read-only: SwiftUI publishes it and does not
/// take it back. That is right for an app and wrong for a harness, because the
/// only honest way to check that Reduce Motion removes travel is to render the
/// real views with it on and read the frames — and there is no other door.
///
/// `nil`, which is what the app always runs with, means "ask the system". The
/// override exists for `ZZMotionShots` and for previews, and nothing in
/// `Sources/` sets it.
private struct ReduceMotionOverrideKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

extension EnvironmentValues {
    var reduceMotionOverride: Bool? {
        get { self[ReduceMotionOverrideKey.self] }
        set { self[ReduceMotionOverrideKey.self] = newValue }
    }
}

extension View {
    /// Render this subtree as though Reduce Motion were on, or off. Harness
    /// only: the app reads the system setting.
    func reduceMotion(_ reduced: Bool) -> some View {
        environment(\.reduceMotionOverride, reduced)
    }
}

/// The greeting's serif, at a size that still answers to the system's text
/// size. See `Design.Text.greetingSize`.
private struct GreetingType: ViewModifier {
    @ScaledMetric(relativeTo: .largeTitle) private var size = Design.Text.greetingSize

    func body(content: Content) -> some View {
        content.font(.system(size: size, design: .serif))
    }
}

private struct CurveAnimation<V: Equatable>: ViewModifier {
    @Curves private var motion
    let curve: Design.Curve
    let value: V

    func body(content: Content) -> some View {
        content.animation(motion(curve), value: value)
    }
}

private struct MotionTransition: ViewModifier {
    @Curves private var motion
    let transition: (Design.Motion) -> AnyTransition

    func body(content: Content) -> some View {
        content.transition(transition(motion))
    }
}

/// The curves, for the few sites that *perform* a change rather than declare
/// one — a drop committing, a list scrolling to follow the keyboard.
///
/// `@Curves private var motion` in a view, then `withAnimation(motion.entrance)`.
/// One line, so no view has to remember to read the accessibility environment
/// itself and none of them can quietly forget.
@propertyWrapper
struct Curves: DynamicProperty {
    @Environment(\.accessibilityReduceMotion) private var system
    @Environment(\.reduceMotionOverride) private var override

    /// The one place the system setting and the harness override are
    /// reconciled, so nothing downstream can read half the answer.
    var wrappedValue: Design.Motion { Design.Motion(reduced: override ?? system) }
}

extension View {
    /// The only way an animation is spelled in this shell.
    ///
    /// A bare `.animation(...)` at a call site is, by construction, a curve
    /// that has not asked whether the person wants motion at all — which is the
    /// whole of what DESIGN.md §13 recorded as owed.
    func motion(_ curve: Design.Curve, value: some Equatable) -> some View {
        modifier(CurveAnimation(curve: curve, value: value))
    }

    /// Arrive from an edge, saying where you came from.
    func arrives(from edge: Edge) -> some View {
        modifier(MotionTransition(transition: { $0.arrival(from: edge) }))
    }

    /// Arrive the way the command bar arrives: forward, out of the window.
    func summoned() -> some View {
        modifier(MotionTransition(transition: { $0.summoned }))
    }

    /// Arrive the way a row arrives in the list it belongs to.
    func arrivesInList() -> some View {
        modifier(MotionTransition(transition: { $0.listRow }))
    }

}

/// A real `NSVisualEffectView`, for the one panel that floats over a web view.
///
/// SwiftUI's `.regularMaterial` blurs the SwiftUI-rendered backdrop. A
/// `WKWebView` is not part of that backdrop — it is an AppKit view hosted
/// through `NSViewRepresentable`, composited by the window server underneath
/// everything SwiftUI drew. So a SwiftUI material over a page has nothing to
/// sample and falls back to its own flat tint, which is exactly what the
/// command bar looked like: a grey slab that did not appear to be over
/// anything.
///
/// `blendingMode = .withinWindow` blends at the AppKit layer, which is where
/// the page actually is. That is the whole reason this exists, and it is why
/// nothing else in the shell uses it: the find bar, the shelf, the banner and
/// the consent sheet all float over SwiftUI, where `.regularMaterial` is
/// correct and cheaper.
///
/// The corner is masked on the layer rather than with `.clipShape`, because
/// SwiftUI clipping does not reliably reach an AppKit subview's own
/// compositing.
///
/// **Not observable offscreen.** A rasterised window has no composited backdrop
/// to blur, so a captured frame shows the material's base tint whichever of the
/// two is used. What is being relied on here is the API contract, and it is
/// written down rather than claimed as something the frames showed.
///
/// **Merge me.** `Palette.swift` is bringing a `ChromeMaterial` for the
/// sidebar, which is this with a different material and the same
/// `.withinWindow` blending and the same reason. Two wrappers around one
/// `NSVisualEffectView` is exactly the drift this file exists to prevent: when
/// both have landed, one of them takes a `material` parameter and the other
/// goes. They were written in parallel, which is why they are both here, and
/// this note is here so the second one is not discovered a month later.
struct VisualEffect: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    var radius: CGFloat = 0

    func makeNSView(context _: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .withinWindow
        // Not `.followsWindowActiveState`: this panel is the reason the window
        // behind it stepped back, and a palette that goes flat because focus
        // moved is a palette that looks broken at the moment it is being used.
        view.state = .active
        view.wantsLayer = true
        view.layer?.masksToBounds = true
        apply(to: view)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context _: Context) {
        apply(to: view)
    }

    private func apply(to view: NSVisualEffectView) {
        view.material = material
        view.layer?.cornerRadius = radius
        view.layer?.cornerCurve = .continuous
    }
}

/// What a control does under the pointer and under the finger.
///
/// macOS gives `.plain` nothing at all: a sidebar row, a space chip and the new
/// tab button were all inert until the click had already happened, which is the
/// one moment feedback is too late to be feedback. The dip is small on purpose —
/// this is an acknowledgement, not an event.
///
/// Reduce Motion keeps the dimming and drops the scale: the answer to "did it
/// hear me" survives, the travel does not.
struct PressFeedback: ButtonStyle {
    @Curves private var motion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(motion.reduced || !configuration.isPressed ? 1 : 0.97)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(Design.subtle, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressFeedback {
    static var pressable: PressFeedback { PressFeedback() }
}

extension View {
    /// Cast the shadow of one elevation step.
    ///
    /// The only way a shadow is spelled in this shell: a `.shadow(...)`
    /// written out at a call site is, by construction, a depth that is not on
    /// the scale.
    ///
    /// **`compositingGroup()` is load-bearing and is the whole reason to read
    /// this.** SwiftUI's `.shadow` is not a shadow cast by a panel — it is a
    /// style that reaches every leaf underneath it, so a card with a label and a
    /// chip on it casts *three* shadows: one for the card and one behind each
    /// piece of text, at the same radius. Photographed at the composer, every
    /// glyph sat in its own grey haze and the chip had a halo half again its own
    /// size. Flattening the subtree first makes the panel one thing that casts
    /// one shadow, which is what every call site here already believed it was
    /// asking for.
    func elevation(_ level: Design.Elevation.Level) -> some View {
        compositingGroup()
            .shadow(color: .black.opacity(level.opacity), radius: level.radius, y: level.y)
    }

    /// The line that opens an empty conversation.
    ///
    /// A modifier rather than a `Font` because the size is a `@ScaledMetric`,
    /// which only exists inside a view — and putting it in one view would be a
    /// number outside the scale in the file the scale exists to keep it out of.
    /// `sectionHeading()` is the same shape for the same reason.
    func greetingType() -> some View {
        modifier(GreetingType())
    }

    /// An uppercase group heading: the type token and the letter-spacing that
    /// always comes with it, in one place.
    ///
    /// Uppercase closes letters up against each other, so the tracking is not
    /// decoration — it is what keeps the word legible at caption size. Applied
    /// by hand at four sites it had already drifted to 0.5 at one of them.
    /// Colour is deliberately left out: the consent sheet paints its headings
    /// by risk tier, and a heading that carried its own colour could not.
    ///
    /// **The tracking is the token's whole reason to exist**, and it was worth
    /// re-asking whether it earns it. It does: at caption size, uppercase and
    /// semibold, the letters close up and the word turns into a shape. What
    /// this heading must *not* do is compete — the rows under it are the pane,
    /// and a heading that outweighed them would be furniture. Small, spaced and
    /// quiet is a species of its own, which is the job. It ranks by being
    /// *different*, where `rowTitle` ranks by being bigger.
    func sectionHeading() -> some View {
        font(Design.Text.sectionTitle)
            .textCase(.uppercase)
            .tracking(0.6)
    }
}

/// A settings row: label and description on the left, control on the right.
///
/// The description is what stops a settings screen being a wall of nouns you
/// have to guess at.
///
/// The title takes `rowTitle` rather than the default body it used to draw at.
/// Body over `detail` is 13 against 12 — one point — so a pane of six settings
/// was twelve lines of near-identical type and the eye had nothing to land on.
/// The weight is what separates the thing from the sentence about the thing.
struct SettingRow<Control: View>: View {
    let title: String
    var description: String?
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Design.Space.regular) {
            VStack(alignment: .leading, spacing: Design.Space.line) {
                Text(title).font(Design.Text.rowTitle)
                if let description {
                    Text(description)
                        .font(Design.Text.detail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Design.Space.regular)
            control
        }
        .padding(.vertical, Design.Space.hair)
    }
}

/// The control a settings row wears when the answer is yes or no.
///
/// Exists because a bare `Toggle` on macOS is a checkbox, and a checkbox with
/// no label pinned to the right margin is not a pattern this platform has — a
/// checkbox carries its own label, a switch is what sits opposite one. An
/// unchecked box is also nearly nothing: an empty hairline square on a
/// recessed fill, which in dark mode is a `#2f2f2f` outline on `#2b2b2b` and
/// reads as blank on the pane where whether a thing is on matters most.
///
/// The label is taken rather than inferred because `labelsHidden()` leaves
/// VoiceOver with a switch for nothing; the row's title says it on screen, and
/// this is how it gets said aloud.
struct SettingSwitch: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle("", isOn: $isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .accessibilityLabel(label)
    }
}

/// A titled group of rows, the way macOS settings are shaped.
struct SettingSection<Content: View>: View {
    let title: String
    var footnote: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.snug) {
            Text(title)
                .sectionHeading()
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: Design.Space.snug) {
                content
            }
            .padding(Design.Space.regular)
            // Every group is the width of the column, not the width of what is
            // in it. Without this a section holding only a radio group is a
            // third the width of the one beside it holding a `SettingRow`,
            // whose `Spacer` pushes it wide — two cards on the same pane that
            // look like two different kinds of thing for no reason anyone
            // could name.
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Design.Surface.recessed, in: RoundedRectangle(cornerRadius: Design.Radius.medium))

            if let footnote {
                Text(footnote)
                    .font(Design.Text.label)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The empty state of a list, treated as a screen rather than an apology.
///
/// The glyph is a view rather than a symbol name because one empty state — the
/// browser with nothing open — is headed by the mark instead of an icon, and
/// two near-identical empty-state layouts would drift apart within a month.
///
/// The headline is `emptyTitle` and the gap under it is `tight` rather than
/// `hair`. Both changed for the same reason: at `.title3` medium the headline
/// was a step and a half over its own message and the screen read as a caption
/// with a picture on it, and 4pt under a bigger line is not a gap, it is a
/// collision. `hair` is the space between a row title and its detail; this is
/// two blocks on a screen, and they are not the same distance.
struct EmptyState<Glyph: View, Action: View>: View {
    @ViewBuilder var glyph: Glyph
    let title: String
    let message: String
    @ViewBuilder var action: Action

    var body: some View {
        VStack(spacing: Design.Space.regular) {
            glyph

            VStack(spacing: Design.Space.tight) {
                Text(title).font(Design.Text.emptyTitle)
                Text(message)
                    .font(Design.Text.detail)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
            // The action is the third rank on this screen, not the second line
            // of the second. Carried here rather than in the stack's spacing so
            // the glyph does not drift away from the words it introduces.
            .padding(.bottom, Design.Space.tight)

            action
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Design.Space.section)
    }
}

extension EmptyState where Glyph == EmptyStateSymbol {
    /// The usual case: an SF Symbol over the text.
    init(icon: String, title: String, message: String, @ViewBuilder action: () -> Action) {
        self.init(
            glyph: { EmptyStateSymbol(name: icon) },
            title: title,
            message: message,
            action: action
        )
    }
}

/// The symbol an empty state wears when it does not have a mark to wear.
struct EmptyStateSymbol: View {
    let name: String

    var body: some View {
        Image(systemName: name)
            .font(.system(size: Design.Glyph.icon, weight: .light))
            .foregroundStyle(.tertiary)
    }
}
