//! The `generateContent` wire.
//!
//! The odd one out of the four, in three ways that each cost something:
//!
//! - **SSE is opt-in.** Without `?alt=sse` the response is a JSON *array*
//!   delivered in chunks, which would need an incremental array parser. The
//!   query parameter is not a nicety, it is what makes this wire the same shape
//!   as the other three.
//! - **A tool call has no usable id.** `FunctionCall.id` exists in the schema
//!   and comes back empty from this endpoint; it is populated only on the live
//!   API. Parallel calls are correlated **by position and name**, which is why
//!   [`super::Content::ToolResult`] carries a name at all.
//! - **A refusal is a 200.** Blocked content arrives with a normal status and a
//!   `blockReason`, so a shell that only inspected the status code would show a
//!   reply that never came as an empty bubble.

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
    let mut body = Map::new();
    body.insert("contents".into(), Value::Array(contents(&chat.messages)));

    if let Some(system) = &chat.system {
        // Its own top-level field, not a message, which is the shape
        // `ChatRequest::system` was built for.
        body.insert(
            "systemInstruction".into(),
            json!({ "parts": [{ "text": system }] }),
        );
    }

    let mut config = Map::new();
    if let Some(max) = chat.max_output_tokens {
        config.insert("maxOutputTokens".into(), json!(max));
    }
    if let Some(temperature) = chat.temperature {
        config.insert("temperature".into(), json!(temperature));
    }
    if !config.is_empty() {
        body.insert("generationConfig".into(), Value::Object(config));
    }

    if !chat.tools.is_empty() {
        let mut declarations = Vec::with_capacity(chat.tools.len());
        for tool in &chat.tools {
            declarations.push(json!({
                "name": tool.name,
                "description": tool.description,
                "parameters": narrow_schema(&super::schema(&tool.input_schema_json)?),
            }));
        }
        body.insert(
            "tools".into(),
            json!([{ "functionDeclarations": declarations }]),
        );
    }

    Ok((
        format!(
            "{root}/v1beta/models/{}:streamGenerateContent?alt=sse",
            chat.model
        ),
        Value::Object(body).to_string(),
    ))
}

/// Everything a `Schema` here is allowed to be.
///
/// An allow-list rather than a list of things to strip, and that direction is
/// the decision. This wire takes a subset of OpenAPI, the documentation does not
/// enumerate what is missing, and a deny-list written against today's rejections
/// silently starts passing whatever JSON Schema adds next — at which point a
/// tool that worked yesterday returns a 400 naming no tool in particular.
///
/// The cost is real and worth stating: an MCP tool declaring `oneOf`, `$ref` or
/// `additionalProperties` has those constraints dropped for this provider, so
/// the model is told less about its own arguments than the tool actually
/// enforces. That is strictly better than the request being refused, and it is
/// the same trade every client library makes here.
const SUPPORTED_SCHEMA_KEYWORDS: &[&str] = &[
    "type",
    "format",
    "title",
    "description",
    "nullable",
    "enum",
    "items",
    "prefixItems",
    "properties",
    "required",
    "propertyOrdering",
    "minimum",
    "maximum",
    "minItems",
    "maxItems",
    "anyOf",
];

/// Three wildcards over `serde_json::Value`, and all three mean the same thing:
/// this is not the shape the keyword implies, so hand it back untouched and let
/// Gemini refuse it.
///
/// The schema being narrowed came out of an MCP server's `tools/list` — read
/// off a socket, believed by nobody (ADR-0024). `Value` is the open set that
/// ADR-0031 names as out of scope by construction: listing `Null`, `Bool`,
/// `Number` and `String` here would be four arms writing `other.clone()` four
/// times, and it would still not be exhaustive in any useful sense, because
/// what arrives is a JSON document rather than a variant somebody chose.
#[allow(
    clippy::wildcard_enum_match_arm,
    reason = "serde_json::Value is a foreign enum over untrusted JSON; every variant that is \
              not the expected shape is passed through unchanged, so naming them would be the \
              same arm written four times"
)]
fn narrow_schema(schema: &Value) -> Value {
    match schema {
        Value::Object(fields) => {
            let mut narrowed = Map::new();
            for (key, value) in fields {
                if !SUPPORTED_SCHEMA_KEYWORDS.contains(&key.as_str()) {
                    continue;
                }
                narrowed.insert(
                    key.clone(),
                    match key.as_str() {
                        // `enum` is a list of literal values, not of schemas.
                        // Recursing into it would rewrite the values.
                        "enum" | "required" | "propertyOrdering" => value.clone(),
                        "properties" => match value {
                            Value::Object(properties) => Value::Object(
                                properties
                                    .iter()
                                    .map(|(name, property)| (name.clone(), narrow_schema(property)))
                                    .collect(),
                            ),
                            other => other.clone(),
                        },
                        "anyOf" | "prefixItems" => match value {
                            Value::Array(entries) => {
                                Value::Array(entries.iter().map(narrow_schema).collect())
                            }
                            other => other.clone(),
                        },
                        _ => narrow_schema(value),
                    },
                );
            }
            Value::Object(narrowed)
        }
        other => other.clone(),
    }
}

/// A tool result goes back as a `user` turn holding `functionResponse` parts.
///
/// The order of those parts is load-bearing: with no id to match on, the only
/// correlation this wire has is position within the turn. The core preserves
/// the order it received the calls in, so this preserves it too.
fn contents(messages: &[WireMessage]) -> Vec<Value> {
    messages
        .iter()
        .map(|message| {
            let parts: Vec<Value> = message.content.iter().map(part).collect();
            json!({
                "role": match message.role {
                    Role::User => "user",
                    Role::Assistant => "model",
                },
                "parts": parts,
            })
        })
        .collect()
}

fn part(content: &Content) -> Value {
    match content {
        Content::Text { text } => json!({ "text": text }),
        Content::ToolCall { call } => json!({
            "functionCall": {
                "name": call.name,
                "args": serde_json::from_str::<Value>(&call.arguments_json)
                    .unwrap_or_else(|_| json!({})),
            }
        }),
        Content::ToolResult {
            name,
            output,
            is_error,
            // No field on this wire takes it. The name above is what correlates.
            call_id: _,
        } => json!({
            "functionResponse": {
                "name": name,
                // The documented keys: `output` for a result, `error` for a
                // failure. Sending a failure under `output` reads to the model
                // as a successful call that returned the word "error".
                "response": if *is_error {
                    json!({ "error": output })
                } else {
                    json!({ "output": output })
                },
            }
        }),
    }
}

// --- reading ---------------------------------------------------------------

#[derive(Debug, Default)]
pub(super) struct Decoder {
    started: bool,
    /// Numbers the calls in a reply, because the wire does not. Deterministic,
    /// so the same stream decodes to the same ids twice.
    calls: u32,
    saw_tool_call: bool,
}

impl Decoder {
    pub(super) fn frame(&mut self, frame: &Frame) -> Vec<StreamEvent> {
        let Ok(value) = serde_json::from_str::<Value>(&frame.data) else {
            return vec![malformed("a chunk that was not JSON")];
        };

        // An error can arrive inside a 200 stream, in the same envelope a
        // failed request uses.
        if let Some(error) = value.get("error") {
            return vec![StreamEvent::Failed {
                error: error_from(error, ProviderErrorKind::ServerError),
            }];
        }

        let mut out = Vec::new();
        if !self.started {
            self.started = true;
            out.push(StreamEvent::Started {
                model: value
                    .get("modelVersion")
                    .and_then(Value::as_str)
                    .map(str::to_owned),
            });
        }

        // The prompt itself was refused. `candidates` is absent in this case,
        // so there is nothing else in the chunk to read.
        if let Some(reason) = value
            .pointer("/promptFeedback/blockReason")
            .and_then(Value::as_str)
        {
            out.push(StreamEvent::Failed {
                error: ProviderError::new(
                    ProviderErrorKind::ContentFiltered,
                    format!("the provider refused the request ({reason})"),
                ),
            });
            return out;
        }

        if let Some(usage) = value.get("usageMetadata") {
            out.extend(usage_event(usage));
        }

        let candidate = value
            .get("candidates")
            .and_then(Value::as_array)
            .and_then(|candidates| candidates.first());
        let Some(candidate) = candidate else {
            return out;
        };

        if let Some(parts) = candidate
            .pointer("/content/parts")
            .and_then(Value::as_array)
        {
            for part in parts {
                out.extend(self.part(part));
            }
        }

        if let Some(reason) = candidate.get("finishReason").and_then(Value::as_str) {
            out.push(self.finish(reason));
        }
        out
    }

    /// The connection closed with no `finishReason`.
    ///
    /// Every candidate carries one when it is done, so its absence means the
    /// stream was cut rather than finished, and there is nothing to salvage.
    pub(super) fn eof(&mut self) -> Vec<StreamEvent> {
        Vec::new()
    }

    fn part(&mut self, part: &Value) -> Vec<StreamEvent> {
        if let Some(call) = part.get("functionCall") {
            let name = call
                .get("name")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_owned();
            let id = format!("call-{}", self.calls);
            self.calls += 1;
            self.saw_tool_call = true;
            // Arguments arrive whole here — the object is inside one complete
            // chunk — so there is nothing to accumulate and `ToolCallStarted`
            // and the call itself land together. The pair is still emitted so
            // the core has one shape for every wire.
            return vec![
                StreamEvent::ToolCallStarted {
                    id: ToolCallId(id.clone()),
                    name: name.clone(),
                },
                super::assembled_tool_call(RawToolCall {
                    id,
                    name,
                    arguments_json: call
                        .get("args")
                        .map(ToString::to_string)
                        .unwrap_or_else(|| "{}".into()),
                }),
            ];
        }

        let Some(text) = part.get("text").and_then(Value::as_str) else {
            return Vec::new();
        };
        if text.is_empty() {
            return Vec::new();
        }
        // A part flagged as thought is the model's reasoning, and the field is
        // what separates it from the reply. Without this check the two would be
        // concatenated into one bubble.
        if part.get("thought").and_then(Value::as_bool) == Some(true) {
            return vec![StreamEvent::ReasoningDelta {
                text: text.to_owned(),
            }];
        }
        vec![StreamEvent::TextDelta {
            text: text.to_owned(),
        }]
    }

    fn finish(&self, reason: &str) -> StreamEvent {
        match reason {
            "STOP" if self.saw_tool_call => StreamEvent::Finished {
                stop: StopReason::ToolCalls,
            },
            "STOP" | "FINISH_REASON_UNSPECIFIED" | "OTHER" => StreamEvent::Finished {
                stop: StopReason::EndTurn,
            },
            "MAX_TOKENS" => StreamEvent::Finished {
                stop: StopReason::MaxOutputTokens,
            },
            "SAFETY" | "RECITATION" | "BLOCKLIST" | "PROHIBITED_CONTENT" | "SPII"
            | "IMAGE_SAFETY" | "LANGUAGE" => StreamEvent::Finished {
                stop: StopReason::Filtered,
            },
            // The model produced a call this wire could not encode, or called
            // something it was not offered. Nothing anybody reading the screen
            // did, and trying again genuinely can work — so it is a fault to
            // report, not a turn to draw as finished.
            other => StreamEvent::Failed {
                error: ProviderError::new(
                    ProviderErrorKind::ServerError,
                    format!("the reply ended with {other}"),
                ),
            },
        }
    }
}

fn usage_event(usage: &Value) -> Vec<StreamEvent> {
    let input = usage.get("promptTokenCount").and_then(Value::as_u64);
    let output = usage.get("candidatesTokenCount").and_then(Value::as_u64);
    if input.is_none() && output.is_none() {
        return Vec::new();
    }
    vec![StreamEvent::Usage {
        input_tokens: input.unwrap_or(0) as u32,
        output_tokens: output.unwrap_or(0) as u32,
    }]
}

// --- failures --------------------------------------------------------------

pub(super) fn error(status: u16, body: &str) -> ProviderError {
    let fallback = kind_for_status(status);
    match serde_json::from_str::<Value>(body) {
        Ok(value) => match value.get("error") {
            Some(error) => error_from(error, fallback),
            None => ProviderError::new(fallback, snippet(body)),
        },
        Err(_) => ProviderError::new(fallback, snippet(body)),
    }
}

fn error_from(error: &Value, fallback: ProviderErrorKind) -> ProviderError {
    let message = error
        .get("message")
        .and_then(Value::as_str)
        .unwrap_or("the provider reported an error without saying what")
        .to_owned();

    // Two envelopes are in the wild at once. The long-standing one carries a
    // `status` string beside a numeric `code`; the newer one moves the name
    // into `code` and drops `status`. Reading both is not defensiveness, it is
    // the only way one parser covers the endpoints that exist today.
    let named = error
        .get("status")
        .and_then(Value::as_str)
        .or_else(|| error.get("code").and_then(Value::as_str));

    let kind = named
        .map(|name| error_kind(name, fallback))
        .unwrap_or(fallback);
    ProviderError::new(kind, message)
}

fn error_kind(name: &str, fallback: ProviderErrorKind) -> ProviderErrorKind {
    match name {
        "UNAUTHENTICATED" | "authentication" => ProviderErrorKind::Unauthorized,
        "PERMISSION_DENIED" | "permission_denied" => ProviderErrorKind::Forbidden,
        "NOT_FOUND" | "not_found" | "model_not_found" => ProviderErrorKind::ModelNotFound,
        // The same status covers "too many requests a minute" and "you are out
        // of quota for the day". They separate on the status code, which is
        // 429 either way, so the message is all there is — and the honest
        // reading of "resource exhausted" is the retryable one.
        "RESOURCE_EXHAUSTED" | "rate_limit_exceeded" => ProviderErrorKind::RateLimited,
        "quota_exceeded" => ProviderErrorKind::QuotaExhausted,
        "INVALID_ARGUMENT" | "invalid_request" | "parameter_unknown" | "OUT_OF_RANGE"
        | "out_of_range" => ProviderErrorKind::InvalidRequest,
        "FAILED_PRECONDITION" | "failed_precondition" => ProviderErrorKind::Forbidden,
        "UNAVAILABLE" | "service_unavailable" => ProviderErrorKind::Overloaded,
        "INTERNAL" | "api_error" | "DEADLINE_EXCEEDED" | "deadline_exceeded" | "unimplemented"
        | "UNIMPLEMENTED" => ProviderErrorKind::ServerError,
        "CANCELLED" | "cancelled" => ProviderErrorKind::Cancelled,
        _ => fallback,
    }
}

fn snippet(body: &str) -> String {
    let trimmed = body.trim();
    if trimmed.is_empty() {
        return "the provider sent no explanation".into();
    }
    trimmed.chars().take(200).collect()
}

// --- listing ---------------------------------------------------------------

/// The richest listing of the four: a readable name *and* the input window,
/// stated by the provider rather than guessed from the id.
///
/// Filtered to models that can actually be talked to. A listing that offered
/// an embedding model as something to chat with would be a dropdown that
/// contains its own bug report.
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
            let name = model.get("name").and_then(Value::as_str)?;
            let generates = model
                .get("supportedGenerationMethods")
                .and_then(Value::as_array)
                .map(|methods| {
                    methods
                        .iter()
                        .any(|method| method.as_str() == Some("generateContent"))
                })
                // A model that does not say what it supports is offered rather
                // than hidden: the cost of a wrong entry in a list is smaller
                // than the cost of the list missing the model somebody wanted.
                .unwrap_or(true);
            if !generates {
                return None;
            }
            Some(ModelInfo {
                // `models/gemini-x` is the resource path; the id that goes in a
                // request is what follows the slash.
                id: name.strip_prefix("models/").unwrap_or(name).to_owned(),
                display_name: model
                    .get("displayName")
                    .and_then(Value::as_str)
                    .map(str::to_owned),
                context_tokens: model
                    .get("inputTokenLimit")
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
