//! What a badly behaved server can put on a pipe, and what happens next.

use super::*;

fn value(raw: &str) -> Value {
    serde_json::from_str(raw).expect("we produce valid JSON")
}

// --- what goes out -------------------------------------------------------

#[test]
fn every_message_is_one_line() {
    let messages = [
        discover_request(1, "0.1.0"),
        initialize_request(2, "0.1.0"),
        initialized_notification(),
        tools_list_request(3, ServerEra::Modern, Some("a\nb"), "0.1.0"),
        cancel_notification(4, "the person\nsaid stop"),
        tools_call_request(5, ServerEra::Modern, "t", r#"{"a":"x\ny"}"#, "0.1.0").unwrap(),
    ];

    for message in messages {
        assert!(
            !message.contains('\n'),
            "a newline inside a message would split it into two: {message}"
        );
    }
}

#[test]
fn a_modern_request_carries_its_version_and_asks_for_nothing() {
    let sent = value(&discover_request(1, "0.1.0"));

    assert_eq!(
        sent["params"]["_meta"]["io.modelcontextprotocol/protocolVersion"],
        PROTOCOL_VERSION
    );
    assert_eq!(
        sent["params"]["_meta"]["io.modelcontextprotocol/clientCapabilities"],
        json!({}),
        "no sampling, no elicitation, no roots: a browser gives a server no \
         way back in"
    );
    assert_eq!(
        sent["params"]["_meta"]["io.modelcontextprotocol/clientInfo"]["name"],
        CLIENT_NAME
    );
}

#[test]
fn a_legacy_handshake_declares_no_capabilities_either() {
    let sent = value(&initialize_request(1, "0.1.0"));

    assert_eq!(sent["params"]["protocolVersion"], LEGACY_PROTOCOL_VERSION);
    assert_eq!(sent["params"]["capabilities"], json!({}));
}

#[test]
fn a_legacy_request_carries_no_meta() {
    let sent = value(&tools_list_request(1, ServerEra::Legacy, None, "0.1.0"));
    assert!(sent["params"].get("_meta").is_none());

    let modern = value(&tools_list_request(1, ServerEra::Modern, None, "0.1.0"));
    assert!(modern["params"].get("_meta").is_some());
}

#[test]
fn arguments_that_are_not_an_object_never_reach_a_server() {
    for hostile in [
        "not json at all",
        "[1,2,3]",
        "\"just a string\"",
        "{\"unclosed\": ",
    ] {
        assert!(
            tools_call_request(1, ServerEra::Modern, "t", hostile, "0.1.0").is_none(),
            "{hostile}"
        );
    }

    assert!(
        tools_call_request(1, ServerEra::Modern, "t", "  ", "0.1.0").is_some(),
        "a tool that takes nothing is called with an empty object"
    );
}

// The header test that used to sit here went with `http_headers` to
// `mcp_http_tests.rs`, where it could also ask the question this one could not:
// what a *legacy* server is told. See
// `the_version_in_the_header_is_the_version_in_the_body`.

// --- era detection -------------------------------------------------------

#[test]
fn a_server_that_answers_discover_is_modern() {
    let reply = parse_reply(
        r#"{"jsonrpc":"2.0","id":1,"result":{"resultType":"complete",
            "supportedVersions":["2026-07-28"],
            "_meta":{"io.modelcontextprotocol/serverInfo":{"name":"w","version":"2"}}}}"#,
        Expect::Discover,
    );

    assert_eq!(
        reply,
        Reply::Discovered {
            server_name: "w".into(),
            server_version: "2".into(),
            supported_versions: vec!["2026-07-28".into()],
        }
    );
    assert_eq!(
        detect_era(&reply),
        EraProbe::Settled {
            era: ServerEra::Modern
        }
    );
}

#[test]
fn a_modern_server_refusing_our_version_is_not_a_reason_to_try_the_old_way() {
    let reply = parse_reply(
        r#"{"jsonrpc":"2.0","id":1,"error":{"code":-32022,
            "message":"Unsupported protocol version",
            "data":{"supported":["2027-01-01"],"requested":"2026-07-28"}}}"#,
        Expect::Discover,
    );

    assert_eq!(
        detect_era(&reply),
        EraProbe::Incompatible {
            supported: vec!["2027-01-01".into()]
        },
        "it is modern and it disagrees; sending `initialize` would be noise"
    );
}

#[test]
fn any_other_failure_falls_back_and_the_fallback_is_not_keyed_to_one_code() {
    // A legacy server has never heard of `server/discover` and will say so in
    // whatever way it likes — or say nothing at all.
    let shapes = [
        r#"{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"Method not found"}}"#,
        r#"{"jsonrpc":"2.0","id":1,"error":{"code":-32603,"message":"boom"}}"#,
        r#"{"jsonrpc":"2.0","id":1,"error":{"code":-1,"message":"?"}}"#,
        "Starting server on port 3000...",
        "",
    ];

    for shape in shapes {
        assert_eq!(
            detect_era(&parse_reply(shape, Expect::Discover)),
            EraProbe::FallBack,
            "{shape}"
        );
    }
}

#[test]
fn a_legacy_server_without_a_protocol_version_is_malformed_not_ready() {
    assert_eq!(
        parse_reply(
            r#"{"jsonrpc":"2.0","id":1,"result":{"serverInfo":{"name":"x"}}}"#,
            Expect::Initialize
        ),
        Reply::Malformed {
            detail: "The server answered without a protocol version.".into()
        }
    );
}

// --- rubbish on the pipe -------------------------------------------------

#[test]
fn junk_on_stdout_is_ignored_rather_than_fatal() {
    for junk in [
        "Listening on stdio",
        "{}",
        "{\"jsonrpc\":\"1.0\",\"id\":1,\"result\":{}}",
        "[]",
        "null",
        "\u{0}\u{1}",
    ] {
        assert_eq!(
            parse_reply(junk, Expect::ToolsList),
            Reply::Ignored,
            "{junk:?}"
        );
    }
}

#[test]
fn a_tool_list_with_no_tools_field_is_malformed() {
    assert!(matches!(
        parse_reply(
            r#"{"jsonrpc":"2.0","id":1,"result":{"resultType":"complete"}}"#,
            Expect::ToolsList
        ),
        Reply::Malformed { .. }
    ));
}

#[test]
fn a_tool_entry_that_is_not_a_tool_is_skipped_and_the_rest_survive() {
    let reply = parse_reply(
        r#"{"jsonrpc":"2.0","id":1,"result":{"tools":[
            {"description":"nameless"},
            "a bare string",
            {"name":"good","description":"fine","inputSchema":{"type":"object"}},
            {"name":42}
        ]}}"#,
        Expect::ToolsList,
    );

    let Reply::Tools { tools, .. } = reply else {
        panic!("expected a list");
    };
    assert_eq!(tools.len(), 1);
    assert_eq!(tools[0].name, "good");
}

#[test]
fn a_tool_with_no_schema_still_has_one() {
    let reply = parse_reply(
        r#"{"jsonrpc":"2.0","id":1,"result":{"tools":[{"name":"t"}]}}"#,
        Expect::ToolsList,
    );
    let Reply::Tools { tools, .. } = reply else {
        panic!()
    };
    assert_eq!(tools[0].input_schema_json, "{}");
    assert_eq!(tools[0].description, "");
    assert_eq!(tools[0].read_only_hint, None);
}

#[test]
fn an_empty_cursor_is_a_cursor_and_not_the_end() {
    let reply = parse_reply(
        r#"{"jsonrpc":"2.0","id":1,"result":{"tools":[],"nextCursor":""}}"#,
        Expect::ToolsList,
    );
    assert_eq!(
        reply,
        Reply::Tools {
            tools: vec![],
            next_cursor: String::new(),
            has_more: true,
        }
    );

    let ended = parse_reply(
        r#"{"jsonrpc":"2.0","id":1,"result":{"tools":[]}}"#,
        Expect::ToolsList,
    );
    assert!(matches!(
        ended,
        Reply::Tools {
            has_more: false,
            ..
        }
    ));
}

#[test]
fn annotations_are_read_but_only_as_the_servers_claims() {
    let reply = parse_reply(
        r#"{"jsonrpc":"2.0","id":1,"result":{"tools":[{"name":"t",
            "annotations":{"readOnlyHint":true,"destructiveHint":false,
                           "openWorldHint":false,"title":"Nice Tool"}}]}}"#,
        Expect::ToolsList,
    );
    let Reply::Tools { tools, .. } = reply else {
        panic!()
    };
    assert_eq!(tools[0].read_only_hint, Some(true));
    assert_eq!(tools[0].destructive_hint, Some(false));
    assert_eq!(tools[0].open_world_hint, Some(false));
}

#[test]
fn an_annotation_that_is_not_a_boolean_reads_as_absent() {
    // Absent means the pessimistic default, so a server gains nothing by
    // sending `"readOnlyHint": "yes"`.
    let reply = parse_reply(
        r#"{"jsonrpc":"2.0","id":1,"result":{"tools":[{"name":"t",
            "annotations":{"readOnlyHint":"yes","destructiveHint":0}}]}}"#,
        Expect::ToolsList,
    );
    let Reply::Tools { tools, .. } = reply else {
        panic!()
    };
    assert_eq!(tools[0].read_only_hint, None);
    assert_eq!(tools[0].destructive_hint, None);
}

// --- results -------------------------------------------------------------

#[test]
fn a_tool_reporting_its_own_failure_is_not_a_protocol_failure() {
    assert_eq!(
        parse_reply(
            r#"{"jsonrpc":"2.0","id":1,"result":{"isError":true,
                "content":[{"type":"text","text":"date must be in the future"}]}}"#,
            Expect::ToolsCall
        ),
        Reply::Called {
            is_error: true,
            text: "date must be in the future".into(),
        },
        "the model gets to see this and correct itself"
    );

    assert_eq!(
        parse_reply(
            r#"{"jsonrpc":"2.0","id":1,"error":{"code":-32602,"message":"Unknown tool"}}"#,
            Expect::ToolsCall
        ),
        Reply::Failed {
            code: -32602,
            message: "Unknown tool".into(),
        },
        "and this one is the call not happening at all"
    );
}

#[test]
fn a_block_that_is_not_text_is_named_rather_than_vanishing() {
    let reply = parse_reply(
        r#"{"jsonrpc":"2.0","id":1,"result":{"content":[
            {"type":"text","text":"here:"},
            {"type":"image","data":"AAAA","mimeType":"image/png"},
            {"type":"resource_link","uri":"file:///x"},
            {"type":"something_new"}
        ]}}"#,
        Expect::ToolsCall,
    );

    assert_eq!(
        reply,
        Reply::Called {
            is_error: false,
            text: "here:\n[an image]\n[a link to file:///x]\n[something_new]".into(),
        },
        "a silently dropped block is a tool that appears to have returned nothing"
    );
}

#[test]
fn a_result_with_only_structured_content_still_shows_something() {
    let reply = parse_reply(
        r#"{"jsonrpc":"2.0","id":1,"result":{"content":[],
            "structuredContent":{"temp":22}}}"#,
        Expect::ToolsCall,
    );
    assert_eq!(
        reply,
        Reply::Called {
            is_error: false,
            text: r#"{"temp":22}"#.into(),
        }
    );
}

#[test]
fn an_error_object_with_nothing_in_it_still_says_something() {
    assert_eq!(
        parse_reply(r#"{"jsonrpc":"2.0","id":1,"error":{}}"#, Expect::ToolsCall),
        Reply::Failed {
            code: 0,
            message: "The server did not say why.".into(),
        }
    );
}

#[test]
fn only_the_notification_we_care_about_is_heard() {
    assert_eq!(
        parse_notification(r#"{"jsonrpc":"2.0","method":"notifications/tools/list_changed"}"#),
        Reply::ToolsChanged
    );
    for other in [
        r#"{"jsonrpc":"2.0","method":"notifications/message","params":{"level":"info"}}"#,
        r#"{"jsonrpc":"2.0","method":"sampling/createMessage","id":9}"#,
        "not json",
    ] {
        assert_eq!(parse_notification(other), Reply::Ignored, "{other}");
    }
}

#[test]
fn an_id_can_be_read_without_reading_the_rest() {
    assert_eq!(reply_id(r#"{"jsonrpc":"2.0","id":7,"result":{}}"#), Some(7));
    assert_eq!(
        reply_id(r#"{"jsonrpc":"2.0","method":"notifications/x"}"#),
        None
    );
    assert_eq!(reply_id("garbage"), None);
    assert_eq!(
        reply_id(r#"{"jsonrpc":"2.0","id":"a-string","result":{}}"#),
        None,
        "we only ever send integer ids, so a string id answers nothing we sent"
    );
}
