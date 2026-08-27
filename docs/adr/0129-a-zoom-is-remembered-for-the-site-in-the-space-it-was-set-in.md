# ADR-0129: A zoom is remembered for the site, in the space it was set in

- **Status:** Accepted, superseding the per-site paragraph of ADR-0095
- **Date:** 2026-08-24
- **Lock:** `crates/zer0-core/src/reducer_tests.rs::a_zoom_is_remembered_for_the_site_in_that_space`, `crates/zer0-core/src/reducer_tests.rs::a_zoom_reset_forgets_the_site_rather_than_remembering_one`, `crates/zer0-core/src/reducer_tests.rs::two_spaces_remember_two_zooms_for_one_site`, `crates/zer0-core/src/store_tests.rs::a_sites_zoom_survives_a_relaunch`, `crates/zer0-core/src/store_tests.rs::an_old_sessions_tab_zooms_seed_the_ledger`, `crates/zer0-core/src/store_tests.rs::a_reset_zoom_is_not_resurrected_by_a_sibling_tab`, `crates/zer0-core/src/store_tests.rs::an_ephemeral_space_writes_no_zooms_down`, `crates/zer0-core/src/store_tests.rs::a_factor_no_keystroke_could_have_set_is_refused`

## Context

ADR-0095 fixed the restore gap and declined per-site zoom in passing, naming
the three things it would need: somewhere for it to live, the answer to what
a tab's own zoom means once the site has one, and a revocation screen. Its
own revisit condition said "soon": the behaviour is what every browser a
person came from does, and per-tab zoom reads as the zoom forgetting itself
for as long as it lasts.

The three questions now have answers:

- **Where it lives.** A `site_zooms` ledger in the core, one remembered
  factor per `(space, canonical origin)` — the same shape as
  `site_permissions`, because the arguments are the same: a Space is an
  identity (ADR-0007), the size somebody reads a site at is part of reading
  it *there*, and a fact that outlives every tab that set it is not a field
  on one. Persisted as its own table (schema 14) for the reason every new
  table here exists: a column added to `tabs` or `spaces` never appears on a
  database that already exists, and a read failing on it costs the whole
  session (ADR-0017).
- **What a tab's zoom means.** It stops meaning anything on its own.
  `SetTabZoom` is write-through — the tab's `zoom_factor` becomes the
  engine-facing copy of the site's answer, not a second opinion — and a
  commit is the apply point: a tab arriving on an origin is drawn at
  whatever that origin remembers in its space, and at the ordinary size
  when nothing does. The engine's own zoom survives a navigation, which is
  precisely why the commit has to answer; without it, a tab leaving a
  zoomed site carries that site's size onto the next one.
- **Revocation.** ⌘0 forgets the origin's row rather than remembering 1.0 —
  a row that remembers the ordinary size is a row lying about being needed.
  A screen that lists and takes back remembered sizes is still not built;
  the reset is the whole of revocation for now, and that is debt this
  record names rather than pretends closed.

One more thing came with the territory: **sessions written by older
builds**. They carry zooms on the tabs and nothing in the ledger, and the
first launch after this change adopts them — one time, first tab wins per
origin — because the alternative is every zoom the person ever set dying
with the upgrade.

## Decision

**Zoom is per site, per space. One ledger in the core is the source of
truth; the tab's `zoom_factor` is its engine-facing copy; a commit applies
the site's answer; ⌘0 forgets it.**

- **Keyed by canonical origin**, through the same `origin_of` door
  permissions use, so there is one spelling of "what counts as a site" in
  the browser. A page with no origin to remember — `about:`, opaque `data:`
  — keeps its zoom on the tab until it navigates somewhere with one, and
  writes nothing down.
- **An ephemeral space keeps its zooms for the session and writes none of
  them** — the projection in `storable.rs` is the guarantee, the same line
  the tabs and the permissions are held to (ADR-0023).
- **A closed space takes its zooms with it**, beside its permissions and
  its trust exceptions: a size remembered for an identity that is gone is a
  preference nobody can find, and one the next space to reuse the name would
  inherit.
- **A file on disk is hostile until proven otherwise** (ADR-0024): a factor
  that is NaN or outside the clamp no keystroke could produce is dropped,
  not repaired into something the person never chose.
- **`restore_view_state` is unchanged and that is the point.** It still
  tells a returning view the zoom the tab already knew; what changed is
  where the tab's number comes from on the way back. The three locks
  ADR-0095 named still pass against this design, which is the evidence that
  the door did not move.

## Consequences

**What hurts:**

- **Two tabs on one origin are no longer two sizes.** Zooming one zooms the
  site, which is the product decision and still a change: somebody who kept
  one tab of a dense dashboard at 150% for readability and another at 100%
  for screenshots has lost the second one.
- **The tabs table still carries `zoom_factor` and it is still written.**
  It is the copy the engine-facing restore reads, and it keeps a session
  readable by older builds — but two numbers exist on disk and only one is
  the truth. The seed adoption is what keeps them from disagreeing on the
  first launch; after that, the write-through does.
- **No screen lists the remembered sizes.** ⌘0 on the site is the only way
  back to the ordinary size, and somebody who forgot which sites they zoomed
  has no way to find out. ADR-0095 called this out and it stays called out.
- **The adoption is first-wins.** Two old tabs that remembered different
  sizes for one origin cannot both be honoured, and whichever loaded first
  wins — invisible when they agreed, one moved size when they did not.
- **A visible reflow at launch remains** (ADR-0095's cost, inherited): a
  restored view is built at 1.0 and told otherwise a moment later.

**What we get:**

- The behaviour people expect: a site with unreadable type stays readable,
  in every tab, on every visit, and leaving it restores the ordinary size.
- Per-space, so a work login's dense dashboard does not decide what the
  personal account's whitespace looks like.
- Testable without a window: which site got which size, and in which space,
  is a question about the core's own state.

## How this regresses

**"My zoom keeps resetting when I restart."** ADR-0095's regression, one
layer up: the write-through in `SetTabZoom` is dropped as redundant with
the tab's own field — the model is right, the ledger is empty, and the
restore is honest about nothing. `a_sites_zoom_survives_a_relaunch` is the
fence.

**"One zoomed site infected the next one."** The apply at commit is
dropped, because the engine-facing copy already holds a number and setting
it looks redundant. It is not: the engine's zoom survives navigation, and
without the commit the last site's size rides onto this one.
`a_zoom_is_remembered_for_the_site_in_that_space` asserts both directions —
arriving and leaving.

**"⌘0 stopped resetting."** The forget is "simplified" into remembering
1.0, which behaves identically on this tab and leaves a row that lies about
being needed — and that resurfaces the moment the origin's row is what a
new tab reads. `a_zoom_reset_forgets_the_site_rather_than_remembering_one`.

**"My private window's zoom came back."** The ephemeral filter is moved
from the projection into a backend "because SQLite is the only one", and
the next backend inherits an empty rule with a full ledger.
`an_ephemeral_space_writes_no_zooms_down` holds the line where ADR-0023
drew it.

**"The upgrade ate my zooms."** The adoption of old per-tab zooms is
removed as dead code once nobody writes files without ledger rows — which
is exactly the files the people who never upgrade are still writing.
`an_old_sessions_tab_zooms_seed_the_ledger`.

**"A reset came back on the next launch."** The adoption runs on every
load instead of only over a file written before schema 14, and it cannot
tell "no row because the old build wrote none" from "no row because the
person pressed ⌘0" — so a sibling tab still carrying the old size re-seeds
what the person deleted. The version the file carried when it was opened is
the only honest difference between the two, which is the one thing the
schema version number is read back for.
`a_reset_zoom_is_not_resurrected_by_a_sibling_tab`.

**"A page opened at 400%."** The bounds check on load is dropped because
`SetTabZoom` clamps anyway; the file is not `SetTabZoom`, it is bytes a
hand-edited config or a corrupt disk put there (ADR-0024).
`a_factor_no_keystroke_could_have_set_is_refused`.

## When to revisit

- **When the revocation screen is worth building.** The ledger already
  holds everything it would list, and `SitePermissionsView` is the pattern.
- **If per-site zoom is ever wanted *across* spaces** — one size for an
  origin everywhere — that is a different identity model, not a setting on
  this one.
- **If the tab's `zoom_factor` column is ever removed**, it will be a
  schema change with a real migration, and the seed adoption retires with
  it.
- **When a Linux host reads this ledger**: the table and the semantics port
  as core state; nothing in them knows what a `WKWebView` is.
