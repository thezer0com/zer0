# ADR-0059: A bookmark is an address with no space, found by typing rather than filed

- **Status:** Accepted
- **Date:** 2026-06-25
- **Lock:** `crates/zer0-core/src/bookmarks.rs::saving_the_same_page_twice_keeps_one_bookmark`, `crates/zer0-core/src/bookmarks.rs::the_newest_thing_you_kept_is_first`, `crates/zer0-core/src/command_bar.rs::a_bookmark_outranks_history_and_loses_to_an_open_tab`, `crates/zer0-core/src/command_bar.rs::a_page_you_kept_and_visited_is_one_row_not_two`, `crates/zer0-core/src/command_bar.rs::an_empty_bar_still_offers_where_you_were`, `crates/zer0-core/src/store_tests.rs::a_bookmark_saved_in_an_ephemeral_space_outlives_it`, `crates/zer0-core/src/store_tests.rs::the_order_of_what_you_kept_survives_a_relaunch`, `crates/zer0-core/src/reducer_tests.rs::keeping_a_page_does_not_touch_the_tab_it_came_from`, `crates/zer0-core/src/reducer_tests.rs::a_tab_archived_for_going_stale_does_not_take_the_bookmark_with_it`

## Context

ADR-0014 said it in one line: *"This replaces bookmarks. There is no favorites
manager: whatever you want to keep moves up a group in the same list where it
already is."*

Three groups, and between them they answer two questions. Favorites answer "the
five things I always have open" — Gmail, Calendar, the repo — and they cross
spaces because those five follow you. Pinned answers the same question narrowed
to one context. Today answers "what am I doing right now", and archives itself
after twelve untouched hours.

None of them answers **"I want to read this in March."**

The only way to hold a page for eight months in that model is to pin a tab on
it, which is not keeping a page — it is paying rent on one. It costs a web
view, it costs memory, and it costs a row in the sidebar every single day
between now and March, in the list that is this browser's *primary* navigation
(ADR-0014). Twenty of those and the sidebar is a filing cabinet, which is the
horizontal tab strip's failure arriving vertically.

So the sentence in ADR-0014 was wrong in one direction: pinned and favorite do
not replace bookmarks, they replace a *bookmarks bar*. The long-horizon keep
has no home.

## Decision

A bookmark is the fourth thing, and it is defined by what it is **not**:

> An address and a name, kept until somebody removes it. No web view, no
> memory, no row in the list you look at all day, and no space.

Four decisions follow, and each of them is a place we did not copy Chrome.

### It belongs to no space

`Bookmark` has no `space` field. Not "is not usually scoped" — there is no
field, the SQLite table has no column, and `StorableSession` cannot express one
(the AGENTS.md rule: a guarantee is structural or it is not a guarantee).

A space is a cookie jar and an identity (ADR-0007). A bookmark holds neither:
it is a string that starts `https://`. Nothing in it can cross a jar boundary,
because there is nothing in it to cross.

The argument for scoping is that a work link in your personal space is
*misfiled*. It is a real argument, and it already has an answer that is not
bookmarks: **the routing table** (ADR-0026). Where a URL opens is decided in
exactly one place, by pattern, and a routed address is reopened in the space
that owns it. So the work link kept from anywhere still lands in Work when it
is opened. Scoping bookmarks would be a second answer to a question that
already has one, and the two would drift — which is the failure the whole
"put the rule at the one door" rule exists to prevent.

The argument against scoping is stronger anyway: the point of keeping something
is to be able to get to it, and in March you may well be somewhere else. A
keep you cannot reach from where you are is a keep you stop using. Favorites —
the existing "keep this everywhere" — already cross spaces, so global is the
answer this browser has already given once.

### Tags, not folders, and neither is required

A folder makes you answer "where does this go" at the moment you know least,
and lets you answer it once. A link is about two things often enough that being
made to choose is the friction people quit over.

Tags are optional and plural. A bookmark with no tags is complete, and most
will have none. They are lowercased and deduplicated in the core, so "Rust" and
"rust" are one label rather than two that look identical in a list and match
separately — which is how tags die everywhere else.

What makes this affordable is that **retrieval is the command bar**, which
already fuzzy-matches and ranks. A tag scores as a *title*, not as a weaker
field: it is not metadata the browser inferred, it is a word somebody typed
about this page on purpose, and it is often the only word they remember about
it. Structure is what you build when search does not work.

### Where they rank: a tier, above history and below an open tab

```
open tabs  →  bookmarks  →  history  →  ask  →  what you typed
```

**Below open tabs**, unchanged: the page is already there, switching costs
nothing, and a second copy is the bug.

**Above history**, and this is the whole ranking decision: history is a record
of where you *went*; a bookmark is a record of where you decided you would want
to return. When both match what was typed, the deliberate one is what was
meant. A bookmark's title may also be one the person wrote, so a match on it is
a match on their own words.

Tiers rather than a blend, which is the shape this file already had for tabs
against history. ADR-0015 is right that nobody praises the correct order and
one inversion sends somebody somewhere else on a key they pressed without
looking. A tier is at least a rule that can be learned once and stays learned.

**An address is offered once.** A tab suppresses the bookmark and the history
row for the same URL; a bookmark suppresses the history row. The page you kept
*and* visited four hundred times is one row, at the higher position — not three
rows that all do the same thing on a list of five.

**The empty bar does not change.** With nothing typed, ⌘T still offers recent
history and no bookmarks. "Where was I" and "what did I file" are different
questions, and history is the one that cannot be answered any other way without
typing — bookmarks have a shelf of their own. Letting them take a list of eight
would leave nothing of it.

### Saving from an ephemeral space is saving

ADR-0023 promises an ephemeral space records no history. A bookmark kept from
one is kept anyway, and survives the space.

The promise is about **traces the browser takes on its own**. History is
written by visiting. A tab is written by existing. A conversation is written by
asking a question about a page. Every one of those happens without anybody
deciding it should, which is exactly why the promise has to be structural.

A bookmark happens because somebody pressed a key that means "keep this". The
category is the one a **download** is already in: a download from an ephemeral
space still puts a file on disk, and nobody thinks that is a leak, because the
person asked for the file. A bookmark is the download of an address.

And there is nothing to leak. The record is a URL, a name and a timestamp, with
no field saying where it was kept from — so "which space were you in" is not a
question the file can answer. Contrast ADR-0056, which decides the opposite for
a site permission kept in an ephemeral space, and correctly: a permission is a
standing capability the browser exercises on your behalf later, and it is only
worth having *because* it is remembered.

What the interface owes in return is honesty about it, before rather than
after: keeping a page from an ephemeral space says, on the panel, that this one
thing outlives the space.

### It gets a shelf, not a fourth group

The kept pages live on a shelf below the tab list and above the spaces bar,
rolled up by default and costing one row when it is shut.

Not a fourth group in the tab list, for two reasons. ADR-0014 says the three
groups become "a list of lists that needs collapsing" at four, and it is right.
The deeper one is that those three are lists of *tabs* — things with a web view
behind them — and a kept page in that list would look like a tab, sort like a
tab and not behave like one. Rolled up by default because a shelf that unrolled
itself every launch would be charging back exactly the rent this feature exists
to stop charging.

### What was cut

**Import from another browser.** It is three parsers (Chrome's `Bookmarks`
JSON, Safari's binary plist, Firefox's `places.sqlite`), a file picker, and a
hostile-input pass over each of them by ADR-0024 — for something a person does
once, and only if they are switching. Everything above has to be right before
that is worth building, and building it now would have meant doing both
halfway.

**A bookmarks manager window.** A manager is what gets built when search does
not work. The command bar ranks these; the shelf lists them; renaming and
removing are on the panel ⌘D already opens. A third screen listing the same
rows would be a third place for the ordering rule to be implemented slightly
differently.

## Consequences

**What hurts:**

- **A stale bookmark outranks a hot history entry, permanently.** A page kept
  eight months ago and never opened beats a page visited forty times yesterday,
  because the tier decides before the score does. That is the cost of a rule
  you can learn, and it is a real cost.
- **Bookmarks can crowd history out of the command bar.** With `limit` 5 there
  are three ranked slots; four matching bookmarks means no history row at all.
  Deliberately uncapped — a cap is a second rule, and the first one is already
  the thing that has to be right — but this is the most likely reason to
  revisit.
- **No folders means no hierarchy, ever, for anybody who wanted one.** Somebody
  with four hundred kept pages and a filing habit will find this thin. The
  answer we are betting on is that they will type instead.
- **Global means a shared list across identities.** Somebody who keeps work and
  personal genuinely separate sees one list. The addresses are visible in a
  window that also belongs to their personal space, and no route changes that —
  routes decide where a link *opens*, not who can read the list.
- **A second store of URLs to keep in step with history.** Clearing history
  does not clear bookmarks, which is correct and will still surprise somebody
  who expected "clear everything" to mean everything.
- **The shelf is one more thing in the sidebar**, in a panel ADR-0014 already
  admits is charging permanent vertical rent.

**What we get:**

- The keep this browser did not have, at the cost it should have: no web view,
  no memory, no daily row.
- ⌘D means what Chrome means (ADR-0061), which removes the divergence ADR-0011
  named as its most likely real surprise.
- One address, one row, wherever it came from.
- A structure that cannot record which space a page was kept from, so the
  ephemerality question has no way of being got wrong later by somebody adding
  a field "for completeness".

## How this regresses

**"I bookmarked it and it went nowhere."** ⌘D on a tab with nothing committed
does nothing at all — deliberately, because keeping `pending_url` would file a
page that is about to fail. If the panel that says so ever stops appearing, the
key becomes silent, and a silent key gets pressed three more times and then
distrusted forever. That is ADR-0011's worst failure mode arriving here.

**"Bookmarking deleted my bookmark."** Somebody turns `SaveBookmark` into a
toggle, because a toggle looks tidier and Chrome's star does look like one. The
second press on a page you already kept then removes it — on the chord that is
pressed without looking, with no confirmation, and the loss is invisible until
March.

**"The command bar sends me somewhere else now."** The tiers get folded into
one blended score to "improve relevance". Nothing breaks, nothing errors, and
Enter starts landing on a different row than it did last week. Nobody reports
it, because nobody can describe it.

**"The same page is in the list three times."** The de-duplication comes apart
— most likely by somebody adding a fourth source and copying the history branch
without the `already` list. On a panel of five rows, three of them saying the
same sentence is the panel being useless.

**"My throwaway space wrote my bookmark to disk without telling me."** Somebody
removes the line on the panel that says so. The behaviour is right and stays
right; what goes is the sentence that made it not a surprise, which is the
whole of ADR-0018.

**"Everything I kept reordered itself."** Someone sorts the shelf by title,
alphabetically, because that looks tidier — and the page you kept thirty
seconds ago is now somewhere in the middle of four hundred rows. Or worse, the
order becomes last-opened, and the list rearranges itself as a side effect of
reading it.

**"Where did my bookmarks go after the update?"** Somebody adds a column to
`bookmarks` instead of a table. The schema is created with
`CREATE TABLE IF NOT EXISTS` and has no migration step, so the column never
appears on a database that already exists, every read fails, and by ADR-0017 a
failed read detaches the store — costing the whole session of everyone who had
one. The comment above the table says this; the comment above `splits` said it
first.

**The locks**, and they are split by which half of the decision they hold:

- What a bookmark *is*: `saving the same page twice keeps one bookmark` fails
  the moment ⌘D becomes destructive or starts duplicating, and
  `the newest thing you kept is first` holds the ordering rule.
- Where it *ranks*: `a bookmark outranks history and loses to an open tab`
  asserts the whole tier order as one list rather than as three comparisons
  that could each pass while the list came out wrong.
  `a page you kept and visited is one row not two` holds de-duplication, and
  `an empty bar still offers where you were` holds the one place bookmarks
  deliberately do not appear.
- What it *costs*: `keeping a page does not touch the tab it came from` is the
  "it is not a tab" half, and
  `a tab archived for going stale does not take the bookmark with it` is the
  job the whole feature exists for — twelve hours pass, the tab goes, the keep
  does not.
- What survives: `a bookmark saved in an ephemeral space outlives it` pins the
  ephemerality decision *and* pins that the tab and the visit still do not, and
  `the order of what you kept survives a relaunch` pins the ordering rule
  where it is most likely to be lost, since there is no `position` column to
  lean on.

**What has no lock:** that the shelf is rolled up by default, and that the
panel's ephemeral-space line appears. Both are appearance, both are the kind of
sentence that quietly disappears in a refactor, and neither has a test —
declared here rather than covered by pointing a lock at something adjacent.

## When to revisit

- **If bookmarks are seen crowding history out of the command bar.** The answer
  is a cap on the bookmark tier, not a blended score.
- **If a stale bookmark outranking a live history entry is felt as wrong more
  than once.** Then the tier gains an age condition — still not a blend.
- **If somebody who switched browsers cannot get their links across.** Then
  import is worth its three parsers, and it should land as one ADR of its own
  about treating each of those files as hostile.
- **If tags go unused after real use.** Then they are dead weight and should be
  deleted, not "improved" with a tag manager.
- **If four hundred kept pages make the shelf useless.** That is the point at
  which a real screen for them earns its place, and it should be
  `zer0://bookmarks` — a page in the address space (ADR-0054), not a window.
- **If somebody genuinely needs their work links invisible from personal.**
  That is the one argument that beats the routing answer, and it would make
  bookmarks space-scoped — which is a new ADR superseding this one, not a
  field added to `Bookmark`.
