//! Tests for the consent vocabulary and the consent ledger.
//!
//! Weighted towards refusal on purpose: the happy path here is one sentence
//! ("what was ticked is what was granted") and everything expensive lives in
//! what must *not* happen.

use super::*;

fn hosts(patterns: &[&str]) -> Vec<String> {
    patterns.iter().map(|p| p.to_string()).collect()
}

fn request_for(key: &str, request: &ConsentRequest) -> Option<PermissionRequest> {
    request.requests.iter().find(|r| r.key == key).cloned()
}

// MARK: - The words

#[test]
fn all_urls_is_described_by_what_it_costs_you_not_by_its_name() {
    let request = consent_request("id", "Blocker", &[], &hosts(&["<all_urls>"]));
    let all_urls = request_for("<all_urls>", &request).expect("described");

    assert_eq!(
        all_urls.title,
        "Read and change everything you do on every site"
    );
    assert_eq!(all_urls.risk, PermissionRisk::Critical);
    assert_eq!(all_urls.kind, PermissionKind::Site);
    // The point of the detail line is that it names something concrete enough
    // to make someone stop.
    assert!(all_urls.detail.contains("bank"));
}

#[test]
fn a_wildcard_host_reads_the_same_as_all_urls_because_it_is_the_same_thing() {
    for pattern in ["https://*/*", "*://*/*", "http://*/*"] {
        let request = consent_request("id", "X", &[], &hosts(&[pattern]));
        let described = request_for(pattern, &request).unwrap_or_else(|| panic!("{pattern}"));
        assert_eq!(
            described.title, "Read and change everything you do on every site",
            "{pattern} grants every site and has to say so"
        );
        assert_eq!(described.risk, PermissionRisk::Critical);
    }
}

#[test]
fn one_site_and_a_whole_domain_are_not_described_as_the_same_thing() {
    let request = consent_request(
        "id",
        "X",
        &[],
        &hosts(&["https://example.com/*", "https://*.example.com/*"]),
    );

    let one = request_for("https://example.com/*", &request).expect("one site");
    let all = request_for("https://*.example.com/*", &request).expect("whole domain");

    assert_eq!(
        one.title,
        "Read and change everything you do on example.com"
    );
    assert_eq!(
        all.title,
        "Read and change everything you do on example.com and every site under it"
    );
    assert_eq!(one.risk, PermissionRisk::Moderate);
    assert_eq!(all.risk, PermissionRisk::High);
}

#[test]
fn every_description_is_a_sentence_someone_could_act_on() {
    // Nothing may fall back to printing the raw key, and nothing may be blank:
    // a dialog row with no words in it is worse than no dialog.
    let keys: Vec<String> = [
        "tabs",
        "cookies",
        "storage",
        "activeTab",
        "debugger",
        "clipboardRead",
        "declarativeNetRequest",
        "somethingNobodyHasHeardOf",
    ]
    .iter()
    .map(|k| k.to_string())
    .collect();

    let request = consent_request("id", "X", &keys, &[]);

    assert_eq!(request.requests.len(), keys.len());
    for described in &request.requests {
        assert!(
            !described.title.is_empty(),
            "{} has no title",
            described.key
        );
        assert!(
            !described.detail.is_empty(),
            "{} has no detail",
            described.key
        );
        assert_ne!(
            described.title, described.key,
            "{} is printing its own name at someone",
            described.key
        );
    }
}

#[test]
fn a_permission_nobody_can_explain_is_not_pre_approved() {
    let request = consent_request("id", "X", &["quantumTelepathy".into()], &[]);
    let unknown = request_for("quantumTelepathy", &request).expect("still listed");

    assert_eq!(unknown.risk, PermissionRisk::Unknown);
    assert!(
        !unknown.default_granted,
        "there is no informed consent to be had for a sentence nobody can write"
    );
    // It is still shown. Hiding it would be the same silence this whole file
    // exists to end.
    assert!(unknown.detail.contains("does not know") || unknown.detail.contains("not one zer0"));
}

#[test]
fn the_permissions_real_packages_declare_all_have_a_sentence() {
    // Measured across the store packages this browser installs. Every one of
    // these used to fall to "Something zer0 cannot explain", which arrives
    // unticked — so the browser denied by default a thing it could have
    // described perfectly well, and the extension quietly did less.
    for key in [
        "offscreen",
        "notifications",
        "management",
        "idle",
        "privacy",
        "sidePanel",
        "identity",
        "downloads",
        "userScripts",
        "webRequestAuthProvider",
        "declarativeNetRequestWithHostAccess",
        "unlimitedStorage",
        "webRequestBlocking",
    ] {
        let request = consent_request("id", "X", &[key.into()], &[]);
        let described = request_for(key, &request).unwrap_or_else(|| panic!("{key}"));
        assert_ne!(
            described.risk,
            PermissionRisk::Unknown,
            "{key} is still filed under what zer0 cannot explain"
        );
    }
}

#[test]
fn anything_the_browser_can_explain_arrives_ticked() {
    // An extension that installs switched off is an extension that looks
    // broken, and a browser that looks broken gets uninstalled instead of read.
    let request = consent_request(
        "id",
        "Blocker",
        &["declarativeNetRequest".into(), "storage".into()],
        &hosts(&["<all_urls>"]),
    );

    assert!(request.requests.iter().all(|r| r.default_granted));
}

// MARK: - Ranking

#[test]
fn the_dangerous_ones_come_first() {
    let request = consent_request(
        "id",
        "X",
        &["storage".into(), "cookies".into(), "debugger".into()],
        &hosts(&["https://example.com/*", "<all_urls>"]),
    );

    let order: Vec<&str> = request.requests.iter().map(|r| r.key.as_str()).collect();
    assert_eq!(
        order,
        [
            // Critical, sites before APIs.
            "<all_urls>",
            "debugger",
            // High.
            "cookies",
            // Moderate.
            "https://example.com/*",
            // Low.
            "storage",
        ]
    );
}

#[test]
fn the_same_manifest_always_produces_the_same_screen() {
    let forwards = consent_request(
        "id",
        "X",
        &["storage".into(), "alarms".into(), "idle".into()],
        &[],
    );
    let backwards = consent_request(
        "id",
        "X",
        &["idle".into(), "alarms".into(), "storage".into()],
        &[],
    );

    let keys =
        |r: &ConsentRequest| -> Vec<String> { r.requests.iter().map(|p| p.key.clone()).collect() };
    assert_eq!(keys(&forwards), keys(&backwards));
}

// MARK: - Patterns nobody could read

#[test]
fn an_unreadable_pattern_is_never_offered_for_approval() {
    let request = consent_request(
        "id",
        "X",
        &[],
        &hosts(&["https://example.com/*", "not a pattern at all"]),
    );

    assert!(
        request_for("not a pattern at all", &request).is_none(),
        "offering it would be presenting a guess as an understanding"
    );
    assert_eq!(request.unreadable_hosts, ["not a pattern at all"]);
    assert_eq!(request.requests.len(), 1);
}

#[test]
fn the_shapes_that_are_not_patterns_are_all_refused() {
    let bad = [
        "not a pattern at all",
        // No scheme separator.
        "example.com/*",
        // A scheme the grammar does not have.
        "javascript://*/*",
        "chrome-extension://abc/*",
        // No path.
        "https://example.com",
        // A star somewhere a star cannot go.
        "https://*.*.com/*",
        "https://exa*mple.com/*",
        // Empty host.
        "https:///*",
        "",
    ];

    for pattern in bad {
        let request = consent_request("id", "X", &[], &hosts(&[pattern]));
        assert!(
            request.requests.is_empty(),
            "{pattern:?} was read as a site rule and should not have been"
        );
        assert_eq!(request.unreadable_hosts, [pattern.to_string()]);
    }
}

#[test]
fn accepting_the_dialog_as_it_opened_cannot_grant_an_unreadable_pattern() {
    let request = consent_request("id", "X", &[], &hosts(&["<all_urls>", "garbage"]));
    let decision = request.default_decision(1_000);

    assert_eq!(decision.granted_hosts, ["<all_urls>"]);
    assert_eq!(decision.unreadable_hosts, ["garbage"]);
    assert!(!decision.grants(PermissionKind::Site, "garbage"));
}

#[test]
fn an_unreadable_pattern_cannot_be_granted_even_when_asked_for_directly() {
    // The last gate before the ledger. Anything upstream can be got around;
    // this cannot.
    let mut decision = ConsentDecision::refusing_everything("id", 0, vec!["garbage".to_string()]);

    decision.allow(PermissionKind::Site, "garbage");

    assert!(decision.granted_hosts.is_empty());
}

#[test]
fn a_pattern_the_engine_refuses_stops_being_recorded_as_granted() {
    // The core reads patterns itself and the engine has the final say. When
    // they disagree, the record must follow the engine, not the parser.
    let mut decision = ConsentDecision::refusing_everything("id", 0, Vec::new());
    decision.allow(PermissionKind::Site, "https://example.com/*");

    decision.mark_unreadable("https://example.com/*");

    assert!(decision.granted_hosts.is_empty());
    assert_eq!(decision.unreadable_hosts, ["https://example.com/*"]);
}

// MARK: - The ledger

#[test]
fn nothing_is_granted_by_default_and_no_decision_is_not_an_empty_one() {
    let consent = ExtensionConsent::new();

    // The difference matters: `None` means "nobody was asked, do not run it",
    // and an empty decision means "asked, and the answer was no".
    assert!(consent.decision("anything").is_none());
}

#[test]
fn what_was_ticked_is_what_is_granted_and_the_rest_is_refused() {
    let request = consent_request(
        "id",
        "X",
        &["storage".into(), "debugger".into()],
        &hosts(&["<all_urls>"]),
    );
    let mut decision = request.default_decision(1_000);
    decision.refuse(PermissionKind::Site, "<all_urls>");
    decision.refuse(PermissionKind::Api, "debugger");

    let mut consent = ExtensionConsent::new();
    consent.record(decision);
    let stored = consent.decision("id").expect("recorded");

    assert!(stored.grants(PermissionKind::Api, "storage"));
    assert!(!stored.grants(PermissionKind::Api, "debugger"));
    assert!(!stored.grants(PermissionKind::Site, "<all_urls>"));
    assert!(stored.refuses(PermissionKind::Site, "<all_urls>"));
}

#[test]
fn a_refusal_is_written_down_rather_than_left_to_be_inferred_from_absence() {
    // Absence has to keep meaning "never asked", because that is what happens
    // when a manifest grows a permission after the install.
    let mut decision = ConsentDecision::refusing_everything("id", 0, Vec::new());
    decision.refuse(PermissionKind::Api, "cookies");

    assert!(decision.refuses(PermissionKind::Api, "cookies"));
    assert!(!decision.refuses(PermissionKind::Api, "history"));
    assert!(!decision.grants(PermissionKind::Api, "history"));
}

#[test]
fn revoking_turns_a_grant_into_a_refusal_so_it_survives_a_relaunch() {
    let mut consent = ExtensionConsent::new();
    let request = consent_request("id", "X", &["cookies".into()], &hosts(&["<all_urls>"]));
    consent.record(request.default_decision(1_000));

    assert!(consent.revoke("id", PermissionKind::Site, "<all_urls>"));

    let stored = consent.decision("id").expect("still there");
    assert!(!stored.grants(PermissionKind::Site, "<all_urls>"));
    assert!(
        stored.refuses(PermissionKind::Site, "<all_urls>"),
        "dropping it instead would let the next launch treat it as never asked"
    );
    assert!(
        stored.grants(PermissionKind::Api, "cookies"),
        "and only that"
    );
}

#[test]
fn revoking_something_that_was_never_granted_changes_nothing() {
    let mut consent = ExtensionConsent::new();
    consent.record(ConsentDecision::refusing_everything("id", 0, Vec::new()));

    assert!(!consent.revoke("id", PermissionKind::Api, "cookies"));
    assert!(!consent.revoke("nobody", PermissionKind::Api, "cookies"));
}

#[test]
fn a_revoked_permission_can_be_given_back_from_the_same_screen() {
    let mut consent = ExtensionConsent::new();
    let request = consent_request("id", "X", &["cookies".into()], &[]);
    consent.record(request.default_decision(1_000));
    consent.revoke("id", PermissionKind::Api, "cookies");

    assert!(consent.grant("id", PermissionKind::Api, "cookies"));

    let stored = consent.decision("id").expect("there");
    assert!(stored.grants(PermissionKind::Api, "cookies"));
    assert!(!stored.refuses(PermissionKind::Api, "cookies"));
}

#[test]
fn an_unreadable_pattern_cannot_be_granted_from_the_review_screen_either() {
    let mut consent = ExtensionConsent::new();
    consent.record(ConsentDecision::refusing_everything(
        "id",
        0,
        vec!["garbage".to_string()],
    ));

    assert!(!consent.grant("id", PermissionKind::Site, "garbage"));
    assert!(
        !consent
            .decision("id")
            .unwrap()
            .grants(PermissionKind::Site, "garbage")
    );
}

#[test]
fn refusing_everything_is_a_decision_and_says_so() {
    let request = consent_request("id", "X", &["cookies".into()], &hosts(&["<all_urls>"]));
    let mut decision = request.default_decision(1_000);
    decision.refuse(PermissionKind::Api, "cookies");
    decision.refuse(PermissionKind::Site, "<all_urls>");

    assert!(decision.grants_nothing());

    let mut consent = ExtensionConsent::new();
    consent.record(decision);
    // Recorded, so nobody is asked twice and nothing is quietly granted on the
    // next launch.
    assert!(consent.decision("id").is_some());
}

#[test]
fn recording_again_replaces_rather_than_stacks() {
    let mut consent = ExtensionConsent::new();
    consent.record(ConsentDecision::refusing_everything("id", 1, Vec::new()));
    let mut second = ConsentDecision::refusing_everything("id", 2, Vec::new());
    second.allow(PermissionKind::Api, "storage");
    consent.record(second);

    assert_eq!(consent.all().len(), 1);
    assert_eq!(consent.decision("id").unwrap().decided_at_ms, 2);
}

#[test]
fn uninstalling_forgets_the_answer_so_a_reinstall_asks_again() {
    let mut consent = ExtensionConsent::new();
    consent.record(consent_request("id", "X", &["storage".into()], &[]).default_decision(1));

    consent.forget("id");

    assert!(
        consent.decision("id").is_none(),
        "a reinstall is different code and must not inherit an answer about the old code"
    );
}

#[test]
fn one_extensions_answer_does_not_reach_another() {
    let mut consent = ExtensionConsent::new();
    consent.record(consent_request("a", "A", &["cookies".into()], &[]).default_decision(1));
    consent.record(ConsentDecision::refusing_everything("b", 1, Vec::new()));

    assert!(
        consent
            .decision("a")
            .unwrap()
            .grants(PermissionKind::Api, "cookies")
    );
    assert!(
        !consent
            .decision("b")
            .unwrap()
            .grants(PermissionKind::Api, "cookies")
    );
}

// MARK: - Two rows never say the same thing

/// Every API permission the vocabulary has an arm for, read out of the source.
///
/// Read rather than listed, because a list is a second copy that goes stale the
/// first time somebody adds a permission and forgets it — and the failure of a
/// stale list is silence, which is the failure this whole check exists to
/// catch. `StoreInstallMessageTests/nothingButTheKindIsReadOutOfAMessage` reads
/// source for the same reason.
fn every_described_permission() -> Vec<String> {
    let source = include_str!("extension_permissions.rs");
    let table = source
        .split_once("fn api_description")
        .expect("the vocabulary lives in api_description")
        .1;

    let mut keys = Vec::new();
    for line in table.lines() {
        let Some(patterns) = line.trim().strip_suffix("=> (") else {
            continue;
        };
        for part in patterns.split('|') {
            let part = part.trim();
            if let Some(key) = part.strip_prefix('"').and_then(|p| p.strip_suffix('"')) {
                keys.push(key.to_string());
            }
        }
    }
    keys
}

#[test]
fn no_two_permissions_are_described_by_the_same_sentence() {
    // The measured defect: `storage` and `unlimitedStorage` shared one
    // description, so a manifest declaring both drew "Store its own settings on
    // this Mac" twice with a switch beside each. Two identical rows read as a
    // rendering fault, and on a consent sheet a rendering fault is a reason to
    // stop trusting the sheet.
    let keys = every_described_permission();
    assert!(
        keys.len() > 40,
        "the vocabulary was not found in the source: {} keys",
        keys.len()
    );

    let request = consent_request("id", "Everything", &keys, &[]);
    assert_eq!(
        request.requests.len(),
        keys.len(),
        "a key described by the vocabulary went missing from the sheet"
    );

    for (index, row) in request.requests.iter().enumerate() {
        for other in &request.requests[index + 1..] {
            assert_ne!(
                row.title, other.title,
                "{} and {} are offered under the same title",
                row.key, other.key
            );
            assert_ne!(
                row.detail, other.detail,
                "{} and {} are offered under the same detail",
                row.key, other.key
            );
        }
    }
}

// MARK: - What the browser holds

#[test]
fn something_that_is_not_installed_has_no_standing_of_any_other_kind() {
    assert_eq!(standing(false, None, &[]), ExtensionStanding::NotInstalled);
    // Even with a decision left over, absent from disk is absent.
    let request = consent_request("id", "X", &["storage".into()], &[]);
    let decision = request.default_decision(1);
    assert_eq!(
        standing(false, Some(&decision), &request.requests),
        ExtensionStanding::NotInstalled
    );
}

#[test]
fn installed_and_never_asked_is_a_state_of_its_own() {
    // The state the owner was stuck in: 1Password on disk, nothing decided, and
    // every surface offering to add what was already there.
    let request = consent_request("id", "X", &["storage".into()], &hosts(&["<all_urls>"]));
    assert_eq!(
        standing(true, None, &request.requests),
        ExtensionStanding::Undecided
    );
}

#[test]
fn granting_nothing_is_a_decision_and_not_an_absent_one() {
    let request = consent_request("id", "X", &["storage".into()], &[]);
    let decision = ConsentDecision::refusing_everything("id", 1, Vec::new());
    assert_eq!(
        standing(true, Some(&decision), &request.requests),
        ExtensionStanding::GrantedNothing,
        "a refusal must not read as never having been asked"
    );
}

#[test]
fn a_running_extension_says_how_much_of_what_it_asked_for_it_holds() {
    let request = consent_request(
        "id",
        "Blocker",
        &["storage".into(), "cookies".into()],
        &hosts(&["https://example.com/*"]),
    );
    let mut decision = request.default_decision(1);
    decision.refuse(PermissionKind::Api, "cookies");

    assert_eq!(
        standing(true, Some(&decision), &request.requests),
        ExtensionStanding::Running {
            held: 2,
            asked: 3,
            withheld: Withheld::SomethingProvidable,
        }
    );
}

#[test]
fn holding_more_than_was_asked_about_never_reports_a_count_it_cannot_justify() {
    // A manifest that grew a permission since the decision, or a decision
    // carried across an upgrade. "3 of 2" is not a sentence the browser is
    // allowed to write (ADR-0018).
    let request = consent_request("id", "X", &["storage".into(), "cookies".into()], &[]);
    let mut decision = ConsentDecision::refusing_everything("id", 1, Vec::new());
    decision.allow(PermissionKind::Api, "storage");
    decision.allow(PermissionKind::Api, "cookies");
    decision.allow(PermissionKind::Api, "tabs");

    assert_eq!(
        standing(true, Some(&decision), &request.requests),
        ExtensionStanding::Running {
            held: 3,
            asked: 3,
            withheld: Withheld::Nothing,
        }
    );
}

// MARK: - What this browser cannot provide

#[test]
fn a_permission_this_browser_cannot_provide_is_stated_rather_than_switched() {
    // Measured: `chrome.offscreen` is absent from a fully granted extension
    // context on this engine, so a switch beside it would be a control that
    // accepts a press and does nothing — the lie of affordance ADR-0018 names.
    let request = consent_request("id", "X", &["offscreen".into()], &[]);
    let offscreen = request_for("offscreen", &request).expect("still listed");

    let stated = offscreen.not_provided.expect("said, not switched");
    let reason = stated.sentence();
    assert!(
        reason.contains("does not provide"),
        "said instead: {reason}"
    );
    assert!(
        !offscreen.default_granted,
        "recording a grant that reaches nothing is the fail-open direction"
    );
    // And it is still described, because what the extension wanted is worth
    // reading even when it cannot have it.
    assert_ne!(offscreen.risk, PermissionRisk::Unknown);
}

#[test]
fn a_permission_this_browser_cannot_provide_is_never_recorded_as_granted() {
    // The last gate before the ledger, and the one that survives a refactor of
    // the views: anything upstream can be got around, this cannot. Without it
    // the missing switch is a promise the next screen is free to break.
    let mut decision = ConsentDecision::refusing_everything("id", 0, Vec::new());

    decision.allow(PermissionKind::Api, "offscreen");

    assert!(decision.granted_permissions.is_empty());
    assert!(!decision.grants(PermissionKind::Api, "offscreen"));

    // And a permission nobody has described is not caught by it. Not knowing
    // what something is has never been evidence that it does nothing.
    decision.allow(PermissionKind::Api, "quantumTelepathy");
    assert!(decision.grants(PermissionKind::Api, "quantumTelepathy"));
}

#[test]
fn a_permission_this_browser_does_provide_keeps_its_switch() {
    // The other half. Without it the whole vocabulary could be marked inert and
    // the test above would still pass.
    for key in ["storage", "cookies", "scripting", "webRequest"] {
        let request = consent_request("id", "X", &[key.into()], &[]);
        let described = request_for(key, &request).unwrap_or_else(|| panic!("{key}"));
        assert!(
            described.not_provided.is_none(),
            "{key} was marked as something this browser cannot provide"
        );
        assert!(described.default_granted, "{key} arrived switched off");
    }
}

#[test]
fn site_access_is_never_marked_as_something_this_browser_cannot_provide() {
    let request = consent_request("id", "X", &[], &hosts(&["<all_urls>"]));
    let all_urls = request_for("<all_urls>", &request).expect("described");

    assert!(all_urls.not_provided.is_none());
    assert!(all_urls.default_granted);
}

#[test]
fn nothing_is_listed_as_working_that_the_vocabulary_has_never_heard_of() {
    // `ENGINE_PROVIDES` is the only thing standing between a typo and a
    // permission silently losing its switch, and a typo in it is invisible:
    // "webrequest" simply never matches, so `webRequest` becomes inert and the
    // screen says this browser cannot do the one thing a blocker is for.
    let described = every_described_permission();
    for key in ENGINE_PROVIDES {
        assert!(
            described.iter().any(|d| d == key),
            "{key} is listed as provided but the vocabulary has no arm for it"
        );
    }
}

#[test]
fn what_is_withheld_is_read_by_whether_a_switch_could_have_helped() {
    // Three ways to be short of what you asked for, and only one of them is a
    // state where pointing somebody at a switch is honest (ADR-0084).
    let request = consent_request(
        "id",
        "X",
        &["storage".into(), "offscreen".into()],
        &hosts(&["<all_urls>"]),
    );

    // Accepting the sheet as it opens: `offscreen` is not granted, and it is
    // the only thing that is not.
    let inert_only = request.default_decision(1);
    assert_eq!(
        standing(true, Some(&inert_only), &request.requests),
        ExtensionStanding::Running {
            held: 2,
            asked: 3,
            withheld: Withheld::OnlyTheUnprovidable,
        }
    );

    // Switch off one thing this browser really does provide, and the answer
    // changes even though the arithmetic barely moves.
    let mut also_real = inert_only.clone();
    also_real.refuse(PermissionKind::Api, "storage");
    assert_eq!(
        standing(true, Some(&also_real), &request.requests),
        ExtensionStanding::Running {
            held: 1,
            asked: 3,
            withheld: Withheld::SomethingProvidable,
        }
    );

    // Nothing withheld is a state only an extension that asked for nothing
    // inert can reach — the row above cannot be switched on, so this browser
    // never gets to "holding all of it" while one of them is in the manifest.
    let plain = consent_request("id", "X", &["storage".into()], &hosts(&["<all_urls>"]));
    assert_eq!(
        standing(true, Some(&plain.default_decision(1)), &plain.requests),
        ExtensionStanding::Running {
            held: 2,
            asked: 2,
            withheld: Withheld::Nothing,
        }
    );
}

// MARK: - Cannot and will not are different facts

/// The line that reads as a position rather than an apology. Its whole job is
/// to be unmistakable for the sentence below it, so this asserts both what it
/// says and what it does not: no "yet", and no blaming the engine for a
/// decision this browser made.
#[test]
fn a_permission_this_browser_declines_reads_as_a_position_rather_than_a_gap() {
    for key in [
        "management",
        "privacy",
        "contentSettings",
        "proxy",
        "debugger",
    ] {
        let request = consent_request("id", "X", &[key.into()], &[]);
        let described = request_for(key, &request).unwrap_or_else(|| panic!("{key}"));
        let stated = described
            .not_provided
            .unwrap_or_else(|| panic!("{key} is offered as a live switch"));

        let NotProvided::Declined { sentence } = &stated else {
            panic!("{key} reads as work nobody has done: {}", stated.sentence());
        };
        assert!(sentence.contains("will not"), "{key}: {sentence}");
        assert!(
            !sentence.contains("yet"),
            "{key} promises the refusal is temporary: {sentence}"
        );
        assert!(
            !sentence.contains("WebKit"),
            "{key} blames the engine for zer0's own decision: {sentence}"
        );
        assert!(
            !described.default_granted,
            "{key} arrived ticked despite being refused"
        );
    }
}

/// The other sentence, and the one word carrying the whole difference. A debt
/// that stopped saying "yet" would be indistinguishable from a refusal, which
/// is the state this pair of tests exists to leave behind.
#[test]
fn a_permission_nobody_has_built_yet_says_yet_and_promises_nothing_more() {
    for key in ["offscreen", "notifications", "identity", "sidePanel"] {
        let request = consent_request("id", "X", &[key.into()], &[]);
        let described = request_for(key, &request).unwrap_or_else(|| panic!("{key}"));
        let stated = described
            .not_provided
            .unwrap_or_else(|| panic!("{key} is offered as a live switch"));

        let NotProvided::NotBuiltYet { sentence } = &stated else {
            panic!("{key} reads as a refusal: {}", stated.sentence());
        };
        assert!(sentence.contains("yet"), "{key}: {sentence}");
        assert!(!sentence.contains("will not"), "{key}: {sentence}");
        // No date, and nothing that could become one.
        for promise in ["soon", "shortly", "next", "planned", "coming"] {
            assert!(!sentence.contains(promise), "{key} promises {promise}");
        }
    }
}

/// A position does not become a gap because an engine caught up.
///
/// This is written as disjointness rather than as ordering because that is the
/// moment the mistake is made: the day somebody re-measures `ENGINE_PROVIDES`
/// on a WebKit that ships `chrome.management` and adds the key, this goes red
/// and names it, instead of the refusal silently turning back into a switch.
#[test]
fn nothing_this_browser_declines_is_also_listed_as_something_it_provides() {
    for (key, _) in DECLINED {
        assert!(
            !ENGINE_PROVIDES.contains(&key),
            "{key} is refused and also listed as provided by the engine — decide which, in an ADR"
        );
        assert!(
            !ZER0_PROVIDES.contains(&key),
            "{key} is refused and also listed as answered by zer0"
        );
    }
}

/// The gate that survives a refactor of the views, for the kind of
/// not-provided that is a decision rather than a gap.
#[test]
fn a_declined_permission_is_never_recorded_as_granted() {
    let mut decision = ConsentDecision::refusing_everything("id", 0, Vec::new());
    for (key, _) in DECLINED {
        decision.allow(PermissionKind::Api, key);
        assert!(
            !decision.grants(PermissionKind::Api, key),
            "{key} was written into the ledger"
        );
    }
    assert!(decision.granted_permissions.is_empty());
}

/// The permissions zer0 answers itself keep a switch that means something, and
/// arrive ticked like everything else it can explain.
///
/// Without this, `ZER0_PROVIDES` could be emptied and every test above would
/// still pass over a browser that offers a sentence where the work already
/// exists.
#[test]
fn the_permissions_zer0_answers_itself_keep_their_switch() {
    for key in ZER0_PROVIDES {
        let request = consent_request("id", "X", &[key.into()], &[]);
        let described = request_for(key, &request).unwrap_or_else(|| panic!("{key}"));
        assert!(
            described.not_provided.is_none(),
            "{key} is answered by zer0 and still says it is not provided"
        );
        assert!(described.default_granted, "{key} arrived switched off");
        assert_ne!(described.risk, PermissionRisk::Unknown, "{key}");
    }
}
