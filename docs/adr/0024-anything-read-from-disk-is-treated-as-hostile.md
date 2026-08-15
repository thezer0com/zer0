# ADR-0024: Anything read from disk is treated as hostile

- **Status:** Accepted
- **Date:** 2026-03-19
- **Lock:** `crates/zer0-core/src/store_tests.rs::a_half_written_session_is_repaired_not_trusted`, `crates/zer0-core/src/store_tests.rs::a_corrupt_id_does_not_overflow_the_id_counter`, `crates/zer0-core/src/store_tests.rs::a_restored_session_keeps_handing_out_fresh_ids`, `crates/zer0-core/src/store_tests.rs::a_navigation_error_does_not_survive_a_restart`, `crates/zer0-core/src/store_tests.rs::an_unknown_route_kind_is_skipped_without_losing_the_others`, `crates/zer0-core/src/store_tests.rs::a_binding_this_version_does_not_understand_is_skipped`, `crates/zer0-core/src/reducer_tests.rs::a_nan_zoom_is_refused_rather_than_poisoning_every_future_save`

## Context

`session.sqlite` sits in Application Support. It is a plain file. It gets
half-written by a crash, written by a version of `zer0` that no longer exists,
opened in a SQLite browser by someone curious, restored from a backup taken
mid-save, or edited by hand by exactly the sort of person who runs a browser
like this one.

It is tempting to treat it as our own data, because we wrote it. That is the
mistake. Between the write and the read there is a filesystem, a crash, a
version bump and a human, and any one of them can hand back something the code
that reads it never anticipated.

The consequences of trusting it are not "a bad row". They are:

- a **panic on load**, which costs the whole session before the window opens;
- a tab in a Space that does not exist — invisible in the sidebar, never saved
  again, and with no cookie jar;
- an id counter that **wraps**, so the next tab opened is handed an id a live
  tab already holds;
- a value SQLite refuses to store, which fails not that save but **every save
  from then on**.

ADR-0017 covers the case where the file cannot be read at all. This one covers
the harder case: the file reads fine, and what is in it is wrong.

## Decision

**Every value crossing into the core from storage is validated, and anything
inconsistent is dropped rather than trusted.** The browser comes back smaller
and correct rather than complete and broken.

### `Browser::restore` scrubs, it does not load

`crates/zer0-core/src/model.rs::restore` is where a stored session becomes a
running one, and almost all of it is refusal:

| What it drops | Why |
| --- | --- |
| tabs whose `space` is not in `spaces` | a tab in no Space is invisible, unsaved and jarless |
| `tab_order` entries with no tab behind them, or pointing at another Space's tab | a stored order is a claim about tabs, not a fact |
| `last_active_tab` not in that Space's order | returning to a Space would focus nothing |
| `parent` that is unknown **or is the tab itself** | a self-parented tab is a cycle in the tab tree |
| `active_tab` that no longer exists | |
| `active_space` that no longer exists — falls back to `space_ids[0]` | |

And in the other direction, one addition: any tab the stored order forgot is
appended, sorted, because *"a tab the stored order forgot still belongs
somewhere, otherwise it would be invisible but alive"*.

`restore` returns `None` only when there is no Space at all, since a browser
with nowhere to put a tab is not representable.

### The id counter saturates rather than wrapping

```rust
// saturating: a hand-edited or corrupt row can hold a value that
// overflows on +1, and panicking on load would cost the whole session.
let next_id = known.iter().map(|t| t.0)
    .chain(space_ids.iter().map(|s| s.0))
    .max().unwrap_or(0)
    .saturating_add(1);
```

A negative id in storage reads back as `u64::MAX`. The plain `+ 1` panics in
debug and **wraps to zero in release** — and the ids it then hands out collide
with tabs that are already open. A collision is not a crash: it is two tabs that
are the same tab, where closing one closes the other and a navigation in one
lands in the other. Saturating trades a broken counter for a stuck one, which is
visible and harmless by comparison.

### `NaN` is refused because of what it does to *every future save*

`crates/zer0-core/src/reducer.rs`, in `Action::SetTabZoom`:

```rust
// NaN survives clamp, and SQLite refuses it in a NOT NULL REAL
// column: one NaN would fail every save from then on, silently.
if factor.is_nan() {
    return Vec::new();
}
let factor = factor.clamp(0.25, 5.0);
```

This is why the rule is about the disk boundary and not only about disk reads.
`NaN` arrives from the shell, not from storage — but it is refused for what it
would do to storage. `clamp` does not catch it: `NaN.clamp(0.25, 5.0)` is `NaN`.
One tab with a `NaN` zoom makes the save transaction fail forever, the failure
is logged and swallowed (`saveNow` is best-effort by design), and the person
finds out at the next launch that nothing has been saved since whenever they hit
that key. `INFINITY`, by contrast, clamps to `5.0` and is stored — a bad zoom is
not a poisoned database.

### One unreadable value does not take the session down

The line is drawn at *structural*: a route with a kind this version does not
understand is skipped and the others load; a keybinding this version does not
understand is skipped and the rest of the keymap loads; a preference that will
not parse falls back to its default. Only a structural read failure detaches the
store (ADR-0017).

## Consequences

**What hurts:**

- **Data is dropped without telling anyone.** A tab in an orphaned Space simply
  is not there at the next launch. Nothing in the interface says "seven tabs
  were discarded because their Space was gone". The person concludes they lost
  tabs, which is true, and has no way to learn why or to get them back.
- **Repair is silent and irreversible.** `restore` runs before anything is
  visible and there is no record of what it changed. Debugging a report of
  "tabs went missing" means reproducing the corrupt file, because the running
  session no longer contains the evidence.
- **A saturated id counter is a browser that stops working in a specific way.**
  Once `next_id` is `u64::MAX` it stays there, and every new tab collides. We
  swapped a wrap for a stick, and neither is a working browser. Nothing detects
  or reports the stuck state.
- **The scrub is a hand-written list.** Six invariants, spelled out one by one in
  one function. A new field with a reference in it — a tab group, a pinned
  ordering, a per-tab rule — has to be added to that list by whoever adds the
  field, and nothing forces them to. The symptom of forgetting is a dangling
  reference that survives a restart.
- **`NaN` is refused for one field only.** Zoom is guarded because someone found
  it. Any future `f64` reaching a `NOT NULL REAL` column has the same failure
  mode and no guard, and the failure is the worst-shaped one in the codebase:
  silent, permanent, and discovered a day later.
- **Validation happens at load, not at the type.** `TabId` is a newtype over
  `u64` and any `u64` is a valid one. The invariants live in `restore` because
  they are relational, and that means they are checked once rather than being
  impossible to violate.

**What we get:**

- A corrupt file produces a smaller browser, never a panic before the window
  opens and never a browser that lies about its own state.
- The id counter never hands out a colliding id, which is the failure that would
  be blamed on everything except its actual cause.
- One bad row costs one row.

## How this regresses

**"It crashed before the window even appeared."** A `+ 1` came back, or a
`.expect()` was added to a lookup in `restore` because "that can't be `None`".
It can. `a_corrupt_id_does_not_overflow_the_id_counter` writes an id of `-1`
into a real database and reopens it.

**"Two tabs are the same tab."** Closing one closes the other; typing in one
navigates the other. This is the id collision, and it is the single hardest bug
in this ADR to diagnose from a user report, because nothing about the symptom
points at storage. `a_restored_session_keeps_handing_out_fresh_ids` asserts the
next id issued after a round trip is above every restored one.

**"Tabs I never opened are in the sidebar"**, or their opposite, **"a tab is
open but I cannot see it anywhere."** The `tab_order` reconciliation was
simplified — either the retain or the append-what-was-forgotten half.
`a_half_written_session_is_repaired_not_trusted` turns foreign keys off, writes
a tab into a Space that does not exist and repoints parents at nothing, then
asserts both that the orphan is gone and that every surviving parent resolves.

**"It says I am offline and the page loads fine."** `last_error` survived the
restart. Yesterday's outage shown over a page that is about to work.
`a_navigation_error_does_not_survive_a_restart` is a one-assertion test with the
right sentence in it.

**"Nothing has been saved since Tuesday."** The `NaN` guard is removed as
redundant "because we clamp anyway". Every save fails from that moment, the
error is logged and swallowed, and the person loses everything from Tuesday
onward.
`a_nan_zoom_is_refused_rather_than_poisoning_every_future_save` is the lock, and
`infinite_zoom_still_clamps` is its counterpart, so nobody closes the hole by
rejecting every non-finite value and quietly breaking clamping.

**"My routing rules disappeared after an upgrade."** A single unknown route kind
started failing the whole load instead of being skipped.
`an_unknown_route_kind_is_skipped_without_losing_the_others` and
`a_binding_this_version_does_not_understand_is_skipped` hold the "one bad row
costs one row" line for the two places that already have forward-compatibility
concerns.

**Declared debt.** Two invariants in the table above have no test of their own:
**a self-parented tab** (`*p != tab.id`) and **`active_space` falling back to
`space_ids[0]`**. Both are one-line additions to `store_tests.rs` and both are
the kind of branch that gets deleted as unreachable by someone reading only the
function.

## When to revisit

- The next time an `f64` is persisted. That is the moment to decide whether the
  `NaN` guard becomes a shared helper at the storage boundary instead of a
  branch in one action.
- When a field carrying a reference is added to `Tab` or `Space`. `restore` is
  the list that has to grow, and it will not remind anyone.
- If "my tabs went missing" reports appear with no explanation. Then the silent
  repair needs to leave a trace — a count of what was dropped, surfaced the way
  ADR-0017's session warning is surfaced.
- If the id counter ever actually saturates in the wild. That would mean a
  stuck browser with no message, and the answer is renumbering on load rather
  than a bigger integer.
