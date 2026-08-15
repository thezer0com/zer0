# ADR-0097: A tab comes back with where it has been, and an ephemeral space has nowhere to write that down

- **Status:** Accepted
- **Date:** 2026-08-10
- **Lock:** `crates/zer0-core/src/navigation_state_tests.rs::an_ephemeral_space_writes_down_no_back_list`, `crates/zer0-core/src/navigation_state_tests.rs::a_persistent_space_brings_its_back_list_back`, `crates/zer0-core/src/navigation_state_tests.rs::a_restored_tab_is_handed_its_history_and_not_a_second_load`, `crates/zer0-core/src/navigation_state_tests.rs::a_state_too_large_to_be_a_back_list_is_not_kept`, `crates/zer0-core/src/navigation_state_tests.rs::a_stored_state_is_held_to_the_same_limit_as_a_live_one`, `apple/Tests/Zer0ShellTests/PageProcessTests.swift::NavigationStateTests/backAndForwardSurviveARelaunch`, `apple/Tests/Zer0ShellTests/PageProcessTests.swift::NavigationStateTests/aRestoredTabIsLoadedOnce`, `apple/Tests/Zer0ShellTests/PageProcessTests.swift::NavigationStateTests/aRefusedStateStillOpensTheTab`, `apple/Tests/Zer0ShellTests/PageProcessTests.swift::NavigationStateTests/anEphemeralSpaceKeepsItsHistoryOffDisk`

## Context

ADR-0017 promises the session comes back whole, and it delivers a list: tabs,
order, tree, pins, spaces, history, rules, keymap, preferences. What it did not
deliver was the part of a tab that took the longest to build.

A restored tab came back on its address with `canGoBack` false. Six links deep
into a documentation site, closed at lunchtime, reopened after: the page is
there and the path to it is gone. That is not a smaller version of "the session
comes back", it is the difference between a tab and the work that produced it —
and it is invisible, because the tab looks right until somebody presses Back.

`WKWebView.interactionState` (macOS 12+) is the whole of it: an opaque,
archivable value carrying a view's back/forward list with the scroll offsets and
form values that make going back restore a page rather than fetch it again. It
was never read and never written anywhere in this repository.

Three things had to be settled before it could be, and the first is the one that
governs the design.

**What it weighs.** Measured on macOS 26.5: a `WKWebView` that has never
navigated reports 137 bytes; one page 730; three 1,406; six 2,420; twelve 4,457
— a little over 340 bytes an entry. WebKit caps a back/forward list at 100
entries, so a real tab tops out around 35 KB and a hundred-tab session at a few
megabytes. That is not a different storage profile from what is written today;
one page of chat transcript is larger.

**Where it cannot go.** `Tab` is a `uniffi::Record` and travels in every
`BrowserSnapshot`, several times a second. A blob on it would be copied out of
the core on every redraw to draw a sidebar row that has no use for it.

**What a person's Back press has to do.** Measured: setting the state *and*
loading the tab's address on top of it leaves the engine with two entries for
one page, so the first Back goes from the page you are reading to the page you
are reading. And a state the engine will not take — truncated, random, empty, or
not `Data` at all — is absorbed in silence: the view keeps no history, reports
`url` as `nil`, and is otherwise perfectly able to load.

## Decision

**The core stores an opaque navigation state per tab, hands it back when that
tab's view is built, and an ephemeral space's cannot reach a file because there
is nowhere in the projection to put one.**

### It lives beside the tabs, not on them

`crates/zer0-core/src/navigation_state.rs`: `NavigationStates`, a map from
`TabId` to bytes, on `Session`. The same argument ADR-0044 makes for icons — the
thing itself sits to one side, and only what a shell draws with crosses the FFI.

`Action::NavigationStateChanged` carries one in, reported by the host at the
commit **and** at the finish. At the commit because otherwise a page that
commits and then takes a minute leaves a stored history naming the *previous*
page while `Tab.url` names this one, and a restore puts the tab back on the
older of the two. At the finish because that version has the settled page in it.

It schedules no save of its own: it arrives on the heels of the
`navigationCommitted` that caused it, and that commit has already started
ADR-0017's two-second debounce.

### The ephemeral guarantee is the shape, not a filter

This is the constraint the whole design was arranged around.

`StorableSpace.tabs` was `Vec<Tab>` and is now `Vec<StorableTab>`, where a
`StorableTab` is a tab **and** its navigation state. The obvious alternative — a
`Vec<(TabId, Vec<u8>)>` beside the spaces on `StorableSession` — was rejected
outright, and not on tidiness: a top-level list needs a filter to keep an
ephemeral space out of it, and a filter is a line somebody can delete in a
refactor that looks like a simplification. A private space's back/forward list
is the most detailed record of a private session this browser could produce:
every address, in order, with scroll positions and form values.

With the state on the tab, there is no filter and no branch. `StorableSpace`
already answers `Vec::new()` for an ephemeral space's tabs (ADR-0023), a
navigation state can only travel inside a `StorableTab`, and a `StorableTab` can
only travel inside a space's `tabs`. **The only way to leak a private space's
history is to leak its pages first** — which the existing lock family already
fails on, loudly, from six directions.

That was checked by trying: the ephemeral branch was made to hand over its tabs,
and seven tests went red by name, `an_ephemeral_space_writes_down_no_back_list`
among them. There is no edit that leaks the history alone, because there is no
field that can hold it alone.

### On disk it is a table of its own

`tab_navigation_states`, keyed by `tab_id`, cascading on delete and on update.
A table rather than a column on `tabs` for the reason `tab_windows` and `splits`
are tables — this schema is created with `CREATE TABLE IF NOT EXISTS` and has no
migration step, so a new column never appears on a database that already exists,
and every read of `tabs` would then fail on exactly the machines with a session
worth keeping, which by ADR-0017 detaches the store.

And for a second reason that is this table's alone: these are the only rows in
the file that are bytes nothing can read. Read in a pass of their own, a row
that will not come off the disk costs one tab's back list rather than the read
of `tabs`.

### Coming back in, it is hostile and it is opaque

ADR-0024 says anything read from disk is treated as hostile. Usually that means
validating it. Here it cannot: the bytes are opaque on both sides of the FFI, so
"is this a real archive" has exactly one authority and it is the engine.

So there are two answers, and they are different questions.

**Before the engine: a bound.** `NavigationStates::set` refuses anything empty
and anything over `MAX_STATE_BYTES` (1 MiB — thirty times the largest list a
real tab can produce). It is the one door: the load path and the live report
both go through it, so a file handing over four megabytes for one tab is refused
without anyone having remembered to check. It is a ceiling on damage, not a
validity test, and it is not described as one.

**At the engine: ask it.** `HostedWebView.restore(navigationState:)` sets the
value and returns whether `backForwardList.currentItem` is non-nil, which is
true on the next line for a whole archive and false for a truncated, random,
empty or wrong-typed one — synchronous, measured, and the only signal there is.
A refusal is reported as `Action::NavigationStateRefused` rather than repaired
in the shell, and the core answers with the `LoadUrl` it had held back.

Which is the third measured fact, in the protocol: **when `CreateWebView`
carries a state, no `LoadUrl` follows it.** The state carries the address; the
load is what appends the duplicate entry. It is not lost, it is held — and a
corrupt state therefore costs exactly the back list and lands the person on
their page with no history, which is the browser as it was yesterday.

## Consequences

**What we get.** Closing the browser stops costing the path you took. Back and
forward work on a restored tab, on the page it comes back on, at the entry it
was left at. And the promise an ephemeral space makes got stronger rather than
weaker: it now covers the one trace that would have been the most revealing.

**What it costs, honestly:**

- **`StorableSpace.tabs` changed type**, so every backend and every test that
  read a tab out of a projection now goes through `.tab`. Four assertions in
  `storable_tests.rs` moved. Nothing else did.
- **A blob per navigation crosses the FFI, twice.** One to four kilobytes, on
  commit and again on finish. Small against what the same commit already writes,
  and it is real, and nothing profiles it.
- **The state is only as fresh as the last navigation.** Scroll a page for ten
  minutes and quit: it comes back where it was when the page finished loading.
  Chasing the scroll would mean reporting on a timer, and a browser writing a
  kilobyte per tab per second to record that somebody is reading is a worse
  trade than the one being made.
- **A form value can now reach the disk.** `interactionState` carries what was
  typed into a page's fields, and that is a genuine widening of what a session
  file holds — mitigated by the ephemeral rule and by nothing else. The file has
  the same protection it has always had, which is the filesystem's.
- **`MAX_STATE_BYTES` is a number.** One megabyte is thirty times the largest
  measured real state and it is still a guess about the future. A tab that
  legitimately exceeded it would silently lose its history with nothing on
  screen.
- **A stale entry outlives nothing but the run.** States are dropped when a tab
  closes, through `answer_pending_for` — the one place a tab leaving the model
  already converges — and a row naming a tab a file no longer has is simply
  never asked for.
- **Nothing tells a person their history was refused.** A corrupt state is a
  silent downgrade to a tab that opens normally. That is deliberate — the
  alternative is a warning about a thing they cannot act on — and it means the
  failure has no symptom at all.

## How this regresses

- **"I opened it this morning and Back was greyed out."** The report stops being
  emitted, or is moved to `didFinish` alone and a slow page loses it. Nothing
  else changes, no test that reads the model notices, and the tab looks
  perfectly correct. `backAndForwardSurviveARelaunch` is the one that asks —
  end to end, through the store, and by pressing Back.
- **"Back does nothing the first time."** The held-back `LoadUrl` is put back,
  because a `CreateWebView` with no load beside it reads like an oversight. The
  duplicate entry is invisible in every snapshot and shows up only under a
  person's finger. `aRestoredTabIsLoadedOnce` counts the back list, and it had
  to be rewritten once already: the first version read the count too early,
  passed with the load restored, and was a lock resolving against nothing.
- **"A private window's browsing is in the session file."** Somebody adds a
  `navigation_states` list to `StorableSession` because reaching through the
  spaces is awkward. This is the expensive one, and it is the one the shape is
  arranged to make impossible rather than merely tested for.
  `anEphemeralSpaceKeepsItsHistoryOffDisk` reads the file as bytes and looks for
  the address, because the promise is about what is in the file and not about
  what an API hands back.
- **"A tab came back blank."** `restore` is changed to return `true`
  unconditionally — the tidier-looking version, since the engine "does not
  complain" — and a corrupt state costs the tab instead of the history.
  `aRefusedStateStillOpensTheTab` drives real garbage through the real command
  and demands the page.
- **"The browser got slow and the session file got huge."** The cap is dropped,
  or moved out of `set` to a call site. `a_state_too_large_to_be_a_back_list_is_not_kept`
  and `a_stored_state_is_held_to_the_same_limit_as_a_live_one` cover both, and
  the second is the one that matters: it proves the *file* is held to the limit,
  not just the engine.

## When to revisit

- If the FFI traffic shows up in a profile. The way out is reporting once per
  navigation rather than twice, and losing the settled version — not storing
  less.
- If scroll position on a restored tab becomes a complaint. That needs the state
  sampled on a timer or at quit, and the honest version of it is a sample taken
  on the way out rather than a stream.
- When a second backend is written. This is the first thing in `StorableSession`
  whose contents no backend can inspect, and clause 2 of ADR-0045 — repair, do
  not invent — has nothing to bite on. It probably deserves a clause of its own:
  a store may drop an opaque value it cannot return intact, and may never return
  a partial one.
- If `interactionState` is found carrying something a session file should not
  hold — a password field, a token in a form — the answer is not to stop storing
  it, it is to find out what WebKit puts in there, which nobody here has been
  able to read.
