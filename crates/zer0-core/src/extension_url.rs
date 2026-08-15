//! The address space an extension's own pages live in.
//!
//! This is the mirror of [`crate::internal_url`], and the two must not be
//! confused with each other. `zer0://` is **ours**, WebKit is never told it
//! exists, and every question about it is answered by that absence (ADR-0054).
//! `webkit-extension://` is **WebKit's**: the engine mints the host, owns every
//! page under it, and refuses to load one anywhere but in the context it
//! belongs to. There is nothing here to implement and nothing to route. The
//! whole job is to stop mangling it.
//!
//! ## The host is not an extension id
//!
//! `webkit-extension://142b180d-…/app/app.html` — that uuid is minted by WebKit
//! per loaded context, not by whoever installed the package, and it is a
//! different uuid on the next launch. So nothing here maps a host to an
//! extension: the core carries the host it was given, and the shell — the only
//! side that knows which contexts exist — resolves it or refuses it. An address
//! naming a context nothing loaded is refused rather than attributed to
//! whichever extension happens to be at hand.

use url::Url;

/// The scheme WebKit gives an extension's own pages.
///
/// Spelled once. Everything that asks "is this an extension's page" asks here,
/// so the shell and the core cannot drift into two ideas of what one is — the
/// same reason `HostedWebView.isInternal` asks the core rather than comparing a
/// string of its own.
pub const SCHEME: &str = "webkit-extension";

/// Whether this text claims the scheme, whatever else is wrong with it.
///
/// Deliberately not "is this a valid extension address": claiming the scheme is
/// enough to know it is not a web search, and an address that claims it and
/// names nothing is refused as an extension's rather than handed to a search
/// engine.
pub fn claims_scheme(input: &str) -> bool {
    Url::parse(input.trim()).is_ok_and(|u| u.scheme() == SCHEME)
}

/// Which context this address belongs to, as WebKit's own host.
///
/// `None` for anything that is not an extension address, and for one that
/// claims the scheme without naming a host — `webkit-extension:///x` is not an
/// address to any extension, and guessing which one it meant is the repair that
/// hides a bug.
pub fn base_host(input: &str) -> Option<String> {
    let parsed = Url::parse(input.trim()).ok()?;
    if parsed.scheme() != SCHEME {
        return None;
    }
    let host = parsed.host_str()?;
    (!host.is_empty()).then(|| host.to_string())
}

// MARK: - Across the FFI
//
// Free functions, for the reason `internal_url`'s are: a shell that spelled
// `"webkit-extension"` out for itself would be a second opinion about what an
// extension's address is, and the half that is wrong is always the half on
// screen.

/// Which context this address belongs to. `None` is "not an extension's, or
/// not one that names a context".
#[cfg(feature = "ffi")]
#[uniffi::export]
pub fn extension_base_host(url: String) -> Option<String> {
    base_host(&url)
}

#[cfg(test)]
mod tests {
    use super::*;

    const PAGE: &str = "webkit-extension://142b180d-a643-4516-9b24-1cc01d08d781/app/app.html";

    #[test]
    fn an_extension_page_is_recognised_and_names_its_context() {
        assert!(claims_scheme(PAGE));
        assert_eq!(
            base_host(&format!("{PAGE}#/page/welcome")).as_deref(),
            Some("142b180d-a643-4516-9b24-1cc01d08d781")
        );
    }

    #[test]
    fn nothing_else_claims_the_scheme() {
        for other in [
            "https://example.com",
            "zer0://settings",
            "chrome-extension://abc/page.html",
            "webkit-extensions://abc/page.html",
            "not a url at all",
            "",
        ] {
            assert!(!claims_scheme(other), "{other} was read as an extension's");
            assert_eq!(base_host(other), None, "{other} named a context");
        }
    }

    /// Two pages of one extension are one context; two extensions are two.
    /// This is the comparison the reducer swaps a view on, so it is the one
    /// worth asserting directly.
    #[test]
    fn the_host_is_what_tells_two_extensions_apart() {
        let a = "webkit-extension://aaaa/app.html";
        let b = "webkit-extension://aaaa/options.html#/deep";
        let c = "webkit-extension://bbbb/app.html";
        assert_eq!(base_host(a), base_host(b));
        assert_ne!(base_host(a), base_host(c));
    }

    /// An address that claims the scheme and names no context is refused rather
    /// than repaired into the extension that happens to be loaded.
    #[test]
    fn an_address_naming_no_context_is_not_repaired_into_one() {
        assert!(claims_scheme("webkit-extension:///app.html"));
        assert_eq!(base_host("webkit-extension:///app.html"), None);
    }

    #[test]
    fn surrounding_whitespace_is_ignored() {
        assert!(claims_scheme(&format!("  {PAGE}  ")));
        assert_eq!(
            base_host(&format!("  {PAGE}  ")).as_deref(),
            Some("142b180d-a643-4516-9b24-1cc01d08d781")
        );
    }
}
