//! Talking to a language model, without the core knowing whose.
//!
//! # What this is
//!
//! A **pure, synchronous translation layer** sitting under
//! [`EngineCommand::StartChatReply`](crate::EngineCommand). It builds requests
//! and it decodes replies. It opens no socket, spawns no task, reads no file
//! and holds no secret. Given the same bytes it produces the same events every
//! time, with no network in the room — which is what makes every rule in here
//! testable.
//!
//! The shape is the one `EngineHost` already established for WebKit:
//!
//! ```text
//!   StartChatReply ──▶ provider::request() ──▶ HttpRequest
//!                                                   │
//!                                     shell: URLSession, TLS, Keychain
//!                                                   │
//!   Action::ChatReply* ◀── StreamEvent ◀── StreamDecoder::push() ◀── bytes
//! ```
//!
//! The shell owns the connection, the token and the cancel. It owns no
//! knowledge of what a `content_block_delta` is, and neither does the reducer.
//!
//! # Why the core never names a provider
//!
//! Nothing in [`crate::protocol`] says `Anthropic`. Which vendor a conversation
//! talks to is **configuration**: a [`ProviderEndpoint`] read off the config
//! file, resolved by the host. The core's half is a transcript and a list of
//! tools.
//!
//! [`WireFormat`] does name vendors, and this is the right place for it — a
//! wire format is named after whoever invented it, the way SSE is. What it is
//! *not* is a list of who you can talk to: one [`WireFormat::OpenAiChat`] entry
//! covers OpenAI, Groq, Together, OpenRouter, vLLM, LM Studio and Ollama's
//! compatibility endpoint, because they all speak it. A new vendor on an
//! existing wire is a line of config and no code at all.
//!
//! # Why a token is not in here
//!
//! [`ProviderEndpoint`] has no field for one, and that is structural rather
//! than polite. An endpoint is the thing written to the config file, so an
//! endpoint that *could* hold a secret is one that eventually does. The token
//! arrives as an argument to [`request`], from the Keychain, by way of a shell
//! that read it a microsecond earlier and does not keep it.

mod anthropic;
mod error;
mod gemini;
mod ollama;
mod openai;

#[cfg(feature = "ffi")]
mod ffi;

use crate::chat::{
    ChatErrorKind, Message as ChatMessage, MessageRole, ToolCallId, ToolCallState, ToolInvocation,
};
use crate::protocol::ReplyStop;

pub use error::{ProviderError, ProviderErrorKind};

// --- who we are talking to -------------------------------------------------

/// The shape of the conversation on the wire.
///
/// Not a vendor list. Four entries because four genuinely incompatible shapes
/// exist; a fifth vendor speaking one of these needs a config entry, not a
/// module.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum WireFormat {
    /// `POST /v1/messages`. Named content blocks, named SSE events, tool input
    /// streamed as fragments of JSON text.
    AnthropicMessages,
    /// `POST /v1/chat/completions`. The most widely spoken wire there is.
    OpenAiChat,
    /// `POST /v1beta/models/{model}:streamGenerateContent?alt=sse`. Parts
    /// rather than blocks, no usable id on a tool call, and a refusal is a 200.
    GeminiGenerateContent,
    /// `POST /api/chat` against a daemon on this machine. Newline-delimited
    /// JSON rather than SSE, no token, tool arguments as an object.
    OllamaChat,
}

impl WireFormat {
    /// Read a wire off a config file, where it is a word somebody typed.
    ///
    /// The vendor names are accepted as well as the wire names, because
    /// `openai` is what a person writes and `openai-chat` is what this calls
    /// it. Anything unrecognised is `None` so config can point at the line.
    pub fn parse(name: &str) -> Option<Self> {
        match name.trim().to_ascii_lowercase().as_str() {
            "anthropic" | "anthropic-messages" | "claude" => Some(Self::AnthropicMessages),
            // Every one of these is the same codec at a different address.
            "openai" | "openai-chat" | "openai-compatible" | "groq" | "together" | "openrouter"
            | "deepseek" | "mistral" | "xai" | "lmstudio" | "vllm" => Some(Self::OpenAiChat),
            "google" | "gemini" | "google-gemini" => Some(Self::GeminiGenerateContent),
            "ollama" | "ollama-chat" | "local" => Some(Self::OllamaChat),
            _ => None,
        }
    }
}

/// How the token is presented, when there is one.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum AuthScheme {
    /// A model on this machine. Not "we forgot to add auth" — a local daemon
    /// demanding a bearer token would be theatre.
    None,
    /// `Authorization: Bearer <token>`.
    Bearer,
    /// A header of the provider's choosing: `x-api-key`, `x-goog-api-key`.
    Header { name: String },
}

/// Everything about a provider that is safe to write down.
///
/// This is config. It round-trips through the config file, it is shown in
/// Settings, and it holds nothing anyone would mind reading over your shoulder
/// — see the note on secrets in the module docs.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct ProviderEndpoint {
    /// How this provider is referred to elsewhere in config. Ours, not the
    /// vendor's: two entries can point at one vendor under different keys.
    pub id: String,
    pub wire: WireFormat,
    /// Scheme and host, no trailing slash. The path is the wire's business.
    /// Present so a proxied or self-hosted address is a config change.
    pub base_url: String,
    pub auth: AuthScheme,
}

impl ProviderEndpoint {
    /// The defaults for a wire, so adding a provider is picking one thing
    /// rather than filling in four.
    ///
    /// In the core because a default that lives in a text field is a default
    /// two platforms will disagree about.
    pub fn preset(wire: WireFormat, id: impl Into<String>) -> Self {
        let (base_url, auth) = match wire {
            WireFormat::AnthropicMessages => (
                "https://api.anthropic.com",
                AuthScheme::Header {
                    name: "x-api-key".into(),
                },
            ),
            WireFormat::OpenAiChat => ("https://api.openai.com", AuthScheme::Bearer),
            WireFormat::GeminiGenerateContent => (
                "https://generativelanguage.googleapis.com",
                AuthScheme::Header {
                    name: "x-goog-api-key".into(),
                },
            ),
            // Loopback by address rather than by name: `localhost` resolves to
            // whatever the machine's hosts file says, and a browser that talks
            // to a language model deserves the version that cannot be pointed
            // somewhere else.
            WireFormat::OllamaChat => ("http://127.0.0.1:11434", AuthScheme::None),
        };
        Self {
            id: id.into(),
            wire,
            base_url: base_url.to_owned(),
            auth,
        }
    }

    /// Whether this provider needs a token at all.
    ///
    /// Behaviour: it decides whether Settings shows a key field, and whether a
    /// missing key is reported before a socket is ever opened.
    pub fn needs_token(&self) -> bool {
        !matches!(self.auth, AuthScheme::None)
    }

    fn root(&self) -> &str {
        self.base_url.trim_end_matches('/')
    }
}

// --- what the model may call -----------------------------------------------

/// One MCP tool, as the model will be shown it.
///
/// The same four facts [`crate::ToolDescriptor`] carries, minus the
/// annotations, which decide what a *person* is asked and have no business in a
/// request. A host builds one of these from the descriptors `StartChatReply`
/// handed it and from nowhere else: a second source of tools is a way to offer
/// the model something the core will refuse.
///
/// The schema is carried and never checked. The server wrote it; validating its
/// own arguments against its own document proves nothing about whether the call
/// is safe, and inventing a check would mean silently changing what was asked
/// for.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct ToolSpec {
    pub server: String,
    pub tool: String,
    /// The server's own description of its own tool, passed through.
    pub summary: String,
    /// JSON Schema for the arguments, as text, exactly as the server published
    /// it. Text rather than a parsed type because it arrives verbatim and
    /// leaves verbatim; parsing it here would only create somewhere to lose a
    /// keyword.
    pub input_schema_json: String,
}

/// Everything a provider allows in a function name: letters, digits,
/// underscore and hyphen, up to sixty-four characters. The intersection of all
/// four wires, so one name works everywhere.
const MAX_TOOL_NAME: usize = 64;

/// The names the model is shown, in the order the tools were given.
///
/// A tool is `(server, tool)` here and one flat string out there, so the pair
/// has to survive a round trip through a model that will echo back only the
/// string. Two rules make that safe:
///
/// - the name is **derived**, not authoritative. What comes back is matched
///   against this list rather than split on a separator, so a server called
///   `read__page` cannot be confused for a tool called `page` on a server
///   called `read`;
/// - a collision after sanitising — two different pairs flattening to one
///   string — is broken by appending a number, so the list is always
///   one-to-one. Silently letting two tools share a name is how a model asks
///   for one and gets the other.
fn wire_names(tools: &[ToolSpec]) -> Vec<String> {
    let mut names: Vec<String> = Vec::with_capacity(tools.len());
    for spec in tools {
        let base = sanitise(&format!("{}__{}", spec.server, spec.tool));
        let mut name = base.clone();
        let mut suffix = 2;
        while names.contains(&name) {
            let room = MAX_TOOL_NAME - 1 - suffix.to_string().len();
            name = format!("{}-{suffix}", truncate(&base, room));
            suffix += 1;
        }
        names.push(name);
    }
    names
}

fn sanitise(raw: &str) -> String {
    let cleaned: String = raw
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '_' || c == '-' {
                c
            } else {
                '_'
            }
        })
        .collect();
    truncate(&cleaned, MAX_TOOL_NAME)
}

fn truncate(value: &str, limit: usize) -> String {
    value.chars().take(limit).collect()
}

// --- what comes back -------------------------------------------------------

/// Why the model stopped, before the core's [`ReplyStop`] narrows it.
///
/// One more variant than the protocol has, and the extra one is the point:
/// a reply the provider refused on policy grounds is not a reply that ended.
/// [`reply_outcome`] is where that becomes a failure rather than a turn.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum StopReason {
    EndTurn,
    ToolCalls,
    MaxOutputTokens,
    Filtered,
}

/// What a stop means to the core: a finished turn, or a failure.
///
/// Behaviour, so it is here and not written twice in two shells. Everything
/// except a refusal is a turn that ended; a refusal is the provider declining,
/// and drawing it as a finished reply would show an empty bubble and call it
/// an answer (ADR-0018).
pub fn reply_outcome(stop: StopReason) -> Result<ReplyStop, ChatErrorKind> {
    match stop {
        StopReason::EndTurn => Ok(ReplyStop::EndOfTurn),
        StopReason::ToolCalls => Ok(ReplyStop::ToolCalls),
        StopReason::MaxOutputTokens => Ok(ReplyStop::MaxTokens),
        StopReason::Filtered => Err(ChatErrorKind::ProviderRefused),
    }
}

/// One thing that happened in a reply, normalised.
///
/// The vocabulary is picked for what [`crate::Action`] needs, not for what any
/// wire sends. Every codec produces exactly this, and a stream that produced
/// something else would be a stream the core had to know the vendor of.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum StreamEvent {
    /// The provider accepted the request and is answering. Emitted once,
    /// before anything else, and it is what turns a spinner into a cursor.
    ///
    /// `model` is what the provider says it is actually running — rarely the
    /// string that was asked for, usually a dated snapshot id — which is
    /// exactly what [`crate::Action::ChatReplyStarted`] wants recorded.
    Started { model: Option<String> },
    /// More of the reply. Never a whole token, never a whole word.
    TextDelta { text: String },
    /// More of the model's reasoning, where a provider streams it apart from
    /// the answer. A separate event because it is shown differently, and a
    /// core that could not tell them apart would have to guess.
    ReasoningDelta { text: String },
    /// A tool call has begun and its name is known; its arguments are not yet.
    ///
    /// Emitted because arguments can take seconds to arrive and a still screen
    /// with no explanation is the one thing this project does not ship. The
    /// core has something true to say — "reading the page" — before it has
    /// anything to run.
    ToolCallStarted { id: ToolCallId, name: String },
    /// A tool call, whole, resolved back to the server and tool it names.
    ///
    /// Goes straight into [`crate::Action::ChatToolCallRequested`]. A call
    /// naming something that was not offered arrives with an empty `server`,
    /// which is the core's own signal to refuse it rather than run it.
    ToolCall { invocation: ToolInvocation },
    /// What the turn cost, when the provider says.
    Usage {
        input_tokens: u32,
        output_tokens: u32,
    },
    /// The reply ended cleanly. Exactly one `Finished` or one `Failed` per
    /// stream: never both, never neither.
    Finished { stop: StopReason },
    /// The reply ended badly. Also terminal.
    Failed { error: ProviderError },
}

/// What the provider says exists.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct ModelInfo {
    /// What goes in the `model` field of a request.
    pub id: String,
    /// What to show instead, when the provider offers something readable.
    pub display_name: Option<String>,
    /// The context window, when stated. Most of them do not state it.
    pub context_tokens: Option<u32>,
}

// --- building a request ----------------------------------------------------

#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct Header {
    pub name: String,
    pub value: String,
}

/// A request, described. Not performed — the shell does that.
///
/// Deliberately dumb: a method, a URL, headers and a body. Everything a URL
/// loader on any platform already knows how to do, and nothing it does not.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct HttpRequest {
    pub method: String,
    pub url: String,
    pub headers: Vec<Header>,
    /// JSON text. Empty for a GET.
    pub body: String,
}

/// What the browser tells a model about itself, before anybody says anything.
///
/// Behaviour rather than wording: it is sent to a model, not shown to a person,
/// and two platforms disagreeing about it would be two browsers.
pub const DEFAULT_SYSTEM_PROMPT: &str = concat!(
    "You are the assistant built into zer0, a web browser. ",
    "You may be given the text of the page the person is looking at; ",
    "when you are, answer from it and say so when it does not contain the answer. ",
    "Be brief. Do not invent sources, quotes or links."
);

/// Build the streaming request for one turn.
///
/// `token` is the secret, straight from the Keychain, used once and not
/// retained. It is [`Option`] because a local model has none, and asking for a
/// token that does not exist is how a local provider ends up with a settings
/// field nobody can fill in.
///
/// Fails rather than guesses when the endpoint wants a token and there is none.
/// That is the first-run mistake and the most likely failure anyone will hit,
/// and it is worth catching before a socket is opened so the report can name
/// which provider and which setting.
pub fn request(
    endpoint: &ProviderEndpoint,
    token: Option<&str>,
    model: &str,
    system: Option<&str>,
    transcript: &[ChatMessage],
    tools: &[ToolSpec],
) -> Result<HttpRequest, ProviderError> {
    let token = authorised(endpoint, token)?;

    let chat = ChatRequest {
        model: model.to_owned(),
        system: Some(system.unwrap_or(DEFAULT_SYSTEM_PROMPT).to_owned()),
        messages: translate(transcript),
        tools: wire_tools(tools),
        max_output_tokens: None,
        temperature: None,
    };

    let mut headers = vec![Header {
        name: "content-type".into(),
        value: "application/json".into(),
    }];
    headers.extend(auth_headers(endpoint, token));

    let (url, body) = match endpoint.wire {
        WireFormat::AnthropicMessages => {
            headers.push(Header {
                name: "anthropic-version".into(),
                value: anthropic::API_VERSION.into(),
            });
            anthropic::stream_request(endpoint.root(), &chat)
        }
        WireFormat::OpenAiChat => openai::stream_request(endpoint.root(), &chat),
        WireFormat::GeminiGenerateContent => gemini::stream_request(endpoint.root(), &chat),
        WireFormat::OllamaChat => ollama::stream_request(endpoint.root(), &chat),
    }?;

    Ok(HttpRequest {
        method: "POST".into(),
        url,
        headers,
        body,
    })
}

/// Build the request that asks a provider what models it has.
///
/// Every wire here can be asked, which is worth stating plainly: Settings can
/// offer a list rather than a text field, and a model id typed by hand is the
/// most common way to get a 404 that reads like an outage. What comes back
/// varies — see [`decode_models`].
pub fn models_request(
    endpoint: &ProviderEndpoint,
    token: Option<&str>,
) -> Result<HttpRequest, ProviderError> {
    let token = authorised(endpoint, token)?;
    let mut headers = auth_headers(endpoint, token);

    let path = match endpoint.wire {
        WireFormat::AnthropicMessages => {
            headers.push(Header {
                name: "anthropic-version".into(),
                value: anthropic::API_VERSION.into(),
            });
            "/v1/models?limit=1000"
        }
        WireFormat::OpenAiChat => "/v1/models",
        WireFormat::GeminiGenerateContent => "/v1beta/models?pageSize=1000",
        WireFormat::OllamaChat => "/api/tags",
    };

    Ok(HttpRequest {
        method: "GET".into(),
        url: format!("{}{}", endpoint.root(), path),
        headers,
        body: String::new(),
    })
}

/// Read a model list off the wire.
pub fn decode_models(wire: WireFormat, body: &str) -> Result<Vec<ModelInfo>, ProviderError> {
    match wire {
        WireFormat::AnthropicMessages => anthropic::models(body),
        WireFormat::OpenAiChat => openai::models(body),
        WireFormat::GeminiGenerateContent => gemini::models(body),
        WireFormat::OllamaChat => ollama::models(body),
    }
}

/// Turn a failed HTTP response into something a person can act on.
///
/// Called by the shell when the status is not 2xx, before any of the body has
/// been fed to a decoder. `retry_after` is the header of that name, untouched.
pub fn decode_error(
    wire: WireFormat,
    status: u16,
    body: &str,
    retry_after: Option<&str>,
) -> ProviderError {
    let advised = error::retry_after_ms(retry_after);
    let error = match wire {
        WireFormat::AnthropicMessages => anthropic::error(status, body),
        WireFormat::OpenAiChat => openai::error(status, body),
        WireFormat::GeminiGenerateContent => gemini::error(status, body),
        WireFormat::OllamaChat => ollama::error(status, body),
    };
    if error.retry_after_ms.is_none() {
        return error.retry_after(advised);
    }
    error
}

/// Nothing answered at all: no route, refused connection, DNS, TLS, timeout.
///
/// A function rather than a value the shell writes for itself, so that "the
/// local model server is not running" and "the wifi is off" stay one category
/// and cannot become two on two platforms.
pub fn unreachable(message: impl Into<String>) -> ProviderError {
    ProviderError::new(ProviderErrorKind::Unreachable, message)
}

/// Somebody pressed Escape.
///
/// Cancellation is the shell tearing its connection down, and it says so with
/// this. A category rather than a silence, because a stream that merely stops
/// leaves half a reply on screen with no explanation — and because the reducer
/// has to tell "abandoned" from "broke".
pub fn cancelled() -> ProviderError {
    ProviderError::new(ProviderErrorKind::Cancelled, "cancelled")
}

fn authorised<'a>(
    endpoint: &ProviderEndpoint,
    token: Option<&'a str>,
) -> Result<Option<&'a str>, ProviderError> {
    if !endpoint.needs_token() {
        return Ok(None);
    }
    match token.map(str::trim).filter(|token| !token.is_empty()) {
        Some(token) => Ok(Some(token)),
        None => Err(ProviderError::new(
            ProviderErrorKind::Unauthorized,
            format!("no API key stored for \"{}\"", endpoint.id),
        )),
    }
}

fn auth_headers(endpoint: &ProviderEndpoint, token: Option<&str>) -> Vec<Header> {
    let Some(token) = token else {
        return Vec::new();
    };
    match &endpoint.auth {
        AuthScheme::None => Vec::new(),
        AuthScheme::Bearer => vec![Header {
            name: "authorization".into(),
            value: format!("Bearer {token}"),
        }],
        AuthScheme::Header { name } => vec![Header {
            name: name.clone(),
            value: token.to_owned(),
        }],
    }
}

// --- from the core's transcript to a wire's ------------------------------

/// What a codec is handed. Not public: the four shapes below are the *inside*
/// of this module, and the outside speaks [`crate::Message`].
#[derive(Debug, Clone, PartialEq)]
struct ChatRequest {
    model: String,
    /// In a field of its own rather than as a first message, because two of
    /// these four wires hoist it out of the message list anyway — Anthropic
    /// into a top-level `system`, Gemini into `systemInstruction`. A transcript
    /// carrying it as a message would need it pulled back out by two codecs,
    /// and one that has it in both places is a bug waiting for a Tuesday.
    system: Option<String>,
    messages: Vec<WireMessage>,
    tools: Vec<WireTool>,
    max_output_tokens: Option<u32>,
    temperature: Option<f64>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Role {
    User,
    Assistant,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct WireMessage {
    role: Role,
    content: Vec<Content>,
}

/// One piece of one message.
///
/// A message is a list of these rather than a string, because a turn in which
/// the model spoke *and* asked for two tools is one turn, and flattening it
/// loses which answer belongs to which request.
#[derive(Debug, Clone, PartialEq, Eq)]
enum Content {
    Text {
        text: String,
    },
    ToolCall {
        call: RawToolCall,
    },
    /// What a tool returned.
    ///
    /// Carries **both** `call_id` and `name`, and that one decision is what
    /// makes a single shape fit four wires. Anthropic and OpenAI correlate by
    /// id and ignore the name; Gemini and Ollama have no usable id and
    /// correlate by name. Neither field is redundant, neither is a workaround,
    /// and the core holds both already — it just ran the tool.
    ToolResult {
        call_id: String,
        name: String,
        output: String,
        /// Sent as a failure rather than as prose where a wire has a flag for
        /// it: a model told "error" in a field retries differently from one
        /// that reads the word in a result.
        is_error: bool,
    },
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct RawToolCall {
    id: String,
    name: String,
    /// Complete JSON text. Two of these wires stream tool arguments as
    /// fragments, and half a JSON object is not something to hand anybody.
    arguments_json: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct WireTool {
    name: String,
    description: String,
    input_schema_json: String,
}

fn wire_tools(tools: &[ToolSpec]) -> Vec<WireTool> {
    wire_names(tools)
        .into_iter()
        .zip(tools)
        .map(|(name, spec)| WireTool {
            name,
            description: spec.summary.clone(),
            input_schema_json: spec.input_schema_json.clone(),
        })
        .collect()
}

/// Rewrite the core's transcript as turns a provider will accept.
///
/// Four things happen here and each is behaviour rather than formatting:
///
/// - a `PageContext` message becomes a user turn that says where the text came
///   from. The model is told the address and the title, so an answer can cite
///   the page rather than assert it (ADR-0018);
/// - a tool result is attached to the turn *after* the assistant turn that
///   asked for it, which is the shape every one of these wires requires;
/// - a result is taken from the `ToolResult` message where there is one and
///   from the call's own record where there is not, so a transcript is
///   complete whichever way the reducer stored it;
/// - a message that is still streaming, or that failed, is left out. Sending
///   half an answer back as though the model had said it is the browser
///   putting words in its mouth.
fn translate(transcript: &[ChatMessage]) -> Vec<WireMessage> {
    let mut results: Vec<(ToolCallId, String)> = Vec::new();
    for message in transcript {
        if let (MessageRole::ToolResult, Some(id)) = (message.role, message.answers.as_ref()) {
            results.push((id.clone(), message.text.clone()));
        }
    }

    let mut out: Vec<WireMessage> = Vec::new();
    for message in transcript {
        match message.role {
            MessageRole::User => {
                if !message.text.is_empty() {
                    out.push(WireMessage {
                        role: Role::User,
                        content: vec![Content::Text {
                            text: message.text.clone(),
                        }],
                    });
                }
            }
            MessageRole::PageContext => {
                out.push(WireMessage {
                    role: Role::User,
                    content: vec![Content::Text {
                        text: page_context(message),
                    }],
                });
            }
            // Already folded into the assistant turn that asked for it.
            MessageRole::ToolResult => {}
            MessageRole::Assistant => {
                let mut content = Vec::new();
                if !message.text.is_empty() {
                    content.push(Content::Text {
                        text: message.text.clone(),
                    });
                }
                for call in &message.tool_calls {
                    content.push(Content::ToolCall {
                        call: RawToolCall {
                            id: call.invocation.id.0.clone(),
                            name: sanitise(&format!(
                                "{}__{}",
                                call.invocation.server, call.invocation.tool
                            )),
                            arguments_json: call.invocation.arguments.clone(),
                        },
                    });
                }
                if content.is_empty() {
                    continue;
                }
                out.push(WireMessage {
                    role: Role::Assistant,
                    content,
                });

                let answers: Vec<Content> = message
                    .tool_calls
                    .iter()
                    .filter(|call| call.state.is_settled())
                    .map(|call| Content::ToolResult {
                        call_id: call.invocation.id.0.clone(),
                        name: sanitise(&format!(
                            "{}__{}",
                            call.invocation.server, call.invocation.tool
                        )),
                        output: results
                            .iter()
                            .find(|(id, _)| *id == call.invocation.id)
                            .map(|(_, text)| text.clone())
                            .unwrap_or_else(|| call.result.clone()),
                        is_error: !matches!(call.state, ToolCallState::Completed),
                    })
                    .collect();
                if !answers.is_empty() {
                    out.push(WireMessage {
                        role: Role::User,
                        content: answers,
                    });
                }
            }
        }
    }
    out
}

fn page_context(message: &ChatMessage) -> String {
    let (url, title) = message
        .page
        .as_ref()
        .map(|page| (page.url.as_str(), page.title.as_str()))
        .unwrap_or(("", ""));
    if message.text.is_empty() {
        return format!(
            "The browser could not read the page at {url} (\"{title}\"). Say so if the answer depends on it."
        );
    }
    format!(
        "The browser attached the text of the page the person is looking at.\nURL: {url}\nTitle: {title}\n\n{}",
        message.text
    )
}

/// Parse a tool's schema, or say which tool is malformed.
///
/// The text came from an MCP server, which is somebody else's process, so it is
/// not trusted to be JSON at all. Failing here rather than sending it on is the
/// difference between "the `read_page` tool has a broken schema" and a 400 from
/// a provider that will not say which of eleven tools it objected to.
fn schema(text: &str) -> Result<serde_json::Value, ProviderError> {
    let trimmed = text.trim();
    if trimmed.is_empty() {
        // A tool that takes no arguments. Every wire here wants an object, and
        // none of them accepts nothing at all.
        return Ok(serde_json::json!({ "type": "object", "properties": {} }));
    }
    serde_json::from_str(trimmed).map_err(|error| {
        ProviderError::new(
            ProviderErrorKind::InvalidRequest,
            format!("a tool's schema is not JSON: {error}"),
        )
    })
}

// --- reading the reply -----------------------------------------------------

/// Bytes in, [`StreamEvent`]s out, incrementally.
///
/// One per request. Fed whatever the network hands over, in whatever sizes, and
/// it is this type's job that a chunk boundary landing in the middle of a word
/// — or of a JSON escape, or of the string `event: content_block_delta` — is
/// invisible to everything above it.
///
/// Terminal by construction: after a [`StreamEvent::Finished`] or a
/// [`StreamEvent::Failed`] it produces nothing more, so a provider that keeps
/// talking after an error cannot make the reducer see two endings.
#[derive(Debug)]
pub struct StreamDecoder {
    wire: WireFormat,
    framer: crate::sse::Framer,
    state: Codec,
    /// What the model was offered, so a name coming back can be resolved to the
    /// server and tool it stands for. Held here rather than looked up later
    /// because this is the only place that knows both.
    offered: Vec<(String, ToolSpec)>,
    done: bool,
}

#[derive(Debug)]
enum Codec {
    Anthropic(anthropic::Decoder),
    OpenAi(openai::Decoder),
    Gemini(gemini::Decoder),
    Ollama(ollama::Decoder),
}

impl StreamDecoder {
    /// `tools` must be the same list, in the same order, that [`request`] was
    /// given. The names the model sees are derived from it, and resolving a
    /// call back to a server needs the same derivation.
    pub fn new(wire: WireFormat, tools: &[ToolSpec]) -> Self {
        let (framing, state) = match wire {
            WireFormat::AnthropicMessages => (
                crate::sse::Framing::EventStream,
                Codec::Anthropic(anthropic::Decoder::default()),
            ),
            WireFormat::OpenAiChat => (
                crate::sse::Framing::EventStream,
                Codec::OpenAi(openai::Decoder::default()),
            ),
            WireFormat::GeminiGenerateContent => (
                crate::sse::Framing::EventStream,
                Codec::Gemini(gemini::Decoder::default()),
            ),
            WireFormat::OllamaChat => (
                crate::sse::Framing::LineJson,
                Codec::Ollama(ollama::Decoder::default()),
            ),
        };
        Self {
            wire,
            framer: crate::sse::Framer::new(framing),
            state,
            offered: wire_names(tools).into_iter().zip(tools.to_vec()).collect(),
            done: false,
        }
    }

    pub fn wire(&self) -> WireFormat {
        self.wire
    }

    /// Whether this stream has already ended, one way or the other.
    pub fn is_done(&self) -> bool {
        self.done
    }

    /// Feed the next chunk.
    pub fn push(&mut self, bytes: &[u8]) -> Vec<StreamEvent> {
        if self.done {
            return Vec::new();
        }
        let frames = self.framer.push(bytes);
        if self.framer.overflowed() {
            return self.terminate(ProviderError::new(
                ProviderErrorKind::MalformedResponse,
                "the response was not a stream we recognise",
            ));
        }
        self.consume(frames)
    }

    /// The connection closed.
    ///
    /// Always called, and it is what catches the stream that simply stops. A
    /// reply cut off mid-sentence has no terminal event of its own, and without
    /// this it would leave a thread that spins for ever.
    pub fn finish(&mut self) -> Vec<StreamEvent> {
        if self.done {
            return Vec::new();
        }
        let frames = self.framer.finish();
        let mut out = self.consume(frames);
        if self.done {
            return out;
        }

        // One wire can still end well here: OpenAI's sentinel is the last thing
        // sent, *after* the chunk that already said why the reply stopped, and
        // connections die in that gap. Asking the codec rather than deciding
        // here is what keeps that knowledge in the one module that has it.
        let salvaged = match &mut self.state {
            Codec::Anthropic(decoder) => decoder.eof(),
            Codec::OpenAi(decoder) => decoder.eof(),
            Codec::Gemini(decoder) => decoder.eof(),
            Codec::Ollama(decoder) => decoder.eof(),
        };
        for event in salvaged {
            let terminal = matches!(
                event,
                StreamEvent::Finished { .. } | StreamEvent::Failed { .. }
            );
            out.push(self.resolve(event));
            if terminal {
                self.done = true;
            }
        }
        if self.done {
            return out;
        }

        out.extend(self.terminate(ProviderError::new(
            ProviderErrorKind::MalformedResponse,
            "the connection closed before the reply ended",
        )));
        out
    }

    /// The shell tore the connection down because somebody asked it to.
    pub fn cancel(&mut self) -> Vec<StreamEvent> {
        if self.done {
            return Vec::new();
        }
        self.terminate(cancelled())
    }

    fn consume(&mut self, frames: Vec<crate::sse::Frame>) -> Vec<StreamEvent> {
        let mut out = Vec::new();
        for frame in frames {
            if self.done {
                break;
            }
            let raw = match &mut self.state {
                Codec::Anthropic(decoder) => decoder.frame(&frame),
                Codec::OpenAi(decoder) => decoder.frame(&frame),
                Codec::Gemini(decoder) => decoder.frame(&frame),
                Codec::Ollama(decoder) => decoder.frame(&frame),
            };
            for event in raw {
                let event = self.resolve(event);
                let terminal = matches!(
                    event,
                    StreamEvent::Finished { .. } | StreamEvent::Failed { .. }
                );
                out.push(event);
                if terminal {
                    self.done = true;
                    break;
                }
            }
        }
        out
    }

    /// Put the server back on a call that came home with a flat name.
    ///
    /// Matched against what was offered rather than split on the separator: a
    /// server named `read__page` and a tool named `page` on a server named
    /// `read` flatten to the same string, and guessing between them would run
    /// the wrong tool. A name that matches nothing keeps an empty `server`,
    /// which the core already refuses — a model asking for something nobody
    /// offered gets a refusal on screen, not a silent drop.
    fn resolve(&self, event: StreamEvent) -> StreamEvent {
        let StreamEvent::ToolCall { invocation } = event else {
            return event;
        };
        let named = self
            .offered
            .iter()
            .find(|(name, _)| *name == invocation.tool);
        match named {
            Some((_, spec)) => StreamEvent::ToolCall {
                invocation: ToolInvocation {
                    server: spec.server.clone(),
                    tool: spec.tool.clone(),
                    ..invocation
                },
            },
            None => StreamEvent::ToolCall { invocation },
        }
    }

    fn terminate(&mut self, error: ProviderError) -> Vec<StreamEvent> {
        self.done = true;
        vec![StreamEvent::Failed { error }]
    }
}

/// A tool call, finished, checked well enough to hand to something that will
/// act on it.
///
/// The check is the point. Two of these wires stream arguments as fragments of
/// text, and a fragment that never completed is a truncated JSON object — which
/// would otherwise reach an MCP server as a call with arguments that parse to
/// something *nearly* right. Empty is normalised to `{}`, because a tool taking
/// no arguments legitimately produces no fragments at all.
///
/// `server` is left empty here on purpose: the codec knows the flat name and
/// nothing else. [`StreamDecoder::resolve`] fills it in.
fn assembled_tool_call(mut call: RawToolCall) -> StreamEvent {
    if call.arguments_json.trim().is_empty() {
        call.arguments_json = "{}".into();
    }
    match serde_json::from_str::<serde_json::Value>(&call.arguments_json) {
        Ok(_) => StreamEvent::ToolCall {
            invocation: ToolInvocation {
                id: ToolCallId(call.id),
                server: String::new(),
                tool: call.name,
                arguments: call.arguments_json,
            },
        },
        Err(error) => StreamEvent::Failed {
            error: ProviderError::new(
                ProviderErrorKind::MalformedResponse,
                format!(
                    "the arguments for \"{}\" did not arrive whole: {error}",
                    call.name
                ),
            ),
        },
    }
}

#[cfg(test)]
#[path = "provider_tests.rs"]
mod tests;
