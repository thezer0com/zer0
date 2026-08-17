use super::*;

/// The composed string for both contexts, so each test below starts from the
/// one door every caller goes through rather than re-spelling its inputs.
fn composed(safari: Option<&str>, own: Option<&str>) -> [String; 2] {
    [
        user_agent(safari, own, UserAgentContext::Browsing),
        user_agent(safari, own, UserAgentContext::WebExtension),
    ]
}

/// Where a token sits, asserted rather than unwrapped so a missing token
/// fails as "the token is gone", not as a panic with a line number.
fn after(agent: &str, later: &str, earlier: &str) {
    let late = agent
        .find(later)
        .unwrap_or_else(|| panic!("no {later} in {agent}"));
    let early = agent
        .find(earlier)
        .unwrap_or_else(|| panic!("no {earlier} in {agent}"));
    assert!(late > early, "{later} must come after {earlier}: {agent}");
}

/// ADR-0008's order, held in every context: we name ourselves *after* the
/// Safari signature, never before it and never in place of it. Edge appends
/// `Edg/` and Vivaldi appends `Vivaldi/` for the same reason — putting our
/// name first is what breaks the sniffing the signature exists to satisfy.
#[test]
fn our_token_comes_after_the_safari_signature() {
    for agent in composed(Some("26.2"), Some("0.4.1")) {
        after(&agent, "zer0/", "Safari/");
    }
}

/// ADR-0073's refusal, at the door where the string is composed: the browsing
/// UA borrows Safari's name and ours, and no other browser's. The Swift lock
/// (`theUserAgentNamesNoOtherBrowser`) reads the same list out of a real page;
/// this half goes red first, without a web view, when someone widens the
/// composition itself.
#[test]
fn the_browsing_user_agent_names_no_browser_we_are_not() {
    let agent = user_agent(Some("26.2"), Some("0.4.1"), UserAgentContext::Browsing);

    for token in ["Chrome/", "Chromium/", "CriOS/", "Edg/", "Firefox/", "OPR/"] {
        assert!(
            !agent.contains(token),
            "the browsing UA claims to be {token}: {agent}"
        );
    }
}

/// The split ADR-0106 made: extension contexts carry Chrome's token because
/// per-extension UA is not a lever WebKit gives and the cost of "tell
/// extensions Safari" was paid twice (1Password, Bitwarden); pages the person
/// visits carry everything the browsing UA does and nothing more. Collapsing
/// the two strings is the regression this exists to catch at the composition,
/// before the Swift lock catches it in a live worker.
#[test]
fn extension_contexts_name_chrome_and_browsing_pages_do_not() {
    let [browsing, extension] = composed(Some("26.2"), Some("0.4.1"));

    assert!(extension.contains(CHROME_MARKETPLACE_TOKEN), "{extension}");
    assert!(!browsing.contains("Chrome/"), "{browsing}");
    // Everything the browsing UA does is preserved in the extension UA: the
    // engine we run and who we are, in the same order.
    assert!(extension.contains("Safari/605.1.15"), "{extension}");
    assert!(extension.contains("zer0/0.4.1"), "{extension}");
}

/// What happens on a machine with no Safari to read: the signature falls back
/// to a named version rather than thinning to nothing. ADR-0008 owns the rot
/// in that; this holds the shape — the fallback is a version, in place, with
/// the fixed suffix beside it, and no double spaces where a token went
/// missing.
#[test]
fn without_an_installed_safari_the_signature_falls_back_rather_than_thins() {
    let [browsing, extension] = composed(None, Some("0.4.1"));

    assert_eq!(browsing, "Version/18.3 Safari/605.1.15 zer0/0.4.1");
    assert_eq!(
        extension,
        "Version/18.3 Safari/605.1.15 Chrome/138.0.0.0 zer0/0.4.1"
    );
}

/// The same honesty for our own name: a host that names no version still
/// announces one, because a `zer0/` with nothing after it is a token no
/// sniffer and no log reader can key on.
#[test]
fn our_own_token_falls_back_to_a_version_when_the_host_names_none() {
    let [browsing, _] = composed(Some("26.2"), None);

    assert_eq!(browsing, "Version/26.2 Safari/605.1.15 zer0/0.1.0");
}

/// ADR-0106's shape claim, held to the literal: `<major>.0.0.0`, a recent
/// stable's silhouette. Extensions gate on `indexOf("Chrome")` and on minimum
/// majors, never on build numbers — so a token like `138.0` or `138.0.0.0.1`
/// is a different promise than the one the comment above the constant makes,
/// and this is what says so when the literal is next bumped.
#[test]
fn the_marketplace_chrome_token_keeps_the_shape_extensions_sniff_for() {
    let version = CHROME_MARKETPLACE_TOKEN
        .strip_prefix("Chrome/")
        .unwrap_or_else(|| panic!("not a Chrome token: {CHROME_MARKETPLACE_TOKEN}"));
    let parts: Vec<_> = version.split('.').collect();
    assert_eq!(parts.len(), 4, "expected <major>.0.0.0, got {version}");
    assert!(parts[0].chars().all(|c| c.is_ascii_digit()) && !parts[0].is_empty());
    assert_eq!(
        &parts[1..],
        ["0", "0", "0"],
        "expected zeros, got {version}"
    );
}
