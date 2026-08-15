# ADR-0068: An extension button lives where the sidebar's own controls live

- **Status:** Accepted, superseding one sentence of ADR-0010
- **Date:** 2026-07-27
- **Lock:** `crates/zer0-core/src/ffi_tests.rs::an_extension_with_no_button_is_never_on_the_row`, `crates/zer0-core/src/ffi_tests.rs::an_extension_that_is_not_running_is_not_on_the_row`, `crates/zer0-core/src/ffi_tests.rs::a_pin_naming_something_no_longer_on_disk_leaves_no_gap`, `crates/zer0-core/src/store_tests.rs::a_pinned_extension_is_still_pinned_after_a_relaunch`, `crates/zer0-core/src/store_tests.rs::an_extension_deliberately_unpinned_stays_unpinned_across_a_relaunch`, `crates/zer0-core/src/store_tests.rs::the_order_of_the_extension_row_survives_a_relaunch`, `crates/zer0-core/src/extension_pins.rs::adopting_never_undoes_a_deliberate_unpinning`, `crates/zer0-core/src/ext/manifest.rs::an_extension_that_declares_no_button_has_none`, `apple/Tests/Zer0ShellTests/ExtensionTests.swift::ExtensionPinTests/pinningSurvivesARelaunch`, `apple/Tests/Zer0ShellTests/ExtensionTests.swift::ExtensionPinTests/anExtensionWithNoActionIsNotOnTheRow`, `apple/Tests/Zer0ShellTests/ExtensionTests.swift::ExtensionPinTests/aMalformedIconDoesNotTakeTheRowDown`, `apple/Tests/Zer0ShellTests/ExtensionTests.swift::ExtensionPinTests/perTabStateFollowsTheTab`

## Context

ADR-0020 shipped extensions. ADR-0028 gave them a consent dialog and a screen in
Settings. Between them they cover everything about an extension except the one
thing most extensions are *for*: 1Password is installed, running, holding what it
asked for — and there is nowhere in the browser to click it.

That is not a missing button. An extension action is an interface a third party
wrote and expects to be reachable; a password manager with no way to open its
popup is a password manager that does not work. The Settings pane can say it is
running, which is the browser reporting on something a person cannot use.

So there has to be a row of extension icons somewhere, and that is exactly what
ADR-0010 refused.

**The refusal is right and its argument is right.** Every mainstream browser
charges 60–100pt at the top of every window forever; the value is occasional and
the cost is permanent. A row of extension icons above the page is the second item
in the junk drawer, and ADR-0010's own regression list names this feature
specifically: *"Somebody needs to show the favicon, or the blocking status, or the
extension icon, and adds 'just one item' to a `.toolbar`. The second item arrives
two weeks later."*

Both of those are true at the same time, and picking a side gets you either a
browser with a 2009 toolbar or a browser whose extensions do not work.

## Decision

**An extension's button goes wherever the sidebar's own controls go.**

With the sidebar open that is the sidebar, in a row above the space chips. With
the sidebar hidden (⌘B) it is `WindowChrome`, in the space that strip already
reserves and leaves empty.

### Why the sidebar is not the thing ADR-0010 refused

ADR-0010 governs what sits **above or over the page**. The sidebar is beside it.
Its width is already spent and already argued for — ADR-0014 accepts permanent
vertical chrome on the grounds that *"the sidebar does something the person does
not know (which tabs exist), and the address bar does not"* — so a row inside it
takes **nothing** from the page. ADR-0010's test, *does it pay for itself on
every page*, is a test for things that charge the page. This charges it zero.

What it does charge is sidebar height, and that cost is paid honestly: the row
lands next to the space chips, which are the other row of small, always-available
controls, in the band under the tab list that had nothing in it. Two rows of
furniture at the bottom, under the list of places. And it is **conditional**:
nothing pinned draws no row at all, not a thinner one.

### The sentence this supersedes

Hiding the sidebar is a real state, and it must not mean the password manager is
unreachable. So the row travels into `WindowChrome`, and that contradicts one
sentence of ADR-0010's decision, quoted exactly:

> *"**`WindowChrome`** — a 38pt strip that only exists **when the sidebar is
> hidden**. It is not a toolbar: it is where the window's traffic lights live and
> where you grab the window to drag it, since there is no title bar."*

**"It is not a toolbar" is superseded.** It now carries a control that is not the
window's own. Everything else in that clause stands, including the 38pt and the
condition.

That sentence was doing real work — it is what stopped the strip becoming a junk
drawer — so it is replaced rather than deleted, by a rule with an edge on it:

> **`WindowChrome` may hold a control if and only if the sidebar holds that same
> control.**

The strip exists *because* the sidebar is away. It already carries the sidebar
toggle for precisely this reason, and ADR-0010 already says so of the sidebar:
*"With the sidebar open the sidebar plays that role, and the strip is gone."* A
pinned extension button makes the same journey for the same reason. A favicon, a
blocking badge, a padlock and a reader-mode button are in no sidebar, so under
this rule none of them can arrive here — which is the discipline the old sentence
was providing, stated so that it has a boundary rather than a blanket.

The page cost of the strip is unchanged at 38pt: the buttons sit in
`Metrics.trafficLightWidth`, a reservation that existed only to balance the
centred title and drew nothing.

### The keyboard path

**⇧⌘1..⇧⌘9 press the first nine buttons on the row.** One Shift away from
⌘1..⌘9 selecting the first nine tabs, which is one sentence to learn rather than
nine chords to memorise, and it is a `UiCommand::RunPinnedExtension { index }`
in the core beside `SelectTab { index }` rather than something invented here.

Chrome has nothing at all here; its extension buttons are pointer-only. The
reason to have an answer is that a password manager is reached for mid-typing,
which is the worst possible moment to be sent to the mouse.

`KeyPress.chords` already resolves ⇧⌘1 through the key's unshifted glyph, so this
needed no new key handling — the same machinery that makes ⇧⌘\ work.

### What is behaviour and what is look

`Zer0::pinned_extensions()` is one door and answers the whole question: which
extensions are on the row, in what order. Four rules live behind it, and every
one is behaviour:

- **the order**, which is what the chords count through;
- **an extension with no `action` in its manifest is never on it.** `has_action`
  is parsed in `ext/manifest.rs` from `action` / `browser_action` / `page_action`
  rather than asked of the engine, because `WKWebExtensionContext.action(for:)`
  answers for every extension whether it declared one or not — a browser that
  asked it would draw a button for a content-script-only extension, and that
  button would do nothing when pressed;
- **an extension that is not running is not on it either**, decided through
  `extension_permissions::standing` so that "running" is one answer in one place;
- **a pin naming something no longer on disk produces nothing rather than a gap.**

The fourth is not fastidiousness. **The row the shell draws and the list the
chords count through have to be the same list.** A shell that drew "the pinned
ones that are actually running" over a core that counted "the pinned ones" would
be off by one for everybody with a switched-off extension, ⇧⌘2 would press the
wrong extension, and nothing on screen would look wrong.

Everything else is the shell's: the size of the box, the corner it rounds to, the
wash under the pointer, which edge the popover opens from.

### Pinning is a preference, so it is core state

`Session.extension_pins` holds one `ExtensionPin { extension_id, pinned }` per
extension the browser has taken a view on, in row order, projected through
`storable.rs` and stored in `extension_pins` (schema 11).

**An entry rather than a list of ids, and that is the whole design.** A
`Vec<String>` of what is pinned cannot tell *"nobody has decided about this"*
apart from *"somebody deliberately hid this"* — the same distinction ADR-0028
makes about denied permissions, and for a sharper reason. An extension that
declares a button is **pinned when it starts running**, because an extension that
installs with nowhere to click it is the defect this ADR exists to fix and Chrome
ships that defect under the name "pinning". Adoption therefore runs on every
launch. If absence meant "not pinned", every launch would re-show the one
extension somebody went out of their way to hide.

Taking one off the row is a right-click on it — the gesture people already
have — and a switch on its row in Settings, both through one path.

### The popup

A press calls `WKWebExtensionContext.performAction(for:)` rather than reaching
for `popupWebView`, because that is what marks the tab as having had a user
gesture, which is the whole of what `activeTab` means. WebKit then calls back
through `presentActionPopup:`, and the button that was pressed puts
`action.popupPopover` on screen, hanging off itself: out to the right in the
sidebar, downwards from the strip.

`popupPopover` rather than re-hosting `popupWebView` in a SwiftUI popover,
because the popover WebKit hands back sizes itself to the extension's own
content. A fixed frame around somebody else's interface is a password manager
with its unlock button cut off. `.transient` is the behaviour: Esc closes it,
clicking the page closes it.

An extension may also open its own popup with nobody having clicked. That
arrives by the same road and lands on the same button. When there is no button —
the extension is unpinned — the delegate reports `nowhereToShowIt` rather than
completing successfully, because saying the popup was shown is a lie told to an
extension that then believes its interface is on screen (ADR-0018).

### Per-tab state, and a stranger's artwork

An action's icon, title and badge are per-tab and change as you browse. Nothing
about one is cached: every button reads `action(for: activeTab)` as it draws, for
the reason ADR-0020 gives about tabs, and `didUpdateAction` bumps one revision on
`BrowserModel` so SwiftUI has a reason to ask again. A stale icon is a claim about
the page in front of you that stopped being true silently, which is worse than no
icon.

The badge is the extension's own string, printed as it arrives, with a ceiling on
how far it may run and a visible truncation. Its colour is ours because
`WKWebExtensionAction` does not expose the one a manifest asks for; the accent is
right because a badge is an attention mark and not a status claim, and a palette
status colour would rank something nobody measured.

Icons come from an untrusted package (ADR-0022). Three failures — the engine
could not load it, it loaded as nothing, it is not an icon but an image somebody
put in the icon slot — all end at the same puzzle-piece glyph rather than on
screen. The absurd-size case is refused rather than scaled, because drawing it
means decoding it first and decoding is the whole of the cost.

**What makes a row of foreign pictures look like one row is the container, not
the artwork.** Every icon gets the same box, smaller than the same hit target, so
a full-bleed square logo and a small centred glyph read at the same weight and
the difference between them is a margin rather than a size. Nothing is masked,
tinted or desaturated: an extension's icon is the thing you recognise it by, and
a browser that restyles it has taken away the only thing the icon was for.

## Consequences

**What hurts:**

- **The strip's discipline is now a sentence, not a fact.** "It is not a toolbar"
  needed no judgement. "Only what the sidebar has" needs somebody to ask the
  question, and the answer for a padlock is genuinely arguable — one could put a
  padlock in the sidebar and then it would qualify. The rule constrains the order
  of the argument rather than settling every case.
- **The sidebar's bottom is getting crowded.** Kept pages, extensions, spaces:
  three strips under the list, each conditional, each individually justified. A
  fourth would be one too many and there is nothing here that says which.
- **Pinned by default means the row fills up.** Somebody with eleven extensions
  gets eleven buttons and has to hide ten of them. The alternative — Chrome's,
  where nothing is pinned and nobody finds the pin — is worse, but this is a real
  cost paid by the people with the most extensions.
- **Only nine have a chord.** The tenth onwards are pointer-only, and the tooltip
  says nothing about a shortcut rather than printing one that does not work.
- **The row does not reorder.** Order is the order things were adopted. It is
  stable, which is what makes ⇧⌘1 mean the same thing tomorrow, and it is not
  something anybody can change — so an extension you want first is first only if
  you installed it first.
- **A badge with words in it truncates.** Extensions do put text in badges. The
  truncation is visible and honest, and it is still less than the extension meant
  to say.
- **`hasAction` is a second parser over the manifest.** WebKit reads the same
  file and may disagree with us about what counts as an action. We made ourselves
  authoritative for *drawing* and left the engine authoritative for *behaviour*,
  which is the opposite of the arrangement ADR-0028 made for match patterns.
- **Schema 11.** A session written by this version is read by an older build
  without loss, but the older build ignores the row entirely and shows nothing.

**What we get:**

- 1Password can be clicked, which was the whole point.
- Not one pixel of page is spent, in either sidebar state.
- A keyboard path where Chrome has none.
- Which buttons are on show, and in what order, is testable without opening a
  window — and it is the same list in the shell and in the keymap by
  construction rather than by two people remembering.

## How this regresses

**"The row moved into a toolbar."** Somebody needs the buttons visible with the
sidebar open *and* somewhere more prominent, and adds them over the page. Nothing
here goes red — `browserViewGrowsNoToolbar` only watches `BrowserView` — and the
screen looks *more* complete, which ADR-0010 already names as the reason this
class of change survives review. The defence is that sentence and this one.

**"⇧⌘3 opens the wrong extension."** The shell starts filtering the row —
dropping one that will not load, hiding one whose icon is missing — while the
chords keep counting the core's list. Every button after the dropped one presses
its neighbour. `an_extension_with_no_button_is_never_on_the_row` and
`an_extension_that_is_not_running_is_not_on_the_row` are what hold the two lists
together, by making the core's answer the only answer.

**"The extension I hid keeps coming back."** `ExtensionPin` is simplified to a
list of pinned ids because the `pinned: false` rows look like dead weight. Then
absence means "not pinned", adoption runs at the next launch, and the button is
back — once a day, forever, with nothing to blame.
`adopting_never_undoes_a_deliberate_unpinning` and
`an_extension_deliberately_unpinned_stays_unpinned_across_a_relaunch` are the
two halves of that fence.

**"The order shuffles."** `ORDER BY position` is dropped from the load because
the rows "come back in order anyway", or `decide` starts appending instead of
keeping an extension's place. Both silently re-point every chord.
`the_order_of_the_extension_row_survives_a_relaunch` covers the first and
`hiding_one_and_showing_it_again_leaves_it_where_it_was` the second.

**"The badge stopped moving."** Somebody caches the action, or the icon, "to
avoid asking WebKit on every draw". The count freezes at whatever it was when the
button was built, and it looks completely fine. `perTabStateFollowsTheTab` asserts
that two tabs give two actions, which is what a cache cannot do.

**"One extension broke the sidebar."** An icon is drawn at its own size instead of
inside the fixed box, and a package with a 512pt icon decides how tall the
sidebar's controls are. `aMalformedIconDoesNotTakeTheRowDown` covers the missing
and unusable cases; **it does not cover this one**, because it needs a rendered
view to see a layout, and that is honest debt rather than coverage.

**And the one no test catches:** the icon getting a treatment. Somebody
desaturates the row so it "looks calmer", or masks every icon to a rounded square
so they "match". It photographs beautifully and it destroys the only thing an
extension icon does, which is to be recognised in a fifth of a second.

## When to revisit

- **If the bottom of the sidebar needs a fourth strip.** Three conditional bands
  under the tab list is already the limit; the answer at four is probably one
  band that changes contents, not a fourth.
- **If somebody wants to reorder the row.** It is a drag, the order is already
  core state and already persisted, and ADR-0041 has the pattern — preview in the
  shell, order decided in the core.
- **When Apple exposes the badge colour a manifest asks for.** Then ours becomes
  a substitution rather than the only available answer, and honouring theirs is
  probably right.
- **If `hasUnreadBadgeText` is wanted.** WebKit maintains it precisely for
  extensions that are hidden behind something, which is what an unpinned
  extension is. Saying "something is waiting in an extension you cannot see"
  would be strictly more honest than the silence there is now — and it is a new
  claim on screen, so it is a decision rather than a detail.
- **When a Linux host is attempted.** The pins, the order and `has_action` port
  unchanged; `WKWebExtensionAction` does not, and neither does `WindowChrome`,
  which exists because macOS puts the traffic lights in the window.
