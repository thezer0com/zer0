# ADR-0023: An ephemeral Space records no history

- **Status:** Accepted
- **Date:** 2026-03-16
- **Lock:** `crates/zer0-core/src/reducer_tests.rs::an_ephemeral_space_keeps_its_pages_out_of_history`, `crates/zer0-core/src/reducer_tests.rs::an_ordinary_space_still_records_history`, `crates/zer0-core/src/store_tests.rs::an_ephemeral_space_keeps_its_tabs_off_disk`, `apple/Tests/Zer0ShellTests/ExtensionTests.swift::ExtensionTabTests/ephemeralSpacesAreReportedPrivate`

## Context

ADR-0007 gave every Space its own data store, and an ephemeral Space a
`.nonPersistent()` one: no cookie, no cache, no local storage. That covers what
*WebKit* writes.

It does not cover what *we* write. History is ours. It is a table in our SQLite
file, populated by the reducer, and it survives every quit. A Space that leaves
no trace in WebKit and a full list of every URL visited in it in our own
database has kept nothing at all — it has moved the leak somewhere the person is
less likely to look.

The failure is worse than the ordinary kind because of where it surfaces. The
person opens the command bar, types three letters, and the ephemeral session
they took the trouble to open is offered back to them as a suggestion, in front
of whoever is looking at the screen.

The obvious place to fix this is the interface: filter ephemeral URLs out of the
command bar, out of the history view, out of the suggestions. That fix is wrong,
and the reason it is wrong is the whole content of this decision.

## Decision

**The page is never recorded.** The promise is kept at the write, not at the
read.

`crates/zer0-core/src/reducer.rs`, in `Action::NavigationCommitted`:

```rust
// A page visited in an ephemeral space must not reach history:
// history is written to disk, and that space promised it would
// leave nothing behind.
let remember = session
    .browser
    .tab(tab)
    .and_then(|t| session.browser.space(t.space))
    .is_none_or(|s| !s.profile.ephemeral);
```

and `history.record` runs only `if remember`.

`remember` is computed **before** the tab is mutated, because the mutation
borrows the browser and the space lookup would be gone by then. That ordering is
load-bearing and reads like an accident; it is not.

The same rule holds one layer out, in `store.rs`: an ephemeral Space's tabs are
skipped on save (`if space.profile.ephemeral { continue }`). And one layer
further out again, in the shell: `ExtensionWindow.isPrivate(for:)` reports the
Space as a private window, so extensions are told not to persist anything from
it either.

### Why not filter in the UI

Because a privacy promise kept only in the interface is not kept. It is a
display convention, and it fails in every direction a display convention fails:

- A second surface reads the same table and does not know about the rule. The
  command bar filters; the history view, added later, does not.
- The data is on disk. Anyone with the file has it — `sqlite3 session.sqlite`,
  a backup, a synced folder, a stolen laptop, a forensic tool. The filter is not
  there.
- The rule has to be re-applied every time someone touches a query, forever, and
  the failure is silent when they forget.

Refusing the write costs one branch, once, at the single place a page enters
history. There is nothing to remember later because there is nothing to filter.

## Consequences

**What hurts:**

- **There is no way back.** Close the tab in an ephemeral Space and the URL is
  gone — not hidden, gone. No back-of-the-command-bar recovery, no "recently
  closed" that reaches it, no undo. That is the feature working, and it is still
  the thing people will lose work to.
- **The counters lie about the person's actual browsing.** History carries visit
  counts and drives ranking (ADR-0015). Time spent in an ephemeral Space is
  invisible to it, so a site used heavily there ranks as if never visited. The
  suggestions get worse in a way nobody will connect back to this.
- **Nothing in the interface says any of this.** A Space is ephemeral because
  somebody set a profile flag in Settings. There is no persistent marker on the
  window while browsing, no line saying "nothing here is being written down".
  ADR-0018 says the interface only asserts what it can back up; here it asserts
  nothing at all, and silence is a bad way to communicate a guarantee.
- **The check is per-navigation and reads the Space's *current* flag.** Make a
  Space ephemeral after browsing in it and the history already recorded stays
  recorded. Reasonable, undocumented in the UI, and exactly the kind of thing
  someone will assume works the other way.
- **The promise is only as wide as the places that remember to check.** Three
  independent sites enforce it today — the reducer for history, the store for
  tabs, the extension window for `isPrivate`. Every future feature that writes
  something derived from browsing (a reading list, a screenshot cache, a
  favicon store, a download record) is a fourth, fifth and sixth place that has
  to know. Nothing forces a new writer to ask the question.
- **Downloads are not covered here.** A file downloaded in an ephemeral Space is
  on the disk with its name in the download list. That is arguably correct — the
  file itself is on disk anyway — and it is not a decision anyone has recorded.

**What we get:**

- The guarantee holds against the file, not against the query. Whoever reads the
  SQLite file directly finds nothing, because nothing was written.
- One branch to review instead of a rule spread across every read path.
- Extensions are told, so they cannot become the leak the browser closed.

## How this regresses

**"I opened a private space and the URLs came back in the command bar."** The
`remember` guard is dropped or inverted during a refactor of
`NavigationCommitted` — most plausibly by someone restructuring the borrow so
the mutation and the record sit together, which is the tidier-looking code.
`an_ephemeral_space_keeps_its_pages_out_of_history` fails immediately, and it
asserts the whole history is empty rather than checking one entry, so a partial
leak fails it too.

**"Now nothing is in my history at all."** The opposite direction, and it is
just as easy: the condition is written to skip the record whenever a space
lookup is involved, or `is_none_or` becomes `is_some_and`.
`an_ordinary_space_still_records_history` is the other half of the pair and
exists for exactly this.

**"My private tabs came back after a restart."** The store's ephemeral skip goes
missing. `an_ephemeral_space_keeps_its_tabs_off_disk` covers it, and it is
listed here rather than only under ADR-0017 because it is the same promise.

**"An extension logged my private browsing."** `isPrivate(for:)` starts
returning `false` — a plausible simplification when someone finds it always
false in their test fixture. `ephemeralSpacesAreReportedPrivate` is the lock,
and its failure message says the point: *"an extension must know not to persist
anything from this space"*.

**And the one with no lock at all:** a new feature that writes something derived
from browsing without asking whether the Space is ephemeral. Nothing goes red,
because the test that would catch it does not exist yet — it would be a test
about the new feature. This is the real long-term risk and it is declared debt
here in as many words. A shared helper (`Browser::records_to_disk(space)`) with
every writer routed through it would close it; today the branch is spelled out
three times independently.

## When to revisit

- When any new subsystem persists something derived from browsing. That is the
  moment to build the shared helper rather than to spell the branch a fourth
  time.
- If the ranking distortion becomes visible — heavy ephemeral use making
  suggestions worse. The answer is not to record; it may be an in-memory,
  per-session ranking that dies with the Space.
- When the interface gets an ephemeral indicator. That is a UX decision of its
  own, and the honest version of it says what is not being recorded rather than
  just showing an icon.
- If downloads in an ephemeral Space turn out to need their own answer. They are
  outside this decision today and nobody has decided that on purpose.
