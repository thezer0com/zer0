# ADR-0075: A page may open a view, and the core decides what that view is

- **Status:** Accepted
- **Date:** 2026-08-08
- **Lock:** `crates/zer0-core/src/reducer_tests.rs::a_page_that_described_no_window_gets_a_tab_beside_the_page_that_asked`, `crates/zer0-core/src/reducer_tests.rs::a_page_that_described_a_window_gets_one_onto_the_space_it_came_from`, `crates/zer0-core/src/reducer_tests.rs::a_pop_up_stays_in_the_space_the_page_that_opened_it_is_in`, `crates/zer0-core/src/reducer_tests.rs::a_pop_up_from_a_tab_that_is_gone_opens_nothing`, `crates/zer0-core/src/reducer_tests.rs::only_a_page_that_opened_a_tab_can_close_it`, `crates/zer0-core/src/reducer_tests.rs::a_window_a_page_opened_goes_with_the_page_that_closes_itself`, `crates/zer0-core/src/reducer_tests.rs::a_page_asked_for_a_window_only_when_it_described_one`, `crates/zer0-core/src/store_tests.rs::popup_blocking_ships_on_and_survives_being_turned_off`, `apple/Tests/Zer0ShellTests/PopupTests.swift::PopupTests/aPageOpensAWindowAndTheFlowItExistsForWorks`, `apple/Tests/Zer0ShellTests/PopupTests.swift::PopupTests/aLinkThatAsksForANewTabOpensOne`, `apple/Tests/Zer0ShellTests/PopupTests.swift::PopupTests/aPopUpFromAPrivateWindowStaysPrivate`, `apple/Tests/Zer0ShellTests/PopupTests.swift::PopupTests/aPopUpIsTheSameKindOfClientAsItsOpener`, `apple/Tests/Zer0ShellTests/PopupTests.swift::PopupTests/aPageCannotCloseATabAPersonOpened`, `apple/Tests/Zer0ShellTests/PopupTests.swift::PopupTests/aPageCannotOpenAWindowUnpromptedAndTheSwitchIsWhatLetsIt`, `apple/Tests/Zer0ShellTests/PopupTests.swift::PopupTests/aPagesWindowIsOpenedInOnePlaceAndAdoptedInOnePlace`

## Context

**`window.open` did nothing.** Not "opened in the wrong place", not "opened
without the opener" — nothing at all. No window, no tab, no error, no console
message. Measured before any of this was built, with a real page in a real
window in the real browser:

```
window.open('about:blank', '_blank', 'width=400,height=500')  ->  null
tabs before / after                                           ->  1 / 1
```

WebKit's contract is that when a page calls `window.open` it asks the UI
delegate to create a web view. No `WKUIDelegate` in this shell implemented
`webView(_:createWebViewWith:for:windowFeatures:)`, and an unimplemented
optional means the call evaluates to `null` and the page has no way to know.

The route in was sideways. Another pass was deciding whether the pop-up blocker
deserved a Settings switch, concluded correctly that the switch would have no
effect because `window.open` opened nothing either way, and removed it. What
that reasoning missed is the larger reading: **the legitimate pop-up was broken
too.**

### It is not a pop-up bug, it is every new-tab link

The finding that changes the size of this. Measured, in the real browser, with
a real click on a real link:

```html
<a href="/child" target="_blank">go</a>
```

```
tabs before / after  ->  1 / 1
the opener           ->  still on /parent
```

WebKit routes `target="_blank"` through the same delegate method. So this was
not a corner reserved for sign-in flows — it was **every "open in a new tab" on
the web**, doing nothing at all, in a browser meant for daily work.

The sign-in half is still what makes it urgent. "Sign in with Google", "Sign in
with GitHub", "Sign in with Apple", Stripe Checkout, most bank 3-D Secure flows
and a large share of OAuth consent screens all open a pop-up. In `zer0` the
button did nothing.

### What WebKit actually hands over, measured

None of this was read off a header. A probe implemented the delegate, returned
a view, and asked the page.

**The configuration is the opener's, object for object.**

| asked of the configuration WebKit passed in | answer |
| --- | --- |
| `websiteDataStore === opener's` | **true** |
| `userContentController === opener's` | **true** |
| `preferences === opener's` | **true** |
| `applicationNameForUserAgent` | the opener's token |
| `mediaTypesRequiringUserActionForPlayback` | `.audio`, as ADR-0074 set it |
| `websiteDataStore.isPersistent`, opened from an ephemeral space | **false** |

That is the single most important fact in this ADR: a pop-up inherits the
opener's cookie jar, block list, injected scripts and every answer on
ADR-0074's sheet **structurally**, because the host uses the object it was
given rather than reconfiguring a new one to match.

**And the substitution is not merely wrong, it aborts.** Returning a view built
from a configuration of our own was tried on purpose:

```
*** Terminating app due to uncaught exception 'NSInternalInconsistencyException',
    reason: 'Returned WKWebView was not created with the given configuration.'
    … WebKit::UIDelegate::UIClient::createNewPage …
    … WebKit::SOAuthorizationCoordinator::tryAuthorize …
```

The engine enforces this itself, and the stack says why it cares: the same code
path runs WebKit's OAuth coordinator.

**The engine performs the navigation.** After the host returns the view, the
popup's URL is the target with nothing here having loaded it. So a `LoadUrl`
from the core would be a *second* visit, and a second visit to a single-use
OAuth address is a flow that fails on the screen.

**`window.opener`, `postMessage` and `window.close()` all work** once the view
is built from the right configuration — measured over a real `http://127.0.0.1`
origin, because two `file://` pages have opaque origins that never match each
other and `window.opener.document` is refused there for a reason that has
nothing to do with this code. That near-miss is recorded because it is exactly
the shape of green-looking evidence that proves nothing.

**A second `window.open` with the same name reuses the view.** WebKit does the
named-target lookup itself; the delegate is called once. So a flow that calls
`window.open('…', 'oauth', …)` twice does not get two tabs.

### `windowFeatures` says less than the feature string does

Measured, one row per call:

| the page wrote | what `WKWindowFeatures` reported |
| --- | --- |
| `window.open(url)` | everything `nil` |
| `window.open(url, '_blank')` | everything `nil` |
| `window.open(url, 'w', 'popup=1')` | everything `nil` |
| `window.open(url, 'w', 'noopener')` | everything `nil` |
| `window.open(url, 'w', 'toolbar=no,menubar=no')` | `menuBar=0`, `toolbars=0` |
| `window.open(url, 'oauth', 'width=480,height=640,left=100,top=80')` | `w=480 h=640 x=100 y=80` |

`navigationType` is `.other` (`-1`) for all of them, so it distinguishes
nothing. The gap worth naming: **`popup=1` alone reports nothing**, so the
modern spelling on its own is indistinguishable from a bare `window.open`.
In practice `popup=1` almost always travels with `width`/`height`, and there is
no public API that exposes the raw feature string.

### `window.close()` is not gated on "script opened it"

The premise this work started from was that WebKit only permits `window.close()`
for script-opened windows. **That is wrong, and it was measured rather than
reasoned:**

| the view | `webViewDidClose` fired |
| --- | --- |
| never script-opened, one entry in the back-forward list | **yes** |
| never script-opened, two entries | no |

WebKit's rule is `openedByDOM || backForwardList.count <= 1`. So a page whose
address somebody typed themselves, in a tab they opened, can make that tab
disappear as long as they have not navigated twice. Safari inherits that.

### The pop-up preference stopped being unobservable

With `javaScriptCanOpenWindowsAutomatically` off, an unprompted `window.open`
returns `null` **and the delegate is never called** — WebKit checks the
preference before consulting it. With the preference on, the delegate is called.
Measured both ways, with the page opening the window itself in a `<script>` at
load rather than through `evaluateJavaScript`, which carries a user gesture.

## Decision

**A page may open a view. The engine builds it, the core decides what it is,
and the shell keeps the object it was given.**

### The seam

`Action::PageOpenedWindow { opener, request }` goes in;
`EngineCommand::AdoptWebView { tab }` comes back. `AdoptWebView` carries no
`data_store_id` and no `profile`, because there is nothing left for the host to
choose — the configuration already holds them.

The delegate is a method with a return value and the core is between its two
halves, which works because `BrowserModel.send` is synchronous all the way
down: `EngineHost.adopt` parks the configuration, sends the action, and the
`AdoptWebView` that comes back fills in the view before `send` returns.

### Three things the core decides, and none of them the host

**The space is the opener's**, read off the tab that asked and never off
`active_space`. A page in an ephemeral space whose pop-up landed in a persistent
one would write a private session's cookies to disk, and the answer must not
depend on which space happened to be in front when the page ran.

**The window is the opener's.** `insert_tab` puts a tab in the key window, so
the key window moves first — the same ordering `open_window` depends on, one
direction along.

**What the page asked for decides tab or window.** The shell reports
`WindowRequest`, which is `WKWindowFeatures` uninterpreted, and
`WindowRequest::asked_for_a_window` is one sentence: *a page that said anything
about the shape of what it wanted — any size, any position, any piece of window
chrome turned off — asked for a window; a page that said nothing asked for a
tab.* Chrome turned **on** is not a request, because a window with its toolbars
is what a tab already is.

That split is the ADR-0053 tie-breaker applied literally. Reading
`WKWindowFeatures` is platform work and belongs in the shell; whether 480×640
means "a window" is browser behaviour that two platforms could not reasonably
disagree about, so it is in the core with tests and `webkit2gtk` inherits it.

**`allowsResizing` is deliberately not carried**: a page that asked for a
resizable window said nothing about whether it wanted a window.

**The window is not sized.** A pop-up that asked for 480×640 gets an ordinary
`zer0` window at the ordinary size. Honouring the numbers means plumbing a frame
through the `WindowGroup` scene that ADR-0065 says gives us no way to hand a
value to the view that will host a window, and a window sized to a page's
request but wearing a full sidebar would be honouring the number and not the
request. Declared, not solved.

### `window.close()` reaches only a tab a page opened

`Tab.opened_by_page` is set in the one arm that creates one, and
`close_from_page` refuses anything else. This is **stricter than the engine on
purpose** — see the measurement above. A tab vanishing under somebody is a loss
no key brings back, and whether a page opened it is a fact this browser already
has.

It is not restored from disk. A page that opened a tab in a previous run is not
on the other end of it after a relaunch, and a permission that outlives the
thing it was granted to is not a permission.

**A window a page opened goes with the page that closes itself**, when that page
was the only thing in it. Closing only the tab would leave an empty frame with
nothing in it and nothing to press.

### The pop-up blocker gets its switch, and ADR-0074 said it would

`block_unprompted_windows` ships on, rendered as **"Block windows that open on
their own"**. ADR-0074 refused it a row and named the exact condition: *"It is
set now so that the day windows can open, unprompted ones already cannot — and
**that** is the day it earns a row beside autoplay."* This is that day, and the
measurement above is what makes it true rather than plausible.

**The two rows in Settings make different promises, and that is not
inconsistency.** Autoplay lives on the configuration, which `WKWebView` copies
at birth, so it reaches pages opened from now on and nothing else. The pop-up
blocker lives on `WKPreferences`, which the copy still shares, so
`EngineHost.policy` pushes it at every live view and it lands on that page's
next load. The rows say those two different things in as many words, because a
person turns this one off *because a page did not work* — a switch that only
reached the next tab would not be the switch they went looking for.

### What is deliberately not built

`webViewDidClose` and `createWebViewWith` are implemented. The **JavaScript
panels are not**, and they are a real defect, declared rather than hidden.
Measured in the real browser today:

| the page calls | what happens | what a person sees |
| --- | --- | --- |
| `alert('…')` | returns immediately | nothing |
| `confirm('…')` | returns **`false`** | nothing, and the answer was "Cancel" |
| `prompt('…', 'x')` | returns **`null`** | nothing, and the answer was "Cancel" |

`confirm()` is the sharp one: a page asking "continue?" is silently told no.
This is the same class of silent failure as the one this ADR fixes, and it is
not fixed here because it is three modal presentations to design in a repo whose
bar is "that is gorgeous", and a browser is not improved by dialogs nobody drew.
It is written into `SitePermissionHost.swift` at the place a reader will look
and counted here rather than left to be rediscovered.

## Consequences

**Pages can open windows now, and some of them will be pop-ups nobody wanted.**
That is what the blocker is for, and it is on by default. What changes for the
worse is that a hostile page has a surface it did not have; what changes for the
better is that a person can sign in.

**`target="_blank"` links work**, which is the change most people will actually
notice and none of them will describe as a fix — they will describe it as the
browser having stopped being broken.

**A pop-up is a tab in the sidebar** and appears in the tab tree under the page
that opened it, because `parent` is set. Extensions are told about it through
`tabOpened` off `AdoptWebView`, the same as any other tab; a tab list with the
sign-in windows missing from it would be worse than none.

**`Tab` grew a field that is not persisted.** Every other field on `Tab` either
survives a relaunch or is re-derived from the engine; this one is neither, and
that asymmetry is the price of the rule being about a live page.

**The pop-up path does not call `EnginePolicy.apply`.** It cannot and must not:
the configuration is the opener's and already carries every value, and writing
over it would be this host deciding a pop-up is a different kind of client from
the page that opened it. `aPopUpIsTheSameKindOfClientAsItsOpener` reads the whole
sheet off a view the host never configured, so the inheritance is asserted
rather than assumed.

**One pop-up at a time.** `EngineHost.adopt` refuses a second while one is in
flight rather than handing back the first one's view. Two pages being adopted at
once would mean two configurations and one slot, and the failure would look like
a working browser until somebody signed in as the wrong person.

## How this regresses

**Somebody builds the view from a fresh configuration.** The most likely single
mistake, and it reads as a tidy-up: `HostedWebView` builds configurations, so
why does this path not? Broken on purpose, and the answer arrives as a **process
abort** — `NSInternalInconsistencyException: Returned WKWebView was not created
with the given configuration`. WebKit holds this one; the tests only have to not
get in its way.

**Somebody reads the space off `active_space`.** It looks equivalent — the page
that called `window.open` is nearly always in the space that is in front — and
it is the line that puts a private session's cookies on disk.
`a_pop_up_stays_in_the_space_the_page_that_opened_it_is_in` moves the active
space away before the pop-up opens, for exactly this; it went red on the break
with `left: SpaceId(1), right: SpaceId(3)`.

**Somebody adds a `LoadUrl` after the adoption.** This is the regression that
reads hardest as an improvement: every other way a tab gets a URL goes through
`start_navigation`, and this one visibly does not, so it looks like a missing
line. It is a second visit to an address the engine has already fetched, and a
single-use OAuth code does not survive one — which fails as "the sign-in said
the link expired", nowhere near this file.
`a_page_that_described_no_window_gets_a_tab_beside_the_page_that_asked` asserts
the absence.

**Somebody drops `opened_by_page` from `close_from_page`.** It looks like a
redundant check, because WebKit already decided to call the delegate. It is the
difference between a page closing its own pop-up and a page closing a tab
somebody was using. Held on both sides — the Rust arm and, through a real
`window.close()` on a real page, `aPageCannotCloseATabAPersonOpened` — because
this one is only true if the engine really does call the delegate for an
ordinary tab, and it does.

**Somebody makes every pop-up a window, or every pop-up a tab.** Either is one
line, both look tidier than a rule, and each breaks the half of the web the
other one serves. Three tests cover the two directions and the rule itself, and
breaking the rule outright turned three of them red at once.

**The Settings switch stops reaching an open page.** The loop in
`EngineHost.policy` looks like waste — every other engine setting is applied at
birth — and without it the switch does nothing for the person who went looking
for it, because they turned it off while looking at the page that failed.
`aPageCannotOpenAWindowUnpromptedAndTheSwitchIsWhatLetsIt` reloads the page that
is already open and asks it; deleting the loop leaves it at `"null"`.

**The delegate is implemented twice.** A second `createWebViewWith` somewhere
else would be a second answer to which space a page's window lands in, and every
behavioural test here would stay green because they all go through the first
one. `aPagesWindowIsOpenedInOnePlaceAndAdoptedInOnePlace` counts both doors —
the delegate and the place a `WKWebView` is built — rather than trusting there
is one.

**Somebody writes the whole thing with `file://` fixtures.** Two `file://` pages
have opaque origins, so `window.opener.document` is refused there whatever the
code does, and a test written that way asserts a `SecurityError` and calls it a
day. The suite serves over `http://127.0.0.1` for that reason and says so at the
top.

## When to revisit

- **When a pop-up window should be sized.** It is the one part of
  `windowFeatures` honoured in the core and ignored in the shell. Doing it means
  handing a frame to a scene ADR-0065 says cannot be handed anything, so it
  supersedes part of that decision rather than extending this one.
- **When the JavaScript panels get drawn.** Named above with measurements and
  no lock, because a test cannot see a dialog nobody wrote. That is debt, it is
  counted, and the day somebody designs the sheet it becomes its own ADR.
- **When a public API exposes the raw feature string.** `popup=1` on its own is
  indistinguishable from a bare `window.open` today, and that is a limit of
  `WKWindowFeatures` rather than a decision taken here.
- **If `window.open` ever needs to be answered asynchronously.** The whole seam
  rests on `BrowserModel.send` being synchronous — a delegate with a return
  value cannot wait. Anything that makes dispatch async takes this with it, and
  the replacement is not a refactor.
- **When a pop-up should be allowed per site rather than globally.** The blocker
  is one switch for the whole browser, which is coarser than what Safari and
  Chrome offer. Per-site or per-space is a `SpaceProfile` or a ledger decision,
  the way ADR-0056 answered the camera, and not a wider version of this one.
