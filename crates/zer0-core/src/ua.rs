//! The User-Agent this browser announces, composed from host-supplied facts.
//!
//! Composition is behaviour: two platforms could not reasonably disagree
//! about the order of the tokens or which context carries Chrome, so the rule
//! lives here and a host supplies only what only it can read — the versions on
//! the machine it is running on. The strings themselves are ADR-0008's and
//! ADR-0106's, unchanged; this module is where they are spelled, not what they
//! say (ADR-0119).

/// Chrome's product token, carried by extension contexts only (ADR-0106).
///
/// Sites and extensions that sniff for `Chrome/` to gate features see it and
/// take the path that calls `connectNative` / `chrome.runtime.connect`, which
/// is the path Chrome-marketplace extensions expect. The version is a recent
/// stable rather than read from a bundle: there is no Chrome on the machine to
/// read, and the shape — `<major>.0.0.0` — is what matters to sniffers, not
/// the build number. Same shape ADR-0008 uses for its `"18.3"` Safari
/// fallback.
///
/// Deliberately not the far-ahead `CHROME_VERSION_FOR_DOWNLOADS` from
/// ADR-0078, though the two are easy to mistake for one rule. That number is
/// chosen against an endpoint that enforces a floor and no ceiling, where too
/// low costs the extension and too high costs nothing. This one is read by an
/// extension deciding which code path to take, where a version no Chrome has
/// reached would be a stranger claim than a stale one. Each rots on its own
/// schedule and each is bumped by editing its own literal.
pub const CHROME_MARKETPLACE_TOKEN: &str = "Chrome/138.0.0.0";

/// The Safari version carried when the installed copy cannot be read.
///
/// A recent-enough Safari for anything that checks a minimum version. It rots
/// rather than ages, and ADR-0008 owns that trade.
const SAFARI_FALLBACK_VERSION: &str = "18.3";

/// The fixed half of the Safari signature. What the sniffers look for, and
/// stable across Safari versions in a way the number in front of it is not.
const SAFARI_SUFFIX: &str = "Safari/605.1.15";

/// What `zer0/` says when the host names no version of its own.
const ZER0_FALLBACK_VERSION: &str = "0.1.0";

/// Which population a User-Agent is about to be read by.
///
/// The one distinction the composition needs: pages the person visits are
/// told which engine renders them and who we are, and nothing else (ADR-0073);
/// extension contexts additionally hear Chrome's name, because the alternative
/// is the extension not loading (ADR-0106).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum UserAgentContext {
    /// A page the person navigated to.
    Browsing,
    /// A web extension's background worker, popup or options page.
    WebExtension,
}

/// The User-Agent one context announces.
///
/// The host hands in the two facts only it can read — the installed Safari's
/// version and this app's own — and everything else is decided here: the
/// order, the fallbacks, the fixed `Safari/605.1.15` suffix, and whether
/// Chrome's token appears at all.
///
/// `zer0/` comes **after** `Safari/`, the way Edge appends `Edg/` and Vivaldi
/// appends `Vivaldi/`; putting our name first, or in place of Safari's, is
/// what breaks the sniffing ADR-0008 exists to satisfy. In extension contexts
/// Chrome sits between the two — the shape Brave uses, not Edge's, because the
/// extensions that sniff do so with `indexOf("Chrome")` and never look past
/// it.
pub fn user_agent(
    safari_version: Option<&str>,
    own_version: Option<&str>,
    context: UserAgentContext,
) -> String {
    let safari = format!(
        "Version/{} {SAFARI_SUFFIX}",
        safari_version.unwrap_or(SAFARI_FALLBACK_VERSION)
    );
    let own = format!("zer0/{}", own_version.unwrap_or(ZER0_FALLBACK_VERSION));
    match context {
        UserAgentContext::Browsing => format!("{safari} {own}"),
        UserAgentContext::WebExtension => format!("{safari} {CHROME_MARKETPLACE_TOKEN} {own}"),
    }
}

#[cfg(test)]
#[path = "ua_tests.rs"]
mod tests;
