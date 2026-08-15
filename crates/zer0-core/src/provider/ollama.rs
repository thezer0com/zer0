//! The local wire.
//!
//! A model on this machine, which for a browser that means what it says about
//! privacy is not a nice-to-have — it is the only configuration where the
//! conversation never leaves the laptop. It is in the first four for that
//! reason, not as a demonstration that the abstraction stretches.
//!
//! It is also the wire that proves the abstraction is not somebody's API with
//! adapters bolted on. It is the only one that is not SSE — it streams
//! newline-delimited JSON — it needs no token at all, its tool arguments arrive
//! as an object rather than as text to concatenate, and its tool results
//! correlate by name. None of that reaches the core.

use serde_json::{Map, Value, json};

use super::error::{ProviderError, ProviderErrorKind, kind_for_status};
use crate::chat::ToolCallId;
use crate::sse::Frame;

use super::{
    ChatRequest, Content, ModelInfo, RawToolCall, Role, StopReason, StreamEvent, WireMessage,
};

pub(super) fn stream_request(
    root: &str,
    chat: &ChatRequest,
) -> Result<(String, String), ProviderError> {
    let mut messages = Vec::new();
    if let Some(system) = &chat.system {
        // A role rather than a top-level field here. `ChatRequest` keeps the
        // system prompt out of the transcript so that the two wires which
        // demand it out of the transcript do not have to dig it back out; the
        // two that want it as a message put it back, exactly once.
        messages.push(json!({ "role": "system", "content": system }));
    }
    for message in &chat.messages {
        messages.extend(wire_messages(message));
    }

    let mut body = Map::new();
    body.insert("model".into(), json!(chat.model));
    body.insert("messages".into(), Value::Array(messages));
    // Stated rather than left to the default, which is `true` here and `false`
    // almost everywhere else. A default worth relying on is one that is the
    // same on both sides of an upgrade.
    body.insert("stream".into(), json!(true));

    let mut options = Map::new();
    if let Some(temperature) = chat.temperature {
        options.insert("temperature".into(), json!(temperature));
    }
    if let Some(max) = chat.max_output_tokens {
        options.insert("num_predict".into(), json!(max));
    }
    if !options.is_empty() {
        body.insert("options".into(), Value::Object(options));
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

    Ok((format!("{root}/api/chat"), Value::Object(body).to_string()))
}

/// One turn can become several messages here, because a tool result is a
/// message of its own rather than a block inside one.
///
/// This is the second shape [`Content`] has to bend into, and it bends the
/// opposite way from Anthropic's: there a result nests inside a user turn, here
/// it is unwrapped into a sibling. One list of content covers both.
fn wire_messages(message: &WireMessage) -> Vec<Value> {
    let mut out = Vec::new();
    let mut text = String::new();
    let mut calls = Vec::new();

    for content in &message.content {
        match content {
            Content::Text { text: fragment } => text.push_str(fragment),
            Content::ToolCall { call } => calls.push(json!({
                "function": {
                    "name": call.name,
                    // An object, not a string. The one field on any of these
                    // four wires whose *type* differs for the same idea.
                    "arguments": serde_json::from_str::<Value>(&call.arguments_json)
                        .unwrap_or_else(|_| json!({})),
                }
            })),
            Content::ToolResult {
                name,
                output,
                is_error,
                call_id: _,
            } => out.push(json!({
                "role": "tool",
                "tool_name": name,
                // No flag for failure on this wire, so a failed tool has to say
                // so in words. Prefixed rather than dropped: a model handed a
                // bare stack trace under a successful result reads it as data.
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
        // Ahead of any tool result in the same turn, because a result that
        // arrives before the call it answers is a transcript out of order.
        out.insert(0, Value::Object(wire));
    }

    out
}

// --- reading ---------------------------------------------------------------

#[derive(Debug, Default)]
pub(super) struct Decoder {
    started: bool,
    calls: u32,
    saw_tool_call: bool,
}

impl Decoder {
    pub(super) fn frame(&mut self, frame: &Frame) -> Vec<StreamEvent> {
        let Ok(value) = serde_json::from_str::<Value>(&frame.data) else {
            return vec![malformed("a line that was not JSON")];
        };

        // A failure mid-stream is a line with nothing else in it. There is no
        // status code left to read by then: the response was a 200.
        if let Some(message) = value.get("error").and_then(Value::as_str) {
            return vec![StreamEvent::Failed {
                error: from_message(message, ProviderErrorKind::ServerError),
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

        if let Some(message) = value.get("message") {
            if let Some(thinking) = message.get("thinking").and_then(Value::as_str)
                && !thinking.is_empty()
            {
                out.push(StreamEvent::ReasoningDelta {
                    text: thinking.to_owned(),
                });
            }
            if let Some(text) = message.get("content").and_then(Value::as_str)
                && !text.is_empty()
            {
                out.push(StreamEvent::TextDelta {
                    text: text.to_owned(),
                });
            }
            if let Some(calls) = message.get("tool_calls").and_then(Value::as_array) {
                for call in calls {
                    out.extend(self.tool_call(call));
                }
            }
        }

        if value.get("done").and_then(Value::as_bool) == Some(true) {
            out.extend(self.done(&value));
        }
        out
    }

    /// The connection closed with no `done` line.
    ///
    /// The daemon was killed, or the model was evicted mid-generation. Not a
    /// finished turn, and reporting it as one would show a half sentence as an
    /// answer.
    pub(super) fn eof(&mut self) -> Vec<StreamEvent> {
        Vec::new()
    }

    fn tool_call(&mut self, call: &Value) -> Vec<StreamEvent> {
        let function = call.get("function");
        let name = function
            .and_then(|f| f.get("name"))
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned();

        // An id is in the schema and is usually absent. When it is absent the
        // wire correlates by `function.index`, and when that is absent too the
        // order calls arrived in is all there is. All three roads end at a
        // stable string, which is what the core was promised.
        let id = call
            .get("id")
            .and_then(Value::as_str)
            .filter(|id| !id.is_empty())
            .map(str::to_owned)
            .unwrap_or_else(|| {
                let index = function
                    .and_then(|f| f.get("index"))
                    .and_then(Value::as_u64)
                    .unwrap_or(u64::from(self.calls));
                format!("call-{index}")
            });
        self.calls += 1;
        self.saw_tool_call = true;

        vec![
            StreamEvent::ToolCallStarted {
                id: ToolCallId(id.clone()),
                name: name.clone(),
            },
            super::assembled_tool_call(RawToolCall {
                id,
                name,
                arguments_json: function
                    .and_then(|f| f.get("arguments"))
                    .map(ToString::to_string)
                    .unwrap_or_else(|| "{}".into()),
            }),
        ]
    }

    fn done(&self, value: &Value) -> Vec<StreamEvent> {
        let mut out = Vec::new();

        let input = value.get("prompt_eval_count").and_then(Value::as_u64);
        let output = value.get("eval_count").and_then(Value::as_u64);
        if input.is_some() || output.is_some() {
            out.push(StreamEvent::Usage {
                input_tokens: input.unwrap_or(0) as u32,
                output_tokens: output.unwrap_or(0) as u32,
            });
        }

        let stop = match value.get("done_reason").and_then(Value::as_str) {
            Some("length") => StopReason::MaxOutputTokens,
            // "load" and "unload" answer a request that was never a chat.
            // Nothing was said, and reporting it as a finished turn would draw
            // an empty reply — but it is also not a fault anybody can fix.
            _ if self.saw_tool_call => StopReason::ToolCalls,
            _ => StopReason::EndTurn,
        };
        out.push(StreamEvent::Finished { stop });
        out
    }
}

// --- failures --------------------------------------------------------------

/// The flattest envelope of the four: one string, no type, no code.
///
/// So the status carries the category and the message narrows it, which is the
/// reverse of everywhere else. The two cases worth naming are both worth
/// naming precisely: a model nobody has pulled yet, and a model that cannot do
/// tools — the first is one `ollama pull` away and the second is a different
/// model, and telling someone "not found" for the second would send them to
/// run a command that will not help.
pub(super) fn error(status: u16, body: &str) -> ProviderError {
    let fallback = kind_for_status(status);
    let message = serde_json::from_str::<Value>(body)
        .ok()
        .and_then(|value| {
            value
                .get("error")
                .and_then(Value::as_str)
                .map(str::to_owned)
        })
        .unwrap_or_else(|| snippet(body));
    from_message(&message, fallback)
}

fn from_message(message: &str, fallback: ProviderErrorKind) -> ProviderError {
    let lowered = message.to_lowercase();
    let kind = if lowered.contains("try pulling it") || lowered.contains("not found") {
        ProviderErrorKind::ModelNotFound
    } else if lowered.contains("does not support") {
        // A local model that cannot do what was asked. Not a bad request we
        // built and not a server fault: the fix is picking another model, which
        // is the same fix as a model that does not exist.
        ProviderErrorKind::ModelNotFound
    } else if lowered.contains("context") && lowered.contains("exceed") {
        ProviderErrorKind::ContextTooLong
    } else {
        fallback
    };
    ProviderError::new(kind, message.to_owned())
}

fn snippet(body: &str) -> String {
    let trimmed = body.trim();
    if trimmed.is_empty() {
        return "the local model server sent no explanation".into();
    }
    trimmed.chars().take(200).collect()
}

// --- listing -------------------------------------------------------------

/// What is pulled, which is the only list that matters locally: a model that
/// is not on disk is not a model you can talk to, however famous it is.
///
/// No context window here. It exists, per model, behind a second call whose
/// key is prefixed by the architecture — `llama.context_length`,
/// `qwen3.context_length` — and a dropdown is not worth one round trip per
/// row. [`ModelInfo::context_tokens`] stays `None` rather than guessed.
pub(super) fn models(body: &str) -> Result<Vec<ModelInfo>, ProviderError> {
    let value: Value = serde_json::from_str(body)
        .map_err(|_| ProviderError::new(ProviderErrorKind::MalformedResponse, snippet(body)))?;
    let Some(models) = value.get("models").and_then(Value::as_array) else {
        return Err(ProviderError::new(
            ProviderErrorKind::MalformedResponse,
            "the model list had no models in it",
        ));
    };

    Ok(models
        .iter()
        .filter_map(|model| {
            let id = model
                .get("model")
                .or_else(|| model.get("name"))
                .and_then(Value::as_str)?;
            Some(ModelInfo {
                id: id.to_owned(),
                // Size is the only readable thing on offer, and on a local
                // machine it is the thing that decides: `8B` and `70B` is the
                // difference between an answer now and a warm laptop.
                display_name: model
                    .pointer("/details/parameter_size")
                    .and_then(Value::as_str)
                    .map(|size| format!("{id} ({size})")),
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
