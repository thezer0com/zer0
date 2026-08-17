use super::*;
use crate::certificates::{
    CertificateFault, ReportedCertificate, ServerTrustRequest, TrustDecision,
};
use crate::http_auth::{AuthChoice, AuthDecision, HttpAuthRequest, HttpAuthScheme};
use crate::icons::IconCandidate;
use crate::model::{
    Browser, DEFAULT_SPLIT_RATIO, MAX_SPLIT_RATIO, MIN_SPLIT_RATIO, NavigationErrorKind, SpaceId,
    SpaceProfile, TabId, TabKind,
};
use crate::page_menu::{PageMenuItem, PageTarget};
use crate::protocol::{Action, EngineCommand, ViewConfiguration};
use crate::routing::RoutePattern;
use crate::session::Session;
use crate::site_permissions::ReportedOrigin;

const HOUR: u64 = 60 * 60 * 1000;

struct Fixture {
    session: Session,
}

impl Fixture {
    fn new() -> Self {
        Self {
            session: Session::new("Personal", "ds-personal"),
        }
    }

    fn send(&mut self, action: Action) -> Vec<EngineCommand> {
        dispatch(&mut self.session, action)
    }

    /// Adds a second space and returns its id, leaving it active.
    fn add_space(&mut self, name: &str, store: &str) -> SpaceId {
        self.send(Action::CreateSpace {
            name: name.into(),
            data_store_id: store.into(),
            ephemeral: false,
        });
        self.session.browser.active_space()
    }

    fn open(&mut self) -> TabId {
        self.send(Action::OpenTab {
            space: None,
            url: None,
            parent: None,
        });
        self.session
            .browser
            .active_tab()
            .expect("a new tab becomes active")
    }

    /// A space's tabs in display order, which is what a drag rearranges.
    fn order_in(&self, space: SpaceId) -> Vec<TabId> {
        self.session
            .browser
            .tabs_in(space)
            .iter()
            .map(|t| t.id)
            .collect()
    }

    fn open_child_of(&mut self, parent: TabId) -> TabId {
        self.send(Action::OpenTab {
            space: None,
            url: None,
            parent: Some(parent),
        });
        self.session.browser.active_tab().unwrap()
    }
}

// --- tabs -------------------------------------------------------------------

#[test]
fn opening_a_tab_creates_a_webview_and_focuses_it() {
    let mut f = Fixture::new();
    let out = f.send(Action::OpenTab {
        space: None,
        url: None,
        parent: None,
    });
    let tab = f.session.browser.active_tab().unwrap();

    assert_eq!(
        out,
        vec![
            EngineCommand::CreateWebView {
                tab,
                configuration: ViewConfiguration::Space {
                    data_store_id: "ds-personal".into(),
                    profile: SpaceProfile::default(),
                },
                // A tab that has never been anywhere has no back list to be
                // handed.
                navigation_state: None,
            },
            EngineCommand::FocusWebView { tab },
        ]
    );
}

#[test]
fn opening_with_a_url_loads_before_focusing() {
    let mut f = Fixture::new();
    let out = f.send(Action::OpenTab {
        space: None,
        url: Some("avelino.run".into()),
        parent: None,
    });
    let tab = f.session.browser.active_tab().unwrap();

    assert!(out.contains(&EngineCommand::LoadUrl {
        tab,
        url: "https://avelino.run".into()
    }));
    assert_eq!(
        f.session.browser.tab(tab).unwrap().pending_url.as_deref(),
        Some("https://avelino.run")
    );
}

#[test]
fn a_child_tab_opens_directly_below_its_parent() {
    let mut f = Fixture::new();
    let first = f.open();
    let last = f.open();
    let child = f.open_child_of(first);

    let order: Vec<_> = f
        .session
        .browser
        .tabs_in(f.session.browser.active_space())
        .iter()
        .map(|t| t.id)
        .collect();
    assert_eq!(order, vec![first, child, last]);
    assert_eq!(f.session.browser.index_in_space(child), Some(1));
}

#[test]
fn closing_the_active_tab_focuses_the_next_one() {
    let mut f = Fixture::new();
    let first = f.open();
    let second = f.open();
    f.send(Action::ActivateTab { tab: first });

    let out = f.send(Action::CloseTab { tab: first });

    assert_eq!(f.session.browser.active_tab(), Some(second));
    assert!(out.contains(&EngineCommand::FocusWebView { tab: second }));
}

#[test]
fn closing_the_last_tab_leaves_nothing_active() {
    let mut f = Fixture::new();
    let only = f.open();

    f.send(Action::CloseTab { tab: only });

    assert_eq!(f.session.browser.active_tab(), None);
    assert_eq!(f.session.browser.tab_count(), 0);
}

#[test]
fn closing_a_parent_reattaches_its_children_to_the_grandparent() {
    let mut f = Fixture::new();
    let root = f.open();
    let mid = f.open_child_of(root);
    let leaf = f.open_child_of(mid);

    f.send(Action::CloseTab { tab: mid });

    assert_eq!(
        f.session.browser.tab(leaf).unwrap().parent,
        Some(root),
        "the tree must stay connected"
    );
}

#[test]
fn events_for_a_closed_tab_are_ignored() {
    let mut f = Fixture::new();
    let tab = f.open();
    f.send(Action::CloseTab { tab });

    // These race with the close in the real engine. They must not panic.
    assert!(
        f.send(Action::TitleChanged {
            tab,
            title: "ghost".into()
        })
        .is_empty()
    );
    assert!(
        f.send(Action::NavigateTo {
            tab,
            input: "a.com".into()
        })
        .is_empty()
    );
    assert!(f.send(Action::GoBack { tab }).is_empty());
    assert!(f.send(Action::CloseTab { tab }).is_empty());
}

#[test]
fn pinning_is_derived_from_kind() {
    let mut f = Fixture::new();
    let tab = f.open();
    assert!(!f.session.browser.tab(tab).unwrap().is_pinned());

    f.send(Action::SetTabKind {
        tab,
        kind: TabKind::Pinned,
    });
    assert!(f.session.browser.tab(tab).unwrap().is_pinned());
}

#[test]
fn muting_reaches_the_engine() {
    let mut f = Fixture::new();
    let tab = f.open();

    let out = f.send(Action::SetTabMuted { tab, muted: true });

    assert_eq!(out, vec![EngineCommand::SetMuted { tab, muted: true }]);
    assert!(f.session.browser.tab(tab).unwrap().muted);
}

// --- navigation -------------------------------------------------------------

#[test]
fn navigation_lifecycle_settles_the_tab() {
    let mut f = Fixture::new();
    let tab = f.open();

    f.send(Action::NavigateTo {
        tab,
        input: "avelino.run".into(),
    });
    assert!(!f.session.browser.tab(tab).unwrap().loading_complete);

    f.send(Action::NavigationCommitted {
        tab,
        url: "https://avelino.run/".into(),
    });
    f.send(Action::TitleChanged {
        tab,
        title: "Avelino".into(),
    });
    f.send(Action::NavigationFinished { tab });

    let t = f.session.browser.tab(tab).unwrap();
    assert_eq!(t.url.as_deref(), Some("https://avelino.run/"));
    assert_eq!(t.pending_url, None);
    assert_eq!(t.title.as_deref(), Some("Avelino"));
    assert!(t.loading_complete);
}

#[test]
fn committing_a_new_page_drops_the_previous_title() {
    let mut f = Fixture::new();
    let tab = f.open();
    f.send(Action::TitleChanged {
        tab,
        title: "Old".into(),
    });

    f.send(Action::NavigationCommitted {
        tab,
        url: "https://b.com/".into(),
    });

    assert_eq!(
        f.session.browser.tab(tab).unwrap().title,
        None,
        "a stale title must not survive"
    );
}

#[test]
fn failed_navigation_clears_pending_state() {
    let mut f = Fixture::new();
    let tab = f.open();
    f.send(Action::NavigateTo {
        tab,
        input: "avelino.run".into(),
    });

    f.send(Action::NavigationFailed {
        tab,
        kind: NavigationErrorKind::Offline,
        message: "offline".into(),
    });

    let t = f.session.browser.tab(tab).unwrap();
    assert_eq!(t.pending_url, None);
    assert!(t.loading_complete);
}

/// A blank page is the same picture whether it failed, is still loading, or is
/// genuinely empty. The reason has to survive as state for the UI to say which.
#[test]
fn a_failure_records_why_and_where() {
    let mut f = Fixture::new();
    let tab = f.open();
    f.send(Action::NavigateTo {
        tab,
        input: "avelino.run".into(),
    });

    f.send(Action::NavigationFailed {
        tab,
        kind: NavigationErrorKind::HostNotFound,
        message: "A server with the specified hostname could not be found.".into(),
    });

    let error = f
        .session
        .browser
        .tab(tab)
        .unwrap()
        .last_error
        .clone()
        .expect("the reason must not be thrown away");
    assert_eq!(error.kind, NavigationErrorKind::HostNotFound);
    assert_eq!(
        error.url.as_deref(),
        Some("https://avelino.run"),
        "the address that failed is the only thing a retry can use"
    );
}

#[test]
fn a_successful_reload_clears_the_error() {
    let mut f = Fixture::new();
    let tab = f.open();
    f.send(Action::NavigateTo {
        tab,
        input: "avelino.run".into(),
    });
    f.send(Action::NavigationFailed {
        tab,
        kind: NavigationErrorKind::Offline,
        message: "offline".into(),
    });
    assert!(f.session.browser.tab(tab).unwrap().last_error.is_some());

    f.send(Action::NavigationStarted {
        tab,
        url: "https://avelino.run".into(),
    });
    assert_eq!(
        f.session.browser.tab(tab).unwrap().last_error,
        None,
        "an attempt in flight is not a failure"
    );

    f.send(Action::NavigationCommitted {
        tab,
        url: "https://avelino.run/".into(),
    });
    f.send(Action::NavigationFinished { tab });

    assert_eq!(
        f.session.browser.tab(tab).unwrap().last_error,
        None,
        "a tab that loaded must not keep showing an error"
    );
}

/// Downloads and redirects cancel the load that was in flight. Treating those
/// as failures would put an error screen over pages that are working.
#[test]
fn a_cancelled_navigation_is_not_an_error() {
    let mut f = Fixture::new();
    let tab = f.open();
    f.send(Action::NavigateTo {
        tab,
        input: "avelino.run/file.zip".into(),
    });

    f.send(Action::NavigationFailed {
        tab,
        kind: NavigationErrorKind::Cancelled,
        message: "frame load interrupted".into(),
    });

    let t = f.session.browser.tab(tab).unwrap();
    assert_eq!(t.last_error, None);
    assert!(t.loading_complete, "the tab still stopped loading");
}

/// The engine has nothing to reload when the load never committed, so a plain
/// reload command would be a button that does nothing.
#[test]
fn retrying_a_failed_navigation_reissues_the_load() {
    let mut f = Fixture::new();
    let tab = f.open();
    f.send(Action::NavigateTo {
        tab,
        input: "avelino.run".into(),
    });
    f.send(Action::NavigationFailed {
        tab,
        kind: NavigationErrorKind::Offline,
        message: "offline".into(),
    });

    let out = f.send(Action::Reload {
        tab,
        from_origin: false,
    });

    assert_eq!(
        out,
        vec![EngineCommand::LoadUrl {
            tab,
            url: "https://avelino.run".into()
        }]
    );
    assert_eq!(
        f.session.browser.tab(tab).unwrap().last_error,
        None,
        "the retry must take its own error screen down"
    );
}

#[test]
fn reloading_a_working_page_is_still_a_reload() {
    let mut f = Fixture::new();
    let tab = f.open();
    f.send(Action::NavigationCommitted {
        tab,
        url: "https://avelino.run/".into(),
    });

    let out = f.send(Action::Reload {
        tab,
        from_origin: true,
    });

    assert_eq!(
        out,
        vec![EngineCommand::Reload {
            tab,
            from_origin: true
        }]
    );
}

#[test]
fn a_failure_for_a_closed_tab_is_ignored() {
    let mut f = Fixture::new();
    let tab = f.open();
    f.send(Action::CloseTab { tab });

    // The engine reports asynchronously, so a load can fail after the user has
    // already closed the tab it was in.
    assert!(
        f.send(Action::NavigationFailed {
            tab,
            kind: NavigationErrorKind::Offline,
            message: "offline".into(),
        })
        .is_empty()
    );
    assert!(f.session.browser.tab(tab).is_none());
}

#[test]
fn typed_prose_becomes_a_search_not_a_navigation() {
    let mut f = Fixture::new();
    let tab = f.open();

    let out = f.send(Action::NavigateTo {
        tab,
        input: "how to build a browser".into(),
    });

    let EngineCommand::LoadUrl { url, .. } = &out[0] else {
        panic!("expected a load");
    };
    assert!(
        url.starts_with("https://www.google.com/search?q="),
        "got {url}"
    );
}

#[test]
fn the_search_engine_is_swappable() {
    let mut f = Fixture::new();
    f.session
        .browser
        .set_search_template("https://duckduckgo.com/?q={}");
    let tab = f.open();

    let out = f.send(Action::NavigateTo {
        tab,
        input: "webkit".into(),
    });

    let EngineCommand::LoadUrl { url, .. } = &out[0] else {
        panic!("expected a load");
    };
    assert_eq!(url, "https://duckduckgo.com/?q=webkit");
}

#[test]
fn committed_navigations_land_in_history() {
    let mut f = Fixture::new();
    let tab = f.open();

    f.send(Action::NavigationCommitted {
        tab,
        url: "https://avelino.run/".into(),
    });
    f.send(Action::TitleChanged {
        tab,
        title: "Avelino".into(),
    });

    let entry = f.session.history.get("https://avelino.run/").unwrap();
    assert_eq!(entry.visit_count, 1);
    assert_eq!(entry.title.as_deref(), Some("Avelino"));
}

// --- spaces -----------------------------------------------------------------

#[test]
fn a_new_space_starts_with_a_tab() {
    let mut f = Fixture::new();

    let out = f.send(Action::CreateSpace {
        name: "Work".into(),
        data_store_id: "ds-work".into(),
        ephemeral: false,
    });

    assert_eq!(f.session.browser.spaces().len(), 2);
    let work = f.session.browser.spaces()[1].id;
    assert_eq!(
        f.session.browser.tabs_in(work).len(),
        1,
        "an empty space is a dead end"
    );
    assert!(out.iter().any(|c| matches!(
        c,
        EngineCommand::CreateWebView {
            configuration: ViewConfiguration::Space { data_store_id, .. },
            ..
        } if data_store_id == "ds-work"
    )));
}

#[test]
fn each_space_keeps_its_own_cookie_jar() {
    let mut f = Fixture::new();
    f.send(Action::CreateSpace {
        name: "Work".into(),
        data_store_id: "ds-work".into(),
        ephemeral: false,
    });
    let work = f.session.browser.spaces()[1].id;

    let out = f.send(Action::OpenTab {
        space: Some(work),
        url: None,
        parent: None,
    });

    assert!(out.iter().any(|c| matches!(
        c,
        EngineCommand::CreateWebView {
            configuration: ViewConfiguration::Space { data_store_id, .. },
            ..
        } if data_store_id == "ds-work"
    )));
}

#[test]
fn returning_to_a_space_restores_the_tab_you_left_it_on() {
    let mut f = Fixture::new();
    let personal = f.session.browser.active_space();
    let first = f.open();
    let second = f.open();
    f.send(Action::ActivateTab { tab: second });

    let work = f.add_space("Work", "ds-work");
    assert_ne!(work, personal);

    f.send(Action::ActivateSpace { space: personal });

    assert_eq!(f.session.browser.active_tab(), Some(second));
    assert_ne!(f.session.browser.active_tab(), Some(first));
}

#[test]
fn closing_a_space_tears_down_its_tabs_and_its_data_store() {
    let mut f = Fixture::new();
    let work = f.add_space("Work", "ds-work");
    let doomed = f.session.browser.active_tab().unwrap();

    let out = f.send(Action::CloseSpace { space: work });

    assert!(out.contains(&EngineCommand::DestroyWebView { tab: doomed }));
    assert!(out.contains(&EngineCommand::DeleteDataStore {
        data_store_id: "ds-work".into()
    }));
    assert_eq!(f.session.browser.spaces().len(), 1);
    assert!(f.session.browser.tab(doomed).is_none());
}

#[test]
fn the_last_space_cannot_be_closed() {
    let mut f = Fixture::new();
    let only = f.session.browser.active_space();
    f.open();

    let out = f.send(Action::CloseSpace { space: only });

    assert!(out.is_empty());
    assert_eq!(
        f.session.browser.spaces().len(),
        1,
        "a browser needs somewhere to put tabs"
    );
}

#[test]
fn renaming_a_space_works_and_unknown_ids_are_ignored() {
    let mut f = Fixture::new();
    let space = f.session.browser.active_space();

    f.send(Action::RenameSpace {
        space,
        name: "Renamed".into(),
    });
    assert_eq!(f.session.browser.space(space).unwrap().name, "Renamed");

    f.send(Action::RenameSpace {
        space: crate::model::SpaceId(999),
        name: "Nope".into(),
    });
    assert_eq!(f.session.browser.space(space).unwrap().name, "Renamed");
}

// --- moving tabs ------------------------------------------------------------

#[test]
fn a_tab_can_be_reordered_within_its_space() {
    let mut f = Fixture::new();
    let first = f.open();
    let second = f.open();
    let third = f.open();
    let space = f.session.browser.active_space();

    f.send(Action::MoveTab {
        tab: third,
        space,
        index: 0,
    });

    let order: Vec<_> = f
        .session
        .browser
        .tabs_in(space)
        .iter()
        .map(|t| t.id)
        .collect();
    assert_eq!(order, vec![third, first, second]);
}

#[test]
fn an_out_of_range_index_clamps_instead_of_panicking() {
    let mut f = Fixture::new();
    let first = f.open();
    let space = f.session.browser.active_space();

    f.send(Action::MoveTab {
        tab: first,
        space,
        index: 9999,
    });

    assert_eq!(f.session.browser.index_in_space(first), Some(0));
}

#[test]
fn moving_a_tab_across_spaces_severs_a_parent_left_behind() {
    let mut f = Fixture::new();
    let parent = f.open();
    let child = f.open_child_of(parent);

    let work = f.add_space("Work", "ds-work");

    f.send(Action::MoveTab {
        tab: child,
        space: work,
        index: 0,
    });

    let moved = f.session.browser.tab(child).unwrap();
    assert_eq!(moved.space, work);
    assert_eq!(moved.parent, None, "a parent cannot live in another space");
}

#[test]
fn moving_a_parent_away_orphans_the_children_it_leaves() {
    let mut f = Fixture::new();
    let parent = f.open();
    let child = f.open_child_of(parent);

    let work = f.add_space("Work", "ds-work");

    f.send(Action::MoveTab {
        tab: parent,
        space: work,
        index: 0,
    });

    assert_eq!(f.session.browser.tab(child).unwrap().parent, None);
    assert_eq!(
        f.session.browser.tab(child).unwrap().space,
        f.session.browser.spaces()[0].id
    );
}

// --- dragging tabs ----------------------------------------------------------
//
// A drop says "this group, above this row". Everything below pins the
// translation from that into an order, because the sidebar shows three filtered
// lists and the order underneath them is one.

#[test]
fn a_drag_reorders_a_tab_inside_its_group() {
    let mut f = Fixture::new();
    let first = f.open();
    let second = f.open();
    let third = f.open();
    let space = f.session.browser.active_space();

    f.send(Action::MoveTabToGroup {
        tab: third,
        space,
        kind: TabKind::Today,
        before: Some(first),
    });

    assert_eq!(f.order_in(space), vec![third, first, second]);
}

#[test]
fn a_drag_downwards_lands_below_the_row_it_was_dropped_past() {
    let mut f = Fixture::new();
    let first = f.open();
    let second = f.open();
    let third = f.open();
    let space = f.session.browser.active_space();

    // Dropped above the third, from above it: the dragged tab is discounted
    // when the index is worked out, so this is "between second and third" and
    // not "one row short of it".
    f.send(Action::MoveTabToGroup {
        tab: first,
        space,
        kind: TabKind::Today,
        before: Some(third),
    });

    assert_eq!(f.order_in(space), vec![second, first, third]);
}

#[test]
fn dropping_a_tab_under_pinned_pins_it() {
    let mut f = Fixture::new();
    let tab = f.open();
    let space = f.session.browser.active_space();

    f.send(Action::MoveTabToGroup {
        tab,
        space,
        kind: TabKind::Pinned,
        before: None,
    });

    assert_eq!(f.session.browser.tab(tab).unwrap().kind, TabKind::Pinned);
}

#[test]
fn a_drop_at_the_end_of_a_group_stays_inside_that_group() {
    let mut f = Fixture::new();
    let favorite = f.open();
    let middle = f.open();
    let last = f.open();
    let space = f.session.browser.active_space();
    f.send(Action::SetTabKind {
        tab: favorite,
        kind: TabKind::Favorite,
    });

    f.send(Action::MoveTabToGroup {
        tab: last,
        space,
        kind: TabKind::Favorite,
        before: None,
    });

    // Straight after the only other favorite, not at the end of the space:
    // ⌃Tab and ⌘1..⌘9 walk this order, and a group scattered through it would
    // make both feel random.
    assert_eq!(f.order_in(space), vec![favorite, last, middle]);
    assert_eq!(f.session.browser.tab(last).unwrap().kind, TabKind::Favorite);
}

#[test]
fn a_drop_into_an_empty_group_still_lands_somewhere() {
    let mut f = Fixture::new();
    let first = f.open();
    let second = f.open();
    let space = f.session.browser.active_space();

    f.send(Action::MoveTabToGroup {
        tab: first,
        space,
        kind: TabKind::Favorite,
        before: None,
    });

    assert_eq!(
        f.session.browser.tab(first).unwrap().kind,
        TabKind::Favorite
    );
    assert_eq!(f.order_in(space), vec![second, first]);
}

#[test]
fn dropping_a_tab_on_another_space_moves_it_and_rebuilds_its_view() {
    let mut f = Fixture::new();
    let tab = f.open();
    f.send(Action::NavigationCommitted {
        tab,
        url: "https://avelino.run/".into(),
    });
    let work = f.add_space("Work", "ds-work");

    let out = f.send(Action::MoveTabToGroup {
        tab,
        space: work,
        kind: TabKind::Today,
        before: None,
    });

    assert_eq!(f.session.browser.tab(tab).unwrap().space, work);
    // ADR-0007: a web view cannot change data store, so crossing spaces costs
    // the view and the history behind it.
    assert!(out.contains(&EngineCommand::DestroyWebView { tab }));
    assert!(out.iter().any(|c| matches!(
        c,
        EngineCommand::CreateWebView {
            configuration: ViewConfiguration::Space { data_store_id, .. },
            ..
        } if data_store_id == "ds-work"
    )));
}

#[test]
fn reordering_by_drag_does_not_disturb_the_web_view() {
    let mut f = Fixture::new();
    let first = f.open();
    let second = f.open();
    let space = f.session.browser.active_space();

    let out = f.send(Action::MoveTabToGroup {
        tab: second,
        space,
        kind: TabKind::Today,
        before: Some(first),
    });

    assert!(
        out.is_empty(),
        "a reorder must not reload the page: {out:?}"
    );
}

#[test]
fn a_drop_above_a_row_that_lives_elsewhere_falls_back_to_the_end_of_the_group() {
    let mut f = Fixture::new();
    let personal = f.session.browser.active_space();
    let stays = f.open();
    let dragged = f.open();

    let work = f.add_space("Work", "ds-work");
    let elsewhere = f.session.browser.active_tab().unwrap();
    f.send(Action::ActivateSpace { space: personal });

    f.send(Action::MoveTabToGroup {
        tab: dragged,
        space: personal,
        kind: TabKind::Today,
        before: Some(elsewhere),
    });

    assert_eq!(f.order_in(personal), vec![stays, dragged]);
    assert_eq!(f.session.browser.tab(dragged).unwrap().space, personal);
    let _ = work;
}

#[test]
fn a_drop_naming_a_tab_that_is_gone_changes_nothing() {
    let mut f = Fixture::new();
    let tab = f.open();
    let space = f.session.browser.active_space();

    let out = f.send(Action::MoveTabToGroup {
        tab: TabId(9999),
        space,
        kind: TabKind::Favorite,
        before: None,
    });

    assert!(out.is_empty());
    assert_eq!(f.order_in(space), vec![tab]);
}

#[test]
fn a_drop_on_a_space_that_is_gone_leaves_the_tab_untouched() {
    let mut f = Fixture::new();
    let tab = f.open();

    let out = f.send(Action::MoveTabToGroup {
        tab,
        space: SpaceId(9999),
        kind: TabKind::Favorite,
        before: None,
    });

    assert!(out.is_empty());
    // The kind is applied after the move, so a refused move cannot pin a tab
    // that stayed where it was.
    assert_eq!(f.session.browser.tab(tab).unwrap().kind, TabKind::Today);
}

// --- the clock and archiving ------------------------------------------------

#[test]
fn an_untouched_today_tab_is_archived_once_it_ages_out() {
    let mut f = Fixture::new();
    f.send(Action::Tick { now_ms: 0 });
    let stale = f.open();
    let keeper = f.open();
    f.send(Action::ActivateTab { tab: keeper });

    let out = f.send(Action::Tick { now_ms: 13 * HOUR });

    assert!(out.contains(&EngineCommand::DestroyWebView { tab: stale }));
    assert!(f.session.browser.tab(stale).is_none());
    assert!(
        f.session.browser.tab(keeper).is_some(),
        "the active tab is never stale"
    );
}

#[test]
fn nothing_is_archived_before_the_window_elapses() {
    let mut f = Fixture::new();
    f.send(Action::Tick { now_ms: 0 });
    let tab = f.open();
    f.send(Action::ActivateTab { tab });
    let other = f.open();
    f.send(Action::ActivateTab { tab: other });

    let out = f.send(Action::Tick { now_ms: 11 * HOUR });

    assert!(out.is_empty());
    assert!(f.session.browser.tab(tab).is_some());
}

#[test]
fn pinned_and_favorite_tabs_never_expire() {
    let mut f = Fixture::new();
    f.send(Action::Tick { now_ms: 0 });
    let pinned = f.open();
    let favorite = f.open();
    let keeper = f.open();
    f.send(Action::SetTabKind {
        tab: pinned,
        kind: TabKind::Pinned,
    });
    f.send(Action::SetTabKind {
        tab: favorite,
        kind: TabKind::Favorite,
    });
    f.send(Action::ActivateTab { tab: keeper });

    f.send(Action::Tick {
        now_ms: 30 * 24 * HOUR,
    });

    assert!(f.session.browser.tab(pinned).is_some());
    assert!(f.session.browser.tab(favorite).is_some());
}

#[test]
fn using_a_tab_resets_its_clock() {
    let mut f = Fixture::new();
    f.send(Action::Tick { now_ms: 0 });
    let tab = f.open();
    let other = f.open();

    f.send(Action::Tick { now_ms: 10 * HOUR });
    f.send(Action::ActivateTab { tab });
    f.send(Action::ActivateTab { tab: other });

    // 13h since it opened, but only 3h since it was touched.
    let out = f.send(Action::Tick { now_ms: 13 * HOUR });

    assert!(out.is_empty());
    assert!(f.session.browser.tab(tab).is_some());
}

#[test]
fn archiving_the_active_tab_moves_focus_somewhere_real() {
    let mut f = Fixture::new();
    f.send(Action::Tick { now_ms: 0 });
    let pinned = f.open();
    f.send(Action::SetTabKind {
        tab: pinned,
        kind: TabKind::Pinned,
    });
    let ephemeral = f.open();
    f.send(Action::ActivateTab { tab: ephemeral });
    // Move focus away so the ephemeral tab is allowed to go stale.
    f.send(Action::ActivateTab { tab: pinned });
    f.send(Action::ActivateTab { tab: ephemeral });
    f.send(Action::Tick { now_ms: 1 });
    f.send(Action::ActivateTab { tab: pinned });

    f.send(Action::Tick { now_ms: 20 * HOUR });

    assert!(f.session.browser.tab(ephemeral).is_none());
    assert_eq!(f.session.browser.active_tab(), Some(pinned));
}

#[test]
fn a_late_tick_cannot_rewind_the_clock() {
    let mut f = Fixture::new();
    f.send(Action::Tick { now_ms: 100 * HOUR });

    f.send(Action::Tick { now_ms: 1 });

    assert_eq!(
        f.session.browser.now_ms(),
        100 * HOUR,
        "time must not run backwards"
    );
}

// --- air traffic ------------------------------------------------------------

/// Sets up "github.com routes to Work", leaving Personal active.
fn with_github_routed_to_work(f: &mut Fixture) -> (SpaceId, SpaceId) {
    let personal = f.session.browser.active_space();
    let work = f.add_space("Work", "ds-work");
    f.send(Action::AddRoute {
        pattern: RoutePattern::Domain {
            host: "github.com".into(),
        },
        space: work,
    });
    f.send(Action::ActivateSpace { space: personal });
    (personal, work)
}

#[test]
fn a_routed_url_opens_in_the_space_that_owns_it() {
    let mut f = Fixture::new();
    let (_, work) = with_github_routed_to_work(&mut f);
    let tab = f.open();

    f.send(Action::NavigateTo {
        tab,
        input: "github.com/avelino".into(),
    });

    let landed = f.session.browser.active_tab().unwrap();
    assert_eq!(f.session.browser.tab(landed).unwrap().space, work);
    assert_eq!(f.session.browser.active_space(), work);
}

#[test]
fn a_routed_page_loads_in_the_target_spaces_cookie_jar() {
    let mut f = Fixture::new();
    with_github_routed_to_work(&mut f);
    let tab = f.open();

    let out = f.send(Action::NavigateTo {
        tab,
        input: "github.com".into(),
    });

    // The whole point of routing: the page must never touch the wrong jar.
    assert!(out.iter().any(|c| matches!(
        c,
        EngineCommand::CreateWebView {
            configuration: ViewConfiguration::Space { data_store_id, .. },
            ..
        } if data_store_id == "ds-work"
    )));
    assert!(!out.iter().any(|c| matches!(
        c,
        EngineCommand::CreateWebView {
            configuration: ViewConfiguration::Space { data_store_id, .. },
            ..
        } if data_store_id == "ds-personal"
    )));
}

#[test]
fn routing_from_a_blank_tab_does_not_litter_the_old_space() {
    let mut f = Fixture::new();
    let (personal, _) = with_github_routed_to_work(&mut f);
    let blank = f.open();
    let before = f.session.browser.tabs_in(personal).len();

    let out = f.send(Action::NavigateTo {
        tab: blank,
        input: "github.com".into(),
    });

    assert!(out.contains(&EngineCommand::DestroyWebView { tab: blank }));
    assert_eq!(f.session.browser.tabs_in(personal).len(), before - 1);
}

#[test]
fn routing_away_from_a_used_tab_leaves_it_where_it_was() {
    let mut f = Fixture::new();
    with_github_routed_to_work(&mut f);
    let tab = f.open();
    f.send(Action::NavigationCommitted {
        tab,
        url: "https://avelino.run/".into(),
    });

    f.send(Action::NavigateTo {
        tab,
        input: "github.com".into(),
    });

    // You did not ask to lose the page you were reading.
    assert!(f.session.browser.tab(tab).is_some());
    assert_eq!(
        f.session.browser.tab(tab).unwrap().url.as_deref(),
        Some("https://avelino.run/")
    );
}

#[test]
fn a_url_already_in_its_own_space_is_not_bounced_again() {
    let mut f = Fixture::new();
    let (_, work) = with_github_routed_to_work(&mut f);
    f.send(Action::ActivateSpace { space: work });
    let tab = f.session.browser.active_tab().unwrap();
    let count_before = f.session.browser.tab_count();

    let out = f.send(Action::NavigateTo {
        tab,
        input: "github.com".into(),
    });

    // This is the loop guard: no new tab, just a plain load.
    assert_eq!(f.session.browser.tab_count(), count_before);
    assert!(matches!(out.as_slice(), [EngineCommand::LoadUrl { .. }]));
}

#[test]
fn opening_a_tab_with_a_routed_url_lands_in_the_right_space() {
    let mut f = Fixture::new();
    let (personal, work) = with_github_routed_to_work(&mut f);

    f.send(Action::OpenTab {
        space: Some(personal),
        url: Some("github.com".into()),
        parent: None,
    });

    let tab = f.session.browser.active_tab().unwrap();
    assert_eq!(f.session.browser.tab(tab).unwrap().space, work);
}

#[test]
fn a_search_is_not_routed_by_a_rule_meant_for_a_site() {
    let mut f = Fixture::new();
    let (personal, _) = with_github_routed_to_work(&mut f);
    let tab = f.open();

    f.send(Action::NavigateTo {
        tab,
        input: "github rust bindings".into(),
    });

    // Typed prose becomes a Google search, which is not github.com.
    assert_eq!(f.session.browser.tab(tab).unwrap().space, personal);
}

#[test]
fn rules_for_a_deleted_space_are_dropped_with_it() {
    let mut f = Fixture::new();
    let (_, work) = with_github_routed_to_work(&mut f);
    assert_eq!(f.session.routes.routes().len(), 1);

    f.send(Action::CloseSpace { space: work });

    assert!(
        f.session.routes.routes().is_empty(),
        "a rule pointing at a deleted space would route into the void"
    );
}

#[test]
fn a_rule_for_an_unknown_space_is_refused() {
    let mut f = Fixture::new();

    f.send(Action::AddRoute {
        pattern: RoutePattern::Domain {
            host: "github.com".into(),
        },
        space: SpaceId(999),
    });

    assert!(f.session.routes.routes().is_empty());
}

// --- space profiles ---------------------------------------------------------

#[test]
fn a_profile_change_rebuilds_the_spaces_web_views() {
    let mut f = Fixture::new();
    let space = f.session.browser.active_space();
    let tab = f.open();
    f.send(Action::NavigationCommitted {
        tab,
        url: "https://avelino.run/".into(),
    });

    let out = f.send(Action::SetSpaceProfile {
        space,
        profile: SpaceProfile {
            user_agent: Some("zer0/0.1".into()),
            ephemeral: false,
        },
    });

    // A user agent is baked in at creation, so the view has to be rebuilt and
    // the page reloaded for the change to mean anything.
    assert!(out.contains(&EngineCommand::DestroyWebView { tab }));
    assert!(out.iter().any(|c| matches!(
        c,
        EngineCommand::CreateWebView {
            configuration: ViewConfiguration::Space { profile, .. },
            ..
        } if profile.user_agent.as_deref() == Some("zer0/0.1")
    )));
    assert!(out.contains(&EngineCommand::LoadUrl {
        tab,
        url: "https://avelino.run/".into()
    }));
}

#[test]
fn an_ephemeral_profile_reaches_the_engine() {
    let mut f = Fixture::new();
    let space = f.session.browser.active_space();
    f.send(Action::SetSpaceProfile {
        space,
        profile: SpaceProfile {
            user_agent: None,
            ephemeral: true,
        },
    });

    let out = f.send(Action::OpenTab {
        space: None,
        url: None,
        parent: None,
    });

    assert!(out.iter().any(|c| matches!(
        c,
        EngineCommand::CreateWebView {
            configuration: ViewConfiguration::Space { profile, .. },
            ..
        } if profile.ephemeral
    )));
}

#[test]
fn dragging_a_tab_to_another_space_rebuilds_it_in_the_new_jar() {
    let mut f = Fixture::new();
    let personal = f.session.browser.active_space();
    let tab = f.open();
    f.send(Action::NavigationCommitted {
        tab,
        url: "https://avelino.run/".into(),
    });
    let work = f.add_space("Work", "ds-work");
    f.send(Action::ActivateSpace { space: personal });

    let out = f.send(Action::MoveTab {
        tab,
        space: work,
        index: 0,
    });

    assert!(out.contains(&EngineCommand::DestroyWebView { tab }));
    assert!(out.iter().any(|c| matches!(
        c,
        EngineCommand::CreateWebView {
            configuration: ViewConfiguration::Space { data_store_id, .. },
            ..
        } if data_store_id == "ds-work"
    )));
}

#[test]
fn reordering_inside_a_space_does_not_disturb_the_web_view() {
    let mut f = Fixture::new();
    let first = f.open();
    let second = f.open();
    let space = f.session.browser.active_space();

    let out = f.send(Action::MoveTab {
        tab: second,
        space,
        index: 0,
    });

    assert!(
        out.is_empty(),
        "a reorder must not reload the page: {out:?}"
    );
    assert_eq!(f.session.browser.index_in_space(second), Some(0));
    assert_eq!(f.session.browser.index_in_space(first), Some(1));
}

// --- two pages at once ------------------------------------------------------

#[test]
fn splitting_pairs_the_active_tab_with_the_next_one() {
    let mut f = Fixture::new();
    let first = f.open();
    let second = f.open();
    f.send(Action::ActivateTab { tab: first });

    f.send(Action::ToggleSplit);

    let split = f.session.browser.active_split().expect("a split is up");
    assert_eq!(split.leading, first);
    assert_eq!(split.trailing, second);
    // The tab already in hand keeps the keyboard.
    assert_eq!(f.session.browser.active_tab(), Some(first));
}

#[test]
fn splitting_again_puts_the_pair_away() {
    let mut f = Fixture::new();
    let first = f.open();
    f.open();
    f.send(Action::ActivateTab { tab: first });
    f.send(Action::ToggleSplit);

    let out = f.send(Action::ToggleSplit);

    assert!(f.session.browser.active_split().is_none());
    // The pane you were reading takes the area; nothing is reloaded and
    // nothing moves.
    assert_eq!(f.session.browser.active_tab(), Some(first));
    assert!(
        out.is_empty(),
        "dismissing must not touch the engine: {out:?}"
    );
}

#[test]
fn splitting_with_nothing_to_pair_with_opens_the_second_pane() {
    let mut f = Fixture::new();
    let only = f.open();

    let out = f.send(Action::ToggleSplit);

    let split = f.session.browser.active_split().expect("a split is up");
    assert_eq!(split.leading, only);
    assert_ne!(split.trailing, only);
    // A blank pane is where you are about to type, so the keyboard follows it.
    assert_eq!(f.session.browser.active_tab(), Some(split.trailing));
    assert!(out.iter().any(|c| matches!(
        c,
        EngineCommand::CreateWebView { tab, .. } if *tab == split.trailing
    )));
}

#[test]
fn a_named_tab_can_be_brought_in_beside_the_current_one() {
    let mut f = Fixture::new();
    let first = f.open();
    f.open();
    let third = f.open();
    f.send(Action::ActivateTab { tab: first });

    f.send(Action::SplitWith { tab: third });

    let split = f.session.browser.active_split().expect("a split is up");
    assert_eq!((split.leading, split.trailing), (first, third));
    // You named it, so it is the one you meant to look at.
    assert_eq!(f.session.browser.active_tab(), Some(third));
}

#[test]
fn a_tab_from_another_space_cannot_be_brought_into_the_split() {
    let mut f = Fixture::new();
    let personal = f.session.browser.active_space();
    let mine = f.open();
    let work = f.add_space("Work", "ds-work");
    let theirs = f.session.browser.active_tab().unwrap();
    f.send(Action::ActivateSpace { space: personal });
    f.send(Action::ActivateTab { tab: mine });

    let out = f.send(Action::SplitWith { tab: theirs });

    // Two panes drawing from two cookie jars would be one window claiming to
    // be two.
    assert!(f.session.browser.active_split().is_none());
    assert!(f.session.browser.split(work).is_none());
    assert!(out.is_empty());
}

#[test]
fn the_keyboard_crosses_the_split_without_touching_the_mouse() {
    let mut f = Fixture::new();
    let first = f.open();
    let second = f.open();
    f.send(Action::ActivateTab { tab: first });
    f.send(Action::ToggleSplit);

    let out = f.send(Action::FocusOtherPane);

    assert_eq!(f.session.browser.active_tab(), Some(second));
    assert_eq!(out, vec![EngineCommand::FocusWebView { tab: second }]);
    // And back, which is what makes one binding enough for two panes.
    f.send(Action::FocusOtherPane);
    assert_eq!(f.session.browser.active_tab(), Some(first));
    // Crossing the split does not dismiss it.
    assert!(f.session.browser.active_split().is_some());
}

#[test]
fn moving_between_panes_does_nothing_when_there_is_no_split() {
    let mut f = Fixture::new();
    let only = f.open();

    let out = f.send(Action::FocusOtherPane);

    assert_eq!(f.session.browser.active_tab(), Some(only));
    assert!(out.is_empty());
}

#[test]
fn closing_one_side_gives_the_other_the_whole_area() {
    let mut f = Fixture::new();
    let first = f.open();
    let second = f.open();
    let third = f.open();
    f.send(Action::ActivateTab { tab: first });
    f.send(Action::SplitWith { tab: third });

    let out = f.send(Action::CloseTab { tab: third });

    assert!(f.session.browser.active_split().is_none());
    // The survivor, not whatever row sits below in the sidebar: `second` is
    // the ordinary successor here and it is not even on screen.
    assert_ne!(f.session.browser.active_tab(), Some(second));
    assert_eq!(f.session.browser.active_tab(), Some(first));
    assert!(out.contains(&EngineCommand::FocusWebView { tab: first }));
}

#[test]
fn going_to_a_third_tab_puts_the_split_away() {
    let mut f = Fixture::new();
    let first = f.open();
    let second = f.open();
    let third = f.open();
    f.send(Action::ActivateTab { tab: first });
    f.send(Action::SplitWith { tab: second });

    f.send(Action::ActivateTab { tab: third });

    // Otherwise the sidebar would mark a row as selected that is not on screen.
    assert!(f.session.browser.active_split().is_none());
    assert_eq!(f.session.browser.active_tab(), Some(third));
}

#[test]
fn leaving_a_space_and_coming_back_finds_the_split_where_it_was() {
    let mut f = Fixture::new();
    let personal = f.session.browser.active_space();
    let first = f.open();
    let second = f.open();
    f.send(Action::ActivateTab { tab: first });
    f.send(Action::SplitWith { tab: second });

    let work = f.add_space("Work", "ds-work");
    assert!(
        f.session.browser.split(work).is_none(),
        "a new space is one pane"
    );
    f.send(Action::ActivateSpace { space: personal });

    let split = f
        .session
        .browser
        .active_split()
        .expect("the pair is still up");
    assert_eq!((split.leading, split.trailing), (first, second));
}

#[test]
fn dragging_a_pane_into_another_space_ends_the_split() {
    let mut f = Fixture::new();
    let personal = f.session.browser.active_space();
    let first = f.open();
    let second = f.open();
    f.send(Action::ActivateTab { tab: first });
    f.send(Action::SplitWith { tab: second });
    let work = f.add_space("Work", "ds-work");

    f.send(Action::MoveTab {
        tab: second,
        space: work,
        index: 0,
    });

    assert!(f.session.browser.split(personal).is_none());
}

#[test]
fn the_divider_cannot_be_dragged_past_either_edge() {
    let mut f = Fixture::new();
    let space = f.session.browser.active_space();
    let first = f.open();
    f.open();
    f.send(Action::ActivateTab { tab: first });
    f.send(Action::ToggleSplit);

    f.send(Action::SetSplitRatio { space, ratio: 0.98 });
    assert_eq!(
        f.session.browser.split(space).unwrap().ratio,
        MAX_SPLIT_RATIO
    );

    f.send(Action::SetSplitRatio { space, ratio: -3.0 });
    assert_eq!(
        f.session.browser.split(space).unwrap().ratio,
        MIN_SPLIT_RATIO
    );

    // A width of NaN lays out as nothing at all, and it survives clamp.
    f.send(Action::SetSplitRatio {
        space,
        ratio: f64::NAN,
    });
    assert_eq!(
        f.session.browser.split(space).unwrap().ratio,
        DEFAULT_SPLIT_RATIO
    );
}

#[test]
fn a_tab_cannot_be_split_with_itself() {
    let mut f = Fixture::new();
    let only = f.open();

    let out = f.send(Action::SplitWith { tab: only });

    assert!(f.session.browser.active_split().is_none());
    assert!(out.is_empty());
}

#[test]
fn a_split_restored_with_a_missing_pane_is_dropped() {
    let mut f = Fixture::new();
    let first = f.open();
    let second = f.open();
    f.send(Action::ActivateTab { tab: first });
    f.send(Action::SplitWith { tab: second });

    let spaces = f.session.browser.spaces().to_vec();
    // Everything the browser knows, minus one pane: what a half-written or
    // hand-edited session file looks like.
    let tabs: Vec<_> = f
        .session
        .browser
        .all_tabs()
        .into_iter()
        .filter(|t| t.id != second)
        .cloned()
        .collect();

    // The window comes back looking at the pane that survived.
    let windows: Vec<_> = f
        .session
        .browser
        .windows()
        .iter()
        .cloned()
        .map(|mut w| {
            w.active_tab = Some(first);
            w
        })
        .collect();
    let key = f.session.browser.key_window();
    let restored = Browser::restore(spaces, tabs, windows, key)
        .expect("a browser with a space is representable");
    assert_eq!(restored.active_tab(), Some(first));

    assert!(restored.active_split().is_none());
}

// --- shortcut-driven actions ------------------------------------------------

#[test]
fn cycling_tabs_wraps_at_both_ends() {
    let mut f = Fixture::new();
    let first = f.open();
    let second = f.open();
    let third = f.open();
    f.send(Action::ActivateTab { tab: first });

    f.send(Action::CycleTab { delta: 1 });
    assert_eq!(f.session.browser.active_tab(), Some(second));

    f.send(Action::CycleTab { delta: 1 });
    f.send(Action::CycleTab { delta: 1 });
    assert_eq!(f.session.browser.active_tab(), Some(first), "wraps forward");

    f.send(Action::CycleTab { delta: -1 });
    assert_eq!(
        f.session.browser.active_tab(),
        Some(third),
        "wraps backward"
    );
}

#[test]
fn cycling_stays_inside_the_active_space() {
    let mut f = Fixture::new();
    let personal = f.session.browser.active_space();
    let only_here = f.open();
    f.add_space("Work", "ds-work");
    let work_tab = f.session.browser.active_tab().unwrap();

    f.send(Action::CycleTab { delta: 1 });

    // A cycle that jumped spaces would cross a cookie-jar boundary.
    assert_eq!(f.session.browser.active_tab(), Some(work_tab));
    assert_ne!(f.session.browser.active_tab(), Some(only_here));
    assert_eq!(
        f.session.browser.active_space(),
        f.session.browser.active_space()
    );
    let _ = personal;
}

#[test]
fn selecting_a_tab_by_number_is_one_based() {
    let mut f = Fixture::new();
    let first = f.open();
    let second = f.open();

    f.send(Action::SelectTabByIndex { index: 1 });
    assert_eq!(f.session.browser.active_tab(), Some(first));

    f.send(Action::SelectTabByIndex { index: 2 });
    assert_eq!(f.session.browser.active_tab(), Some(second));
}

#[test]
fn selecting_past_the_end_lands_on_the_last_tab() {
    let mut f = Fixture::new();
    f.open();
    let last = f.open();

    // This is what ⌘9 is for.
    f.send(Action::SelectTabByIndex { index: 9 });

    assert_eq!(f.session.browser.active_tab(), Some(last));
}

#[test]
fn the_ninth_slot_is_the_last_tab_however_many_are_open() {
    let mut f = Fixture::new();
    // Twelve, so "the ninth" and "the last" are different tabs and clamping
    // cannot accidentally pass. This is the case ADR-0011 warns about: with
    // nine tabs or fewer, a literal ninth and the last one look identical, and
    // only people who keep a lot of tabs would ever notice the difference.
    let mut opened = Vec::new();
    for _ in 0..12 {
        opened.push(f.open());
    }

    f.send(Action::SelectTabByIndex { index: 9 });

    assert_eq!(f.session.browser.active_tab(), opened.last().copied());
    assert_ne!(
        f.session.browser.active_tab(),
        Some(opened[8]),
        "⌘9 is 'the last tab', not 'the ninth tab'"
    );
}

#[test]
fn the_lower_slots_stay_literal() {
    let mut f = Fixture::new();
    let mut opened = Vec::new();
    for _ in 0..12 {
        opened.push(f.open());
    }

    // Only the ninth slot carries the special meaning. ⌘8 is the eighth tab
    // even when there are twelve.
    f.send(Action::SelectTabByIndex { index: 8 });

    assert_eq!(f.session.browser.active_tab(), Some(opened[7]));
}

#[test]
fn selecting_tab_zero_does_nothing() {
    let mut f = Fixture::new();
    let only = f.open();

    f.send(Action::SelectTabByIndex { index: 0 });

    assert_eq!(f.session.browser.active_tab(), Some(only));
}

#[test]
fn reopening_brings_back_the_last_closed_tab() {
    let mut f = Fixture::new();
    let tab = f.open();
    f.send(Action::NavigationCommitted {
        tab,
        url: "https://avelino.run/".into(),
    });

    f.send(Action::CloseTab { tab });
    f.send(Action::ReopenClosedTab);

    let reopened = f.session.browser.active_tab().unwrap();
    assert_eq!(
        f.session
            .browser
            .tab(reopened)
            .unwrap()
            .pending_url
            .as_deref(),
        Some("https://avelino.run/")
    );
}

#[test]
fn reopening_restores_a_pinned_tab_as_pinned() {
    let mut f = Fixture::new();
    let tab = f.open();
    f.send(Action::NavigationCommitted {
        tab,
        url: "https://avelino.run/".into(),
    });
    f.send(Action::SetTabKind {
        tab,
        kind: TabKind::Pinned,
    });

    f.send(Action::CloseTab { tab });
    f.send(Action::ReopenClosedTab);

    let reopened = f.session.browser.active_tab().unwrap();
    assert_eq!(
        f.session.browser.tab(reopened).unwrap().kind,
        TabKind::Pinned
    );
}

#[test]
fn reopening_works_backwards_through_several_closes() {
    let mut f = Fixture::new();
    for url in ["https://a.com/", "https://b.com/"] {
        let tab = f.open();
        f.send(Action::NavigationCommitted {
            tab,
            url: url.into(),
        });
        f.send(Action::CloseTab { tab });
    }

    f.send(Action::ReopenClosedTab);
    let newest = f.session.browser.active_tab().unwrap();
    assert_eq!(
        f.session
            .browser
            .tab(newest)
            .unwrap()
            .pending_url
            .as_deref(),
        Some("https://b.com/")
    );

    f.send(Action::ReopenClosedTab);
    let older = f.session.browser.active_tab().unwrap();
    assert_eq!(
        f.session.browser.tab(older).unwrap().pending_url.as_deref(),
        Some("https://a.com/")
    );
}

#[test]
fn a_blank_tab_is_not_worth_reopening() {
    let mut f = Fixture::new();
    let blank = f.open();

    f.send(Action::CloseTab { tab: blank });
    let out = f.send(Action::ReopenClosedTab);

    assert!(
        out.is_empty(),
        "nothing was lost, so there is nothing to restore"
    );
}

#[test]
fn reopening_with_nothing_closed_does_nothing() {
    let mut f = Fixture::new();
    assert!(f.send(Action::ReopenClosedTab).is_empty());
}

#[test]
fn a_tab_whose_space_is_gone_reopens_where_you_are() {
    let mut f = Fixture::new();
    let work = f.add_space("Work", "ds-work");
    let tab = f.session.browser.active_tab().unwrap();
    f.send(Action::NavigationCommitted {
        tab,
        url: "https://avelino.run/".into(),
    });
    f.send(Action::CloseTab { tab });
    f.send(Action::CloseSpace { space: work });

    f.send(Action::ReopenClosedTab);

    let reopened = f.session.browser.active_tab().unwrap();
    let landed = f.session.browser.tab(reopened).unwrap().space;
    assert!(
        f.session.browser.space(landed).is_some(),
        "must land somewhere real"
    );
}

#[test]
fn cycling_spaces_wraps() {
    let mut f = Fixture::new();
    let personal = f.session.browser.active_space();
    let work = f.add_space("Work", "ds-work");

    f.send(Action::CycleSpace { delta: 1 });
    assert_eq!(f.session.browser.active_space(), personal, "wraps forward");

    f.send(Action::CycleSpace { delta: -1 });
    assert_eq!(f.session.browser.active_space(), work, "wraps backward");
}

/// ⌃1..⌃9. The chips are drawn in `spaces()` order, so the digits count
/// through that same list — the shell drawing one order while the chords
/// counted another would send ⌃3 somewhere nothing on screen points at.
#[test]
fn a_digit_goes_straight_to_the_space_in_that_position() {
    let mut f = Fixture::new();
    let personal = f.session.browser.active_space();
    let work = f.add_space("Work", "ds-work");
    let side = f.add_space("Side", "ds-side");

    f.send(Action::SelectSpaceByIndex { index: 1 });
    assert_eq!(f.session.browser.active_space(), personal);

    f.send(Action::SelectSpaceByIndex { index: 3 });
    assert_eq!(f.session.browser.active_space(), side);

    f.send(Action::SelectSpaceByIndex { index: 2 });
    assert_eq!(f.session.browser.active_space(), work);
}

/// The ninth slot is the ninth space, not "the last one". Clamping would put
/// somebody in a space they did not name, and unlike ⌘9 for tabs there is no
/// browser anywhere that taught the finger otherwise.
#[test]
fn a_digit_past_the_last_space_moves_nobody() {
    let mut f = Fixture::new();
    let personal = f.session.browser.active_space();
    let work = f.add_space("Work", "ds-work");
    f.send(Action::SelectSpaceByIndex { index: 1 });
    assert_eq!(f.session.browser.active_space(), personal);

    for index in [3u32, 9, 0, u32::MAX] {
        assert!(
            f.send(Action::SelectSpaceByIndex { index }).is_empty(),
            "index {index} named nothing and must do nothing"
        );
        assert_eq!(
            f.session.browser.active_space(),
            personal,
            "index {index} moved somebody"
        );
    }

    // And the one that does name something still works, so the guard above is
    // not just refusing everything.
    f.send(Action::SelectSpaceByIndex { index: 2 });
    assert_eq!(f.session.browser.active_space(), work);
}

#[test]
fn zoom_reaches_the_engine_and_is_clamped() {
    let mut f = Fixture::new();
    let tab = f.open();

    let out = f.send(Action::SetTabZoom { tab, factor: 1.5 });
    assert_eq!(out, vec![EngineCommand::SetZoom { tab, factor: 1.5 }]);
    assert_eq!(f.session.browser.tab(tab).unwrap().zoom_factor, 1.5);

    // A stuck key must not leave the page unreadable.
    f.send(Action::SetTabZoom { tab, factor: 500.0 });
    assert_eq!(f.session.browser.tab(tab).unwrap().zoom_factor, 5.0);
    f.send(Action::SetTabZoom { tab, factor: 0.0 });
    assert_eq!(f.session.browser.tab(tab).unwrap().zoom_factor, 0.25);
}

// --- privacy and input validation -------------------------------------------

#[test]
fn an_ephemeral_space_keeps_its_pages_out_of_history() {
    let mut f = Fixture::new();
    let space = f.session.browser.active_space();
    f.send(Action::SetSpaceProfile {
        space,
        profile: SpaceProfile {
            user_agent: None,
            ephemeral: true,
        },
    });
    let tab = f.open();

    f.send(Action::NavigationCommitted {
        tab,
        url: "https://very-private.example/secret".into(),
    });

    // History goes to disk. A space that promised to leave no trace cannot
    // write every URL you visited in it there.
    assert!(
        f.session.history.is_empty(),
        "ephemeral browsing leaked into history: {:?}",
        f.session.history
    );
}

#[test]
fn an_ordinary_space_still_records_history() {
    let mut f = Fixture::new();
    let tab = f.open();

    f.send(Action::NavigationCommitted {
        tab,
        url: "https://avelino.run/".into(),
    });

    assert!(f.session.history.get("https://avelino.run/").is_some());
}

// --- site icons -------------------------------------------------------------

/// A tab sitting on a page, which is the state an icon is declared from.
fn on_page(f: &mut Fixture, url: &str) -> TabId {
    let tab = f.open();
    f.send(Action::NavigationCommitted {
        tab,
        url: url.into(),
    });
    tab
}

fn make_ephemeral(f: &mut Fixture, space: SpaceId) {
    f.send(Action::SetSpaceProfile {
        space,
        profile: SpaceProfile {
            user_agent: None,
            ephemeral: true,
        },
    });
}

fn png() -> Vec<u8> {
    let mut bytes = b"\x89PNG\r\n\x1a\n".to_vec();
    bytes.extend_from_slice(b"pixels");
    bytes
}

#[test]
fn an_ephemeral_space_is_never_told_to_fetch_an_icon() {
    let mut f = Fixture::new();
    let space = f.session.browser.active_space();
    make_ephemeral(&mut f, space);
    let tab = on_page(&mut f, "https://very-private.example/secret");

    let out = f.send(Action::IconsDeclared {
        tab,
        candidates: vec![IconCandidate {
            url: "https://very-private.example/icon.png".into(),
            size_px: Some(32),
        }],
    });

    // Fetching an icon is a request the site sees, from an address that just
    // loaded a page there. A space that promised to leave nothing behind
    // cannot make it, and the refusal has to be here — at the request — rather
    // than in the interface, which is not where the packet leaves from.
    assert!(
        out.is_empty(),
        "an ephemeral space reached the network for an icon: {out:?}"
    );
    assert!(f.session.icons.is_empty());
}

#[test]
fn an_ordinary_space_is_told_to_fetch_its_icon() {
    let mut f = Fixture::new();
    let tab = on_page(&mut f, "https://avelino.run/posts/one");

    let out = f.send(Action::IconsDeclared {
        tab,
        candidates: vec![
            IconCandidate {
                url: "https://avelino.run/16.png".into(),
                size_px: Some(16),
            },
            IconCandidate {
                url: "https://avelino.run/32.png".into(),
                size_px: Some(32),
            },
        ],
    });

    assert_eq!(
        out,
        vec![EngineCommand::FetchIcon {
            data_store_id: "ds-personal".into(),
            host: "avelino.run".into(),
            url: "https://avelino.run/32.png".into(),
            max_bytes: crate::icons::MAX_ICON_BYTES,
        }]
    );
}

#[test]
fn an_ephemeral_space_records_nothing_even_if_the_host_hands_us_bytes() {
    let mut f = Fixture::new();
    let space = f.session.browser.active_space();
    make_ephemeral(&mut f, space);

    // The host should never send this, because it was never told to fetch.
    // Refusing it anyway is the second lock on the same promise: ADR-0023's
    // standing risk is a new writer that forgets to ask the question.
    f.send(Action::IconFetched {
        data_store_id: "ds-personal".into(),
        host: "very-private.example".into(),
        bytes: png(),
    });

    assert!(f.session.icons.is_empty());
}

#[test]
fn a_cookie_jar_no_space_owns_is_not_a_place_to_write_to() {
    let mut f = Fixture::new();

    f.send(Action::IconFetched {
        data_store_id: "ds-that-never-existed".into(),
        host: "a.com".into(),
        bytes: png(),
    });

    assert!(f.session.icons.is_empty());
}

#[test]
fn a_page_that_is_not_on_the_web_is_never_fetched_for() {
    let mut f = Fixture::new();
    let tab = on_page(&mut f, "file:///Users/me/notes.html");

    let out = f.send(Action::IconsDeclared {
        tab,
        candidates: Vec::new(),
    });

    assert!(out.is_empty());
}

#[test]
fn a_tab_that_has_not_committed_anything_declares_nothing() {
    let mut f = Fixture::new();
    let tab = f.open();

    let out = f.send(Action::IconsDeclared {
        tab,
        candidates: Vec::new(),
    });

    assert!(out.is_empty());
}

#[test]
fn one_site_is_asked_once_however_many_tabs_are_open_on_it() {
    let mut f = Fixture::new();
    let first = on_page(&mut f, "https://avelino.run/a");
    let second = on_page(&mut f, "https://avelino.run/b");

    let out = f.send(Action::IconsDeclared {
        tab: first,
        candidates: Vec::new(),
    });
    assert_eq!(out.len(), 1);

    // The first request is still out. Ten tabs restoring at launch must not be
    // ten requests to the same server.
    let again = f.send(Action::IconsDeclared {
        tab: second,
        candidates: Vec::new(),
    });
    assert!(again.is_empty(), "asked the same site twice: {again:?}");
}

#[test]
fn an_answer_is_not_asked_for_again() {
    let mut f = Fixture::new();
    let tab = on_page(&mut f, "https://avelino.run/a");
    f.send(Action::IconsDeclared {
        tab,
        candidates: Vec::new(),
    });

    f.send(Action::IconFetched {
        data_store_id: "ds-personal".into(),
        host: "avelino.run".into(),
        bytes: png(),
    });

    let again = f.send(Action::IconsDeclared {
        tab,
        candidates: Vec::new(),
    });
    assert!(again.is_empty());
}

#[test]
fn a_failed_fetch_falls_back_rather_than_blanking_the_row() {
    let mut f = Fixture::new();
    let tab = on_page(&mut f, "https://avelino.run/a");
    f.send(Action::IconsDeclared {
        tab,
        candidates: Vec::new(),
    });

    f.send(Action::IconFetchFailed {
        data_store_id: "ds-personal".into(),
        host: "avelino.run".into(),
    });

    // Nothing to draw, which is what puts the letter back. A row that had an
    // empty square instead would be worse than the placeholder it replaced.
    assert_eq!(
        f.session
            .icons
            .bytes(&crate::icons::IconKey::new("ds-personal", "avelino.run")),
        None
    );
    // And it is not asked again on the next navigation.
    let again = f.send(Action::IconsDeclared {
        tab,
        candidates: Vec::new(),
    });
    assert!(again.is_empty());
}

#[test]
fn a_404_page_served_as_an_icon_is_refused_and_remembered_as_nothing() {
    let mut f = Fixture::new();
    let tab = on_page(&mut f, "https://avelino.run/a");
    f.send(Action::IconsDeclared {
        tab,
        candidates: Vec::new(),
    });

    f.send(Action::IconFetched {
        data_store_id: "ds-personal".into(),
        host: "avelino.run".into(),
        bytes: b"<!DOCTYPE html><html><body>404</body></html>".to_vec(),
    });

    assert_eq!(
        f.session
            .icons
            .bytes(&crate::icons::IconKey::new("ds-personal", "avelino.run")),
        None
    );
    let again = f.send(Action::IconsDeclared {
        tab,
        candidates: Vec::new(),
    });
    assert!(
        again.is_empty(),
        "a site serving HTML for its favicon would be asked forever"
    );
}

#[test]
fn an_oversized_response_is_refused() {
    let mut f = Fixture::new();
    let tab = on_page(&mut f, "https://avelino.run/a");
    f.send(Action::IconsDeclared {
        tab,
        candidates: Vec::new(),
    });

    let mut huge = b"\x89PNG\r\n\x1a\n".to_vec();
    huge.resize(crate::icons::MAX_ICON_BYTES as usize + 1, 0);
    f.send(Action::IconFetched {
        data_store_id: "ds-personal".into(),
        host: "avelino.run".into(),
        bytes: huge,
    });

    assert_eq!(
        f.session
            .icons
            .bytes(&crate::icons::IconKey::new("ds-personal", "avelino.run")),
        None
    );
}

#[test]
fn two_spaces_each_fetch_their_own_copy() {
    let mut f = Fixture::new();
    let first = on_page(&mut f, "https://avelino.run/a");
    f.send(Action::IconsDeclared {
        tab: first,
        candidates: Vec::new(),
    });
    f.send(Action::IconFetched {
        data_store_id: "ds-personal".into(),
        host: "avelino.run".into(),
        bytes: png(),
    });

    f.add_space("Work", "ds-work");
    let second = on_page(&mut f, "https://avelino.run/a");

    let out = f.send(Action::IconsDeclared {
        tab: second,
        candidates: Vec::new(),
    });

    // Serving the second space from the first space's cache would mean no
    // request goes out — and the missing request is itself a signal the site
    // can read: "this browser has already been here, as somebody else".
    assert_eq!(
        out,
        vec![EngineCommand::FetchIcon {
            data_store_id: "ds-work".into(),
            host: "avelino.run".into(),
            url: "https://avelino.run/favicon.ico".into(),
            max_bytes: crate::icons::MAX_ICON_BYTES,
        }]
    );
}

#[test]
fn closing_a_space_takes_its_icons_with_it() {
    let mut f = Fixture::new();
    let work = f.add_space("Work", "ds-work");
    let tab = on_page(&mut f, "https://avelino.run/a");
    f.send(Action::IconsDeclared {
        tab,
        candidates: Vec::new(),
    });
    f.send(Action::IconFetched {
        data_store_id: "ds-work".into(),
        host: "avelino.run".into(),
        bytes: png(),
    });

    f.send(Action::CloseSpace { space: work });

    // ADR-0007 deletes the cookie jar for the same reason: anything left on
    // disk from a closed space cannot be reached from the interface again.
    assert_eq!(
        f.session
            .icons
            .bytes(&crate::icons::IconKey::new("ds-work", "avelino.run")),
        None
    );
    assert_eq!(f.session.icons.take_dropped(), vec!["ds-work".to_string()]);
}

#[test]
fn opening_a_tab_in_a_space_that_does_not_exist_is_refused() {
    let mut f = Fixture::new();
    let before = f.session.browser.tab_count();

    let out = f.send(Action::OpenTab {
        space: Some(SpaceId(9999)),
        url: Some("avelino.run".into()),
        parent: None,
    });

    // A tab in no space is invisible in the sidebar, never persisted, never
    // archived, and gets an empty cookie jar. Better to refuse it.
    assert!(out.is_empty());
    assert_eq!(f.session.browser.tab_count(), before);
    assert_eq!(f.session.browser.all_tabs().len(), before);
}

#[test]
fn a_nan_zoom_is_refused_rather_than_poisoning_every_future_save() {
    let mut f = Fixture::new();
    let tab = f.open();
    let before = f.session.browser.tab(tab).unwrap().zoom_factor;

    let out = f.send(Action::SetTabZoom {
        tab,
        factor: f64::NAN,
    });

    // NaN survives clamp, and SQLite refuses it in a NOT NULL REAL column,
    // which would fail the whole save transaction from then on.
    assert!(out.is_empty());
    assert_eq!(f.session.browser.tab(tab).unwrap().zoom_factor, before);
    assert!(!f.session.browser.tab(tab).unwrap().zoom_factor.is_nan());
}

#[test]
fn infinite_zoom_still_clamps() {
    let mut f = Fixture::new();
    let tab = f.open();

    f.send(Action::SetTabZoom {
        tab,
        factor: f64::INFINITY,
    });

    assert_eq!(f.session.browser.tab(tab).unwrap().zoom_factor, 5.0);
}

// MARK: - The browser's own addresses (ADR-0054)

/// The decision the whole scheme rests on. `zer0://` is never handed to a web
/// engine, so there is nothing in any engine that could be pointed at one.
#[test]
fn an_address_of_ours_never_reaches_a_web_engine() {
    let mut f = Fixture::new();
    let tab = f.open();

    let out = f.send(Action::NavigateTo {
        tab,
        input: "zer0://chat".into(),
    });

    assert!(
        !out.iter()
            .any(|c| matches!(c, EngineCommand::LoadUrl { .. })),
        "one of our own addresses was handed to an engine: {out:?}"
    );
    // And it committed here instead, with no round trip to wait for.
    let t = f.session.browser.tab(tab).unwrap();
    assert_eq!(t.url.as_deref(), Some("zer0://chat"));
    assert!(t.loading_complete);
    assert!(t.pending_url.is_none());
}

/// A page address commits under its canonical spelling, not under whatever was
/// typed — otherwise the session file carries somebody's capitalisation for
/// ever and two tabs on one address stop looking like one address.
#[test]
fn an_address_commits_canonically_however_it_was_typed() {
    let mut f = Fixture::new();
    let tab = f.open();

    f.send(Action::NavigateTo {
        tab,
        input: "ZER0://Chat/".into(),
    });

    assert_eq!(
        f.session.browser.tab(tab).unwrap().url.as_deref(),
        Some("zer0://chat")
    );
}

/// Settings is a window, and going to it leaves you on the page you were
/// reading. A tab that went blank to open a window would be the browser losing
/// your place in order to obey you.
#[test]
fn a_window_address_raises_a_window_and_leaves_the_tab_where_it_was() {
    let mut f = Fixture::new();
    let tab = f.open();
    f.send(Action::NavigateTo {
        tab,
        input: "https://example.com/reading".into(),
    });
    f.send(Action::NavigationCommitted {
        tab,
        url: "https://example.com/reading".into(),
    });

    let out = f.send(Action::NavigateTo {
        tab,
        input: "zer0://settings".into(),
    });

    assert_eq!(
        out,
        vec![EngineCommand::RaiseWindow {
            command: crate::shortcuts::UiCommand::ShowSettings
        }]
    );
    assert_eq!(
        f.session.browser.tab(tab).unwrap().url.as_deref(),
        Some("https://example.com/reading"),
        "opening a window moved the tab"
    );
}

/// Every address in the scheme does something, and what it does is visible: a
/// page commits into the tab that asked, a window address raises a window. An
/// address that parses and then leaves the screen exactly as it was is a dead
/// link inside the browser.
#[test]
fn no_address_in_the_scheme_is_dead() {
    for input in [
        "zer0://chat",
        "zer0://history",
        "zer0://downloads",
        "zer0://settings",
    ] {
        let mut f = Fixture::new();
        let tab = f.open();
        let out = f.send(Action::NavigateTo {
            tab,
            input: input.into(),
        });

        let landed = f.session.browser.tab(tab).unwrap().url.as_deref() == Some(input);
        let raised = out
            .iter()
            .any(|c| matches!(c, EngineCommand::RaiseWindow { .. }));
        assert!(
            landed || raised,
            "{input} neither drew a page nor raised a window: {out:?}"
        );
        // Whichever it did, it never asked an engine to load one of ours.
        assert!(
            !out.iter()
                .any(|c| matches!(c, EngineCommand::LoadUrl { .. })),
            "{input} reached a web engine"
        );
    }
}

/// History and downloads are pages now, and the Settings panes they came from
/// are gone (ADR-0063). Typing the address draws the list in the tab that asked
/// rather than putting a window in front of it.
#[test]
fn history_and_downloads_commit_into_the_tab_that_asked_for_them() {
    for input in ["zer0://history", "zer0://downloads"] {
        let mut f = Fixture::new();
        let tab = f.open();
        f.send(Action::NavigationCommitted {
            tab,
            url: "https://example.com/reading".into(),
        });

        let out = f.send(Action::NavigateTo {
            tab,
            input: input.into(),
        });

        assert!(out.is_empty(), "{input} produced {out:?}");
        let t = f.session.browser.tab(tab).unwrap();
        assert_eq!(t.url.as_deref(), Some(input));
        assert!(t.loading_complete, "{input} left the tab loading");
        assert!(t.last_error.is_none(), "{input} failed");
    }
}

/// ⌘Y and ⇧⌘J open a tab; they do not take the page you were reading. Typing
/// the address means *this* tab, pressing the chord means "show me my
/// history" — and a browser that answered by discarding your place would be
/// obeying you by losing something.
#[test]
fn the_chord_opens_a_page_beside_your_work_rather_than_over_it() {
    for address in [
        crate::internal_url::InternalAddress::History,
        crate::internal_url::InternalAddress::Downloads,
    ] {
        let mut f = Fixture::new();
        let reading = f.open();
        f.send(Action::NavigationCommitted {
            tab: reading,
            url: "https://example.com/reading".into(),
        });

        f.send(Action::OpenInternalPage {
            address: address.clone(),
        });

        let opened = f.session.browser.active_tab().unwrap();
        assert_ne!(opened, reading, "{address:?} took the page being read");
        assert_eq!(
            f.session.browser.tab(reading).unwrap().url.as_deref(),
            Some("https://example.com/reading")
        );
        assert_eq!(
            f.session.browser.tab(opened).unwrap().url,
            Some(address.url())
        );
    }
}

/// Pressing it twice returns to the list rather than opening a second copy of
/// it. Two tabs showing one history are two views of one state, and the stale
/// one is always the one being read.
#[test]
fn pressing_the_chord_again_goes_back_to_the_page_it_opened() {
    let mut f = Fixture::new();
    f.open();

    f.send(Action::OpenInternalPage {
        address: crate::internal_url::InternalAddress::History,
    });
    let opened = f.session.browser.active_tab().unwrap();
    let count = f.session.browser.all_tabs().len();

    // From somewhere else entirely, so this is not "it was already active".
    let elsewhere = f.open();
    f.send(Action::NavigationCommitted {
        tab: elsewhere,
        url: "https://example.com/".into(),
    });

    f.send(Action::OpenInternalPage {
        address: crate::internal_url::InternalAddress::History,
    });

    assert_eq!(f.session.browser.active_tab(), Some(opened));
    assert_eq!(
        f.session.browser.all_tabs().len(),
        count + 1,
        "a second history tab was opened"
    );
}

/// A window address asked for by the chord still raises its window. The
/// decision is `InternalAddress::effect` and it is made in one place, so a
/// fifth address cannot arrive and quietly become a tab.
#[test]
fn a_window_address_still_raises_its_window_when_it_is_asked_for_by_command() {
    let mut f = Fixture::new();
    let tab = f.open();

    let out = f.send(Action::OpenInternalPage {
        address: crate::internal_url::InternalAddress::Settings,
    });

    assert_eq!(
        out,
        vec![EngineCommand::RaiseWindow {
            command: crate::shortcuts::UiCommand::ShowSettings
        }]
    );
    assert_eq!(f.session.browser.active_tab(), Some(tab));
}

/// An address of ours that names nothing we have fails **as ours**. Handing it
/// to an engine would report it as a site that does not exist, which is a lie
/// about whose address it was.
#[test]
fn an_address_that_names_nothing_fails_as_ours_rather_than_as_a_site() {
    let mut f = Fixture::new();
    let tab = f.open();

    let out = f.send(Action::NavigateTo {
        tab,
        input: "zer0://nonsense".into(),
    });

    assert!(out.is_empty(), "{out:?}");
    let error = f.session.browser.tab(tab).unwrap().last_error.clone();
    let error = error.expect("an address that went nowhere said nothing");
    assert_eq!(error.kind, NavigationErrorKind::UnsupportedUrl);
    assert_eq!(error.url.as_deref(), Some("zer0://nonsense"));
}

/// A restored session has nothing to reload for an internal page: the shell
/// draws it from the tab's own URL. Asking an engine to load one would be the
/// one place a `zer0://` URL reached WebKit after all.
#[test]
fn a_restored_internal_tab_is_never_reloaded() {
    let mut f = Fixture::new();
    let tab = f.open();
    f.send(Action::NavigateTo {
        tab,
        input: "zer0://chat".into(),
    });

    let out = rehydrate(&f.session);

    assert!(
        !out.iter()
            .any(|c| matches!(c, EngineCommand::LoadUrl { url, .. } if url.starts_with("zer0:"))),
        "a restored internal page was sent to an engine: {out:?}"
    );
}

/// Every challenge is answered exactly once, including the ones nobody sees.
///
/// This is the invariant with the worst failure in the whole file and the one
/// no error screen can catch. Measured against a real server: a completion
/// handler that is never called produces no `didFinish`, no `didFail` and no
/// timeout — the tab holds a white rectangle for as long as the browser is
/// open, which is indistinguishable from a slow page and stays that way.
#[test]
fn a_challenge_nobody_is_asked_about_is_still_answered() {
    let mut f = Fixture::new();
    let tab = f.open();
    f.send(Action::ActivateTab { tab });
    let hidden = f.open();
    f.send(Action::ActivateTab { tab });

    // A background tab: refused without a panel, and still answered.
    let out = f.send(Action::HttpAuthRequested {
        request: HttpAuthRequest {
            request: 7,
            tab: hidden,
            scheme: HttpAuthScheme::Basic,
            origin: ReportedOrigin {
                scheme: "https".into(),
                host: "staging.example".into(),
                port: 0,
            },
            realm: None,
            previous_failures: 0,
            is_proxy: false,
            asked_at_ms: 1_000,
        },
    });

    assert_eq!(
        out,
        vec![EngineCommand::AnswerHttpAuth {
            request: 7,
            decision: AuthDecision::Cancel
        }],
        "a navigation was left with nothing to receive: {out:?}"
    );
}

/// A tab closing while a password panel is up still answers the server.
#[test]
fn closing_a_tab_answers_the_server_it_was_being_asked_by() {
    let mut f = Fixture::new();
    let tab = f.open();
    f.send(Action::HttpAuthRequested {
        request: HttpAuthRequest {
            request: 3,
            tab,
            scheme: HttpAuthScheme::Basic,
            origin: ReportedOrigin {
                scheme: "https".into(),
                host: "staging.example".into(),
                port: 0,
            },
            realm: None,
            previous_failures: 0,
            is_proxy: false,
            asked_at_ms: 1_000,
        },
    });
    assert!(f.session.http_auth.pending().is_some(), "no panel went up");

    let out = f.send(Action::CloseTab { tab });

    assert!(
        out.contains(&EngineCommand::AnswerHttpAuth {
            request: 3,
            decision: AuthDecision::Cancel
        }),
        "the engine was left holding a handler for a view that is gone: {out:?}"
    );
    assert!(f.session.http_auth.pending().is_none());
}

/// Answering the panel twice answers the server once.
#[test]
fn a_panel_that_was_already_answered_answers_nothing_a_second_time() {
    let mut f = Fixture::new();
    let tab = f.open();
    f.send(Action::HttpAuthRequested {
        request: HttpAuthRequest {
            request: 5,
            tab,
            scheme: HttpAuthScheme::Basic,
            origin: ReportedOrigin {
                scheme: "https".into(),
                host: "staging.example".into(),
                port: 0,
            },
            realm: None,
            previous_failures: 0,
            is_proxy: false,
            asked_at_ms: 1_000,
        },
    });

    let first = f.send(Action::DecideHttpAuth {
        request: 5,
        choice: AuthChoice::Supply,
    });
    let second = f.send(Action::DecideHttpAuth {
        request: 5,
        choice: AuthChoice::Supply,
    });

    assert_eq!(first.len(), 1);
    assert!(
        second.is_empty(),
        "the same challenge was answered twice: {second:?}"
    );
}

/// A certificate nobody has waved through is refused, and the screen is given
/// the facts to explain it.
#[test]
fn a_rejected_certificate_is_refused_and_its_faults_are_kept_for_the_screen() {
    let mut f = Fixture::new();
    let tab = f.open();

    let out = f.send(Action::ServerTrustRejected {
        request: ServerTrustRequest {
            request: 11,
            tab,
            host: "dev.localhost".into(),
            port: 8443,
            certificate: self_signed_certificate(),
        },
    });

    assert_eq!(
        out,
        vec![EngineCommand::AnswerServerTrust {
            request: 11,
            decision: TrustDecision::Refuse
        }]
    );
    let report = f
        .session
        .certificate_reports
        .get(&tab)
        .expect("the screen was given nothing to say");
    assert_eq!(report.faults, vec![CertificateFault::SelfSigned]);
}

/// And one somebody waved through, in this space, goes on.
#[test]
fn a_certificate_somebody_waved_through_is_not_asked_about_again_in_that_space() {
    let mut f = Fixture::new();
    let tab = f.open();
    let certificate = self_signed_certificate();

    f.send(Action::TrustThisCertificate {
        tab,
        origin: "https://dev.localhost:8443".into(),
        fingerprint: certificate.fingerprint.clone(),
    });

    let out = f.send(Action::ServerTrustRejected {
        request: ServerTrustRequest {
            request: 12,
            tab,
            host: "dev.localhost".into(),
            port: 8443,
            certificate: certificate.clone(),
        },
    });

    assert!(
        out.contains(&EngineCommand::AnswerServerTrust {
            request: 12,
            decision: TrustDecision::Proceed
        }),
        "the exception did not reach the engine: {out:?}"
    );

    // A different certificate on the same host does not inherit it. This is the
    // shape an interception takes, and it is the whole reason the exception is
    // keyed by fingerprint rather than by host.
    let mut swapped = certificate;
    swapped.fingerprint = "ffffffffff".into();
    let out = f.send(Action::ServerTrustRejected {
        request: ServerTrustRequest {
            request: 13,
            tab,
            host: "dev.localhost".into(),
            port: 8443,
            certificate: swapped,
        },
    });

    assert!(
        out.contains(&EngineCommand::AnswerServerTrust {
            request: 13,
            decision: TrustDecision::Refuse
        }),
        "a second certificate on that host inherited the first one's exception: {out:?}"
    );
}

fn self_signed_certificate() -> ReportedCertificate {
    ReportedCertificate {
        fingerprint: "aa11bb22".into(),
        subject: "localhost".into(),
        issuer: String::new(),
        covers: vec!["localhost".into()],
        not_before_ms: Some(0),
        not_after_ms: Some(u64::MAX / 2),
        self_signed: true,
        reaches_trusted_anchor: false,
        host_matches: true,
        chain_length: 1,
    }
}

/// A tab left at 150% comes back at 150%.
///
/// `zoom_factor` has been persisted since the column existed and the model
/// brought it back correctly; nothing ever pushed it at the engine. So after a
/// relaunch the core said 1.5 and the page drew at 1.0 — the interface holding
/// a value the screen contradicts, which is exactly what ADR-0018 forbids, and
/// invisible to every test that only asked what the core remembered.
#[test]
fn a_restored_tab_is_drawn_at_the_zoom_it_was_left_at() {
    let mut f = Fixture::new();
    let tab = f.open();
    f.send(Action::SetTabZoom { tab, factor: 1.5 });

    let out = rehydrate(&f.session);

    assert!(
        out.contains(&EngineCommand::SetZoom { tab, factor: 1.5 }),
        "the restored zoom never reached the view: {out:?}"
    );
}

/// And a tab at the default costs nothing to restore.
///
/// The other half of the same rule: a fresh `WKWebView` is already at 1.0, so
/// telling it so is a command per tab at every launch that changes nothing.
#[test]
fn a_restored_tab_at_the_ordinary_size_is_told_nothing() {
    let f = Fixture::new();
    let out = rehydrate(&f.session);

    assert!(
        !out.iter()
            .any(|c| matches!(c, EngineCommand::SetZoom { .. })),
        "an untouched tab was zoomed on the way back: {out:?}"
    );
}

/// A view rebuilt mid-session is the same problem through the other door.
///
/// `rebuild_view` runs when a space's profile changes, and it forgot both the
/// mute and the zoom. Changing a space's user agent silently unmuted every tab
/// in it and reset the type size.
#[test]
fn a_rebuilt_view_keeps_the_zoom_and_the_mute_the_tab_already_had() {
    let mut f = Fixture::new();
    let tab = f.open();
    let space = f.session.browser.tab(tab).unwrap().space;
    f.send(Action::SetTabZoom { tab, factor: 0.75 });
    f.send(Action::SetTabMuted { tab, muted: true });

    let out = f.send(Action::SetSpaceProfile {
        space,
        profile: SpaceProfile {
            ephemeral: false,
            user_agent: Some("something else".into()),
        },
    });

    assert!(
        out.contains(&EngineCommand::SetZoom { tab, factor: 0.75 }),
        "the rebuilt view lost the zoom: {out:?}"
    );
    assert!(
        out.contains(&EngineCommand::SetMuted { tab, muted: true }),
        "the rebuilt view came back unmuted: {out:?}"
    );
}

/// An air-traffic rule sends a *site* to the space that owns it. None of the
/// browser's own addresses belongs to a space, and a pattern that happened to
/// match our scheme would move the tab on the strength of it.
#[test]
fn an_air_traffic_rule_cannot_route_one_of_our_addresses() {
    let mut f = Fixture::new();
    let tab = f.open();
    let home = f.session.browser.tab(tab).unwrap().space;
    let elsewhere = f.add_space("Work", "ds-work");
    f.send(Action::AddRoute {
        pattern: RoutePattern::UrlContains {
            fragment: "zer0".into(),
        },
        space: elsewhere,
    });

    f.send(Action::NavigateTo {
        tab,
        input: "zer0://chat".into(),
    });

    assert_eq!(
        f.session.browser.tab(tab).unwrap().space,
        home,
        "an internal address was routed out of its space"
    );
    assert_ne!(home, elsewhere);
}

// --- keeping a page without keeping a tab ------------------------------------

#[test]
fn keeping_the_page_you_are_on_keeps_its_address_and_its_title() {
    // Which tab "this page" means is resolved here rather than by whichever
    // shell handled ⌘D, so it means the same thing on every platform.
    let mut f = Fixture::new();
    f.send(Action::Tick { now_ms: 5_000 });
    let tab = f.open();
    f.send(Action::NavigationCommitted {
        tab,
        url: "https://avelino.run/".into(),
    });
    f.send(Action::TitleChanged {
        tab,
        title: "Avelino".into(),
    });

    f.send(Action::SaveBookmark { tab: None });

    let bookmark = f.session.bookmarks.for_url("https://avelino.run/").unwrap();
    assert_eq!(bookmark.title, "Avelino");
    assert_eq!(bookmark.saved_at_ms, 5_000);
}

#[test]
fn keeping_a_page_does_not_touch_the_tab_it_came_from() {
    // The whole point of a bookmark being the fourth thing: it is not a tab,
    // and keeping one must not move, pin or archive the tab you were reading.
    let mut f = Fixture::new();
    let tab = f.open();
    f.send(Action::NavigationCommitted {
        tab,
        url: "https://avelino.run/".into(),
    });
    let before = f.session.browser.tab(tab).unwrap().clone();

    let commands = f.send(Action::SaveBookmark { tab: None });

    assert!(commands.is_empty(), "nothing is asked of the engine");
    assert_eq!(f.session.browser.tab(tab).unwrap(), &before);
    assert_eq!(f.session.browser.tab(tab).unwrap().kind, TabKind::Today);
}

#[test]
fn there_is_nothing_to_keep_about_a_tab_that_has_not_loaded_anything() {
    // Refuse rather than repair. Keeping `pending_url` would file a page that
    // may be about to fail, and the placeholder title would file one called
    // "New Tab".
    let mut f = Fixture::new();
    let tab = f.open();
    f.send(Action::NavigationStarted {
        tab,
        url: "https://avelino.run/".into(),
    });

    f.send(Action::SaveBookmark { tab: None });

    assert!(f.session.bookmarks.is_empty());
}

#[test]
fn keeping_with_no_tab_open_at_all_keeps_nothing() {
    let mut f = Fixture::new();
    assert_eq!(f.session.browser.active_tab(), None);

    f.send(Action::SaveBookmark { tab: None });

    assert!(f.session.bookmarks.is_empty());
}

#[test]
fn pressing_the_keep_chord_twice_does_not_take_it_back() {
    // ⌘D is pressed without looking, and a second press that deleted the
    // bookmark would make the safest chord in the browser destructive.
    let mut f = Fixture::new();
    let tab = f.open();
    f.send(Action::NavigationCommitted {
        tab,
        url: "https://avelino.run/".into(),
    });

    f.send(Action::SaveBookmark { tab: None });
    f.send(Action::SaveBookmark { tab: None });

    assert_eq!(f.session.bookmarks.len(), 1);
}

#[test]
fn a_bookmark_goes_away_only_when_somebody_says_so() {
    let mut f = Fixture::new();
    let tab = f.open();
    f.send(Action::NavigationCommitted {
        tab,
        url: "https://avelino.run/".into(),
    });
    f.send(Action::SaveBookmark { tab: None });
    let id = f.session.bookmarks.all()[0].id;

    f.send(Action::RemoveBookmark { bookmark: id });

    assert!(f.session.bookmarks.is_empty());
}

#[test]
fn closing_the_tab_leaves_what_you_kept_alone() {
    // The job a bookmark does that no tab does: outliving the tab.
    let mut f = Fixture::new();
    let tab = f.open();
    f.send(Action::NavigationCommitted {
        tab,
        url: "https://avelino.run/".into(),
    });
    f.send(Action::SaveBookmark { tab: None });

    f.send(Action::CloseTab { tab });

    assert_eq!(f.session.browser.tab_count(), 0);
    assert!(
        f.session
            .bookmarks
            .for_url("https://avelino.run/")
            .is_some()
    );
}

#[test]
fn a_tab_archived_for_going_stale_does_not_take_the_bookmark_with_it() {
    // Twelve untouched hours archive a Today tab. That is exactly the case
    // bookmarks exist for, so it is the case that must not lose one.
    let mut f = Fixture::new();
    f.send(Action::Tick { now_ms: 1_000 });
    let tab = f.open();
    f.send(Action::NavigationCommitted {
        tab,
        url: "https://avelino.run/".into(),
    });
    f.send(Action::SaveBookmark { tab: None });
    // Somewhere else, so the archived tab is not the active one.
    let other = f.open();
    f.send(Action::ActivateTab { tab: other });

    f.send(Action::Tick {
        now_ms: 1_000 + 13 * HOUR,
    });

    assert!(f.session.browser.tab(tab).is_none(), "the tab aged out");
    assert!(
        f.session
            .bookmarks
            .for_url("https://avelino.run/")
            .is_some(),
        "and what was kept about it did not"
    );
}

#[test]
fn relabelling_a_bookmark_is_the_only_thing_that_changes_one() {
    let mut f = Fixture::new();
    let tab = f.open();
    f.send(Action::NavigationCommitted {
        tab,
        url: "https://avelino.run/".into(),
    });
    f.send(Action::SaveBookmark { tab: None });
    let id = f.session.bookmarks.all()[0].id;

    f.send(Action::EditBookmark {
        bookmark: id,
        title: "Read in March".into(),
        tags: vec!["Rust".into(), "rust".into()],
    });

    let bookmark = f.session.bookmarks.get(id).unwrap();
    assert_eq!(bookmark.title, "Read in March");
    assert_eq!(
        bookmark.tags,
        vec!["rust"],
        "two spellings of one label are one label"
    );
}

// --- windows ----------------------------------------------------------------

/// ⌘N. Everything about this test is about *not* surprising somebody: the same
/// space, therefore the same cookie jar and the same logins, and something to
/// type in when it arrives.
#[test]
fn a_new_window_opens_onto_the_space_you_were_in_with_a_tab_to_type_in() {
    let mut f = Fixture::new();
    let first_window = f.session.browser.key_window();
    let space = f.session.browser.active_space();
    f.open();

    let out = f.send(Action::OpenWindow {
        onto: WindowContents::CurrentSpace,
    });

    let window = f.session.browser.key_window();
    assert_ne!(window, first_window, "the new window takes the front");
    assert_eq!(f.session.browser.windows().len(), 2);
    assert_eq!(
        f.session.browser.active_space_in(window),
        Some(space),
        "a second window that logged you out of everything is not a second window"
    );
    assert!(
        out.contains(&EngineCommand::OpenBrowserWindow { window }),
        "the shell is told to put a window on screen"
    );

    let seeded = f
        .session
        .browser
        .active_tab()
        .expect("a window with nothing in it is a dead end");
    assert_eq!(f.session.browser.window_of(seeded), Some(window));
    assert_eq!(
        f.session.browser.tabs_in_window(window, space).len(),
        1,
        "one tab, and not the other window's"
    );
    assert!(out.contains(&EngineCommand::FocusWebView { tab: seeded }));
}

/// ⇧⌘N. The argument of ADR-0065 in one assertion: private browsing here is an
/// ephemeral space, so the private window has to actually get one.
#[test]
fn a_private_window_opens_onto_an_ephemeral_space_of_its_own() {
    let mut f = Fixture::new();
    let ordinary = f.session.browser.active_space();

    let out = f.send(Action::OpenWindow {
        onto: WindowContents::NewPrivateSpace {
            name: "Private".into(),
            data_store_id: "ds-private".into(),
        },
    });

    let window = f.session.browser.key_window();
    let space = f.session.browser.active_space_in(window).unwrap();
    assert_ne!(space, ordinary, "a private window is not your own space");
    assert!(
        !f.session.browser.records_to_disk(space),
        "an ephemeral space that writes to disk is a broken promise"
    );

    // Ephemeral from the first web view, not from a second dispatch: a jar that
    // was persistent for one instant is a directory on disk nothing points at.
    // `if let` rather than a match with a wildcard: ADR-0031 keeps `_` out of a
    // switch over a command, and a test is not an exception to that.
    let created = out
        .iter()
        .filter_map(|c| {
            if let EngineCommand::CreateWebView {
                configuration: ViewConfiguration::Space { profile, .. },
                ..
            } = c
            {
                Some(profile.clone())
            } else {
                None
            }
        })
        .next()
        .expect("the private window's first page is built");
    assert!(
        created.ephemeral,
        "the host was handed a persistent store for a private window"
    );
}

/// ⇧⌘W, and the half of it that is not about the frame: the jar goes too.
#[test]
fn closing_a_private_window_takes_its_cookie_jar_with_it() {
    let mut f = Fixture::new();
    f.send(Action::OpenWindow {
        onto: WindowContents::NewPrivateSpace {
            name: "Private".into(),
            data_store_id: "ds-private".into(),
        },
    });
    let window = f.session.browser.key_window();
    let space = f.session.browser.active_space_in(window).unwrap();

    let out = f.send(Action::CloseWindow { window });

    assert!(f.session.browser.window(window).is_none());
    assert!(
        f.session.browser.space(space).is_none(),
        "an empty private space left in the sidebar says somebody browsed privately"
    );
    assert!(
        out.contains(&EngineCommand::DeleteDataStore {
            data_store_id: "ds-private".into()
        }),
        "a jar nobody can reach from the interface is the leak ADR-0007 deletes jars to avoid"
    );
    assert!(out.contains(&EngineCommand::CloseBrowserWindow { window }));
}

#[test]
fn closing_a_window_takes_its_tabs_and_leaves_the_other_window_alone() {
    let mut f = Fixture::new();
    let kept = f.open();
    f.send(Action::OpenWindow {
        onto: WindowContents::CurrentSpace,
    });
    let second = f.session.browser.key_window();
    let doomed = f.session.browser.active_tab().unwrap();

    let out = f.send(Action::CloseWindow { window: second });

    assert!(f.session.browser.tab(doomed).is_none());
    assert!(
        out.contains(&EngineCommand::DestroyWebView { tab: doomed }),
        "the view outlives the model unless somebody says otherwise"
    );
    assert!(
        f.session.browser.tab(kept).is_some(),
        "the other window's page"
    );
    assert_eq!(f.session.browser.windows().len(), 1);
    assert_eq!(
        f.session.browser.key_window(),
        f.session.browser.windows()[0].id,
        "the front moves to a window that exists"
    );
}

#[test]
fn the_last_window_refuses_to_close() {
    let mut f = Fixture::new();
    let tab = f.open();
    let only = f.session.browser.key_window();

    let out = f.send(Action::CloseWindow { window: only });

    assert!(out.is_empty(), "nothing to carry out");
    assert_eq!(f.session.browser.windows().len(), 1);
    assert!(
        f.session.browser.tab(tab).is_some(),
        "a browser with nowhere to draw a page is not a state worth representing"
    );
}

/// The multi-window half of ADR-0053. `frontmost` and `browserWindow` told two
/// browser windows apart from Settings and not from each other; a command with
/// nobody named in it now acts on whichever window last said it was in front.
#[test]
fn a_command_acts_on_the_window_that_is_in_front_and_not_the_one_behind() {
    let mut f = Fixture::new();
    let first = f.session.browser.key_window();
    let behind = f.open();
    f.send(Action::OpenWindow {
        onto: WindowContents::CurrentSpace,
    });
    let second = f.session.browser.key_window();
    let in_front = f.session.browser.active_tab().unwrap();

    // ⌘W with the second window in front.
    f.send(Action::CloseTab { tab: in_front });
    assert!(
        f.session.browser.tab(behind).is_some(),
        "a tab behind the window"
    );

    // And now the first one is in front, so the same command means its tab.
    f.send(Action::FocusWindow { window: first });
    assert_eq!(f.session.browser.active_tab(), Some(behind));
    f.send(Action::CloseTab { tab: behind });
    assert!(f.session.browser.tab(behind).is_none());

    assert_eq!(f.session.browser.windows().len(), 2);
    assert_eq!(f.session.browser.active_tab_in(second), None);
}

/// Two windows on one space is what ⌘N makes, so the sidebar of each has to
/// show its own tabs and no others.
#[test]
fn two_windows_on_the_same_space_do_not_show_each_others_tabs() {
    let mut f = Fixture::new();
    let space = f.session.browser.active_space();
    let mine = f.open();
    f.send(Action::OpenWindow {
        onto: WindowContents::CurrentSpace,
    });
    let second = f.session.browser.key_window();
    let theirs = f.session.browser.active_tab().unwrap();
    let first = f.session.browser.windows()[0].id;

    assert_eq!(
        f.session
            .browser
            .tabs_in_window(first, space)
            .iter()
            .map(|t| t.id)
            .collect::<Vec<_>>(),
        vec![mine]
    );
    assert_eq!(
        f.session
            .browser
            .tabs_in_window(second, space)
            .iter()
            .map(|t| t.id)
            .collect::<Vec<_>>(),
        vec![theirs]
    );
    // And the same jar, which is the point of sharing the space at all.
    assert_eq!(
        f.session.browser.tab(mine).map(|t| t.space),
        f.session.browser.tab(theirs).map(|t| t.space)
    );
}

/// A split lives on the space (ADR-0042), and two windows can show one space.
/// The window that does not have the panes must not be told to draw them.
#[test]
fn a_split_is_only_a_split_in_the_window_holding_both_panes() {
    let mut f = Fixture::new();
    let leading = f.open();
    let trailing = f.open();
    f.send(Action::ActivateTab { tab: leading });
    f.send(Action::SplitWith { tab: trailing });
    assert!(f.session.browser.active_split().is_some());

    f.send(Action::OpenWindow {
        onto: WindowContents::CurrentSpace,
    });

    assert!(
        f.session.browser.active_split().is_none(),
        "the new window would be drawing two pages it does not have"
    );
}

// MARK: - A page that opens a window (ADR-0075)

/// What a page states when it asks for nothing at all.
fn asked_for_nothing() -> WindowRequest {
    WindowRequest::default()
}

/// The OAuth shape: a named window with a size on it.
fn asked_for_a_shaped_window() -> WindowRequest {
    WindowRequest {
        width: Some(480.0),
        height: Some(640.0),
        ..WindowRequest::default()
    }
}

/// `window.open(url)` with no feature string, and every `target="_blank"` link
/// on the web, which arrives through exactly the same door.
#[test]
fn a_page_that_described_no_window_gets_a_tab_beside_the_page_that_asked() {
    let mut f = Fixture::new();
    let opener = f.open();
    let windows_before = f.session.browser.windows().len();

    let out = f.send(Action::PageOpenedWindow {
        opener,
        request: asked_for_nothing(),
    });

    assert_eq!(
        f.session.browser.windows().len(),
        windows_before,
        "a page that described no window got one anyway"
    );
    let tab = f
        .session
        .browser
        .active_tab()
        .expect("the pop-up is in front");
    assert_ne!(tab, opener);
    let tab = f.session.browser.tab(tab).unwrap();
    assert_eq!(
        tab.window,
        f.session.browser.tab(opener).unwrap().window,
        "the pop-up landed in a window other than the one holding the page that asked"
    );
    assert_eq!(tab.parent, Some(opener));
    assert!(tab.opened_by_page);

    // The engine already built the view and is holding the page's `window.open`
    // call on it. Anything but `AdoptWebView` means a view built from a
    // configuration of ours, which is a different browsing context.
    assert!(
        out.iter()
            .any(|c| matches!(c, EngineCommand::AdoptWebView { .. })),
        "nothing told the host to keep the view the engine built"
    );
    assert!(
        !out.iter()
            .any(|c| matches!(c, EngineCommand::CreateWebView { .. })),
        "a second view was built for a page that already has one"
    );
    // The engine navigates the view it made on its own. A `LoadUrl` here is a
    // second visit, and a single-use OAuth address does not survive one.
    assert!(
        !out.iter()
            .any(|c| matches!(c, EngineCommand::LoadUrl { .. })),
        "the pop-up was navigated a second time"
    );
}

/// A page that gave a size asked for a window, and gets one — onto the space
/// it was opened from, never a new one.
#[test]
fn a_page_that_described_a_window_gets_one_onto_the_space_it_came_from() {
    let mut f = Fixture::new();
    let opener = f.open();
    let space = f.session.browser.tab(opener).unwrap().space;
    let spaces_before = f.session.browser.spaces().len();

    let out = f.send(Action::PageOpenedWindow {
        opener,
        request: asked_for_a_shaped_window(),
    });

    assert_eq!(f.session.browser.windows().len(), 2);
    assert!(
        out.iter()
            .any(|c| matches!(c, EngineCommand::OpenBrowserWindow { .. })),
        "the core made a window the shell was never told to draw"
    );
    assert_eq!(
        f.session.browser.spaces().len(),
        spaces_before,
        "a pop-up created a space, and a space is a cookie jar"
    );
    let tab = f.session.browser.active_tab().unwrap();
    assert_eq!(f.session.browser.tab(tab).unwrap().space, space);
}

/// The rule that keeps a private session private, asserted against the space
/// rather than against a flag: the pop-up is in the opener's space, so whatever
/// is true of that space is true of it (ADR-0007, ADR-0065).
#[test]
fn a_pop_up_stays_in_the_space_the_page_that_opened_it_is_in() {
    let mut f = Fixture::new();
    let ordinary = f.session.browser.active_space();

    f.send(Action::OpenWindow {
        onto: WindowContents::NewPrivateSpace {
            name: "Private".into(),
            data_store_id: "ds-private".into(),
        },
    });
    let opener = f.session.browser.active_tab().unwrap();
    let private = f.session.browser.tab(opener).unwrap().space;
    assert_ne!(private, ordinary);

    // Somewhere else is in front, which is the whole point: the answer must
    // come off the tab that asked and not off what is active.
    f.session.browser.set_active_space(ordinary);

    f.send(Action::PageOpenedWindow {
        opener,
        request: asked_for_a_shaped_window(),
    });

    let tab = f.session.browser.active_tab().unwrap();
    assert_eq!(
        f.session.browser.tab(tab).unwrap().space,
        private,
        "a page in a private space opened a pop-up somewhere its cookies get written down"
    );
    assert!(!f.session.browser.records_to_disk(private));
}

/// A page whose tab has gone opens nothing. Falling back to the active space
/// would choose a cookie jar on a dead page's behalf.
#[test]
fn a_pop_up_from_a_tab_that_is_gone_opens_nothing() {
    let mut f = Fixture::new();
    let opener = f.open();
    let before = f.session.browser.all_tabs().len();
    f.send(Action::CloseTab { tab: opener });

    let out = f.send(Action::PageOpenedWindow {
        opener,
        request: asked_for_a_shaped_window(),
    });

    assert!(out.is_empty());
    assert!(f.session.browser.all_tabs().len() < before);
}

/// `window.close()` reaches only a tab a page opened.
///
/// The engine's own gate is wider — measured, WebKit lets any view with one
/// back-forward entry close itself — so this is the browser being stricter than
/// the engine on purpose.
#[test]
fn only_a_page_that_opened_a_tab_can_close_it() {
    let mut f = Fixture::new();
    let mine = f.open();

    let out = f.send(Action::PageClosedWindow { tab: mine });

    assert!(out.is_empty());
    assert!(
        f.session.browser.tab(mine).is_some(),
        "a page closed a tab a person opened, and no key brings it back"
    );

    f.send(Action::PageOpenedWindow {
        opener: mine,
        request: asked_for_nothing(),
    });
    let theirs = f.session.browser.active_tab().unwrap();

    f.send(Action::PageClosedWindow { tab: theirs });
    assert!(f.session.browser.tab(theirs).is_none());
}

/// A window a page opened goes when the page in it closes itself. Leaving the
/// frame behind would leave an empty window with nothing to press.
#[test]
fn a_window_a_page_opened_goes_with_the_page_that_closes_itself() {
    let mut f = Fixture::new();
    let opener = f.open();
    f.send(Action::PageOpenedWindow {
        opener,
        request: asked_for_a_shaped_window(),
    });
    assert_eq!(f.session.browser.windows().len(), 2);
    let popup = f.session.browser.active_tab().unwrap();

    let out = f.send(Action::PageClosedWindow { tab: popup });

    assert_eq!(f.session.browser.windows().len(), 1);
    assert!(
        out.iter()
            .any(|c| matches!(c, EngineCommand::CloseBrowserWindow { .. })),
        "the model closed a window the shell still has on screen"
    );
}

/// What the page stated, and what it adds up to.
///
/// The two rows that matter are the first and the last: a page that said
/// nothing wanted a tab, and a page that asked for chrome to stay *on* did not
/// ask for a pop-up.
#[test]
fn a_page_asked_for_a_window_only_when_it_described_one() {
    assert!(!WindowRequest::default().asked_for_a_window());

    assert!(
        WindowRequest {
            width: Some(480.0),
            ..WindowRequest::default()
        }
        .asked_for_a_window()
    );
    assert!(
        WindowRequest {
            y: Some(80.0),
            ..WindowRequest::default()
        }
        .asked_for_a_window()
    );
    assert!(
        WindowRequest {
            toolbars_visible: Some(false),
            ..WindowRequest::default()
        }
        .asked_for_a_window()
    );
    assert!(
        !WindowRequest {
            toolbars_visible: Some(true),
            menu_bar_visible: Some(true),
            status_bar_visible: Some(true),
            ..WindowRequest::default()
        }
        .asked_for_a_window(),
        "a page asking for an ordinary-looking window asked for what a tab already is"
    );
}

// MARK: - The rows this browser puts in the engine's context menu (ADR-0091)

fn on_a_link(url: &str) -> PageTarget {
    PageTarget {
        link_url: Some(url.to_string()),
        ..PageTarget::default()
    }
}

/// The whole reason the target travels back with the row. A host that named a
/// row the target never earned is a caller naming something that does not
/// exist, and the answer is a refusal rather than a repair.
#[test]
fn a_row_that_was_never_on_offer_does_nothing() {
    let mut f = Fixture::new();
    let tab = f.open();
    let before = f.session.browser.all_tabs().len();

    // No link anywhere in the target, so "Open Link in New Tab" was never drawn.
    let commands = f.send(Action::ChosePageMenuItem {
        tab,
        item: PageMenuItem::OpenLinkInNewTab,
        target: PageTarget::default(),
    });

    assert!(commands.is_empty());
    assert_eq!(f.session.browser.all_tabs().len(), before);
}

/// ADR-0054, reached from the one direction a menu opens. `additions_for` draws
/// no row for one of our addresses, so choosing one is choosing a row that was
/// never there — and nothing is opened, in a space or anywhere else.
#[test]
fn a_menu_can_never_open_one_of_our_own_addresses() {
    let mut f = Fixture::new();
    let tab = f.open();
    let before = f.session.browser.all_tabs().len();

    for url in [
        "zer0://settings",
        "zer0://chat?conversation=7",
        "ZER0://history",
    ] {
        let commands = f.send(Action::ChosePageMenuItem {
            tab,
            item: PageMenuItem::OpenLinkInNewTab,
            target: on_a_link(url),
        });
        assert!(commands.is_empty(), "{url} reached a command");
    }
    assert_eq!(f.session.browser.all_tabs().len(), before);
}

/// What the check against `additions_for` catches that nothing else does.
///
/// Both rows below name an address that exists, so the arm's own "is there a
/// URL" guard lets them through. What refuses them is that the target never
/// earned the row: a `blob:` names an object inside one page's script context
/// and the download runs from outside it, and Back from the start of a
/// back-forward list is a road that is not there.
///
/// Written after the check was broken on purpose and the suite stayed green —
/// which is the whole reason this test exists rather than the two beside it.
#[test]
fn a_row_the_target_never_earned_is_refused_even_when_it_names_an_address() {
    let mut f = Fixture::new();
    let tab = f.open();

    // A blob can be opened in a tab and cannot be saved, so `SaveLinkedFile`
    // was never drawn for this target.
    let saved = f.send(Action::ChosePageMenuItem {
        tab,
        item: PageMenuItem::SaveLinkedFile,
        target: on_a_link("blob:https://example.com/abc"),
    });
    assert!(
        saved.is_empty(),
        "a download was started for an address the menu never offered to save: {saved:?}"
    );

    // Nowhere to go, so no row was drawn.
    let back = f.send(Action::ChosePageMenuItem {
        tab,
        item: PageMenuItem::Back,
        target: PageTarget::default(),
    });
    assert!(
        back.is_empty(),
        "it went back from a row nobody drew: {back:?}"
    );

    let forward = f.send(Action::ChosePageMenuItem {
        tab,
        item: PageMenuItem::Forward,
        target: PageTarget::default(),
    });
    assert!(forward.is_empty());
}

/// The lesson ADR-0075 paid for, in the one other place a tab is opened from a
/// page. Reading the space off `active_space` would put a link followed in a
/// private window into a jar that is written to disk.
#[test]
fn a_link_opened_from_a_menu_lands_in_the_space_the_page_is_in() {
    let mut f = Fixture::new();
    let ordinary = f.session.browser.active_space();

    f.send(Action::OpenWindow {
        onto: WindowContents::NewPrivateSpace {
            name: "Private".into(),
            data_store_id: "ds-private".into(),
        },
    });
    let source = f.session.browser.active_tab().unwrap();
    let private = f.session.browser.tab(source).unwrap().space;
    assert_ne!(private, ordinary);

    // Somewhere else is in front, which is the whole point.
    f.session.browser.set_active_space(ordinary);

    f.send(Action::ChosePageMenuItem {
        tab: source,
        item: PageMenuItem::OpenLinkInNewTab,
        target: on_a_link("https://example.com/a"),
    });

    let opened = f.session.browser.active_tab().unwrap();
    assert_ne!(opened, source);
    assert_eq!(
        f.session.browser.tab(opened).unwrap().space,
        private,
        "a link followed from a private page opened where its cookies get written down"
    );
    assert!(!f.session.browser.records_to_disk(private));
}

/// A new tab lands beside the page it came from, and it lands in that page's
/// window rather than in whichever window last happened to be key.
#[test]
fn a_link_opened_from_a_menu_lands_beside_the_page_and_in_its_window() {
    let mut f = Fixture::new();
    let source = f.open();
    let source_window = f.session.browser.tab(source).unwrap().window;

    f.send(Action::OpenWindow {
        onto: WindowContents::CurrentSpace,
    });
    let elsewhere = f.session.browser.active_tab().unwrap();
    assert_ne!(
        f.session.browser.tab(elsewhere).unwrap().window,
        source_window
    );

    f.send(Action::ChosePageMenuItem {
        tab: source,
        item: PageMenuItem::OpenLinkInNewTab,
        target: on_a_link("https://example.com/a"),
    });

    let opened = f.session.browser.active_tab().unwrap();
    assert_eq!(f.session.browser.tab(opened).unwrap().window, source_window);
    assert_eq!(f.session.browser.tab(opened).unwrap().parent, Some(source));
}

/// The row says "in New Window", so a window is what it has to produce. The
/// engine's own row of that name asks through `createWebViewWith` with every
/// window feature unset, which ADR-0075 answers with a tab.
#[test]
fn open_link_in_new_window_really_opens_a_window() {
    let mut f = Fixture::new();
    let source = f.open();
    let before = f.session.browser.windows().len();

    let commands = f.send(Action::ChosePageMenuItem {
        tab: source,
        item: PageMenuItem::OpenLinkInNewWindow,
        target: on_a_link("https://example.com/a"),
    });

    assert_eq!(f.session.browser.windows().len(), before + 1);
    let opened = f.session.browser.active_tab().unwrap();
    let window = f.session.browser.tab(opened).unwrap().window;
    assert_ne!(window, f.session.browser.tab(source).unwrap().window);
    assert!(commands.contains(&EngineCommand::OpenBrowserWindow { window }));
    assert!(commands.contains(&EngineCommand::LoadUrl {
        tab: opened,
        url: "https://example.com/a".into(),
    }));
}

/// Through the tab the file came from, so the space's cookies come with it —
/// a download fetched through the wrong jar arrives as a sign-in page.
#[test]
fn saving_from_a_menu_goes_through_the_tab_it_was_asked_from() {
    let mut f = Fixture::new();
    let tab = f.open();

    let commands = f.send(Action::ChosePageMenuItem {
        tab,
        item: PageMenuItem::SaveImage,
        target: PageTarget {
            image_url: Some("https://example.com/a.png".into()),
            ..PageTarget::default()
        },
    });

    assert_eq!(
        commands,
        vec![EngineCommand::StartDownload {
            tab,
            url: "https://example.com/a.png".into(),
        }]
    );
}

/// The row says "Search for", and it has to mean it. Resolving the text the way
/// the command bar resolves typing would navigate to a selection that happens
/// to look like a hostname, which is not what the row offered.
#[test]
fn searching_for_a_selection_searches_even_when_it_looks_like_an_address() {
    let mut f = Fixture::new();
    f.session
        .browser
        .set_search_template("https://duckduckgo.com/?q={}");
    let tab = f.open();

    let commands = f.send(Action::ChosePageMenuItem {
        tab,
        item: PageMenuItem::SearchForSelection,
        target: PageTarget {
            selection: Some("example.com".into()),
            ..PageTarget::default()
        },
    });

    let opened = f.session.browser.active_tab().unwrap();
    assert!(commands.contains(&EngineCommand::LoadUrl {
        tab: opened,
        url: "https://duckduckgo.com/?q=example.com".into(),
    }));
}

/// The configured engine, not one spelled a second time in a menu.
#[test]
fn searching_for_a_selection_uses_the_configured_engine() {
    let mut f = Fixture::new();
    f.session
        .browser
        .set_search_template("https://kagi.com/search?q={}");
    let tab = f.open();

    let commands = f.send(Action::ChosePageMenuItem {
        tab,
        item: PageMenuItem::SearchForSelection,
        target: PageTarget {
            selection: Some("rust & swift".into()),
            ..PageTarget::default()
        },
    });

    let opened = f.session.browser.active_tab().unwrap();
    assert!(
        commands.contains(&EngineCommand::LoadUrl {
            tab: opened,
            url: "https://kagi.com/search?q=rust+%26+swift".into(),
        }),
        "the menu searched somewhere Settings does not name: {commands:?}"
    );
}

/// Back and Forward go through the same commands ⌘[ and ⌘] produce, on the tab
/// the menu was opened over rather than on whatever is active.
#[test]
fn back_and_forward_from_a_menu_act_on_the_tab_the_menu_was_opened_over() {
    let mut f = Fixture::new();
    let first = f.open();
    let second = f.open();
    assert_eq!(f.session.browser.active_tab(), Some(second));

    let back = f.send(Action::ChosePageMenuItem {
        tab: first,
        item: PageMenuItem::Back,
        target: PageTarget {
            can_go_back: true,
            ..PageTarget::default()
        },
    });
    assert_eq!(back, vec![EngineCommand::GoBack { tab: first }]);

    let forward = f.send(Action::ChosePageMenuItem {
        tab: first,
        item: PageMenuItem::Forward,
        target: PageTarget {
            can_go_forward: true,
            ..PageTarget::default()
        },
    });
    assert_eq!(forward, vec![EngineCommand::GoForward { tab: first }]);
}

/// Engine events arrive asynchronously and a menu is slower than a keystroke.
#[test]
fn a_menu_row_chosen_on_a_tab_that_is_gone_does_nothing() {
    let mut f = Fixture::new();
    let tab = f.open();
    f.send(Action::CloseTab { tab });
    let before = f.session.browser.all_tabs().len();

    let commands = f.send(Action::ChosePageMenuItem {
        tab,
        item: PageMenuItem::OpenLinkInNewTab,
        target: on_a_link("https://example.com/a"),
    });

    assert!(commands.is_empty());
    assert_eq!(f.session.browser.all_tabs().len(), before);
}

// --- an extension's own pages -----------------------------------------------

/// WebKit mints a fresh host per loaded context, so the shape of one of these
/// is all a test can pin: a uuid that is not a hostname anybody could reach.
const EXT: &str = "webkit-extension://142b180d-a643-4516-9b24-1cc01d08d781";
const OTHER_EXT: &str = "webkit-extension://9f0c2ae1-0000-4000-8000-1cc01d08d781";

fn created_configurations(out: &[EngineCommand]) -> Vec<ViewConfiguration> {
    out.iter()
        .filter_map(|c| {
            if let EngineCommand::CreateWebView { configuration, .. } = c {
                Some(configuration.clone())
            } else {
                None
            }
        })
        .collect()
}

/// The defect, from the top: an extension asks for one of its own pages and it
/// arrives as a web search. Both halves are asserted here — that the address
/// survives `resolve` at all, and that the view it lands in is built for the
/// extension rather than for the space.
#[test]
fn a_page_inside_an_extension_gets_a_view_built_for_that_extension() {
    let mut f = Fixture::new();
    let page = format!("{EXT}/app/app.html#/page/welcome");
    let out = f.send(Action::OpenTab {
        space: None,
        url: Some(page.clone()),
        parent: None,
    });
    let tab = f.session.browser.active_tab().unwrap();

    assert_eq!(
        created_configurations(&out),
        vec![ViewConfiguration::Extension {
            base_host: "142b180d-a643-4516-9b24-1cc01d08d781".into(),
        }],
        "one view, built for the extension. Two would mean the space's was \
         built first and torn down in the same dispatch"
    );
    assert!(
        out.contains(&EngineCommand::LoadUrl {
            tab,
            url: page.clone()
        }),
        "the address was mangled on the way through: {out:?}"
    );
    assert!(!out.contains(&EngineCommand::DestroyWebView { tab }));
}

/// The half that is a security requirement rather than symmetry. Without it a
/// link off an extension's own page loads the web into the extension's
/// configuration, whose store is WebKit's shared persistent one rather than the
/// space's.
#[test]
fn leaving_an_extensions_page_puts_the_tab_back_in_its_spaces_jar() {
    let mut f = Fixture::new();
    let page = format!("{EXT}/app/app.html#/page/welcome");
    f.send(Action::OpenTab {
        space: None,
        url: Some(page),
        parent: None,
    });
    let tab = f.session.browser.active_tab().unwrap();
    let space = f.session.browser.tab(tab).unwrap().space;
    let window = f.session.browser.tab(tab).unwrap().window;

    let out = f.send(Action::NavigateTo {
        tab,
        input: "https://start.1password.com/signin/".into(),
    });

    assert!(out.contains(&EngineCommand::DestroyWebView { tab }));
    assert_eq!(
        created_configurations(&out),
        vec![ViewConfiguration::Space {
            data_store_id: "ds-personal".into(),
            profile: SpaceProfile::default(),
        }]
    );
    // The view is replaced; the tab is not. Same id, same space, same window.
    let after = f
        .session
        .browser
        .tab(tab)
        .expect("the tab outlives its view");
    assert_eq!((after.space, after.window), (space, window));
}

/// The same crossing, started by the **page** rather than by a person.
///
/// This is the half that was missing and is the one that matters in practice:
/// nobody types the address a password manager's "Sign in" goes to, the page
/// sets `window.location.href` to it. Measured before this existed, in a view
/// built from an extension's own configuration: the navigation delegate is
/// asked about `https://example.com/`, answers `.allow`, and then nothing
/// happens at all — no start, no failure, no commit — so the tab sits on the
/// extension's page and the button reads as dead.
#[test]
fn a_page_that_sent_itself_out_of_its_extension_gets_a_view_for_where_it_went() {
    let mut f = Fixture::new();
    f.send(Action::OpenTab {
        space: None,
        url: Some(format!("{EXT}/app/app.html#/page/welcome")),
        parent: None,
    });
    let tab = f.session.browser.active_tab().unwrap();
    let space = f.session.browser.tab(tab).unwrap().space;
    let window = f.session.browser.tab(tab).unwrap().window;

    let url = "https://start.1password.com/signin/?auth-only=1".to_string();
    let out = f.send(Action::PageLeftExtension {
        tab,
        url: url.clone(),
    });

    assert!(out.contains(&EngineCommand::DestroyWebView { tab }));
    assert_eq!(
        created_configurations(&out),
        vec![ViewConfiguration::Space {
            data_store_id: "ds-personal".into(),
            profile: SpaceProfile::default(),
        }],
        "the web loaded into the extension's shared jar: {out:?}"
    );
    assert!(
        out.contains(&EngineCommand::LoadUrl { tab, url }),
        "the crossing was made and then nobody went anywhere: {out:?}"
    );
    let after = f.session.browser.tab(tab).unwrap();
    assert_eq!((after.space, after.window), (space, window));
}

/// The two cases this must **not** act on, and neither is defensive tidiness.
///
/// A tab already on the web is one where the engine did carry the navigation
/// out, so answering it here would load the address a second time — and a
/// second visit to a single-use sign-in address is a flow that fails on the
/// screen (ADR-0075 measured that for pop-ups). A move inside one extension is
/// one context and costs no view (above).
#[test]
fn a_page_that_did_not_leave_an_extension_costs_no_view() {
    let mut f = Fixture::new();
    f.send(Action::OpenTab {
        space: None,
        url: Some("https://example.com/".into()),
        parent: None,
    });
    let ordinary = f.session.browser.active_tab().unwrap();
    let out = f.send(Action::PageLeftExtension {
        tab: ordinary,
        url: "https://example.com/next".into(),
    });
    assert!(out.is_empty(), "an ordinary page was loaded twice: {out:?}");

    f.send(Action::OpenTab {
        space: None,
        url: Some(format!("{EXT}/app/app.html")),
        parent: None,
    });
    let inside = f.session.browser.active_tab().unwrap();
    let out = f.send(Action::PageLeftExtension {
        tab: inside,
        url: format!("{EXT}/app/options.html#/general"),
    });
    assert!(out.is_empty(), "one extension, two views: {out:?}");
}

/// A view costs something to replace, so it is replaced only when the crossing
/// really happens. Two pages of one extension are one context.
#[test]
fn moving_between_two_pages_of_one_extension_does_not_cost_the_view() {
    let mut f = Fixture::new();
    f.send(Action::OpenTab {
        space: None,
        url: Some(format!("{EXT}/app/app.html")),
        parent: None,
    });
    let tab = f.session.browser.active_tab().unwrap();

    let out = f.send(Action::NavigateTo {
        tab,
        input: format!("{EXT}/app/options.html#/general"),
    });
    assert!(created_configurations(&out).is_empty());
    assert!(!out.contains(&EngineCommand::DestroyWebView { tab }));

    // And two extensions are two contexts, so that one does.
    let out = f.send(Action::NavigateTo {
        tab,
        input: format!("{OTHER_EXT}/options.html"),
    });
    assert!(out.contains(&EngineCommand::DestroyWebView { tab }));
    assert_eq!(
        created_configurations(&out),
        vec![ViewConfiguration::Extension {
            base_host: "9f0c2ae1-0000-4000-8000-1cc01d08d781".into(),
        }]
    );
}

/// ADR-0023 says an ephemeral space records nothing. An extension's page is
/// built from that extension's configuration, which carries WebKit's shared
/// persistent store and — measured — will not take another: assigning a
/// non-persistent one leaves `WKWebView.init` never returning. So there is
/// nowhere in a private window to put one, and it is refused rather than
/// quietly excepted.
#[test]
fn a_space_that_records_nothing_has_nowhere_to_put_an_extensions_page() {
    let mut f = Fixture::new();
    f.send(Action::CreateSpace {
        name: "Private".into(),
        data_store_id: "ds-private".into(),
        ephemeral: true,
    });
    let page = format!("{EXT}/app/app.html");
    let out = f.send(Action::OpenTab {
        space: None,
        url: Some(page.clone()),
        parent: None,
    });
    let tab = f.session.browser.active_tab().unwrap();

    assert!(
        !created_configurations(&out)
            .iter()
            .any(|c| matches!(c, ViewConfiguration::Extension { .. })),
        "a private window was handed a persistent store: {out:?}"
    );
    assert!(
        !out.iter()
            .any(|c| matches!(c, EngineCommand::LoadUrl { .. }))
    );
    // Refused as an extension's, and said so, rather than left blank.
    let after = f.session.browser.tab(tab).unwrap();
    assert_eq!(
        after.last_error.as_ref().map(|e| e.kind),
        Some(NavigationErrorKind::UnsupportedUrl)
    );
    assert_eq!(
        after.last_error.as_ref().unwrap().url.as_deref(),
        Some(page.as_str())
    );
    assert_eq!(after.pending_url, None);
}

/// The mirror of `an_address_that_names_nothing_fails_as_ours_rather_than_as_a
/// _site`: an address claiming the scheme and naming no context is refused as
/// an extension's, not repaired into whichever extension is at hand and not
/// handed to an engine that would call it a host that does not resolve.
#[test]
fn an_extension_address_naming_no_context_is_refused_rather_than_repaired() {
    let mut f = Fixture::new();
    let tab = f.open();
    let out = f.send(Action::NavigateTo {
        tab,
        input: "webkit-extension:///app/app.html".into(),
    });

    assert!(out.is_empty(), "something was asked of the engine: {out:?}");
    assert_eq!(
        f.session
            .browser
            .tab(tab)
            .unwrap()
            .last_error
            .as_ref()
            .map(|e| e.kind),
        Some(NavigationErrorKind::UnsupportedUrl)
    );
}

/// The back/forward list belongs to the view that is going. Every entry on one
/// side of the boundary is one the view on the other side refuses, so a
/// restored half would be a Back button landing on nothing.
#[test]
fn crossing_into_an_extension_does_not_carry_the_back_list_over() {
    let mut f = Fixture::new();
    let tab = f.open();
    f.send(Action::NavigationCommitted {
        tab,
        url: "https://avelino.run/".into(),
    });
    f.send(Action::NavigationStateChanged {
        tab,
        state: vec![1, 2, 3],
    });
    assert!(f.session.navigation_states.get(tab).is_some());

    let out = f.send(Action::NavigateTo {
        tab,
        input: format!("{EXT}/app/app.html"),
    });

    assert!(out.contains(&EngineCommand::DestroyWebView { tab }));
    assert!(
        out.iter().any(|c| matches!(
            c,
            EngineCommand::CreateWebView {
                navigation_state: None,
                ..
            }
        )),
        "the new view was handed the old view's history: {out:?}"
    );
    assert!(f.session.navigation_states.get(tab).is_none());
}

/// Whether a tab can go back and forward is the core's state, written by the
/// engine's report and read by everything that draws or keys a Back. The shell
/// never puts the question to its own engine (ADR-0002: two platforms could
/// not disagree about the answer, so it is not theirs to give).
#[test]
fn the_back_and_forward_answer_is_state_the_core_holds() {
    let mut f = Fixture::new();
    let tab = f.open();
    let t = f.session.browser.tab(tab).unwrap();
    assert!(
        !t.can_go_back && !t.can_go_forward,
        "no engine has spoken for a fresh tab"
    );

    let out = f.send(Action::NavigationStackChanged {
        tab,
        can_go_back: true,
        can_go_forward: false,
    });
    assert!(
        out.is_empty(),
        "a report asks nothing of the engine: {out:?}"
    );
    let t = f.session.browser.tab(tab).unwrap();
    assert!(t.can_go_back && !t.can_go_forward);

    f.send(Action::NavigationStackChanged {
        tab,
        can_go_back: false,
        can_go_forward: true,
    });
    let t = f.session.browser.tab(tab).unwrap();
    assert!(!t.can_go_back && t.can_go_forward);

    // A report for a tab that has gone changes nothing and breaks nothing.
    f.send(Action::CloseTab { tab });
    let out = f.send(Action::NavigationStackChanged {
        tab,
        can_go_back: true,
        can_go_forward: true,
    });
    assert!(out.is_empty());
    assert!(f.session.browser.tab(tab).is_none());
}
