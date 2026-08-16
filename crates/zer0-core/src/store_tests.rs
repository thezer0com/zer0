use super::*;
use crate::extension_permissions::consent_request;
use crate::model::NavigationErrorKind;
use crate::protocol::{Action, WindowContents};
use crate::reducer::dispatch;
use crate::shortcuts::{Chord, UiCommand};
use crate::site_permissions::{SiteCapability, SiteVerdict};

/// Builds a session with two spaces, a few tabs, history and a routing rule.
fn populated() -> Session {
    let mut s = Session::new("Personal", "ds-personal");
    dispatch(&mut s, Action::Tick { now_ms: 1_000 });

    dispatch(
        &mut s,
        Action::OpenTab {
            space: None,
            url: None,
            parent: None,
        },
    );
    let first = s.browser.active_tab().unwrap();
    dispatch(
        &mut s,
        Action::NavigationCommitted {
            tab: first,
            url: "https://avelino.run/".into(),
        },
    );
    dispatch(
        &mut s,
        Action::TitleChanged {
            tab: first,
            title: "Avelino".into(),
        },
    );
    dispatch(
        &mut s,
        Action::SetTabKind {
            tab: first,
            kind: TabKind::Pinned,
        },
    );

    dispatch(
        &mut s,
        Action::OpenTab {
            space: None,
            url: None,
            parent: Some(first),
        },
    );

    dispatch(
        &mut s,
        Action::CreateSpace {
            name: "Work".into(),
            data_store_id: "ds-work".into(),
            ephemeral: false,
        },
    );
    let work = s.browser.active_space();
    dispatch(
        &mut s,
        Action::AddRoute {
            pattern: RoutePattern::Domain {
                host: "github.com".into(),
            },
            space: work,
        },
    );
    s
}

fn round_trip(session: &Session) -> Session {
    let mut store = Store::in_memory().unwrap();
    store.save(&StorableSession::project(session)).unwrap();
    store.load().unwrap().expect("a saved session must load")
}

#[test]
fn a_saved_session_comes_back_the_same() {
    let before = populated();

    let after = round_trip(&before);

    assert_eq!(after.browser.spaces().len(), before.browser.spaces().len());
    assert_eq!(after.browser.tab_count(), before.browser.tab_count());
    assert_eq!(after.browser.active_space(), before.browser.active_space());
    assert_eq!(after.browser.active_tab(), before.browser.active_tab());
}

#[test]
fn tab_order_and_the_tree_survive() {
    let before = populated();
    let space = before.browser.spaces()[0].id;
    let order: Vec<_> = before.browser.tabs_in(space).iter().map(|t| t.id).collect();
    let parents: Vec<_> = before
        .browser
        .tabs_in(space)
        .iter()
        .map(|t| t.parent)
        .collect();

    let after = round_trip(&before);

    let restored: Vec<_> = after.browser.tabs_in(space).iter().map(|t| t.id).collect();
    assert_eq!(restored, order);
    assert_eq!(
        after
            .browser
            .tabs_in(space)
            .iter()
            .map(|t| t.parent)
            .collect::<Vec<_>>(),
        parents
    );
}

#[test]
fn pinned_tabs_come_back_pinned() {
    let before = populated();
    let pinned: Vec<_> = before
        .browser
        .all_tabs()
        .iter()
        .filter(|t| t.is_pinned())
        .map(|t| t.id)
        .collect();
    assert!(!pinned.is_empty(), "fixture should have a pinned tab");

    let after = round_trip(&before);

    for id in pinned {
        assert!(after.browser.tab(id).unwrap().is_pinned());
    }
}

#[test]
fn a_split_comes_back_as_a_split() {
    let mut before = populated();
    let space = before.browser.spaces()[0].id;
    let tabs: Vec<_> = before.browser.tabs_in(space).iter().map(|t| t.id).collect();
    dispatch(&mut before, Action::ActivateTab { tab: tabs[0] });
    dispatch(&mut before, Action::SplitWith { tab: tabs[1] });
    dispatch(&mut before, Action::SetSplitRatio { space, ratio: 0.62 });

    let after = round_trip(&before);

    // Coming back as two loose tabs would keep every page and lose the thing
    // the person actually arranged.
    let split = after.browser.split(space).expect("the pair comes back");
    assert_eq!((split.leading, split.trailing), (tabs[0], tabs[1]));
    assert!(
        (split.ratio - 0.62).abs() < f64::EPSILON,
        "the divider moved"
    );
}

#[test]
fn an_ephemeral_space_keeps_its_split_off_disk_too() {
    let mut before = populated();
    let space = before.browser.spaces()[0].id;
    let tabs: Vec<_> = before.browser.tabs_in(space).iter().map(|t| t.id).collect();
    dispatch(&mut before, Action::ActivateTab { tab: tabs[0] });
    dispatch(&mut before, Action::SplitWith { tab: tabs[1] });
    dispatch(
        &mut before,
        Action::SetSpaceProfile {
            space,
            profile: SpaceProfile {
                user_agent: None,
                ephemeral: true,
            },
        },
    );

    let after = round_trip(&before);

    // Its tabs were never written down, so a pair naming them would be two
    // empty panes.
    assert!(after.browser.split(space).is_none());
}

/// Deliberately not persisted: every restored tab is loaded again at launch,
/// so a stored failure would be shown over a page that is about to work.
#[test]
fn a_navigation_error_does_not_survive_a_restart() {
    let mut before = populated();
    let tab = before.browser.all_tabs()[0].id;
    dispatch(
        &mut before,
        Action::NavigationFailed {
            tab,
            kind: NavigationErrorKind::Offline,
            message: "The Internet connection appears to be offline.".into(),
        },
    );
    assert!(before.browser.tab(tab).unwrap().last_error.is_some());

    let after = round_trip(&before);

    assert_eq!(
        after.browser.tab(tab).unwrap().last_error,
        None,
        "yesterday's outage is not today's state"
    );
}

#[test]
fn space_profiles_survive() {
    let mut before = populated();
    let space = before.browser.active_space();
    dispatch(
        &mut before,
        Action::SetSpaceProfile {
            space,
            profile: SpaceProfile {
                user_agent: Some("zer0/0.1".into()),
                ephemeral: false,
            },
        },
    );

    let after = round_trip(&before);

    let profile = &after.browser.space(space).unwrap().profile;
    assert_eq!(profile.user_agent.as_deref(), Some("zer0/0.1"));
}

#[test]
fn an_ephemeral_space_keeps_its_tabs_off_disk() {
    let mut before = Session::new("Private", "ds-private");
    let space = before.browser.active_space();
    dispatch(
        &mut before,
        Action::SetSpaceProfile {
            space,
            profile: SpaceProfile {
                user_agent: None,
                ephemeral: true,
            },
        },
    );
    dispatch(
        &mut before,
        Action::OpenTab {
            space: None,
            url: Some("avelino.run".into()),
            parent: None,
        },
    );
    assert_eq!(before.browser.tab_count(), 1);

    let after = round_trip(&before);

    // The space itself survives; what you did in it does not.
    assert_eq!(after.browser.spaces().len(), 1);
    assert!(after.browser.space(space).unwrap().profile.ephemeral);
    assert_eq!(
        after.browser.tab_count(),
        0,
        "an ephemeral space must leave no trace of its pages"
    );
}

// --- kept pages ---------------------------------------------------------------

#[test]
fn what_you_kept_comes_back_with_its_labels() {
    let mut before = populated();
    let id = before
        .bookmarks
        .save("https://avelino.run/", "Avelino", 2_000)
        .unwrap();
    before
        .bookmarks
        .edit(id, "Read in March", &["rust".into(), "browsers".into()]);

    let after = round_trip(&before);

    let bookmark = after.bookmarks.for_url("https://avelino.run/").unwrap();
    assert_eq!(bookmark.title, "Read in March");
    assert_eq!(bookmark.tags, vec!["rust", "browsers"]);
    assert_eq!(bookmark.saved_at_ms, 2_000);
}

#[test]
fn the_order_of_what_you_kept_survives_a_relaunch() {
    // The ordering rule, checked where it is most likely to be lost: SQLite
    // returns rows in whatever order it likes, and there is no `position`
    // column to lean on because the order is derived.
    let mut before = populated();
    before.bookmarks.save("https://one.com/", "One", 1_000);
    before.bookmarks.save("https://two.com/", "Two", 2_000);
    before.bookmarks.save("https://three.com/", "Three", 3_000);

    let after = round_trip(&before);

    let urls: Vec<&str> = after
        .bookmarks
        .all()
        .iter()
        .map(|b| b.url.as_str())
        .collect();
    assert_eq!(
        urls,
        ["https://three.com/", "https://two.com/", "https://one.com/"]
    );
}

#[test]
fn a_bookmark_saved_in_an_ephemeral_space_outlives_it() {
    // The one thing an ephemeral space is allowed to leave behind, and the
    // reason is the same one that lets a download from one keep its file:
    // somebody asked for it. ADR-0023's promise is about the traces the browser
    // takes on its own — history, tabs, threads — and every one of those is
    // still gone here. What survives is an address and a name, with nothing on
    // it that says which space it came from, because `Bookmark` has no field
    // that could.
    let mut before = Session::new("Private", "ds-private");
    let space = before.browser.active_space();
    dispatch(
        &mut before,
        Action::SetSpaceProfile {
            space,
            profile: SpaceProfile {
                user_agent: None,
                ephemeral: true,
            },
        },
    );
    dispatch(
        &mut before,
        Action::OpenTab {
            space: None,
            url: Some("avelino.run".into()),
            parent: None,
        },
    );
    let tab = before.browser.active_tab().unwrap();
    dispatch(
        &mut before,
        Action::NavigationCommitted {
            tab,
            url: "https://avelino.run/".into(),
        },
    );
    dispatch(&mut before, Action::SaveBookmark { tab: None });
    assert_eq!(before.bookmarks.len(), 1);

    let after = round_trip(&before);

    assert_eq!(
        after.browser.tab_count(),
        0,
        "the tab is still a trace of a page, and still must not survive"
    );
    assert!(
        after.history.is_empty(),
        "and neither does the visit that put it there"
    );
    assert!(
        after.bookmarks.for_url("https://avelino.run/").is_some(),
        "what somebody pressed a key to keep is kept"
    );
}

#[test]
fn removing_a_bookmark_actually_removes_it_from_disk() {
    // The failure this is here for is the one history had: upserting alone left
    // the row on disk, so a page you deleted came back on the next launch.
    let mut before = populated();
    let id = before.bookmarks.save("https://a.com/", "A", 1_000).unwrap();
    let mut store = Store::in_memory().unwrap();
    store.save(&StorableSession::project(&before)).unwrap();

    before.bookmarks.remove(id);
    store.save(&StorableSession::project(&before)).unwrap();

    let after = store.load().unwrap().unwrap();
    assert!(after.bookmarks.is_empty());
}

#[test]
fn history_survives_with_its_counts() {
    let mut before = populated();
    before.history.record("https://avelino.run/", None, 2_000);

    let after = round_trip(&before);

    let entry = after.history.get("https://avelino.run/").unwrap();
    assert_eq!(entry.visit_count, 2);
    assert_eq!(entry.title.as_deref(), Some("Avelino"));
}

#[test]
fn routing_rules_survive_in_order() {
    let mut before = populated();
    let work = before.browser.spaces()[1].id;
    dispatch(
        &mut before,
        Action::AddRoute {
            pattern: RoutePattern::UrlContains {
                fragment: "/buserbrasil/".into(),
            },
            space: work,
        },
    );

    let after = round_trip(&before);

    assert_eq!(after.routes.routes().len(), 2);
    assert_eq!(
        after.routes.routes()[0].pattern,
        RoutePattern::Domain {
            host: "github.com".into()
        }
    );
    assert_eq!(after.routes.route("https://github.com/x"), Some(work));
}

#[test]
fn a_disabled_rule_comes_back_disabled() {
    let mut before = populated();
    before.routes.set_enabled(0, false);

    let after = round_trip(&before);

    assert!(!after.routes.routes()[0].enabled);
}

#[test]
fn preferences_survive() {
    let mut before = populated();
    before
        .browser
        .set_search_template("https://duckduckgo.com/?q={}");
    before.browser.set_archive_after_ms(3_600_000);

    let after = round_trip(&before);

    assert_eq!(
        after.browser.search_template(),
        "https://duckduckgo.com/?q={}"
    );
    assert_eq!(after.browser.archive_after_ms(), 3_600_000);
}

#[test]
fn autoplay_blocking_ships_on_and_survives_being_turned_off() {
    // Two failures in one, and the second is the one that hides. A field the
    // store writes but never reads back looks correct in Settings for the rest
    // of the session and is gone on the next launch — the same shape as a
    // preference applied to nothing (ADR-0074).
    let default = Preferences::default();
    assert!(
        default.block_audible_autoplay,
        "a browser any page can make noise through is a broken default"
    );

    let mut before = populated();
    before.preferences.block_audible_autoplay = false;

    let after = round_trip(&before);

    assert!(
        !after.preferences.block_audible_autoplay,
        "turning autoplay blocking off did not survive a relaunch"
    );
}

#[test]
fn popup_blocking_ships_on_and_survives_being_turned_off() {
    // The same pair of failures as the autoplay row above, and the same reason
    // for asserting both halves in one test: a preference the store writes and
    // never reads back is a switch that forgets, which reads as a bug in the
    // browser rather than as a missing line (ADR-0075).
    let default = Preferences::default();
    assert!(
        default.block_unprompted_windows,
        "a browser any page can open a window through is a broken default"
    );

    let mut before = populated();
    before.preferences.block_unprompted_windows = false;

    let after = round_trip(&before);

    assert!(
        !after.preferences.block_unprompted_windows,
        "letting pages open windows did not survive a relaunch"
    );
}

#[test]
fn background_tabs_throttle_out_of_the_box_and_survive_being_let_loose() {
    // Both halves, for the same reason as the autoplay row above: a field the
    // store writes but never reads back is correct until the day something
    // changes it, and then it forgets on relaunch. No row in Settings changes
    // this yet — a host or a future switch will, and storage is not allowed
    // to be the half that is broken when that happens (ADR-0120).
    let default = Preferences::default();
    assert!(
        default.background_throttling,
        "a browser whose background tabs are frozen rather than slowed is a broken default"
    );

    let mut before = populated();
    before.preferences.background_throttling = false;

    let after = round_trip(&before);

    assert!(
        !after.preferences.background_throttling,
        "letting background tabs run free did not survive a relaunch"
    );
}

#[test]
fn https_first_ships_on_and_survives_being_turned_off() {
    // Same pair of failures, same reason: the upgrade policy is the core's to
    // give and the store's to keep, and a value written but never read back
    // would read as browser state while being launch-time weather (ADR-0120).
    let default = Preferences::default();
    assert!(
        default.https_first,
        "a browser that navigates a typed http address over plain http is a broken default"
    );

    let mut before = populated();
    before.preferences.https_first = false;

    let after = round_trip(&before);

    assert!(
        !after.preferences.https_first,
        "turning the https upgrade off did not survive a relaunch"
    );
}

#[test]
fn a_denied_extension_permission_stays_denied_across_a_relaunch() {
    // The whole point of writing consent down. If a refusal evaporated on
    // quit, the next launch would treat it as never asked and grant it back —
    // which is how people learn that reading the dialog is a waste of time.
    let mut before = populated();
    let request = consent_request(
        "abcd",
        "Blocker",
        &["cookies".into(), "storage".into()],
        &["<all_urls>".to_string()],
    );
    let mut decision = request.default_decision(9_000);
    decision.refuse(PermissionKind::Site, "<all_urls>");
    decision.refuse(PermissionKind::Api, "cookies");
    before.extension_consent.record(decision);

    let after = round_trip(&before);
    let stored = after.extension_consent.decision("abcd").expect("recorded");

    assert!(stored.grants(PermissionKind::Api, "storage"));
    assert!(stored.refuses(PermissionKind::Site, "<all_urls>"));
    assert!(stored.refuses(PermissionKind::Api, "cookies"));
    assert!(!stored.grants(PermissionKind::Site, "<all_urls>"));
    assert_eq!(stored.decided_at_ms, 9_000);
}

#[test]
fn an_extension_that_was_granted_nothing_is_still_a_decision_after_a_relaunch() {
    // Otherwise it comes back looking like it was never asked about, and the
    // browser asks again on every single launch.
    let mut before = populated();
    before
        .extension_consent
        .record(ConsentDecision::refusing_everything("abcd", 7, Vec::new()));

    let after = round_trip(&before);

    let stored = after.extension_consent.decision("abcd").expect("recorded");
    assert!(stored.grants_nothing());
}

#[test]
fn a_pattern_nobody_could_read_survives_as_unreadable_and_not_as_granted() {
    let mut before = populated();
    before
        .extension_consent
        .record(ConsentDecision::refusing_everything(
            "abcd",
            1,
            vec!["garbage".to_string()],
        ));

    let after = round_trip(&before);

    let stored = after.extension_consent.decision("abcd").expect("recorded");
    assert_eq!(stored.unreadable_hosts, ["garbage"]);
    assert!(!stored.grants(PermissionKind::Site, "garbage"));
}

/// The whole point of the row: put a button somewhere and it is still there
/// tomorrow. A pin that lived only in the running process would put every
/// extension back on the row on every launch, which is exactly the "consent
/// that resets" failure ADR-0028 names one file over.
#[test]
fn a_pinned_extension_is_still_pinned_after_a_relaunch() {
    let mut before = populated();
    before.extension_pins.adopt("abcd");

    let after = round_trip(&before);

    assert!(after.extension_pins.is_pinned("abcd"));
}

/// The asymmetric half, and the one that actually breaks.
///
/// Adoption runs every time an extension starts, so an unpinning that came back
/// as "nobody has decided" would be undone at the next launch — the button
/// somebody deliberately hid, back again, once a day, with nothing to blame.
/// The refusal is a row, not an absence, and it has to survive as one.
#[test]
fn an_extension_deliberately_unpinned_stays_unpinned_across_a_relaunch() {
    let mut before = populated();
    before.extension_pins.adopt("abcd");
    before.extension_pins.decide("abcd", false);

    let mut after = round_trip(&before);

    assert!(
        after.extension_pins.decided("abcd"),
        "the refusal is a record"
    );
    assert!(!after.extension_pins.is_pinned("abcd"));
    assert!(
        !after.extension_pins.adopt("abcd"),
        "the next launch must not put it back"
    );
}

/// Order is data (ADR-0045 clause 3), and here it is data with a keyboard
/// shortcut pointing at it: ⇧⌘2 is whatever is second in this list. A store
/// that handed the rows back in whatever order SQLite felt like would re-point
/// every chord, silently, on somebody else's disk.
/// A refusal that came back as "nobody was asked" would put the sheet on
/// screen at every press for ever, which is how a dialog stops being read.
#[test]
fn an_answer_about_starting_a_program_survives_a_relaunch() {
    let mut before = populated();
    before.native_hosts.record(NativeHostDecision {
        extension_id: "aeblfdkhhhdcdjpifhhbdiojplfjncoa".into(),
        program: "/Applications/1Password.app/Contents/helper".into(),
        allowed: true,
        decided_at_ms: 1_700_000_000_000,
    });
    before.native_hosts.record(NativeHostDecision {
        extension_id: "aeblfdkhhhdcdjpifhhbdiojplfjncoa".into(),
        program: "/tmp/something-else".into(),
        allowed: false,
        decided_at_ms: 1_700_000_000_001,
    });

    let after = round_trip(&before);

    let allowed = after
        .native_hosts
        .decision(
            "aeblfdkhhhdcdjpifhhbdiojplfjncoa",
            "/Applications/1Password.app/Contents/helper",
        )
        .expect("the answer that was given");
    assert!(allowed.allowed);
    assert_eq!(allowed.decided_at_ms, 1_700_000_000_000);

    let refused = after
        .native_hosts
        .decision("aeblfdkhhhdcdjpifhhbdiojplfjncoa", "/tmp/something-else")
        .expect("a refusal is an answer, not an absence");
    assert!(!refused.allowed);

    // And nothing was invented about a program nobody was asked about.
    assert!(
        after
            .native_hosts
            .decision("aeblfdkhhhdcdjpifhhbdiojplfjncoa", "/bin/sh")
            .is_none()
    );
}

#[test]
fn the_order_of_the_extension_row_survives_a_relaunch() {
    let mut before = populated();
    for id in ["cccc", "aaaa", "bbbb"] {
        before.extension_pins.adopt(id);
    }
    before.extension_pins.decide("aaaa", false);

    let after = round_trip(&before);

    assert_eq!(after.extension_pins.pinned_ids(), ["cccc", "bbbb"]);
    // Including the hidden one, in its place, so showing it again puts it back
    // between the two rather than at the end.
    assert_eq!(
        after
            .extension_pins
            .all()
            .iter()
            .map(|p| p.extension_id.as_str())
            .collect::<Vec<_>>(),
        ["cccc", "aaaa", "bbbb"]
    );
}

#[test]
fn an_extension_nobody_was_asked_about_has_no_decision_after_a_relaunch() {
    // `None` has to keep meaning "do not run this yet". If a missing decision
    // loaded as an empty one, an extension installed before the browser
    // started asking would silently become a decided, permission-less one.
    let after = round_trip(&populated());

    assert!(after.extension_consent.decision("abcd").is_none());
}

#[test]
fn an_empty_database_loads_as_nothing_rather_than_failing() {
    let store = Store::in_memory().unwrap();
    assert!(store.load().unwrap().is_none());
}

#[test]
fn saving_twice_replaces_rather_than_accumulates() {
    let before = populated();
    let mut store = Store::in_memory().unwrap();

    store.save(&StorableSession::project(&before)).unwrap();
    store.save(&StorableSession::project(&before)).unwrap();
    let after = store.load().unwrap().unwrap();

    assert_eq!(after.browser.tab_count(), before.browser.tab_count());
    assert_eq!(after.routes.routes().len(), before.routes.routes().len());
}

#[test]
fn a_closed_space_is_gone_after_the_next_save() {
    let mut before = populated();
    let mut store = Store::in_memory().unwrap();
    store.save(&StorableSession::project(&before)).unwrap();

    let work = before.browser.spaces()[1].id;
    dispatch(&mut before, Action::CloseSpace { space: work });
    store.save(&StorableSession::project(&before)).unwrap();

    let after = store.load().unwrap().unwrap();
    assert_eq!(after.browser.spaces().len(), 1);
    assert!(after.routes.routes().is_empty());
}

#[test]
fn a_restored_session_keeps_handing_out_fresh_ids() {
    let before = populated();
    let highest = before
        .browser
        .all_tabs()
        .iter()
        .map(|t| t.id.0)
        .max()
        .unwrap();

    let mut after = round_trip(&before);
    dispatch(
        &mut after,
        Action::OpenTab {
            space: None,
            url: None,
            parent: None,
        },
    );

    let fresh = after.browser.active_tab().unwrap();
    assert!(
        fresh.0 > highest,
        "a reused id would collide with a restored tab: {fresh:?} vs {highest}"
    );
}

#[test]
fn a_half_written_session_is_repaired_not_trusted() {
    let before = populated();
    let mut store = Store::in_memory().unwrap();
    store.save(&StorableSession::project(&before)).unwrap();

    // Foreign keys stop us writing this, which is the point of having them.
    // Turn them off to stand in for a file written by another version, or one
    // someone opened in a SQLite browser and edited.
    store
        .conn
        .pragma_update(None, "foreign_keys", "OFF")
        .unwrap();
    store
        .conn
        .execute(
            "INSERT INTO tabs (id, space_id, position, parent_id, kind, url, title,
                               muted, zoom_factor, last_active_at)
             VALUES (9001, 4242, 0, NULL, 'today', NULL, NULL, 0, 1.0, 0)",
            [],
        )
        .unwrap();
    store
        .conn
        .execute(
            "UPDATE tabs SET parent_id = 7777 WHERE parent_id IS NULL",
            [],
        )
        .unwrap();

    let after = store
        .load()
        .unwrap()
        .expect("a repairable session still loads");

    assert!(
        after.browser.tab(TabId(9001)).is_none(),
        "a tab in a space that does not exist must be dropped"
    );
    for tab in after.browser.all_tabs() {
        if let Some(parent) = tab.parent {
            assert!(
                after.browser.tab(parent).is_some(),
                "a parent must exist: {parent:?}"
            );
        }
    }
}

#[test]
fn an_unknown_route_kind_is_skipped_without_losing_the_others() {
    let before = populated();
    let mut store = Store::in_memory().unwrap();
    store.save(&StorableSession::project(&before)).unwrap();

    // A rule written by a newer version than this one.
    store
        .conn
        .execute(
            "INSERT INTO routes (position, kind, value, space_id, enabled)
             VALUES ('99999999', 'from_the_future', 'x', 1, 1)",
            [],
        )
        .unwrap();

    let after = store.load().unwrap().unwrap();

    assert_eq!(
        after.routes.routes().len(),
        1,
        "the known rule must survive"
    );
}

#[test]
fn history_can_be_pruned_by_age() {
    let mut before = populated();
    before.history.record("https://old.com/", None, 100);
    before.history.record("https://new.com/", None, 5_000);
    let mut store = Store::in_memory().unwrap();
    store.save(&StorableSession::project(&before)).unwrap();

    let removed = store.forget_history_before(1_000).unwrap();

    let after = store.load().unwrap().unwrap();
    assert_eq!(removed, 1);
    assert!(after.history.get("https://old.com/").is_none());
    assert!(after.history.get("https://new.com/").is_some());
}

#[test]
fn a_session_survives_a_real_file_and_a_reopen() {
    let dir = crate::test_support::scratch_path("store");
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("session.sqlite");
    let _ = std::fs::remove_file(&path);

    let before = populated();
    {
        let mut store = Store::open(&path).unwrap();
        store.save(&StorableSession::project(&before)).unwrap();
    }

    // A brand new connection, the way a restart would open it.
    let store = Store::open(&path).unwrap();
    let after = store.load().unwrap().unwrap();

    assert_eq!(after.browser.tab_count(), before.browser.tab_count());
    assert_eq!(after.browser.active_tab(), before.browser.active_tab());

    let _ = std::fs::remove_dir_all(&dir);
}

// --- keyboard shortcuts -----------------------------------------------------

#[test]
fn an_untouched_keymap_stores_nothing() {
    let before = populated();
    let mut store = Store::in_memory().unwrap();
    store.save(&StorableSession::project(&before)).unwrap();

    let count: i64 = store
        .conn
        .query_row("SELECT COUNT(*) FROM keybindings", [], |r| r.get(0))
        .unwrap();

    // Storing the defaults would freeze them: a later change to the shipped
    // bindings would never reach anyone.
    assert_eq!(count, 0);
}

#[test]
fn a_rebound_shortcut_survives_a_restart() {
    let mut before = populated();
    before.keymap.bind(Chord::primary("j"), UiCommand::NextTab);

    let after = round_trip(&before);

    assert_eq!(
        after.keymap.command_for(&Chord::primary("j")),
        Some(UiCommand::NextTab)
    );
    // Everything nobody touched is still the default.
    assert_eq!(
        after.keymap.command_for(&Chord::primary("t")),
        Some(UiCommand::NewTab)
    );
}

#[test]
fn a_shortcut_with_an_argument_survives() {
    let mut before = populated();
    before
        .keymap
        .bind(Chord::primary_shift("5"), UiCommand::SelectTab { index: 5 });

    let after = round_trip(&before);

    assert_eq!(
        after.keymap.command_for(&Chord::primary_shift("5")),
        Some(UiCommand::SelectTab { index: 5 })
    );
}

#[test]
fn a_binding_this_version_does_not_understand_is_skipped() {
    let before = populated();
    let mut store = Store::in_memory().unwrap();
    store.save(&StorableSession::project(&before)).unwrap();

    // Written by a newer version that has a command this one lacks.
    store
        .conn
        .execute(
            "INSERT INTO keybindings
             (key_kind, key_value, primary_mod, shift, alt, control, command, command_arg)
             VALUES ('char', 'q', 1, 0, 0, 0, 'summon_a_dragon', NULL)",
            [],
        )
        .unwrap();

    let after = store.load().unwrap().expect("the session must still load");

    assert_eq!(after.keymap.command_for(&Chord::primary("q")), None);
    assert_eq!(
        after.keymap.command_for(&Chord::primary("t")),
        Some(UiCommand::NewTab)
    );
}

// --- what the trait promises ------------------------------------------------

#[test]
fn a_session_round_trips_through_the_trait_without_naming_the_backend() {
    let before = populated();

    // What the browser itself holds: a store whose type it cannot name. The
    // annotation is the test — if `SessionStore` stops being something you can
    // hold behind a `Box`, the shell is welded to one backend again and this
    // stops compiling.
    let mut store: Box<dyn SessionStore + Send> = Box::new(Store::in_memory().unwrap());

    assert!(
        store.load().unwrap().is_none(),
        "nothing stored yet is an answer, not a failure"
    );
    store.save(&StorableSession::project(&before)).unwrap();
    let after = store.load().unwrap().expect("a saved session must load");

    assert_eq!(after.browser.tab_count(), before.browser.tab_count());
    assert_eq!(after.routes.routes().len(), before.routes.routes().len());
    assert!(!store.take_clean_shutdown().unwrap());
}

#[test]
fn a_save_that_fails_partway_leaves_the_stored_session_alone() {
    let mut before = populated();
    let mut store = Store::in_memory().unwrap();
    store.save(&StorableSession::project(&before)).unwrap();
    let tabs = before.browser.tab_count();

    // A save that gets underway and then cannot finish. A full disk or a file
    // pulled out from under us does this for real; a trigger is the only way
    // to make it happen at a chosen point — here, after the deletes and the
    // tabs have gone in and before the routes do.
    store
        .conn
        .execute_batch(
            "CREATE TRIGGER refuse_routes BEFORE INSERT ON routes
             BEGIN SELECT RAISE(ABORT, 'the disk said no'); END;",
        )
        .unwrap();

    before.history.clear();
    dispatch(
        &mut before,
        Action::OpenTab {
            space: None,
            url: None,
            parent: None,
        },
    );
    assert!(
        store.save(&StorableSession::project(&before)).is_err(),
        "the failure has to actually happen, or this test proves nothing"
    );

    // Not half of two sessions: the one that was last saved whole.
    let after = store
        .load()
        .unwrap()
        .expect("the session saved before the failure is still there");
    assert_eq!(
        after.browser.tab_count(),
        tabs,
        "a tab from the failed save"
    );
    assert_eq!(after.routes.routes().len(), 1);
    assert!(
        after.history.get("https://avelino.run/").is_some(),
        "history is deleted before it is rewritten, so a save that stops in \
         the middle without putting it back has eaten it"
    );
}

// --- clean shutdown ---------------------------------------------------------

#[test]
fn a_fresh_database_has_not_shut_down_cleanly() {
    let store = Store::in_memory().unwrap();

    // Nothing was ever saved, so there is nothing to claim was clean.
    assert!(!store.take_clean_shutdown().unwrap());
}

#[test]
fn a_marked_shutdown_reads_as_clean_once() {
    let before = populated();
    let mut store = Store::in_memory().unwrap();
    store.save(&StorableSession::project(&before)).unwrap();
    store.mark_clean_shutdown().unwrap();

    assert!(store.take_clean_shutdown().unwrap());
    // Reading clears it, so this run is dirty until it quits properly too.
    assert!(!store.take_clean_shutdown().unwrap());
}

#[test]
fn a_save_without_a_quit_reads_as_a_crash() {
    let before = populated();
    let mut store = Store::in_memory().unwrap();
    store.mark_clean_shutdown().unwrap();

    // Saving mid-run must not look like a completed shutdown.
    store.save(&StorableSession::project(&before)).unwrap();
    store.mark_clean_shutdown().unwrap();
    assert!(store.take_clean_shutdown().unwrap());

    store.save(&StorableSession::project(&before)).unwrap();
    assert!(
        !store.take_clean_shutdown().unwrap(),
        "an ordinary save is not a clean quit"
    );
}

#[test]
fn the_session_still_loads_after_an_unclean_shutdown() {
    let before = populated();
    let mut store = Store::in_memory().unwrap();
    store.save(&StorableSession::project(&before)).unwrap();
    // No mark: the process died.

    let after = store
        .load()
        .unwrap()
        .expect("a crashed session must still restore");

    // Losing the marker must not lose the session. This is the whole point.
    assert_eq!(after.browser.tab_count(), before.browser.tab_count());
    assert!(!store.take_clean_shutdown().unwrap());
}

// --- history actually leaves the disk ---------------------------------------

#[test]
fn clearing_history_actually_clears_it() {
    let mut before = populated();
    before
        .history
        .record("https://embarrassing.example/", None, 100);
    let mut store = Store::in_memory().unwrap();
    store.save(&StorableSession::project(&before)).unwrap();
    assert!(
        store
            .load()
            .unwrap()
            .unwrap()
            .history
            .get("https://embarrassing.example/")
            .is_some()
    );

    before.history.clear();
    store.save(&StorableSession::project(&before)).unwrap();

    // Upserting alone left the row on disk, so clearing history emptied memory
    // and the next launch read it all back.
    let after = store.load().unwrap().unwrap();
    assert!(
        after.history.is_empty(),
        "cleared history came back: {:?}",
        after.history
    );
}

#[test]
fn forgetting_one_page_removes_it_from_disk_too() {
    let mut before = populated();
    before.history.record("https://keep.example/", None, 100);
    before.history.record("https://forget.example/", None, 100);
    let mut store = Store::in_memory().unwrap();
    store.save(&StorableSession::project(&before)).unwrap();

    before.history.forget("https://forget.example/");
    store.save(&StorableSession::project(&before)).unwrap();

    let after = store.load().unwrap().unwrap();
    assert!(after.history.get("https://forget.example/").is_none());
    assert!(after.history.get("https://keep.example/").is_some());
}

#[test]
fn pruning_by_age_is_not_undone_by_the_next_save() {
    let mut before = populated();
    before.history.record("https://old.example/", None, 100);
    before.history.record("https://new.example/", None, 9_000);
    let mut store = Store::in_memory().unwrap();
    store.save(&StorableSession::project(&before)).unwrap();

    // Pruning the disk while memory still holds the row used to be reinserted
    // by the next autosave.
    store.forget_history_before(1_000).unwrap();
    before.history.forget("https://old.example/");
    store.save(&StorableSession::project(&before)).unwrap();

    let after = store.load().unwrap().unwrap();
    assert!(after.history.get("https://old.example/").is_none());
}

#[test]
fn a_corrupt_id_does_not_overflow_the_id_counter() {
    let before = populated();
    let mut store = Store::in_memory().unwrap();
    store.save(&StorableSession::project(&before)).unwrap();

    // A negative id in storage reads back as u64::MAX, and the old +1
    // overflowed: a panic in debug, a wrap to zero in release, which would
    // then hand out ids that collide with existing tabs.
    store
        .conn
        .execute(
            "UPDATE tabs SET id = -1 WHERE id = (SELECT MIN(id) FROM tabs)",
            [],
        )
        .unwrap();

    let after = store.load().unwrap().expect("must still load");

    // Whatever it decides, it must not panic and must not hand out a colliding
    // id on the next tab.
    let highest = after
        .browser
        .all_tabs()
        .iter()
        .map(|t| t.id.0)
        .max()
        .unwrap_or(0);
    let mut after = after;
    crate::reducer::dispatch(
        &mut after,
        Action::OpenTab {
            space: None,
            url: None,
            parent: None,
        },
    );
    let fresh = after.browser.active_tab().unwrap();
    assert!(
        after
            .browser
            .all_tabs()
            .iter()
            .filter(|t| t.id == fresh)
            .count()
            == 1,
        "handed out a colliding id: {fresh:?} against a high water mark of {highest}"
    );
}

// MARK: - What a site was allowed to point at you

#[test]
fn a_site_refused_a_camera_stays_refused_across_a_relaunch() {
    // The whole point of writing an answer down. A refusal that evaporates on
    // quit is a site that gets to ask again tomorrow, which teaches people to
    // stop reading the sheet — the sentence ADR-0028 wrote for extensions,
    // aimed at something a *page* triggers whenever it likes.
    let mut before = populated();
    let space = before.browser.active_space();
    before.site_permissions.record(
        space,
        "https://meet.example",
        SiteCapability::Camera,
        false,
        9_000,
    );
    before.site_permissions.record(
        space,
        "https://meet.example",
        SiteCapability::Microphone,
        true,
        9_000,
    );

    let after = round_trip(&before);

    assert_eq!(
        after
            .site_permissions
            .verdict(space, "https://meet.example", SiteCapability::Camera),
        SiteVerdict::Refused
    );
    assert_eq!(
        after
            .site_permissions
            .verdict(space, "https://meet.example", SiteCapability::Microphone),
        SiteVerdict::Allowed
    );
    // And a site nobody was asked about is still nobody-was-asked, rather than
    // collapsing into the same state as a refusal.
    assert_eq!(
        after
            .site_permissions
            .verdict(space, "https://other.example", SiteCapability::Camera),
        SiteVerdict::Undecided
    );
}

#[test]
fn an_answer_given_in_an_ephemeral_space_is_never_written_down() {
    // A grant is only worth having because it is remembered, so remembering one
    // from a space that promised to remember nothing is not a smaller version
    // of the promise — it is the promise broken (ADR-0023).
    let mut before = populated();
    let space = before.browser.active_space();
    dispatch(
        &mut before,
        Action::SetSpaceProfile {
            space,
            profile: SpaceProfile {
                user_agent: None,
                ephemeral: true,
            },
        },
    );
    before.site_permissions.record(
        space,
        "https://meet.example",
        SiteCapability::Camera,
        true,
        9_000,
    );
    // A refusal too: leaving one behind would be just as much of a trace, and
    // it is the half somebody would argue is harmless.
    before.site_permissions.record(
        space,
        "https://meet.example",
        SiteCapability::Microphone,
        false,
        9_000,
    );

    let after = round_trip(&before);

    assert!(
        after.site_permissions.all().is_empty(),
        "an ephemeral space that writes down who may watch you is a broken promise"
    );
}

#[test]
fn an_answer_given_in_one_space_comes_back_belonging_to_that_space() {
    let mut before = populated();
    let personal = before.browser.spaces()[0].id;
    let work = before.browser.spaces()[1].id;
    before.site_permissions.record(
        work,
        "https://meet.example",
        SiteCapability::Camera,
        true,
        9_000,
    );

    let after = round_trip(&before);

    // If the space were dropped on the way to disk, one launch later the work
    // account's camera grant would be answering for the personal one.
    assert_eq!(
        after
            .site_permissions
            .verdict(work, "https://meet.example", SiteCapability::Camera),
        SiteVerdict::Allowed
    );
    assert_eq!(
        after
            .site_permissions
            .verdict(personal, "https://meet.example", SiteCapability::Camera),
        SiteVerdict::Undecided
    );
}

#[test]
fn a_row_naming_a_capability_this_build_does_not_know_is_dropped_rather_than_repaired() {
    // Anything read from disk is hostile, including our own file (ADR-0024).
    // The two failure modes are not symmetrical: dropping a row costs one
    // prompt, and guessing at one hands a camera to a site over a string
    // nobody wrote.
    let before = populated();
    let space = before.browser.active_space();
    let mut store = Store::in_memory().unwrap();
    store.save(&StorableSession::project(&before)).unwrap();
    store
        .conn
        .execute(
            "INSERT INTO site_permissions
                 (space_id, origin, capability, allowed, decided_at_ms)
             VALUES (?1, ?2, ?3, 1, 1)",
            params![space.0 as i64, "https://meet.example", "retina-scanner"],
        )
        .unwrap();

    let after = store.load().unwrap().expect("a saved session must load");

    assert!(after.site_permissions.all().is_empty());
}

#[test]
fn a_thread_whose_address_is_missing_from_the_file_is_dropped_rather_than_repaired() {
    // Anything read from disk is hostile, including our own file (ADR-0024).
    // A `page` conversation with no row in `conversation_pages` names no page,
    // and the two failure modes are not symmetrical: dropping it costs one
    // thread nobody could have reached anyway, and repairing it into a thread
    // about *some* page would put last week's questions in front of whatever
    // address the repair guessed at (ADR-0060).
    let mut before = populated();
    let tab = before.browser.active_tab().unwrap();
    dispatch(
        &mut before,
        Action::NavigationCommitted {
            tab,
            url: "https://example.com/a".into(),
        },
    );
    dispatch(
        &mut before,
        Action::OpenChat {
            about: crate::protocol::ChatSubject::CurrentPage,
            ask: Some("what is this".into()),
        },
    );
    let mut store = Store::in_memory().unwrap();
    store.save(&StorableSession::project(&before)).unwrap();
    // The control: it does come back while its address is on disk beside it.
    assert_eq!(store.load().unwrap().unwrap().chat.all().len(), 1);

    store
        .conn
        .execute("DELETE FROM conversation_pages", [])
        .unwrap();

    let after = store.load().unwrap().expect("a saved session must load");

    assert!(
        after.chat.all().is_empty(),
        "a thread came back naming nothing"
    );
    // And losing one thread must not cost the session it was in.
    assert_eq!(after.browser.spaces().len(), before.browser.spaces().len());
}

#[test]
fn a_thread_whose_address_this_build_cannot_read_is_dropped_too() {
    // The same door from the other side: a row hand-edited to an address this
    // build would never produce keys a thread nothing can ever anchor to again.
    let mut before = populated();
    let tab = before.browser.active_tab().unwrap();
    dispatch(
        &mut before,
        Action::NavigationCommitted {
            tab,
            url: "https://example.com/a".into(),
        },
    );
    dispatch(
        &mut before,
        Action::OpenChat {
            about: crate::protocol::ChatSubject::CurrentPage,
            ask: Some("what is this".into()),
        },
    );
    let mut store = Store::in_memory().unwrap();
    store.save(&StorableSession::project(&before)).unwrap();

    store
        .conn
        .execute(
            "UPDATE conversation_pages SET url = ?1",
            params!["not a url"],
        )
        .unwrap();

    assert!(store.load().unwrap().unwrap().chat.all().is_empty());
}

/// ADR-0017 promises the session comes back whole. With more than one window,
/// "whole" has to include which window held what — otherwise a relaunch quietly
/// pours every tab into one window and calls it restored.
#[test]
fn which_window_held_what_survives_a_relaunch() {
    let mut before = populated();
    let first = before.browser.key_window();
    let stayed = before.browser.active_tab().unwrap();
    dispatch(
        &mut before,
        Action::OpenWindow {
            onto: WindowContents::CurrentSpace,
        },
    );
    let second = before.browser.key_window();
    let moved = before.browser.active_tab().unwrap();

    let after = round_trip(&before);

    assert_eq!(after.browser.windows().len(), 2);
    assert_eq!(after.browser.key_window(), second);
    assert_eq!(after.browser.window_of(moved), Some(second));
    assert_eq!(after.browser.window_of(stayed), Some(first));
    assert_eq!(after.browser.active_tab_in(second), Some(moved));
    assert_eq!(
        after.browser.active_space_in(second),
        before.browser.active_space_in(second)
    );
}

/// A session written by a build with no windows in its schema. The pages are
/// what somebody kept; which window they were in is not worth losing them over.
#[test]
fn a_session_written_before_windows_comes_back_in_one_window() {
    let before = populated();
    let mut store = Store::in_memory().unwrap();
    store.save(&StorableSession::project(&before)).unwrap();
    store.conn.execute("DELETE FROM windows", []).unwrap();
    store.conn.execute("DELETE FROM tab_windows", []).unwrap();

    let after = store.load().unwrap().expect("must still load");

    assert_eq!(after.browser.windows().len(), 1);
    let only = after.browser.windows()[0].id;
    assert_eq!(after.browser.key_window(), only);
    assert_eq!(after.browser.tab_count(), before.browser.tab_count());
    assert!(
        after.browser.all_tabs().iter().all(|t| t.window == only),
        "a tab with nowhere to be drawn is invisible but alive"
    );
}

/// The private window's promise, one layer further out than the projection:
/// nothing about it is in the file either.
#[test]
fn a_private_window_is_not_on_disk_after_a_save() {
    let mut before = populated();
    dispatch(
        &mut before,
        Action::OpenWindow {
            onto: WindowContents::NewPrivateSpace {
                name: "Private".into(),
                data_store_id: "ds-private".into(),
            },
        },
    );
    let private = before.browser.key_window();
    let secret = before.browser.active_tab().unwrap();
    dispatch(
        &mut before,
        Action::NavigationCommitted {
            tab: secret,
            url: "https://secret.example/".into(),
        },
    );

    let mut store = Store::in_memory().unwrap();
    store.save(&StorableSession::project(&before)).unwrap();

    let rows: i64 = store
        .conn
        .query_row(
            "SELECT COUNT(*) FROM windows WHERE id = ?1",
            [private.0 as i64],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(rows, 0, "whoever reads the file finds the private window");

    let after = store.load().unwrap().expect("must still load");
    assert!(after.browser.window(private).is_none());
    assert!(
        after
            .browser
            .all_tabs()
            .iter()
            .all(|t| t.url.as_deref() != Some("https://secret.example/")),
        "the page came back"
    );
}
