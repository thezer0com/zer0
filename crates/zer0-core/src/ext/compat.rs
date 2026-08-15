//! The one modification zer0 makes to somebody else's package.
//!
//! ADR-0020 says there is no shim layer and no `chrome.*` polyfill of our own,
//! and that was the right call for a *namespace*: what WebKit implements is
//! Apple's to widen and reimplementing it is a treadmill. It is the wrong call
//! for a **member missing from a namespace that exists**, which is a different
//! failure with a different cost — measured across 59 store packages, six
//! background workers die on one absent member each, and React Developer Tools
//! dies on `chrome.scripting.ExecutionWorld.ISOLATED`, which is two strings.
//!
//! ## Why this has to happen on disk
//!
//! Measured, on macOS 26.6, for reaching an extension's background worker:
//!
//! | Route | Reaches the worker |
//! | --- | --- |
//! | `WKWebExtensionController.Configuration.webViewConfiguration.userContentController` + `WKUserScript` | no |
//! | `WKWebExtensionContext.unsupportedAPIs` | no — it only removes |
//! | rewriting `background` in `manifest.json` at unpack | yes |
//!
//! There is no third option. So the unpacked tree stops being a copy of the
//! archive, and ADR-0022 and ADR-0024 both care about that. What answers them
//! is that the modification is **bounded, named and recorded in the file it
//! modifies**: one file is added — two for a module worker, see
//! [`COMPAT_API_FILE`] — under names no extension would choose, and
//! `manifest.json` carries a `zer0_compat` block saying so and naming where the
//! extension's own code still begins. A person can read both without a hex
//! editor, and the Extensions screen prints them.
//!
//! ## What is not kept
//!
//! Not the verified CRX. Holding a second copy of every package — 361 MB for
//! AdBlock alone — buys a comparison nothing performs and nobody is offered.
//! The auditable thing is what the modification *is*, and that is two files
//! with fixed names plus two keys in a manifest that names the entry point it
//! replaced. That is readable; a blob nobody diffs is not.

use std::fs;
use std::path::Path;

use super::ExtError;

/// The file zer0 adds and points `background` at. Named so it cannot be
/// mistaken for the extension's own.
pub const COMPAT_FILE: &str = "zer0-compat.js";

/// The second file, added only for a **module** service worker.
///
/// One file would do if a module could run something before its own imports.
/// It cannot: static `import` is hoisted and evaluated before the importing
/// module's body, so a shim written after one runs second — too late for a
/// worker that has already died. And the obvious escape, `await import()`, is
/// not available at all: measured on macOS 26.6, a module service worker
/// reaches it and throws *"Dynamic-import is not available in Worklets or
/// ServiceWorkers"*. That version of this file shipped and looked like it
/// worked, because the worker came up clean and the extension's own code never
/// ran — the silent failure this whole change is forbidden to create.
///
/// So a module worker gets an entry that is nothing but two static imports, in
/// order: this file, then the extension's. Which is also strictly better than
/// the top-level `await` it replaced, since nothing is deferred past the
/// startup turn MV3 requires listeners to be registered in.
pub const COMPAT_API_FILE: &str = "zer0-compat-api.js";

/// The manifest key recording that this package was modified and by what.
pub const MANIFEST_KEY: &str = "zer0_compat";

/// What gets written into every package that has a background this can reach.
///
/// `include_str!` rather than a string here: the file is JavaScript, it is read
/// and argued about as JavaScript, and the Swift suite evaluates these exact
/// bytes in a real interpreter to hold it to what it claims.
pub const SOURCE: &str = include_str!("compat.js");

/// That a package was modified, and what by.
///
/// One record carrying both halves, so a screen cannot draw the fact that the
/// package was changed without also being handed the names of the files that
/// changed it and the entry point they run in front of.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct CompatNotice {
    /// Every file zer0 added, relative to the package root. One for a classic
    /// worker or an MV2 background, two for a module worker — see
    /// [`COMPAT_API_FILE`] for why the second one has to exist.
    pub added_files: Vec<String>,
    /// Where the extension's own background code begins, and still begins.
    pub original_entry_point: String,
}

/// The background shape a package declares, as far as this cares.
enum Background {
    /// MV3. `module` decides how the original is re-entered, and the two ways
    /// are not interchangeable in either direction.
    Worker { path: String, module: bool },
    /// MV2. Ours goes in front of the list rather than replacing it.
    Scripts { first: String },
}

/// Add the compatibility file to an unpacked package.
///
/// Runs inside the staging directory, before the swap, so a failure here leaves
/// nothing behind and leaves any working version exactly where it was
/// (ADR-0022).
///
/// **Refuses rather than repairs.** A background this cannot reach — an HTML
/// background page, no background at all, an entry point that is not a plain
/// path inside the package — is left exactly as it arrived, with no file added
/// and no key written. There is no half-modified state to explain.
pub fn inject(dir: &Path) -> Result<(), ExtError> {
    let manifest_path = dir.join("manifest.json");
    if !manifest_path.exists() {
        // `read_manifest` is the one that refuses a package with no manifest,
        // and it says so in the error a person reads. Nothing to do here.
        return Ok(());
    }

    // A package that already ships a file by either of these names is one we do
    // not understand, and overwriting somebody's file to install a
    // compatibility layer is the kind of repair that becomes a bug report about
    // them.
    if dir.join(COMPAT_FILE).exists() || dir.join(COMPAT_API_FILE).exists() {
        return Ok(());
    }

    let json = super::read_package_json(&manifest_path)?;
    let Ok(serde_json::Value::Object(mut manifest)) = serde_json::from_str(&json) else {
        // Unparseable, or not an object. `manifest::parse` is where that
        // becomes an error worth reading.
        return Ok(());
    };

    let Some(background) = read_background(manifest.get("background")) else {
        return Ok(());
    };

    let entry = match &background {
        Background::Worker { path, .. } => path.clone(),
        Background::Scripts { first } => first.clone(),
    };

    let mut added = vec![COMPAT_FILE.to_string()];
    match &background {
        Background::Worker {
            path, module: true, ..
        } => {
            // Two static imports, in the order they are written. The extension's
            // own module is the second, so everything below has already run by
            // the time its first line does.
            fs::write(
                dir.join(COMPAT_FILE),
                format!(
                    "// Added by zer0. {COMPAT_API_FILE} is the compatibility file; the\n\
                     // second import is where this extension's own code begins.\n\
                     import {};\nimport {};\n",
                    module_specifier(COMPAT_API_FILE),
                    module_specifier(path)
                ),
            )?;
            fs::write(dir.join(COMPAT_API_FILE), SOURCE)?;
            added.push(COMPAT_API_FILE.to_string());
        }
        Background::Worker {
            path,
            module: false,
            ..
        } => {
            fs::write(
                dir.join(COMPAT_FILE),
                format!(
                    "{SOURCE}\n// Over to the extension's own background code.\n\
                     importScripts({});\n",
                    json_string(path)
                ),
            )?;
        }
        Background::Scripts { .. } => {
            fs::write(dir.join(COMPAT_FILE), SOURCE)?;
        }
    }

    rewrite_background(&mut manifest, &background);
    manifest.insert(
        MANIFEST_KEY.to_string(),
        serde_json::json!({
            "added_files": added,
            "original_entry_point": entry,
        }),
    );

    // Written beside and renamed over, because a manifest cut off halfway by a
    // full disk is an extension nothing can read, and `fs::write` truncates
    // before it writes. The rename is within one directory, so it is atomic.
    let pending = dir.join(".manifest.json.incoming");
    let rewritten = serde_json::to_string_pretty(&manifest)
        .map_err(|e| ExtError::BadManifest(e.to_string()))?;
    fs::write(&pending, rewritten)?;
    fs::rename(&pending, &manifest_path)?;
    Ok(())
}

/// What the extension's `background` key declares, or `None` for a shape this
/// cannot get in front of.
fn read_background(value: Option<&serde_json::Value>) -> Option<Background> {
    let background = value?.as_object()?;

    if let Some(path) = background.get("service_worker").and_then(|v| v.as_str()) {
        if !is_package_relative(path) {
            return None;
        }
        return Some(Background::Worker {
            path: path.to_string(),
            module: background.get("type").and_then(|v| v.as_str()) == Some("module"),
        });
    }

    // MV2, and MV3's `scripts` fallback for browsers without workers. Only the
    // first entry is named in the notice — it is where the extension's code
    // begins, which is the fact a person needs — and the whole list keeps
    // running, in order, after ours.
    let scripts = background.get("scripts")?.as_array()?;
    let first = scripts.first()?.as_str()?;
    if !is_package_relative(first) {
        return None;
    }
    Some(Background::Scripts {
        first: first.to_string(),
    })
}

/// Whether a path names a file inside this package and nothing else.
///
/// The manifest is hostile input (ADR-0024) and this string is about to become
/// a JavaScript module specifier. Absolute paths, parent traversal and anything
/// carrying a scheme are refused, and refusing means the package is installed
/// untouched rather than installed with a specifier nobody vetted.
fn is_package_relative(path: &str) -> bool {
    !path.is_empty()
        && !path.starts_with('/')
        && !path.starts_with('\\')
        && !path.contains(':')
        && !path.contains('\\')
        && !path.split('/').any(|segment| segment == "..")
}

/// Point `background` at our file, keeping everything else the manifest said.
fn rewrite_background(manifest: &mut serde_json::Map<String, serde_json::Value>, of: &Background) {
    let Some(serde_json::Value::Object(background)) = manifest.get_mut("background") else {
        return;
    };
    match of {
        Background::Worker { .. } => {
            background.insert(
                "service_worker".to_string(),
                serde_json::Value::String(COMPAT_FILE.to_string()),
            );
        }
        Background::Scripts { .. } => {
            let Some(serde_json::Value::Array(scripts)) = background.get_mut("scripts") else {
                return;
            };
            scripts.insert(0, serde_json::Value::String(COMPAT_FILE.to_string()));
        }
    }
}

/// A path from the manifest as a JavaScript string literal.
///
/// Through `serde_json` rather than by wrapping it in quotes, so a manifest
/// that puts a quote or a newline in its own entry point produces a string
/// rather than a syntax error or a line of somebody else's JavaScript running
/// ahead of every extension this browser installs.
fn json_string(path: &str) -> String {
    serde_json::Value::String(path.to_string()).to_string()
}

/// The same, as a module specifier: relative, so it resolves against the
/// package root rather than against an import map nobody wrote.
fn module_specifier(path: &str) -> String {
    let literal = json_string(path);
    format!("\"./{}", &literal[1..])
}

#[cfg(test)]
#[path = "compat_tests.rs"]
mod tests;
