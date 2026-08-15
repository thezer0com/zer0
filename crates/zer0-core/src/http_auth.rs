//! Who the server says you have to be, and whether the server is who it says.
//!
//! Both arrive on one engine callback — `didReceive:challenge:` — and they are
//! two entirely different questions, so this file keeps them apart from the
//! first line and they reach two different screens.
//!
//! **Being asked for a password is routine.** A staging box, an internal
//! dashboard, a router's admin page: somebody typed the address on purpose and
//! the server wants a name. That is a request, and a request gets a panel over
//! the page it belongs to.
//!
//! **Being told the site is not provably the site is a security decision.**
//! Nothing about it is routine, there is no "just answer it and move on", and
//! ADR-0016 already decided that a page which failed takes the whole screen
//! rather than a strip. So it stays on that screen and this file only makes the
//! screen able to say what is actually wrong.
//!
//! # What is not here
//!
//! **A password.** Same guarantee as [`crate::passwords`], for the same reason
//! and by the same means: no type in this module has a field one fits in, no
//! function takes one and none returns one. What crosses the FFI is a decision
//! — an origin to key by, a refusal to explain, whether somebody may be offered
//! the chance to keep what they typed. The value goes from the panel into the
//! Keychain and into the engine's credential, and never through here.
//!
//! # The realm is the server's text, not ours
//!
//! `WWW-Authenticate: Basic realm="..."` is chosen by whoever runs the server
//! and arrives over the network, which makes it exactly as trustworthy as a
//! page's `alert()` string. Measured against a server that sends
//! `realm="Staging <script>alert(1)</script> "quoted""`, what reaches the
//! delegate is `Staging <script>alert(1)</script> ` — markup intact, and cut
//! wherever the quoting happened to end.
//!
//! So it is carried as [`AuthPrompt::realm`], separately from every sentence
//! this browser wrote, and it is capped and stripped of the characters that
//! let a line pretend to be two. The panel draws it as quoted foreign text. A
//! realm interpolated into one of our own sentences would be a server writing
//! in the browser's voice.

use crate::model::{Browser, TabId};
use crate::site_permissions::{ReportedOrigin, canonical_origin};

/// How much of a server's realm is worth showing.
///
/// Long enough for every real one — they are short labels like `Staging` or
/// `NAS admin` — and short enough that a server cannot push the buttons off
/// the panel by sending a paragraph.
const MAX_REALM: usize = 120;

/// How many times a server may say "wrong" before the panel stops coming back.
///
/// `URLAuthenticationChallenge.previousFailureCount` counts the rejections for
/// this one navigation. Two retries is what a person who mistyped needs;
/// past that the panel is a loop, and a loop over a password field is how
/// somebody ends up typing their real password into the fourth prompt to make
/// it stop.
const MAX_FAILURES: u32 = 3;

/// The authentication schemes the engine can hand us.
///
/// Closed on purpose. `NSURLAuthenticationMethod*` is an open set of strings
/// and a new one must not silently become "ask for a password": the shell maps
/// the spellings it knows and everything else arrives as [`HttpAuthScheme::Other`],
/// which is refused rather than guessed at.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum HttpAuthScheme {
    /// `Basic`. The password crosses the wire base64-encoded, which is not
    /// encryption — it is why [`AuthPrompt::insecure_note`] exists.
    Basic,
    /// `Digest`. Not sent in the clear, still keyed to one origin.
    Digest,
    /// Windows integrated authentication in either spelling. Named so the
    /// panel can be honest that this is a domain login rather than a site one.
    Ntlm,
    Negotiate,
    /// Anything else the engine names, including a client-certificate request.
    /// Refused: a panel asking for a username would be the wrong question.
    Other,
}

impl HttpAuthScheme {
    /// Whether a username and a password are the answer to this.
    fn takes_a_password(self) -> bool {
        matches!(
            self,
            HttpAuthScheme::Basic
                | HttpAuthScheme::Digest
                | HttpAuthScheme::Ntlm
                | HttpAuthScheme::Negotiate
        )
    }
}

/// What somebody chose on the panel.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum AuthChoice {
    /// Sign in with what was typed.
    Supply,
    /// Sign in, and keep it for next time.
    SupplyAndRemember,
    /// Escape, Cancel, or the tab going away. The server is told nobody
    /// answered and the page gets whatever it serves to strangers.
    Cancel,
}

/// What the engine is told. There is no third value.
///
/// `URLSession.AuthChallengeDisposition` has four, and the two missing ones are
/// missing deliberately. `performDefaultHandling` is the state this browser was
/// in before this file existed — measured, it commits the 401 and hands the
/// person the server's refusal bytes as a page. `rejectProtectionSpace` asks
/// the engine to try another scheme, which is a decision about the protocol
/// rather than about the person, and nothing here has a reason to make it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum AuthDecision {
    /// Use what the panel collected. The shell holds the value.
    UseCredential,
    /// Answer with nothing. The navigation continues and the server serves
    /// whatever it serves without credentials.
    Cancel,
}

/// A challenge exactly as the engine reported it, before anything is decided.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct HttpAuthRequest {
    /// The host's handle for the completion handler it is holding.
    pub request: u64,
    pub tab: TabId,
    pub scheme: HttpAuthScheme,
    /// The protection space, uninterpreted. `canonical_origin` decides what it
    /// means, once, in the same place every other origin in this browser is
    /// decided.
    pub origin: ReportedOrigin,
    /// The server's own label for the area. Straight off the wire.
    pub realm: Option<String>,
    /// How many times this navigation has already been told no.
    pub previous_failures: u32,
    /// A proxy asking, rather than the site. A different thing to be told, and
    /// nothing is ever remembered for one.
    pub is_proxy: bool,
    /// The shell's clock. The core has none (ADR-0002).
    pub asked_at_ms: u64,
}

/// A question waiting on a person.
///
/// The words are here rather than in whatever draws it, for the reason
/// ADR-0028 and ADR-0056 both give: what it costs you to type a password into
/// an unencrypted connection is not something two platforms should be free to
/// disagree about.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct AuthPrompt {
    pub request: u64,
    pub tab: TabId,
    /// Canonical origin. The Keychain key, and the string shown verbatim.
    pub origin: String,
    /// The host on its own, for the sentence. Punycode where the real thing
    /// was not ASCII, so a Cyrillic lookalike cannot borrow a Latin name.
    pub host: String,
    pub scheme: HttpAuthScheme,
    /// What is being asked, in the second person.
    pub title: String,
    /// What that means for somebody who has not thought about it.
    pub detail: String,
    /// The server's own words, or `None`. Never merged into `title` or
    /// `detail`: see the module documentation.
    pub realm: Option<String>,
    /// Set when the password would go out in the clear.
    pub insecure_note: Option<String>,
    /// Set when the server has already rejected an answer this navigation, so
    /// the second panel does not look identical to the first.
    pub retry_note: Option<String>,
    /// Set when a proxy is asking rather than the site.
    pub proxy_note: Option<String>,
    /// Which Space this would be remembered for, said out loud, because "for
    /// this site" is what everybody expects and it is not what this does.
    pub scope_note: String,
    /// Whether "remember this" may be offered at all. `false` for a proxy, for
    /// an unencrypted origin off loopback, and for a Space that promised to
    /// write nothing down — each of which is a refusal with a different reason
    /// and none of which the panel should discover for itself.
    pub may_remember: bool,
    pub asked_at_ms: u64,
}

/// What to do about a challenge, before anybody is asked.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AuthGate {
    /// Answered without anybody being asked. Always [`AuthDecision::Cancel`]:
    /// nothing here can produce a credential on its own.
    Answer(AuthDecision),
    /// Put this in front of somebody.
    Ask(Box<AuthPrompt>),
}

/// Every challenge the browser is currently holding a person's attention for.
///
/// One, not a queue, for the reason [`crate::site_permissions`] keeps one: a
/// page with twenty subresources behind the same realm would otherwise stack
/// twenty panels, and a stack of password panels is a machine for getting one
/// answered without being read.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct HttpAuth {
    pending: Option<AuthPrompt>,
}

impl HttpAuth {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn pending(&self) -> Option<&AuthPrompt> {
        self.pending.as_ref()
    }

    pub(crate) fn raise(&mut self, prompt: AuthPrompt) {
        self.pending = Some(prompt);
    }

    /// Take the prompt if it is the one being answered.
    ///
    /// Matched on the request number rather than the tab, so an answer to a
    /// panel that has already been replaced answers nothing.
    pub(crate) fn take_pending(&mut self, request: u64) -> Option<AuthPrompt> {
        match &self.pending {
            Some(prompt) if prompt.request == request => self.pending.take(),
            _ => None,
        }
    }

    /// Drop the question a closing tab was asking, so the caller can answer
    /// the engine before the web view goes.
    pub(crate) fn drop_pending_for(&mut self, tab: TabId) -> Option<AuthPrompt> {
        match &self.pending {
            Some(prompt) if prompt.tab == tab => self.pending.take(),
            _ => None,
        }
    }
}

/// Whether an origin may carry a password at all without warning about it.
///
/// The same rule [`crate::passwords::save_verdict`] applies to a login form,
/// and deliberately the same function shape: `http` is in the clear, except on
/// loopback, where there is no network between the two ends to read it.
fn encrypted_or_loopback(origin: &ReportedOrigin) -> bool {
    if origin.scheme.eq_ignore_ascii_case("https") {
        return true;
    }
    is_loopback(&origin.host)
}

/// Hosts that cannot be reached across a network.
///
/// This is load-bearing in two places — whether a password may go out in the
/// clear, and whether a certificate exception may be offered at all — so it is
/// written once. `.localhost` is in the list because RFC 6761 reserves the
/// whole tree for exactly this and every toolchain resolves it to loopback.
pub fn is_loopback(host: &str) -> bool {
    let host = host.to_ascii_lowercase();
    host == "localhost"
        || host.ends_with(".localhost")
        || host == "127.0.0.1"
        || host == "::1"
        || host == "[::1]"
}

/// The server's label, made safe to draw without being made up.
///
/// Three things happen and no more: control characters go, because a realm
/// carrying a newline can draw itself as two lines and the second one can look
/// like ours; it is cut to [`MAX_REALM`]; and an empty result becomes `None`
/// rather than an empty quotation.
///
/// What deliberately does **not** happen is escaping or rewriting the text. It
/// is the server's sentence and it is shown as the server's sentence — the
/// panel is responsible for drawing it as foreign, and a realm we had rewritten
/// would be a realm we were half-claiming.
fn readable_realm(realm: Option<&str>) -> Option<String> {
    let cleaned: String = realm?
        .chars()
        .filter(|c| !c.is_control())
        .take(MAX_REALM)
        .collect();
    let trimmed = cleaned.trim();
    (!trimmed.is_empty()).then(|| trimmed.to_string())
}

/// Decide what happens to a challenge, before anybody is asked.
///
/// Every silent answer here is [`AuthDecision::Cancel`]. There is no path
/// through this function that supplies a credential, which is the property that
/// makes "a page cannot get itself signed in" true rather than careful.
pub fn gate(browser: &Browser, auth: &HttpAuth, request: &HttpAuthRequest) -> AuthGate {
    let Some(tab) = browser.tab(request.tab) else {
        return AuthGate::Answer(AuthDecision::Cancel);
    };

    // A scheme whose answer is not a username and a password. A client
    // certificate request lands here, and asking for a password would be
    // asking the wrong question with the right-looking panel.
    if !request.scheme.takes_a_password() {
        return AuthGate::Answer(AuthDecision::Cancel);
    }

    // An origin nobody could read, before anything else, because everything
    // below is keyed by one.
    let Some(origin) = canonical_origin(&request.origin) else {
        return AuthGate::Answer(AuthDecision::Cancel);
    };

    // A tab nobody is looking at must not put a password panel in front of the
    // page somebody is reading. A background tab reloading on a timer is the
    // ordinary way this happens, and the panel would arrive with no visible
    // cause at all.
    if !is_visible(browser, request.tab) {
        return AuthGate::Answer(AuthDecision::Cancel);
    }

    // The server has said no enough times. Asking again is a loop.
    if request.previous_failures >= MAX_FAILURES {
        return AuthGate::Answer(AuthDecision::Cancel);
    }

    // One question at a time. Not queued: see `HttpAuth`.
    if auth.pending().is_some() {
        return AuthGate::Answer(AuthDecision::Cancel);
    }

    let host = host_of(&origin);
    let (title, detail) = describe(request.scheme, &host, request.is_proxy);
    let space_name = browser
        .space(tab.space)
        .map(|s| s.name.clone())
        .unwrap_or_default();
    let records = browser.records_to_disk(tab.space);
    let secure = encrypted_or_loopback(&request.origin);

    AuthGate::Ask(Box::new(AuthPrompt {
        request: request.request,
        tab: request.tab,
        origin,
        host,
        scheme: request.scheme,
        title,
        detail,
        realm: readable_realm(request.realm.as_deref()),
        insecure_note: (!secure).then(|| {
            "This connection is not encrypted, so what you type here can be read by anything \
             between this Mac and the server."
                .to_string()
        }),
        retry_note: (request.previous_failures > 0)
            .then(|| "That did not work. The server refused what was sent.".to_string()),
        proxy_note: request.is_proxy.then(|| {
            "A proxy on this network is asking, not the site. It sees every address you open \
             through it."
                .to_string()
        }),
        scope_note: format!(
            "Remembered for {space_name} only, and changeable in Settings › Passwords. \
             Another space is another sign-in, and gets asked again."
        ),
        // Three separate refusals, each sufficient on its own, and each for a
        // reason the others do not cover. A proxy credential is not keyed to a
        // site at all; an unencrypted origin off loopback is one we would be
        // writing down a password we watched go out in the clear; and an
        // ephemeral space promised to leave nothing behind (ADR-0023).
        may_remember: !request.is_proxy && secure && records,
        asked_at_ms: request.asked_at_ms,
    }))
}

/// Whether this tab is one a person can currently see.
///
/// The active tab, or either half of the active space's split — the same
/// question [`crate::site_permissions`] asks, and for the same reason.
fn is_visible(browser: &Browser, tab: TabId) -> bool {
    if browser.active_tab() == Some(tab) {
        return true;
    }
    browser
        .space(browser.active_space())
        .and_then(|space| space.split.as_ref())
        .is_some_and(|split| split.leading == tab || split.trailing == tab)
}

/// The host out of a canonical origin, which is `scheme://host[:port]`.
fn host_of(origin: &str) -> String {
    origin
        .split_once("://")
        .map(|(_, rest)| rest.to_string())
        .unwrap_or_else(|| origin.to_string())
}

/// What is being asked, in the second person.
///
/// Named for what it is — a sign-in belonging to one address — rather than for
/// the protocol. "Authentication required" is a status line; nobody has ever
/// been helped by reading one.
fn describe(scheme: HttpAuthScheme, host: &str, is_proxy: bool) -> (String, String) {
    if is_proxy {
        return (
            format!("{host} wants you to sign in before it will let anything through"),
            "This is the proxy your network makes you go through, not the site you asked for."
                .to_string(),
        );
    }
    match scheme {
        HttpAuthScheme::Basic | HttpAuthScheme::Digest => (
            format!("Sign in to {host}"),
            "The server will not show this page to anyone who has not named themselves."
                .to_string(),
        ),
        HttpAuthScheme::Ntlm | HttpAuthScheme::Negotiate => (
            format!("Sign in to {host} with a Windows account"),
            "This server is asking for a domain login rather than one belonging to the site."
                .to_string(),
        ),
        // Refused in `gate` before it can reach here. Spelled out rather than
        // left to a wildcard so a new scheme breaks the build (ADR-0031).
        HttpAuthScheme::Other => (
            format!("Sign in to {host}"),
            "The server asked for a kind of sign-in zer0 does not know how to collect.".to_string(),
        ),
    }
}

/// Which Keychain item a credential for this prompt belongs to.
///
/// Deliberately the same origin string [`crate::passwords`] keys a saved login
/// by, so an HTTP-auth credential for `https://staging.example` and a form
/// login for the same origin are one account list rather than two — the same
/// argument ADR-0064 makes about not owning a second index, applied one level
/// up. A proxy has no site to key by and gets `None`.
pub fn keychain_origin(prompt: &AuthPrompt) -> Option<String> {
    (!matches!(prompt.scheme, HttpAuthScheme::Other) && prompt.may_remember)
        .then(|| prompt.origin.clone())
}

#[cfg(test)]
#[path = "http_auth_tests.rs"]
mod tests;
