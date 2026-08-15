import SwiftUI
import Zer0Core

/// What a download says about itself.
///
/// Copy, so it lives on this side: the core decided *what happened*, and this
/// decides how to put it. Every line here is answerable from the record — none
/// of them guesses at a size, a rate or a time remaining, because none of those
/// is known (ADR-0018).
enum DownloadCopy {
    /// Outline throughout, including success.
    ///
    /// A filled glyph is the heaviest shape in a list of outlines, and it was
    /// being spent on the one state with nothing left to do about it. Weight is
    /// how a row asks for attention, and a download that finished is not asking
    /// for any.
    static func icon(_ download: Download) -> String {
        switch download.state {
        case .inProgress: "arrow.down.circle"
        case .completed: "checkmark.circle"
        case .cancelled: "xmark.circle"
        case .interrupted: "pause.circle"
        case .failed: failureIcon(download.error?.kind ?? .unknown)
        }
    }

    /// How far along, when that is knowable at all.
    ///
    /// The core's `downloadFraction` answers from the byte counts alone, so it
    /// still returns a number for a download that stopped at 40%. Only
    /// something still arriving has a position worth drawing.
    static func fraction(_ download: Download) -> Double? {
        guard download.state == .inProgress else { return nil }
        return downloadFraction(download: download)
    }

    /// Something is arriving and no total came with it.
    static func isArrivingWithNoTotal(_ download: Download) -> Bool {
        download.state == .inProgress && fraction(download) == nil
    }

    /// The one line under the filename.
    static func status(_ download: Download) -> String {
        switch download.state {
        case .inProgress:
            if let total = download.totalBytes {
                "\(size(download.receivedBytes)) of \(size(total))"
            } else {
                // No total was sent, so there is nothing to be a fraction of.
                // What has arrived is a fact and is all that gets said.
                "\(size(download.receivedBytes)) so far"
            }
        case .completed:
            size(download.totalBytes ?? download.receivedBytes)
        case .cancelled:
            "Stopped"
        case .interrupted:
            "Stopped when zer0 quit"
        case .failed:
            failureTitle(download.error?.kind ?? .unknown)
        }
    }

    /// The sentence a failure gets, in the same voice the navigation error
    /// screen uses: what happened, and what it means for you.
    static func failureMessage(_ error: DownloadError?) -> String {
        switch error?.kind ?? .unknown {
        case .offline:
            "Your Mac isn't connected to the internet. Nothing more arrived."
        case .connectionFailed:
            "The connection dropped partway through. The file on disk is incomplete."
        case .timeout:
            "The server took the connection and then stopped answering."
        case .certificateInvalid:
            "The site's certificate can't be trusted, so nothing was written."
        case .cannotWrite:
            "zer0 couldn't write there. The folder may be gone, or read-only."
        case .noSpace:
            "There isn't enough room left on the disk for this file."
        case .nameUnavailable:
            "Every name this file could have taken is already used in that folder."
        case .unknown:
            // The category is the shell admitting it does not recognise the
            // failure. What the engine said then beats a guess.
            (error?.message).flatMap { $0.isEmpty ? nil : $0 }
                ?? "The download stopped before the file was complete."
        }
    }

    static func failureTitle(_ kind: DownloadErrorKind) -> String {
        switch kind {
        case .offline: "You're offline"
        case .connectionFailed: "The connection dropped"
        case .timeout: "The server stopped answering"
        case .certificateInvalid: "This connection isn't private"
        case .cannotWrite: "Couldn't write the file"
        case .noSpace: "The disk is full"
        case .nameUnavailable: "No free name in that folder"
        case .unknown: "The download didn't finish"
        }
    }

    private static func failureIcon(_ kind: DownloadErrorKind) -> String {
        switch kind {
        case .offline: "wifi.slash"
        case .connectionFailed: "bolt.horizontal.circle"
        case .timeout: "clock.badge.exclamationmark"
        case .certificateInvalid: "lock.trianglebadge.exclamationmark"
        case .cannotWrite: "folder.badge.questionmark"
        case .noSpace: "externaldrive.badge.exclamationmark"
        case .nameUnavailable: "character.cursor.ibeam"
        case .unknown: "exclamationmark.triangle"
        }
    }

    static func size(_ bytes: UInt64) -> String {
        Int64(clamping: bytes).formatted(.byteCount(style: .file))
    }
}

/// The bar under a running download, drawn only when there is a position to
/// draw.
///
/// Both facts used to be a linear `ProgressView` — one determinate, one not —
/// and that was the whole problem. The indeterminate one animates, so it is not
/// a still screen, but it is the *same track at a different fill*: the shape
/// never says "unknown", it says "somewhere along here". A bar that implies a
/// scale we were never sent is exactly what ADR-0018 forbids, and the person
/// only finds out when the sweep passes the end and starts again.
///
/// So the two facts get two shapes. A length was sent: a bar that fills. No
/// length was sent: `UnknownTotalSpinner`, which cannot be read as a position
/// at all.
private struct DownloadProgressBar: View {
    let fraction: Double

    var body: some View {
        ProgressView(value: fraction)
            .progressViewStyle(.linear)
            .controlSize(.small)
    }
}

/// What stands in for the bar when nothing can be a fraction of anything.
///
/// A spinner beside the byte count, rather than a bar under it: the same device
/// the find bar uses while WebKit is still answering, and for the same reason —
/// it says "working, and nobody knows how long" without naming a position. The
/// count next to it is the part that carries the fact.
private struct UnknownTotalSpinner: View {
    var body: some View {
        ProgressView()
            .progressViewStyle(.circular)
            .controlSize(.small)
            .accessibilityLabel("Still arriving. The server did not say how big this is.")
    }
}

/// The leading glyph of a download row, and the column it is centred in.
///
/// Local metrics, because they are measurements of these rows rather than of
/// the UI. A state glyph is not always a circle: a failure wears the badge
/// symbol for whatever went wrong, and the widest of those
/// (`externaldrive.badge.exclamationmark`, `folder.badge.questionmark`)
/// measures 26pt at `.title2` against a circle's 20pt. Centred in the 24pt
/// column this used to borrow from `Space.loose` it overflowed by a point on
/// each side, and the overflow read as a broken left margin against every
/// circular glyph above it.
///
/// The criterion for each number: the widest symbol any row can wear at that
/// size, rounded up to the 4pt rhythm. Measured, not guessed — if a new failure
/// kind brings a wider glyph, this is the number that has to move.
private enum DownloadGlyph {
    /// The list row: `.title2`, widest symbol 26pt.
    static let listFont = Font.title2
    static let listColumn: CGFloat = 28

    /// The shelf card, one step down because its text is one step down:
    /// `.title3`, widest symbol 23pt.
    static let shelfFont = Font.title3
    static let shelfColumn: CGFloat = 24
}

// MARK: - The shelf

/// The acknowledgement.
///
/// Starting a download has to register — a click that produces nothing is
/// indistinguishable from a click that missed — but the person already knows
/// they asked for it, so this is a corner of the window and not a panel over
/// the page. It arrives, it says what is happening, and it goes away by itself
/// once everything has landed.
///
/// A failure does not go away by itself. There is something to do about it, and
/// a notice that removes itself is one you can miss entirely.
struct DownloadShelf: View {
    @Environment(BrowserModel.self) private var model

    /// Sizes that belong to this one card rather than to the whole UI, so they
    /// are named here instead of pretending to be design tokens.
    private enum Metrics {
        /// Wide enough for a real filename over a status line, narrow enough
        /// that the card stays a corner of the window rather than a panel.
        static let width: CGFloat = 320
    }

    /// Downloads this shelf watched start. Presentation state: how long a
    /// notice stays is a look, not a behaviour, so it does not belong in the
    /// core.
    @State private var watching: Set<DownloadId> = []
    /// Stopped, but still on screen.
    @State private var lingering: Set<DownloadId> = []
    @State private var retreat: Task<Void, Never>?

    /// The most recent first, and never more than a cornerful.
    private var showing: [Download] {
        model.downloads
            .filter { $0.state == .inProgress || lingering.contains($0.id) }
            .prefix(3)
            .map(\.self)
    }

    /// Changes whenever a download appears or moves on, which is exactly when
    /// this needs to reconsider itself.
    private var signature: String {
        model.downloads.map { "\($0.id):\($0.state)" }.joined(separator: "|")
    }

    var body: some View {
        Group {
            // Out of the command bar's way, the same as the install banner.
            if !showing.isEmpty, !model.commandBarOpen {
                card
                    .arrives(from: .trailing)
            }
        }
        .motion(.entrance, value: showing.count)
        .onAppear(perform: sync)
        .onChange(of: signature) { _, _ in sync() }
    }

    private var card: some View {
        VStack(spacing: Design.Space.snug) {
            ForEach(showing, id: \.id) { download in
                ShelfRow(download: download)

                if download.id != showing.last?.id {
                    Divider().hairline()
                }
            }
        }
        .padding(Design.Space.regular)
        .frame(width: Metrics.width)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Design.Radius.large))
        .overlay(
            RoundedRectangle(cornerRadius: Design.Radius.large)
                .strokeBorder(.quaternary, lineWidth: Design.Stroke.hairline)
        )
        // Floating over the page rather than resting on it: this is a panel
        // with its own rows, not a strip, and it arrives unasked.
        .elevation(Design.Elevation.floating)
        .padding(Design.Space.loose)
        // The whole card is a way into the list, so nothing here needs its own
        // "see all" affordance.
        .contentShape(RoundedRectangle(cornerRadius: Design.Radius.large))
        .onTapGesture { model.perform(.showDownloads) }
    }

    /// Follow every download from starting to stopping, and start the retreat
    /// once nothing is running.
    private func sync() {
        for download in model.downloads {
            switch download.state {
            case .inProgress:
                watching.insert(download.id)
            // A download restored from the last session was never watched, so
            // it never lingers: it is history, not news.
            case .completed, .cancelled, .failed, .interrupted:
                if watching.remove(download.id) != nil {
                    lingering.insert(download.id)
                }
            }
        }
        lingering = lingering.filter { id in model.downloads.contains { $0.id == id } }
        scheduleRetreat()
    }

    private func scheduleRetreat() {
        retreat?.cancel()
        retreat = nil

        guard watching.isEmpty, !lingering.isEmpty else { return }
        // Anything that failed stays put. It is the one case with an action
        // still owed, and it is the one the person needs to see.
        let unresolved = model.downloads.contains {
            lingering.contains($0.id) && $0.state == .failed
        }
        guard !unresolved else { return }

        retreat = Task {
            try? await Task.sleep(for: .seconds(Design.Duration.linger))
            guard !Task.isCancelled else { return }
            lingering.removeAll()
        }
    }
}

/// One line in the shelf: what it is, how it is going, and the one thing to do.
private struct ShelfRow: View {
    @Environment(BrowserModel.self) private var model
    let download: Download

    var body: some View {
        // Top, matching the list. Centred, the glyph and the trailing button
        // drifted down onto the status line, so the icon appeared to label
        // "41 kB so far" rather than the file it belongs to.
        HStack(alignment: .top, spacing: Design.Space.snug) {
            Image(systemName: DownloadCopy.icon(download))
                .foregroundStyle(download.state == .failed
                    ? AnyShapeStyle(Design.Palette.warning)
                    : AnyShapeStyle(.secondary))
                .font(DownloadGlyph.shelfFont)
                .frame(width: DownloadGlyph.shelfColumn)

            VStack(alignment: .leading, spacing: Design.Space.line) {
                Text(download.filename)
                    .font(Design.Text.rowTitle)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: Design.Space.tight) {
                    Text(DownloadCopy.status(download))
                        .font(Design.Text.label)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()

                    if DownloadCopy.isArrivingWithNoTotal(download) {
                        UnknownTotalSpinner()
                    }
                }

                if let fraction = DownloadCopy.fraction(download) {
                    DownloadProgressBar(fraction: fraction)
                        .padding(.top, Design.Space.line)
                }
            }

            Spacer(minLength: Design.Space.tight)

            action
        }
    }

    @ViewBuilder
    private var action: some View {
        switch download.state {
        case .inProgress:
            iconButton("xmark", "Stop") { model.cancelDownload(download.id) }
        case .completed:
            iconButton("magnifyingglass", "Show in Finder") { model.revealDownload(download) }
        case .failed, .cancelled, .interrupted:
            // Two glyphs for two different promises. `arrow.clockwise` says
            // "again, from the start", which is what Try Again does; a resume
            // keeps what arrived, and drawing that as a retry would say the
            // progress behind it is about to be thrown away.
            if download.resumable {
                iconButton("play.fill", "Resume") { model.resumeDownload(download.id) }
            } else {
                iconButton("arrow.clockwise", "Try Again") { model.retryDownload(download.id) }
            }
        }
    }

    private func iconButton(
        _ symbol: String,
        _ help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(help)
    }
}

// MARK: - The list

/// Everything that has come down, as a page.
///
/// A page rather than the Settings pane it used to be, for the reason history
/// is: it is a list you scroll and act on, it wants an address so ⇧⌘J can bring
/// you back to the one you already have open, and everything a tab does — ⌘W,
/// pinning, splitting, restoring — it wanted anyway (ADR-0063).
///
/// **The rows are the pane's, unchanged**, and that is deliberate. ADR-0027
/// settled what a download row may say: a spinner rather than a bar when no
/// length was sent, a failure louder than a success, one prominent action per
/// screen. None of that got better by being on a page, so none of it was
/// rewritten.
struct DownloadsPage: View {
    @Environment(BrowserModel.self) private var model

    /// Sizes local to this page.
    fileprivate enum Metrics {
        /// The progress bar in a list row is capped so it reads as a detail of
        /// the row rather than as the row's whole width.
        static let progressWidth: CGFloat = 260
        /// A column of rows, not the width of a maximised window. The same
        /// measure the history page takes, so the two pages do not read as two
        /// different kinds of screen.
        static let column: CGFloat = 720
    }

    private var downloads: [Download] { model.downloads }

    /// The newest failure, which is the one that gets Return. Only one thing
    /// can be the default action, and it should be the thing you just watched
    /// go wrong.
    private var newestFailure: DownloadId? {
        downloads.first { $0.state == .failed }?.id
    }

    var body: some View {
        VStack(spacing: 0) {
            // Nothing listed, so no strip and no rule under it. Rendered with
            // one, the screen carried "Downloads Folder" in the corner *and*
            // "Open Downloads Folder" in the middle: two buttons doing one
            // thing, four inches apart, on the only screen most people will
            // ever see here.
            if !downloads.isEmpty {
                strip
                Divider().hairline()
            }

            if downloads.isEmpty {
                empty
            } else {
                ScrollView {
                    list
                        .frame(maxWidth: Metrics.column)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, Design.Space.loose)
                        // A card that starts on the rule above it reads as
                        // attached to the strip rather than as the list under
                        // it. Rendered without this and it was the first thing
                        // that looked wrong.
                        .padding(.vertical, Design.Space.loose)
                }
            }
        }
        .background(.background)
    }

    /// No title: the tab, the sidebar row and the address all already say
    /// "Downloads", and a fourth would be chrome that does not pay for itself.
    /// What is left is the one action the list has, and the way back to the
    /// folder — which is where the files actually are.
    private var strip: some View {
        HStack(spacing: Design.Space.tight) {
            Spacer(minLength: Design.Space.regular)

            Button {
                DownloadHost.reveal(downloadFolder)
            } label: {
                Label("Downloads Folder", systemImage: "folder")
            }
            .help("Open the folder these are saved into.")

            if downloads.contains(where: { $0.state != .inProgress }) {
                Button("Clear") { model.clearFinishedDownloads() }
                    .help("Removes the entries. The files stay where they are.")
            }
        }
        // On the same column the list is on, not on the window's edges. A Clear
        // that ends a hundred points to the right of the card it empties reads
        // as belonging to the window rather than to the list.
        .frame(maxWidth: Metrics.column)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Design.Space.loose)
        .padding(.vertical, Design.Space.snug)
    }

    private var downloadFolder: String {
        model.preferences.downloadDirectory ?? DownloadHost.systemDownloadDirectory()
    }

    /// The first thing anyone sees here, because nobody has downloaded
    /// anything on their first day.
    private var empty: some View {
        EmptyState(
            icon: "arrow.down.circle",
            title: "Nothing downloaded yet",
            message: "Files you save land in your Downloads folder, and stay listed here "
                + "with a way back to them."
        ) {
            Button {
                DownloadHost.reveal(downloadFolder)
            } label: {
                Label("Open Downloads Folder", systemImage: "folder")
            }
            .buttonStyle(.bordered)
        }
        // No `Pane.emptyStateMinHeight`: that floor exists so an empty pane
        // does not collapse inside a settings window. A page already has the
        // whole tab, and `EmptyState` fills it.
    }

    private var list: some View {
        VStack(spacing: 0) {
            ForEach(Array(downloads.enumerated()), id: \.element.id) { index, download in
                DownloadListRow(
                    download: download,
                    isDefaultAction: download.id == newestFailure
                )

                if index < downloads.count - 1 {
                    Divider().hairline().padding(.leading, Design.Space.regular)
                }
            }
        }
        .background(
            Design.Surface.recessed,
            in: RoundedRectangle(cornerRadius: Design.Radius.medium)
        )
    }
}

/// A full row: the file, what happened to it in a sentence, and what to do.
private struct DownloadListRow: View {
    @Environment(BrowserModel.self) private var model
    let download: Download
    /// Whether this row's action answers the return key.
    let isDefaultAction: Bool

    var body: some View {
        HStack(alignment: .top, spacing: Design.Space.snug) {
            Image(systemName: DownloadCopy.icon(download))
                .font(DownloadGlyph.listFont)
                .foregroundStyle(tint)
                .frame(width: DownloadGlyph.listColumn)

            VStack(alignment: .leading, spacing: Design.Space.line) {
                Text(download.filename)
                    .font(Design.Text.rowTitle)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: Design.Space.tight) {
                    Text(detail)
                        .font(Design.Text.label)
                        .foregroundStyle(.secondary)
                        // The same numbers the shelf already holds still. A
                        // size ticking up in proportional digits shifts the
                        // whole line on every tick, which reads as the row
                        // twitching rather than as progress.
                        .monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)

                    if DownloadCopy.isArrivingWithNoTotal(download) {
                        UnknownTotalSpinner()
                    }
                }

                if let fraction = DownloadCopy.fraction(download) {
                    DownloadProgressBar(fraction: fraction)
                        .frame(maxWidth: DownloadsPage.Metrics.progressWidth)
                        .padding(.top, Design.Space.line)
                }
            }

            Spacer(minLength: Design.Space.regular)

            actions
        }
        .padding(Design.Space.snug)
    }

    /// One colour in the list, and it belongs to the row that needs something.
    ///
    /// A finished download used to be `.tint` — the loudest thing on screen,
    /// spent on the state with nothing left to do about it, while the failure
    /// underneath it whispered. It was also the same accent as `Try Again` two
    /// inches away, so the one colour meant both "this went fine" and "press
    /// this". Success drops to `.secondary`, which is what the shelf has always
    /// drawn it as, and orange is left as the only colour in the list.
    private var tint: AnyShapeStyle {
        switch download.state {
        case .failed: AnyShapeStyle(Design.Palette.warning)
        case .completed, .inProgress, .cancelled, .interrupted: AnyShapeStyle(.secondary)
        }
    }

    /// One line while it runs, a whole sentence once something went wrong.
    private var detail: String {
        switch download.state {
        case .inProgress, .completed:
            DownloadCopy.status(download)
        case .failed:
            DownloadCopy.failureMessage(download.error)
        case .cancelled:
            "You stopped this one. The part that arrived is still on disk."
        case .interrupted:
            "zer0 quit while this was still coming down, so it is incomplete."
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch download.state {
        case .inProgress:
            Button("Stop") { model.cancelDownload(download.id) }

        case .completed:
            HStack(spacing: Design.Space.tight) {
                // Reveal before Open: the next thing is usually to move the
                // file somewhere, not to look at it.
                Button("Show in Finder") { model.revealDownload(download) }
                Button("Open") { model.openDownload(download) }
                remove
            }

        case .failed, .cancelled, .interrupted:
            HStack(spacing: Design.Space.tight) {
                retry
                remove
            }
        }
    }

    /// Prominent only where Return actually lands.
    ///
    /// The style used to be unconditional, so three stopped downloads gave
    /// three identical prominent buttons and exactly one of them answered the
    /// return key — with nothing on screen saying which. macOS allows one
    /// prominent button per screen for that reason: prominence is the promise
    /// that Return does this.
    ///
    /// **One button, not two.** Resume and Try Again are the same slot, because
    /// they are the same intent — get this file — and offering both would make
    /// somebody choose between two words for it. Which one appears is the core's
    /// answer to whether carrying on is really possible, and it turns back into
    /// Try Again the moment it stops being (ADR-0101).
    private var retry: some View {
        let button = download.resumable
            ? Button("Resume") { model.resumeDownload(download.id) }
            : Button("Try Again") { model.retryDownload(download.id) }

        return Group {
            if isDefaultAction {
                button
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                button.buttonStyle(.bordered)
            }
        }
    }

    private var remove: some View {
        Button {
            model.removeDownload(download.id)
        } label: {
            Image(systemName: "xmark")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help("Remove from this list. The file stays where it is.")
    }
}
