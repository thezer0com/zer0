//! The chat-completions wire.
//!
//! One codec, many providers. This is the shape everyone who did not invent
//! their own copied, so the same module talks to OpenAI, to a hosted
//! inference service, to a self-hosted server and to Ollama's compatibility
//! endpoint — each of them a [`super::ProviderProfile`] with a different
//! `base_url` and no code at all.
//!
//! Its one genuinely awkward feature is how a tool call streams: the arguments
//! arrive as fragments of a JSON **string**, and the only thing tying one
//! fragment to the call it belongs to is an `index` that appears on the first
//! fragment and is repeated — or, on some compatible servers, is not.

use serde_json::{Map, Value, json};

use super::error::{ProviderError, ProviderErrorKind, kind_for_status};
use crate::chat::ToolCallId;
use crate::sse::Frame;

use super::{
    ChatRequest, Content, ModelInfo, RawToolCall, Role, StopReason, StreamEvent, WireMessage,
};

/// The sentinel that ends the stream. Not JSON, and parsing it as JSON is the
/// classic way to end a working reply with a decoding error.
const DONE: &str = "[DONE]";

pub(super) fn stream_request(
    root: &str,
    chat: &ChatRequest,
) -> Result<(String, String), ProviderError> {
    let mut messages = Vec::new();
    if let Some(system) = &chat.system {
        messages.push(json!({ "role": "system", "content": system }));
    }
    for message in &chat.messages {
        messages.extend(wire_messages(message));
    }

    let mut body = Map::new();
    body.insert("model".into(), json!(chat.model));
    body.insert("messages".into(), Value::Array(messages));
    body.insert("stream".into(), json!(true));
    // Without this the usage block is simply absent from a streamed reply, and
    // a chat that can never say what a turn cost is a chat that cannot show a
    // budget. Servers that do not know the option ignore it.
    body.insert("stream_options".into(), json!({ "include_usage": true }));
    if let Some(max) = chat.max_output_tokens {
        // `max_completion_tokens` rather than the older `max_tokens`: the
        // reasoning models refuse the old name outright, and every compatible
        // server that is current accepts the new one. An old server ignoring an
        // unknown field costs a longer reply; the other way round costs a 400.
        body.insert("max_completion_tokens".into(), json!(max));
    }
    if let Some(temperature) = chat.temperature {
        body.insert("temperature".into(), json!(temperature));
    }

    if !chat.tools.is_empty() {
        let mut tools = Vec::with_capacity(chat.tools.len());
        for tool in &chat.tools {
            tools.push(json!({
                "type": "function",
                "function": {
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": super::schema(&tool.input_schema_json)?,
                }
            }));
        }
        body.insert("tools".into(), Value::Array(tools));
    }

    Ok((
        format!("{root}/v1/chat/completions"),
        Value::Object(body).to_string(),
    ))
}

fn wire_messages(message: &WireMessage) -> Vec<Value> {
    let mut out = Vec::new();
    let mut text = String::new();
    let mut calls = Vec::new();

    for content in &message.content {
        match content {
            Content::Text { text: fragment } => text.push_str(fragment),
            Content::ToolCall { call } => calls.push(json!({
                "id": call.id,
                "type": "function",
                "function": {
                    "name": call.name,
                    // A string here, an object on the two local-ish wires. The
                    // neutral shape keeps it as text for exactly this reason:
                    // text survives being turned into an object, and an object
                    // that has been through a parser does not survive being
                    // turned back into the same text.
                    "arguments": call.arguments_json,
                }
            })),
            Content::ToolResult {
                call_id,
                output,
                is_error,
                // Correlated by id here. The name rides along for the wires
                // that have no id, and is dropped without loss on this one.
                name: _,
            } => out.push(json!({
                "role": "tool",
                "tool_call_id": call_id,
                "content": if *is_error { format!("error: {output}") } else { output.clone() },
            })),
        }
    }

    if !text.is_empty() || !calls.is_empty() {
        let mut wire = Map::new();
        wire.insert(
            "role".into(),
            json!(match message.role {
                Role::User => "user",
                Role::Assistant => "assistant",
            }),
        );
        wire.insert("content".into(), json!(text));
        if !calls.is_empty() {
            wire.insert("tool_calls".into(), Value::Array(calls));
        }
        out.insert(0, Value::Object(wire));
    }

    out
}

// --- reading ---------------------------------------------------------------

#[derive(Debug)]
struct PartialCall {
    index: u64,
    id: String,
    name: String,
    arguments: String,
    /// Whether the core has been told this call exists. Sent as soon as a name
    /// is known, which is usually the first fragment and occasionally the
    /// second.
    announced: bool,
}

#[derive(Debug, Default)]
pub(super) struct Decoder {
    started: bool,
    calls: Vec<PartialCall>,
    stop: Option<StopReason>,
    finished: bool,
}

impl Decoder {
    pub(super) fn frame(&mut self, frame: &Frame) -> Vec<StreamEvent> {
        let payload = frame.data.trim();
        if payload.is_empty() {
            return Vec::new();
        }
        if payload == DONE {
            return self.end();
        }

        let Ok(value) = serde_json::from_str::<Value>(payload) else {
            return vec![malformed("a chunk that was not JSON")];
        };

        // Some servers report a mid-stream failure as a chunk rather than by
        // dropping the connection. A 200 that turns into a rate limit halfway
        // through is a real thing and it has to reach the same screen as a 429.
        if let Some(error) = value.get("error") {
            return vec![StreamEvent::Failed {
                error: error_from(Some(error), None, ProviderErrorKind::ServerError),
            }];
        }

        let mut out = Vec::new();
        if !self.started {
            self.started = true;
            out.push(StreamEvent::Started {
                model: value
                    .get("model")
                    .and_then(Value::as_str)
                    .map(str::to_owned),
            });
        }

        if let Some(usage) = value.get("usage").filter(|usage| !usage.is_null()) {
            out.extend(usage_event(usage));
        }

        let choice = value
            .get("choices")
            .and_then(Value::as_array)
            .and_then(|choices| choices.first());
        let Some(choice) = choice else {
            return out;
        };

        if let Some(delta) = choice.get("delta") {
            out.extend(self.delta(delta));
        }

        if let Some(reason) = choice
            .get("finish_reason")
            .and_then(Value::as_str)
            .filter(|reason| !reason.is_empty())
        {
            self.stop = Some(stop_reason(reason));
            // The tools are complete the moment the reply is: their fragments
            // cannot arrive after the choice that ended. Flushing here rather
            // than at `[DONE]` means a server that closes without the sentinel
            // still delivers its calls.
            out.extend(self.flush());
        }
        out
    }

    /// The connection closed without `[DONE]`.
    ///
    /// Unlike the other three wires this one can still be salvaged: the
    /// sentinel is the *last* thing sent, after the chunk that already said
    /// why the reply stopped, and connections die in that gap often enough to
    /// matter. A reply that reached its `finish_reason` is a finished reply;
    /// one that did not was cut off, and says so.
    pub(super) fn eof(&mut self) -> Vec<StreamEvent> {
        if self.stop.is_none() {
            return Vec::new();
        }
        self.end()
    }

    fn delta(&mut self, delta: &Value) -> Vec<StreamEvent> {
        let mut out = Vec::new();

        // Not in the official schema and sent by several compatible servers
        // under two spellings. Read rather than ignored: a reasoning model
        // whose thinking arrives as ordinary text puts its scratch work in the
        // reply, and dropping it entirely loses the only progress a slow
        // thinking turn has to show.
        for field in ["reasoning_content", "reasoning"] {
            if let Some(text) = delta.get(field).and_then(Value::as_str)
                && !text.is_empty()
            {
                out.push(StreamEvent::ReasoningDelta {
                    text: text.to_owned(),
                });
            }
        }

        if let Some(text) = delta.get("content").and_then(Value::as_str)
            && !text.is_empty()
        {
            out.push(StreamEvent::TextDelta {
                text: text.to_owned(),
            });
        }

        // A refusal streams on a field of its own, beside `content` rather than
        // in it. Shown as reply text and not dropped: the model explaining why
        // it will not answer *is* the answer, and an empty bubble with a
        // `content_filter` badge tells nobody anything.
        if let Some(text) = delta.get("refusal").and_then(Value::as_str)
            && !text.is_empty()
        {
            out.push(StreamEvent::TextDelta {
                text: text.to_owned(),
            });
        }

        let Some(fragments) = delta.get("tool_calls").and_then(Value::as_array) else {
            return out;
        };
        for (position, fragment) in fragments.iter().enumerate() {
            out.extend(self.fragment(fragment, position));
        }
        out
    }

    /// Fold one fragment into the call it belongs to.
    ///
    /// `index` is how the wire says which call is being extended, and it is
    /// absent on enough compatible servers to need a fallback. Position within
    /// the array is that fallback: with one call in flight the two always
    /// agree, and with several a server that omits the index has already lost
    /// the ability to interleave them.
    fn fragment(&mut self, fragment: &Value, position: usize) -> Vec<StreamEvent> {
        let index = fragment
            .get("index")
            .and_then(Value::as_u64)
            .unwrap_or(position as u64);

        if !self.calls.iter().any(|call| call.index == index) {
            self.calls.push(PartialCall {
                index,
                id: String::new(),
                name: String::new(),
                arguments: String::new(),
                announced: false,
            });
        }
        let Some(call) = self.calls.iter_mut().find(|call| call.index == index) else {
            return Vec::new();
        };

        if let Some(id) = fragment.get("id").and_then(Value::as_str)
            && !id.is_empty()
        {
            call.id = id.to_owned();
        }
        if let Some(name) = fragment
            .pointer("/function/name")
            .and_then(Value::as_str)
            .filter(|name| !name.is_empty())
        {
            call.name.push_str(name);
        }
        if let Some(arguments) = fragment
            .pointer("/function/arguments")
            .and_then(Value::as_str)
        {
            call.arguments.push_str(arguments);
        }

        if call.announced || call.name.is_empty() {
            return Vec::new();
        }
        call.announced = true;
        if call.id.is_empty() {
            call.id = format!("call-{index}");
        }
        vec![StreamEvent::ToolCallStarted {
            id: ToolCallId(call.id.clone()),
            name: call.name.clone(),
        }]
    }

    /// Hand over every call that has finished arriving, in the order the wire
    /// numbered them.
    fn flush(&mut self) -> Vec<StreamEvent> {
        let mut calls = std::mem::take(&mut self.calls);
        calls.sort_by_key(|call| call.index);
        calls
            .into_iter()
            .map(|call| {
                super::assembled_tool_call(RawToolCall {
                    id: if call.id.is_empty() {
                        format!("call-{}", call.index)
                    } else {
                        call.id
                    },
                    name: call.name,
                    arguments_json: call.arguments,
                })
            })
            .collect()
    }

    fn end(&mut self) -> Vec<StreamEvent> {
        if self.finished {
            return Vec::new();
        }
        self.finished = true;
        let mut out = self.flush();
        out.push(StreamEvent::Finished {
            stop: self.stop.unwrap_or(StopReason::EndTurn),
        });
        out
    }
}

fn usage_event(usage: &Value) -> Vec<StreamEvent> {
    let input = usage.get("prompt_tokens").and_then(Value::as_u64);
    let output = usage.get("completion_tokens").and_then(Value::as_u64);
    if input.is_none() && output.is_none() {
        return Vec::new();
    }
    vec![StreamEvent::Usage {
        input_tokens: input.unwrap_or(0) as u32,
        output_tokens: output.unwrap_or(0) as u32,
    }]
}

fn stop_reason(raw: &str) -> StopReason {
    match raw {
        "tool_calls" | "function_call" => StopReason::ToolCalls,
        "length" => StopReason::MaxOutputTokens,
        "content_filter" => StopReason::Filtered,
        _ => StopReason::EndTurn,
    }
}

// --- failures --------------------------------------------------------------

pub(super) fn error(status: u16, body: &str) -> ProviderError {
    let fallback = kind_for_status(status);
    // A status that names one thing and one thing only. 400 and 500 are not in
    // here on purpose: both cover too much to override what the body says.
    let definitive =
        matches!(status, 401 | 402 | 403 | 404 | 413 | 429 | 503 | 529).then_some(fallback);
    match serde_json::from_str::<Value>(body) {
        Ok(value) => error_from(value.get("error"), definitive, fallback),
        Err(_) => ProviderError::new(fallback, snippet(body)),
    }
}

/// Three sources disagree about what went wrong, and the order they are read
/// in is the decision.
///
/// `code` is exact. The status is next, because it is the one thing a proxy
/// cannot get wrong. `type` is read **last** and it is the field that looks
/// most authoritative: a wrong API key comes back as
/// `type: "invalid_request_error"` with `code: "invalid_api_key"`, so trusting
/// `type` would tell somebody with a mistyped key that they had sent a bad
/// request — and send them looking in entirely the wrong place.
fn error_from(
    error: Option<&Value>,
    status: Option<ProviderErrorKind>,
    fallback: ProviderErrorKind,
) -> ProviderError {
    let message = error
        .and_then(|e| e.get("message"))
        .and_then(Value::as_str)
        .unwrap_or("the provider reported an error without saying what")
        .to_owned();

    let code = error
        .and_then(|e| e.get("code"))
        .and_then(Value::as_str)
        .and_then(specific);
    let broad = error
        .and_then(|e| e.get("type"))
        .and_then(Value::as_str)
        .and_then(specific);

    ProviderError::new(code.or(status).or(broad).unwrap_or(fallback), message)
}

fn specific(name: &str) -> Option<ProviderErrorKind> {
    Some(match name {
        "invalid_api_key" | "authentication_error" => ProviderErrorKind::Unauthorized,
        "permission_error" | "account_deactivated" => ProviderErrorKind::Forbidden,
        // A family rather than one code, and the whole family has to be told
        // apart from a rate limit even though both arrive as a 429. Backing off
        // and retrying works for one and never works for the other, so getting
        // this wrong means a browser that retries a spend cap until somebody
        // gives up on it.
        "insufficient_quota"
        | "billing_hard_limit_reached"
        | "credit_balance_exhausted"
        | "organization_spend_limit_exceeded"
        | "project_spend_limit_exceeded"
        | "organization_usage_limit_exceeded" => ProviderErrorKind::QuotaExhausted,
        "rate_limit_exceeded" | "rate_limit_error" | "tokens_exceeded" => {
            ProviderErrorKind::RateLimited
        }
        "context_length_exceeded" | "string_above_max_length" => ProviderErrorKind::ContextTooLong,
        "content_filter" | "content_policy_violation" => ProviderErrorKind::ContentFiltered,
        "model_not_found" | "not_found_error" => ProviderErrorKind::ModelNotFound,
        "server_error" | "api_error" | "internal_error" => ProviderErrorKind::ServerError,
        "overloaded_error" | "engine_overloaded" | "slow_down" => ProviderErrorKind::Overloaded,
        "invalid_request_error" => ProviderErrorKind::InvalidRequest,
        _ => return None,
    })
}

fn snippet(body: &str) -> String {
    let trimmed = body.trim();
    if trimmed.is_empty() {
        return "the provider sent no explanation".into();
    }
    trimmed.chars().take(200).collect()
}

// --- listing ---------------------------------------------------------------

/// The thinnest listing of the four: ids and nothing else — no readable name,
/// no window, and every embedding, moderation and speech model in the same
/// list as the ones you can chat with.
///
/// Nothing is filtered out of it, and that is deliberate. The names that mark
/// a model as non-chat are OpenAI's own conventions, and this codec also talks
/// to a dozen servers that never adopted them; a filter written against one
/// vendor's naming would quietly hide half of somebody's self-hosted list.
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
                display_name: None,
                context_tokens: None,
            })
        })
        .collect())
}

fn malformed(what: &str) -> StreamEvent {
    StreamEvent::Failed {
        error: ProviderError::new(ProviderErrorKind::MalformedResponse, what),
    }
}
