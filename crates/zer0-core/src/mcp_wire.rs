//! Model Context Protocol, on the wire, with no wire attached.
//!
//! Pure string in, pure string out. Building a request is a function, reading a
//! reply is a function, and neither of them knows whether the bytes came from a
//! pipe, a socket or a test.
//!
//! ## Why this is in the core at all
//!
//! Framing JSON-RPC looks like plumbing, and plumbing belongs to the host
//! (ADR-0002). But almost none of what is in this file is plumbing. Which
//! protocol version we claim, what we do when a server answers with a version
//! we do not speak, whether a tool result counts as an error, how a list of
//! content blocks becomes one string a person reads — those are decisions, and
//! a second host reimplementing them would be a second host quietly disagreeing
//! about them. What is left for the host is genuinely mechanical: open the
//! pipe, write the line, read the line, match the id.
//!
//! ## Two eras
//!
//! Revision `2026-07-28` deleted the handshake. There is no `initialize`, no
//! `notifications/initialized`, no session; every request carries its own
//! version and capabilities in `_meta`, and `server/discover` replaces the
//! handshake as an optional, cacheable question.
//!
//! Almost nothing in the wild speaks it yet. A client that only speaks the new
//! shape fails outright against every server built in the last year, so this
//! speaks both, and [`detect_era`] encodes the probe the specification
//! prescribes: ask `server/discover`; a result means modern, a *recognised*
//! modern error means modern-but-incompatible, and anything else — including
//! silence — means legacy. The specification is explicit that the fallback must
//! not be keyed to one error code, so it is not.
//!
//! Sources, all `modelcontextprotocol.io/specification/2026-07-28/`:
//! `basic/index` (`_meta`, error code ranges), `basic/versioning` (era
//! detection, compatibility matrix), `basic/transports/stdio` (framing),
//! `server/discover`, `server/tools`, `basic/patterns/cancellation`.

use serde_json::{Map, Value, json};

use crate::mcp::ReportedTool;

/// The revision this browser prefers.
pub const PROTOCOL_VERSION: &str = "2026-07-28";

/// What we fall back to. `2025-06-18` rather than the newest legacy revision
/// because it is the one the installed base actually speaks, and a fallback
/// nobody implements is not a fallback.
pub const LEGACY_PROTOCOL_VERSION: &str = "2025-06-18";

/// What the browser calls itself when a server asks.
pub const CLIENT_NAME: &str = "zer0";

/// `-32022`, from the range the specification reserves for itself. The one
/// error that means "modern server, wrong version" rather than "not a modern
/// server".
pub const UNSUPPORTED_PROTOCOL_VERSION: i64 = -32022;

/// How many pages of `tools/list` will be followed before giving up.
///
/// A cursor is opaque and a server controls it, so a server can hand out a
/// cursor forever. Following it forever is the bug.
pub const MAX_TOOL_PAGES: u32 = 16;

/// Which shape of the protocol a server speaks.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum ServerEra {
    /// `2026-07-28` or later: stateless, `_meta` on every request.
    Modern,
    /// `2025-11-25` or earlier: `initialize`, then `notifications/initialized`.
    Legacy,
}

/// What a reply is expected to be an answer to.
///
/// The host holds the id-to-request map, because that is bookkeeping. It tells
/// us which kind of answer this is so we can read it; we do not guess from the
/// shape, because guessing from the shape is how a `tools/list` result gets
/// read as a `tools/call` result by a server that wants it to be.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum Expect {
    Discover,
    Initialize,
    ToolsList,
    ToolsCall,
}

/// What one line from a server turned out to mean.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum Reply {
    /// A modern server answered `server/discover`.
    Discovered {
        server_name: String,
        server_version: String,
        supported_versions: Vec<String>,
    },
    /// A modern server that does not speak our version. Not a reason to fall
    /// back to `initialize`: it is modern, it simply disagrees.
    VersionRefused { supported: Vec<String> },
    /// A legacy server answered `initialize`.
    Initialized {
        protocol_version: String,
        server_name: String,
        server_version: String,
    },
    /// A page of tools. `next_cursor` empty means this was the last one.
    ///
    /// An empty string is a valid cursor per the specification, so "no more
    /// pages" is `has_more: false` and not an empty string.
    Tools {
        tools: Vec<ReportedTool>,
        next_cursor: String,
        has_more: bool,
    },
    /// A tool ran. `is_error` is the tool's own verdict on itself
    /// (`isError: true`), which is a different thing from the call failing.
    Called { is_error: bool, text: String },
    /// A JSON-RPC error object. The call did not happen.
    Failed { code: i64, message: String },
    /// The server says its tool list moved.
    ToolsChanged,
    /// Not JSON, not JSON-RPC, or an answer we asked nothing for.
    ///
    /// Dropped rather than treated as a failure. A stdio server is forbidden
    /// from writing non-protocol bytes to stdout, but plenty of them print a
    /// banner anyway, and killing a server over a stray line would make this
    /// browser the only client that cannot talk to it.
    Ignored,
    /// Well-formed JSON-RPC we could not read as the answer we were expecting.
    /// Distinct from `Ignored` because this one is a server misbehaving in a
    /// way a person should be told about.
    Malformed { detail: String },
}

/// What the probe said about a server's era.
///
/// Modelled as a function over one reply rather than as a state machine,
/// because it is one decision made once: the specification says the era is a
/// property of the server and should be cached for its lifetime.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum EraProbe {
    /// Modern, and it works. Nothing more to send.
    Settled { era: ServerEra },
    /// Modern, but it will not speak our version. Stop.
    Incompatible { supported: Vec<String> },
    /// Send `initialize` and see.
    FallBack,
}

/// Read one answer to `server/discover` as a verdict about the whole server.
pub fn detect_era(reply: &Reply) -> EraProbe {
    match reply {
        Reply::Discovered { .. } => EraProbe::Settled {
            era: ServerEra::Modern,
        },
        Reply::VersionRefused { supported } => EraProbe::Incompatible {
            supported: supported.clone(),
        },
        // Every other outcome, including a plain error and including nothing at
        // all, means "try the old way". The specification is explicit that this
        // must not be keyed to one error code, because a legacy server has no
        // idea what `server/discover` is and will fail in whatever way it
        // likes.
        Reply::Failed { .. }
        | Reply::Ignored
        | Reply::Malformed { .. }
        | Reply::Initialized { .. }
        | Reply::Tools { .. }
        | Reply::Called { .. }
        | Reply::ToolsChanged => EraProbe::FallBack,
    }
}

// ---------------------------------------------------------------------------
// Building what goes out
// ---------------------------------------------------------------------------

/// The `_meta` block a modern request carries instead of a handshake.
fn meta(version: &str) -> Value {
    json!({
        "io.modelcontextprotocol/protocolVersion": PROTOCOL_VERSION,
        // Empty rather than absent: the field is required, and we ask for
        // nothing. No sampling, no elicitation, no roots — see ADR-0050 for
        // why a browser does not offer a server a way back in.
        "io.modelcontextprotocol/clientCapabilities": {},
        "io.modelcontextprotocol/clientInfo": {
            "name": CLIENT_NAME,
            "version": version,
        },
    })
}

fn line(value: Value) -> String {
    // One message per line, and a message may not contain a newline. Serde's
    // compact form never emits one, which is what makes this safe rather than
    // hopeful.
    value.to_string()
}

/// `server/discover`. The first thing sent to any server.
pub fn discover_request(id: i64, version: &str) -> String {
    line(json!({
        "jsonrpc": "2.0",
        "id": id,
        "method": "server/discover",
        "params": { "_meta": meta(version) },
    }))
}

/// `initialize`, for a server that did not understand the above.
pub fn initialize_request(id: i64, version: &str) -> String {
    line(json!({
        "jsonrpc": "2.0",
        "id": id,
        "method": "initialize",
        "params": {
            "protocolVersion": LEGACY_PROTOCOL_VERSION,
            // Deliberately empty. Declaring `sampling` would let a server ask
            // our model to generate text; declaring `roots` would tell it
            // where our files are; declaring `elicitation` would let it put a
            // prompt in front of the person. A browser offers none of the
            // three.
            "capabilities": {},
            "clientInfo": { "name": CLIENT_NAME, "version": version },
        },
    }))
}

/// The notification that finishes a legacy handshake. Not sent to a modern
/// server, which has no handshake to finish.
pub fn initialized_notification() -> String {
    line(json!({ "jsonrpc": "2.0", "method": "notifications/initialized" }))
}

/// `tools/list`, optionally from a cursor.
pub fn tools_list_request(id: i64, era: ServerEra, cursor: Option<&str>, version: &str) -> String {
    let mut params = Map::new();
    if let Some(cursor) = cursor {
        params.insert("cursor".into(), Value::String(cursor.to_string()));
    }
    if era == ServerEra::Modern {
        params.insert("_meta".into(), meta(version));
    }
    line(json!({
        "jsonrpc": "2.0",
        "id": id,
        "method": "tools/list",
        "params": Value::Object(params),
    }))
}

/// `tools/call`.
///
/// `arguments_json` arrives as text because it came from a language model as
/// text. It is parsed here so that an unparseable one is caught before it
/// reaches a server rather than after — and, more to the point, so the object
/// that goes on the wire is the same object the confirmation sheet showed.
pub fn tools_call_request(
    id: i64,
    era: ServerEra,
    tool: &str,
    arguments_json: &str,
    version: &str,
) -> Option<String> {
    let arguments: Value = if arguments_json.trim().is_empty() {
        json!({})
    } else {
        serde_json::from_str(arguments_json).ok()?
    };
    // A tool call's arguments are an object. A bare array or string would be
    // rejected by the server anyway, and refusing it here means the failure
    // reads as "the model wrote nonsense" rather than as "the server broke".
    if !arguments.is_object() {
        return None;
    }

    let mut params = Map::new();
    params.insert("name".into(), Value::String(tool.to_string()));
    params.insert("arguments".into(), arguments);
    if era == ServerEra::Modern {
        params.insert("_meta".into(), meta(version));
    }
    Some(line(json!({
        "jsonrpc": "2.0",
        "id": id,
        "method": "tools/call",
        "params": Value::Object(params),
    })))
}

/// Ask a server to stop working on a request.
///
/// Only meaningful over stdio. On Streamable HTTP the cancellation signal is
/// closing the response stream, and sending this as well would be a message the
/// specification says not to send.
pub fn cancel_notification(request_id: i64, reason: &str) -> String {
    line(json!({
        "jsonrpc": "2.0",
        "method": "notifications/cancelled",
        "params": { "requestId": request_id, "reason": reason },
    }))
}

// `http_headers` used to live here, taking a method and a tool name. It moved
// to `mcp_http`, and grew the era and the session with it: the headers a
// request carries are not the same in both eras, and the version in the header
// has to be the version in the body. Writing it from the line about to be sent
// is what makes the two unable to disagree.

// ---------------------------------------------------------------------------
// Reading what comes back
// ---------------------------------------------------------------------------

/// The id on a line, so the host can match it to what it sent.
///
/// `None` for a notification, which has no id, and for anything unreadable.
pub fn reply_id(raw: &str) -> Option<i64> {
    let value: Value = serde_json::from_str(raw).ok()?;
    value.get("id")?.as_i64()
}

/// Read one line as the answer to the request the host says it is.
pub fn parse_reply(raw: &str, expect: Expect) -> Reply {
    let Ok(value) = serde_json::from_str::<Value>(raw) else {
        return Reply::Ignored;
    };
    if value.get("jsonrpc").and_then(Value::as_str) != Some("2.0") {
        return Reply::Ignored;
    }

    if let Some(error) = value.get("error") {
        let code = error.get("code").and_then(Value::as_i64).unwrap_or(0);
        let message = error
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or("The server did not say why.")
            .to_string();

        if code == UNSUPPORTED_PROTOCOL_VERSION {
            return Reply::VersionRefused {
                supported: string_list(error.pointer("/data/supported")),
            };
        }
        return Reply::Failed { code, message };
    }

    let Some(result) = value.get("result") else {
        return Reply::Ignored;
    };

    match expect {
        Expect::Discover => {
            let info = result.pointer("/_meta/io.modelcontextprotocol~1serverInfo");
            Reply::Discovered {
                server_name: text_at(info, "name"),
                server_version: text_at(info, "version"),
                supported_versions: string_list(result.get("supportedVersions")),
            }
        }
        Expect::Initialize => {
            let version = result
                .get("protocolVersion")
                .and_then(Value::as_str)
                .unwrap_or_default();
            if version.is_empty() {
                return Reply::Malformed {
                    detail: "The server answered without a protocol version.".to_string(),
                };
            }
            let info = result.get("serverInfo");
            Reply::Initialized {
                protocol_version: version.to_string(),
                server_name: text_at(info, "name"),
                server_version: text_at(info, "version"),
            }
        }
        Expect::ToolsList => parse_tools(result),
        Expect::ToolsCall => parse_call(result),
    }
}

/// Read a notification. Only one of them matters to us.
pub fn parse_notification(raw: &str) -> Reply {
    let Ok(value) = serde_json::from_str::<Value>(raw) else {
        return Reply::Ignored;
    };
    match value.get("method").and_then(Value::as_str) {
        Some("notifications/tools/list_changed") => Reply::ToolsChanged,
        _ => Reply::Ignored,
    }
}

fn parse_tools(result: &Value) -> Reply {
    let Some(list) = result.get("tools").and_then(Value::as_array) else {
        return Reply::Malformed {
            detail: "The server answered a tool list with no tools field.".to_string(),
        };
    };

    let tools = list
        .iter()
        .filter_map(|tool| {
            let name = tool.get("name")?.as_str()?.to_string();
            let annotations = tool.get("annotations");
            Some(ReportedTool {
                name,
                description: tool
                    .get("description")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_string(),
                // Kept exactly as sent. It is what a fingerprint is taken over,
                // so re-serialising it would make an approval expire whenever
                // a serde version changed its key order.
                input_schema_json: tool
                    .get("inputSchema")
                    .map(Value::to_string)
                    .unwrap_or_else(|| "{}".to_string()),
                read_only_hint: annotations
                    .and_then(|a| a.get("readOnlyHint"))
                    .and_then(Value::as_bool),
                destructive_hint: annotations
                    .and_then(|a| a.get("destructiveHint"))
                    .and_then(Value::as_bool),
                open_world_hint: annotations
                    .and_then(|a| a.get("openWorldHint"))
                    .and_then(Value::as_bool),
            })
        })
        .collect();

    // An empty string is a valid cursor, so "is there another page" cannot be
    // "is the cursor empty". It is "is the field there at all".
    let next = result.get("nextCursor").and_then(Value::as_str);
    Reply::Tools {
        tools,
        next_cursor: next.unwrap_or_default().to_string(),
        has_more: next.is_some(),
    }
}

/// Flatten a tool's answer into one string.
///
/// What a person and a model both get to see, and therefore behaviour. A block
/// that is not text is named rather than dropped: "the server sent a picture"
/// is information, and a silently missing block is a tool that appears to have
/// returned nothing.
fn parse_call(result: &Value) -> Reply {
    let is_error = result
        .get("isError")
        .and_then(Value::as_bool)
        .unwrap_or(false);

    let mut parts: Vec<String> = Vec::new();
    if let Some(blocks) = result.get("content").and_then(Value::as_array) {
        for block in blocks {
            match block.get("type").and_then(Value::as_str) {
                Some("text") => parts.push(
                    block
                        .get("text")
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .to_string(),
                ),
                Some("image") => parts.push("[an image]".to_string()),
                Some("audio") => parts.push("[a sound]".to_string()),
                Some("resource_link") => parts.push(format!(
                    "[a link to {}]",
                    block
                        .get("uri")
                        .and_then(Value::as_str)
                        .unwrap_or("something")
                )),
                Some("resource") => parts.push(
                    block
                        .pointer("/resource/text")
                        .and_then(Value::as_str)
                        .unwrap_or("[a file]")
                        .to_string(),
                ),
                Some(other) => parts.push(format!("[{other}]")),
                None => {}
            }
        }
    }

    // `structuredContent` is meant to be mirrored into a text block, and
    // usually is. When it is not, showing nothing would be showing nothing.
    if parts.is_empty()
        && let Some(structured) = result.get("structuredContent")
    {
        parts.push(structured.to_string());
    }

    Reply::Called {
        is_error,
        text: parts.join("\n"),
    }
}

fn text_at(value: Option<&Value>, key: &str) -> String {
    value
        .and_then(|v| v.get(key))
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string()
}

fn string_list(value: Option<&Value>) -> Vec<String> {
    value
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(Value::as_str)
                .map(str::to_string)
                .collect()
        })
        .unwrap_or_default()
}

#[cfg(test)]
#[path = "mcp_wire_tests.rs"]
mod tests;
