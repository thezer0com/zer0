# ADR-0045: Persistence sits behind a `SessionStore` trait, and SQLite is one implementation of it

- **Status:** Accepted
- **Date:** 2026-05-07
- **Lock:** `crates/zer0-core/src/store_tests.rs::a_session_round_trips_through_the_trait_without_naming_the_backend`, `crates/zer0-core/src/store_tests.rs::a_save_that_fails_partway_leaves_the_stored_session_alone`, `crates/zer0-core/src/store_tests.rs::an_empty_database_loads_as_nothing_rather_than_failing`, `crates/zer0-core/src/store_tests.rs::a_save_without_a_quit_reads_as_a_crash`, `crates/zer0-core/src/ffi_tests.rs::a_session_that_opens_but_cannot_be_read_is_never_written_over`

## Context

The core talked to `rusqlite` directly. `Zer0::open` named `Store`, `State` held
an `Option<Store>`, and every promise ADR-0006 and ADR-0017 make about the
session was, in the code, a promise about one file format.

That is a problem before anybody proposes replacing anything. While the type is
concrete, the cost of *asking* whether some other store would suit is "rewrite
the persistence layer and find out", so the question never gets asked honestly —
not about the Git-backed store being assessed right now, and not about whatever
turns up in a year.

The second problem is that the guarantees were invisible. "Every save is a
single transaction" reads like a note about SQLite; it is a requirement on
anything that ever holds a session, and there was nowhere to write it down where
the next implementer would be made to read it. The same goes for the one that
matters most: `load()` telling "there is nothing stored here" apart from "there
is something stored and I could not read it". That distinction is the whole of
ADR-0017, it lives in the shape of a `Result<Option<..>>`, and nothing said so.

## Decision

**A `SessionStore` trait, in `crates/zer0-core/src/session_store.rs`.** Five
methods, and they are the entire surface the core needs:

```rust
fn load(&self) -> Result<Option<Session>>;
fn save(&mut self, session: &Session) -> Result<()>;
fn mark_clean_shutdown(&self) -> Result<()>;
fn take_clean_shutdown(&self) -> Result<bool>;
fn forget_history_before(&mut self, before_ms: u64) -> Result<usize>;
```

**Whole session in, whole session out, because that is what the core actually
does.** Every read path was walked before the trait was written, and there is
only one: at launch, the whole session is loaded into memory, and from then on
the reducer, the command bar's ranking, history's recency ordering and the tab
tree are all answered from the `Session` the core already holds. There is no
query interface here because there is nothing to query. Adding one shaped like
the SQL that happens to back it today would be the failure mode this ADR exists
to avoid.

**`Store` is the SQLite implementation and the only place `rusqlite` is named on
the session path.** `Zer0::open` is the one line in the browser that picks a
backend; `State.store` is an `Option<Box<dyn SessionStore + Send>>`, so nothing
downstream of that line can depend on the answer. `None` still means "this
browser writes nothing", which is what ADR-0017 turns a failed read into.

### What a backend must guarantee to be a legal implementation

This is the part worth having written down. The doc comments on the trait say
all of it; this is the list.

1. **`Ok(None)` and `Err` are different answers.** `Ok(None)` is "nothing has
   ever been stored here" and the caller will write over the nothing. `Err` is
   "something is stored and I could not turn it into a session", and the caller
   detaches and writes nothing for the rest of the run. Reporting a failed read
   as `Ok(None)` destroys the session on the first autosave twenty seconds
   later, with no backup and nothing on screen until the next launch.
2. **Repair, do not invent.** One value the store cannot make sense of — a
   routing rule of an unknown kind, a rebind for a command this version dropped,
   an unparseable preference, a download whose file is gone — is left out and
   the rest of the session comes back. Losing one setting must not cost thirty
   tabs. What is not allowed is filling the gap with a guess: an unreadable
   permission comes back unmentioned, never as granted.
3. **Order is data.** Tabs come back in their order, in their space, with their
   parent. Routing rules come back in match order. A medium with no inherent
   order has to write the order down.
4. **Storage order must not decide the outcome.** Where reconstruction depends
   on seeing two records together, the same content produces the same session
   whatever order it arrives in. The SQLite backend needs two passes over the
   permission rows for exactly this reason.
5. **`save` replaces, it does not merge.** After it returns `Ok`, what is stored
   is this session and nothing else. Cleared history stays cleared. A store that
   only adds and updates brings deleted pages back at the next launch; that has
   happened here once already.
6. **`save` is all of it or none of it.** A save that returns `Err`, or that the
   process dies in the middle of, leaves the previously stored session exactly
   as it was. Saving runs on a timer with the interface alive and again on the
   way out of a quit, so "interrupted halfway" is ordinary. A backend that can
   leave half a session behind is not a legal implementation.
7. **Two rules about content travel with the data, not the backend.** An
   ephemeral space leaves no trace of its pages — its tabs and its split are not
   written, though the space is. A download still running is written down as
   interrupted; a failed or cancelled one is not written at all. Both are
   promises made to the person using the browser.
8. **The clean-shutdown marker is written last and read once.** Its presence has
   to mean the save before it is durable, or it is worthless. Reading it clears
   it, so the current run counts as unclean until it ends properly. A store that
   was never marked answers `false` — that is a normal state, not an error.
9. **`forget_history_before` touches history and nothing else**, and returns how
   many entries went, because a "clear history" that silently removed nothing
   looks exactly like one that worked.
10. **Opening is not on the trait.** How a store is addressed — a path, a
    directory, a URL — is the one thing backends cannot agree on, and inventing
    a lowest common denominator for it would buy nothing.
11. **The error keeps two failure modes apart.** `StoreError::Backend` is "the
    store would not answer" and says nothing about the content;
    `StoreError::Unusable` is a statement about the content. Neither one is
    where "nothing stored yet" goes.

## Consequences

**What we get.** A second backend is now a file that implements five methods and
one line changed in `Zer0::open`, and it has a written contract to be measured
against instead of a reading of `store.rs`. The guarantees that were tacit are
in front of whoever writes it, in the place they cannot skip.

**What this costs, honestly:**

- **The trait cannot enforce most of what it promises.** Clauses 2, 3, 4, 5, 7
  and 8 are prose and tests, not types. A backend that ignores all of them still
  compiles. Only atomicity and the empty-versus-unreadable distinction have locks
  today, and those locks run against the SQLite implementation, because it is the
  only one there is. The suite proves the contract holds *here*; it cannot prove
  a second backend holds it.
- **Clause 7 asks a backend for judgement, not just storage.** The ephemeral
  rule and the download-state rule live inside `Store::save`, so a second
  implementation has to reimplement them rather than inherit them. The right fix
  is a projection on `Session` — "what is worth writing down" computed once,
  before any backend sees it — and it was not done here because it is a change
  to what `save` reads, and this change was meant to alter nothing.
- **`StoreError` no longer carries the driver's error, only its message.**
  `Database(#[from] rusqlite::Error)` became `Backend(String)`, because an
  abstraction whose error names one backend makes every other backend
  second-class. The source chain is gone (nobody used it) and the text a person
  sees in the session-warning banner changed from `database error: …` to
  `the session store failed: …`.
- **`mark_clean_shutdown` and `take_clean_shutdown` take `&self` and write.**
  SQLite allows it; a backend that cannot write behind a shared reference has to
  reach for interior mutability. Kept as it was because tightening it would have
  edited tests that have nothing to do with this decision.
- **Loading is all-at-once, including all of history.** That is not a new cost —
  it is what the core already did — but it is now a contract: a store that
  cannot cheaply hand over everything is not usable without changing this trait.
- **One existing test file changed.** `download_reducer_tests.rs` gained a
  `use crate::session_store::SessionStore;`, because calling a trait method needs
  the trait in scope. No assertion moved.

## How this regresses

- **The trait grows a method shaped like a query.** Someone adds
  `fn tabs_in_space(..)` or `fn recent_history(limit)` because it is convenient,
  and the abstraction becomes an ORM with one implementation. There is no
  symptom for a person here at all; it is discovered the next time somebody
  tries to write a second backend and finds they cannot.
- **A backend writes as it goes.** The person opens the browser and finds half
  of yesterday's tabs sitting next to half of today's, and no way to say which
  half is missing. `a_save_that_fails_partway_leaves_the_stored_session_alone`
  is what stands in the way: it makes a save fail after the tabs are written and
  before the routes are, and demands the last whole session back.
- **A backend answers `Ok(None)` for a read it could not perform.** This is the
  worst outcome in the record and it has no symptom before the damage:
  thirty tabs are replaced by one, twenty seconds in, and the person assumes
  they did it. `a_session_that_opens_but_cannot_be_read_is_never_written_over`
  covers it end to end, byte for byte on disk.
- **Something bypasses the trait.** A new call site imports `Store` directly
  instead of holding a `dyn SessionStore`. Nothing catches this — no test can
  see an import — and it is why `Zer0::open` carries a comment saying it is the
  only place allowed to name a backend.

## When to revisit

- **When a second backend is actually written.** The first real implementation
  is what will show which clauses are contract and which are wishes. That is the
  moment to move clause 7 out of `save` and into a projection on `Session`, so
  the ephemeral rule cannot be forgotten by a backend that never read this file.
- **If history stops fitting in memory.** Loading everything at launch is the
  assumption underneath "there is nothing to query". When that breaks, the trait
  gains a real read interface, and it should be designed from the ranking the
  command bar actually does — not from what any one store makes easy.
- **If a backend needs an open that can be slow or can fail in ways the caller
  must act on.** Opening deliberately sits outside the trait; a network-backed
  store may make that the wrong call.
- **If `StoreError` needs a third variant.** Two is enough for one backend. A
  store that can be busy, or unreachable and retryable, is telling the caller
  something the caller might act on, and flattening that into `Backend` would
  lose it.
