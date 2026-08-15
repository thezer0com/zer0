# ADR-0007: Every Space gets its own data store

- **Status:** Accepted
- **Date:** 2026-01-26
- **Lock:** `apple/Tests/Zer0ShellTests/NavigationRoundTripTests.swift::NavigationRoundTripTests/spacesGetSeparateDataStores`, `crates/zer0-core/src/reducer_tests.rs::each_space_keeps_its_own_cookie_jar`

## Context

A Space is only worth having if it is real isolation. A Space that is just a
visual grouping of tabs does not solve the problem it exists to solve: two
accounts on the same site, work and personal in the same window, a throwaway
context that does not contaminate the rest.

If every Space shared the default store, cookies would mix silently — the worst
kind of failure, because it looks like it works right up to the moment someone
notices they are logged in with the wrong account.

There is a second requirement, coming from Air Traffic (the rules that send a
URL to the Space that owns it): if a URL is going to be routed to another Space,
it has to load **in that Space's cookie jar**, never exist even for an instant
in the wrong one.

## Decision

Every `Space` carries a `data_store_id` (`crates/zer0-core/src/model.rs`), and
the Apple host turns it into an isolated store:

```swift
// apple/Sources/Zer0Shell/EngineHost.swift
return WKWebsiteDataStore(forIdentifier: uuid)
```

The core does not know what a `WKWebsiteDataStore` is. It only carries the
string and hands it over in
`EngineCommand::CreateWebView { tab, data_store_id, profile }`. The
`data_store_id` is generated **by the shell** and reaches the core through
`Action::CreateSpace { name, data_store_id }`, because the core has to be
deterministic and cannot hold a source of randomness (ADR-0002).

Three design consequences follow from that, all implemented:

- **An ephemeral profile gets `.nonPersistent()`**, not an identified store. A
  Space that promises to leave no trace writes no cookie, no cache and no local
  storage — and the `Store` does not record its tabs either (`store.rs`:
  `if space.profile.ephemeral { continue }`), nor its history (`reducer.rs`
  checks that before `history.record`).
- **An invalid UUID falls back to `.nonPersistent()`**, not to the default
  store. Falling back to the default would merge cookies across Spaces
  silently; the choice is to lose persistence rather than lose isolation.
- **Closing a Space deletes the store.** `CloseSpace` emits
  `EngineCommand::DeleteDataStore`, and the host calls
  `WKWebsiteDataStore.remove(forIdentifier:)`. Leaving the jar orphaned on disk
  would be a privacy leak with no way to reach it from the interface.

And as a consequence of that, routing **reopens** the page in the destination
Space instead of moving the tab: a web view is stuck with the jar it was built
with.

## Consequences

- **A web view does not change store. Period.** Any change that alters the jar
  or the profile requires destroying and rebuilding the view (`rebuild_view` in
  `reducer.rs`). That happens when dragging a tab between Spaces and when
  changing a Space's profile — and in both cases **the back/forward history goes
  with it**, along with the scroll, the half-filled form and the state of any
  web app on the page. Changing the user agent of a Space with ten open tabs
  reloads all ten.
- **N Spaces cost N caches on disk.** Each identified store has its own
  directory: cookies, cache, local storage, service workers. There is no
  deduplication between them, and nothing in the product shows how much that
  takes up.
- **Deleting is final and immediate.** Closing a Space wipes its logins with no
  trash and no undo. `ReopenClosedTab` brings the tab back; nothing brings the
  session back.
- **Losing persistence is silent.** The invalid-UUID fallback to
  `.nonPersistent()` protects isolation and tells nobody: the Space just stops
  remembering anything at all, and the only symptom is having to log in again
  every time.
- **The API is Apple's alone.** `WKWebsiteDataStore(forIdentifier:)` has no
  direct equivalent in `webkit2gtk`. `data_store_id` was kept as an opaque
  string precisely so the Linux host can map it onto its own mechanism
  (`WebKitWebsiteDataManager` with per-Space directories is the candidate), but
  that is an unverified bet: if the Linux mechanism has a different granularity,
  the field has the wrong shape.

## How this regresses

The symptom is the one that hurts most and is hardest to see: **logging into one
Space and showing up logged in on another.** Nothing breaks, nothing warns, and
the person finds out by sending a message from the wrong account.

The path there is short — someone swaps
`WKWebsiteDataStore(forIdentifier: uuid)` for `.default()`, whether through a
refactor or through a "safer" fallback for the invalid-UUID case.

`spacesGetSeparateDataStores` screams in that case: it explicitly asserts that
the web view's store **is not** `WKWebsiteDataStore.default()` and that it is
persistent. `each_space_keeps_its_own_cookie_jar` screams one level up, in the
core: if `CreateWebView` stops carrying the `data_store_id` of the Space that
owns the tab, it fails with no window needed.

A parallel symptom, covered by another test: an ephemeral Space whose store goes
back to being persistent. `ephemeralSpaceIsNonPersistent` calls it by name —
*"an ephemeral space that writes to disk is a broken promise"*.

## When to revisit

When the Linux host gets written. That is the moment we find out whether
`data_store_id` as an opaque string was the right abstraction, or whether
per-Space isolation has a different shape outside the Apple world.

Beyond that, one product trigger: if disk usage across multiple Spaces turns
into a real complaint, the question becomes whether cache can be shared while
cookies and storage stay separate — which is a new decision, not a revision of
this one.
