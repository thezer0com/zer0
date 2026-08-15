# ADR-0067: The Web Inspector is the one SPI, reached by name at runtime

- **Status:** Accepted. Narrows ADR-0001's refusal of SPI — see *Decision* for the sentence.
- **Date:** 2026-07-23
- **Lock:** `crates/zer0-core/src/shortcuts.rs::both_inspector_chords_arrive_and_shift_is_the_one_linux_keeps`, `apple/Tests/Zer0ShellTests/WebInspectorTests.swift::WebInspectorTests/bothInspectorChordsArriveFromARealPress`, `apple/Tests/Zer0ShellTests/WebInspectorTests.swift::WebInspectorTests/theInspectorIsStillBehindTheDoor`, `apple/Tests/Zer0ShellTests/WebInspectorTests.swift::WebInspectorTests/aPageIsInspectableBeforeAnybodyAsks`, `apple/Tests/Zer0ShellTests/WebInspectorTests.swift::WebInspectorTests/openingTheInspectorDoesNotThrowThePageAway`, `apple/Tests/Zer0ShellTests/SourceRuleTests.swift::SpiContainmentTests/noShellSourceOutsideTheOneFileSpellsAnSpi`

## Context

`UiCommand::ToggleDevTools` existed, bound to ⌥⌘I, and did not open anything.
What it did was set `WKWebView.isInspectable = true` and reload the page. So the
entire observable effect of the shortcut was that the page came back: scroll
position gone, half-typed form gone, no inspector. That is worse than an unbound
key. An unbound key does nothing; this one took something away and gave nothing
back.

The reason it was written that way is that the public API stops one step short.
Measured on the macOS 26.5 SDK rather than assumed:

- `WKWebView.h` declares exactly one inspector-related member,
  `@property (nonatomic, getter=isInspectable) BOOL inspectable`, available
  since macOS 13.3. There is nothing else. No `showInspector`, no controller,
  no notification.
- `_WKInspector` is real and is SPI. `WebKit.tbd` exports it alongside
  `_WKInspectorShow`, `_WKInspectorHide`, `_WKInspectorAttach`,
  `_WKInspectorIsVisible` and a dozen more; the runtime confirms the class
  responds to `show`, `hide`, `attach`, `detach`, `isVisible`, and that
  `WKWebView` responds to `_inspector`. Every one of those names is
  underscored.

So `isInspectable` makes a view *attachable* and nothing public *opens* the
inspector. That is not a gap somebody forgot to fill; it is where Apple drew the
line.

**And it takes three private calls, not one.** This was measured rather than
assumed, and each one is the reason a simpler version of this change does not
work:

1. With `isInspectable` set and nothing else, `_WKInspector` is there, `show`
   returns cleanly, and `isVisible` stays `false`. Nothing opens. WebKit gates
   the *local* inspector on a `developerExtrasEnabled` preference that
   `WKPreferences` does not publish either — the accessors it really has are
   `_developerExtrasEnabled` and `_setDeveloperExtrasEnabled:`, reachable
   through KVC's underscore fallback.
2. With both on, `show` opens the inspector — docked into the SwiftUI view that
   hosts the page, where the next layout pass covers it. `isVisible` says
   `true`; the screen shows nothing.
3. `detach` moves it into a window of its own, and that is the first state in
   which a person can actually see it — but only if it is asked *after* the
   frontend is up. Called in the same breath as `show` it is a silent no-op,
   because there is nothing attached yet to detach, and the inspector then
   comes up docked and stays there.

What `isInspectable` alone buys, and the reason it is worth setting on every
page whatever happens to the rest: it is what lets **Safari's Develop menu**
attach to our web views. That route is entirely public API and cannot be taken
away by anything discussed here. What it is not, is a key you can press in our
own app.

ADR-0001 refused SPI. It was arguing about `_WKFeature` and `WKPreferences._features`
— experimental feature flags — and its stated fear is precise and correct:
*"the build passes and Apple's next point update breaks the app with no
warning."*

## Decision

**The Web Inspector is one exception to ADR-0001, and the only one.**

This supersedes one sentence of ADR-0001, in its "Trivial things have no public
API" neighbourhood: *"We decided not to use SPI, so a feature behind a flag
simply does not exist for us."* That sentence stands for feature flags, which is
what it was written about, and no longer stands as a rule about SPI in general.
The regression symptom ADR-0001 names — *"reaching for underscored SPI to unlock
a feature"* — also survives, minus this one use.

Three things make the exception affordable, and it is only affordable because of
all three.

**It is not on the browsing path.** Nobody's page fails to load because the
inspector went away. Devtools is a tool for the person building the browser and
the person debugging a site; a browser with no inspector is a worse tool and a
working browser. That asymmetry is the entire case, and it does not extend to
feature flags, content-blocking internals, or anything a page depends on.

**It is reached by name at runtime, never linked, and never unguarded.**
`_WKInspector`, `_inspector` and the preference are strings looked up through
the Objective-C runtime at the moment they are used. This is the part that
answers ADR-0001's fear directly: a private *header* turns Apple deleting a
symbol into a dyld failure at launch on somebody's machine, with nothing we can
do about it from here. A runtime lookup turns the same deletion into `nil`,
which is a value the shell can see, act on, and explain.

The guard is not a formality, and one of these two is genuinely dangerous
without it. `setValue(_:forKey:)` against a key that no longer exists raises
`NSUnknownKeyException`, and an Objective-C exception is not something Swift can
catch — unguarded, Apple removing that preference would take the process down on
every tab, at launch, which is strictly worse than the link-time failure ADR-0001
was afraid of. So `allowInspection` asks `WKPreferences` whether it still
responds to `_setDeveloperExtrasEnabled:` before writing anything. The failure
mode is downgraded from "the app does not start" to "one shortcut says it cannot
do this, and points at the route that still works".

**It is confined to one file, structurally.** Every private spelling — the
class, the accessor, the preference, `show`, `hide`, `detach` — lives in
`apple/Sources/Zer0Shell/WebInspector.swift`. A source scan over the shell fails
on `_WK`, `_features`, `_inspector`, `developerExtrasEnabled` or
`_setDeveloperExtrasEnabled:` appearing in any other file. ADR-0001 asked for
exactly this and said it did not exist — *"A `grep` for `_WK` and `_features`
under `apple/Sources/` inside `scripts/check.sh` would cover half the risk, and
it does not exist"* — so it exists now, and it is stricter than the sentence that
asked for it: it reads string literals, so a name reached through the runtime is
caught rather than hidden inside quotes, and it covers the private preference,
which is not underscored at the call site and would otherwise look like ordinary
configuration.

**Separately, and not conditional on any of the above: the reload is gone.**
Both switches are set when the web view is built, in `HostedWebView.init`, not
the first time somebody presses the shortcut. Neither reaches a page that has
already loaded, which is why the old code reloaded; setting them at birth
removes the reason. It also makes Safari's Develop menu true from the first page
rather than after a round trip.

**Toggling reads WebKit's state rather than remembering our own, and that state
is not symmetric.** `hide` clears `isVisible` before it returns; `show` sets it
about 150ms later, once the frontend is up. So a second press inside that window
sees `false` and shows again, which is a no-op — every press at human speed
toggles. Remembering here what we last asked for would be a second copy of state
that goes wrong the moment somebody closes the inspector with its own button.

**The chord is ⌥⌘I and ⇧⌘I, both.** ⌥⌘I is Chrome-on-Mac's and Safari's, is
listed first, and is what the menu prints. ⇧⌘I is what Chrome publishes
everywhere that is not a Mac, and it is the only one of the two that survives
the collapse to a Control primary (ADR-0012): on Linux it lands on Ctrl+Shift+I,
which is Chrome's chord there, while ⌥⌘I collapses to Ctrl+Alt+I, which is
nobody's. Two chords for one command is the pattern Downloads already set —
⇧⌘J and ⌥⌘L — for the same reason: where the browsers disagree, taking both
beats picking a loser.

The split holds. The chord and the command are core; `WebInspector.swift` is a
platform detail and the core never learns it exists.

## Consequences

The day `_WKInspector` disappears, this is what happens, in order: the canary
test goes red on whoever runs the suite next; ⌥⌘I and ⇧⌘I stop opening anything
and put up a sheet naming the route that still works; Safari's Develop menu
keeps working, because `isInspectable` is public and never needed the private
half; and this ADR's revisit trigger fires. Nothing crashes and nothing else in
the browser notices. The same is true, separately, if the preference goes
instead — that path is guarded rather than caught, because it cannot be caught.
That is the whole exposure, and it was chosen rather than inherited.

Two costs are real and are accepted:

- **The App Store is closed to this build.** Private API use is a review
  rejection, and this is private API use. Notarisation does not inspect for it,
  so direct distribution is unaffected — but if an App Store path ever becomes
  the plan, `WebInspector.swift` is the file to delete, and deleting it leaves a
  browser whose devtools go through Safari's Develop menu.
- **A third private call, and it is not optional.** WebKit's default is to dock
  the frontend into the inspected view's superview, and in this shell that
  superview belongs to SwiftUI. Measured: the frontend lands inside
  `AppKitPlatformViewHost<PlatformViewRepresentableAdaptor<WebViewContainer>>`,
  SwiftUI lays the page straight back over the whole host on the next pass, and
  `isVisible` reports `true` over something nobody can see — the exact shape of
  lie ADR-0018 exists to forbid, arrived at by accident. `detach` fixes it and
  produces a real `_WKInspectorWindow` carrying the page's title.

  So `toggle` shows, then waits for `isVisible` and detaches — a bounded wait,
  a second at most, because a poll with no end is how a temporary loop becomes
  permanent. It only has to work once per person: **WebKit writes the dock side
  into the app's user defaults**, so every later press opens detached on its own
  and the wait finds it already out.

  Two caveats worth recording, both of which cost time. `detach` **deadlocks**
  when the inspected web view *is* its window's `contentView` — what a bare
  AppKit probe looks like, never what this shell looks like; if a web view is
  ever hosted without SwiftUI in between, that call is the first place to look.
  And that same persisted dock side is a trap for the test: on a machine that
  has run it before, WebKit opens the inspector detached whether or not the code
  still asks, so the test clears the key first and every run genuinely exercises
  the detach. Without that line it was green with the fix deleted.
- **A greyed-out future.** If Apple keeps the class and renames the methods, the
  canary catches the rename rather than the removal, which is the same red for a
  different reason. That is on purpose: the test asks about `show`, `hide` and
  `isVisible` by name, because a class that survived with its methods renamed is
  the same outage.

**What was measured, and what was not.** On macOS 26.5, a Web Inspector really
opened, in its own window, over a SwiftUI-hosted `WKWebView` built the way this
shell builds them — Elements, Console, Sources, Network, the DOM tree, the
computed-style panel, the lot — and it was photographed rather than inferred.
`openingTheInspectorDoesNotThrowThePageAway` presses the command through the
shell, waits for WebKit to report the frontend up, requires that it has a window
that is not the page's, and reads a value back out of the page to prove it was
not reloaded. The three-call finding, the ~150ms delay on `isVisible`, the
docking behaviour and the `detach` deadlock were all established the same way.

Not measured, and so not claimed anywhere in the product copy: whether the
page's own context menu carries **Inspect Element**. WKWebView builds that menu
out of process and `menu(for:)` returns nil, so short of a person right-clicking
there is nothing to read. The alert names Safari's Develop menu only, which is
what public API actually promises.

## How this regresses

**The reload comes back.** Somebody notices the two switches sitting in
`HostedWebView.init` and thinks they are wasteful on a page nobody will ever
inspect, moves them to the moment of first use, and has to add the reload back
to make them take. This is the shape AGENTS.md warns about: the regression that reads
as an improvement. `openingTheInspectorDoesNotThrowThePageAway` is what goes red,
and it asks through a value set on `window` rather than through `webView.url`,
because a reload lands on the same URL and would leave a URL check green.

**The exception stops being one.** The second SPI is always easier to justify
than the first, and it arrives as "well, we already do it for the inspector".
`noShellSourceOutsideTheOneFileSpellsAnSpi` is the answer, and it is a lint
rather than a rule in a file because a rule in a file is a wish.

**The detach goes, as a simplification.** It reads like a preference — "let
WebKit dock it where it likes" — and it is not one: docked, in this shell, means
invisible. The lock is the assertion that the inspector ends up in a window that
is *not* the one showing the page, and it is deliberately not an assertion on
`isVisible`, which was `true` throughout the version where nothing appeared on
screen. The test hosts the web view in `WebViewContainer` inside an
`NSHostingView`, because that is what puts the SwiftUI view in the middle — a
bare web view with no window cannot tell docked from detached, and the first
draft of this test was green with the fix deleted for exactly that reason.

**The scan quietly stops matching.** A containment scan passes both when nothing
violates it and when its needles have gone stale. Two things guard that: the
needles are read off `WebInspector` itself rather than copied into the test, and
`theOnePermittedUseIsStillWhereItIsPermitted` fails if the one permitted use
leaves the one permitted file.

**⇧⌘I gets tidied away** as a duplicate of ⌥⌘I by someone who has only ever used
a Mac. It is the binding that keeps the inspector reachable on the Linux host,
and `both_inspector_chords_arrive_and_shift_is_the_one_linux_keeps` asserts the
collapsed form as well as the Apple one.

## When to revisit

Three triggers, all named:

1. **WebKit grows a public way to open the inspector.** Take it the same day and
   delete `WebInspector.swift`; this ADR's whole justification is the absence of
   one. The two source-scan tests are what will notice the file changing shape.
2. **`theInspectorIsStillBehindTheDoor` goes red.** The symbol is gone. Decide
   between the public path alone and whatever replaced it, and record the answer
   here — the fallback shipping quietly is not the same as the decision having
   been made.
3. **An App Store path becomes the plan rather than an idea.** Then the cost
   above is no longer theoretical and the exception has to be paid for or
   dropped.

Outside those three, never — and in particular, this ADR is not a precedent for
a second SPI. The argument above is about a tool that is not on the browsing
path; anything a page depends on is still governed by ADR-0001.
