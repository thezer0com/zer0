//! What a page asked the machine for, what it was told, and why.
//!
//! A site permission is not an extension permission with a different noun, and
//! the difference is the whole of this file. An extension is installed by
//! somebody who went looking for it, and the dialog arrives at the end of a
//! gesture they made. A page asks **whenever it likes**: while you are typing,
//! a second after you clicked something else, again on the next frame. That is
//! a click-through machine, and a dialog is the wrong shape of defence against
//! one on its own.
//!
//! So the words are here for the reason ADR-0028 gives — what `getUserMedia`
//! costs you is not something macOS and Linux get to disagree about — and the
//! *rules about when anybody is asked at all* are here too, because those are
//! the part that actually protects anyone.
//!
//! ## What is decided without asking
//!
//! [`gate`] answers most requests with no prompt at all, and every one of those
//! answers is a refusal:
//!
//! - An origin nobody could read. A `file://` page, a sandboxed frame, a
//!   `data:` URL: all of them report an origin that is either empty or shared
//!   with every other document of the same shape. Granting a camera to that is
//!   granting it to everything.
//! - A tab you are not looking at. A background tab must not be able to put a
//!   sheet in front of the page you are reading.
//! - Something already refused. A refusal that lets the page ask again on the
//!   next frame is not a refusal, it is a delay.
//! - Something dismissed in this tab since it last navigated. Escape is not an
//!   answer, but it must not be a way to be asked forever either.
//! - Anything arriving while a prompt is already up. One question at a time,
//!   and the second one is not queued: a queue is a stack of dialogs, which is
//!   the same machine with a waiting room.
//!
//! ## What is never inferred
//!
//! Absence means nobody was asked. A refusal is written down as a refusal, for
//! the reason ADR-0028 writes extension denials down: absence has to keep
//! meaning "nobody was asked", or the browser cannot tell a fresh question from
//! an answered one.

use crate::model::{Browser, SpaceId, TabId};

/// How long a prompt has to have been on screen before an answer to it counts.
///
/// The attack this exists for needs no attacker: a page fires `getUserMedia`
/// while somebody is mid-sentence, a sheet takes the keyboard, and the Return
/// that was already on its way down says yes to a camera. Half a second is past
/// any keystroke that was already in flight and under the time it takes to read
/// a word, so nobody who is actually answering ever notices it.
///
/// An answer inside the window is **ignored**, not turned into a refusal. A page
/// that could force a refusal by racing would have found a way to make the
/// browser answer for you, which is the thing being prevented, only quieter.
pub const PROMPT_SETTLE_MS: u64 = 500;

/// Something a page can be given.
///
/// One value per thing that can be held, rather than per shape the engine asks
/// in: `WKMediaCaptureType` has a combined camera-and-microphone case, and a
/// ledger keyed by that would record a grant that no screen could take half of
/// back.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum SiteCapability {
    Camera,
    Microphone,
}

impl SiteCapability {
    /// Written to disk, so these strings are a format. Renaming one silently
    /// drops every row that used the old spelling.
    pub fn as_str(self) -> &'static str {
        match self {
            SiteCapability::Camera => "camera",
            SiteCapability::Microphone => "microphone",
        }
    }

    /// Deliberately not `FromStr`: this reads one exact spelling out of the
    /// session file and nothing else. A trait implementation would invite
    /// `"Camera".parse()` from somewhere that is not the store, and a
    /// capability parsed out of anything a person typed is a capability granted
    /// by a typo.
    pub fn from_stored(value: &str) -> Option<Self> {
        match value {
            "camera" => Some(SiteCapability::Camera),
            "microphone" => Some(SiteCapability::Microphone),
            _ => None,
        }
    }
}

/// What the engine asked for, in the shapes the engine has.
///
/// These are `WKMediaCaptureType`'s three cases and nothing else. The list is
/// short because the SDK's list is short: on macOS `WKUIDelegate` surfaces
/// exactly one permission callback, and it is this one. See ADR-0056 for what
/// the platform does *not* hand us and what that costs.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum CaptureRequest {
    Camera,
    Microphone,
    CameraAndMicrophone,
}

impl CaptureRequest {
    /// Everything this request would hand over. Answered as a unit, because the
    /// engine hands over one decision for the pair.
    pub fn capabilities(self) -> &'static [SiteCapability] {
        match self {
            CaptureRequest::Camera => &[SiteCapability::Camera],
            CaptureRequest::Microphone => &[SiteCapability::Microphone],
            CaptureRequest::CameraAndMicrophone => {
                &[SiteCapability::Camera, SiteCapability::Microphone]
            }
        }
    }
}

/// What the page is told. There is no third value on purpose.
///
/// `WKPermissionDecision` has a `Prompt` case, which hands the question back to
/// WebKit's own dialog — the state this browser was in before ADR-0056, where
/// the answer was chosen by nobody and written down nowhere. Not having a
/// variant for it is what stops it coming back.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum SiteDecision {
    Allow,
    Deny,
}

/// What somebody chose on the sheet.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum SiteChoice {
    /// Yes, and remember it.
    Allow,
    /// No, and remember it. The site stops asking.
    Block,
    /// Escape, or the sheet closed some other way. The page is told no and
    /// nothing is written down — but it does not get to ask again until the tab
    /// navigates, or Escape becomes the thing you press twenty times.
    Dismiss,
}

/// An origin exactly as the engine reported it, before anybody decides whether
/// it is one.
///
/// Three fields rather than a joined string, because joining them is a
/// decision: whether `https://example.com:443` and `https://example.com` are
/// the same key is the difference between one grant and two.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct ReportedOrigin {
    pub scheme: String,
    pub host: String,
    /// `0` for "whatever the scheme's default is", which is what
    /// `WKSecurityOrigin` reports for an ordinary address.
    pub port: u32,
}

/// The canonical spelling of an origin, or `None` for something that is not one.
///
/// `None` is the answer for every shape that looks like an origin and is not:
/// a `file://` page (empty host, and every file on the disk shares it), a
/// `data:` URL, a sandboxed frame, anything with a scheme the web does not
/// grant capture to. All of those fail closed in [`gate`].
///
/// Deliberately strict about the scheme. `http` is here only because
/// `http://localhost` is a secure context and is where anybody developing
/// against a camera actually works; every other unencrypted origin is refused
/// by the engine before it reaches us, and refusing it here too costs nothing.
///
/// The host goes through the URL parser, so an internationalised domain arrives
/// in its punycode form — `xn--80ak6aa92e.com` rather than a string of Cyrillic
/// that draws as `apple.com`. That is the spelling a person can act on, and it
/// is the spelling the ledger is keyed by.
pub fn canonical_origin(origin: &ReportedOrigin) -> Option<String> {
    let scheme = origin.scheme.to_ascii_lowercase();
    let default_port = match scheme.as_str() {
        "https" => 443,
        "http" => 80,
        _ => return None,
    };

    if origin.host.is_empty() {
        return None;
    }
    // Through the parser rather than by inspection: it is what normalises the
    // host, rejects the shapes that are not hosts, and turns an IDN into
    // punycode. A hand-rolled check here would be a second, worse parser.
    let parsed = url::Url::parse(&format!("{scheme}://{}/", origin.host)).ok()?;
    let host = parsed.host_str()?;
    if host.is_empty() {
        return None;
    }

    Some(if origin.port == 0 || origin.port == default_port {
        format!("{scheme}://{host}")
    } else {
        format!("{scheme}://{host}:{}", origin.port)
    })
}

/// The origin of a page, for matching a tab against a grant.
///
/// Built out of the same pieces in the same order as [`canonical_origin`], so a
/// tab showing `https://meet.google.com/abc` and a grant recorded for
/// `https://meet.google.com` are the same key and cannot drift into disagreeing.
pub fn origin_of(url: &str) -> Option<String> {
    let parsed = url::Url::parse(url).ok()?;
    canonical_origin(&ReportedOrigin {
        scheme: parsed.scheme().to_string(),
        host: parsed.host_str()?.to_string(),
        port: u32::from(parsed.port().unwrap_or(0)),
    })
}

/// One answer, about one capability, on one site, in one space.
///
/// **Per space, and that is the decision this file is about.** ADR-0007 makes a
/// Space a cookie jar, and a cookie jar is an identity: `meet.google.com` in
/// Work is your work account and in Personal it is not. A camera grant is a
/// grant to whoever you are on that site, and in this browser who you are is a
/// function of which Space you are in. Carrying it across would put a hole in
/// the identity boundary the whole product rests on, and open it for the single
/// most invasive thing a page can ask for.
///
/// It also falls out of what a Space *is*: closing one deletes its jar with no
/// undo. A grant that outlived that deletion would be an approval for an
/// account that no longer exists, waiting for the next space to reuse the name.
///
/// The cost is real and is the cost we chose: the same site asked twice, once
/// per Space. Over-asking costs a click; under-asking costs a recording.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct SiteGrant {
    pub space: SpaceId,
    /// Canonical, as [`canonical_origin`] spells it.
    pub origin: String,
    pub capability: SiteCapability,
    /// Denials are stored rather than inferred from absence, so absence keeps
    /// meaning "nobody was asked" (ADR-0028).
    pub allowed: bool,
    pub decided_at_ms: u64,
}

/// What the ledger says about one capability on one site in one space.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SiteVerdict {
    Allowed,
    Refused,
    /// Nobody has been asked. Not the same as refused, and never treated as
    /// either answer.
    Undecided,
}

/// A question waiting on an answer.
///
/// The words are in here rather than being built by whatever draws it: what
/// pointing a camera at someone costs them is not a matter of taste, and two
/// platforms must not disagree about it (ADR-0028).
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct SitePermissionPrompt {
    /// The engine's handle for the request this answers. The host is holding a
    /// decision handler under this number and will call it exactly once.
    pub request: u64,
    pub tab: TabId,
    /// Canonical origin — the ledger key, and the string shown verbatim.
    pub origin: String,
    /// The host on its own, for the sentence. Punycode where the real thing was
    /// not ASCII.
    pub host: String,
    pub capture: CaptureRequest,
    /// The consequence, in the second person.
    pub title: String,
    /// What that means for somebody who has never thought about it.
    pub detail: String,
    /// Set only when the frame that asked is not the page you are looking at:
    /// an embedded video call, an advert, anything in an iframe. The grant goes
    /// to whoever asked, not to the page around them, and this is what says so.
    pub embedded_note: Option<String>,
    /// Which Space this answer is remembered for, said out loud, because "per
    /// site" is what everybody expects and it is not what this does.
    pub scope_note: String,
    /// When the prompt went up, by the shell's clock. The core has none
    /// (ADR-0002), and [`PROMPT_SETTLE_MS`] is measured against this.
    pub asked_at_ms: u64,
}

/// What the engine reported, before anything has been decided about it.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct SitePermissionRequest {
    /// The host's handle for the decision it is holding.
    pub request: u64,
    pub tab: TabId,
    /// The frame that asked.
    pub origin: ReportedOrigin,
    /// The page that frame is in. Equal to `origin` for a top-level request.
    pub page_origin: ReportedOrigin,
    pub capture: CaptureRequest,
    /// The shell's clock, at the moment the engine asked.
    pub asked_at_ms: u64,
}

/// What to do about a request.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Gate {
    /// Answered without anybody being asked. Always [`SiteDecision::Deny`]
    /// unless the ledger already said yes.
    Answer(SiteDecision),
    /// Put this in front of somebody.
    Ask(Box<SitePermissionPrompt>),
}

/// A question the page is not allowed to ask again yet.
///
/// Never persisted, and deliberately keyed by tab rather than by origin: this
/// is about one page's behaviour in one tab, not about a decision.
#[derive(Debug, Clone, PartialEq, Eq)]
struct Muted {
    tab: TabId,
    origin: String,
    capability: SiteCapability,
}

/// Every answer this browser has given a site, and the one question it is
/// waiting on.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct SitePermissions {
    grants: Vec<SiteGrant>,
    muted: Vec<Muted>,
    /// **One, not a queue.** A queue of permission prompts is a stack of
    /// dialogs, which is the click-through machine with a waiting room attached.
    pending: Option<SitePermissionPrompt>,
}

impl SitePermissions {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn load(grants: Vec<SiteGrant>) -> Self {
        Self {
            grants,
            muted: Vec::new(),
            pending: None,
        }
    }

    /// Everything written down, for the screen that takes it back.
    pub fn all(&self) -> &[SiteGrant] {
        &self.grants
    }

    pub fn verdict(&self, space: SpaceId, origin: &str, capability: SiteCapability) -> SiteVerdict {
        match self.find(space, origin, capability) {
            None => SiteVerdict::Undecided,
            Some(grant) if grant.allowed => SiteVerdict::Allowed,
            Some(_) => SiteVerdict::Refused,
        }
    }

    /// Write an answer down, replacing whatever was there.
    pub fn record(
        &mut self,
        space: SpaceId,
        origin: &str,
        capability: SiteCapability,
        allowed: bool,
        decided_at_ms: u64,
    ) {
        self.grants
            .retain(|g| !(g.space == space && g.origin == origin && g.capability == capability));
        self.grants.push(SiteGrant {
            space,
            origin: origin.to_string(),
            capability,
            allowed,
            decided_at_ms,
        });
    }

    /// Take an answer back entirely, so the site is asked again next time.
    ///
    /// Different from recording a refusal, and the screen offers both: "stop
    /// letting it" and "ask me again" are different things to want.
    pub fn forget(&mut self, space: SpaceId, origin: &str, capability: SiteCapability) -> bool {
        let before = self.grants.len();
        self.grants
            .retain(|g| !(g.space == space && g.origin == origin && g.capability == capability));
        self.grants.len() != before
    }

    /// The space is gone, and its cookie jar with it. An approval that outlived
    /// the identity it was given by is an approval nobody can find or revoke.
    ///
    /// The prompt is not touched here. Closing a space destroys its tabs, and
    /// the reducer drops the prompt tab by tab as their web views go — which is
    /// the one path that also answers the engine's handler, and answering it is
    /// the part that must not be skipped.
    pub fn forget_space(&mut self, space: SpaceId) {
        self.grants.retain(|g| g.space != space);
    }

    /// Escape is not an answer, but it is not an invitation either.
    pub fn mute(&mut self, tab: TabId, origin: &str, capability: SiteCapability) {
        if self.is_muted(tab, origin, capability) {
            return;
        }
        self.muted.push(Muted {
            tab,
            origin: origin.to_string(),
            capability,
        });
    }

    pub fn is_muted(&self, tab: TabId, origin: &str, capability: SiteCapability) -> bool {
        self.muted
            .iter()
            .any(|m| m.tab == tab && m.origin == origin && m.capability == capability)
    }

    /// A new page in this tab is a new question. Called on every commit, so a
    /// dismissal lasts exactly as long as the page that earned it.
    pub fn clear_mutes(&mut self, tab: TabId) {
        self.muted.retain(|m| m.tab != tab);
    }

    /// The question on screen right now, if there is one.
    pub fn pending(&self) -> Option<&SitePermissionPrompt> {
        self.pending.as_ref()
    }

    pub(crate) fn raise(&mut self, prompt: SitePermissionPrompt) {
        self.pending = Some(prompt);
    }

    /// Take the pending prompt if it is the one being answered.
    ///
    /// Matched by request id rather than by tab, so an answer to a prompt that
    /// has already been replaced answers nothing.
    pub(crate) fn take_pending(&mut self, request: u64) -> Option<SitePermissionPrompt> {
        match &self.pending {
            Some(prompt) if prompt.request == request => self.pending.take(),
            _ => None,
        }
    }

    /// Drop the question a closing tab was asking. The engine's handler goes
    /// with the web view.
    pub(crate) fn drop_pending_for(&mut self, tab: TabId) -> Option<SitePermissionPrompt> {
        match &self.pending {
            Some(prompt) if prompt.tab == tab => self.pending.take(),
            _ => None,
        }
    }

    fn find(&self, space: SpaceId, origin: &str, capability: SiteCapability) -> Option<&SiteGrant> {
        self.grants
            .iter()
            .find(|g| g.space == space && g.origin == origin && g.capability == capability)
    }
}

/// Whether an answer arrived too soon after the question to be one.
///
/// A clock that went backwards between the two — a shell that read wall time
/// twice across an NTP step — reads as "too soon" rather than as an enormous
/// gap, because `saturating_sub` floors at zero. That is the safe direction: it
/// costs a second click.
pub fn answered_too_soon(asked_at_ms: u64, decided_at_ms: u64) -> bool {
    decided_at_ms.saturating_sub(asked_at_ms) < PROMPT_SETTLE_MS
}

/// Whether this tab is one a person can currently see.
///
/// The active tab, or either half of the active space's split. A page in a tab
/// nobody is looking at must not be able to put a sheet in front of the page
/// somebody *is* looking at, and "the active tab" alone would refuse the
/// left-hand pane of a split, which is on screen.
fn is_visible(browser: &Browser, tab: TabId) -> bool {
    if browser.active_tab() == Some(tab) {
        return true;
    }
    browser
        .space(browser.active_space())
        .and_then(|space| space.split.as_ref())
        .is_some_and(|split| split.leading == tab || split.trailing == tab)
}

/// Decide what happens to a request, before anybody is asked.
///
/// Every refusal here is silent — the page is told no and nothing is written
/// down — except the one that comes from the ledger, which is somebody's answer
/// being honoured.
pub fn gate(
    browser: &Browser,
    permissions: &SitePermissions,
    request: &SitePermissionRequest,
) -> Gate {
    let Some(tab) = browser.tab(request.tab) else {
        return Gate::Answer(SiteDecision::Deny);
    };

    // An origin nobody could read is refused before anything else, because
    // every rule below it is keyed by one. This is the `file://` case, the
    // sandboxed-frame case and the `data:` case at once.
    let Some(origin) = canonical_origin(&request.origin) else {
        return Gate::Answer(SiteDecision::Deny);
    };

    if !is_visible(browser, request.tab) {
        return Gate::Answer(SiteDecision::Deny);
    }

    let capabilities = request.capture.capabilities();

    // A refusal is honoured without a prompt, for every capability in the
    // request. Asking again about something already refused is how a dialog
    // teaches people to stop reading it.
    if capabilities
        .iter()
        .any(|&c| permissions.verdict(tab.space, &origin, c) == SiteVerdict::Refused)
    {
        return Gate::Answer(SiteDecision::Deny);
    }

    if capabilities
        .iter()
        .any(|&c| permissions.is_muted(request.tab, &origin, c))
    {
        return Gate::Answer(SiteDecision::Deny);
    }

    // Allowed only when *everything* asked for was allowed. A page holding the
    // microphone and asking for both is a page asking about the camera, and it
    // gets a prompt about both rather than half a grant it cannot be told about.
    if capabilities
        .iter()
        .all(|&c| permissions.verdict(tab.space, &origin, c) == SiteVerdict::Allowed)
    {
        return Gate::Answer(SiteDecision::Allow);
    }

    // One question at a time.
    if permissions.pending().is_some() {
        return Gate::Answer(SiteDecision::Deny);
    }

    let host = host_of(&origin);
    let (title, detail) = describe(request.capture, &host);
    let space_name = browser
        .space(tab.space)
        .map(|s| s.name.clone())
        .unwrap_or_default();

    Gate::Ask(Box::new(SitePermissionPrompt {
        request: request.request,
        tab: request.tab,
        origin: origin.clone(),
        host,
        capture: request.capture,
        title,
        detail,
        embedded_note: embedded_note(&request.page_origin, &origin),
        scope_note: format!(
            "Remembered for {space_name} only, and changeable in Settings › \
             Privacy. Another space is another sign-in, and gets asked again."
        ),
        asked_at_ms: request.asked_at_ms,
    }))
}

/// The host out of a canonical origin, which is `scheme://host[:port]`.
pub(crate) fn host_of(origin: &str) -> String {
    origin
        .split_once("://")
        .map(|(_, rest)| rest.to_string())
        .unwrap_or_else(|| origin.to_string())
}

/// Said only when the thing asking is not the page you are on.
///
/// This is the shape that turns a permission prompt into a trick: an advert or
/// an embedded widget asks for the camera, the sheet appears over a site you
/// trust, and the name in the sheet is not the name you would have read. So the
/// sheet names whoever asked, and this sentence names who they were inside.
fn embedded_note(page_origin: &ReportedOrigin, canonical: &str) -> Option<String> {
    let page = canonical_origin(page_origin);
    match page {
        Some(page) if page == canonical => None,
        Some(page) => Some(format!(
            "You are on {}. This was asked for by something embedded in that \
             page, and the answer goes to whatever asked.",
            host_of(&page)
        )),
        // The page around it is a shape we could not read. Naming a site here
        // would be inventing one, so this says only what is certain.
        None => Some(
            "This was asked for by something embedded in the page rather than \
             by the page itself, and the answer goes to whatever asked."
                .to_string(),
        ),
    }
}

/// What granting this costs you, in the second person.
///
/// Consequences rather than API names, for the reason ADR-0028 lays out at
/// length: "camera" is a noun somebody clicks past, and "watch and record
/// whatever is in front of the camera" is a sentence they answer.
///
/// Nothing here claims a recording indicator. Whether a light comes on is a
/// property of the hardware — an external webcam may have none — and ADR-0018
/// is that we say only what we can prove.
fn describe(capture: CaptureRequest, host: &str) -> (String, String) {
    match capture {
        CaptureRequest::Camera => (
            format!("Let {host} see through your camera"),
            "It can watch and record whatever is in front of the camera, for as long as the \
             page is open."
                .to_string(),
        ),
        CaptureRequest::Microphone => (
            format!("Let {host} hear through your microphone"),
            "It can listen to and record whatever is said near this Mac, for as long as the \
             page is open."
                .to_string(),
        ),
        CaptureRequest::CameraAndMicrophone => (
            format!("Let {host} see and hear you"),
            "It can watch and record whatever is in front of the camera, and listen to \
             whatever is said near this Mac, for as long as the page is open."
                .to_string(),
        ),
    }
}

#[cfg(test)]
#[path = "site_permissions_tests.rs"]
mod tests;
