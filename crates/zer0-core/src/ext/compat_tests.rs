use std::io::Write;

use zip::write::SimpleFileOptions;

use super::*;
use crate::ext::{InstalledExtension, install_extension, installed_extensions};

/// A temp directory that cleans itself up.
struct TempDir(std::path::PathBuf);

impl TempDir {
    fn new(label: &str) -> Self {
        let path = crate::test_support::scratch_path(&format!("compat-{label}"));
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

// MARK: - Packages

fn zip_of(files: &[(&str, &[u8])]) -> Vec<u8> {
    let mut buffer = Vec::new();
    {
        let mut writer = zip::ZipWriter::new(std::io::Cursor::new(&mut buffer));
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

/// A valid CRX3 envelope — genuinely signed, since the parser verifies
/// signatures — so these tests go through the real front door rather
/// than calling [`inject`] on a directory somebody laid out by hand.
fn crx_of(key: &[u8], archive: &[u8]) -> Vec<u8> {
    crate::ext::crx::test_support::crx_signed_by(
        &[&crate::ext::crx::test_support::TestSigner::from_seed(key)],
        None,
        archive,
    )
}

/// Install a package whose only interesting part is its manifest.
fn install(dir: &TempDir, manifest: &str, extra: &[(&str, &[u8])]) -> InstalledExtension {
    let mut files: Vec<(&str, &[u8])> = vec![("manifest.json", manifest.as_bytes())];
    files.extend_from_slice(extra);
    install_extension(&crx_of(b"compat-key", &zip_of(&files)), dir.path(), None).unwrap()
}

const WORKER_MANIFEST: &str = r#"{
    "manifest_version": 3,
    "name": "Worker Extension",
    "version": "1.0",
    "permissions": ["storage"],
    "background": {"service_worker": "js/background.js"},
    "icons": {"128": "icon.png"}
}"#;

fn manifest_json(installed: &InstalledExtension) -> serde_json::Value {
    let text = fs::read_to_string(Path::new(&installed.path).join("manifest.json")).unwrap();
    serde_json::from_str(&text).unwrap()
}

// MARK: - The modification, and the record of it

/// The whole decision in one test: the package is modified, the extension's own
/// code is still what runs, and the file that was modified is where it says so.
///
/// Break any of the three — drop the `inject` call from `install_extension`,
/// rename the file, stop writing the key — and this goes red naming which.
#[test]
fn a_modified_package_starts_at_zer0s_file_and_records_where_its_own_code_begins() {
    let dir = TempDir::new("record");
    let installed = install(
        &dir,
        WORKER_MANIFEST,
        &[("js/background.js", b"self.x = 1")],
    );
    let root = Path::new(&installed.path);

    // The added file is there, under a name nothing else would choose.
    assert!(root.join("zer0-compat.js").exists());

    // WebKit is handed a manifest that starts at it.
    assert_eq!(
        manifest_json(&installed)["background"]["service_worker"],
        serde_json::json!("zer0-compat.js")
    );

    // And the record travels in the file it describes, naming both halves.
    let notice = installed.manifest.compat.expect("a notice was written");
    assert_eq!(notice.added_files, ["zer0-compat.js"]);
    assert_eq!(
        notice.original_entry_point, "js/background.js",
        "a person has to be able to see where the extension's own code starts"
    );

    // The extension's own file is untouched and is still reached.
    let compat = fs::read_to_string(root.join("zer0-compat.js")).unwrap();
    assert!(compat.starts_with(SOURCE));
    assert!(compat.contains(r#"importScripts("js/background.js")"#));
    assert_eq!(
        fs::read_to_string(root.join("js/background.js")).unwrap(),
        "self.x = 1"
    );
}

/// Read back from disk on a later launch, not only from the install that wrote
/// it. Every screen goes through `installed_extensions`, and a notice that only
/// existed on the return value of `install_extension` would be a line that
/// showed up once and then vanished at the next start.
#[test]
fn the_record_survives_a_restart() {
    let dir = TempDir::new("restart");
    install(&dir, WORKER_MANIFEST, &[("js/background.js", b"1")]);

    let found = installed_extensions(dir.path(), None);
    assert_eq!(found.len(), 1);
    let notice = found[0].manifest.compat.clone().expect("still recorded");
    assert_eq!(notice.original_entry_point, "js/background.js");
}

/// The measurement that cost this change a rewrite, and the reason the module
/// path looks the way it does.
///
/// **A module service worker in WebKit cannot use `import()`.** Measured on
/// macOS 26.6: it throws *"Dynamic-import is not available in Worklets or
/// ServiceWorkers"*. The version that used one came up clean and never ran the
/// extension's code at all, and nothing about the worker looked wrong — which
/// is precisely the silent failure this file is forbidden to create. So a
/// module worker gets an entry of two static imports, ours first, and the shim
/// itself moves into a second file because a module's own body runs *after* the
/// modules it imports.
///
/// Swap the two spellings and every module-worker extension in the store loads
/// a worker that does nothing, with no error anywhere.
#[test]
fn a_module_worker_is_re_entered_by_static_import_and_a_classic_one_by_import_scripts() {
    let module = TempDir::new("module");
    let installed = install(
        &module,
        r#"{
            "manifest_version": 3,
            "name": "Module Worker",
            "version": "1.0",
            "background": {"service_worker": "sw.js", "type": "module"}
        }"#,
        &[("sw.js", b"export {}")],
    );
    let root = Path::new(&installed.path);
    let entry = fs::read_to_string(root.join("zer0-compat.js")).unwrap();

    assert!(
        !entry.contains("import("),
        "a dynamic import is unavailable in a WebKit service worker: {entry:?}"
    );
    assert!(!entry.contains("importScripts"));
    // Ours first, theirs second. The order is the whole mechanism.
    let ours = entry.find(r#"import "./zer0-compat-api.js";"#).unwrap();
    let theirs = entry.find(r#"import "./sw.js";"#).unwrap();
    assert!(ours < theirs, "the extension's module would run first");

    // The shim is in the second file, because a module's own body runs after
    // everything it imports.
    assert_eq!(
        fs::read_to_string(root.join("zer0-compat-api.js")).unwrap(),
        SOURCE
    );
    assert_eq!(
        installed.manifest.compat.clone().unwrap().added_files,
        ["zer0-compat.js", "zer0-compat-api.js"]
    );

    // And `type` survives, or WebKit runs the entry as a classic worker and its
    // `import` statements are a syntax error.
    assert_eq!(
        manifest_json(&installed)["background"]["type"],
        serde_json::json!("module")
    );

    // A classic worker gets the other half: `import` is a syntax error there.
    let classic = TempDir::new("classic");
    let installed = install(&classic, WORKER_MANIFEST, &[("js/background.js", b"1")]);
    let root = Path::new(&installed.path);
    let entry = fs::read_to_string(root.join("zer0-compat.js")).unwrap();
    assert!(entry.starts_with(SOURCE));
    assert!(entry.contains(r#"importScripts("js/background.js")"#));
    assert!(!root.join("zer0-compat-api.js").exists());
}

/// MV2 has a list, so ours goes in front of it rather than replacing it.
/// Replacing it would drop every script after the first.
#[test]
fn an_mv2_background_runs_ours_first_and_keeps_every_script_it_had() {
    let dir = TempDir::new("mv2");
    let installed = install(
        &dir,
        r#"{
            "manifest_version": 2,
            "name": "Old Extension",
            "version": "1.0",
            "background": {"scripts": ["a.js", "b.js"], "persistent": false}
        }"#,
        &[("a.js", b"1"), ("b.js", b"2")],
    );

    assert_eq!(
        manifest_json(&installed)["background"]["scripts"],
        serde_json::json!(["zer0-compat.js", "a.js", "b.js"])
    );
    assert_eq!(
        installed.manifest.compat.unwrap().original_entry_point,
        "a.js"
    );

    // Nothing is appended for MV2: the list is what runs the extension's code.
    let source = fs::read_to_string(Path::new(&installed.path).join("zer0-compat.js")).unwrap();
    assert_eq!(source, SOURCE);
}

// MARK: - Refusing rather than repairing

/// Three shapes this cannot get in front of, and one that is not ours to touch.
/// Each must come out byte-identical to what the store served, with no file
/// added and nothing claimed.
#[test]
fn a_package_this_cannot_get_in_front_of_is_left_exactly_as_it_arrived() {
    /// A label, the manifest, and whatever else the package ships.
    type Case = (
        &'static str,
        &'static str,
        &'static [(&'static str, &'static [u8])],
    );

    let cases: [Case; 4] = [
        (
            "page",
            r#"{"manifest_version": 2, "name": "Page", "version": "1",
                "background": {"page": "background.html"}}"#,
            &[("background.html", b"<html></html>")],
        ),
        (
            "none",
            r#"{"manifest_version": 3, "name": "Content Only", "version": "1",
                "content_scripts": [{"matches": ["<all_urls>"], "js": ["c.js"]}]}"#,
            &[("c.js", b"1")],
        ),
        (
            "empty-scripts",
            r#"{"manifest_version": 2, "name": "Empty", "version": "1",
                "background": {"scripts": []}}"#,
            &[],
        ),
        (
            // A package that already ships a file by this name is one nobody
            // here understands, and overwriting somebody's own file to install
            // a compatibility layer becomes a bug report about them.
            "already-taken",
            r#"{"manifest_version": 3, "name": "Taken", "version": "1",
                "background": {"service_worker": "sw.js"}}"#,
            &[("sw.js", b"1"), ("zer0-compat.js", b"// theirs")],
        ),
    ];

    for (label, manifest, extra) in cases {
        let dir = TempDir::new(label);
        let installed = install(&dir, manifest, extra);
        let root = Path::new(&installed.path);

        assert_eq!(
            fs::read_to_string(root.join("manifest.json")).unwrap(),
            manifest,
            "{label}: the manifest was rewritten"
        );
        assert!(
            installed.manifest.compat.is_none(),
            "{label}: a modification was claimed"
        );
        if label != "already-taken" {
            assert!(
                !root.join("zer0-compat.js").exists(),
                "{label}: a file was added"
            );
        } else {
            assert_eq!(
                fs::read_to_string(root.join("zer0-compat.js")).unwrap(),
                "// theirs",
                "{label}: the package's own file was overwritten"
            );
        }
    }
}

/// The entry point comes out of a hostile manifest and goes into a JavaScript
/// module specifier. Anything that is not a plain path inside the package is
/// refused, and refusing means installed untouched — not installed with a
/// specifier nobody vetted.
#[test]
fn an_entry_point_that_is_not_a_path_inside_the_package_is_refused() {
    for (label, entry) in [
        ("parent", "../../evil.js"),
        ("absolute", "/etc/passwd.js"),
        ("scheme", "https://example.com/evil.js"),
        ("empty", ""),
    ] {
        let dir = TempDir::new(label);
        let manifest = format!(
            r#"{{"manifest_version": 3, "name": "Escape", "version": "1",
                "background": {{"service_worker": "{entry}"}}}}"#
        );
        let installed = install(&dir, &manifest, &[]);

        assert!(
            installed.manifest.compat.is_none(),
            "{label}: {entry} was accepted"
        );
        assert!(
            !Path::new(&installed.path).join("zer0-compat.js").exists(),
            "{label}: a file was written for {entry}"
        );
    }
}

/// A quote in the entry point must become a string, not a line of somebody
/// else's JavaScript running ahead of every extension this browser installs.
///
/// The payload carries a newline as well as a quote, and that is the whole
/// assertion: whatever the path contains, the re-entry is **one line**. A path
/// that broke out of its literal would put the second half on a line of its
/// own, and `//` at the end of a one-line attack would not save it.
#[test]
fn an_entry_point_that_carries_javascript_becomes_a_string_rather_than_a_statement() {
    let dir = TempDir::new("quote");
    let installed = install(
        &dir,
        r#"{"manifest_version": 3, "name": "Quote", "version": "1",
            "background": {"service_worker": "a\");\nglobalThis.pwned = 1;\n//.js"}}"#,
        &[],
    );

    let source = fs::read_to_string(Path::new(&installed.path).join("zer0-compat.js")).unwrap();
    let (_, re_entry) = source
        .split_once("// Over to the extension's own background code.\n")
        .expect("the re-entry is marked");
    assert_eq!(
        re_entry.lines().count(),
        1,
        "the path escaped its literal: {re_entry:?}"
    );
    assert!(
        re_entry.starts_with("importScripts(\"a\\\");\\nglobalThis.pwned = 1;\\n//.js\");"),
        "{re_entry:?}"
    );
}

/// Anybody can write `zer0_compat` into their own manifest. A browser that
/// printed it back would be telling somebody zer0 added a file it never wrote —
/// a claim about our own conduct, sourced from the package being described.
#[test]
fn a_package_claiming_a_modification_that_did_not_happen_is_not_believed() {
    let dir = TempDir::new("liar");
    let installed = install(
        &dir,
        r#"{"manifest_version": 3, "name": "Liar", "version": "1",
            "content_scripts": [{"matches": ["<all_urls>"], "js": ["c.js"]}],
            "zer0_compat": {"added_files": ["zer0-compat.js"],
                            "original_entry_point": "something-innocent.js"}}"#,
        &[("c.js", b"1")],
    );

    assert!(
        installed.manifest.compat.is_none(),
        "a claim was believed with no background behind it"
    );
}

// MARK: - What is in the file

/// The promise about the rewrite is that it is bounded: every key the package
/// wrote is still there, in the order it wrote them, with `background` pointed
/// at our file and one key appended. Somebody who reformats the manifest, sorts
/// it, or drops a key this browser does not read breaks the one thing that
/// makes the modification auditable without a second copy of the package.
#[test]
fn the_rewrite_moves_one_key_and_appends_one() {
    let dir = TempDir::new("bounded");
    let installed = install(&dir, WORKER_MANIFEST, &[("js/background.js", b"1")]);

    let before: serde_json::Value = serde_json::from_str(WORKER_MANIFEST).unwrap();
    let after = manifest_json(&installed);

    let keys = |v: &serde_json::Value| {
        v.as_object()
            .unwrap()
            .keys()
            .cloned()
            .collect::<Vec<String>>()
    };
    let mut expected = keys(&before);
    expected.push("zer0_compat".to_string());
    assert_eq!(
        keys(&after),
        expected,
        "keys moved, were sorted, or were lost"
    );

    for key in keys(&before) {
        if key == "background" {
            continue;
        }
        assert_eq!(before[&key], after[&key], "{key} was changed");
    }
    // Everything `background` said other than where it starts.
    assert_eq!(
        after["background"]["service_worker"],
        serde_json::json!("zer0-compat.js")
    );
}

/// The line this file draws, and the one worth breaking on purpose: a value is
/// allowed in only where Chrome documents it as a literal. A capacity — how
/// many rules this engine will take, how many calls per ten minutes — is a
/// claim about WebKit, and Chrome's number is not evidence about it (ADR-0018).
#[test]
fn the_compatibility_file_states_no_capacity_it_cannot_back() {
    // The prose above the code names these in order to rule them out, so the
    // scan is over what runs rather than over what explains it.
    let code: String = SOURCE
        .lines()
        .filter(|line| !line.trim_start().starts_with("//"))
        .collect::<Vec<&str>>()
        .join("\n");

    for forbidden in [
        "MAX_NUMBER_OF",
        "MAX_HANDLER_BEHAVIOR",
        "QUOTA_BYTES",
        "MAX_WRITE_OPERATIONS",
        "MAX_ITEMS",
    ] {
        assert!(
            !code.contains(forbidden),
            "{forbidden} is a number about this engine that nobody measured"
        );
    }
}

/// A member is only installed where nothing is there, so the day WebKit ships
/// one of these the real one wins and this file goes quiet without anybody
/// re-measuring. An unguarded assignment would shadow a working API with a
/// permanently-empty stand-in — a silent failure, which is the one outcome
/// worse than the loud one this replaces.
#[test]
fn every_write_in_the_compatibility_file_is_guarded() {
    assert!(SOURCE.contains("if (namespace[member] !== undefined) return;"));
}
