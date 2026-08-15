//! MCP over Streamable HTTP: the one wire that has an address.
//!
//! `mcp_wire` builds and reads the messages and does not care what carries
//! them. This file is everything that only makes sense once the carrier is
//! HTTP, and all four of its parts are decisions rather than plumbing:
//!
//! - **which addresses may be spoken to at all** ([`endpoint_verdict`]),
//! - **which headers a request carries**, which differs by era and gets a
//!   `400 HeaderMismatch` when it disagrees with the body ([`http_headers`]),
//! - **what an HTTP status means about a server** ([`http_status_failure`]),
//! - **how a response body becomes messages**, which is not one-per-line
//!   because a server may answer a POST with an event stream
//!   ([`http_reply_lines`]).
//!
//! A second host reimplementing any of those would be a second host quietly
//! disagreeing about them, which is the whole argument of ADR-0002.
//!
//! ## What is not here
//!
//! No OAuth. ADR-0050 left authorization out and ADR-0099 keeps it out: a
//! static bearer token read from the Keychain is the only credential this
//! speaks, and it is attached to a request rather than obtained by one. There
//! is no discovery, no metadata document, no token endpoint and no refresh.
//!
//! No long-lived `GET`. The specification makes the server-to-client stream
//! optional, and ADR-0050 already decided this browser does not subscribe to
//! `notifications/tools/list_changed` — it re-lists on connect and the
//! fingerprint catches a changed tool. So every exchange is one POST with one
//! response, which is why there is no connection to lose and no reconnection
//! to get wrong.
//!
//! Sources, all `modelcontextprotocol.io/specification/2026-07-28/`:
//! `basic/transports/http`, `basic/versioning`, `basic/authorization`.

use serde_json::Value;
use url::{Host, Url};

use crate::mcp::McpFailure;
use crate::mcp_wire::{LEGACY_PROTOCOL_VERSION, PROTOCOL_VERSION, ServerEra};
use crate::sse::{Framer, Framing};

/// Whether an address out of the configuration may be spoken to.
///
/// A refusal carries the sentence rather than a code, for the same reason
/// [`McpFailure::reason`] does: this is the only thing a person will see, and a
/// screen that had to write its own would be a second opinion about what went
/// wrong.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum EndpointVerdict {
    /// Reachable. `url` is the address **as parsed**, so nothing downstream
    /// re-reads the string from the file and reaches a different host than the
    /// one this decision was made about.
    Allowed {
        url: String,
        loopback: bool,
    },
    Refused {
        reason: String,
    },
}

/// Which addresses a tool server may live at.
///
/// **`https` anywhere, `http` only to this machine.** The asymmetry is not
/// caution about eavesdropping, which would argue for a warning; it is that an
/// MCP server sits on both sides of the model at once. It receives whatever the
/// assistant decided to send — which is drawn from the conversation, and the
/// conversation is drawn from pages and from what somebody typed — and it
/// returns text the model then acts on. Anyone able to rewrite a plaintext
/// response can write instructions straight into the model's context, or serve
/// a tool list of their own; the fingerprint in ADR-0050 defends against the
/// *server* changing a tool and is no defence at all against somebody else
/// answering in its place.
///
/// So this is not the page rule. `EnginePolicy` sets HTTPS-First for pages and
/// falls back to `http` when there is no `https`, which is right there: a
/// person is watching, the failure is visible, and refusing outright would
/// break a web that still contains plaintext. Nobody is watching when the model
/// calls a tool, so the same permissiveness would be a fallback nobody sees
/// into a channel nobody can audit. Refuse instead.
///
/// **Loopback is the exception because it has no path.** Packets to
/// `127.0.0.1` do not leave the machine, so plaintext there is exactly as
/// private as the pipe to a child process — which is what stdio already is, and
/// stdio is the transport this browser already ships. Refusing `http` to
/// loopback would refuse the case this transport was added for while adding no
/// safety at all.
///
/// Everything else is refused rather than repaired. No upgrade to `https` and
/// retry: an address that silently becomes a different address is the failure
/// mode this project keeps naming.
pub fn endpoint_verdict(raw: &str) -> EndpointVerdict {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return refused("This connection has no address.");
    }

    let Ok(url) = Url::parse(trimmed) else {
        return refused(format!("“{trimmed}” is not an address zer0 can read."));
    };

    match url.scheme() {
        "http" | "https" => {}
        other => {
            return refused(format!(
                "zer0 reaches a tool server over https, or over http when the address is this \
                 Mac. It does not speak {other}."
            ));
        }
    }

    // A password in the address is a password in `config.toml`. ADR-0048 says a
    // secret only ever lives in the Keychain, and the file already has the
    // field that does this properly, so this is a refusal with somewhere to go
    // rather than a rule with no alternative.
    if !url.username().is_empty() || url.password().is_some() {
        return refused(
            "That address carries a user name or password. Put the token in the Keychain and \
             name it with `credential`, so it is not sitting in a text file.",
        );
    }

    let Some(host) = url.host() else {
        return refused(format!("“{trimmed}” names no server to connect to."));
    };

    let loopback = is_loopback(&host);
    if url.scheme() == "http" && !loopback {
        return refused(format!(
            "zer0 will not reach {host} over plain http. A tool server is handed whatever the \
             assistant sends and its answers steer what the assistant does next, so anyone on \
             the way could read the one and write the other. Use https, or run the server on \
             this Mac.",
        ));
    }

    EndpointVerdict::Allowed {
        // The parsed form, not the string that came in. A trailing space or a
        // stray fragment that changed nothing here would otherwise reach
        // `URLSession` unexamined.
        url: url.to_string(),
        loopback,
    }
}

/// Whether an address is this machine, decided on the parsed host and never on
/// the text.
///
/// `http://127.0.0.1.evil.com/` and `http://127.0.0.1@evil.com/` both contain
/// the loopback address as a substring and neither is loopback, which is why
/// nothing here does string matching on `raw`.
fn is_loopback(host: &Host<&str>) -> bool {
    match host {
        Host::Ipv4(address) => address.is_loopback(),
        Host::Ipv6(address) => {
            address.is_loopback()
                // `::ffff:127.0.0.1` is the same machine written the other way.
                || address.to_ipv4_mapped().is_some_and(|v4| v4.is_loopback())
        }
        // RFC 6761 reserves `localhost` and everything under it, and requires a
        // resolver to answer them with a loopback address. Trusting that is
        // trusting the local resolver, which is the same trust stdio places in
        // the local machine when it runs a program on it.
        Host::Domain(name) => *name == "localhost" || name.ends_with(".localhost"),
    }
}

fn refused(reason: impl Into<String>) -> EndpointVerdict {
    EndpointVerdict::Refused {
        reason: reason.into(),
    }
}

// ---------------------------------------------------------------------------
// Headers
// ---------------------------------------------------------------------------

/// The headers one request carries.
///
/// Built from the message about to be sent rather than from a description of
/// it, because the failure this prevents is precisely the two disagreeing:
/// `MCP-Protocol-Version` that does not match the body's `_meta` is a `400`
/// with `HeaderMismatch`, and `Mcp-Method` naming a different method than the
/// body is the same class of bug with no error attached. One function reads the
/// line and writes both, so they cannot drift.
///
/// `era` is `None` while the probe is still out. That is not "unknown, guess" —
/// the probe *is* a modern request, so the only request ever sent without a
/// settled era is one that must carry modern headers.
///
/// `session` is whatever a legacy server put in `Mcp-Session-Id` when it
/// answered `initialize`. Modern servers have no sessions, so it is never sent
/// to one even if a host held on to it.
pub fn http_headers(
    era: Option<ServerEra>,
    session: Option<&str>,
    line: &str,
) -> Vec<(String, String)> {
    let body: Option<Value> = serde_json::from_str(line).ok();
    let method = body
        .as_ref()
        .and_then(|value| value.get("method"))
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();

    let mut headers = vec![
        ("Content-Type".to_string(), "application/json".to_string()),
        // Both, and the specification requires being able to read either
        // answer. `http_reply_lines` is the half that makes that true.
        (
            "Accept".to_string(),
            "application/json, text/event-stream".to_string(),
        ),
    ];

    match era.unwrap_or(ServerEra::Modern) {
        ServerEra::Modern => {
            headers.push((
                "MCP-Protocol-Version".to_string(),
                PROTOCOL_VERSION.to_string(),
            ));
            headers.push(("Mcp-Method".to_string(), method.clone()));
            if method == "tools/call"
                && let Some(name) = body
                    .as_ref()
                    .and_then(|value| value.pointer("/params/name"))
                    .and_then(Value::as_str)
                // Non-ASCII would need the Base64 sentinel form. A tool name
                // that is not ASCII never gets this far: `sanitize_tool_name`
                // dropped it.
                && name.is_ascii()
            {
                headers.push(("Mcp-Name".to_string(), name.to_string()));
            }
        }
        ServerEra::Legacy => {
            // The old rule is that the header appears on everything *after* the
            // handshake, carrying the version the handshake agreed on. Sending
            // it on `initialize` itself is sending a version before either side
            // has settled one.
            if method != "initialize" {
                headers.push((
                    "MCP-Protocol-Version".to_string(),
                    LEGACY_PROTOCOL_VERSION.to_string(),
                ));
            }
            if let Some(session) = session.filter(|value| !value.is_empty()) {
                headers.push(("Mcp-Session-Id".to_string(), session.to_string()));
            }
        }
    }

    headers
}

/// The `Authorization` value for a token, or `None` when there is no token.
///
/// One line, and it is here rather than in the host so that the shape of the
/// header is not a thing two hosts can spell differently — and so the one place
/// a credential is turned into a header is a place with no way to log it.
///
/// A token that already names its own scheme is passed through: somebody whose
/// proxy wants `Basic` has written `Basic …` into the Keychain, and prefixing
/// `Bearer ` onto that would produce a header that authenticates as nobody.
pub fn authorization_header(token: &str) -> Option<(String, String)> {
    let token = token.trim();
    if token.is_empty() {
        return None;
    }
    let value = if token.contains(' ') {
        token.to_string()
    } else {
        format!("Bearer {token}")
    };
    Some(("Authorization".to_string(), value))
}

// ---------------------------------------------------------------------------
// Reading what came back
// ---------------------------------------------------------------------------

/// What an HTTP status says about a server, and what to say about it.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct HttpOutcome {
    pub failure: McpFailure,
    pub message: String,
}

/// Read a status code as a fact about the connection.
///
/// The interesting one is `405`. An address ending in `/sse` is the older
/// HTTP+SSE transport — two endpoints, a `GET` that stays open and a `POST`
/// that answers `202` while the real answer arrives on the other one. The
/// protocol replaced it with Streamable HTTP and this browser speaks only the
/// replacement, so the honest thing is to say what was measured — this address
/// does not take a POST — and say what is needed, without guessing which other
/// address on that server would work. Stripping `/sse` and retrying would be
/// right for one proxy and wrong for the next, and a repair that guesses is a
/// bug with a delay on it.
pub fn http_status_failure(
    status: u16,
    allow: Option<&str>,
    authenticate: Option<&str>,
) -> HttpOutcome {
    let outcome = |failure: McpFailure, message: String| HttpOutcome { failure, message };

    match status {
        401 | 403 => {
            let mut message = if status == 401 {
                "That server would not let zer0 in.".to_string()
            } else {
                "That server refused the request.".to_string()
            };
            if authenticate.is_some_and(|value| value.to_ascii_lowercase().contains("bearer")) {
                message.push(' ');
                // Said plainly rather than hidden, because the useful next
                // action depends on which of the two it is and only the person
                // knows. See ADR-0099: sign-in is the part that is not built.
                message.push_str(
                    "It is asking for a token. zer0 sends the one named by `credential` in the \
                     settings file and cannot sign in on your behalf.",
                );
            }
            outcome(McpFailure::Unauthorized, message)
        }
        404 | 410 => outcome(
            McpFailure::Unreachable,
            "There is no tool server at that address.".to_string(),
        ),
        405 => {
            let mut message = "That address does not accept a POST".to_string();
            if let Some(allow) = allow.filter(|value| !value.trim().is_empty()) {
                message.push_str(&format!(", only {}", allow.trim()));
            }
            message.push_str(
                ". zer0 speaks Streamable HTTP, which is one address that answers a POST. An \
                 address ending in /sse is usually the older two-endpoint transport, which the \
                 protocol retired and zer0 does not speak.",
            );
            outcome(McpFailure::Rejected, message)
        }
        406 => outcome(
            McpFailure::Rejected,
            "That server would not answer in JSON or as an event stream, which are the two \
             things zer0 can read."
                .to_string(),
        ),
        408 | 429 => outcome(
            McpFailure::Unreachable,
            format!("That server asked zer0 to slow down or wait ({status})."),
        ),
        500..=599 => outcome(
            McpFailure::Unreachable,
            format!("That server failed while answering ({status})."),
        ),
        other => outcome(
            McpFailure::Unreachable,
            format!("That server answered {other}, which is not an answer zer0 can use."),
        ),
    }
}

/// Split a response body into the messages inside it.
///
/// A POST gets one of two answers and the specification requires reading both:
/// a single JSON document, or an event stream carrying one or more. The stream
/// case is why this is not `vec![body]` — handing `event: message\ndata: {…}`
/// to `parse_reply` would read as not-JSON, be ignored exactly as a stdio
/// banner is ignored, and turn into a request that quietly times out fifteen
/// seconds later.
///
/// `202 Accepted` with an empty body is the correct answer to a notification,
/// and produces nothing here rather than an error.
///
/// A batched response — a JSON array of replies — is unpacked into its
/// elements, because the host matches one id at a time.
pub fn http_reply_lines(content_type: &str, body: &str) -> Vec<String> {
    let is_event_stream = content_type
        .to_ascii_lowercase()
        .split(';')
        .next()
        .is_some_and(|kind| kind.trim() == "text/event-stream");

    if !is_event_stream {
        return unpack(body);
    }

    let mut framer = Framer::new(Framing::EventStream);
    let mut frames = framer.push(body.as_bytes());
    // A body that ended without its final blank line still has an event in it,
    // and a body delivered whole very often does.
    frames.extend(framer.finish());
    frames
        .into_iter()
        .flat_map(|frame| unpack(&frame.data))
        .collect()
}

fn unpack(raw: &str) -> Vec<String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Vec::new();
    }
    match serde_json::from_str::<Value>(trimmed) {
        Ok(Value::Array(items)) => items.iter().map(Value::to_string).collect(),
        // Not parsed here beyond that: reading a message is `parse_reply`'s
        // job, and doing any of it twice is how two readers start disagreeing.
        _ => vec![trimmed.to_string()],
    }
}

#[cfg(test)]
#[path = "mcp_http_tests.rs"]
mod tests;
