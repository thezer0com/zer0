import AppKit

/// The one place in this suite that makes an `NSWindow`.
///
/// `isReleasedWhenClosed` is `true` on every window built from an initialiser,
/// and it predates ARC: `close()` releases the window on the window's behalf.
/// A test that also holds the window in a `let` therefore owns a reference
/// AppKit has already spent, and `close()` costs a retain the test still needs.
///
/// **The second release does not land where it was caused.** It arrives when
/// the autorelease pool drains, which is at the end of some later main-queue
/// job, so the process dies in `objc_release` under `objc_autoreleasePoolPop`
/// with nothing of ours on the stack and a different test in flight each run.
/// That reads as flakiness in whatever was unlucky, which is why it survived
/// two days of "green on my slice": the suite died after `EnginePolicyTests`
/// passed, and `EnginePolicyTests` was where the window was.
///
/// Six of the thirteen windows in this suite remembered the flag. Two of the
/// seven that did not went on to call `close()`, and that was the whole defect.
/// A rule held at thirteen call sites is twelve bugs waiting (AGENTS.md), so
/// there is one call site now, and `WindowOwnershipTests` in
/// `SourceRuleTests.swift` keeps it that way.
///
/// `backing` and `defer` are not parameters because every window here wants the
/// same answer to both, and an argument nobody varies is an argument somebody
/// eventually gets wrong.
@MainActor
func testWindow(
    _ contentRect: CGRect,
    styleMask: NSWindow.StyleMask = [.titled, .closable]
) -> NSWindow {
    let window = NSWindow(
        contentRect: contentRect,
        styleMask: styleMask,
        backing: .buffered,
        defer: false
    )
    // The line this file exists for. Without it the caller and AppKit each
    // think they hold the last reference.
    window.isReleasedWhenClosed = false
    return window
}
