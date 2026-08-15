//! Which saved login may be put into which field, and which may be written down.
//!
//! # What is not here
//!
//! **A password.** No type in this module has a field a password fits in, and
//! no function here takes one or returns one. That is the same guarantee
//! ADR-0048 made for API keys, extended to the other kind of secret: the value
//! lives in the Keychain, reached only from `SecretStore.swift` in the shell,
//! and the core decides *which* item to reach for by name. A credential cannot
//! reach a log line, a config file or `session.sqlite` from here, because there
//! is nothing here that can hold one.
//!
//! **An index of who you have accounts with.** The Keychain is the store, and
//! an internet-password item is already keyed by server, port, protocol and
//! account. Copying that index into `session.sqlite` would put a plaintext list
//! of every site you have a login on into a file this project already treats as
//! readable by anyone holding the disk (ADR-0023 makes that argument about
//! history; it is the same argument). So there is no second store to keep in
//! step, and nothing to filter out on the way to disk, because nothing is
//! written.
//!
//! # What is here
//!
//! The refusals. Every function in this file exists to say no to something, and
//! the yes is what is left over.
//!
//! - An origin is matched **exactly** — scheme, host and port. Not by suffix.
//!   See [`matches`] for why a subdomain rule would be wrong here even though
//!   ADR-0026 is right to use one for routing.
//! - A field that cannot be seen gets nothing ([`usable`]). This is the attack
//!   the whole feature has to survive: a form that is one pixel tall, or drawn
//!   at `left: -9999px`, or at `opacity: 0`, or underneath something else, is
//!   how a page harvests an autofill it was never offered.
//! - A frame whose origin is not the origin in the address bar gets nothing.
//! - An ephemeral space writes nothing down (ADR-0023).
//!
//! # Why nothing here is automatic
//!
//! **A page can get [`fill_verdict`] called. It cannot get anything filled.**
//! That distinction is the design, and stating it the other way round would be
//! a lie: `focusin` on a password field is what makes the shell ask, and a page
//! can call `field.focus()` itself, so the caret is *not* a trusted gesture.
//!
//! What a page gets for doing that is a list of usernames written into Swift
//! state that never goes back into the document. Nothing is put into the page
//! until somebody picks an entry out of zer0's own interface, and that path
//! does not start at the message channel — there is no message a page can post
//! that reaches it, and the entry point that fills lives in a content world the
//! page world cannot see.
//!
//! So the guarantee is not "a page cannot make us look". It is "a page cannot
//! make us fill", and [`usable`] is the second, independent condition on the
//! moment we do. It is here rather than in the shell precisely because it must
//! be re-checked against the geometry the shell measured rather than trusted
//! from a boolean the page could shape.

use crate::site_permissions::{ReportedOrigin, canonical_origin};

/// Narrower than a person would draw it, and deliberately so: this is not "is
/// the field big enough to use", it is "is the field too small to be real".
/// A login field on a phone-width layout is comfortably past both.
const MIN_WIDTH: f64 = 24.0;

/// Smaller than any font a value could be typed into.
const MIN_HEIGHT: f64 = 8.0;

/// Not `1.0`. A real form fades in, and a fill landing mid-animation is
/// ordinary; the shape being refused is `opacity: 0`, which is invisible and
/// stays that way.
const MIN_OPACITY: f64 = 0.1;

/// One field of a login form, as the shell measured it.
///
/// Deliberately geometry and flags rather than a single `visible: bool`. The
/// shell can measure; deciding what the measurements *mean* is behaviour, and
/// behaviour is testable only if it is here. A boolean would move the decision
/// into JavaScript running in the page's own document, which is the one place
/// it must not be.
#[derive(Debug, Clone, PartialEq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct ReportedField {
    pub width: f64,
    pub height: f64,
    /// The element's effective opacity, with its ancestors' multiplied in.
    pub opacity: f64,
    /// Top-left of the field, in viewport coordinates. Negative is off-screen
    /// to the left or above, which is where a harvesting form is usually put.
    pub x: f64,
    pub y: f64,
    pub viewport_width: f64,
    pub viewport_height: f64,
    pub disabled: bool,
    pub readonly: bool,
    /// `document.elementFromPoint` at the field's centre came back as this
    /// field. `false` when something is drawn over it — the clickjacking shape,
    /// where the person believes they are typing somewhere else.
    pub topmost: bool,
}

/// A login form, as the shell found it.
#[derive(Debug, Clone, PartialEq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct ReportedForm {
    /// The origin in the address bar — what the person believes they are on.
    pub page: ReportedOrigin,
    /// The origin of the document the form is actually in. Equal to `page` for
    /// an ordinary login form; different inside a cross-origin iframe.
    pub form: ReportedOrigin,
    pub username: Option<ReportedField>,
    pub password: ReportedField,
}

/// Why nothing was offered, or nothing was written down.
///
/// Every one of these is a refusal a person may have to be told about, so each
/// carries enough to say which of the two origins was the problem rather than
/// only that there was one.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum Refusal {
    /// Not a shape an origin can be spelled in: a `file://` page, a `data:`
    /// URL, a sandboxed frame, a scheme the web does not put logins on.
    NotAnOrigin,
    /// Unencrypted, and not loopback. A password put into an `http://` form
    /// goes out in the clear, and filling it would be zer0 doing that rather
    /// than the person.
    Insecure { origin: String },
    /// The form is in a frame belonging to somebody other than the site named
    /// in the address bar.
    CrossOrigin { page: String, form: String },
    /// The field cannot be seen, or cannot be typed into.
    UnusableField,
    /// The space promised to leave nothing behind (ADR-0023).
    Ephemeral,
}

/// What may be put into this form.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum FillVerdict {
    /// A saved login for exactly this origin may be filled in.
    Fill {
        origin: String,
    },
    Refuse {
        because: Refusal,
    },
}

/// Whether what was just typed may be written down.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum SaveVerdict {
    Save { origin: String },
    Refuse { because: Refusal },
}

/// One saved login, without the password.
///
/// This is the whole of what crosses into the interface to draw a list. The
/// value stays in the Keychain until the moment it is filled, which is the
/// same shape `SecretStore.names()` already has and for the same reason: a list
/// of accounts is a question about presence, and answering it by reading every
/// password would put all of them in memory to draw a menu.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct SavedLogin {
    /// Canonical, as [`canonical_origin`] spells it.
    pub origin: String,
    pub username: String,
}

/// Whether a saved login belongs to this page.
///
/// **Exact equality, and this is the decision in the file most likely to be
/// "improved".** ADR-0026 matches a routing rule against a host *or any
/// subdomain of it*, and that is right there: sending `gist.github.com` to the
/// same space as `github.com` is what somebody writing the rule meant.
///
/// It is wrong here, and the reason is that a routing mistake opens a tab in
/// the wrong space while a credential mistake hands a password to somebody
/// else. Subdomain matching needs a public suffix list to be safe at all —
/// without one, a rule for `github.io` matches `anybody.github.io`, and
/// `s3.amazonaws.com`, `blogspot.com` and every other host where strangers get
/// a subdomain behave the same way. zer0 does not ship a public suffix list,
/// so the honest boundary is the exact origin.
///
/// The scheme and port are in the key too. `http://example.com` and
/// `https://example.com` are different origins to the web, and treating them
/// as one would let a downgrade collect a password saved for the secure one.
pub fn matches(candidate: &str, page_origin: &str) -> bool {
    candidate == page_origin
}

/// Every saved login that may be offered on this page, in a stable order.
///
/// Filtering happens here rather than in the interface for the reason ADR-0023
/// gives about history: a rule applied at the read has to be applied at every
/// read, forever, and the failure is silent when a second surface forgets. This
/// is the one door.
pub fn offerable(page_origin: &str, candidates: &[SavedLogin]) -> Vec<SavedLogin> {
    let mut offers: Vec<SavedLogin> = candidates
        .iter()
        .filter(|c| matches(&c.origin, page_origin))
        .cloned()
        .collect();
    // By username, so the list does not reorder itself between two openings of
    // the same menu. Keychain query order is not specified.
    offers.sort_by(|a, b| a.username.cmp(&b.username));
    offers.dedup();
    offers
}

/// Whether a field is real enough to put a password into.
///
/// Every clause here is one shape of the same attack: a form the person cannot
/// see, filled by a browser that was not looking, read back by the page. They
/// are separate clauses rather than one heuristic because each is separately
/// sufficient, and a heuristic that scored them together would let two of them
/// pass by being individually mild.
pub fn usable(field: &ReportedField) -> bool {
    // Typed into, and submitted. A disabled field is neither; a readonly field
    // is not typed into, and filling one writes a value the person cannot then
    // correct.
    if field.disabled || field.readonly {
        return false;
    }
    if field.width < MIN_WIDTH || field.height < MIN_HEIGHT {
        return false;
    }
    // NaN is spelled out rather than left to `<`. A computed style can produce
    // one, and `NaN < MIN_OPACITY` is `false`, so a plain comparison would let
    // the one value nobody can see through.
    if field.opacity.is_nan() || field.opacity < MIN_OPACITY {
        return false;
    }
    if !field.topmost {
        return false;
    }
    // Intersects the viewport at all. `left: -9999px` is the textbook
    // placement, and it fails here rather than on the size check because the
    // field is otherwise ordinary.
    let on_screen = field.x + field.width > 0.0
        && field.y + field.height > 0.0
        && field.x < field.viewport_width
        && field.y < field.viewport_height;
    if !on_screen {
        return false;
    }
    true
}

/// Whether an origin may carry a password at all.
///
/// `http` is refused except on loopback, where there is no network to watch and
/// where anybody building a login form actually works.
fn secure_enough(origin: &ReportedOrigin) -> bool {
    if origin.scheme.eq_ignore_ascii_case("https") {
        return true;
    }
    if !origin.scheme.eq_ignore_ascii_case("http") {
        return false;
    }
    let host = origin.host.to_ascii_lowercase();
    host == "localhost"
        || host.ends_with(".localhost")
        || host == "127.0.0.1"
        || host == "[::1]"
        || host == "::1"
}

/// The two checks both verdicts start with: the form is on a real, encrypted
/// origin, and that origin is the one in the address bar.
///
/// Returns the canonical origin to key by, or the refusal.
///
/// **Keyed by the frame's own origin, and refused when that is not the page's.**
/// A credential offered for a site other than the one the address bar names is
/// the exact confusion phishing is built out of, and it stays confusing when
/// the frame is genuine. Refusing costs a real thing — a site that puts its
/// sign-in on a separate origin in an iframe will not fill — and that cost is
/// booked in the ADR rather than traded away here.
fn origin_to_key_by(form: &ReportedForm) -> Result<String, Refusal> {
    let page = canonical_origin(&form.page).ok_or(Refusal::NotAnOrigin)?;
    let frame = canonical_origin(&form.form).ok_or(Refusal::NotAnOrigin)?;

    if !secure_enough(&form.form) {
        return Err(Refusal::Insecure { origin: frame });
    }
    if page != frame {
        return Err(Refusal::CrossOrigin { page, form: frame });
    }
    Ok(frame)
}

/// What may be filled into this form.
///
/// Called when somebody put the caret in a login field or chose an entry from
/// zer0's own list — **never** in response to anything the page did. See the
/// module documentation for why that is the load-bearing half of the defence
/// and [`usable`] for the half that does not depend on it.
pub fn fill_verdict(form: &ReportedForm) -> FillVerdict {
    let origin = match origin_to_key_by(form) {
        Ok(origin) => origin,
        Err(because) => return FillVerdict::Refuse { because },
    };

    // The password field is the one that must be usable. A username field that
    // is hidden is ordinary — plenty of sites collect the username on a
    // previous screen and keep it in a hidden input — but if one is present and
    // unusable, nothing goes into it either. That is handled by the shell
    // filling only what it was told; here the question is whether the form as a
    // whole may be filled, and that turns on the password field.
    if !usable(&form.password) {
        return FillVerdict::Refuse {
            because: Refusal::UnusableField,
        };
    }

    FillVerdict::Fill { origin }
}

/// Whether what was typed into this form may be written down.
///
/// `space_records_to_disk` comes from `Browser::records_to_disk`, which is the
/// helper ADR-0023 named as the debt it left behind — the ephemeral branch
/// spelled out independently at every writer. This is a writer, and it asks the
/// question through that door rather than reading `profile.ephemeral` itself.
pub fn save_verdict(form: &ReportedForm, space_records_to_disk: bool) -> SaveVerdict {
    // Asked first, and before the origin is even canonicalised. An ephemeral
    // space refuses for a reason that has nothing to do with the page, and
    // reporting the page's problem instead would be answering a question
    // nobody asked.
    if !space_records_to_disk {
        return SaveVerdict::Refuse {
            because: Refusal::Ephemeral,
        };
    }

    let origin = match origin_to_key_by(form) {
        Ok(origin) => origin,
        Err(because) => return SaveVerdict::Refuse { because },
    };

    // Deliberately *not* gated on `usable`. Saving records something the person
    // typed themselves, so a field that shrank, scrolled off or got covered
    // between the typing and the submit is not a reason to lose the password —
    // and none of the shapes `usable` refuses can steal anything on the way
    // out, because nothing is being put into the page.
    SaveVerdict::Save { origin }
}

/// The Keychain item's security domain, which is what makes two Spaces two
/// logins.
///
/// A Space is a cookie jar and a cookie jar is an identity (ADR-0007), so
/// `github.com` in Work and `github.com` in Personal are two different accounts
/// and must be two different items. `kSecAttrSecurityDomain` is part of an
/// internet-password item's identity on macOS, so putting the Space's
/// `data_store_id` there makes "two Spaces cannot collide" a property of the
/// platform's own uniqueness rule rather than of a convention this code keeps.
///
/// `None` for a space that records nothing, and that is the structural half of
/// the ephemeral promise: without this string the shell cannot build a Keychain
/// query at all, and there is no other value it could reasonably substitute.
pub fn keychain_scope(data_store_id: &str, space_records_to_disk: bool) -> Option<String> {
    if !space_records_to_disk {
        return None;
    }
    let trimmed = data_store_id.trim();
    if trimmed.is_empty() {
        return None;
    }
    Some(format!("zer0.space.{trimmed}"))
}

/// A canonical origin, taken apart into the attributes a Keychain item is keyed
/// by.
///
/// An internet-password item is already keyed by server, port and protocol, so
/// the Keychain *is* the index and there is no second one to keep in step. What
/// it needs is those three as separate values.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct KeychainFields {
    /// Lowercased, and only ever `https` or `http`.
    pub scheme: String,
    /// Punycode for an internationalised domain, because that is the spelling
    /// the origin was canonicalised to and the two must not drift.
    pub host: String,
    /// Resolved, never `0`: the Keychain has no "whatever the default is".
    pub port: u32,
}

/// Take a canonical origin back apart.
///
/// In the core rather than in the shell because it is the inverse of
/// [`canonical_origin`], and a second parser written in Swift would be free to
/// disagree with it — which would show up as a password saved under one key and
/// looked for under another. That exact bug is recorded in `SecretStore.swift`,
/// where two Keychain implementations under different service names meant a key
/// stored successfully and never found again.
///
/// Takes the origin the core itself produced, so anything it cannot read is a
/// programming error rather than hostile input, and `None` is the honest answer
/// rather than a guess.
pub fn keychain_fields(origin: &str) -> Option<KeychainFields> {
    let parsed = url::Url::parse(origin).ok()?;
    let scheme = parsed.scheme().to_ascii_lowercase();
    let default_port = match scheme.as_str() {
        "https" => 443,
        "http" => 80,
        _ => return None,
    };
    let host = parsed.host_str()?;
    if host.is_empty() {
        return None;
    }
    Some(KeychainFields {
        scheme,
        host: host.to_string(),
        port: u32::from(parsed.port().unwrap_or(default_port)),
    })
}

#[cfg(test)]
#[path = "passwords_tests.rs"]
mod tests;
