//! Installing Chrome extensions.
//!
//! The pipeline is: bytes in, a directory on disk out, ready to hand to
//! `WKWebExtension(resourceBaseURL:)`. Downloading is the shell's job, since
//! URLSession already handles the system's proxy and certificate settings;
//! everything after that happens here where it can be tested.
//!
//! ## What is and is not verified
//!
//! Two checks gate an install (ADR-0113). The package's declared id must be
//! derivable from one of the signing keys in its header — one, because a
//! package from the store carries several and the author's is not the first —
//! which stops a swapped response from installing a different extension under
//! the id you asked for. And every RSA and ECDSA signature in the header must
//! verify over the signed data and the entire archive, which stops a forged
//! or modified package outright: whoever built it does not hold the key the
//! id was derived from, so they cannot produce a signature that passes.
//!
//! What this does not do is vouch for the *author*. An attacker is free to
//! sign a package with their own key; it derives their own id and installs as
//! their own extension — the store's publisher proof, which Chrome can
//! require, is not required here, because the gate is "the extension you
//! asked for, unmodified", not "vetted by Google". Everything after install
//! therefore still treats the package as hostile input, and unpacking runs
//! under [`UnpackLimits`].
//!
//! ## What a package is allowed to cost
//!
//! Neither check is a gate against the package's *author*: an attacker signs
//! with their own key and ships under their own id, and that package is as
//! genuine as anyone's. Everything after that point treats the archive as
//! hostile input, and unpacking runs under [`UnpackLimits`].

mod compat;
// `pub(crate)` only so the FFI door's tests can build a genuinely signed
// package through the same `test_support` this module's own tests use, rather
// than a second builder that could drift from what the parser accepts.
pub(crate) mod crx;
mod i18n;
mod manifest;

use std::fs;
use std::io::{self, Read};
use std::path::{Path, PathBuf};

pub use compat::CompatNotice;
pub use manifest::ExtensionManifest;

#[derive(Debug, thiserror::Error)]
pub enum ExtError {
    #[error("not a CRX package")]
    NotACrx,
    #[error("unsupported CRX version {version}, only CRX3 is read")]
    UnsupportedCrxVersion { version: u32 },
    #[error("the package is truncated")]
    Truncated,
    #[error("the package header is malformed")]
    MalformedHeader,
    #[error(
        "package declares id {declared} but no key in it derives that id (keys derive: {derived})"
    )]
    IdMismatch { declared: String, derived: String },
    #[error("a signature in the package header does not verify")]
    CrxSignatureInvalid,
    #[error("archive error: {0}")]
    Archive(String),
    #[error("the package has {count} files, more than the {limit} allowed")]
    TooManyEntries { count: usize, limit: usize },
    #[error("{path} is bigger than the {limit} bytes allowed for one file")]
    EntryTooLarge { path: String, limit: u64 },
    #[error("the package unpacks to more than the {limit} bytes allowed")]
    PackageTooLarge { limit: u64 },
    #[error("the package has no manifest.json")]
    NoManifest,
    #[error("manifest is unusable: {0}")]
    BadManifest(String),
    #[error("unsupported manifest version {version}")]
    UnsupportedManifestVersion { version: u32 },
    #[error("the package calls itself {key}, which is a translation none of its _locales defines")]
    UntranslatedName { key: String },
    #[error("refused a path that escapes the extension directory: {path}")]
    UnsafePath { path: String },
    #[error("io error: {0}")]
    Io(String),
}

impl From<io::Error> for ExtError {
    fn from(e: io::Error) -> Self {
        ExtError::Io(e.to_string())
    }
}

/// An extension unpacked and ready to load.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct InstalledExtension {
    pub id: String,
    /// Directory to hand to `WKWebExtension(resourceBaseURL:)`.
    pub path: String,
    pub manifest: ExtensionManifest,
}

/// The Chrome version the update endpoint is told it is answering.
///
/// The endpoint keys off this and **only enforces a floor**: an extension
/// declaring `minimum_chrome_version` above what is asked with is answered
/// `204 No Content`, and there is no ceiling at all. Measured on 2026-08-10,
/// asking with `151.0.7922.109` (Chrome stable that day), `200.0.0.0` and
/// `999.0.0.0` returned byte-identical packages for uBlock Origin Lite,
/// Bitwarden and Violentmonkey. Too high costs nothing; too low costs the
/// extension.
///
/// Which is why this is not "a recent stable release". That is what it used to
/// be — `131.0.0.0`, current when it was written — and a number whose job is to
/// stay recent is a number that rots. At `120.0.0.0` the store served nothing
/// for 15 of 18 ids measured, including uBlock Origin Lite, MetaMask, 1Password
/// and both big Adblocks. At the shipping `131.0.0.0` it still served nothing
/// for Violentmonkey, whose floor is between 132 and 135.
///
/// So it is set far ahead instead. The floor can never usefully exceed Chrome
/// stable — an extension requiring an unreleased Chrome would be uninstallable
/// for everyone — so any value above stable is sufficient, and stays sufficient
/// until Chrome catches up. Chrome reaches 200 somewhere around 2030.
///
/// **How the next person knows to move it:** the store answering with no
/// package is a refusal that names this number, so the report that arrives
/// carries the thing that has to change (ADR-0078).
pub const CHROME_VERSION_FOR_DOWNLOADS: &str = "200.0.0.0";

/// The URL Chrome's own updater fetches a package from.
///
/// Note this is not a documented public API, and the Chrome Web Store terms do
/// not grant third-party clients access to it. It is behind one function so
/// that swapping to a different source is a new implementation rather than a
/// refactor.
///
/// The version is not a parameter. It used to be, and the shell held the value
/// — which meant the number that decides whether a quarter of the store answers
/// at all lived where nothing tests it, on the side of the boundary that is
/// per-platform. Two hosts could not reasonably disagree about what Chrome's
/// endpoint wants, so there is no argument for it being answerable from there,
/// and no field for a stale one to sit in.
pub fn download_url(id: &str) -> String {
    format!(
        "https://clients2.google.com/service/update2/crx\
         ?response=redirect&acceptformat=crx2,crx3\
         &prodversion={CHROME_VERSION_FOR_DOWNLOADS}&x=id%3D{id}%26uc"
    )
}

/// The hosts a Chrome Web Store page can be served from.
///
/// There is one rule and this is it. [`extension_id_from_store_url`] reads it
/// to decide whether a URL is worth parsing, and the shell reads it to decide
/// where it may inject a script into the store's own pages — so a page the
/// parser would refuse is a page nothing of ours ever touches.
///
/// It is a value rather than a predicate because the second reader is
/// JavaScript running inside a page, which cannot call back into here. Handing
/// out the hosts keeps the *data* in one place; a test holds the two readers to
/// the same answer, because two spellings of "is this the store" means the
/// looser of the two is the one an attacker gets.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct StoreHosts {
    /// Matched whole, against a lowercased host.
    pub exact: Vec<String>,
    /// Matched as a suffix, leading dot included. The dot is the decision:
    /// without it `evil-chromewebstore.google.com.attacker.example` ends with
    /// the store's name and is not the store.
    pub suffixes: Vec<String>,
}

impl StoreHosts {
    fn matches(&self, host: &str) -> bool {
        let host = host.to_lowercase();
        self.exact.contains(&host) || self.suffixes.iter().any(|tail| host.ends_with(tail))
    }
}

/// The hosts the store is served from, for everything that has to agree on it.
pub fn store_hosts() -> StoreHosts {
    StoreHosts {
        exact: vec![
            "chromewebstore.google.com".to_string(),
            "chrome.google.com".to_string(),
        ],
        suffixes: vec![".chromewebstore.google.com".to_string()],
    }
}

/// The extension a Chrome Web Store page is showing, if it is showing one.
///
/// Lets the browser offer to install what you are looking at, instead of
/// making you copy an ID out of a URL. Handles both the current store host and
/// the old one, and both `/detail/<slug>/<id>` and `/detail/<id>`. HTTPS only:
/// the answer feeds an install, so a host nobody authenticated is worth
/// nothing.
pub fn extension_id_from_store_url(url: &str) -> Option<String> {
    let parsed = url::Url::parse(url).ok()?;

    // The host check is only worth something over a scheme that authenticates
    // the host. `http://chromewebstore.google.com/...` is whatever the network
    // says it is, and `javascript://chromewebstore.google.com/detail/<id>` is
    // not a page at all, it is a script whose "host" is a comment.
    if parsed.scheme() != "https" {
        return None;
    }

    if !store_hosts().matches(parsed.host_str()?) {
        return None;
    }

    // A detail page is `/detail/<slug>/<id>` or `/detail/<id>`, and the store
    // hangs subpages off it (`/reviews`, `/privacy`). So the id is one of the
    // two segments right after `detail`, and nowhere else.
    //
    // Scanning the whole path for the *last* id-shaped segment instead means a
    // crafted path like `/detail/slug/<real>/x/<planted>` offers the planted
    // id, and the id is precisely what we go download and install. Anchoring
    // to `detail` and stopping after two segments leaves nowhere to plant one.
    let mut segments = parsed.path_segments()?.skip_while(|s| *s != "detail");
    segments.next()?; // the "detail" segment itself
    segments
        .take(2)
        .find(|s| looks_like_extension_id(s))
        .map(str::to_string)
}

/// 32 characters drawn from a..p, which is how Chrome encodes an extension id.
fn looks_like_extension_id(value: &str) -> bool {
    value.len() == 32 && value.bytes().all(|b| (b'a'..=b'p').contains(&b))
}

/// Install a downloaded package under `base_dir/<id>`.
///
/// Replaces any previous copy, so reinstalling is also how you upgrade.
///
/// `locale` is the language the person reads, and it only ever affects which
/// `_locales` bundle the package's own name and description are read from.
pub fn install_extension(
    bytes: &[u8],
    base_dir: &Path,
    locale: Option<&str>,
) -> Result<InstalledExtension, ExtError> {
    let package = crx::parse(bytes)?;
    let dir = base_dir.join(&package.id);

    // Unpack beside the target and swap, so a failure halfway through cannot
    // leave a half-written extension where a working one used to be.
    let staging = base_dir.join(format!(".{}.incoming", package.id));
    let _ = fs::remove_dir_all(&staging);
    fs::create_dir_all(&staging)?;

    // Unpack, then modify, then read. The compatibility file goes in while the
    // tree is still staging, so a package that could not be modified leaves
    // nothing behind and leaves any working version exactly where it was — the
    // same guarantee unpacking already had (ADR-0022).
    let result = unpack(&package.archive, &staging)
        .and_then(|_| compat::inject(&staging))
        .and_then(|_| read_manifest(&staging, locale));

    let manifest = match result {
        Ok(manifest) => manifest,
        Err(e) => {
            let _ = fs::remove_dir_all(&staging);
            return Err(e);
        }
    };

    let _ = fs::remove_dir_all(&dir);
    fs::rename(&staging, &dir)?;

    Ok(InstalledExtension {
        id: package.id,
        path: dir.to_string_lossy().into_owned(),
        manifest,
    })
}

pub fn uninstall_extension(id: &str, base_dir: &Path) -> Result<(), ExtError> {
    let dir = base_dir.join(id);
    if dir.exists() {
        fs::remove_dir_all(dir)?;
    }
    Ok(())
}

/// Every extension already unpacked under `base_dir`.
pub fn installed_extensions(base_dir: &Path, locale: Option<&str>) -> Vec<InstalledExtension> {
    let Ok(entries) = fs::read_dir(base_dir) else {
        return Vec::new();
    };
    entries
        .filter_map(Result::ok)
        .filter(|e| e.path().is_dir())
        .filter_map(|entry| {
            let path = entry.path();
            let id = path.file_name()?.to_string_lossy().into_owned();
            // Skip staging leftovers from an interrupted install.
            if id.starts_with('.') {
                return None;
            }
            Some(InstalledExtension {
                id,
                path: path.to_string_lossy().into_owned(),
                manifest: read_manifest(&path, locale).ok()?,
            })
        })
        .collect()
}

/// The one place a directory on disk becomes an [`ExtensionManifest`].
///
/// Which means it is the one place `__MSG_*__` gets resolved. Doing it here
/// rather than at each screen is the difference between a rule and a wish:
/// there is no way to obtain a manifest whose name is still a placeholder,
/// because there is no other function that builds one.
fn read_manifest(dir: &Path, locale: Option<&str>) -> Result<ExtensionManifest, ExtError> {
    let path = dir.join("manifest.json");
    if !path.exists() {
        return Err(ExtError::NoManifest);
    }
    let json = read_package_json(&path)?;
    let mut manifest = manifest::parse(&json)?;
    i18n::localise(
        &mut manifest,
        manifest::default_locale(&json).as_deref(),
        dir,
        locale,
    )?;
    Ok(manifest)
}

/// The one place a JSON file inside a package becomes a string to parse.
///
/// It exists to strip a leading byte-order mark, and it exists as a *function*
/// because there are two such files — `manifest.json` and each locale's
/// `messages.json` — and the rule enforced at two call sites is the rule with
/// one bug waiting in it. That is not hypothetical: this was written at neither
/// call site, and the asymmetry cost nothing on the manifest and refused
/// Awesome Screenshot outright, whose 54 `messages.json` files all carry one.
///
/// `serde_json` refuses a leading `U+FEFF` — "expected value, line 1 column 1"
/// — and Chrome accepts it, so a package that works everywhere else arrives
/// here as a message table that reads as empty and a name that resolves to
/// nothing. Exactly one mark is removed: a BOM is an encoding artefact an
/// editor left behind, and a second one is a malformed file rather than a
/// second artefact. A UTF-16 file never reaches this at all, since
/// `read_to_string` refuses anything that is not UTF-8.
fn read_package_json(path: &Path) -> io::Result<String> {
    let text = fs::read_to_string(path)?;
    Ok(match text.strip_prefix('\u{feff}') {
        Some(without) => without.to_string(),
        None => text,
    })
}

/// What a package is allowed to cost us while it is being unpacked.
///
/// A CRX arrives from the network and every number in its ZIP headers is
/// written by whoever built it. These are limits on what we are willing to
/// spend, not descriptions of the file, which is why they are checked against
/// bytes that actually arrive rather than against anything the package claims.
#[derive(Debug, Clone, Copy)]
struct UnpackLimits {
    max_entries: usize,
    max_entry_bytes: u64,
    max_total_bytes: u64,
}

impl UnpackLimits {
    /// Sized against what real extensions are, measured rather than guessed.
    ///
    /// Every number below is a bound on what *we* are willing to spend on a
    /// hostile archive (ADR-0022), so each one is stated as a multiple of the
    /// worst real package measured. Packages pulled from the store through this
    /// pipeline on 2026-08-10, unpacked bytes as they actually arrived:
    ///
    /// | Package | Unpacks to | Entries | Largest entry |
    /// | --- | --- | --- | --- |
    /// | AdBlock | 361,445,737 | 443 | 18.7 MB |
    /// | Adblock Plus | 355,798,527 | 355 | 18.7 MB |
    /// | Keeper | 231,578,760 | 887 | 23.8 MB |
    /// | Screencastify | 221,579,594 | 152 | **32.2 MB** |
    /// | Bitwarden | 80,491,018 | 263 | 10.9 MB |
    /// | Wappalyzer | 76,953,181 | **13,244** | 1.8 MB |
    /// | uBlock Origin Lite | 36,221,511 | 1,021 | 2.1 MB |
    ///
    /// The previous numbers — 256 MiB and 10,000 entries — refused the two
    /// biggest content blockers on the store and Wappalyzer, which is the
    /// signal ADR-0022 named for moving them (ADR-0079). So:
    ///
    /// - **512 MiB in total.** 1.48× AdBlock, the largest real package
    ///   measured. Deflate reaches roughly 1000:1, so the thing this stops is
    ///   a 100 MB download expanding to ~100 GB; half a gigabyte of staging
    ///   that is deleted on refusal is a bounded, recoverable cost, and four
    ///   orders of magnitude short of what the bomb wanted.
    /// - **64 MiB for a single file**, unchanged. 2.08× Screencastify's
    ///   bundled `ffmpeg-core.wasm`, the largest entry anywhere in the survey.
    ///   It bounds one entry before the running total gets a chance to notice,
    ///   and nothing measured comes close to it.
    /// - **32,768 entries.** 2.47× Wappalyzer, which is an outlier by 7.5×
    ///   over the next busiest package measured (Coinbase Wallet, 1,762). Each
    ///   entry costs a file creation and an inode and no bytes, so this is the
    ///   *only* thing standing between us and a 1 MB archive declaring a
    ///   million empty files; it is raised to clear a real extension, not
    ///   removed.
    ///
    /// Note the headroom is deliberately proportional and not "just above
    /// today's largest". 256 MiB was set below a package that already existed,
    /// which is how two of the most-installed extensions on the store came to
    /// be uninstallable without anyone noticing.
    const DEFAULT: Self = Self {
        max_entries: 32_768,
        max_entry_bytes: 64 * 1024 * 1024,
        max_total_bytes: 512 * 1024 * 1024,
    };
}

/// Extract a ZIP into `dest`, refusing anything that would write outside it.
fn unpack(archive: &[u8], dest: &Path) -> Result<(), ExtError> {
    unpack_within(archive, dest, UnpackLimits::DEFAULT)
}

fn unpack_within(archive: &[u8], dest: &Path, limits: UnpackLimits) -> Result<(), ExtError> {
    let mut zip = zip::ZipArchive::new(io::Cursor::new(archive))
        .map_err(|e| ExtError::Archive(e.to_string()))?;

    if zip.len() > limits.max_entries {
        return Err(ExtError::TooManyEntries {
            count: zip.len(),
            limit: limits.max_entries,
        });
    }

    // First pass, over the central directory only: the declared sizes are a
    // claim, so they are used to refuse a package early and cheaply and for
    // nothing else. An honest compression bomb declares its real size and dies
    // here without a byte being decompressed; one that lies low about its size
    // is caught by the counters in the second pass.
    let mut declared_total = 0u64;
    for i in 0..zip.len() {
        let entry = zip
            .by_index_raw(i)
            .map_err(|e| ExtError::Archive(e.to_string()))?;
        if entry.size() > limits.max_entry_bytes {
            return Err(ExtError::EntryTooLarge {
                path: entry.name().to_string(),
                limit: limits.max_entry_bytes,
            });
        }
        declared_total = declared_total.saturating_add(entry.size());
        if declared_total > limits.max_total_bytes {
            return Err(ExtError::PackageTooLarge {
                limit: limits.max_total_bytes,
            });
        }
    }

    let mut unpacked_total = 0u64;
    for i in 0..zip.len() {
        let mut entry = zip
            .by_index(i)
            .map_err(|e| ExtError::Archive(e.to_string()))?;

        // `enclosed_name` returns None for anything that escapes, which is the
        // zip-slip defence: an entry named "../../.zshrc" must never be
        // written just because a package asked for it.
        let Some(relative) = entry.enclosed_name() else {
            return Err(ExtError::UnsafePath {
                path: entry.name().to_string(),
            });
        };
        let target = dest.join(&relative);
        if !target.starts_with(dest) {
            return Err(ExtError::UnsafePath {
                path: relative.to_string_lossy().into_owned(),
            });
        }

        if entry.is_dir() {
            fs::create_dir_all(&target)?;
            continue;
        }
        if let Some(parent) = target.parent() {
            fs::create_dir_all(parent)?;
        }

        // `entry.size()` is never used to size anything. It is a number in a
        // header the attacker wrote, and `Vec::with_capacity` on a ridiculous
        // value calls `handle_alloc_error`, which aborts the process: not an
        // unwind, not an error the FFI can report, the whole browser gone. So
        // the entry is streamed through a reader capped at what is still
        // affordable, and the cap is one byte past the budget so that landing
        // exactly on the limit is legal and exceeding it is detectable.
        let total_left = limits.max_total_bytes.saturating_sub(unpacked_total);
        let budget = limits.max_entry_bytes.min(total_left);
        let mut file = fs::File::create(&target)?;
        let written = io::copy(
            &mut Read::by_ref(&mut entry).take(budget.saturating_add(1)),
            &mut file,
        )?;

        if written > limits.max_entry_bytes {
            return Err(ExtError::EntryTooLarge {
                path: relative.to_string_lossy().into_owned(),
                limit: limits.max_entry_bytes,
            });
        }
        if written > total_left {
            return Err(ExtError::PackageTooLarge {
                limit: limits.max_total_bytes,
            });
        }
        unpacked_total += written;
    }
    Ok(())
}

/// Where extensions live, given the app's support directory.
pub fn default_extension_directory(app_support: &Path) -> PathBuf {
    app_support.join("extensions")
}

#[cfg(test)]
#[path = "ext_tests.rs"]
mod tests;
