import AppKit
import SwiftUI
import Testing
import Zer0Core

@testable import Zer0Shell

/// Looking at the three panels a page gets to summon.
///
/// Whether they are *correct* is `PageDialogTests`. The questions only a
/// rendered frame answers are the ones this change is actually about: whether
/// the page's own words read as the page's, whether the origin is the first
/// thing you can find, and whether an alert, a confirm and a prompt look like
/// one family rather than three.
///
/// **At window width, not component width.** A panel photographed at its own
/// 420 points fills the frame and tells you nothing about where it sits or how
/// much of the page it covers — which is how a bad layout got through here
/// before. These are rendered inside a scene the size the author's window is.
///
/// Opt-in. See `ZZShotHarness.swift`.
@MainActor
struct ZZPageDialogShots {
    /// A dialog built the way the core builds one, so the words on the picture
    /// are the real words rather than a second copy written here.
    private func dialog(
        kind: PageDialogKind,
        message: String,
        host: String = "example.com",
        nameless: Bool = false,
        offersSilence: Bool = false,
        truncated: Bool = false
    ) -> PageDialog {
        PageDialog(
            request: 1,
            tab: 1,
            window: 1,
            kind: kind,
            speaker: nameless
                ? .nameless(note: "This page has no address of its own, so there is "
                    + "nobody to hold to what it says.")
                : .site(origin: "https://\(host)", host: host),
            message: message,
            messageTruncated: truncated,
            offersSilence: offersSilence,
            // Nothing here dispatches, so the settle window has nothing to be
            // measured against. Zero rather than a plausible clock reading, so
            // nobody reads a time off a picture.
            askedAtMs: 0
        )
    }

    /// Over a page, because a `.regularMaterial` panel with nothing behind it is
    /// a grey rectangle and says nothing about what it looks like in use.
    private func scene(dark: Bool, @ViewBuilder content: () -> some View) -> some View {
        ZStack {
            LinearGradient(
                colors: dark
                    ? [Color(white: 0.16), Color(white: 0.09)]
                    : [Color(white: 0.97), Color(white: 0.88)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            content()
        }
        .preferredColorScheme(dark ? .dark : .light)
        // An offscreen window never becomes key, so without this every
        // `.borderedProminent` button draws grey and the picture says nothing
        // about which one answers Return (DESIGN.md §12).
        .environment(\.controlActiveState, .key)
    }

    /// The window the author uses, so a panel is seen at the size it is seen at.
    private static let window = CGSize(width: 1440, height: 900)

    @Test(
        "the three panels are one family",
        .disabled(if: ProcessInfo.processInfo.environment["ZER0_SHOT"] == nil)
    )
    func theThreePanelsAreOneFamily() {
        let cases: [(String, PageDialog)] = [
            ("alert", dialog(kind: .alert, message: "Your session has ended.")),
            ("confirm", dialog(
                kind: .confirm,
                message: "Delete this project? Everything in it goes with it."
            )),
            ("prompt", dialog(
                kind: .prompt(defaultText: "Untitled"),
                message: "What should this be called?"
            )),
        ]

        for dark in [false, true] {
            for (name, subject) in cases {
                let shot = Shot(size: Self.window) {
                    scene(dark: dark) {
                        PageDialogSheet(dialog: subject) { _, _ in }
                    }
                }
                // Past the settle window, so the buttons in the picture are the
                // ones a person sees rather than the dead half second.
                shot.advance(Double(promptSettleMs()) / 1000 + 0.2)
                shot.write("page-dialog-\(name)-\(dark ? "dark" : "light")")
            }
        }
    }

    /// The two cases the identity block has to survive: a page that has no
    /// address, and a page trying to write in our voice.
    @Test(
        "the page's words stay the page's",
        .disabled(if: ProcessInfo.processInfo.environment["ZER0_SHOT"] == nil)
    )
    func thePagesWordsStayThePages() {
        // Everything a spoof would reach for: our own product name, markdown
        // that `Text(_:)` would render, and a run of blank lines to push the
        // real sentence away from the origin line.
        let hostile = """
        **zer0 security notice**

        Your password has expired. [Sign in again](https://example.invalid) to \
        keep your account.

        \u{2014} zer0
        """

        for dark in [false, true] {
            let shot = Shot(size: Self.window) {
                scene(dark: dark) {
                    PageDialogSheet(
                        dialog: dialog(
                            kind: .confirm,
                            message: hostile,
                            host: "xn--80ak6aa92e.com",
                            offersSilence: true
                        )
                    ) { _, _ in }
                }
            }
            shot.advance(Double(promptSettleMs()) / 1000 + 0.2)
            shot.write("page-dialog-hostile-\(dark ? "dark" : "light")")

            let anonymous = Shot(size: Self.window) {
                scene(dark: dark) {
                    PageDialogSheet(
                        dialog: dialog(
                            kind: .alert,
                            message: "Saved.",
                            nameless: true
                        )
                    ) { _, _ in }
                }
            }
            anonymous.advance(Double(promptSettleMs()) / 1000 + 0.2)
            anonymous.write("page-dialog-nameless-\(dark ? "dark" : "light")")
        }
    }

    /// A page that writes far more than a panel can hold, and the sentence that
    /// says so. The scroll region is what stops the buttons being pushed off the
    /// bottom of the screen, and it is only visible here.
    @Test(
        "a page that will not stop talking",
        .disabled(if: ProcessInfo.processInfo.environment["ZER0_SHOT"] == nil)
    )
    func aPageThatWillNotStopTalking() {
        let long = (1...60)
            .map { "Line \($0) of something this page would like you to read." }
            .joined(separator: "\n")

        for dark in [false, true] {
            let shot = Shot(size: Self.window) {
                scene(dark: dark) {
                    PageDialogSheet(
                        dialog: dialog(
                            kind: .alert,
                            message: long,
                            offersSilence: true,
                            truncated: true
                        )
                    ) { _, _ in }
                }
            }
            shot.advance(Double(promptSettleMs()) / 1000 + 0.2)
            shot.write("page-dialog-long-\(dark ? "dark" : "light")")
        }
    }

    /// An empty message, which a page is allowed to send and which would
    /// otherwise be a recessed rectangle with nothing in it.
    @Test(
        "a message with nothing in it",
        .disabled(if: ProcessInfo.processInfo.environment["ZER0_SHOT"] == nil)
    )
    func aMessageWithNothingInIt() {
        let shot = Shot(size: Self.window) {
            scene(dark: false) {
                PageDialogSheet(dialog: dialog(kind: .alert, message: "")) { _, _ in }
            }
        }
        shot.advance(Double(promptSettleMs()) / 1000 + 0.2)
        shot.write("page-dialog-empty-light")
    }
}
