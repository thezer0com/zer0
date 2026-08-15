//! Lopsided on purpose, the same way [`crate::site_permissions`]'s tests are.
//!
//! A password panel is only worth having if the refusals work, and every
//! refusal in [`gate`] is one nobody ever sees a panel for — so nothing on any
//! screen would show that one had stopped happening.

use super::*;
use crate::model::{SpaceId, SpaceProfile};
use crate::protocol::Action;
use crate::session::Session;

fn session() -> Session {
    let mut session = Session::new("Personal", "jar-personal");
    open(&mut session, None, "https://staging.example/");
    session
}

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

fn tab_of(session: &Session) -> TabId {
    session.browser.active_tab().expect("a tab")
}

fn ephemeral_space(session: &mut Session) -> SpaceId {
    crate::reducer::dispatch(
        session,
        Action::CreateSpace {
            name: "Throwaway".into(),
            data_store_id: "jar-throwaway".into(),
            ephemeral: true,
        },
    );
    session.browser.active_space()
}

fn origin(scheme: &str, host: &str) -> ReportedOrigin {
    ReportedOrigin {
        scheme: scheme.into(),
        host: host.into(),
        port: 0,
    }
}

fn request(tab: TabId, host: &str) -> HttpAuthRequest {
    HttpAuthRequest {
        request: 1,
        tab,
        scheme: HttpAuthScheme::Basic,
        origin: origin("https", host),
        realm: Some("Staging".into()),
        previous_failures: 0,
        is_proxy: false,
        asked_at_ms: 1_000,
    }
}

fn ask(session: &Session, request: &HttpAuthRequest) -> AuthGate {
    gate(&session.browser, &session.http_auth, request)
}

fn prompt(session: &Session, request: &HttpAuthRequest) -> AuthPrompt {
    match ask(session, request) {
        AuthGate::Ask(prompt) => *prompt,
        AuthGate::Answer(decision) => panic!("expected a panel, got {decision:?}"),
    }
}

// --- the one case that asks ------------------------------------------------

#[test]
fn a_server_asking_the_page_you_are_looking_at_gets_a_panel() {
    let session = session();
    let tab = tab_of(&session);
    let prompt = prompt(&session, &request(tab, "staging.example"));

    assert_eq!(prompt.origin, "https://staging.example");
    assert_eq!(prompt.host, "staging.example");
    assert!(prompt.title.contains("staging.example"));
    assert!(prompt.may_remember);
    assert!(prompt.insecure_note.is_none());
    assert!(prompt.retry_note.is_none());
    assert!(prompt.proxy_note.is_none());
}

// --- everything that must not ask -------------------------------------------

#[test]
fn nothing_here_can_produce_a_credential_on_its_own() {
    // The property that makes "a page cannot get itself signed in" structural
    // rather than careful: every silent answer `gate` can give is a refusal.
    // Read off the source of this module, because the claim is about the shape
    // of the code and no single call can observe it.
    let source = include_str!("http_auth.rs");
    assert!(
        !source.contains("AuthGate::Answer(AuthDecision::UseCredential)"),
        "gate answered with a credential without anybody being asked"
    );
}

#[test]
fn a_page_you_are_not_looking_at_is_refused_without_a_panel() {
    let mut session = session();
    let background = tab_of(&session);
    open(&mut session, None, "https://elsewhere.example/");

    assert_eq!(
        ask(&session, &request(background, "staging.example")),
        AuthGate::Answer(AuthDecision::Cancel),
        "a background tab put a password panel in front of the page being read"
    );
}

#[test]
fn a_second_challenge_is_refused_rather_than_stacked() {
    let mut session = session();
    let tab = tab_of(&session);
    let first = request(tab, "staging.example");
    session.http_auth.raise(prompt(&session, &first));

    let mut second = request(tab, "staging.example");
    second.request = 2;
    assert_eq!(
        ask(&session, &second),
        AuthGate::Answer(AuthDecision::Cancel),
        "a page with many subresources behind one realm stacked panels"
    );
}

#[test]
fn a_server_that_keeps_saying_no_stops_being_asked_about() {
    let session = session();
    let tab = tab_of(&session);

    for failures in 0..MAX_FAILURES {
        let mut asking = request(tab, "staging.example");
        asking.previous_failures = failures;
        assert!(
            matches!(ask(&session, &asking), AuthGate::Ask(_)),
            "gave up after {failures} refusals, before a mistyped password could be fixed"
        );
    }

    let mut exhausted = request(tab, "staging.example");
    exhausted.previous_failures = MAX_FAILURES;
    assert_eq!(
        ask(&session, &exhausted),
        AuthGate::Answer(AuthDecision::Cancel),
        "the panel came back forever, which is how a real password gets typed into it"
    );
}

#[test]
fn the_shapes_that_are_not_origins_are_all_refused() {
    let session = session();
    let tab = tab_of(&session);

    for (scheme, host) in [
        ("file", ""),
        ("data", ""),
        ("", "staging.example"),
        ("ftp", "staging.example"),
        ("javascript", "staging.example"),
        ("https", ""),
        ("zer0", "settings"),
    ] {
        let mut asking = request(tab, "staging.example");
        asking.origin = origin(scheme, host);
        assert_eq!(
            ask(&session, &asking),
            AuthGate::Answer(AuthDecision::Cancel),
            "{scheme}://{host} was treated as somewhere a password belongs"
        );
    }
}

#[test]
fn a_scheme_whose_answer_is_not_a_password_is_refused_rather_than_asked_about() {
    let session = session();
    let tab = tab_of(&session);
    let mut asking = request(tab, "staging.example");
    asking.scheme = HttpAuthScheme::Other;

    assert_eq!(
        ask(&session, &asking),
        AuthGate::Answer(AuthDecision::Cancel),
        "a client-certificate request drew a username field"
    );
}

#[test]
fn a_challenge_for_a_tab_that_is_gone_is_answered_rather_than_dropped() {
    let session = session();
    let tab = tab_of(&session);
    let mut asking = request(tab, "staging.example");
    asking.tab = TabId(9_999);

    assert_eq!(
        ask(&session, &asking),
        AuthGate::Answer(AuthDecision::Cancel),
        "a navigation was left hanging with no answer at all"
    );
}

// --- what may be written down -----------------------------------------------

#[test]
fn a_password_going_out_in_the_clear_is_said_so_and_never_offered_to_be_kept() {
    let mut session = Session::new("Personal", "jar-personal");
    open(&mut session, None, "http://router.example/");
    let tab = tab_of(&session);

    let mut asking = request(tab, "router.example");
    asking.origin = origin("http", "router.example");
    let prompt = prompt(&session, &asking);

    assert!(
        prompt.insecure_note.is_some(),
        "an unencrypted sign-in said nothing about being unencrypted"
    );
    assert!(
        !prompt.may_remember,
        "offered to write down a password it had just watched go out in the clear"
    );
    assert_eq!(keychain_origin(&prompt), None);
}

#[test]
fn a_loopback_sign_in_is_neither_warned_about_nor_refused_a_keychain_item() {
    // Where anybody building a server actually works. There is no network
    // between the two ends, so the sentence about being read in transit would
    // be a warning about something that cannot happen (ADR-0018).
    for host in ["localhost", "127.0.0.1", "dev.localhost", "[::1]"] {
        let mut session = Session::new("Personal", "jar-personal");
        open(&mut session, None, &format!("http://{host}/"));
        let tab = tab_of(&session);

        let mut asking = request(tab, host);
        asking.origin = origin("http", host);
        let prompt = prompt(&session, &asking);

        assert!(prompt.insecure_note.is_none(), "{host} was warned about");
        assert!(prompt.may_remember, "{host} could not be remembered");
    }
}

#[test]
fn an_ephemeral_space_is_never_offered_the_chance_to_write_one_down() {
    let mut session = session();
    let space = ephemeral_space(&mut session);
    let tab = open(&mut session, Some(space), "https://staging.example/");

    let prompt = prompt(&session, &request(tab, "staging.example"));
    assert!(
        !prompt.may_remember,
        "a space that promised to leave nothing behind offered to keep a password"
    );
    assert_eq!(keychain_origin(&prompt), None);
}

#[test]
fn a_proxy_is_named_as_one_and_nothing_is_kept_for_it() {
    let session = session();
    let tab = tab_of(&session);
    let mut asking = request(tab, "proxy.example");
    asking.is_proxy = true;

    let prompt = prompt(&session, &asking);
    assert!(prompt.proxy_note.is_some());
    assert!(
        !prompt.may_remember,
        "a proxy credential was keyed to a site it does not belong to"
    );
    assert_eq!(keychain_origin(&prompt), None);
}

#[test]
fn an_internationalised_host_is_keyed_by_the_spelling_that_cannot_be_faked() {
    let mut session = Session::new("Personal", "jar-personal");
    open(&mut session, None, "https://example.com/");
    let tab = tab_of(&session);

    let mut asking = request(tab, "аррӏе.com");
    asking.origin = origin("https", "аррӏе.com");
    let prompt = prompt(&session, &asking);

    assert!(
        prompt.host.starts_with("xn--"),
        "a Cyrillic lookalike drew as its Latin spelling: {}",
        prompt.host
    );
}

// --- the realm is the server's text -----------------------------------------

#[test]
fn the_servers_realm_is_carried_apart_from_every_sentence_we_wrote() {
    let session = session();
    let tab = tab_of(&session);
    let mut asking = request(tab, "staging.example");
    // Measured off a real server: what reaches the delegate keeps its markup.
    asking.realm = Some("Staging <script>alert(1)</script>".into());

    let prompt = prompt(&session, &asking);
    assert_eq!(
        prompt.realm.as_deref(),
        Some("Staging <script>alert(1)</script>")
    );
    for ours in [&prompt.title, &prompt.detail, &prompt.scope_note] {
        assert!(
            !ours.contains("script"),
            "the server's own text was folded into a sentence zer0 wrote: {ours}"
        );
    }
}

#[test]
fn a_realm_cannot_draw_itself_as_a_second_line_or_push_the_buttons_off() {
    assert_eq!(readable_realm(Some("one\ntwo")), Some("onetwo".to_string()));
    assert_eq!(
        readable_realm(Some("a\r\nzer0 says:")),
        Some("azer0 says:".to_string())
    );
    assert_eq!(readable_realm(Some("   ")), None);
    assert_eq!(readable_realm(Some("")), None);
    assert_eq!(readable_realm(None), None);

    let long = readable_realm(Some(&"x".repeat(1000))).expect("a realm");
    assert_eq!(long.chars().count(), MAX_REALM);
}

// --- the pending question ---------------------------------------------------

#[test]
fn an_answer_to_a_panel_that_was_already_replaced_answers_nothing() {
    let mut auth = HttpAuth::new();
    let session = session();
    let tab = tab_of(&session);
    auth.raise(prompt(&session, &request(tab, "staging.example")));

    assert!(
        auth.take_pending(99).is_none(),
        "a stale answer settled a live question"
    );
    assert!(auth.take_pending(1).is_some());
    assert!(auth.pending().is_none());
}

#[test]
fn a_closing_tab_gives_up_the_question_it_was_asking() {
    let mut auth = HttpAuth::new();
    let session = session();
    let tab = tab_of(&session);
    auth.raise(prompt(&session, &request(tab, "staging.example")));

    assert!(auth.drop_pending_for(TabId(9_999)).is_none());
    assert!(
        auth.drop_pending_for(tab).is_some(),
        "the engine was left holding a completion handler for a view that is gone"
    );
}

#[test]
fn a_space_profile_is_what_decides_whether_anything_is_written_down() {
    // Guards the seam rather than the branch: `may_remember` asks the browser
    // through `records_to_disk`, which is the one door ADR-0023 named. A
    // second copy of the ephemeral test in this file would be the debt that
    // ADR names, moved somewhere new.
    let mut session = session();
    let space = ephemeral_space(&mut session);
    assert!(!session.browser.records_to_disk(space));
    assert!(session.browser.space(space).is_some_and(|s| {
        s.profile
            == SpaceProfile {
                ephemeral: true,
                user_agent: s.profile.user_agent.clone(),
            }
    }));
}
