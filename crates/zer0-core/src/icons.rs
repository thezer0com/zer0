//! Site icons: which one to ask for, what counts as one, and who is allowed
//! to ask.
//!
//! The bytes are drawn by the shell, but nothing here is appearance. Which URL
//! to fetch, whether a space may fetch at all, what a server is allowed to
//! hand back and how long a site that gave us nothing is left alone are all
//! behaviour, and two platforms must not be free to disagree about any of them.

use std::collections::{HashMap, HashSet};

use url::Url;

/// The pixel size a 16pt badge needs on a Retina screen.
///
/// An icon declared smaller than this is scaled up, and a blurred 16px logo
/// reads worse than the letter it replaced. So a page offering both 16 and 32
/// is asked for the 32.
pub const TARGET_ICON_PX: u32 = 32;

/// The most one icon may weigh.
///
/// Generous for a favicon — a 180px PNG is a few kilobytes — and small enough
/// that a site serving a 4 MB image, by accident or on purpose, costs us a
/// truncated read instead of memory. The shell is told this number rather than
/// choosing one, so the limit is written down once.
pub const MAX_ICON_BYTES: u32 = 128 * 1024;

/// How long a site that gave us nothing is left alone.
///
/// Without a memory of the failure, every navigation to a site with no icon is
/// another request to that site. A week is long enough that a site adding an
/// icon is noticed eventually, and short enough that the retry is never a
/// storm.
pub const RETRY_MISSING_AFTER_MS: u64 = 7 * 24 * 60 * 60 * 1000;

/// The most declarations one page may hand us.
///
/// The list comes out of a page, so it is hostile input (ADR-0024). A page
/// declaring ten thousand `<link rel="icon">` elements should cost us a
/// truncated vector, not a scan of ten thousand URLs.
pub const MAX_CANDIDATES: usize = 16;

/// One `<link rel="icon">` the page declared.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct IconCandidate {
    /// Absolute. The DOM resolves it against the page's own base, which is the
    /// one part of this the host is better placed to do than we are.
    pub url: String,
    /// The largest edge the page declared, if it declared one. `sizes="any"`
    /// on an SVG says nothing measurable, so it arrives as `None`.
    pub size_px: Option<u32>,
}

/// One site's icon, as it sits in the cache and on disk.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StoredIcon {
    /// The space's cookie jar, from [`crate::model::Space::data_store_id`].
    /// Two spaces never share a row: see the module docs on ADR-0007.
    pub data_store_id: String,
    pub host: String,
    /// Empty when the site had nothing to give. The row still earns its place:
    /// it is what stops us asking the same site again tomorrow.
    pub bytes: Vec<u8>,
    pub fetched_at_ms: u64,
}

impl StoredIcon {
    pub fn is_missing(&self) -> bool {
        self.bytes.is_empty()
    }
}

/// What a cached icon is filed under.
///
/// Per cookie jar, not per host alone. ADR-0007 gives every space its own data
/// store; a cache shared across spaces would mean a site visited in one space
/// is served from cache in another, and the *absence* of a second request is
/// something the site can see. Duplicating a few kilobytes is the cheaper side
/// of that trade.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct IconKey {
    pub data_store_id: String,
    pub host: String,
}

impl IconKey {
    pub fn new(data_store_id: impl Into<String>, host: impl Into<String>) -> Self {
        Self {
            data_store_id: data_store_id.into(),
            host: host.into(),
        }
    }
}

/// Every icon this browser holds, and what it is still waiting for.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Icons {
    entries: HashMap<IconKey, StoredIcon>,
    /// Asked for and not yet answered. Ten tabs opening on one host is one
    /// request, not ten.
    in_flight: HashSet<IconKey>,
    /// Rows the disk has not seen yet.
    dirty: Vec<IconKey>,
    /// Cookie jars whose rows should go, because the space that owned them is
    /// gone.
    dropped: Vec<String>,
    /// Bumped whenever anything a row would draw has changed, so the shell can
    /// tell "no icon yet" from "no icon, we asked".
    revision: u64,
}

impl Icons {
    pub fn new() -> Self {
        Self::default()
    }

    /// Restore from storage. Not a fetch, so nothing is marked dirty.
    pub fn load(entries: Vec<StoredIcon>) -> Self {
        Self {
            entries: entries
                .into_iter()
                .map(|icon| (IconKey::new(&icon.data_store_id, &icon.host), icon))
                .collect(),
            ..Self::default()
        }
    }

    /// The bytes to draw, or `None` for a site we have nothing for — whether
    /// because we never asked, because the request failed, or because what came
    /// back was not an image.
    pub fn bytes(&self, key: &IconKey) -> Option<&[u8]> {
        self.entries
            .get(key)
            .filter(|icon| !icon.is_missing())
            .map(|icon| icon.bytes.as_slice())
    }

    /// Whether this site is worth asking about right now.
    ///
    /// No if we already have it, no if a request is out, and no if the site
    /// already told us it has nothing and the answer has not gone stale.
    pub fn wants(&self, key: &IconKey, now_ms: u64) -> bool {
        if self.in_flight.contains(key) {
            return false;
        }
        match self.entries.get(key) {
            None => true,
            Some(icon) if icon.is_missing() => {
                now_ms.saturating_sub(icon.fetched_at_ms) >= RETRY_MISSING_AFTER_MS
            }
            Some(_) => false,
        }
    }

    /// A request is going out.
    pub fn begin(&mut self, key: IconKey) {
        self.in_flight.insert(key);
    }

    /// An answer came back. Empty bytes mean the site gave us nothing usable,
    /// which is recorded rather than forgotten.
    pub fn record(&mut self, key: IconKey, bytes: Vec<u8>, now_ms: u64) {
        self.in_flight.remove(&key);

        let icon = StoredIcon {
            data_store_id: key.data_store_id.clone(),
            host: key.host.clone(),
            bytes,
            fetched_at_ms: now_ms,
        };
        // An identical row on disk is not worth a write, but the *time* moving
        // is: it is what keeps a site with no icon from being asked weekly and
        // then daily.
        self.entries.insert(key.clone(), icon);
        self.dirty.push(key);
        self.revision = self.revision.wrapping_add(1);
    }

    /// The space that owned this cookie jar is gone, so its icons go with it.
    ///
    /// ADR-0007 deletes the jar itself for the same reason: leaving anything
    /// derived from a closed space on disk is a leak with no way to reach it
    /// from the interface.
    pub fn forget_data_store(&mut self, data_store_id: &str) {
        let before = self.entries.len();
        self.entries
            .retain(|key, _| key.data_store_id != data_store_id);
        self.in_flight
            .retain(|key| key.data_store_id != data_store_id);
        self.dirty.retain(|key| key.data_store_id != data_store_id);
        self.dropped.push(data_store_id.to_string());

        if self.entries.len() != before {
            self.revision = self.revision.wrapping_add(1);
        }
    }

    /// Changes since the last flush. Draining, because whoever takes them owns
    /// getting them onto disk.
    pub fn take_dirty(&mut self) -> Vec<StoredIcon> {
        self.dirty
            .drain(..)
            .filter_map(|key| self.entries.get(&key).cloned())
            .collect()
    }

    /// Cookie jars whose rows should be deleted from disk.
    pub fn take_dropped(&mut self) -> Vec<String> {
        std::mem::take(&mut self.dropped)
    }

    /// Changes with every icon that arrives, so the shell knows when a row it
    /// drew as a letter is worth asking about again.
    pub fn revision(&self) -> u64 {
        self.revision
    }

    pub fn len(&self) -> usize {
        self.entries.len()
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }
}

/// Which of the page's declarations to ask for.
///
/// In order of preference:
///
/// 1. the smallest one at least [`TARGET_ICON_PX`] across — big enough to draw
///    sharp on a Retina row, and no bigger than it has to be;
/// 2. failing that the largest declared, because scaling one down loses less
///    than scaling one up;
/// 3. failing that whatever the page offered without saying how big it is;
/// 4. failing that `/favicon.ico`, which is what every site had before any of
///    this was declarable and what a great many still rely on.
pub fn choose(candidates: &[IconCandidate], page_url: &str) -> Option<String> {
    let usable: Vec<&IconCandidate> = candidates
        .iter()
        .take(MAX_CANDIDATES)
        .filter(|candidate| is_fetchable(&candidate.url))
        .collect();

    usable
        .iter()
        .filter(|candidate| candidate.size_px.is_some_and(|px| px >= TARGET_ICON_PX))
        .min_by_key(|candidate| candidate.size_px.unwrap_or(u32::MAX))
        .or_else(|| {
            usable
                .iter()
                .filter(|candidate| candidate.size_px.is_some())
                .max_by_key(|candidate| candidate.size_px.unwrap_or(0))
        })
        .or_else(|| usable.iter().find(|candidate| candidate.size_px.is_none()))
        .map(|candidate| candidate.url.clone())
        .or_else(|| conventional_url(page_url))
}

/// `/favicon.ico` at the page's own origin.
pub fn conventional_url(page_url: &str) -> Option<String> {
    let parsed = Url::parse(page_url).ok()?;
    if !is_web_scheme(parsed.scheme()) {
        return None;
    }
    parsed.join("/favicon.ico").ok().map(String::from)
}

/// The host a cache row is filed under. `None` for anything that is not a page
/// on the web: `about:blank` and a local file have no site to have an icon.
pub fn host_of(page_url: &str) -> Option<String> {
    let parsed = Url::parse(page_url).ok()?;
    if !is_web_scheme(parsed.scheme()) {
        return None;
    }
    parsed.host_str().map(str::to_ascii_lowercase)
}

/// Whether a declared icon URL is one we are willing to go and get.
///
/// `http` and `https` only. A `data:` URL is the page's own bytes wearing a
/// URL, `javascript:` is not a fetch at all, and `file:` would let a page point
/// the browser at the disk.
fn is_fetchable(url: &str) -> bool {
    Url::parse(url).is_ok_and(|parsed| is_web_scheme(parsed.scheme()) && parsed.has_host())
}

fn is_web_scheme(scheme: &str) -> bool {
    scheme == "http" || scheme == "https"
}

/// Whether what came back is an image at all, and small enough to keep.
///
/// Failure is the common case here, not the edge: a request for
/// `/favicon.ico` on a site that has none very often returns the site's 404
/// page — HTML, `200 OK`, `Content-Type: text/html` — and a browser that
/// trusted the status code would file a web page as a picture and draw
/// nothing. The magic bytes are the only honest answer.
pub fn is_image(bytes: &[u8]) -> bool {
    if bytes.is_empty() || bytes.len() > MAX_ICON_BYTES as usize {
        return false;
    }

    const PNG: &[u8] = b"\x89PNG\r\n\x1a\n";
    const JPEG: &[u8] = b"\xff\xd8\xff";
    const GIF: &[u8] = b"GIF8";
    const BMP: &[u8] = b"BM";
    // `.ico` and `.cur` share a container: a zero word, then the type.
    const ICO: &[u8] = b"\x00\x00\x01\x00";
    const CUR: &[u8] = b"\x00\x00\x02\x00";

    if bytes.starts_with(PNG)
        || bytes.starts_with(JPEG)
        || bytes.starts_with(GIF)
        || bytes.starts_with(BMP)
        || bytes.starts_with(ICO)
        || bytes.starts_with(CUR)
    {
        return true;
    }
    if bytes.starts_with(b"RIFF") && bytes.len() > 12 && &bytes[8..12] == b"WEBP" {
        return true;
    }
    is_svg(bytes)
}

/// SVG is the one image format that is also text, which is exactly why it
/// needs its own answer: an HTML error page and an SVG both start with `<`.
fn is_svg(bytes: &[u8]) -> bool {
    let head = &bytes[..bytes.len().min(1024)];
    let text = String::from_utf8_lossy(head).to_ascii_lowercase();
    let text = text.trim_start();

    if text.starts_with("<!doctype html") || text.starts_with("<html") {
        return false;
    }
    (text.starts_with("<svg") || text.starts_with("<?xml") || text.starts_with("<!doctype svg"))
        && text.contains("<svg")
}

#[cfg(test)]
#[path = "icons_tests.rs"]
mod tests;
