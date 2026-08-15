# ADR-0063: History and downloads are pages, and the panes they came from are gone

- **Status:** Accepted
- **Date:** 2026-07-09
- **Lock:** `crates/zer0-core/src/internal_url.rs::an_address_decides_its_own_shape_and_the_scheme_does_not`, `crates/zer0-core/src/internal_url.rs::no_address_in_the_scheme_does_nothing`, `crates/zer0-core/src/reducer_tests.rs::history_and_downloads_commit_into_the_tab_that_asked_for_them`, `crates/zer0-core/src/reducer_tests.rs::the_chord_opens_a_page_beside_your_work_rather_than_over_it`, `crates/zer0-core/src/reducer_tests.rs::pressing_the_chord_again_goes_back_to_the_page_it_opened`, `crates/zer0-core/src/reducer_tests.rs::a_window_address_still_raises_its_window_when_it_is_asked_for_by_command`, `crates/zer0-core/src/reducer_tests.rs::no_address_in_the_scheme_is_dead`, `crates/zer0-core/src/command_bar.rs::the_page_ranks_history_exactly_as_the_command_bar_does`, `crates/zer0-core/src/command_bar.rs::an_empty_search_is_the_whole_list_newest_first`, `crates/zer0-core/src/command_bar.rs::a_search_that_matches_nothing_returns_nothing`, `crates/zer0-core/src/history.rs::a_range_clears_only_what_falls_inside_it`, `crates/zer0-core/src/history.rs::a_range_judges_an_entry_by_its_last_visit`, `crates/zer0-core/src/history.rs::a_span_reaches_back_exactly_as_far_as_it_says`, `apple/Tests/Zer0ShellTests/HistoryAndDownloadPageTests.swift::HistoryAndDownloadPageTests/settingsHasNeitherPane`, `apple/Tests/Zer0ShellTests/HistoryAndDownloadPageTests.swift::HistoryAndDownloadPageTests/noSettingsPaneDrawsEither`, `apple/Tests/Zer0ShellTests/HistoryAndDownloadPageTests.swift::HistoryAndDownloadPageTests/clearingHistoryHasOneHome`, `apple/Tests/Zer0ShellTests/HistoryAndDownloadPageTests.swift::HistoryAndDownloadPageTests/historyOpensAsATab`, `apple/Tests/Zer0ShellTests/HistoryAndDownloadPageTests.swift::HistoryAndDownloadPageTests/downloadsOpensAsATab`, `apple/Tests/Zer0ShellTests/HistoryAndDownloadPageTests.swift::HistoryAndDownloadPageTests/pressingItTwiceReturnsToThePage`, `apple/Tests/Zer0ShellTests/HistoryAndDownloadPageTests.swift::HistoryAndDownloadPageTests/searchIsTheCoresRanking`, `apple/Tests/Zer0ShellTests/HistoryAndDownloadPageTests.swift::HistoryAndDownloadPageTests/clearingASpanReachesTheCore`, `apple/Tests/Zer0ShellTests/HistoryAndDownloadPageTests.swift::HistoryAndDownloadPageTests/forgettingOnePageReachesTheCore`, `apple/Tests/Zer0ShellTests/HistoryAndDownloadPageTests.swift::HistoryAndDownloadPageTests/findOnTheHistoryPageAsksThePage`, `apple/Tests/Zer0ShellTests/HistoryAndDownloadPageTests.swift::HistoryAndDownloadPageTests/aPageCommandDoesNotCrossIntoAnAuxiliaryWindow`, `apple/Tests/Zer0ShellTests/InternalPageTests.swift::InternalPageTests/anAddressDecidesWhetherItIsAPageOrAWindow`, `apple/Tests/Zer0ShellTests/InternalPageTests.swift::InternalPageTests/everyPageAddressCommitsIntoTheTabThatWentToIt`

## Context

ADR-0054 built `zer0://` and routed four addresses through it. Two of them were
honest placeholders: `zer0://history` and `zer0://downloads` raised the Settings
window at a pane, because a pane was where both had been built.

That ADR said in as many words what would have to happen next, and it named the
part that needed deciding rather than typing:

> **When history or downloads becomes a page.** Both are panes inside the
> Settings window today. When either becomes a page, the pane it came from has
> to go — otherwise the browser has two screens for one thing, which this
> project treats as a defect. That is a product decision and it is inherited by
> whoever builds the page, not settled here.

So the shape question was already answered and only the cost was open. The
argument for the shape is what the two things *are*. A history is four hundred
rows you search, scroll, and walk with the keyboard. A settings window is a
place you go to change a value and then close. Putting the first inside the
second cost both of them: the list got a 640-point column inside an 880-point
window it could not leave, no address, no ⌘W, no place in the sidebar, no way
back after a restart — and Settings got two panes that were not settings.

The second question is where the searching lives. `command_bar::suggest` had
already ranked history for years, with a frecency bonus deliberately capped
below match scores for the reason ADR-0015 gives. A history page is asking that
exact question again.

## Decision

**`zer0://history` and `zer0://downloads` are pages, and the Settings panes are
deleted.**

### Both are `Effect::Page`, in the one place that decides

`InternalAddress::effect()` gained no machinery: two arms moved. Everything that
follows — the address committing into the tab, the sidebar row, the title, ⌘W,
the session bringing it back — was already built for chat and cost nothing here.
Settings is now the only `Effect::Window` in the scheme, which is the honest
end state: it is the one surface you open beside your work and then close.

**Nothing was told to WebKit.** ADR-0054's security position is untouched and it
is untouched *by construction*: these pages are `NSView`s in a tab, there is no
scheme handler, no document, no origin and nothing for a hostile page to reach
through. That was the reason the scheme is a core concept rather than a
`WKURLSchemeHandler`, and it is the reason turning two addresses into two pages
was a change to one match arm rather than a change to a security surface.

### The chord opens a page; typing the address navigates one

`Action::OpenInternalPage { address }` is new, and it is not `NavigateTo` with a
URL in it. Typing `zer0://history` means *this tab, now* — that is what an
address bar is. Pressing ⌘Y means "show me my history", and a browser that
answered by discarding the page you were reading would be obeying you by losing
your place. So the chord opens a tab, or returns to the tab already showing that
address, exactly as ⌘E does for a conversation. The reuse is not an optimisation:
two tabs showing one history are two views of one state, and the one being read
is always the stale one.

It carries an `InternalAddress` rather than a URL string, so no shell ever spells
one of our addresses out for itself.

`show_internal_page` still asks `effect()` rather than assuming a page, so
`zer0://settings` dispatched as a command still raises the window. A fifth
address cannot arrive here and quietly become a tab.

### Search is `command_bar`'s ranking, called by both

`command_bar::search_history` is the one ranking of history there is.
`suggest` calls it; the page calls it through the FFI. The extraction was
mechanical — the loop that was inside `suggest` became a function — and that is
the point: a page with a search of its own would have been eight lines of
`filter { contains }` that nobody would ever have reported, because nobody
notices an ordering that is only slightly wrong.

Empty query is not a ranking question, so it is not answered by the ranking:
each caller answers it in its own terms. The bar offers where you were; the page
shows the whole list, newest first.

### Grouping by day earns its space, and only when there is no query

With no query the order *is* time, and a header every so often is what turns
four hundred rows into "yesterday afternoon" — the question people actually
bring to a history. With a query the order is how well each row answers what was
typed, and a day header over that would assert a second ordering that is not
there. So: grouped when browsing, flat when searching, and each row carries as
much of its timestamp as the surrounding context does not already say.

The grouping runs in the shell and the ordering does not. Which day a moment
falls in is a question about somebody's calendar and timezone; the core has
neither and should not grow one to draw a header. It never re-sorts — it only
says where one run of the core's order ends.

### Clearing takes a span, and there is exactly one of it

`HistoryRange` is `LastHour`, `LastDay`, `Everything`, and `Everything` is a
span like the others: one path, `History::forget_since`, with a number on it.
Spans and not calendar days, because "today" is a question about a timezone and
this is a *delete* — the arithmetic that decides how much is destroyed should
not move at midnight or differ by locale.

**"Clear History…" left the Privacy pane.** It now sits beside the list it
clears, and it is the same `DestructiveButton` component, so the pairing that
component exists to enforce — a red label always carries an asking — could not
be dropped on the way. The confirmation restates the span, so nothing is
discarded without the amount being said one more time, and the control opens
aimed at the narrowest span rather than the widest.

### The downloads rows were not rewritten

ADR-0027 settled what a download row may say: a spinner rather than a bar when
no length was sent, a failure louder than a success, one prominent action per
screen because prominence is the promise that Return does this. None of that got
better by being on a page, so none of it was touched. The page added a frame, a
scroll, and the way back to the folder — which is where the files actually are.

## Consequences

**What this costs:**

- **A third internal page to write again for a second shell.** ADR-0054 priced
  this and the price has not changed; there are now three of them rather than
  one.
- **⌘F on the downloads page does nothing.** History has a search and ⌘F means
  it. Downloads does not, and rather than open WebKit's find bar over a page
  with no document — which would report "not found" about a screen full of rows
  — nothing opens. Silence is the honest outcome, but it is still a chord that
  appears to be ignored, and it is the weakest part of this change.
- **`Action` grew a variant that opens a tab, next to one that navigates one.**
  `OpenInternalPage` and `NavigateTo` will look redundant to somebody reading
  them side by side, and collapsing them would silently make ⌘Y take the page
  you were reading.
- **Two commands stopped crossing into the Settings window.** ⌘Y from Settings
  used to bring a window to the front; now it would open a tab behind that
  window, so it is refused there. That is ADR-0053's rule applied correctly, and
  it is still a chord that stopped working in one place it used to work.
- **The Privacy pane's Data section is down to one row.** Clearing history was
  half of what it held.
- **The page re-reads history from the core on every body evaluation.** The
  pane did too, so this is not new, but a list is now on screen for as long as a
  tab rather than as long as a settings window.

**What we get:**

- History and downloads can be addressed, linked, pinned, split, closed with ⌘W
  and restored after a quit, and none of that was built.
- One screen per thing. There is no second history in the browser, so there is
  no stale one.
- One ranking of history, called from two places.
- One way to clear history, with a span on it.
- Settings is settings again.

## How this regresses

**"There are two history screens again."** The likeliest route is somebody
restoring the pane because a `SettingsSection` case reads as harmless.
`settingsHasNeitherPane` holds the enum and `noSettingsPaneDrawsEither` scans
the sources for the view types by name — the second one exists because the enum
can lose a case while the pane it drew sits in the file waiting to be re-wired.
`clearingHistoryHasOneHome` holds the destructive half separately, because a
second "Clear History…" is worse than a second list.

**"⌘Y blanked the page I was reading."** Somebody notices that
`OpenInternalPage` and `NavigateTo` both end up at the same address and unifies
them. `the_chord_opens_a_page_beside_your_work_rather_than_over_it` is the
fence, and `historyOpensAsATab` covers the same ground through the shell.

**"⌘Y opened four history tabs."** The reuse check in `show_internal_page` is
the kind of lookup that looks like a needless scan of every tab.
`pressing_the_chord_again_goes_back_to_the_page_it_opened` is written from
another tab entirely, so it cannot pass by accident on "it was already active".

**"The history page found different pages than the command bar."** A shell-side
`filter` is the tidier-looking thing to write and would leave every Rust test
green. `searchIsTheCoresRanking` is therefore asserted *through the shell*, on a
weak-match-visited-often against a strong-match-visited-once pair — the case a
substring filter or an uncapped frecency bonus orders differently.
`the_page_ranks_history_exactly_as_the_command_bar_does` holds the same
agreement in the core, on the observable order rather than on the call, so it
survives either side being rewritten.

**"Clear the last hour wiped everything."** `forget_since` keeps what is *older*
than the cutoff, and the comparison is one character from being backwards.
`a_range_clears_only_what_falls_inside_it` walks all three spans over one
history, and `a_span_reaches_back_exactly_as_far_as_it_says` pins the arithmetic
so a span cannot quietly grow.

**"Settings opened in a tab."** Somebody makes every address a page because the
enum is simpler with one shape.
`a_window_address_still_raises_its_window_when_it_is_asked_for_by_command` and
ADR-0054's `aWindowAddressRaisesAWindowAndLeavesTheTabAlone` hold both doors.

**And the one no test catches:** the day-grouping runs on `Calendar.current`, so
a machine whose timezone changes while the page is open draws the old day
boundaries until the view is rebuilt. Nothing is wrong with the data and nothing
is lost; the header is briefly a lie about which day a row belongs to.

## When to revisit

- **When downloads wants searching.** It has no search today because the core
  has no ranking for a download and a substring filter written in the shell
  would be exactly the second opinion this ADR removed from history. If the list
  grows to the point where scrolling it is the complaint, the answer is a
  `downloads::search` in the core reusing the same scorer, and ⌘F on that page
  then means what it means on the history page.
- **When history stops fitting in memory.** `search_history` ranks every entry
  on every keystroke. That is what the command bar already did and it is bounded
  by `MAX_SCAN_CHARS` per candidate, not by the number of candidates. A history
  large enough to make typing stutter is a paging question, and it is a question
  about the store rather than about this page.
- **If Settings ever becomes a page.** It is the last `Effect::Window` in the
  scheme, and the argument for keeping it a window — you open it beside your
  work and then close it — is a claim about how people use it rather than a
  structural fact. If that turns out to be wrong, `Effect` has one inhabitant
  left and is a type worth deleting rather than an arm worth moving.
- **When an internal page wants remote content.** Unchanged from ADR-0054, and
  now with three pages that could want it. A history row already knows a site's
  icon; the day one of these pages loads anything over the network, every
  question ADR-0054 answered by construction has to be asked again, and that is
  a new ADR rather than a change to either of these.
