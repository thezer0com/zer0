//! What a backend is allowed to be handed.
//!
//! These are the locks that used to live in the SQLite suite, and the reason
//! they moved: an assertion about `Store` proves the ephemeral rule holds in
//! the one backend that exists, and an assertion about the projection proves it
//! holds in every backend there will ever be, because the pages are gone before
//! a backend is called.

use super::*;
use crate::downloads::{Download, DownloadError, DownloadErrorKind, Downloads};
use crate::model::{NavigationErrorKind, TabKind};
use crate::protocol::{Action, WindowContents};
use crate::reducer::dispatch;
use crate::routing::RoutePattern;
use crate::shortcuts::{Chord, UiCommand};

/// One space, two tabs shown side by side, a page in history and a rule.
fn a_session_with_two_tabs_side_by_side() -> Session {
    let mut s = Session::new("Personal", "ds-personal");
    dispatch(&mut s, Action::Tick { now_ms: 1_000 });

    for url in ["avelino.run", "github.com"] {
        dispatch(
            &mut s,
            Action::OpenTab {
                space: None,
                url: Some(url.into()),
                parent: None,
            },
        );
    }
    let space = s.browser.active_space();
    let tabs: Vec<_> = s.browser.tabs_in(space).iter().map(|t| t.id).collect();
    dispatch(&mut s, Action::ActivateTab { tab: tabs[0] });
    dispatch(&mut s, Action::SplitWith { tab: tabs[1] });
    s
}

fn make_ephemeral(session: &mut Session) {
    let space = session.browser.active_space();
    dispatch(
        session,
        Action::SetSpaceProfile {
            space,
            profile: SpaceProfile {
                user_agent: None,
                ephemeral: true,
            },
        },
    );
}

fn only_space(projected: &StorableSession) -> &StorableSpace {
    assert_eq!(projected.spaces.len(), 1, "fixture has one space");
    &projected.spaces[0]
}

// --- ADR-0023: an ephemeral space records no history -------------------------

#[test]
fn an_ephemeral_space_hands_a_backend_none_of_its_pages() {
    let mut session = a_session_with_two_tabs_side_by_side();
    assert_eq!(session.browser.tab_count(), 2, "fixture has pages to lose");
    make_ephemeral(&mut session);

    let projected = StorableSession::project(&session);

    // The space survives a quit. What was done inside it does not, and it does
    // not depend on the backend noticing: there is nothing here to write.
    let space = only_space(&projected);
    assert!(space.profile.ephemeral);
    assert_eq!(space.name, "Personal");
    assert!(
        space.tabs.is_empty(),
        "an ephemeral space must leave no trace of its pages"
    );
    assert!(
        projected.spaces.iter().all(|s| s.tabs.is_empty()),
        "and not by moving them into some other space either"
    );
}

#[test]
fn an_ephemeral_space_hands_over_no_split_either() {
    let mut session = a_session_with_two_tabs_side_by_side();
    let space = session.browser.active_space();
    assert!(
        session.browser.split(space).is_some(),
        "fixture has a split"
    );
    make_ephemeral(&mut session);

    let projected = StorableSession::project(&session);

    // A pair naming two tabs nobody stored is not a layout, it is two empty
    // panes.
    assert!(only_space(&projected).split.is_none());
}

#[test]
fn an_ordinary_space_still_hands_over_its_pages_in_order() {
    let session = a_session_with_two_tabs_side_by_side();
    let space = session.browser.active_space();
    let order: Vec<_> = session
        .browser
        .tabs_in(space)
        .iter()
        .map(|t| t.id)
        .collect();

    let projected = StorableSession::project(&session);

    // The control. A projection that dropped everything would pass the two
    // tests above and lose every session on the machine.
    let space = only_space(&projected);
    assert_eq!(
        space.tabs.iter().map(|t| t.tab.id).collect::<Vec<_>>(),
        order,
        "order is part of the data, so it has to arrive with it"
    );
    assert!(space.split.is_some());
}

#[test]
fn a_navigation_error_never_reaches_a_backend() {
    let mut session = a_session_with_two_tabs_side_by_side();
    let tab = session.browser.all_tabs()[0].id;
    dispatch(
        &mut session,
        Action::NavigationFailed {
            tab,
            kind: NavigationErrorKind::Offline,
            message: "The Internet connection appears to be offline.".into(),
        },
    );
    assert!(session.browser.tab(tab).unwrap().last_error.is_some());

    let projected = StorableSession::project(&session);

    // Every restored tab is loaded again at launch, so a stored failure would
    // be drawn over a page that is about to work.
    assert!(
        projected
            .spaces
            .iter()
            .flat_map(|s| &s.tabs)
            .all(|t| t.tab.last_error.is_none() && t.tab.pending_url.is_none())
    );
}

// --- ADR-0027: a download row only claims what is really there ---------------

fn a_download(id: &str, state: DownloadState) -> Download {
    Download {
        id: DownloadId(id.to_string()),
        url: format!("https://example.com/{id}"),
        tab: None,
        filename: format!("{id}.bin"),
        path: format!("/tmp/{id}.bin"),
        state,
        received_bytes: 10,
        total_bytes: Some(100),
        error: if let DownloadState::Failed = state {
            Some(DownloadError {
                kind: DownloadErrorKind::Offline,
                message: "offline".into(),
            })
        } else {
            None
        },
        started_at_ms: 5,
        // Set by the tests that are about it. A projection must not be able to
        // carry it whatever it says here: `StorableDownload` has no field for
        // it (ADR-0101).
        resumable: false,
    }
}

fn projected_with(downloads: Vec<Download>) -> StorableSession {
    let mut session = a_session_with_two_tabs_side_by_side();
    session.downloads = Downloads::load(downloads);
    StorableSession::project(&session)
}

#[test]
fn a_download_still_running_is_handed_over_as_interrupted() {
    // Quitting stops it, and `WKDownload` goes with the process. A row that
    // came back saying "in progress" would draw a bar for a transfer that
    // ended hours ago.
    let projected = projected_with(vec![a_download("live", DownloadState::InProgress)]);

    assert_eq!(projected.downloads.len(), 1);
    assert_eq!(
        projected.downloads[0].state,
        StorableDownloadState::Interrupted
    );
}

#[test]
fn a_finished_download_is_handed_over_as_finished() {
    let projected = projected_with(vec![a_download("done", DownloadState::Completed)]);

    assert_eq!(
        projected.downloads[0].state,
        StorableDownloadState::Completed
    );
}

#[test]
fn a_failed_download_is_not_handed_over_at_all() {
    // There is no file at the far end of it, so a row would offer Reveal in
    // Finder for nothing.
    let projected = projected_with(vec![a_download("gone", DownloadState::Failed)]);

    assert!(projected.downloads.is_empty());
}

#[test]
fn a_cancelled_download_is_not_handed_over_either() {
    let projected = projected_with(vec![a_download("nope", DownloadState::Cancelled)]);

    assert!(projected.downloads.is_empty());
}

#[test]
fn the_ones_that_are_dropped_do_not_take_the_others_with_them() {
    let projected = projected_with(vec![
        a_download("first", DownloadState::Completed),
        a_download("failed", DownloadState::Failed),
        a_download("last", DownloadState::Completed),
    ]);

    assert_eq!(
        projected
            .downloads
            .iter()
            .map(|d| d.id.0.as_str())
            .collect::<Vec<_>>(),
        ["first", "last"],
        "newest-first order has to survive a gap in the middle"
    );
}

#[test]
fn projecting_a_live_download_does_not_change_what_is_on_screen() {
    // The row a store is handed says what would be true if this save were the
    // last thing written. The running browser is unaffected.
    let mut session = a_session_with_two_tabs_side_by_side();
    session.downloads = Downloads::load(vec![a_download("live", DownloadState::InProgress)]);

    let _ = StorableSession::project(&session);

    assert_eq!(session.downloads.in_flight_count(), 1);
}

// --- the keymap delta --------------------------------------------------------

#[test]
fn an_untouched_keymap_hands_over_nothing() {
    let projected = StorableSession::project(&a_session_with_two_tabs_side_by_side());

    // Storing the defaults would freeze them: a later change to the shipped
    // bindings would never reach anyone who had already quit once.
    assert!(projected.keybindings.is_empty());
}

#[test]
fn a_rebound_shortcut_is_the_only_binding_handed_over() {
    let mut session = a_session_with_two_tabs_side_by_side();
    session.keymap.bind(Chord::primary("j"), UiCommand::NextTab);

    let projected = StorableSession::project(&session);

    assert_eq!(projected.keybindings.len(), 1);
    assert_eq!(projected.keybindings[0].command, UiCommand::NextTab);
}

// --- and everything else arrives whole ---------------------------------------

#[test]
fn everything_a_store_is_meant_to_keep_arrives() {
    let mut session = a_session_with_two_tabs_side_by_side();
    session.history.record("https://avelino.run/", None, 2_000);
    session
        .browser
        .set_search_template("https://kagi.com/?q={}");
    session.browser.set_archive_after_ms(3_600_000);
    let space = session.browser.active_space();
    dispatch(
        &mut session,
        Action::AddRoute {
            pattern: RoutePattern::Domain {
                host: "github.com".into(),
            },
            space,
        },
    );
    let tab = session.browser.all_tabs()[0].id;
    dispatch(
        &mut session,
        Action::SetTabKind {
            tab,
            kind: TabKind::Pinned,
        },
    );

    let projected = StorableSession::project(&session);

    assert_eq!(projected.key_window, session.browser.key_window());
    assert_eq!(projected.windows.len(), 1);
    assert_eq!(
        projected.windows[0].active_space,
        session.browser.active_space()
    );
    assert_eq!(
        projected.windows[0].active_tab,
        session.browser.active_tab()
    );
    assert_eq!(projected.search_template, "https://kagi.com/?q={}");
    assert_eq!(projected.archive_after_ms, 3_600_000);
    assert_eq!(projected.routes.len(), 1);
    assert_eq!(projected.history.len(), 1);
    assert_eq!(projected.preferences, session.preferences);
    assert!(
        projected
            .spaces
            .iter()
            .flat_map(|s| &s.tabs)
            .any(|t| t.tab.is_pinned()),
        "a pinned tab that comes back unpinned is a tab that was lost"
    );
}

// --- Conversations: what a backend may never be handed -----------------------

use crate::chat::{ChatErrorKind, ConsentChoice, ToolCallId, ToolInvocation};
use crate::mcp::{McpServerState, ReportedTool};
use crate::protocol::{ChatSubject, ReplyStop};

/// Bring a server up and have it publish one tool, which is the least a call
/// needs to get anywhere at all.
fn offer_tool(s: &mut Session, server: &str, tool: &str) {
    s.mcp.adopt_server(server);
    s.mcp.set_state(
        server,
        McpServerState::Ready {
            protocol_version: "2026-07-28".into(),
            server_name: server.into(),
            server_version: "1".into(),
        },
    );
    dispatch(
        s,
        Action::ToolsListed {
            server: server.into(),
            tools: vec![ReportedTool {
                name: tool.into(),
                description: String::new(),
                input_schema_json: r#"{"type":"object"}"#.into(),
                read_only_hint: None,
                destructive_hint: None,
                open_world_hint: None,
            }],
        },
    );
}

/// A thread about a page, with the page read and a reply that finished.
fn a_session_with_a_conversation() -> Session {
    let mut s = a_session_with_two_tabs_side_by_side();
    let tab = s.browser.active_tab().unwrap();
    dispatch(
        &mut s,
        Action::NavigationCommitted {
            tab,
            url: "https://avelino.run/".into(),
        },
    );
    dispatch(
        &mut s,
        Action::OpenChat {
            about: ChatSubject::CurrentPage,
            ask: Some("what is this".into()),
        },
    );
    let conversation = s.chat.all().last().unwrap().id;
    dispatch(
        &mut s,
        Action::PageContextCaptured {
            conversation,
            url: "https://avelino.run/".into(),
            title: "Avelino".into(),
            text: "every private word that was on the page".into(),
        },
    );
    let reply = s.chat.get(conversation).unwrap().streaming().unwrap().id;
    dispatch(
        &mut s,
        Action::ChatReplyDelta {
            message: reply,
            text: "it is a blog".into(),
        },
    );
    dispatch(
        &mut s,
        Action::ChatReplyFinished {
            message: reply,
            stop: ReplyStop::EndOfTurn,
        },
    );
    s
}

#[test]
fn a_conversation_comes_back_with_what_was_said() {
    let s = a_session_with_a_conversation();

    let projected = StorableSession::project(&s);

    assert_eq!(projected.conversations.len(), 1);
    let thread = &projected.conversations[0];
    assert!(matches!(
        thread.messages.as_slice(),
        [
            StorableMessage::Page { .. },
            StorableMessage::User { .. },
            StorableMessage::Assistant { .. },
        ]
    ));
}

#[test]
fn an_ephemeral_space_leaves_no_conversation_behind() {
    // The same promise ADR-0023 makes about pages, applied to the most
    // detailed trace of a page this browser can produce: a thread holds what
    // was said about the page *and*, since ADR-0060, the page's address in its
    // own identity.
    let mut s = a_session_with_a_conversation();
    assert_eq!(StorableSession::project(&s).conversations.len(), 1);

    make_ephemeral(&mut s);

    let projected = StorableSession::project(&s);
    assert!(
        projected.conversations.is_empty(),
        "an ephemeral space wrote a conversation down"
    );
    assert!(only_space(&projected).tabs.is_empty());
}

#[test]
fn an_ephemeral_space_writes_down_no_address_a_thread_was_anchored_to() {
    // The half anchoring added, and the one that would not have been caught by
    // looking at messages. A thread carries its page in its *scope* now, so it
    // is on disk whether or not anything was ever captured — a thread opened in
    // a private space and never asked a question would still name the page it
    // was opened on. Asserted over the whole projection rather than one field,
    // because the next place a URL leaks will not be the field anyone expected.
    let mut s = a_session_with_a_conversation();
    // Establish that the instrument can see the thing before trusting it not
    // to: an ordinary space does write the address down, so an empty result
    // below is the promise being kept and not the grep being blind.
    assert!(
        format!("{:?}", StorableSession::project(&s).conversations).contains("avelino.run"),
        "the address is not written down even in an ordinary space, so this test proves nothing"
    );

    make_ephemeral(&mut s);

    assert!(
        !format!("{:?}", StorableSession::project(&s).conversations).contains("avelino.run"),
        "an ephemeral space wrote down an address a thread was about"
    );
}

#[test]
fn what_was_on_the_page_is_never_written_down() {
    // The address and the title are already in history. The body of every page
    // anyone ever asked about is a shadow archive, and it is the single most
    // sensitive thing chat could put on disk.
    let s = a_session_with_a_conversation();

    let projected = StorableSession::project(&s);
    let page = projected.conversations[0]
        .messages
        .iter()
        .find(|m| matches!(m, StorableMessage::Page { .. }))
        .expect("no page in the thread");

    let StorableMessage::Page { url, title, .. } = page else {
        unreachable!()
    };
    assert_eq!(url, "https://avelino.run/");
    assert_eq!(title, "Avelino");

    // And nowhere in the whole projection is the text of the page.
    let written = format!("{projected:?}");
    assert!(
        !written.contains("every private word"),
        "the page's text reached a backend"
    );
}

#[test]
fn a_tool_call_cannot_be_written_down_at_all() {
    // No variant carries one, so a consent prompt cannot come back after a
    // restart and a stale result cannot come back answering it.
    let mut s = a_session_with_two_tabs_side_by_side();
    offer_tool(&mut s, "files", "read_file");
    dispatch(
        &mut s,
        Action::OpenChat {
            about: ChatSubject::Nothing,
            ask: Some("read it".into()),
        },
    );
    let conversation = s.chat.all().last().unwrap().id;
    let reply = s.chat.get(conversation).unwrap().streaming().unwrap().id;
    dispatch(
        &mut s,
        Action::ChatReplyDelta {
            message: reply,
            text: "let me look".into(),
        },
    );
    dispatch(
        &mut s,
        Action::ChatToolCallRequested {
            message: reply,
            invocation: ToolInvocation {
                id: ToolCallId("c1".into()),
                server: "files".into(),
                tool: "read_file".into(),
                arguments: "{\"path\":\"/etc/passwd\"}".into(),
            },
        },
    );
    assert!(s.chat.get(conversation).unwrap().needs_consent());

    let projected = StorableSession::project(&s);

    let written = format!("{projected:?}");
    assert!(
        !written.contains("/etc/passwd"),
        "a tool call's arguments reached a backend"
    );
    assert!(
        !written.contains("AwaitingConsent"),
        "a consent prompt reached a backend"
    );
}

#[test]
fn a_reply_still_arriving_is_written_down_as_interrupted() {
    // If this save turns out to be the last thing we write, that is exactly
    // what happened. The same reading a download gets.
    let mut s = a_session_with_two_tabs_side_by_side();
    dispatch(
        &mut s,
        Action::OpenChat {
            about: ChatSubject::Nothing,
            ask: Some("hello".into()),
        },
    );
    let conversation = s.chat.all().last().unwrap().id;
    let reply = s.chat.get(conversation).unwrap().streaming().unwrap().id;
    dispatch(
        &mut s,
        Action::ChatReplyDelta {
            message: reply,
            text: "half".into(),
        },
    );

    let projected = StorableSession::project(&s);

    let last = projected.conversations[0].messages.last().unwrap();
    assert!(matches!(
        last,
        StorableMessage::Assistant {
            state: StorableMessageState::Interrupted,
            ..
        }
    ));
}

#[test]
fn a_thread_nobody_asked_anything_is_not_written_down() {
    let mut s = a_session_with_two_tabs_side_by_side();
    dispatch(
        &mut s,
        Action::OpenChat {
            about: ChatSubject::CurrentPage,
            ask: None,
        },
    );

    assert!(StorableSession::project(&s).conversations.is_empty());
}

#[test]
fn what_may_run_without_asking_is_written_down_and_so_is_what_may_never() {
    // A consent that resets on relaunch trains people to click through, which
    // is the whole argument of ADR-0028.
    let mut s = a_session_with_two_tabs_side_by_side();
    s.chat.consent_mut().record("files", "read_file", true, 10);
    s.chat
        .consent_mut()
        .record("files", "delete_everything", false, 20);

    let projected = StorableSession::project(&s);

    assert_eq!(projected.tool_consent.len(), 2);
    assert!(
        projected
            .tool_consent
            .iter()
            .any(|g| g.tool == "delete_everything" && !g.allowed),
        "a refusal was not written down: {:?}",
        projected.tool_consent
    );
}

#[test]
fn a_thread_whose_reply_broke_keeps_what_was_read_and_not_the_error() {
    // The error belongs to the run: a provider that was rate limited last
    // night is not a fact about this morning.
    let mut s = a_session_with_two_tabs_side_by_side();
    dispatch(
        &mut s,
        Action::OpenChat {
            about: ChatSubject::Nothing,
            ask: Some("hello".into()),
        },
    );
    let conversation = s.chat.all().last().unwrap().id;
    let reply = s.chat.get(conversation).unwrap().streaming().unwrap().id;
    dispatch(
        &mut s,
        Action::ChatFailed {
            conversation,
            message: Some(reply),
            kind: ChatErrorKind::RateLimited,
            detail: "429 from the provider".into(),
        },
    );

    let projected = StorableSession::project(&s);

    let written = format!("{projected:?}");
    assert!(!written.contains("429 from the provider"));
    // The question survives, because the person asked it.
    assert!(matches!(
        projected.conversations[0].messages.as_slice(),
        [StorableMessage::User { .. }]
    ));
}

#[test]
fn a_refusal_and_a_thread_both_survive_a_round_trip_through_a_store() {
    use crate::session_store::SessionStore;
    use crate::store::Store;

    let mut s = a_session_with_a_conversation();
    s.chat
        .consent_mut()
        .record("files", "delete_everything", false, 20);
    offer_tool(&mut s, "files", "delete_everything");

    let mut store = Store::in_memory().unwrap();
    store.save(&StorableSession::project(&s)).unwrap();
    let back = store.load().unwrap().unwrap();

    assert_eq!(
        back.chat.consent().decision("files", "delete_everything"),
        Some(false),
        "a refusal that resets is worse than never having asked"
    );
    let thread = back
        .chat
        .all()
        .first()
        .expect("the thread did not come back");
    assert_eq!(thread.messages.len(), 3);
    assert!(
        thread.messages.iter().all(|m| m.tool_calls.is_empty()),
        "a restored thread holds a live tool call"
    );
    // Nothing a server said it could do is remembered: a call answered against
    // a remembered list would run a tool the server may no longer have.
    assert!(back.mcp.tools().is_empty());
    assert!(back.mcp.server_ids().is_empty());
}

#[test]
fn a_standing_approval_comes_back_bound_to_the_tool_it_was_given_about() {
    use crate::session_store::SessionStore;
    use crate::store::Store;

    let mut s = a_session_with_a_conversation();
    offer_tool(&mut s, "files", "read_file");
    let bound = s.remember_tool_answer("files", "read_file", true, 20);
    assert!(bound, "the fixture approved a tool that is really there");
    let fingerprint = s.mcp.shapes()[0].fingerprint.clone();

    let mut store = Store::in_memory().unwrap();
    store.save(&StorableSession::project(&s)).unwrap();
    let mut back = store.load().unwrap().unwrap();

    // Both halves, or the surviving half is the one that fails open. The
    // register comes back holding what the answer was about and holding no
    // tools at all, because no server is running yet.
    assert_eq!(
        back.chat.consent().decision("files", "read_file"),
        Some(true)
    );
    assert_eq!(back.mcp.shapes().len(), 1);
    assert_eq!(back.mcp.shapes()[0].fingerprint, fingerprint);

    // And it only becomes an approval again once a server publishes the very
    // same tool. Until then the verdict is `Unknown`, not `Approved`.
    assert_eq!(
        back.mcp.verdict(back.chat.consent(), "files", "read_file"),
        crate::mcp::ToolVerdict::Unknown
    );
    offer_tool(&mut back, "files", "read_file");
    assert_eq!(
        back.mcp.verdict(back.chat.consent(), "files", "read_file"),
        crate::mcp::ToolVerdict::Approved,
        "a relaunch should not re-interrogate somebody about a tool that has not moved"
    );
}

#[test]
fn a_grant_that_comes_back_without_its_shape_is_not_an_approval() {
    use crate::session_store::SessionStore;
    use crate::store::Store;

    // What a file written by schema 5 looks like on the way back in, and what
    // any future path that writes a ledger row without binding a shape would
    // produce. It must degrade into asking again, never into running.
    let mut s = a_session_with_a_conversation();
    offer_tool(&mut s, "files", "read_file");
    s.chat.consent_mut().record("files", "read_file", true, 20);

    let mut store = Store::in_memory().unwrap();
    store.save(&StorableSession::project(&s)).unwrap();
    let mut back = store.load().unwrap().unwrap();
    offer_tool(&mut back, "files", "read_file");

    assert!(
        back.mcp.shapes().is_empty(),
        "nothing bound it in the first place"
    );
    assert_eq!(
        back.mcp.verdict(back.chat.consent(), "files", "read_file"),
        crate::mcp::ToolVerdict::Changed,
        "a grant with no shape behind it must not run unattended"
    );
}

#[test]
fn a_restored_thread_does_not_reuse_a_message_id() {
    use crate::session_store::SessionStore;
    use crate::store::Store;

    let s = a_session_with_a_conversation();
    let highest = s
        .chat
        .all()
        .iter()
        .flat_map(|c| c.messages.iter())
        .map(|m| m.id.0)
        .max()
        .unwrap();

    let mut store = Store::in_memory().unwrap();
    store.save(&StorableSession::project(&s)).unwrap();
    let mut back = store.load().unwrap().unwrap();

    dispatch(
        &mut back,
        Action::OpenChat {
            about: ChatSubject::Nothing,
            ask: Some("something new".into()),
        },
    );

    let fresh: Vec<u64> = back
        .chat
        .all()
        .iter()
        .flat_map(|c| c.messages.iter())
        .map(|m| m.id.0)
        .filter(|id| *id > highest)
        .collect();
    assert!(!fresh.is_empty(), "a new message reused an old id");
}

#[test]
fn what_a_conversation_is_about_survives_a_round_trip() {
    use crate::session_store::SessionStore;
    use crate::store::Store;

    let s = a_session_with_a_conversation();
    let scope = s.chat.all()[0].scope.clone();
    // The address is the subject now, so "what it is about" is only carried if
    // the page survives with it. A round trip that dropped it would come back
    // with a thread nothing can ever anchor to again.
    assert_eq!(
        scope.page().map(|p| p.as_str()),
        Some("https://avelino.run/")
    );

    let mut store = Store::in_memory().unwrap();
    store.save(&StorableSession::project(&s)).unwrap();
    let back = store.load().unwrap().unwrap();

    assert_eq!(back.chat.all()[0].scope, scope);
    assert!(back.chat.latest_for_scope(&scope).is_some());
}

#[test]
fn a_restored_thread_is_not_still_working() {
    use crate::session_store::SessionStore;
    use crate::store::Store;

    let mut s = a_session_with_two_tabs_side_by_side();
    dispatch(
        &mut s,
        Action::OpenChat {
            about: ChatSubject::Nothing,
            ask: Some("hello".into()),
        },
    );
    let conversation = s.chat.all().last().unwrap().id;
    let reply = s.chat.get(conversation).unwrap().streaming().unwrap().id;
    dispatch(
        &mut s,
        Action::ChatReplyDelta {
            message: reply,
            text: "half".into(),
        },
    );

    let mut store = Store::in_memory().unwrap();
    store.save(&StorableSession::project(&s)).unwrap();
    let back = store.load().unwrap().unwrap();

    let thread = &back.chat.all()[0];
    assert!(
        !thread.is_busy(),
        "a thread came back spinning for a process that is gone"
    );
    assert!(!thread.needs_consent());
}

#[test]
fn a_consent_choice_is_a_ledger_row_and_not_a_running_call() {
    // Guards the seam between what somebody chose and what is happening: a
    // `Once` is deliberately absent from the ledger, so it cannot come back as
    // a standing grant.
    let mut s = a_session_with_two_tabs_side_by_side();
    offer_tool(&mut s, "files", "read_file");
    dispatch(
        &mut s,
        Action::OpenChat {
            about: ChatSubject::Nothing,
            ask: Some("read it".into()),
        },
    );
    let conversation = s.chat.all().last().unwrap().id;
    let reply = s.chat.get(conversation).unwrap().streaming().unwrap().id;
    dispatch(
        &mut s,
        Action::ChatToolCallRequested {
            message: reply,
            invocation: ToolInvocation {
                id: ToolCallId("c1".into()),
                server: "files".into(),
                tool: "read_file".into(),
                arguments: "{}".into(),
            },
        },
    );
    dispatch(
        &mut s,
        Action::DecideToolCall {
            call: ToolCallId("c1".into()),
            decision: ConsentChoice::Once,
        },
    );

    assert!(
        StorableSession::project(&s).tool_consent.is_empty(),
        "a one-off yes was written down as a standing grant"
    );
}

// --- ADR-0065: a private window is not written down --------------------------

/// The whole-window version of `an_ephemeral_space_hands_a_backend_none_of_its_pages`.
///
/// ADR-0023 proved a private *space* hands over no pages. That left the window
/// it was opened in: an entry naming it, with a space id and a tab id in it,
/// would be a record that somebody browsed privately and roughly where. There
/// is no branch here testing for "private" — the window has no stored tabs, so
/// there is nothing to write an entry from.
#[test]
fn a_private_window_hands_a_backend_no_window_at_all() {
    let mut session = Session::new("Personal", "ds-personal");
    dispatch(&mut session, Action::Tick { now_ms: 1_000 });
    dispatch(
        &mut session,
        Action::OpenTab {
            space: None,
            url: None,
            parent: None,
        },
    );
    let ordinary = session.browser.key_window();

    dispatch(
        &mut session,
        Action::OpenWindow {
            onto: WindowContents::NewPrivateSpace {
                name: "Private".into(),
                data_store_id: "ds-private".into(),
            },
        },
    );
    let private = session.browser.key_window();
    let secret = session.browser.active_tab().unwrap();
    dispatch(
        &mut session,
        Action::NavigationCommitted {
            tab: secret,
            url: "https://secret.example/".into(),
        },
    );

    let projected = StorableSession::project(&session);

    assert_eq!(
        projected.windows.iter().map(|w| w.id).collect::<Vec<_>>(),
        vec![ordinary],
        "the private window reached a backend"
    );
    assert_eq!(
        projected.key_window, ordinary,
        "the window in front was private, so the front goes to one that was not"
    );
    // Not its tabs, not the address, not a history row.
    assert!(
        projected
            .spaces
            .iter()
            .all(|s| s.tabs.iter().all(|t| t.tab.window != private)),
        "a page from the private window"
    );
    assert!(
        projected
            .history
            .iter()
            .all(|h| h.url != "https://secret.example/")
    );
    assert!(projected.conversations.is_empty());
}

/// The other half of the pair, and it exists for the same reason
/// `an_ordinary_space_still_records_history` does: the easy way to make the
/// test above pass is to stop writing windows down at all.
#[test]
fn an_ordinary_window_is_still_written_down_with_where_it_was_looking() {
    let mut session = Session::new("Personal", "ds-personal");
    dispatch(&mut session, Action::Tick { now_ms: 1_000 });
    dispatch(
        &mut session,
        Action::OpenTab {
            space: None,
            url: None,
            parent: None,
        },
    );
    dispatch(
        &mut session,
        Action::OpenWindow {
            onto: WindowContents::CurrentSpace,
        },
    );
    let second = session.browser.key_window();

    let projected = StorableSession::project(&session);

    assert_eq!(projected.windows.len(), 2);
    assert_eq!(projected.key_window, second);
    let entry = projected
        .windows
        .iter()
        .find(|w| w.id == second)
        .expect("the second window");
    assert_eq!(entry.active_space, session.browser.active_space());
    assert_eq!(entry.active_tab, session.browser.active_tab());
}

/// An address inside an extension is not written down.
///
/// The host in one is a uuid **WebKit** minted for a live context and mints
/// again on the next launch, so a stored one names nothing: it would come back
/// as a tab whose address resolves to no extension, which is a refusal screen
/// where an options page used to be. The tab is kept and comes back blank.
#[test]
fn an_address_inside_an_extension_is_not_written_down() {
    let mut session = Session::new("Personal", "ds-personal");
    dispatch(&mut session, Action::Tick { now_ms: 1_000 });
    let page = "webkit-extension://142b180d-a643-4516-9b24-1cc01d08d781/app/app.html";
    dispatch(
        &mut session,
        Action::OpenTab {
            space: None,
            url: Some(page.into()),
            parent: None,
        },
    );
    let tab = session.browser.active_tab().unwrap();
    dispatch(
        &mut session,
        Action::NavigationCommitted {
            tab,
            url: page.into(),
        },
    );
    dispatch(
        &mut session,
        Action::NavigationStateChanged {
            tab,
            state: vec![7, 7, 7],
        },
    );
    // The instrument first: the tab really is holding the address, so an empty
    // result below is this rule and not an empty session.
    assert_eq!(session.browser.tab(tab).unwrap().url.as_deref(), Some(page));

    let projected = StorableSession::project(&session);
    let stored = only_space(&projected)
        .tabs
        .iter()
        .find(|t| t.tab.id == tab)
        .expect("the tab itself is still worth keeping");

    assert_eq!(
        stored.tab.url, None,
        "an extension's address was written down"
    );
    assert_eq!(stored.navigation_state, None, "its history went with it");
}
