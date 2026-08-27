# ADR-0128: An extension hidden from the row says so on the row, and only when the row is there to say it

- **Status:** Accepted
- **Date:** 2026-08-24
- **Lock:** `apple/Tests/Zer0ShellTests/ExtensionTests.swift::ExtensionUnreadTests/anExtensionHiddenFromTheRowSaysSoAndPinningClearsIt`

## Context

ADR-0068 put every extension's button on the row in the sidebar, and gave a
person the right to take one off it. What that bought came with a silence:
an extension that is running, holding something it wants to show, and not on
the row, has `hasUnreadBadgeText == true` on its action and nowhere for that
fact to be seen. WebKit maintains the flag for precisely this case — the
header says so: *"useful for higher-level notification badges when extensions
might be hidden behind an action sheet."*

The silence is the defect ADR-0068's revisit condition named: a password
manager that unlocks in the background and wants attention is unheard by
construction, and the person who hid it has no way to know that hiding it
cost them its only channel.

The flag's lifecycle is the engine's and the contract is partly ours:

- set to `YES` automatically when `badgeText` changes to something non-empty;
- cleared automatically when the popup is presented or the badge empties;
- **cleared by the app when the badge has been presented to the user** — and
  for an unpinned extension, the badge is never presented, so the flag is
  ours to clear or nobody's.

This is a new claim on screen (ADR-0018's test applies to marks, not just
numbers: a dot nobody can vouch for is the same lie as an invented count), so
it is a decision rather than a detail — which is why the revisit said so.

## Decision

**A hidden extension's unread signal is a small accent dot on the extension
row itself, at its trailing edge, and it exists only while the row does.**

### The claim

The dot is drawn when an installed, running extension that declares an action
is **not** on the row and its action for the tab in front reports
`hasUnreadBadgeText`. Read fresh on every draw, off the same
`extensionActionRevision` bump the buttons read — for the same reason nothing
about an action is cached (ADR-0020, ADR-0068): a stale dot is a claim about
an extension's state that stopped being true silently.

Clicking it opens Manage Extensions, which is the one place a hidden
extension can be reached at all. A dot that only explained itself on hover
would invite the click and waste it.

### Pinning is presenting

`setExtensionPinned(id, true)` clears the flag on the action for the tab in
front. The badge is on screen from that moment, which is the contract's own
definition of presented — and without the clear, the sequence *pin, see the
badge, unpin* would draw a dot for something the person already saw. The
clear is the app's half of the engine's contract; skipping it is not an
option the engine covers.

### Not core state

Which extensions are on the row is the core's (ADR-0068). The unread flag is
not: it is the engine's fact about the extension's own action, read the same
way the badge text is, and the core has no WKWebExtension to ask. A
`webkit2gtk` host reads its own equivalent off its own engine and inherits
the claim unchanged.

### The accent, and only the accent

The dot wears `.tint`, for the reason the badge does: it is an attention
mark, not a status claim, and a palette status colour would rank something
nobody measured (ADR-0018).

## Consequences

**What hurts:**

- **No row, no signal — and the no-row case is the strongest one.** Somebody
  who hid every button has hidden every channel, and the ADR that governs
  the row says nothing pinned draws nothing at all, not a thinner thing. The
  honest options were a dot with no row around it (furniture the row's own
  rule refuses) or a new always-present control, which is Chrome's puzzle
  button and a much bigger decision. This takes neither and says so.
- **An extension that never clears its unread keeps the dot lit forever.**
  The engine's flag is the extension's to set and mostly the app's to clear,
  and an extension that holds it lit is choosing to nag. The escape, if it
  is ever needed, is a per-extension silence in Settings — not a global
  switch that turns the channel off for the extensions that use it honestly.
- **The clear on pin covers the tab in front.** Actions are per-tab; a badge
  shown for one tab does not present another tab's. The residual is a dot
  after unpinning for a badge that was visible on a background tab — the
  same class of edge the badge itself has, and smaller.
- **One more thing at the bottom of the sidebar.** The third conditional
  mark in a band that already has two, and ADR-0068's "a fourth strip is one
  too many" is now one mark closer.

**What we get:**

- A hidden extension that wants attention can be heard, and the one click
  the dot costs goes where the extension can actually be reached.
- The dot says only what the engine vouches for: it appears when the flag is
  set and not before, and the pin path clears what the person has seen.
- Nothing about it is cached, so it moves when the extension moves.

## How this regresses

**"The dot froze."** Somebody hoists the unread read out of the draw "to
avoid asking WebKit on every redraw" — the same motive that would freeze the
badge, and the revision bump is the only thing that makes the view ask
again. The lock test sets the flag after the row exists and expects the
answer to move.

**"The dot appears for an extension that has a button."** The filter that
subtracts the row's members from the installed set is dropped or widened,
and a pinned extension's unread draws a second mark beside its own badge.
The lock test pins and expects silence.

**"You can never get rid of it."** The clear in `setExtensionPinned` is
removed as a side effect nobody asked about — and the contract's line
("should be set to `NO` by the app when the badge has been presented") is
the whole reason it is there. The lock test un-pins after seeing the badge
and expects silence.

**"The dot gets a second home."** It starts appearing on Settings' extension
rows, or on the sidebar toggle, one surface at a time — and a claim that
lives in two places is two claims to keep true. Nothing here goes red for
that; this paragraph is the fence.

**"It should be red, dots mean warnings."** A palette status colour here
ranks a stranger's nag as the browser's own alarm. The badge had this
argument; the dot inherits the answer.

## When to revisit

- **If a home for the no-row case is wanted.** That is a new control — the
  puzzle button — and it takes its own ADR about what the sidebar may hold,
  not an amendment here.
- **If extensions in the wild hold the flag lit abusively.** The per-extension
  silence in Settings is the escape, and it wants evidence first: one real
  extension, named, misbehaving.
- **If Apple moves the unread signal to the context or the manager.** Then
  the per-tab read becomes the wrong question and this follows the badge
  wherever it goes.
- **When a Linux host is attempted.** The claim ports; the dot's home is the
  row's, and the row's placement was already answered per host (ADR-0068).
