//! Addresses this browser hands to another application.
//!
//! A page can put any scheme in a link. Most of them are the engine's business
//! and a few are nobody's, but a small set name something the *system* owns —
//! a mail client, the phone, a calendar — and following one of those means
//! starting another program on somebody's behalf with an argument a page wrote.
//!
//! That is an outward-facing act, so the list of schemes it may happen for is a
//! decision rather than a lookup, and it lives here where a test can read it.
//! Whether anything on the machine actually answers is the host's question, not
//! this one's: two platforms could not reasonably disagree about whether
//! `mailto:` is handed over, and they could not agree about what opens it.

use url::Url;

/// The schemes handed to whatever the system registered for them.
///
/// Every one of them names a **conversation**: a message, a call, an
/// appointment. The address is the whole payload — there is no argument list
/// and no file path in any of them — so the worst a page can do with one is
/// open a compose window addressed to somebody.
///
/// Deliberately short. `slack:`, `zoommtg:`, `vscode:` and every other
/// application scheme are left off, not because they are not wanted but because
/// handing one over starts a program a page named, and the only honest gate for
/// that is a person reading which program it is before it happens. That is a
/// sheet nobody has drawn yet. See ADR-0092.
const HANDED_TO_THE_SYSTEM: [&str; 7] = [
    "mailto",
    "tel",
    "sms",
    "facetime",
    "facetime-audio",
    "webcal",
    "maps",
];

/// Whether this address may be handed to whatever application the system
/// registered for its scheme.
///
/// **Never one of ours.** `zer0` is not on the list above, and the explicit
/// refusal below is the second lock on the same thing: ADR-0054's whole
/// security answer is that our scheme reaches nothing outside the core, and a
/// list somebody extends is a worse guarantee than a sentence that says no.
///
/// Anything that does not parse as a URL is refused. A string we could not read
/// the scheme of is not a string to hand to `NSWorkspace`.
pub fn may_hand_to_the_system(url: &str) -> bool {
    if crate::internal_url::claims_scheme(url) {
        return false;
    }

    let Ok(parsed) = Url::parse(url.trim()) else {
        return false;
    };
    let scheme = parsed.scheme().to_ascii_lowercase();
    HANDED_TO_THE_SYSTEM.contains(&scheme.as_str())
}

// MARK: - Across the FFI

/// Free function for the same reason every other one in this crate is: a shell
/// that kept its own list would be a second opinion about what leaves the
/// browser, and the half that is wrong is always the half that runs.
#[cfg(feature = "ffi")]
#[uniffi::export]
pub fn hand_to_the_system(url: String) -> bool {
    may_hand_to_the_system(&url)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_communication_schemes_are_handed_over() {
        assert!(may_hand_to_the_system(
            "mailto:someone@example.com?subject=hi"
        ));
        assert!(may_hand_to_the_system("tel:+15551234"));
        assert!(may_hand_to_the_system("sms:+15551234"));
        assert!(may_hand_to_the_system("facetime:someone@example.com"));
        assert!(may_hand_to_the_system("facetime-audio:someone@example.com"));
        assert!(may_hand_to_the_system("webcal://example.com/cal.ics"));
        assert!(may_hand_to_the_system("maps:?q=lisbon"));
    }

    /// Case is not a decision. A page writing `MAILTO:` means `mailto:`.
    #[test]
    fn the_scheme_is_read_without_regard_to_case() {
        assert!(may_hand_to_the_system("MAILTO:someone@example.com"));
        assert!(may_hand_to_the_system("Tel:+15551234"));
    }

    /// The whole point of the list being short. An application scheme starts a
    /// program a page named, and nothing here asks anybody first.
    #[test]
    fn an_application_scheme_is_not_handed_over() {
        assert!(!may_hand_to_the_system("slack://channel?id=1"));
        assert!(!may_hand_to_the_system("zoommtg://zoom.us/join?confno=1"));
        assert!(!may_hand_to_the_system("vscode://file/etc/passwd"));
        assert!(!may_hand_to_the_system("ms-msdt:/id"));
        assert!(!may_hand_to_the_system("spotify:track:1"));
    }

    /// ADR-0054. Our scheme reaches nothing outside the core, and that includes
    /// the one call in this browser that starts another program.
    #[test]
    fn one_of_our_own_addresses_is_never_handed_to_the_system() {
        assert!(!may_hand_to_the_system("zer0://settings"));
        assert!(!may_hand_to_the_system("zer0://chat?conversation=7"));
        assert!(!may_hand_to_the_system("ZER0://settings"));
        // Not an address we have, and still ours to refuse.
        assert!(!may_hand_to_the_system("zer0://nonsense"));
    }

    /// The engine's own business stays the engine's. Handing `https:` to
    /// `NSWorkspace` would open the page in whatever browser is default, which
    /// on a machine where zer0 *is* default is a loop.
    #[test]
    fn what_the_engine_loads_is_never_handed_over() {
        assert!(!may_hand_to_the_system("https://example.com"));
        assert!(!may_hand_to_the_system("http://example.com"));
        assert!(!may_hand_to_the_system("file:///etc/hosts"));
        assert!(!may_hand_to_the_system("about:blank"));
        assert!(!may_hand_to_the_system("data:text/html,hi"));
        assert!(!may_hand_to_the_system("blob:https://example.com/abc"));
    }

    #[test]
    fn nonsense_is_refused_rather_than_repaired() {
        assert!(!may_hand_to_the_system(""));
        assert!(!may_hand_to_the_system("   "));
        assert!(!may_hand_to_the_system("mailto"));
        assert!(!may_hand_to_the_system("not a url at all"));
        assert!(!may_hand_to_the_system("//example.com"));
    }

    /// A scheme that merely *starts* with one on the list is a different
    /// scheme. Without the exact comparison, `mailto-evil:` would ride in.
    #[test]
    fn a_scheme_that_only_looks_like_one_on_the_list_is_refused() {
        assert!(!may_hand_to_the_system("mailtox:someone@example.com"));
        assert!(!may_hand_to_the_system("telnet://example.com"));
        assert!(!may_hand_to_the_system("smsx:+1555"));
    }
}
