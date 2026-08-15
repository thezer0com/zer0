//! Reading the name a package actually calls itself.
//!
//! A Chrome manifest may write `"name": "__MSG_extName__"` and keep the real
//! string in `_locales/<locale>/messages.json`. Most of the store does. Showing
//! the placeholder is not a cosmetic fault: the row in Settings and the consent
//! sheet both name the extension, and **a permission prompt that cannot say
//! what is asking is a prompt nobody can answer** (ADR-0028).
//!
//! ## This is hostile input like everything else in a package
//!
//! `_locales` arrives in the same CRX as the rest (ADR-0022), so:
//!
//! - **a locale is never used as a path until it is checked.** `default_locale`
//!   is a string the package wrote, and `../../..` is a string;
//! - **a message file has a size of its own.** `UnpackLimits` bounds an entry at
//!   64 MiB, which is fine for a resource nobody parses and wrong for JSON we
//!   hold in memory and index;
//! - **substitution is one pass, so recursion is not possible rather than
//!   guarded against.** What a message expands to is written to the output and
//!   never looked at again, so `extName` = `__MSG_extName__` expands once and
//!   stops.
//!
//! Anything unreadable — a missing directory, JSON that is not JSON, an entry
//! that is not an object — is treated as a locale that is not there. Falling
//! back is right here because a *worse* locale is still an answer to the same
//! question; refusing outright is right one level up, where a name that resolves
//! to nothing at all is refused by [`localise`].

use std::collections::HashMap;
use std::fs;
use std::path::Path;

use super::{ExtError, ExtensionManifest};

/// Message name (lowercased) to the text it stands for.
///
/// Lowercased because Chrome matches message names case-insensitively, and an
/// extension that writes `__MSG_extname__` against a message called `extName`
/// works there.
type Messages = HashMap<String, String>;

const PREFIX: &str = "__MSG_";
const SUFFIX: &str = "__";

/// The most a `messages.json` may be before it is treated as unreadable.
///
/// The heaviest real bundle is tens of kilobytes; a megabyte is two orders of
/// magnitude of room. The number exists because the alternative is parsing
/// whatever a package felt like shipping.
const MAX_MESSAGES_BYTES: u64 = 1024 * 1024;

/// A locale is a directory name, so it is checked before it is one.
///
/// ASCII letters, digits and `_` only. That accepts every locale Chrome
/// publishes (`en`, `en_GB`, `pt_BR`, `zh_CN`) and refuses every way of
/// spelling a path.
fn safe_locale(raw: &str) -> Option<String> {
    let value = raw.trim().replace('-', "_");
    if value.is_empty() || value.len() > 32 {
        return None;
    }
    value
        .bytes()
        .all(|b| b.is_ascii_alphanumeric() || b == b'_')
        .then_some(value)
}

/// `pt-br` and `pt_BR` name the same directory in Chrome's spelling.
fn canonical(locale: &str) -> String {
    match locale.split_once('_') {
        Some((language, region)) => {
            format!("{}_{}", language.to_lowercase(), region.to_uppercase())
        }
        None => locale.to_lowercase(),
    }
}

fn push_unique(out: &mut Vec<String>, value: String) {
    if !out.contains(&value) {
        out.push(value);
    }
}

/// Where to look, best first.
///
/// The requested locale, then the language without its region, then the
/// package's own `default_locale` and its language. Dropping the region is the
/// fallback that matters in practice: a package that ships `pt` and is asked
/// for `pt_BR` has the right words and the wrong directory name.
fn candidates(requested: Option<&str>, default_locale: Option<&str>) -> Vec<String> {
    let mut out = Vec::new();
    for raw in [requested, default_locale].into_iter().flatten() {
        let Some(locale) = safe_locale(raw) else {
            continue;
        };
        push_unique(&mut out, canonical(&locale));
        push_unique(&mut out, locale.clone());
        if let Some((language, _)) = locale.split_once('_') {
            push_unique(&mut out, language.to_lowercase());
        }
    }
    out
}

/// One locale's messages, or `None` if there are none to be had.
fn read_messages(dir: &Path, locale: &str) -> Option<Messages> {
    let path = dir.join("_locales").join(locale).join("messages.json");
    let metadata = fs::metadata(&path).ok()?;
    if !metadata.is_file() || metadata.len() > MAX_MESSAGES_BYTES {
        return None;
    }

    // Through the package-JSON door rather than `read_to_string` directly, so
    // a byte-order mark is handled here for the same reason and in the same
    // place it is handled for `manifest.json` (see `read_package_json`).
    let parsed: serde_json::Value =
        serde_json::from_str(&super::read_package_json(&path).ok()?).ok()?;
    let mut messages = Messages::new();
    for (name, entry) in parsed.as_object()? {
        // Chrome's shape is `{"extName": {"message": "…"}}`. Anything else in
        // there is somebody else's business, and skipping it beats refusing the
        // whole file over one malformed entry.
        if let Some(text) = entry.get("message").and_then(serde_json::Value::as_str) {
            messages.insert(name.to_lowercase(), text.to_string());
        }
    }
    Some(messages)
}

/// Every candidate locale merged, best last so it wins.
///
/// Merged rather than "first locale that has anything", because a translation
/// that covers the name and not the description is normal, and the fallback for
/// the string it does not cover is the package's own language — not the
/// placeholder.
fn table(dir: &Path, requested: Option<&str>, default_locale: Option<&str>) -> Messages {
    let mut table = Messages::new();
    for locale in candidates(requested, default_locale).into_iter().rev() {
        if let Some(messages) = read_messages(dir, &locale) {
            table.extend(messages);
        }
    }
    table
}

/// Whether a string has anything to resolve.
fn is_localised(text: &str) -> bool {
    text.contains(PREFIX)
}

/// Replace every `__MSG_name__`, or `None` if any of them names a message the
/// package does not define.
///
/// `None` rather than "leave that one alone": a half-resolved string is how
/// `__MSG_extName__` reached a screen in the first place.
fn substitute(text: &str, messages: &Messages) -> Option<String> {
    if !is_localised(text) {
        return Some(text.to_string());
    }

    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(start) = rest.find(PREFIX) {
        out.push_str(&rest[..start]);
        let after = &rest[start + PREFIX.len()..];
        // An opening with no closing is not a placeholder, and guessing where
        // it was meant to end is guessing.
        let end = after.find(SUFFIX)?;
        let name = &after[..end];
        if name.is_empty() {
            return None;
        }
        // Written to the output and never re-scanned. This is why a message
        // that expands to another placeholder terminates.
        out.push_str(messages.get(&name.to_lowercase())?);
        rest = &after[end + SUFFIX.len()..];
    }
    out.push_str(rest);
    Some(out)
}

/// Resolve a manifest's human-readable strings against the package's
/// `_locales`, in place.
///
/// Nothing is read from disk unless there is a placeholder to resolve, so a
/// package with a broken `_locales` and a plain name costs nothing.
///
/// **A name that cannot be resolved refuses the package.** That is the same
/// rule an unparseable `manifest.json` already gets, and Chrome refuses such a
/// package too. The alternative is an extension whose only name is a key, shown
/// on the one screen where a person decides what it may do. A *description*
/// that cannot be resolved is dropped instead: it is incidental to the ask, and
/// AGENTS.md's fallback rule turns on exactly that difference.
pub fn localise(
    manifest: &mut ExtensionManifest,
    default_locale: Option<&str>,
    dir: &Path,
    requested: Option<&str>,
) -> Result<(), ExtError> {
    let localised_description = manifest.description.as_deref().is_some_and(is_localised);
    if !is_localised(&manifest.name) && !localised_description {
        return Ok(());
    }

    let table = table(dir, requested, default_locale);

    let name = substitute(&manifest.name, &table).filter(|name| !name.trim().is_empty());
    manifest.name = name.ok_or_else(|| ExtError::UntranslatedName {
        key: manifest.name.clone(),
    })?;

    if localised_description {
        manifest.description = manifest
            .description
            .take()
            .and_then(|description| substitute(&description, &table))
            .filter(|description| !description.trim().is_empty());
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A directory laid out the way an unpacked package is.
    struct Package {
        root: std::path::PathBuf,
    }

    impl Package {
        fn new(label: &str) -> Self {
            let root = crate::test_support::scratch_path(&format!("i18n-{label}"));
            let _ = fs::remove_dir_all(&root);
            fs::create_dir_all(&root).unwrap();
            Self { root }
        }

        fn locale(self, locale: &str, body: &str) -> Self {
            let dir = self.root.join("_locales").join(locale);
            fs::create_dir_all(&dir).unwrap();
            fs::write(dir.join("messages.json"), body).unwrap();
            self
        }

        fn path(&self) -> &Path {
            &self.root
        }
    }

    impl Drop for Package {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.root);
        }
    }

    fn a_manifest(name: &str, description: Option<&str>) -> ExtensionManifest {
        ExtensionManifest {
            name: name.to_string(),
            version: "1.0".to_string(),
            description: description.map(str::to_string),
            manifest_version: 3,
            permissions: Vec::new(),
            host_permissions: Vec::new(),
            has_action: false,
            compat: None,
        }
    }

    #[test]
    fn a_name_that_is_a_placeholder_becomes_the_real_name() {
        // The defect this file exists for: 1Password installed, and the list
        // said `__MSG_extName__`.
        let package = Package::new("resolves").locale(
            "en",
            r#"{"extName": {"message": "1Password"},
                "extDesc": {"message": "The world's most-loved password manager"}}"#,
        );
        let mut manifest = a_manifest("__MSG_extName__", Some("__MSG_extDesc__"));

        localise(&mut manifest, Some("en"), package.path(), None).unwrap();

        assert_eq!(manifest.name, "1Password");
        assert_eq!(
            manifest.description.as_deref(),
            Some("The world's most-loved password manager")
        );
    }

    #[test]
    fn a_message_name_is_matched_however_it_is_cased() {
        let package =
            Package::new("case").locale("en", r#"{"extName": {"message": "Case Insensitive"}}"#);
        let mut manifest = a_manifest("__MSG_EXTNAME__", None);

        localise(&mut manifest, Some("en"), package.path(), None).unwrap();

        assert_eq!(manifest.name, "Case Insensitive");
    }

    #[test]
    fn the_requested_locale_wins_and_the_default_fills_what_it_misses() {
        let package = Package::new("requested")
            .locale(
                "en",
                r#"{"extName": {"message": "Blocker"}, "extDesc": {"message": "Blocks things"}}"#,
            )
            .locale("pt_BR", r#"{"extName": {"message": "Bloqueador"}}"#);
        let mut manifest = a_manifest("__MSG_extName__", Some("__MSG_extDesc__"));

        localise(&mut manifest, Some("en"), package.path(), Some("pt-BR")).unwrap();

        assert_eq!(manifest.name, "Bloqueador");
        // The locale that had the name did not have the description, and the
        // fallback for that string is the package's own language rather than
        // the placeholder.
        assert_eq!(manifest.description.as_deref(), Some("Blocks things"));
    }

    #[test]
    fn a_requested_locale_that_is_absent_falls_back_to_the_language_then_the_default() {
        let package = Package::new("fallback")
            .locale("en", r#"{"extName": {"message": "Default"}}"#)
            .locale("pt", r#"{"extName": {"message": "Português"}}"#);
        let mut manifest = a_manifest("__MSG_extName__", None);

        // `pt_BR` is not there; `pt` is.
        localise(&mut manifest, Some("en"), package.path(), Some("pt_BR")).unwrap();
        assert_eq!(manifest.name, "Português");

        let mut manifest = a_manifest("__MSG_extName__", None);
        // Nothing resembling `fr` is there, so the package's own locale answers.
        localise(&mut manifest, Some("en"), package.path(), Some("fr_CA")).unwrap();
        assert_eq!(manifest.name, "Default");
    }

    #[test]
    fn a_package_with_no_locales_at_all_is_refused_rather_than_showing_the_key() {
        let package = Package::new("none");
        let mut manifest = a_manifest("__MSG_extName__", None);

        let result = localise(&mut manifest, Some("en"), package.path(), None);

        assert!(matches!(result, Err(ExtError::UntranslatedName { .. })));
    }

    #[test]
    fn a_malformed_locale_falls_back_instead_of_throwing() {
        // Every one of these is a locale directory that is not a message
        // bundle. None of them may panic, and none of them may stop the good
        // one being found.
        let package = Package::new("malformed")
            .locale("en", "{ this is not json")
            .locale("pt_BR", "[]")
            .locale("de", r#"{"extName": 42}"#)
            .locale("es", r#"{"extName": {"description": "no message here"}}"#)
            .locale("fr", r#"{"extName": {"message": "Le Nom"}}"#);
        let mut manifest = a_manifest("__MSG_extName__", None);

        localise(&mut manifest, Some("en"), package.path(), Some("fr")).unwrap();

        assert_eq!(manifest.name, "Le Nom");
    }

    #[test]
    fn a_manifest_with_nothing_to_resolve_never_touches_the_disk() {
        // `/nonexistent` is the proof: if this read anything it would be
        // reading from a directory that is not there.
        let mut manifest = a_manifest("Plain Name", Some("Plain description"));

        localise(
            &mut manifest,
            Some("en"),
            Path::new("/nonexistent/zer0/package"),
            Some("pt_BR"),
        )
        .unwrap();

        assert_eq!(manifest.name, "Plain Name");
        assert_eq!(manifest.description.as_deref(), Some("Plain description"));
    }

    #[test]
    fn a_message_that_refers_to_itself_expands_once_and_stops() {
        // The recursion case. It terminates because substitution is one pass,
        // not because anything counts depth.
        let package = Package::new("recursive").locale(
            "en",
            r#"{"extName": {"message": "__MSG_extName__ Pro"},
                "loop": {"message": "__MSG_loop__"}}"#,
        );
        let mut manifest = a_manifest("__MSG_extName__", Some("__MSG_loop__"));

        localise(&mut manifest, Some("en"), package.path(), None).unwrap();

        assert_eq!(manifest.name, "__MSG_extName__ Pro");
        assert_eq!(manifest.description.as_deref(), Some("__MSG_loop__"));
    }

    #[test]
    fn a_locale_that_is_a_path_is_never_followed() {
        let package = Package::new("escape").locale("en", r#"{"extName": {"message": "Safe"}}"#);
        let mut manifest = a_manifest("__MSG_extName__", None);

        // The requested locale is a traversal and the default is the real one.
        // The traversal contributes nothing, and it certainly does not read
        // anything outside the package.
        localise(
            &mut manifest,
            Some("en"),
            package.path(),
            Some("../../../../etc"),
        )
        .unwrap();

        assert_eq!(manifest.name, "Safe");
        for hostile in ["..", "/etc", "en/../..", "en\0", "a".repeat(64).as_str()] {
            assert!(safe_locale(hostile).is_none(), "accepted {hostile:?}");
        }
    }

    #[test]
    fn a_description_that_cannot_be_resolved_is_dropped_rather_than_shown_as_a_key() {
        let package = Package::new("partial").locale("en", r#"{"extName": {"message": "Named"}}"#);
        let mut manifest = a_manifest("__MSG_extName__", Some("__MSG_missingDesc__"));

        localise(&mut manifest, Some("en"), package.path(), None).unwrap();

        assert_eq!(manifest.name, "Named");
        assert_eq!(manifest.description, None);
    }

    #[test]
    fn an_unterminated_placeholder_is_not_a_placeholder() {
        let package =
            Package::new("unterminated").locale("en", r#"{"extname": {"message": "Whatever"}}"#);
        let mut manifest = a_manifest("__MSG_extName", None);

        // No closing `__`, so there is nothing to look up and nothing to guess.
        // `is_localised` sees the prefix, so this reaches `substitute` and has
        // to be refused there rather than silently kept.
        let result = localise(&mut manifest, Some("en"), package.path(), None);

        assert!(matches!(result, Err(ExtError::UntranslatedName { .. })));
    }

    /// A byte-order mark at the front of a message bundle is not a broken
    /// bundle.
    ///
    /// Awesome Screenshot ships one in all 54 of its `messages.json` files and
    /// could not be installed at all: `serde_json` refuses a leading `U+FEFF`,
    /// so the table came back empty, every name resolved to nothing and
    /// `localise` refused the package with `UntranslatedName`. Chrome accepts
    /// it, which is why the package exists in that shape.
    ///
    /// The fault is total rather than cosmetic, so the assertion is that the
    /// name arrives — not that the file parses.
    #[test]
    fn a_message_bundle_that_starts_with_a_byte_order_mark_is_still_read() {
        let package = Package::new("bom").locale(
            "en",
            "\u{feff}{\"extName\": {\"message\": \"Awesome Screenshot\"}}",
        );
        let mut manifest = a_manifest("__MSG_extName__", None);

        localise(&mut manifest, Some("en"), package.path(), None).unwrap();

        assert_eq!(manifest.name, "Awesome Screenshot");
    }

    #[test]
    fn a_message_bundle_bigger_than_the_ceiling_is_not_read() {
        let package = Package::new("huge").locale("en", r#"{"extName": {"message": "Small"}}"#);
        let fat = package.path().join("_locales").join("de");
        fs::create_dir_all(&fat).unwrap();
        let padding = " ".repeat(MAX_MESSAGES_BYTES as usize + 1);
        fs::write(
            fat.join("messages.json"),
            format!(r#"{{"extName": {{"message": "Fat"}}}}{padding}"#),
        )
        .unwrap();

        let mut manifest = a_manifest("__MSG_extName__", None);
        localise(&mut manifest, Some("en"), package.path(), Some("de")).unwrap();

        assert_eq!(manifest.name, "Small", "an oversized bundle was read");
    }
}
