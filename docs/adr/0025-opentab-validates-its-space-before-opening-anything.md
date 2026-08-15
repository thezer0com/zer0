# ADR-0025: `OpenTab` validates its Space before opening anything

- **Status:** Accepted
- **Date:** 2026-03-23
- **Lock:** `crates/zer0-core/src/reducer_tests.rs::opening_a_tab_in_a_space_that_does_not_exist_is_refused`, `crates/zer0-core/src/reducer_tests.rs::a_rule_for_an_unknown_space_is_refused`, `crates/zer0-core/src/reducer_tests.rs::a_drop_on_a_space_that_is_gone_leaves_the_tab_untouched`, `crates/zer0-core/src/reducer_tests.rs::a_tab_whose_space_is_gone_reopens_where_you_are`

## Context

A `SpaceId` reaching the reducer from outside is a claim, not a fact. The
snapshot the shell is holding is from the last dispatch, and between reading a
`SpaceId` out of it and sending an action, a Space can close — a menu item held
open across a `CloseSpace`, a drag started before a sync, an extension calling
`chrome.tabs.create` with a window it saw a moment ago, a keyboard shortcut
firing against a stale binding.

`Action::OpenTab` was the one action that took the id on trust. It looked
harmless because the argument is `Option<SpaceId>` and the common path is
`None`, which resolves to the active Space. The uncommon path — an explicit id
that no longer resolves — created a tab anyway.

A tab in a Space that does not exist is not a cosmetic problem. It is:

- **invisible in the sidebar**, which lists tabs per Space;
- **never persisted**, because `store.rs` saves tabs by walking Spaces;
- **never archived**, because archiving walks the same structure;
- attached to a `data_store_id` that resolves to nothing, so it gets an empty
  cookie jar and no session on any site.

And it becomes the active tab. The window shows a blank page, the sidebar shows
no selection, and there is no gesture that reaches it.

## Decision

`OpenTab` validates before it creates, and refuses rather than repairing:

```rust
Action::OpenTab { space, url, parent } => {
    let space = space.unwrap_or_else(|| session.browser.active_space());
    // Every other action validates its SpaceId. Without this, a stale
    // id from a snapshot creates a tab no space owns: invisible in the
    // sidebar, never saved, and with no cookie jar.
    if session.browser.space(space).is_none() {
        return Vec::new();
    }
    ...
```

An empty command list is the reducer's "nothing happened". Nothing is created,
nothing is focused, and the engine is not asked to build a view.

### Refuse, not fall back

Falling back to the active Space was the alternative, and it is what
`ReopenClosedTab` does — deliberately, and for a different reason. The
distinction is what the action means:

| Action | Stale Space | Why |
| --- | --- | --- |
| `OpenTab { space: Some(gone) }` | refuse | the caller named a destination; landing somewhere else is not what was asked |
| `ReopenClosedTab` | fall back to active | the person asked for *that tab back*, and its Space is incidental — *"it comes back in the current one rather than vanishing again"* |

A silent fallback in `OpenTab` would put a page into a cookie jar the caller did
not choose. After ADR-0007 that is a privacy fault, not a convenience: a work
URL opened into the personal Space's jar is the exact thing Spaces exist to
prevent.

### It is the rule, not the exception

The comment says "every other action validates its `SpaceId`", and that is the
point: `OpenTab` was the gap being closed, not a special case being added.

- `ActivateTab` returns empty for an unknown tab.
- `MoveTabToGroup` checks tab *and* Space **up front**, because changing `kind`
  on a tab that never moved would pin a page the person only dragged past.
- `AddRoute` only pushes the rule if the Space exists — a rule pointing nowhere
  would route pages into the void.
- `CloseSpace` calls `routes.retain_spaces`, so rules cannot outlive their
  destination.

Actions naming a tab that no longer exists are dropped throughout, and the
module doc says why that is not defensive programming: engine events arrive
asynchronously, so a `TitleChanged` for a tab the person just closed is expected
traffic.

## Consequences

**What hurts:**

- **The click does nothing, and nothing says so.** Press ⌘T against a stale
  Space and no tab appears, no error, no shake, no toast. Doing nothing is
  strictly better than the alternative and it is still a screen that does not
  explain itself — which is the failure ADR-0018 spends its whole length on.
- **The caller cannot tell "refused" from "no commands needed".** `Vec::new()`
  is the return for both. Every reason a dispatch produced nothing looks
  identical from Swift, so the shell can neither log it nor react to it.
- **A check per action, repeated by hand.** Four actions validate a `SpaceId`
  and each spells it out in its own way. Nothing makes a new action do it; the
  next `Action` carrying a `SpaceId` will be written by someone who did not read
  this file. The type system is no help — `SpaceId` is a newtype over `u64` and
  every `u64` is one.
- **The race is narrowed, not closed.** The check runs at dispatch. Every action
  that reads a `SpaceId` from a snapshot is racing the same way, and validation
  turns a corrupt state into a no-op rather than into the thing the person
  wanted.
- **Refusing costs the person their input.** The URL they typed is discarded
  along with the action. A fallback would at least have opened the page
  somewhere — in the wrong jar, which is why we do not, but the typed text is
  genuinely gone.

**What we get:**

- No tab can exist outside a Space, so the sidebar, the store and the archiver
  can all walk Spaces without a "loose tabs" case.
- A stale id is a no-op instead of a privacy fault.

## How this regresses

**"⌘T opened a blank window and the sidebar is empty."** The guard is removed —
most plausibly by someone who reads it as redundant next to
`unwrap_or_else(active_space)` and does not notice that the `unwrap_or_else`
only covers `None`, not a stale `Some`. The tab is created, focused, invisible,
and lost at the next launch.
`opening_a_tab_in_a_space_that_does_not_exist_is_refused` sends
`SpaceId(9999)` and asserts three things at once: no commands, no change in
`tab_count`, and no change in `all_tabs()`.

**"An extension opened a tab into the wrong Space."** The guard is replaced by a
fallback to the active Space, which reads as friendlier and is not: the page
lands in whichever cookie jar happened to be in front. No test covers a
fallback, because a fallback would still open *a* tab — this one is caught only
by the assertion that `tab_count` did not change.

**"My routing rule vanished"** or **"a rule sends pages nowhere."** `AddRoute`
stops checking, and a rule is stored against a Space that does not exist. The
symptom is a rule that is visible in Settings and never fires.
`a_rule_for_an_unknown_space_is_refused` covers the create side;
`rules_for_a_deleted_space_are_dropped_with_it` covers the delete side.

**"I dragged a tab and it got pinned somewhere I cannot find."**
`MoveTabToGroup`'s up-front check moves below the `kind` assignment. The move
fails, the `kind` change lands, and a page the person only dragged past is now
pinned. `a_drop_on_a_space_that_is_gone_leaves_the_tab_untouched` is the lock.

**"⌘⇧T did nothing."** Someone makes `ReopenClosedTab` consistent with `OpenTab`
and refuses instead of falling back. That is a regression in the opposite
direction — the two actions differ on purpose — and
`a_tab_whose_space_is_gone_reopens_where_you_are` is why the difference is
recorded here rather than left to be rediscovered as an inconsistency.

**No lock, and the real risk:** the next action that carries a `SpaceId`. It is
not covered by anything above, and the failure mode is the one this ADR exists
to prevent. A helper on `Session` that resolves-or-refuses, with every such
action routed through it, would make the invariant structural instead of
repeated.

## When to revisit

- When a new `Action` carries a `SpaceId`. That is the moment to write the
  shared resolver rather than the fifth copy of the check.
- If `Vec::new()` meaning both "refused" and "nothing to do" ever costs a
  debugging session. A refusal reason crossing the FFI is a bigger change than
  it looks and would pay for itself the first time a support report is
  reproducible.
- If refusing silently turns out to be a real complaint. Then the shell needs to
  learn the action was refused, which is the same change as the point above.
- If `SpaceId` ever becomes a validated handle rather than a newtype over `u64`.
  Then most of this decision is enforced by the compiler and this ADR is
  superseded rather than revised.
