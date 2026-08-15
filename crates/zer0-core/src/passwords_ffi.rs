//! The password surface, as the shell reaches it.
//!
//! Split out of `ffi.rs` the way `mcp_ffi.rs` is: same object, same lock, one
//! more `impl` block. The free functions below are the pure half and take no
//! lock at all — they are here rather than in `passwords.rs` only because
//! uniffi wants owned arguments and the core should not grow a second set of
//! signatures to satisfy a binding generator.
//!
//! **Nothing here takes or returns a password.** Everything crossing this seam
//! is a *decision* — an origin to key by, a refusal to explain, a list of
//! usernames. The value moves Keychain → `WKWebView` entirely inside the shell,
//! so the guarantee ADR-0048 made for API keys holds here unchanged: the core
//! has no call a credential fits through.

use crate::ffi::Zer0;
use crate::model::SpaceId;
use crate::passwords::{
    FillVerdict, KeychainFields, ReportedForm, SaveVerdict, SavedLogin, fill_verdict,
    keychain_fields, keychain_scope, offerable, save_verdict,
};

/// A canonical origin, taken apart into the attributes a Keychain item is keyed
/// by. `None` for anything that is not one of ours.
#[uniffi::export]
pub fn password_keychain_fields(origin: String) -> Option<KeychainFields> {
    keychain_fields(&origin)
}

/// What may be filled into this form.
///
/// Called from the shell's own gesture handling — a caret landing in a login
/// field, or somebody choosing an entry from zer0's list — and never from the
/// message channel a page can post to. See the module docs on `passwords.rs`
/// for why that is the load-bearing half of the defence.
#[uniffi::export]
pub fn password_fill_verdict(form: ReportedForm) -> FillVerdict {
    fill_verdict(&form)
}

/// Which saved logins may be shown for this page.
///
/// The candidates come from the Keychain, already narrowed to one space by the
/// query. This filters again by origin, because a Keychain query matches on
/// attributes the shell assembled and this is the one place that decision is
/// tested.
#[uniffi::export]
pub fn passwords_offerable(page_origin: String, candidates: Vec<SavedLogin>) -> Vec<SavedLogin> {
    offerable(&page_origin, &candidates)
}

#[uniffi::export]
impl Zer0 {
    /// Whether what was typed into this form may be written down, in this space.
    ///
    /// The space is looked up here rather than passed as a boolean so the
    /// ephemeral question is asked through `Browser::records_to_disk` — the
    /// helper ADR-0023 named as the debt it left behind. A shell that answered
    /// it itself would be the fourth independent spelling of that branch.
    pub fn password_save_verdict(&self, space: SpaceId, form: ReportedForm) -> SaveVerdict {
        let records = self.lock().session.browser.records_to_disk(space);
        save_verdict(&form, records)
    }

    /// The Keychain security domain for this space's logins, or `None` when the
    /// space records nothing.
    ///
    /// `None` is not an error to report; it is the ephemeral promise arriving
    /// as an absence. Without this string the shell has no query to build, and
    /// there is no other value it could reasonably substitute — which is what
    /// makes "a private space saves no password" structural rather than a rule
    /// somebody remembers.
    pub fn password_keychain_scope(&self, space: SpaceId) -> Option<String> {
        let state = self.lock();
        let records = state.session.browser.records_to_disk(space);
        let data_store_id = state.session.browser.space(space)?.data_store_id.clone();
        drop(state);
        keychain_scope(&data_store_id, records)
    }
}

/// Which Keychain item a credential collected on an HTTP-auth panel belongs to,
/// or `None` when it must not be written down at all.
///
/// Here rather than in the shell so there is one answer, and deliberately the
/// same origin string a form login is keyed by: an HTTP-auth sign-in and a form
/// login for one origin are one account list rather than two. `None` covers a
/// proxy, an unencrypted origin off loopback, and a space that promised to
/// leave nothing behind — three refusals the panel must not work out for itself.
#[uniffi::export]
pub fn auth_keychain_origin(prompt: crate::http_auth::AuthPrompt) -> Option<String> {
    crate::http_auth::keychain_origin(&prompt)
}

/// Everything a screen needs to explain one rejected certificate.
///
/// Exported so the shell can turn a measured chain into words without owning
/// any of the decisions in it — which fault leads, whether there are others,
/// and whether a way through may be offered at all.
#[uniffi::export]
pub fn certificate_report(
    host: String,
    port: u32,
    certificate: crate::certificates::ReportedCertificate,
    now_ms: u64,
) -> crate::certificates::CertificateReport {
    crate::certificates::certificate_report(&host, port, &certificate, now_ms)
}
