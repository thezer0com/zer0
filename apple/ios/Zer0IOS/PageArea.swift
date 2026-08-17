import SwiftUI
import WebKit
import Zer0Core

/// Hosts a tab's web view. Keyed by tab id so switching tabs swaps the view
/// instead of mutating one in place — the same contract the macOS container
/// carries, for the same reason: the view belongs to the engine and is
/// reparented, never rebuilt.
struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context _: Context) -> WKWebView { webView }
    func updateUIView(_: WKWebView, context _: Context) {}
}

/// WebKit's own estimate of the page in flight, published as it moves.
///
/// The core knows a page is loading but not how far along it is; the engine
/// under the view does. This carries that number and nothing else — no
/// smoothing, no floor — so a determinate bar fed by it can only ever say
/// what the engine actually reported (ADR-0018: the interface asserts what
/// the layer beneath can back up).
@MainActor
private final class LoadProgress: ObservableObject {
    @Published var value: Double = 0
    private var observation: NSKeyValueObservation?

    func track(_ webView: WKWebView) {
        observation = webView.observe(\.estimatedProgress, options: [.initial, .new]) { [weak self] _, change in
            guard let value = change.newValue else { return }
            // KVO notes arrive on whatever thread moved the value; the hop
            // keeps "this is main-actor state" a checked fact rather than an
            // assumption. The number is read from the note, never from the
            // view, so this closure does not touch the engine off its actor.
            Task { @MainActor [weak self] in self?.value = value }
        }
    }
}

/// The page in front, or — when there is no page — the screen that says so
/// and offers the one way out of it.
struct PageArea: View {
    @Environment(BrowserModel.self) private var model

    let startNewTab: () -> Void

    @StateObject private var progress = LoadProgress()

    var body: some View {
        if let tab = model.activeTab {
            content(tab)
        } else {
            nothingOpen
        }
    }

    @ViewBuilder
    private func content(_ tab: BrowserTab) -> some View {
        if internalAddress(url: tab.url ?? "") != nil {
            // One of the browser's own pages. Each is native views on the
            // macOS host and none of them is built for this one yet; the web
            // view under this address is never navigated, so a blank rectangle
            // would be claiming a page loaded. Named and refused instead —
            // an honest absence, not a white lie.
            internalPageMissing
        } else if let webView = model.engine.webView(for: tab.id) {
            WebViewContainer(webView: webView)
                .id(tab.id)
                .overlay(alignment: .top) { loadingBar(tab) }
                // Re-pointed whenever the front tab changes: each page's
                // engine view carries its own estimate.
                .task(id: tab.id) { progress.track(webView) }
        }
        // No view yet is a frame between the core's dispatch and the engine's
        // perform, not an error screen. It has never survived a layout pass.
    }

    /// The only thing allowed to sit on top of a page, and only while loading
    /// (ADR-0010). Two points — `Stroke.insertion`, the weight this shell
    /// gives a line that is the whole answer to a question — filled in the
    /// accent the root already wears.
    ///
    /// The fill is the engine's own estimate and nothing else. The Mac wears
    /// this same 2pt as an indeterminate sweep because nothing there feeds it
    /// a number; here the engine's estimate is one KVO read away, and a real
    /// fill beats a fake sweep — a determinate bar over an unknown length is
    /// the download shelf's exact lie, one screen over (ADR-0018).
    private func loadingBar(_ tab: BrowserTab) -> some View {
        ZStack(alignment: .top) {
            if !tab.loadingComplete {
                ProgressView(value: progress.value)
                    .progressViewStyle(.linear)
                    .frame(height: Design.Stroke.insertion)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .motion(.subtle, value: tab.loadingComplete)
    }

    private var internalPageMissing: some View {
        EmptyState(
            glyph: {
                Zer0MarkGlyph(side: Design.Glyph.icon)
                    .foregroundStyle(.tertiary)
            },
            title: "Not on this phone yet",
            message: "This is one of zer0's own pages. It opens in the Mac app; "
                + "the work of drawing it here has not been done."
        ) {}
        .background(.background)
    }

    /// The browser with nothing in it: the first screen of the first day, and
    /// the one that comes back every time the last tab closes. The same words
    /// the macOS screen says, because it is the same screen.
    private var nothingOpen: some View {
        EmptyState(
            glyph: {
                Zer0MarkGlyph(side: Design.Glyph.mark)
                    .foregroundStyle(.tertiary)
            },
            title: "Nothing open",
            message: "Open a tab and zer0 asks where to: an address, a search, "
                + "or somewhere you have already been."
        ) {
            Button("New Tab", action: startNewTab)
                .buttonStyle(.borderedProminent)
        }
        .background(.background)
    }
}
