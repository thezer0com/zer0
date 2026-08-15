use std::io::Write;

use zip::write::SimpleFileOptions;

use super::*;

/// A temp directory that cleans itself up.
struct TempDir(PathBuf);

impl TempDir {
    fn new(label: &str) -> Self {
        let path = crate::test_support::scratch_path(&format!("ext-{label}"));
        let _ = fs::remove_dir_all(&path);
        fs::create_dir_all(&path).unwrap();
        Self(path)
    }

    fn path(&self) -> &Path {
        &self.0
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

/// Builds a ZIP from (name, contents) pairs.
fn zip_of(files: &[(&str, &[u8])]) -> Vec<u8> {
    let mut buffer = Vec::new();
    {
        let mut writer = zip::ZipWriter::new(io::Cursor::new(&mut buffer));
        for (name, contents) in files {
            writer
                .start_file(*name, SimpleFileOptions::default())
                .unwrap();
            writer.write_all(contents).unwrap();
        }
        writer.finish().unwrap();
    }
    buffer
}

/// The ZIP flavour of CRC-32, spelled out because the reader checks it once an
/// entry is read to the end, and a hand-made archive has to be honest about
/// the bytes it really carries even while it lies about how many there are.
fn crc32(bytes: &[u8]) -> u32 {
    let mut crc = 0xFFFF_FFFFu32;
    for byte in bytes {
        crc ^= u32::from(*byte);
        for _ in 0..8 {
            crc = if crc & 1 == 1 {
                (crc >> 1) ^ 0xEDB8_8320
            } else {
                crc >> 1
            };
        }
    }
    !crc
}

/// One entry of a hand-assembled ZIP, headers included.
struct HandmadeEntry<'a> {
    name: &'a str,
    /// The bytes actually in the file, stored uncompressed.
    stored: &'a [u8],
    /// What the headers *say* the entry unpacks to, true or not. Anything that
    /// does not fit in 32 bits is declared through a ZIP64 extra field, which
    /// is how a 261-byte package claims to hold 8 exabytes.
    declared_size: u64,
}

/// The size fields for one entry: the 32-bit value that goes in the headers,
/// and the ZIP64 extra field carrying the real claim when it does not fit.
fn declared_size_fields(declared_size: u64) -> (u32, Vec<u8>) {
    const ZIP64_ESCAPE: u32 = 0xFFFF_FFFF;
    if declared_size < u64::from(ZIP64_ESCAPE) {
        return (declared_size as u32, Vec::new());
    }
    let mut extra = Vec::new();
    extra.extend_from_slice(&0x0001u16.to_le_bytes()); // ZIP64 extended info
    extra.extend_from_slice(&8u16.to_le_bytes()); // just the one field
    extra.extend_from_slice(&declared_size.to_le_bytes());
    (ZIP64_ESCAPE, extra)
}

/// Assembles a ZIP byte by byte so its headers can lie.
///
/// `zip`'s writer always records the real sizes, and the real size is exactly
/// what a hostile package will not tell us: either it declares something
/// enormous to make the reader allocate, or it declares nothing to slip past a
/// check and then keeps sending bytes. Both need headers written by hand.
fn handmade_zip(entries: &[HandmadeEntry]) -> Vec<u8> {
    let mut out = Vec::new();
    let mut offsets = Vec::new();
    let crcs: Vec<u32> = entries.iter().map(|e| crc32(e.stored)).collect();

    for (entry, crc) in entries.iter().zip(&crcs) {
        offsets.push(out.len() as u32);
        let name = entry.name.as_bytes();
        let (size_field, extra) = declared_size_fields(entry.declared_size);
        out.extend_from_slice(&0x0403_4b50u32.to_le_bytes()); // local header
        out.extend_from_slice(&20u16.to_le_bytes()); // version needed
        out.extend_from_slice(&0u16.to_le_bytes()); // flags
        out.extend_from_slice(&0u16.to_le_bytes()); // stored, no compression
        out.extend_from_slice(&0u16.to_le_bytes()); // time
        out.extend_from_slice(&0u16.to_le_bytes()); // date
        out.extend_from_slice(&crc.to_le_bytes()); // of the bytes really there
        out.extend_from_slice(&(entry.stored.len() as u32).to_le_bytes());
        out.extend_from_slice(&size_field.to_le_bytes());
        out.extend_from_slice(&(name.len() as u16).to_le_bytes());
        out.extend_from_slice(&(extra.len() as u16).to_le_bytes());
        out.extend_from_slice(name);
        out.extend_from_slice(&extra);
        out.extend_from_slice(entry.stored);
    }

    let directory_start = out.len() as u32;
    for ((entry, offset), crc) in entries.iter().zip(&offsets).zip(&crcs) {
        let name = entry.name.as_bytes();
        let (size_field, extra) = declared_size_fields(entry.declared_size);
        out.extend_from_slice(&0x0201_4b50u32.to_le_bytes()); // central header
        out.extend_from_slice(&20u16.to_le_bytes()); // version made by
        out.extend_from_slice(&20u16.to_le_bytes()); // version needed
        out.extend_from_slice(&0u16.to_le_bytes()); // flags
        out.extend_from_slice(&0u16.to_le_bytes()); // stored
        out.extend_from_slice(&0u16.to_le_bytes()); // time
        out.extend_from_slice(&0u16.to_le_bytes()); // date
        out.extend_from_slice(&crc.to_le_bytes());
        out.extend_from_slice(&(entry.stored.len() as u32).to_le_bytes());
        out.extend_from_slice(&size_field.to_le_bytes());
        out.extend_from_slice(&(name.len() as u16).to_le_bytes());
        out.extend_from_slice(&(extra.len() as u16).to_le_bytes());
        out.extend_from_slice(&0u16.to_le_bytes()); // comment length
        out.extend_from_slice(&0u16.to_le_bytes()); // disk number
        out.extend_from_slice(&0u16.to_le_bytes()); // internal attributes
        out.extend_from_slice(&0u32.to_le_bytes()); // external attributes
        out.extend_from_slice(&offset.to_le_bytes());
        out.extend_from_slice(name);
        out.extend_from_slice(&extra);
    }
    let directory_size = out.len() as u32 - directory_start;

    let count = entries.len() as u16;
    out.extend_from_slice(&0x0605_4b50u32.to_le_bytes()); // end of directory
    out.extend_from_slice(&0u16.to_le_bytes()); // this disk
    out.extend_from_slice(&0u16.to_le_bytes()); // disk with the directory
    out.extend_from_slice(&count.to_le_bytes());
    out.extend_from_slice(&count.to_le_bytes());
    out.extend_from_slice(&directory_size.to_le_bytes());
    out.extend_from_slice(&directory_start.to_le_bytes());
    out.extend_from_slice(&0u16.to_le_bytes()); // comment length
    out
}

/// Wraps a ZIP in a valid CRX3 envelope — genuinely signed, since the parser
/// verifies signatures. The key bytes only pick the signing key.
fn crx_of(key: &[u8], archive: &[u8]) -> Vec<u8> {
    crx::test_support::crx_signed_by(
        &[&crx::test_support::TestSigner::from_seed(key)],
        None,
        archive,
    )
}

const MANIFEST: &[u8] = br#"{
    "manifest_version": 3,
    "name": "Test Extension",
    "version": "1.2.3",
    "permissions": ["storage", "declarativeNetRequest"],
    "host_permissions": ["https://*/*"]
}"#;

fn sample_package() -> Vec<u8> {
    crx_of(
        b"test-key",
        &zip_of(&[
            ("manifest.json", MANIFEST),
            ("background.js", b"console.log('hi')"),
            ("icons/128.png", b"\x89PNG"),
        ]),
    )
}

#[test]
fn installing_lays_out_a_loadable_directory() {
    let dir = TempDir::new("install");

    let installed = install_extension(&sample_package(), dir.path(), None).unwrap();

    assert_eq!(installed.manifest.name, "Test Extension");
    assert_eq!(installed.manifest.version, "1.2.3");
    assert_eq!(installed.manifest.manifest_version, 3);

    // This directory is what WKWebExtension(resourceBaseURL:) is handed.
    let root = Path::new(&installed.path);
    assert!(root.join("manifest.json").exists());
    assert!(root.join("background.js").exists());
    assert!(
        root.join("icons/128.png").exists(),
        "nested resources must survive"
    );
}

#[test]
fn the_install_directory_is_named_for_the_verified_id() {
    let dir = TempDir::new("id-dir");

    let installed = install_extension(&sample_package(), dir.path(), None).unwrap();

    assert_eq!(
        installed.id,
        crx::test_support::TestSigner::from_seed(b"test-key").id()
    );
    assert!(installed.path.ends_with(&installed.id));
}

#[test]
fn an_entry_escaping_the_directory_is_refused() {
    let dir = TempDir::new("zipslip");
    let evil = crx_of(
        b"evil-key",
        &zip_of(&[("manifest.json", MANIFEST), ("../../escaped.txt", b"pwned")]),
    );

    let result = install_extension(&evil, dir.path(), None);

    // Writing outside the extension directory is how a package becomes a
    // remote file write. It must fail, and leave nothing behind.
    assert!(
        matches!(result, Err(ExtError::UnsafePath { .. })),
        "{result:?}"
    );
    assert!(!dir.path().parent().unwrap().join("escaped.txt").exists());
}

#[test]
fn an_absolute_entry_path_cannot_write_outside_the_directory() {
    let dir = TempDir::new("absolute");

    // The target is absolute — which is the whole point of the test — but it
    // is this run's own absolute path, not a fixed one. `/tmp/zer0-pwned` was
    // fixed, and a fixed target that nothing cleans up turns one genuine
    // failure into a machine where this test can never pass again: the file
    // stays, and every later run reads it as an escape it did not make.
    let target = TempDir::new("absolute-target");
    let escapee = target.path().join("zer0-pwned");
    let evil = crx_of(
        b"evil-key",
        &zip_of(&[
            ("manifest.json", MANIFEST),
            (escapee.to_str().expect("utf-8 path"), b"x"),
        ]),
    );

    // Either outcome is fine, refusing the package or containing the path.
    // What must never happen is a write at the absolute location.
    let result = install_extension(&evil, dir.path(), None);

    assert!(!escapee.exists(), "escaped the sandbox");
    if let Ok(installed) = result {
        assert!(
            Path::new(&installed.path).starts_with(dir.path()),
            "everything written must stay under the extension directory"
        );
    }
}

#[test]
fn a_package_without_a_manifest_is_refused() {
    let dir = TempDir::new("nomanifest");
    let package = crx_of(b"key", &zip_of(&[("background.js", b"x")]));

    assert!(matches!(
        install_extension(&package, dir.path(), None),
        Err(ExtError::NoManifest)
    ));
}

#[test]
fn a_failed_install_leaves_no_staging_directory_behind() {
    let dir = TempDir::new("staging");
    let package = crx_of(b"key", &zip_of(&[("background.js", b"x")]));

    let _ = install_extension(&package, dir.path(), None);

    let leftovers: Vec<_> = fs::read_dir(dir.path())
        .unwrap()
        .filter_map(Result::ok)
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .collect();
    assert!(leftovers.is_empty(), "left behind: {leftovers:?}");
}

#[test]
fn a_failed_upgrade_leaves_the_working_version_in_place() {
    let dir = TempDir::new("upgrade-fail");
    let good = install_extension(&sample_package(), dir.path(), None).unwrap();

    // Same signing key, so same id and same target directory, but broken.
    let broken = crx_of(b"test-key", &zip_of(&[("background.js", b"x")]));
    let result = install_extension(&broken, dir.path(), None);

    assert!(result.is_err());
    assert!(
        Path::new(&good.path).join("manifest.json").exists(),
        "a broken upgrade must not take out the installed version"
    );
    assert_eq!(installed_extensions(dir.path(), None).len(), 1);
}

#[test]
fn reinstalling_replaces_rather_than_merges() {
    let dir = TempDir::new("reinstall");
    install_extension(&sample_package(), dir.path(), None).unwrap();

    let updated = crx_of(
        b"test-key",
        &zip_of(&[(
            "manifest.json",
            br#"{"manifest_version": 3, "name": "Test Extension", "version": "2.0.0"}"#,
        )]),
    );
    let after = install_extension(&updated, dir.path(), None).unwrap();

    assert_eq!(after.manifest.version, "2.0.0");
    assert!(
        !Path::new(&after.path).join("background.js").exists(),
        "a file dropped by the new version must not linger from the old one"
    );
}

#[test]
fn installed_lists_what_is_on_disk() {
    let dir = TempDir::new("list");
    assert!(installed_extensions(dir.path(), None).is_empty());

    install_extension(&sample_package(), dir.path(), None).unwrap();
    install_extension(
        &crx_of(b"other-key", &zip_of(&[("manifest.json", MANIFEST)])),
        dir.path(),
        None,
    )
    .unwrap();

    assert_eq!(installed_extensions(dir.path(), None).len(), 2);
}

/// The whole path, from a package that names itself with a placeholder to the
/// string every screen ends up drawing.
///
/// The unit tests in `i18n` prove the resolution; this proves the resolution is
/// wired to the one function that builds a manifest. Without it, a correct
/// resolver that nothing calls still ships `__MSG_extName__` to the consent
/// sheet — which is exactly what happened.
#[test]
fn an_extension_that_names_itself_in_locales_installs_under_its_real_name() {
    let dir = TempDir::new("locales");
    let package = crx_of(
        b"i18n-key",
        &zip_of(&[
            (
                "manifest.json",
                br#"{
                    "manifest_version": 3,
                    "name": "__MSG_extName__",
                    "description": "__MSG_extDesc__",
                    "version": "8.10.0",
                    "default_locale": "en"
                }"#,
            ),
            (
                "_locales/en/messages.json",
                br#"{"extName": {"message": "1Password - Password Manager"},
                     "extDesc": {"message": "The world's most-loved password manager"}}"#,
            ),
        ]),
    );

    let installed = install_extension(&package, dir.path(), None).unwrap();
    assert_eq!(installed.manifest.name, "1Password - Password Manager");

    // And again on the way back out of the directory, because Settings lists
    // from here rather than from what install returned.
    let listed = installed_extensions(dir.path(), None);
    assert_eq!(listed.len(), 1);
    assert_eq!(listed[0].manifest.name, "1Password - Password Manager");
    assert_eq!(
        listed[0].manifest.description.as_deref(),
        Some("The world's most-loved password manager")
    );
}

/// Both JSON files a package is read for go through the same door, so a
/// byte-order mark on either is not a package that fails to install.
///
/// Awesome Screenshot is the real case, and it is total: it ships a BOM in all
/// 54 of its `messages.json` files, `serde_json` refuses a leading `U+FEFF`, so
/// the message table read as empty and the install died on
/// `UntranslatedName { key: "__MSG_extName__" }`.
///
/// The manifest carries one here too, and no package measured actually does
/// that — it is in the test because the bug was never that one reader lacked
/// the rule. It was that the rule lived at a call site instead of at the door,
/// which leaves it possible to fix the reported half and ship the other. Delete
/// `read_package_json` and inline the strip into `i18n` and this is what still
/// goes red.
#[test]
fn a_byte_order_mark_on_either_json_file_does_not_refuse_the_package() {
    let dir = TempDir::new("bom");
    let package = crx_of(
        b"bom-key",
        &zip_of(&[
            (
                "manifest.json",
                "\u{feff}{\
                    \"manifest_version\": 3,
                    \"name\": \"__MSG_extName__\",
                    \"version\": \"5.1.6\",
                    \"default_locale\": \"en\"
                }"
                .as_bytes(),
            ),
            (
                "_locales/en/messages.json",
                "\u{feff}{\"extName\": {\"message\": \"Awesome Screen Recorder & Screenshot\"}}"
                    .as_bytes(),
            ),
        ]),
    );

    let installed = install_extension(&package, dir.path(), None).unwrap();

    assert_eq!(
        installed.manifest.name,
        "Awesome Screen Recorder & Screenshot"
    );
    // `default_locale` is read off the manifest text a second time, so a mark
    // left on that read would resolve nothing and refuse the package here too.
    assert_eq!(
        installed_extensions(dir.path(), None)[0].manifest.name,
        "Awesome Screen Recorder & Screenshot"
    );
}

/// A package whose name resolves to nothing is refused rather than installed
/// under a key. The consent sheet is the reason: it is the one screen where a
/// person decides, and it has to be able to say what is asking.
#[test]
fn a_package_whose_name_resolves_to_nothing_is_refused() {
    let dir = TempDir::new("untranslated");
    let package = crx_of(
        b"untranslated-key",
        &zip_of(&[(
            "manifest.json",
            br#"{"manifest_version": 3, "name": "__MSG_extName__", "version": "1"}"#,
        )]),
    );

    let result = install_extension(&package, dir.path(), None);

    assert!(matches!(result, Err(ExtError::UntranslatedName { .. })));
    assert!(
        installed_extensions(dir.path(), None).is_empty(),
        "a refused package must not be left on disk"
    );
}

#[test]
fn uninstalling_removes_the_directory_and_is_safe_to_repeat() {
    let dir = TempDir::new("uninstall");
    let ext = install_extension(&sample_package(), dir.path(), None).unwrap();

    uninstall_extension(&ext.id, dir.path()).unwrap();
    assert!(!Path::new(&ext.path).exists());

    // Uninstalling something already gone is not an error.
    uninstall_extension(&ext.id, dir.path()).unwrap();
}

#[test]
fn listing_a_directory_that_does_not_exist_is_empty_not_an_error() {
    assert!(installed_extensions(Path::new("/nonexistent/zer0/extensions"), None).is_empty());
}

#[test]
fn a_corrupt_archive_is_reported_rather_than_panicked_on() {
    let dir = TempDir::new("corrupt");
    let package = crx_of(b"key", b"this is definitely not a zip");

    assert!(matches!(
        install_extension(&package, dir.path(), None),
        Err(ExtError::Archive(_))
    ));
}

// --- what a package is allowed to cost -------------------------------------

#[test]
fn a_package_declaring_an_absurd_size_is_refused_rather_than_allocated_for() {
    // The whole reason `entry.size()` never touches an allocation: a package
    // this size declares an 8-exabyte entry through a ZIP64 extra field, and
    // `Vec::with_capacity` on that calls `handle_alloc_error`, which aborts.
    // An abort is not an unwind: no error crosses the FFI, the browser is just
    // gone. So this has to come back as a value.
    let dir = TempDir::new("declared-huge");
    let archive = handmade_zip(&[HandmadeEntry {
        name: "huge.bin",
        stored: b"",
        declared_size: 9_223_372_036_854_775_000,
    }]);
    assert!(archive.len() < 512, "the whole point is that it is tiny");
    let package = crx_of(b"declared-huge-key", &archive);

    let result = install_extension(&package, dir.path(), None);

    assert!(
        matches!(result, Err(ExtError::EntryTooLarge { .. })),
        "{result:?}"
    );
    assert!(
        fs::read_dir(dir.path()).unwrap().next().is_none(),
        "a refused package must not leave a staging directory behind"
    );
}

#[test]
fn entries_that_are_each_small_enough_but_add_up_are_refused() {
    // Splitting the payload across files is the obvious way around a per-file
    // limit, so the running total is what actually holds the line.
    //
    // The chunk is under `max_entry_bytes`, so no entry is individually
    // refusable, and the count is derived from the shipping ceiling rather than
    // written out. It used to be eight fixed chunks, which was comfortably over
    // 256 MiB and quietly under 512 MiB the moment the ceiling moved — a test
    // that stops testing when a constant changes and says nothing about it.
    let dir = TempDir::new("declared-total");
    const CHUNK: u64 = 48 * 1024 * 1024;
    let chunks = (UnpackLimits::DEFAULT.max_total_bytes / CHUNK) + 1;
    let names: Vec<String> = (0..chunks).map(|i| format!("chunk{i}.bin")).collect();
    let entries: Vec<HandmadeEntry> = names
        .iter()
        .map(|name| HandmadeEntry {
            name,
            stored: b"",
            declared_size: CHUNK,
        })
        .collect();
    let package = crx_of(b"declared-total-key", &handmade_zip(&entries));

    let result = install_extension(&package, dir.path(), None);

    assert!(
        matches!(result, Err(ExtError::PackageTooLarge { .. })),
        "{result:?}"
    );
}

#[test]
fn a_real_compression_bomb_is_stopped_by_the_total_limit() {
    // Real deflate over real zeros. The limits are shrunk so the test stays
    // cheap; the mechanism is the one the shipping limits run through.
    let dir = TempDir::new("bomb-real");
    let megabyte = vec![0u8; 1024 * 1024];
    let archive = zip_of(&[
        ("a.bin", &megabyte),
        ("b.bin", &megabyte),
        ("c.bin", &megabyte),
        ("d.bin", &megabyte),
    ]);
    assert!(
        archive.len() < 64 * 1024,
        "4 MiB of zeros must compress small, or this is not a bomb"
    );

    let result = unpack_within(
        &archive,
        dir.path(),
        UnpackLimits {
            max_entries: 100,
            max_entry_bytes: 2 * 1024 * 1024,
            max_total_bytes: 3 * 1024 * 1024,
        },
    );

    assert!(
        matches!(result, Err(ExtError::PackageTooLarge { .. })),
        "{result:?}"
    );
}

#[test]
fn an_entry_that_keeps_sending_bytes_past_its_declared_size_is_cut_off() {
    // The package that lies the other way: headers say the file is empty, then
    // a megabyte arrives. Nothing declared is over any limit, so only counting
    // the bytes that actually turn up catches it.
    let dir = TempDir::new("undeclared-entry");
    let payload = vec![0u8; 1024 * 1024];
    let archive = handmade_zip(&[HandmadeEntry {
        name: "quiet.bin",
        stored: &payload,
        declared_size: 0,
    }]);

    let result = unpack_within(
        &archive,
        dir.path(),
        UnpackLimits {
            max_entries: 100,
            max_entry_bytes: 256 * 1024,
            max_total_bytes: 8 * 1024 * 1024,
        },
    );

    assert!(
        matches!(result, Err(ExtError::EntryTooLarge { .. })),
        "{result:?}"
    );
}

#[test]
fn undeclared_bytes_across_entries_still_hit_the_total_limit() {
    // Both entries fit under the per-file limit even once their real size is
    // known, so the second one can only be refused by the running total.
    let dir = TempDir::new("undeclared-total");
    let payload = vec![0u8; 512 * 1024];
    let archive = handmade_zip(&[
        HandmadeEntry {
            name: "one.bin",
            stored: &payload,
            declared_size: 0,
        },
        HandmadeEntry {
            name: "two.bin",
            stored: &payload,
            declared_size: 0,
        },
    ]);

    let result = unpack_within(
        &archive,
        dir.path(),
        UnpackLimits {
            max_entries: 100,
            max_entry_bytes: 1024 * 1024,
            max_total_bytes: 768 * 1024,
        },
    );

    assert!(
        matches!(result, Err(ExtError::PackageTooLarge { .. })),
        "{result:?}"
    );
}

#[test]
fn a_package_with_an_absurd_number_of_entries_is_refused() {
    // Every entry costs a create and an inode, and a small archive can declare
    // a great many of them.
    let dir = TempDir::new("entry-flood");
    let names: Vec<String> = (0..32_769).map(|i| format!("f{i}")).collect();
    let files: Vec<(&str, &[u8])> = names.iter().map(|n| (n.as_str(), b"" as &[u8])).collect();
    let package = crx_of(b"flood-key", &zip_of(&files));

    let result = install_extension(&package, dir.path(), None);

    assert!(
        matches!(result, Err(ExtError::TooManyEntries { .. })),
        "{result:?}"
    );
}

#[test]
fn an_extension_the_size_of_a_real_one_still_installs() {
    // The limits are worth nothing if they refuse uBlock Origin, which unpacks
    // to a few MB across a couple hundred files.
    let dir = TempDir::new("realistic");
    let blob = vec![b'x'; 512 * 1024];
    let names: Vec<String> = (0..200).map(|i| format!("assets/rule{i}.json")).collect();

    let mut files: Vec<(&str, &[u8])> = vec![
        ("manifest.json", MANIFEST),
        ("background.js", &blob),
        ("assets/font.woff2", &blob),
    ];
    files.extend(names.iter().map(|n| (n.as_str(), b"[]" as &[u8])));

    let installed =
        install_extension(&crx_of(b"realistic-key", &zip_of(&files)), dir.path(), None).unwrap();

    assert_eq!(installed.manifest.name, "Test Extension");
    let root = Path::new(&installed.path);
    assert_eq!(
        fs::metadata(root.join("background.js")).unwrap().len(),
        512 * 1024
    );
    assert!(root.join("assets/rule199.json").exists());
}

/// The limits hold the line in one direction and this holds it in the other.
///
/// Every row was downloaded from the store through this crate's own
/// `install_extension` on 2026-08-10 and the figures are the bytes and entries
/// that actually arrived, not anything a header claimed. Four of these rows are
/// what the previous limits refused: AdBlock and Adblock Plus over 256 MiB,
/// Wappalyzer over 10,000 entries.
///
/// It asserts against the constants rather than unpacking 361 MB in a test,
/// and that is the deliberate trade. A synthetic 300 MB unpack stays green if
/// somebody sets the ceiling to 310 MB, which still refuses AdBlock; this goes
/// red naming the extension that stops installing. The mechanism at scale is
/// held next door by `an_extension_the_size_of_a_real_one_still_installs` and
/// `a_package_with_as_many_entries_as_the_busiest_real_extension_installs`.
#[test]
fn every_extension_measured_on_the_store_fits_inside_the_limits() {
    // name, unpacked bytes, entries, largest single entry
    const MEASURED: &[(&str, u64, usize, u64)] = &[
        ("AdBlock", 361_445_737, 443, 18_782_560),
        ("Adblock Plus", 355_798_527, 355, 18_782_560),
        ("Keeper", 231_578_760, 887, 23_824_254),
        ("Screencastify", 221_579_594, 152, 32_232_419),
        ("Bitwarden", 80_491_018, 263, 10_918_878),
        ("Wappalyzer", 76_953_181, 13_244, 1_764_089),
        ("uBlock Origin Lite", 36_221_511, 1_021, 2_122_468),
        ("Awesome Screenshot", 19_248_655, 837, 1_764_042),
        ("Violentmonkey", 1_943_462, 108, 292_818),
    ];

    let limits = UnpackLimits::DEFAULT;
    for (name, total, entries, largest) in MEASURED {
        assert!(
            *total <= limits.max_total_bytes,
            "{name} unpacks to {total} bytes and the ceiling is {}, so it no longer installs",
            limits.max_total_bytes
        );
        assert!(
            *entries <= limits.max_entries,
            "{name} ships {entries} files and the ceiling is {}, so it no longer installs",
            limits.max_entries
        );
        assert!(
            *largest <= limits.max_entry_bytes,
            "{name}'s biggest file is {largest} bytes and the ceiling is {}, \
             so it no longer installs",
            limits.max_entry_bytes
        );
    }
}

/// The entry count at the scale that actually refused a real extension.
///
/// Cheap, because entries cost an inode and no bytes — which is also why
/// `max_entries` is the only thing standing between the browser and a one
/// megabyte archive declaring a million files, and why it was raised to clear
/// Wappalyzer rather than removed.
#[test]
fn a_package_with_as_many_entries_as_the_busiest_real_extension_installs() {
    let dir = TempDir::new("wappalyzer-shaped");
    // Wappalyzer's measured count, which the previous ceiling of 10,000 refused.
    let names: Vec<String> = (0..13_243)
        .map(|i| format!("technologies/{i}.json"))
        .collect();
    let mut files: Vec<(&str, &[u8])> = vec![("manifest.json", MANIFEST)];
    files.extend(names.iter().map(|n| (n.as_str(), b"{}" as &[u8])));

    let installed =
        install_extension(&crx_of(b"busy-key", &zip_of(&files)), dir.path(), None).unwrap();

    let root = Path::new(&installed.path);
    assert!(root.join("technologies/13242.json").exists());
}

#[test]
fn the_download_url_names_the_extension_being_asked_for() {
    let url = download_url("cjpalhdlnbpafiamejdnhcphjbkeiagm");

    assert!(url.contains("cjpalhdlnbpafiamejdnhcphjbkeiagm"));
    assert!(url.contains(&format!("prodversion={CHROME_VERSION_FOR_DOWNLOADS}")));
    assert!(url.starts_with("https://"));
}

/// The endpoint refuses downward, never upward, so this number may only be
/// wrong in one direction — and being wrong in it costs whole extensions.
///
/// Measured against the live endpoint on 2026-08-10, asking for one id at a
/// time and reading the first response (`302` = a package, `204` = nothing):
///
/// - at `120.0.0.0`, **15 of 18** ids answered `204`, among them uBlock Origin
///   Lite, MetaMask, 1Password, Privacy Badger, DuckDuckGo, both Adblocks,
///   AdGuard, Stylus, Wappalyzer and Refined GitHub;
/// - at `131.0.0.0` — the value the shell used to hold — Violentmonkey still
///   answered `204`. Its floor is between `132.0.0.0` (`204`) and `135.0.0.0`
///   (`302`);
/// - `151.0.7922.109` (Chrome stable that day), `200.0.0.0` and `999.0.0.0`
///   all returned the same package for every id tried, so there is no ceiling
///   to be caught by.
///
/// A floor is all this can assert without a network, and a floor is the whole
/// of the failure: the regression is somebody "correcting" the number back to a
/// real, current Chrome, which is precisely the reasoning that shipped
/// `131.0.0.0` and lost Violentmonkey. Staleness itself is caught in the
/// product instead, by the refusal that names this number (ADR-0078).
#[test]
fn the_chrome_version_asked_with_is_ahead_of_the_stable_it_could_be_mistaken_for() {
    /// Chrome stable on macOS the day the numbers above were taken, read from
    /// `versionhistory.googleapis.com`.
    const STABLE_WHEN_MEASURED: u32 = 151;

    let major: u32 = CHROME_VERSION_FOR_DOWNLOADS
        .split('.')
        .next()
        .and_then(|major| major.parse().ok())
        .expect("the version has to start with a major number the endpoint can compare");

    assert!(
        major > STABLE_WHEN_MEASURED,
        "asking with Chrome {major} is at or behind the stable release of the day \
         ({STABLE_WHEN_MEASURED}), which is a value that goes stale on the next \
         Chrome and takes an extension with it"
    );
}

// --- recognising a store page -----------------------------------------------

const REAL_ID: &str = "cjpalhdlnbpafiamejdnhcphjbkeiagm";

#[test]
fn a_store_detail_page_offers_its_extension() {
    let url = format!("https://chromewebstore.google.com/detail/ublock-origin/{REAL_ID}");

    assert_eq!(extension_id_from_store_url(&url).as_deref(), Some(REAL_ID));
}

#[test]
fn the_old_store_host_still_works() {
    let url = format!("https://chrome.google.com/webstore/detail/ublock-origin/{REAL_ID}");

    assert_eq!(extension_id_from_store_url(&url).as_deref(), Some(REAL_ID));
}

#[test]
fn a_page_without_a_slug_still_works() {
    let url = format!("https://chromewebstore.google.com/detail/{REAL_ID}");

    assert_eq!(extension_id_from_store_url(&url).as_deref(), Some(REAL_ID));
}

#[test]
fn query_strings_and_locales_do_not_get_in_the_way() {
    let url = format!(
        "https://chromewebstore.google.com/detail/ublock-origin/{REAL_ID}?hl=pt-BR&authuser=0"
    );

    assert_eq!(extension_id_from_store_url(&url).as_deref(), Some(REAL_ID));
}

#[test]
fn the_store_home_page_offers_nothing() {
    assert_eq!(
        extension_id_from_store_url("https://chromewebstore.google.com/"),
        None
    );
    assert_eq!(
        extension_id_from_store_url("https://chromewebstore.google.com/category/extensions"),
        None
    );
}

#[test]
fn another_site_cannot_pass_itself_off_as_the_store() {
    // Offering to install from a lookalike host would be a straight path to
    // installing whatever an attacker wants.
    let url = format!("https://chromewebstore.google.com.evil.io/detail/x/{REAL_ID}");

    assert_eq!(extension_id_from_store_url(&url), None);
}

#[test]
fn the_store_over_plain_http_offers_nothing() {
    // Over http the host is whatever the network says it is, so the host check
    // proves nothing and the id it hands back is an attacker's choice.
    let url = format!("http://chromewebstore.google.com/detail/ublock-origin/{REAL_ID}");

    assert_eq!(extension_id_from_store_url(&url), None);
}

#[test]
fn a_javascript_url_wearing_the_store_host_offers_nothing() {
    // `javascript://host/...` is not a page on that host, it is a script whose
    // "host" is a comment. Nothing about it came from the store.
    let url = format!("javascript://chromewebstore.google.com/detail/{REAL_ID}");

    assert_eq!(extension_id_from_store_url(&url), None);
}

#[test]
fn a_second_id_planted_deeper_in_the_path_does_not_win() {
    // The id decides what gets downloaded and installed, so a crafted link
    // must not be able to append one and have it picked over the real one.
    let planted = "ponmlkjihgfedcbaponmlkjihgfedcba";
    let url =
        format!("https://chromewebstore.google.com/detail/ublock-origin/{REAL_ID}/x/{planted}");

    assert_eq!(extension_id_from_store_url(&url).as_deref(), Some(REAL_ID));
}

#[test]
fn an_id_outside_a_detail_page_is_not_offered() {
    let url = format!("https://chromewebstore.google.com/category/extensions/{REAL_ID}");

    assert_eq!(extension_id_from_store_url(&url), None);
}

// --- the one host rule ------------------------------------------------------

#[test]
fn the_published_hosts_are_the_ones_the_parser_accepts() {
    // The shell hands `store_hosts` to a script it injects into pages. If the
    // published list ever admits a host the parser refuses, or refuses one it
    // admits, the script and the installer disagree about what the store is —
    // and the script is the half that runs inside somebody else's page.
    let hosts = store_hosts();

    for host in ["chromewebstore.google.com", "chrome.google.com"] {
        assert!(hosts.matches(host), "published list refuses {host}");
        let url = format!("https://{host}/detail/name/{REAL_ID}");
        assert_eq!(
            extension_id_from_store_url(&url).as_deref(),
            Some(REAL_ID),
            "parser refuses {host}"
        );
    }
}

#[test]
fn the_published_hosts_refuse_every_other_origin() {
    for host in [
        "example.com",
        "chromewebstore.google.com.evil.io",
        "evil-chromewebstore.google.com",
        "chromewebstore.google.com.",
        "notchrome.google.com",
        "google.com",
        "chromewebstore.google.com.attacker.example",
    ] {
        assert!(
            !store_hosts().matches(host),
            "published list accepts {host}"
        );
        let url = format!("https://{host}/detail/name/{REAL_ID}");
        assert_eq!(
            extension_id_from_store_url(&url),
            None,
            "parser accepts {host}"
        );
    }
}

#[test]
fn a_suffix_only_matches_a_real_subdomain() {
    // The leading dot is the whole defence. Without it any host merely ending
    // in the store's name — which anyone can register — is the store.
    let hosts = store_hosts();

    assert!(hosts.matches("static.chromewebstore.google.com"));
    assert!(!hosts.matches("evilchromewebstore.google.com"));
    assert!(
        hosts.suffixes.iter().all(|tail| tail.starts_with('.')),
        "a suffix without a leading dot matches hosts nobody authorised"
    );
}

#[test]
fn the_host_rule_ignores_case() {
    // WebKit hands back what the page's URL says, and a URL's host is
    // case-insensitive. A rule that is not would let `CHROMEWEBSTORE...`
    // through one reader and not the other.
    assert!(store_hosts().matches("ChromeWebStore.Google.COM"));
    let url = format!("https://ChromeWebStore.Google.COM/detail/name/{REAL_ID}");
    assert_eq!(extension_id_from_store_url(&url).as_deref(), Some(REAL_ID));
}

#[test]
fn something_that_is_not_an_id_is_not_treated_as_one() {
    for tail in [
        "short",
        "CJPALHDLNBPAFIAMEJDNHCPHJBKEIAGM",
        "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz",
    ] {
        let url = format!("https://chromewebstore.google.com/detail/name/{tail}");
        assert_eq!(extension_id_from_store_url(&url), None, "accepted {tail}");
    }
}
