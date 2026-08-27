import Testing
import Zer0Core

@testable import Zer0Shell

/// The feedback a finished image copy leaves, and the timer that takes it
/// away (issue #124, ADR-0091's revisit).
///
/// Driven through `engine.imageCopyReported` — the same closure the host
/// calls when a copy answers — because the model's half is what is being
/// held here: an outcome becomes a notice, a newer copy replaces an older
/// one, and only the notice a timer was armed for is the one it may clear.
/// `ImageCopyTests` holds the fetch and the outcome contract; what the
/// strip looks like over a page is for the looking harness, not an
/// assertion.
@MainActor
struct ImageCopyNoticeTests {
    private func model() -> BrowserModel { BrowserModel(storagePath: nil) }

    @Test("an outcome becomes a notice a view can watch")
    func anOutcomeBecomesANotice() {
        let model = model()
        let window = model.snapshot.keyWindow
        #expect(model.imageCopyNotice(in: window) == nil)

        model.engine.imageCopyReported?(window, .copied)
        #expect(model.imageCopyNotice(in: window)?.outcome == .copied)

        model.engine.imageCopyReported?(window, .failed(.notAnImage))
        #expect(model.imageCopyNotice(in: window)?.outcome == .failed(.notAnImage))
    }

    @Test("a copy notice belongs only to the window that started it")
    func noticesStayInTheirOriginatingWindow() throws {
        let model = model()
        let first = model.snapshot.keyWindow
        model.send(.openWindow(onto: .currentSpace))
        let second = model.snapshot.keyWindow
        #expect(first != second)

        model.engine.imageCopyReported?(first, .copied)

        #expect(model.imageCopyNotice(in: first)?.outcome == .copied)
        #expect(model.imageCopyNotice(in: second) == nil)
    }

    /// The hazard is a race the cancellation alone cannot close: a timer
    /// that already slept past its cancellation still runs its tail. The id
    /// a timer carries is what makes the clear conditional, so the tail is
    /// fired here by hand — the older timer's arm, held against a newer
    /// notice — because sleeping past two live timers proves only that the
    /// notice went, whichever timer took it.
    @Test("an older timer cannot clear a newer copy's notice")
    func anOlderTimerLeavesANewerNoticeAlone() throws {
        let model = model()
        let window = model.snapshot.keyWindow
        model.engine.imageCopyReported?(window, .copied)
        let older = try #require(model.imageCopyNotice(in: window)?.id)

        // A second copy replaces the first's feedback: the newest outcome
        // is the one being waited on.
        model.engine.imageCopyReported?(window, .failed(.tooLarge))
        #expect(model.imageCopyNotice(in: window)?.outcome == .failed(.tooLarge))

        // The first copy's timer, firing late, must find nothing it was
        // armed for.
        model.retreatImageCopyNotice(in: window, ifItIs: older)
        #expect(model.imageCopyNotice(in: window)?.outcome == .failed(.tooLarge))

        // Its own timer is the one that may clear it.
        let newer = try #require(model.imageCopyNotice(in: window)?.id)
        model.retreatImageCopyNotice(in: window, ifItIs: newer)
        #expect(model.imageCopyNotice(in: window) == nil)
    }

    /// The one test that pays `linger`'s five seconds. The guard above
    /// cannot prove a timer was armed at all — only that it behaves once it
    /// fires — and a notice that never left would be furniture, which is
    /// the one thing `Duration.linger` exists to prevent. The deadline is
    /// generous because the main actor is one lane under the full suite and
    /// everything here resumes late or not at all until it frees up.
    @Test("the notice leaves on its own after linger")
    func theNoticeRetreatsOnItsOwn() async {
        let model = model()
        let window = model.snapshot.keyWindow
        model.engine.imageCopyReported?(window, .failed(.unreachable))
        #expect(model.imageCopyNotice(in: window) != nil)

        #expect(await eventually(timeout: .seconds(20)) {
            model.imageCopyNotice(in: window) == nil
        })
    }
}
