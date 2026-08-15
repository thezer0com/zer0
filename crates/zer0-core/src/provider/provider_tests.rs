//! What the provider layer promises, checked without a network.
//!
//! Nothing here opens a socket, and nothing here can: the whole layer is bytes
//! in and events out. That is the point of the design and it is what lets these
//! tests be exact — a chunk boundary is placed on purpose, in the middle of a
//! word, and the same test runs the same way on a machine with no wifi.

use super::*;
use crate::chat::{
    Message as ChatMessage, MessageId, MessageRole, MessageState, PageReference, ToolCall,
    ToolCallState,
};

// --- fixtures --------------------------------------------------------------

fn anthropic() -> ProviderEndpoint {
    ProviderEndpoint::preset(WireFormat::AnthropicMessages, "claude")
}

fn openai() -> ProviderEndpoint {
    ProviderEndpoint::preset(WireFormat::OpenAiChat, "openai")
}

fn gemini() -> ProviderEndpoint {
    ProviderEndpoint::preset(WireFormat::GeminiGenerateContent, "google")
}

fn ollama() -> ProviderEndpoint {
    ProviderEndpoint::preset(WireFormat::OllamaChat, "local")
}

fn every_wire() -> Vec<ProviderEndpoint> {
    vec![anthropic(), openai(), gemini(), ollama()]
}

fn said(role: MessageRole, text: &str) -> ChatMessage {
    ChatMessage {
        id: MessageId(1),
        role,
        text: text.to_owned(),
        page: None,
        state: MessageState::Complete,
        tool_calls: Vec::new(),
        answers: None,
        model: None,
        created_at_ms: 0,
    }
}

fn tool() -> ToolSpec {
    ToolSpec {
        server: "browser".into(),
        tool: "read_page".into(),
        summary: "Read the current page".into(),
        input_schema_json: r#"{"type":"object","properties":{"url":{"type":"string"}}}"#.into(),
    }
}

fn body_of(built: &HttpRequest) -> serde_json::Value {
    serde_json::from_str(&built.body).expect("the body we built is JSON")
}

/// Feed a whole response one byte at a time.
///
/// The cruellest split there is, and the one that catches everything a
/// half-chunked test would miss: every boundary is exercised at once, including
/// the ones inside `data:`, inside a JSON escape and inside a word.
fn decode_byte_by_byte(wire: WireFormat, tools: &[ToolSpec], body: &str) -> Vec<StreamEvent> {
    let mut decoder = StreamDecoder::new(wire, tools);
    let mut events = Vec::new();
    for byte in body.as_bytes() {
        events.extend(decoder.push(&[*byte]));
    }
    events.extend(decoder.finish());
    events
}

fn decode_whole(wire: WireFormat, tools: &[ToolSpec], body: &str) -> Vec<StreamEvent> {
    let mut decoder = StreamDecoder::new(wire, tools);
    let mut events = decoder.push(body.as_bytes());
    events.extend(decoder.finish());
    events
}

// Three ways of asking "was this one of these", written as `if let` rather
// than as a match with a wildcard. The distinction is the one ADR-0031 draws:
// a filter picks a variant out, it does not decide what happens to each one,
// and only the second shape has anything to gain from exhaustiveness.
fn text_of(events: &[StreamEvent]) -> String {
    events
        .iter()
        .filter_map(|event| {
            if let StreamEvent::TextDelta { text } = event {
                Some(text.as_str())
            } else {
                None
            }
        })
        .collect()
}

fn calls_of(events: &[StreamEvent]) -> Vec<ToolInvocation> {
    events
        .iter()
        .filter_map(|event| {
            if let StreamEvent::ToolCall { invocation } = event {
                Some(invocation.clone())
            } else {
                None
            }
        })
        .collect()
}

fn failure_of(events: &[StreamEvent]) -> Option<ProviderError> {
    events.iter().find_map(|event| {
        if let StreamEvent::Failed { error } = event {
            Some(error.clone())
        } else {
            None
        }
    })
}

// --- the streams, verbatim -------------------------------------------------

const ANTHROPIC_REPLY: &str = concat!(
    "event: message_start\n",
    r#"data: {"type":"message_start","message":{"id":"msg_1","model":"claude-sonnet-4-5-20250929","usage":{"input_tokens":11,"output_tokens":1}}}"#,
    "\n\n",
    "event: content_block_start\n",
    r#"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
    "\n\n",
    "event: ping\ndata: {\"type\": \"ping\"}\n\n",
    "event: content_block_delta\n",
    r#"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Edin"}}"#,
    "\n\n",
    "event: content_block_delta\n",
    r#"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"burgh"}}"#,
    "\n\n",
    "event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n",
    "event: message_delta\n",
    r#"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":9}}"#,
    "\n\n",
    "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n",
);

const OPENAI_REPLY: &str = concat!(
    r#"data: {"id":"chatcmpl-1","model":"gpt-4o-mini-2024-07-18","choices":[{"index":0,"delta":{"role":"assistant","content":"","refusal":null},"finish_reason":null}],"usage":null,"obfuscation":""}"#,
    "\n\n",
    r#"data: {"choices":[{"index":0,"delta":{"content":"Edin"},"finish_reason":null}],"usage":null,"obfuscation":"l7qY"}"#,
    "\n\n",
    r#"data: {"choices":[{"index":0,"delta":{"content":"burgh"},"finish_reason":null}],"usage":null}"#,
    "\n\n",
    r#"data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":null}"#,
    "\n\n",
    r#"data: {"choices":[],"usage":{"prompt_tokens":22,"completion_tokens":9,"total_tokens":31}}"#,
    "\n\n",
    "data: [DONE]\n\n",
);

const GEMINI_REPLY: &str = concat!(
    r#"data: {"candidates":[{"content":{"parts":[{"text":"Edin"}],"role":"model"}}],"modelVersion":"gemini-2.5-flash"}"#,
    "\n\n",
    r#"data: {"candidates":[{"content":{"parts":[{"text":"burgh"}],"role":"model"},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":22,"candidatesTokenCount":9}}"#,
    "\n\n",
);

const OLLAMA_REPLY: &str = concat!(
    r#"{"model":"llama3.2","message":{"role":"assistant","content":"Edin"},"done":false}"#,
    "\n",
    r#"{"model":"llama3.2","message":{"role":"assistant","content":"burgh"},"done":false}"#,
    "\n",
    r#"{"model":"llama3.2","message":{"role":"assistant","content":""},"done":true,"done_reason":"stop","prompt_eval_count":22,"eval_count":9}"#,
    "\n",
);

fn reply_for(wire: WireFormat) -> &'static str {
    match wire {
        WireFormat::AnthropicMessages => ANTHROPIC_REPLY,
        WireFormat::OpenAiChat => OPENAI_REPLY,
        WireFormat::GeminiGenerateContent => GEMINI_REPLY,
        WireFormat::OllamaChat => OLLAMA_REPLY,
    }
}

// --- streaming assembly ----------------------------------------------------

/// The load-bearing test of the whole layer.
///
/// A reply is fed a byte at a time, which splits every word, every field name
/// and every JSON escape in the stream, and the same four events come out as
/// when it arrives whole. If this passes, no chunk boundary anywhere can be
/// visible to the core.
#[test]
fn a_reply_split_in_the_middle_of_a_word_arrives_whole() {
    for endpoint in every_wire() {
        let body = reply_for(endpoint.wire);
        let dribbled = decode_byte_by_byte(endpoint.wire, &[], body);
        let at_once = decode_whole(endpoint.wire, &[], body);

        assert_eq!(
            dribbled, at_once,
            "{:?} disagrees with itself",
            endpoint.wire
        );
        assert_eq!(text_of(&dribbled), "Edinburgh", "{:?}", endpoint.wire);
        assert!(
            dribbled.contains(&StreamEvent::Finished {
                stop: StopReason::EndTurn
            }),
            "{:?} never finished: {dribbled:?}",
            endpoint.wire
        );
        assert!(
            dribbled.contains(&StreamEvent::Usage {
                input_tokens: 22,
                output_tokens: 9
            }) || matches!(endpoint.wire, WireFormat::AnthropicMessages),
            "{:?} lost its usage: {dribbled:?}",
            endpoint.wire
        );
    }
}

/// Every wire says who actually answered, and the answer is not the id that was
/// asked for. It is what `Action::ChatReplyStarted` records on the message.
#[test]
fn every_wire_says_which_model_replied() {
    for endpoint in every_wire() {
        let events = decode_whole(endpoint.wire, &[], reply_for(endpoint.wire));
        let started = events.first().expect("something happened");
        let StreamEvent::Started { model } = started else {
            panic!("{:?} opened with {started:?}", endpoint.wire)
        };
        assert!(model.is_some(), "{:?} did not name a model", endpoint.wire);
    }
}

/// A keep-alive comment, a `ping`, and a blank line between events are all
/// noise, and noise must not become an empty message.
#[test]
fn keep_alives_and_comments_produce_nothing() {
    let noise = format!(": ping\n\n: still here\n\n{ANTHROPIC_REPLY}");
    let events = decode_byte_by_byte(WireFormat::AnthropicMessages, &[], &noise);
    assert_eq!(text_of(&events), "Edinburgh");
    assert!(failure_of(&events).is_none(), "{events:?}");
}

/// `\r\n` is what a strict server writes, and treating the carriage return as
/// content turns every event name into one nobody recognises.
#[test]
fn a_stream_with_carriage_returns_reads_the_same() {
    let strict = OPENAI_REPLY.replace('\n', "\r\n");
    assert_eq!(
        text_of(&decode_byte_by_byte(WireFormat::OpenAiChat, &[], &strict)),
        "Edinburgh"
    );
}

// --- tool calling, which is where the wires disagree most ------------------

/// One tool, four wires, one shape out.
///
/// The arguments arrive as text fragments on two of them and as an object on
/// the other two; there is a call id on two and none on the other two. What the
/// core receives is identical, resolved back to the server and tool it named.
#[test]
fn a_tool_call_comes_back_the_same_shape_from_every_wire() {
    let tools = vec![tool()];

    let streams = [
        (
            WireFormat::AnthropicMessages,
            concat!(
                "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"model\":\"claude\"}}\n\n",
                "event: content_block_start\n",
                r#"data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_9","name":"browser__read_page","input":{}}}"#,
                "\n\n",
                "event: content_block_delta\n",
                r#"data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"url\": \"htt"}}"#,
                "\n\n",
                "event: content_block_delta\n",
                r#"data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"ps://a.example\"}"}}"#,
                "\n\n",
                "event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n",
                "event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"}}\n\n",
                "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n",
            ),
        ),
        (
            WireFormat::OpenAiChat,
            concat!(
                r#"data: {"model":"gpt-4o","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_9","type":"function","function":{"name":"browser__read_page","arguments":""}}]}}]}"#,
                "\n\n",
                r#"data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"url\": \"htt"}}]}}]}"#,
                "\n\n",
                r#"data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"ps://a.example\"}"}}]}}]}"#,
                "\n\n",
                r#"data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#,
                "\n\ndata: [DONE]\n\n",
            ),
        ),
        (
            WireFormat::GeminiGenerateContent,
            concat!(
                r#"data: {"modelVersion":"gemini-2.5-flash","candidates":[{"content":{"parts":[{"functionCall":{"name":"browser__read_page","args":{"url":"https://a.example"}}}],"role":"model"},"finishReason":"STOP"}]}"#,
                "\n\n",
            ),
        ),
        (
            WireFormat::OllamaChat,
            concat!(
                r#"{"model":"llama3.2","message":{"role":"assistant","content":"","tool_calls":[{"function":{"index":0,"name":"browser__read_page","arguments":{"url":"https://a.example"}}}]},"done":false}"#,
                "\n",
                r#"{"model":"llama3.2","message":{"role":"assistant","content":""},"done":true,"done_reason":"stop"}"#,
                "\n",
            ),
        ),
    ];

    for (wire, body) in streams {
        let events = decode_byte_by_byte(wire, &tools, body);
        let calls = calls_of(&events);

        assert_eq!(calls.len(), 1, "{wire:?} produced {calls:?}");
        assert_eq!(calls[0].server, "browser", "{wire:?} lost the server");
        assert_eq!(calls[0].tool, "read_page", "{wire:?} lost the tool");
        assert!(!calls[0].id.0.is_empty(), "{wire:?} produced no call id");

        // The text is compared as parsed JSON: the wires that send an object
        // are re-serialised, and key order is not something to assert on.
        let arguments: serde_json::Value =
            serde_json::from_str(&calls[0].arguments).expect("arguments are whole JSON");
        assert_eq!(arguments["url"], "https://a.example", "{wire:?}");

        assert!(
            events.contains(&StreamEvent::Finished {
                stop: StopReason::ToolCalls
            }),
            "{wire:?} did not stop for tools: {events:?}"
        );

        // The name is known before the arguments are, on every wire, so the
        // interface has something true to say while they arrive.
        let announced = events.iter().position(
            |event| matches!(event, StreamEvent::ToolCallStarted { name, .. } if name == "browser__read_page"),
        );
        let delivered = events
            .iter()
            .position(|event| matches!(event, StreamEvent::ToolCall { .. }));
        assert!(announced <= delivered, "{wire:?}: {events:?}");
    }
}

/// Arguments that stop mid-object are a failure, not a call.
///
/// The stream ends after half a JSON object. Passing that on would reach an MCP
/// server as a call whose arguments parse to something *nearly* right, which is
/// the worst possible outcome — it would run.
#[test]
fn a_tool_call_whose_arguments_were_cut_off_is_a_failure_not_a_call() {
    let body = concat!(
        "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"model\":\"c\"}}\n\n",
        "event: content_block_start\n",
        r#"data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"browser__read_page","input":{}}}"#,
        "\n\n",
        "event: content_block_delta\n",
        r#"data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"url\": \"htt"}}"#,
        "\n\n",
        "event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n",
    );

    let events = decode_byte_by_byte(WireFormat::AnthropicMessages, &[tool()], body);
    assert!(
        calls_of(&events).is_empty(),
        "a half call escaped: {events:?}"
    );
    assert_eq!(
        failure_of(&events).map(|error| error.kind),
        Some(ProviderErrorKind::MalformedResponse)
    );
}

/// A tool nobody offered comes back with no server, which is the core's own
/// signal to refuse it. Refusing beats guessing, and it beats dropping the call
/// silently — a model asking for something that does not exist is worth seeing.
#[test]
fn a_call_naming_a_tool_that_was_not_offered_keeps_an_empty_server() {
    let body = concat!(
        r#"data: {"model":"gpt-4o","choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"rm_rf","arguments":"{}"}}]}}]}"#,
        "\n\n",
        r#"data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#,
        "\n\ndata: [DONE]\n\n",
    );
    let calls = calls_of(&decode_whole(WireFormat::OpenAiChat, &[tool()], body));
    assert_eq!(calls.len(), 1);
    assert!(calls[0].server.is_empty(), "{calls:?}");
    assert_eq!(calls[0].tool, "rm_rf");
}

/// Two tools that flatten to the same name would let a model ask for one and
/// get the other. They are pulled apart instead, and the round trip still lands
/// on the right pair.
#[test]
fn two_tools_that_would_share_a_name_are_kept_apart() {
    let tools = vec![
        ToolSpec {
            server: "a.b".into(),
            tool: "run".into(),
            summary: String::new(),
            input_schema_json: String::new(),
        },
        ToolSpec {
            server: "a/b".into(),
            tool: "run".into(),
            summary: String::new(),
            input_schema_json: String::new(),
        },
    ];

    let names = wire_names(&tools);
    assert_ne!(
        names[0], names[1],
        "two tools answer to one name: {names:?}"
    );

    for (index, name) in names.iter().enumerate() {
        let body = format!(
            concat!(
                r#"data: {{"model":"m","choices":[{{"delta":{{"tool_calls":[{{"index":0,"id":"c","function":{{"name":"{}","arguments":"{{}}"}}}}]}}}}]}}"#,
                "\n\n",
                r#"data: {{"choices":[{{"delta":{{}},"finish_reason":"tool_calls"}}]}}"#,
                "\n\ndata: [DONE]\n\n",
            ),
            name
        );
        let calls = calls_of(&decode_whole(WireFormat::OpenAiChat, &tools, &body));
        assert_eq!(
            calls[0].server, tools[index].server,
            "{name} resolved wrong"
        );
    }
}

// --- what goes out ---------------------------------------------------------

/// The one field every wire spells differently, checked where it is written.
/// A schema under the wrong key is a tool the model is never told about.
#[test]
fn a_tool_schema_lands_under_each_wires_own_key() {
    let transcript = [said(MessageRole::User, "hello")];
    let tools = [tool()];

    let built = request(&anthropic(), Some("k"), "m", None, &transcript, &tools).unwrap();
    assert!(body_of(&built)["tools"][0]["input_schema"].is_object());

    let built = request(&openai(), Some("k"), "m", None, &transcript, &tools).unwrap();
    assert!(body_of(&built)["tools"][0]["function"]["parameters"].is_object());

    let built = request(&gemini(), Some("k"), "m", None, &transcript, &tools).unwrap();
    assert!(body_of(&built)["tools"][0]["functionDeclarations"][0]["parameters"].is_object());

    let built = request(&ollama(), None, "m", None, &transcript, &tools).unwrap();
    assert!(body_of(&built)["tools"][0]["function"]["parameters"].is_object());
}

/// A schema this wire will not accept is narrowed rather than sent and refused.
/// The keywords it does understand survive; the ones it does not are dropped,
/// including from inside a nested property.
#[test]
fn gemini_keeps_the_schema_it_understands_and_drops_the_rest() {
    let tools = [ToolSpec {
        server: "s".into(),
        tool: "t".into(),
        summary: String::new(),
        input_schema_json: r#"{
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "url": {"type": "string", "description": "where", "pattern": "^https"},
                "mode": {"type": "string", "enum": ["fast", "slow"]}
            },
            "required": ["url"],
            "oneOf": [{"required": ["url"]}]
        }"#
        .into(),
    }];

    let built = request(
        &gemini(),
        Some("k"),
        "m",
        None,
        &[said(MessageRole::User, "hi")],
        &tools,
    )
    .unwrap();
    let schema = &body_of(&built)["tools"][0]["functionDeclarations"][0]["parameters"];

    assert_eq!(schema["type"], "object");
    assert_eq!(schema["required"][0], "url");
    assert_eq!(schema["properties"]["url"]["description"], "where");
    assert_eq!(schema["properties"]["mode"]["enum"][1], "slow");
    assert!(schema.get("$schema").is_none());
    assert!(schema.get("additionalProperties").is_none());
    assert!(schema.get("oneOf").is_none());
    assert!(schema["properties"]["url"].get("pattern").is_none());
}

/// A tool round trip: the model asked, the tool answered, and the answer has to
/// go back where each wire expects it. Four wires, four completely different
/// shapes, and one transcript in the core.
#[test]
fn a_tool_result_travels_back_in_each_wires_own_shape() {
    let mut asked = said(MessageRole::Assistant, "");
    asked.tool_calls = vec![ToolCall {
        invocation: ToolInvocation {
            id: ToolCallId("toolu_9".into()),
            server: "browser".into(),
            tool: "read_page".into(),
            arguments: r#"{"url":"https://a.example"}"#.into(),
        },
        state: ToolCallState::Completed,
        result: "a page".into(),
        requested_at_ms: 0,
    }];
    let transcript = [said(MessageRole::User, "what is on it?"), asked];

    let built = request(&anthropic(), Some("k"), "m", None, &transcript, &[tool()]).unwrap();
    let body = body_of(&built);
    let result = &body["messages"][2]["content"][0];
    assert_eq!(body["messages"][2]["role"], "user");
    assert_eq!(result["type"], "tool_result");
    assert_eq!(result["tool_use_id"], "toolu_9");
    assert_eq!(result["content"], "a page");
    assert_eq!(result["is_error"], false);

    let built = request(&openai(), Some("k"), "m", None, &transcript, &[tool()]).unwrap();
    let body = body_of(&built);
    assert_eq!(body["messages"][3]["role"], "tool");
    assert_eq!(body["messages"][3]["tool_call_id"], "toolu_9");
    assert_eq!(body["messages"][3]["content"], "a page");

    // No id on this wire at all: the name is the correlation, which is why
    // `Content::ToolResult` carries one.
    let built = request(&gemini(), Some("k"), "m", None, &transcript, &[tool()]).unwrap();
    let body = body_of(&built);
    let response = &body["contents"][2]["parts"][0]["functionResponse"];
    assert_eq!(body["contents"][2]["role"], "user");
    assert_eq!(response["name"], "browser__read_page");
    assert_eq!(response["response"]["output"], "a page");

    let built = request(&ollama(), None, "m", None, &transcript, &[tool()]).unwrap();
    let body = body_of(&built);
    assert_eq!(body["messages"][3]["role"], "tool");
    assert_eq!(body["messages"][3]["tool_name"], "browser__read_page");
}

/// A tool that failed is sent as a failure where a wire has a flag for it, and
/// says so in words where it does not. A model told "error" in a field retries
/// differently from one that reads the word in a successful result.
#[test]
fn a_tool_that_failed_is_not_sent_as_a_result() {
    let mut asked = said(MessageRole::Assistant, "");
    asked.tool_calls = vec![ToolCall {
        invocation: ToolInvocation {
            id: ToolCallId("t1".into()),
            server: "browser".into(),
            tool: "read_page".into(),
            arguments: "{}".into(),
        },
        state: ToolCallState::Failed,
        result: "no such page".into(),
        requested_at_ms: 0,
    }];
    let transcript = [asked];

    let body = body_of(&request(&anthropic(), Some("k"), "m", None, &transcript, &[]).unwrap());
    assert_eq!(body["messages"][1]["content"][0]["is_error"], true);

    let body = body_of(&request(&gemini(), Some("k"), "m", None, &transcript, &[]).unwrap());
    assert!(
        body["contents"][1]["parts"][0]["functionResponse"]["response"]["error"].is_string(),
        "a failure went out under `output`"
    );

    // Index 2: the system prompt, then the turn that asked, then the answer.
    let body = body_of(&request(&ollama(), None, "m", None, &transcript, &[]).unwrap());
    assert!(
        body["messages"][2]["content"]
            .as_str()
            .unwrap()
            .starts_with("error:"),
        "a failure read as a successful result"
    );
}

/// The system prompt is hoisted out of the transcript by two of these wires and
/// put back as a message by the other two. Exactly once, in exactly one place.
#[test]
fn the_system_prompt_lands_once_wherever_each_wire_keeps_it() {
    let transcript = [said(MessageRole::User, "hello")];

    let body = body_of(
        &request(
            &anthropic(),
            Some("k"),
            "m",
            Some("be brief"),
            &transcript,
            &[],
        )
        .unwrap(),
    );
    assert_eq!(body["system"], "be brief");
    assert_eq!(body["messages"].as_array().unwrap().len(), 1);

    let body = body_of(
        &request(
            &gemini(),
            Some("k"),
            "m",
            Some("be brief"),
            &transcript,
            &[],
        )
        .unwrap(),
    );
    assert_eq!(body["systemInstruction"]["parts"][0]["text"], "be brief");
    assert_eq!(body["contents"].as_array().unwrap().len(), 1);

    let body = body_of(
        &request(
            &openai(),
            Some("k"),
            "m",
            Some("be brief"),
            &transcript,
            &[],
        )
        .unwrap(),
    );
    assert_eq!(body["messages"][0]["role"], "system");
    assert_eq!(body["messages"][0]["content"], "be brief");

    let body = body_of(&request(&ollama(), None, "m", Some("be brief"), &transcript, &[]).unwrap());
    assert_eq!(body["messages"][0]["role"], "system");
}

/// A page the browser attached goes to the model with its address, so an answer
/// can cite the page rather than assert it (ADR-0018). A page that could not be
/// read says so rather than arriving as an empty message.
#[test]
fn an_attached_page_travels_with_its_address() {
    let mut attached = said(MessageRole::PageContext, "The capital is Edinburgh.");
    attached.page = Some(PageReference {
        url: "https://a.example/scotland".into(),
        title: "Scotland".into(),
    });
    let body =
        body_of(&request(&openai(), Some("k"), "m", None, &[attached.clone()], &[]).unwrap());
    let sent = body["messages"][1]["content"].as_str().unwrap();
    assert!(sent.contains("https://a.example/scotland"), "{sent}");
    assert!(sent.contains("The capital is Edinburgh."), "{sent}");

    let mut unread = attached;
    unread.text = String::new();
    let body = body_of(&request(&openai(), Some("k"), "m", None, &[unread], &[]).unwrap());
    let sent = body["messages"][1]["content"].as_str().unwrap();
    assert!(sent.contains("could not read"), "{sent}");
}

/// Only the loopback address, and only the one that cannot be pointed
/// somewhere else by a hosts file.
#[test]
fn the_local_provider_asks_for_no_key_and_talks_to_this_machine() {
    let local = ollama();
    assert!(!local.needs_token());
    assert!(local.base_url.starts_with("http://127.0.0.1"));

    let built = request(
        &local,
        None,
        "llama3.2",
        None,
        &[said(MessageRole::User, "hi")],
        &[],
    )
    .unwrap();
    assert!(
        built
            .headers
            .iter()
            .all(|header| header.name != "authorization"),
        "a local request carried a credential"
    );
}

/// A token is never written down anywhere it could be persisted. The endpoint
/// has no field for one, so it cannot be — and the request that uses it puts it
/// in a header and nowhere else.
#[test]
fn a_token_reaches_the_header_and_nothing_else() {
    let secret = "sk-do-not-log-me";

    for endpoint in every_wire() {
        let built = request(
            &endpoint,
            Some(secret),
            "m",
            None,
            &[said(MessageRole::User, secret)],
            &[],
        )
        .unwrap();

        assert!(
            !built.url.contains(secret),
            "{:?} put a key in the URL, where it lands in every log there is",
            endpoint.wire
        );

        let carried: Vec<&str> = built
            .headers
            .iter()
            .filter(|header| header.value.contains(secret))
            .map(|header| header.name.as_str())
            .collect();
        if endpoint.needs_token() {
            assert_eq!(carried.len(), 1, "{:?}: {carried:?}", endpoint.wire);
        } else {
            assert!(carried.is_empty(), "{:?}: {carried:?}", endpoint.wire);
        }
    }
}

/// The first-run mistake, caught before a socket is opened, naming the provider
/// whose setting is wrong.
#[test]
fn a_provider_with_no_key_fails_before_anything_is_sent() {
    for token in [None, Some(""), Some("   ")] {
        let error = request(
            &anthropic(),
            token,
            "m",
            None,
            &[said(MessageRole::User, "hi")],
            &[],
        )
        .expect_err("a request went out with no key");

        assert_eq!(error.kind, ProviderErrorKind::Unauthorized);
        assert!(error.is_configuration_fault());
        assert!(!error.is_transient(), "someone will be told to try again");
        assert!(error.message.contains("claude"), "{}", error.message);
    }
}

/// A schema that is not JSON names the tool it came from. A provider handed the
/// same thing answers "invalid request" and names nothing at all.
#[test]
fn a_tool_with_a_broken_schema_says_which_tool() {
    let broken = [ToolSpec {
        server: "s".into(),
        tool: "t".into(),
        summary: String::new(),
        input_schema_json: "{not json".into(),
    }];
    let error = request(
        &anthropic(),
        Some("k"),
        "m",
        None,
        &[said(MessageRole::User, "hi")],
        &broken,
    )
    .expect_err("a broken schema was sent");
    assert_eq!(error.kind, ProviderErrorKind::InvalidRequest);
    assert!(error.message.contains("schema"), "{}", error.message);
}

// --- cancellation ----------------------------------------------------------

/// Escape, halfway through. What arrived is kept, the ending is `Cancelled`
/// rather than a fault, and the decoder goes quiet — a provider whose bytes are
/// still in flight cannot append to a reply somebody stopped.
#[test]
fn cancelling_mid_stream_ends_it_once_and_keeps_what_arrived() {
    for endpoint in every_wire() {
        let body = reply_for(endpoint.wire);
        let half = body.len() / 2;

        let mut decoder = StreamDecoder::new(endpoint.wire, &[]);
        let before = decoder.push(&body.as_bytes()[..half]);
        assert!(!decoder.is_done(), "{:?} ended early", endpoint.wire);

        let stopped = decoder.cancel();
        assert_eq!(
            stopped,
            vec![StreamEvent::Failed { error: cancelled() }],
            "{:?}",
            endpoint.wire
        );
        assert!(decoder.is_done());

        // The rest of the response arrives anyway, because a socket does not
        // close the instant it is asked to.
        assert!(
            decoder.push(&body.as_bytes()[half..]).is_empty(),
            "{:?} kept writing after it was stopped",
            endpoint.wire
        );
        assert!(
            decoder.finish().is_empty(),
            "{:?} ended twice",
            endpoint.wire
        );
        assert!(
            decoder.cancel().is_empty(),
            "{:?} cancelled twice",
            endpoint.wire
        );

        // Whatever had already arrived is still an event that was delivered.
        assert!(
            before
                .iter()
                .any(|event| matches!(event, StreamEvent::Started { .. })),
            "{:?} lost what had arrived: {before:?}",
            endpoint.wire
        );
    }
}

/// Cancellation is not a fault, and the interface must not offer to fix it.
#[test]
fn cancelling_is_neither_transient_nor_a_setting_to_change() {
    let stopped = cancelled();
    assert_eq!(stopped.kind, ProviderErrorKind::Cancelled);
    assert!(!stopped.is_transient());
    assert!(!stopped.is_configuration_fault());
}

// --- a stream that stops making sense --------------------------------------

/// A reply that simply stops has no ending of its own, and without one the
/// thread spins for ever. Every wire produces exactly one ending.
#[test]
fn a_stream_that_is_cut_off_still_ends() {
    for endpoint in every_wire() {
        let body = reply_for(endpoint.wire);
        let truncated = &body[..body.len() * 2 / 3];

        let events = decode_byte_by_byte(endpoint.wire, &[], truncated);
        let endings = events
            .iter()
            .filter(|event| {
                matches!(
                    event,
                    StreamEvent::Finished { .. } | StreamEvent::Failed { .. }
                )
            })
            .count();
        assert_eq!(
            endings, 1,
            "{:?} ended {endings} times: {events:?}",
            endpoint.wire
        );
    }
}

/// A gateway's HTML error page, served with a 200. It is not a stream, it never
/// sends a newline worth the name, and it must not be held in memory for ever
/// or read as an empty reply.
#[test]
fn a_response_that_is_not_a_stream_at_all_is_reported_as_one_failure() {
    for endpoint in every_wire() {
        let html = format!("<html><body>{}</body></html>", "x".repeat(4 * 1024 * 1024));
        let mut decoder = StreamDecoder::new(endpoint.wire, &[]);
        let mut events = decoder.push(html.as_bytes());
        events.extend(decoder.finish());

        assert_eq!(
            failure_of(&events).map(|error| error.kind),
            Some(ProviderErrorKind::MalformedResponse),
            "{:?}: {events:?}",
            endpoint.wire
        );
        assert_eq!(events.len(), 1, "{:?}: {events:?}", endpoint.wire);
    }
}

/// A well-framed event holding something that is not JSON. One failure, no
/// text, and nothing after it.
#[test]
fn an_event_that_is_not_json_ends_the_stream() {
    for (wire, body) in [
        (WireFormat::AnthropicMessages, "event: x\ndata: {oops\n\n"),
        (WireFormat::OpenAiChat, "data: {oops\n\n"),
        (WireFormat::GeminiGenerateContent, "data: {oops\n\n"),
        (WireFormat::OllamaChat, "{oops\n"),
    ] {
        let events = decode_byte_by_byte(wire, &[], body);
        assert_eq!(
            events,
            vec![StreamEvent::Failed {
                error: ProviderError::new(
                    ProviderErrorKind::MalformedResponse,
                    // Every wire named, so a fifth one has to say here what its
                    // framing calls the thing it failed to read, rather than
                    // inheriting a sentence about chunks that may not be true
                    // of it.
                    match wire {
                        WireFormat::AnthropicMessages => "an event that was not JSON",
                        WireFormat::OllamaChat => "a line that was not JSON",
                        WireFormat::OpenAiChat | WireFormat::GeminiGenerateContent => {
                            "a chunk that was not JSON"
                        }
                    }
                )
            }],
            "{wire:?}"
        );
    }
}

/// A 200 that turns into a failure part way through. The status code already
/// said everything was fine, which is why the shell cannot be the only thing
/// that reads errors.
#[test]
fn a_failure_after_a_200_is_still_a_failure() {
    let cases = [
        (
            WireFormat::AnthropicMessages,
            concat!(
                "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"model\":\"c\"}}\n\n",
                "event: error\n",
                r#"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#,
                "\n\n",
            ),
            ProviderErrorKind::Overloaded,
        ),
        (
            WireFormat::OpenAiChat,
            concat!(
                r#"data: {"model":"gpt-4o","choices":[{"delta":{"content":"hi"}}]}"#,
                "\n\n",
                r#"data: {"error":{"message":"Rate limit reached","type":"rate_limit_error","code":"rate_limit_exceeded"}}"#,
                "\n\n",
            ),
            ProviderErrorKind::RateLimited,
        ),
        (
            WireFormat::GeminiGenerateContent,
            concat!(
                r#"data: {"error":{"code":429,"message":"Quota exceeded","status":"RESOURCE_EXHAUSTED"}}"#,
                "\n\n",
            ),
            ProviderErrorKind::RateLimited,
        ),
        (
            WireFormat::OllamaChat,
            "{\"error\":\"model 'llama9' not found, try pulling it first\"}\n",
            ProviderErrorKind::ModelNotFound,
        ),
    ];

    for (wire, body, expected) in cases {
        let events = decode_byte_by_byte(wire, &[], body);
        assert_eq!(
            failure_of(&events).map(|error| error.kind),
            Some(expected),
            "{wire:?}: {events:?}"
        );
    }
}

/// The prompt was refused before anything was generated, and the status was
/// 200. Drawn as a finished reply this is an empty bubble presented as an
/// answer, which is exactly what ADR-0018 forbids.
#[test]
fn a_refusal_served_as_a_200_is_not_an_empty_reply() {
    let body = concat!(
        r#"data: {"promptFeedback":{"blockReason":"PROHIBITED_CONTENT"},"modelVersion":"gemini-2.5-flash"}"#,
        "\n\n",
    );
    let events = decode_whole(WireFormat::GeminiGenerateContent, &[], body);
    assert_eq!(
        failure_of(&events).map(|error| error.kind),
        Some(ProviderErrorKind::ContentFiltered),
        "{events:?}"
    );
    assert!(text_of(&events).is_empty());
}

// --- error mapping ---------------------------------------------------------

/// Every failure a provider states, in that provider's own words, and the
/// category it has to become.
///
/// This is the table the whole error story rests on: the wording is the shell's
/// but the category is not, and a category that is wrong sends somebody to fix
/// the wrong thing. The 401 rows are the ones that matter most — a mistyped key
/// is the first failure anybody hits.
#[test]
fn every_failure_a_provider_states_becomes_something_to_act_on() {
    use ProviderErrorKind::*;

    let cases: &[(WireFormat, u16, &str, ProviderErrorKind)] = &[
        // Anthropic states the category in `error.type`.
        (
            WireFormat::AnthropicMessages,
            401,
            r#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#,
            Unauthorized,
        ),
        (
            WireFormat::AnthropicMessages,
            403,
            r#"{"type":"error","error":{"type":"permission_error","message":"no"}}"#,
            Forbidden,
        ),
        (
            WireFormat::AnthropicMessages,
            404,
            r#"{"type":"error","error":{"type":"not_found_error","message":"model"}}"#,
            ModelNotFound,
        ),
        (
            WireFormat::AnthropicMessages,
            429,
            r#"{"type":"error","error":{"type":"rate_limit_error","message":"slow"}}"#,
            RateLimited,
        ),
        // A 400 whose body is strictly more truthful than its status code.
        (
            WireFormat::AnthropicMessages,
            400,
            r#"{"type":"error","error":{"type":"billing_error","message":"credit low"}}"#,
            QuotaExhausted,
        ),
        (
            WireFormat::AnthropicMessages,
            413,
            r#"{"type":"error","error":{"type":"request_too_large","message":"big"}}"#,
            ContextTooLong,
        ),
        (
            WireFormat::AnthropicMessages,
            529,
            r#"{"type":"error","error":{"type":"overloaded_error","message":"busy"}}"#,
            Overloaded,
        ),
        (
            WireFormat::AnthropicMessages,
            500,
            r#"{"type":"error","error":{"type":"api_error","message":"oops"}}"#,
            ServerError,
        ),
        // OpenAI's 401 says `invalid_request_error` in `type`. Believing that
        // field would send somebody with a mistyped key looking at their prompt.
        (
            WireFormat::OpenAiChat,
            401,
            r#"{"error":{"message":"Incorrect API key provided","type":"invalid_request_error","param":null,"code":"invalid_api_key"}}"#,
            Unauthorized,
        ),
        (
            WireFormat::OpenAiChat,
            429,
            r#"{"error":{"message":"Rate limit","type":"rate_limit_error","code":"rate_limit_exceeded"}}"#,
            RateLimited,
        ),
        // A 429 that backing off never fixes. Told apart from the row above by
        // its code alone.
        (
            WireFormat::OpenAiChat,
            429,
            r#"{"error":{"message":"You exceeded your quota","type":"insufficient_quota","code":"insufficient_quota"}}"#,
            QuotaExhausted,
        ),
        (
            WireFormat::OpenAiChat,
            429,
            r#"{"error":{"message":"Credit balance","type":"invalid_request_error","code":"credit_balance_exhausted"}}"#,
            QuotaExhausted,
        ),
        (
            WireFormat::OpenAiChat,
            429,
            r#"{"error":{"message":"Spend limit","type":"invalid_request_error","code":"organization_spend_limit_exceeded"}}"#,
            QuotaExhausted,
        ),
        (
            WireFormat::OpenAiChat,
            400,
            r#"{"error":{"message":"too long","type":"invalid_request_error","code":"context_length_exceeded"}}"#,
            ContextTooLong,
        ),
        (
            WireFormat::OpenAiChat,
            403,
            r#"{"error":{"message":"no access","type":"invalid_request_error","code":"model_not_found"}}"#,
            ModelNotFound,
        ),
        (
            WireFormat::OpenAiChat,
            500,
            r#"{"error":{"message":"oops","type":"server_error","code":"server_error"}}"#,
            ServerError,
        ),
        // A gateway that answered with no JSON at all. The status is all there
        // is, and it still has to become something.
        (
            WireFormat::OpenAiChat,
            502,
            "<html>502 Bad Gateway</html>",
            ServerError,
        ),
        (WireFormat::OpenAiChat, 503, "", Overloaded),
        // Gemini's long-standing envelope, `status` beside a numeric `code`.
        (
            WireFormat::GeminiGenerateContent,
            401,
            r#"{"error":{"code":401,"message":"key","status":"UNAUTHENTICATED"}}"#,
            Unauthorized,
        ),
        (
            WireFormat::GeminiGenerateContent,
            403,
            r#"{"error":{"code":403,"message":"no","status":"PERMISSION_DENIED"}}"#,
            Forbidden,
        ),
        (
            WireFormat::GeminiGenerateContent,
            429,
            r#"{"error":{"code":429,"message":"quota","status":"RESOURCE_EXHAUSTED"}}"#,
            RateLimited,
        ),
        (
            WireFormat::GeminiGenerateContent,
            400,
            r#"{"error":{"code":400,"message":"bad","status":"INVALID_ARGUMENT"}}"#,
            InvalidRequest,
        ),
        (
            WireFormat::GeminiGenerateContent,
            503,
            r#"{"error":{"code":503,"message":"busy","status":"UNAVAILABLE"}}"#,
            Overloaded,
        ),
        // The newer envelope, where `code` is a string and `status` is gone.
        // A parser that typed `code` as a number reads this as nothing at all.
        (
            WireFormat::GeminiGenerateContent,
            401,
            r#"{"error":{"code":"authentication","message":"key"}}"#,
            Unauthorized,
        ),
        (
            WireFormat::GeminiGenerateContent,
            429,
            r#"{"error":{"code":"quota_exceeded","message":"out"}}"#,
            QuotaExhausted,
        ),
        (
            WireFormat::GeminiGenerateContent,
            404,
            r#"{"error":{"code":"model_not_found","message":"gone"}}"#,
            ModelNotFound,
        ),
        // One string, no type, no code. The status carries the category and the
        // message narrows it — the reverse of everywhere else.
        (
            WireFormat::OllamaChat,
            404,
            r#"{"error":"model 'llama9' not found, try pulling it first"}"#,
            ModelNotFound,
        ),
        (
            WireFormat::OllamaChat,
            400,
            r#"{"error":"\"llama3.2\" does not support tools"}"#,
            ModelNotFound,
        ),
        (
            WireFormat::OllamaChat,
            500,
            r#"{"error":"something broke"}"#,
            ServerError,
        ),
    ];

    for (wire, status, body, expected) in cases {
        let error = decode_error(*wire, *status, body, None);
        assert_eq!(
            error.kind, *expected,
            "{wire:?} {status} {body} became {:?}",
            error.kind
        );
        assert!(
            !error.message.is_empty(),
            "{wire:?} {status}: no detail kept"
        );
    }
}

/// Waiting fixes one of these and never fixes the other, and both arrive as a
/// 429. Getting it wrong is a browser that retries a spend cap until somebody
/// gives up on it.
#[test]
fn a_rate_limit_is_worth_retrying_and_an_empty_wallet_is_not() {
    let limited = decode_error(
        WireFormat::OpenAiChat,
        429,
        r#"{"error":{"message":"slow down","code":"rate_limit_exceeded"}}"#,
        Some("30"),
    );
    assert!(limited.is_transient());
    assert!(!limited.is_configuration_fault());
    assert_eq!(limited.retry_after_ms, Some(30_000));

    let broke = decode_error(
        WireFormat::OpenAiChat,
        429,
        r#"{"error":{"message":"no credit","code":"insufficient_quota"}}"#,
        Some("30"),
    );
    assert!(
        !broke.is_transient(),
        "somebody would be told to wait it out"
    );
    assert!(broke.is_configuration_fault());
}

/// The header is advice, and advice from a provider is not to be followed off a
/// cliff. A date, a negative number and an hour are all read as "no advice".
#[test]
fn retry_advice_is_read_but_not_obeyed_blindly() {
    let for_header = |header: Option<&str>| {
        decode_error(
            WireFormat::OpenAiChat,
            429,
            r#"{"error":{"code":"rate_limit_exceeded","message":"x"}}"#,
            header,
        )
        .retry_after_ms
    };

    assert_eq!(for_header(Some("2")), Some(2_000));
    assert_eq!(for_header(Some("0.5")), Some(500));
    assert_eq!(for_header(Some("99999")), Some(300_000));
    assert_eq!(for_header(Some("Wed, 21 Oct 2026 07:28:00 GMT")), None);
    assert_eq!(for_header(Some("-5")), None);
    assert_eq!(for_header(None), None);
}

/// Nothing answered. A local model server that is not running and a laptop with
/// the wifi off are one category, because they are one sentence.
#[test]
fn nothing_answering_is_one_category() {
    let down = unreachable("Could not connect to the server");
    assert_eq!(down.kind, ProviderErrorKind::Unreachable);
    assert!(down.is_transient());
    assert!(!down.is_configuration_fault());
}

/// Every category is one of the two, or deliberately neither. A category that
/// is both would offer "Try again" and "Open Settings" at once, which tells
/// somebody the browser does not know what went wrong.
#[test]
fn no_failure_is_both_worth_retrying_and_a_setting_to_change() {
    use ProviderErrorKind::*;
    for kind in [
        Unauthorized,
        Forbidden,
        RateLimited,
        QuotaExhausted,
        ModelNotFound,
        ContextTooLong,
        ContentFiltered,
        InvalidRequest,
        Overloaded,
        ServerError,
        Unreachable,
        MalformedResponse,
        Cancelled,
    ] {
        let error = ProviderError::new(kind, "x");
        assert!(
            !(error.is_transient() && error.is_configuration_fault()),
            "{kind:?} is both"
        );
    }
}

/// The core has its own vocabulary and every one of ours has to land in it.
/// A refusal is the one that is not a finished turn.
#[test]
fn every_stop_becomes_a_turn_that_ended_or_a_failure() {
    assert_eq!(reply_outcome(StopReason::EndTurn), Ok(ReplyStop::EndOfTurn));
    assert_eq!(
        reply_outcome(StopReason::ToolCalls),
        Ok(ReplyStop::ToolCalls)
    );
    assert_eq!(
        reply_outcome(StopReason::MaxOutputTokens),
        Ok(ReplyStop::MaxTokens)
    );
    assert_eq!(
        reply_outcome(StopReason::Filtered),
        Err(ChatErrorKind::ProviderRefused)
    );
}

/// A reply the provider cut short must not read as a whole one.
#[test]
fn a_reply_that_ran_out_of_room_says_so() {
    let cases = [
        (
            WireFormat::AnthropicMessages,
            concat!(
                "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"model\":\"c\"}}\n\n",
                "event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"max_tokens\"}}\n\n",
                "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n",
            ),
        ),
        (
            WireFormat::OpenAiChat,
            "data: {\"model\":\"m\",\"choices\":[{\"delta\":{},\"finish_reason\":\"length\"}]}\n\ndata: [DONE]\n\n",
        ),
        (
            WireFormat::GeminiGenerateContent,
            "data: {\"modelVersion\":\"g\",\"candidates\":[{\"finishReason\":\"MAX_TOKENS\"}]}\n\n",
        ),
        (
            WireFormat::OllamaChat,
            "{\"model\":\"m\",\"done\":true,\"done_reason\":\"length\"}\n",
        ),
    ];

    for (wire, body) in cases {
        let events = decode_byte_by_byte(wire, &[], body);
        assert!(
            events.contains(&StreamEvent::Finished {
                stop: StopReason::MaxOutputTokens
            }),
            "{wire:?}: {events:?}"
        );
    }
}

/// The sentinel is the last thing sent, after the chunk that already said why
/// the reply stopped, and connections die in that gap. A reply that reached its
/// `finish_reason` is a finished reply.
#[test]
fn an_openai_stream_that_loses_its_sentinel_is_still_finished() {
    let body = concat!(
        r#"data: {"model":"gpt-4o","choices":[{"delta":{"content":"hi"},"finish_reason":null}]}"#,
        "\n\n",
        r#"data: {"choices":[{"delta":{},"finish_reason":"stop"}]}"#,
        "\n\n",
    );
    let events = decode_byte_by_byte(WireFormat::OpenAiChat, &[], body);
    assert_eq!(text_of(&events), "hi");
    assert!(
        events.contains(&StreamEvent::Finished {
            stop: StopReason::EndTurn
        }),
        "{events:?}"
    );
}

// --- listing what exists ---------------------------------------------------

/// Every wire here can be asked what it has, which is what lets Settings offer
/// a list instead of a text field somebody has to type a model id into.
#[test]
fn every_provider_can_be_asked_what_models_it_has() {
    for endpoint in every_wire() {
        let token = endpoint.needs_token().then_some("k");
        let built = models_request(&endpoint, token).expect("a listing request");
        assert_eq!(built.method, "GET");
        assert!(built.body.is_empty());
        assert!(
            built.url.starts_with(&endpoint.base_url),
            "{:?} asked somewhere else: {}",
            endpoint.wire,
            built.url
        );
    }
}

/// What each listing actually offers, which is not the same everywhere: two
/// state a readable name and a window, one states a size, and one states an id
/// and nothing else. Settings has to be able to tell.
#[test]
fn a_model_list_is_read_for_whatever_the_provider_offers() {
    let listed = decode_models(
        WireFormat::AnthropicMessages,
        r#"{"data":[{"type":"model","id":"claude-sonnet-4-5","display_name":"Claude Sonnet 4.5","max_input_tokens":200000}]}"#,
    )
    .unwrap();
    assert_eq!(listed[0].id, "claude-sonnet-4-5");
    assert_eq!(listed[0].display_name.as_deref(), Some("Claude Sonnet 4.5"));
    assert_eq!(listed[0].context_tokens, Some(200_000));

    let listed = decode_models(
        WireFormat::OpenAiChat,
        r#"{"object":"list","data":[{"id":"gpt-4o-mini","object":"model","created":1,"owned_by":"openai"}]}"#,
    )
    .unwrap();
    assert_eq!(listed[0].id, "gpt-4o-mini");
    assert_eq!(listed[0].display_name, None);

    // The resource path is not the id that goes in a request, and a model that
    // cannot be chatted with is not offered as one.
    let listed = decode_models(
        WireFormat::GeminiGenerateContent,
        r#"{"models":[
            {"name":"models/gemini-2.5-flash","displayName":"Gemini 2.5 Flash","inputTokenLimit":1048576,"supportedGenerationMethods":["generateContent"]},
            {"name":"models/text-embedding-004","displayName":"Embedding","inputTokenLimit":2048,"supportedGenerationMethods":["embedContent"]}
        ]}"#,
    )
    .unwrap();
    assert_eq!(
        listed.len(),
        1,
        "an embedding model was offered as a chat model"
    );
    assert_eq!(listed[0].id, "gemini-2.5-flash");
    assert_eq!(listed[0].context_tokens, Some(1_048_576));

    // Locally the size is what decides, so it is what gets shown.
    let listed = decode_models(
        WireFormat::OllamaChat,
        r#"{"models":[{"name":"llama3.2:latest","model":"llama3.2:latest","details":{"parameter_size":"3.2B"}}]}"#,
    )
    .unwrap();
    assert_eq!(listed[0].id, "llama3.2:latest");
    assert!(listed[0].display_name.as_deref().unwrap().contains("3.2B"));
}

/// A listing that is not a listing is a failure with a category, not a panic
/// and not an empty dropdown that looks like "no models exist".
#[test]
fn a_model_list_that_is_not_one_is_a_failure() {
    for wire in [
        WireFormat::AnthropicMessages,
        WireFormat::OpenAiChat,
        WireFormat::GeminiGenerateContent,
        WireFormat::OllamaChat,
    ] {
        for body in ["<html>nope</html>", "{}", ""] {
            let error = decode_models(wire, body).expect_err("{wire:?} accepted {body}");
            assert_eq!(error.kind, ProviderErrorKind::MalformedResponse, "{wire:?}");
        }
    }
}

// --- configuration ---------------------------------------------------------

/// A vendor on a wire we already speak is a line of config and no code. That is
/// the claim the whole design rests on, so it is the claim with a test.
#[test]
fn a_new_vendor_on_a_wire_we_speak_is_config_and_nothing_else() {
    for name in [
        "openai",
        "groq",
        "together",
        "openrouter",
        "deepseek",
        "mistral",
        "lmstudio",
        "vllm",
    ] {
        assert_eq!(
            WireFormat::parse(name),
            Some(WireFormat::OpenAiChat),
            "{name} would need a module"
        );
    }
    assert_eq!(
        WireFormat::parse("claude"),
        Some(WireFormat::AnthropicMessages)
    );
    assert_eq!(
        WireFormat::parse("  Gemini "),
        Some(WireFormat::GeminiGenerateContent)
    );
    assert_eq!(WireFormat::parse("ollama"), Some(WireFormat::OllamaChat));
    // Unrecognised rather than guessed, so config can point at the line.
    assert_eq!(WireFormat::parse("wat"), None);

    // A hosted service on a borrowed wire needs only its own address.
    let groq = ProviderEndpoint {
        base_url: "https://api.groq.com/openai".into(),
        ..ProviderEndpoint::preset(WireFormat::parse("groq").unwrap(), "groq")
    };
    let built = request(
        &groq,
        Some("k"),
        "llama-3.3-70b",
        None,
        &[said(MessageRole::User, "hi")],
        &[],
    )
    .unwrap();
    assert_eq!(built.url, "https://api.groq.com/openai/v1/chat/completions");
}

/// A base URL with a trailing slash is what somebody types, and two slashes in
/// a path is a 404 that reads like an outage.
#[test]
fn a_trailing_slash_in_config_does_not_become_a_broken_url() {
    let endpoint = ProviderEndpoint {
        base_url: "https://api.anthropic.com/".into(),
        ..anthropic()
    };
    let built = request(
        &endpoint,
        Some("k"),
        "m",
        None,
        &[said(MessageRole::User, "hi")],
        &[],
    )
    .unwrap();
    assert_eq!(built.url, "https://api.anthropic.com/v1/messages");
}

/// The parameter that decides whether this wire speaks SSE at all. Without it
/// the response is a JSON array in chunks and nothing here can read it.
#[test]
fn gemini_asks_for_the_stream_it_can_actually_parse() {
    let built = request(
        &gemini(),
        Some("k"),
        "gemini-2.5-flash",
        None,
        &[said(MessageRole::User, "hi")],
        &[],
    )
    .unwrap();
    assert!(
        built.url.ends_with(":streamGenerateContent?alt=sse"),
        "{}",
        built.url
    );
    assert!(
        built.url.contains("/models/gemini-2.5-flash"),
        "{}",
        built.url
    );
}

/// Every wire is asked to stream, because a request that is not is a reply that
/// arrives all at once after twenty seconds of nothing.
#[test]
fn every_request_asks_for_a_stream() {
    for endpoint in every_wire() {
        let token = endpoint.needs_token().then_some("k");
        let built = request(
            &endpoint,
            token,
            "m",
            None,
            &[said(MessageRole::User, "hi")],
            &[],
        )
        .unwrap();
        assert_eq!(built.method, "POST");

        let streams = match endpoint.wire {
            // Stated in the path rather than the body.
            WireFormat::GeminiGenerateContent => built.url.contains("alt=sse"),
            WireFormat::AnthropicMessages | WireFormat::OpenAiChat | WireFormat::OllamaChat => {
                body_of(&built)["stream"] == serde_json::json!(true)
            }
        };
        assert!(streams, "{:?} did not ask to stream", endpoint.wire);

        assert!(
            built
                .headers
                .iter()
                .any(|header| header.name == "content-type" && header.value == "application/json"),
            "{:?} sent no content type",
            endpoint.wire
        );
    }
}

/// The field this wire requires and has no default for. Without it every
/// request is a 400 that names a parameter nobody set.
#[test]
fn anthropic_always_states_a_token_budget() {
    let built = request(
        &anthropic(),
        Some("k"),
        "m",
        None,
        &[said(MessageRole::User, "hi")],
        &[],
    )
    .unwrap();
    assert!(body_of(&built)["max_tokens"].as_u64().unwrap() > 0);
}

/// A reply still arriving is not something the model said, and sending it back
/// as though it were is the browser putting words in its mouth.
#[test]
fn a_transcript_leaves_out_what_has_not_been_said_yet() {
    let mut streaming = said(MessageRole::Assistant, "");
    streaming.state = MessageState::Streaming;

    let transcript = [said(MessageRole::User, "hi"), streaming];
    let body = body_of(&request(&openai(), Some("k"), "m", None, &transcript, &[]).unwrap());
    let messages = body["messages"].as_array().unwrap();

    // The system prompt and the question, and nothing else.
    assert_eq!(messages.len(), 2, "{messages:?}");
    assert_eq!(messages[1]["content"], "hi");
}
