import Foundation
import Zer0Core

/// Field access, not policy.
///
/// A uniffi record carries no methods across the bridge, and asking the core
/// "is this tab in the split" once per sidebar row would be an FFI crossing to
/// answer a comparison. Anything that *decides* something — where the divider
/// may go, when a split ends — stays in Rust.
///
/// Shared by both hosts' model code (the keyboard's "other pane", the tab
/// bookkeeping that reads a split), which is why this is a file of its own
/// rather than a member of `SplitView.swift`: the split view is macOS
/// furniture, and this is arithmetic on a record.
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
