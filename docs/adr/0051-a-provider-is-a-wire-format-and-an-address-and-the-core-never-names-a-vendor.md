# ADR-0051: A provider is a wire format and an address, and the core never names a vendor

- **Status:** Accepted
- **Date:** 2026-05-29
- **Lock:** `crates/zer0-core/src/provider/provider_tests.rs::a_reply_split_in_the_middle_of_a_word_arrives_whole`, `crates/zer0-core/src/provider/provider_tests.rs::a_tool_call_comes_back_the_same_shape_from_every_wire`, `crates/zer0-core/src/provider/provider_tests.rs::a_tool_result_travels_back_in_each_wires_own_shape`, `crates/zer0-core/src/provider/provider_tests.rs::two_tools_that_would_share_a_name_are_kept_apart`, `crates/zer0-core/src/provider/provider_tests.rs::every_failure_a_provider_states_becomes_something_to_act_on`, `crates/zer0-core/src/provider/provider_tests.rs::a_new_vendor_on_a_wire_we_speak_is_config_and_nothing_else`, `crates/zer0-core/src/provider/provider_tests.rs::a_token_reaches_the_header_and_nothing_else`, `crates/zer0-core/src/provider/provider_tests.rs::a_stream_that_is_cut_off_still_ends`, `apple/Tests/Zer0ShellTests/ChatProviderTests.swift::ChatProviderTests/cancellingClosesTheConnection`, `apple/Tests/Zer0ShellTests/ChatProviderTests.swift::ChatProviderTests/aMissingKeyFailsBeforeConnecting`

## Context

Chat has to reach every language model somebody might want to use: the frontier
labs, whatever hosted service is cheap this quarter, and a model running on the
laptop with no network involved at all. The person pastes a token and picks a
model. That is the whole of the requirement, and it is a much harder
requirement than it sounds, because the four APIs behind it are not variations
on a theme.

They disagree about nearly everything:

- **The transport.** Three speak Server-Sent Events. Ollama speaks
  newline-delimited JSON. Gemini speaks SSE only if you ask for it in a query
  parameter, and otherwise streams a JSON *array* in chunks.
- **The shape of a reply.** Anthropic sends named events carrying indexed
  content blocks. OpenAI sends unnamed chunks with a `[DONE]` sentinel, plus a
  padding field that is in no published schema. Gemini sends whole response
  objects. Ollama sends one line per token.
- **Tool arguments.** Anthropic and OpenAI stream them as fragments of a JSON
  **string** that must be concatenated and only then parsed. Gemini and Ollama
  send them as an **object**, whole, in one piece.
- **Tool identity.** Anthropic and OpenAI give every call an id. Gemini has an
  `id` field that this endpoint leaves empty, so calls correlate by position and
  name. Ollama correlates by an index.
- **Where a tool result goes.** Anthropic: a block inside a *user* message.
  OpenAI: a message with a role of its own. Gemini: a `functionResponse` part in
  a user turn. Ollama: a `tool` message with a `tool_name`.
- **What a failure looks like.** A refusal is a 200 on Gemini. A wrong API key
  on OpenAI arrives with `type: "invalid_request_error"`, which is a lie in the
  only field that looks authoritative. Ollama's whole error envelope is one
  string.

Three questions had to be settled before a byte could be sent, and they are the
whole of this record: **what a provider is**, **where the layer lives**, and
**what a tool call is when four APIs cannot agree what one is.**

## Decision

### A provider is a wire format plus an address, and neither is a vendor

`ProviderEndpoint` is `{ id, wire, base_url, auth }`. That is the entire model
of "who we are talking to". `WireFormat` has four values because four
genuinely incompatible shapes exist, and it is named after who invented each
shape, the way SSE is.

What it is emphatically **not** is a list of who you can talk to. One
`OpenAiChat` entry covers OpenAI, Groq, Together, OpenRouter, DeepSeek,
Mistral, vLLM, LM Studio and Ollama's compatibility endpoint, because they all
speak it. Adding one of those is a line of configuration and **no code**:
`a_new_vendor_on_a_wire_we_speak_is_config_and_nothing_else` is that claim
written down as a test, and it builds a real Groq request at a real Groq
address without a module existing for Groq.

Nothing in `crates/zer0-core/src/protocol.rs` says `Anthropic`.
`EngineCommand::StartChatReply` carries a conversation, a transcript and a list
of tools, and the host resolves the rest from configuration. That was not an
accident of layering — it is what makes "support every provider" a
configuration problem rather than a permanently open code problem.

### The layer is pure translation in the core; only the socket is in the shell

This is the part with a genuine tension in it, so here is the tension.

"Behaviour goes to the core, appearance stays in the shell" would put HTTP in
the shell. But *parsing* an SSE stream is not appearance and two platforms
cannot reasonably disagree about it — which by the corollary in `CLAUDE.md`
means it is in the wrong place if it lives in a shell. Written in Swift, the
whole thing would be rewritten for Linux, which is precisely the outcome
ADR-0002 exists to prevent.

So the seam is cut at the socket rather than at the protocol:

```
StartChatReply ──▶ provider::request() ──▶ HttpRequest
                                                │
                                  shell: URLSession, TLS, Keychain, cancel
                                                │
Action::ChatReply* ◀── StreamEvent ◀── StreamDecoder::push() ◀── bytes
```

The core half is **pure and synchronous**: bytes in, events out, no socket, no
task, no clock, no file, no secret. It is the same arrangement `EngineHost` has
with WebKit — the host reports facts and carries out instructions — and it has
the same payoff. Every rule in this ADR is checked by a test that runs with the
wifi off, including the ones that are impossible to check against a live
provider: a stream cut off after two thirds of a byte, a gateway that returns
four megabytes of HTML with a 200 on it, a tool call whose arguments stop
halfway through a JSON string.

`ChatProviderHost.swift` is what is left in the shell, and it is small: open the
connection, read the Keychain, hand the bytes over, cancel. It contains no
provider name and no field name from any API.

### One shape for a tool call, and it carries both correlation keys

Tool calling is where these APIs differ most, and it is where an abstraction
either works or quietly becomes "Anthropic's shape with adapters". Three
decisions carry it.

**A call always has an id, even where the wire has none.** Gemini and Ollama get
one synthesised deterministically. So the core has exactly one shape —
`ToolInvocation { id, server, tool, arguments }` — and never learns that two of
the four wires cannot produce an id.

**A result carries the id *and* the name.** This is the single decision that
makes one shape fit four wires. Anthropic and OpenAI correlate by id and ignore
the name; Gemini and Ollama have no usable id and correlate by name. Neither
field is redundant and neither is a workaround: the core holds both already,
because it just ran the tool. Had the shape carried only an id, Gemini and
Ollama would each need a side table, which is exactly the special case leaking
upward that this design is measured against.

**Arguments only ever leave the layer whole.** The two wires that stream them as
text fragments assemble them in the decoder, and what comes out is either valid
JSON or a `MalformedResponse`. Half a JSON object reaching an MCP server is the
worst available outcome, because it parses to something *nearly* right and then
runs.

There is a fourth thing, which is smaller and bit immediately: a tool is
`(server, tool)` here and one flat name out there. The name is **derived**
(`server__tool`, sanitised, capped at the 64 characters every provider allows)
and what comes back is **matched against the list that was offered** rather than
split on the separator — a server called `read__page` and a tool `page` on a
server `read` flatten to the same string. Two pairs that would collide are
pulled apart with a numeric suffix. A name matching nothing comes home with an
empty `server`, which is the core's existing signal to refuse it, so a model
asking for something nobody offered produces a refusal on screen rather than a
silent drop.

### A failure becomes one of thirteen categories, and each one is an action

`ProviderErrorKind` is deliberately shorter than any provider's own list and
deliberately longer in one place. `authentication_error` and `permission_error`
both mean "your key will not work", but they are different screens — one is
"the key is wrong", the other is "the key is right and does not reach this
model" — so they stay apart. `invalid_request_error` covering both a bad
`temperature` and a prompt over the context window is the opposite mistake, so
`ContextTooLong` is its own category.

Two questions are answered in the core because they decide what buttons a screen
has, and a second copy is how one platform starts offering "Try again" on a
wrong API key:

- `is_transient()` — is retrying the identical request worth offering?
- `is_configuration_fault()` — is the fix in Settings?

No category is both, and `no_failure_is_both_worth_retrying_and_a_setting_to_change`
checks it. The pair that made this necessary is OpenAI's 429: `rate_limit_exceeded`
is worth waiting out and `insufficient_quota` never is, they arrive with the
same status code, and telling them apart needs the `code` field.

Reading order matters and is itself a decision: **`code`, then the status, then
`type`.** A rejected key on OpenAI comes back as
`{"type": "invalid_request_error", "code": "invalid_api_key"}` with a 401.
Believing `type` — the field that looks most authoritative — would tell someone
who mistyped their key that they had sent a bad request, and send them looking
in the wrong place entirely.

### Cancellation reaches the socket

Escape cancels the task, the task's termination handler cancels the URLSession
task, and the decoder is told so it goes quiet. All three are needed. Without
the last, bytes still in flight append to a reply somebody stopped. Without the
middle one the connection stays open, the provider keeps generating, and it is
still billed — none of these APIs has a cancel endpoint for a chat, so hanging
up is the only mechanism there is.

A cancelled stream is a category, not a silence, but it is **not** a
`ChatFailed`: `chat_error_kind` returns `None` for it, because putting an error
on a thread somebody deliberately stopped is the browser arguing with them.

### Every provider can be asked what models it has

All four answer, which is worth stating because it is what lets Settings offer a
list rather than a text field. What they offer differs and the difference is
kept rather than flattened: Anthropic and Gemini state a readable name and a
context window; Ollama states a parameter size, which locally is the thing that
decides; OpenAI states an id and nothing else, in a list mixing embeddings and
speech models with chat models and no field to tell them apart.

Gemini's list is filtered to models that declare `generateContent`, because a
dropdown offering an embedding model contains its own bug report. OpenAI's is
**not** filtered, and that is deliberate — the naming conventions that would
identify a chat model are OpenAI's own, and this codec also talks to a dozen
servers that never adopted them.

### A token has nowhere to be written down

`ProviderEndpoint` has no field for one. That is structural rather than polite:
it is the thing written to the config file, so an endpoint that *could* hold a
secret is one that eventually does — the same closed-on-both-sides argument
ADR-0048 makes about the file. The token arrives as an argument, is used once,
and goes in exactly one header. Never the URL, where it would land in every
proxy log on the path.

## Consequences

- Adding a vendor that speaks an existing wire costs a config entry. Adding a
  genuinely new wire costs one module and four functions, and touches neither
  the core nor the shell.
- A local Ollama model and a hosted frontier model go through the identical
  code path. The local one needs no token, speaks no SSE, sends tool arguments
  as objects and correlates results by name — and none of that reaches the
  core, which is the test this design was built to pass.
- The core carries a JSON parser and four codecs it did not have. That is
  roughly a thousand lines in `crates/zer0-core/src/provider/`, behind a
  `provider` feature so a build that does not want chat does not pay for it.
- **Gemini gets less schema than the tool declared.** Its `Schema` is a subset
  of OpenAPI, so tool schemas are narrowed to an allow-list of the keywords it
  understands. An MCP tool declaring `oneOf`, `$ref` or `additionalProperties`
  has those constraints dropped for this provider only, so the model is told
  less about its arguments than the tool actually enforces. Strictly better than
  the request being refused, and the same trade every client library makes here.
- Reasoning deltas are decoded and then dropped by the shell, because the
  transcript has nowhere to put them yet. The decoding is not wasted — it is
  what stops a model's scratch work being concatenated into its answer.
- The `anthropic-version` header is pinned rather than tracked. A browser
  following "latest" would take a breaking change on a Tuesday from a deploy it
  was not part of.

## How this regresses

The failure a person notices is a chat that spins for ever, and there are four
ways back to it. A reply cut off mid-sentence with no terminal event; a stream
whose framing breaks on a chunk boundary so nothing is ever assembled; a cancel
that stops the loop but not the socket; a `[DONE]` that never arrives because
the connection died in the gap after `finish_reason`. Each has a lock, and
`a_stream_that_is_cut_off_still_ends` checks the general shape of it — exactly
one ending per stream, on every wire.

The second failure is worse because the screen still looks deliberate: a reply
that never came, drawn as an empty bubble. Gemini serves a refusal with a 200,
so a host reading only the status code shows nothing and calls it an answer —
which is ADR-0018 broken by a status code.

The third is the one anybody actually hits first: a mistyped API key reported as
"invalid request". `every_failure_a_provider_states_becomes_something_to_act_on`
holds the whole table, and the OpenAI 401 row is in it specifically because the
provider's own `type` field says the wrong thing.

The quietest regression is a tool call running the wrong tool. It needs two
tools whose names collide after sanitising, so it will not show up in casual
use and will be catastrophic when it does; `two_tools_that_would_share_a_name_are_kept_apart`
is the only thing standing between here and there.

## When to revisit

- **If a fifth wire appears that is not one of these four.** The bet is that
  new vendors adopt the chat-completions shape rather than invent one. If a
  serious provider ships something genuinely new, the cost is one module — but
  if it happens twice in a year, the four-value enum is the wrong axis and
  something plugin-shaped is worth pricing.
- **If Gemini's `parametersJsonSchema` proves reliable.** It accepts full JSON
  Schema and would delete the narrowing entirely, along with the one place this
  layer knowingly tells a model less than the truth. It was not used here
  because the narrowing works today on the field every version of that API has.
- **If Gemini's newer Interactions API becomes the only one that gets
  features.** `generateContent` is documented as fully supported and marked
  legacy. When something worth having is only on the new endpoint, that is a
  fifth wire and this is the argument to re-read first.
- **If the transcript grows somewhere to put reasoning.** The events are already
  decoded and thrown away in one named place in `ChatProviderHost`.
- **If a provider ships a real cancel endpoint.** Today hanging up is the only
  mechanism, and tokens generated before the disconnect are billed regardless.
- **If token accounting starts mattering.** `Usage` is decoded and dropped, and
  a cancelled reply never receives the final usage chunk on any of these wires,
  so an accurate figure needs a local estimate on the cancel path.
