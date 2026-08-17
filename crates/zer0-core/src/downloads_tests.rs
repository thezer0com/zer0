//! Most of these are about a hostile filename, because that is where a
//! download can hurt someone. The happy path is three lines and is at the
//! bottom.

use std::collections::HashSet;
use std::path::{Path, PathBuf};

use super::*;

/// A filesystem that only knows which paths are taken.
fn folder(taken: &[&str]) -> impl Fn(&Path) -> bool + use<> {
    let taken: HashSet<PathBuf> = taken.iter().map(PathBuf::from).collect();
    move |path: &Path| taken.contains(path)
}

fn download(id: &str, state: DownloadState) -> Download {
    Download {
        id: DownloadId(id.to_string()),
        url: "https://example.com/file.zip".to_string(),
        tab: None,
        filename: "file.zip".to_string(),
        path: format!("/tmp/{id}"),
        state,
        received_bytes: 0,
        total_bytes: None,
        error: None,
        started_at_ms: 0,
        resumable: false,
    }
}

// MARK: - A name cannot escape the folder

#[test]
fn a_suggested_name_cannot_climb_out_of_the_download_folder() {
    // The whole point of the function. Everything else is detail.
    assert_eq!(safe_filename("../../../etc/passwd"), "passwd");
    assert_eq!(safe_filename("/etc/passwd"), "passwd");
    assert_eq!(
        safe_filename("..\\..\\Windows\\System32\\evil.dll"),
        "evil.dll"
    );
    assert_eq!(safe_filename("a/b/c/report.pdf"), "report.pdf");
}

#[test]
fn a_name_that_is_only_dots_does_not_become_a_directory_reference() {
    // "." and ".." are paths, not names. Left alone they would make the
    // destination the folder itself.
    assert_eq!(safe_filename("."), FALLBACK_FILENAME);
    assert_eq!(safe_filename(".."), FALLBACK_FILENAME);
    assert_eq!(safe_filename("../"), FALLBACK_FILENAME);
    assert_eq!(safe_filename("/"), FALLBACK_FILENAME);
    assert_eq!(safe_filename(""), FALLBACK_FILENAME);
    assert_eq!(safe_filename("   "), FALLBACK_FILENAME);
}

#[test]
fn a_percent_encoded_separator_stays_encoded_rather_than_becoming_one() {
    // Decoding here is the classic way traversal gets reintroduced *after*
    // the separators have been stripped. We never decode.
    let name = safe_filename("..%2f..%2fetc%2fpasswd");

    assert!(!name.contains('/'), "{name} still resolves to a path");
    assert!(!name.starts_with('.'), "{name} is hidden");
    assert_eq!(name, "%2f..%2fetc%2fpasswd");
}

#[test]
fn a_null_byte_cannot_truncate_the_name_at_the_filesystem() {
    // A C string stops at the NUL: "safe.txt\0.sh" is written as "safe.txt"
    // by anything that goes through a char*, and as the whole thing by
    // anything that does not.
    let name = safe_filename("safe.txt\u{0}.sh");

    assert!(!name.contains('\u{0}'));
    assert_eq!(name, "safe.txt-.sh");
}

#[test]
fn a_bidi_override_cannot_disguise_the_extension() {
    // U+202E makes "photo\u{202e}gpj.app" read as "photo.app" backwards —
    // in practice, as a harmless image with a very different extension.
    let name = safe_filename("photo\u{202e}gpj.app");

    assert!(
        !name.contains('\u{202e}'),
        "{name} still carries an override"
    );
    assert!(
        name.ends_with(".app"),
        "the real extension must stay visible"
    );
}

#[test]
fn a_leading_dot_cannot_hide_the_file() {
    assert_eq!(safe_filename(".zshrc"), "zshrc");
    assert_eq!(safe_filename("...hidden.sh"), "hidden.sh");
}

#[test]
fn control_characters_and_separators_are_replaced_not_dropped() {
    // Dropping them would let "ev\nil.sh" and "evil.sh" collapse to one name,
    // which is a different way of colliding on purpose.
    assert_eq!(safe_filename("re\nport\t.pdf"), "re-port-.pdf");
    assert_eq!(
        safe_filename("Macintosh HD:file.txt"),
        "Macintosh HD-file.txt"
    );
}

#[test]
fn windows_forbidden_characters_are_replaced_not_dropped() {
    // Same rule as the control characters above: dropping them would collapse
    // distinct suggestions onto one name. NTFS refuses these outright, so they
    // cannot cross onto a Windows filesystem as they are.
    assert_eq!(safe_filename("what?.pdf"), "what-.pdf");
    assert_eq!(safe_filename("a<b>*c.pdf"), "a-b--c.pdf");
    assert_eq!(safe_filename("\"quoted\".txt"), "-quoted-.txt");
    assert_eq!(safe_filename("star|craft.zip"), "star-craft.zip");
}

#[test]
fn a_windows_device_name_is_refused_whatever_its_case_or_extension() {
    // On NTFS these are not file names: "CON.txt" resolves to the console
    // device, and the reservation is matched on the stem before the first
    // dot, so "CON.tar.gz" is caught too. No character can be blamed — the
    // stem as a whole is reserved — so the fallback applies, as with a name
    // that came out empty.
    assert_eq!(safe_filename("CON"), FALLBACK_FILENAME);
    assert_eq!(safe_filename("con"), FALLBACK_FILENAME);
    assert_eq!(safe_filename("Con.txt"), FALLBACK_FILENAME);
    assert_eq!(safe_filename("nul.tar.gz"), FALLBACK_FILENAME);
    assert_eq!(safe_filename("lpt3"), FALLBACK_FILENAME);

    // Near misses that are ordinary names on every filesystem.
    assert_eq!(safe_filename("contact.txt"), "contact.txt");
    assert_eq!(safe_filename("com10.txt"), "com10.txt");
    assert_eq!(safe_filename("report.CON"), "report.CON");
    assert_eq!(safe_filename("console.log"), "console.log");
}

#[test]
fn a_name_that_only_becomes_a_device_name_after_sanitising_is_refused() {
    // Windows matches the reservation ignoring trailing dots and spaces, and
    // the trim inside safe_filename removes exactly those. The check has to
    // run on the trimmed name, or "CON." would become the console device the
    // moment its dot was stripped.
    assert_eq!(safe_filename("CON."), FALLBACK_FILENAME);
    assert_eq!(safe_filename(" .con "), FALLBACK_FILENAME);
    assert_eq!(safe_filename(".NUL"), FALLBACK_FILENAME);
}

#[test]
fn an_absurdly_long_name_is_cut_but_keeps_its_extension() {
    let long = format!("{}.pdf", "x".repeat(4000));

    let name = safe_filename(&long);

    assert!(name.len() <= MAX_FILENAME_BYTES, "{} bytes", name.len());
    assert!(
        name.ends_with(".pdf"),
        "the extension says what the file is"
    );
}

#[test]
fn cutting_a_long_name_never_splits_a_character_in_half() {
    // "é" is two bytes; a byte-wise cut lands inside one and panics.
    let long = format!("{}.pdf", "é".repeat(4000));

    let name = safe_filename(&long);

    assert!(name.len() <= MAX_FILENAME_BYTES);
    assert!(name.is_char_boundary(name.len()));
}

// MARK: - A download can add a file, never replace one

#[test]
fn an_existing_file_is_never_written_over() {
    let taken = folder(&["/d/report.pdf"]);

    let path = destination_in("/d", "report.pdf", taken).unwrap();

    assert_eq!(path, PathBuf::from("/d/report-2.pdf"));
}

#[test]
fn collisions_keep_counting_rather_than_reusing_a_number() {
    let taken = folder(&["/d/report.pdf", "/d/report-2.pdf", "/d/report-3.pdf"]);

    let path = destination_in("/d", "report.pdf", taken).unwrap();

    assert_eq!(path, PathBuf::from("/d/report-4.pdf"));
}

#[test]
fn a_double_extension_keeps_both_halves_when_numbered() {
    let taken = folder(&["/d/archive.tar.gz"]);

    let path = destination_in("/d", "archive.tar.gz", taken).unwrap();

    // ".gz" is the extension; ".tar" is part of the name and stays put.
    assert_eq!(path, PathBuf::from("/d/archive.tar-2.gz"));
}

#[test]
fn a_name_with_no_extension_is_numbered_too() {
    let taken = folder(&["/d/LICENSE"]);

    let path = destination_in("/d", "LICENSE", taken).unwrap();

    assert_eq!(path, PathBuf::from("/d/LICENSE-2"));
}

#[test]
fn a_folder_with_no_free_name_left_refuses_rather_than_overwriting() {
    // Contrived, and the point is what happens at the end of the loop: giving
    // up is correct, picking one of the taken names is not.
    let mut names = vec!["/d/f.txt".to_string()];
    names.extend((2..=MAX_COLLISION_ATTEMPTS).map(|n| format!("/d/f-{n}.txt")));
    let refs: Vec<&str> = names.iter().map(String::as_str).collect();

    assert!(destination_in("/d", "f.txt", folder(&refs)).is_none());
}

#[test]
fn the_destination_is_sanitised_even_when_the_caller_forgot() {
    // This function is the last thing before the filesystem, so it does not
    // trust having been called correctly.
    let path = destination_in("/d", "../../etc/passwd", folder(&[])).unwrap();

    assert_eq!(path, PathBuf::from("/d/passwd"));
}

#[test]
fn a_collision_suffix_cannot_push_a_name_past_the_length_limit() {
    let long = format!("{}.pdf", "x".repeat(4000));
    let filename = safe_filename(&long);
    let taken = folder(&[&format!("/d/{filename}")]);

    let path = destination_in("/d", &filename, taken).unwrap();

    let name = path.file_name().unwrap().to_str().unwrap();
    assert!(
        name.len() <= 255,
        "{} bytes would be rejected by APFS",
        name.len()
    );
}

// MARK: - Progress is only claimed when it is known

#[test]
fn an_unknown_content_length_has_no_percentage() {
    let mut d = download("a", DownloadState::InProgress);
    d.received_bytes = 4096;
    d.total_bytes = None;

    assert_eq!(d.fraction(), None);
}

#[test]
fn a_total_the_server_got_wrong_produces_no_percentage_either() {
    let mut d = download("a", DownloadState::InProgress);
    d.received_bytes = 200;
    // More has arrived than was promised, so the promise was not a total.
    d.total_bytes = Some(100);

    assert_eq!(d.fraction(), None);

    d.total_bytes = Some(0);
    assert_eq!(d.fraction(), None);
}

#[test]
fn a_known_content_length_produces_the_fraction() {
    let mut d = download("a", DownloadState::InProgress);
    d.received_bytes = 50;
    d.total_bytes = Some(200);

    assert_eq!(d.fraction(), Some(0.25));
}

// MARK: - The list

#[test]
fn newest_is_first() {
    let mut list = Downloads::new();
    list.begin(download("first", DownloadState::InProgress));
    list.begin(download("second", DownloadState::InProgress));

    assert_eq!(list.all()[0].id, DownloadId("second".into()));
}

#[test]
fn clearing_leaves_what_is_still_running_alone() {
    let mut list = Downloads::new();
    list.begin(download("done", DownloadState::Completed));
    list.begin(download("running", DownloadState::InProgress));
    list.begin(download("broken", DownloadState::Failed));

    list.retain_in_flight();

    assert_eq!(list.all().len(), 1);
    assert_eq!(list.all()[0].id, DownloadId("running".into()));
}

#[test]
fn a_running_download_is_never_evicted_to_make_room() {
    // Evicting one would leave bytes arriving with nothing on screen saying so.
    let mut list = Downloads::new();
    for n in 0..DOWNLOAD_MEMORY {
        list.begin(download(&format!("live-{n}"), DownloadState::InProgress));
    }

    list.begin(download("newest", DownloadState::InProgress));

    assert_eq!(list.in_flight_count(), DOWNLOAD_MEMORY + 1);
}

#[test]
fn the_oldest_finished_entry_makes_room_for_a_new_one() {
    let mut list = Downloads::new();
    list.begin(download("oldest", DownloadState::Completed));
    for n in 0..DOWNLOAD_MEMORY - 1 {
        list.begin(download(&format!("done-{n}"), DownloadState::Completed));
    }

    list.begin(download("newest", DownloadState::InProgress));

    assert_eq!(list.all().len(), DOWNLOAD_MEMORY);
    assert!(list.get(&DownloadId("oldest".into())).is_none());
    assert!(list.get(&DownloadId("newest".into())).is_some());
}

// Gated with the constructor it exercises: `Downloads::load` is the store's
// rebuild door, so a default-feature suite has nothing here to test.
#[cfg(feature = "store")]
#[test]
fn a_restored_list_is_capped() {
    let items: Vec<Download> = (0..DOWNLOAD_MEMORY * 2)
        .map(|n| download(&format!("d-{n}"), DownloadState::Completed))
        .collect();

    assert_eq!(Downloads::load(items).all().len(), DOWNLOAD_MEMORY);
}

// MARK: - Ordinary use

#[test]
fn an_ordinary_name_survives_untouched() {
    assert_eq!(
        safe_filename("Quarterly Report (final).pdf"),
        "Quarterly Report (final).pdf"
    );
    assert_eq!(safe_filename("relatório-2026.csv"), "relatório-2026.csv");
    assert_eq!(safe_filename("v1.2.3-arm64.dmg"), "v1.2.3-arm64.dmg");
}

#[test]
fn an_empty_folder_takes_the_name_as_it_is() {
    let path = destination_in("/d", "report.pdf", folder(&[])).unwrap();

    assert_eq!(path, PathBuf::from("/d/report.pdf"));
}

#[test]
fn a_folder_that_is_not_there_is_not_usable() {
    assert!(!is_usable_directory("/definitely/not/a/real/folder/here"));
    assert!(!is_usable_directory(""));

    // And the other direction, against a directory that really is there. Made
    // rather than borrowed: the system temp directory would do, but a test
    // that names a shared path is the thing `scripts/scratch-check.sh` exists
    // to refuse, and "usable" is a property of any directory.
    let dir = crate::test_support::scratch_path("usable");
    std::fs::create_dir_all(&dir).expect("scratch directory");
    assert!(is_usable_directory(&dir.to_string_lossy()));
    let _ = std::fs::remove_dir_all(&dir);
}
