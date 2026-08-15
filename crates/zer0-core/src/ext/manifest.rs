//! Reading `manifest.json`.
//!
//! Only what the browser needs to decide whether it can run the extension and
//! what to warn the user about.
//!
//! **Corrected 2026-08-10.** This file used to say the manifest is handed to
//! WebKit unmodified. It is not, and has not been since `ext::compat`: a
//! package with a background this browser can reach has its `background` key
//! pointed at `zer0-compat.js`. The sentence was a true statement about the
//! code when it was written and became a false one; the warning it carried —
//! that rewriting a third party's manifest breaks things in ways nobody can
//! debug — is why every such rewrite is recorded in the manifest itself and
//! printed on the Extensions screen.

use serde::Deserialize;

use super::compat::CompatNotice;
use super::{ExtError, compat};

#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct ExtensionManifest {
    pub name: String,
    pub version: String,
    pub description: Option<String>,
    /// 2 or 3. Anything else is refused.
    pub manifest_version: u32,
    /// API permissions, as declared. Not yet filtered against what WebKit
    /// actually implements.
    pub permissions: Vec<String>,
    /// Sites the extension wants access to, from `host_permissions` (MV3) or
    /// the host entries mixed into `permissions` (MV2).
    pub host_permissions: Vec<String>,
    /// Whether the extension declares a button at all: `action` in MV3,
    /// `browser_action` or `page_action` in MV2.
    ///
    /// Read here rather than asked of the engine, because it decides something
    /// the engine has no opinion about: whether this extension can appear in a
    /// row of clickable icons. `WKWebExtensionContext.action(for:)` answers for
    /// every extension whether it declared one or not, so a browser that asked
    /// it would draw a button for a content-script-only extension and that
    /// button would do nothing when pressed. An affordance that does nothing is
    /// worse than no affordance.
    pub has_action: bool,
    /// Set when zer0 modified this package on the way in, holding what it added
    /// and where the extension's own code still begins.
    ///
    /// Here rather than on [`super::InstalledExtension`] for one reason: the
    /// modification *is* a modification of this file, and this is the one door
    /// a directory on disk comes through. A screen cannot obtain a manifest
    /// without being handed the notice with it, so there is no way to draw a
    /// modified package as though it were untouched.
    pub compat: Option<CompatNotice>,
}

#[derive(Deserialize)]
struct RawManifest {
    name: Option<String>,
    version: Option<String>,
    description: Option<String>,
    manifest_version: Option<u32>,
    #[serde(default)]
    permissions: Vec<serde_json::Value>,
    #[serde(default)]
    host_permissions: Vec<String>,
    /// The three spellings, kept as raw values: the browser only asks whether
    /// the key is there, and an extension whose `action` is `{}` — which is
    /// legal, and means "a button with the defaults" — still has a button.
    action: Option<serde_json::Value>,
    browser_action: Option<serde_json::Value>,
    page_action: Option<serde_json::Value>,
    /// Kept raw so the claim below can be checked against it.
    background: Option<serde_json::Value>,
    /// What `ext::compat` wrote, if it wrote anything. A package is free to
    /// ship this key itself, which is why it is only believed when the
    /// `background` beside it really does start at the file it names.
    zer0_compat: Option<RawCompat>,
}

#[derive(Deserialize)]
struct RawCompat {
    added_files: Option<Vec<String>>,
    original_entry_point: Option<String>,
}

/// The language a package says its own strings are written in.
///
/// Read on its own rather than carried on [`ExtensionManifest`], and that is
/// deliberate: it is scaffolding for resolving `__MSG_*__` (see `i18n`), not
/// anything a screen shows. A field downstream can see is a field downstream
/// can resolve against a second time, and the whole point of doing it in
/// `read_manifest` is that there is one door.
pub fn default_locale(json: &str) -> Option<String> {
    #[derive(Deserialize)]
    struct JustTheLocale {
        default_locale: Option<String>,
    }

    serde_json::from_str::<JustTheLocale>(json)
        .ok()?
        .default_locale
}

/// A host permission looks like a match pattern; an API permission does not.
fn looks_like_host_pattern(value: &str) -> bool {
    value.contains("://") || value == "<all_urls>" || value.starts_with("*.")
}

pub fn parse(json: &str) -> Result<ExtensionManifest, ExtError> {
    let raw: RawManifest =
        serde_json::from_str(json).map_err(|e| ExtError::BadManifest(e.to_string()))?;

    let manifest_version = raw.manifest_version.unwrap_or(2);
    if !(2..=3).contains(&manifest_version) {
        return Err(ExtError::UnsupportedManifestVersion {
            version: manifest_version,
        });
    }

    let name = raw
        .name
        .filter(|n| !n.trim().is_empty())
        .ok_or_else(|| ExtError::BadManifest("missing name".into()))?;
    let version = raw
        .version
        .filter(|v| !v.trim().is_empty())
        .ok_or_else(|| ExtError::BadManifest("missing version".into()))?;

    // In MV2 hosts and APIs share one list, so they have to be told apart.
    let declared: Vec<String> = raw
        .permissions
        .into_iter()
        .filter_map(|v| v.as_str().map(str::to_string))
        .collect();

    let (hosts, apis): (Vec<String>, Vec<String>) = declared
        .into_iter()
        .partition(|p| looks_like_host_pattern(p));

    let mut host_permissions = raw.host_permissions;
    host_permissions.extend(hosts);
    host_permissions.sort();
    host_permissions.dedup();

    // An explicit `null` is not a declaration. Serde reports it as a present
    // key, and a manifest that writes `"action": null` is saying there is none.
    let declared = |value: &Option<serde_json::Value>| value.as_ref().is_some_and(|v| !v.is_null());
    let has_action =
        declared(&raw.action) || declared(&raw.browser_action) || declared(&raw.page_action);

    Ok(ExtensionManifest {
        name,
        version,
        description: raw.description,
        manifest_version,
        permissions: apis,
        host_permissions,
        has_action,
        compat: compat_notice(raw.zer0_compat, raw.background.as_ref()),
    })
}

/// A modification is only reported where the manifest still shows it.
///
/// The key is read from a package, and a package is hostile input (ADR-0024).
/// Anyone can write `zer0_compat` into their own manifest, and a browser that
/// printed it back would be telling somebody zer0 added a file it never wrote —
/// a claim about our own conduct, sourced from the thing being described. So
/// the claim is checked against the `background` beside it: unless the
/// extension's background really does start at the file the notice names,
/// nothing was injected and there is nothing to report.
fn compat_notice(
    raw: Option<RawCompat>,
    background: Option<&serde_json::Value>,
) -> Option<CompatNotice> {
    let raw = raw?;
    let added_files = raw.added_files?;
    let original_entry_point = raw.original_entry_point?;
    if added_files.first().map(String::as_str) != Some(compat::COMPAT_FILE)
        || !background_starts_at(background, compat::COMPAT_FILE)
    {
        return None;
    }
    Some(CompatNotice {
        added_files,
        original_entry_point,
    })
}

fn background_starts_at(background: Option<&serde_json::Value>, file: &str) -> bool {
    let Some(background) = background.and_then(|v| v.as_object()) else {
        return false;
    };
    if background.get("service_worker").and_then(|v| v.as_str()) == Some(file) {
        return true;
    }
    background
        .get("scripts")
        .and_then(|v| v.as_array())
        .and_then(|scripts| scripts.first())
        .and_then(|first| first.as_str())
        == Some(file)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_manifest_v3_extension_parses() {
        let manifest = parse(
            r#"{
                "manifest_version": 3,
                "name": "uBlock Origin Lite",
                "version": "2026.1.1",
                "description": "An efficient blocker",
                "permissions": ["declarativeNetRequest", "storage"],
                "host_permissions": ["https://*/*"]
            }"#,
        )
        .unwrap();

        assert_eq!(manifest.name, "uBlock Origin Lite");
        assert_eq!(manifest.manifest_version, 3);
        assert_eq!(manifest.permissions, ["declarativeNetRequest", "storage"]);
        assert_eq!(manifest.host_permissions, ["https://*/*"]);
    }

    #[test]
    fn manifest_v2_hosts_are_split_out_of_the_permission_list() {
        let manifest = parse(
            r#"{
                "manifest_version": 2,
                "name": "Old Extension",
                "version": "1.0",
                "permissions": ["tabs", "https://example.com/*", "<all_urls>", "storage"]
            }"#,
        )
        .unwrap();

        // Showing "https://example.com/*" as an API permission would be
        // nonsense in a consent prompt.
        assert_eq!(manifest.permissions, ["tabs", "storage"]);
        assert_eq!(
            manifest.host_permissions,
            ["<all_urls>", "https://example.com/*"]
        );
    }

    #[test]
    fn a_missing_manifest_version_is_assumed_to_be_two() {
        let manifest = parse(r#"{"name": "X", "version": "1.0"}"#).unwrap();
        assert_eq!(manifest.manifest_version, 2);
    }

    #[test]
    fn a_future_manifest_version_is_refused_rather_than_guessed_at() {
        let result = parse(r#"{"manifest_version": 4, "name": "X", "version": "1"}"#);
        assert!(matches!(
            result,
            Err(ExtError::UnsupportedManifestVersion { version: 4 })
        ));
    }

    #[test]
    fn a_manifest_without_a_name_or_version_is_refused() {
        assert!(parse(r#"{"manifest_version": 3, "version": "1"}"#).is_err());
        assert!(parse(r#"{"manifest_version": 3, "name": "X"}"#).is_err());
        assert!(parse(r#"{"manifest_version": 3, "name": "  ", "version": "1"}"#).is_err());
    }

    #[test]
    fn malformed_json_is_reported_not_panicked_on() {
        assert!(matches!(parse("{not json"), Err(ExtError::BadManifest(_))));
        assert!(matches!(parse(""), Err(ExtError::BadManifest(_))));
    }

    #[test]
    fn non_string_permissions_are_ignored_rather_than_crashing() {
        // MV2 allowed object-shaped entries in this list.
        let manifest = parse(
            r#"{
                "manifest_version": 2,
                "name": "X",
                "version": "1",
                "permissions": ["tabs", {"weird": true}, 42]
            }"#,
        )
        .unwrap();

        assert_eq!(manifest.permissions, ["tabs"]);
    }

    #[test]
    fn duplicate_hosts_are_collapsed() {
        let manifest = parse(
            r#"{
                "manifest_version": 3,
                "name": "X",
                "version": "1",
                "permissions": ["https://a.com/*"],
                "host_permissions": ["https://a.com/*"]
            }"#,
        )
        .unwrap();

        assert_eq!(manifest.host_permissions, ["https://a.com/*"]);
    }

    /// Three spellings for one thing, and the browser has to know all three:
    /// MV3 renamed `browser_action` to `action`, and MV2 also had
    /// `page_action` for a button that only lights up on some pages.
    #[test]
    fn every_spelling_of_a_button_counts_as_one() {
        let with = |key: &str, value: &str| {
            parse(&format!(
                r#"{{"manifest_version": 3, "name": "X", "version": "1", "{key}": {value}}}"#
            ))
            .unwrap()
            .has_action
        };

        assert!(with("action", r#"{"default_title": "X"}"#));
        assert!(with("browser_action", r#"{"default_popup": "p.html"}"#));
        assert!(
            with("page_action", "{}"),
            "an empty action is still a button"
        );
    }

    /// The one that decides whether an extension can be pinned, so it is not
    /// allowed to guess in the generous direction: plenty of extensions are
    /// content scripts and a background page, and a button drawn for one of
    /// those is a button that does nothing when it is pressed.
    #[test]
    fn an_extension_that_declares_no_button_has_none() {
        let manifest = parse(
            r#"{
                "manifest_version": 3,
                "name": "Content Script Only",
                "version": "1",
                "content_scripts": [{"matches": ["<all_urls>"], "js": ["c.js"]}]
            }"#,
        )
        .unwrap();

        assert!(!manifest.has_action);

        // And an explicit null is a statement that there is none, not a key
        // that happens to be present.
        let nulled =
            parse(r#"{"manifest_version": 3, "name": "X", "version": "1", "action": null}"#)
                .unwrap();
        assert!(!nulled.has_action);
    }

    #[test]
    fn unknown_keys_are_left_alone() {
        // Manifests carry plenty we do not read. Choking on them would reject
        // most of the store.
        let manifest = parse(
            r#"{
                "manifest_version": 3,
                "name": "X",
                "version": "1",
                "background": {"service_worker": "sw.js"},
                "icons": {"128": "icon.png"},
                "some_future_key": [1, 2, 3]
            }"#,
        )
        .unwrap();

        assert_eq!(manifest.name, "X");
    }
}
