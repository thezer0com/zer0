//! The Messages wire.
//!
//! Named SSE events carrying named content blocks, indexed by position in the
//! reply. The one shape here that costs real work is a tool call: the name
//! arrives in `content_block_start` and the arguments arrive afterwards as
//! fragments of JSON *text* in `input_json_delta`, which have to be
//! concatenated and only then parsed.

use serde_json::{Map, Value, json};

use super::error::{ProviderError, ProviderErrorKind, kind_for_status};
use crate::chat::ToolCallId;
use crate::sse::Frame;

use super::{
    ChatRequest, Content, ModelInfo, RawToolCall, Role, StopReason, StreamEvent, WireMessage,
};

/// Pinned rather than tracked. The header is a dated contract, and a browser
/// that followed "latest" would take a breaking change on a Tuesday from a
/// deploy it was not part of.
pub(super) const API_VERSION: &str = "2023-06-01";

/// The field is required by the API and has no default there. A reply cut off
/// at an arbitrary number would be worse than one that is long, so this is set
/// high enough to be invisible in a chat and is overridable per request.
const DEFAULT_MAX_TOKENS: u32 = 8192;

pub(super) fn stream_request(
    root: &str,
    chat: &ChatRequest,
) -> Result<(String, String), ProviderError> {
    let mut body = Map::new();
    body.insert("model".into(), json!(chat.model));
    body.insert("stream".into(), json!(true));
    body.insert(
        "max_tokens".into(),
        json!(chat.max_output_tokens.unwrap_or(DEFAULT_MAX_TOKENS)),
    );
    if let Some(system) = &chat.system {
        body.insert("system".into(), json!(system));
    }
    if let Some(temperature) = chat.temperature {
        body.insert("temperature".into(), json!(temperature));
    }
    body.insert("messages".into(), Value::Array(messages(&chat.messages)));
    if !chat.tools.is_empty() {
        let mut tools = Vec::with_capacity(chat.tools.len());
        for tool in &chat.tools {
            tools.push(json!({
                "name": tool.name,
                "description": tool.description,
                "input_schema": super::schema(&tool.input_schema_json)?,
            }));
        }
        body.insert("tools".into(), Value::Array(tools));
    }

    Ok((
        format!("{root}/v1/messages"),
        Value::Object(body).to_string(),
    ))
}

/// A tool result goes in a **user** message here, not a role of its own, and it
/// is the first place the shared [`Content`] shape has to bend to a wire. It
/// bends without the core noticing, which is the whole test.
fn messages(messages: &[WireMessage]) -> Vec<Value> {
    messages
        .iter()
        .map(|message| {
            let blocks: Vec<Value> = message.content.iter().map(block).collect();
            json!({
                "role": match message.role {
                    Role::User => "user",
                    Role::Assistant => "assistant",
                },
                "content": blocks,
            })
        })
        .collect()
}

fn block(content: &Content) -> Value {
    match content {
        Content::Text { text } => json!({ "type": "text", "text": text }),
        Content::ToolCall { call } => json!({
            "type": "tool_use",
            "id": call.id,
            "name": call.name,
            // Sent as parsed JSON, and an unparseable argument list becomes an
            // empty object rather than a failed turn: the call already
            // happened, and dropping the whole transcript over it would lose
            // the reply it belongs to.
            "input": serde_json::from_str::<Value>(&call.arguments_json)
                .unwrap_or_else(|_| json!({})),
        }),
        Content::ToolResult {
            call_id,
            output,
            is_error,
            // The name is what Gemini and Ollama correlate on. Here the id
            // does that job, so the name is not sent.
            name: _,
        } => json!({
            "type": "tool_result",
            "tool_use_id": call_id,
            "content": output,
            "is_error": is_error,
        }),
    }
}

// --- reading ---------------------------------------------------------------

/// One content block being assembled.
#[derive(Debug)]
enum Block {
    Text,
    Thinking,
    /// A tool call whose arguments are still arriving as text fragments.
    Tool {
        id: String,
        name: String,
        arguments: String,
    },
    /// A block type we do not draw. Its deltas are dropped rather than shown
    /// as text, because a redacted thinking block rendered as prose is the
    /// browser leaking an implementation detail into a conversation.
    Ignored,
}

#[derive(Debug, Default)]
pub(super) struct Decoder {
    /// Keyed by the `index` the wire gives every block. A reply can have a
    /// text block and two tool calls open at once, and they interleave.
    blocks: Vec<(u64, Block)>,
    stop: Option<StopReason>,
}

impl Decoder {
    pub(super) fn frame(&mut self, frame: &Frame) -> Vec<StreamEvent> {
        let Ok(value) = serde_json::from_str::<Value>(&frame.data) else {
            return vec![malformed("an event that was not JSON")];
        };
        // The `type` inside the payload rather than the `event:` field: they
        // agree, and the one inside the payload is the one that survives a
        // proxy that drops event names.
        let kind = value
            .get("type")
            .and_then(Value::as_str)
            .unwrap_or_default();

        match kind {
            "message_start" => {
                let model = value
                    .pointer("/message/model")
                    .and_then(Value::as_str)
                    .map(str::to_owned);
                let mut out = vec![StreamEvent::Started { model }];
                // Input tokens are stated here and never again, so a reply that
                // is cancelled part way through still has a cost.
                if let Some(usage) = value.pointer("/message/usage") {
                    out.extend(usage_event(usage));
                }
                out
            }
            "content_block_start" => self.open(&value),
            "content_block_delta" => self.delta(&value),
            "content_block_stop" => self.close(&value),
            "message_delta" => {
                if let Some(stop) = value.pointer("/delta/stop_reason").and_then(Value::as_str) {
                    self.stop = Some(stop_reason(stop));
                }
                value.get("usage").map(usage_event).unwrap_or_default()
            }
            "message_stop" => vec![StreamEvent::Finished {
                // No `message_delta` at all means the reply simply ended, which
                // is what `end_turn` says.
                stop: self.stop.unwrap_or(StopReason::EndTurn),
            }],
            // An error after a 200. The status code said everything was fine
            // and then it was not, which is why the shell cannot be the only
            // thing reading errors.
            "error" => vec![StreamEvent::Failed {
                error: error_from(value.get("error"), ProviderErrorKind::ServerError),
            }],
            // `ping` is a keep-alive and anything unrecognised is a field we
            // have not needed yet. Neither is a reason to stop reading.
            _ => Vec::new(),
        }
    }

    /// The connection closed with no `message_stop`.
    ///
    /// This wire always sends one, so its absence means the reply was cut off
    /// rather than finished. Nothing is salvaged: a truncated turn reported as
    /// a whole one is the interface asserting something it cannot back up.
    pub(super) fn eof(&mut self) -> Vec<StreamEvent> {
        Vec::new()
    }

    fn open(&mut self, value: &Value) -> Vec<StreamEvent> {
        let Some(index) = value.get("index").and_then(Value::as_u64) else {
            return Vec::new();
        };
        let block = value.get("content_block");
        let kind = block
            .and_then(|b| b.get("type"))
            .and_then(Value::as_str)
            .unwrap_or_default();

        let (block, events) = match kind {
            "text" => (Block::Text, Vec::new()),
            "thinking" => (Block::Thinking, Vec::new()),
            "tool_use" => {
                let id = block
                    .and_then(|b| b.get("id"))
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_owned();
                let name = block
                    .and_then(|b| b.get("name"))
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_owned();
                let started = StreamEvent::ToolCallStarted {
                    id: ToolCallId(id.clone()),
                    name: name.clone(),
                };
                (
                    Block::Tool {
                        id,
                        name,
                        arguments: String::new(),
                    },
                    vec![started],
                )
            }
            _ => (Block::Ignored, Vec::new()),
        };

        self.blocks.retain(|(seen, _)| *seen != index);
        self.blocks.push((index, block));
        events
    }

    fn delta(&mut self, value: &Value) -> Vec<StreamEvent> {
        let Some(index) = value.get("index").and_then(Value::as_u64) else {
            return Vec::new();
        };
        let Some(delta) = value.get("delta") else {
            return Vec::new();
        };
        let Some(block) = self
            .blocks
            .iter_mut()
            .find(|(seen, _)| *seen == index)
            .map(|(_, block)| block)
        else {
            return Vec::new();
        };

        match delta
            .get("type")
            .and_then(Value::as_str)
            .unwrap_or_default()
        {
            "text_delta" => match (&block, text(delta, "text")) {
                (Block::Text, Some(text)) => vec![StreamEvent::TextDelta { text }],
                _ => Vec::new(),
            },
            "thinking_delta" => match (&block, text(delta, "thinking")) {
                (Block::Thinking, Some(text)) => vec![StreamEvent::ReasoningDelta { text }],
                _ => Vec::new(),
            },
            "input_json_delta" => {
                if let (Block::Tool { arguments, .. }, Some(fragment)) =
                    (&mut *block, text(delta, "partial_json"))
                {
                    arguments.push_str(&fragment);
                }
                Vec::new()
            }
            // `signature_delta` and anything later. A cryptographic signature
            // over a thinking block is not prose and must not be shown as any.
            _ => Vec::new(),
        }
    }

    fn close(&mut self, value: &Value) -> Vec<StreamEvent> {
        let Some(index) = value.get("index").and_then(Value::as_u64) else {
            return Vec::new();
        };
        let Some(position) = self.blocks.iter().position(|(seen, _)| *seen == index) else {
            return Vec::new();
        };
        let (_, block) = self.blocks.remove(position);

        match block {
            Block::Tool {
                id,
                name,
                arguments,
            } => vec![super::assembled_tool_call(RawToolCall {
                id,
                name,
                arguments_json: arguments,
            })],
            Block::Text | Block::Thinking | Block::Ignored => Vec::new(),
        }
    }
}

fn text(delta: &Value, field: &str) -> Option<String> {
    delta.get(field).and_then(Value::as_str).map(str::to_owned)
}

fn usage_event(usage: &Value) -> Vec<StreamEvent> {
    let input = usage.get("input_tokens").and_then(Value::as_u64);
    let output = usage.get("output_tokens").and_then(Value::as_u64);
    if input.is_none() && output.is_none() {
        return Vec::new();
    }
    vec![StreamEvent::Usage {
        input_tokens: input.unwrap_or(0) as u32,
        output_tokens: output.unwrap_or(0) as u32,
    }]
}

/// `pause_turn` and `stop_sequence` both mean "it stopped and there is more it
/// could say", which is not a thing to tell anybody about; they read as a
/// finished turn. `refusal` is the one that has to be visible.
fn stop_reason(raw: &str) -> StopReason {
    match raw {
        "tool_use" => StopReason::ToolCalls,
        "max_tokens" => StopReason::MaxOutputTokens,
        "refusal" => StopReason::Filtered,
        _ => StopReason::EndTurn,
    }
}

// --- failures --------------------------------------------------------------

pub(super) fn error(status: u16, body: &str) -> ProviderError {
    let fallback = kind_for_status(status);
    match serde_json::from_str::<Value>(body) {
        Ok(value) => error_from(value.get("error"), fallback),
        Err(_) => ProviderError::new(fallback, snippet(body)),
    }
}

fn error_from(error: Option<&Value>, fallback: ProviderErrorKind) -> ProviderError {
    let kind = error
        .and_then(|e| e.get("type"))
        .and_then(Value::as_str)
        .map(|declared| error_kind(declared, fallback))
        .unwrap_or(fallback);
    let message = error
        .and_then(|e| e.get("message"))
        .and_then(Value::as_str)
        .unwrap_or("the provider reported an error without saying what")
        .to_owned();
    ProviderError::new(kind, message)
}

fn error_kind(declared: &str, fallback: ProviderErrorKind) -> ProviderErrorKind {
    match declared {
        "authentication_error" => ProviderErrorKind::Unauthorized,
        "permission_error" => ProviderErrorKind::Forbidden,
        "not_found_error" => ProviderErrorKind::ModelNotFound,
        "rate_limit_error" => ProviderErrorKind::RateLimited,
        // Credit exhausted arrives as a 400 with this type, so the status
        // alone would have said "you built a bad request". It is the one case
        // where the body is strictly more truthful than the code.
        "billing_error" => ProviderErrorKind::QuotaExhausted,
        // A request over the limit is a size problem, and it is the same
        // problem as a conversation that has outgrown the window.
        "request_too_large" => ProviderErrorKind::ContextTooLong,
        "overloaded_error" => ProviderErrorKind::Overloaded,
        "api_error" | "timeout_error" => ProviderErrorKind::ServerError,
        "invalid_request_error" => ProviderErrorKind::InvalidRequest,
        _ => fallback,
    }
}

/// A body that is not JSON is a proxy's HTML, and pasting a whole page into an
/// error message helps nobody.
fn snippet(body: &str) -> String {
    let trimmed = body.trim();
    if trimmed.is_empty() {
        return "the provider sent no explanation".into();
    }
    trimmed.chars().take(200).collect()
}

// --- listing ---------------------------------------------------------------

/// The only listing besides Gemini's that states both a readable name and a
/// window, so Settings can show "Claude Sonnet 4.5" beside a number rather than
/// a dated id somebody has to recognise.
pub(super) fn models(body: &str) -> Result<Vec<ModelInfo>, ProviderError> {
    let value: Value = serde_json::from_str(body)
        .map_err(|_| ProviderError::new(ProviderErrorKind::MalformedResponse, snippet(body)))?;
    let Some(data) = value.get("data").and_then(Value::as_array) else {
        return Err(ProviderError::new(
            ProviderErrorKind::MalformedResponse,
            "the model list had no models in it",
        ));
    };

    Ok(data
        .iter()
        .filter_map(|model| {
            let id = model.get("id").and_then(Value::as_str)?;
            Some(ModelInfo {
                id: id.to_owned(),
                display_name: model
                    .get("display_name")
                    .and_then(Value::as_str)
                    .map(str::to_owned),
                context_tokens: model
                    .get("max_input_tokens")
                    .and_then(Value::as_u64)
                    .map(|limit| limit as u32),
            })
        })
        .collect())
}

fn malformed(what: &str) -> StreamEvent {
    StreamEvent::Failed {
        error: ProviderError::new(ProviderErrorKind::MalformedResponse, what),
    }
}
