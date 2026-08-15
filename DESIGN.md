# The design system

`CLAUDE.md` says why design matters here and what the bar is. It does not say
which spacing to use, how long a transition lasts, or what a screen shows when
it has nothing to show. That is this file.

Two things to know before reading it:

- **This describes what is in the code today.** Where something is an intention
  rather than a line of Swift, it is marked as one. Everything that is not
  marked is in `apple/Sources/Zer0Shell/`.
- **It was written by reading code, not by looking at screens.** Where a claim
  would need eyes to make, it says what the code does and stops there. Nothing
  below asserts how anything looks rendered.

The whole vocabulary lives in one file: `apple/Sources/Zer0Shell/DesignSystem.swift`.
If a number is not in there, it is either a genuinely local dimension (see
[Local metrics](#local-metrics-the-honest-exception)) or it is debt (see
[Debt](#12-debt-what-the-views-do-that-the-system-does-not-say)).

---

## 1. Where a decision lives

The architectural rule from `CLAUDE.md` — the core decides, the shell renders —
is also the design rule, and it is the one that settles arguments. Restated for
this file:

> **If two platforms can disagree, it is appearance and stays in the shell.
> If they cannot, it is behaviour and goes to the core.** (ADR-0002)

That is why behaviour has tests and appearance does not. `CLAUDE.md`: *tests
cover behaviour, not pixels — but UX behaviour, focus, order, selection, **is**
behaviour and it gets a test.*

The corollary is the reason this file exists, and ADR-0041 states it about the
sidebar drag:

> *"What has no lock: everything about how it **feels**. That the insertion line
> is a line and not a highlight, that the lifted row follows the pointer, that
> the space chip lights, that Esc cancels, that the edge scrolls. Those are
> appearance and gesture, they are tested by looking, and every one of them can
> be deleted without a single test going red."*

The ADRs lock behaviour: every one names the test that goes red if it is undone,
`./scripts/adr-check.sh` resolves them on every run, and the ones that cannot be
locked print as a debt count so *"a number you see every day gets paid down."*
Appearance has no such mechanism. This file is the only place it is written
down.

**The shell owns:** spacing, radius, material, shadow, animation curve and
duration, icon choice, label text and copy, how long a notice lingers on screen,
which of two facts gets more weight, and geometry — including drag geometry
(`TabDrop.slot` turns a pointer position into a target).

**The core owns:** command-bar ranking, the keymap, tab lifecycle, routing,
what the order becomes after a drop, whether a download has a fraction at all,
and the wording of anything a person consents to.

### The ambiguous cases, resolved

These are the ones worth writing down, because each was decided against the
obvious reading.

| Case | Where it lives | Why |
|---|---|---|
| **The drag** | Preview in the shell, order in the core | `TabDrag.swift`: *"Preview, all of it. The order it implies is never applied here; on release the slot is handed to the core and the answer is rendered."* The insertion line, the lifted card, the autoscroll are look. Where the tab ends up is behaviour, and ADR-0041 locks it. |
| **Whether a progress bar can fill** | Core | `Download::fraction()` in `crates/zer0-core/src/downloads.rs` returns `Option<f64>` and returns `None` for a missing total, a zero total, or a total smaller than what already arrived. The shell only picks which of two `ProgressView`s to draw. Two platforms must not disagree about whether a number is knowable. |
| **What a permission costs you** | Core | `ExtensionConsentSheet.swift`: *"The words on every row come from the core. What is drawn here is order, weight and colour; what is said is behaviour, and two platforms must not disagree about what `<all_urls>` costs you."* |
| **Menu and tooltip labels** | Shell | `Shortcuts.swift`: *"Kept here rather than in the core because it is copy, and copy gets localised per platform."* The chord next to the label is read live from the core's keymap. |
| **How long the download shelf stays** | Shell | `DownloadsView.swift`: *"how long a notice stays is a look, not a behaviour, so it does not belong in the core."* Hence `Duration.linger`. |
| **The clock** | Shell | `ExtensionConsentSheet.swift`: *"The clock belongs to the shell: the core has to stay deterministic."* |
| **A tab's display title** | Shell | `Sidebar.swift`: *"Presentation only, which is why it lives on this side. Anything that changes behaviour belongs in the reducer."* |
| **Sidebar visibility** | Shell | ADR-0014, locked by `ShortcutTests.swift::hiding and showing round-trips through the split view's visibility`. A split view is an Apple concept; the Linux shell will not have one. |
| **Which error screen you see** | Core | `NavigationErrorKind` is a core enum. The host only translates `NSURLErrorDomain -1009` → `offline` — *"the number belongs to the platform and the meaning does not."* The icon, the title and the sentence are the shell's. |
| **Whether what you typed is a URL or a search** | Core | The shell sends raw text; the core resolves it. |
| **What a downloaded file is named** | Core | ADR-0027: *"naming is behaviour, not appearance."* `report-2.pdf` rather than an overwrite, the 240-byte cap, the refusal after 999 collisions — all in `crates/zer0-core/src/downloads.rs`, and the save-panel path goes through the same two functions. |
| **What Enter means** | Core | ADR-0019: `CommandBarIntent` is a core type and `accept(browser, intent, suggestion) -> Action` is a core function. *"The shell carries the intent and hands it back; it does not interpret it."* |

Two things the core deliberately does **not** own, because it has to stay
deterministic: **the clock** (`Action::Tick { now_ms }`, and the consent sheet
stamping its own decision) and **randomness** (`CreateSpace { data_store_id }`).

---

## 2. The tokens

Every value below is from `DesignSystem.swift`. The criterion column is the
part that matters: a token without a criterion is a magic number nobody knows
when to reach for.

### Space — a 4pt rhythm

> *"Everything is a multiple, so nothing lands half a pixel off from everything
> else."*

| Token | Value | What it is for, as the code uses it |
|---|---|---|
| `hair` | 4 | Vertical padding inside a row; the gap between a label and the thing it labels; the drag gesture's minimum distance; the dash length in a dashed border. The smallest gap the system names. |
| `tight` | 8 | Gap between a badge and a title; horizontal padding inside a sidebar row or a chip; the gap between two buttons in a group. |
| `snug` | 12 | Gap between the parts of a composed row (icon / text block / action); padding on a compact card row; horizontal padding on the find bar and the window strip. |
| `regular` | 16 | The default padding of a panel — the session warning, the download shelf card, the settings group, the command-bar field. Also the standard gap between a label column and its control. |
| `loose` | 24 | Gap between the major blocks of a pane; padding of a settings detail column and of the consent sheet's sections; the offset that holds the lifted drag card clear of the pointer. |
| `section` | 32 | Padding around an `EmptyState`; the gap between top-level settings groups; the autoscroll trigger band at the edge of the sidebar list. |
| `line` | 2 | **The one value deliberately off the rhythm.** The gap between the two lines of a single label — a title and the line that qualifies it. Those two lines are one thing, and at `hair` they separate into two stacked rows. Added because four values (1, 2, 3 and `hair / 2`) were doing this one job. |

Three tokens do double duty as sizes rather than gaps, deliberately and
consistently: `Space.regular` (16) is the width of the trailing control column
in a sidebar row so the spinner, the mute button and the close button all sit
on the same vertical; `Space.loose` (24) is the height of a `TabDropWell` and
the size of the new-space button's hit area.

### Text — a scale, not a size list

> *"Built on text styles rather than fixed point sizes, so the whole UI follows
> the system's text size instead of staying at 11pt for someone who cannot read
> 11pt."*

| Token | Built on | Where |
|---|---|---|
| `row` | `.subheadline` | Sidebar rows, command-bar result titles, download filenames. The bulk of the UI. |
| `label` | `.caption` | Secondary lines, metadata, counts, status under a filename. |
| `micro` | `.caption2` | The smallest thing the project is willing to print: sidebar group headings, keyboard hints. The monospaced sites it used to cover are `mono` now. |
| `sectionTitle` | `.caption` semibold | The uppercase, letter-spaced heading over a group of settings rows. |
| `commandInput` | `.title3` | The command bar's own text, and the headline of its empty state — *"Same scale as the input above it: the empty state belongs to the palette rather than looking pasted into it."* |
| `detail` | `.callout` | The descriptive line under a label or a title: a sentence rather than a fragment. One step under body, which is what keeps a settings screen from reading as a wall of equally weighted prose. |
| `rowTitle` | `.body` medium | **The name of a thing in a list**: a suggestion, a tab, a download, an extension, a history entry, a settings row. The line you scan for. |
| `emptyTitle` | `.title2` semibold | **The headline of an empty state**, which is a product screen and for most people on most panes the only screen they ever see (§9). |
| `display` | `.largeTitle` bold | **The product saying its own name.** The About panel, under the mark, and nowhere else. |
| `greetingSize` → `.greetingType()` | 40pt serif, `@ScaledMetric(relativeTo: .largeTitle)` | **The line that opens an empty conversation** (ADR-0070). The chat page with nothing in it, and nowhere else. The one size in the scale that is a number, because macOS compresses every text style into 10–26pt and a hero line needs something the scale does not have — at `.largeTitle` it took twelve per cent of the width of the window this browser is used in (ADR-0090). It is a modifier rather than a `Font` because `@ScaledMetric` only exists inside a view, and it is **not** the raw point size §12 refuses: it still follows the system's text size. |
| `mono` | `.caption2` monospaced | **A string that is a value rather than prose**: a permission key, a host pattern, a URL shown as a URL, a version number. |

**Two things are display-sized, and one of them is the only serif in the
shell.** `display`'s own comment used to say it was the only thing above
`.title2`; that stopped being true when `greeting` landed and is corrected in
the file. The criterion did not move: a display size is a claim on attention,
and there are exactly two screens in this browser where nothing else wants it —
the About panel, and a conversation with nothing in it yet.

The serif is the part worth arguing with. Every other word in this shell is
interface — a label on a control, a name in a list — and SF is what interface is
set in. A conversation is not interface, it is writing, and the greeting is the
page saying so before anything has been typed. It is in tension with §7's
commitment to the mark being "cold, geometric", deliberately: the mark is the
product, the greeting is a page inviting prose, and they are allowed to be
different materials.

`paneTitle` (`.title2` semibold) was here and is gone. It had no consumer by
decision — a pane does not repeat what the sidebar says (§5) — and it sat at
exactly the value `emptyTitle` now needs, which is two tokens for one size and
the first half of a drift. The debt it was carrying is paid by deleting it.

**Why `rowTitle` is `.body` and not `row`.** On macOS the whole scale is
compressed into 10–13pt: `.subheadline` is 11 and `.caption` is 10. A row title
in `row` over a detail line in `label` was **one point apart**, so weight was
doing the entire job of separating them and losing. Body over caption is 13
against 10 — a step you see before you read — and the weight goes back to being
the second lever. `row` keeps its meaning and its consumers; it is the bulk of
the UI, and a title in a list is not the bulk of anything.

**Numbers that change in place take `.monospacedDigit()`, not `mono`.** A byte
count ticking up in proportional digits shifts the whole line on every tick,
which reads as the row twitching rather than as progress. That is a modifier on
whatever token the line already wears, so the label beside the number does not
turn into code.

Emphasis is applied on top of a token, not by picking a different one:
`Design.Text.row.weight(.medium)`, `Design.Text.micro.weight(.semibold)`.

**One place the scale cannot reach**, named rather than hidden.
`Design.Text.FieldSize` holds two point sizes — `command` (20) and `strip`
(13) — because `CommandBarField` is an `NSTextField` and AppKit wants a number
where everything else takes a `Font`. Neither follows the system text size;
that is the cost of dropping to AppKit to win the focus fight (ADR-0013), and
it is written here rather than left as two literals in two files.

**Uppercase headings come with their letter-spacing.**
`.sectionHeading()` applies `sectionTitle`, `.textCase(.uppercase)` and
`.tracking(0.6)` together, because uppercase closes letters up and the tracking
is what keeps the word legible at caption size. Applied by hand at four sites
it had already drifted to 0.5 at one of them. Colour is deliberately left out:
the consent sheet paints its headings by risk tier.

### Glyph — pictures, on purpose outside the type scale

> *"A mark is a picture, and a picture does not need to grow when someone turns
> their text size up."*

| Token | Value | What |
|---|---|---|
| `icon` | 34 | The SF Symbol at the head of an empty state (`EmptyStateSymbol`). |
| `mark` | 72 | The zer0 mark, on the two screens where it *is* the screen. *"Well clear of the floor ADR-0040 settles at 32 rendered pixels."* |
| `control` | 13 | An SF Symbol that is the whole of a control's label, in a strip sized for the window's own controls. Sized to the strip rather than to a line of text, because there is no text beside it to match. One use: `WindowChrome`'s sidebar toggle. |

### Stroke — line weights, also outside the rhythm

> *"A stroke is not a gap, and a 4pt rule would read as a bar."*

| Token | Value | What |
|---|---|---|
| `hairline` | 1 | *"A border that should be seen and not noticed."* The lifted drag card's edge, the offered-space chip's dashed outline, the critical-permission group's border. |
| `insertion` | 2 | *"The line a drag draws where the row is about to land. Heavier than a border because it is the whole answer to 'where does this go'."* Also the target space chip's solid border, which is the same answer in another shape. |

### Radius

| Token | Value | Where the code puts it |
|---|---|---|
| `small` | 6 | Row-scale things: a sidebar row's selected background, the new-tab button, a keyboard-hint key cap, a drop well, an expanded permissions block. |
| `medium` | 10 | Panel-scale things: the find bar, the session warning, a settings group, a list of rows treated as one surface. |
| `large` | 16 | The two floating panels that sit over the page: the command bar and the download shelf card. |

Radius tracks the scale of the thing, not its importance. Four uses of `large`,
all of them a panel over content.

### Duration and curves

| Token | Value | Criterion, in the file's own words |
|---|---|---|
| `quick` | 0.18 | *"Fast enough to feel instant, slow enough to be seen."* Consumed by `subtle`. |
| `linger` | 5 | *"How long a notice about something that already happened stays before it retreats on its own. Long enough to read twice, short enough that it is gone before it becomes furniture."* Added for the downloads shelf; used by it and nothing else. |
| `entrance` | `spring(response: 0.34, dampingFraction: 0.82)` | *"Panels arriving on screen come from somewhere, with a little overshoot so they feel physical rather than switched on."* |
| `subtle` | `easeOut(duration: quick)` | Everything that is not an arrival. |

Both curves are `fileprivate`. They are reached through `Design.Curve` and
`Design.Motion`, which resolve them against Reduce Motion (ADR-0046) — a curve
written out at a call site is a curve that never asked, so it no longer
compiles. §3 has the three spellings.

There was a third duration, `settle` (0.28), declared and referenced nowhere.
It was deleted rather than given a use: the shell has exactly two curves on
purpose (§3), and a spare duration with no consumer is the first half of an
inconsistency — the next person needing "a bit slower" reaches for it without
knowing what it means.

### Surface — the recessed fill

> *"`.quaternary` on its own is heavier than this UI wants."*

| Token | Value | Criterion |
|---|---|---|
| `recessed` | `Palette.recessed` | A group of rows on the window's own background: a settings section, a list treated as one surface, the capsule around a failed address. |
| `recessedInner` | `Palette.recessedInner` | The second level of recess, for a group nested inside a view that already has one at full strength: an extension row's expanded permissions. Two fills at full strength stack into a visible step instead of reading as one surface set back from another. |

Both were `.quaternary.opacity(0.4)` and `0.3` — **derived** values, and what
they derived from moved when the palette landed. With the ink ladder set at the
root, `.quaternary` stopped resolving off the system's near-neutral label colour
and started resolving off `ink`, a saturated navy: every settings group on every
pane went two shades heavier, and no token recorded it. They are stated colours
now (§7). The 0.4/0.3 relationship survives in the swatches themselves.

The 0.3 was already in the code twice with nothing saying why. It was kept
rather than flattened for the site that is genuinely *nested*: rendered against
a 0.4 block the difference is small but real, and the lighter one reads as
subordinate where the full-strength one competes with the group around it.

**It has one site now, not two.** The consent sheet's unreadable-hosts note used
to take it, and that was the wrong tool: the note is not nested inside a group,
it is *ranked after* the groups, and a step of 0.1 in a translucent fill is not
a rank anyone can see. Side by side with the real groups it read as a fifth
group whose heading had gone missing. It is no longer a card at all — a rule and
a note, the same shape `SettingSection` gives a footnote. **Recess is for depth,
not for rank.** A thing that is subordinate rather than inside something needs a
different shape, not a lighter fill.

### Elevation — depth as a scale

> *"A shadow is earned by distance, not by importance."*

Three steps, because the shell has exactly three distances. Each darkens as it
spreads: further out means a wider and heavier cast. The radii are their own
numbers rather than borrowed spacing tokens — a shadow radius is a blur, not a
gap.

| Token | Recipe | Who takes it |
|---|---|---|
| `resting` | black 0.18, radius 12, y 4 | A strip resting on the page: the find bar, the install banner. It has left the surface, but only just. |
| `floating` | black 0.22, radius 18, y 8 | A panel over the page: the download shelf, the session warning. A bigger surface needs a bigger cast to separate from a page that can be any colour. |
| `overlay` | black 0.28, radius 30, y 12 | A panel over a window dimmed for it: the command bar, and nothing else. |

`.elevation(_:)` is the only way a shadow is spelled. A `.shadow(...)` written
out at a call site is, by construction, a depth that is not on the scale.

Two deliberate exceptions:

- **`SiteBadge`** — its own hue at 0.35, radius 2, y 1. Not a black shadow for
  a panel: it is the badge's colour bled a point past its edge, which is what
  stops a saturated 16pt square looking like a sticker dropped on the row. Any
  of the three steps would swamp something that small.
- **The lifted drag row** (`Sidebar`) — still at black 0.3, radius 12, y 4, and
  not converted; see [Debt](#12-debt-what-the-views-do-that-the-system-does-not-say).

### Pane

| Token | Value | Criterion |
|---|---|---|
| `emptyStateMinHeight` | 220 | The floor an empty state gets when it sits inside a scrolling pane instead of filling a window. Tall enough that the glyph, the two lines and the action read as a screen rather than a squeezed notice; short enough that the pane's own controls above it stay in view. |

### Local metrics: the honest exception

`CommandBar` declares a private `Metrics` enum and says why:

> *"Sizes that belong to this one panel rather than to the whole UI, so they
> are named here instead of pretending to be design tokens."*

`width: 620` (*"wide enough for a real URL to fit on one line"*),
`fieldHeight: 28`, `listMaxHeight: 320` (*"the list stops before the palette
covers the page it floats over"*), `iconColumn: 18` (*"icons share a column so
every title starts on the same vertical"*), `shadow: 30` / `shadowOffset: 12`
(*"deeper than the find bar's: this one sits above a dimmed window"*).

`WindowChrome` does the same for `height: 38`, `trafficLightWidth: 78` and
`titleWidth: 340`. `WindowChrome.height` is `static` and read by `Sidebar` and
`BrowserView`, because the page top must not jump when the sidebar comes and
goes.

**This is the pattern to copy**, and it now covers every panel outside the two
files left to their owners. A dimension that belongs to one panel does not
become a token; it becomes a named constant next to the panel, with the
sentence that justifies it:

| Panel | `Metrics` holds |
|---|---|
| `CommandBar` | `width` 620 · `fieldHeight` 28 · `listMaxHeight` 320 · `iconColumn` 18 |
| `WindowChrome` | `height` 38 · `trafficLightWidth` 78 · `titleWidth` 340 · `actionsWidth` 164 |
| `FindBar` | `fieldWidth` 200 · `fieldHeight` 20 · `dividerHeight` 16 · `edge` 0.5 |
| `InstallBanner` | `width` 460 · `iconColumn` 20 · `edge` 0.5 |
| `ExtensionConsentSheet` | `width` 480 · `maxHeight` 620 · `mark` 26 · `markColumn` 32 · `riskColumn` 20 · `fade` 28 |
| `PageDialogSheet` | `width` 420 · `mark` 30 · `markColumn` 36 · `fieldHeight` 24 — the first three deliberately identical to `SitePermissionSheet`'s, because the two are the same object: a panel a *page* summoned. Two widths would read as two products (ADR-0089). |
| `SiteWords` | `maxHeight` 200 · `fade` 20 — a ceiling on how much of a page's own text is drawn before it scrolls, and how far it dissolves at an edge it carries on past. Most `confirm()` messages are one line; the ones that are twenty must not push the buttons off the screen, and the last visible line must not be cut through its middle. |
| `PageStack` (the split) | `gutter` `Space.regular` · `gripWidth` `Space.hair` · `gripLength` 44 · `halo` [0.42, 0.26, 0.14, 0.06] |
| `DownloadShelf` | `width` 320 |
| `DownloadsSettings` | `progressWidth` 260 |
| `ExtensionsView` | `iconColumn` 22 |
| `ExtensionActionBar` | `target` `Space.loose` · `icon` 18 · `badgeWidth` 22 · `absurdIcon` 1024 |
| `AboutView` | `width` 340 |
| `ChatPage` | `composerMin` 34 · `composerMax` 96 · `action` 28 · `actionGlyph` 13 · `leading` 4 · file-scope `chatColumn` 450 |
| `MessageRow` | `askInset` 96 |
| `ChatProse` | `markerColumn` 18 · `markerGap` `Space.tight` · `step` 26 · `deepest` 4 · `majorHeading` `.title3` semibold · `minorHeading` `.headline` |
| `SettingsView` (file scope: one window, many panes) | `windowWidth` 880 · `windowHeight` 580 · `sectionListWidth` 200 · `contentWidth` 640 · `menu` 180 · `segmented` 220 · `field` 260 · `counter` 30 · `ruleKind` 150 · `ruleTarget` 130 |

What is *not* acceptable is the same dimension as a bare literal at the point
of use.

**`ChatProse` is the first entry to hold type as well as dimensions**, and it is
the same argument one level up. A model's reply has headings and the scale has
no token for one: `rowTitle` is a point away from the body it would sit over,
and `emptyTitle` is exactly the size an empty state uses — a second token at
that value is the drift `paneTitle` was deleted for (§2). So the two heading
sizes are named beside the one view that sets them, built on text styles like
the rest of the scale, with the reason in the file. Two steps rather than six is
itself a decision, and it is argued in ADR-0071: a reply is a passage inside a
page, and models reach for `##` and `###` interchangeably.

---

## 3. Motion

Two curves, and the choice between them is not stylistic.

### The three spellings, and why there are only three

Outside `DesignSystem.swift` the curves cannot be named. They are `fileprivate`,
and everything reaches them through one of:

```swift
.motion(.entrance, value: something)   // declaring a change
.arrives(from: .top)                   // a transition that carries a direction
@Curves private var motion             // for withAnimation(motion.entrance)
```

All three read `\.accessibilityReduceMotion` on the way through. That is the
enforcement mechanism for ADR-0046: the rule cannot be forgotten by omission,
only reverted on purpose, because a bare `.animation(...)` no longer compiles.

`.summoned()` and `.arrivesInList()` are the same machinery with a named
transition instead of an edge — the command bar's arrival and a row's place in
a list are each used in exactly one place, and naming them is what keeps the
recipe out of the call site.

**`entrance` — a spring with overshoot. Something arrived.** Used where a thing
that was not on screen is now on screen, or where a thing changed place:

- the install banner appearing at the bottom, the find bar at the top right,
  the command bar overlay and its scrim, the session warning, the sidebar
  coming and going (`BrowserView`);
- the download shelf card entering and leaving (`DownloadsView`);
- the rows settling after a drop — *"animated here rather than on the list, so
  the rows settle into the order the core just handed back instead of appearing
  in it"* (`Sidebar`);
- the tab list arriving from the side when a space changes, and the marker
  under the current tab travelling between rows (`Sidebar`);
- a tab row growing into the gap the list opens for it, and collapsing back
  into the gap it leaves;
- a space chip scaling to 1.08 when it becomes the drop target — *"a space is a
  bigger destination than a row, so it answers bigger"*;
- the install banner's phase changing (offering → installing → deciding →
  installed / failed), because each phase is a new thing arriving in the same
  place.

**`subtle` — a short ease-out. Something adjusted.** Used where the thing is
already there and only its state moved:

- the command-bar panel growing and shrinking with the result count — *"gliding
  shows it is the same panel rather than a new one being swapped in"*;
- the command bar's highlight travelling between rows as you arrow;
- the find bar changing width as the status label appears — *"gliding keeps it
  from twitching on every keystroke"*;
- the insertion line moving between slots mid-drag, and the drag state clearing;
- hover on a sidebar row, a space chip and the new-tab button, and the press
  dip every `.pressable` button gets;
- the page loading bar fading in and out;
- an extension row expanding its permissions; the consent sheet's consequence
  sentence changing as switches change;
- the navigation error screen fading in — *"a page failing is already jarring;
  the explanation should fade in rather than snap over whatever was there."*

**The transitions carry the direction.** A transition says where something came
from: `.move(edge: .top)` for the find bar, the session warning and the window
strip; `.move(edge: .bottom)` for the install banner; `.move(edge: .trailing)`
for the download shelf, which lives in the bottom-right corner; the direction
the chip row was travelled in for the sidebar's tab list; plain `.opacity` for
the command bar's dimming scrim, the insertion line and the lifted card, which
do not come from anywhere in particular.

The one custom shape is `summoned`, for the command bar: it comes in from
`Space.snug` above where it lands, at 97%, anchored to its own top. Not an edge,
because it is not pushed in from one — it comes forward out of the window, and
the scrim dims on the same curve so the two read as one event.

**The rule.** Motion that does not answer "where did that come from" or "what
just changed" is noise and does not go in. There is no decorative animation in
the shell today: every animation in `apple/Sources/Zer0Shell/` is bound to a
specific `value:`, and every one of them is `.entrance` or `.subtle`. No view
constructs its own curve, and none of them can.

### Reduce Motion

Decided in ADR-0046, and stated once so it does not have to be re-decided per
site: **Reduce Motion takes away travel and overshoot, never feedback.**

- `entrance` loses its spring and becomes `subtle`. A panel still arrives, over
  the same 180ms; it stops bouncing.
- `subtle` does not change at all. Someone who asked for less movement did not
  ask for a less responsive interface.
- A transition loses its edge and keeps its fade — it arrives where it will
  live rather than flying there.
- A press keeps its dimming and loses its 3% squeeze.

### What is claimed here has been looked at

Two sentences in this section used to be false. The command bar's overlay
carried `.transition(.opacity)` and nothing bound an animation to
`commandBarOpen`, so it had never faded; the panel "gliding" with the result
count could not glide, because the list claimed a fixed 320 points whether it
held two rows or eight. The session warning and the loading bar were the same
defect: a transition written, and no animation to run it.

The rule that follows from that, and from the `SplitView` doc comment recording
three formulations that moved nothing: **a claim about motion in this file is
worth what the frames are worth.** `apple/Tests/Zer0ShellTests/ZZMotionShots.swift`
drives the real views with the real curve and reads the position of the thing
across every layout pass — including with Reduce Motion forced on. It reads
geometry rather than pixels for a reason worth knowing: `cacheDisplay` on an
`NSHostingView` draws the *model* layer, so a view part way through a
transform-based transition rasterises where it is going to be, and five probes
of a working animation all photographed as "never moved". Opt-in behind
`ZER0_SHOT=1`, per `check.sh`.

**Timed retreat.** One thing in the UI removes itself: the download shelf, after
`Duration.linger` with nothing running. The rule around it is stated in
`DownloadsView`:

> *"A failure does not go away by itself. There is something to do about it, and
> a notice that removes itself is one you can miss entirely."*

A download restored from a previous session never lingers either — *"it is
history, not news."*

---

## 4. Materials and depth

The project uses system materials rather than fills, because a grey rectangle
does not track light and dark, does not vibrate against what is behind it, and
does not look like the platform.

| Material | Where | Why that one |
|---|---|---|
| `.thinMaterial` | The sidebar (`Sidebar`) | It is a large permanent surface with the page next to it. |
| `.regularMaterial` | Every floating panel: command bar, find bar, download shelf card, install banner, session warning, consent sheet, and the lifted row during a drag | These sit over content and have to separate from it. |
| `.bar` | `WindowChrome` | It is a window strip standing in for a title bar, and `.bar` is what the system uses for one. |
| `.quaternary` | Grouped list backgrounds, keyboard-hint key caps, panel borders | The system's own "recessed surface" fill. |
| `.background` | The two full-screen states (`NothingOpenScreen`, `NavigationErrorScreen`) | These replace the page rather than float over it, so they are opaque. |

**Selection and target use system semantics too:** `.selection` for the active
tab row and the active space chip (at `.opacity(0.85)`), `.tint` for a drop
target, `.primary.opacity(0.06)` for hover.

### When a shadow is earned

A shadow appears in the code only on something that has left the surface it
belongs to:

- the command bar (over a dimmed window),
- the find bar, the install banner, the download shelf, the session warning
  (over the page),
- the lifted row during a drag — *"the thing being moved should look like it
  left the surface, which is what makes the gap it left behind read as a gap"*,
- the insertion line, which carries a tinted glow rather than a black shadow
  because it is a light source, not an object,
- the `SiteBadge`, which shadows in its own colour at radius 2.

Nothing else in the shell has a shadow. A settings group, a list row, a chip and
the sidebar do not: they have not left anything.

The depths are a three-step scale, `Design.Elevation`, applied through
`.elevation(_:)` — see [Elevation](#elevation--depth-as-a-scale) for the steps,
the two documented exceptions, and the one site still off the scale.

### What is allowed to sit on the page

ADR-0010 is a spending limit, not a style. Mainstream browsers reserve 60–100pt
at the top of every window forever; *"the cost is permanent; the value is
occasional."* zer0 reclaims 38 to 90pt on every page by refusing it.

**Exactly three things have a licence to take space above or over the page:**

1. **`WindowChrome`** — 38pt, and only when the sidebar is hidden. It holds the
   traffic lights, is where you grab the window since there is no title bar, and
   carries the sidebar's own controls while the sidebar is away — the toggle, and
   the pinned extension buttons (ADR-0068). The rule that bounds it: **it may hold
   a control only if the sidebar holds that same control**, which is what keeps
   the favicon, the blocking badge and the padlock out. Sidebar open, the sidebar
   is that place and the strip is gone.
2. **The loading bar** — 2pt of linear progress, only while loading. *"The only
   thing allowed to sit on top of a page, and only while loading."*
3. **Ephemeral overlays** — find bar, command bar, install banner, session
   warning, download shelf. All conditional, all with a way out.

The invariant behind it, which no test enforces: **with the sidebar visible, the
sum of chrome above the content is zero.** ADR-0010 also names how it goes
wrong — *"the symptom is the screen getting fuller, and a fuller screen looks
'more complete' until someone measures it. The path from '2pt conditional' to
'24pt permanent' is always incremental."*

**The test for anything new that wants to be permanent:** does it pay for itself
on *every* page? The sidebar is the one deliberate exception, and ADR-0014
justifies it precisely: *the sidebar does something the person does not know
(which tabs exist), and the address bar does not.*

---

## 5. Hierarchy

Three levers, applied in this order.

**Colour first, and it is opacity of a semantic role rather than a palette.**
The standard ladder in this codebase is `.primary` → `.secondary` →
`.tertiary`, and the choice is argued each time it matters:

- A sidebar row is `.primary` when active and `.secondary` when not. So is a
  space chip: *"Switching space is the largest move in the sidebar, so it cannot
  be the faintest thing in it."*
- The About window's licence line is deliberately `.secondary` rather than
  `.tertiary`: *"this is the one thing this window says that the menu bar does
  not, and it should not be the faintest text on screen."*
- The mark on the empty browser screen is `.tertiary` on purpose: *"Large,
  quiet and low-contrast on purpose: the line under it is the part with a job
  to do."*
- The tab title in `WindowChrome` is `.caption` `.tertiary`: *"The one thing
  worth saying up here, in the quietest way that still reads."*

**Weight second, and sparingly.** The consent sheet is the clearest statement of
the rule: only `critical` rows get `.semibold`, `high` gets `.medium`, and
everything else is plain — *"Only the worst tier gets weight. If every row
shouted, none would."* Elsewhere weight marks the one primary thing in a block:
a download filename against its status line, the new-tab button's label, a
group heading.

**Size last.** Size separates an empty state's headline from its message. It is
not used to rank items within a list; that is what weight and colour are for.

**A settings pane does not repeat its own name.** The sidebar row says
"Shortcuts" and stays on screen the whole time; a `title2` saying it again two
inches away is chrome that does not pay for itself, and it was on five of the
nine panes and absent from four. So none of them carries one. A pane that has
something to explain opens with the explanation — `Design.Text.detail`,
`.secondary`, the part the sidebar cannot say — and a pane made of groups opens
with its first `sectionHeading()`. `Design.Text.paneTitle` is now without a
consumer; see [Debt](#12-debt-what-the-views-do-that-the-system-does-not-say).

**One primary action per surface, and it answers Return.** The navigation error
screen's "Try Again" is `.borderedProminent` with `.keyboardShortcut(.defaultAction)`
— *"It is the only thing to do here, so return does it."* The browser's empty
screen gives it to "New Tab", for the same reason. The downloads list gives it
to the **newest failure only**: *"Only one thing can be the default action, and
it should be the thing you just watched go wrong."* The consent sheet gives it
to "Add Extension", with `.cancelAction` on "Don't Add".

**Prominence and Return are one decision, not two.** `.borderedProminent` used
to be unconditional on the downloads list's "Try Again", so three stopped
downloads drew three identical prominent buttons and exactly one of them
answered the key — with nothing on screen saying which. The style now follows
`isDefaultAction`: prominence *is* the promise that Return does this, and a
screen that makes it twice has broken it once.

**Destructive reads as destructive** — but the role alone does not always say
so. On macOS `role: .destructive` paints a **borderless** button red and a
**bordered** one nothing at all, so "Clear History…" arrived on the Privacy
pane looking exactly like the benign "Choose…" a group above it. The rule is
therefore in two halves:

- **Borderless: the role, unadorned.** `ExtensionsView` notes that adding a
  `.foregroundStyle` to a Remove button *"took the one signal that this button
  is not like the others."* **Unverified**: in an offscreen render the
  borderless destructive button came out grey like everything else, but so does
  every accent in that harness — the test process cannot become the active app.
  This one has to be checked in a running window.
- **Bordered: the role plus `.foregroundStyle(.red)`.** Rendered side by side
  in both themes, `role` alone and `role` + `.tint(.red)` are both
  indistinguishable from a plain button; only `.foregroundStyle` paints — a red
  label over a pale red fill. The role stays, because it is what VoiceOver and
  a second platform read; the colour is what makes it visible on this one.
  `SettingsView.DestructiveButton` is the only place this is spelled.

An ellipsis is a promise: *"Close Space…"* means something happens before
anything is destroyed. `DestructiveButton` appends it rather than trusting the
call site to remember, because the promise is the component's to keep.

---

## 6. Shared components

These exist so two near-identical screens cannot drift apart. Reach for them
before building a layout by hand.

| Component | File | Notes |
|---|---|---|
| `EmptyState` | `DesignSystem.swift` | Glyph, `emptyTitle` headline, `detail` message (capped at 320pt wide), action. Takes a `Glyph` view rather than a symbol name *"because one empty state — the browser with nothing open — is headed by the mark instead of an icon, and two near-identical empty-state layouts would drift apart within a month."* The action carries its own gap below the text block: it is the third rank on the screen, not the second line of the second. |
| `EmptyStateSymbol` | `DesignSystem.swift` | The usual glyph: an SF Symbol at `Glyph.icon`, `.light`, `.tertiary`. |
| `SettingRow` | `DesignSystem.swift` | `rowTitle` label + `detail` description on the left, control on the right. The description is *"what stops a settings screen being a wall of nouns you have to guess at"* — and the title carries the weight, because body over callout is one point and weight was doing the whole job. |
| `SettingSection` | `DesignSystem.swift` | Uppercase `sectionTitle` heading, a `Radius.medium` group of rows, optional footnote. The group is the width of the column, not of its contents: without that, a section holding only a radio group came out a third the width of the one beside it, whose `SettingRow` `Spacer` pushed it wide. |
| `SettingSwitch` | `DesignSystem.swift` | The control a settings row wears when the answer is yes or no. A bare `Toggle` on macOS is a **checkbox**, and an unlabelled checkbox pinned to the right margin is not a pattern this platform has — a checkbox carries its own label. It also all but vanishes unchecked: `#2f2f2f` on a `#2b2b2b` group in dark. Takes the label rather than inferring it, because `labelsHidden()` otherwise leaves VoiceOver with a switch for nothing. |
| `DestructiveButton` | `SettingsView.swift` | Local rather than shared: the pairing of red tint, ellipsis and confirmation, in the one file that had two of them disagreeing. See [Hierarchy](#5-hierarchy). |
| `CommandBarField` | `CommandBarField.swift` | An AppKit `NSTextField` that **takes** first responder and selects its contents, because `@FocusState` loses to the `WKWebView` underneath. Reused by the command bar, the find bar and the space-rename popover. |
| `SiteBadge` | `SiteBadge.swift` | See [Colour](#7-colour--b--fault-adr-0043). |
| `Zer0Mark` | `Zer0Mark.swift` | The mark as a `Shape`. See [The mark](#8-the-mark). |
| `TabInsertionLine`, `TabDropWell` | `TabDrag.swift` | The drag's two affordances. A line rather than a highlighted row, *"because a highlighted row leaves the person guessing between 'above this' and 'below this'."* |
| `DownloadProgressBar`, `UnknownTotalSpinner` | `DownloadsView.swift` | The two shapes a running download can wear, chosen by whether the core has a fraction to give. A bar when there is one; a spinner when there is not, because an indeterminate *bar* is the determinate one at another fill and asserts a scale nobody sent (ADR-0027). |
| `DownloadCopy` | `DownloadsView.swift` | Every sentence a download can say, in one place. |

---

## 7. Colour — B · Fault (ADR-0043)

**zer0 has a palette.** One saturated ultramarine on neutrals tinted to the
same temperature: *"the mark is a cut zero — cold, geometric — and the colour
commits to that."* It is stated once, as `Design.Palette` in `Palette.swift`,
and worn once, as `.zer0Palette()` at the root of each of the three windows.
`PaletteProposals.swift` stays as the record of the two that lost.

Every token is a `Swatch` — bytes, so a ratio can be recomputed — surfaced as
**one `Color` that resolves against the drawing appearance**. No view reads
`colorScheme` to pick a hex, which is what keeps the Theme setting honest.

| Token | Light | Dark | What it is |
|---|---|---|---|
| `background` | `#FAFAFC` | `#0E0F17` | The window's own background. |
| `chrome` | `#F0F0F6` | `#181925` | The sidebar's surface, under its material. New at adoption: until then no palette owned it. |
| `ink` / `inkSecondary` / `inkTertiary` | `#121327` / `#53556B` / `#83859A` | `#ECEDF5` / `#9EA1B5` / `#6E7186` | The `.primary` → `.secondary` → `.tertiary` ladder. The first two clear 4.5:1 everywhere they land; the third is a 3:1 level, and nothing that must be read is set in it. |
| `accent` | `#3B2FE0` | `#8E86FF` | `.tint`: focus, the drop target, prominent buttons, the mark. Violet where Safari and Chrome run cyan. |
| `selectedRow` | `#837AE0` | `#635BC9` | The selected sidebar row and the active space chip. **Derived, not picked**: 3:1 against `chrome` so the state is seen, 4.5:1 for `ink` on it so the label is read. |
| `companionRow` | `#C6C0F2` | `#4A448F` | The other half of a split. The luminance **midpoint** between `chrome` and `selectedRow` — *"plainly less of it"* as a number rather than an impression. |
| `recessed` / `recessedInner` | `#ECECF3` / `#E2E2EC` | `#1A1B27` / `#222432` | What `Design.Surface.recessed` draws. **Stated, not derived**: `.quaternary.opacity(0.4)` resolved off the ink once the ladder was set at the root, and every settings group went two shades heavier overnight. |
| `rule` | `#D7D7E0` | `#33354A` | The hairline a `Divider` wears, via `.hairline()`. Same reason, same day: a divider went from 1.15:1 to 2.7:1 against its own surface, and lists turned into stacked bars. Criterion: 1.15–1.6:1 — *"seen and not noticed."* |
| `warning` / `danger` / `success` | `#8F5600` / `#B92019` / `#1C7549` | `#E5A94D` / `#F0726A` / `#63C08D` | The three status claims, below. |

**`.selection` is not `.tint`.** It resolves to the *system* accent, so the
selected sidebar row — the most-looked-at accent surface in the product — was
painted whatever colour macOS was set to, and no palette could move it. Board
`design/palette/04-sidebar-light.png` shows all three proposals producing an
identical grey-blue row, which is the defect in one picture. `selectedRow` is
the answer, and its two floors are what make it a token rather than a taste.

**What a root `.foregroundStyle()` breaks on the way past.** Setting the ink
ladder at the root re-points every *derived* style with it, and two of those
were carrying weight nobody had chosen: `.quaternary`, which
`Design.Surface.recessed` was built on, and `Divider`, which takes its colour
from the ladder. Both got two shades heavier the day the palette landed. Both
are now stated in `Design.Palette` rather than derived — `recessed`,
`recessedInner`, `rule` — and `Divider().hairline()` is how a rule is spelled.
A hairline without it is whatever the ink happens to imply.

**A status colour comes from the palette or it does not exist.** `.orange`,
`.red` and `.green` were written as system hues at about a dozen sites, and a
system hue moves independently of everything else on screen — which for the
consent sheet, where the three are a *rank*, is a rank that lies.
`PaletteContrastTests::noViewSpellsAStatusColourForItself` scans the shell for
a view spelling one for itself. Two files are exempt and say why in their own
headers: `PaletteProposals` is the record, and `SiteBadge` is a function of a
hostname rather than a palette.

**The sidebar is painted, not blurred.** It was `.thinMaterial`, and a material
at the window's edge with nothing opaque behind it blurs the *wallpaper*: the
sidebar came out the same dark charcoal in the light board and the dark board,
because the photograph behind the window was dark. Two defects follow — the
Theme setting does not hold, and the palette cannot reach the largest piece of
chrome in the product.

Keeping the material and changing what it samples was tried first — an
`NSVisualEffectView` at `.withinWindow` over a chrome fill — and **measured, it
does not work**: the effect view paints its own achromatic backdrop over the
fill, rendering `#F3F3F3` / `#353535` against a palette asking for `#F0F0F6` /
`#181925`. So the sidebar is `Palette.chrome` and nothing else. The cost is
stated rather than dodged: it is flat where it used to be translucent, and what
separates it from the page is colour and an edge instead of depth.

Materials keep every place they still earn. The command bar, the download
shelf, the find bar, the install banner and the consent sheet all keep
`.regularMaterial`, because they float over a live page and blurring page
content is what a panel over a page is *for*. Only the surface at the window's
edge, which had nothing real to blur, gave one up. ADR-0043 argues it, and its
lock is a render and a sampled pixel — this decision has been got wrong twice
by reading APIs instead of looking.

Everything else still runs on system semantics, unchanged:

- roles: `.primary`, `.secondary`, `.tertiary`, `.quaternary`, `.selection`,
  `.background`;
- accent: **`.tint`, and only `.tint`.** The two spellings are not
  interchangeable: `.tint` is a `ShapeStyle` that resolves against the
  environment and honours a `.tint()` applied anywhere up the hierarchy;
  `Color.accentColor` reads the system setting and ignores it. Since whether
  zer0 gets an accent of its own is an open decision (below), the spelling that
  a single `.tint()` at the root can re-point is the one that keeps that
  decision cheap — so `.tint` is correct and `Color.accentColor` is not. Where
  a concrete value was structurally required, the property's type changed to
  `AnyShapeStyle` rather than the style changing to `Color`. One site remains,
  in a file left to another owner — see Debt;
- status, now from the palette rather than the platform:
  `Design.Palette.warning` for a warning that has not broken anything yet
  (session could not be read, extension not running, download failed),
  `.danger` for a hard negative (`notFound` in the find bar, `critical`
  permission tier, a destructive button), `.success` for a confirmed success
  (extension running).

**A status colour is a claim, so a tier with no claim to make does not get
one.** The consent sheet paints `critical` red and `high` orange because both
are measured costs. `unknown` was orange too — one alpha point apart in the
fill, which is no distance at all — and that put *"this reaches your bank"* and
*"we could not find out what this is"* in the same paint. They are different
kinds of statement: one is a ranked risk, the other is our ignorance, and a
shade of the warning ranks ignorance on a scale nobody measured it on
(ADR-0018). `unknown` is achromatic now, and says what it is by shape instead:

| Tier | Fill | Edge | Badge |
|---|---|---|---|
| `critical` | `.red` 0.08 | solid `.red` hairline | filled triangle |
| `high` | `.orange` 0.07 | none | filled circle |
| `unknown` | none | **dashed** `.secondary` hairline | **hollow** `questionmark.circle` |
| `moderate`, `low` | `Surface.recessed` | none | filled circle |

The edge carries the confidence: solid is drawn around what we know and can
price, dashed is a line with holes in it around a statement with holes in it,
and the ordinary tiers need no edge at all. The unfilled box is the shape of a
field left blank, which is what the group is; the hollow badge is the same
sentence one size down, since a filled badge is the sheet asserting something.
The `<all_urls>` patterns nobody could parse wear `slash.circle` rather than a
second question mark: those were never offered, and the glyph has to carry the
difference between *"we cannot explain this"* and *"we struck this out"*.

The Theme setting (System / Light / Dark) is applied via
`.preferredColorScheme(model.colorScheme)` on all three windows in
`Zer0App.swift`. Because every colour is semantic, nothing else has to change
between themes — there is no per-theme token table, and none is needed today.

### The one derived palette: `SiteBadge`

`SiteBadge` is the exception, and it is not a brand palette — it is a function.
A site's colour is `SHA256(registrable name)`, first byte, mapped to a hue:

> *"Hashed rather than picked from a rotating palette so the same site gets the
> same colour in every window, every session, forever."*

It carries a real accessibility argument and the numbers to back it: saturation
fixed at 0.62; each hue lands on one of exactly two brightness levels — vivid
(0.95) with black ink, or deep (0.60) with white ink — chosen by whether its
relative luminance crosses 0.30. The crossover sits above the WCAG threshold of
0.179 on purpose, *"the gradient's bright corner must not cross back over it."*
Worst case across all 256 reachable hues is about 6:1, gradient included, and
`SettingsTests.swift::every site colour keeps its letter readable` sweeps all of
them.

The badge is `.accessibilityHidden(true)`: *"the row next to it already says
which site this is, and hearing 'G' before every title is noise."*

### ~~Open decision: the absence is now urgent~~ — settled by ADR-0043

The absence of a palette was comfortable while there was nothing to be a palette
*of*. That changed, ADR-0040 said so and declined to settle it, and this is the
answer to the three questions it left open:

1. **The mark keeps `currentColor`** and takes the tint it is given, which is
   now the palette's accent rather than the person's macOS setting. The SVG's
   own header argued for this and it still does: *"the size belongs to whoever
   draws it; so does the colour."*
2. **There is a zer0 accent, and it replaces `.tint`'s source.** The browser is
   no longer the system's colour. Adopting it was one modifier at the root
   precisely because the accent was always spelled `.tint` and never
   `Color.accentColor`.
3. **What inherits from it did have to be re-derived**, and two things did not
   inherit at all: `.selection` and the sidebar's material, both above.
   `SiteBadge` is deliberately *not* re-derived — it is a hash of a hostname,
   not an accent, and its contrast floor stands on its own argument.

ADR-0040's trap is still worth reading: *"a mark that only exists in
`currentColor` has never been tested against a background it must live on, and
colour can break a shape that works in black — a thin cut between two mid-tone
fills has far less contrast than the same cut in black on white."* The mark
appears in exactly two places and both are rendered in `design/adopted/`.

**The rule that replaces "do not add a colour constant":** a colour constant
belongs in `Design.Palette` and nowhere else. That is stricter than the ban it
replaces, and a test enforces the half of it that can be.

---

## 8. The mark

`design/logo/zer0.svg` is the source of truth; `Zer0Mark` is a port of its path
data into a SwiftUI `Shape`, coordinate for coordinate, in the SVG's own 256×256
viewBox so the two can be read side by side. It is geometry rather than a
bundled asset for the same reason the SVG carries no `<text>` and no `stroke`: a
path takes the colour of whatever draws it, stays sharp at any size, and there
is no resource that can fail to load.

**The mark appears in exactly two places**, and `BrowserView` states the rule:

> *"It earns it here because it is the one moment the browser is not being used
> for anything — the sidebar, the command bar and the page are all tools in
> hand, and a logo on a tool in hand is an interruption."*

1. `NothingOpenScreen` — `Glyph.mark` (72), `.tertiary`, quiet.
2. `AboutView` — `Glyph.mark` (72), `.tint`, *"the one place it is allowed to be
   the loudest thing on screen."*

**There is a size floor, and it is measured in rendered pixels.** ADR-0040
settles it at **32 px, not 24**: at 32 the canonical cut *"survives only as a
disturbance in the antialiasing — present, but not legible, which is the worse
failure because it looks intentional."* Pixels rather than points is deliberate:
16pt@2x and 32pt@1x get the small drawing, while 32pt@2x gets the canonical one.

`design/logo/zer0-small.svg` is that small drawing, and it is a **redraw, not a
scale** — the ring goes 32u → 44u, the gap and slip roughly double, and the mark
is *shortened*, 80×104 → 72×94, *"because the grid scales by the tallest
dimension and height given up buys thickness everywhere else. This is what type
designers call hinting, and refusing to do it is how a mark ends up as a smudge
in the Dock."*

**It is not ported into code.** `Zer0Mark` carries only `zer0.svg`. Both current
uses are at `Glyph.mark` (72), well clear of the floor, so nothing is broken —
but there is no correct drawing available in Swift below 32 px, and two places
in the repository still quote the superseded 24 (see Debt).

**The app icon's body is the system's.** On macOS 26 the platform draws the
rounded square and insets the artwork, so the mark ships free-standing on
transparency. Drawing our own body *"puts a second squircle inside the system's
— a dark tile floating in a light one — and at 16px that degrades into a
checkerboard smudge."*

ADR-0040 also records what the mark deliberately does not carry: *"The mark
carries no meaning beyond the name. It says 'zero' and nothing about browsing,
speed or privacy."* A browser icon competing with a globe, a compass and a fox
*"does better as an unexplained shape than as a worse metaphor"* — at the cost
of having no recognition on day one.

`Zer0MarkTests.swift` holds four properties: the path is not empty, it stays
inside the box it is given, it fills that box rather than hiding in a corner,
and there is a hole in the middle with a ring around it.

---

## 9. States

`CLAUDE.md`: *anything in flight has feedback; no still screen with no
explanation.* Concretely, the shell has five kinds of state and each one has a
form.

### Empty — a product screen, not an apology

Every empty state in the codebase uses `EmptyState` and every one of them offers
an action, except History, where there is genuinely nothing to offer but
browsing — **and except the chat page, which is a different kind of screen and
is treated as one below.**

The browser's own empty screen was the exception until recently, and it was the
exception in the worst possible place: the screen everyone meets on day one had
less in it than the three buried inside Settings. It now carries the same
prominent button they do.

| Screen | Glyph | Title | The action |
|---|---|---|---|
| Browser, nothing open | the mark | "Nothing open" | prominent "New Tab" on `.defaultAction`, with the chord under it read from the live keymap. The message says what the button is about to do — the command bar opening on "Where to?" — rather than printing a shortcut that rebinding would turn into a lie. |
| Sidebar, empty space | `rectangle.stack` | "Nothing open here" | prominent "New Tab". *"Without it the sidebar is a blank panel with one small button in the corner, which is the worst possible first impression of the feature the whole browser is built around."* |
| Command bar, no query | `command` | "Where to?" | teaches what the bar takes, plus the ↑↓ / ↩ / ⌘↩ / ⎋ hints |
| Command bar, no results | `magnifyingglass` | "No results for “…”" | says the search came back empty rather than leaving a field floating on its own |
| Downloads | `arrow.down.circle` | "Nothing downloaded yet" | "Open Downloads Folder" |
| Extensions | `puzzlepiece.extension` | "No extensions yet" | "Open the Chrome Web Store" — *"Somebody with no extensions has no link to paste yet."* |
| Air Traffic | `arrow.triangle.branch` | "No rules yet" | "Start with an example", which **writes the first rule into the composer** — *"Somebody with no rules does not know the shape of one."* |
| History | `clock` / `magnifyingglass` | "Nothing here yet" / "No matches" | none; there is nothing to do but browse |

The pattern to follow: **the empty state teaches the feature and hands over the
first step.** Two of them do it by pre-filling a form.

**The one screen that is not an `EmptyState`, and why** (ADR-0070). A
conversation with nothing in it is not a list saying it has no rows — it is the
front door of the feature with a live field on it. `EmptyState` fills whatever
it is dropped into, which would make the composer a child of the empty screen;
and the composer has to be *the same view* before and after the first question,
because it travels from the middle of the canvas to the bottom and carries the
cursor and the half-typed question with it. So the chat page composes its own:
one line in `Design.Text.greeting`, the sentence that says what will and will
not be read, and the composer directly beneath. No glyph — a picture of sparkles
was decoration standing where the invitation should be.

It follows the pattern above rather than escaping it, and ADR-0090 finished the
job of making it do so (§9's own rule: *teach the feature and hand over the first
step*):

- **The glyph slot is the page**, as a capsule carrying its favicon, its title
  and its site — the three things a person recognises a page by. The address
  used to be printed in the sentence instead, which on a real page meant
  `chromewebstore.google.com/detail/1password-%E2%80%93-password-mana/…` wrapped
  over three lines of body copy.
- **The action slot is three questions**, pressable, that send. Air Traffic and
  the command bar already do this by pre-filling a form; here the form is a
  conversation, so the first step is a question rather than a template. They
  claim nothing about what the page says, and they are **not offered when the
  page is closed** — a chip saying "Summarise this page" under a sentence saying
  nothing will be read is one screen contradicting itself.

### Loading — visible, and never more than it has to be

- The page: 2pt of linear `ProgressView` at the top of the web view. ADR-0010
  and the code call it *"the only thing allowed to sit on top of a page, and
  only while loading."*
- A sidebar row: a mini spinner in the trailing column, and the `SiteBadge`
  drops to `.opacity(0.4)` until the load completes.
- The find bar: a `searching` state with a spinner, which exists because
  *"WebKit answers asynchronously, and a bar that says nothing while it waits
  looks broken on a long page."*
- The install banner: a spinner replaces the icon during `installing`.
- A download: a bar when the server sent a length, a spinner beside the byte
  count when it did not. Two shapes rather than one at two fills, per §10.

### Error — the failure gets the whole screen

`NavigationErrorScreen` replaces the page rather than floating over it, because
*"a white rectangle is the worst possible answer to 'did that work?': it is
indistinguishable from a page still loading and from a page that is genuinely
empty."* (ADR-0016.)

Its shape is fixed: an icon chosen per failure kind, a title **named for what
happened rather than for the error that reported it** (*"Nobody has ever been
helped by reading 'NSURLErrorDomain -1009'"*), a sentence a person can act on,
the full address in a monospaced capsule under the headline (*"a long URL in a
title destroys the hierarchy, but you still need to see exactly what was asked
for"*), and one prominent action on Return.

Eight kinds, each with its own icon, title and sentence: `offline`,
`hostNotFound`, `connectionFailed`, `timeout`, `certificateInvalid`,
`unsupportedUrl`, `cancelled`, `unknown`. The host is shown as a person would
say it — `www.` is dropped, *"noise nobody says out loud."*

`unknown` is the only case that shows the engine's own message, and the comment
says why: *"the category is the shell admitting it does not recognise the
failure. What the engine said is then better than a guess."*

`DownloadCopy` mirrors this exactly for downloads: eight failure kinds, an icon,
a short title and a full sentence for each, and the same `unknown` fallback,
*"in the same voice the navigation error screen uses: what happened, and what it
means for you."*

### The app could not deliver what it promised

Two cases exist, and they are the most important ones in the file because
neither is a page failing — both are the browser failing.

**The session could not be read.** Saving is switched off in that state, so the
alternative to saying something is *"letting someone work all day and lose it at
the next launch."* The notice appears at the top of the window, is
`.regularMaterial` with an orange hairline, carries the real error text, and is
dismissible *"because knowing once is enough."* Its wording is the point:

> "Your previous session could not be read. Nothing is being saved this session,
> so the file you already have is not written over."

That is not an apology; it names the trade being made on the person's behalf.
`BrowserModel.showsSessionWarning` is a named property rather than an inline
condition *"so the condition can be tested: a banner that silently stops
appearing is a warning nobody ever gets"* — locked by ADR-0017.

**A download died on quit.** `WKDownload` cannot be resumed across a launch, so
`SessionLifecycle` asks **before** quitting, and the alert names the file (or
the count) and states the consequence: *"Quitting stops them. zer0 can't pick
them up again next time, so they would have to start over."* Buttons are "Quit
Anyway" / "Keep Downloading" — verbs, not Yes/No.

A download that was in flight when the process died comes back as
`interrupted`, not `failed`, and says so in its own words: *"Stopped when zer0
quit"*, and in the list, *"zer0 quit while this was still coming down, so it is
incomplete."*

### A page said something — and it is visibly the page saying it

`alert()`, `confirm()` and `prompt()` are the only screens in this browser whose
words are **not ours**, and the whole of `PageDialogSheet` is about that showing
(ADR-0089). Three things carry it, and the third is the only one with a test:

- **The identity line is never absent.** The browser's own sentence names the
  host — "example.com says", "example.com is asking" — and the canonical origin
  sits under it in `mono`, exactly as `SitePermissionSheet` does it. The host is
  punycode, so a string of Cyrillic drawing as `apple.com` shows as
  `xn--80ak6aa92e.com`. A page with no origin gets a *sentence* saying so rather
  than a blank line, because a blank is what a spoof stands in.
- **The page's words sit in a recessed block and nowhere else.** Different
  material from everything around them, selectable, never weighted, never
  tinted, capped at 200pt with the edge dissolving where it carries on. Rendered
  without that last part, the twentieth line was cut through its middle against
  a hard edge, which reads as a drawing fault rather than as more text — the
  same defect `ExtensionConsentSheet`'s fade exists for.
- **`Text(verbatim:)`, never `Text(_:)`.** The second parses markdown at
  runtime, so `**Your password has expired**` would arrive in bold, in our type,
  on a panel we drew. `PageDialogSourceRuleTests` reads the source for it,
  because no assertion can watch a string *not* being parsed.

The `prompt()` field carries a hairline edge the quoted block does not. Rendered
without it the two recesses were the same fill at the same radius, stacked, and
what somebody typed read as something the site had said.

The glyph is a grey speech bubble on all three — saying, asking, waiting — and
grey rather than a status colour for the reason `unknown` is grey on the consent
sheet: the browser has no claim to make about words it has not read.

### Destructive — the warning says what is lost

The shared rule, written twice in the codebase in nearly the same words:

> *"Says what is actually about to be lost. 'Are you sure?' is not a warning, it
> is a speed bump."*

`Sidebar.closeSpaceWarning` has three branches — nothing open, one tab, *n*
tabs — and names the count. Clearing history says *"Every page you have visited
will be forgotten. This cannot be undone."* Closing a window is gated by
`shouldConfirmClosingWindow`, which counts only `today` tabs *"because pinned
and favorite tabs come back on their own, so they do not count towards 'you are
about to lose things'."*

**When it asks, stated as a rule rather than left to each site.** An action that
discards something a person accumulated or configured, and that cannot be got
back, asks first. Two rows of the same settings window used to disagree about
this: "Clear History…" asked, and "Reset to Defaults" wiped every rebinding on
one click and looked like "Choose…" while doing it. That was an omission, not a
decision, and it is now not possible to make again — `DestructiveButton` takes
the question and the consequence as arguments, so a caller cannot have the red
without the asking.

What does *not* ask: an action that removes an entry without removing the thing
it points at. The downloads list's "Clear" takes the rows and leaves the files
where they are, and says so in its tooltip.

And the negative case: `Close Space…` is `.disabled` when there is only one
space *"rather than letting the core silently ignore it"*. An enabled control
that does nothing is the same lie in another shape.

---

## 10. Saying only what can be proven

This is a design principle, not a note about the find bar. ADR-0018 states it:

> **The interface only asserts what the layer beneath it can back up.** Where
> the data does not exist, it does not fill the space with a plausible number:
> it says what it knows, or it says it does not know yet.

**In the find bar.** `WKFindResult` reports `matchFound` — a boolean — and
nothing else. No total, no index. So there is no "3 of 17", and none is
invented. The status is a closed enum of five cases, each corresponding to a
fact: `idle` (no query, show nothing), `pending` (the query changed and has not
been searched — `↩ to search`), `searching` (WebKit is answering — spinner),
`found` (✓), `notFound` (red). `pending` exists because of `searchedFor`:
without it, *"a stale 'not found' from the previous term would sit next to
freshly typed text."*

**In downloads.** A server that sends no `Content-Length` gets no bar at all —
it gets the spinner, beside the byte count:

> *"A bar that implies a scale we were never sent is exactly what ADR-0018
> forbids, and the person only finds out when the sweep passes the end and
> starts again."*

This is the rule catching its own drawing. The indeterminate linear
`ProgressView` that used to sit here animates, so it never read as a still
screen — but it is the *same track as the determinate one at a different fill*,
and a shape that cannot say "unknown" is a shape that says something else. Two
facts, two shapes. The status line says `"1.2 MB so far"` rather than a
percentage, because
*"there is nothing to be a fraction of. What has arrived is a fact and is all
that gets said."* And the decision is in the core, so it cannot be worked
around: `fraction()` also returns `None` for a zero total and for a total
smaller than what already arrived, *"a number the server got wrong."*
`DownloadTests.swift::DownloadHonestyTests` locks all three.

**The same principle, in five more places:**

- **Tooltips read the live keymap.** `Sidebar.tip` and `FindBar.tooltip` call
  `model.chord(for:)` rather than writing a chord by hand, *"so rebinding a
  shortcut does not leave a lie behind in the tooltip."* A hard-coded shortcut
  is an assertion with an expiry date.
- **The consent sheet's footer changes as switches change**, saying what Add is
  about to do in the present tense and naming the counts: *"X will run holding 3
  of 7. Whatever it needed from the rest will not work."* A dialog whose
  consequence only becomes visible afterwards teaches nobody anything.
- **A list that goes on says so before anyone touches it.** The consent sheet
  caps at `maxHeight` 620, and an ordinary seven-permission manifest overruns
  it. macOS hides its overlay scrollbars at rest, so what that produced was a
  permission sliced through the middle against the footer rule, its rounded
  corner cut flat, two more below it that nothing mentioned — under a footer
  counting *all seven*. A count is only honest if the things it counts can be
  reached. The list now dissolves over `Metrics.fade` at whichever edge it
  continues past, and while there is more below, the rule between list and
  footer carries a chevron. Both are driven by one `ScrollEdges` read from one
  scroll geometry, so the two cannot disagree.
  **Add stays reachable throughout, deliberately.** Gating it on having
  scrolled to the end would assert that the list was read, and scroll position
  is not comprehension — every scroll-to-accept dialog ever shipped proves it
  produces scrolling, not reading. Under ADR-0018 that is a claim we cannot
  back, and it would cost Return its meaning (§9) for a ritual. The honest fix
  is to make the remainder visible and reachable, not to lock the door: Escape
  still grants nothing, and everything the browser cannot explain still arrives
  switched off.
- **The extensions list shows what an extension holds, not what it asked for** —
  *"Those stopped being the same thing the moment refusing became possible."*
- **Permission patterns zer0 could not parse are listed and deliberately not
  switchable**: *"an approval the browser could not act on would be a lie with a
  control next to it."*
- **A permission this engine does not implement gets the same treatment**, on
  both the consent sheet and the expanded row in `ExtensionsView`: where the
  switch would be there is a sentence, *"zer0 cannot provide this — WebKit does
  not implement it."* It is short because it repeats: 1Password asks for six of
  them, and a longer line stacked six identical paragraphs down the block, which
  reads as a rendering fault rather than as six rows sharing a status. Measured — twenty-five
  of the permissions the vocabulary describes gate a `chrome.*` namespace that
  is absent from a fully granted extension context (ADR-0084). The row keeps its
  risk tier and its rank, because what the extension asked for is worth reading
  even where it cannot have it. The words come from the core, like every other
  word on that row: `PermissionRequest.cannotProvide` is an `Option<String>` and
  not a flag, so a row cannot be drawn inert without carrying the reason.
- **And the row's status line stops pointing at a switch that could not help.**
  A background WebKit could not start used to read *"switching one off can be
  enough to cause this"* whenever the extension held less than it asked for.
  Where everything it is missing is something this browser cannot provide, that
  sends somebody to a control that changes nothing, so the sentence says what is
  true instead and names no cause.
- **A disabled button says why it is disabled.** `ExtensionsView.hint`: *"A
  disabled button with nothing next to it is a dead end: you can see it will not
  work, but not what to change."*
- **The About window says "Development build"** when there is no bundle to read
  a version from, rather than printing a version nobody built.

**The cost is real and is written down.** ADR-0018 records that the find bar is
objectively less informative than any competitor's, that it will look
unfinished, and — the sharpest bit — that this is *"the only ADR in the set
whose regression makes the interface look better."* Adding "3 of 17" is a change
everybody praises in the PR. **ADR-0018 has no test lock.** It is marked
`Lock: none — debt`, and the ADR lists, in order of cost, what would lock it:
extracting `FindBar.Status` out of the `View` and testing its transition table
first.

### Where the principle is currently owed something

Three places where the interface says nothing, and the ADRs say that silence is
itself a claim.

- **No padlock, no HTTPS indicator.** ADR-0010 removed the permanent chrome that
  would have carried one and records the consequence without softening it:
  *"the absence of an error is not a claim of safety."* Whether the browser
  should say something about the connection, and where, is undecided.
- **No persistent marker that a space is ephemeral.** The space chip carries an
  `eye.slash.fill` glyph and a *"keeps nothing"* tooltip, but nothing on screen
  says so while you are browsing. ADR-0023: *"There is no persistent marker on
  the window while browsing, no line saying 'nothing here is being written
  down'. ADR-0018 says the interface only asserts what it can back up; here it
  asserts nothing at all, and silence is a bad way to communicate a guarantee."*
  The same ADR names the shape of the answer: *"the honest version of it says
  what is not being recorded rather than just showing an icon."*
- **Menus lie by omission when a command has two chords.** `chord_for` returns
  the first binding, so `ToggleSidebar` shows ⌃S in the menu and its ⌘B
  fallback — the only one that survives on Linux, per ADR-0012 — is invisible.
  Declaration order in the core's defaults became a UI decision without looking
  like one.

**The question to ask on any new surface** that shows a count, a percentage, a
time remaining or a security status: what backs that number, and what does it
say when the source does not know? ADR-0018's own revisit clause is the
strongest form of it — if WebKit ever exposes a real occurrence count, showing
"3 of 17" becomes *mandatory*: *"The rule does not change; what changes is what
can be proven."*

And its self-check, worth keeping in view: *"Honesty can become an excuse not to
investigate… The rule is about not **inventing**, not about accepting the first
limitation you hit."*

---

## 11. Keyboard and focus

Focus is design here, not plumbing, and it has more tests than anything else in
the shell.

- **A field that opens is focused, and its contents are selected.** ADR-0013,
  locked by `CommandBarFocusTests.swift::the field takes first responder without
  anyone clicking it` and `::the existing text comes selected, so typing
  replaces it`. `CommandBarField` drops to AppKit to do it, because
  `@FocusState` loses to the `WKWebView` underneath: *"A text field you have to
  click into first is not a text field, it is a chore."* Focus is taken **once**,
  not stolen back on every redraw — also tested.
- **Esc closes. Everywhere.** Including a drag still under the pointer, which
  needs an `NSEvent` local monitor rather than `.onKeyPress`, *"because a key
  press only reaches a view that has focus, and during a drag focus is wherever
  it was before the mouse went down."* The About window carries a hidden
  zero-opacity `.cancelAction` button for the same reason: *"A panel you can only
  dismiss with the mouse breaks the rule for no gain."*
- **Enter means what the gesture that opened the bar meant** (ADR-0019). ⌘L
  navigates the tab you are on; ⌘T opens a new one; ⌘↩ overrides either, and
  picking an already-open tab always switches to it whichever gesture opened the
  bar. The hint row changes to match the intent — and ADR-0019 concedes the
  weakness of that mitigation: *"a hint is weaker than an interface that cannot
  be misread."* ⌘↩ itself has no test; it needs a key window and a real event
  loop.
- **Enter always does something.** The command bar reserves its last slot for
  the interpretation of what was typed —
  `let room = limit.saturating_sub(1)` — so *"even with zero results, Enter does
  something."* The failure message on the test that guards it reads *"the escape
  hatch must never be crowded out."*
- **⌘S / ⌃S / ⌘B.** ⌘S stays Save Page, as in Chrome. The sidebar toggle is ⌃S
  on a Mac — but off Apple `primary` *is* Control, so the two collapse, and Save
  wins. ⌘B is the universal fallback that survives the collision, which is why it
  exists and why deleting it for looking redundant would leave Linux with no way
  to reach the toggle at all (ADR-0012).
- **Arrows walk the list and wrap**, and only keyboard moves scroll the list:
  *"doing it for the pointer would drag a row out from under the pointer, which
  hovers the next row, which scrolls again."*
- **Pointer and keyboard never disagree**: hovering a command-bar row takes the
  highlight, *"so mouse and keyboard never disagree about what Enter would do."*
- **The shortcuts are Chrome's** (ADR-0011), and the keymap lives in the core
  against a `primary` modifier (ADR-0012) so ⌘ here is Ctrl elsewhere. Menus and
  tooltips are generated from it.

### Accessibility, as it stands

What is there: the sidebar row is `.focusable()` with `.onKeyPress(.return)`,
an `accessibilityLabel`, `.isButton` / `.isSelected` traits and
`.accessibilityElement(children: .contain)` so its close and mute buttons stay
reachable — *"a tap gesture is invisible to both the keyboard and VoiceOver."*
Unlabelled switches in the consent sheet and the extensions list carry
`accessibilityLabel(item.title)`, *"read aloud, an unlabelled switch next to two
lines of prose is a switch for nothing."* `SiteBadge` is hidden as decoration.
The type scale follows the system text size by construction.

What is **not** there, stated as an absence rather than a plan: no view reads
`accessibilityReduceMotion`, `reduceTransparency`, `differentiateWithoutColor`
or `dynamicTypeSize`. Motion, materials and the status colours are unconditional.

---

## 12. Debt: what the views do that the system does not say

Everything below is a real inconsistency between `DesignSystem.swift` and the
views, found by grepping `apple/Sources/Zer0Shell/`. It is listed rather than
silently normalised, and nothing here has been invented into a token.

**Most of this list has been paid.** What was paid is struck through with a
note saying what replaced it and where the criterion now lives; what is still
owed is left standing. Nothing has been deleted from the list on the strength
of being fixed, so the shape of the debt stays readable.

**Three files were off limits while this was paid down** — `Sidebar.swift`,
`TabDrag.swift` and `BrowserView.swift` were being edited by other work, and
`DesignSystem.swift`'s `Stroke` enum belongs to that work too. Their sites are
called out individually below and are the bulk of what remains. Every one of
them is a mechanical substitution against a token that now exists.

### ~~A dead token~~ — paid

`Design.Duration.settle` (0.28) was deleted rather than given a use. The shell
has exactly two curves on purpose (§3), and a third duration nothing consumed
was the first half of an inconsistency: the next person needing "a bit slower"
would have reached for it without knowing what it meant. `DesignSystem.swift`
carries a comment where it was, so it does not come back by accident.

### A superseded number quoted in two places

ADR-0040 settles the mark's size floor at **32 rendered pixels**, revising the
24 that was first assumed. Both places have been corrected:

- ~~`DesignSystem.swift:51`~~ — `Glyph.mark`'s comment now reads *"Well clear
  of the floor ADR-0040 settles at 32 rendered pixels, below which the diagonal
  cut survives only as a disturbance in the antialiasing."*
- ~~`design/logo/zer0.svg`~~ — fixed separately.

Neither caused a wrong drawing — `Glyph.mark` is 72 and clears either figure —
but both stated the criterion using a number the decision record had moved.

### Raw point sizes, which the type scale exists to prevent — mostly paid

The `Text` scale's whole argument is *"so the whole UI follows the system's text
size instead of staying at 11pt for someone who cannot read 11pt."*

| Where | Was | Now |
|---|---|---|
| `CommandBarField` | `fontSize: CGFloat = 20` | `Design.Text.FieldSize.command` |
| `FindBar` | `fontSize: 13` | `Design.Text.FieldSize.strip` |
| `WindowChrome` | `.font(.system(size: 13, weight: .medium))` | `Design.Glyph.control` |
| `ExtensionConsentSheet` | `.font(.system(size: 26))` | `Metrics.mark`, local to the sheet |
| **`Sidebar.swift`** | `fontSize: 13` (the rename popover's field) | **still a literal — file left to its owner.** Same size and same argument as the find bar's, so it reads `Design.Text.FieldSize.strip`. |

`FieldSize` is a naming, not a fix. Both sizes still bypass the system text
size, because `CommandBarField` is an `NSTextField` and AppKit takes a number.
**The real fix is still owed**: `NSFont.preferredFont(forTextStyle:)` would
follow the system size, but the two callers set fixed frame heights (28 and 20)
around the field, so it cannot be swapped in without re-deciding that geometry
— and `CommandBarFocusTests` is the thing that would have to stay green.

### Two ways to write the same type — paid

- ~~Five pane titles, two spellings.~~ `SettingsView` (Air Traffic, Shortcuts)
  and `ExtensionsView` were put on `Design.Text.paneTitle` like the other two.
  **Since superseded twice:** all five titles are gone — a pane does not
  repeat what the sidebar already says (§5) — which left the token without a
  consumer, and it has now been deleted. See [below](#a-token-with-no-consumer-designtextpanetitle--paid).
- ~~`.caption` written directly; `.callout` with no token at all.~~
  `Design.Text.detail` (`.callout`) was added with a criterion, and every
  `.caption` / `.callout` in the files below now goes through
  `Design.Text.label` / `Design.Text.detail`: `DesignSystem.swift`,
  `AboutView`, `FindBar`, `InstallBanner`, `WindowChrome`, `CommandBar`,
  `DownloadsView`, `ExtensionsView`, `ExtensionConsentSheet`, `SettingsView`.
  `Sidebar.swift` and `BrowserView.swift` were checked and turned out to have
  none: they were already on the tokens. The "roughly two dozen" were all in
  the panes above.
- ~~`CommandBar`'s empty state at `.largeTitle.weight(.light)`.~~ It now uses
  `EmptyStateSymbol`, the same glyph every other empty state gets.

- ~~`.title3` spelled out at `EmptyState`'s title.~~ Half paid, and by
  answering a different question. The empty-state headline is
  `Design.Text.emptyTitle` — and it moved up a step while it was at it, because
  `.title3` medium was one notch over the sentence beneath it and the screen
  read as a caption with a picture on top.

Still owed: the consent sheet's header is `.title3.weight(.semibold)` written
out. One site, which is under the Rule of Three, and `commandInput` is the same
value under a name that means something else.

### ~~Sub-`hair` spacing~~ — paid, except in two files

`Design.Space.line` (2) was added as the one named exception to the 4pt rhythm,
with the criterion on it: the two lines of a single label are one thing, and at
`hair` they separate into two stacked rows.

Converted: `DesignSystem.swift` (`SettingRow`), `CommandBar` (row stack, both
`hair / 2` paddings), `InstallBanner`, `ExtensionsView`,
`ExtensionConsentSheet`, `SettingsView`.

Still literal, in files left to their owners:

- `spacing: 1` — `BrowserView.swift`'s session warning, a title over its
  explanation. That is the two-line label case and it is `Space.line`.
- `Design.Space.hair / 2` — `TabDrag.swift`, the vertical padding on the
  insertion line's destination pill. Same shape as the command bar's
  destination chip, which is now `Space.line`.

**And one correction to this list as it was written.** `Sidebar.swift`'s two
`spacing: 1` sites are *not* the two-line label case: they are the seam between
rows in a list — the gap between the three section groups, and the gap between
the rows inside one. That is a different job, and `Space.line` is the wrong
token for it. A 1pt seam between selectable rows is arguably its own token
(a list seam, deliberately below the smallest gap so adjacent selected rows do
not fuse), but with two sites in one file it is under the Rule of Three and it
stays a literal until a second list wants one.

Also paid: `.padding(.vertical, 3)` on the shortcut key cap in `SettingsView`
is now `Design.Space.hair` — a point taller, back on the rhythm, and looked at.
**Still owed:** `.padding(.top, 100)` in `BrowserView.swift`, the command bar's
distance from the top of the window. Larger than the largest token and unnamed;
it belongs in `CommandBar.Metrics` as the answer to "how far down does the
palette sit", but the file is not mine to touch.

### Strokes that bypass `Design.Stroke` — half paid, and one investigated

- ~~`lineWidth: 1` at `DownloadsView`~~ — now `Design.Stroke.hairline`.
  **Still raw at `BrowserView.swift`** (the session warning's orange border).
- `lineWidth: 0.5` at `FindBar` and `InstallBanner` — **investigated, and it is
  a real difference, not drift.** 0.5pt is one device pixel at @2x: the
  thinnest line a Retina display can draw. Both sites are a `.regularMaterial`
  panel whose border exists to close its edge against whatever page is behind
  it, not to be seen; a full point there reads as a frame drawn around the bar.
  The `Design.Stroke.hairline` uses are the opposite case — a border that
  *should* be noticed (the lifted drag card, the critical-permission group, the
  download shelf's card).

  **The token is owed and was deliberately not added.** It belongs in
  `Design.Stroke` as something like `pixel`, and `Stroke` is the one part of
  `DesignSystem.swift` another agent is editing. Both sites are named
  `Metrics.edge` locally instead, each with the reasoning above written on it,
  so the finding is not lost — but two local constants for one idea is still
  debt, and it closes by moving them into `Stroke`.

### ~~No elevation scale~~ — paid

`Design.Elevation` is three steps applied through `.elevation(_:)`; the steps
and their criteria are in §4. What changed at each site:

| Where | Was | Now |
|---|---|---|
| `CommandBar` | black 0.28 / 30 / 12 | `overlay` — same numbers, now named, and `Metrics.shadow` / `Metrics.shadowOffset` are gone |
| `DownloadsView` (shelf) | black 0.22 / `Space.regular` / `Space.tight` | `floating` (0.22 / 18 / 8) |
| `FindBar` | black 0.15 / 12 / 4 | `resting` (0.18 / 12 / 4) |
| `InstallBanner` | black 0.18 / 18 / 6 | `resting` (0.18 / 12 / 4) |
| `SiteBadge` | own colour 0.35 / 2 / 1 | unchanged — documented exception, see §4 |
| **`BrowserView`** (session warning) | black 0.2 / `Space.regular` / `Space.hair` | **unchanged — file left to its owner.** It is `floating`. |
| **`Sidebar`** (lifted row) | black 0.3 / `Space.snug` / `Space.hair` | **unchanged — file left to its owner.** Closest to `resting`; the 0.3 is the highest opacity in the shell paired with the smallest radius, which is the one recipe on the old list that inverts. Worth deciding rather than substituting blind: a row under the pointer may want to read heavier than a bar that merely appeared. |

Rendered before and after, in light and dark, on a gradient page: the old set
had the install banner casting a *blurrier* shadow than the deeper download
shelf, and the find bar and install banner — the same class of object — reading
as two different distances. The new set reads as three steps.

### ~~The most-repeated value in the codebase is not a token~~ — paid

`Design.Surface.recessed` (`.quaternary.opacity(0.4)`) replaces all ten sites
except `BrowserView.swift`'s error-address capsule, which is in a file left to
its owner.

The near-twin at 0.3 was **kept, not flattened**: it is
`Design.Surface.recessedInner`, and the criterion is in §2. Both of its sites
are a second recess inside a view that already has one at full strength.

### ~~Two spellings of the accent colour~~ — decided, and mostly paid

**`.tint` is correct.** The reasoning is in §7: `.tint` resolves against the
environment and a single `.tint()` at the root can re-point it,
`Color.accentColor` reads the system setting and cannot. Since whether zer0 has
an accent of its own is explicitly open (ADR-0040), the spelling that keeps
that decision cheap wins.

- `CommandBar` — both `Color.accentColor` sites are now `.tint`, one via
  `AnyShapeStyle` so the highlighted and unhighlighted branches share a type.
- `DownloadsView` — `tint` changed return type from `Color` to `AnyShapeStyle`
  rather than changing the style to a colour.
- **`TabDrag.swift` still uses both, five lines apart** — file left to its
  owner. The `.accentColor` there is the insertion line's glow.

### ~~Letter-spacing on uppercase headings~~ — paid, except in one file

`.sectionHeading()` bundles `sectionTitle`, `.textCase(.uppercase)` and
`.tracking(0.6)`, so the three can no longer be applied separately.
`DesignSystem.swift` (`SettingSection`) and `ExtensionConsentSheet` use it.

`Sidebar.swift`'s two headings are left to its owner, and they are **not the
same case as each other**:

- The rename popover's heading is `Design.Text.sectionTitle` + uppercase +
  0.6 — exactly `.sectionHeading()`, and a clean substitution.
- The tab-group heading (FAVORITES / PINNED / TODAY) at 0.5 is **not** on
  `sectionTitle`: it is `Design.Text.micro.weight(.semibold)`, a step smaller.
  So the 0.5 may be right rather than a drift — less tracking on smaller
  uppercase is a defensible call, it was simply never written down. Applying
  `.sectionHeading()` there would silently grow the type as well as the
  tracking. **Whoever takes it should decide whether the sidebar's group
  heading is the same object as a settings section heading**, and either move
  it onto `sectionTitle` or give `micro`-scale headings their own modifier with
  the smaller tracking stated. What is not acceptable is leaving 0.5 next to
  0.6 with nothing saying which is which.

### ~~Panel dimensions as literals at the point of use~~ — paid

Every panel outside `Sidebar.swift` and `BrowserView.swift` now has a local
`Metrics`, listed in §2 under [Local metrics](#local-metrics-the-honest-exception).
Still literal in the two files left to their owners: the session warning's 560,
the error address capsule's 420, the command bar's 100pt top padding, the
rename popover's 220×28. `EmptyState`'s 320pt message cap stays inline inside
`DesignSystem.swift`, which is where the component lives.

~~The three empty-state heights: 220, 220, 220, 260.~~ All four now take
`Design.Pane.emptyStateMinHeight` (220). Air Traffic's also changed from
`.frame(height:)` to `.frame(minHeight:)`, matching the other three — it was
the only one that could not grow.

### ~~A token with no consumer: `Design.Text.paneTitle`~~ — paid

Deleted. Settings panes no longer repeat their own name (§5), so the `title2`
semibold that meant "the title of a settings pane" had nothing left to title.

What closed it was not the file going quiet — it was `emptyTitle` needing
exactly `title2` semibold and for a different reason. Two tokens at one value,
one of them with no consumer, is not a spare part; it is the moment the next
person picks whichever name they read first. If a pane title comes back it
comes back with an argument for why the sidebar is not enough, not because a
token was lying around.

### A test harness marked temporary — still undecided

`apple/Tests/Zer0ShellTests/ZZRenderHarness.swift` renders `NothingOpenScreen`
and `AboutView` to PNG in light and dark, and its own header says *"TEMPORARY …
Deleted before reporting."* It is still the only mechanism in the repository for
looking at a screen, it is still marked temporary, and **this pass did not
settle it** — the elevation scale was checked with a second throwaway harness in
the same style, which was then deleted, which is exactly the pattern that keeps
being reinvented. Two known limits worth recording for whoever does settle it:
`ImageRenderer` rasterises a `ScrollView` as an empty box, and a
`NavigationSplitView` (so all of `SettingsView` and `BrowserView`) does not
rasterise offscreen at all — those screens have to be reached through their
components.

**One trap in it is now closed.** `ZZRenderHarness` held a byte-for-byte copy of
`NothingOpenScreen`'s composition rather than the screen, on the grounds that
the screen was `private`. The copy went stale the moment the screen changed, and
carried on rendering a message the product no longer says — a harness that
photographs last month's layout is worse than no harness, because it is
believed. `NothingOpenScreen` is `internal` now and both harnesses render the
real view. The rule that falls out: **a harness may reduce a screen to its
components, but it may not restate one.** If reaching a screen requires copying
it, widen the access instead.

Two further limits, learned by rasterising the download rows for this pass:
`ImageRenderer` mangles `.regularMaterial`, so anything with a material has to
go through `NSHostingView` + `cacheDisplay`; and an offscreen window never
becomes key, so every `.borderedProminent` button and selected row draws grey
unless the view is given `.environment(\.controlActiveState, .key)`. Judging an
accent without that measures nothing.

---

## 13. What is not decided yet

Open questions, not plans. Nothing below is implemented; where a partial
version exists, it says so.

- ~~**The palette.**~~ Decided: B · Fault, ADR-0043, §7. One saturated
  ultramarine on neutrals tinted to the same temperature. What it also settled,
  because a root `.tint()` cannot reach them: the selected sidebar row, the
  sidebar's own surface, and the three status colours.
- **The small mark.** `design/logo/zer0-small.svg` is not ported;
  `Zer0Mark` cannot be drawn correctly below 32 rendered pixels.
- **An ephemeral indicator while browsing** (§10). The space chip already
  carries an `eye.slash.fill` glyph; there is nothing on the window. ADR-0023
  names the gap and the shape of the answer, and says the decision is its own.
- **Anything the interface says about the connection.** No padlock, no HTTPS
  indicator, no "proceed anyway" on an invalid certificate — the last of those
  is the right security call with a real cost for self-signed dev certificates
  (ADR-0016).
- **An undo for a cross-space drop.** Crossing a space costs the page's
  back/forward history with no warning beyond the destination name on the
  insertion line. ADR-0041: *"The answer is probably an undo, not a dialog — the
  objection to asking is the timing, and undo has the right timing."*
- **Localisation.** Every string in the shell is an English literal. Copy lives
  in the shell precisely so it can be localised per platform, and none of it is.
- ~~**An elevation scale.**~~ Decided: three steps, `Design.Elevation`, §4.
- ~~**A recessed-surface token.**~~ Decided: `Design.Surface.recessed`, and its
  quieter twin `recessedInner`, §2.
- ~~**A sub-`hair` gap.**~~ Decided: `Design.Space.line` (2), the one named
  exception to the 4pt rhythm.
- **A type scale that survives AppKit.** `Design.Text.FieldSize` names the two
  point sizes `CommandBarField` needs but does not make them follow the system
  text size. The two callers wrap the field in fixed frame heights, so this is
  a geometry decision as much as a type one.
- **Whether the render harness becomes a real facility**, or keeps being
  rewritten from scratch every time someone needs to look at a screen (§12).
- **A lock for ADR-0018.** The ADR names the test that would close it and it has
  not been written. It is, by the ADR's own argument, the easiest decision in the
  set to revert and the one nobody would notice being reverted.
- ~~**Reduced motion.**~~ Decided: ADR-0046, §3. Travel and overshoot go, all
  feedback stays, and the raw curves are `fileprivate` so a call site cannot
  skip the question.
- **Reduced transparency, and colour-blind-safe status.** The other two thirds
  of what used to be one entry here. The shell's materials are still
  unconditional, and nothing reads `accessibilityReduceTransparency` or
  `accessibilityDifferentiateWithoutColor`.
- **Linux appearance.** The core/shell split exists so the Linux shell is a new
  host rather than a rewrite, but no second shell exists, so no token in this
  file has yet been tested against a platform that would disagree with it.

---

## 14. The checklist, for design specifically

`CLAUDE.md` has the six questions to ask before calling anything done. These are
the ones this file adds:

1. Is every number you wrote in `DesignSystem.swift`? If not, is it genuinely
   local to one panel — and did you name it and say why, the way
   `CommandBar.Metrics` does?
2. Did you write the same value a second time? Two is a coincidence, three is a
   token — and **a token needs a criterion in its comment, not just a value.**
   A token without one is a magic number with a nicer name, and the next person
   will put a second one beside it.
3. Does the motion say where the thing came from? If it explains nothing, cut it.
4. Does the shadow belong to something that left a surface? If not, cut it. If
   it does, did it take a step on `Design.Elevation` through `.elevation(_:)`?
   A `.shadow(...)` written out at a call site is a depth that is not on the
   scale.
5. Does the screen assert anything the layer below it cannot back up? A count, a
   percentage, a time remaining, a security status — what proves it, and what
   does it say when the source does not know?
6. Is the empty state a product screen with a first step in it, or an apology?
7. Does the destructive warning name what is lost, or does it just ask "are you
   sure?"
8. Does anything you added a colour to have a reason to be that colour, given
   that the project has no palette? If it is the accent, is it `.tint` rather
   than `Color.accentColor`?
9. If it takes space above or over the page permanently, does it pay for itself
   on *every* page? If it does not, it is conditional or it does not ship.
