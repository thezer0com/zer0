//! What happens when the session file cannot be read.
//!
//! This is the one failure mode where doing the obvious thing — start empty,
//! carry on — is destructive: the first autosave twenty seconds later replaces
//! a real session with a blank one, and there is no second copy. So the store
//! is detached instead, and these tests are what stops that from being quietly
//! undone.

use super::*;
use crate::protocol::Action;
use crate::reducer::dispatch;
use crate::session::Session;

/// A directory of its own per test, so two of them cannot fight over a file.
fn scratch(name: &str) -> PathBuf {
    let dir = crate::test_support::scratch_path(&format!("ffi-{name}"));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

/// Name, size and a hash of the contents of every file in the profile
/// directory, bar the icon cache.
///
/// The whole directory, not just the database: SQLite spreads a write across
/// `-wal` and `-shm` too, and a save that only landed in the log would still be
/// a save. Hashed rather than compared byte for byte only so a failure prints
/// something a human can read.
///
/// `icons.sqlite` is the one deliberate exception, and it is named rather than
/// filtered by pattern so that adding a second file to the profile cannot slip
/// past this by accident. It is a separate store holding a cache (ADR-0044),
/// and it is *supposed* to keep working while the session is detached: an
/// unreadable session is enough to be going on with without every row losing
/// its picture as well.
fn bytes_on_disk(dir: &Path) -> Vec<(String, usize, u64)> {
    let mut files: Vec<(String, usize, u64)> = std::fs::read_dir(dir)
        .unwrap()
        .filter_map(|entry| {
            let entry = entry.unwrap();
            let name = entry.file_name().to_string_lossy().into_owned();
            if name.starts_with("icons.sqlite") {
                return None;
            }
            entry.file_type().unwrap().is_file().then(|| {
                let bytes = std::fs::read(entry.path()).unwrap();
                let mut hasher = std::hash::DefaultHasher::new();
                std::hash::Hash::hash(&bytes, &mut hasher);
                (
                    entry.file_name().to_string_lossy().into_owned(),
                    bytes.len(),
                    std::hash::Hasher::finish(&hasher),
                )
            })
        })
        .collect();
    files.sort();
    files
}

/// A session worth losing: two spaces, a tab with a URL on it.
fn a_real_session() -> Session {
    let mut session = Session::new("Personal", "ds-personal");
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
        Action::CreateSpace {
            name: "Work".into(),
            data_store_id: "ds-work".into(),
            ephemeral: false,
        },
    );
    session
}

fn open_at(path: &Path) -> Arc<Zer0> {
    Zer0::open(
        path.to_str().unwrap().to_string(),
        "Personal".into(),
        "ds-fresh".into(),
    )
}

/// A full day of browsing, then the save the autosave timer would do anyway.
fn browse_and_save(zer0: &Zer0) {
    zer0.dispatch(Action::OpenTab {
        space: None,
        url: None,
        parent: None,
    });
    zer0.dispatch(Action::CreateSpace {
        name: "Somewhere else".into(),
        data_store_id: "ds-other".into(),
        ephemeral: false,
    });
    zer0.save()
        .expect("a detached store must not report failure");
    zer0.mark_clean_shutdown();
}

#[test]
fn a_session_file_that_cannot_be_opened_is_reported_and_never_written_to() {
    let dir = scratch("unopenable");
    let path = dir.join("session.sqlite");
    // Not a database at all: a truncated copy, a half-finished restore, a disk
    // that lied about a flush.
    std::fs::write(&path, b"zer0 session, allegedly").unwrap();
    let before = bytes_on_disk(&dir);

    let zer0 = open_at(&path);

    assert!(
        zer0.load_error().is_some(),
        "a session that could not be read has to be reported, not swallowed"
    );
    assert!(
        !zer0.is_persistent(),
        "saving on top of a file we could not read is the loss this exists to prevent"
    );

    browse_and_save(&zer0);

    assert_eq!(
        bytes_on_disk(&dir),
        before,
        "the session file was written over after a failed load"
    );
}

#[test]
fn a_session_that_opens_but_cannot_be_read_is_never_written_over() {
    let dir = scratch("unreadable");
    let path = dir.join("session.sqlite");

    // The session that has to survive.
    {
        let mut store = Store::open(&path).unwrap();
        store
            .save(&StorableSession::project(&a_real_session()))
            .unwrap();
    }

    // A perfectly healthy database whose *contents* have gone wrong: a space
    // name that is raw bytes rather than text. Nothing about the file stops it
    // being written to, which is exactly the point — the only thing standing
    // between this session and oblivion is the decision to detach the store.
    {
        let conn = rusqlite::Connection::open(&path).unwrap();
        conn.execute("UPDATE spaces SET name = x'00ff00ff'", [])
            .unwrap();
    }
    let size_before = std::fs::metadata(&path).unwrap().len();

    let zer0 = open_at(&path);

    assert!(zer0.load_error().is_some());
    assert!(
        !zer0.is_persistent(),
        "a session we could not read is not a session we may write over"
    );

    // Measured from just after opening, because opening is not free of side
    // effects: SQLite bumps the file change counter when the connection closes,
    // so the header differs even though not one row was touched. Reading is
    // allowed to do that. Saving is not allowed to do anything.
    let untouched = bytes_on_disk(&dir);

    browse_and_save(&zer0);

    assert_eq!(
        bytes_on_disk(&dir),
        untouched,
        "a failed load must not become a write"
    );
    assert_eq!(
        std::fs::metadata(&path).unwrap().len(),
        size_before,
        "the file did not even change size, let alone content"
    );

    // And the point of all of it: what was in there is still in there,
    // unreadable and all, for a future version or a repair tool to recover.
    let conn = rusqlite::Connection::open(&path).unwrap();
    let spaces: i64 = conn
        .query_row("SELECT COUNT(*) FROM spaces", [], |r| r.get(0))
        .unwrap();
    let url: String = conn
        .query_row("SELECT url FROM tabs WHERE url IS NOT NULL", [], |r| {
            r.get(0)
        })
        .unwrap();
    assert_eq!(spaces, 2);
    assert_eq!(url, "https://avelino.run/");
}

#[test]
fn a_detached_session_still_gets_its_icons() {
    // The reason the icon cache is a file of its own (ADR-0044). Someone whose
    // session file has gone wrong is already having the worst day this browser
    // can give them; the sidebar losing every picture as well would be a second
    // failure caused only by where we chose to put the bytes.
    let dir = scratch("detached-icons");
    let path = dir.join("session.sqlite");
    std::fs::write(&path, b"zer0 session, allegedly").unwrap();

    let zer0 = open_at(&path);
    assert!(!zer0.is_persistent());

    let space = zer0.snapshot().active_space;
    let store = zer0.snapshot().spaces[0].data_store_id.clone();
    let mut png = b"\x89PNG\r\n\x1a\n".to_vec();
    png.extend_from_slice(b"pixels");
    zer0.dispatch(Action::IconFetched {
        data_store_id: store,
        host: "avelino.run".into(),
        bytes: png.clone(),
    });

    assert_eq!(zer0.icon(space, "avelino.run".into()), Some(png));
    assert!(
        dir.join("icons.sqlite").exists(),
        "the icon cache is meant to be a file of its own, beside the session"
    );
}

#[test]
fn an_icon_is_read_back_by_the_space_that_fetched_it() {
    let dir = scratch("icons-per-space");
    let path = dir.join("session.sqlite");
    let zer0 = open_at(&path);

    let personal = zer0.snapshot().active_space;
    let store = zer0.snapshot().spaces[0].data_store_id.clone();
    zer0.dispatch(Action::CreateSpace {
        name: "Work".into(),
        data_store_id: "ds-work".into(),
        ephemeral: false,
    });
    let work = zer0.snapshot().active_space;

    let mut png = b"\x89PNG\r\n\x1a\n".to_vec();
    png.extend_from_slice(b"pixels");
    zer0.dispatch(Action::IconFetched {
        data_store_id: store,
        host: "avelino.run".into(),
        bytes: png.clone(),
    });

    assert_eq!(zer0.icon(personal, "avelino.run".into()), Some(png));
    assert_eq!(
        zer0.icon(work, "avelino.run".into()),
        None,
        "one space read another space's cache: the missing second request is a signal the site can read"
    );
    // Case is not part of the identity of a site.
    assert!(zer0.icon(personal, "AVELINO.run".into()).is_some());
}

#[test]
fn a_session_that_reads_fine_is_saved_as_usual() {
    // The control. Without it the two tests above would pass just as happily
    // on a `save()` that never wrote anything to anywhere.
    let dir = scratch("healthy");
    let path = dir.join("session.sqlite");
    {
        let mut store = Store::open(&path).unwrap();
        store
            .save(&StorableSession::project(&a_real_session()))
            .unwrap();
    }

    let zer0 = open_at(&path);

    assert!(zer0.load_error().is_none());
    assert!(zer0.is_persistent());
    assert_eq!(zer0.snapshot().spaces.len(), 2, "the session came back");

    let before = bytes_on_disk(&dir);
    browse_and_save(&zer0);
    assert_ne!(
        bytes_on_disk(&dir),
        before,
        "a healthy session must actually be written"
    );
}

// MARK: - Which extension buttons are on show

/// Unpack an extension by hand, the way an install leaves one on disk.
///
/// `has_action` is the whole variable, so it is the only thing that changes
/// between the two callers.
fn plant_extension(profile: &Path, id: &str, with_action: bool) {
    let dir = profile.join("extensions").join(id);
    std::fs::create_dir_all(&dir).unwrap();
    let action = if with_action {
        r#", "action": {"default_title": "Press me"}"#
    } else {
        ""
    };
    std::fs::write(
        dir.join("manifest.json"),
        format!(
            r#"{{"manifest_version": 3, "name": "{id}", "version": "1",
                 "permissions": ["storage"]{action}}}"#
        ),
    )
    .unwrap();
}

/// Grant it enough to be running, which is what a button needs before it is
/// worth drawing.
fn let_it_run(zer0: &Zer0, id: &str) {
    let mut decision = ConsentDecision::refusing_everything(id, 1, Vec::new());
    decision.allow(PermissionKind::Api, "storage");
    zer0.record_extension_consent(decision);
}

/// The row and the chords count through the same list, and this is the list.
///
/// ⇧⌘2 presses whatever is second here. If the shell were allowed to drop a
/// button the core still counted — the one with no `action`, say — then every
/// chord after it would press the wrong extension, and nothing on screen would
/// look wrong. So every rule that decides membership lives behind this one
/// call, and this is the test that says so.
#[test]
fn an_extension_with_no_button_is_never_on_the_row() {
    let dir = scratch("pinned-no-action");
    plant_extension(&dir, "aaaa", true);
    plant_extension(&dir, "bbbb", false);

    let zer0 = open_at(&dir.join("session.sqlite"));
    for id in ["aaaa", "bbbb"] {
        let_it_run(&zer0, id);
        zer0.adopt_extension_pin(id.into());
    }

    let row: Vec<String> = zer0.pinned_extensions().into_iter().map(|e| e.id).collect();

    assert_eq!(
        row,
        ["aaaa"],
        "a button that cannot be pressed is not drawn"
    );
    // And it is not pinnable by the back door either: adoption records a
    // decision for it, and the row still refuses to carry it.
    assert!(zer0.extension_is_pinned("bbbb".into()));
}

/// An extension that was granted nothing is installed and deliberately not
/// loaded (ADR-0028), so its button would be a picture that swallows clicks.
#[test]
fn an_extension_that_is_not_running_is_not_on_the_row() {
    let dir = scratch("pinned-not-running");
    plant_extension(&dir, "aaaa", true);
    plant_extension(&dir, "bbbb", true);

    let zer0 = open_at(&dir.join("session.sqlite"));
    let_it_run(&zer0, "aaaa");
    // "bbbb" is asked about and granted nothing, which is a decision and not an
    // omission.
    zer0.record_extension_consent(ConsentDecision::refusing_everything("bbbb", 1, Vec::new()));
    for id in ["aaaa", "bbbb"] {
        zer0.adopt_extension_pin(id.into());
    }

    let row: Vec<String> = zer0.pinned_extensions().into_iter().map(|e| e.id).collect();
    assert_eq!(row, ["aaaa"]);
}

/// The uninstall path forgets the pin, so a pin naming nothing on disk only
/// happens when a directory went away behind the browser's back. It produces
/// nothing rather than a gap: a hole in the row would shift every chord after
/// it, which is the same off-by-one from the other direction.
#[test]
fn a_pin_naming_something_no_longer_on_disk_leaves_no_gap() {
    let dir = scratch("pinned-vanished");
    plant_extension(&dir, "aaaa", true);
    plant_extension(&dir, "bbbb", true);

    let zer0 = open_at(&dir.join("session.sqlite"));
    for id in ["aaaa", "bbbb"] {
        let_it_run(&zer0, id);
        zer0.adopt_extension_pin(id.into());
    }
    std::fs::remove_dir_all(dir.join("extensions").join("aaaa")).unwrap();

    let row: Vec<String> = zer0.pinned_extensions().into_iter().map(|e| e.id).collect();
    assert_eq!(row, ["bbbb"]);
}

// MARK: - A conversation keeps its name across a restart

/// What a thread is called is derived from the thread, so it comes back from a
/// session file saying the same thing it said before the browser quit.
///
/// The name is *not* stored as a fact of its own — it is the tab's title, which
/// the session file does carry, and it is re-derived from the conversation the
/// moment that file is read (`reducer::name_our_pages`, called by
/// [`Zer0::open`]). Both halves are wanted: the stored title is what a row is
/// drawn from before anything has been dispatched, and the pass is what stops a
/// tab wearing the name of a thread the load dropped (ADR-0060).
#[test]
fn a_conversation_comes_back_called_what_it_was_called() {
    let dir = scratch("chat-name-restart");
    let path = dir.join("session.sqlite");

    {
        let zer0 = open_at(&path);
        zer0.dispatch(Action::OpenTab {
            space: None,
            url: None,
            parent: None,
        });
        let tab = zer0.snapshot().active_tab.unwrap();
        zer0.dispatch(Action::NavigationCommitted {
            tab,
            url: "https://github.com/avelino/zer0/pull/412".into(),
        });
        zer0.dispatch(Action::OpenChat {
            about: crate::protocol::ChatSubject::CurrentPage,
            ask: Some("does the migration in here roll back cleanly".into()),
        });
        zer0.save().unwrap();
        zer0.mark_clean_shutdown();
    }

    let zer0 = open_at(&path);
    let names: Vec<String> = zer0
        .snapshot()
        .tabs
        .iter()
        .filter_map(|t| t.title.clone())
        .collect();

    assert!(
        names
            .iter()
            .any(|n| n == "does the migration in here roll back cleanly"),
        "a restored conversation is called {names:?}"
    );
    assert!(
        !names.iter().any(|n| n == "Chat"),
        "a restored conversation is still called the word Chat: {names:?}"
    );
}
