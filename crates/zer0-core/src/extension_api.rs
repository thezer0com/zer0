//! The `chrome.*` calls zer0 answers itself, because WebKit answers none of
//! them.
//!
//! ADR-0084 measured seventeen namespaces in an extension's context and
//! twenty-five permissions gating namespaces that are not there. ADR-0100 then
//! drew the line for the compatibility file: enums, event objects and an empty
//! managed storage — nothing that would have to *do* something, because a
//! method that resolves without doing the thing is a silent failure and
//! strictly worse than the loud one it replaces.
//!
//! This file is where the other side of that line lives. `chrome.downloads` and
//! `chrome.idle` are not gaps in an engine we do not own: they are a download
//! subsystem this browser already has (ADR-0027, ADR-0101) and a number the
//! system will hand over for the asking. Answering them is not a polyfill of
//! somebody else's API, it is this browser doing what it was asked, over a
//! channel of its own.
//!
//! ## Where the request comes from, and why it is hostile
//!
//! An extension's background worker cannot be reached by a `WKUserScript` and
//! cannot use native messaging unless it declared `nativeMessaging` — measured,
//! and the second one is what rules native messaging out as the road for this:
//! `typeof chrome.runtime.sendNativeMessage` is `undefined` in a worker granted
//! only `downloads`. What does reach it is a `WKURLSchemeHandler` registered on
//! `WKWebExtensionController.Configuration.webViewConfiguration`. Measured on
//! macOS 26.6: a `fetch("zer0-extension-api://call/…")` from a background
//! service worker arrives at the handler with the method, the body and an
//! `Origin: webkit-extension://<uuid>` header naming which extension asked.
//!
//! And measured with a control, because that is the fact ADR-0054 makes
//! load-bearing: a web page whose view carries the same controller reaches that
//! handler by no route at all — not `fetch`, not an iframe, not an image —
//! while the same page reaches a handler registered on its *own* configuration.
//!
//! So every argument in here came out of somebody else's JavaScript. The rules
//! are ADR-0024's: refuse rather than repair, and never guess at what was meant.
//!
//! ## What is refused, and the shape of every refusal
//!
//! **An option this browser will not honour is refused by name rather than
//! ignored.** `chrome.downloads.download({url, filename})` that quietly drops
//! `filename` puts the file somewhere the extension did not ask for and reports
//! success — the lie ADR-0018 forbids, with the diagnosis cost ADR-0077
//! measured. So an unsupported option is an error naming the option, at the
//! call site, and the extension can take another path.

use crate::downloads::{Download, DownloadId, DownloadState, Downloads};
use crate::extension_permissions::{ConsentDecision, PermissionKind};
use crate::model::TabId;
use crate::protocol::Action;

/// Facts only the host can measure, handed in with every call.
///
/// The shell reads them and decides nothing about them: how long counts as
/// idle, and whether a locked screen outranks a recent keystroke, are answers
/// two platforms must not disagree about, so they are worked out here.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct HostFacts {
    /// Seconds since this machine last saw any input from the person.
    pub seconds_since_input: u64,
    /// Whether the screen is locked right now.
    pub screen_locked: bool,
}

/// What the shell has to do to make an answer true.
///
/// Exhaustive on purpose and with no catch-all arm anywhere it is read: a call
/// that needs the shell to act has to be given an arm here before it can be
/// answered at all.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum ExtensionApiOutcome {
    /// The JSON beside this is the whole answer.
    Nothing,
    /// Fetch this as a file, then answer with
    /// [`extension_api_download_started`] rather than with the JSON here —
    /// which is empty, because the answer is the identity of a download that
    /// does not exist yet.
    StartDownload { tab: TabId, url: String },
    /// Show this file where it is.
    ShowFile { path: String },
    /// Hand this file to whatever the system opens that kind of file with.
    OpenFile { path: String },
}

/// One answer: the body the caller gets, plus anything that has to happen for
/// it to be true.
#[derive(Debug, Clone, PartialEq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct ExtensionApiAnswer {
    /// A JSON object carrying exactly one of `ok` or `error`. Empty only where
    /// [`ExtensionApiOutcome::StartDownload`] says the answer is not known yet.
    pub json: String,
    pub outcome: ExtensionApiOutcome,
    /// Applied in order before the answer is handed over.
    ///
    /// Actions rather than engine commands, and that is the whole of it: a
    /// cancel an extension asked for has to move the row on the Downloads
    /// screen as well as stop the transfer, and only the reducer does both. An
    /// answer that reached `WKDownload` directly would stop the bytes and leave
    /// every screen saying the download was still arriving.
    pub actions: Vec<Action>,
}

impl ExtensionApiAnswer {
    fn refuse(message: impl std::fmt::Display) -> Self {
        Self {
            json: serde_json::json!({ "error": message.to_string() }).to_string(),
            outcome: ExtensionApiOutcome::Nothing,
            actions: Vec::new(),
        }
    }

    fn ok(value: serde_json::Value) -> Self {
        Self {
            json: serde_json::json!({ "ok": value }).to_string(),
            outcome: ExtensionApiOutcome::Nothing,
            actions: Vec::new(),
        }
    }
}

/// Every call this browser answers, as a closed set.
///
/// A string that is not one of these is refused rather than routed, which is
/// the whole reason the parse is separate from the dispatch: an unknown method
/// cannot reach a `_ =>` that "handles" it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Method {
    DownloadsDownload,
    DownloadsSearch,
    DownloadsCancel,
    DownloadsErase,
    DownloadsOpen,
    DownloadsShow,
    /// Answered, and the answer is no. See [`RESUMABILITY_IS_NOT_OURS_TO_PROMISE`].
    DownloadsPause,
    /// The same.
    DownloadsResume,
    IdleQueryState,
}

impl Method {
    fn read(name: &str) -> Option<Self> {
        match name {
            "downloads.download" => Some(Self::DownloadsDownload),
            "downloads.search" => Some(Self::DownloadsSearch),
            "downloads.cancel" => Some(Self::DownloadsCancel),
            "downloads.erase" => Some(Self::DownloadsErase),
            "downloads.open" => Some(Self::DownloadsOpen),
            "downloads.show" => Some(Self::DownloadsShow),
            "downloads.pause" => Some(Self::DownloadsPause),
            "downloads.resume" => Some(Self::DownloadsResume),
            "idle.queryState" => Some(Self::IdleQueryState),
            _ => None,
        }
    }

    /// Every manifest permission this call needs, all of which must be held.
    ///
    /// `downloads.open` needs both, exactly as Chrome does, and for the reason
    /// Chrome does: opening a downloaded file hands it to whatever the system
    /// opens that kind of file with, which is a way out of the browser and not
    /// a rider on being allowed to start a download.
    fn needs(self) -> &'static [&'static str] {
        match self {
            Self::DownloadsDownload
            | Self::DownloadsSearch
            | Self::DownloadsCancel
            | Self::DownloadsErase
            | Self::DownloadsShow
            | Self::DownloadsPause
            | Self::DownloadsResume => &["downloads"],
            Self::DownloadsOpen => &["downloads", "downloads.open"],
            Self::IdleQueryState => &["idle"],
        }
    }
}

/// Why `pause` and `resume` are answered with a refusal rather than carried
/// out.
///
/// ADR-0101 made resumability a fact the *shell* holds, for this run of the
/// application only, in a map bounded at sixty-four blobs — and
/// `StorableDownload` has no field for it, deliberately, so that a row read
/// back from disk cannot claim it. There is nothing behind an extension-facing
/// pause that could keep the promise the word makes: the blob is gone at quit,
/// gone when the bound evicts it, and gone when a resume it was spent on failed
/// to start.
///
/// A `pause` that stopped the transfer and hoped would be exactly ADR-0077's
/// silent failure, and it would be worse than the usual kind because what it
/// loses is the person's bytes.
const RESUMABILITY_IS_NOT_OURS_TO_PROMISE: &str = "zer0 does not pause or resume downloads for an extension. Whether a stopped download can \
     be carried on is something this browser knows only while it is still holding what that \
     would take, and only for this run, so an answer here would be a promise nothing keeps.";

/// Answer one call.
///
/// `decision` is what the person allowed this extension, and `None` means
/// nobody was ever asked — which is refused, because an unanswered sheet is not
/// a grant.
pub fn answer(
    method_name: &str,
    body: &str,
    decision: Option<&ConsentDecision>,
    downloads: &mut Downloads,
    active_tab: Option<TabId>,
    host: HostFacts,
) -> ExtensionApiAnswer {
    let Some(method) = Method::read(method_name) else {
        // Named something that does not exist: refuse, do not repair
        // (AGENTS.md). Nothing here guesses at the nearest match.
        return ExtensionApiAnswer::refuse(format!("zer0 does not answer {method_name}."));
    };

    let Some(decision) = decision else {
        return ExtensionApiAnswer::refuse(
            "Nobody has decided what this extension may do yet, so it may do nothing.",
        );
    };
    for key in method.needs() {
        if !decision.grants(PermissionKind::Api, key) {
            return ExtensionApiAnswer::refuse(format!(
                "This extension is not holding \"{key}\", so zer0 will not answer {method_name}."
            ));
        }
    }

    let Ok(args) = serde_json::from_str::<serde_json::Value>(body) else {
        return ExtensionApiAnswer::refuse("zer0 could not read the arguments as JSON.");
    };

    match method {
        Method::DownloadsDownload => download(&args, active_tab),
        Method::DownloadsSearch => search(&args, downloads),
        Method::DownloadsCancel => cancel(&args, downloads),
        Method::DownloadsErase => erase(&args, downloads),
        Method::DownloadsOpen => reach_file(&args, downloads, FileReach::Open),
        Method::DownloadsShow => reach_file(&args, downloads, FileReach::Show),
        Method::DownloadsPause | Method::DownloadsResume => {
            ExtensionApiAnswer::refuse(RESUMABILITY_IS_NOT_OURS_TO_PROMISE)
        }
        Method::IdleQueryState => idle_state(&args, host),
    }
}

/// The answer to a `downloads.download` whose download has now started.
///
/// Separate from [`answer`] because the identity of a download is not known
/// until there is one, and the alternative — a placeholder in the JSON for the
/// shell to substitute — would put the shape of this answer in two places.
///
/// The number is bare rather than wrapped, because `ok` is whatever the method
/// returns and `chrome.downloads.download` returns an id. An extension writing
/// `.then(function (id) { … })` gets a number, as it does in Chrome.
pub fn download_started(downloads: &mut Downloads, id: &DownloadId) -> String {
    serde_json::json!({ "ok": downloads.api_id(id) }).to_string()
}

// MARK: - downloads

/// What `download` will accept, and what it refuses by name.
///
/// Chrome's options that are not here are refused rather than dropped. Each one
/// is something this browser genuinely does not do:
///
/// - `filename` — the name is settled by `downloads::safe_filename` against
///   what the server suggested, and there is no road from here to that decision
///   that does not also become a road for a hostile manifest (ADR-0027).
/// - `method`, `headers`, `body` — `EngineCommand::StartDownload` issues a GET
///   through the tab's web view so the space's cookies come with it. A POST with
///   headers of somebody else's choosing is a different request through a
///   different door.
/// - `saveAs` — where a download goes is answered by this browser's own
///   setting. Honouring `saveAs: false` while the setting says always ask, or
///   the other way round, would be an extension overruling something the person
///   set.
/// - `conflictAction` — accepted when it is `uniquify`, because that is exactly
///   what this browser does; refused otherwise, because `overwrite` is the one
///   thing ADR-0027 exists to make impossible.
fn download(args: &serde_json::Value, active_tab: Option<TabId>) -> ExtensionApiAnswer {
    let Some(options) = args.as_object() else {
        return ExtensionApiAnswer::refuse("downloads.download wants an options object.");
    };

    for key in options.keys() {
        let honoured = match key.as_str() {
            "url" => true,
            "conflictAction" => options["conflictAction"] == "uniquify",
            _ => false,
        };
        if !honoured {
            return ExtensionApiAnswer::refuse(format!(
                "zer0 does not honour downloads.download's \"{key}\", so it will not pretend to. \
                 It accepts \"url\", and \"conflictAction\": \"uniquify\", which is what it does."
            ));
        }
    }

    let Some(url) = options.get("url").and_then(|v| v.as_str()) else {
        return ExtensionApiAnswer::refuse("downloads.download wants a url.");
    };
    if !fetchable(url) {
        return ExtensionApiAnswer::refuse(format!(
            "zer0 downloads http and https addresses. {url} is neither."
        ));
    }
    // Through a tab because that is what carries the space's cookies
    // (ADR-0027), and there is no tab-less road to `WKDownload` here. With no
    // window open there is nothing to route through, and saying otherwise
    // would be a download reported as started that never began.
    let Some(tab) = active_tab else {
        return ExtensionApiAnswer::refuse(
            "zer0 has no page open to download through, so there is nowhere for this to go.",
        );
    };

    ExtensionApiAnswer {
        json: String::new(),
        outcome: ExtensionApiOutcome::StartDownload {
            tab,
            url: url.to_string(),
        },
        actions: Vec::new(),
    }
}

/// Only what `WKWebView.startDownload` can be asked for.
///
/// A `file:` or `data:` URL handed to a download is a way for an extension to
/// read the disk through the browser, and neither is what `downloads.download`
/// is for.
fn fetchable(url: &str) -> bool {
    let lower = url.to_ascii_lowercase();
    lower.starts_with("http://") || lower.starts_with("https://")
}

/// Chrome's `DownloadQuery`, narrowed to what this browser can answer.
///
/// An unrecognised filter is refused rather than ignored: a `search` that drops
/// a filter answers a question nobody asked, and the caller cannot tell that
/// from a genuinely empty result.
fn search(args: &serde_json::Value, downloads: &mut Downloads) -> ExtensionApiAnswer {
    // `null` is Chrome's "no query at all"; anything that is not an object is
    // a caller who meant something this cannot work out, and guessing at it is
    // how a filter goes missing.
    let query = if args.is_null() {
        serde_json::Map::new()
    } else if let Some(map) = args.as_object() {
        map.clone()
    } else {
        return ExtensionApiAnswer::refuse("downloads.search wants a query object.");
    };

    let mut limit = usize::MAX;
    let mut wanted_id: Option<u64> = None;
    let mut wanted_state: Option<String> = None;
    let mut wanted_url: Option<String> = None;

    for (key, value) in &query {
        match key.as_str() {
            "id" => wanted_id = value.as_u64(),
            "state" => wanted_state = value.as_str().map(str::to_string),
            "url" => wanted_url = value.as_str().map(str::to_string),
            "limit" => limit = value.as_u64().unwrap_or(0) as usize,
            _ => {
                return ExtensionApiAnswer::refuse(format!(
                    "zer0 cannot answer downloads.search filtered by \"{key}\", and will not \
                     answer as though the filter were not there. It filters by \"id\", \"state\", \
                     \"url\" and \"limit\"."
                ));
            }
        }
    }

    let matched: Vec<Download> = downloads
        .all()
        .iter()
        .filter(|download| {
            // An id filter can only ever mean a number this browser handed out,
            // so a download nothing was ever told about matches no id at all.
            wanted_id.is_none_or(|wanted| downloads.api_id_if_known(&download.id) == Some(wanted))
                && wanted_state
                    .as_ref()
                    .is_none_or(|wanted| chrome_state(download.state) == wanted)
                && wanted_url
                    .as_ref()
                    .is_none_or(|wanted| &download.url == wanted)
        })
        .take(limit)
        .cloned()
        .collect();

    let described: Vec<serde_json::Value> = matched
        .iter()
        .map(|download| item(downloads.api_id(&download.id), download))
        .collect();
    ExtensionApiAnswer::ok(serde_json::Value::Array(described))
}

fn cancel(args: &serde_json::Value, downloads: &Downloads) -> ExtensionApiAnswer {
    let Some(id) = named_download(args, downloads) else {
        return ExtensionApiAnswer::refuse("zer0 has no download under that id.");
    };
    let Some(download) = downloads.get(&id) else {
        return ExtensionApiAnswer::refuse("zer0 has no download under that id.");
    };
    if download.state.is_terminal() {
        return ExtensionApiAnswer::refuse("That download has already stopped.");
    }
    ExtensionApiAnswer {
        json: serde_json::json!({ "ok": serde_json::Value::Null }).to_string(),
        outcome: ExtensionApiOutcome::Nothing,
        actions: vec![Action::CancelDownload { id }],
    }
}

/// Chrome's `erase` takes the same query `search` does and answers with the ids
/// it removed, so this is `search` and then a removal each.
///
/// The rows are not taken out here. `Action::RemoveDownload` is, so the
/// Downloads screen and this answer are the same removal rather than two.
fn erase(args: &serde_json::Value, downloads: &mut Downloads) -> ExtensionApiAnswer {
    let found = search(args, downloads);
    let Ok(serde_json::Value::Object(body)) =
        serde_json::from_str::<serde_json::Value>(&found.json)
    else {
        return found;
    };
    let Some(serde_json::Value::Array(items)) = body.get("ok") else {
        // A refusal from `search` is a refusal from `erase`, verbatim: the
        // filter it could not answer is the same filter.
        return found;
    };

    let mut erased = Vec::new();
    let mut removals = Vec::new();
    for entry in items {
        let Some(api_id) = entry.get("id").and_then(|v| v.as_u64()) else {
            continue;
        };
        let Some(id) = downloads.by_api_id(api_id) else {
            continue;
        };
        removals.push(Action::RemoveDownload { id });
        erased.push(serde_json::Value::from(api_id));
    }
    ExtensionApiAnswer {
        actions: removals,
        ..ExtensionApiAnswer::ok(serde_json::Value::Array(erased))
    }
}

enum FileReach {
    Open,
    Show,
}

/// `open` and `show` differ only in what the shell is asked to do with the
/// path, so the two guards that matter — the download finished, and the row
/// still names a path — are written once.
fn reach_file(
    args: &serde_json::Value,
    downloads: &Downloads,
    reach: FileReach,
) -> ExtensionApiAnswer {
    let Some(id) = named_download(args, downloads) else {
        return ExtensionApiAnswer::refuse("zer0 has no download under that id.");
    };
    let Some(download) = downloads.get(&id) else {
        return ExtensionApiAnswer::refuse("zer0 has no download under that id.");
    };
    if download.state != DownloadState::Completed || download.path.is_empty() {
        return ExtensionApiAnswer::refuse(
            "That download did not finish, so there is no whole file to reach.",
        );
    }
    let path = download.path.clone();
    ExtensionApiAnswer {
        json: serde_json::json!({ "ok": serde_json::Value::Null }).to_string(),
        outcome: match reach {
            FileReach::Open => ExtensionApiOutcome::OpenFile { path },
            FileReach::Show => ExtensionApiOutcome::ShowFile { path },
        },
        actions: Vec::new(),
    }
}

/// The download an `{ "id": n }` argument names, or `None`.
fn named_download(args: &serde_json::Value, downloads: &Downloads) -> Option<DownloadId> {
    // A bare number is Chrome's shape for `cancel(id)`; `{ "id": n }` is the
    // one `search` and `erase` use. Both mean the same thing.
    let api_id = args
        .as_u64()
        .or_else(|| args.get("id").and_then(serde_json::Value::as_u64))?;
    downloads.by_api_id(api_id)
}

/// One `DownloadItem`, carrying only fields this browser can back.
///
/// Chrome's has thirty; what is here is what the core really knows.
/// `totalBytes` is `0` when the server never said, which is Chrome's own answer
/// for the same fact and is why nothing here computes a percentage (ADR-0027).
fn item(api_id: u64, download: &Download) -> serde_json::Value {
    serde_json::json!({
        "id": api_id,
        "url": download.url,
        "finalUrl": download.url,
        "filename": download.path,
        "state": chrome_state(download.state),
        "paused": false,
        "canResume": false,
        "incognito": false,
        "bytesReceived": download.received_bytes,
        "totalBytes": download.total_bytes.unwrap_or(0),
        "fileSize": download.total_bytes.unwrap_or(0),
        "exists": download.state == DownloadState::Completed,
        "startTime": download.started_at_ms,
        "error": download.error.as_ref().map(|e| e.message.clone()),
    })
}

/// Chrome has three download states where this browser has five.
///
/// `Cancelled`, `Failed` and `Interrupted` all map to `interrupted`, which is
/// the truthful collapse: Chrome's `interrupted` means "stopped before the
/// whole file arrived", and all three of ours are that. Nothing is invented in
/// the other direction — there is no Chrome state for "the browser quit", so
/// the difference lives in `error` and in the row on the Downloads screen.
fn chrome_state(state: DownloadState) -> &'static str {
    match state {
        DownloadState::InProgress => "in_progress",
        DownloadState::Completed => "complete",
        DownloadState::Cancelled | DownloadState::Failed | DownloadState::Interrupted => {
            "interrupted"
        }
    }
}

// MARK: - idle

/// Chrome's three states, decided here rather than in the shell.
///
/// A locked screen is `locked` whatever the input clock says, because the
/// question `chrome.idle` is really asked to answer — may I do the thing I do
/// when nobody is there — has one answer at a lock screen and it is not
/// "active". The threshold is the caller's, clamped to Chrome's documented
/// minimum of fifteen seconds so that a caller asking for one second is told
/// about a second that was never measured.
fn idle_state(args: &serde_json::Value, host: HostFacts) -> ExtensionApiAnswer {
    // A bare number is Chrome's `queryState(seconds)`; the object form is what
    // a promise-style caller passes. Neither is repaired into the other.
    let asked = args.as_u64().or_else(|| {
        args.get("detectionIntervalInSeconds")
            .and_then(serde_json::Value::as_u64)
    });
    let Some(threshold) = asked else {
        return ExtensionApiAnswer::refuse(
            "idle.queryState wants how many seconds without input counts as idle.",
        );
    };
    let threshold = threshold.max(IDLE_FLOOR_SECONDS);

    let state = if host.screen_locked {
        "locked"
    } else if host.seconds_since_input >= threshold {
        "idle"
    } else {
        "active"
    };
    ExtensionApiAnswer::ok(serde_json::Value::from(state))
}

/// Chrome refuses a detection interval below fifteen seconds, and so does this.
///
/// Not tidiness: the number underneath comes from
/// `CGEventSourceSecondsSinceLastEventType`, which answers about input events
/// this process can see. Reporting "idle" a second after somebody stopped
/// typing would be a claim about a person built out of a number about a mouse.
const IDLE_FLOOR_SECONDS: u64 = 15;

#[cfg(test)]
#[path = "extension_api_tests.rs"]
mod tests;
