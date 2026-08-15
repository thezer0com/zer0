//! The MCP surface the shell talks to.
//!
//! Two kinds of thing live here and they are different kinds of thing.
//!
//! **Free functions** are the wire. A host builds a line, writes it down a
//! pipe, reads a line back, and hands it here to be read. Nothing about the
//! protocol is decided on the Swift side, so a Linux host that reimplements
//! `Process` does not also reimplement JSON-RPC, era detection, or what a
//! content block turns into.
//!
//! **Methods on [`Zer0`]** are the register: which servers are up, what they
//! offer, and whether a remembered approval still applies to the tool in front
//! of you. State, so the core owns it.
//!
//! The one method worth reading twice is [`Zer0::remember_tool_answer`]. It
//! writes the ledger row *and* binds it to the tool's current shape, in one
//! call, because those two facts are one decision and there must be no way to
//! record half of it. A grant with no shape behind it fails closed — see
//! `an_approval_with_no_recorded_shape_never_runs_unattended`.

use crate::chat::ToolDescriptor;
use crate::ffi::Zer0;
use crate::mcp::{
    self, ApprovedShape, McpFailure, McpServerState, McpTool, ReportedTool, ToolDisclosure,
    ToolVerdict,
};
use crate::mcp_http::{self, EndpointVerdict, HttpOutcome};
use crate::mcp_wire::{self, EraProbe, Expect, Reply, ServerEra};

// ---------------------------------------------------------------------------
// The wire
// ---------------------------------------------------------------------------

/// The revision this browser prefers, so a host can put it in a log line
/// without inventing its own copy of the string.
#[uniffi::export]
pub fn mcp_protocol_version() -> String {
    mcp_wire::PROTOCOL_VERSION.to_string()
}

#[uniffi::export]
pub fn mcp_discover_request(id: i64, app_version: String) -> String {
    mcp_wire::discover_request(id, &app_version)
}

#[uniffi::export]
pub fn mcp_initialize_request(id: i64, app_version: String) -> String {
    mcp_wire::initialize_request(id, &app_version)
}

#[uniffi::export]
pub fn mcp_initialized_notification() -> String {
    mcp_wire::initialized_notification()
}

#[uniffi::export]
pub fn mcp_tools_list_request(
    id: i64,
    era: ServerEra,
    cursor: Option<String>,
    app_version: String,
) -> String {
    mcp_wire::tools_list_request(id, era, cursor.as_deref(), &app_version)
}

/// `None` when the model's arguments are not a JSON object, which is the one
/// case where nothing may be sent at all.
#[uniffi::export]
pub fn mcp_tools_call_request(
    id: i64,
    era: ServerEra,
    tool: String,
    arguments_json: String,
    app_version: String,
) -> Option<String> {
    mcp_wire::tools_call_request(id, era, &tool, &arguments_json, &app_version)
}

#[uniffi::export]
pub fn mcp_cancel_notification(request_id: i64, reason: String) -> String {
    mcp_wire::cancel_notification(request_id, &reason)
}

/// The id on a line, so a host can match a reply to what it sent without
/// parsing the rest.
/// How many pages of `tools/list` a host may follow. A cursor is opaque and a
/// server controls it, so a server can hand one out forever.
#[uniffi::export]
pub fn mcp_max_tool_pages() -> u32 {
    mcp_wire::MAX_TOOL_PAGES
}

#[uniffi::export]
pub fn mcp_reply_id(raw: String) -> Option<i64> {
    mcp_wire::reply_id(&raw)
}

#[uniffi::export]
pub fn mcp_parse_reply(raw: String, expect: Expect) -> Reply {
    mcp_wire::parse_reply(&raw, expect)
}

#[uniffi::export]
pub fn mcp_parse_notification(raw: String) -> Reply {
    mcp_wire::parse_notification(&raw)
}

/// What one answer to `server/discover` says about the whole server.
#[uniffi::export]
pub fn mcp_detect_era(reply: Reply) -> EraProbe {
    mcp_wire::detect_era(&reply)
}

/// The headers one Streamable HTTP request carries, read off the line that is
/// about to be sent so the header and the body cannot name different versions.
///
/// `era` is `None` only while the era probe is still out, and the probe is
/// itself a modern request — so that case is not a guess.
#[uniffi::export]
pub fn mcp_http_headers(
    era: Option<ServerEra>,
    session: Option<String>,
    line: String,
) -> Vec<McpHeader> {
    mcp_http::http_headers(era, session.as_deref(), &line)
        .into_iter()
        .map(|(name, value)| McpHeader { name, value })
        .collect()
}

/// The `Authorization` header for a token out of the Keychain, or `None` when
/// there is no token. The one place a credential becomes a header.
#[uniffi::export]
pub fn mcp_authorization_header(token: String) -> Option<McpHeader> {
    mcp_http::authorization_header(&token).map(|(name, value)| McpHeader { name, value })
}

/// A header, as a record, because uniffi has no tuple.
#[derive(Debug, Clone, uniffi::Record)]
pub struct McpHeader {
    pub name: String,
    pub value: String,
}

/// Whether an address out of the configuration may be reached at all.
///
/// The rule, not a hint: `https` anywhere, `http` only to this machine. A host
/// that asked this and then connected anyway would be a host with its own
/// security policy, which is the thing ADR-0002 exists to prevent.
#[uniffi::export]
pub fn mcp_endpoint_verdict(url: String) -> EndpointVerdict {
    mcp_http::endpoint_verdict(&url)
}

/// What an HTTP status says about a server, and the sentence to show for it.
#[uniffi::export]
pub fn mcp_http_status_failure(
    status: u16,
    allow: Option<String>,
    authenticate: Option<String>,
) -> HttpOutcome {
    mcp_http::http_status_failure(status, allow.as_deref(), authenticate.as_deref())
}

/// The messages inside one response body.
///
/// Not one per line: a server may answer a POST with an event stream, and a
/// host that assumed otherwise would sit waiting on a reply it had already been
/// given.
#[uniffi::export]
pub fn mcp_http_reply_lines(content_type: String, body: String) -> Vec<String> {
    mcp_http::http_reply_lines(&content_type, &body)
}

// ---------------------------------------------------------------------------
// The words
// ---------------------------------------------------------------------------

/// What adding a server that runs a program on this machine costs you.
#[uniffi::export]
pub fn mcp_stdio_consequence() -> String {
    mcp::STDIO_CONSEQUENCE.to_string()
}

/// The same, for one reached over the network.
#[uniffi::export]
pub fn mcp_http_consequence() -> String {
    mcp::HTTP_CONSEQUENCE.to_string()
}

/// The command line, whole. Never shortened; see [`mcp::exact_command`].
#[uniffi::export]
pub fn mcp_exact_command(command: String, args: Vec<String>) -> String {
    mcp::exact_command(&command, &args)
}

/// Whether an id can be used as a server's, checked in one place so the add
/// sheet refuses the same things the register does.
#[uniffi::export]
pub fn mcp_is_valid_server_id(id: String) -> bool {
    mcp::is_valid_server_id(&id)
}

/// The flat name a model is given for one tool.
#[uniffi::export]
pub fn mcp_qualified_name(server: String, tool: String) -> String {
    mcp::qualified_name(&server, &tool)
}

/// Split a flat name back into a server and a tool, or `None` if it is not one.
#[uniffi::export]
pub fn mcp_split_qualified(qualified: String) -> Option<McpToolName> {
    mcp::split_qualified(&qualified).map(|(server, tool)| McpToolName { server, tool })
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct McpToolName {
    pub server: String,
    pub tool: String,
}

#[uniffi::export]
pub fn mcp_failure_reason(failure: McpFailure) -> String {
    failure.reason().to_string()
}

#[uniffi::export]
pub fn mcp_verdict_reason(verdict: ToolVerdict) -> String {
    verdict.reason().to_string()
}

#[uniffi::export]
pub fn mcp_verdict_runs_unattended(verdict: ToolVerdict) -> bool {
    verdict.runs_unattended()
}

#[uniffi::export]
pub fn mcp_verdict_is_refusal(verdict: ToolVerdict) -> bool {
    verdict.is_refusal()
}

// ---------------------------------------------------------------------------
// The register
// ---------------------------------------------------------------------------

#[uniffi::export]
impl Zer0 {
    /// Take a server on. `false` means the id is unusable or already taken, and
    /// nothing was started.
    pub fn adopt_mcp_server(&self, id: String) -> bool {
        self.lock().session.mcp.adopt_server(&id)
    }

    /// Drop a server and everything bound to it.
    ///
    /// The shapes go with it: a server added again under the same name could
    /// point at another program entirely, and an approval bound to the old one
    /// must not survive to describe the new one.
    pub fn forget_mcp_server(&self, id: String) {
        self.lock().session.mcp.forget_server(&id);
    }

    pub fn mcp_server_state(&self, id: String) -> McpServerState {
        self.lock().session.mcp.state_of(&id)
    }

    pub fn set_mcp_server_state(&self, id: String, state: McpServerState) {
        self.lock().session.mcp.set_state(&id, state);
    }

    /// Whether a server that is still starting has run out of patience.
    /// `now_ms` comes from the shell for the same reason `Action::Tick` does.
    pub fn mcp_handshake_expired(&self, id: String, now_ms: u64) -> bool {
        self.lock().session.mcp.handshake_expired(&id, now_ms)
    }

    /// Replace what one server offers. Returns the names that were not taken,
    /// so a screen can say what went rather than showing a shorter list.
    pub fn set_mcp_tools(&self, server: String, tools: Vec<ReportedTool>) -> Vec<String> {
        self.lock().session.mcp.set_tools(&server, &tools)
    }

    pub fn mcp_tools(&self, server: String) -> Vec<McpTool> {
        self.lock()
            .session
            .mcp
            .tools()
            .into_iter()
            .filter(|t| t.server == server)
            .cloned()
            .collect()
    }

    /// What may be handed to a model right now. A refused tool is not in here.
    pub fn offerable_mcp_tools(&self) -> Vec<ToolDescriptor> {
        let state = self.lock();
        state.session.mcp.offerable(state.session.chat.consent())
    }

    /// Whether this tool may be called, and on what terms. See
    /// [`ToolVerdict`].
    pub fn mcp_tool_verdict(&self, server: String, tool: String) -> ToolVerdict {
        let state = self.lock();
        state
            .session
            .mcp
            .verdict(state.session.chat.consent(), &server, &tool)
    }

    /// Write down a *remembered* answer about a tool, bound to the tool it was
    /// given about.
    ///
    /// One call, because the answer and the shape it was given about are one
    /// decision. Two calls would be two chances to record half of it, and the
    /// half that goes missing is always the one that fails open.
    ///
    /// The same function the reducer uses for `ConsentChoice::Always` and for
    /// `Action::SetToolConsent`, so Settings and a consent prompt cannot write
    /// different amounts of the same answer.
    ///
    /// Returns `false` when `allowed` and there is no such tool to bind to, in
    /// which case nothing was written: a standing approval must never sit
    /// waiting for a server to supply a matching tool later. A refusal needs no
    /// shape and is always written — see `Session::remember_tool_answer`.
    pub fn remember_tool_answer(
        &self,
        server: String,
        tool: String,
        allowed: bool,
        decided_at_ms: u64,
    ) -> bool {
        self.lock()
            .session
            .remember_tool_answer(&server, &tool, allowed, decided_at_ms)
    }

    /// Take a remembered answer back, both halves of it, so the next call asks
    /// again.
    pub fn forget_tool_answer(&self, server: String, tool: String) -> bool {
        self.lock().session.forget_tool_answer(&server, &tool)
    }

    /// Tools whose remembered approval no longer applies because the server
    /// changed them. What a "needs review" badge counts.
    pub fn mcp_tools_needing_review(&self) -> Vec<McpTool> {
        let state = self.lock();
        state
            .session
            .mcp
            .tools_needing_review(state.session.chat.consent())
            .into_iter()
            .cloned()
            .collect()
    }

    /// What can honestly be said about a tool, and who said which half.
    pub fn mcp_tool_disclosure(&self, server: String, tool: String) -> Option<ToolDisclosure> {
        let state = self.lock();
        let found = state.session.mcp.tool(&server, &tool)?;
        Some(state.session.mcp.disclosure(found))
    }

    /// Every shape currently bound, for whatever saves the session.
    pub fn mcp_approved_shapes(&self) -> Vec<ApprovedShape> {
        self.lock().session.mcp.shapes().to_vec()
    }

    pub fn load_mcp_approved_shapes(&self, shapes: Vec<ApprovedShape>) {
        self.lock().session.mcp.load_shapes(shapes);
    }
}
