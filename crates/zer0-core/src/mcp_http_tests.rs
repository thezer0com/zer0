//! What Streamable HTTP is allowed to reach, and what it makes of an answer.

use super::*;

fn allowed(raw: &str) -> (String, bool) {
    match endpoint_verdict(raw) {
        EndpointVerdict::Allowed { url, loopback } => (url, loopback),
        EndpointVerdict::Refused { reason } => panic!("{raw} was refused: {reason}"),
    }
}

fn refusal(raw: &str) -> String {
    match endpoint_verdict(raw) {
        EndpointVerdict::Refused { reason } => reason,
        EndpointVerdict::Allowed { url, .. } => panic!("{raw} was allowed as {url}"),
    }
}

// ---------------------------------------------------------------------------
// Which addresses may be spoken to
// ---------------------------------------------------------------------------

#[test]
fn plain_http_reaches_this_machine_and_nowhere_else() {
    // The case the transport was added for.
    for address in [
        "http://127.0.0.1:7332/mcp",
        "http://localhost:7332/mcp",
        "http://[::1]:7332/mcp",
        "http://127.0.0.2:9000/mcp",
        "http://proxy.localhost/mcp",
    ] {
        let (_, loopback) = allowed(address);
        assert!(loopback, "{address} should read as this machine");
    }

    // The same address off this machine, in every shape somebody might reach
    // for. Each of these hands a tool server the assistant's messages in clear
    // text and takes its answers back the same way.
    for address in [
        "http://example.com/mcp",
        "http://192.168.1.10:7332/mcp",
        "http://10.0.0.4/mcp",
        "http://[2001:db8::1]/mcp",
    ] {
        let reason = refusal(address);
        assert!(
            reason.contains("plain http"),
            "{address} should be refused for being plaintext, said: {reason}"
        );
    }
}

#[test]
fn an_address_that_only_looks_like_this_machine_is_not_this_machine() {
    // Substring matching on the text would let all four of these through, and
    // all four of them are somebody else's server.
    for address in [
        "http://127.0.0.1.evil.example/mcp",
        "http://127.0.0.1@evil.example/mcp",
        "http://localhost.evil.example/mcp",
        "http://evil.example/?host=127.0.0.1",
    ] {
        assert!(
            matches!(endpoint_verdict(address), EndpointVerdict::Refused { .. }),
            "{address} was allowed"
        );
    }
}

#[test]
fn https_is_reachable_anywhere_and_is_not_this_machine() {
    let (url, loopback) = allowed("https://tools.example.com/mcp");
    assert_eq!(url, "https://tools.example.com/mcp");
    assert!(!loopback);
}

#[test]
fn a_credential_in_the_address_is_refused_rather_than_used() {
    // ADR-0048: a secret only ever lives in the Keychain. An address with a
    // password in it is a password in `config.toml`.
    let reason = refusal("https://someone:t0ken@tools.example.com/mcp");
    assert!(reason.contains("Keychain"), "said: {reason}");
    assert!(reason.contains("credential"), "said: {reason}");

    assert!(matches!(
        endpoint_verdict("http://someone@127.0.0.1:7332/mcp"),
        EndpointVerdict::Refused { .. }
    ));
}

#[test]
fn only_http_and_https_are_transports_and_the_rest_are_refused() {
    for address in [
        "ws://127.0.0.1:7332/mcp",
        "file:///Users/someone/mcp",
        "javascript:alert(1)",
        "zer0://settings",
        "",
        "   ",
        "not an address",
    ] {
        assert!(
            matches!(endpoint_verdict(address), EndpointVerdict::Refused { .. }),
            "{address:?} was allowed"
        );
    }
}

#[test]
fn an_allowed_address_is_the_parsed_one_so_nothing_reads_the_file_string_again() {
    let (url, _) = allowed("  http://127.0.0.1:7332/mcp  ");
    assert_eq!(url, "http://127.0.0.1:7332/mcp");
}

// ---------------------------------------------------------------------------
// Headers
// ---------------------------------------------------------------------------

fn header<'a>(headers: &'a [(String, String)], name: &str) -> Option<&'a str> {
    headers
        .iter()
        .find(|(key, _)| key.eq_ignore_ascii_case(name))
        .map(|(_, value)| value.as_str())
}

#[test]
fn the_version_in_the_header_is_the_version_in_the_body() {
    // A `MCP-Protocol-Version` that disagrees with the body's `_meta` is a 400
    // with `HeaderMismatch`, so the two are written from the same line.
    let line = crate::mcp_wire::tools_list_request(1, ServerEra::Modern, None, "0.1.0");
    let headers = http_headers(Some(ServerEra::Modern), None, &line);
    assert_eq!(
        header(&headers, "MCP-Protocol-Version"),
        Some(PROTOCOL_VERSION)
    );
    assert!(line.contains(PROTOCOL_VERSION));

    // And a legacy server is told the version it actually agreed to, not the
    // one we would have preferred.
    let legacy = crate::mcp_wire::tools_list_request(1, ServerEra::Legacy, None, "0.1.0");
    let headers = http_headers(Some(ServerEra::Legacy), None, &legacy);
    assert_eq!(
        header(&headers, "MCP-Protocol-Version"),
        Some(LEGACY_PROTOCOL_VERSION)
    );
    assert!(!legacy.contains(PROTOCOL_VERSION));
}

#[test]
fn the_probe_goes_out_with_modern_headers_before_any_era_is_known() {
    let line = crate::mcp_wire::discover_request(1, "0.1.0");
    let headers = http_headers(None, None, &line);
    assert_eq!(
        header(&headers, "MCP-Protocol-Version"),
        Some(PROTOCOL_VERSION)
    );
    assert_eq!(header(&headers, "Mcp-Method"), Some("server/discover"));
}

#[test]
fn a_legacy_handshake_carries_no_version_and_no_modern_only_headers() {
    let line = crate::mcp_wire::initialize_request(1, "0.1.0");
    let headers = http_headers(Some(ServerEra::Legacy), None, &line);
    // Before the handshake there is no agreed version to name.
    assert_eq!(header(&headers, "MCP-Protocol-Version"), None);
    assert_eq!(header(&headers, "Mcp-Method"), None);
    assert_eq!(header(&headers, "Mcp-Name"), None);
}

#[test]
fn a_session_is_carried_back_to_a_legacy_server_and_never_to_a_modern_one() {
    let line = crate::mcp_wire::tools_list_request(2, ServerEra::Legacy, None, "0.1.0");
    let headers = http_headers(Some(ServerEra::Legacy), Some("abc123"), &line);
    assert_eq!(header(&headers, "Mcp-Session-Id"), Some("abc123"));

    // Modern deleted sessions. Sending one is telling a stateless server about
    // state it never issued.
    let modern = crate::mcp_wire::tools_list_request(2, ServerEra::Modern, None, "0.1.0");
    let headers = http_headers(Some(ServerEra::Modern), Some("abc123"), &modern);
    assert_eq!(header(&headers, "Mcp-Session-Id"), None);
}

#[test]
fn the_named_tool_in_the_header_is_the_tool_in_the_body() {
    let line =
        crate::mcp_wire::tools_call_request(3, ServerEra::Modern, "outl__search", "{}", "0.1.0")
            .expect("a call with object arguments builds");
    let headers = http_headers(Some(ServerEra::Modern), None, &line);
    assert_eq!(header(&headers, "Mcp-Method"), Some("tools/call"));
    assert_eq!(header(&headers, "Mcp-Name"), Some("outl__search"));

    // Nothing else names a tool, so nothing else carries the header.
    let listing = crate::mcp_wire::tools_list_request(4, ServerEra::Modern, None, "0.1.0");
    assert_eq!(
        header(
            &http_headers(Some(ServerEra::Modern), None, &listing),
            "Mcp-Name"
        ),
        None
    );
}

#[test]
fn a_token_becomes_one_header_and_an_empty_one_becomes_none() {
    assert_eq!(
        authorization_header("t0ken"),
        Some(("Authorization".to_string(), "Bearer t0ken".to_string()))
    );
    // Already carries its scheme: prefixing `Bearer` would authenticate as
    // nobody.
    assert_eq!(
        authorization_header("Basic Zm9vOmJhcg=="),
        Some((
            "Authorization".to_string(),
            "Basic Zm9vOmJhcg==".to_string()
        ))
    );
    assert_eq!(authorization_header(""), None);
    assert_eq!(authorization_header("   "), None);
}

// ---------------------------------------------------------------------------
// Reading an answer
// ---------------------------------------------------------------------------

#[test]
fn an_answer_arriving_as_an_event_stream_is_read_as_one() {
    // The specification lets a server answer a POST either way, so a client
    // that reads only JSON hangs against half of them until the deadline.
    let body = "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\n\n";
    assert_eq!(
        http_reply_lines("text/event-stream", body),
        vec!["{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}".to_string()]
    );

    // Without the final blank line, which is what a body delivered whole very
    // often looks like.
    let unterminated = "data: {\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{}}\n";
    assert_eq!(http_reply_lines("text/event-stream", unterminated).len(), 1);

    // And with the parameters a real server puts on the content type.
    assert_eq!(
        http_reply_lines("text/event-stream; charset=utf-8", body).len(),
        1
    );
}

#[test]
fn a_plain_json_answer_is_handed_over_untouched() {
    let body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"tools\":[]}}";
    assert_eq!(
        http_reply_lines("application/json", body),
        vec![body.to_string()]
    );
}

#[test]
fn an_answer_with_nothing_in_it_is_not_a_message() {
    // `202 Accepted` to a notification. Reading it as a reply would be reading
    // a reply to something that asked for none.
    assert!(http_reply_lines("application/json", "").is_empty());
    assert!(http_reply_lines("text/event-stream", "").is_empty());
    assert!(http_reply_lines("application/json", "   \n ").is_empty());
}

#[test]
fn a_batch_comes_apart_because_the_host_matches_one_id_at_a_time() {
    let body = "[{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}},{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{}}]";
    let lines = http_reply_lines("application/json", body);
    assert_eq!(lines.len(), 2);
    assert_eq!(crate::mcp_wire::reply_id(&lines[0]), Some(1));
    assert_eq!(crate::mcp_wire::reply_id(&lines[1]), Some(2));
}

// ---------------------------------------------------------------------------
// What a status means
// ---------------------------------------------------------------------------

#[test]
fn the_older_sse_transport_is_named_rather_than_guessed_around() {
    // The measured fact against the author's own proxy: `/mcp/sse` answers GET
    // and refuses POST. Retrying at a URL we invented would work for one proxy
    // and reach a stranger's server on the next.
    let outcome = http_status_failure(405, Some("GET,HEAD"), None);
    assert_eq!(outcome.failure, McpFailure::Rejected);
    assert!(
        outcome.message.contains("POST"),
        "said: {}",
        outcome.message
    );
    assert!(
        outcome.message.contains("GET,HEAD"),
        "said: {}",
        outcome.message
    );
    assert!(
        outcome.message.contains("/sse"),
        "said: {}",
        outcome.message
    );
}

#[test]
fn a_server_asking_for_a_sign_in_says_so_rather_than_reading_as_broken() {
    let outcome = http_status_failure(401, None, Some("Bearer resource_metadata=\"…\""));
    assert_eq!(outcome.failure, McpFailure::Unauthorized);
    assert!(
        outcome.message.contains("token"),
        "said: {}",
        outcome.message
    );
    assert!(
        outcome.message.contains("cannot sign in"),
        "zer0 does not do OAuth and must say so: {}",
        outcome.message
    );

    // 403 is a refusal, not a request for a token.
    let refused = http_status_failure(403, None, None);
    assert_eq!(refused.failure, McpFailure::Unauthorized);
    assert!(!refused.message.contains("cannot sign in"));
}

#[test]
fn a_server_that_is_not_running_reads_as_unreachable_rather_than_as_broken() {
    for status in [404, 410, 500, 502, 503] {
        let outcome = http_status_failure(status, None, None);
        assert_eq!(
            outcome.failure,
            McpFailure::Unreachable,
            "{status} should read as unreachable"
        );
    }
}
