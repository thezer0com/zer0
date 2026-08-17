import SwiftUI
import Zer0Core

/// A page's question, waiting on an answer.
///
/// `PageDialog` comes from the core and carries no identity, which
/// `.sheet(item:)` needs. The request number is the identity: it is monotonic
/// and never reused, so a sheet cannot be recycled for the next question and
/// carry the last one's words for a frame.
///
/// Off `PageDialogSheet.swift` because the model names the pending question —
/// the macOS sheet draws it, and a host with its own dialog UI reads the same
/// value without inheriting this platform's sheet.
struct PendingPageDialog: Identifiable {
    let dialog: PageDialog
    var id: UInt64 { dialog.request }
}

/// A question a page asked, waiting on an answer.
///
/// `SitePermissionPrompt` comes from the core and carries no identity, which
/// `.sheet(item:)` needs. The request number is the identity: it is monotonic
/// and never reused, so a sheet cannot be recycled for the next question and
/// carry the last one's words for a frame.
///
/// Off `SitePermissionSheet.swift` for the same reason as
/// `PendingPageDialog` above: the value is the model's to name, the sheet is
/// macOS's to draw.
struct PendingSitePermission: Identifiable {
    let prompt: SitePermissionPrompt
    var id: UInt64 { prompt.request }
}
