# ADR-0006: The session lives in SQLite with WAL, and the store detaches when the load fails

- **Status:** Accepted
- **Date:** 2026-01-22
- **Lock:** `crates/zer0-core/src/store_tests.rs::a_save_without_a_quit_reads_as_a_crash`, `apple/Tests/Zer0ShellTests/SettingsTests.swift::SessionPersistenceTests/structuralChangesSaveThemselves`, `apple/Tests/Zer0ShellTests/SettingsTests.swift::SessionPersistenceTests/crashDoesNotCostTheSession`, `crates/zer0-core/src/ffi_tests.rs::a_session_that_opens_but_cannot_be_read_is_never_written_over`

## Context

Losing the session is the most expensive failure a browser has. It is not a
crash — it is opening in the morning and yesterday's thirty tabs are not there,
with nothing you can do about it.

The comment in the test file is the record of what already happened here:
*"Session persistence: the thing that was silently losing everything on quit."*

Constraints: the state is relational (spaces, tabs with a parent, history with
counts, ordered routes, keybindings), the save runs while the UI is alive, and
`scenePhase` is not enough on macOS — ⌘Q does not reliably deliver a phase
change before the process is gone, and a save every twenty seconds loses the
last nineteen.

## Decision

**One SQLite file**, schema in `crates/zer0-core/src/store.rs`, versioned
`user_version` (`SCHEMA_VERSION = 1`), `foreign_keys = ON` and
`journal_mode = WAL`. WAL because a save cannot block a read at the moment the
save fires on a timer with the interface alive.

**Every save is a single transaction.** A crash halfway through leaves the
previous session intact instead of half of two.

**Layered defense to get the save onto disk**, described in
`SessionLifecycle.swift`:

1. **A structural change saves itself, debounced 2s.** Opening a tab is worth
   writing; typing in a field is not. `BrowserModel.isStructural` decides, and
   it is tested both ways: `openTab`/`closeTab`/`navigationCommitted` are
   structural, `titleChanged`/`navigationStarted`/`tick` are not.
2. **A 20s periodic timer**, as a net.
3. **`applicationWillTerminate` and `applicationShouldTerminate`**, which AppKit
   guarantees — and the save happens *before* agreeing to quit, not after.
4. **A clean shutdown marker.** `mark_clean_shutdown` is written last, so its
   presence means the rest of the save reached disk. `take_clean_shutdown` reads
   and clears it, so the current run counts as dirty until it closes properly.

**And the decision this ADR is named for: when the load fails, the store is
detached.** In `crates/zer0-core/src/ffi.rs`, `Zer0::open` distinguishes three
cases:

| situation | store | session | `load_error` |
| --- | --- | --- | --- |
| opens and reads | kept | whatever was there | `None` |
| **does not open** | `None` | new, in memory | set |
| **opens but does not read** | **`None`** | new, in memory | set |

The third row is the point. The intuitive path — start empty and get on with
life — would destroy the session on the first autosave, twenty seconds later,
with no backup and no warning. Instead the browser **runs and refuses to write
over a file it did not understand**. `load_error()` is available for the shell
to say so on screen (`BrowserView.swift` shows the banner), and
`is_persistent()` answers `false`.

What settles it is the comment on the constructor itself, and it is worth
quoting:

> *"Starting empty and then saving over it would destroy the session on the
> first autosave, twenty seconds later, with no backup and no warning."*

## Consequences

- **Every save rewrites everything.** `save()` does `DELETE FROM` on tabs,
  spaces, routes, keybindings and history, then re-inserts row by row. It is
  O(whole session) every 20 seconds and on every structural change. With a large
  history that grows without bound and there is no incremental path. History is
  replaced rather than merged on purpose — upserting alone brought forgotten
  pages back, because the row stayed on disk and nothing deleted it — but the
  price is rewriting the entire history every time.
- **WAL means three files, not one.** `session.sqlite`, `-wal` and `-shm`.
  Anything that copies "the session file" copies an incomplete state.
- **The bundled SQLite is built for the installed SDK, not for the deployment
  target.** The `cc` crate derives its own `-target` and ignores
  `MACOSX_DEPLOYMENT_TARGET`, so `sqlite3.o` declares a minimum macOS equal to
  the build machine's SDK. It runs where it was built. This has to be resolved
  before shipping to an older macOS.
- **Detaching the store is expensive for whoever lands in that case.** They
  browse an entire session with nothing written. There is no backup, no attempt
  at partial recovery, no "rename the bad file and start clean" — just the
  refusal and a banner. It is the right call (do not destroy > convenience) and
  it is still a dead end for the user: the only way out is deleting the file by
  hand.
- **Garbage tolerance spread everywhere, and that is silent debt.** An
  unreadable preference becomes the default, a route of unknown type is skipped,
  an unknown binding is skipped, an unknown `kind` becomes `Today`, a negative
  id becomes `0`, the id counter saturates instead of overflowing. Each of those
  is defensible on its own; together they mean a half-corrupted file loads
  **partially** and nobody is told what was lost.

## How this regresses

**Save layers:** the symptom is yesterday's session being stale when you open
today — the last few seconds are missing. That means one of the layers fell.
`structuralChangesSaveThemselves` screams if the debounce disappears (it opens
tabs, does not call `save()` and waits three seconds), and
`crashDoesNotCostTheSession` screams if a save without a quit stops counting.
`a_save_without_a_quit_reads_as_a_crash` screams if the clean shutdown marker
starts being written at the wrong point in the order.

**Detached store:** the symptom is the worst one in this ADR — someone opens the
browser with the odd file, uses it for twenty minutes, and the old session is
gone. It happens if the `Err(error) => (None, None, Some(...))` branch in
`ffi.rs` becomes something that keeps the `Store` alive, or if an
`unwrap_or_default()` gets dropped in where the `match` was.

**A test screams in that case.** The three tests this list once called for
exist:

1. A file whose bytes are not a valid database, opened with `Zer0::open`,
   asserting `load_error().is_some()` and `is_persistent() == false`:
   `crates/zer0-core/src/ffi_tests.rs::a_session_file_that_cannot_be_opened_is_reported_and_never_written_to`.
2. `save()` in that state leaving the file on disk **byte-identical** — the real
   guarantee, and not the same thing as `save()` returning `Ok`:
   `crates/zer0-core/src/ffi_tests.rs::a_session_that_opens_but_cannot_be_read_is_never_written_over`,
   which corrupts the contents of a database that opens fine and asserts
   `load_error` and `is_persistent()` as well.
3. On the Swift side, `BrowserModel.loadError` arriving populated and the banner
   appearing, so the refusal to write is never silent:
   `apple/Tests/Zer0ShellTests/SettingsTests.swift::SessionPersistenceTests/unreadableSessionWarnsInTheUI`.

`ffi_tests.rs::a_session_that_reads_fine_is_saved_as_usual` is the control: a
healthy session reads `load_error` `None`, `is_persistent()` true, and `save()`
still writes — without it, the byte-identical guarantee above would pass just as
happily on a `save()` that never wrote anything to anywhere.

Each has been seen failing under its named regression, broken on purpose.
Keeping the `Store` alive in the `Err` arm of `Zer0::open` fails the
read-failure test at its first assertion — `load_error().is_some()` — before any
write, while the unopenable test and the healthy control stay green. Swallowing
`load_error` in the could-not-open arm fails the unopenable test on the
reporting assertion only, its bytes assertion not reached — the test stops at
the reporting failure, and under that break the store stays detached so
`save()` still no-ops — and fails the Swift test on both `loadError` and the
banner. The controls staying green is what proves the mutations surgical.

## When to revisit

Three triggers:

1. **When `SCHEMA_VERSION` has to leave 1.** There is no migration path written;
   the first real `ALTER TABLE` has to choose between migrating and discarding,
   and that decision becomes its own ADR.
2. **When the full `save()` shows up in a profile.** The trigger is measuring,
   not guessing: if rewriting the whole session costs a frame in the UI, the
   path is an incremental save per dirty table.
3. **Before shipping to a macOS older than the build machine**, because of the
   bundled SQLite's `-target`.
