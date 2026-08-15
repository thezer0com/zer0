# ADR-0044: A site icon is cached per cookie jar, in a file of its own, and an ephemeral Space never fetches one

- **Status:** Accepted
- **Date:** 2026-05-04
- **Lock:** `crates/zer0-core/src/reducer_tests.rs::an_ephemeral_space_is_never_told_to_fetch_an_icon`, `crates/zer0-core/src/reducer_tests.rs::an_ordinary_space_is_told_to_fetch_its_icon`, `crates/zer0-core/src/reducer_tests.rs::an_ephemeral_space_records_nothing_even_if_the_host_hands_us_bytes`, `crates/zer0-core/src/reducer_tests.rs::two_spaces_each_fetch_their_own_copy`, `crates/zer0-core/src/reducer_tests.rs::closing_a_space_takes_its_icons_with_it`, `crates/zer0-core/src/icons_tests.rs::html_served_as_an_icon_is_refused`, `crates/zer0-core/src/icons_tests.rs::an_oversized_response_is_refused`, `crates/zer0-core/src/icon_store_tests.rs::the_cache_survives_a_relaunch`, `crates/zer0-core/src/ffi_tests.rs::a_detached_session_still_gets_its_icons`, `apple/Tests/Zer0ShellTests/SiteIconTests.swift::SiteIconTests/spacesDoNotShare`

## Context

The sidebar drew a coloured square with the site's first letter. It was a
well-made placeholder — hashed hue, contrast held above 4.5:1 across all 256
reachable hues — and it was still a placeholder. Nobody recognises a tab by a
letter. They recognise it by its icon, and how fast a hand lands on the right
row depends on that. A browser without favicons reads as a prototype however
good the rest of it looks.

Four constraints shaped the answer, and none of them is about drawing.

**WebKit will not tell us.** Checked against the installed SDK rather than
recalled: `WKWebView` has no `icon` property, `WKNavigationDelegate` has no
icon callback, `WKWebsiteDataStore` has no icon data type, and there is no
`WKIconDatabase` header. The symbols exist in `WebKit.tbd`
(`_WKIconDatabaseCopyIconDataForPageURL` and friends) and not one of them is in
a public header. The last public favicon API was `WebView.mainFrameIcon`,
deprecated at macOS 10.14 and unreachable from a `WKWebView`. So the page's
`<link rel="icon">` has to be read out of the DOM, and the bytes fetched
ourselves.

**Fetching an icon is a network request**, which makes this a privacy decision
before it is a visual one. ADR-0023 promises that an ephemeral Space records
nothing, and it names this feature by name as the next place that promise would
have to be spelled out: *"Every future feature that writes something derived
from browsing (a reading list, a screenshot cache, a favicon store, a download
record) is a fourth, fifth and sixth place that has to know."*

**ADR-0007 gives every Space its own cookie jar.** A cache keyed by host alone
would serve a site visited at work from cache when it is opened at home — and
the *missing* request is itself a signal, the same one that makes browsers
partition HTTP caches.

**Failure is the common case.** A request for `/favicon.ico` on a site that has
none very often answers `200 OK` with the site's own 404 page. Sites serve
4 MB PNGs. Servers time out. The letter badge has to survive all of it.

## Decision

### Where the cache lives: a second SQLite file, `icons.sqlite`, beside the session

Not a table in `session.sqlite`, for two reasons that are both about blast
radius rather than tidiness.

ADR-0006 says a session file that opens but cannot be *read* detaches the
store: the browser runs for the entire session writing nothing, with no
recovery but deleting the file by hand. Icons are the least important bytes in
the profile, the largest, and the only ones that arrive from a stranger.
Putting them in the session file lets the least important data cost the most
important. The inverse holds too, and it is the nicer half: someone whose
session file has gone wrong still gets their icons, because they are somewhere
else. `a_detached_session_still_gets_its_icons` is that half, written down.

And the write shape is wrong. A session save is a full rewrite of every table
inside one transaction, every twenty seconds and on every structural change.
Rewriting every icon the browser has ever seen to record one arriving is
absurd. An icon row is written once, when it arrives, in `Zer0::dispatch`.

A third reason, smaller and real: ADR-0006 says leaving `SCHEMA_VERSION = 1`
requires choosing between migrating and discarding, and that choice is its own
ADR. A separate file with its own version does not spend that.

### What it is keyed by: `(data_store_id, host)`

The cookie jar, not the Space id. Both are stable across a relaunch, but the
two files can disagree — delete `session.sqlite` and Space ids restart at 1,
which would attach a stranger's rows to a new Space. A `data_store_id` is a
UUID minted by the shell and cannot collide.

Keying per jar means two Spaces each fetch their own copy of the same icon.
That is the trade, taken deliberately: a few kilobytes duplicated against a
cross-Space correlation channel closed.

`CloseSpace` deletes the rows, in the same breath as `DeleteDataStore`. ADR-0007
deletes the jar because leaving it orphaned is a leak with no way to reach it
from the interface; the icons are the same leak, smaller.

### The privacy rule: refused at the request, not in the interface

`Action::IconsDeclared` is reported for every page, ephemeral or not — reading
the DOM sends nothing anywhere. Whether it becomes a fetch is the reducer's
call, and for an ephemeral Space the answer is no. No `EngineCommand` is
emitted, so there is nothing for the shell to suppress and no interface rule to
remember.

The same question is asked a second time on the way in: `Action::IconFetched`
for a jar that no non-ephemeral Space claims is dropped. Belt and braces,
because ADR-0023's standing risk is a writer that forgets to ask.

Asking it is now one call. `Browser::records_to_disk(space)` and
`Browser::data_store_records_to_disk(id)` are the shared helper ADR-0023 named
as its debt — *"a shared helper (`Browser::records_to_disk(space)`) with every
writer routed through it would close it"*. This ADR builds it and routes the
new writer through it. The three older writers still spell the branch out by
hand; moving them is a change to their behaviour's blast radius and belongs in
its own commit.

### The fetch itself: anonymous, not through the tab

`EngineCommand::FetchIcon` carries no `TabId`. The shell fetches through a
`URLSession` with no cookie storage, no credential storage, no cache, and
`httpShouldHandleCookies = false`.

The obvious alternative — `fetch()` inside the page's own web view, inheriting
the Space's jar — was rejected twice over. It breaks under any `connect-src`
CSP and under CORS for a cross-origin CDN, which is most large sites. And it is
worse privacy, not better: an icon request carrying a logged-in session cookie
is a request the site can attribute to a person. Carrying none tells the site
strictly less than the page load it follows already did.

Per-Space isolation is kept in the cache instead, where it costs a duplicate
fetch and buys the guarantee.

### What comes back is not trusted

`icons::is_image` checks magic bytes: PNG, JPEG, GIF, BMP, ICO, CUR, WebP, and
SVG — SVG separately, because it is the one image format that is also text and
an HTML error page also starts with `<`. Anything beginning `<!doctype html` or
`<html>` is refused whatever the `Content-Type` said. Over
`MAX_ICON_BYTES` (128 KB) is refused. The shell also stops reading at the
limit, so a 4 MB body costs the limit and not the 4 MB — but the core's check
is the guarantee and the shell's is the courtesy.

### Which icon to ask for

`icons::choose`, in the core, because two platforms must not rank differently:

1. the smallest declared at least 32px — a 16pt badge on a Retina row is 32
   physical pixels, and an icon scaled up from 16 looks worse than the letter
   it replaced;
2. failing that, the largest declared;
3. failing that, one with no declared size;
4. failing that, `/favicon.ico` at the page's origin.

`apple-touch-icon` is collected alongside `rel="icon"` because on a great many
sites it is the only large source on offer. Only `http` and `https` URLs are
followed: `data:`, `file:` and `javascript:` are a page pointing the fetcher
somewhere it has no business going.

### The fallback

`SiteBadge` keeps its letter and gains an `icon:`. The letter is what shows
while a fetch is in flight, for a site with no icon, for a failed fetch, for
bytes that would not decode, and for a page that is not on the web. The icon
crossfades in over it, in the same square at the same size, so the row resolves
rather than flickers. A failed fetch is recorded as an empty row and not
retried for a week, so a site with no favicon is not requested on every
navigation forever.

## Consequences

**What hurts:**

- **N Spaces cost N copies of one icon, and N requests for it.** Small in
  bytes, and it means the second Space you open a site in shows a letter for a
  moment even though the browser already has the picture. That will look like a
  bug to whoever notices it.
- **A profile directory now has two databases and no relationship between
  them.** Delete one, keep the other, and nothing reconciles: rows keyed by a
  `data_store_id` no live Space claims sit there until something happens to
  mention that jar. There is no sweep, no size cap, and no expiry on a
  *successful* row. A long-lived profile's icon cache only grows.
- **The DOM read costs a JavaScript evaluation on every page load.** Small, and
  it is still one more thing running in every page, in the page's own world,
  where the page can shadow anything it likes. Every result is treated as
  hostile, which is the mitigation, not the absence of the cost.
- **Icons are fetched for every page, including one visited once.** A browser
  that opens forty tabs makes up to forty extra requests. They are anonymous,
  they are deduplicated per host and remembered per failure, and they are still
  forty requests that a browser drawing letters did not make.
- **`chrome.tabs.favIconUrl` stays empty.** We hold bytes filed under a host,
  not a URL, and there is nothing honest to put in that field. Extensions that
  read it get nothing rather than something wrong (ADR-0018).
- **Nothing says why a row has no icon.** Never asked, refused, timed out and
  "this site has none" all draw the same letter. That is right for the sidebar
  and it means there is no way, from the interface, to tell a broken fetcher
  from a plain site.
- **The retry window is a week and is not configurable.** A site that adds a
  favicon today is drawn as a letter for up to seven more days.

**What we get:**

- Rows you can find without reading them, which was the whole point.
- A privacy promise kept where the packet leaves from, with a test that fails
  if it moves.
- A cross-Space correlation channel closed before it existed.
- An icon cache that cannot cost anybody their session, and a broken session
  that cannot cost anybody their icons.
- One shared answer to "may this Space be written down", which ADR-0023 asked
  for by name.

## How this regresses

**"I opened a private Space and the site got a hit from me anyway."** The
ephemeral guard in `declare_icons` is dropped — most plausibly by someone
simplifying the function's four early returns into one happy path, which is the
tidier-looking code. `an_ephemeral_space_is_never_told_to_fetch_an_icon` fails
immediately, and it asserts the whole command list is empty rather than
checking for one command, so a partial leak fails it too.
`an_ordinary_space_is_told_to_fetch_its_icon` is the other half of the pair and
exists so that "fix" cannot be "never fetch anything".

**"An ephemeral Space's icons ended up on disk anyway."** The second check —
`data_store_records_to_disk` on the way in — is removed as redundant, and then
some later code path emits `IconFetched` without having been told to.
`an_ephemeral_space_records_nothing_even_if_the_host_hands_us_bytes` is the
lock, and it dispatches exactly that: bytes for a jar nobody asked about.

**"My work Space and my personal Space are the same browser to this site."**
The cache key loses its `data_store_id` — an entirely reasonable-looking
simplification, since the host is what identifies an icon.
`two_spaces_each_fetch_their_own_copy` fails, and `spacesDoNotShare` fails on
the Swift side where the reading happens.

**"I closed a Space and its browsing is still on my disk."**
`forget_data_store` stops being called from `CloseSpace`, or the `dropped` list
stops being drained. `closing_a_space_takes_its_icons_with_it` covers both: it
asserts the row is gone from memory *and* that the deletion was queued for the
disk.

**"Every row went blank."** A site serves HTML, or a 4 MB image, and it is
filed as an icon: `NSImage` returns something with no size and the badge draws
nothing where the letter used to be. `html_served_as_an_icon_is_refused` and
`an_oversized_response_is_refused` are the core's half;
`undecodableBytesFallBack` is the shell's, because bytes can pass a magic-byte
check and still not draw.

**"Every launch re-fetches everything."** The write moved from `dispatch` to
`save`, or the load at startup was dropped. `the_cache_survives_a_relaunch`
opens a real file twice, which is the only shape of that test worth having.

**"The session file went bad and now nothing has an icon either."** Someone
moves the icon table into `session.sqlite` for tidiness.
`a_detached_session_still_gets_its_icons` fails, and it also asserts
`icons.sqlite` exists as a file — so the decision, not just its effect, is
locked.

**And the one with no lock:** the cache grows without bound. Nothing prunes a
successful row, nothing caps the file, and no test can watch a directory get
slowly larger over a year. Declared debt.

## When to revisit

- **When WebKit ships a public favicon API.** The moment there is one, the DOM
  read and the whole fetcher become a compatibility shim and should go. The SDK
  was checked at 26.5 and at 27.0; both have nothing.
- **When the cache needs pruning.** The trigger is a real profile directory,
  measured, not a guess. The likely answer is eviction by last use, which needs
  a column this schema does not have — and adding one to a cache is free, which
  is another small argument for it being its own file.
- **If the per-Space duplication becomes visible** — someone with eight Spaces
  noticing the same icon fetched eight times. A shared cache with a per-Space
  *presence* set would keep the correlation closed while storing one copy, at
  the cost of a more complicated invariant.
- **When a second thing derived from browsing needs persisting.** That is the
  moment to route the three hand-spelled ephemeral branches through
  `records_to_disk` as well, and to stop spelling it a fifth time.
- **If Linux needs a different fetcher.** `FetchIcon` deliberately says nothing
  about how to fetch. A `webkit2gtk` host with a real icon database could
  satisfy the command from it, and the core would not know.
