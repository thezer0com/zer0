//! The download lifecycle, end to end through the reducer.
//!
//! These use a real temporary directory, because half of what is being checked
//! is what happens when a file is already there. A fake filesystem would pass
//! every one of them and prove nothing about the path that runs.

use std::path::{Path, PathBuf};

use super::*;
use crate::protocol::Action;

/// A directory of our own, so two tests never collide over a filename.
///
/// The name used to be the test's label and nothing else, which is a directory
/// of our own only if no two runs, threads or processes ever overlap. They do:
/// `scratch_path` is what puts the process, the thread and a counter in it.
struct Scratch {
    path: PathBuf,
}

impl Scratch {
    fn new(name: &str) -> Self {
        let path = crate::test_support::scratch_path(&format!("download-{name}"));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(&path).expect("temp directory");
        Self { path }
    }

    fn as_str(&self) -> String {
        self.path.to_string_lossy().into_owned()
    }

    fn put(&self, name: &str) -> PathBuf {
        let at = self.path.join(name);
        std::fs::write(&at, b"already here").expect("write");
        at
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.path);
    }
}

fn session() -> Session {
    Session::new("Personal", "store")
}

fn started(id: &str, suggested: &str, directory: &str) -> Action {
    Action::DownloadStarted {
        id: DownloadId(id.to_string()),
        tab: None,
        url: "https://example.com/thing".to_string(),
        suggested_filename: suggested.to_string(),
        total_bytes: Some(1000),
        default_directory: directory.to_string(),
    }
}

fn accepted_path(commands: &[EngineCommand]) -> Option<String> {
    commands.iter().find_map(|c| {
        if let EngineCommand::AcceptDownload { path, .. } = c {
            Some(path.clone())
        } else {
            None
        }
    })
}

fn only(session: &Session) -> &Download {
    session.downloads.all().first().expect("a download")
}

// MARK: - A download can never write outside the folder we chose

#[test]
fn a_traversing_filename_still_lands_in_the_download_folder() {
    let scratch = Scratch::new("traversal");
    let mut s = session();

    let commands = dispatch(
        &mut s,
        started("d1", "../../../../etc/passwd", &scratch.as_str()),
    );

    let path = accepted_path(&commands).expect("a destination");
    assert_eq!(Path::new(&path).parent(), Some(scratch.path.as_path()));
    assert_eq!(only(&s).filename, "passwd");
}

#[test]
fn a_filename_the_person_typed_into_the_panel_is_sanitised_too() {
    // A save panel will accept a name carrying a bidi override just as happily
    // as a server will send one, and the person typing it may be pasting.
    let scratch = Scratch::new("panel");
    let mut s = session();
    s.preferences.ask_where_to_save = true;
    dispatch(&mut s, started("d1", "report.pdf", &scratch.as_str()));

    let chosen = scratch.path.join("photo\u{202e}gpj.app");
    let commands = dispatch(
        &mut s,
        Action::DownloadDestinationChosen {
            id: DownloadId("d1".into()),
            path: chosen.to_string_lossy().into_owned(),
        },
    );

    let path = accepted_path(&commands).expect("a destination");
    assert!(
        !path.contains('\u{202e}'),
        "{path} still carries an override"
    );
    assert_eq!(Path::new(&path).parent(), Some(scratch.path.as_path()));
}

#[test]
fn a_file_that_is_already_there_is_never_written_over() {
    let scratch = Scratch::new("collision");
    scratch.put("report.pdf");
    let mut s = session();

    let commands = dispatch(&mut s, started("d1", "report.pdf", &scratch.as_str()));

    let path = accepted_path(&commands).expect("a destination");
    assert!(path.ends_with("report-2.pdf"), "{path}");
    assert!(
        scratch.path.join("report.pdf").exists(),
        "the original is untouched"
    );
    // The row names the file that will actually exist, not the one asked for.
    assert_eq!(only(&s).filename, "report-2.pdf");
}

#[test]
fn a_download_folder_that_is_not_there_fails_rather_than_guessing() {
    let mut s = session();

    let commands = dispatch(
        &mut s,
        started("d1", "report.pdf", "/definitely/not/here/at/all"),
    );

    assert_eq!(
        commands,
        vec![EngineCommand::CancelDownload {
            id: DownloadId("d1".into())
        }]
    );
    assert_eq!(only(&s).state, DownloadState::Failed);
    assert_eq!(
        only(&s).error.as_ref().map(|e| e.kind),
        Some(DownloadErrorKind::CannotWrite)
    );
}

#[test]
fn a_configured_folder_that_went_away_falls_back_to_the_system_one() {
    let scratch = Scratch::new("fallback");
    let mut s = session();
    s.preferences.download_directory = Some("/gone/since/last/week".to_string());

    let commands = dispatch(&mut s, started("d1", "report.pdf", &scratch.as_str()));

    let path = accepted_path(&commands).expect("a destination");
    assert_eq!(Path::new(&path).parent(), Some(scratch.path.as_path()));
}

#[test]
fn two_downloads_of_the_same_name_at_once_do_not_share_a_destination() {
    // The file only appears when the first byte lands, so both see an empty
    // folder. Without reserving the path, both are sent to report.pdf and the
    // second writes over the first.
    let scratch = Scratch::new("simultaneous");
    let mut s = session();

    let first = dispatch(&mut s, started("d1", "report.pdf", &scratch.as_str()));
    let second = dispatch(&mut s, started("d2", "report.pdf", &scratch.as_str()));

    let a = accepted_path(&first).expect("a destination");
    let b = accepted_path(&second).expect("a destination");
    assert_ne!(a, b);
    assert!(b.ends_with("report-2.pdf"), "{b}");
}

#[test]
fn a_name_freed_by_a_download_that_never_landed_can_be_used_again() {
    // A reservation only holds while the transfer does. One that failed leaves
    // nothing behind, so the next attempt should get the plain name back.
    let scratch = Scratch::new("released");
    let mut s = session();
    dispatch(&mut s, started("d1", "report.pdf", &scratch.as_str()));
    dispatch(
        &mut s,
        Action::DownloadFailed {
            id: DownloadId("d1".into()),
            kind: DownloadErrorKind::Offline,
            message: String::new(),
        },
    );

    let commands = dispatch(&mut s, started("d2", "report.pdf", &scratch.as_str()));

    let path = accepted_path(&commands).expect("a destination");
    assert!(path.ends_with("report.pdf"), "{path}");
    assert!(!path.ends_with("report-2.pdf"), "{path}");
}

#[test]
fn a_repeated_id_is_ignored_rather_than_overwriting_a_live_download() {
    let scratch = Scratch::new("repeat");
    let mut s = session();
    dispatch(&mut s, started("d1", "first.pdf", &scratch.as_str()));

    let commands = dispatch(&mut s, started("d1", "second.pdf", &scratch.as_str()));

    assert!(commands.is_empty());
    assert_eq!(s.downloads.all().len(), 1);
    assert_eq!(only(&s).filename, "first.pdf");
}

// MARK: - What the interface is allowed to claim

#[test]
fn a_download_with_no_content_length_reports_no_percentage() {
    let scratch = Scratch::new("indeterminate");
    let mut s = session();
    dispatch(
        &mut s,
        Action::DownloadStarted {
            id: DownloadId("d1".into()),
            tab: None,
            url: "https://example.com/stream".into(),
            suggested_filename: "stream.bin".into(),
            total_bytes: None,
            default_directory: scratch.as_str(),
        },
    );

    dispatch(
        &mut s,
        Action::DownloadProgressed {
            id: DownloadId("d1".into()),
            received_bytes: 4096,
            total_bytes: None,
        },
    );

    assert_eq!(only(&s).received_bytes, 4096);
    assert_eq!(
        only(&s).fraction(),
        None,
        "there is nothing to be a fraction of"
    );
}

#[test]
fn finishing_turns_an_unknown_size_into_a_known_one() {
    // The file is whole, so its size is a fact now rather than a guess.
    let scratch = Scratch::new("finish-unknown");
    let mut s = session();
    dispatch(
        &mut s,
        Action::DownloadStarted {
            id: DownloadId("d1".into()),
            tab: None,
            url: "https://example.com/stream".into(),
            suggested_filename: "stream.bin".into(),
            total_bytes: None,
            default_directory: scratch.as_str(),
        },
    );
    dispatch(
        &mut s,
        Action::DownloadProgressed {
            id: DownloadId("d1".into()),
            received_bytes: 4096,
            total_bytes: None,
        },
    );

    dispatch(
        &mut s,
        Action::DownloadFinished {
            id: DownloadId("d1".into()),
        },
    );

    assert_eq!(only(&s).state, DownloadState::Completed);
    assert_eq!(only(&s).total_bytes, Some(4096));
    assert_eq!(only(&s).fraction(), Some(1.0));
}

#[test]
fn progress_never_runs_backwards() {
    // Reports arrive out of order often enough, and a bar that retreats is
    // something nobody can explain to the person watching it.
    let scratch = Scratch::new("backwards");
    let mut s = session();
    dispatch(&mut s, started("d1", "f.bin", &scratch.as_str()));
    dispatch(
        &mut s,
        Action::DownloadProgressed {
            id: DownloadId("d1".into()),
            received_bytes: 900,
            total_bytes: Some(1000),
        },
    );

    dispatch(
        &mut s,
        Action::DownloadProgressed {
            id: DownloadId("d1".into()),
            received_bytes: 100,
            total_bytes: Some(1000),
        },
    );

    assert_eq!(only(&s).received_bytes, 900);
}

#[test]
fn progress_after_the_end_does_not_un_finish_a_download() {
    let scratch = Scratch::new("late-progress");
    let mut s = session();
    dispatch(&mut s, started("d1", "f.bin", &scratch.as_str()));
    dispatch(
        &mut s,
        Action::DownloadFinished {
            id: DownloadId("d1".into()),
        },
    );

    dispatch(
        &mut s,
        Action::DownloadProgressed {
            id: DownloadId("d1".into()),
            received_bytes: 5,
            total_bytes: Some(1000),
        },
    );

    assert_eq!(only(&s).state, DownloadState::Completed);
}

// MARK: - Failure

#[test]
fn a_failure_carries_the_cause_it_was_given() {
    let scratch = Scratch::new("failure");
    let mut s = session();
    dispatch(&mut s, started("d1", "f.bin", &scratch.as_str()));

    dispatch(
        &mut s,
        Action::DownloadFailed {
            id: DownloadId("d1".into()),
            kind: DownloadErrorKind::NoSpace,
            message: "The disk is full.".into(),
        },
    );

    let error = only(&s).error.as_ref().expect("a cause");
    assert_eq!(only(&s).state, DownloadState::Failed);
    assert_eq!(error.kind, DownloadErrorKind::NoSpace);
    assert_eq!(error.message, "The disk is full.");
    // The URL is kept so Try Again has something to ask for.
    assert_eq!(only(&s).url, "https://example.com/thing");
}

#[test]
fn stopping_a_download_is_not_reported_back_as_a_breakage() {
    // Cancelling makes WebKit report NSURLErrorCancelled a moment later.
    // Letting that through would turn "you stopped it" into "it broke".
    let scratch = Scratch::new("cancel");
    let mut s = session();
    dispatch(&mut s, started("d1", "f.bin", &scratch.as_str()));

    let commands = dispatch(
        &mut s,
        Action::CancelDownload {
            id: DownloadId("d1".into()),
        },
    );
    dispatch(
        &mut s,
        Action::DownloadFailed {
            id: DownloadId("d1".into()),
            kind: DownloadErrorKind::ConnectionFailed,
            message: "cancelled".into(),
        },
    );

    assert_eq!(
        commands,
        vec![EngineCommand::CancelDownload {
            id: DownloadId("d1".into())
        }]
    );
    assert_eq!(only(&s).state, DownloadState::Cancelled);
    assert!(only(&s).error.is_none(), "nothing broke");
}

#[test]
fn retrying_replaces_the_failed_entry_rather_than_sitting_next_to_it() {
    let scratch = Scratch::new("retry");
    let mut s = session();
    // A tab to issue it through: a retry goes out through a web view, so the
    // space's cookies come with it.
    dispatch(
        &mut s,
        Action::OpenTab {
            space: None,
            url: None,
            parent: None,
        },
    );
    let tab = s.browser.active_tab().expect("a tab");
    dispatch(&mut s, started("d1", "f.bin", &scratch.as_str()));
    dispatch(
        &mut s,
        Action::DownloadFailed {
            id: DownloadId("d1".into()),
            kind: DownloadErrorKind::Offline,
            message: String::new(),
        },
    );

    let commands = dispatch(
        &mut s,
        Action::RetryDownload {
            id: DownloadId("d1".into()),
        },
    );

    assert_eq!(
        commands,
        vec![EngineCommand::StartDownload {
            tab,
            url: "https://example.com/thing".into()
        }]
    );
    assert!(s.downloads.all().is_empty());
}

#[test]
fn retrying_something_still_running_would_start_a_second_copy_so_it_does_not() {
    let scratch = Scratch::new("retry-live");
    let mut s = session();
    dispatch(&mut s, started("d1", "f.bin", &scratch.as_str()));

    let commands = dispatch(
        &mut s,
        Action::RetryDownload {
            id: DownloadId("d1".into()),
        },
    );

    assert!(commands.is_empty());
    assert_eq!(s.downloads.all().len(), 1);
}

// MARK: - Carrying on where it stopped (ADR-0101)

/// A session with one tab and one download that stopped partway.
fn stopped_partway(scratch: &Scratch, name: &str) -> (Session, TabId) {
    let mut s = session();
    dispatch(
        &mut s,
        Action::OpenTab {
            space: None,
            url: None,
            parent: None,
        },
    );
    let tab = s.browser.active_tab().expect("a tab");
    dispatch(&mut s, started("d1", name, &scratch.as_str()));
    dispatch(
        &mut s,
        Action::DownloadProgressed {
            id: DownloadId("d1".into()),
            received_bytes: 400,
            total_bytes: Some(1000),
        },
    );
    dispatch(
        &mut s,
        Action::DownloadFailed {
            id: DownloadId("d1".into()),
            kind: DownloadErrorKind::ConnectionFailed,
            message: String::new(),
        },
    );
    (s, tab)
}

fn resumable(s: &mut Session, can: bool) -> Vec<EngineCommand> {
    dispatch(
        s,
        Action::DownloadResumability {
            id: DownloadId("d1".into()),
            resumable: can,
        },
    )
}

/// The whole reason `Resume` is a different word from `Try Again`: a retry
/// starts at byte zero and this does not.
#[test]
fn resuming_keeps_the_entry_and_the_bytes_that_already_arrived() {
    let scratch = Scratch::new("resume-keeps");
    let (mut s, tab) = stopped_partway(&scratch, "f.bin");
    resumable(&mut s, true);
    assert!(only(&s).resumable);

    let commands = dispatch(
        &mut s,
        Action::ResumeDownload {
            id: DownloadId("d1".into()),
        },
    );

    assert_eq!(
        commands,
        vec![EngineCommand::ResumeDownload {
            tab,
            id: DownloadId("d1".into())
        }]
    );
    let d = only(&s);
    assert_eq!(s.downloads.all().len(), 1, "no second row for one file");
    assert_eq!(d.state, DownloadState::InProgress);
    assert_eq!(d.received_bytes, 400, "nobody threw those bytes away");
    assert!(d.error.is_none());
    // Spent. A second press must not ask the host to spend the same blob twice.
    assert!(!d.resumable);
}

/// The offer exists only while the host is holding something to spend, and the
/// host is the only thing that can say so.
#[test]
fn a_download_nobody_kept_resume_data_for_cannot_be_resumed() {
    let scratch = Scratch::new("resume-none");
    let (mut s, _) = stopped_partway(&scratch, "f.bin");
    assert!(!only(&s).resumable, "nothing has said it can carry on");

    let commands = dispatch(
        &mut s,
        Action::ResumeDownload {
            id: DownloadId("d1".into()),
        },
    );

    assert!(commands.is_empty());
    assert_eq!(only(&s).state, DownloadState::Failed);
}

/// The `false` half. Without it, a row goes on offering a Resume the host can no
/// longer honour — which is worse than never having offered one (ADR-0018).
#[test]
fn a_download_whose_resume_data_went_away_stops_offering_to_carry_on() {
    let scratch = Scratch::new("resume-lost");
    let (mut s, _) = stopped_partway(&scratch, "f.bin");
    resumable(&mut s, true);
    resumable(&mut s, false);

    assert!(!only(&s).resumable);
    let commands = dispatch(
        &mut s,
        Action::ResumeDownload {
            id: DownloadId("d1".into()),
        },
    );
    assert!(commands.is_empty());
}

/// A report that arrives while the bytes are still coming is late traffic about
/// a stop that has not happened, and a finished file has nothing left to fetch.
#[test]
fn only_a_stopped_and_unfinished_download_can_be_marked_resumable() {
    let scratch = Scratch::new("resume-live");
    let mut s = session();
    dispatch(&mut s, started("d1", "f.bin", &scratch.as_str()));

    resumable(&mut s, true);
    assert!(!only(&s).resumable, "still arriving");

    dispatch(
        &mut s,
        Action::DownloadFinished {
            id: DownloadId("d1".into()),
        },
    );
    resumable(&mut s, true);
    assert!(!only(&s).resumable, "the whole file is on disk");
}

/// Two connections writing to one path is the failure this refuses, and it is
/// the same shape `RetryDownload` already refuses.
#[test]
fn resuming_something_still_arriving_would_open_a_second_connection_so_it_does_not() {
    let scratch = Scratch::new("resume-running");
    let (mut s, _) = stopped_partway(&scratch, "f.bin");
    resumable(&mut s, true);
    dispatch(
        &mut s,
        Action::ResumeDownload {
            id: DownloadId("d1".into()),
        },
    );

    assert_eq!(only(&s).state, DownloadState::InProgress);

    // Set past the reducer, which is what isolates the guard this test is
    // about: `DownloadResumability` refuses a running download, so asking
    // through it would leave the flag false and the refusal below would happen
    // for the wrong reason — a green test either way.
    s.downloads
        .get_mut(&DownloadId("d1".into()))
        .expect("the row")
        .resumable = true;

    let commands = dispatch(
        &mut s,
        Action::ResumeDownload {
            id: DownloadId("d1".into()),
        },
    );
    assert!(commands.is_empty());
    assert_eq!(s.downloads.all().len(), 1);
}

/// A person's Stop is a pause, because the host keeps what it would take to
/// carry on. There is no paused state and this is why one is not needed.
#[test]
fn stopping_a_download_yourself_can_still_be_carried_on_from() {
    let scratch = Scratch::new("resume-cancel");
    let mut s = session();
    dispatch(
        &mut s,
        Action::OpenTab {
            space: None,
            url: None,
            parent: None,
        },
    );
    let tab = s.browser.active_tab().expect("a tab");
    dispatch(&mut s, started("d1", "f.bin", &scratch.as_str()));
    dispatch(
        &mut s,
        Action::CancelDownload {
            id: DownloadId("d1".into()),
        },
    );
    resumable(&mut s, true);

    let commands = dispatch(
        &mut s,
        Action::ResumeDownload {
            id: DownloadId("d1".into()),
        },
    );
    assert_eq!(
        commands,
        vec![EngineCommand::ResumeDownload {
            tab,
            id: DownloadId("d1".into())
        }]
    );
}

// MARK: - The list

#[test]
fn removing_an_entry_leaves_the_file_alone() {
    let scratch = Scratch::new("remove");
    let mut s = session();
    let commands = dispatch(&mut s, started("d1", "keep.bin", &scratch.as_str()));
    let path = accepted_path(&commands).expect("a destination");
    std::fs::write(&path, b"downloaded").expect("write");
    dispatch(
        &mut s,
        Action::DownloadFinished {
            id: DownloadId("d1".into()),
        },
    );

    dispatch(
        &mut s,
        Action::RemoveDownload {
            id: DownloadId("d1".into()),
        },
    );

    assert!(s.downloads.all().is_empty());
    assert!(
        Path::new(&path).exists(),
        "the file is the person's, not ours"
    );
}

#[test]
fn clearing_keeps_whatever_is_still_arriving() {
    let scratch = Scratch::new("clear");
    let mut s = session();
    dispatch(&mut s, started("done", "a.bin", &scratch.as_str()));
    dispatch(
        &mut s,
        Action::DownloadFinished {
            id: DownloadId("done".into()),
        },
    );
    dispatch(&mut s, started("live", "b.bin", &scratch.as_str()));

    dispatch(&mut s, Action::ClearFinishedDownloads);

    assert_eq!(s.downloads.all().len(), 1);
    assert_eq!(s.downloads.in_flight_count(), 1);
}

#[test]
fn asking_where_to_save_holds_the_download_until_an_answer_comes_back() {
    let scratch = Scratch::new("ask");
    let mut s = session();
    s.preferences.ask_where_to_save = true;

    let commands = dispatch(&mut s, started("d1", "report.pdf", &scratch.as_str()));

    assert_eq!(
        commands,
        vec![EngineCommand::AskDownloadDestination {
            id: DownloadId("d1".into()),
            directory: scratch.as_str(),
            filename: "report.pdf".into(),
        }]
    );
    // The row exists so the shelf can already say something is happening, and
    // it has no path yet because nowhere has been chosen.
    assert_eq!(only(&s).state, DownloadState::InProgress);
    assert!(only(&s).path.is_empty());
}

// MARK: - Persistence

#[cfg(feature = "store")]
mod persistence {
    use super::*;
    use crate::session_store::SessionStore;
    use crate::storable::StorableSession;
    use crate::store::Store;

    fn saved_and_loaded(session: &Session) -> Session {
        let mut store = Store::in_memory().expect("store");
        store
            .save(&StorableSession::project(session))
            .expect("save");
        store.load().expect("load").expect("a session")
    }

    #[test]
    fn a_finished_download_comes_back_after_a_restart() {
        let scratch = Scratch::new("persist-done");
        let mut s = session();
        let commands = dispatch(&mut s, started("d1", "report.pdf", &scratch.as_str()));
        let path = accepted_path(&commands).expect("a destination");
        std::fs::write(&path, b"pdf").expect("write");
        dispatch(
            &mut s,
            Action::DownloadFinished {
                id: DownloadId("d1".into()),
            },
        );

        let restored = saved_and_loaded(&s);

        assert_eq!(restored.downloads.all().len(), 1);
        assert_eq!(restored.downloads.all()[0].filename, "report.pdf");
        assert_eq!(restored.downloads.all()[0].state, DownloadState::Completed);
    }

    /// Resume data lives in the host and dies with the process. A row that came
    /// back offering to carry on would be offering to spend something nothing
    /// holds — a Resume that fails on the one occasion somebody needs it, which
    /// ADR-0018 rates worse than no button at all.
    ///
    /// `StorableDownload` has no field for it, so this cannot be undone by
    /// changing a line: it takes adding one. That is the point (ADR-0101).
    #[test]
    fn a_download_does_not_come_back_offering_to_carry_on() {
        let scratch = Scratch::new("persist-resume");
        let mut s = session();
        let commands = dispatch(&mut s, started("d1", "report.pdf", &scratch.as_str()));
        let path = accepted_path(&commands).expect("a destination");
        std::fs::write(&path, b"pdf").expect("write");
        // Set past the reducer on purpose. The reducer refuses to mark a
        // running download resumable, and the two states that *are* resumable —
        // cancelled and failed — are never written down at all, so the only way
        // to ask the store this question is to hand it the claim directly. That
        // is what makes this a test of the store rather than of the reducer.
        s.downloads
            .get_mut(&DownloadId("d1".into()))
            .expect("the row")
            .resumable = true;

        let restored = saved_and_loaded(&s);

        let d = &restored.downloads.all()[0];
        assert_eq!(d.state, DownloadState::Interrupted);
        assert!(!d.resumable, "a restored row cannot carry on from anywhere");
    }

    #[test]
    fn an_entry_whose_file_is_gone_is_not_brought_back() {
        // A list of rows that reveal nothing in Finder is worse than no list.
        let scratch = Scratch::new("persist-missing");
        let mut s = session();
        let commands = dispatch(&mut s, started("d1", "report.pdf", &scratch.as_str()));
        let path = accepted_path(&commands).expect("a destination");
        std::fs::write(&path, b"pdf").expect("write");
        dispatch(
            &mut s,
            Action::DownloadFinished {
                id: DownloadId("d1".into()),
            },
        );

        let mut store = Store::in_memory().expect("store");
        store.save(&StorableSession::project(&s)).expect("save");
        std::fs::remove_file(&path).expect("remove");
        let restored = store.load().expect("load").expect("a session");

        assert!(restored.downloads.all().is_empty());
    }

    #[test]
    fn a_download_still_running_comes_back_as_interrupted_not_as_running() {
        // Quitting stops it, and `WKDownload` goes with the process. A row
        // that came back saying "in progress" would draw a bar for a transfer
        // that ended hours ago.
        let scratch = Scratch::new("persist-live");
        let mut s = session();
        let commands = dispatch(&mut s, started("d1", "big.iso", &scratch.as_str()));
        let path = accepted_path(&commands).expect("a destination");
        std::fs::write(&path, b"partial").expect("write");

        let restored = saved_and_loaded(&s);

        assert_eq!(restored.downloads.all().len(), 1);
        assert_eq!(
            restored.downloads.all()[0].state,
            DownloadState::Interrupted
        );
        assert_eq!(
            restored.downloads.in_flight_count(),
            0,
            "nothing is running in a session that has just started"
        );
    }

    #[test]
    fn saving_a_live_download_does_not_change_what_is_on_screen() {
        // The row on disk says what would be true if that save were the last
        // thing written. The running browser is unaffected.
        let scratch = Scratch::new("persist-live-inmemory");
        let mut s = session();
        dispatch(&mut s, started("d1", "big.iso", &scratch.as_str()));

        let mut store = Store::in_memory().expect("store");
        store.save(&StorableSession::project(&s)).expect("save");

        assert_eq!(s.downloads.in_flight_count(), 1);
    }

    #[test]
    fn a_failure_is_not_carried_into_the_next_session() {
        // There is no file at the end of it, so the row would offer Reveal in
        // Finder for something that was never there.
        let scratch = Scratch::new("persist-failed");
        let mut s = session();
        dispatch(&mut s, started("d1", "f.bin", &scratch.as_str()));
        dispatch(
            &mut s,
            Action::DownloadFailed {
                id: DownloadId("d1".into()),
                kind: DownloadErrorKind::Offline,
                message: String::new(),
            },
        );

        let restored = saved_and_loaded(&s);

        assert!(restored.downloads.all().is_empty());
    }

    #[test]
    fn a_cancelled_download_is_not_carried_over_either() {
        let scratch = Scratch::new("persist-cancelled");
        let mut s = session();
        dispatch(&mut s, started("d1", "f.bin", &scratch.as_str()));
        dispatch(
            &mut s,
            Action::CancelDownload {
                id: DownloadId("d1".into()),
            },
        );

        let restored = saved_and_loaded(&s);

        assert!(restored.downloads.all().is_empty());
    }

    #[test]
    fn the_newest_download_is_still_first_after_a_restart() {
        let scratch = Scratch::new("persist-order");
        let mut s = session();
        for name in ["first.bin", "second.bin"] {
            let commands = dispatch(&mut s, started(name, name, &scratch.as_str()));
            let path = accepted_path(&commands).expect("a destination");
            std::fs::write(&path, b"x").expect("write");
            dispatch(
                &mut s,
                Action::DownloadFinished {
                    id: DownloadId(name.into()),
                },
            );
        }

        let restored = saved_and_loaded(&s);

        assert_eq!(restored.downloads.all()[0].filename, "second.bin");
    }
}
