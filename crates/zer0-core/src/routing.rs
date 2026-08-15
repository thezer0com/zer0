//! Air traffic control: rules that send a URL to the space where it belongs.
//!
//! Ported from the idea behind `avelino/firefox-airtraffic`, which routes URLs
//! into Firefox containers. Here it lands better than it does in Firefox: a
//! space already owns its cookie jar, so routing to a space *is* routing to a
//! container. There is no pairing to keep in sync.
//!
//! Work accounts stay in the work space, personal stays personal, and you stop
//! being the one who has to remember.

use std::sync::OnceLock;

use regex::Regex;

use crate::model::SpaceId;

#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum RoutePattern {
    /// Exact host match, or a subdomain of it. `github.com` matches
    /// `gist.github.com` but never `fakegithub.com`.
    Domain { host: String },
    /// Substring of the host. Looser, and deliberately so.
    DomainContains { fragment: String },
    /// Substring anywhere in the URL, path and query included.
    UrlContains { fragment: String },
    /// Full regular expression against the whole URL.
    Regex { pattern: String },
}

#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct Route {
    pub pattern: RoutePattern,
    pub space: SpaceId,
    pub enabled: bool,
}

/// Ordered rule set. The first match wins, so a specific rule placed above a
/// general one does what you would expect.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct RoutingTable {
    routes: Vec<Route>,
    prepared: PreparedCache,
}

impl RoutingTable {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn routes(&self) -> &[Route] {
        &self.routes
    }

    pub fn push(&mut self, route: Route) {
        self.routes.push(route);
        self.invalidate();
    }

    pub fn remove(&mut self, index: usize) -> Option<Route> {
        let removed = (index < self.routes.len()).then(|| self.routes.remove(index));
        if removed.is_some() {
            self.invalidate();
        }
        removed
    }

    pub fn set_enabled(&mut self, index: usize, enabled: bool) -> bool {
        match self.routes.get_mut(index) {
            Some(route) => {
                route.enabled = enabled;
                self.invalidate();
                true
            }
            None => false,
        }
    }

    /// Drop every rule pointing at a space that no longer exists, so a deleted
    /// space cannot leave rules routing into the void.
    pub fn retain_spaces(&mut self, existing: &[SpaceId]) {
        self.routes.retain(|r| existing.contains(&r.space));
        self.invalidate();
    }

    pub fn load(routes: Vec<Route>) -> Self {
        Self {
            routes,
            prepared: PreparedCache::default(),
        }
    }

    /// Which space this URL belongs to, if any rule claims it.
    pub fn route(&self, url: &str) -> Option<SpaceId> {
        let host = host_of(url);
        let prepared = self.prepared();
        // Worth doing once for the whole table, but only if some rule reads the
        // URL: a `data:` URL out of view-source runs to hundreds of kilobytes.
        let url_lower = prepared
            .iter()
            .any(|p| matches!(p, Prepared::UrlContains(_)))
            .then(|| url.to_lowercase());

        self.routes
            .iter()
            .zip(prepared)
            .find(|(route, prepared)| {
                route.enabled && matches(prepared, url, url_lower.as_deref(), host.as_deref())
            })
            .map(|(route, _)| route.space)
    }

    /// The prepared form of every rule, built on first use.
    fn prepared(&self) -> &[Prepared] {
        self.prepared
            .0
            .get_or_init(|| self.routes.iter().map(prepare).collect())
    }

    /// The cache is index-aligned with `routes`, so any edit makes it stale.
    fn invalidate(&mut self) {
        let _ = self.prepared.0.take();
    }
}

/// Everything about a rule that does not depend on the URL being tested,
/// resolved once instead of once per evaluation.
///
/// `route` runs on every navigation, every new tab, and every keystroke in the
/// command bar. Compiling a regex there costs hundreds of microseconds per rule
/// and buys nothing: the pattern cannot change between two calls.
#[derive(Debug, Clone)]
enum Prepared {
    /// Host and its `.host` suffix, both already normalized.
    Domain {
        host: String,
        dot_suffix: String,
    },
    /// Lowercased fragment to look for inside the host.
    HostContains(String),
    /// Lowercased fragment to look for inside the whole URL.
    UrlContains(String),
    Regex(Regex),
    /// The rule can never match: an empty fragment, a malformed domain, or a
    /// regex that does not compile. Keeping it as a value is what preserves
    /// "a broken rule matches nothing" without a special case at match time.
    Never,
}

fn prepare(route: &Route) -> Prepared {
    match &route.pattern {
        RoutePattern::Domain { host } => match normalized_host(host) {
            Some(host) => Prepared::Domain {
                dot_suffix: format!(".{host}"),
                host,
            },
            None => Prepared::Never,
        },
        RoutePattern::DomainContains { fragment } => {
            trimmed_lower(fragment).map_or(Prepared::Never, Prepared::HostContains)
        }
        RoutePattern::UrlContains { fragment } => {
            trimmed_lower(fragment).map_or(Prepared::Never, Prepared::UrlContains)
        }
        // A rule that will not compile matches nothing. Silently ignoring it
        // beats refusing to route anything at all.
        RoutePattern::Regex { pattern } => {
            Regex::new(pattern).map_or(Prepared::Never, Prepared::Regex)
        }
    }
}

fn trimmed_lower(fragment: &str) -> Option<String> {
    match fragment.trim() {
        "" => None,
        f => Some(f.to_lowercase()),
    }
}

fn matches(prepared: &Prepared, url: &str, url_lower: Option<&str>, host: Option<&str>) -> bool {
    match prepared {
        Prepared::Domain {
            host: want,
            dot_suffix,
        } => match host {
            // Subdomains count, lookalikes do not: the boundary must be a dot.
            Some(host) => host == want || host.ends_with(dot_suffix.as_str()),
            None => false,
        },
        Prepared::HostContains(fragment) => host.is_some_and(|h| h.contains(fragment.as_str())),
        Prepared::UrlContains(fragment) => url_lower.is_some_and(|u| u.contains(fragment.as_str())),
        Prepared::Regex(re) => re.is_match(url),
        Prepared::Never => false,
    }
}

/// Rewrite a domain rule into the exact shape [`host_of`] produces, so the two
/// can be compared as plain strings.
///
/// The round trip through `Url` is what makes IDN work. A rule typed as
/// `münchen.de` and a URL whose host arrives as `xn--mnchen-3ya.de` are the
/// same domain, but comparing the raw text matches neither spelling, and the
/// page lands in the wrong space with nothing said.
fn normalized_host(raw: &str) -> Option<String> {
    let want = raw.trim().trim_start_matches('.');
    if want.is_empty() {
        return None;
    }
    let parsed = url::Url::parse(&format!("https://{want}/")).ok()?;
    // A domain rule is a host and nothing else. Anything carrying userinfo, a
    // port, a path or a query is malformed, and a malformed rule matches
    // nothing rather than quietly matching more than it says.
    let host_only = parsed.username().is_empty()
        && parsed.port().is_none()
        && parsed.path() == "/"
        && parsed.query().is_none()
        && parsed.fragment().is_none();
    if !host_only {
        return None;
    }
    parsed.host_str().map(str::to_lowercase)
}

/// Lowercased host of a URL, without credentials or port.
fn host_of(url: &str) -> Option<String> {
    url::Url::parse(url)
        .ok()
        .and_then(|u| u.host_str().map(str::to_lowercase))
}

/// Lazily built, index-aligned with `RoutingTable::routes`.
///
/// A separate type only so `RoutingTable` keeps deriving `Clone` and
/// `PartialEq`: the cache is derived state, and two tables with the same rules
/// are the same table no matter what either has compiled so far.
#[derive(Debug, Clone, Default)]
struct PreparedCache(OnceLock<Vec<Prepared>>);

impl PartialEq for PreparedCache {
    fn eq(&self, _other: &Self) -> bool {
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const WORK: SpaceId = SpaceId(2);

    fn table(pattern: RoutePattern) -> RoutingTable {
        let mut t = RoutingTable::new();
        t.push(Route {
            pattern,
            space: WORK,
            enabled: true,
        });
        t
    }

    #[test]
    fn a_domain_rule_matches_the_host_and_its_subdomains() {
        let t = table(RoutePattern::Domain {
            host: "github.com".into(),
        });

        assert_eq!(t.route("https://github.com/avelino"), Some(WORK));
        assert_eq!(t.route("https://gist.github.com/x"), Some(WORK));
    }

    #[test]
    fn a_domain_rule_refuses_lookalike_hosts() {
        let t = table(RoutePattern::Domain {
            host: "github.com".into(),
        });

        // This is the whole point of strict matching. Getting it wrong sends
        // your session cookies to a phishing domain's space.
        assert_eq!(t.route("https://fakegithub.com/"), None);
        assert_eq!(t.route("https://github.com.evil.io/"), None);
        assert_eq!(t.route("https://notgithub.com/"), None);
    }

    #[test]
    fn host_matching_ignores_case_port_and_credentials() {
        let t = table(RoutePattern::Domain {
            host: "GitHub.com".into(),
        });

        assert_eq!(t.route("https://GITHUB.com:8443/x"), Some(WORK));
        assert_eq!(t.route("https://user:pw@github.com/x"), Some(WORK));
    }

    #[test]
    fn a_leading_dot_in_a_rule_is_tolerated() {
        let t = table(RoutePattern::Domain {
            host: ".github.com".into(),
        });
        assert_eq!(t.route("https://github.com/"), Some(WORK));
    }

    #[test]
    fn domain_contains_is_looser_on_purpose() {
        let t = table(RoutePattern::DomainContains {
            fragment: "github".into(),
        });

        assert_eq!(t.route("https://fakegithub.com/"), Some(WORK));
        assert_eq!(t.route("https://gitlab.com/"), None);
    }

    #[test]
    fn url_contains_looks_past_the_host() {
        let t = table(RoutePattern::UrlContains {
            fragment: "/buserbrasil/".into(),
        });

        assert_eq!(t.route("https://github.com/buserbrasil/repo"), Some(WORK));
        assert_eq!(t.route("https://github.com/avelino/repo"), None);
    }

    #[test]
    fn a_regex_rule_matches_the_whole_url() {
        let t = table(RoutePattern::Regex {
            pattern: r"^https://[a-z]+\.corp\.example\.com/".into(),
        });

        assert_eq!(t.route("https://mail.corp.example.com/inbox"), Some(WORK));
        assert_eq!(t.route("https://example.com/"), None);
    }

    #[test]
    fn a_broken_regex_matches_nothing_instead_of_breaking_routing() {
        let mut t = table(RoutePattern::Regex {
            pattern: "([unclosed".into(),
        });
        t.push(Route {
            pattern: RoutePattern::Domain {
                host: "avelino.run".into(),
            },
            space: SpaceId(3),
            enabled: true,
        });

        assert_eq!(t.route("https://anything.com/"), None);
        // The rules after it must still work.
        assert_eq!(t.route("https://avelino.run/"), Some(SpaceId(3)));

        // And it must stay that way once the rule set has been prepared: a
        // pattern that does not compile is remembered as "matches nothing",
        // never retried in a way that could poison the rules behind it.
        for _ in 0..10 {
            assert_eq!(t.route("https://anything.com/"), None);
            assert_eq!(t.route("https://avelino.run/"), Some(SpaceId(3)));
        }
    }

    #[test]
    fn a_regex_rule_is_compiled_once_not_once_per_url() {
        let mut t = RoutingTable::new();
        for i in 0..10 {
            t.push(Route {
                pattern: RoutePattern::Regex {
                    pattern: format!(r"^https://([a-z0-9-]+\.)*corp{i}\.example\.com/(a|b|c)+/\d+"),
                },
                space: WORK,
                enabled: true,
            });
        }

        // Behavioral stand-in for "compiled once": a thousand evaluations of ten
        // non-trivial patterns. Recompiling per call cost seconds here, reusing
        // the compiled form costs milliseconds. The bound is loose on purpose so
        // a busy machine does not turn this red for the wrong reason.
        let start = std::time::Instant::now();
        for i in 0..1000 {
            assert_eq!(
                t.route(&format!("https://mail.corp9.example.com/abc/{i}")),
                Some(WORK)
            );
            assert_eq!(t.route(&format!("https://example.com/abc/{i}")), None);
        }
        let elapsed = start.elapsed();
        assert!(
            elapsed < std::time::Duration::from_secs(1),
            "2000 evaluations took {elapsed:?}: the regexes are being recompiled"
        );
    }

    #[test]
    fn adding_a_rule_takes_effect_on_an_already_used_table() {
        let mut t = table(RoutePattern::Domain {
            host: "github.com".into(),
        });
        assert_eq!(t.route("https://avelino.run/"), None);

        t.push(Route {
            pattern: RoutePattern::Domain {
                host: "avelino.run".into(),
            },
            space: SpaceId(3),
            enabled: true,
        });

        assert_eq!(t.route("https://avelino.run/"), Some(SpaceId(3)));
    }

    #[test]
    fn removing_a_rule_takes_effect_on_an_already_used_table() {
        let mut t = table(RoutePattern::Domain {
            host: "github.com".into(),
        });
        t.push(Route {
            pattern: RoutePattern::Domain {
                host: "avelino.run".into(),
            },
            space: SpaceId(3),
            enabled: true,
        });
        assert_eq!(t.route("https://github.com/"), Some(WORK));
        assert_eq!(t.route("https://avelino.run/"), Some(SpaceId(3)));

        t.remove(0);

        assert_eq!(t.route("https://github.com/"), None);
        // The rule that survived moved down an index and must still match.
        assert_eq!(t.route("https://avelino.run/"), Some(SpaceId(3)));
    }

    #[test]
    fn disabling_a_rule_takes_effect_on_an_already_used_table() {
        let mut t = table(RoutePattern::Domain {
            host: "github.com".into(),
        });
        assert_eq!(t.route("https://github.com/"), Some(WORK));

        t.set_enabled(0, false);
        assert_eq!(t.route("https://github.com/"), None);

        t.set_enabled(0, true);
        assert_eq!(t.route("https://github.com/"), Some(WORK));
    }

    #[test]
    fn an_idn_rule_matches_both_spellings_of_the_host() {
        let t = table(RoutePattern::Domain {
            host: "münchen.de".into(),
        });

        // Same domain, two spellings. A rule that only catches one of them is
        // an isolation control that fails without saying so.
        assert_eq!(t.route("https://münchen.de/"), Some(WORK));
        assert_eq!(t.route("https://xn--mnchen-3ya.de/"), Some(WORK));
        assert_eq!(t.route("https://www.münchen.de/"), Some(WORK));
        assert_eq!(t.route("https://www.xn--mnchen-3ya.de/"), Some(WORK));

        // Strict matching still holds across the encoding.
        assert_eq!(t.route("https://notmünchen.de/"), None);
        assert_eq!(t.route("https://xn--notmnchen-o8a.de/"), None);
    }

    #[test]
    fn a_punycode_rule_matches_the_unicode_url() {
        let t = table(RoutePattern::Domain {
            host: "xn--mnchen-3ya.de".into(),
        });

        assert_eq!(t.route("https://münchen.de/"), Some(WORK));
        assert_eq!(t.route("https://xn--mnchen-3ya.de/"), Some(WORK));
    }

    #[test]
    fn a_domain_rule_carrying_more_than_a_host_matches_nothing() {
        // Fail closed: these are malformed rules, and guessing what they meant
        // would route more than they say.
        let with_path = table(RoutePattern::Domain {
            host: "github.com/avelino".into(),
        });
        assert_eq!(with_path.route("https://github.com/avelino"), None);

        let with_user = table(RoutePattern::Domain {
            host: "user@github.com".into(),
        });
        assert_eq!(with_user.route("https://github.com/"), None);
    }

    #[test]
    fn the_first_matching_rule_wins() {
        let mut t = RoutingTable::new();
        t.push(Route {
            pattern: RoutePattern::UrlContains {
                fragment: "/buserbrasil/".into(),
            },
            space: WORK,
            enabled: true,
        });
        t.push(Route {
            pattern: RoutePattern::Domain {
                host: "github.com".into(),
            },
            space: SpaceId(3),
            enabled: true,
        });

        assert_eq!(t.route("https://github.com/buserbrasil/x"), Some(WORK));
        assert_eq!(t.route("https://github.com/other/x"), Some(SpaceId(3)));
    }

    #[test]
    fn a_disabled_rule_is_skipped() {
        let mut t = table(RoutePattern::Domain {
            host: "github.com".into(),
        });
        t.set_enabled(0, false);

        assert_eq!(t.route("https://github.com/"), None);
    }

    #[test]
    fn empty_patterns_never_match() {
        assert_eq!(
            table(RoutePattern::Domain { host: "  ".into() }).route("https://a.com/"),
            None
        );
        assert_eq!(
            table(RoutePattern::UrlContains {
                fragment: "".into()
            })
            .route("https://a.com/"),
            None
        );
    }

    #[test]
    fn unparseable_urls_do_not_match_host_rules() {
        let t = table(RoutePattern::Domain {
            host: "github.com".into(),
        });
        assert_eq!(t.route("not a url"), None);
        assert_eq!(t.route("about:blank"), None);
    }

    #[test]
    #[ignore]
    fn bench_route() {
        let mut t = RoutingTable::new();
        for i in 0..10 {
            t.push(Route {
                pattern: RoutePattern::Regex {
                    pattern: format!(r"^https://([a-z0-9-]+\.)*corp{i}\.example\.com/(a|b|c)+/\d+"),
                },
                space: WORK,
                enabled: true,
            });
        }
        let n = 1000;
        let start = std::time::Instant::now();
        for i in 0..n {
            std::hint::black_box(t.route(&format!("https://mail.corp9.example.com/abc/{i}")));
        }
        let el = start.elapsed();
        println!("route(): {:?} total, {:?}/call", el, el / n);
    }

    #[test]
    fn rules_pointing_at_a_deleted_space_are_dropped() {
        let mut t = table(RoutePattern::Domain {
            host: "github.com".into(),
        });
        // Route once first: the drop has to take effect on a table already in
        // use, not only on a fresh one.
        assert_eq!(t.route("https://github.com/"), Some(WORK));

        t.retain_spaces(&[SpaceId(1)]);

        assert!(t.routes().is_empty());
        assert_eq!(t.route("https://github.com/"), None);
    }
}
