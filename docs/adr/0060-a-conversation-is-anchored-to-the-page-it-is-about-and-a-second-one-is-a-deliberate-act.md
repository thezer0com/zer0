# ADR-0060: A conversation is anchored to the page it is about, and a second one is a deliberate act

- **Status:** Accepted — supersedes the scope half of ADR-0049
- **Date:** 2026-06-29
- **Lock:** `crates/zer0-core/src/chat_tests.rs::opening_a_page_discussed_before_brings_the_thread_back`, `crates/zer0-core/src/chat_tests.rs::two_tabs_on_one_page_are_one_thread`, `crates/zer0-core/src/chat_tests.rs::a_page_addressed_two_ways_is_one_thread`, `crates/zer0-core/src/chat_tests.rs::a_query_string_is_part_of_the_page`, `crates/zer0-core/src/chat_tests.rs::the_same_page_in_another_space_is_another_thread`, `crates/zer0-core/src/chat_tests.rs::a_page_with_no_address_worth_keeping_asks_about_no_page`, `crates/zer0-core/src/chat_tests.rs::a_second_thread_about_one_page_is_asked_for_and_does_not_steal_the_first`, `crates/zer0-core/src/chat_tests.rs::where_a_page_has_several_the_most_recent_opens_and_the_rest_are_listed`, `crates/zer0-core/src/chat_tests.rs::a_thread_whose_page_is_not_open_reads_nothing_rather_than_reading_something_else`, `crates/zer0-core/src/chat_tests.rs::closing_the_tab_keeps_the_thread_it_was_about`, `crates/zer0-core/src/chat_tests.rs::navigating_the_tab_leaves_the_thread_where_its_page_is`, `crates/zer0-core/src/storable_tests.rs::an_ephemeral_space_writes_down_no_address_a_thread_was_anchored_to`, `crates/zer0-core/src/storable_tests.rs::an_ephemeral_space_leaves_no_conversation_behind`, `crates/zer0-core/src/storable_tests.rs::what_a_conversation_is_about_survives_a_round_trip`, `crates/zer0-core/src/store_tests.rs::a_thread_whose_address_is_missing_from_the_file_is_dropped_rather_than_repaired`, `crates/zer0-core/src/store_tests.rs::a_thread_whose_address_this_build_cannot_read_is_dropped_too`, `apple/Tests/Zer0ShellTests/InternalPageTests.swift::InternalPageTests/aPageDiscussedBeforeGivesItsConversationBack`

## Context

ADR-0049 decided a conversation belongs to a tab or to a space, and argued
against the space at some length. It never considered the page. That reads as
an oversight and it was not: at the time chat had no screen at all, and a tab
was the only handle in the browser that reliably meant "a thing I am doing".

What that bought is a browser where the chord works and nothing accumulates.
You press ⌘E on a page, ask three questions, close the tab, and the whole
exchange is gone — not archived, gone. Come back to the same page tomorrow and
the browser has never heard of it. Every one of those threads was work, and
none of it was retrievable by the one gesture anybody would try.

The owner's sentence for it is the shortest version of this ADR:

> por padrão ao abrir um chat em pagina que já abrimos devemos trazer tudo que
> já conversamos com aquela pagina/url

Two other things had to be true before this was worth doing, and both now are.
ADR-0054 gave a conversation an address (`zer0://chat?conversation=7`) and
shaped it, deliberately, to survive exactly this change. ADR-0045 moved "what
may be written down" into a projection above every backend, which is where a
rule about *URLs* in the chat record has to live if it is going to be a
guarantee rather than a reminder.

The moment a thread is keyed on a URL, three questions arrive that a
tab-scoped thread never had to answer, and none of them has a safe default.

**What counts as the same page.** Too loose and two conversations about
unrelated things merge; too strict and the thread you want never comes back.
Both are felt on the first day.

**What a URL carries.** Anchoring means the address is part of a conversation's
identity, so it is written down whether or not anything was ever captured. Some
URLs carry secrets — magic links, password resets, signed URLs. History already
holds URLs, so this is not a new class of exposure, but it is a second copy in
a second place, and "it was already leaking" is not an argument.

**What a thread means when the page is gone.** A tab-scoped thread could not
outlive its subject. A page-scoped one routinely will.

## Decision

**A conversation is about a page, and it outlives every tab that ever showed
it.** `ConversationScope::Tab { tab }` is replaced by
`ConversationScope::Page { space, page }`.

### The same page, in one rule

`PageAnchor::of(&str)` is the only place in the codebase that decides whether
two addresses are one page. It is built out of conventions this codebase
already has, because a third convention for normalising a URL is a third thing
to be inconsistent with:

- **The host is normalised the way `routing.rs` normalises one** — parsed with
  `url`, so case and IDN spelling are settled, credentials are gone, and a
  default port with them.
- **A fragment and a trailing slash are punctuation**, which is the sentence
  `internal_url.rs` already writes about `zer0://chat/` and
  `zer0://chat#anything`.
- **The query string is part of the address.** This clause is new, and it is
  the one that decides the hard cases.

Nothing is folded that the site itself has not already folded. `http` is not
rewritten to `https` and `www.` is not stripped, because the address anchored
here is the one a navigation *committed* — which is the site's own
canonicalisation, after its own redirects. Guessing at either would key threads
on an address nobody ever visited.

What that decides, in both directions:

| Two addresses | Same thread? |
|---|---|
| `example.com/Docs` and `EXAMPLE.com/Docs` | yes — host case is not the page |
| `example.com/Docs` and `example.com/Docs/` | yes — punctuation |
| `example.com/Docs#install` and `…#usage` | yes — one document, two places in it |
| `example.com/Docs` and `example.com:443/Docs` | yes — the default port is not an address |
| `example.com/Docs` and `reader:pw@example.com/Docs` | yes — credentials are not the page |
| `search/?q=rust&page=1` and `…&page=2` | **no** — different pages of results |
| `reports?user=alice` and `reports?user=bob` | **no** — different subjects entirely |
| `avelino/zer0` and `avelino/zer0?tab=readme` | **no** — and this one is a cost |

The last row is the price and it is worth naming plainly: on a site that uses
the query string for a tab strip, one page can end up with two threads. We took
that over the alternative because the two failures are not symmetric. **A
thread that did not come back is visible and one gesture from being fixed** —
the list of conversations about a page is right there. **A thread that came
back about the wrong thing reads as the model being confused, and nobody files
that.** It is the same asymmetry ADR-0049 named when it refused a per-space
thread, applied one level down.

### The address decides the space, and the space still decides everything

`Page` carries its `SpaceId` outright rather than finding one through a tab.
The same URL open in two spaces is two threads, because a conversation holds
typed questions and page text, which is precisely the material ADR-0007 gives
every space its own cookie jar for. Anchoring by address must not become the
side door that carries a work page into a personal thread.

Carrying the space also makes `ConversationScope::space()` **total**. That is
not tidiness: it is what lets the projection decide whether a thread may be
written down without a lookup that can fail. Under ADR-0049 the space was found
by hopping through a tab, and a thread whose tab had closed since the last
dispatch resolved to no space at all — which happened to fail closed. Now there
is no arrangement of open and closed tabs that routes around the check.

### Not every tab holds a page

`PageAnchor::of` anchors `http`, `https` and `file` and refuses everything
else. An allowlist rather than a blocklist, because a blocklist fails silently:
a scheme nobody thought of gets anchored, and whatever it carries is written to
disk under an address.

So `data:`, `blob:`, `about:blank`, a blank tab and one of the browser's own
`zer0://` pages all resolve to the space's own thread — "about no page in
particular", which is what ADR-0049 already built for the command bar. The last
of those is worth pointing at: ADR-0054 kept internal pages out of chat with a
hand-written guard in `page_worth_attaching`, and that rule is now a scheme
that cannot be anchored. Same rule, nothing left to delete.

### One page, several threads, and the second one is asked for

`Chat::ensure` hands back the **most recent** thread for a subject and mints one
only when there is none. `Chat::start` is the only thing that mints a second,
and the only action that reaches it is `StartAnotherConversation { like }`.

Most recent means **when anything last happened**, derived from the messages
rather than stored beside them: a stored field can disagree with the rows it was
saved with, and what that disagreement decides is which of somebody's
conversations opens when they press ⌘E. Ties break on the id, descending.

Where a page has several, the most recent opens and the rest are one keystroke
away, on a screen of their own. That screen is in the tab, not in a menu: it is
the moment the feature shows what it is, and a dropdown would file it under
housekeeping.

### What is written down, and what is deliberately not

**Written down: the normalised URL, in plain text, in `conversation_pages`.**
Said plainly rather than hidden behind a digest. A hash would buy nothing —
the same thread's transcript already stores the page address beside it, which
is ADR-0049's decision and unchanged — and it would cost the list of
conversations the ability to say which page each one is about. Storing
something people cannot see is worse than storing something they can.

**Not written down, structurally:**

- **A password in userinfo.** An anchor is assembled from scheme, host, port,
  path and query. Userinfo is not read, so there is no line to forget to
  delete.
- **A token in a fragment.** Dropped for the reason above, which takes the
  OAuth implicit flow's `#access_token=…` with it — the single most common
  place a credential hides in a URL.
- **Anything at all from an ephemeral space.** Extended in the projection, where
  ADR-0023's promise already lives, and now stronger than it was: the URL cannot
  reach a backend without passing the space that decides whether it may.
- **A `data:` URL's payload**, because a `data:` URL is not anchorable.

**And what is not covered, stated rather than implied:** a signed URL with a
token in its query string *is* written down. That is the direct cost of the
query being part of the address, it is the same plain text history already holds
it in, and clearing the conversation is what removes it. A person who wants a
page discussed without its address kept has one honest answer today — an
ephemeral space — and that is a gap rather than a solution.

### A thread that cannot see its page says so

When a question is sent, the browser looks for a tab in the thread's space
showing the thread's page. If there is none, **nothing is read**. It does not
fall back to whatever tab is in front of somebody: that would answer about a
page nobody mentioned, which is the failure `ChatSubject::Nothing` exists for.

The screen says it out loud rather than letting it be discovered. A thread about
a page that is not open carries one line saying so, and its empty state says the
next question will go out unaccompanied. The address is a fact; what is at that
address today is not, and the interface asserts only the first (ADR-0018).

### Closing a tab stops the reply and forgets nothing

Closing the tab that is *showing* a conversation cancels the reply in flight and
the tools it had running — a reply arriving into a view nobody has any more is
bytes somebody is paying for, which was always the real argument. The thread
itself stays. Closing the **space** still ends every thread in it, because there
is nowhere left to reach one from.

## Consequences

**What this costs, honestly:**

- **`?tab=readme` is a second thread.** Named above; it is the price of the
  query string being part of the address, and the screen listing a page's
  threads is the mitigation rather than a fix.
- **A signed URL ends up in the chat table.** Also named above. The projection
  cannot tell a session token from a page number, and a blocklist of
  credential-shaped parameter names would be a wish with a false sense of
  safety attached.
- **`ConversationScope` is no longer `Copy`.** It holds a `String`. Every call
  site that moved a scope now clones one, which is a small cost paid on paths
  that already clone transcripts.
- **Threads accumulate where they used to evaporate.** ADR-0049's cap of 200
  conversations was written for a world where closing a tab freed one; it now
  has to do that work alone, and the oldest thread goes without anybody being
  told. That bound has not been re-examined against the new lifetime.
- **The list is per page, and there is no way to see all of them.** Somebody
  with forty threads can only reach one by opening the page it is about, or by
  restoring the tab. A history-shaped screen for conversations is a real gap and
  is not built.
- **A page whose URL changes takes its thread with it.** A site that adds a
  tracking parameter to its own canonical URL, or moves from a query to a path,
  strands every thread anchored to the old spelling. Nothing detects that and
  nothing could.
- **A `file://` thread writes a local path down.** Downloads already store paths
  and history already records `file://` visits, so this is consistent rather
  than new — but it is a filename on disk that somebody may not expect.

**What we get:**

- The thing the owner asked for, by the gesture he would try: open a page you
  have discussed, press ⌘E, and the conversation is there.
- One rule for "the same page", in one function, with a test in each direction.
- The ephemeral promise held by a projection whose space lookup can no longer
  fail.
- Every rule above is tested with no window, no network and no provider.

## How this regresses

**"It forgot everything again."** `Chat::ensure` starts calling `Chat::start`
unconditionally — most plausibly while making "new conversation" work, because
minting is what that button does and `ensure` is the function next to it. The
symptom is a browser that looks exactly like the one before this ADR, which is
the reason nobody would notice from the code.
`opening_a_page_discussed_before_brings_the_thread_back` goes red, and it is
written end to end — the tab is closed and the browser goes elsewhere before the
page is opened again — so a version that only works while the tab is still up
does not pass it.

**"It answered about the wrong page."** Normalisation loosens: someone drops the
query string because `?tab=readme` annoyed them, or strips `www.` because it
looks like noise. `a_query_string_is_part_of_the_page` holds one direction and
`a_page_addressed_two_ways_is_one_thread` holds the other, and they have to be
read as a pair — either one alone can be satisfied by a rule that is wrong the
other way.

**"My work page turned up in a personal thread."** `Page` stops carrying its
space, or the space stops being compared, during a change that makes the anchor
"just a URL" — which is the tidier-looking type.
`the_same_page_in_another_space_is_another_thread` is the fence.

**"My private window kept the address of everything I read."** The projection's
ephemeral check moves, or is written against messages rather than the scope —
easy to do, because before this ADR the only URL in a conversation *was* in a
message. `an_ephemeral_space_writes_down_no_address_a_thread_was_anchored_to`
asserts over the whole projected conversation rather than one field, and it
first proves an ordinary space *does* write the address down, so an empty result
is the promise being kept rather than the assertion being blind.

**"It read a page I never mentioned."** The "no tab showing this page" case
grows a fallback to the active tab, because a thread that reads nothing feels
broken. It is not broken; it is honest.
`a_thread_whose_page_is_not_open_reads_nothing_rather_than_reading_something_else`
puts a bank statement in the active tab and demands silence.

**"⌘E opened a thread I had never seen."** The ordering flips, or starts using
`created_at_ms` because it is the field that is stored.
`where_a_page_has_several_the_most_recent_opens_and_the_rest_are_listed` speaks
in the *oldest* thread last and demands it come back first.

**"Closing the tab deleted my conversation."** `close_tabs` goes back to
`end_conversations` during a refactor of tab teardown — a function with nothing
chat-shaped in its name, which is how ADR-0049 lost this once already in the
other direction. `closing_the_tab_keeps_the_thread_it_was_about` is the lock.

**Which of ADR-0049's sentences are now false.** Its decision text is left as
written; these are the parts this ADR replaces.

- *"`ConversationScope` has two variants: `Tab` … and `Space`."* — `Tab` is
  gone. The two are `Page` and `Space`.
- *"Pressing ⌘E twice on the same tab reopens the same thread; pressing it on a
  different tab opens a different one."* — the second clause is false when both
  tabs show the same page, which is now one thread.
- *"Navigating the tab does not start a new thread: you kept the tab, so you
  kept the subject — the new page is attached to the thread you already
  have."* — false in both halves. Navigating leaves the thread with the page it
  is about, and the new page gets a thread of its own.
- *"Why a tab and not a space."* — the argument stands (an unbounded thread
  made of every page you glanced at is still the thing to avoid) but its
  conclusion does not: the unit is the page, which bounds context more tightly
  than a tab did.
- *"A conversation dies with what it is about. Closing the tab ends the thread,
  cancels the reply in flight, and cancels the tools it had running."* — the
  first sentence is still true and now means something else, because what a
  conversation is about is a page. Closing the tab cancels; it does not end.
  Closing the *space* still ends.
- *"`ConversationScope` … `#[derive(Copy)]`"* — implementation, but it is a
  sentence somebody's code depended on.

**And the lock in ADR-0049 that now under-claims.**
`closing_the_tab_ends_the_conversation_it_was_about` is named in ADR-0049's
`Lock:` field. That test still exists and still passes, and it now proves only
the half of its own name that survived: the reply is cancelled. Its other half —
that the thread is forgotten — is false, and is fenced from the opposite side by
`closing_the_tab_keeps_the_thread_it_was_about` in this ADR. **The two must be
read together; neither is complete alone.** ADR-0049's file was left untouched
on instruction, so the correction lives in a doc comment on the test itself and
here. This is a lock that buys slightly more confidence than it is owed, which
AGENTS.md is right to call worse than declared debt, and it is declared.

**And the one no test catches:** the anchor and the transcript can disagree
about what a thread is about. `ConversationScope::Page` holds the normalised
address; `StorableMessage::Page` holds the raw URL the host reported when it
captured. They are two spellings of the same page and nothing checks that they
still name the same one — a host that reported a post-redirect URL would file a
capture under one address inside a thread keyed on another, and the screen would
show both without either being wrong enough to notice.

## When to revisit

- **When somebody wants every conversation in one place.** The list is per page
  today, which means a thread is only reachable through the page it is about.
  That is a `zer0://conversations` page and it inherits ADR-0054's decision
  about what an address does.
- **When a page's URL is not what a person means by "the page".** A single-page
  application that keeps its state in the query, or one that keeps it in the
  fragment, will be wrong in opposite directions here. The answer is not a
  per-site rule in `PageAnchor`; it is an explicit "these are the same page"
  somebody states, which is a different feature.
- **If a signed URL in the chat table turns out to matter.** The honest fix is
  not a blocklist of parameter names. It is an anchor a person can see and
  delete — "forget the address of this thread" — which is a smaller change than
  it sounds now that the address lives in exactly one column.
- **When the conversation cap is re-examined.** 200 was chosen for threads that
  died with their tabs. It has not been re-derived for threads that do not.
- **When a thread should be able to keep its page.** ADR-0049 named this: an
  opt-in "keep this page with the conversation" for a thread whose page is
  behind a login that has expired. Anchoring makes the case sharper, because now
  the thread comes back and the page does not.
