//! Why a certificate did not check out, and the one case where going on anyway
//! is not a lie.
//!
//! # Naming the fault is the whole point
//!
//! Before this file, every TLS failure in this browser was one category and one
//! sentence: *"It may be expired, or someone may be impersonating the site."*
//! That sentence is a list of guesses. It is also, by ADR-0018's own test, the
//! interface saying something it cannot back up — it does not know which of the
//! two it is, and a person reading it cannot act on either.
//!
//! They are different facts and the difference is exactly what a person can act
//! on. A certificate that ran out last Tuesday on a site you use every day is
//! an administrator who forgot; a certificate for a completely different name is
//! the shape an interception takes; a certificate signed by nobody on
//! `localhost` is the person's own development server, working as intended.
//!
//! So the shell **measures** and this file **decides what the measurements
//! mean** — the [`crate::passwords::ReportedField`] pattern, for the same
//! reason: a judgement made in the shell is a judgement that cannot be tested
//! without a network, and one each platform is free to get differently wrong.
//!
//! Every measurement in [`ReportedCertificate`] was taken from a real
//! `SecTrust` handed over by WebKit, using only public API, against four
//! servers stood up for it:
//!
//! | server | self-signed | reaches an anchor | name matches | dates |
//! | --- | --- | --- | --- | --- |
//! | a real public site | no | **yes** | yes | valid |
//! | self-signed `localhost` | **yes** | no | yes | valid |
//! | self-signed, wrong name | yes | no | **no** | valid |
//! | self-signed, 2020 | yes | no | yes | **expired** |
//! | leaf under a private CA | **no** | **no** | yes | valid |
//!
//! The last row is why "self-signed" and "signed by somebody we do not know"
//! are two faults rather than one: a company's internal CA produces the second
//! and never the first, and telling somebody their corporate certificate is
//! self-signed would be telling them something untrue.
//!
//! # What is deliberately not here
//!
//! **Revocation.** A revoked certificate is a genuinely different fact from
//! everything above and a person could act on it. The trust object WebKit hands
//! over does not carry a revocation verdict that can be read without asking the
//! network again, and this file will not invent a case that never fires: a
//! variant nothing can produce is a branch that reads as covered and is not.
//! Declared debt in ADR-0094 rather than a lie in an enum.

use crate::model::{SpaceId, TabId};

/// One certificate, as the shell measured it. Measurements, never judgements.
///
/// Every field is something the platform's own API answered, not something the
/// shell concluded. `host_matches` looks like a judgement and is not: it is the
/// answer to "does the platform's SSL policy accept this chain for this name,
/// with the dates and the anchor taken out of the question", which only the
/// platform can answer and which no rule in this file could recompute.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct ReportedCertificate {
    /// Lowercase hex SHA-256 of the leaf's DER. What an exception is pinned to.
    pub fingerprint: String,
    /// The leaf's common name, for saying whose certificate arrived. May be
    /// empty; a certificate is not required to have one.
    pub subject: String,
    /// Who signed it. Empty when unreadable.
    pub issuer: String,
    /// The names the certificate covers, as the certificate spells them —
    /// `example.com`, `*.example.com`, an address. Shown when the name is the
    /// thing that is wrong, because "it is for something else" is only useful
    /// with the something else in it.
    pub covers: Vec<String>,
    /// Milliseconds since the epoch. `None` where the field would not parse,
    /// which is a certificate we cannot make a claim about rather than one that
    /// is fine.
    pub not_before_ms: Option<u64>,
    pub not_after_ms: Option<u64>,
    /// The leaf's issuer is its own subject.
    pub self_signed: bool,
    /// The chain reaches a root this machine trusts, with dates pinned inside
    /// the leaf's own window so an expired certificate does not also read as
    /// untrusted.
    pub reaches_trusted_anchor: bool,
    /// The platform's SSL policy accepts the chain for the host that was asked
    /// for.
    pub host_matches: bool,
    pub chain_length: u32,
}

/// One thing that is wrong, named so it can be acted on.
///
/// Closed, and a new fact must break the build until it earns a sentence
/// (ADR-0031). Ordered by how much it tells you: see [`faults`].
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum CertificateFault {
    /// It covers other names, and not this one. The interception shape, and
    /// also what a misconfigured virtual host looks like.
    WrongHost { covers: Vec<String> },
    /// It ran out. `since_ms` is the moment it did, so the screen can say when
    /// rather than that.
    Expired { since_ms: u64 },
    /// Its start date has not arrived. Almost always a clock that is wrong —
    /// this Mac's, usually — and saying so saves somebody an afternoon.
    NotYetValid { until_ms: u64 },
    /// It signed itself. Nobody vouches for it but itself.
    SelfSigned,
    /// Signed by somebody, and not by anybody this machine trusts. A private
    /// CA that was never installed looks exactly like this.
    UnknownIssuer,
    /// The certificate could not be read well enough to say anything else about
    /// it. Distinct from every fault above, because "we could not tell" is not
    /// the same claim as any of them.
    Unreadable,
}

/// Everything wrong with this certificate, most actionable first.
///
/// **All of them, not the first one.** A certificate can easily be both expired
/// and for the wrong name, and a screen that named only one would send somebody
/// to fix the wrong thing and then be surprised again.
///
/// The order is what a person can do something about, not what the checker
/// happened to notice. A wrong name is first because it is the only one of
/// these that a stranger on the network produces on purpose. Dates come next
/// because they are the ones with a fix. `SelfSigned` and `UnknownIssuer` are
/// mutually exclusive by construction — a certificate that signed itself has no
/// other issuer to be unknown — and both are last because on their own they
/// describe an ordinary development setup as accurately as an attack.
pub fn faults(cert: &ReportedCertificate, now_ms: u64) -> Vec<CertificateFault> {
    let mut out = Vec::new();

    if !cert.host_matches {
        out.push(CertificateFault::WrongHost {
            covers: cert.covers.clone(),
        });
    }

    match (cert.not_before_ms, cert.not_after_ms) {
        (Some(before), Some(after)) => {
            if now_ms > after {
                out.push(CertificateFault::Expired { since_ms: after });
            }
            if now_ms < before {
                out.push(CertificateFault::NotYetValid { until_ms: before });
            }
        }
        // A window we could not read is not a window we may call valid.
        _ => out.push(CertificateFault::Unreadable),
    }

    if !cert.reaches_trusted_anchor {
        out.push(if cert.self_signed {
            CertificateFault::SelfSigned
        } else {
            CertificateFault::UnknownIssuer
        });
    }

    // Something rejected it and nothing above explains what. Saying "this is
    // fine" would be worse than admitting the gap, and this is the branch a
    // revoked certificate lands in today (see the module documentation).
    if out.is_empty() {
        out.push(CertificateFault::Unreadable);
    }
    out
}

/// The headline for a screen naming this fault, in the second person.
///
/// One sentence per fault, and each one says what is true rather than what
/// might be. `host` is the address that was asked for.
pub fn headline(fault: &CertificateFault, host: &str) -> String {
    match fault {
        CertificateFault::WrongHost { .. } => {
            format!("This certificate is not for {host}")
        }
        CertificateFault::Expired { .. } => format!("{host}'s certificate has run out"),
        CertificateFault::NotYetValid { .. } => {
            format!("{host}'s certificate is not valid yet")
        }
        CertificateFault::SelfSigned => format!("Nobody vouches for {host}"),
        CertificateFault::UnknownIssuer => format!("{host}'s certificate was signed by a stranger"),
        CertificateFault::Unreadable => format!("{host}'s certificate could not be checked"),
    }
}

/// What that fault means for somebody who has not thought about it.
///
/// Deliberately not a security lecture and deliberately not reassuring. Each
/// one names the two things it could be where there genuinely are two, and one
/// where there is one.
pub fn explanation(fault: &CertificateFault) -> String {
    match fault {
        CertificateFault::WrongHost { covers } if covers.is_empty() => {
            "The certificate this server sent covers a different address. Either the server is \
             misconfigured, or something between this Mac and it answered in its place."
                .to_string()
        }
        CertificateFault::WrongHost { covers } => format!(
            "The certificate this server sent is for {}. Either the server is misconfigured, or \
             something between this Mac and it answered in its place.",
            list(covers)
        ),
        CertificateFault::Expired { .. } => {
            "Certificates run out on purpose, and this one has. Usually that means somebody who \
             runs the site has not renewed it yet."
                .to_string()
        }
        CertificateFault::NotYetValid { .. } => {
            "It does not start being valid until later. That is most often this Mac's own clock \
             being wrong rather than anything about the site."
                .to_string()
        }
        CertificateFault::SelfSigned => {
            "This certificate signed itself, so there is nothing behind it saying the server is \
             who it claims. That is ordinary on a machine somebody is developing on and is not \
             ordinary anywhere else."
                .to_string()
        }
        CertificateFault::UnknownIssuer => {
            "It was signed by an authority this Mac does not know. A company's own internal \
             authority looks like this until it has been installed."
                .to_string()
        }
        CertificateFault::Unreadable => {
            "The connection was refused and zer0 could not establish why from the certificate \
             itself."
                .to_string()
        }
    }
}

/// `a`, `a and b`, `a, b and c`. English rather than a debug list, because it
/// is read in a sentence.
fn list(items: &[String]) -> String {
    match items {
        [] => String::new(),
        [only] => only.clone(),
        [rest @ .., last] => format!("{} and {last}", rest.join(", ")),
    }
}

/// Whether going on anyway may even be offered here.
///
/// **This is the decision in this file, and it is a refusal almost everywhere.**
///
/// Every mainstream browser puts a way through on this screen, and the result
/// is a generation of people who have learned that the certificate warning is a
/// door with an awkward handle. The button is not harmful because it exists; it
/// is harmful because it exists *in the one place a warning is being read*, so
/// pressing it becomes the way to make the warning go away. Once that reflex is
/// built, it fires on the bank too.
///
/// So zer0 offers it in exactly one situation: **the host cannot be reached
/// across a network.** `localhost`, `127.0.0.1`, `::1`, anything under
/// `.localhost`. There, the sentence every other browser has to write —
/// *"someone may be impersonating this site"* — is not merely unlikely, it
/// describes something that cannot happen: there is no network segment between
/// the two ends for anybody to sit on. A self-signed certificate on loopback is
/// a person's own development server and nothing else, and refusing it costs
/// them the ability to use this browser for their job while protecting them
/// from no one.
///
/// Everywhere else the answer is no, **including an internal host on a private
/// network**, and that is the boundary worth being explicit about. `10.x`,
/// `192.168.x` and `staging.corp` all sit on a network somebody else can be on;
/// a wrong certificate there is exactly as likely to be an interception as a
/// misconfiguration, and we cannot tell which. The way through for those exists
/// and it is deliberately not on this screen — Settings › Privacy takes a host
/// and a fingerprint, typed. That is what "proceed anyway must cost something
/// deliberate" buys: the cost is that clicking through the warning is not one
/// of the things you can do while reading it.
///
/// The offer is also pinned to one certificate. See [`TrustExceptions`].
pub fn may_offer_certificate_exception(host: &str, cert: &ReportedCertificate) -> bool {
    if !crate::http_auth::is_loopback(host) {
        return false;
    }
    // Even on loopback, a certificate we could not read is not one to wave
    // through: the fingerprint is what the exception is pinned to, and without
    // one there is nothing to pin.
    !cert.fingerprint.is_empty()
}

/// Why the way through is not on this screen, for the screen to say.
///
/// Said out loud rather than left as an absent button. A screen that simply has
/// no way forward reads as a browser that cannot do something; this one has
/// decided not to, and saying so is the difference between a limitation and a
/// position (ADR-0018).
///
/// **It deliberately does not point anywhere.** The first version of this
/// sentence ended "Settings › Privacy takes the address and its fingerprint",
/// which is where that door is going and is not where it is: no such control
/// exists yet. A security screen naming a way out that is not there is the
/// find bar's invented match count wearing a padlock — and it is worse than
/// the others of its kind, because somebody would go looking. The sentence
/// says what is true today and gains the pointer on the day the pane does.
pub fn no_exception_note(host: &str) -> String {
    format!(
        "zer0 has no button here that loads {host} anyway. On a network somebody else can be on, \
         a wrong certificate and an interception look identical, and a button that made the \
         warning go away would be the one you press without reading it. Fixing the certificate, \
         or trusting its authority on this Mac, is the way in."
    )
}

/// One space's answer to "this certificate is not the certificate".
///
/// Keyed by the exact certificate, not by the host. That is the whole of why
/// this is safe to have at all: an exception made for the self-signed
/// certificate on a development box does **not** cover a different certificate
/// arriving from that host tomorrow, which is precisely the shape an
/// interception takes. A host-keyed exception turns one deliberate decision into
/// a standing invitation.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TrustException {
    pub space: SpaceId,
    /// Canonical origin, as `canonical_origin` spells it.
    pub origin: String,
    /// Lowercase hex SHA-256 of the leaf certificate's DER.
    pub fingerprint: String,
}

/// Everything somebody has waved through this session, and nothing more.
///
/// **Never written to disk, and that is the decision rather than an omission.**
/// A stored exception is a hole in the browser's own guarantee that outlives
/// every memory of making it: months later the development box has been
/// rebuilt, the certificate on it belongs to somebody else, and nothing on any
/// screen says the browser stopped checking that host. Kept in memory it costs
/// a developer one click per launch, and it cannot rot.
///
/// Per space for the reason ADR-0056 gives about a camera: a space is an
/// identity, and closing one takes everything it decided with it.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct TrustExceptions {
    granted: Vec<TrustException>,
}

impl TrustExceptions {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn all(&self) -> &[TrustException] {
        &self.granted
    }

    pub fn holds(&self, space: SpaceId, origin: &str, fingerprint: &str) -> bool {
        self.granted
            .iter()
            .any(|e| e.space == space && e.origin == origin && e.fingerprint == fingerprint)
    }

    pub(crate) fn record(&mut self, space: SpaceId, origin: &str, fingerprint: &str) {
        if fingerprint.is_empty() || self.holds(space, origin, fingerprint) {
            return;
        }
        self.granted.push(TrustException {
            space,
            origin: origin.to_string(),
            fingerprint: fingerprint.to_string(),
        });
    }

    /// The space is gone and its cookie jar with it. An exception that outlived
    /// the identity that made it is one nobody can find (ADR-0007).
    pub fn forget_space(&mut self, space: SpaceId) {
        self.granted.retain(|e| e.space != space);
    }
}

/// A rejected certificate exactly as the engine and the shell reported it.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct ServerTrustRequest {
    /// The host's handle for the completion handler it is holding.
    pub request: u64,
    pub tab: TabId,
    /// The protection space's host, uninterpreted.
    pub host: String,
    pub port: u32,
    pub certificate: ReportedCertificate,
}

/// What the engine is told about a certificate.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum TrustDecision {
    /// Somebody already said yes to this exact certificate in this space.
    Proceed,
    /// Fail the navigation. The screen ADR-0016 built then explains it.
    Refuse,
}

/// What a screen needs to explain one rejected certificate.
///
/// Held against the tab rather than being rebuilt when the failure lands,
/// because by then the certificate is gone: `-1202` arrives after the trust
/// challenge has been answered and carries no chain anybody has measured.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct CertificateReport {
    pub host: String,
    /// The origin an exception for this certificate is keyed by.
    ///
    /// Supplied here rather than rebuilt by whatever draws the screen, because
    /// the reducer keys the exception by this exact string and a second
    /// spelling assembled in the shell would be free to disagree — an
    /// internationalised host especially, where one side punycodes and the
    /// other does not. The failure is silent and looks like "the exception did
    /// not take". This is the one door, and it is the same one
    /// `canonical_origin` opens for every other per-origin decision here.
    pub origin: String,
    pub certificate: ReportedCertificate,
    /// Everything wrong with it, most actionable first.
    pub faults: Vec<CertificateFault>,
    /// The headline for the first fault — the one the screen leads with.
    pub headline: String,
    /// Its explanation.
    pub explanation: String,
    /// The other faults' headlines, so a certificate that is wrong twice says
    /// so rather than sending somebody to fix half of it.
    pub also: Vec<String>,
    /// Whether this screen may offer a way through at all.
    pub may_proceed: bool,
    /// Said when it may not. Empty when it may.
    pub no_proceed_note: String,
}

/// The origin a certificate on this host and port is keyed by.
///
/// The one spelling, used by the report the screen offers and by the ledger the
/// reducer stores into, so the two cannot disagree. Always `https`: a trust
/// challenge cannot arrive on anything else.
pub fn certificate_origin(host: &str, port: u32) -> String {
    crate::site_permissions::canonical_origin(&crate::site_permissions::ReportedOrigin {
        scheme: "https".to_string(),
        host: host.to_string(),
        port,
    })
    .unwrap_or_default()
}

/// Everything a screen needs, decided in one place.
pub fn certificate_report(
    host: &str,
    port: u32,
    certificate: &ReportedCertificate,
    now_ms: u64,
) -> CertificateReport {
    let faults = faults(certificate, now_ms);
    // `faults` never returns empty — it falls back to `Unreadable` — so the
    // lead is always there. Spelled with a fallback anyway rather than an
    // index, because a panic on a security screen is the worst possible way to
    // find out that invariant moved.
    let lead = faults
        .first()
        .cloned()
        .unwrap_or(CertificateFault::Unreadable);
    let may_proceed = may_offer_certificate_exception(host, certificate);

    CertificateReport {
        host: host.to_string(),
        origin: certificate_origin(host, port),
        certificate: certificate.clone(),
        headline: headline(&lead, host),
        explanation: explanation(&lead),
        also: faults
            .iter()
            .skip(1)
            .map(|fault| headline(fault, host))
            .collect(),
        faults,
        may_proceed,
        no_proceed_note: if may_proceed {
            String::new()
        } else {
            no_exception_note(host)
        },
    }
}

#[cfg(test)]
#[path = "certificates_tests.rs"]
mod tests;
