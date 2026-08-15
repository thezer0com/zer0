//! What gets blocked, and where it does not.
//!
//! The core decides **which rules are active and which sites are excepted**.
//! The shell compiles the result and hands it to the engine, because
//! `WKContentRuleListStore` is a platform API and a Linux host will reach the
//! same engine through `WebKitUserContentFilterStore` instead.
//!
//! The *format* is nevertheless written here, and that is a deliberate reading
//! of the tie-breaker in AGENTS.md — "if two platforms could reasonably
//! disagree about it, it belongs in the shell". They cannot disagree about
//! this. Both hosts are WebKit (ADR-0001) and both take the **same**
//! content-blocker JSON: it is a WebKit format, not an Apple one. Emitting it
//! twice, once per host, would be two chances to anchor a host pattern
//! differently — and a host pattern anchored differently is ADR-0026's bug
//! wearing a new hat.
//!
//! Everything asserted below about the format was **measured against the
//! installed WebKit** rather than recalled. ADR-0058 records the measurements
//! and what each one costs.

use crate::preferences::Preferences;
use serde_json::{Value, json};

/// Bumped when the shipped rules change in a way a cached compile would get
/// wrong. It is part of the identifier, so an old compile is never reused for
/// new rules — and a downgrade does not reuse a newer one either.
const RULES_VERSION: u32 = 1;

/// The ceiling on how many sites may be excepted at once.
///
/// Not a performance limit — 50,000 rules compile in 119ms on this machine, and
/// WebKit's own ceiling is 150,000. It is a limit on what one hostile session
/// file can do: without it, a file carrying a million exceptions turns every
/// launch into a compile of a million rules.
pub const MAX_EXCEPTIONS: usize = 1_000;

/// A third-party host whose job on a page is to watch who is reading it.
///
/// **Where this list comes from, stated plainly because the licence turns on
/// it: it is hand-written in this repository, and no public blocklist was
/// copied or converted into it.** The survey behind that decision is in
/// ADR-0058; the short version is that every list worth having carries an
/// obligation an MIT binary cannot absorb by embedding it — AdGuard's filters
/// and uBlock Origin's `uAssets` are GPL-3.0, and Disconnect, Ghostery's
/// `trackerdb` and DuckDuckGo's Tracker Radar are all CC-BY-**NC**-SA-4.0,
/// whose non-commercial clause would reach zer0's own users downstream.
///
/// **What that means for the person using it, stated just as plainly: this is
/// about seventy hosts, and EasyList has well over a hundred thousand rules.**
/// It stops the advertising and analytics infrastructure that sits on a large
/// share of the web. It is not comprehensive, it is not EasyList, and nothing
/// in the interface says otherwise (ADR-0018).
///
/// Every entry is blocked **third-party only**: a request to a host from a page
/// already on that host is that site serving itself, and a blocker that breaks
/// a site somebody visited on purpose is a blocker that gets switched off.
const TRACKER_HOSTS: &[&str] = &[
    // Advertising exchanges and ad servers.
    "doubleclick.net",
    "googlesyndication.com",
    "googleadservices.com",
    "adnxs.com",
    "rubiconproject.com",
    "pubmatic.com",
    "openx.net",
    "criteo.com",
    "criteo.net",
    "taboola.com",
    "outbrain.com",
    "adsrvr.org",
    "casalemedia.com",
    "sharethrough.com",
    "smartadserver.com",
    "teads.tv",
    "amazon-adsystem.com",
    "advertising.com",
    "adcolony.com",
    "applovin.com",
    "moatads.com",
    "serving-sys.com",
    "247realmedia.com",
    "yieldmo.com",
    "indexww.com",
    "3lift.com",
    // Analytics and session recording.
    "google-analytics.com",
    "googletagmanager.com",
    "googletagservices.com",
    "scorecardresearch.com",
    "quantserve.com",
    "chartbeat.com",
    "hotjar.com",
    "hotjar.io",
    "fullstory.com",
    "mouseflow.com",
    "crazyegg.com",
    "luckyorange.com",
    "inspectlet.com",
    "clarity.ms",
    "mixpanel.com",
    "segment.com",
    "segment.io",
    "amplitude.com",
    "heapanalytics.com",
    "kissmetrics.com",
    "statcounter.com",
    "nr-data.net",
    "parsely.com",
    "quantcast.com",
    // Cross-site identity and behavioural profiling.
    "bluekai.com",
    "krxd.net",
    "demdex.net",
    "everesttech.net",
    "agkn.com",
    "exelator.com",
    "rlcdn.com",
    "crwdcntrl.net",
    "bidswitch.net",
    "id5-sync.com",
    "adsymptotic.com",
    "tapad.com",
    "branch.io",
    "onesignal.com",
    "braze.com",
    "adform.net",
    "eyeota.net",
    "mathtag.com",
    "simpli.fi",
    "zqtk.net",
    // Social buttons that report a visit whether or not anybody clicks them.
    "connect.facebook.net",
    "ct.pinterest.com",
    "analytics.tiktok.com",
    "ads-twitter.com",
    "px.ads.linkedin.com",
    "snap.licdn.com",
];

/// What the interface may say about blocking, and nothing past it.
///
/// Note what is **not** in here: how many requests were blocked on this page.
/// `WKContentRuleList` was read in the installed SDK and carries exactly one
/// member, `identifier`. There is no count, no callback and no notification in
/// any public WebKit header — the only thing that reports a blocked load is
/// `_WKContentRuleListAction`, which is SPI. So the number every other browser
/// prints on a shield badge cannot be had honestly here, and is not invented to
/// fill the space (ADR-0018, ADR-0058).
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct BlockingSummary {
    /// Whether blocking is switched on at all.
    pub enabled: bool,
    /// How many rules the compiled list holds: the shipped rules, plus one
    /// exception rule when there is anything to except. A fact about the list,
    /// which is a different claim from a fact about a page.
    pub rules: u32,
    /// How many sites blocking is switched off for.
    pub exceptions: u32,
}

/// An exception host we can actually express, or nothing.
///
/// The one door (AGENTS.md). Both [`Preferences::blocks`] and the rule emitter
/// read exceptions through it, so what the interface says and what WebKit
/// enforces cannot drift apart — which they would the moment one of them
/// honoured a host the other skipped.
///
/// It is also the guard on the real failure mode here, and the reason the
/// charset is a whitelist rather than an escape: **one bad rule fails the whole
/// compile.** That is measured, not assumed — WebKit refuses the list, not the
/// rule. So a session file with `"))|.*"` in its exception table would switch
/// blocking off entirely, silently, on every launch. Refusing rather than
/// repairing is the rule (AGENTS.md), so a host that is not a host never
/// becomes a pattern at all.
pub fn usable_exception(host: &str) -> Option<String> {
    let host = host.trim().to_lowercase();

    // 253 is the ceiling on a DNS name. Longer than that is not one.
    if host.is_empty() || host.len() > 253 {
        return None;
    }
    // A leading dot, a trailing dot, or an empty label: none of these is
    // something a person typed, and `..` would emit `\.\.` and match nothing.
    if host.starts_with('.') || host.ends_with('.') || host.contains("..") {
        return None;
    }
    if host.starts_with('-') || host.ends_with('-') {
        return None;
    }
    // The whitelist, and what makes the escaping below complete rather than
    // hopeful: after this, `.` is the only character left in the string that a
    // regex engine reads as anything other than itself.
    //
    // ASCII only, deliberately. WebKit refuses a non-ASCII `url-filter`
    // outright ("Only ASCII characters are supported in pattern"), so an IDN
    // has to arrive here already punycoded or not at all.
    if !host
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '.' || c == '-')
    {
        return None;
    }

    Some(host)
}

/// A host as a WebKit `url-filter`, anchored so that it is that host and not a
/// host that merely begins with it.
///
/// Three anchors, and every one of them is load-bearing (ADR-0026):
///
/// - `^https?://` — the host has to start the authority, so `github.com` cannot
///   match `https://evil.io/?next=github.com/`. WebKit's matching is
///   **unanchored by default**, so leaving this off is not a stylistic choice.
/// - `\.` on every dot — unescaped, `github.com` matches `githubXcom`, which is
///   a name somebody can register.
/// - `[:/]` at the end — the host has to *end* there, so `github.com` cannot
///   match `github.com.evil.io`. This is the anchor the bug is always missing.
///
/// Written with only what WebKit's regex subset accepts. Measured against the
/// installed engine: alternation (`|`), bounded repeats (`{2,4}`), lookahead
/// and word boundaries are all refused — "Disjunctions are not supported yet"
/// is the actual wording — so none of the tidier ways to write this exist.
fn host_pattern(host: &str) -> String {
    format!("^https?://{}[:/]", host.replace('.', "\\."))
}

/// The same, but also matching any subdomain.
///
/// Only the shipped tracker rules use this. An **exception** deliberately does
/// not: [`Preferences::blocks`] answers for the exact host and nothing else, so
/// an exception that quietly covered subdomains would make the interface's
/// answer and WebKit's behaviour two different things — and the interface's
/// would be the one on screen.
fn host_and_subdomains_pattern(host: &str) -> String {
    format!("^https?://([^/]+\\.)?{}[:/]", host.replace('.', "\\."))
}

/// Every exception that can be expressed, in order, capped.
fn expressible_exceptions(preferences: &Preferences) -> Vec<String> {
    preferences
        .blocking_exceptions
        .iter()
        .filter_map(|host| usable_exception(host))
        .take(MAX_EXCEPTIONS)
        .collect()
}

/// The rule list, as WebKit content-blocker JSON, or `None` when there is
/// nothing to compile.
///
/// `None` rather than `"[]"`, because an empty array **does not compile** —
/// measured, and WebKit's own error for it is "Empty extension". Handing the
/// shell an empty list would turn "blocking is off" into an error report on
/// every launch.
///
/// Built through `serde_json` rather than by formatting strings. Not tidiness:
/// a hand-rolled escape is a rule, and a value that cannot be spelled wrongly
/// is a guarantee (AGENTS.md). The only thing that reaches these strings is a
/// host that already survived [`usable_exception`], and this is the second lock
/// on it.
pub fn rule_list_json(preferences: &Preferences) -> Option<String> {
    if !preferences.block_content || TRACKER_HOSTS.is_empty() {
        return None;
    }

    let mut rules: Vec<Value> = TRACKER_HOSTS
        .iter()
        .map(|host| {
            json!({
                "trigger": {
                    "url-filter": host_and_subdomains_pattern(host),
                    // Not a `condition` in WebKit's sense, so it may sit
                    // beside `url-filter`. The `if-*`/`unless-*` family is
                    // mutually exclusive — *any* two of them in one trigger is
                    // a compile error, not just a contradictory pair.
                    "load-type": ["third-party"],
                },
                "action": { "type": "block" },
            })
        })
        .collect();

    // Last, and the order is the entire mechanism: WebKit walks a list in
    // order and `ignore-previous-rules` undoes what came before it. Put this
    // first and every rule after it still fires — a blocker that ignores its
    // own exceptions, and looks like it is working.
    //
    // It also has to live in *this* list rather than in a second one, which is
    // the fact that shapes the caching below. `ignore-previous-rules` is scoped
    // to the rule list it appears in and can never reach another one, so
    // "compile the rules once forever and recompile only a tiny exception
    // list" is not available.
    let exceptions = expressible_exceptions(preferences);
    if !exceptions.is_empty() {
        let patterns: Vec<String> = exceptions.iter().map(|host| host_pattern(host)).collect();
        rules.push(json!({
            "trigger": {
                "url-filter": ".*",
                // `if-top-url` and not `if-domain`: both are matched against
                // the top-level document, but `if-domain` is a shorthand whose
                // anchoring WebKit writes for us, and the whole of ADR-0026 is
                // that this project anchors its own host patterns and proves
                // it. This one is proven below.
                "if-top-url": patterns,
            },
            "action": { "type": "ignore-previous-rules" },
        }));
    }

    Some(Value::Array(rules).to_string())
}

/// The key the compiled list is cached under.
///
/// This is the whole of the launch-cost story. A cold compile of the shipped
/// list is single-digit milliseconds and a warm lookup is 0.1ms — measured, at
/// every size from 100 rules to 50,000 — so what matters is never compiling
/// when nothing changed, and what makes that safe is that the identifier moves
/// whenever the *content* does.
///
/// Derived from the JSON rather than from the inputs, so there is no way to
/// change what compiles without changing what it is filed under. Version
/// prefixed as well, so a future WebKit storing things differently under the
/// same name never gets to answer for it.
pub fn rule_list_identifier(preferences: &Preferences) -> Option<String> {
    let json = rule_list_json(preferences)?;
    Some(format!("zer0-block-v{RULES_VERSION}-{:016x}", fnv1a(&json)))
}

/// What may be said about blocking as it currently stands.
pub fn summary(preferences: &Preferences) -> BlockingSummary {
    let exceptions = expressible_exceptions(preferences);
    let rules = if preferences.block_content {
        TRACKER_HOSTS.len() + usize::from(!exceptions.is_empty())
    } else {
        0
    };

    BlockingSummary {
        enabled: preferences.block_content,
        rules: rules as u32,
        exceptions: exceptions.len() as u32,
    }
}

/// How many hosts the shipped list covers. Public so the interface can print
/// the number instead of rounding it into a claim.
pub fn shipped_host_count() -> u32 {
    TRACKER_HOSTS.len() as u32
}

/// FNV-1a, 64-bit. A hash, not a defence: the identifier only has to move when
/// the content does, and nothing downstream trusts it for anything else.
fn fnv1a(value: &str) -> u64 {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in value.as_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x1000_0000_01b3);
    }
    hash
}

#[cfg(test)]
mod tests {
    use super::*;
    use regex::Regex;

    fn prefs_excepting(hosts: &[&str]) -> Preferences {
        let mut prefs = Preferences::default();
        for host in hosts {
            prefs.allow_blocking(host, false);
        }
        prefs
    }

    /// The pattern as a real regex engine reads it.
    ///
    /// WebKit's grammar is a *subset*: anchors, escaped literals, character
    /// classes and `?` mean the same thing in both engines, and nothing emitted
    /// here uses anything outside that overlap — which is itself asserted by
    /// `every_shipped_pattern_stays_inside_webkits_regex_subset`, and by a
    /// Swift test that hands the real compiler a real list.
    fn matches(pattern: &str, url: &str) -> bool {
        Regex::new(pattern)
            .expect("pattern is a regex")
            .is_match(url)
    }

    /// Every `url-filter` in the emitted list, pulled back out of the JSON so
    /// the assertions run against what is actually shipped rather than against
    /// a second construction of it.
    fn emitted_filters(json: &str) -> Vec<String> {
        let parsed: Value = serde_json::from_str(json).expect("emitted JSON parses");
        parsed
            .as_array()
            .expect("a top-level array")
            .iter()
            .map(|rule| rule["trigger"]["url-filter"].as_str().unwrap().to_string())
            .collect()
    }

    fn exception_patterns(json: &str) -> Vec<String> {
        let parsed: Value = serde_json::from_str(json).expect("emitted JSON parses");
        parsed
            .as_array()
            .expect("a top-level array")
            .iter()
            .filter(|rule| rule["action"]["type"] == "ignore-previous-rules")
            .flat_map(|rule| {
                rule["trigger"]["if-top-url"]
                    .as_array()
                    .expect("if-top-url is an array")
                    .iter()
                    .map(|value| value.as_str().unwrap().to_string())
            })
            .collect()
    }

    #[test]
    fn an_exception_exempts_the_host_it_names() {
        let prefs = prefs_excepting(&["github.com"]);
        let json = rule_list_json(&prefs).expect("a list");

        let patterns = exception_patterns(&json);
        assert_eq!(patterns.len(), 1);
        let pattern = &patterns[0];

        assert!(matches(pattern, "https://github.com/avelino"));
        assert!(matches(pattern, "http://github.com/"));
        assert!(matches(pattern, "https://github.com:8443/x"));
        // And the core's own answer agrees with the rule it just emitted.
        assert!(!prefs.blocks("https://github.com/avelino"));
    }

    /// ADR-0026's standard, applied to the thing here that would break it.
    ///
    /// Every one of these is a name somebody can register. `github.com.evil.io`
    /// is the one that ships: it ends where a lazy anchor would let it start.
    #[test]
    fn an_exception_does_not_leak_to_a_lookalike_host() {
        let prefs = prefs_excepting(&["github.com"]);
        let json = rule_list_json(&prefs).expect("a list");
        let pattern = &exception_patterns(&json)[0];

        assert!(!matches(pattern, "https://fakegithub.com/x"));
        assert!(!matches(pattern, "https://github.com.evil.io/x"));
        assert!(!matches(pattern, "https://githubXcom/x"));
        assert!(!matches(pattern, "https://notgithub.com/x"));
        assert!(!matches(pattern, "https://www.github.com/x"));
        // The host appears, but not in the authority.
        assert!(!matches(pattern, "https://evil.io/?next=github.com/"));
        assert!(!matches(pattern, "https://evil.io/github.com/"));

        // And the two answers still agree: the core says these are blocked.
        assert!(prefs.blocks("https://fakegithub.com/x"));
        assert!(prefs.blocks("https://github.com.evil.io/x"));
        assert!(prefs.blocks("https://www.github.com/x"));
    }

    /// The dot is the one character in a hostname a regex reads as something
    /// else, so it gets a test of its own rather than riding along.
    #[test]
    fn every_dot_in_a_host_is_escaped() {
        assert_eq!(
            host_pattern("a.b.c"),
            "^https?://a\\.b\\.c[:/]",
            "an unescaped dot matches any character, and somebody owns that name"
        );
        assert!(!matches(&host_pattern("a.b.c"), "https://aXbXc/"));
    }

    #[test]
    fn a_tracker_rule_covers_subdomains_and_still_ends_at_the_host() {
        let json = rule_list_json(&Preferences::default()).expect("a list");
        let filters = emitted_filters(&json);
        let pattern = filters
            .iter()
            .find(|filter| filter.contains("doubleclick"))
            .expect("doubleclick is in the shipped list");

        assert!(matches(pattern, "https://doubleclick.net/x"));
        assert!(matches(pattern, "https://stats.g.doubleclick.net/x"));
        // The same anchor, doing the same job on the other side.
        assert!(!matches(pattern, "https://doubleclick.net.evil.io/x"));
        assert!(!matches(pattern, "https://notdoubleclick.net/x"));
        assert!(!matches(pattern, "https://evil.io/?u=doubleclick.net/"));
    }

    /// The failure guarded here is not "one exception is ignored". It is
    /// **blocking silently switched off**: WebKit refuses an entire list when
    /// any single rule in it is malformed, so one bad row in the exceptions
    /// table would take all seventy-odd rules with it.
    #[test]
    fn a_hostile_exception_never_reaches_the_rule_list() {
        // Written straight into the field, the way a hand-edited or corrupted
        // session file reaches it. `allow_blocking` is not the only door
        // (ADR-0024).
        let prefs = Preferences {
            blocking_exceptions: vec![
                "\"}],\"x\":[".into(),
                "*".into(),
                "(a|b)".into(),
                "..".into(),
                "-lead.com".into(),
                "with space.com".into(),
                "exámple.com".into(),
                "github.com".into(),
            ],
            ..Preferences::default()
        };

        let json = rule_list_json(&prefs).expect("a list");
        let patterns = exception_patterns(&json);

        assert_eq!(
            patterns,
            vec!["^https?://github\\.com[:/]".to_string()],
            "only the one real host should have become a pattern"
        );
        // Still valid JSON, and still a list WebKit's grammar accepts.
        for filter in emitted_filters(&json) {
            Regex::new(&filter).expect("every emitted filter is a regex");
            assert!(!filter.contains('|'), "{filter} would fail the whole list");
        }
        // And the junk excepts nothing, so the interface and WebKit agree.
        assert!(prefs.blocks("https://anything.com/"));
    }

    #[test]
    fn a_host_that_is_not_a_host_is_refused_rather_than_repaired() {
        for junk in [
            "",
            "   ",
            "*.example.com",
            "exam ple.com",
            "http://example.com",
            "example.com/path",
            ".example.com",
            "example.com.",
            "a..b",
            "-example.com",
            "example.com-",
            "exámple.com",
            "example.com:443",
        ] {
            assert_eq!(usable_exception(junk), None, "{junk} should be refused");
        }

        assert_eq!(
            usable_exception("  GitHub.COM  ").as_deref(),
            Some("github.com"),
            "a real host is still accepted, normalised the way blocks() reads it"
        );
    }

    /// Every rule the list can emit has to be one WebKit will take, and the
    /// pattern is the only part of it with any freedom.
    #[test]
    fn every_shipped_pattern_stays_inside_webkits_regex_subset() {
        // Measured against the installed engine: each of these is refused, and
        // one refusal fails the entire list.
        let json = rule_list_json(&prefs_excepting(&["github.com"])).expect("a list");

        for filter in emitted_filters(&json) {
            for forbidden in ['|', '{', '}'] {
                assert!(
                    !filter.contains(forbidden),
                    "{filter} contains {forbidden}, which WebKit refuses"
                );
            }
            assert!(!filter.contains("(?"), "{filter} is a group assertion");
            assert!(!filter.contains("\\d"), "{filter} uses a builtin class");
            assert!(!filter.contains("\\b"), "{filter} uses a word boundary");
            assert!(filter.is_ascii(), "{filter} is not ASCII");
            Regex::new(&filter).expect("every emitted filter is a regex");
        }
    }

    #[test]
    fn no_shipped_host_is_listed_twice_or_malformed() {
        let mut seen: Vec<&str> = Vec::new();
        for host in TRACKER_HOSTS {
            assert!(
                usable_exception(host).as_deref() == Some(*host),
                "{host} is not a lowercase, well-formed host"
            );
            assert!(!seen.contains(host), "{host} is listed twice");
            seen.push(host);
        }
    }

    /// An empty array does not compile, so "off" has to be the absence of a
    /// list rather than an empty one.
    #[test]
    fn blocking_switched_off_produces_no_list_at_all() {
        let prefs = Preferences {
            block_content: false,
            ..Preferences::default()
        };

        assert_eq!(rule_list_json(&prefs), None);
        assert_eq!(rule_list_identifier(&prefs), None);
        assert_eq!(summary(&prefs).rules, 0);
        assert!(!summary(&prefs).enabled);
    }

    #[test]
    fn the_identifier_follows_the_content_and_nothing_else() {
        let plain = Preferences::default();
        let excepted = prefs_excepting(&["github.com"]);

        let a = rule_list_identifier(&plain).expect("an id");
        let b = rule_list_identifier(&excepted).expect("an id");

        assert_ne!(a, b, "an exception has to invalidate the cached compile");
        assert_eq!(
            a,
            rule_list_identifier(&Preferences::default()).unwrap(),
            "the same rules must land on the same key, or nothing is ever cached"
        );
        assert!(a.starts_with(&format!("zer0-block-v{RULES_VERSION}-")));

        // A setting with nothing to do with blocking must not invalidate it,
        // or every unrelated preference change costs a recompile.
        let unrelated = Preferences {
            send_do_not_track: false,
            confirm_close_over: 42,
            ..Preferences::default()
        };
        assert_eq!(a, rule_list_identifier(&unrelated).unwrap());
    }

    #[test]
    fn the_exception_rule_is_last_or_it_undoes_nothing() {
        let prefs = prefs_excepting(&["github.com"]);
        let json = rule_list_json(&prefs).expect("a list");
        let parsed: Value = serde_json::from_str(&json).unwrap();
        let rules = parsed.as_array().unwrap();

        let last = rules.last().expect("at least one rule");
        assert_eq!(last["action"]["type"], "ignore-previous-rules");
        for rule in &rules[..rules.len() - 1] {
            assert_eq!(
                rule["action"]["type"], "block",
                "an ignore-previous-rules before the end would undo nothing after it"
            );
        }
    }

    #[test]
    fn one_rule_carries_every_exception_rather_than_one_rule_each() {
        let prefs = prefs_excepting(&["a.com", "b.com", "c.com"]);
        let json = rule_list_json(&prefs).expect("a list");

        assert_eq!(json.matches("ignore-previous-rules").count(), 1);
        assert_eq!(exception_patterns(&json).len(), 3);
        assert_eq!(summary(&prefs).exceptions, 3);
    }

    /// A session file is a boundary like any other (ADR-0024).
    #[test]
    fn the_exception_list_is_capped_however_long_the_file_is() {
        let prefs = Preferences {
            blocking_exceptions: (0..MAX_EXCEPTIONS * 3)
                .map(|index| format!("site{index}.example"))
                .collect(),
            ..Preferences::default()
        };

        assert_eq!(summary(&prefs).exceptions as usize, MAX_EXCEPTIONS);

        let json = rule_list_json(&prefs).expect("a list");
        assert_eq!(
            exception_patterns(&json).len(),
            MAX_EXCEPTIONS,
            "the cap has to reach the emitted rules, not only the count"
        );
    }

    /// The summary is a claim, so it has to be a true one.
    #[test]
    fn the_summary_counts_the_rules_that_are_actually_emitted() {
        let plain = Preferences::default();
        let json = rule_list_json(&plain).expect("a list");
        assert_eq!(summary(&plain).rules as usize, emitted_filters(&json).len());
        assert_eq!(summary(&plain).rules, shipped_host_count());
        assert_eq!(summary(&plain).exceptions, 0);

        let excepted = prefs_excepting(&["github.com"]);
        let json = rule_list_json(&excepted).expect("a list");
        assert_eq!(
            summary(&excepted).rules as usize,
            emitted_filters(&json).len(),
            "the exception rule is a rule and has to be counted as one"
        );
    }

    /// WebKit refuses a list over 150,000 rules outright. Nothing here is
    /// close, and this is the test that says so if the shipped list ever grows
    /// into a converted blocklist without the caching being rethought.
    #[test]
    fn the_shipped_list_stays_far_under_webkits_ceiling() {
        let prefs = prefs_excepting(&["github.com"]);
        let count = emitted_filters(&rule_list_json(&prefs).unwrap()).len();
        assert!(count < 150_000, "WebKit refuses more than 150,000 rules");
        // And under the size where compilation stops being free: 5,000 rules
        // measured at 11.5ms, which is already more than a launch should spend.
        assert!(
            count < 5_000,
            "a list this size needs the compile budget re-measured"
        );
    }
}
