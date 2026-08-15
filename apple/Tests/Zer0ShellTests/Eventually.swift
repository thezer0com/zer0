import Foundation

/// Waits for a condition to hold, instead of guessing how long it takes.
///
/// A fixed sleep is a flaky test by construction: whatever margin looks
/// generous on an idle machine evaporates the moment the suite runs under load,
/// and the failure lands on whoever is unlucky rather than on whoever broke
/// something. Polling costs nothing on the happy path — it returns the instant
/// the condition holds — and only spends the deadline when something is
/// genuinely wrong.
///
/// The deadline is deliberately far longer than the thing being waited for.
/// It exists to turn a hang into a readable failure, not to be a timing
/// assertion of its own.
///
/// Which is why the default is ninety seconds and not the thirty it used to be.
/// Thirty was the same order as the whole run, so it was not a hang detector at
/// all. swift-testing puts all five hundred tests in flight at once, nearly all
/// of them are `@MainActor`, and the main actor is one lane. Measured under a
/// full suite: a `Task.sleep(for: .milliseconds(25))` on that actor resumed
/// **6.4 seconds** later, six hundred main-actor sleeps scheduled two seconds
/// out all resumed together **twenty-four seconds** later, and a whole run took
/// 26–40 seconds. A poll expecting six hundred turns gets two, and the deadline
/// stops detecting hangs and starts asserting how busy the machine is — which
/// is how a correct test goes red on whoever is unlucky.
///
/// Ninety is above everything measured with room to spare, and deliberately not
/// higher: the deadline is also what a genuine hang costs, once per call site,
/// and ADR-0030 is right that a slow gate is a gate people stop running.
///
/// None of this reads a meaning into the number, because no caller has one:
/// every one waits for an event that either arrives or does not. A deadline
/// that *is* load-bearing — one that has to beat another timer — cannot be
/// expressed as a deadline at all, and needs something that tells the two
/// apart. `BrowserModel.firstSaveWritten` is what that looks like.
///
/// **The condition may be `async`, and that is what keeps this the one door.**
/// A fact that lives inside a page can only be read by awaiting
/// `evaluateJavaScript`, which a synchronous closure cannot do — so three test
/// files grew hand-rolled copies of this loop carrying their own ten, fifteen
/// and twenty second deadlines, every one of them below the delays measured
/// above. A synchronous closure still satisfies an `async` parameter, so every
/// existing caller is unchanged and there is nothing left to justify a second
/// copy.
@MainActor
func eventually(
    timeout: Duration = .seconds(90),
    polling every: Duration = .milliseconds(25),
    _ condition: () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        // Yielding the main actor is the point: the work being waited on is
        // almost always a task that needs this actor to make progress.
        try? await Task.sleep(for: every)
    }
    return await condition()
}
