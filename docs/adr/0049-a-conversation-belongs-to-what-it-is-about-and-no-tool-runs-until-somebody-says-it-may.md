# ADR-0049: A conversation belongs to what it is about, and no tool runs until somebody says it may

- **Status:** Accepted
- **Date:** 2026-05-21
- **Lock:** `crates/zer0-core/src/chat_tests.rs::pressing_it_on_another_tab_is_another_thread`, `crates/zer0-core/src/chat_tests.rs::a_question_from_the_command_bar_is_about_no_page_at_all`, `crates/zer0-core/src/chat_tests.rs::opening_a_panel_reads_nothing_until_something_is_asked`, `crates/zer0-core/src/chat_tests.rs::asking_about_a_page_reads_it_before_it_asks_anything`, `crates/zer0-core/src/chat_tests.rs::nothing_runs_until_somebody_says_it_may`, `crates/zer0-core/src/chat_tests.rs::a_tool_nobody_configured_is_refused_without_being_asked_about`, `crates/zer0-core/src/chat_tests.rs::always_covers_one_tool_and_not_the_server_it_came_from`, `crates/zer0-core/src/chat_tests.rs::never_is_written_down_and_the_next_call_does_not_ask`, `crates/zer0-core/src/chat_tests.rs::a_decision_cannot_be_replayed_to_run_a_call_twice`, `crates/zer0-core/src/chat_tests.rs::a_model_that_loops_through_tools_is_stopped`, `crates/zer0-core/src/chat_tests.rs::a_consent_prompt_dies_with_the_reply_it_belonged_to`, `crates/zer0-core/src/chat_tests.rs::closing_the_tab_ends_the_conversation_it_was_about`, `crates/zer0-core/src/chat_tests.rs::closing_the_tab_keeps_the_thread_it_was_about`, `crates/zer0-core/src/storable_tests.rs::an_ephemeral_space_leaves_no_conversation_behind`, `crates/zer0-core/src/storable_tests.rs::what_was_on_the_page_is_never_written_down`, `crates/zer0-core/src/storable_tests.rs::a_tool_call_cannot_be_written_down_at_all`, `crates/zer0-core/src/storable_tests.rs::a_refusal_and_a_thread_both_survive_a_round_trip_through_a_store`

## Context

`zer0` is growing chat: ask a configured model a question, and let it call the
MCP tools the browser has configured. Two ways in — a row in the command bar
while you are typing, and ⌘E about the page you are on.

Every part of that fights the architecture this project is built on, and it is
worth being precise about which part.

A provider request is a network call that arrives in pieces over seconds.
ADR-0002 says the core is a pure, synchronous reducer that does not know what a
`WKWebView` is, and that is the thing which lets behaviour be tested without a
window. A streaming HTTP response is exactly the sort of thing that ends up in
a shell "because it has to be async", and once the transcript lives next to the
socket, every question about what a conversation *is* — what it is about, what
gets sent, what gets kept — becomes a question each platform answers for
itself.

The second problem is worse and it is new. Everything this browser has held
until now belongs to a page: a URL, a title, a cookie, an icon. A conversation
holds what a *person* said, and it holds whatever the browser scraped off a
page to answer them. There has never been a value in this codebase whose
accidental persistence would matter as much.

The third is that a tool call is not data. It is an action, chosen by a model,
with arguments chosen by the same model, run on somebody's machine under their
credentials. ADR-0028 has already been through this once with extensions and
its conclusion — nothing is granted that nobody approved, and the approval is
written down in the core — was reached the hard way, after shipping the
opposite.

## Decision

### Chat is the shape WebKit already is

The core emits an `EngineCommand`, a host performs it, facts come back as
`Action`s. Nothing about chat is special-cased.

Six commands: `StartChatReply`, `CancelChatReply`, `RunToolCall`,
`CancelToolCall`, `CapturePageContext`, `ListTools`. Nothing in any of them
names a provider, a model, a key or a transport — the host reads all four out
of configuration and reports back which model actually answered.

Streaming is modelled as what it is rather than flattened into one event: the
core mints the assistant message *before* it asks, sets it `Streaming`, and the
host reports `ChatReplyStarted`, then `ChatReplyDelta` and
`ChatToolCallRequested`, then exactly one of `ChatReplyFinished` or
`ChatFailed`. The message's own state machine — `Streaming`, `Complete`,
`Cancelled`, `Failed`, `Interrupted`, `Truncated` — is the same shape a
download's is, for the same reason: only one of those is live, and everything
that reads a conversation needs to be able to tell which.

**The whole transcript travels with every request.** The host holds no
conversation of its own. That is the same trade `BrowserSnapshot` makes: a
second copy of one thread will eventually disagree with the first, and the one
that is wrong is always the one on screen.

### A conversation belongs to a tab, or to a space, and never to neither

`ConversationScope` has two variants:

- **`Tab`** — what ⌘E opens. Pressing ⌘E twice on the same tab reopens the same
  thread; pressing it on a different tab opens a different one. Navigating the
  tab does not start a new thread: you kept the tab, so you kept the subject —
  the new page is attached to the thread you already have.
- **`Space`** — what the command bar opens. One per space, for questions about
  no page in particular.

**Why a tab and not a space.** A tab is already this browser's unit of "a thing
I am doing": it is what the sidebar lists, what ⌘W closes, what archiving
expires. If a thread were per space, ⌘E on the second page would carry the
first page into it, and every page you glanced at all day would still be in the
prompt at six o'clock — an unbounded context you are paying for, made of pages
you have forgotten you opened. Worse, "clear this chat" would have no honest
meaning.

**Why never global.** Both variants resolve to exactly one space, and that is
the point rather than a side effect. A conversation holds page text and typed
questions, which is precisely the material ADR-0007 gives every space its own
cookie jar for. A global thread would carry a work page into a personal
question with nothing on screen saying so.

**A conversation dies with what it is about.** Closing the tab ends the thread,
cancels the reply in flight, and cancels the tools it had running. So does
closing the space. A reply still arriving for a thread nothing can reach is
bytes somebody is paying for and nobody will read.

### The page is read when a question is sent, and at no other moment

Opening the panel reads nothing. There is no capture on navigation, on focus or
on a timer. `CapturePageContext` is emitted only when a question is being sent
in a thread that is about a page, and only when that page is not the one the
thread was already told about.

What was read becomes a message with its own role, `PageContext` — not a `User`
message with the page pasted into it. The difference between "you sent this"
and "the browser sent this on your behalf" is the thing a person needs to be
able to see, and it is what decides what may be written down.

The captured page is inserted **before** the question it was read for. Arrival
order is not the order of the conversation.

The host must answer `CapturePageContext` even when it read nothing, because
the thread holds its question until the answer arrives. A page nobody could
read still has an address worth telling the model.

### Nothing runs until somebody says it may

Four rules, and they are ADR-0028's four with the nouns changed.

1. **Ask by default.** A tool call arrives `AwaitingConsent` and nothing is
   emitted. Extensions arrive with everything the browser can describe already
   ticked, because an extension that installs switched off looks broken; that
   argument does not transfer. A tool that asks the first time looks careful.

2. **A tool the browser cannot name is refused without anybody being asked.**
   Consenting to something nobody could describe is not consent — the same
   sentence ADR-0028 wrote about a match pattern nobody could parse. The
   refusal is fed back to the model as a tool result, so the transcript has no
   gap in it.

3. **Always is remembered per `(server, tool)` and never per server.**
   Approving a server is approving tools it has not published yet, which is
   exactly the "manifest grew a permission after the install" failure ADR-0028
   names.

4. **Never is written down; Refuse is not.** A refusal stored is a refusal that
   survives a relaunch, which is the only thing that makes a prompt worth
   reading twice. A one-off no is deliberately absent from the ledger, so the
   next call asks again.

The gate is the call's *state*, not the arrival of the answer: a duplicated or
replayed `DecideToolCall` finds a call that is no longer `AwaitingConsent` and
does nothing. There is no path from a model's request to a running tool that
does not pass through a row somebody answered.

**A server's own description of its own tool is never the browser's
statement.** It is carried so a person can read it, and it never shortens the
prompt. A server claiming its tool is harmless is the thing being trusted
describing itself.

**One question, twelve rounds.** A model that calls a tool, reads the result
and calls it again is an unattended loop spending somebody's money. Past
`MAX_TOOL_ROUNDS` the thread stops and says `ToolLoop`.

### Errors are a category in the core and a sentence in the shell

`ChatErrorKind` follows `NavigationErrorKind` exactly: `NoProviderConfigured`,
`NotAuthorised`, `RateLimited`, `Offline`, `ConnectionFailed`, `Timeout`,
`ContextTooLong`, `MalformedResponse`, `ProviderRefused`, `ToolUnavailable`,
`ToolFailed`, `ToolLoop`, `Unknown`. An HTTP 429 with a provider's JSON body in
it is not something any interface can branch on; which screen to draw is
behaviour and lives here, and the wording is copy and lives in the shell —
which is what `NavigationErrorScreen` already does.

`NoProviderConfigured` is the one whose useful action is a settings screen
rather than "try again", and it is the first thing anybody will see. Until a
provider host exists, `UnconfiguredChatHost` answers every request with it —
because a question that silently goes nowhere is the worst outcome available.

### Cancellation is one path

`CancelChat` stops the reply, stops the tools that were running, cancels the
consent prompts that were waiting, and clears a page capture in flight —
keeping every word that had already arrived. Closing a tab or a space goes
through the same function. A delta for a stopped reply is dropped as ordinary
late traffic, the way a `DownloadProgressed` for a finished download already is.

A consent prompt is cancelled without ever being answered, because the reply it
belonged to is gone: a prompt for a turn that no longer exists is a prompt
whose Yes does nothing anyone can see.

### Conversations survive a restart, minus three things

They persist, because a thread is at least as much work as a download and
because the browser already promises the session comes back whole (ADR-0017).
What does not persist is decided in the projection (ADR-0045), above every
backend:

- **An ephemeral space's threads are never written.** ADR-0023's promise
  applied to the most detailed trace of a page this browser can produce.
- **The page's text is never written — anywhere, for any space.**
  `StorableMessage::Page` carries an address and a title and has no field for a
  body. The address and title are already in history; the body of every page
  anybody ever asked about is a shadow archive well past anything this browser
  has written down before. A restored thread names its page and reads it again
  if the conversation goes on.
- **A tool call cannot be stored at all**, because no variant carries one. A
  consent prompt cannot come back after a restart, and a stale result cannot
  come back answering a call nothing can produce. Tool results go with them.

What a server said it could do is not restored either: that is a fact about a
process which is not running yet, and a call answered against a remembered list
would run a tool the server may no longer have.

The consent ledger *is* stored, in `tool_consent` (schema 5). A consent that
resets on relaunch trains people to click through, which is the whole of
ADR-0028.

### ⌘E, and a row in the command bar

⌘E is `UiCommand::OpenChat`. Chrome spends it on "Use Selection for Find", a
command this browser does not have, so it is free; E is the letter a finger
reaches for; and it survives the collapse to Control, so Linux needs no second
binding.

The command bar grows `Suggestion::AskChat`, offered for anything typed and
never for an empty bar, sitting directly above the typed interpretation. Two
reserved slots instead of one. It means the same thing whichever gesture opened
the bar: ⌘L says "put this somewhere" and ⌘T says "somewhere new", and neither
sentence has an opinion about a question (ADR-0019 decides destinations, and a
question has none).

A question typed into the command bar is about **no page**. The person was
navigating a second ago; attaching whatever happened to be open would send a
page nobody mentioned to a provider.

## Consequences

**What this costs, honestly:**

- **The transcript crosses the FFI on every turn.** A long thread with a big
  page attached is a large copy per request. It is the same bet ADR-0002 makes
  about `snapshot()`, taken again with a bigger value, and the profiler has not
  been asked.
- **A host that answers neither `ChatReplyFinished` nor `ChatFailed` hangs a
  thread forever.** The core has no clock — that is ADR-0002 — so there is no
  timeout here. The same applies to `CapturePageContext`: a host that stays
  quiet leaves a question waiting. Escape clears it, which makes this
  survivable rather than fixed, and it is named rather than hidden.
- **Always-allow is approval of every future argument.** Granting `write_file`
  standing permission approves every path it will ever be handed. The ledger is
  reviewable and revocable, and that is the whole mitigation. Per-argument
  consent was considered and rejected: a prompt on every call is a prompt
  nobody reads by the third one.
- **A restored thread is missing its page.** The answers reference something
  that is no longer in front of the model, so continuing an old conversation
  starts by re-reading the page. That is the price of not keeping a copy of
  every page anyone discussed, and it is worth it.
- **Twelve rounds is a number somebody will disagree with**, reasonably. It is
  a judgement, like ADR-0028's risk tiers.
- **Consent is held in two places, deliberately.** `Session.chat` holds
  *whether* a tool may run without asking; `Session.mcp` holds *what it was* —
  the shape the answer was given about (ADR-0050). Only one of them holds the
  answer, so they cannot drift into disagreeing about it, but reading either
  half alone gives a wrong picture and somebody will.
- **`ToolCallId` is chosen by the model.** It is bounded and never interpreted,
  never used as a path or a key to anything on disk — but it is an
  attacker-influenced string that is compared for equality, and the duplicate
  check is the only thing standing between a repeated id and a call answered by
  the wrong result.

**What we get:**

- The whole conversation state machine — streaming, tool round trip,
  cancellation, the ephemeral promise — is tested with no window, no network
  and no provider.
- Four other agents can build against a protocol with no `default:` anywhere in
  it, so a variant nobody handled breaks the build rather than falling through.
- The Linux port is a `ChatHost` and a page-text script, not a rewrite.

## How this regresses

**"It answered about the wrong page."** Somebody makes the conversation
per-space because it is fewer objects, and ⌘E on a new tab starts replying with
yesterday's page still in context. Nobody files this; it reads as the model
being confused. `pressing_it_on_another_tab_is_another_thread` goes red.

**"It sent my bank statement to an API."** Someone makes the panel capture the
page when it opens, or on navigation, because it feels more responsive. The
symptom is nothing at all — it works better, and page text leaves the machine
for questions nobody asked. `opening_a_panel_reads_nothing_until_something_is_asked`
and `a_question_from_the_command_bar_is_about_no_page_at_all` are the two
fences, and the second one is the one that survives a refactor of the first.

**"It deleted a file and never asked."** A convenience path that runs a tool
straight off `ChatToolCallRequested` — most plausibly added while making the
common case feel faster. `nothing_runs_until_somebody_says_it_may` and
`a_decision_cannot_be_replayed_to_run_a_call_twice` hold that line from both
ends.

**"I said yes once and it stopped asking."** `Once` starts being written to the
ledger, or a grant widens from a tool to a server.
`always_covers_one_tool_and_not_the_server_it_came_from` and
`a_consent_choice_is_a_ledger_row_and_not_a_running_call` are the pair.

**"I said never and it asked again."** The ledger stops being saved.
`a_refusal_and_a_thread_both_survive_a_round_trip_through_a_store` covers it
across the file.

**"My private window kept a transcript."** A conversation table written without
the projection filter, or a backend reading `Session` instead of
`StorableSession`. `an_ephemeral_space_leaves_no_conversation_behind` and
`what_was_on_the_page_is_never_written_down` are the locks, and the second one
greps the whole projection rather than one field, because the next place page
text leaks will not be the field anyone expected.

**"It kept spending after I closed the tab."** Conversation teardown is dropped
from `close_tabs` during a refactor of tab closing, which is a function with
nothing chat-shaped in its name.
`closing_the_tab_ends_the_conversation_it_was_about` is the one that screams.

*Correction to the record, not to the decision. That test now proves only the
surviving half of its own name: since ADR-0060 anchored a conversation to the
page rather than to the tab, closing a tab **cancels** the reply and no longer
ends the thread — closing the space still does. Its companion,
`closing_the_tab_keeps_the_thread_it_was_about`, holds the half that moved, and
both are on the `Lock:` line. A test whose name outlived its claim is exactly
the shape that made the keymap lock in ADR-0012 stay green through a real bug.*

**And the one no test catches:** a host that offers a model more tools than the
core will accept. The calls come back, the core refuses them, and the model
spends its turn being told no by a browser that offered in the first place.
Nothing goes red — the protocol says the host must offer only what
`StartChatReply` carried, and only prose enforces it.

## When to revisit

- **When a second entry point wants a conversation that is neither a tab nor a
  space.** A thread pinned to a project across tabs is a real thing people
  want, and it is a third scope rather than a widening of either existing one.
- **If re-reading the page after a restart turns out to be the wrong trade** —
  someone whose thread is useless the next morning because the page is behind a
  login that has expired. The fix then is an explicit "keep this page with the
  conversation", opted into per thread, not page text stored by default.
- **When ADR-0050's registry is persisted.** The chat-side ledger is stored
  today and the fingerprints beside it are not, so a standing grant comes back
  needing confirmation. That is the safe direction to be wrong in, and it is
  still a thing that will surprise somebody the first time.
- **If the transcript copy shows up in a profile.** The answer is a delta
  protocol for messages, not moving the transcript into the host.
- **When a provider offers server-side conversation state.** Everything here
  assumes the browser holds the thread and re-sends it. A provider that holds
  it changes what `StartChatReply` carries, and it changes what "delete this
  conversation" can honestly promise — which is the more interesting half.
