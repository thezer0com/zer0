use super::*;

use crate::icons::{IconKey, Icons};

fn png() -> Vec<u8> {
    let mut bytes = b"\x89PNG\r\n\x1a\n".to_vec();
    bytes.extend_from_slice(b"pixels");
    bytes
}

fn icon(data_store_id: &str, host: &str, bytes: Vec<u8>) -> StoredIcon {
    StoredIcon {
        data_store_id: data_store_id.to_string(),
        host: host.to_string(),
        bytes,
        fetched_at_ms: 1_000,
    }
}

#[test]
fn the_cache_survives_a_relaunch() {
    // A directory rather than a bare file: SQLite writes `-wal` and `-shm`
    // beside the database, so removing the database alone leaves two files
    // behind for the next run to open on top of.
    let dir = crate::test_support::scratch_path("icons");
    std::fs::create_dir_all(&dir).expect("scratch directory");
    let file = dir.join("icons.sqlite");

    {
        let mut store = IconStore::open(&file).expect("open");
        store.put(&icon("ds", "a.com", png())).expect("put");
    }

    // A second process would see exactly this: a fresh handle on the same file.
    let store = IconStore::open(&file).expect("reopen");
    let restored = Icons::load(store.all().expect("read"));

    assert_eq!(
        restored.bytes(&IconKey::new("ds", "a.com")),
        Some(png().as_slice()),
        "the row was written and not read back: every site would be fetched again"
    );

    drop(store);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_site_with_no_icon_is_remembered_as_having_none() {
    let mut store = IconStore::in_memory().expect("open");
    store.put(&icon("ds", "a.com", Vec::new())).expect("put");

    let restored = Icons::load(store.all().expect("read"));

    // Nothing to draw, and nothing to ask about either: the empty row is the
    // whole reason a site with no favicon is not requested on every launch.
    assert_eq!(restored.bytes(&IconKey::new("ds", "a.com")), None);
    assert!(!restored.wants(&IconKey::new("ds", "a.com"), 1_000));
}

#[test]
fn one_site_is_one_row_per_jar() {
    let mut store = IconStore::in_memory().expect("open");
    store.put(&icon("ds", "a.com", png())).expect("first");
    store.put(&icon("ds", "a.com", png())).expect("second");
    store.put(&icon("other", "a.com", png())).expect("third");

    assert_eq!(store.all().expect("read").len(), 2);
}

#[test]
fn nothing_that_is_not_an_image_reaches_the_disk() {
    let mut store = IconStore::in_memory().expect("open");

    let refused = store.put(&icon("ds", "a.com", b"<html>404</html>".to_vec()));

    assert!(refused.is_err(), "a 404 page was written as an icon");
    assert!(store.all().expect("read").is_empty());
}

#[test]
fn a_row_that_stopped_being_an_image_is_not_handed_back() {
    // Reached by editing the file, by a format we stopped accepting, or by
    // corruption. ADR-0024: the disk is treated as hostile, and this file
    // holds bytes that came off the wire.
    let store = IconStore::in_memory().expect("open");
    store
        .conn
        .execute(
            "INSERT INTO icons (data_store_id, host, bytes, fetched_at_ms)
             VALUES ('ds', 'a.com', ?1, 1000)",
            [b"<html>not an icon</html>".to_vec()],
        )
        .expect("insert");

    assert!(store.all().expect("read").is_empty());
}

#[test]
fn closing_a_space_takes_its_rows_off_the_disk() {
    let mut store = IconStore::in_memory().expect("open");
    store.put(&icon("ds-gone", "a.com", png())).expect("put");
    store.put(&icon("ds-kept", "a.com", png())).expect("put");

    store.forget_data_store("ds-gone").expect("forget");

    let left = store.all().expect("read");
    assert_eq!(left.len(), 1);
    assert_eq!(left[0].data_store_id, "ds-kept");
}

#[test]
fn a_negative_timestamp_does_not_come_back_as_an_enormous_one() {
    // A `u64` written through an `i64` column can come back negative, and
    // `as u64` would turn that into a date far enough in the future that the
    // row is never retried again.
    let store = IconStore::in_memory().expect("open");
    store
        .conn
        .execute(
            "INSERT INTO icons (data_store_id, host, bytes, fetched_at_ms)
             VALUES ('ds', 'a.com', ?1, -5)",
            [Vec::<u8>::new()],
        )
        .expect("insert");

    let restored = Icons::load(store.all().expect("read"));
    assert!(restored.wants(&IconKey::new("ds", "a.com"), RETRY_AFTER));
}

const RETRY_AFTER: u64 = crate::icons::RETRY_MISSING_AFTER_MS;
