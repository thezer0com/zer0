//! Where a tab has been: what is kept, what is refused, and what an ephemeral
//! space is structurally unable to write down.

use super::*;
use crate::model::{NavigationErrorKind, SpaceProfile};
use crate::protocol::{Action, EngineCommand};
use crate::reducer::{dispatch, rehydrate};
use crate::session::Session;
#[cfg(feature = "store")]
use crate::session_store::SessionStore;
#[cfg(feature = "store")]
use crate::storable::StorableSession;
#[cfg(feature = "store")]
use crate::store::Store;

/// Roughly what WebKit hands over for a three-page tab: measured at 1,406
/// bytes on macOS 26.5. The content is meaningless on this side of the FFI,
/// which is the point.
fn a_state(seed: u8) -> Vec<u8> {
    (0..1_406u16).map(|i| (i as u8) ^ seed).collect()
}

#[cfg(feature = "store")]
fn round_trip(session: &Session) -> Session {
    let mut store = Store::in_memory().unwrap();
    store.save(&StorableSession::project(session)).unwrap();
    store.load().unwrap().expect("a saved session must load")
}

/// One tab, on a page, with a back list.
fn browsed(ephemeral: bool) -> (Session, TabId) {
    let mut session = Session::new("Personal", "ds-personal");
    dispatch(&mut session, Action::Tick { now_ms: 1_000 });
    if ephemeral {
        let space = session.browser.active_space();
        dispatch(
            &mut session,
            Action::SetSpaceProfile {
                space,
                profile: SpaceProfile {
                    user_agent: None,
                    ephemeral: true,
                },
            },
        );
    }
    dispatch(
        &mut session,
        Action::OpenTab {
            space: None,
            url: None,
            parent: None,
        },
    );
    let tab = session.browser.active_tab().unwrap();
    dispatch(
        &mut session,
        Action::NavigationCommitted {
            tab,
            url: "https://avelino.run/".into(),
        },
    );
    dispatch(
        &mut session,
        Action::NavigationStateChanged {
            tab,
            state: a_state(1),
        },
    );
    (session, tab)
}

// --- the size cap, which is the only check these bytes can be given ---------

#[test]
fn a_state_too_large_to_be_a_back_list_is_not_kept() {
    let mut states = NavigationStates::new();
    let tab = TabId(1);

    states.set(tab, vec![7; MAX_STATE_BYTES]);
    assert_eq!(
        states.get(tab).map(|s| s.len()),
        Some(MAX_STATE_BYTES),
        "the largest allowed state is allowed"
    );

    states.set(tab, vec![7; MAX_STATE_BYTES + 1]);
    assert!(
        states.get(tab).is_none(),
        "one byte over the cap is refused, and refusing it also drops what was there"
    );
}

#[test]
fn an_empty_state_is_no_state_rather_than_an_empty_one() {
    let mut states = NavigationStates::new();
    let tab = TabId(1);
    states.set(tab, a_state(0));
    states.set(tab, Vec::new());
    assert!(states.get(tab).is_none());
    assert!(states.is_empty());
}

#[test]
fn a_stored_state_is_held_to_the_same_limit_as_a_live_one() {
    // The load path and the live path are the same door, which is what makes
    // "the file cannot be trusted" a fact about the type rather than about
    // whoever remembered to check (ADR-0024).
    let states = NavigationStates::load([
        (TabId(1), a_state(2)),
        (TabId(2), vec![0; MAX_STATE_BYTES + 1]),
        (TabId(3), Vec::new()),
    ]);
    assert!(states.get(TabId(1)).is_some());
    assert!(
        states.get(TabId(2)).is_none(),
        "a huge blob off disk is refused"
    );
    assert!(states.get(TabId(3)).is_none());
    assert_eq!(states.len(), 1);
}

// --- the promise: a private space's history cannot reach a file -------------

#[cfg(feature = "store")]
#[test]
fn an_ephemeral_space_writes_down_no_back_list() {
    let (session, tab) = browsed(true);
    assert!(
        session.navigation_states.get(tab).is_some(),
        "the state is held while the browser runs; the promise is about the disk"
    );

    let projection = StorableSession::project(&session);

    // There is exactly one place a state can be in a projection, and this is
    // it. If this loop ever has somewhere else to look, the guarantee has
    // stopped being structural.
    let written: Vec<_> = projection
        .spaces
        .iter()
        .flat_map(|s| s.tabs.iter())
        .filter_map(|t| t.navigation_state.as_ref())
        .collect();
    assert!(
        written.is_empty(),
        "an ephemeral space handed a backend a back/forward list"
    );

    let after = round_trip(&session);
    assert_eq!(after.navigation_states.len(), 0);
}

#[cfg(feature = "store")]
#[test]
fn a_persistent_space_brings_its_back_list_back() {
    let (session, tab) = browsed(false);

    let after = round_trip(&session);

    let restored = after
        .browser
        .all_tabs()
        .iter()
        .map(|t| t.id)
        .find(|id| *id == tab)
        .expect("the tab comes back");
    assert_eq!(
        after.navigation_states.get(restored),
        Some(a_state(1).as_slice()),
        "the bytes come back exactly as the engine wrote them"
    );
}

// --- what the engine is handed at launch ------------------------------------

#[cfg(feature = "store")]
#[test]
fn a_restored_tab_is_handed_its_history_and_not_a_second_load() {
    let (session, tab) = browsed(false);
    let after = round_trip(&session);

    let commands = rehydrate(&after);

    // `if let` rather than a `match` with a wildcard on the end: a `_ => None`
    // over an `EngineCommand` is the shape AGENTS.md forbids, and forbids in a
    // test for the same reason it forbids it in the reducer — it is how the
    // next variant gets added and silently ignored by the thing that was meant
    // to notice.
    let created = commands
        .iter()
        .filter_map(|c| {
            if let EngineCommand::CreateWebView {
                tab: t,
                navigation_state,
                ..
            } = c
            {
                (*t == tab).then(|| navigation_state.clone())
            } else {
                None
            }
        })
        .next()
        .expect("the tab's view is created");
    assert_eq!(
        created,
        Some(a_state(1)),
        "the view is built with the history the tab had"
    );
    // The load is held back on purpose: measured, setting the state and then
    // loading the same address leaves two entries for one page, so the first
    // Back press goes nowhere a person can see.
    assert!(
        !commands
            .iter()
            .any(|c| matches!(c, EngineCommand::LoadUrl { tab: t, .. } if *t == tab)),
        "a tab handed its history must not also be told to load"
    );
}

#[test]
fn a_tab_with_no_history_is_still_told_to_load() {
    let (mut session, tab) = browsed(false);
    session.navigation_states.forget(tab);

    let commands = rehydrate(&session);

    assert!(
        commands.iter().any(|c| matches!(
            c,
            EngineCommand::CreateWebView {
                tab: t,
                navigation_state: None,
                ..
            } if *t == tab
        )),
        "no state to hand over"
    );
    assert!(
        commands
            .iter()
            .any(|c| matches!(c, EngineCommand::LoadUrl { tab: t, .. } if *t == tab)),
        "so the address is what puts the page back"
    );
}

#[test]
fn a_history_the_engine_will_not_take_costs_the_history_and_not_the_tab() {
    let (mut session, tab) = browsed(false);

    let commands = dispatch(&mut session, Action::NavigationStateRefused { tab });

    assert_eq!(
        commands,
        vec![EngineCommand::LoadUrl {
            tab,
            url: "https://avelino.run/".into(),
        }],
        "the load held back at creation is the one that is owed"
    );
    assert!(
        session.navigation_states.get(tab).is_none(),
        "and the bytes the engine refused are not offered again"
    );
}

// --- a tab that goes away takes its history with it -------------------------

#[test]
fn closing_a_tab_forgets_where_it_had_been() {
    let (mut session, tab) = browsed(false);
    dispatch(
        &mut session,
        Action::OpenTab {
            space: None,
            url: None,
            parent: None,
        },
    );

    dispatch(&mut session, Action::CloseTab { tab });

    assert!(
        session.navigation_states.get(tab).is_none(),
        "a state nothing can ever hand back is held for the rest of the run"
    );
}

#[test]
fn a_state_for_a_tab_that_is_gone_is_never_taken() {
    let (mut session, tab) = browsed(false);
    dispatch(
        &mut session,
        Action::OpenTab {
            space: None,
            url: None,
            parent: None,
        },
    );
    dispatch(&mut session, Action::CloseTab { tab });

    // The engine can report a state after the close: the two travel in
    // opposite directions and nothing orders them.
    dispatch(
        &mut session,
        Action::NavigationStateChanged {
            tab,
            state: a_state(3),
        },
    );

    assert!(session.navigation_states.get(tab).is_none());
}

// --- the page died, and the tab did not -------------------------------------

#[test]
fn a_page_whose_process_ended_says_so_and_keeps_the_address() {
    let (mut session, tab) = browsed(false);

    let commands = dispatch(&mut session, Action::PageProcessEnded { tab });

    let t = session.browser.tab(tab).unwrap();
    let error = t.last_error.as_ref().expect("a dead page is a state");
    assert_eq!(error.kind, NavigationErrorKind::PageProcessEnded);
    assert_eq!(
        error.url.as_deref(),
        Some("https://avelino.run/"),
        "the address that died is the only thing a retry can use"
    );
    assert!(
        error.message.is_empty(),
        "the engine says nothing about why, so neither do we (ADR-0018)"
    );
    assert!(
        t.loading_complete,
        "nothing is loading in a process that is gone"
    );
    assert!(
        t.tint.is_none(),
        "the window stops wearing a page that is gone"
    );
    assert!(
        commands.is_empty(),
        "nothing is reloaded: a page that dies on load would do it forever"
    );
}

#[test]
fn a_page_that_died_while_loading_offers_the_address_it_was_going_to() {
    let (mut session, tab) = browsed(false);
    dispatch(
        &mut session,
        Action::NavigateTo {
            tab,
            input: "https://example.com/next".into(),
        },
    );

    dispatch(&mut session, Action::PageProcessEnded { tab });

    let t = session.browser.tab(tab).unwrap();
    assert_eq!(
        t.last_error.as_ref().unwrap().url.as_deref(),
        Some("https://example.com/next"),
        "a page that died mid-load has its address in pending_url and nowhere else"
    );
    assert!(t.pending_url.is_none());
}

#[test]
fn retrying_a_dead_page_asks_the_engine_to_load_it_again() {
    let (mut session, tab) = browsed(false);
    dispatch(&mut session, Action::PageProcessEnded { tab });

    // The same path every other failed page takes — measured on macOS 26.5, an
    // ordinary load into the view whose process died recovers it in under
    // 50ms, so there is nothing else this needs to be.
    let commands = dispatch(
        &mut session,
        Action::Reload {
            tab,
            from_origin: false,
        },
    );

    assert!(
        commands.iter().any(|c| matches!(
            c,
            EngineCommand::LoadUrl { tab: t, url } if *t == tab && url == "https://avelino.run/"
        )),
        "Try Again has to actually try: {commands:?}"
    );
    assert!(
        session.browser.tab(tab).unwrap().last_error.is_none(),
        "and the screen goes as the attempt starts"
    );
}

#[test]
fn a_page_that_died_in_a_tab_that_is_gone_is_ignored() {
    let (mut session, tab) = browsed(false);
    dispatch(
        &mut session,
        Action::OpenTab {
            space: None,
            url: None,
            parent: None,
        },
    );
    dispatch(&mut session, Action::CloseTab { tab });

    let commands = dispatch(&mut session, Action::PageProcessEnded { tab });

    assert!(commands.is_empty());
}

// --- the readable half of the same list --------------------------------------

/// The engine's back/forward *answer* is this run's, not the page's. Unlike
/// the opaque archive beside it, a stored `true` would be read back as a
/// promise the restored engine has not made, so the projection clears it and
/// the restored tab starts from silence.
#[cfg(feature = "store")]
#[test]
fn the_back_and_forward_answer_is_never_written_down() {
    let (mut session, tab) = browsed(false);
    dispatch(
        &mut session,
        Action::NavigationStackChanged {
            tab,
            can_go_back: true,
            can_go_forward: true,
        },
    );

    let projection = StorableSession::project(&session);
    let stored = projection
        .spaces
        .iter()
        .flat_map(|s| s.tabs.iter())
        .find(|t| t.tab.id == tab)
        .expect("the tab is in the projection");
    assert!(
        !stored.tab.can_go_back && !stored.tab.can_go_forward,
        "the engine's answer reached the file"
    );

    let after = round_trip(&session);
    let restored = after.browser.tab(tab).expect("the tab comes back");
    assert!(
        !restored.can_go_back && !restored.can_go_forward,
        "a restored tab claims an engine answer before any engine spoke"
    );
}
