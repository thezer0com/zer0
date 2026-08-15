//! Which MCP servers are running, what tools they really offer, and whether a
//! remembered approval still applies to the tool in front of you.
//!
//! ## Where this sits
//!
//! The conversation, the tool-call lifecycle and the ledger of what may run
//! without asking all live in [`crate::chat`]. This file is the layer
//! underneath: the browser's own register of what a tool *is*. It answers three
//! questions that the ledger cannot, because the ledger only knows names.
//!
//! **Is this a tool we have?** A model writes a tool name as text. Two servers
//! may both call something `search`, and a server may name its tool anything at
//! all — including something that reads like another server's. Naming is
//! decided here, once, so no host has to invent it.
//!
//! **Is it the same tool it was?** Every tool is fingerprinted over its name,
//! its description and its input schema. When somebody chooses *always*, the
//! shape they saw is recorded beside the answer. A server that later changes
//! any of the three has not been approved: the fingerprints disagree, and the
//! next call asks again. This is the entire defence against a server that is
//! useful for a fortnight and then grows a tool that reads your files, and it
//! costs one hash. Nothing in the ledger alone could catch it — the name did
//! not change.
//!
//! **What can honestly be said about it?** A tool's description is written by
//! the server. It may be shown, but never in the browser's voice; see
//! [`ToolDisclosure`] and ADR-0018. What the browser says as itself is limited
//! to what it can prove without believing anybody: what kind of server this is,
//! what running it costs you, and what the annotations do and do not mean.
//!
//! ## What is deliberately absent
//!
//! Arguments are never checked against a tool's input schema. The server wrote
//! the schema. Validating its own arguments against its own document proves
//! nothing about whether the call is safe, and putting "checked" next to it
//! would be worse than putting nothing.
//!
//! The specification's tool annotations are never allowed to *lower* what a
//! call has to pass. They pick a default and phrase a sentence. A server can
//! make its own tools harder to run by admitting they are destructive; it
//! cannot make them easier by claiming they are not.

use sha2::{Digest, Sha256};

use crate::chat::{ToolConsent, ToolDescriptor};

/// How many tools one server may contribute.
///
/// Not a resource limit. A list longer than this is a list nobody reads, and
/// the review screen is the whole point.
pub const MAX_TOOLS_PER_SERVER: usize = 128;

/// How much of a server's prose is kept. One screen, not one book.
pub const MAX_DESCRIPTION_CHARS: usize = 2_000;

/// How long a server gets to answer before it is called failed.
pub const HANDSHAKE_TIMEOUT_MS: u64 = 15_000;

/// How long a tool call may run before the browser stops waiting.
pub const DEFAULT_CALL_TIMEOUT_MS: u64 = 60_000;

/// What separates a server from a tool in the flat name a model is given.
///
/// Two underscores rather than one, because a server id may not contain them
/// and a tool name may. That asymmetry is what makes the joined name
/// unambiguous.
pub const QUALIFIER: &str = "__";

// ---------------------------------------------------------------------------
// What running a server costs you
// ---------------------------------------------------------------------------

/// What adding a server that runs a program on this machine actually means.
///
/// In the core, and pinned by a test, for the reason ADR-0028 pins the sentence
/// about `<all_urls>`: this is the one line that carries the whole decision, and
/// nothing goes red when a consequence quietly softens back into a category
/// name. macOS and Linux do not get to word it differently.
pub const STDIO_CONSEQUENCE: &str = "This runs a program on your Mac. It can do anything you can do: read your \
     files, reach your network, act as you. zer0 cannot limit it.";

/// The same sentence for a server reached over the network.
pub const HTTP_CONSEQUENCE: &str = "This connects to a website. Whatever the assistant sends it — including \
     anything you paste into the chat — leaves your Mac.";

/// The command line, whole, exactly as it will be run.
///
/// Not shortened, not elided, not prettified. The specification's words for a
/// client offering one-click local server setup are that it MUST "show the
/// exact command that will be executed, without truncation", and a view that
/// ran out of room and put an ellipsis through the middle of it would be hiding
/// the argument that matters. The screen scrolls; the string does not shrink.
pub fn exact_command(command: &str, args: &[String]) -> String {
    if args.is_empty() {
        command.to_string()
    } else {
        format!("{command} {}", args.join(" "))
    }
}

// ---------------------------------------------------------------------------
// What a server is doing
// ---------------------------------------------------------------------------

/// Why a server is not usable. Every one is something a person can be told
/// without being shown a stack trace.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum McpFailure {
    /// The program is not installed, or is not where the configuration says.
    NotFound,
    /// It started and then stopped on its own.
    Crashed,
    /// It never answered.
    HandshakeTimeout,
    /// It answered with a protocol revision this browser does not speak.
    VersionMismatch,
    /// It answered with something that is not the protocol at all.
    Malformed,
    /// The connection went away mid-session.
    Disconnected,
    /// An endpoint that could not be reached.
    Unreachable,
    /// An endpoint that refused us.
    Unauthorized,
    /// The browser would not accept the configuration.
    Rejected,
}

impl McpFailure {
    /// What to say when this is why nothing works.
    ///
    /// Behaviour rather than copy: a failure that reads as a glitch teaches
    /// people to retry, and one that reads as a fact teaches them what to fix.
    pub fn reason(self) -> &'static str {
        match self {
            McpFailure::NotFound => "zer0 could not find that program.",
            McpFailure::Crashed => "The server stopped on its own.",
            McpFailure::HandshakeTimeout => "The server never answered.",
            McpFailure::VersionMismatch => {
                "This server speaks a version of MCP that zer0 does not."
            }
            McpFailure::Malformed => "The server sent something zer0 could not read.",
            McpFailure::Disconnected => "The connection to the server was lost.",
            McpFailure::Unreachable => "zer0 could not reach that address.",
            McpFailure::Unauthorized => "That server would not let zer0 in.",
            McpFailure::Rejected => "zer0 will not run this server as configured.",
        }
    }
}

/// Where a server is in its life.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum McpServerState {
    /// Configured, never connected. Not an error.
    Idle,
    /// Connecting, or working out which revision it speaks.
    Starting { since_ms: u64 },
    /// Connected. `tools` may still be empty until the first listing lands.
    Ready {
        protocol_version: String,
        server_name: String,
        server_version: String,
    },
    Failed {
        failure: McpFailure,
        message: String,
    },
    /// Deliberately stopped.
    Stopped,
}

impl McpServerState {
    pub fn is_ready(&self) -> bool {
        matches!(self, McpServerState::Ready { .. })
    }
}

// ---------------------------------------------------------------------------
// Tools
// ---------------------------------------------------------------------------

/// A tool exactly as a server described it, before the browser has had an
/// opinion.
///
/// Everything here is hostile input: it came off a pipe from a program we did
/// not write. Nothing is trusted, everything is bounded, and the three hints
/// are the server's claims about its own code.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct ReportedTool {
    pub name: String,
    /// The server's own prose. Shown attributed, never as the browser's claim.
    pub description: String,
    /// The raw JSON of `inputSchema`. Never parsed here — fingerprinted, and
    /// handed on to whatever builds the model's request.
    pub input_schema_json: String,
    /// `annotations.readOnlyHint`. Absent means false, per the specification.
    pub read_only_hint: Option<bool>,
    /// `annotations.destructiveHint`. Absent means **true**, per the
    /// specification: a server that says nothing has said the pessimistic
    /// thing.
    pub destructive_hint: Option<bool>,
    /// `annotations.openWorldHint`. Absent means **true**. This is the one that
    /// decides whether a call can carry your data off the machine.
    pub open_world_hint: Option<bool>,
}

/// A tool after the browser has looked at it: named unambiguously, bounded, and
/// pinned to a fingerprint an approval can be bound to.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct McpTool {
    pub server: String,
    /// As the server said it. What goes back on the wire.
    pub name: String,
    /// `server__name`. The flat name a model is given, and the only name that
    /// crosses into a provider's tool-calling API.
    pub qualified_name: String,
    pub description: String,
    pub input_schema_json: String,
    pub read_only_hint: Option<bool>,
    pub destructive_hint: Option<bool>,
    pub open_world_hint: Option<bool>,
    /// Hex SHA-256 over name, description and schema.
    pub fingerprint: String,
}

impl McpTool {
    /// Whether the browser is willing to offer "do not ask me again" for this
    /// tool at all.
    ///
    /// Only where the server calls the tool read-only, non-destructive **and**
    /// closed-world. Note which way the defaults run: absent `destructiveHint`
    /// and absent `openWorldHint` both mean `true`, so a server that declines
    /// to describe itself gets no standing approval offered — and that is the
    /// specification's own choice, not ours.
    ///
    /// Claiming read-only therefore buys the *offer* of a tick box. It never
    /// buys the tick.
    pub fn may_be_standing(&self) -> bool {
        self.read_only_hint == Some(true)
            && !self.destructive_hint.unwrap_or(true)
            && !self.open_world_hint.unwrap_or(true)
    }

    /// What the chat side hands a model. The bridge between this register and
    /// [`crate::chat`].
    ///
    /// Everything the fingerprint was taken over travels with it — the name,
    /// the description and the schema — so a descriptor can be checked against
    /// this register by anybody holding one, and a provider host has what it
    /// needs to write a real tool definition. The `qualified_name` and the
    /// fingerprint itself do not travel: a host that compared fingerprints
    /// would be a second place deciding whether a call may run.
    pub fn descriptor(&self) -> ToolDescriptor {
        ToolDescriptor {
            server: self.server.clone(),
            tool: self.name.clone(),
            summary: self.description.clone(),
            input_schema_json: self.input_schema_json.clone(),
            read_only_hint: self.read_only_hint,
            destructive_hint: self.destructive_hint,
            open_world_hint: self.open_world_hint,
        }
    }
}

/// Everything the browser can honestly say about a tool, separated by who said
/// it.
///
/// Two fields rather than one paragraph, because the difference between "zer0
/// says this reads your files" and "this server says it reads your files" is
/// the whole difference between a warning and a quotation. A view that
/// concatenated them would be putting our name on a stranger's sentence.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct ToolDisclosure {
    pub server: String,
    pub tool: String,
    pub qualified_name: String,
    /// What zer0 knows, in zer0's voice.
    pub ours: String,
    /// What the server claims, to be shown as a quotation. Empty when the
    /// server said nothing — which is itself worth showing as nothing.
    pub theirs: String,
    /// Whether "do not ask me again" may be offered at all.
    pub may_be_standing: bool,
}

/// Trim a tool name to what a provider's tool-calling API will accept, or
/// refuse it.
///
/// Refusing is the interesting branch. A server can name a tool anything —
/// something with a newline that would break the screen it is drawn on,
/// something that collides with another name once cleaned up, something that is
/// not a name at all. Those are dropped rather than repaired, the same decision
/// ADR-0028 took for a host pattern nobody could parse, and for the same
/// reason: a repaired name is a name nobody approved.
pub fn sanitize_tool_name(raw: &str) -> Option<String> {
    if raw.is_empty() || raw.len() > 64 {
        return None;
    }
    if !raw
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
    {
        return None;
    }
    Some(raw.to_string())
}

/// Whether an id may be used as the left half of a qualified name.
///
/// Not a style rule. An id containing the qualifier would let one server
/// produce a joined name that reads as if it came from another, which is the
/// difference between namespacing and decoration.
pub fn is_valid_server_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 64
        && id
            .chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
}

/// Join a server and a tool into the one flat name a model is shown.
pub fn qualified_name(server: &str, tool: &str) -> String {
    format!("{server}{QUALIFIER}{tool}")
}

/// Split a flat name back apart at the **first** separator.
///
/// First and not last, deliberately: a tool name may contain the separator and
/// a server id may not, so splitting at the front is the parse that cannot be
/// steered by the untrusted half.
pub fn split_qualified(qualified: &str) -> Option<(String, String)> {
    let (server, tool) = qualified.split_once(QUALIFIER)?;
    if server.is_empty() || tool.is_empty() {
        return None;
    }
    Some((server.to_string(), tool.to_string()))
}

/// What an approval is bound to.
///
/// Length-prefixed per field, so a server cannot move bytes across a boundary —
/// renaming a tool into its own description — to land on a hash somebody
/// already approved.
pub fn fingerprint(name: &str, description: &str, input_schema_json: &str) -> String {
    let mut hasher = Sha256::new();
    for field in [name, description, input_schema_json] {
        hasher.update((field.len() as u64).to_le_bytes());
        hasher.update(field.as_bytes());
    }
    let digest = hasher.finalize();
    let mut hex = String::with_capacity(digest.len() * 2);
    for byte in digest {
        hex.push_str(&format!("{byte:02x}"));
    }
    hex
}

fn truncate(text: &str, max_chars: usize) -> String {
    if text.chars().count() <= max_chars {
        return text.to_string();
    }
    let mut out: String = text.chars().take(max_chars).collect();
    out.push('…');
    out
}

// ---------------------------------------------------------------------------
// The verdict
// ---------------------------------------------------------------------------

/// Whether a named tool may be called, and on what terms.
///
/// The one place that combines "does this exist", "is its server up" and "does
/// the remembered answer still apply to it". Everything about MCP that could
/// hurt somebody goes through this match.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum ToolVerdict {
    /// No server offers this. A model naming it has invented it, or is naming
    /// something that has since gone away.
    Unknown,
    /// It exists, but its server is not connected.
    NotReady,
    /// Refused when it was reviewed.
    Refused,
    /// Nobody has ever answered about this one. The call has to be confirmed,
    /// with its arguments on screen.
    MustConfirm,
    /// Approved once and for all, and the tool is still the one that was
    /// approved.
    Approved,
    /// Approved once — but not this. The definition moved after the answer was
    /// given, so the answer does not apply and the call is confirmed again.
    ///
    /// Distinct from [`ToolVerdict::MustConfirm`] because the two want
    /// different sentences: "nobody has said" and "what you said was about
    /// something else" are not the same news.
    Changed,
}

impl ToolVerdict {
    /// Whether anything may be sent without asking first.
    pub fn runs_unattended(self) -> bool {
        matches!(self, ToolVerdict::Approved)
    }

    /// Whether this is a refusal rather than a question.
    pub fn is_refusal(self) -> bool {
        matches!(
            self,
            ToolVerdict::Unknown | ToolVerdict::NotReady | ToolVerdict::Refused
        )
    }

    pub fn reason(self) -> &'static str {
        match self {
            ToolVerdict::Unknown => "There is no tool by that name.",
            ToolVerdict::NotReady => "That server is not connected.",
            ToolVerdict::Refused => "You refused this tool.",
            ToolVerdict::MustConfirm => "Nobody has approved this tool yet.",
            ToolVerdict::Approved => "You approved this tool.",
            ToolVerdict::Changed => {
                "This is not the tool you approved — the server has changed it."
            }
        }
    }
}

// ---------------------------------------------------------------------------
// The register
// ---------------------------------------------------------------------------

/// What one server is and what it currently offers.
#[derive(Debug, Clone, PartialEq, Eq)]
struct Entry {
    id: String,
    state: McpServerState,
    tools: Vec<McpTool>,
    /// Names the server offered that the browser would not take. Kept so a
    /// screen can say so: a tool that quietly vanished is indistinguishable
    /// from one that was never offered.
    dropped: Vec<String>,
}

/// One remembered shape, beside the ledger's remembered answer.
///
/// Deliberately *not* a second consent ledger. [`ToolConsent`] says whether;
/// this says what it was about. Splitting them this way means the two cannot
/// drift into disagreeing about the answer, because only one of them holds one.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct ApprovedShape {
    pub server: String,
    pub tool: String,
    pub fingerprint: String,
}

/// Every MCP server this browser knows about, and what it offers.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct McpRegistry {
    servers: Vec<Entry>,
    shapes: Vec<ApprovedShape>,
}

impl McpRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    /// Rebuild the remembered shapes from storage.
    pub fn load_shapes(&mut self, shapes: Vec<ApprovedShape>) {
        self.shapes = shapes;
    }

    pub fn shapes(&self) -> &[ApprovedShape] {
        &self.shapes
    }

    pub fn server_ids(&self) -> Vec<String> {
        self.servers.iter().map(|s| s.id.clone()).collect()
    }

    /// Take a server on, or return `false` if the id is unusable or taken.
    pub fn adopt_server(&mut self, id: &str) -> bool {
        if !is_valid_server_id(id) || self.servers.iter().any(|s| s.id == id) {
            return false;
        }
        self.servers.push(Entry {
            id: id.to_string(),
            state: McpServerState::Idle,
            tools: Vec::new(),
            dropped: Vec::new(),
        });
        true
    }

    /// Drop a server and everything remembered about it.
    ///
    /// The shapes go too. A server added again under the same name could point
    /// at another program entirely, and an approval bound to the old one must
    /// not survive to describe the new one.
    pub fn forget_server(&mut self, id: &str) {
        self.servers.retain(|s| s.id != id);
        self.shapes.retain(|s| s.server != id);
    }

    pub fn state_of(&self, id: &str) -> McpServerState {
        self.servers
            .iter()
            .find(|s| s.id == id)
            .map(|s| s.state.clone())
            .unwrap_or(McpServerState::Idle)
    }

    /// Record where a server has got to.
    ///
    /// Anything other than `Ready` empties its tool list. A tool from a server
    /// that is not running is a tool that cannot be called, and leaving it
    /// listed would put it in front of a model that would then ask for it.
    pub fn set_state(&mut self, id: &str, state: McpServerState) {
        let Some(entry) = self.servers.iter_mut().find(|s| s.id == id) else {
            return;
        };
        if !state.is_ready() {
            entry.tools.clear();
            entry.dropped.clear();
        }
        entry.state = state;
    }

    /// Whether a server that started at `since_ms` has run out of patience.
    pub fn handshake_expired(&self, id: &str, now_ms: u64) -> bool {
        match self.state_of(id) {
            McpServerState::Starting { since_ms } => {
                now_ms.saturating_sub(since_ms) >= HANDSHAKE_TIMEOUT_MS
            }
            McpServerState::Idle
            | McpServerState::Ready { .. }
            | McpServerState::Failed { .. }
            | McpServerState::Stopped => false,
        }
    }

    /// Replace what one server offers.
    ///
    /// Whole rather than incremental, matching `Action::ToolsListed`: a tool
    /// that has gone away has to stop being callable, and there is no "removed"
    /// event to rely on.
    ///
    /// Returns the names that were not taken.
    pub fn set_tools(&mut self, server: &str, reported: &[ReportedTool]) -> Vec<String> {
        let Some(index) = self.servers.iter().position(|s| s.id == server) else {
            // A listing for a server nobody configured is not an error to
            // report anywhere; it is a message about something that does not
            // exist.
            return Vec::new();
        };
        let (tools, dropped) = adopt_tools(server, reported);
        self.servers[index].tools = tools;
        self.servers[index].dropped = dropped.clone();
        dropped
    }

    pub fn tools(&self) -> Vec<&McpTool> {
        self.servers.iter().flat_map(|s| s.tools.iter()).collect()
    }

    pub fn dropped(&self, server: &str) -> Vec<String> {
        self.servers
            .iter()
            .find(|s| s.id == server)
            .map(|s| s.dropped.clone())
            .unwrap_or_default()
    }

    pub fn tool(&self, server: &str, tool: &str) -> Option<&McpTool> {
        self.servers
            .iter()
            .find(|s| s.id == server)?
            .tools
            .iter()
            .find(|t| t.name == tool)
    }

    /// Find a tool by the flat name a model used.
    ///
    /// Goes through [`split_qualified`], so a server cannot reach another
    /// server's tool by naming its own tool cleverly.
    pub fn tool_by_qualified_name(&self, qualified: &str) -> Option<&McpTool> {
        let (server, tool) = split_qualified(qualified)?;
        self.tool(&server, &tool)
    }

    /// What to hand a model, which is not everything that exists.
    ///
    /// A tool somebody refused is not described to the model at all. Describing
    /// it and refusing the call afterwards would burn a turn, tell whatever is
    /// reading the conversation that the tool exists, and — the part that
    /// matters — teach the model to keep asking.
    pub fn offerable(&self, consent: &ToolConsent) -> Vec<ToolDescriptor> {
        self.servers
            .iter()
            .filter(|s| s.state.is_ready())
            .flat_map(|s| s.tools.iter())
            .filter(|t| consent.decision(&t.server, &t.name) != Some(false))
            .map(McpTool::descriptor)
            .collect()
    }

    /// The one decision. See [`ToolVerdict`].
    pub fn verdict(&self, consent: &ToolConsent, server: &str, tool: &str) -> ToolVerdict {
        let Some(known) = self.tool(server, tool) else {
            return ToolVerdict::Unknown;
        };
        if !self.state_of(server).is_ready() {
            return ToolVerdict::NotReady;
        }
        match consent.decision(server, tool) {
            None => ToolVerdict::MustConfirm,
            Some(false) => ToolVerdict::Refused,
            Some(true) => match self.approved_shape(server, tool) {
                // An approval with no recorded shape is an approval from before
                // this browser recorded shapes, or one recorded through a path
                // that forgot to. Either way nothing binds it to this tool, so
                // it does not run unattended.
                None => ToolVerdict::Changed,
                Some(shape) if shape.fingerprint == known.fingerprint => ToolVerdict::Approved,
                Some(_) => ToolVerdict::Changed,
            },
        }
    }

    fn approved_shape(&self, server: &str, tool: &str) -> Option<&ApprovedShape> {
        self.shapes
            .iter()
            .find(|s| s.server == server && s.tool == tool)
    }

    /// Bind an answer to the tool it was given about.
    ///
    /// Called at the moment a *remembered* answer is written down, and at no
    /// other moment. Answering "just this once" records nothing here, because
    /// there is nothing to keep.
    ///
    /// Returns whether there was a tool to bind to. `false` means somebody
    /// approved a name the browser does not have, which must not become a
    /// standing approval waiting for a server to supply the tool later.
    pub fn remember_shape(&mut self, server: &str, tool: &str) -> bool {
        let Some(fingerprint) = self.tool(server, tool).map(|t| t.fingerprint.clone()) else {
            return false;
        };
        self.shapes
            .retain(|s| !(s.server == server && s.tool == tool));
        self.shapes.push(ApprovedShape {
            server: server.to_string(),
            tool: tool.to_string(),
            fingerprint,
        });
        true
    }

    /// Drop a bound shape, so nothing is left claiming an answer that is gone.
    pub fn forget_shape(&mut self, server: &str, tool: &str) {
        self.shapes
            .retain(|s| !(s.server == server && s.tool == tool));
    }

    /// Tools whose remembered approval no longer applies, so a screen can say
    /// how many there are rather than letting each one surprise somebody
    /// mid-conversation.
    pub fn tools_needing_review(&self, consent: &ToolConsent) -> Vec<&McpTool> {
        self.servers
            .iter()
            .filter(|s| s.state.is_ready())
            .flat_map(|s| s.tools.iter())
            .filter(|t| self.verdict(consent, &t.server, &t.name) == ToolVerdict::Changed)
            .collect()
    }

    /// What can honestly be said about a tool, and who said which half.
    pub fn disclosure(&self, tool: &McpTool) -> ToolDisclosure {
        ToolDisclosure {
            server: tool.server.clone(),
            tool: tool.name.clone(),
            qualified_name: tool.qualified_name.clone(),
            ours: ours_about(tool),
            theirs: tool.description.clone(),
            may_be_standing: tool.may_be_standing(),
        }
    }
}

/// Turn what a server reported into what the browser will offer.
///
/// Drops, in order: names that cannot be sanitized, names already taken within
/// this server, and everything past [`MAX_TOOLS_PER_SERVER`]. The dropped ones
/// come back so a screen can list them.
pub fn adopt_tools(server: &str, reported: &[ReportedTool]) -> (Vec<McpTool>, Vec<String>) {
    let mut tools: Vec<McpTool> = Vec::new();
    let mut dropped = Vec::new();

    for tool in reported {
        if tools.len() >= MAX_TOOLS_PER_SERVER {
            dropped.push(tool.name.clone());
            continue;
        }
        let Some(name) = sanitize_tool_name(&tool.name) else {
            dropped.push(tool.name.clone());
            continue;
        };
        if tools.iter().any(|t| t.name == name) {
            dropped.push(tool.name.clone());
            continue;
        }
        let description = truncate(&tool.description, MAX_DESCRIPTION_CHARS);
        tools.push(McpTool {
            server: server.to_string(),
            qualified_name: qualified_name(server, &name),
            fingerprint: fingerprint(&name, &description, &tool.input_schema_json),
            name,
            description,
            input_schema_json: tool.input_schema_json.clone(),
            read_only_hint: tool.read_only_hint,
            destructive_hint: tool.destructive_hint,
            open_world_hint: tool.open_world_hint,
        });
    }

    (tools, dropped)
}

/// The half of a tool's description that zer0 is willing to put its name to.
///
/// It says only what holds without believing the server: what the annotations
/// claim, and what that claim is worth.
///
/// The difference between an annotation that is *absent* and one that is
/// *false* matters here and nowhere else. For deciding what a call has to pass
/// through, absent means the pessimistic reading, because that is the
/// specification's own default. For deciding what to *say*, absent means the
/// server has not said — and printing "this tool deletes things" over a server
/// that never claimed it would be the browser asserting something it cannot
/// prove, which is the failure ADR-0018 is about. Same treatment, different
/// sentence.
fn ours_about(tool: &McpTool) -> String {
    match (
        tool.read_only_hint,
        tool.destructive_hint,
        tool.open_world_hint,
    ) {
        (Some(true), Some(false), Some(false)) => {
            "This server says this tool only reads, and only from itself. zer0 \
             cannot check that — it is the server's word about its own code."
                .to_string()
        }
        (Some(true), Some(false), _) => {
            "This server says this tool only reads, but that it reaches other \
             services. Anything sent to it can leave your Mac."
                .to_string()
        }
        (_, Some(true), _) => "This server says this tool changes or deletes things. zer0 asks \
             every time, and shows you what is being sent."
            .to_string(),
        _ => "The server has not said what this tool does, so zer0 treats it as if it could \
             change anything: it asks every time, and shows you what is being sent."
            .to_string(),
    }
}

#[cfg(test)]
#[path = "mcp_tests.rs"]
mod tests;
