# ADR-0091: The engine's context menu is amended rather than replaced, and the core decides the amendment

- **Status:** Accepted
- **Date:** 2026-08-10
- **Lock:** `crates/zer0-core/src/page_menu.rs::a_link_to_one_of_our_own_addresses_earns_no_row`, `crates/zer0-core/src/page_menu.rs::a_link_the_system_owns_earns_no_row`, `crates/zer0-core/src/page_menu.rs::a_blob_can_be_opened_and_not_saved`, `crates/zer0-core/src/page_menu.rs::back_and_forward_appear_only_where_there_is_somewhere_to_go`, `crates/zer0-core/src/page_menu.rs::a_selection_under_the_pointer_can_be_searched_for`, `crates/zer0-core/src/page_menu.rs::a_very_long_selection_is_searched_for_by_its_first_characters`, `crates/zer0-core/src/page_menu.rs::an_image_inside_a_link_earns_both_sets_of_rows`, `crates/zer0-core/src/reducer_tests.rs::a_row_the_target_never_earned_is_refused_even_when_it_names_an_address`, `crates/zer0-core/src/reducer_tests.rs::a_row_that_was_never_on_offer_does_nothing`, `crates/zer0-core/src/reducer_tests.rs::a_menu_can_never_open_one_of_our_own_addresses`, `crates/zer0-core/src/reducer_tests.rs::a_link_opened_from_a_menu_lands_in_the_space_the_page_is_in`, `crates/zer0-core/src/reducer_tests.rs::a_link_opened_from_a_menu_lands_beside_the_page_and_in_its_window`, `crates/zer0-core/src/reducer_tests.rs::open_link_in_new_window_really_opens_a_window`, `crates/zer0-core/src/reducer_tests.rs::saving_from_a_menu_goes_through_the_tab_it_was_asked_from`, `crates/zer0-core/src/reducer_tests.rs::searching_for_a_selection_searches_even_when_it_looks_like_an_address`, `crates/zer0-core/src/reducer_tests.rs::searching_for_a_selection_uses_the_configured_engine`, `crates/zer0-core/src/reducer_tests.rs::back_and_forward_from_a_menu_act_on_the_tab_the_menu_was_opened_over`, `crates/zer0-core/src/reducer_tests.rs::a_menu_row_chosen_on_a_tab_that_is_gone_does_nothing`, `crates/zer0-core/src/url_input.rs::searching_for_something_that_looks_like_a_host_still_searches`, `apple/Tests/Zer0ShellTests/PageMenuTests.swift::PageMenuTests/menuIdentifiersAreStillWhatWebKitSets`, `apple/Tests/Zer0ShellTests/PageMenuTests.swift::PageMenuTests/theHitTestIsInHandBeforeTheEngineBuildsItsMenu`, `apple/Tests/Zer0ShellTests/PageMenuTests.swift::PageMenuTests/aLinkGetsANewTabRowAboveTheEnginesNewWindowRow`, `apple/Tests/Zer0ShellTests/PageMenuTests.swift::PageMenuTests/theNewWindowRowIsOursRatherThanTheEngines`, `apple/Tests/Zer0ShellTests/PageMenuTests.swift::PageMenuTests/aLinkToOneOfOurOwnAddressesOffersNothing`, `apple/Tests/Zer0ShellTests/PageMenuTests.swift::PageMenuTests/choosingOpenLinkInNewTabOpensOneThroughTheCore`, `apple/Tests/Zer0ShellTests/PageMenuTests.swift::PageMenuTests/theSearchRowNamesTheConfiguredEngine`, `apple/Tests/Zer0ShellTests/PageMenuTests.swift::PageMenuTests/aSelectionThePointerIsNotOnIsNotOffered`, `apple/Tests/Zer0ShellTests/PageMenuTests.swift::PageMenuTests/thePageGetsBackAndForwardOnlyWhereThereIsSomewhereToGo`

## Context

Right-clicking a page gave whatever `WKWebView` does by default, and nothing in
this repository had ever looked at what that was.

### What the default menu actually contains, measured

Not read off a header and not recalled. A `WKWebView` subclass overriding
`willOpenMenu(_:with:)`, a real page, a synthesised right-click on each thing a
pointer can land on:

| right-clicked | the engine's menu |
| --- | --- |
| the page | **Reload** — and nothing else |
| a link | Open Link, Open Link in New Window, Download Linked File, Copy Link, Share… |
| an image | Open Image in New Window, Download Image, Copy Image, Copy Subject, Look Up, Share… |
| a selection | Look Up "…", Translate "…", Search with Google, Copy, Copy Link with Highlight, Share…, Speech |
| a text field | Look Up, Translate, Search with Google, Cut, Copy, Paste, Spelling and Grammar, Substitutions, Transformations, Font, Speech, Paragraph Direction, Selection Direction, Share… |

Most of that is good and none of it is ours to rebuild. The spelling submenu
alone is a screen of work nobody is going to do better, and the media items,
Look Up, Translate and Share are the system's.

**Four of those rows are wrong in this browser, and one is missing.**

- **There is no "Open Link in New Tab" at all**, anywhere in the engine's menu.
  In a browser whose entire navigation model is a vertical list of tabs, the
  most-used item in every context menu on the web is absent.
- **"Open Link in New Window" opens a tab here.** Invoked, it asks through
  `createWebViewWith` with every `windowFeatures` field `nil`, and ADR-0075 is
  explicit that a page that described no window gets a tab. So the row says one
  thing and does another.
- **"Download Linked File" and "Download Image" reach nothing.** Invoked, no
  `webView(_:navigationAction:didBecome:)`, no `WKDownloadDelegate`, and not
  even the private `_webView:contextMenuDidCreateDownload:` — implemented on a
  probe purely to find out. The same invocation mechanism *did* reach
  `createWebViewWith` for the row beside it, so the instrument can see things
  happening; these two do nothing.
- **"Search with Google" says Google whatever Settings names.** That is this
  interface stating something false about itself, which is ADR-0018's subject.

### The route in, and the one the SDK does not have

An earlier pass measured `menu(for:)` returning `nil` and concluded the menu was
unreadable. `menu(for:)` does return `nil` — the menu is built in the web
content process and arrives afterwards — but that is not the route.

The route is **`NSView.willOpenMenu(_:with:)`**, overridden on a `WKWebView`
subclass. It arrives with the finished menu and the menu is mutable.

`WKUIDelegate`'s context-menu methods are **not** the route on this SDK, which
was read rather than remembered: `contextMenuConfigurationForElement`,
`contextMenuWillPresentForElement`, `contextMenuForElement:willCommitWithAnimator`
and `contextMenuDidEndForElement` are all `API_AVAILABLE(ios(13.0))`, they
answer with a `UIContextMenuConfiguration`, and `WKUIDelegate.h` has no macOS
equivalent. `WKMenuItemIdentifier*` is likewise in no public header on this
machine; the identifiers below were read off a real menu.

### `willOpenMenu` knows nothing about what was clicked

It carries the menu and the event, and no element information at all. The link's
address is not in it. So the target has to come from a hit test in the page,
which is asynchronous — and so is the menu.

## Decision

**The engine's menu is amended, never replaced. The core decides which rows this
browser adds and which it puts right; the host decides where they sit.**

### The gesture is ours, and the ordering is the whole design

`PageView` overrides `rightMouseDown(with:)`, runs a hit test, and forwards the
event to the engine **from inside the hit test's own completion handler**. The
engine has not been asked for a menu when the answer arrives, so `willOpenMenu`
cannot run first. That is a structural guarantee rather than a fast path:
starting both and hoping the hit test wins is a race that is usually fine, and
"usually" is what this project has learned not to build on.

Measured over twelve gestures in the suite: twelve menus, twelve with the target
already in hand.

Replaying a stale `NSEvent` works — measured, a right-click on a text field
forwarded this way still produces the engine's full editing menu, spelling
submenu and all, and the page keeps answering afterwards.

### The core decides the rows, and it decides only ours

`page_menu::additions_for(&PageTarget) -> Vec<PageMenuItem>` is a pure function
with tests and no window. It returns **only what this browser adds or corrects**,
because the engine's menu is the engine's: a `webkit2gtk` host has a different
list to sit beside, and the one thing both hosts must answer identically is what
*zer0* offers.

`PageTarget` is reported and not interpreted, exactly as `WindowRequest` is: the
host runs the hit test in its own vocabulary and what it adds up to is decided
here. `can_go_back` and `can_go_forward` are on it because only the engine holds
a back-forward list.

Eight rows, and every one is either missing from the engine's menu or measured
to be wrong in ours:

| row | why it exists |
| --- | --- |
| Open Link in New Tab | the engine has none |
| Open Link in New Window | the engine's opens a tab |
| Download Linked File | the engine's reaches nothing |
| Open Image in New Tab | the engine has none |
| Download Image | the engine's reaches nothing |
| Search *engine* for "…" | the engine's names Google regardless |
| Back, Forward | the engine's page menu is one row |

**Nothing else.** Not Inspect Element (⌥⌘I, ADR-0067), not View Source, not
Print (⌘P), not Save Page As (⌘S), not Bookmark (⌘D, ADR-0061), not Reload
Ignoring Cache, not Open in New Private Window. A twenty-item menu is what every
other browser has and none of them is proud of it, and a row that duplicates a
chord somebody's fingers already know earns nothing.

### Back and Forward are omitted rather than greyed out

A disabled row is a control earning its place by telling you about a road you
cannot take. The menu is short enough that nothing depends on a row staying in
one position, and omitting keeps the host free of a third state to draw. The
counter-argument is real — Chrome and Safari both grey them — and it is
recorded here rather than left implicit.

### The row travels back with the target it was drawn for

`Action::ChosePageMenuItem { tab, item, target }`. The reducer checks the item
against `additions_for(&target)` before acting, so a row that was never on offer
is refused rather than performed. That is not defensive noise: it is the only
thing that stops a `blob:` reaching the download machinery and a Back with
nowhere to go reaching the engine, and it was written *after* the check was
broken on purpose and the suite stayed green.

Everything the row does then goes down a road that already exists —
`Action::OpenTab` for a tab (routing and all, ADR-0026),
`Browser::add_window` for a window, `EngineCommand::StartDownload` for a file
(ADR-0027), `url_input::search_for` for a search. No second road, and no search
URL spelled twice.

**The space is the tab's and never `active_space`, and the key window moves
first.** Both are ADR-0075's lessons applied to the one other place a tab is
opened from a page.

### Nothing about one of our own addresses is offered

A link claiming `zer0://` earns no row of ours, and the engine's four link rows
are removed. The navigation door already refuses every one of them (ADR-0054),
so they are offers to travel a road that dead-ends — and a row that cannot act
earns no place. Two locks on one rule, in the core and in the host.

### What "Search for" means

`url_input::search_for` rather than `resolve`. The row says *search*, so
selecting the words `example.com` and choosing it must search for them; resolving
them the way the command bar resolves typing would navigate somewhere the row
did not offer. The two questions are different and now have two functions, with
one spelling of the URL between them.

The selection is offered **only when the pointer is on it**, checked against the
range's own client rectangles. A menu drawn this way never lets the engine clear
the selection, so without that check a selection made half a screen away would
follow the pointer around the page forever.

A selection longer than 512 characters is searched for by its first 512. Stated,
not silent.

## Consequences

**Every web view is a `PageView`.** `HostedWebView`'s initialiser will not take a
plain `WKWebView`, so a view that silently has no menu of ours cannot be hosted.
A guarantee is structural or it is not a guarantee.

**`PageView` is not `final`,** and that is a cost. An engine-built menu tracks
modally, so the only way a test can read one is from inside `willOpenMenu`, and
the only way in is a subclass. Watching `NSMenu.didBeginTrackingNotification`
and cancelling from the handler was tried first and hangs.

**The row identifiers are undocumented.** `WKMenuItemIdentifierOpenLinkInNewWindow`
and its five neighbours appear in no public header. If WebKit renames one, our
row lands at the top of the menu instead of in its place — and, for the four
replacements, the engine's wrong row survives beside ours.
`menuIdentifiersAreStillWhatWebKitSets` is the test that notices.

**Copying an image is still the engine's.** "Copy Image" was left exactly as it
is. A row of our own would have to fetch the bytes through the space's cookie
jar and put decoded image data on the pasteboard, which is a second download
machine — and ADR-0027 says there is one.

**A right-click no longer collapses a selection.** The engine used to clear it
as part of building its menu; the gesture is ours now, so it does not. That is
better on the common path and it is why the selection has to be tested for
containment.

## How this regresses

**Somebody starts the hit test and the menu together.** It reads as an obvious
win — two round trips in flight instead of one after the other — and it is
correct almost every time. When it is not, the menu opens with the previous
element's rows on it, which is a link to the wrong address under somebody's
pointer. `theHitTestIsInHandBeforeTheEngineBuildsItsMenu` asks twelve times;
broken on purpose, it went red on the first.

**Somebody deletes the check against `additions_for`.** It looks like belt and
braces, because every arm below it already asks whether there is a URL. It is
not: it is the only thing that refuses a `blob:` to the download machinery and a
Back with no history. Broken on purpose, the suite stayed green — which is why
`a_row_the_target_never_earned_is_refused_even_when_it_names_an_address` exists
and why the other two tests beside it are not the lock they look like.

**Somebody uses `resolve` for the search row** because the command bar does, and
`search_for` looks like a duplicate of it. Selecting `example.com` then navigates
to it, from a row that said "Search". One line, and
`searching_for_a_selection_searches_even_when_it_looks_like_an_address` is the
fence.

**Somebody reads the space off `active_space`.** The same line ADR-0075 named,
in the second place it can be written, and the same failure: a link followed from
a private page writes that session's cookies to disk.

**Somebody replaces the menu instead of amending it.** It is tidier — one list,
built in one place, no undocumented identifiers to anchor against — and it
silently deletes spelling correction, Look Up, Translate, Share, Picture in
Picture and the media items. No test can catch that, because the menu it would
assert against is the one being written. It is written here because that is the
only place it can be.

**Somebody drops the removal of the engine's link rows for `zer0://`.** It looks
redundant, because the navigation door refuses them anyway. What a person sees is
a menu offering four things, choosing any of which does nothing.

## When to revisit

- **When "Copy Image" should be ours.** It needs a fetch through the space's
  cookie jar and a pasteboard write of decoded bytes. That is ADR-0027's
  machinery pointed somewhere new, not a wider version of this decision.
- **When a text field's menu should carry anything of ours.** Today an editable
  target gets the engine's menu untouched, which is right — Cut, Copy, Paste and
  the spelling submenu are the whole of what anybody wants there — and the
  moment a password manager or a saved-login row belongs on it (ADR-0064) that
  stops being obvious.
- **If `WKMenuItemIdentifier*` becomes public API.** The anchors stop being
  undocumented strings and `menuIdentifiersAreStillWhatWebKitSets` becomes a
  compile-time fact instead of a test.
- **When Back and Forward should be greyed rather than absent.** If somebody
  reaches for a row by position and finds a different one there, the argument
  above was wrong and this is where to say so.
- **If a second shell arrives.** `additions_for` crosses unchanged; the
  placement table does not, and `webkit2gtk`'s menu will need its own.
