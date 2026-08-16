//! Downloads: what is coming down, where it lands, and what happened to it.
//!
//! A download outlives the view that shows it — you can close the tab, switch
//! space and hide the shelf while the bytes keep arriving — so it is state, and
//! state lives here rather than in a SwiftUI view.
//!
//! Two things in this file are security, not bookkeeping:
//!
//! - [`safe_filename`] is the only thing standing between a name chosen by a
//!   remote server and a write outside the download directory.
//! - [`destination_in`] never returns a path that already holds something, so a
//!   download can add a file but can never replace one.

use std::path::{Path, PathBuf};

use crate::model::TabId;

/// The shell's handle on one download.
///
/// A string supplied by the host, for the same reason a space's `data_store_id`
/// is: the core stays free of randomness and stays deterministic under test,
/// and the host keeps a key it can map straight back to its `WKDownload`.
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct DownloadId(pub String);

#[cfg(feature = "ffi")]
uniffi::custom_newtype!(DownloadId, String);

/// Where a download is in its life.
///
/// Every state except `InProgress` is terminal: once a download has stopped it
/// never starts again, and a retry is a new download with a new id.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum DownloadState {
    /// Bytes are arriving.
    InProgress,
    /// The whole file is on disk.
    Completed,
    /// The person stopped it.
    Cancelled,
    /// The transfer broke. `error` says how.
    Failed,
    /// The browser went away while it was still running. Distinct from
    /// `Failed` because nothing went wrong with the transfer: we did.
    Interrupted,
}

impl DownloadState {
    pub fn is_terminal(self) -> bool {
        !matches!(self, DownloadState::InProgress)
    }
}

/// Why a download stopped, in terms the interface can act on.
///
/// Decided here rather than in the shell for the same reason
/// [`crate::NavigationErrorKind`] is: "you are offline" and "the disk is full"
/// are different sentences with different actions on every platform, and
/// `NSURLErrorDomain -1009` is not something any UI can branch on.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum DownloadErrorKind {
    /// There is no network at all.
    Offline,
    /// The connection was refused, reset or dropped partway.
    ConnectionFailed,
    Timeout,
    /// TLS failed on the way to the file.
    CertificateInvalid,
    /// The destination could not be written: permissions, a read-only volume,
    /// a folder that went away.
    CannotWrite,
    /// The volume is full.
    NoSpace,
    /// Every name we could form in that folder was already taken.
    NameUnavailable,
    Unknown,
}

#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct DownloadError {
    pub kind: DownloadErrorKind,
    /// What the host said, verbatim. Only worth showing when `kind` is
    /// `Unknown` and we have nothing better.
    pub message: String,
}

#[derive(Debug, Clone, PartialEq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct Download {
    pub id: DownloadId,
    /// Where the bytes came from. Kept so a failed download can be retried
    /// without the person having to find the link again.
    pub url: String,
    /// The tab that asked for it, if there was one. It may well be closed by
    /// the time the file lands.
    pub tab: Option<TabId>,
    /// The name we settled on, after sanitising and resolving collisions.
    pub filename: String,
    /// Full path on disk. Empty only while a destination is still being asked
    /// for.
    pub path: String,
    pub state: DownloadState,
    pub received_bytes: u64,
    /// `None` when the server never said how big the file is. There is no
    /// percentage in that case and none is invented: see ADR-0018.
    pub total_bytes: Option<u64>,
    pub error: Option<DownloadError>,
    pub started_at_ms: u64,
    /// Whether the host is still holding what it would take to carry on from
    /// where this stopped.
    ///
    /// Set only by the host saying so, never inferred here. Resume data is a
    /// blob the engine made, the server has to agree to honour it, and it stops
    /// being usable the moment the process that holds it goes away — so this is
    /// a fact reported from outside rather than something the core can work out
    /// from the byte counts, and ADR-0018 forbids offering a Resume that is a
    /// guess.
    ///
    /// [`crate::StorableDownload`] has no field for it, which is the guarantee
    /// rather than a rule: a row read back from disk cannot claim it.
    pub resumable: bool,
}

impl Download {
    /// How far along, or `None` when that cannot be worked out.
    ///
    /// The `None` case is the whole point. Plenty of servers send no
    /// `Content-Length`, and a bar that fills at a made-up rate is a lie the
    /// person only catches when it sits at 99% for a minute.
    pub fn fraction(&self) -> Option<f64> {
        let total = self.total_bytes?;
        // A zero total is not a total, and a total smaller than what has
        // already arrived is a number the server got wrong. Neither can be
        // turned into a percentage, so neither is.
        if total == 0 || self.received_bytes > total {
            return None;
        }
        Some(self.received_bytes as f64 / total as f64)
    }

    pub fn is_in_flight(&self) -> bool {
        self.state == DownloadState::InProgress
    }
}

/// How many downloads are worth remembering. Deep enough to find last week's
/// file, shallow enough not to become a second history.
pub(crate) const DOWNLOAD_MEMORY: usize = 200;

/// Every download this browser knows about, newest first.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct Downloads {
    items: Vec<Download>,
    /// The identities handed to extensions, in the order they were first asked
    /// for. The number an extension sees is the position in here, plus one.
    ///
    /// `chrome.downloads` documents an id as an integer, and this browser's own
    /// [`DownloadId`] is a string chosen by whatever created the transfer.
    /// Handing the string over would break `downloads.search({id})` for every
    /// extension that treats the value as Chrome says it can, so one integer is
    /// minted per download the first time an extension is told about it.
    ///
    /// **Never written down, and never rebuilt from what was.** It is an
    /// identity for a conversation that lasts as long as this process, which is
    /// exactly how long the extension holding it lasts. A number restored from
    /// disk would name a different download to an extension that remembered the
    /// old one.
    api_ids: Vec<DownloadId>,
}

impl Downloads {
    pub fn new() -> Self {
        Self::default()
    }

    /// The integer an extension knows this download by, minting one if this is
    /// the first time anything asked.
    pub(crate) fn api_id(&mut self, id: &DownloadId) -> u64 {
        if let Some(at) = self.api_ids.iter().position(|known| known == id) {
            return at as u64 + 1;
        }
        self.api_ids.push(id.clone());
        self.api_ids.len() as u64
    }

    /// The same, without minting. `None` means nothing has ever been told about
    /// this download, so no extension can be holding a number for it.
    pub(crate) fn api_id_if_known(&self, id: &DownloadId) -> Option<u64> {
        self.api_ids
            .iter()
            .position(|known| known == id)
            .map(|at| at as u64 + 1)
    }

    /// Which download an extension means. `None` for a number nobody was given,
    /// including one for a row that has since been removed.
    pub(crate) fn by_api_id(&self, api_id: u64) -> Option<DownloadId> {
        let at = usize::try_from(api_id.checked_sub(1)?).ok()?;
        let id = self.api_ids.get(at)?;
        self.get(id).map(|download| download.id.clone())
    }

    /// Newest first.
    pub fn all(&self) -> &[Download] {
        &self.items
    }

    pub fn get(&self, id: &DownloadId) -> Option<&Download> {
        self.items.iter().find(|d| &d.id == id)
    }

    pub fn in_flight(&self) -> Vec<&Download> {
        self.items.iter().filter(|d| d.is_in_flight()).collect()
    }

    /// How many are still running. The shell asks before quitting, because
    /// quitting stops them and it must not pretend otherwise.
    pub fn in_flight_count(&self) -> usize {
        self.items.iter().filter(|d| d.is_in_flight()).count()
    }

    /// Paths already promised to downloads that have not landed yet.
    pub(crate) fn reserved_paths(&self) -> Vec<String> {
        self.items
            .iter()
            .filter(|d| d.is_in_flight() && !d.path.is_empty())
            .map(|d| d.path.clone())
            .collect()
    }

    pub(crate) fn get_mut(&mut self, id: &DownloadId) -> Option<&mut Download> {
        self.items.iter_mut().find(|d| &d.id == id)
    }

    pub(crate) fn begin(&mut self, download: Download) {
        self.trim();
        self.items.insert(0, download);
    }

    pub(crate) fn remove(&mut self, id: &DownloadId) -> Option<Download> {
        let at = self.items.iter().position(|d| &d.id == id)?;
        Some(self.items.remove(at))
    }

    /// Forget everything that has stopped. Files on disk are not touched: the
    /// list is a record of what happened, not the files themselves.
    pub(crate) fn retain_in_flight(&mut self) {
        self.items.retain(Download::is_in_flight);
    }

    pub(crate) fn load(items: Vec<Download>) -> Self {
        let mut items = items;
        items.truncate(DOWNLOAD_MEMORY);
        Self {
            items,
            api_ids: Vec::new(),
        }
    }

    /// Make room for one more, dropping the oldest finished entry first.
    ///
    /// A running download is never evicted to make room: it is the one entry
    /// whose disappearance would leave bytes arriving with nothing on screen
    /// saying so.
    fn trim(&mut self) {
        while self.items.len() >= DOWNLOAD_MEMORY {
            let oldest_finished = self.items.iter().rposition(|d| d.state.is_terminal());
            match oldest_finished {
                Some(at) => {
                    self.items.remove(at);
                }
                None => break,
            }
        }
    }
}

// MARK: - Naming

/// Used when nothing usable survives sanitising.
const FALLBACK_FILENAME: &str = "download";

/// APFS allows 255 bytes. Stopping short leaves room for the `-999` a
/// collision adds, so resolving one can never push a name over the limit.
const MAX_FILENAME_BYTES: usize = 240;

/// Past this, a trailing `.something` is not an extension, it is part of a
/// name that happens to contain a dot.
const MAX_EXTENSION_BYTES: usize = 16;

/// How many names to try before giving up on a folder.
const MAX_COLLISION_ATTEMPTS: u32 = 999;

/// Reduce a filename suggested by a server or a page to something that can only
/// ever land inside the directory we chose for it.
///
/// The suggestion is attacker-controlled. `Content-Disposition` is written by
/// whoever is serving the file, and web content can override it outright, so
/// everything below treats it as hostile input rather than as a hint.
pub fn safe_filename(suggested: &str) -> String {
    // Only the last component survives. A suggestion is a *name*; anything
    // shaped like a path is either a mistake or an attempt to write somewhere
    // else. Both separators, because `Content-Disposition` carries Windows
    // paths in the wild and `\` is a real separator to whoever sent it.
    let last = suggested.rsplit(['/', '\\']).next().unwrap_or_default();

    // Deliberately not percent-decoded. Decoding is exactly what turns %2F
    // back into a separator after the separators have been taken out.
    let cleaned: String = last
        .chars()
        .map(|c| if is_forbidden(c) { '-' } else { c })
        .collect();

    // Leading dots hide the file from Finder and from `ls`. A download nobody
    // can see is worse than one with an ugly name. Trailing dots and spaces go
    // too: they are invisible and they make two different names look identical.
    let trimmed = cleaned
        .trim()
        .trim_start_matches('.')
        .trim_end_matches(|c: char| c == '.' || c.is_whitespace());

    // A device name cannot be repaired by replacing a character — every
    // character in "CON" is legal, the stem as a whole is the problem — so it
    // takes the same refusal as a name that came out empty. Checked on the
    // trimmed name because Windows matches the reservation ignoring trailing
    // dots and spaces too: "CON." must not survive by losing its dot here.
    if trimmed.is_empty() || is_windows_device_name(trimmed) {
        return FALLBACK_FILENAME.to_string();
    }
    cap_length(trimmed)
}

/// Characters that must not reach the filesystem.
fn is_forbidden(c: char) -> bool {
    // `:` is not a path separator on APFS, but Finder still renders it as `/`,
    // so a name containing one reads as a folder to the person looking at it.
    // `* ? " < > |` are refused outright by NTFS: the core is hosted on
    // Windows too, and a name that cannot be written there is not a name.
    c.is_control()
        || matches!(c, '/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|')
        // Bidirectional overrides let a name read as "invoice.pdf" on screen
        // while ending in .app on disk. Nothing legitimate needs one in a
        // filename, and the only reason to send one is to be misread.
        || matches!(c,
            '\u{200e}' | '\u{200f}'
            | '\u{202a}'..='\u{202e}'
            | '\u{2066}'..='\u{2069}')
}

/// On NTFS these are not file names. `CON.txt` resolves to the console device,
/// `LPT1.pdf` to a printer port — the reservation travels with the extension.
const WINDOWS_DEVICE_NAMES: [&str; 22] = [
    "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8",
    "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
];

/// Whether `name`'s stem is a Windows device name.
///
/// The stem is the text before the *first* dot — not the extension split
/// [`split_extension`] makes at the last one — because Windows matches the
/// reservation that way: `CON.tar.gz` is the console device, while
/// `report.CON` is an ordinary file. ASCII case only, as the reserved set
/// itself is ASCII.
fn is_windows_device_name(name: &str) -> bool {
    let stem = name.split('.').next().unwrap_or_default();
    let stem = stem.to_ascii_uppercase();
    WINDOWS_DEVICE_NAMES.contains(&stem.as_str())
}

/// Split a name into stem and extension, extension included with its dot.
fn split_extension(name: &str) -> (&str, &str) {
    match name.rfind('.') {
        // `at > 0` because a leading dot is part of the name, not an extension.
        Some(at) if at > 0 && name.len() - at <= MAX_EXTENSION_BYTES => name.split_at(at),
        _ => (name, ""),
    }
}

/// Cut an over-long name down, keeping the extension.
///
/// The extension is what tells the person, and the system, what the file is.
/// Truncating the tail rather than the stem would turn `report.pdf` into
/// `repo` and lose that.
fn cap_length(name: &str) -> String {
    if name.len() <= MAX_FILENAME_BYTES {
        return name.to_string();
    }
    let (stem, extension) = split_extension(name);
    let budget = MAX_FILENAME_BYTES.saturating_sub(extension.len());

    // Cut on a character boundary; slicing a multi-byte character in half
    // would panic.
    let mut cut = 0;
    for (at, c) in stem.char_indices() {
        if at + c.len_utf8() > budget {
            break;
        }
        cut = at + c.len_utf8();
    }
    let stem = &stem[..cut];
    if stem.is_empty() {
        return FALLBACK_FILENAME.to_string();
    }
    format!("{stem}{extension}")
}

/// The path to write to inside `directory`, or `None` when there is no free
/// name left.
///
/// `taken` reports whether something already occupies a path. It is a parameter
/// so the collision rules can be tested without a filesystem; the real check is
/// [`occupied`].
///
/// Numbering matches what Safari does on the same machine: the second copy of
/// `report.pdf` is `report-2.pdf`. A person who downloads the same file twice
/// should recognise the result without being told the rule.
pub fn destination_in(
    directory: &str,
    filename: &str,
    taken: impl Fn(&Path) -> bool,
) -> Option<PathBuf> {
    let directory = Path::new(directory);
    // Sanitised here as well as at the call site. This function is the last
    // thing between a name and the filesystem, and a caller that forgot must
    // not be able to make it write outside `directory`.
    let filename = safe_filename(filename);

    let first = directory.join(&filename);
    if !taken(&first) {
        return Some(first);
    }

    let (stem, extension) = split_extension(&filename);
    for n in 2..=MAX_COLLISION_ATTEMPTS {
        let candidate = directory.join(format!("{stem}-{n}{extension}"));
        if !taken(&candidate) {
            return Some(candidate);
        }
    }
    None
}

/// [`destination_in`] against the real filesystem, plus the paths other
/// downloads have already been promised.
///
/// `reserved` is not belt and braces. A destination is decided the moment
/// WebKit asks, and the file only appears when the first byte lands, so two
/// downloads of the same name started together both see an empty folder and
/// are both sent to `report.pdf`. One then writes over the other, which is the
/// one thing this whole module exists to prevent.
pub fn destination(directory: &str, suggested: &str, reserved: &[String]) -> Option<PathBuf> {
    destination_in(directory, suggested, |candidate| {
        occupied(candidate) || reserved.iter().any(|r| Path::new(r) == candidate)
    })
}

/// Whether anything already occupies `path`.
///
/// `symlink_metadata` rather than `exists`: `exists` follows the link, so a
/// dangling symlink planted at the destination would read as free, and the
/// download would be written *through* it to wherever it points. That is a
/// write outside the download directory carrying the person's own filename.
fn occupied(path: &Path) -> bool {
    std::fs::symlink_metadata(path).is_ok()
}

/// Whether `path` is a directory we can put a file in.
///
/// A configured download folder that has been deleted or unmounted is not an
/// error worth stopping a download for; it is a reason to fall back.
pub fn is_usable_directory(path: &str) -> bool {
    !path.is_empty() && Path::new(path).is_dir()
}

#[cfg(test)]
#[path = "downloads_tests.rs"]
mod tests;
