import SwiftUI
import WebKit
import Zer0Core

/// Hosts a tab's web view. Keyed by tab id so switching tabs swaps the view
/// instead of mutating one in place.
struct WebViewContainer: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context _: Context) -> WKWebView { webView }
    func updateNSView(_: WKWebView, context _: Context) {}
}

extension NavigationSplitViewVisibility {
    /// `.all` is for three-column layouts. Using it here does nothing, so
    /// showing the sidebar again would silently fail.
    static func showingSidebar(_ visible: Bool) -> Self {
        visible ? .doubleColumn : .detailOnly
    }

    var showsSidebar: Bool {
        self != .detailOnly
    }
}

/// The whole browser: a sidebar and a page, and nothing above the page.
///
/// There is no toolbar and no title bar. An address bar that sits there all
/// day costs vertical space on every site to show something you already know.
/// ⌘L brings it up when you actually want it.
public struct BrowserView: View {
    @Environment(BrowserModel.self) private var model

    /// Which core window this scene ended up drawing. `nil` for the moment
    /// between the view existing and the window it lives in existing.
    @State private var windowId: WindowId?

    public init() {}

    public var body: some View {
        NavigationSplitView(columnVisibility: Binding(
            get: { .showingSidebar(model.sidebarVisible) },
            set: { model.sidebarVisible = $0.showsSidebar }
        )) {
            Sidebar()
                // The floor is the sidebar's own, next to the rows it is a
                // floor for. Dropping this modifier is not a compile error and
                // not a visible one either: SwiftUI's default column is 140,
                // which still looks like a sidebar and is no longer one you can
                // read (`SidebarWidthTests`).
                .navigationSplitViewColumnWidth(
                    min: Sidebar.Metrics.minWidth,
                    ideal: Sidebar.Metrics.idealWidth,
                    max: Sidebar.Metrics.maxWidth
                )
        } detail: {
            detail
        }
        // Everything below this draws for one window, so everything below has
        // to know which. Read from the window rather than passed in, because
        // `WindowGroup` builds the view before there is a window (ADR-0065).
        .background(BrowserWindowIdentityReader { windowId = $0 })
        .environment(\.browserWindowId, windowId)
        // The built-in toggle floats loose over the page once there is no
        // title bar to sit in. Ours lives in the strip instead.
        .toolbar(removing: .sidebarToggle)
        .overlay(alignment: .topTrailing) { findBar }
        // Where Chrome puts the same answer, and the corner nothing permanent
        // occupies. Above the find bar in the stack because it is the newer of
        // the two: whichever one you just pressed is the one you are looking at.
        .overlay(alignment: .topTrailing) { keptPageOverlay }
        .overlay(alignment: .top) { commandBarOverlay }
        .overlay(alignment: .bottom) { installBanner }
        // Bottom trailing, out of the install banner's way. A download is
        // something you asked for, so it gets a corner rather than the page.
        .overlay(alignment: .bottomTrailing) { DownloadShelf() }
        .overlay(alignment: .top) { sessionWarning }
        // A sheet rather than an overlay, and the one modal thing in this
        // window. Everything else here can be ignored and stepped around,
        // because everything else here is something *you* asked for. This one
        // is a page's question about a camera, and a browser that let you carry
        // on reading with it half-visible in a corner would be a browser
        // teaching people to answer it without looking (ADR-0056).
        .sheet(item: Binding(
            get: { model.pendingSitePermission },
            // Never assigned to. The question belongs to the core, and the only
            // way it goes away is the core answering the page — so a set here
            // could only ever be SwiftUI telling us the sheet closed, which the
            // handlers below have already dealt with.
            set: { _ in }
        )) { pending in
            SitePermissionSheet(
                prompt: pending.prompt,
                onAllow: { model.decideSitePermission(pending.prompt.request, .allow) },
                onBlock: { model.decideSitePermission(pending.prompt.request, .block) },
                onDismiss: { model.decideSitePermission(pending.prompt.request, .dismiss) }
            )
        }
        // A server asking who you are. A sheet rather than a strip because the
        // navigation is genuinely stopped behind it — nothing loads until it is
        // answered — and because the field wants the keyboard, which a corner
        // panel over a live page would be fighting for.
        //
        // Deliberately a different surface from the certificate screen, which
        // takes the whole area (ADR-0016). Being asked for a password is
        // routine; being told a site cannot be shown to be itself is not, and
        // one surface for both would teach the second to be dismissed like the
        // first (ADR-0093).
        .sheet(item: Binding(
            get: { model.pendingHttpAuth },
            // Never assigned to, for the reason the two sheets around it are
            // not: the question belongs to the core, and the only way it goes
            // away is the core answering the server.
            set: { _ in }
        )) { pending in
            AuthChallengeSheet(
                prompt: pending.prompt,
                onSignIn: { username, password, remember in
                    model.signInToServer(
                        pending.prompt.request,
                        username: username,
                        password: password,
                        remember: remember
                    )
                },
                onCancel: { model.cancelServerSignIn(pending.prompt.request) }
            )
        }
        // What a page said, over the page that said it. A sheet for the same
        // reason the one above is one — it is modal in the engine too, since
        // `alert()` has stopped the script that called it — and scoped to one
        // window, which the camera sheet above is not: this one is raised by a
        // tab, and a tab is in exactly one window (ADR-0089).
        .sheet(item: Binding(
            get: { model.pendingPageDialog(in: windowId) },
            // Never assigned to. The question belongs to the core, and the only
            // way it goes away is the core answering the page.
            set: { _ in }
        )) { pending in
            PageDialogSheet(dialog: pending.dialog) { answer, silence in
                model.answerPageDialog(pending.dialog.request, answer, silence: silence)
            }
        }
        // Over the page the person was on, which is where the decision was
        // asked for. It is presented here rather than by `InstallBanner`
        // because the banner is mounted from the listing, and the listing stops
        // being an offer the instant the package lands on disk — a sheet
        // presented from something with that lifetime is a sheet that is torn
        // down halfway through being asked for (ADR-0069).
        .sheet(item: Binding(
            get: { model.extensionFlow?.request.map(PendingConsent.init(request:)) },
            // Never assigned to. Both ways out of this sheet go through the
            // model, which is also what removes a package nobody agreed to
            // have; a set here could only ever be SwiftUI reporting a dismissal
            // the handlers below already carried out.
            set: { _ in }
        )) { pending in
            ExtensionConsentSheet(
                request: pending.request,
                onAdd: { model.answerExtensionConsent($0) },
                onCancel: { model.cancelExtensionConsent() }
            )
        }
        // A program about to be started outside the browser, over the window
        // the gesture happened in. The request is held open in
        // `NativeMessagingHost` while this is up, which is why every way out of
        // this sheet answers it (ADR-0105).
        .sheet(item: Binding(
            get: { model.pendingNativeHost.map(PendingNativeHostQuestion.init(pending:)) },
            // Never assigned to, for the reason the consent sheet above gives.
            set: { _ in }
        )) { asked in
            NativeHostConsentSheet(
                prompt: nativeHostPrompt(
                    extensionName: asked.pending.extensionName,
                    host: asked.pending.host
                ),
                onAllow: { model.answerNativeHost(asked.pending, allowed: true) },
                onRefuse: { model.answerNativeHost(asked.pending, allowed: false) },
                onDismiss: { model.dismissNativeHostQuestion(asked.pending) }
            )
        }
        // Removing takes the extension's own stored data with it and there is
        // no undo, so it warns before rather than after — the same rule
        // `DestructiveButton` carries for every red button in a window of ours.
        // It cannot *be* that component here, because the button that raises it
        // is drawn inside the store's page and a page cannot host a dialog.
        .confirmationDialog(
            model.pendingExtensionRemoval.map { "Remove \($0.name)?" } ?? "",
            isPresented: Binding(
                get: { model.pendingExtensionRemoval != nil },
                set: { if !$0 { model.cancelExtensionRemoval() } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) { model.confirmExtensionRemoval() }
            Button("Cancel", role: .cancel) { model.cancelExtensionRemoval() }
        } message: {
            Text("It stops running now, and everything it stored on this Mac goes with it. "
                + "Adding it again starts it from nothing.")
        }
        .motion(.entrance, value: model.listingExtensionId)
        .motion(.entrance, value: model.finder.isOpen)
        .motion(.entrance, value: model.sidebarVisible)
        // The bar is summoned, so it is summoned *by something*: the scrim and
        // the panel move on the same curve, which is what ties "the window
        // stepped back" to "and this is the reason why".
        //
        // This line is the whole of why the overlay's transition used to be
        // decoration. It carried `.transition(.opacity)` and nothing bound an
        // animation to `commandBarOpen`, so across every captured frame the
        // panel was simply present or simply absent. The transition had been
        // written; it had never run.
        .motion(.entrance, value: model.commandBarOpen)
        // It arrives *because* a key was pressed, so it has to look like it
        // arrived rather than like it was always there.
        .motion(.entrance, value: model.keeping)
        // Same defect, same fix: the warning declared `.move(edge: .top)` and
        // nothing drove it, so a notice about losing a session appeared by
        // teleporting into the top of the window.
        .motion(.entrance, value: model.showsSessionWarning)
        // A page failing is already jarring; the explanation should fade in
        // rather than snap over whatever was there.
        .motion(.subtle, value: model.activeTab?.lastError != nil)
        // Entering and leaving a split: the page in hand takes its half while
        // the other pane slides in from the edge. A page that teleported into a
        // half-width column would read as a rendering fault. Keyed on the pair
        // rather than on the split itself, so moving the divider does not set a
        // spring going underneath the drag.
        .motion(.entrance, value: model.splitPanes)
    }

    /// The page, with a strip above it when the sidebar is not there to hold
    /// the window's controls.
    private var detail: some View {
        VStack(spacing: 0) {
            if !model.sidebarVisible {
                WindowChrome()
                    .arrives(from: .top)
            }
            content
        }
        .ignoresSafeArea(.container, edges: .top)
    }

    /// One page, or two side by side.
    ///
    /// Both go through `PageStack`, which is what lets the page you were
    /// reading move over to its half instead of being cross-faded into it.
    @ViewBuilder
    private var content: some View {
        // This window's tab, not the browser's. Reading `snapshot.activeTab`
        // here would draw the front window's page in every window behind it
        // (ADR-0065).
        if let tab = model.activeTab(in: windowId) {
            let split = model.activeSplit(in: windowId)
            PageStack(leading: split?.leading ?? tab, split: split)
        } else {
            NothingOpenScreen()
        }
    }

    @ViewBuilder
    private var findBar: some View {
        if model.finder.isOpen {
            FindBar()
                .padding(Design.Space.regular)
                .padding(.top, model.sidebarVisible ? 0 : WindowChrome.height)
                .arrives(from: .top)
        }
    }

    /// Shown when the session file could not be read.
    ///
    /// Saving is off in that state, so the alternative is letting someone work
    /// all day and lose it at the next launch. Dismissable, because knowing
    /// once is enough.
    @ViewBuilder
    private var sessionWarning: some View {
        if model.showsSessionWarning, let error = model.loadError {
            HStack(spacing: Design.Space.snug) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Design.Palette.warning)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Your previous session could not be read")
                        .font(Design.Text.rowTitle)
                    Text("Nothing is being saved this session, so the file you already have "
                        + "is not written over. \(error)")
                        .font(Design.Text.label)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: Design.Space.regular)

                Button("Dismiss") { model.sessionWarningDismissed = true }
                    .buttonStyle(.borderless)
            }
            .padding(Design.Space.regular)
            .frame(maxWidth: 560)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Design.Radius.medium))
            .overlay(
                RoundedRectangle(cornerRadius: Design.Radius.medium)
                    .strokeBorder(Design.Palette.warning.opacity(0.4), lineWidth: 1)
            )
            .elevation(Design.Elevation.floating)
            .padding(.top, model.sidebarVisible ? Design.Space.regular : WindowChrome.height + 8)
            .arrives(from: .top)
        }
    }

    @ViewBuilder
    private var installBanner: some View {
        // Bottom, so it never covers what you are reading, and it stays out of
        // the command bar's way.
        //
        // Mounted for the listing the tab is showing *or* for an install in
        // flight, and the two genuinely differ. The store is a single-page app,
        // so a listing reached without loading a document leaves the tab's URL
        // behind what the frame is showing; and an install started from the
        // page has to keep reporting after the person has navigated away from
        // the listing that started it.
        if let id = model.listingExtensionId ?? model.unfinishedExtensionFlowId,
           !model.commandBarOpen {
            // On a listing where the store's own button became ours, the banner
            // says nothing until there is something to say. Where it did not —
            // the store changed its markup, the script never ran — this is the
            // whole of it, exactly as it was before ADR-0062.
            InstallBanner(
                extensionId: id,
                pageCarriesTheOffer: model.activeTab.map {
                    model.storeControlState(inTab: $0.id) == .adopted
                } ?? false
            )
            .padding(.bottom, Design.Space.loose)
            .arrives(from: .bottom)
        }
    }

    /// What ⌘D says back, and where you rename what it kept.
    ///
    /// No scrim: this is not modal. Keeping a page is a thing you do *while*
    /// reading one, and dimming the page to confirm that you kept it would
    /// interrupt exactly the activity the feature exists to serve.
    @ViewBuilder
    private var keptPageOverlay: some View {
        if let kept = model.keeping {
            BookmarkPanel(kept: kept)
                .padding(.top, WindowChrome.height)
                .padding(.trailing, Design.Space.regular)
                .summoned()
        }
    }

    @ViewBuilder
    private var commandBarOverlay: some View {
        if model.commandBarOpen {
            ZStack(alignment: .top) {
                // Clicking anywhere outside dismisses, which is what people
                // expect from a palette.
                //
                // The dimming is the modal statement, and it is the half of
                // this that must not travel: a scrim that slid in from an edge
                // would be a curtain, and a curtain is a thing in the room. It
                // fades, and it fades on the same curve as the panel, because
                // the two are one event.
                Color.black.opacity(0.15)
                    .ignoresSafeArea()
                    .onTapGesture { model.commandBarOpen = false }
                    .transition(.opacity)

                CommandBar()
                    .padding(.top, CommandBar.Metrics.dropFromTop)
                    .summoned()
            }
        }
    }
}

/// The browser with nothing in it: the first screen of the first day, and the
/// one that comes back every time the last tab closes.
///
/// This is one of only two places the mark appears. It earns it here because
/// it is the one moment the browser is not being used for anything — the
/// sidebar, the command bar and the page are all tools in hand, and a logo on
/// a tool in hand is an interruption. Large, quiet and low-contrast on
/// purpose: the button under it is the part with a job to do.
///
/// It used to be the only empty state in the shell with nothing in its action
/// slot, which had the investment exactly inverted: the screen everyone meets
/// first got less than the ones buried three panes into Settings. Its message
/// was also the sentence "Press ⌘T to go somewhere.", typed out — an assertion
/// with an expiry date, which rebinding ⌘T would quietly turn into a lie
/// (ADR-0018, ADR-0012). The chord is now read from the live keymap, and it is
/// printed once rather than folded into prose.
///
/// What it deliberately does **not** grow into: a grid of recent sites, a
/// search field, a news panel. This is a browser at rest, not a dashboard. One
/// action, and the keyboard path to it.
struct NothingOpenScreen: View {
    @Environment(BrowserModel.self) private var model

    var body: some View {
        EmptyState(
            glyph: {
                Zer0MarkGlyph(side: Design.Glyph.mark)
                    .foregroundStyle(.tertiary)
            },
            title: "Nothing open",
            // What the button is about to do, in the words the command bar
            // itself uses when it opens. Everything named here is something the
            // bar actually accepts (ADR-0015), so the sentence is a description
            // rather than a promise.
            message: "Open a tab and zer0 asks where to: an address, a search, "
                + "or somewhere you have already been."
        ) {
            // `tight` rather than `snug`: the chord belongs to the button above
            // it, and at the empty state's own spacing it read as a fourth
            // element in the stack instead of as a caption on the third.
            VStack(spacing: Design.Space.tight) {
                Button {
                    model.perform(.newTab)
                } label: {
                    Label("New Tab", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                // The only thing to do on this screen, so Return does it — the
                // same rule the navigation error screen follows. Safe next to
                // the command bar: once that is open its field holds first
                // responder and eats the key itself.
                .keyboardShortcut(.defaultAction)
                .help(newTabTip)

                // The keyboard path, printed once and read from the keymap.
                // `label` rather than `micro`: this is the sentence's only
                // remaining job now that the prose no longer carries the chord,
                // and at caption2 it was a smudge under a large button.
                if let chord = model.chord(for: .newTab) {
                    Text(chord.displayString)
                        .font(Design.Text.label)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.top, Design.Space.hair)
        }
        .background(.background)
    }

    /// Read from the keymap rather than printed, the same as every other
    /// shortcut this shell mentions.
    private var newTabTip: String {
        guard let chord = model.chord(for: .newTab) else { return "New Tab" }
        return "New Tab (\(chord.displayString))"
    }
}

/// What a page that failed to load looks like.
///
/// A white rectangle is the worst possible answer to "did that work?": it is
/// indistinguishable from a page still loading and from a page that is
/// genuinely empty. This says what happened in a sentence a person can act on,
/// names the site it happened to, and puts the one useful action under the
/// return key.
struct NavigationErrorScreen: View {
    let error: NavigationError
    /// What was wrong with the certificate, when a certificate is what stopped
    /// it. `nil` for every other kind of failure.
    var certificate: CertificateReport?
    var onTrust: ((_ origin: String, _ fingerprint: String) -> Void)?
    let retry: () -> Void

    var body: some View {
        EmptyState(icon: icon, title: title, message: message) {
            VStack(spacing: Design.Space.regular) {
                if let address = error.url {
                    // The full address, under the headline rather than in it:
                    // a long URL in a title destroys the hierarchy, but you
                    // still need to see exactly what was asked for.
                    Text(address)
                        .font(Design.Text.mono)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, Design.Space.tight)
                        .padding(.vertical, Design.Space.hair)
                        .background(.quaternary.opacity(0.4), in: Capsule())
                        .frame(maxWidth: 420)
                }

                if let certificate { certificateDetail(certificate) }

                Button(action: retry) {
                    Label("Try Again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                // It is the only thing to do here, so return does it. ⌘R goes
                // through the same path in the core.
                //
                // Still Return, and still Try Again, on the certificate screen
                // too: the way through is never the default action, because a
                // key already in flight must not be what waves a certificate
                // through (the rule ADR-0056 wrote for the camera sheet).
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, Design.Space.tight)
        }
        .background(.background)
        .transition(.opacity)
    }

    /// The facts, under the sentence.
    ///
    /// Everything here is the core's: which faults there are, in which order,
    /// what each is called, and whether there is a way through at all. This
    /// draws weight and order and decides none of it (ADR-0094).
    @ViewBuilder
    private func certificateDetail(_ report: CertificateReport) -> some View {
        VStack(spacing: Design.Space.snug) {
            // The second and further faults. A certificate that is both expired
            // and for the wrong name says both, because naming one sends
            // somebody to fix half of it and be surprised again.
            if !report.also.isEmpty {
                VStack(spacing: Design.Space.hair) {
                    ForEach(report.also, id: \.self) { fault in
                        Text("And \(fault.prefix(1).lowercased())\(fault.dropFirst())")
                            .font(Design.Text.label)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: 420)
            }

            // Who sent it, in mono, because it is a name off a certificate
            // rather than prose. Shown only when there is one — a certificate
            // with no readable subject would otherwise draw an empty row.
            if !report.certificate.subject.isEmpty {
                Text("Sent by \(report.certificate.subject)")
                    .font(Design.Text.mono)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 420)
            }

            if report.mayProceed, let onTrust {
                wayThrough(report, onTrust)
            } else if !report.noProceedNote.isEmpty {
                // Said out loud rather than left as an absent button. A screen
                // with no way forward reads as a browser that cannot do
                // something; this one has decided not to (ADR-0018).
                Text(report.noProceedNote)
                    .font(Design.Text.label)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 420)
            }
        }
    }

    /// The one case where going on is offered: a host with no network between
    /// the two ends.
    ///
    /// Deliberately the quietest control on the screen — `.link`, below the
    /// prominent Try Again, carrying no key equivalent. It is a way through for
    /// somebody who already knows what they are looking at, not the obvious
    /// thing to press to make the warning stop.
    @ViewBuilder
    private func wayThrough(
        _ report: CertificateReport,
        _ onTrust: @escaping (String, String) -> Void
    ) -> some View {
        VStack(spacing: Design.Space.hair) {
            // `.link` keeps the pointer and the hover a link has, so it does
            // not become a control nobody can tell is one. Tinted secondary
            // rather than left at the accent: rendered, an accent-coloured
            // link under a grey Try Again was the brightest thing on a screen
            // whose whole argument is that going on must not be the obvious
            // thing to press.
            Button("Continue to \(report.host) this time") {
                onTrust(report.origin, report.certificate.fingerprint)
            }
            .buttonStyle(.link)
            .controlSize(.small)
            .font(Design.Text.label)
            .foregroundStyle(.secondary)

            Text("Only this certificate, only in this space, and only until zer0 quits.")
                .font(Design.Text.micro)
                .foregroundStyle(.tertiary)
        }
    }


    /// The site, as a person would name it. `www.` is noise nobody says out
    /// loud, so it goes.
    private var site: String? {
        guard let url = error.url, let host = URL(string: url)?.host() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private var icon: String {
        switch error.kind {
        case .offline: "wifi.slash"
        // The same symbol Safari uses when it cannot open a page, so it is
        // already familiar rather than something to decode.
        case .hostNotFound: "globe.badge.chevron.backward"
        case .connectionFailed: "bolt.horizontal.circle"
        case .timeout: "clock.badge.exclamationmark"
        case .certificateInvalid: "lock.trianglebadge.exclamationmark"
        case .unsupportedUrl: "questionmark.circle"
        case .cancelled: "xmark.circle"
        // The page, and the thing that was drawing it, stopped. Not a warning
        // triangle: nothing here is anybody's mistake and nothing is unsafe.
        case .pageProcessEnded: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90"
        case .unknown: "exclamationmark.triangle"
        }
    }

    /// Named for what happened, not for the error that reported it. Nobody has
    /// ever been helped by reading "NSURLErrorDomain -1009".
    /// The headline.
    ///
    /// When a certificate is what failed, the core has named which fact is
    /// wrong and that beats the category — `certificateInvalid` on its own can
    /// only produce "This connection isn't private", which is true of five
    /// different problems and tells somebody nothing they can act on.
    private var title: String {
        if let certificate { return certificate.headline }
        // `return switch` rather than an implicit one: the line above makes
        // this a body with statements in it.
        return switch error.kind {
        case .offline: "You're offline"
        case .hostNotFound: site.map { "Can't find \($0)" } ?? "Can't find that site"
        case .connectionFailed: site.map { "Can't reach \($0)" } ?? "Can't reach that site"
        case .timeout: site.map { "\($0) took too long" } ?? "That took too long"
        case .certificateInvalid: "This connection isn't private"
        case .unsupportedUrl: "That address can't be opened"
        case .cancelled: "This page stopped loading"
        case .pageProcessEnded: site.map { "\($0) stopped responding" } ?? "This page stopped responding"
        case .unknown: "This page didn't load"
        }
    }

    private var message: String {
        if let certificate { return certificate.explanation }
        return switch error.kind {
        case .offline:
            "Your Mac isn't connected to the internet. Check Wi-Fi or the cable, then try again."
        case .hostNotFound:
            "No server answers to that name. It could be a typo, or the site could be gone. ⌘L opens the address for editing."
        case .connectionFailed:
            "The connection was refused or dropped partway. The site may be down right now."
        case .timeout:
            "The server took the connection and then stopped answering."
        case .certificateInvalid:
            "This site's certificate can't be trusted, so the page was not loaded. It may be expired, or someone may be impersonating the site."
        case .unsupportedUrl:
            "zer0 doesn't know how to open an address of this kind."
        case .cancelled:
            "Something interrupted the load before the page arrived."
        case .pageProcessEnded:
            // What is known: the process ended, and anything typed into the
            // page went with it. What is not known is why — WebKit reports the
            // fact and no reason — so nothing here guesses at memory or at the
            // site's code (ADR-0018). Reloading is offered rather than done,
            // because a page that dies as it loads would otherwise do it in a
            // loop.
            "zer0 is still running, but the page isn't. Anything you had typed into it is gone. Reloading usually brings it back."
        case .unknown:
            // The category is the shell admitting it does not recognise the
            // failure. What the engine said is then better than a guess.
            error.message.isEmpty ? "The page stopped before it could be shown." : error.message
        }
    }
}
