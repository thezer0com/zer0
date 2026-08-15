import AppKit
import SwiftUI
import Zer0Core

/// Field access, not policy.
///
/// A uniffi record carries no methods across the bridge, and asking the core
/// "is this tab in the split" once per sidebar row would be an FFI crossing to
/// answer a comparison. Anything that *decides* something — where the divider
/// may go, when a split ends — stays in Rust.
extension Split {
    func contains(_ tab: TabId) -> Bool {
        leading == tab || trailing == tab
    }

    /// The pane that is not `tab`, or nil if `tab` is not in this split.
    func other(_ tab: TabId) -> TabId? {
        switch tab {
        case leading: trailing
        case trailing: leading
        default: nil
        }
    }
}

/// One tab's area: the page, or the explanation for why there is no page.
///
/// Extracted so a pane and the whole window are the same view rather than two
/// that drift. The web view it hosts is owned by `EngineHost` and merely
/// reparented, so moving a page into a split does not reload it.
struct PageArea: View {
    @Environment(BrowserModel.self) private var model
    let tab: TabId

    var body: some View {
        content
            .background(.background)
    }

    @ViewBuilder
    private var content: some View {
        if let error = state?.lastError {
            // A failed page has nothing worth showing, so the explanation takes
            // the whole area rather than floating over a blank web view. The
            // core clears the error the moment another attempt starts, so this
            // can never linger over a page that came back.
            NavigationErrorScreen(
                error: error,
                // What was actually wrong with the certificate, when a
                // certificate is what stopped it. `nil` for every other kind of
                // failure, and for a certificate we could not measure — in both
                // of which the screen falls back to what it always said
                // (ADR-0094).
                certificate: model.certificateReport,
                onTrust: { origin, fingerprint in
                    model.trustThisCertificate(
                        tab: tab, origin: origin, fingerprint: fingerprint
                    )
                },
                retry: { model.send(.reload(tab: tab, fromOrigin: false)) }
            )
        } else if let address = internalAddress(url: state?.url ?? "") {
            // One of the browser's own pages. Drawn natively, over the tab's own
            // web view rather than in it — the web view was created with the tab
            // and is never navigated, because WebKit is never told this scheme
            // exists (ADR-0054).
            //
            // No loading bar: there was nothing to load. The core commits an
            // internal address the moment it is asked for, so a progress
            // indicator here would be a claim about a wait that never happened
            // (ADR-0018).
            InternalPageArea(address: address, tab: tab)
        } else if let webView = model.engine.webView(for: tab) {
            WebViewContainer(webView: webView)
                .id(tab)
                .overlay(alignment: .top) { loadingBar }
        }
    }

    private var state: BrowserTab? {
        model.snapshot.tabs.first { $0.id == tab }
    }

    /// The only thing allowed to sit on top of a page, and only while loading.
    ///
    /// Two points, and that is a decision rather than an oversight: it is
    /// `Stroke.insertion`, the weight this shell gives a line that is the whole
    /// answer to a question. Anything heavier is a bar across the top of every
    /// page you open, which ADR-0010 exists to prevent, and the sidebar row is
    /// already carrying a spinner for the same tab.
    ///
    /// What was wrong with it was not the height. It appeared and vanished in a
    /// single frame — on a page that loads in 300ms that reads as a grey seam
    /// flickering at the top of the window, which is worse than nothing. It
    /// carried `.transition(.opacity)` and nothing bound an animation to
    /// `loadingComplete`, so the fade had been written and had never run. Now
    /// it fades on both edges, and a fast load is a glow rather than a twitch.
    ///
    /// The animation lives on a wrapper rather than on the overlay's parent
    /// deliberately: the parent hosts a `WKWebView`, and an animation modifier
    /// over a live web view is how you end up resizing one every frame.
    private var loadingBar: some View {
        ZStack(alignment: .top) {
            if let state, !state.loadingComplete {
                ProgressView()
                    .progressViewStyle(.linear)
                    .frame(height: Design.Stroke.insertion)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .motion(.subtle, value: state?.loadingComplete ?? true)
    }
}

/// The page area: one page, or two side by side.
///
/// One view for both cases rather than two, and that is what makes the
/// transition work. Entering a split has to *show* the second page arriving;
/// if the whole area were swapped for a different view, SwiftUI would
/// cross-fade and both pages would appear to teleport into half-width columns,
/// which reads as a rendering fault. Here the leading pane is the same view
/// before and after, and only the divider and the second pane are inserted —
/// which is what their transition is for.
///
/// What that buys, rasterised frame by frame under `Design.entrance` slowed
/// twelvefold: the second pane genuinely travels, entering at the window's
/// trailing edge and sweeping to its half with the spring's overshoot before
/// settling. It does not cross-fade.
///
/// What it does not buy, from the same frames: **the leading pane's width does
/// not animate — it snaps to its half in one frame.** Three formulations were
/// tried and none moved it (`.animation` on the stack keyed on `split != nil`,
/// `.animation` bound to the width value itself, and both against a four-second
/// curve so nothing could be missed); in every captured frame the leading edge
/// was already at its final position. Written down rather than asserted away:
/// the sentence that used to stand here claimed the width animated, and it
/// never did. The arriving pane is what carries the motion today.
///
/// **That paragraph is now itself in doubt, and for a reason worth writing
/// down.** Both of those findings came from rasterised frames, and
/// `cacheDisplay` on an `NSHostingView` draws the *model* layer: a view part
/// way through a transform-based transition rasterises where it is going to be,
/// not where it is. `ZZMotionShots` establishes that directly — five probes of
/// the command bar's arrival, including a plain rectangle with no AppKit in it
/// and one driven by an explicit `withAnimation`, all captured as "never
/// moved", while `onGeometryChange` on the same view across the same frames
/// showed it travelling. So "the leading pane's width does not animate" may be
/// true or may be the same false negative; it has not been re-measured with
/// geometry. What is *not* in doubt is that the sentence it replaced — the one
/// claiming the width animated — was written without measuring anything at all.
///
/// The pair itself is decided in the core: which tabs, which one has the
/// keyboard, how far the divider may travel. Everything here is how that looks.
struct PageStack: View {
    @Environment(BrowserModel.self) private var model
    /// The tab in the leading pane, which is the only pane when `split` is nil.
    let leading: TabId
    let split: Split?

    /// Where the divider is being dragged to, before it is committed.
    ///
    /// Local so the divider tracks the pointer at frame rate without a round
    /// trip through the reducer for every pixel. The value is still the core's
    /// to judge: `clampSplitRatio` decides how far it may go, here and on
    /// release, so what you see mid-drag is what you get.
    @State private var dragging: Double?
    /// Where the divider stood when the drag began. `DragGesture` reports
    /// translation from the start of the gesture, so this is what it is
    /// translation *from*.
    @State private var anchor: Double?
    @State private var hoveringDivider = false
    /// Clicking into a page has to move the keyboard to that pane. A web view
    /// swallows the click before any SwiftUI gesture sees it, so the window is
    /// asked what it hit instead.
    @State private var clickMonitor: Any?

    /// Sizes that belong to the split rather than to the whole UI, so they are
    /// named here instead of pretending to be design tokens.
    private enum Metrics {
        /// The gap between the two panes, and the strip the pointer has to
        /// land in to move it.
        ///
        /// One dimension doing three jobs, which is why it is the widest gap
        /// on the screen: the space that makes the pair read as two cards, the
        /// target a drag has to land in, and the clearance the focused pane's
        /// halo needs so the grip does not end up glued to whichever pane is
        /// lit. At `Space.tight` none of the three had room — 8pt is at the
        /// bottom of what a thin splitter runs on this platform, and rendered,
        /// the halo filled the whole gap on one side of the grip and left the
        /// other empty. Nothing is drawn in here, so it cannot read as a third
        /// column however wide it gets; it can only read as air.
        ///
        /// `nonisolated` because geometry is measured off the main actor, the
        /// same reason the sidebar's coordinate spaces are.
        nonisolated static let gutter: CGFloat = Design.Space.regular

        /// The handle in the middle of the gutter: the part that says the gap
        /// can be moved.
        ///
        /// A line down the whole gutter could not say it. It was the same mark
        /// the panes wear as a border — three hairlines a few points apart,
        /// and the one you can drag differed from the two you cannot by two
        /// values out of 255. A short bar is a *different kind of object*, so
        /// it does not have to win a contrast argument against a border to be
        /// told apart from one.
        static let gripWidth: CGFloat = Design.Space.hair
        /// Long enough to read as a handle rather than as a speck; short
        /// enough to stay a mark in the gap rather than becoming the line it
        /// replaced.
        static let gripLength: CGFloat = 44

        /// The focused pane's halo: what says "this one is lit" where a shadow
        /// cannot.
        ///
        /// A black cast is a depth cue that needs a surface lighter than the
        /// shadow to land on. In dark mode the window is `#1E1E1E` and the
        /// cast moved it by two values out of 255 — half the focus signal was
        /// drawing nothing at all. Focus is a light source rather than an
        /// object (§4, the same argument the insertion line's glow makes), so
        /// it glows in the accent instead, and light is legible on a dark
        /// background and a pale one alike.
        ///
        /// Drawn as concentric hairlines at a falling opacity rather than as a
        /// blurred stroke: a blur is rasterised inside the view's own bounds,
        /// so a glow made that way is cut off at exactly the edge it has to
        /// escape — rendered, it produced nothing at all. Four rings make the
        /// same falloff out of geometry, which nothing clips.
        ///
        /// It stops at four points out. Further and it reaches the other pane
        /// across the gutter, at which point the halo is telling you about a
        /// pane that is not the one it is touching.
        static let halo: [Double] = [0.42, 0.26, 0.14, 0.06]
    }

    private var ratio: Double { dragging ?? split?.ratio ?? 1 }

    var body: some View {
        GeometryReader { geometry in
            // A single page runs to the edges of the window, as it always has.
            // Two pages get a margin, so the pair reads as two things rather
            // than one page with a line down it. Animating between the two is
            // half of what makes the split look like it opened.
            let inset = split == nil ? 0 : Design.Space.tight
            let area = max(0, geometry.size.width - inset * 2)
            let usable = split == nil ? area : max(0, area - Metrics.gutter)

            HStack(spacing: 0) {
                pane(leading)
                    .frame(width: split == nil ? area : usable * ratio)

                if let split {
                    divider(over: usable)

                    pane(split.trailing)
                        .frame(width: max(0, usable * (1 - ratio)))
                        // The second page comes in from the edge it will
                        // occupy, so the eye follows it there instead of
                        // finding it already arrived.
                        .arrives(from: .trailing)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(inset)
        }
        .background(.background)
        .onAppear { watchForClicks() }
        .onDisappear { stopWatchingForClicks() }
    }

    /// One side.
    ///
    /// Which pane has the keyboard is said twice and quietly: a hairline in the
    /// accent colour where the other side has a plain one, and a halo in the
    /// same colour bleeding out from under its edge. Neither shouts, and
    /// together they read before anyone goes looking for a border. On a single
    /// page there is nothing to tell apart, so none of it is drawn.
    ///
    /// Both signals are light rather than shade, because the thing they have to
    /// survive is a near-black window: at `#1E1E1E` a pane, the gutter and the
    /// window behind them are all the same colour, and every mark that
    /// separates them has to make its own contrast rather than borrow the
    /// page's.
    @ViewBuilder
    private func pane(_ tab: TabId) -> some View {
        let isSplit = split != nil
        let focused = isSplit && model.snapshot.activeTab == tab
        let shape = RoundedRectangle(
            cornerRadius: isSplit ? Design.Radius.medium : 0,
            style: .continuous
        )

        paneContent(tab)
            .clipShape(shape)
            // Behind the pane, whose fill is opaque, so only the half that
            // spreads past the edge survives: a halo around it rather than a
            // glow inside it.
            .background {
                if focused {
                    ZStack {
                        ForEach(Array(Metrics.halo.enumerated()), id: \.offset) { step, opacity in
                            shape
                                .strokeBorder(.tint.opacity(opacity), lineWidth: Design.Stroke.hairline)
                                .padding(-CGFloat(step + 1))
                        }
                    }
                }
            }
            .overlay {
                if isSplit {
                    shape.strokeBorder(
                        focused ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary),
                        lineWidth: Design.Stroke.hairline
                    )
                }
            }
            .motion(.subtle, value: focused)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(model.snapshot.tabs.first { $0.id == tab }?.displayTitle ?? "Page")
            .accessibilityAddTraits(focused ? [.isSelected] : [])
    }

    @ViewBuilder
    private func paneContent(_ tab: TabId) -> some View {
        if split != nil, isBlank(tab) {
            // Half a window of nothing reads as a bug. A pane that has not been
            // pointed anywhere says so, and says how to point it. Only inside a
            // split: on its own, a blank tab has the command bar over it and
            // nothing to explain.
            EmptyPane(tab: tab)
        } else {
            PageArea(tab: tab)
        }
    }

    /// A pane that has never been anywhere and is not on its way anywhere.
    private func isBlank(_ tab: TabId) -> Bool {
        guard let state = model.snapshot.tabs.first(where: { $0.id == tab }) else { return true }
        return state.url == nil && state.pendingUrl == nil && state.lastError == nil
    }

    // MARK: - The divider

    /// The gap between the panes, and the grip that says it moves.
    ///
    /// The gap itself is left empty. A rule down it would be a third hairline
    /// between the two the panes already wear, and a seam is not a control —
    /// what carries the affordance is the grip: a short rounded bar, centred,
    /// shaped like nothing else on the screen. It is the whole gutter that
    /// drags, not just the bar, which is why the pointer changes over all of
    /// it.
    private func divider(over width: CGFloat) -> some View {
        let live = hoveringDivider || dragging != nil

        return Rectangle()
            .fill(.clear)
            .frame(width: Metrics.gutter)
            .overlay {
                Capsule()
                    .fill(live ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .frame(width: Metrics.gripWidth, height: Metrics.gripLength)
            }
            .contentShape(Rectangle())
            // Double-click puts it back down the middle, the way every split
            // divider on this platform does.
            .onTapGesture(count: 2) { model.setSplitRatio(defaultSplitRatio()) }
            .gesture(drag(over: width))
            .onHover { inside in
                hoveringDivider = inside
                // The pointer says the divider can be moved before anyone
                // tries to move it.
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .motion(.subtle, value: live)
            .transition(.opacity)
            .accessibilityLabel("Split Divider")
    }

    private func drag(over width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                guard width > 0, let split else { return }
                // Translation rather than location, because `.global` puts the
                // origin at the window and the panes do not start there — and
                // measured from where the divider stood when the drag began,
                // because translation is cumulative. Adding it to the running
                // value instead would make the divider accelerate away from
                // the pointer.
                let from = anchor ?? split.ratio
                anchor = from
                dragging = clampSplitRatio(ratio: (from * width + value.translation.width) / width)
            }
            .onEnded { _ in
                if let dragging { model.setSplitRatio(dragging) }
                dragging = nil
                anchor = nil
            }
    }

    // MARK: - Clicking into a pane

    /// A click that lands in a page moves the keyboard to that page's pane.
    ///
    /// A monitor rather than a gesture, for the same reason the sidebar watches
    /// for Escape during a drag: a `WKWebView` takes the click before SwiftUI
    /// ever sees it. The window is asked which view it hit and the answer is
    /// compared by identity, so this cannot disagree with what is on screen the
    /// way a frame comparison could.
    private func watchForClicks() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            if let hit = event.window?.contentView?.hitTest(event.locationInWindow),
               let tab = model.pane(containing: hit),
               model.snapshot.activeTab != tab
            {
                model.activate(tab)
            }
            // Returned unchanged: the click is still the page's to handle.
            return event
        }
    }

    private func stopWatchingForClicks() {
        guard let clickMonitor else { return }
        NSEvent.removeMonitor(clickMonitor)
        self.clickMonitor = nil
    }
}

/// A pane with nothing in it yet.
private struct EmptyPane: View {
    @Environment(BrowserModel.self) private var model
    let tab: TabId

    var body: some View {
        EmptyState(
            icon: "rectangle.split.2x1",
            title: "Empty pane",
            message: "Point it somewhere and it stays here, beside the page you were reading."
        ) {
            Button {
                model.activate(tab)
                model.focusCommandBar()
            } label: {
                // `globe`, which is what the command bar already draws next to
                // a suggestion that navigates. It was `magnifyingglass`, and
                // the shelf spends that one on Show in Finder — the platform's
                // own symbol for revealing a file, which Safari uses for the
                // same thing. One glyph cannot mean both, and the one with a
                // convention behind it keeps it.
                Label("Open Address", systemImage: "globe")
            }
            .buttonStyle(.borderedProminent)
            .help(openLocationTip)
        }
        .background(.background)
    }

    /// Read from the keymap rather than printed, so rebinding ⌘L changes what
    /// this says the way it already changes the menus.
    private var openLocationTip: String {
        guard let chord = model.chord(for: .openLocation) else { return "Open Address" }
        return "Open Address (\(chord.displayString))"
    }
}
