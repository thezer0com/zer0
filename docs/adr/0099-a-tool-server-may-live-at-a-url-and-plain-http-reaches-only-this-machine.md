# ADR-0099: A tool server may live at a URL, and plain http reaches only this machine

- **Status:** Accepted
- **Date:** 2026-08-10
- **Lock:** `crates/zer0-core/src/mcp_http_tests.rs::plain_http_reaches_this_machine_and_nowhere_else`, `crates/zer0-core/src/mcp_http_tests.rs::an_address_that_only_looks_like_this_machine_is_not_this_machine`, `crates/zer0-core/src/mcp_http_tests.rs::a_credential_in_the_address_is_refused_rather_than_used`, `crates/zer0-core/src/mcp_http_tests.rs::only_http_and_https_are_transports_and_the_rest_are_refused`, `crates/zer0-core/src/mcp_http_tests.rs::the_version_in_the_header_is_the_version_in_the_body`, `crates/zer0-core/src/mcp_http_tests.rs::a_legacy_handshake_carries_no_version_and_no_modern_only_headers`, `crates/zer0-core/src/mcp_http_tests.rs::a_session_is_carried_back_to_a_legacy_server_and_never_to_a_modern_one`, `crates/zer0-core/src/mcp_http_tests.rs::an_answer_arriving_as_an_event_stream_is_read_as_one`, `crates/zer0-core/src/mcp_http_tests.rs::the_older_sse_transport_is_named_rather_than_guessed_around`, `crates/zer0-core/src/mcp_http_tests.rs::a_server_asking_for_a_sign_in_says_so_rather_than_reading_as_broken`, `apple/Tests/Zer0ShellTests/McpHttpTests.swift::McpHttpLinkTests/plaintextOffThisMacIsRefused`, `apple/Tests/Zer0ShellTests/McpHttpTests.swift::McpHttpLinkTests/theRefusalIsTheCoresSentence`, `apple/Tests/Zer0ShellTests/McpHttpTests.swift::McpHttpLinkTests/aLoopbackProxyGetsALink`, `apple/Tests/Zer0ShellTests/McpHttpTests.swift::McpConnectionStatusTests/anUnreachableServerIsNotHealthy`, `apple/Tests/Zer0ShellTests/McpHttpTests.swift::McpConnectionStatusTests/aFailureBlamesNobody`

## Context

ADR-0050 shipped MCP over stdio and left HTTP out on purpose, in one sentence
worth quoting because this ADR is narrowing it rather than overturning it:

> a remote server needs OAuth 2.1 with RFC 9728 discovery, both metadata
> mechanisms, PKCE `S256`, the RFC 8707 `resource` parameter, RFC 9207 `iss`
> validation, and either CIMD or deprecated dynamic registration — plus SSRF
> defences on metadata URLs the server itself supplies. That is a feature, not a
> transport. Shipping it half-done would be shipping the confused-deputy attack.

Every clause of that is about **authorization**. None of it reaches a server on
`127.0.0.1` with no credential: there is no authorization flow to get wrong, no
token that could be forwarded to the wrong audience, no metadata document from a
stranger to fetch, and no deputy to confuse. The reasoning was sound and it
simply does not apply to the case in front of us.

The case in front of us is concrete. The author runs a local MCP proxy and has
asked twice to point `zer0` at it. Everything except the link existed already:
`McpServerConfig` has `transport`, `url` and `credential`; the file parser
refuses a secret written into the file; the add sheet collects all three;
`mcp_wire` was already pure string-in string-out with an `http_headers` written
and never called. The missing piece was thirty lines of `URLSession` and one
decision nobody had taken.

**That decision is which addresses are allowed.** A browser starting a program
is one kind of trust; a browser opening a socket to an address out of a text
file is another, and it is not obviously smaller. It is worth being exact about
what an MCP server is: it receives whatever the assistant decided to send, which
is drawn from the conversation, which is drawn from pages and from what somebody
typed; and it returns text that goes straight into the model's context and
steers what the model does next. It sits on both sides of the model at once.

### What the author's proxy actually speaks

Measured, not assumed, because the configured URL ends in `/sse` and that is the
name of an older transport:

| Address | Method | Answer |
| --- | --- | --- |
| `http://127.0.0.1:7332/mcp/sse` | `GET` | `text/event-stream`, `event: endpoint` → `/mcp?session_id=…` |
| `http://127.0.0.1:7332/mcp/sse` | `POST` | `405`, `Allow: GET,HEAD` |
| `http://127.0.0.1:7332/mcp?session_id=…` | `POST` | `202 Accepted`, body `null` |
| `http://127.0.0.1:7332/mcp` | `POST` | `200`, the reply in the body |

So the proxy (`mcp-proxy 0.6.2`) serves **both**: the retired HTTP+SSE transport
at `/mcp/sse`, and Streamable HTTP at `/mcp`. Asked `server/discover` at `/mcp`
it answers with `supportedVersions: ["2026-07-28", "2025-11-25", "2025-06-18",
"2025-03-26", "2024-11-05"]` — it is a **modern-era** server by
`mcp_wire::detect_era`, so there is no `initialize`, no session, and no
handshake to sequence. It publishes 255 tools in one page, no cursor.

The third row is the load-bearing measurement. Had the legacy endpoint answered
a POST in the body, HTTP+SSE would have been a *discovery step* — read the
endpoint off the stream, then carry on. `202` with an empty body says it is not:
the answers come back on the separate `GET` that has to stay open, correlated
across two connections. That is a second transport, not a detail.

## Decision

**A tool server may be configured at a URL, spoken to with Streamable HTTP.
`https` is reachable anywhere; plain `http` is reachable only when the address
is this machine. Everything else is refused rather than repaired.**

### The address rule, and why it is not the page rule

`EnginePolicy` sets HTTPS-First for pages: try `https`, fall back to `http`.
That is right *there*. A person is watching, the address bar shows what
happened, and refusing plaintext outright would break a web that still contains
some. None of those hold here. Nobody is watching when the model calls a tool,
there is no address bar, and the number of MCP servers that exist only over
plaintext on the open internet is approximately zero.

The threat is not eavesdropping, which would argue for a warning. It is that
anyone able to rewrite a plaintext response can **write instructions into the
model's context**, or serve a tool list of their own. The fingerprint from
ADR-0050 defends against the server changing a tool; it is no defence at all
against somebody else answering in the server's place, because the tools they
serve are the tools that get fingerprinted. A warning is the wrong shape for
that. So: refuse.

**Loopback is the exception because it has no path.** Packets to `127.0.0.1` do
not leave the machine, so plaintext there is exactly as private as the pipe to a
child process — which is what stdio already is, and stdio already ships.
Refusing it would refuse the only case this transport was built for while buying
nothing.

The full table, in `mcp_http::endpoint_verdict`:

| Address | Verdict |
| --- | --- |
| `https://` anywhere | allowed |
| `http://` to `127.0.0.0/8`, `::1`, `::ffff:127.x.x.x` | allowed |
| `http://` to `localhost` or `*.localhost` | allowed (RFC 6761 reserves them) |
| `http://` to anything else, including `192.168.*` and `10.*` | **refused** |
| any scheme that is not `http`/`https` | **refused** |
| any URL carrying a user name or password | **refused** |
| unparseable, or naming no host | **refused** |

Two of those need a word. A **LAN** address is refused: a LAN has a path, and
the other people on the coffee-shop wifi are on it. A **credential in the URL**
is refused because it is a credential in `config.toml`, which ADR-0048 forbids —
and the refusal has somewhere to send you, since `credential` already names a
Keychain entry.

"Is this loopback" is decided on the **parsed host**, never on the text.
`http://127.0.0.1.evil.example/` and `http://127.0.0.1@evil.example/` both
contain the loopback address as a substring and neither is loopback. And the
rule survives a redirect: `URLSession` would otherwise follow a `301` to
wherever it was pointed, so `RedirectGuard` runs the destination through the
same core function and cancels if it is refused. A rule that only holds on the
first request is not a rule.

### Streamable HTTP only, and the older transport is named rather than worked around

`zer0` speaks the transport the specification has, which is one address that
answers a POST. It does not speak HTTP+SSE. Pointed at `/mcp/sse` it reports
what it measured — this address does not accept a POST, and here is what it does
accept — plus what `zer0` needs. It does **not** strip `/sse` and retry. That
would be right for this proxy and wrong for the next one, and an address that
silently becomes a different address is exactly the repair-that-guesses ADR-0024
keeps naming. The person changes four characters, having been told why.

### The era mechanism is the one that already exists

No second mechanism. The probe is `server/discover`, the verdict is
`mcp_wire::detect_era`, and the fallback is `initialize` — the same three
functions stdio uses, over a different carrier. What HTTP adds is that the era
also decides the **headers**: a modern request carries `MCP-Protocol-Version:
2026-07-28`, `Mcp-Method` and (for a call) `Mcp-Name`; a legacy one carries the
version it negotiated, omits it on `initialize` itself, and carries
`Mcp-Session-Id` back if the server issued one.

`http_headers` is therefore built **from the line about to be sent**, reading
the method and the tool name out of it, because the failure it prevents is the
header and the body disagreeing — which is a `400 HeaderMismatch` — and one
function that writes both cannot drift.

### There is no connection, and that is the feature

No long-lived `GET`. The server-to-client stream is optional, and ADR-0050
already decided this browser re-lists on connect rather than subscribing to
`notifications/tools/list_changed`. So every exchange is one POST with one
response, and there is no socket to lose, no reconnection state machine, and no
`Last-Event-ID` to resume from.

A POST may still be answered with `text/event-stream` rather than a document —
the specification allows either and requires reading both — so a body comes
apart through `http_reply_lines`. That uses the event-stream reader the chat
providers already had, moved from `provider/sse.rs` to `sse.rs` so there is one
of them. Writing a second next door would be a second set of answers to `data:`
continuation, `\r\n`, comment lines and the event with no final blank line, and
they would disagree about one of them eventually.

### A server that is not running is a normal state, and now says so

Three things were wrong here and all three are fixed, because a transport whose
server is missing half the time makes them matter.

**Nothing in the shell ever told the register anything.** `adoptMcpServer` and
`setMcpServerState` were never called from Swift. Every configured server read
as `Idle`, `toolsListed` arrived for a server the register had never adopted and
was dropped on the floor, and *no failure a connection could have ever reached a
screen*. `BrowserModel` now adopts on the first state a server reports and
relays every one after.

**The Connections pane was showing the wrong thing.** It asked `Readiness`,
which is about the *file* — is it switched on, does its key exist — and printed
the answer as though it were about the connection. A proxy that was not running
showed a clock and the sentence "Ready. zer0 will list what it can do once it
has connected." That is the browser asserting something it had no evidence for,
which is ADR-0018. It now shows the connection's own state, and a failure in the
core's words: "zer0 could not reach that address", never anything that reads as
`zer0` breaking. The row also stopped telling somebody their `127.0.0.1` proxy
is reached "over the internet".

**A server that failed stayed failed for the life of the launch.**
`ConfiguredChatHost` kept a set of ids it had started and never removed one, so
a proxy quit and restarted was gone until the browser was. That set is deleted;
`McpHost.start` already refuses to start a server it is holding and drops one
that failed, so asking every time is both idempotent and the retry.

### What is still out, and stays out

- **OAuth 2.1, RFC 9728 discovery, dynamic client registration, token
  refresh.** ADR-0050's argument holds for all of it unchanged, and this change
  settles none of it. A static bearer token from the Keychain is *attached* to a
  request; nothing here *obtains* one. A `401` says so plainly rather than
  looking like a fault: "It is asking for a token. zer0 sends the one named by
  `credential` and cannot sign in on your behalf."
- **The HTTP+SSE transport.** Retired, and named when met.
- **Sampling, roots, elicitation, subscriptions.** Unchanged from ADR-0050.
- **Server-initiated anything.** There is no stream for it to arrive on.

### Everything ADR-0050 decided about tools is untouched

Checked rather than assumed, because an HTTP server is a new way for the same
hostile input to arrive (ADR-0024). The door is
`McpRegistry::set_tools(&str, &[ReportedTool])`, and `ReportedTool` is a record
of strings and three `Option<bool>`s — it carries no connection, no handle and
no transport tag. The fingerprint is `fingerprint(name, description, schema)`;
the flat name is `qualified_name`/`split_qualified` over `__`; dropping an
unusable name is `sanitize_tool_name`; "not ready offers nothing" is
`set_state` clearing the list. None of them can observe what carried the bytes.
The only transport-aware things in `mcp.rs` are two consequence sentences and a
command-line joiner, and no guarantee depends on any of them.

## Consequences

**What hurts:**

- **The author's own URL does not work as written, and this ships anyway.** He
  configured `/mcp/sse` and will get a refusal the first time. It names what was
  measured and what is needed, and the fix is deleting four characters — but it
  is still a person hitting an error on the feature they asked for twice. The
  alternative was guessing at an address, and a wrong guess reaches a stranger's
  server rather than showing an error.
- **A non-2xx ends the connection**, including a `503` a healthy server emitted
  once. With a stateless transport reconnecting costs one POST on the next
  listing, which is why this was chosen over teaching the link to distinguish a
  blip from a fault; but a person watching the pane will see a server drop out
  over something transient.
- **Requests to one server are ordered behind any notification.** A notification
  waits for everything in flight and everything after it waits for the
  notification, because `notifications/initialized` must not be overtaken. Two
  tool calls still overlap; a tool call issued after a notification does not.
  This costs nothing against a modern server, which sends no notifications at
  all.
- **The bearer token is static and this browser cannot refresh it.** When it
  expires, the server says `401` and somebody re-enters it. For a local proxy
  that is nothing; for anything else it is the missing feature wearing a
  workaround.
- **`endpoint_verdict` trusts the local resolver for `localhost`.** Allowing
  only IP literals would be structural; allowing the name is a judgement that a
  hostile `/etc/hosts` means an attacker already runs code as you, which stdio
  hands them anyway.
- **`sse.rs` moved**, so a merge that touches `provider/sse.rs` will conflict.

**What we get:**

- The thing that was asked for: `zer0` connects to a local MCP proxy, lists what
  it offers, and calls it.
- A rule about addresses that is decided once, in the core, and is enforced on
  redirects as well as on the first request.
- A Connections screen that says true things about connections, which it did not
  before this and would not have started saying on its own.
- A transport with no connection to leak, no reconnection to get wrong, and no
  reason for a restarted proxy to need the browser restarted.

## How this regresses

Somebody adds `http://tools.example.com/mcp` to their file — perhaps copied from
a README — and it works. Nothing on screen is wrong; the tools list, the calls
return. What has happened is that every tool call and every tool result now
crosses the network in clear text, and anyone on the path can rewrite the
results. The assistant starts doing things nobody asked for, and it looks like
the model behaving badly. `plain_http_reaches_this_machine_and_nowhere_else`
goes red the moment the refusal is relaxed.

The subtler one: somebody makes the refusal "helpful" by upgrading to `https`
and retrying, or by stripping a path that did not answer. Now the address the
person approved is not the address being spoken to, and on a bad day it is a
different server entirely. `theRefusalIsTheCoresSentence` and
`the_older_sse_transport_is_named_rather_than_guessed_around` both fail.

Or the loopback check gets rewritten as a string comparison, because
`host.hasPrefix("127.")` is shorter and reads fine. Then
`http://127.0.0.1.evil.example/` is plaintext to a stranger, and
`an_address_that_only_looks_like_this_machine_is_not_this_machine` names it.

And the one this project has already paid for once: somebody tidies the
connection status back into `Readiness`, because two sources for one row looks
like duplication. It is not — one is about the file and one is about the
connection — and the symptom is a green tick over a server that is not running.
`anUnreachableServerIsNotHealthy` is that lock.

## When to revisit

- **When a remote server somebody actually wants needs signing in.** That is
  the OAuth feature ADR-0050 described, it is still a feature rather than a
  transport, and it gets its own ADR.
- **When a `503` dropping a healthy server is observed hurting.** The fix is to
  fail the one request rather than the connection, and it needs the link to know
  what it sent — which it does.
- **If a server worth using speaks only HTTP+SSE.** Measure first: most things
  advertising `/sse` also serve Streamable HTTP on the same host, as the
  author's proxy does.
- **When `tools/list_changed` starts mattering.** It needs the long-lived `GET`
  this deliberately does not open, and that brings reconnection back with it.
- **If loopback stops being enough of a boundary** — a machine where other
  users' processes can bind or read loopback is a different threat model, and
  the answer there is `https` everywhere, not a warning.
