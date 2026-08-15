# ADR-0096: A page that stops is a state the tab outlives, and the reload belongs to a person

- **Status:** Accepted
- **Date:** 2026-08-10
- **Lock:** `apple/Tests/Zer0ShellTests/PageProcessTests.swift::PageProcessTests/aDeadPageIsAState`, `apple/Tests/Zer0ShellTests/PageProcessTests.swift::PageProcessTests/nothingReloadsItself`, `apple/Tests/Zer0ShellTests/PageProcessTests.swift::PageProcessTests/retryRecoversTheSameView`, `apple/Tests/Zer0ShellTests/PageProcessTests.swift::PageProcessTests/historySurvivesTheCrash`, `crates/zer0-core/src/navigation_state_tests.rs::a_page_whose_process_ended_says_so_and_keeps_the_address`, `crates/zer0-core/src/navigation_state_tests.rs::retrying_a_dead_page_asks_the_engine_to_load_it_again`

## Context

`webViewWebContentProcessDidTerminate` was not implemented anywhere in the
shell. WebKit's answer to an unimplemented optional is a documented default, and
this one's default is nothing at all: the view goes blank, `url` drops to `nil`,
no error is raised, nothing is logged, and no `Action` reaches the core. The tab
sits there looking like a page that is taking a very long time.

ADR-0086 enumerated it as one of six gaps and made a stronger claim beside it,
which is the reason this record exists rather than a two-line patch:

> Measured, after the web content process dies: […] `reload()` returns `nil`
> and produces no navigation at all, and an explicit `load()` had still not
> committed after eight seconds on a localhost page. […] So recovery is a
> *replacement*, not a reload, and code written the obvious way — call
> `reload()` from the terminate callback — would leave the tab exactly as dead.

**That is not what happens, and it was worth the day it cost to find out.** It
is corrected in ADR-0086 in place, and the correction is here because a reader
acting on that sentence would have decided differently: they would have built a
view-replacement path — a second `WKWebView`, a swap under a SwiftUI identity
that does not change, a back/forward list carried across by hand — and none of
it is needed.

### What was measured, and with what

The instrument first, because the first two attempts at this measurement were
wrong in the same direction and reported the same reassuring nothing.

`WKWebView._killWebContentProcess` — the obvious way to stage a crash — **does
nothing** when called from a test. The selector exists, `responds(to:)` is true,
the call returns, and afterwards `_webProcessIdentifier` is unchanged, `url` is
unchanged, `canGoBack` is unchanged and
`webViewWebContentProcessDidTerminate` never fires. A run built on it produces a
full page of measurements about a process that never died.

`kill(webProcess, SIGKILL)` is a crash WebKit did not agree to, which is what a
crash is. With it, and with the delegate method watched rather than assumed:

| | before | after |
|---|---|---|
| `webViewWebContentProcessDidTerminate` | — | fires, within one poll |
| `_webProcessIdentifier` | 38603 | 0 |
| `url` | the page | `nil` |
| `canGoBack` | true | **true** |
| `interactionState` | 1,064 bytes | **1,064 bytes** |

Then, on that same view:

- **`reload()` recovers it.** It returns a `WKNavigation`, commits, finishes and
  comes back with a new web process, in under 50ms. From inside the terminate
  callback, one run loop later, and three seconds later. Whether the view is in
  a visible window or in no window at all. `loadFileURL` on the address does the
  same. Left alone, the tab is still blank after eight seconds — which is the
  browser as it stood, and the defect.
- **The back/forward list is not the web process's to lose.** It lives in the UI
  process; a crash does not touch it.
- A fresh `WKWebView` handed the dead one's `interactionState` also restores
  everything, so replacement *would* have worked. It is simply the expensive way
  to reach the same place.

## Decision

**A page whose process ends is recorded as a failure on the tab, and nothing is
loaded until a person asks.** The view is kept.

Three parts.

**The host reports and does not decide.** `PageProcessHost.swift` implements the
one delegate method and its whole body is
`emitAction(.pageProcessEnded(tab: tab))`.

**The core turns it into the state ADR-0016 already draws.**
`NavigationErrorKind` gains `PageProcessEnded`, and the reducer fills
`last_error` with it, the address that died — read out of `pending_url` first,
so a page that died *while loading* still has one — and an **empty message**,
because WebKit reports the fact and no reason and inventing one is the find
bar's match count in another shape (ADR-0018). It clears the tint, the audio
flag and the pending navigation, and emits no commands at all.

**The retry is the same retry every other failed page has.** Return, or ⌘R,
through `Action::Reload`, which re-emits `LoadUrl` for the address that failed —
the path ADR-0016 built and the path measured recovering a dead view. The screen
says what is known and offers one thing:

> **avelino.run stopped responding**
> zer0 is still running, but the page isn't. Anything you had typed into it is
> gone. Reloading usually brings it back.

### Why the reload is not automatic

This is the part that will look like timidity later, so it is written down.

**A page can end its process while loading.** Reloading from the callback then
reloads into the same crash, forever, with a spinner on screen and nothing
saying why — a browser burning a core on a page nobody can see. There is no
counter that fixes this honestly: "retry twice then stop" is a number nobody can
justify and a rule that still loops twice on every crash of every tab.

**And the loss has already happened.** The form the person was filling in went
with the process. A tab that silently reloads itself is a tab that replaces
their half-written comment with a blank one and never mentions it. Saying so
costs one key press and buys the one thing that cannot be recovered afterwards:
knowing.

### Why the view is not replaced

Because it does not need to be, and because keeping it is free. A replacement
costs the scroll position, the zoom, the tab's place in the view hierarchy —
`SplitView` keys its container on the tab id, so a swapped view is a view
SwiftUI never asks for — and a generation counter somewhere to make that work.
All of it to reach a state a `reload()` reaches in 50ms.

## Consequences

**What we get.** A crashed tab is recoverable, is recoverable with the key
already under the finger, and says what happened while it waits. The tab keeps
its identity entirely: same `TabId`, same space, same cookie jar, same row in
the sidebar, same conversation anchored to its page (ADR-0060). Nothing about a
`WKWebView` dying is visible above the shell.

**What it costs, honestly:**

- **A background tab that crashes is not announced.** It carries the screen and
  waits to be looked at. That is deliberate — a notification for a page nobody
  is reading is worse — but it means a person can find a stopped page an hour
  later with no idea when it stopped.
- **We say "stopped responding" and cannot say why.** Out of memory, a bug in
  the site, a bug in WebKit: the person is told none of it, because we know none
  of it. Every browser that does say has more to read than a `WKWebView`
  delegate gives.
- **One measurement, one machine, one SDK.** macOS 26.5, local pages, killed
  with `SIGKILL`. A crash inside WebKit's own teardown, or one that takes the
  network process with it, is not covered by anything here.
- **`SIGKILL` and `_webProcessIdentifier` are SPI in the test suite.** The
  containment scan in `SourceRuleTests` covers `apple/Sources` and not the
  tests, so this is allowed and unpoliced. It is the only way to stage a real
  crash, and `_killWebContentProcess` — the sanctioned-looking one — was
  measured doing nothing.
- **A crash loop is still a crash loop, just a quiet one.** A page that dies on
  every load now gives an honest screen every time somebody presses Return. It
  does not get better; it just stops being the browser's fault.

## How this regresses

- **"The tab went white and stayed white."** The delegate method is renamed,
  moved, or ends up on a class that is not the navigation delegate. There is no
  compiler error and no failing test unless something asks whether the callback
  *arrives* — which is the trap ADR-0086 named and the reason
  `aDeadPageIsAState` waits on the core's `lastError` rather than on a counter
  of its own.
- **"It reloaded on its own and I lost what I was typing."** Somebody adds the
  reload to the terminate callback, because it reads as the completion of a
  half-done fix. `nothingReloadsItself` is what stands in the way, and it is the
  only test here that asserts an absence.
- **"The browser hung and the fan came on."** The same change, on a page that
  dies during load. The reload is a loop and nothing on screen says so.
- **"Try Again does nothing."** Someone concludes from ADR-0086's uncorrected
  sentence that a reload cannot work on a dead view and builds a replacement
  path — and gets it subtly wrong, because the SwiftUI identity does not change
  when the view does. `retryRecoversTheSameView` asserts the view is the same
  object and the page is back.
- **"Back stopped working after a crash."** A replacement view with no history
  carried across. `historySurvivesTheCrash` covers it, and covers it *without*
  the session store, because this list never went to disk in the first place.
- **"It says the page stopped, on a page that loaded."** `NavigationStarted`
  stops clearing `last_error`. Already locked by
  `a_successful_reload_clears_the_error` from ADR-0016; named here because this
  kind arrives without a navigation and is the one most likely to get stuck.

## When to revisit

- If WebKit ever reports *why* a process ended. The screen has a sentence
  waiting for it, and ADR-0018 turns from forbidding the claim to requiring it.
- If a crash loop turns out to be common in real use. The answer is not a retry
  counter; it is a screen that says this page has stopped more than once, which
  is a fact we would then have.
- If a page's process is measured ending in a way a reload does **not** recover.
  Then replacement earns its cost, and it should be built with the SwiftUI
  identity problem solved first, not second.
- When there is a second shell. `webkit2gtk` reports the same fact with a
  reason attached (`WebKitWebProcessTerminationReason`), which is more than
  WebKit gives — and the moment `PageProcessEnded` should stop being a kind with
  no data on it.
