# ADR-0017: The session comes back whole, and a file that was not read is never written over

- **Status:** Accepted
- **Date:** 2026-02-25
- **Lock:** `apple/Tests/Zer0ShellTests/NavigationRoundTripTests.swift::PersistenceTests/sessionSurvivesRelaunch`, `crates/zer0-core/src/ffi_tests.rs::a_session_that_opens_but_cannot_be_read_is_never_written_over`, `apple/Tests/Zer0ShellTests/SettingsTests.swift::SessionPersistenceTests/unreadableSessionWarnsInTheUI`

## Context

A tab is not an open document, it is work in progress. Thirty open tabs are
research under way, and the person closing the browser is not giving up — they are
going to lunch. Losing that is not losing configuration: it is losing context that
took hours to assemble and that they cannot rebuild.

Two separate problems, and the second is the dangerous one.

**One:** making sure the session reaches the disk. `scenePhase` is not enough on
macOS — ⌘Q does not deliver a phase change reliably before the process dies. And
saving on a twenty-second timer loses everything that happened in the last nineteen.

**Two:** what to do when the session **could not be read**. The naive path —
"could not read it, start empty" — is catastrophic. The browser opens with one tab,
the person navigates, and twenty seconds later the autosave writes *one tab* over
the file that had thirty. No backup, no warning, no chance to recover. The read
error was temporary; the destruction is permanent.

## Decision

### Three lines of defense for the save

`SessionLifecycle.swift` documents all three:

1. **A structural change saves immediately, with a debounce.**
   `BrowserModel.isStructural` separates what is worth writing (opening/closing/moving
   a tab, a navigation commit, creating/closing a space, a routing rule) from what is
   not (a title arriving, progress, zoom). The 2s debounce coalesces a burst: opening
   five tabs is one write, not five full rewrites.
2. **`applicationWillTerminate` and `applicationShouldTerminate`.** AppKit
   guarantees these. `applicationShouldTerminate` saves **before** agreeing to quit,
   not after.
3. **A clean-shutdown marker.** `mark_clean_shutdown` is written **last**, so its
   presence means everything before it reached the disk. `take_clean_shutdown` reads
   and clears it, so the current run counts as dirty until it exits properly.

`SaveReason` (`periodic`, `structuralChange`, `quitting`, `backgrounded`) is only
for logging — and it exists because a save that fails with no reason attached is a
ticket nobody can answer.

The whole write goes in a single transaction, so a crash mid-save leaves the
previous session intact instead of half of two.

Closing the last window quits the app, the way browsers do.

### Do not write over what was not read

It lives in `ffi.rs::Zer0::open`, and the comment is the decision:

> A database that opens but fails to *read* is a different thing, and is treated
> as one. Starting empty and then saving over it would destroy the session on the
> first autosave, twenty seconds later, with no backup and no warning. So the
> store is detached instead.

Three distinct cases:

| Situation | `store` | `load_error` | Saves? |
|---|---|---|---|
| Opened and read | `Some` | `None` | yes |
| Could not open the file | `None` | `"could not open the session file"` | no |
| Opened but failed to read | `None` | the error message | **no** |

The third case is the one that matters. The `Store` is **detached**: the browser
runs, and `Zer0::save()` falls into `None => Ok(())`. It refuses to write anything
over a file it did not understand. The user's file stays there, intact, recoverable.

Losing a single piece of data does not take the session down: an unreadable
preference falls back to the default, an unknown rebind is skipped, a routing rule
from a future version is ignored. Only a *structural* read failure detaches.

### And the person is told

Silently switching saves off would trade one disaster for another: the person works
all day and finds out about the loss at the next launch. The `sessionWarning` in
`BrowserView.swift` appears when `model.loadError` is set:

> **Your previous session could not be read**
> Nothing is being saved this session, so the file you already have is not
> written over. *(the error message)*

It says what happened, what is happening now (nothing is being saved) and **why
that is intentional** (so nothing gets written over). Dismissible, because knowing
once is enough.

Separately, `lastRunEndedCleanly` distinguishes a clean quit from a crash — the
session is restored in both cases, but after a crash it may be slightly behind.

## Consequences

**What hurts:**

- **A whole session switched off because of one unreadable file.** It is the right
  choice and the cost is high: everything the person does in that session evaporates
  on exit. There is no degraded mode — saving to an alternate file, for instance.
  Preserving the old file beat preserving the new session.
- **No automatic recovery.** There is no rotating backup, no `session.sqlite.bak`,
  no UI path for "try again" or "start from scratch and let me save". The person has
  to quit, touch a file by hand, and come back.
- **The warning is dismissible and does not return.** `sessionWarningDismissed` is
  `@State` on the model, not persisted. Dismiss it by reflex and the only indicator
  that nothing is being saved is gone for the rest of the session.
- **A save is a full rewrite.** `DELETE FROM` followed by `INSERT` on every table.
  With a large history, every structural save rewrites the entire history. The
  debounce hides it; the cost grows with use.
- **`isStructural` is a manual list.** The `switch` with no `default:` forces every
  new action to be classified, but classifying it wrong is easy and the symptom is
  silent data loss. `titleChanged` being non-structural means the title only reaches
  the disk riding along with the next structural change.
- **An ephemeral space loses its tabs on purpose.** Coherent with the promise, but
  it means closing the browser with work in an ephemeral space loses everything — and
  this ADR promises the opposite in the general case.
- **`MainActor.assumeIsolated` in the AppKit delegates.** If those callbacks ever
  come from another thread, that is a crash, not a warning.

**What we get:**

- Close it and open it: everything is there. Tabs, order, the tab tree, pins,
  spaces, profiles, history with counts, routing rules, custom keymap, preferences.
- A read failure never becomes data loss.
- The person knows when they are not protected, at the moment that becomes true.

## How this regresses

Two distinct regressions, and the second is the most expensive one in this whole
document.

**The first — the session does not come back:**

- **"I opened it and tabs were missing."** Not all of them: the last ones.
  `isStructural` classified something wrong, or the debounce was swallowed by the
  quit. The person assumes they closed them by accident and blames themselves.
- **"The tabs came back in the wrong order"** or **"the child tab detached from its
  parent"**. `position`/`parent_id` stopped being written. The list comes back
  shuffled and the person loses the structure they had built.
- **"I lost what I did in the last minute."** `applicationShouldTerminate` stopped
  saving before agreeing to quit, and only the 20s timer is left.
- **"My shortcuts went back to the defaults."** `customisations()` saves only the
  delta; if the comparison against the defaults changes shape, the delta comes out
  empty and the rebind disappears at the next launch.
- **"I cleared my history and it came back."** This already happened — it is the
  reason for the `DELETE FROM history` before the insert, commented in `store.rs`.
  Going back to an upsert brings the ghost back.

**The second — and this one is serious:**

- **"I lost everything."** Somebody "improves" the error handling: instead of
  detaching the store, it logs and carries on with a valid `Store`. The browser opens
  with one tab. Twenty seconds later, the autosave writes one tab over thirty.
  **There is no symptom before the damage.** The person sees nothing wrong — they see
  an empty browser, assume "something went bad", and keep using it. The file was
  already destroyed on the first autosave.

  That is the failure mode this ADR exists to prevent, and it passes the entire
  test suite as it stands today.

- **"Nothing is being saved anymore and nobody told me."** The inverse path:
  `loadError` still switches saves off, but the `sessionWarning` disappears from
  `BrowserView` in an overlay refactor. The browser goes **silently** without
  persistence. The person works all day and finds out the next day.

**The lock** (`tabs, spaces and rules come back after a relaunch`) covers the first
half: it writes tabs, spaces and rules into a real file, reopens it and compares.
Complemented on the Swift side by
`apple/Tests/Zer0ShellTests/SettingsTests.swift::a structural change is written without waiting for the timer`,
`::quitting writes everything, including what happened a second ago`,
`::noisy actions do not each trigger a write`,
`::a clean quit is remembered; a crash is not`,
`::a crash still restores the session`, `::settings survive a restart`. And on the
Rust side, `crates/zer0-core/src/store_tests.rs` covers practically everything that
persists: `a_saved_session_comes_back_the_same`, `tab_order_and_the_tree_survive`,
`a_half_written_session_is_repaired_not_trusted`,
`an_ephemeral_space_keeps_its_tabs_off_disk`,
`a_rebound_shortcut_survives_a_restart`,
`clearing_history_actually_clears_it`,
`a_corrupt_id_does_not_overflow_the_id_counter`.

**The second half has no lock at all.** There is no test about `load_error`
anywhere in the repository. Closing it would take three tests in
`store_tests.rs`/`ffi`:

1. **`Zer0::open` over a corrupted file does not write to it.** Write structural
   garbage into a `.sqlite`, open it, fire actions, call `save()`, and check that the
   file's bytes **did not change**. That is the test that prevents total loss.
2. **`load_error` is `Some` when the read failed and `None` when it worked.** The
   value exists today and nothing checks it.
3. **`is_persistent()` is `false` after a failed read.** The "detached store"
   invariant, declared in prose and never measured.

And on the Swift side, a test that `loadError != nil` makes the warning exist —
unreachable today without instrumenting the SwiftUI hierarchy, but reachable if the
condition becomes a computed property on `BrowserModel`.

## When to revisit

- **Before anything else: write the three `load_error` tests.** It is the largest
  risk debt across the UX ADRs, because the regression is silent and the damage is
  irreversible.
- If a full save shows up in a profile with a large history. The way out is
  incremental writing, not saving less often.
- If `loadError` happens with any real frequency. Then the design needs real
  recovery: a rotating backup, or an explicit "save into a new file" path.
- If the warning being dismissed by accident becomes a problem. Persist the dismissal
  per session, or swap it for a permanent, discreet indicator.
- When `clear_data_on_quit` or `StartupBehaviour::SpecificUrls` are actually
  exercised. Both interact with restoration and have no case described here.
