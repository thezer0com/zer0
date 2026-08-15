//! What an extension is told, and — mostly — what it is refused.
//!
//! Weighted towards refusals on purpose. Every method here has a happy path
//! that is one line of plumbing and a refusal that is the whole decision: an
//! option silently dropped, a filter silently ignored or a pause that stops the
//! transfer and hopes are each a *working-looking* answer, and ADR-0077
//! measured that those cost more than the loud failure they replace.

use super::*;
use crate::downloads::{Download, DownloadError, DownloadErrorKind};
use crate::extension_permissions::PermissionKind;
use crate::model::TabId;

const NOBODY_IS_IDLE: HostFacts = HostFacts {
    seconds_since_input: 0,
    screen_locked: false,
};

fn holding(keys: &[&str]) -> ConsentDecision {
    let mut decision = ConsentDecision::refusing_everything("ext", 0, Vec::new());
    for key in keys {
        decision.allow(PermissionKind::Api, key);
    }
    decision
}

fn a_download(id: &str, state: DownloadState) -> Download {
    Download {
        id: DownloadId(id.to_string()),
        url: format!("https://example.com/{id}.zip"),
        tab: None,
        filename: format!("{id}.zip"),
        path: format!("/tmp/zer0-fake/{id}.zip"),
        state,
        received_bytes: 10,
        total_bytes: Some(20),
        error: None,
        started_at_ms: 1_000,
        resumable: false,
    }
}

/// The one call shape everything here uses. `active_tab` is `Some` because a
/// browser with no page open is its own refusal and has its own test.
fn call(
    method: &str,
    body: &str,
    decision: &ConsentDecision,
    downloads: &mut Downloads,
) -> ExtensionApiAnswer {
    answer(
        method,
        body,
        Some(decision),
        downloads,
        Some(TabId(7)),
        NOBODY_IS_IDLE,
    )
}

fn error_in(answer: &ExtensionApiAnswer) -> String {
    let body: serde_json::Value = serde_json::from_str(&answer.json).expect("an answer is JSON");
    body.get("error")
        .and_then(|v| v.as_str())
        .unwrap_or_else(|| panic!("expected a refusal, got {}", answer.json))
        .to_string()
}

fn ok_in(answer: &ExtensionApiAnswer) -> serde_json::Value {
    let body: serde_json::Value = serde_json::from_str(&answer.json).expect("an answer is JSON");
    body.get("ok")
        .cloned()
        .unwrap_or_else(|| panic!("expected an answer, got {}", answer.json))
}

// MARK: - who may call

#[test]
fn a_call_from_an_extension_nobody_was_asked_about_is_refused() {
    let mut downloads = Downloads::new();
    let refused = answer(
        "downloads.search",
        "{}",
        None,
        &mut downloads,
        Some(TabId(7)),
        NOBODY_IS_IDLE,
    );
    assert!(error_in(&refused).contains("decided"));
    assert_eq!(refused.outcome, ExtensionApiOutcome::Nothing);
}

#[test]
fn a_call_needing_a_permission_the_extension_is_not_holding_is_refused() {
    let mut downloads = Downloads::new();
    let refused = call(
        "downloads.search",
        "{}",
        &holding(&["idle"]),
        &mut downloads,
    );
    assert!(error_in(&refused).contains("downloads"));
}

/// The whole reason `downloads.open` is a separate key: it hands a file to
/// whatever the system opens that kind of file with, which is a way out of the
/// browser, and holding `downloads` is not consent to that.
#[test]
fn opening_a_downloaded_file_needs_its_own_permission() {
    let mut downloads = Downloads::load(vec![a_download("a", DownloadState::Completed)]);
    let holds_downloads = holding(&["downloads"]);
    let named = call("downloads.search", "{}", &holds_downloads, &mut downloads);
    assert_eq!(ok_in(&named)[0]["id"], 1);

    let refused = call(
        "downloads.open",
        "{\"id\":1}",
        &holds_downloads,
        &mut downloads,
    );
    assert!(error_in(&refused).contains("downloads.open"));

    let allowed = call(
        "downloads.open",
        "{\"id\":1}",
        &holding(&["downloads", "downloads.open"]),
        &mut downloads,
    );
    assert_eq!(
        allowed.outcome,
        ExtensionApiOutcome::OpenFile {
            path: "/tmp/zer0-fake/a.zip".to_string()
        }
    );
}

#[test]
fn a_method_this_browser_does_not_answer_is_refused_rather_than_guessed_at() {
    let mut downloads = Downloads::new();
    let refused = call(
        "downloads.setShelfEnabled",
        "{}",
        &holding(&["downloads"]),
        &mut downloads,
    );
    assert!(error_in(&refused).contains("downloads.setShelfEnabled"));
}

// MARK: - starting one

#[test]
fn a_download_reaches_the_engine_through_a_tab() {
    let mut downloads = Downloads::new();
    let started = call(
        "downloads.download",
        r#"{"url":"https://example.com/big.iso"}"#,
        &holding(&["downloads"]),
        &mut downloads,
    );
    assert_eq!(
        started.outcome,
        ExtensionApiOutcome::StartDownload {
            tab: TabId(7),
            url: "https://example.com/big.iso".to_string(),
        }
    );
    // Empty, because the answer is the identity of a download that does not
    // exist yet. The second call is what says it.
    assert!(started.json.is_empty());
    assert_eq!(
        download_started(&mut downloads, &DownloadId("x".into())),
        r#"{"ok":1}"#
    );
}

/// The option is not dropped and the call does not half-succeed. Both halves
/// matter: a version that ignored `filename` would pass a test that only
/// checked the download started.
#[test]
fn an_option_this_browser_will_not_honour_is_refused_by_name() {
    let mut downloads = Downloads::new();
    for option in [
        r#""filename":"invoice.pdf""#,
        r#""saveAs":true"#,
        r#""method":"POST""#,
        r#""headers":[]"#,
        r#""body":"x""#,
        r#""conflictAction":"overwrite""#,
    ] {
        let refused = call(
            "downloads.download",
            &format!(r#"{{"url":"https://example.com/f",{option}}}"#),
            &holding(&["downloads"]),
            &mut downloads,
        );
        let said = error_in(&refused);
        let name = option.split('"').nth(1).expect("an option has a name");
        assert!(said.contains(name), "{said} does not name {name}");
        assert_eq!(
            refused.outcome,
            ExtensionApiOutcome::Nothing,
            "{name} was refused and started anyway"
        );
    }

    // `uniquify` is accepted, and only because it is what this browser really
    // does — `report-2.pdf`, ADR-0027.
    let accepted = call(
        "downloads.download",
        r#"{"url":"https://example.com/f","conflictAction":"uniquify"}"#,
        &holding(&["downloads"]),
        &mut downloads,
    );
    assert!(matches!(
        accepted.outcome,
        ExtensionApiOutcome::StartDownload { .. }
    ));
}

#[test]
fn only_http_and_https_are_downloaded() {
    let mut downloads = Downloads::new();
    for url in [
        "file:///etc/passwd",
        "data:text/plain,hello",
        "webkit-extension://abc/manifest.json",
        "javascript:alert(1)",
        "",
    ] {
        let refused = call(
            "downloads.download",
            &serde_json::json!({ "url": url }).to_string(),
            &holding(&["downloads"]),
            &mut downloads,
        );
        assert_eq!(
            refused.outcome,
            ExtensionApiOutcome::Nothing,
            "{url} was accepted"
        );
    }
}

#[test]
fn a_browser_with_no_page_open_has_nowhere_to_download_through() {
    let mut downloads = Downloads::new();
    let refused = answer(
        "downloads.download",
        r#"{"url":"https://example.com/f"}"#,
        Some(&holding(&["downloads"])),
        &mut downloads,
        None,
        NOBODY_IS_IDLE,
    );
    assert!(error_in(&refused).contains("no page open"));
}

// MARK: - reading the list

#[test]
fn a_search_answers_out_of_the_list_the_core_already_keeps() {
    let mut downloads = Downloads::load(vec![
        a_download("new", DownloadState::InProgress),
        a_download("old", DownloadState::Completed),
    ]);
    let found = ok_in(&call(
        "downloads.search",
        "{}",
        &holding(&["downloads"]),
        &mut downloads,
    ));
    assert_eq!(found.as_array().expect("an array").len(), 2);
    assert_eq!(found[0]["state"], "in_progress");
    assert_eq!(found[1]["state"], "complete");
    assert_eq!(found[1]["bytesReceived"], 10);
    assert_eq!(found[1]["totalBytes"], 20);
}

/// A total nobody sent is `0`, which is Chrome's own answer for the same fact.
/// Anything else here would be this file inventing the number ADR-0027 refuses
/// to draw a bar from.
#[test]
fn a_length_no_server_sent_is_not_invented() {
    let mut unknown = a_download("a", DownloadState::InProgress);
    unknown.total_bytes = None;
    let mut downloads = Downloads::load(vec![unknown]);
    let found = ok_in(&call(
        "downloads.search",
        "{}",
        &holding(&["downloads"]),
        &mut downloads,
    ));
    assert_eq!(found[0]["totalBytes"], 0);
}

/// The refusal is the decision. A `search` that dropped the filter would answer
/// a question nobody asked, and the caller cannot tell that from a genuinely
/// empty result.
#[test]
fn a_search_filtered_by_something_this_browser_cannot_answer_is_refused() {
    let mut downloads = Downloads::load(vec![a_download("a", DownloadState::Completed)]);
    for filter in [
        r#""danger":"safe""#,
        r#""filenameRegex":".*""#,
        r#""mime":"x""#,
    ] {
        let refused = call(
            "downloads.search",
            &format!("{{{filter}}}"),
            &holding(&["downloads"]),
            &mut downloads,
        );
        let name = filter.split('"').nth(1).expect("a filter has a name");
        assert!(error_in(&refused).contains(name));
    }
}

#[test]
fn a_search_filters_by_what_it_says_it_filters_by() {
    let mut downloads = Downloads::load(vec![
        a_download("running", DownloadState::InProgress),
        a_download("done", DownloadState::Completed),
    ]);
    let holds = holding(&["downloads"]);

    let complete = ok_in(&call(
        "downloads.search",
        r#"{"state":"complete"}"#,
        &holds,
        &mut downloads,
    ));
    assert_eq!(complete.as_array().expect("an array").len(), 1);
    assert_eq!(complete[0]["url"], "https://example.com/done.zip");

    let one = ok_in(&call(
        "downloads.search",
        r#"{"limit":1}"#,
        &holds,
        &mut downloads,
    ));
    assert_eq!(one.as_array().expect("an array").len(), 1);
}

/// Cancelled, failed and interrupted are all `interrupted` to Chrome, which is
/// the truthful collapse: all three mean the whole file did not arrive.
#[test]
fn every_way_a_download_stops_short_reads_as_interrupted() {
    for state in [
        DownloadState::Cancelled,
        DownloadState::Failed,
        DownloadState::Interrupted,
    ] {
        let mut stopped = a_download("a", state);
        stopped.error = Some(DownloadError {
            kind: DownloadErrorKind::Offline,
            message: "offline".to_string(),
        });
        let mut downloads = Downloads::load(vec![stopped]);
        let found = ok_in(&call(
            "downloads.search",
            "{}",
            &holding(&["downloads"]),
            &mut downloads,
        ));
        assert_eq!(found[0]["state"], "interrupted");
        assert_eq!(found[0]["exists"], false);
    }
}

/// An extension can only mean a number this browser handed it. A number nobody
/// was given naming whatever happens to be in that slot is how one extension's
/// stale id erases another's file.
#[test]
fn a_download_this_browser_never_named_cannot_be_reached_by_number() {
    let mut downloads = Downloads::load(vec![a_download("a", DownloadState::Completed)]);
    let holds = holding(&["downloads", "downloads.open"]);

    for method in ["downloads.cancel", "downloads.open", "downloads.show"] {
        let refused = call(method, r#"{"id":1}"#, &holds, &mut downloads);
        assert!(
            error_in(&refused).contains("no download"),
            "{method} answered about a download it had never named"
        );
    }

    // Now it has been named, so the same number means something.
    let _ = call("downloads.search", "{}", &holds, &mut downloads);
    let shown = call("downloads.show", r#"{"id":1}"#, &holds, &mut downloads);
    assert_eq!(
        shown.outcome,
        ExtensionApiOutcome::ShowFile {
            path: "/tmp/zer0-fake/a.zip".to_string()
        }
    );
}

#[test]
fn a_file_that_never_finished_arriving_is_not_offered_to_be_opened() {
    let mut downloads = Downloads::load(vec![a_download("a", DownloadState::InProgress)]);
    let holds = holding(&["downloads", "downloads.open"]);
    let _ = call("downloads.search", "{}", &holds, &mut downloads);

    let refused = call("downloads.open", r#"{"id":1}"#, &holds, &mut downloads);
    assert!(error_in(&refused).contains("did not finish"));
    assert_eq!(refused.outcome, ExtensionApiOutcome::Nothing);
}

#[test]
fn cancelling_reaches_the_engine_and_only_for_something_still_arriving() {
    let mut downloads = Downloads::load(vec![
        a_download("running", DownloadState::InProgress),
        a_download("done", DownloadState::Completed),
    ]);
    let holds = holding(&["downloads"]);
    let _ = call("downloads.search", "{}", &holds, &mut downloads);

    let stopped = call("downloads.cancel", r#"{"id":1}"#, &holds, &mut downloads);
    assert_eq!(
        stopped.actions,
        vec![Action::CancelDownload {
            id: DownloadId("running".to_string())
        }]
    );

    let refused = call("downloads.cancel", r#"{"id":2}"#, &holds, &mut downloads);
    assert!(error_in(&refused).contains("already stopped"));
    assert!(refused.actions.is_empty());
}

#[test]
fn erasing_takes_the_rows_out_of_the_list_and_says_which() {
    let mut downloads = Downloads::load(vec![
        a_download("running", DownloadState::InProgress),
        a_download("done", DownloadState::Completed),
    ]);
    let holds = holding(&["downloads"]);
    // Named first, so the numbers below are ones an extension really holds.
    let _ = call("downloads.search", "{}", &holds, &mut downloads);

    let answered = call(
        "downloads.erase",
        r#"{"state":"complete"}"#,
        &holds,
        &mut downloads,
    );
    let erased = ok_in(&answered);
    // Through the reducer, so the row leaves the Downloads screen too.
    assert_eq!(
        answered.actions,
        vec![Action::RemoveDownload {
            id: DownloadId("done".to_string())
        }]
    );
    assert_eq!(erased, serde_json::json!([2]));
}

/// A filter `search` refuses is a filter `erase` refuses, and it must refuse
/// before removing anything. An erase that ignored the filter would empty the
/// list.
#[test]
fn an_erase_this_browser_cannot_narrow_removes_nothing() {
    let mut downloads = Downloads::load(vec![a_download("a", DownloadState::Completed)]);
    let refused = call(
        "downloads.erase",
        r#"{"danger":"safe"}"#,
        &holding(&["downloads"]),
        &mut downloads,
    );
    assert!(error_in(&refused).contains("danger"));
    assert!(refused.actions.is_empty());
}

// MARK: - the two that are refused

/// ADR-0101 put resumability in the shell, for this run only, and
/// `StorableDownload` has no field that could carry it. There is nothing behind
/// an extension-facing pause that could keep the promise the word makes, so the
/// answer is no and it says why.
#[test]
fn pausing_and_resuming_are_refused_rather_than_answered() {
    let mut downloads = Downloads::load(vec![a_download("a", DownloadState::InProgress)]);
    let holds = holding(&["downloads"]);
    let _ = call("downloads.search", "{}", &holds, &mut downloads);

    for method in ["downloads.pause", "downloads.resume"] {
        let refused = call(method, r#"{"id":1}"#, &holds, &mut downloads);
        let said = error_in(&refused);
        assert!(said.contains("this run"), "{method}: {said}");
        assert_eq!(refused.outcome, ExtensionApiOutcome::Nothing);
        assert!(refused.actions.is_empty(), "{method} did something");
    }
    // And the transfer is untouched: a pause that stopped it and hoped would be
    // the silent failure this refusal exists to avoid.
    assert_eq!(downloads.all()[0].state, DownloadState::InProgress);
}

// MARK: - idle

#[test]
fn a_locked_screen_is_locked_however_recently_anything_was_typed() {
    let mut downloads = Downloads::new();
    let answered = answer(
        "idle.queryState",
        "60",
        Some(&holding(&["idle"])),
        &mut downloads,
        Some(TabId(7)),
        HostFacts {
            seconds_since_input: 0,
            screen_locked: true,
        },
    );
    assert_eq!(ok_in(&answered), "locked");
}

#[test]
fn idle_is_what_the_machine_says_and_the_threshold_is_the_callers() {
    let mut downloads = Downloads::new();
    let holds = holding(&["idle"]);
    let ask = |seconds: u64, threshold: &str, downloads: &mut Downloads| {
        ok_in(&answer(
            "idle.queryState",
            threshold,
            Some(&holds),
            downloads,
            Some(TabId(7)),
            HostFacts {
                seconds_since_input: seconds,
                screen_locked: false,
            },
        ))
    };
    assert_eq!(ask(59, "60", &mut downloads), "active");
    assert_eq!(ask(60, "60", &mut downloads), "idle");
    // Chrome's object form of the same question.
    assert_eq!(
        ask(600, r#"{"detectionIntervalInSeconds":60}"#, &mut downloads),
        "idle"
    );
}

/// A caller asking about one second would otherwise be told about a second
/// nothing measured. Chrome refuses the same interval for the same reason.
#[test]
fn an_idle_threshold_below_the_floor_is_raised_to_it_rather_than_answered() {
    let mut downloads = Downloads::new();
    let answered = answer(
        "idle.queryState",
        "1",
        Some(&holding(&["idle"])),
        &mut downloads,
        Some(TabId(7)),
        HostFacts {
            seconds_since_input: 5,
            screen_locked: false,
        },
    );
    assert_eq!(ok_in(&answered), "active");
}

#[test]
fn an_idle_question_with_no_threshold_in_it_is_refused() {
    let mut downloads = Downloads::new();
    let refused = call("idle.queryState", "{}", &holding(&["idle"]), &mut downloads);
    assert!(error_in(&refused).contains("seconds"));
}

// MARK: - the body is somebody else's JavaScript

#[test]
fn a_body_that_is_not_json_is_refused_rather_than_repaired() {
    let mut downloads = Downloads::new();
    let refused = call(
        "downloads.download",
        "{url: https://example.com}",
        &holding(&["downloads"]),
        &mut downloads,
    );
    assert!(error_in(&refused).contains("JSON"));
}

/// Every answer is a JSON object with exactly one of `ok` and `error`, so the
/// file on the other side never has to guess which it got.
#[test]
fn every_answer_says_either_ok_or_error_and_never_both() {
    let mut downloads = Downloads::load(vec![a_download("a", DownloadState::Completed)]);
    let holds = holding(&["downloads"]);
    for (method, body) in [
        ("downloads.search", "{}"),
        ("downloads.erase", "{}"),
        ("downloads.cancel", r#"{"id":9}"#),
        ("downloads.pause", r#"{"id":9}"#),
        ("nonsense.method", "{}"),
        ("idle.queryState", "60"),
    ] {
        let answered = call(method, body, &holds, &mut downloads);
        let body: serde_json::Value =
            serde_json::from_str(&answered.json).expect("an answer is JSON");
        let object = body.as_object().expect("an answer is an object");
        assert_eq!(object.len(), 1, "{method} answered {}", answered.json);
        assert!(
            object.contains_key("ok") || object.contains_key("error"),
            "{method} answered {}",
            answered.json
        );
    }
}
