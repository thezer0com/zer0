# ADR-0047: The chrome takes its colour from the page, and the core decides what that colour is

- **Status:** Accepted
- **Date:** 2026-05-14
- **Lock:** `crates/zer0-core/src/tint_tests.rs::the_colour_travels_to_the_tab`, `crates/zer0-core/src/tint_tests.rs::a_transparent_background_falls_through_to_what_was_painted`, `crates/zer0-core/src/tint_tests.rs::every_colour_a_page_can_state_ends_up_legible`, `crates/zer0-core/src/tint_tests.rs::a_colour_that_has_to_move_keeps_its_hue`, `apple/Tests/Zer0ShellTests/ChromeTintTests.swift::ChromeTintTests/theStripsInkIsReadableOnAnyColourAPageCanState`

## Context

With the sidebar hidden, `WindowChrome` draws a strip across the top of the
window holding the traffic lights, a sidebar toggle and the page title. It was
painted in `.bar` — the system's own chrome material — with a `Divider` under
it.

On a dark site that is a white band welded above a near-black page, with a rule
drawn along the join in case anyone missed it. Two surfaces that know nothing
about each other, touching. It is the first thing you see on every page you read
with the sidebar away, and it is the one part of the window that never belongs
to what is under it.

The page already publishes the answer, and publishes it three times over:

- `<meta name="theme-color">`, which is the author stating a chrome colour
  outright — and which may carry a `media` query, so a site can state one colour
  for light and another for dark;
- the computed background of `documentElement` and `body`, which is the author
  stating it by drawing;
- what the engine actually painted behind the page, which is the only source
  that knows the colour of the very large number of pages that state nothing at
  all.

Safari has done this for years and Arc does it constantly. Neither is the reason
to do it; the reason is that a browser drawing its own grey above someone's page
is a browser that has not read the page.

Three questions had to be settled before any of it could be drawn, and they are
the whole of this record: **where the answer lives**, **what happens when the
page's colour cannot carry our controls**, and **what a page that lies is
allowed to do to the window**.

## Decision

### The colour is a fact about the page, so it lives on the tab

`Tab` grows a `tint: Option<PageTint>`, beside `title`, and it travels the same
road a title travels: the engine host reports what it read as an `Action`, the
reducer decides what that means, and the shell reads it off the snapshot.

```
WKWebView ─ Action::ColorsDeclared ─▶ reducer ─▶ Tab.tint ─▶ BrowserSnapshot ─▶ WindowChrome
```

Nothing about this is stored in a view. A colour parked in `@State` would be
invisible to the sidebar, to a split, to the Linux host and to a test, and it
would have to be worked out again by whoever wanted it next.

`PageTint` is `{ rgb: u32, prefers_dark_ink: bool }` — the colour, and which end
of the ink ladder is legible on it. Both are properties of the colour rather
than of a palette, which is what makes them the core's business. *Which* dark ink
and *which* light one is the shell's, and stays there.

### The host reports sources; the core picks between them

`Action::ColorsDeclared` carries three separately named fields — the
`theme-color` declarations, the element backgrounds, and the engine's canvas —
rather than one merged list. The order between them is the fallback chain, the
fallback chain is behaviour, and a host that flattened the three into one array
would have chosen it. The chain is:

1. the first `<meta name="theme-color">` whose `media` matches, that parses, and
   that is opaque;
2. the computed background of `documentElement`, then of `body`;
3. what the engine painted behind the page;
4. nothing — the shell wears its own surface.

The `media` query is evaluated *in the page*, because matching
`(prefers-color-scheme: dark)` needs the view's own idea of the appearance it is
drawn in and nothing on the Rust side has one. The page answers whether each
declaration applies; the core picks which applying one wins.

Rung 3 is not a nicety. `getComputedStyle` reports `rgba(0, 0, 0, 0)` for both
elements on the great majority of documents, so without it the common case —
a page that declares no colour anywhere — would fall straight to rung 4 and the
feature would be for the minority of sites that already thought about it.

### A colour that cannot carry a control is moved until it can

Contrast is not optional here, and it cannot be met by choosing an ink, because
a colour exists on which neither ink is readable. The gap is real and it is not
narrow: with the palette's actual inks it runs from roughly 0.145 to 0.232
relative luminance, and pure red sits in the middle of it.

So the core guarantees a band instead. `MIN_INK_CONTRAST` is 6:1 **against the
extreme ink** — pure white for a dark tint, pure black for a light one — which
is a margin the core can state without knowing what a palette is. A tint landing
between the two sides is moved to the nearer edge, along lightness only: hue and
saturation are untouched, so the page stays recognisable in its own chrome. Pure
red comes out as `#ff3e3e`, which is still plainly red.

The shell then has to stay inside that band, and
`ChromeTintTests/theStripsInkIsReadableOnAnyColourAPageCanState` is where that is
checked — every colour a page can state, through the real core, measured against
the ink `WindowChrome` would really paint on it, at WCAG AA.

### One ink level in the strip

Everywhere else in this shell, text ranks by colour first. The strip cannot: at
the edge of the band even a level 25% down from the ink drops under AA, and a
hierarchy that is only legible on most pages is not one. The toggle and the title
both take the full ink, and rank by being a control and a caption respectively.
Size and weight already say it.

### The seam goes when there is something to be seamless with

Tinted, there is no divider: a rule drawn under a strip that is already the
page's colour puts back exactly the "bar bolted on" reading the colour removes.
Untinted, the divider stays, because then there really is a boundary — the app's
own surface over a page of unknown colour — and a boundary that exists should be
drawn rather than left for the page to reveal by accident.

The untinted strip also stops being `.bar` and becomes `chromeSurface()`, the
same surface the sidebar wears (ADR-0043 is where that surface came from). The
two places the window's own controls live now look like the same place.

### The colour changes on `subtle`, and it survives Reduce Motion

`.motion(.subtle, value: tint)`. Nothing arrived; a surface that was already
there changed. `subtle` is also the curve ADR-0046 leaves alone under Reduce
Motion, which is correct: a cross-fade is feedback, not travel, and a window that
hard-cut to a new colour on every navigation would be worse than one that never
changed colour at all.

### What a hostile page gets

Four answers, and each one is a decision rather than a guard clause:

- **A colour chosen to hide our controls** is moved, not refused. Refusing would
  throw away real brand colours; moving costs the page a shade of lightness and
  guarantees the strip works.
- **An animated `theme-color`** cannot make the window strobe, because the page
  is sampled exactly twice per navigation — at commit and at load end — and never
  on a timer or a KVO observer. Two samples is also enough for the case this
  serves honestly: a site that changes its colour when you switch its own theme
  gets picked up on the next navigation.
- **A translucent colour is refused** rather than composited. What sits behind a
  half-transparent background is a guess, and a guess that is wrong is a strip
  that does not match the page it is welded to.
- **Everything else is hostile input** (ADR-0024): declarations are capped at
  eight, strings over 64 characters are not colours, every value is parsed rather
  than believed, and a script that fails entirely yields no colour rather than
  black.

### The sidebar rows do not take it — yet

The tint is on `Tab`, so every row that draws a tab could wear it. They should
not, and this is the argument rather than an omission.

The strip earns the colour by **adjacency**: it touches the page, so sharing the
page's colour makes the two one surface. A sidebar row does not touch the page it
names, so the same colour there is not continuity — it is decoration, and it
would be competing decoration: the row already carries `Palette.selectedRow` and
`companionRow`, which are states someone has to read, and a third colour system
in a 24pt row makes all three harder to see. The recognition job it would be
doing is also already taken, and taken better: a favicon is a logo, and a logo is
more identifiable than the average colour of the page behind it.

The data is there the day there is a reason. There is not one today.

## Consequences

- Every page that states a colour gets a window that agrees with it, and the
  page that states nothing — most of the web — gets one too, off the engine's
  own canvas.

  *Factual correction: this was written as an accomplished fact and was not one.
  The colour was computed, stored on the tab and painted correctly — and then
  covered by the system's own toolbar glass, so no window ever agreed with any
  page. Everything this ADR describes was working; none of it reached a screen
  until ADR-0055. Worth keeping in view: every lock on this decision renders
  `WindowChrome` outside a real window, which is exactly why none of them
  noticed.*
- The core carries a colour parser: hex in four lengths, `rgb()`/`hsl()` in both
  the comma and the space syntax, and twenty colour keywords. Not all 148
  keywords, because a `theme-color` is written by someone reaching for an exact
  brand colour and they reach for a hex; a page that says `papayawhip` falls
  through to its background, which is the same colour anyway.
- A tint in the unreadable band is drawn a shade away from what the page asked
  for. That is a visible cost on a small number of sites and it is the price of
  the strip working on all of them.
- The strip has one text level where the rest of the shell has three. That is a
  local exception with a stated reason, and `WindowChrome` says so where someone
  would otherwise "fix" it.
- `Tab` grew a field that is deliberately not persisted, like `last_error`: it
  describes a page that is loaded, and a restored tab has not loaded one.

## How this regresses

The failure a person notices is a white band above a black page — the defect
this removes, coming back. It comes back three ways, and each has a lock:

- the colour stops reaching the tab, and every page draws the fallback strip;
- the chain loses its bottom rung, and every site that never heard of
  `theme-color` — which is most of them — draws the fallback strip while a
  handful of sites work, which reads as "sometimes broken" rather than "off";
- the tint stops being made legible, and a page in the band gets a strip whose
  toggle and title you cannot see. This is the worst of the three, because the
  window still looks deliberate.

The subtler regression is the palette moving out from under the guarantee: a
future ink a few shades softer clears nothing, silently, on colours nobody
tested. `ChromeTintTests` measures the shipped palette against every colour a
page can state, which is the only place that says so.

## When to revisit

- **If a sidebar row gets a reason to carry the colour.** Favicons are landing
  now; if they turn out not to be enough to tell rows apart — a wall of tabs on
  one host, say — the tint is already on the tab and the argument above is the
  thing to re-read.
- **If `theme-color` starts being the common case.** The chain is ordered on the
  observation that almost nobody declares one. If that changes, rung 3 stops
  being load-bearing and could be dropped for a simpler story.
- **If WebKit exposes the resolved theme colour in a form worth taking.**
  `WKWebView.themeColor` exists; we read the DOM instead so that *which*
  declaration wins is a rule the core owns and a test can name. If a Linux host
  arrives with the same property and the same semantics, delegating both is worth
  a second look.
- **If the band ever has to widen.** 6:1 against the extreme ink is sized for
  this palette with room to spare. A palette with much softer ink would need a
  wider band, which means moving more colours further — at which point tinting
  a strip and keeping a legible control may stop being compatible, and the honest
  answer would be a different treatment rather than a bigger nudge.
