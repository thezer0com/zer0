import Foundation
import Zer0Core

/// Presentation-only conveniences over the core's tab record, which a uniffi
/// record cannot carry across the bridge.
///
/// Shared by both hosts' model code (titles in prompts and saves, hosts in
/// permission copy), which is why this is a file of its own rather than a
/// member of `Sidebar.swift`: the sidebar is macOS furniture, and these are
/// not. Anything that *decides* something belongs in the reducer.
extension BrowserTab {
    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        if let url, !url.isEmpty { return url }
        return "New Tab"
    }

    var host: String? {
        guard let url, let parsed = URL(string: url) else { return nil }
        return parsed.host()
    }
}
