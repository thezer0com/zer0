# ADR-0088: A conversation is called what it is about, and the browser names its own pages in one pass

- **Status:** Accepted
- **Date:** 2026-08-10
- **Lock:** `crates/zer0-core/src/internal_url.rs::a_conversation_is_called_what_was_asked_and_never_the_word_chat`, `crates/zer0-core/src/internal_url.rs::three_conversations_about_three_pages_are_three_different_names`, `crates/zer0-core/src/internal_url.rs::a_conversation_about_no_page_with_nothing_asked_says_so`, `crates/zer0-core/src/internal_url.rs::a_long_question_is_cut_to_a_title_at_a_word_boundary`, `crates/zer0-core/src/internal_url.rs::a_question_typed_over_several_lines_is_still_one_line_of_title`, `crates/zer0-core/src/internal_url.rs::a_page_with_no_site_to_name_falls_back_rather_than_inventing_one`, `crates/zer0-core/src/internal_url.rs::a_page_names_itself_so_two_shells_cannot_disagree`, `crates/zer0-core/src/chat_tests.rs::a_chat_tabs_name_follows_the_thread_it_is_showing`, `crates/zer0-core/src/chat_tests.rs::three_conversations_are_three_different_names`, `crates/zer0-core/src/chat_tests.rs::a_tab_whose_thread_is_gone_stops_wearing_its_name`, `crates/zer0-core/src/ffi_tests.rs::a_conversation_comes_back_called_what_it_was_called`

## Context

`InternalAddress::title()` answered `"Chat"` for every conversation, and had
since the address space was written. That was correct while a thread had no
well-defined subject and became wrong the day ADR-0060 gave it one.

ADR-0083 is the half of this that has already landed and it named the other half
in its own consequences, twice:

> **A conversation's row is a copy of its page's row.** Same icon, adjacent in
> the list, and the only thing separating them is the word "Chat".

> **And none of it is spoken.** `SiteBadge` is `accessibilityHidden`, correctly,
> because for an ordinary row the title beside it already names the site. For a
> conversation the title is the word "Chat", so this change tells a sighted
> person which thread is which and tells VoiceOver nothing new.

So a sidebar holding three conversations showed three different badges under
three identical labels, and a screen reader heard the word "Chat" three times.
The badge was doing all of the work and could not do any of it for anybody who
does not look at the screen.

Two things had to be settled before the obvious change was safe.

**A thread that has not been asked anything yet.** `conversationOpeningQuestion`
already names a thread by its first question and `ThreadList` already uses it,
but a thread is minted before that question exists — ⌘E opens a conversation and
a screen, and the person types afterwards. So there is a real interval, and for
some threads it never ends.

**Where the name is kept up to date.** A tab's title is a stored field, written
when a tab commits to an address and read by the sidebar, the window strip, the
command bar's ranking and the session file. A conversation's name is not a
constant: it is one thing when the thread is minted and another the moment a
question lands. Something has to notice.

## Decision

**A conversation is named after what it is about, and the browser re-derives the
names of its own pages after every action rather than assigning them where a tab
is pointed somewhere.**

### What a thread is called

`internal_url::conversation_title` is the one door, and it answers in the order a
thread acquires facts about itself:

- **The first thing the person typed.** It is the only line in a transcript
  written on purpose to say what was wanted, and it is what `ThreadList` already
  labels a thread by — so a conversation is called the same thing in the sidebar
  as on the screen that lists it. Folded to one line, because ⇧↩ is a new line
  in the composer and a question really does arrive with line breaks in it, and
  clamped at 56 characters on a word boundary, because a question is allowed to
  be a paragraph and a title is not.
- **The site it is about**, before anything has been asked: *"Chat about
  github.com"*. The thread has a subject from the moment it is minted, and that
  subject is the whole reason to open this page rather than another tab on
  somebody's website. Not the page's *title* — that is the page's own claim
  about itself, it lives on a tab that may be closed, and this is the core,
  where there is no such thing as "whatever is open".
- **"New chat"**, for a thread about no page with nothing asked. There is
  nothing true to name it after, so it says that (ADR-0018) rather than
  borrowing the front tab's site.

### `InternalAddress::title()` returns `Option<String>` and `Chat` is `None`

Not a convenience — the guarantee. An address is a number in a query string, and
a caller holding one has no way to know what the thread it names is about. The
old signature let anybody with an address in hand produce a name, and what came
back was the word that caused this. Now the compiler sends them to find the
thread, and there is no spelling of "name this conversation without looking at
it" that builds.

### One pass, not four call sites

`reducer::name_our_pages` walks the open tabs and names every one whose address
is ours. `dispatch` calls it after applying the action, so every action leaves
through it; `Zer0::open` calls it once on the session it just read, which covers
every backend behind `SessionStore` (ADR-0045) rather than one store's `load`.

The alternative is to spell the name at the places a tab is pointed at a
conversation — the address bar, ⌘E, the thread list, and again when a question
lands. Four sites that have to agree, and the one that is forgotten is a row
that keeps saying *"Chat about github.com"* over a conversation forty messages
long. `go_internal` no longer assigns a title at all; it clears the old page's
and lets the pass name the new one before the dispatch returns.

The cost is one walk over the open tabs per dispatch, and it buys a name that
cannot go stale.

### It holds on restart, from both ends

The name is a tab title, which the session file already carries, so a restored
row is drawn correctly before anything has been dispatched. And the pass runs on
the session the moment it is read, so a tab addressing a conversation that did
*not* survive the load — ADR-0060 drops a thread whose address this build cannot
read — stops wearing that thread's name instead of keeping it until the next
action happens to arrive.

## Consequences

- **A conversation's row and its page's row stop being pixel copies.** They
  still share an icon, which is ADR-0083's decision and is the point of it, and
  now the words say which is which.
- **VoiceOver hears the difference**, which is the part that was missing
  entirely. Nothing about the badge changed; the fix was always the title, and
  ADR-0083 said so.
- **The command bar can find a conversation by what was asked in it.**
  `Tab::display_title` is what `command_bar` ranks against, and it is now the
  question rather than the word "Chat" for every thread at once. Not designed
  for here, and worth naming because it is the kind of thing that gets
  attributed to the wrong change later.
- **A tab title is now derived state for four addresses.** Anybody writing a
  fifth internal page gets a name from `InternalAddress::title()` by existing,
  and gets nothing at all if they leave it `None` — the pass skips it and the
  tab shows its URL. That is a real trap and the `switch` is what will catch it,
  because it does not compile without a new arm.
- **The clamp is a decision about the session file, not about the sidebar.** A
  sidebar truncates anyway; 56 characters is what stops a pasted three-paragraph
  question becoming a three-paragraph row in SQLite that the command bar then
  scores every word of.
- **`internal_title` across the FFI changed shape** and has no consumer in the
  Apple shell, which reads the tab's title. It is left exported rather than
  deleted because a second shell will want it, and it now returns the same
  `Option` for the same reason.

## How this regresses

**"All my conversations are called Chat again."** Somebody restores a constant
for the `Chat` arm of `InternalAddress::title()` — it is the only arm that
returns `None`, which reads as an oversight, and filling it in makes the
function total and the signature simpler. Everything compiles and every
conversation in the sidebar goes back to one word.
`a_conversation_is_called_what_was_asked_and_never_the_word_chat` and
`three_conversations_about_three_pages_are_three_different_names` both go red,
and the second prints the three names it got.

**"The name is stuck on the first thing it said."** `name_our_pages` is moved
out of `dispatch` and back to the places a tab is pointed at an address, because
running it after every action looks wasteful next to assigning a string once.
The screen is right at the moment a thread is opened and wrong from the first
question onward, which is a state nobody photographs.
`a_chat_tabs_name_follows_the_thread_it_is_showing` asks for the name before and
after a question and is the fence.

**"It is called something I deleted."** The pass is dropped from `Zer0::open`, on
the grounds that the session file already holds the title, and a tab restored
addressing a conversation that the load dropped keeps that conversation's name
in the sidebar until something else happens.
`a_tab_whose_thread_is_gone_stops_wearing_its_name` is the near half of this and
`a_conversation_comes_back_called_what_it_was_called` is the restart.

**"My tab title is somebody's essay."** The clamp is removed as arbitrary, or is
moved to the view — where it would be applied by the sidebar and not by the
session file or the command bar.
`a_long_question_is_cut_to_a_title_at_a_word_boundary` also holds the two
things a clamp gets wrong on the first attempt: cutting mid-word, and counting
bytes, which does not truncate a question in Portuguese so much as panic on it.

**"A private page's address is in my sidebar."** Not introduced here and worth
being explicit about, because this decision moves more of a thread onto the row:
the name is the *question* and the *site*, never the path. A signed URL with a
token in its query is already written down by ADR-0060 and is not printed by
this.

## When to revisit

- **When a thread can be renamed by hand.** That is the obvious next request and
  it changes the shape of this: the derived name becomes a default, the stored
  one wins, and `conversation_title` grows an argument rather than a branch.
- **If a model ever proposes a name.** Every other assistant titles a thread by
  asking a model to. It would be a claim the browser cannot check and it would
  cost a request per conversation, so it is not this; if it ever is, the thing
  to argue with is the second bullet of the decision above.
- **If the pass shows up in a profile.** It is a walk over the open tabs per
  dispatch, and a dispatch happens on every delta of a streaming reply. Measured
  at nothing today against tens of tabs; a browser holding hundreds is where the
  arithmetic would be worth doing again.
- **When a second internal page wants a name that is not a constant.** One
  exception is a branch; two is a table, and the table belongs next to
  `InternalAddress`.
