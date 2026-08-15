import SwiftUI
import Zer0Core

/// The browser's own pages, drawn in a tab.
///
/// The switch is exhaustive and stays that way: an address added to the core
/// with no screen behind it breaks this build rather than rendering nothing,
/// which is the same rule every other switch over the shared vocabulary follows
/// (ADR-0031).
///
/// Only the addresses whose effect is `Page` reach here. Settings is the one
/// that raises a window instead, so no tab is ever holding it — but it is still
/// listed, because the alternative is a `default:` and a `default:` is what
/// turns "we forgot" into "it drew a blank rectangle" (ADR-0054).
struct InternalPageArea: View {
    let address: InternalAddress
    let tab: TabId

    var body: some View {
        switch address {
        case let .chat(conversation):
            ChatPage(tab: tab, addressed: conversation)

        case .history:
            HistoryPage()

        case .downloads:
            DownloadsPage()

        case .settings:
            // Unreachable by construction: it resolves to `Effect.window`, so
            // the core raises a window and never commits the address to a tab.
            // Stated rather than left to a wildcard, so that the day settings
            // becomes a page too this is where the compiler sends whoever does
            // it.
            EmptyView()
        }
    }
}
