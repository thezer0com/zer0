# ADR-0016: A page that fails gets the whole screen, names the site and puts the action on Return

- **Status:** Accepted
- **Date:** 2026-02-23
- **Lock:** `crates/zer0-core/src/reducer_tests.rs::a_failure_records_why_and_where`

## Context

A white rectangle is the worst possible answer to "did that work?". It is
**indistinguishable** from three different things: a page still loading, a page that
failed, and a page that is genuinely empty. The person stares at the screen not
knowing whether to wait, to reload, or to assume they typed it wrong.

And the platform's default answer is worse still: `NSURLErrorDomain -1009`. Nobody
in history has ever been helped by reading that.

The project's rule — "an action in flight has feedback, no frozen screen without an
explanation" — is very specific here: a failure **is** a state, and a state with no
representation is a bug.

## Decision

### The core keeps the reason

A failure is not the absence of a page, it is a fact with data. `Tab.last_error`
holds `NavigationError { kind, url, message }`. The comment in the test states the
principle:

> A blank page is the same picture whether it failed, is still loading, or is
> genuinely empty. The reason has to survive as state for the UI to say which.

`kind` is a closed enum (`offline`, `hostNotFound`, `connectionFailed`, `timeout`,
`certificateInvalid`, `unsupportedUrl`, `cancelled`, `unknown`), and closed is the
point: a new category breaks the build until it gets an icon, a title and a message.

The lifecycle is driven by the core, not by the View:

- `NavigationStarted` **clears** the error. An attempt in flight is not a failure,
  which is why the error screen never hangs over a page that came back.
- `Cancelled` does **not** become an error. Downloads and redirects cancel the
  in-flight navigation; treating that as a failure would put an error screen on top
  of a working page.
- `last_error` is **not** a column in the database. It is commented in `store.rs`: a
  restored tab is loaded again at launch, so yesterday's "you are offline" would show
  up on top of a page that is about to load fine.
- `Reload` over a failure re-emits `LoadUrl` with the address that failed, because
  the engine has nothing to reload when the navigation never committed. Without
  that, "Try Again" would be a button that does nothing.

### The shell takes the whole area

`NavigationErrorScreen`, in `apple/Sources/Zer0Shell/BrowserView.swift`, is an
alternative to `WebViewContainer`, not an overlay on it:

```swift
if let error = model.activeTab?.lastError {
    NavigationErrorScreen(error: error) { model.reload() }
} else if ... {
```

Four things make that screen:

1. **It names the site the way a person would.** `Can't find avelino.run`. The
   `www.` goes — it is noise nobody says out loud. With no resolvable host, it falls
   back to "that site" instead of showing a broken string.
2. **The title names what happened, not the error that was reported.** "You're
   offline", "This connection isn't private", "avelino.run took too long".
3. **The full URL appears under the title**, monospaced, truncated in the middle, in
   a capsule. The justification is in the code: a long URL inside the title destroys
   the hierarchy, but you still need to see exactly what was requested.
4. **The useful action is under Return.** `.keyboardShortcut(.defaultAction)` — it is
   the only thing to do there, so Return does it. ⌘R goes through the same path in
   the core.

The messages are actionable, not descriptive. `hostNotFound` says: *"No server
answers to that name. It could be a typo, or the site could be gone. ⌘L opens the
address for editing."* — which is the bridge to ADR-0015, where `address_bar_text`
returns the address **that failed** precisely so the typo does not have to be
retyped from scratch.

Icons are the ones the system already uses (`wifi.slash`,
`globe.badge.chevron.backward` — the same one Safari uses), so they are recognized
rather than decoded.

Only `unknown` shows the engine's message, and only because in that case the
category is the shell admitting it does not recognize the failure: what the engine
said beats a guess.

The transition is `Design.subtle`, with a comment: a page failing is unpleasant
enough already, so the explanation should fade in and not snap over what was there.

## Consequences

**What hurts:**

- **Eight categories, eight icons, eight titles, eight messages.** Every new
  category costs four copy and design decisions. The `switch` with no `default:`
  guarantees nobody forgets — and guarantees, too, that nobody adds a category in
  passing.
- **Copy lives in the shell, so each platform writes its own.** That is coherent
  with the architecture (copy is appearance), but it means Linux and macOS can say
  different things for the same `kind`. Nothing prevents divergence.
- **The whole screen is a `String` literal in English.** There is no localization,
  and retrofitting l10n into a `switch` expression is tedious.
- **The screen replaces the content instead of coexisting with it.** If the page had
  something useful rendered before the failure, it is gone. Acceptable for a
  navigation failure (it did not commit, there was nothing there), but it closes the
  door on partial errors — a subresource that failed, for example.
- **`certificateInvalid` does not offer "proceed anyway".** The right security
  decision and a real UX cost: anyone dealing with a self-signed cert in development
  has no path in the browser.
- **`last_error` not persisting means the error always reappears on the next
  attempt.** It is the right choice, but it means a dead tab is reloaded on every
  launch just to fail again.
- **The error screen is beautiful and we want it to be rare.** Investment in a
  surface that ideally nobody sees.

**What we get:**

- "Did it work?" has a one-sentence answer, always.
- Recovery without taking your hands off the keyboard: Return tries again, ⌘L edits
  the address with the failed text already inside.
- The error lifecycle lives in the core, testable without opening a window.

## How this regresses

It regresses back to the white rectangle. And the white rectangle **does not look
like a bug** — it looks like a slow page. The person waits. Waits more. Reloads.
Waits. Only after a minute do they get suspicious. The damage is time and trust, and
it never becomes an issue.

What the person would notice:

- **"The page does not open and says nothing."** `last_error` stopped being filled
  in, or the `if let error` was swapped for an overlay that does not show up. A blank
  screen indistinguishable from loading.
- **"It keeps saying I am offline even after I am back."** `NavigationStarted`
  stopped clearing the error. The error screen is stuck over a page that loaded. That
  is worse than blank: it lies with confidence.
- **"It errored on a file I was downloading."** `Cancelled` counts as a failure
  again. Every download throws an error screen over a page that is perfectly fine.
- **"Everything shows an error when I open the browser."** Somebody adds
  `last_error` as a column in `store.rs` "to restore the full state". Restored tabs
  show yesterday's error before they even try to load. The comment in `load_tabs`
  exists to prevent that, and a comment locks nothing.
- **"I clicked Try Again and nothing happened."** The reload stopped re-emitting
  `LoadUrl` for the address that failed. The engine has nothing to reload (the
  navigation never committed), the button blinks and the screen stays the same.
- **"⌘L opened empty on the error screen."** `address_bar_text` stopped considering
  the address that failed. The typo has to be retyped in full — which is exactly the
  moment the person needs it preserved most.
- **"A code showed up instead of the explanation."** Somebody simplifies the
  `switch` down to `error.message`. `NSURLErrorDomain -1009` is back.
- **"The title got huge with the whole URL in it."** The URL moves up into the title
  in a layout refactor. The hierarchy dies, the screen becomes a wall of text.

**The locks:**

- `a_failure_records_why_and_where` — the core of it. Checks `kind` and checks that
  `error.url` is the address that failed, with the message *"the address that failed
  is the only thing a retry can use"*. Without it, neither the title names the site
  nor the retry works.
- `crates/zer0-core/src/reducer_tests.rs::a_successful_reload_clears_the_error` —
  covers both clears (in flight and after the commit), with *"an attempt in flight is
  not a failure"*.
- `::a_cancelled_navigation_is_not_an_error` — downloads and redirects.
- `::retrying_a_failed_navigation_reissues_the_load` — "Try Again" actually doing
  something, by comparing the emitted `EngineCommand`.
- `::failed_navigation_clears_pending_state` — the tab stops "loading".
- `::a_failure_for_a_closed_tab_is_ignored` — a failure arriving after the close.
- `crates/zer0-core/src/store_tests.rs::a_navigation_error_does_not_survive_a_restart`
  — prevents the column in the database.

**What has no lock:** the screen itself. No test checks that `kind` maps to a
non-empty title/icon/message, that `site` strips the `www.`, or that the action is on
`.defaultAction`. The `switch` with no `default:` guarantees *coverage*, not
*quality* — an empty string compiles. The three functions (`site`, `title`,
`message`) are pure and private: extracting them into a testable type would close
that hole cheaply.

## When to revisit

- If `unknown` shows up often in real use. Every recurring `unknown` is a missing
  category.
- If a partial error (subresource, mixed content) needs representation. The current
  design is all-or-nothing by design.
- If `certificateInvalid` with no escape becomes a real blocker for development. The
  way out is an explicit and scary path, not loosening the default.
- When there is a second shell. Each platform writing its own copy can diverge; if it
  diverges too far, the copy moves up into the core and becomes data.
- If l10n enters the roadmap. Then the `switch` over strings has to become keys.
