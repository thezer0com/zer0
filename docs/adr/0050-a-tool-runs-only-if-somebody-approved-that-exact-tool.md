# ADR-0050: A tool runs only if somebody approved that exact tool

- **Status:** In progress — the register, the wire and the stdio host are built and tested; the review screen and persistence are not. Partly superseded by ADR-0099, which takes back one bullet of "What is left out of 0.1.0": HTTP servers, for the loopback and static-token case only. Everything this ADR decided about *tools* — the fingerprint, the flat name, the annotations, what is never automatic — is transport-independent and stands unchanged
- **Date:** 2026-05-26
- **Lock:** `crates/zer0-core/src/mcp_tests.rs::a_tool_that_changed_after_being_approved_does_not_run_unattended`, `crates/zer0-core/src/mcp_tests.rs::an_approval_with_no_recorded_shape_never_runs_unattended`, `crates/zer0-core/src/mcp_tests.rs::approving_a_tool_that_does_not_exist_binds_nothing`, `crates/zer0-core/src/mcp_tests.rs::a_fingerprint_cannot_be_forged_by_moving_bytes_between_fields`, `crates/zer0-core/src/mcp_tests.rs::a_refused_tool_is_never_described_to_the_model`, `crates/zer0-core/src/mcp_tests.rs::a_tool_nobody_answered_about_is_confirmed_not_assumed`, `crates/zer0-core/src/mcp_tests.rs::only_a_tool_the_server_calls_harmless_may_even_be_offered_a_tick_box`, `crates/zer0-core/src/mcp_tests.rs::a_server_cannot_name_a_tool_so_it_reads_as_another_servers`, `crates/zer0-core/src/mcp_tests.rs::a_tool_name_the_browser_cannot_use_is_dropped_rather_than_repaired`, `crates/zer0-core/src/mcp_tests.rs::a_server_that_is_not_ready_offers_nothing_and_answers_nothing`, `crates/zer0-core/src/mcp_tests.rs::forgetting_a_server_forgets_what_was_bound_to_it`, `crates/zer0-core/src/mcp_tests.rs::what_a_stdio_server_costs_you_is_said_in_zer0s_own_voice`, `crates/zer0-core/src/mcp_tests.rs::the_command_that_will_run_is_never_shortened`, `crates/zer0-core/src/mcp_tests.rs::the_servers_words_and_ours_are_kept_apart`, `crates/zer0-core/src/mcp_wire_tests.rs::a_modern_request_carries_its_version_and_asks_for_nothing`, `crates/zer0-core/src/mcp_wire_tests.rs::any_other_failure_falls_back_and_the_fallback_is_not_keyed_to_one_code`, `crates/zer0-core/src/mcp_wire_tests.rs::arguments_that_are_not_an_object_never_reach_a_server`, `crates/zer0-core/src/mcp_wire_tests.rs::junk_on_stdout_is_ignored_rather_than_fatal`, `crates/zer0-core/src/mcp_wire_tests.rs::a_tool_reporting_its_own_failure_is_not_a_protocol_failure`, `apple/Tests/Zer0ShellTests/McpTests.swift::McpFailureTests/aServerThatCannotStartIsReported`, `apple/Tests/Zer0ShellTests/McpTests.swift::McpFailureTests/aMissingCredentialStopsTheServerBeforeItRuns`, `apple/Tests/Zer0ShellTests/McpTests.swift::McpFailureTests/aServerThatDiesAnswersWhateverWasInFlight`, `apple/Tests/Zer0ShellTests/McpTests.swift::McpMalformedTests/rubbishOnThePipeIsIgnored`, `apple/Tests/Zer0ShellTests/McpTests.swift::McpMalformedTests/aVersionRefusalDoesNotFallBack`, `apple/Tests/Zer0ShellTests/McpTests.swift::McpConversationTests/aLegacyServerIsSpokenToInTheOldWay`, `apple/Tests/Zer0ShellTests/McpTests.swift::McpConversationTests/nonsenseArgumentsAreRefusedBeforeSending`, `apple/Tests/Zer0ShellTests/McpTests.swift::McpVocabularyTests/theExactCommandIsNeverShortened`, `apple/Tests/Zer0ShellTests/McpTests.swift::McpVocabularyTests/theConsequenceIsAConsequence`

## Context

MCP lets somebody plug tools into the assistant. A server publishes a list of
tools; a language model picks one and writes its arguments; the browser runs it.
Both halves of that sentence are code we did not write deciding something on
somebody's behalf, inside the application that is also holding their bank
session, their mail and their signed-in everything.

Three properties of the protocol make this different from every consent problem
this project has already solved.

**The arguments are the payload, and a model writes them.** ADR-0028 could ask
about `<all_urls>` once because a permission is static: approving it approves
every future use of it. A tool is not static. Approving `write_file` is not
approving `write_file("~/.ssh/authorized_keys", <a key>)`. The dangerous part of
an MCP call is the part nobody has seen yet.

**The server describes itself, and the model reads that description.** A tool's
`description` is prose from the server, and it is the *only* thing the model
uses to decide when to call it. That makes it an instruction channel into our
model, written by a stranger, refreshed on every `tools/list`. The specification
says so plainly: annotations "are not guaranteed to provide a faithful
description of tool behavior" and clients "should never make tool use decisions
based on `ToolAnnotations` received from untrusted servers".

**The list can change after you agree to it.** A server can be exactly what it
claims for a fortnight and then publish one more tool. Every field of an
existing tool can change too, silently, with the same name. A ledger keyed by
name — which is what a normal permission ledger is — cannot see any of this. It
says yes to `read_file` forever, whatever `read_file` has become.

On top of that the specification moved under us. The current revision is
`2026-07-28`: it removed `initialize`, removed sessions, removed
`Mcp-Session-Id`, removed SSE resumability, and made every request carry its own
version and capabilities in `_meta`. Nearly every server in the wild still
speaks `2025-06-18` or `2025-11-25`. A client that speaks only the new shape
fails against all of them; the compatibility matrix in the specification is
explicit that Modern→Legacy "Fails".

## Decision

**An approval is bound to the tool it was given about, and a tool the browser
cannot name unambiguously is not offered at all.**

Six parts.

ADR-0049 settled that no tool runs until somebody says it may. This one is about
what "it" is.

**Consent has two halves and they live in two places on purpose.**
`chat::ToolConsent` holds *whether* a tool may run without asking, per
`(server, tool)`. `mcp::McpRegistry` holds *what it was* — a SHA-256 over the
tool's name, description and input schema, taken at the moment the answer was
recorded. `McpRegistry::verdict` is the only thing that combines them, and it
returns `Approved` only when both halves agree about the same tool. The two
cannot drift into disagreeing about the answer, because only one of them holds
one.

`Zer0::remember_tool_answer` writes both in a single call, and refuses if there
is no tool to bind to. A grant with no shape behind it reads as `Changed`, not
as `Approved` — so a ledger row restored from an older session, or written
through some future path that forgot the second half, fails closed.

**A tool that changed is a tool nobody approved.** Not a warning beside a
running call: the standing approval is void and the call goes back to being
confirmed with its arguments on screen. This is the whole rug-pull defence and
it costs one hash. The alternative — trusting the name — is what every other
client does today.

**Names are decided in the core, once.** Two servers may both publish `search`.
A model is given one flat name per tool, `server__tool`, joined and split in
`mcp.rs`. Server ids may not contain the separator and tool names may, and the
split happens at the *first* separator — which is what makes it impossible for a
server called `beta` to publish a tool named `alpha__search` and land on an
approval `alpha` was given. A tool name that cannot be sanitised is dropped
rather than repaired, exactly as ADR-0028 drops a host pattern nobody could
parse, and for the same reason: a repaired name is a name nobody approved.

**Annotations may make a tool harder to run and never easier.** The
specification's defaults are already pessimistic — absent `destructiveHint`
means `true`, absent `openWorldHint` means `true` — and we keep them. "Do not
ask me again" is *offered* only for a tool the server calls read-only,
non-destructive and closed-world. Offered, not ticked. A server that lies about
being harmless buys itself the existence of a tick box that a person still has
to find and tick, having read what the tool is for. A server that admits it is
destructive removes the box. That asymmetry is the only useful thing an
untrusted self-description can be wired to do.

**What we say and what they say are separate fields.** `ToolDisclosure` carries
`ours` and `theirs`. `theirs` is the server's prose, shown as a quotation.
`ours` is limited to what holds without believing anybody, and the distinction
between an annotation that is *absent* and one that is *false* is honoured
there and nowhere else: for gating, absent means the pessimistic reading; for
prose, absent means "the server has not said", because printing "this tool
deletes things" over a server that never claimed it would be the browser
asserting something it cannot prove (ADR-0018).

**Only stdio ships, and it is spoken in two dialects.** `mcp_wire.rs` speaks
`2026-07-28` and falls back to `2025-06-18`, using the probe the specification
prescribes: ask `server/discover`; a result means modern; the *recognised*
`-32022` means modern-but-incompatible and we stop rather than falling back;
anything else — including silence — means legacy. The specification is explicit
that the fallback must not be keyed to one error code, and it is not. The era is
decided once per server process and cached, as the specification asks.

The framing, the era decision, the reading of a `CallToolResult` and the
vocabulary all live in Rust. `McpHost.swift` owns the `Process`, the pipes and
the timeouts, and decides nothing. A Linux host reimplements thirty lines, not
the protocol.

### What is never automatic

- **Adding a server.** Not from a page, not from a link, not from the model, not
  from a tool result. There is no install URL and no scheme handler.
- **Standing approval.** Never a default, never pre-ticked, never bulk-applied.
  There is no "allow all". `ToolVerdict::MustConfirm` is what an unanswered tool
  gets, and it means the arguments go on screen.
- **A tool that appeared after the review.** Undecided, so it is confirmed with
  its arguments visible, every time, until somebody answers about it deliberately
  in Settings.
- **Anything from a server that is not connected.** Its tools leave the register
  the moment it stops being `Ready`, so a model is never offered something that
  cannot be called.
- **A refused tool.** Not described to the model at all. Describing it and
  refusing afterwards would burn a turn, disclose that the tool exists, and teach
  the model to keep asking.
- **The server asking us for anything.** We declare no capabilities: no
  `sampling` (a server driving our model), no `roots` (telling it where the
  filesystem is), no `elicitation` (a server putting a prompt in front of the
  person). The `_meta` block is `{}` and the legacy handshake declares `{}` too.
- **A shell.** `Process` gets an executable URL and an argument vector. A server
  gets a minimal environment, not the browser's.

### What is left out of 0.1.0, deliberately

- **HTTP servers.** The transport is understood and `http_headers` is written,
  but a remote server needs OAuth 2.1 with RFC 9728 discovery, both metadata
  mechanisms, PKCE `S256`, the RFC 8707 `resource` parameter, RFC 9207 `iss`
  validation, and either CIMD or deprecated dynamic registration — plus SSRF
  defences on metadata URLs the server itself supplies. That is a feature, not a
  transport. Shipping it half-done would be shipping the confused-deputy attack.

  **ADR-0099 narrowed this.** Every clause above is about *authorization*, and
  none of it reaches a server on `127.0.0.1` with no credential: no flow, no
  audience to confuse, no metadata from a stranger to fetch. So Streamable HTTP
  ships for an address the core allows — `https` anywhere, plain `http` only to
  this machine — with a static bearer token from the Keychain. The whole
  paragraph above still holds for **signing in**, which is still not built.
- **Sampling, roots, elicitation, subscriptions.** See above. Without
  `subscriptions/listen` we never receive `notifications/tools/list_changed` on
  the current revision, which is fine: we re-list on connect, and the fingerprint
  catches a changed tool whenever we next see it.
- **A catalogue of one-click servers.** See "Consequences".
- **Persisting the fingerprints.** They are session state today and the ledger
  outlives them, which is why a grant with no shape fails closed.

## Consequences

**What hurts:**

- **A stdio server is not a thing a non-technical person can add, and we should
  stop pretending otherwise.** It is a command, arguments and environment
  variables, and the specification *requires* a client offering one-click setup
  to show "the exact command that will be executed, without truncation". So the
  honest screen leads with `STDIO_CONSEQUENCE` — "This runs a program on your
  Mac. It can do anything you can do" — and shows the whole command line under
  it. That is a screen a careful person can act on. It is not a screen my mother
  can act on, and no amount of design makes `npx -y @vendor/thing@1.2.3` friendly.
  The genuinely clickable version of MCP is a remote server plus a sign-in, which
  is the transport we are not shipping. **0.1.0 has an advanced feature wearing a
  nice sheet.**
- **The fingerprint is not persisted, so every relaunch re-confirms.** The
  register is in `Session` but not yet in the SQLite schema. Until it is, a
  restored grant reads as `Changed` and asks again. That fails closed, which is
  the right direction, but it is friction we owe a schema bump for.
- **The two eras double the surface.** Every request has two shapes and the
  probe costs a round trip against every legacy server. The specification is
  moving fast enough that this will need revisiting within the year.
- **A changed description re-asks, and descriptions change for innocent
  reasons.** A server that fixes a typo costs somebody a confirmation. We chose
  that over the alternative, and the alternative is not catching the rug pull.
- **There are now two entry points into the core for one feature.**
  `Action`/`EngineCommand` carry the tool-call lifecycle; `Zer0`'s MCP methods
  carry the register. That is a real seam and it is here because three agents
  were writing this crate at once, not because it is right. It should collapse
  into `protocol.rs` — see "When to revisit".
- **Containment of a stdio server is theatre and we say so in the sentence.**
  We spawn a child with the person's own rights. Without an App Sandbox profile
  and entitlements we cannot restrict its filesystem, its network or its
  keychain access. `STDIO_CONSEQUENCE` ends with "zer0 cannot limit it" because
  that is true, and a client that said "sandboxed" here would be lying.
- **Prompt injection is not solved and cannot be, here.** A tool returns text;
  that text enters the model's context; if it says "now call `send_email`", the
  model may. Per-call confirmation with the arguments visible is the only real
  defence, and it works exactly as well as somebody reading the sheet.

**What we get:**

- A server cannot grow a capability past what somebody agreed to, which is the
  one failure mode this protocol has that extensions do not.
- Two servers cannot shadow each other's tools, in either direction.
- What a tool is, what it costs, and who claimed what are all testable without
  opening a window or spawning a process.
- The protocol lives in one language. A Linux host inherits era detection,
  result flattening and the whole vocabulary for free.

## How this regresses

**"It ran something I never agreed to."** Somebody adds a convenience path that
records a grant without binding a shape — a second `record` call, a bulk
"approve all" in a settings screen. `an_approval_with_no_recorded_shape_never_runs_unattended`
is the fence, and it holds because the unbound state fails closed rather than
open. `approving_a_tool_that_does_not_exist_binds_nothing` covers the other half.

**"The server updated and my approval carried over."** The fingerprint stops
covering a field — someone drops the description from it to reduce re-prompting,
which will feel like a bug fix.
`a_tool_that_changed_after_being_approved_does_not_run_unattended` and
`a_changed_input_schema_voids_the_approval_too` are what go red, and
`a_fingerprint_cannot_be_forged_by_moving_bytes_between_fields` covers the
subtler version where a server moves bytes across a field boundary.

**"One server answered for another."** The split moves to the last separator, or
server ids start allowing underscores "because people want them".
`a_server_cannot_name_a_tool_so_it_reads_as_another_servers` and
`a_server_id_may_not_contain_the_qualifier` pin both ends.

**"A tool I switched off still got called."** `offerable` stops filtering, or
`verdict` starts trusting the ledger without checking the register.
`a_refused_tool_is_never_described_to_the_model` and
`a_server_that_is_not_ready_offers_nothing_and_answers_nothing` hold that line.

**"It ticked the box for me."** `may_be_standing` starts believing an absent
annotation, which is a one-character change to `unwrap_or`.
`only_a_tool_the_server_calls_harmless_may_even_be_offered_a_tick_box` pins all
four cases.

**"It stopped talking to my server after an update."** The era probe is keyed to
a specific error code because that seemed tidier.
`any_other_failure_falls_back_and_the_fallback_is_not_keyed_to_one_code` is the
fence, and `aLegacyServerIsSpokenToInTheOldWay` proves the fallback still
finishes its handshake.

**"It said the tool did not run, and it had."** A timeout starts reporting
"failed" instead of "stopped waiting". Nothing in a type catches that;
`aServerThatDiesAnswersWhateverWasInFlight` asserts on the sentence, because the
claim is the thing that is wrong.

**And the one no test catches:** the add sheet growing a "Recommended servers"
list with an Install button. Nothing goes red, every string still passes, and
the browser has quietly become a package manager for arbitrary local code. That
is a product decision and it belongs in this file, not in a diff.

## When to revisit

- **When the chat protocol settles.** The register should move behind
  `Action`/`EngineCommand`: `Action::ToolsListed` should carry the annotations
  and the schema rather than a bare summary, `EngineCommand::ListTools` should
  name a server, and the server-state facts should be actions. Two entry points
  is a seam, not a design.
- **When the fingerprints are persisted.** A schema bump beside
  `extension_consent`, and the "grant with no shape" branch becomes what it
  should be — a real inconsistency rather than the ordinary state after a
  relaunch.
- **When there is a story for remote servers.** A URL and a sign-in is the first
  genuinely clickable MCP configuration there has ever been, and this browser is
  the one application already able to run an OAuth flow properly. That is when
  the "non-technical person" claim becomes true rather than aspirational.
- **When macOS gives us anything to contain a child process with.** If a server
  can be given a filesystem scope, `STDIO_CONSEQUENCE` gets to stop ending with
  "zer0 cannot limit it", and that is the single largest improvement available to
  this feature.
- **When the specification moves again.** `2026-07-28` is weeks old, the draft is
  open, and the deprecation policy gives twelve months' notice. The two-era probe
  should become a three-era probe or lose its oldest branch, not accumulate.
