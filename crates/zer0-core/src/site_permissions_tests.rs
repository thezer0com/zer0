//! Deliberately lopsided.
//!
//! There are two tests here about a request being allowed and a great many
//! about requests that must not be, because a permission prompt is only worth
//! having if refusing works — and because every refusal in [`gate`] is one the
//! page never sees a dialog for, which means nothing on screen would ever show
//! that it had stopped happening.

use super::*;
use crate::model::{Browser, SpaceProfile};
use crate::protocol::{Action, EngineCommand};
use crate::session::Session;

fn session() -> Session {
    let mut session = Session::new("Personal", "jar-personal");
    open(&mut session, None, "https://meet.example/");
    session
}

/// Through the reducer rather than through the model, so every test starts from
/// a browser that got where it is the way the browser does.
fn open(session: &mut Session, space: Option<SpaceId>, url: &str) -> TabId {
    crate::reducer::dispatch(
        session,
        Action::OpenTab {
            space,
            url: Some(url.to_string()),
            parent: None,
        },
    );
    tab_of(session)
}

fn add_space(session: &mut Session, name: &str) -> SpaceId {
    crate::reducer::dispatch(
        session,
        Action::CreateSpace {
            name: name.to_string(),
            data_store_id: format!("jar-{name}"),
            ephemeral: false,
        },
    );
    session.browser.active_space()
}

fn tab_of(session: &Session) -> TabId {
    session.browser.active_tab().expect("a tab")
}

fn origin(host: &str) -> ReportedOrigin {
    ReportedOrigin {
        scheme: "https".into(),
        host: host.into(),
        port: 0,
    }
}

fn request(tab: TabId, host: &str, capture: CaptureRequest) -> SitePermissionRequest {
    SitePermissionRequest {
        request: 1,
        tab,
        origin: origin(host),
        page_origin: origin(host),
        capture,
        asked_at_ms: 10_000,
    }
}

// MARK: - What an origin is

#[test]
fn a_default_port_is_not_part_of_the_key() {
    let bare = canonical_origin(&ReportedOrigin {
        scheme: "https".into(),
        host: "meet.example".into(),
        port: 0,
    });
    let explicit = canonical_origin(&ReportedOrigin {
        scheme: "https".into(),
        host: "meet.example".into(),
        port: 443,
    });

    assert_eq!(bare.as_deref(), Some("https://meet.example"));
    // Two spellings of one origin would be two grants, and taking one back in
    // Settings would leave the other holding the camera.
    assert_eq!(bare, explicit);
}

#[test]
fn a_port_that_is_not_the_default_is_a_different_site() {
    let one = canonical_origin(&ReportedOrigin {
        scheme: "https".into(),
        host: "localhost".into(),
        port: 8443,
    });
    let two = canonical_origin(&ReportedOrigin {
        scheme: "https".into(),
        host: "localhost".into(),
        port: 9443,
    });

    assert_eq!(one.as_deref(), Some("https://localhost:8443"));
    assert_ne!(one, two);
}

#[test]
fn an_internationalised_host_is_keyed_by_the_spelling_that_cannot_be_faked() {
    let punycode = canonical_origin(&ReportedOrigin {
        scheme: "https".into(),
        // Cyrillic а, е, о — draws as "аpple.com" and is not apple.com.
        host: "аpple.com".into(),
        port: 0,
    });

    let punycode = punycode.expect("a readable origin");
    assert!(
        punycode.starts_with("https://xn--"),
        "an IDN keyed by its display form is an IDN somebody can impersonate: {punycode}"
    );
    assert_ne!(punycode, "https://apple.com");
}

#[test]
fn the_shapes_that_are_not_origins_are_all_refused() {
    // Every one of these is a shape a real page can have, and every one of them
    // is shared by documents that have nothing to do with each other. A grant
    // to any of them is a grant to all of them.
    let refused = [
        ReportedOrigin {
            scheme: "file".into(),
            host: String::new(),
            port: 0,
        },
        ReportedOrigin {
            scheme: String::new(),
            host: String::new(),
            port: 0,
        },
        ReportedOrigin {
            scheme: "data".into(),
            host: String::new(),
            port: 0,
        },
        ReportedOrigin {
            scheme: "https".into(),
            host: String::new(),
            port: 0,
        },
        ReportedOrigin {
            scheme: "about".into(),
            host: "blank".into(),
            port: 0,
        },
        ReportedOrigin {
            scheme: "zer0".into(),
            host: "settings".into(),
            port: 0,
        },
        ReportedOrigin {
            scheme: "blob".into(),
            host: "example.com".into(),
            port: 0,
        },
    ];

    for shape in refused {
        assert_eq!(
            canonical_origin(&shape),
            None,
            "{shape:?} was read as an origin"
        );
    }
}

#[test]
fn a_pages_url_and_a_reported_origin_agree_on_the_same_key() {
    // If these two ever disagree, a grant recorded from a prompt could never be
    // matched against the tab it was given for — so revoking would find no tab
    // to stop capture on.
    assert_eq!(
        origin_of("https://meet.example/room/42?x=1#top").as_deref(),
        canonical_origin(&origin("meet.example")).as_deref()
    );
}

// MARK: - Nothing is granted without an answer

#[test]
fn an_undecided_site_is_asked_about_rather_than_answered() {
    let session = session();
    let tab = tab_of(&session);

    match gate(
        &session.browser,
        &session.site_permissions,
        &request(tab, "meet.example", CaptureRequest::Camera),
    ) {
        Gate::Ask(prompt) => {
            assert_eq!(prompt.origin, "https://meet.example");
            assert_eq!(prompt.request, 1);
        }
        other => panic!("expected a question, got {other:?}"),
    }
}

#[test]
fn nothing_is_granted_until_somebody_answers() {
    let mut session = session();
    let tab = tab_of(&session);
    let space = session.browser.active_space();

    crate::reducer::dispatch(
        &mut session,
        Action::SitePermissionRequested {
            request: request(tab, "meet.example", CaptureRequest::Camera),
        },
    );

    // The prompt is up and the ledger is empty. Nothing anywhere says yes.
    assert!(session.site_permissions.pending().is_some());
    assert_eq!(
        session
            .site_permissions
            .verdict(space, "https://meet.example", SiteCapability::Camera),
        SiteVerdict::Undecided
    );
}

#[test]
fn an_answer_arriving_faster_than_a_person_could_give_it_is_ignored() {
    let mut session = session();
    let tab = tab_of(&session);
    let space = session.browser.active_space();
    crate::reducer::dispatch(
        &mut session,
        Action::SitePermissionRequested {
            request: request(tab, "meet.example", CaptureRequest::Camera),
        },
    );

    // A keystroke already on its way down when the sheet took the keyboard.
    let commands = crate::reducer::dispatch(
        &mut session,
        Action::DecideSitePermission {
            request: 1,
            choice: SiteChoice::Allow,
            decided_at_ms: 10_000 + PROMPT_SETTLE_MS - 1,
        },
    );

    assert!(commands.is_empty(), "the engine was answered by a race");
    assert!(
        session.site_permissions.pending().is_some(),
        "the question has to still be on screen, or the race silently refused it"
    );
    assert_eq!(
        session
            .site_permissions
            .verdict(space, "https://meet.example", SiteCapability::Camera),
        SiteVerdict::Undecided
    );
}

#[test]
fn an_answer_from_somebody_who_read_it_lands() {
    let mut session = session();
    let tab = tab_of(&session);
    let space = session.browser.active_space();
    crate::reducer::dispatch(
        &mut session,
        Action::SitePermissionRequested {
            request: request(tab, "meet.example", CaptureRequest::Camera),
        },
    );

    let commands = crate::reducer::dispatch(
        &mut session,
        Action::DecideSitePermission {
            request: 1,
            choice: SiteChoice::Allow,
            decided_at_ms: 10_000 + PROMPT_SETTLE_MS,
        },
    );

    assert!(commands.contains(&EngineCommand::AnswerSitePermission {
        request: 1,
        decision: SiteDecision::Allow,
    }));
    assert_eq!(
        session
            .site_permissions
            .verdict(space, "https://meet.example", SiteCapability::Camera),
        SiteVerdict::Allowed
    );
    assert!(session.site_permissions.pending().is_none());
}

#[test]
fn an_answer_to_a_question_nobody_asked_answers_nothing() {
    let mut session = session();

    let commands = crate::reducer::dispatch(
        &mut session,
        Action::DecideSitePermission {
            request: 99,
            choice: SiteChoice::Allow,
            decided_at_ms: 20_000,
        },
    );

    assert!(commands.is_empty());
    assert!(session.site_permissions.all().is_empty());
}

// MARK: - A refusal is a refusal

#[test]
fn a_second_request_for_something_already_refused_is_answered_without_asking() {
    let mut session = session();
    let tab = tab_of(&session);
    crate::reducer::dispatch(
        &mut session,
        Action::SitePermissionRequested {
            request: request(tab, "meet.example", CaptureRequest::Camera),
        },
    );
    crate::reducer::dispatch(
        &mut session,
        Action::DecideSitePermission {
            request: 1,
            choice: SiteChoice::Block,
            decided_at_ms: 20_000,
        },
    );

    let mut again = request(tab, "meet.example", CaptureRequest::Camera);
    again.request = 2;
    again.asked_at_ms = 30_000;
    let commands = crate::reducer::dispatch(
        &mut session,
        Action::SitePermissionRequested { request: again },
    );

    assert!(commands.contains(&EngineCommand::AnswerSitePermission {
        request: 2,
        decision: SiteDecision::Deny,
    }));
    assert!(
        session.site_permissions.pending().is_none(),
        "a refused site that gets a second dialog is a site that has learned to keep asking"
    );
}

#[test]
fn a_dismissal_answers_the_page_and_writes_nothing_down() {
    let mut session = session();
    let tab = tab_of(&session);
    let space = session.browser.active_space();
    crate::reducer::dispatch(
        &mut session,
        Action::SitePermissionRequested {
            request: request(tab, "meet.example", CaptureRequest::Camera),
        },
    );

    let commands = crate::reducer::dispatch(
        &mut session,
        Action::DecideSitePermission {
            request: 1,
            choice: SiteChoice::Dismiss,
            decided_at_ms: 20_000,
        },
    );

    // Told no, so the page's promise settles rather than hanging.
    assert!(commands.contains(&EngineCommand::AnswerSitePermission {
        request: 1,
        decision: SiteDecision::Deny,
    }));
    // And closing a window is not an instruction, so nothing is remembered.
    assert!(session.site_permissions.all().is_empty());
    assert_eq!(
        session
            .site_permissions
            .verdict(space, "https://meet.example", SiteCapability::Camera),
        SiteVerdict::Undecided
    );
}

#[test]
fn a_dismissed_question_is_not_asked_again_until_the_page_changes() {
    let mut session = session();
    let tab = tab_of(&session);
    crate::reducer::dispatch(
        &mut session,
        Action::SitePermissionRequested {
            request: request(tab, "meet.example", CaptureRequest::Camera),
        },
    );
    crate::reducer::dispatch(
        &mut session,
        Action::DecideSitePermission {
            request: 1,
            choice: SiteChoice::Dismiss,
            decided_at_ms: 20_000,
        },
    );

    // Escape has to cost the page something, or the page just asks again on the
    // next frame and Escape becomes a key you hold down.
    let mut again = request(tab, "meet.example", CaptureRequest::Camera);
    again.request = 2;
    crate::reducer::dispatch(
        &mut session,
        Action::SitePermissionRequested { request: again },
    );
    assert!(session.site_permissions.pending().is_none());

    // A new page in the tab is a new question, so the mute goes.
    crate::reducer::dispatch(
        &mut session,
        Action::NavigationCommitted {
            tab,
            url: "https://meet.example/room/2".into(),
        },
    );
    let mut third = request(tab, "meet.example", CaptureRequest::Camera);
    third.request = 3;
    crate::reducer::dispatch(
        &mut session,
        Action::SitePermissionRequested { request: third },
    );
    assert!(session.site_permissions.pending().is_some());
}

#[test]
fn a_page_you_are_not_looking_at_is_refused_without_a_dialog() {
    let mut session = session();
    let background = tab_of(&session);
    let space = session.browser.active_space();
    open(&mut session, Some(space), "https://elsewhere.example/");
    assert_ne!(session.browser.active_tab(), Some(background));

    let commands = crate::reducer::dispatch(
        &mut session,
        Action::SitePermissionRequested {
            request: request(background, "meet.example", CaptureRequest::Camera),
        },
    );

    assert!(commands.contains(&EngineCommand::AnswerSitePermission {
        request: 1,
        decision: SiteDecision::Deny,
    }));
    assert!(
        session.site_permissions.pending().is_none(),
        "a background tab that can raise a sheet is a background tab that can steal an answer"
    );
}

#[test]
fn a_pane_of_a_split_is_a_page_you_are_looking_at() {
    let mut session = session();
    let first = tab_of(&session);
    crate::reducer::dispatch(&mut session, Action::ToggleSplit);
    let split = session
        .browser
        .space(session.browser.active_space())
        .and_then(|s| s.split.clone())
        .expect("a split");
    let other = if split.leading == first {
        split.trailing
    } else {
        split.leading
    };
    crate::reducer::dispatch(&mut session, Action::ActivateTab { tab: first });

    match gate(
        &session.browser,
        &session.site_permissions,
        &request(other, "meet.example", CaptureRequest::Camera),
    ) {
        Gate::Ask(_) => {}
        other => panic!("the visible half of a split was refused: {other:?}"),
    }
}

#[test]
fn a_second_question_is_refused_rather_than_stacked() {
    let mut session = session();
    let tab = tab_of(&session);
    crate::reducer::dispatch(
        &mut session,
        Action::SitePermissionRequested {
            request: request(tab, "meet.example", CaptureRequest::Camera),
        },
    );
    let first = session
        .site_permissions
        .pending()
        .cloned()
        .expect("a question");

    let mut second = request(tab, "meet.example", CaptureRequest::Microphone);
    second.request = 2;
    let commands = crate::reducer::dispatch(
        &mut session,
        Action::SitePermissionRequested { request: second },
    );

    assert!(commands.contains(&EngineCommand::AnswerSitePermission {
        request: 2,
        decision: SiteDecision::Deny,
    }));
    assert_eq!(
        session.site_permissions.pending(),
        Some(&first),
        "a queue of consent dialogs is the same click-through machine with a waiting room"
    );
}

#[test]
fn an_unreadable_origin_is_refused_and_never_written_down() {
    let mut session = session();
    let tab = tab_of(&session);
    let mut hostile = request(tab, "meet.example", CaptureRequest::Camera);
    hostile.origin = ReportedOrigin {
        scheme: "file".into(),
        host: String::new(),
        port: 0,
    };

    let commands = crate::reducer::dispatch(
        &mut session,
        Action::SitePermissionRequested { request: hostile },
    );

    assert!(commands.contains(&EngineCommand::AnswerSitePermission {
        request: 1,
        decision: SiteDecision::Deny,
    }));
    assert!(session.site_permissions.pending().is_none());
    assert!(session.site_permissions.all().is_empty());
}

#[test]
fn a_tab_that_went_away_is_answered_rather_than_left_hanging() {
    let mut session = session();
    let tab = tab_of(&session);
    let commands = crate::reducer::dispatch(
        &mut session,
        Action::SitePermissionRequested {
            request: request(TabId(tab.0 + 500), "meet.example", CaptureRequest::Camera),
        },
    );

    // The one thing that must never happen is silence: the host is holding a
    // decision handler, and a promise nobody settles is a page that spins.
    assert!(commands.contains(&EngineCommand::AnswerSitePermission {
        request: 1,
        decision: SiteDecision::Deny,
    }));
}

#[test]
fn closing_a_tab_answers_the_question_it_was_asking() {
    let mut session = session();
    let tab = tab_of(&session);
    crate::reducer::dispatch(
        &mut session,
        Action::SitePermissionRequested {
            request: request(tab, "meet.example", CaptureRequest::Camera),
        },
    );

    let commands = crate::reducer::dispatch(&mut session, Action::CloseTab { tab });

    assert!(commands.contains(&EngineCommand::AnswerSitePermission {
        request: 1,
        decision: SiteDecision::Deny,
    }));
    assert!(session.site_permissions.pending().is_none());
}

// MARK: - Half a grant is not a grant

#[test]
fn holding_one_half_of_a_pair_still_asks_about_the_other() {
    let mut session = session();
    let tab = tab_of(&session);
    let space = session.browser.active_space();
    session.site_permissions.record(
        space,
        "https://meet.example",
        SiteCapability::Microphone,
        true,
        1_000,
    );

    match gate(
        &session.browser,
        &session.site_permissions,
        &request(tab, "meet.example", CaptureRequest::CameraAndMicrophone),
    ) {
        Gate::Ask(prompt) => assert_eq!(prompt.capture, CaptureRequest::CameraAndMicrophone),
        other => panic!("a microphone grant answered for a camera: {other:?}"),
    }
}

#[test]
fn refusing_one_half_of_a_pair_refuses_the_pair() {
    let mut session = session();
    let tab = tab_of(&session);
    let space = session.browser.active_space();
    session.site_permissions.record(
        space,
        "https://meet.example",
        SiteCapability::Camera,
        true,
        1_000,
    );
    session.site_permissions.record(
        space,
        "https://meet.example",
        SiteCapability::Microphone,
        false,
        1_000,
    );

    assert_eq!(
        gate(
            &session.browser,
            &session.site_permissions,
            &request(tab, "meet.example", CaptureRequest::CameraAndMicrophone),
        ),
        Gate::Answer(SiteDecision::Deny)
    );
}

#[test]
fn both_halves_granted_answers_the_pair_without_asking_again() {
    let mut session = session();
    let tab = tab_of(&session);
    let space = session.browser.active_space();
    for capability in [SiteCapability::Camera, SiteCapability::Microphone] {
        session
            .site_permissions
            .record(space, "https://meet.example", capability, true, 1_000);
    }

    assert_eq!(
        gate(
            &session.browser,
            &session.site_permissions,
            &request(tab, "meet.example", CaptureRequest::CameraAndMicrophone),
        ),
        Gate::Answer(SiteDecision::Allow)
    );
}

// MARK: - A grant belongs to a Space

#[test]
fn an_answer_given_in_one_space_does_not_follow_you_into_another() {
    let mut session = session();
    let personal = session.browser.active_space();
    session.site_permissions.record(
        personal,
        "https://meet.example",
        SiteCapability::Camera,
        true,
        1_000,
    );

    let work = add_space(&mut session, "Work");
    let tab = open(&mut session, Some(work), "https://meet.example/");

    // Same site, different identity. ADR-0007 makes a Space a cookie jar, and a
    // cookie jar is who you are signed in as.
    match gate(
        &session.browser,
        &session.site_permissions,
        &request(tab, "meet.example", CaptureRequest::Camera),
    ) {
        Gate::Ask(_) => {}
        other => panic!("a work grant answered for a personal one: {other:?}"),
    }
}

#[test]
fn a_refusal_in_one_space_does_not_refuse_for_another() {
    let mut session = session();
    let personal = session.browser.active_space();
    session.site_permissions.record(
        personal,
        "https://meet.example",
        SiteCapability::Camera,
        false,
        1_000,
    );

    let work = add_space(&mut session, "Work");

    assert_eq!(
        session
            .site_permissions
            .verdict(work, "https://meet.example", SiteCapability::Camera),
        SiteVerdict::Undecided
    );
}

#[test]
fn closing_a_space_takes_its_answers_with_it() {
    let mut session = session();
    let personal = session.browser.active_space();
    let work = add_space(&mut session, "Work");
    session.site_permissions.record(
        work,
        "https://meet.example",
        SiteCapability::Camera,
        true,
        1_000,
    );
    session.site_permissions.record(
        personal,
        "https://meet.example",
        SiteCapability::Camera,
        true,
        1_000,
    );

    crate::reducer::dispatch(&mut session, Action::CloseSpace { space: work });

    // The jar is deleted with no undo (ADR-0007). A grant that outlived it
    // would be an approval for an account that no longer exists.
    assert_eq!(
        session
            .site_permissions
            .verdict(work, "https://meet.example", SiteCapability::Camera),
        SiteVerdict::Undecided
    );
    assert_eq!(
        session
            .site_permissions
            .verdict(personal, "https://meet.example", SiteCapability::Camera),
        SiteVerdict::Allowed
    );
}

// MARK: - Taking it back

#[test]
fn revoking_reaches_every_tab_that_is_on_the_site() {
    let mut session = session();
    let space = session.browser.active_space();
    let watching = tab_of(&session);
    let elsewhere = open(&mut session, Some(space), "https://elsewhere.example/");
    session.site_permissions.record(
        space,
        "https://meet.example",
        SiteCapability::Camera,
        true,
        1_000,
    );
    // The tab's committed address, which is what a live capture is attached to.
    crate::reducer::dispatch(
        &mut session,
        Action::NavigationCommitted {
            tab: watching,
            url: "https://meet.example/room/1".into(),
        },
    );

    let commands = crate::reducer::dispatch(
        &mut session,
        Action::SetSitePermission {
            space,
            origin: "https://meet.example".into(),
            capability: SiteCapability::Camera,
            allowed: false,
            decided_at_ms: 30_000,
        },
    );

    // A revoke that repaints a row and leaves the camera on is the exact lie
    // this screen exists to end (ADR-0028).
    assert!(commands.contains(&EngineCommand::StopCapture {
        tab: watching,
        capability: SiteCapability::Camera,
    }));
    assert!(!commands.contains(&EngineCommand::StopCapture {
        tab: elsewhere,
        capability: SiteCapability::Camera,
    }));
    assert_eq!(
        session
            .site_permissions
            .verdict(space, "https://meet.example", SiteCapability::Camera),
        SiteVerdict::Refused
    );
}

#[test]
fn blocking_from_the_sheet_also_stops_whatever_is_running() {
    let mut session = session();
    let tab = tab_of(&session);
    crate::reducer::dispatch(
        &mut session,
        Action::NavigationCommitted {
            tab,
            url: "https://meet.example/room/1".into(),
        },
    );
    crate::reducer::dispatch(
        &mut session,
        Action::SitePermissionRequested {
            request: request(tab, "meet.example", CaptureRequest::CameraAndMicrophone),
        },
    );

    let commands = crate::reducer::dispatch(
        &mut session,
        Action::DecideSitePermission {
            request: 1,
            choice: SiteChoice::Block,
            decided_at_ms: 20_000,
        },
    );

    for capability in [SiteCapability::Camera, SiteCapability::Microphone] {
        assert!(
            commands.contains(&EngineCommand::StopCapture { tab, capability }),
            "{capability:?} was refused and left running"
        );
    }
}

#[test]
fn forgetting_an_answer_asks_again_rather_than_refusing() {
    let mut session = session();
    let tab = tab_of(&session);
    let space = session.browser.active_space();
    session.site_permissions.record(
        space,
        "https://meet.example",
        SiteCapability::Camera,
        true,
        1_000,
    );

    crate::reducer::dispatch(
        &mut session,
        Action::ForgetSitePermission {
            space,
            origin: "https://meet.example".into(),
            capability: SiteCapability::Camera,
        },
    );

    // "Ask me again" and "stop letting it" are different things to want, and
    // the screen offers both.
    match gate(
        &session.browser,
        &session.site_permissions,
        &request(tab, "meet.example", CaptureRequest::Camera),
    ) {
        Gate::Ask(_) => {}
        other => panic!("expected the question back, got {other:?}"),
    }
}

// MARK: - The words

#[test]
fn a_camera_is_described_by_what_it_costs_you_not_by_its_name() {
    let session = session();
    let tab = tab_of(&session);

    let Gate::Ask(prompt) = gate(
        &session.browser,
        &session.site_permissions,
        &request(tab, "meet.example", CaptureRequest::Camera),
    ) else {
        panic!("expected a question")
    };

    // Nothing goes red when "Let meet.example see through your camera" becomes
    // "Allow camera access", and the second one is a phrase that has never
    // stopped anybody. See ADR-0018.
    assert_eq!(prompt.title, "Let meet.example see through your camera");
    assert!(prompt.detail.contains("watch and record"));
    // A recording light is a property of the hardware, and an external webcam
    // may have none. We say only what we can prove.
    assert!(!prompt.detail.to_lowercase().contains("light"));
}

#[test]
fn the_prompt_says_which_space_the_answer_is_for() {
    let session = session();
    let tab = tab_of(&session);

    let Gate::Ask(prompt) = gate(
        &session.browser,
        &session.site_permissions,
        &request(tab, "meet.example", CaptureRequest::Camera),
    ) else {
        panic!("expected a question")
    };

    // "Per site" is what everybody expects and it is not what this does, so the
    // sheet has to say so where the answer is given.
    assert!(prompt.scope_note.contains("Personal"));
}

#[test]
fn a_frame_asking_from_inside_someone_elses_page_says_so() {
    let session = session();
    let tab = tab_of(&session);
    let mut embedded = request(tab, "ads.example", CaptureRequest::Camera);
    embedded.page_origin = origin("news.example");

    let Gate::Ask(prompt) = gate(&session.browser, &session.site_permissions, &embedded) else {
        panic!("expected a question")
    };

    // The trick this defends against: a sheet appears over a site you trust and
    // the name on it is not the name you would have read.
    assert_eq!(prompt.origin, "https://ads.example");
    assert_eq!(prompt.host, "ads.example");
    let note = prompt
        .embedded_note
        .expect("a note naming the page it was inside");
    // It names the page you thought you were on. The site that actually asked
    // is on the prompt itself, said once, where the sheet prints it verbatim —
    // saying it twice is what made the sentence wrap through the middle of a
    // URL.
    assert!(note.contains("news.example"));
    assert!(!note.contains("ads.example"));
}

#[test]
fn a_top_level_request_says_nothing_about_embedding() {
    let session = session();
    let tab = tab_of(&session);

    let Gate::Ask(prompt) = gate(
        &session.browser,
        &session.site_permissions,
        &request(tab, "meet.example", CaptureRequest::Camera),
    ) else {
        panic!("expected a question")
    };

    assert_eq!(prompt.embedded_note, None);
}

#[test]
fn a_grant_from_an_embedded_frame_belongs_to_the_frame_and_not_the_page() {
    let mut session = session();
    let tab = tab_of(&session);
    let space = session.browser.active_space();
    let mut embedded = request(tab, "ads.example", CaptureRequest::Camera);
    embedded.page_origin = origin("news.example");
    crate::reducer::dispatch(
        &mut session,
        Action::SitePermissionRequested { request: embedded },
    );
    crate::reducer::dispatch(
        &mut session,
        Action::DecideSitePermission {
            request: 1,
            choice: SiteChoice::Allow,
            decided_at_ms: 20_000,
        },
    );

    assert_eq!(
        session
            .site_permissions
            .verdict(space, "https://ads.example", SiteCapability::Camera),
        SiteVerdict::Allowed
    );
    // Granting the page around it would hand the camera to a site nobody was
    // asked about.
    assert_eq!(
        session
            .site_permissions
            .verdict(space, "https://news.example", SiteCapability::Camera),
        SiteVerdict::Undecided
    );
}

// MARK: - An ephemeral space

#[test]
fn an_ephemeral_space_answers_within_the_run_and_writes_nothing_down() {
    let mut session = session();
    let space = session.browser.active_space();
    crate::reducer::dispatch(
        &mut session,
        Action::SetSpaceProfile {
            space,
            profile: SpaceProfile {
                user_agent: None,
                ephemeral: true,
            },
        },
    );
    session.site_permissions.record(
        space,
        "https://meet.example",
        SiteCapability::Camera,
        true,
        1_000,
    );

    // It works while you are in it — a video call in a throwaway space is still
    // a video call.
    assert_eq!(
        session
            .site_permissions
            .verdict(space, "https://meet.example", SiteCapability::Camera),
        SiteVerdict::Allowed
    );
    // What must not happen is on the way out; see `storable_tests.rs`.
    assert_eq!(session.site_permissions.all().len(), 1);
}

// MARK: - The settle window itself

#[test]
fn the_settle_window_is_measured_from_the_question() {
    assert!(answered_too_soon(1_000, 1_000));
    assert!(answered_too_soon(1_000, 1_000 + PROMPT_SETTLE_MS - 1));
    assert!(!answered_too_soon(1_000, 1_000 + PROMPT_SETTLE_MS));
    // A clock that stepped backwards reads as "too soon" rather than as an
    // enormous gap, which costs a second click and never a camera.
    assert!(answered_too_soon(5_000, 1_000));
}

/// A `Browser` with nothing in it is what a fresh session looks like before the
/// shell opens anything, and a request arriving then must not panic.
#[test]
fn a_browser_with_no_tabs_refuses_rather_than_falls_over() {
    let browser = Browser::new("Personal", "jar");
    let permissions = SitePermissions::new();

    assert_eq!(
        gate(
            &browser,
            &permissions,
            &request(TabId(1), "meet.example", CaptureRequest::Camera)
        ),
        Gate::Answer(SiteDecision::Deny)
    );
}
