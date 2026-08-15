import AppKit
import SwiftUI
import WebKit
import Zer0Core

/// The row of extension buttons.
///
/// **Where it is, and the argument.** ADR-0010 refuses a strip over the page,
/// and a row of extension icons above the content is precisely the thing it
/// refuses. It is not what this is. The sidebar is *beside* the page, its width
/// is already spent (ADR-0014), and a row inside it costs the page nothing —
/// ADR-0010's test, *does it pay for itself on every page*, is a test for things
/// that charge the page, and this charges it zero. What it charges is sidebar
/// height, next to the space chips, which are the other row of small
/// always-available controls and the reason this reads as furniture rather than
/// as a toolbar that wandered in.
///
/// When the sidebar is away it travels to `WindowChrome`, which is where the
/// sidebar's own controls already go. ADR-0068 has the whole argument and the
/// rule that keeps that strip from becoming a junk drawer.
///
/// **What is drawn here and what is not.** Which extensions appear and in what
/// order is the core's answer, read whole from `model.pinnedExtensions` — the
/// row must not filter, because ⇧⌘1..⇧⌘9 count through the same list and a view
/// that dropped one would leave every chord after it pointing somewhere else.
/// Everything below is look: the size of the box, the corner it rounds to, the
/// wash under the pointer, which edge the popover comes out of.
struct ExtensionActionBar: View {
    @Environment(BrowserModel.self) private var model
    /// Which window this row belongs to, so a popup asked for by an extension
    /// lands in the window in front rather than in all of them at once.
    @Environment(\.browserWindowId) private var windowId

    /// What is legible on the surface this row sits on.
    ///
    /// Passed in rather than read, because the two places this appears have
    /// different answers: the sidebar is a surface we chose, and the window
    /// strip is whatever colour the page declared (ADR-0047).
    let ink: Color
    /// Which way a popup opens. The sidebar is down the left edge so its popups
    /// come out to the right; the strip is along the top so its come down.
    let popoverEdge: NSRectEdge

    /// Sizes that belong to this row rather than to the whole UI, so they are
    /// named here instead of pretending to be design tokens.
    enum Metrics {
        /// The hit area of one button. The same square the new-space button
        /// takes, so this row and the space bar under it have one rhythm rather
        /// than nearly one.
        static let target: CGFloat = Design.Space.loose
        /// The box a stranger's artwork is drawn inside.
        ///
        /// Every icon gets the same one, and it is smaller than the target: a
        /// full-bleed square logo and a small centred glyph then read at the
        /// same weight, and the difference between the two is a margin rather
        /// than a size. This is the whole of what makes a row of foreign
        /// pictures look like one row.
        static let icon: CGFloat = 18
        /// How far a badge may run before it truncates. Four figures of a
        /// count, and then the extension is saying more than a badge can hold.
        static let badgeWidth: CGFloat = 22
        /// Beyond this, in points on a side, it is not an icon — it is an image
        /// somebody put in the icon slot. Comfortably past a @3x rendering of
        /// the largest icon any manifest declares, and small enough that
        /// decoding one cannot be an attack (ADR-0022).
        static let absurdIcon: CGFloat = 1024
    }

    var body: some View {
        // Nothing pinned draws nothing at all. An empty strip is chrome that
        // does not pay for itself, and this row's whole claim to its space is
        // that it only takes it when there is something in it.
        if !model.pinnedExtensions.isEmpty {
            content
        }
    }

    private var content: some View {
        // Horizontal, and scrolling, for the reason the space chips scroll:
        // the number of extensions is not bounded by the width of a sidebar,
        // and squeezing is how six of them become six identical smudges.
        ScrollView(.horizontal) {
            HStack(spacing: Design.Space.hair) {
                ForEach(Array(model.pinnedExtensions.enumerated()), id: \.element.id) { index, ext in
                    ExtensionActionButton(
                        extension: ext,
                        // 1-based, as printed on the keyboard and as the core
                        // counts. Only the first nine have a chord; the rest
                        // are reachable with the pointer, and saying so is
                        // better than printing a chord that does nothing.
                        chordIndex: index < 9 ? UInt8(index + 1) : nil,
                        ink: ink,
                        popoverEdge: popoverEdge,
                        isKeyWindow: windowId == model.snapshot.keyWindow
                    )
                }
            }
        }
        .scrollIndicators(.hidden)
        // Without this the scroll view claims every point it is offered and the
        // row eats the list above it — the same defect the space bar has a line
        // about.
        .fixedSize(horizontal: false, vertical: true)
        // A button arriving or leaving is a thing appearing where there was
        // none, which is what `entrance` is for.
        .motion(.entrance, value: model.pinnedExtensions.count)
    }
}

/// One extension's button.
///
/// Everything it shows — the picture, the name, the badge — is read fresh from
/// `WKWebExtensionContext.action(for:)` as it draws, against the tab in front.
/// Nothing is held. An action is per-tab and moves as you browse, and a cached
/// icon is a claim about the page you are on that stopped being true silently.
private struct ExtensionActionButton: View {
    @Environment(BrowserModel.self) private var model

    let `extension`: InstalledExtension
    let chordIndex: UInt8?
    let ink: Color
    let popoverEdge: NSRectEdge
    let isKeyWindow: Bool

    @State private var hovering = false
    @State private var anchor = PopoverAnchor.Box()

    private typealias Metrics = ExtensionActionBar.Metrics

    /// The action as it stands for the tab in front, or `nil` when the engine
    /// has no context for this extension.
    ///
    /// Reading `model.extensionActionRevision` is not incidental: it is what
    /// makes SwiftUI ask again when WebKit says a badge moved. Nothing else in
    /// this expression changes when a count goes from 2 to 3.
    private var action: WKWebExtension.Action? {
        _ = model.extensionActionRevision
        return model.extensions?.action(for: `extension`.id, tab: model.snapshot.activeTab)
    }

    /// Whether WebKit could not start this extension, asked fresh as we draw.
    ///
    /// `extensionActionRevision` is read for the same reason `action` reads it:
    /// the error arrives after the row is already on screen, and nothing else in
    /// this expression changes when it does.
    private var isBroken: Bool {
        _ = model.extensionActionRevision
        return model.extensions?.backgroundContentFailed(`extension`.id) == true
    }

    var body: some View {
        Button {
            // An extension whose background content never started has nothing
            // behind this button. Asking WebKit for its popup anyway is how you
            // get a panel that spins forever and never says why — measured on
            // 1Password, which dies reaching for an API WebKit does not have.
            // So the press goes where the sentence explaining it is, rather than
            // opening an interface that cannot answer (ADR-0072).
            guard !isBroken else {
                model.perform(.showExtensions)
                return
            }
            model.extensions?.performAction(
                for: `extension`.id,
                tab: model.snapshot.activeTab
            )
        } label: {
            artwork
                .frame(width: Metrics.target, height: Metrics.target)
                .background(
                    RoundedRectangle(cornerRadius: Design.Radius.small, style: .continuous)
                        // A wash of whatever ink this surface reads in, rather
                        // than a stated grey: over a page that declared
                        // near-black this has to lighten and over one that
                        // declared near-white it has to darken, and the ink
                        // already knows which way that is.
                        .fill(ink.opacity(hovering ? 0.14 : 0))
                )
                .overlay(alignment: .topTrailing) {
                    // The mark lands seconds after the row is first drawn, so
                    // it is a state changing rather than a thing arriving.
                    corner.motion(.subtle, value: isBroken)
                }
                .contentShape(RoundedRectangle(cornerRadius: Design.Radius.small))
        }
        .buttonStyle(.pressable)
        .onHover { hovering = $0 }
        .motion(.subtle, value: hovering)
        .background { PopoverAnchor(box: anchor) }
        .help(tooltip)
        .accessibilityLabel(accessibilityLabel)
        .contextMenu { menu }
        // An extension asking for its own popup, and a press, arrive by the
        // same road: `performAction` goes out to WebKit and comes back as this.
        // One path, so a popup opened by a keystroke lands exactly where a
        // popup opened by a click lands.
        .onChange(of: model.popupRequest) { _, request in
            guard isKeyWindow, request?.extensionId == `extension`.id else { return }
            model.clearExtensionPopupRequest()
            showPopup()
        }
    }

    // MARK: - A stranger's artwork, on our surface

    /// The icon, or the shape of one when there is not a usable icon to draw.
    ///
    /// Three ways an icon from an untrusted package fails, and all three land in
    /// the same place rather than on screen (ADR-0022, ADR-0024): the engine
    /// could not load it, it loaded as nothing, or it is not an icon at all.
    /// A row with a hole in it is worse than a row with a generic mark in it —
    /// the hole reads as the browser having lost the extension.
    @ViewBuilder
    private var artwork: some View {
        if let icon = usableIcon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                // `scaledToFit` inside a fixed box, never the image's own size:
                // what a package declares its icon to be is a number from a
                // stranger, and a view that sized itself from it would let one
                // extension decide how tall the sidebar's controls are.
                .scaledToFit()
                .frame(width: Metrics.icon, height: Metrics.icon)
        } else {
            Image(systemName: "puzzlepiece.extension.fill")
                .font(.system(size: Metrics.icon * 0.8))
                .foregroundStyle(ink.opacity(0.55))
                .frame(width: Metrics.icon, height: Metrics.icon)
        }
    }

    /// The action's icon, once it has been established that it is one.
    ///
    /// Asked for at the size it is drawn at, so the engine picks the best
    /// representation the package ships rather than us scaling whichever one
    /// happened to be first.
    private var usableIcon: NSImage? {
        guard let icon = action?.icon(for: CGSize(width: Metrics.icon, height: Metrics.icon))
        else { return nil }

        let size = icon.size
        guard size.width > 0, size.height > 0 else { return nil }
        guard size.width <= Metrics.absurdIcon, size.height <= Metrics.absurdIcon else {
            // Refused rather than scaled down. Drawing it would mean decoding
            // it first, and the cost of decoding is the whole of the problem —
            // a package is allowed 64 MiB in one file (ADR-0022) and that is a
            // great many pixels.
            return nil
        }
        return icon
    }

    /// The one mark this button is allowed in its corner.
    ///
    /// The extension's badge, unless WebKit could not start the extension — in
    /// which case the badge is a number from a process that never ran, and the
    /// only honest thing to put there is that it is not running. One slot and
    /// not two: a warning wearing a count beside it would be the row saying
    /// both "this is broken" and "this has three things waiting for you".
    @ViewBuilder
    private var corner: some View {
        if isBroken {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(Design.Text.micro)
                .foregroundStyle(Design.Palette.warning)
                .offset(x: Design.Space.hair, y: -Design.Space.line)
        } else {
            badge
        }
    }

    /// What the extension says is waiting on this page.
    ///
    /// **Its words, not ours.** The string is printed as it arrives, and the
    /// only thing done to it is a ceiling on how far it may run — an extension
    /// is free to put a sentence in a badge and a row that grew to fit one
    /// would be a row one extension decided the shape of. The truncation is
    /// visible, which is the honest way to say there is more than fits.
    ///
    /// The colour is ours and has to be: `WKWebExtensionAction` does not expose
    /// the badge colour a manifest asks for, so there is nothing to honour. The
    /// accent is right because a badge is an attention mark rather than a
    /// status claim — it is not the browser saying anything is wrong, and a
    /// palette status colour here would rank something nobody measured
    /// (ADR-0018).
    @ViewBuilder
    private var badge: some View {
        if let text = action?.badgeText, !text.isEmpty {
            Text(text)
                .font(Design.Text.micro.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(Design.Palette.onAccent)
                .padding(.horizontal, Design.Space.hair)
                .frame(minWidth: Design.Space.snug, maxWidth: Metrics.badgeWidth)
                .background(Capsule().fill(.tint))
                .offset(x: Design.Space.hair, y: -Design.Space.line)
                // A count changing is a thing already on screen adjusting, not a
                // thing arriving.
                .motion(.subtle, value: text)
        }
    }

    // MARK: - The popup

    /// Put the extension's own interface on screen, hanging off this button.
    ///
    /// `popupPopover` rather than the bare `popupWebView`: the popover WebKit
    /// hands back sizes itself to the popup's content, and an extension popup is
    /// whatever height its author wrote. A fixed frame around one is a password
    /// manager with its unlock button cut off.
    ///
    /// `.transient` is the behaviour a popup wants — Esc closes it, clicking the
    /// page closes it, and neither costs anything you had typed anywhere else.
    private func showPopup() {
        guard let action, action.presentsPopup,
              let popover = action.popupPopover,
              let view = anchor.view, view.window != nil
        else { return }

        popover.behavior = .transient
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: popoverEdge)
    }

    // MARK: - Words

    /// The extension's own label for what this does right now, which is per-tab
    /// like everything else about an action, with the chord that presses it.
    ///
    /// Read off the keymap rather than written as "⇧⌘1", so rebinding does not
    /// leave a lie behind in a tooltip.
    private var tooltip: String {
        let name = action?.label.isEmpty == false ? action!.label : `extension`.manifest.name
        // Before the press, not after it. A button that opens nothing and only
        // then explains itself has already wasted the gesture.
        if isBroken {
            return "\(name) is not running — WebKit could not start its background page."
        }
        guard let chordIndex,
              let chord = model.chord(for: .runPinnedExtension(index: chordIndex))
        else { return name }
        return "\(name) (\(chord.displayString))"
    }

    /// Spoken, the badge is not decoration — it is the only thing saying there
    /// is something here to deal with.
    private var accessibilityLabel: String {
        let name = `extension`.manifest.name
        // Said rather than only drawn: the warning tint below is the sighted
        // half of this, and a state only one of the two carries is a state
        // somebody is not told about.
        if isBroken { return "\(name), not running" }
        guard let badge = action?.badgeText, !badge.isEmpty else { return name }
        return "\(name), \(badge)"
    }

    @ViewBuilder
    private var menu: some View {
        // The gesture people already have. Right-clicking an icon to take it
        // off the row is what every browser with a row of icons has taught, and
        // inventing something else here would be inventing for its own sake.
        Button("Hide Button") {
            model.setExtensionPinned(`extension`.id, false)
        }
        Divider()
        Button("Manage Extensions…") {
            model.perform(.showExtensions)
        }
    }
}

/// A view that exists only so an `NSPopover` has something real to point at.
///
/// SwiftUI has a popover of its own and it is the wrong one here: the popover
/// WebKit hands back is already built, already loaded and already sized to the
/// extension's own content, and re-hosting its web view inside a SwiftUI
/// popover means picking a size for somebody else's interface. So the popover
/// stays AppKit's, and this is the one AppKit thing it needs — a view at the
/// button's own position, which is the difference between a popup that came out
/// of the thing you pressed and a panel that appeared.
private struct PopoverAnchor: NSViewRepresentable {
    @MainActor
    final class Box {
        weak var view: NSView?
    }

    let box: Box

    func makeNSView(context _: Context) -> NSView {
        let view = NSView()
        box.view = view
        return view
    }

    func updateNSView(_ view: NSView, context _: Context) {
        box.view = view
    }
}
