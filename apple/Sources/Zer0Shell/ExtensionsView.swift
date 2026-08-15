import SwiftUI
import Zer0Core

/// Installed extensions, and a way to add one.
///
/// Takes a store URL or a bare ID, because those are the two things anyone
/// actually has in hand. Nobody should have to know which is which.
public struct ExtensionsView: View {
    @Environment(BrowserModel.self) private var model
    @State private var input: String = ""
    @State private var installing = false
    @State private var failure: String?
    /// What is on disk and waiting to be told what it may do. Nothing is
    /// granted and nothing runs while this is set.
    @State private var deciding: PendingConsent?
    /// Which rows have their permissions open.
    @State private var expanded: Set<String> = []

    /// Sizes that belong to this one pane rather than to the whole UI, so they
    /// are named here instead of pretending to be design tokens.
    private enum Metrics {
        /// The puzzle-piece icon shares a column, so every extension's name
        /// starts on the same vertical whatever its icon renders at.
        static let iconColumn: CGFloat = 22
    }

    public init() {}

    /// Opened on these rows from the start.
    ///
    /// The only caller is the harness that photographs the permissions block.
    /// `expanded` is `@State`, so from outside there is no press to send and no
    /// set to write — and the block it opens is the one thing on this pane that
    /// a screenshot has to see, because whether a row offers a switch or a
    /// sentence is not something an assertion can look at (ADR-0084).
    init(expanding: Set<String>) {
        _expanded = State(initialValue: expanding)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.loose) {
            header
            installer

            if model.installedExtensions.isEmpty {
                EmptyState(
                    icon: "puzzlepiece.extension",
                    title: "No extensions yet",
                    message: "Paste a Chrome Web Store link above, or open the store and zer0 "
                        + "will offer to add whatever listing you land on."
                ) {
                    // Somebody with no extensions has no link to paste yet, so
                    // the empty state hands them the one place to find one.
                    Button(action: openTheStore) {
                        Label("Open the Chrome Web Store", systemImage: "arrow.up.forward")
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(minHeight: Design.Pane.emptyStateMinHeight)
            } else {
                list
            }
        }
        .motion(.subtle, value: model.installedExtensions.count)
        .sheet(item: $deciding) { pending in
            ExtensionConsentSheet(
                request: pending.request,
                onAdd: { decision in
                    deciding = nil
                    Task { await model.applyConsent(decision) }
                },
                onCancel: { cancelDecision(pending.request) }
            )
        }
    }

    /// Backing out of the dialog.
    ///
    /// For something that was just downloaded this removes it: nobody agreed
    /// to have it, so it does not stay on disk. For something already
    /// installed and merely being reviewed it changes nothing, because closing
    /// a window is not an instruction to uninstall.
    private func cancelDecision(_ request: ConsentRequest) {
        deciding = nil
        guard model.consent(for: request.extensionId) == nil,
              model.installedExtensions.contains(where: { $0.id == request.extensionId })
        else { return }
        do {
            try model.uninstallExtension(id: request.extensionId)
        } catch {
            failure = "\(request.extensionName) was not added, and could not be "
                + "removed from disk: \(error.localizedDescription)"
        }
    }

    /// No title: the sidebar row already says "Extensions", and a pane that
    /// repeats its own name is chrome that does not pay for itself. What it
    /// opens with is the part the sidebar cannot say.
    private var header: some View {
        Text("Chrome extensions run on WebKit's implementation, which covers a large part "
            + "of the API surface but not all of it. Some will not work.")
            .font(Design.Text.detail)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var installer: some View {
        VStack(alignment: .leading, spacing: Design.Space.tight) {
            HStack(spacing: Design.Space.tight) {
                Image(systemName: "link")
                    .foregroundStyle(.secondary)

                // Bordered, like the Air Traffic composer's field. Plain on a
                // recessed bar left nothing on screen saying the thing was
                // typeable: the bar looked like a label with a button on it.
                TextField("Chrome Web Store link or extension ID", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(install)

                if installing {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Add", action: install)
                        .buttonStyle(.borderedProminent)
                        .disabled(extractedId == nil)
                        .help(hint ?? "Install this extension")
                }
            }
            .padding(Design.Space.regular)
            .background(Design.Surface.recessed, in: RoundedRectangle(cornerRadius: Design.Radius.medium))

            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(Design.Text.label)
                    .foregroundStyle(Design.Palette.warning)
            } else if let hint {
                Label(hint, systemImage: "info.circle")
                    .font(Design.Text.label)
                    .foregroundStyle(.secondary)
            }
        }
        .motion(.subtle, value: hint)
    }

    /// Why "Add" is greyed out. A disabled button with nothing next to it is a
    /// dead end: you can see it will not work, but not what to change.
    private var hint: String? {
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              extractedId == nil
        else { return nil }
        return "No extension ID in there yet. An ID is 32 letters, a through p."
    }

    private var list: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.installedExtensions.enumerated()), id: \.element.id) { index, ext in
                row(ext)

                if index < model.installedExtensions.count - 1 {
                    Divider().hairline().padding(.leading, Design.Space.regular)
                }
            }
        }
        .background(Design.Surface.recessed, in: RoundedRectangle(cornerRadius: Design.Radius.medium))
    }

    private func row(_ ext: InstalledExtension) -> some View {
        VStack(alignment: .leading, spacing: Design.Space.snug) {
            HStack(alignment: .top, spacing: Design.Space.snug) {
                Image(systemName: "puzzlepiece.extension.fill")
                    .font(.title3)
                    .foregroundStyle(status(of: ext).isRunning ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    .frame(width: Metrics.iconColumn)

                VStack(alignment: .leading, spacing: Design.Space.line) {
                    Text(ext.manifest.name).font(Design.Text.rowTitle)

                    Text("\(ext.manifest.version) · Manifest V\(ext.manifest.manifestVersion)")
                        .font(Design.Text.label)
                        .foregroundStyle(.secondary)

                    // What it holds, not what it asked for. Those stopped
                    // being the same thing the moment refusing became possible.
                    Label(status(of: ext).summary, systemImage: status(of: ext).symbol)
                        .font(Design.Text.label)
                        .foregroundStyle(status(of: ext).isRunning
                            ? AnyShapeStyle(.secondary)
                            : AnyShapeStyle(Design.Palette.warning))
                        .fixedSize(horizontal: false, vertical: true)

                    // Last, and quieter than everything above it, because it is
                    // disclosure rather than a fault — not the warning colour,
                    // and not hidden either. This browser changed somebody
                    // else's package on the way in (ADR-0100), and the only
                    // version of that anybody should accept is one they can see
                    // without a hex editor. Below the status rather than above
                    // it so the block still reads name, then state, then
                    // footnote, instead of putting a tertiary line between two
                    // secondary ones where it looks like a rendering fault.
                    if let modification = extensionModificationLine(ext.manifest) {
                        Label(modification, systemImage: "doc.badge.plus")
                            .font(Design.Text.micro)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // What this extension may start outside the browser
                    // (ADR-0105). The answer was given once, in a sheet, and a
                    // grant that can only be seen at the moment it is given is
                    // a grant nobody can review — which is the whole argument
                    // of ADR-0028 applied to the one permission that reaches
                    // off the machine's browser entirely. Warning-coloured
                    // rather than tertiary, because this is the only line on
                    // the row that names something running outside the sandbox.
                    if let programs = extensionProgramLine(model.allowedPrograms(of: ext.id)) {
                        Label(programs, systemImage: "terminal")
                            .font(Design.Text.micro)
                            .foregroundStyle(Design.Palette.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: Design.Space.regular)

                controls(ext)
            }

            if expanded.contains(ext.id) {
                held(ext)
            }
        }
        .padding(Design.Space.regular)
        .motion(.subtle, value: expanded)
    }

    /// Whether this extension's button is on show, and why it cannot be.
    ///
    /// Two reasons it is not offered, and each says which one it is, because a
    /// disabled control with nothing next to it is a dead end (ADR-0018): an
    /// extension that declares no button in its manifest has none to show, and
    /// one that is not running would show a button that swallows the press.
    @ViewBuilder
    private func pinControl(_ ext: InstalledExtension) -> some View {
        let running = status(of: ext).isRunning

        Toggle("", isOn: Binding(
            get: { model.extensionIsPinned(ext.id) },
            set: { model.setExtensionPinned(ext.id, $0) }
        ))
        .toggleStyle(.switch)
        .controlSize(.mini)
        .labelsHidden()
        .disabled(!ext.manifest.hasAction || !running)
        .help(pinHint(ext, running: running))
        .accessibilityLabel("Show \(ext.manifest.name)’s button")
    }

    private func pinHint(_ ext: InstalledExtension, running: Bool) -> String {
        if !ext.manifest.hasAction {
            return "\(ext.manifest.name) has no button to show — it does its work without one."
        }
        if !running {
            return "\(ext.manifest.name) is not running, so its button would do nothing."
        }
        return "Show \(ext.manifest.name)’s button in the sidebar"
    }

    @ViewBuilder
    private func controls(_ ext: InstalledExtension) -> some View {
        HStack(spacing: Design.Space.snug) {
            pinControl(ext)

            if model.consent(for: ext.id) == nil {
                // Nothing was ever decided about this one, so there is nothing
                // to expand. The only useful action is the dialog itself.
                Button("Review…") { deciding = PendingConsent(request: model.consentRequest(for: ext)) }
                    .buttonStyle(.bordered)
            } else {
                Button(expanded.contains(ext.id) ? "Hide Permissions" : "Permissions") {
                    if expanded.contains(ext.id) {
                        expanded.remove(ext.id)
                    } else {
                        expanded.insert(ext.id)
                    }
                }
                .buttonStyle(.borderless)
            }

            // `DestructiveButton` rather than a bare red button, which is what
            // this was. Removing an extension takes everything it stored with
            // it and there is no undo, and this project's rule is that a
            // destructive state warns before rather than after — the same
            // question the store page's Remove now raises. One act, one
            // wording, wherever it is pressed.
            DestructiveButton(
                title: "Remove",
                question: "Remove \(ext.manifest.name)?",
                consequence: "It stops running now, and everything it stored on this Mac goes "
                    + "with it. Adding it again starts it from nothing.",
                confirm: "Remove"
            ) {
                remove(ext)
            }
        }
    }

    /// What this extension holds right now, with a way to take each one back.
    ///
    /// Switching a row off goes through the core and down into the live
    /// `WKWebExtensionContext`; it is not a repaint. Switching one back on
    /// takes the same path in reverse.
    @ViewBuilder
    private func held(_ ext: InstalledExtension) -> some View {
        let request = model.consentRequest(for: ext)
        let decision = model.consent(for: ext.id)

        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(request.requests.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .top, spacing: Design.Space.snug) {
                    VStack(alignment: .leading, spacing: Design.Space.line) {
                        Text(item.title)
                            .font(Design.Text.label)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(item.key)
                            .font(Design.Text.mono)
                            .foregroundStyle(.tertiary)

                        // A switch that changes nothing is a lie of affordance
                        // (ADR-0018), so where granting reaches nothing there is
                        // no switch at all — the row says so instead, in the
                        // core's words (ADR-0084). Under the key rather than in
                        // the switch's column because a sentence does not fit a
                        // control's width.
                        //
                        // Two glyphs, because there are two facts and a reader
                        // skimming six stacked rows sees the mark before the
                        // words (ADR-0103). Exhaustive, so a third kind of
                        // not-provided cannot arrive wearing one of these.
                        if let stated = item.notProvided {
                            switch stated {
                            case let .notBuiltYet(sentence):
                                // Dotted: an outline with nothing in it yet.
                                Label(sentence, systemImage: "circle.dotted")
                                    .font(Design.Text.micro)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            case let .declined(sentence):
                                // A hand, not a slash: this is a position taken
                                // rather than a hole in what was built.
                                Label(sentence, systemImage: "hand.raised")
                                    .font(Design.Text.micro)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }

                    Spacer(minLength: Design.Space.snug)

                    if item.notProvided == nil {
                        Toggle("", isOn: Binding(
                            get: {
                                guard let decision else { return false }
                                return consentDecisionGrants(
                                    decision: decision,
                                    kind: item.kind,
                                    key: item.key
                                )
                            },
                            set: { granted in
                                if granted {
                                    model.grantExtensionPermission(ext.id, item.kind, item.key)
                                } else {
                                    model.revokeExtensionPermission(ext.id, item.kind, item.key)
                                }
                            }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                        .accessibilityLabel(item.title)
                    }
                }
                .padding(.vertical, Design.Space.tight)
                .padding(.horizontal, Design.Space.snug)

                if index < request.requests.count - 1 {
                    Divider().hairline()
                }
            }

            if let decision, !decision.unreadableHosts.isEmpty {
                Divider().hairline()
                Label(
                    "Not granted, because zer0 could not read "
                        + "\(decision.unreadableHosts.count == 1 ? "it" : "them"): "
                        + decision.unreadableHosts.joined(separator: "  ·  "),
                    systemImage: "questionmark.circle"
                )
                .font(Design.Text.micro)
                .foregroundStyle(.tertiary)
                .padding(Design.Space.snug)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .background(Design.Surface.recessedInner, in: RoundedRectangle(cornerRadius: Design.Radius.small))
        .padding(.leading, Design.Space.section)
    }

    /// This pane's reading of one row, from the core's answer and the
    /// platform's.
    private func status(of ext: InstalledExtension) -> ExtensionStatus {
        ExtensionStatus.of(
            standing: model.standing(of: ext.id),
            backgroundFailed: model.extensions?.backgroundContentFailed(ext.id) == true
        )
    }

    /// Uninstalling touches the disk and can fail. Swallowing that left a
    /// button that visibly did nothing, which reads as a broken browser rather
    /// than a locked file.
    private func remove(_ ext: InstalledExtension) {
        do {
            failure = nil
            try model.uninstallExtension(id: ext.id)
        } catch {
            failure = "\(ext.manifest.name) could not be removed: \(error.localizedDescription)"
        }
    }

    /// Settings is its own window, so this lands the store in the browser
    /// window behind rather than taking this one over.
    private func openTheStore() {
        model.send(.openTab(
            space: nil,
            url: "https://chromewebstore.google.com/",
            parent: nil
        ))
    }

    /// Accepts a bare ID or any store URL containing one. Chrome IDs are 32
    /// characters drawn from a..p.
    private var extractedId: String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }

        // A full URL is the common case, so try the core's parser first.
        if let fromUrl = model.extensionId(inURL: trimmed) {
            return fromUrl
        }
        return isExtensionId(trimmed) ? trimmed : nil
    }

    private func isExtensionId(_ value: String) -> Bool {
        value.count == 32 && value.allSatisfy { ("a" ... "p").contains($0) }
    }

    private func install() {
        guard let id = extractedId else {
            failure = "That does not look like a store link or an extension ID."
            return
        }
        failure = nil
        installing = true

        Task {
            do {
                // Downloaded and unpacked, holding nothing. The dialog is what
                // turns that into an extension that runs.
                deciding = PendingConsent(request: try await model.installExtension(id: id))
                input = ""
            } catch {
                failure = error.localizedDescription
            }
            installing = false
        }
    }
}

/// What a row says about a package zer0 changed on the way in.
///
/// `nil` for a package nobody touched, which is most of them: a package with no
/// background, or one whose background is an HTML page, is installed exactly as
/// the store served it and has nothing to declare.
///
/// Lifted out of the view for the reason `ExtensionStatus` was: the only way to
/// find out what a row says must not be to photograph one. And it takes the
/// manifest rather than a `Bool` and two strings, because the core carries the
/// fact and the names in one record — a caller cannot obtain permission to say
/// "this was modified" without also being handed what to say (ADR-0100).
/// What this extension is allowed to start outside the browser.
///
/// A file-level function rather than a view method for the reason
/// `ExtensionStatus` is a file-level type: the sentence is the thing worth
/// asserting, and asserting it should not mean rendering a row and
/// photographing it.
///
/// `nil` for an extension that has been allowed nothing, which is nearly all of
/// them — a row that said "may start no programs" about every extension in the
/// browser would be noise that trains people past the one row that matters.
///
/// The paths are named in full and not counted. "May start 1 program" is the
/// shape of sentence ADR-0018 refuses: the number is true and the fact somebody
/// needs is which one.
func extensionProgramLine(_ programs: [String]) -> String? {
    guard let last = programs.last else { return nil }

    let named = programs.count == 1
        ? last
        : programs.dropLast().joined(separator: ", ") + " and " + last

    return "You allowed this extension to start \(named)."
}

func extensionModificationLine(_ manifest: ExtensionManifest) -> String? {
    guard let compat = manifest.compat, let last = compat.addedFiles.last else { return nil }

    // Two files where the extension's background is an ES module, one
    // otherwise, and the difference is not something a person should have to
    // know — so the sentence counts rather than assuming.
    let named = compat.addedFiles.count == 1
        ? last
        : compat.addedFiles.dropLast().joined(separator: ", ") + " and " + last
    let verb = compat.addedFiles.count == 1 ? "runs" : "run"

    return "zer0 changed this package: it added \(named), which \(verb) "
        + "before the extension's own \(compat.originalEntryPoint)."
}

/// Installed, running and holding what — in one sentence per state.
///
/// Lifted out of the view so the sentence can be asked for without rendering
/// anything. It used to be a private method reading `@Environment`, which meant
/// the only way to find out what a row says was to photograph one — and the
/// state that matters most here is the one a screenshot is least likely to
/// catch, because it arrives seconds after the row is first drawn.
struct ExtensionStatus {
    let summary: String
    let symbol: String
    let isRunning: Bool

    /// The core's standing, corrected by the one thing only the platform knows.
    ///
    /// **`backgroundFailed` is checked first and can only move the answer
    /// downward.** The core knows what was granted and that the context loaded;
    /// it cannot know that the background content then died, because that
    /// happens afterwards and WebKit tells nobody else. Read second — or not at
    /// all, which is what shipped — the row says *"Running with all 15
    /// permissions it asked for"* over an extension that never started, which
    /// is the browser vouching for something it has no evidence for (ADR-0072).
    ///
    /// Which state a row is in is otherwise the core's: this used to work it out
    /// here — read the ledger, count the grants, compare against the manifest —
    /// and the same arithmetic is now needed by the button injected into the
    /// store's page. Two copies of "is it running" is one copy too many, and the
    /// one that would be wrong is always the one on screen.
    static func of(standing: ExtensionStanding, backgroundFailed: Bool) -> ExtensionStatus {
        if backgroundFailed {
            return brokenBackground(standing)
        }

        switch standing {
        // A row exists, so it is on disk. `notInstalled` here means the
        // directory went out from under us between two draws, and the honest
        // thing is to say what we can see rather than invent a count.
        case .notInstalled:
            return ExtensionStatus(
                summary: "Not running. zer0 can no longer find it on disk.",
                symbol: "questionmark.circle",
                isRunning: false
            )
        case .undecided:
            return ExtensionStatus(
                summary: "Not running. You have not said what it may do yet.",
                symbol: "hand.raised",
                isRunning: false
            )
        case .grantedNothing:
            return ExtensionStatus(
                summary: "Not running. You granted it nothing.",
                symbol: "hand.raised",
                isRunning: false
            )
        case let .running(held, asked, _):
            return ExtensionStatus(
                summary: held < asked
                    ? "Running with \(held) of the \(asked) permissions it asked for."
                    : "Running with all \(asked) permissions it asked for.",
                symbol: "checkmark.seal",
                isRunning: true
            )
        }
    }

    /// What to say about an extension WebKit loaded and could not start.
    ///
    /// **Naming WebKit is only honest when nothing a person could have granted
    /// is missing.** A permission that is declared but not granted does not
    /// merely make its calls fail — WebKit leaves the whole namespace
    /// `undefined` in the background context. Measured: with `storage` declared
    /// and denied, `chrome.storage` is `undefined`, and a worker that touches it
    /// while starting dies with exactly the `backgroundContentFailedToLoad` this
    /// flag reads. Which is to say the browser can produce this state itself,
    /// out of a decision it recorded, and then blame the engine for it
    /// (ADR-0077).
    ///
    /// **But `held < asked` is the wrong question.** It is arithmetic, and
    /// arithmetic cannot tell a switch that would have helped from one that
    /// could not: `chrome.offscreen` is absent from a fully granted extension
    /// context whatever this browser records, so a row missing only that is a
    /// row being sent somewhere pointless. The core answers the question that
    /// matters instead — whether anything withheld is something this browser
    /// could actually provide (ADR-0084).
    ///
    /// What is provable in every arm is the shape and never the cause: WebKit
    /// reports one error for every way a worker can fail to come up.
    private static func brokenBackground(_ standing: ExtensionStanding) -> ExtensionStatus {
        // Where there is nothing on this screen to point at, the engine is the
        // only thing left to name (ADR-0072).
        let engineAlone = ExtensionStatus(
            summary: "Not running. WebKit could not start its background page.",
            symbol: "exclamationmark.triangle",
            isRunning: false
        )
        guard case let .running(held, asked, withheld) = standing else { return engineAlone }

        switch withheld {
        case .nothing:
            return engineAlone
        case .somethingProvidable:
            return ExtensionStatus(
                summary: """
                Not running. Its background page failed to start, and it is \
                holding \(held) of the \(asked) things it asked for — \
                switching one off can be enough to cause this.
                """,
                symbol: "exclamationmark.triangle",
                isRunning: false
            )
        case .onlyTheUnprovidable:
            // The counts stay, because they are the same numbers the running
            // state prints and the row a moment ago was one of them. What goes
            // is the invitation to go and flip something: there is nothing to
            // flip. No cause is named — a worker has plenty of other ways to
            // die, and this browser cannot tell which one happened.
            return ExtensionStatus(
                summary: """
                Not running. WebKit could not start its background page. It is \
                holding \(held) of the \(asked) things it asked for, and zer0 \
                cannot provide what is missing — no switch here would change that.
                """,
                symbol: "exclamationmark.triangle",
                isRunning: false
            )
        }
    }
}
