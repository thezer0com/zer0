//! Everything the settings window can change.
//!
//! In the core, not the shell, for the same reason the keymap is: a preference
//! that only exists on macOS is a preference Linux will implement differently
//! or forget. The shell renders these and reports changes; it decides none of
//! them.

use crate::blocking::usable_exception;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum ThemePreference {
    /// Follow the OS.
    #[default]
    System,
    Light,
    Dark,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum StartupBehaviour {
    /// Everything comes back exactly as you left it.
    #[default]
    RestoreSession,
    /// Start clean, with one empty tab.
    NewTab,
    /// Open a fixed set of pages every time.
    SpecificUrls { urls: Vec<String> },
}

/// A search engine offered in the picker.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct SearchEngine {
    pub name: String,
    /// URL with `{}` where the query goes.
    pub template: String,
}

/// The engines offered out of the box.
///
/// Google is the default because it is what people expect, not because it is
/// the best answer. The rest are here so switching is one click rather than a
/// trip to a settings text field.
pub fn search_engines() -> Vec<SearchEngine> {
    [
        ("Google", "https://www.google.com/search?q={}"),
        ("DuckDuckGo", "https://duckduckgo.com/?q={}"),
        ("Kagi", "https://kagi.com/search?q={}"),
        ("Brave", "https://search.brave.com/search?q={}"),
        ("Ecosia", "https://www.ecosia.org/search?q={}"),
        ("Startpage", "https://www.startpage.com/sp/search?query={}"),
        ("Bing", "https://www.bing.com/search?q={}"),
    ]
    .into_iter()
    .map(|(name, template)| SearchEngine {
        name: name.to_string(),
        template: template.to_string(),
    })
    .collect()
}

/// The name of the engine matching `template`, if it is one we ship.
pub fn search_engine_name(template: &str) -> Option<String> {
    search_engines()
        .into_iter()
        .find(|e| e.template == template)
        .map(|e| e.name)
}

#[derive(Debug, Clone, PartialEq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct Preferences {
    pub theme: ThemePreference,
    pub startup: StartupBehaviour,
    /// `None` means the system's Downloads folder.
    pub download_directory: Option<String>,
    /// Ask for a location on every download instead of using the folder above.
    pub ask_where_to_save: bool,
    /// WebKit's own content blocking, independent of any extension.
    pub block_content: bool,
    /// Sites whose content blocking is switched off, by host.
    pub blocking_exceptions: Vec<String>,
    /// Send a Do Not Track header. Mostly theatre, but it costs nothing and
    /// some jurisdictions treat it as a legal signal.
    pub send_do_not_track: bool,
    /// Wipe every space's cookies and storage when the browser quits.
    pub clear_data_on_quit: bool,
    /// Warn before closing a window with more than this many tabs. Zero means
    /// never warn.
    pub confirm_close_over: u32,
    /// A page may not start playing *audible* media on its own. Muted media
    /// autoplays either way — the gate is on sound, not on media (ADR-0074).
    pub block_audible_autoplay: bool,
    /// A page may not open a window unless somebody touched something first.
    ///
    /// The pop-up blocker. It only became a setting worth having the day
    /// `window.open` could open anything at all: before that it was a control
    /// with no effect on either position, which is why ADR-0074 refused it a
    /// row and ADR-0075 gives it one.
    pub block_unprompted_windows: bool,
}

impl Default for Preferences {
    fn default() -> Self {
        Self {
            theme: ThemePreference::System,
            startup: StartupBehaviour::RestoreSession,
            download_directory: None,
            ask_where_to_save: false,
            // On by default. A browser that ships blocking switched off is a
            // browser whose default is to be tracked.
            block_content: true,
            blocking_exceptions: Vec::new(),
            send_do_not_track: true,
            clear_data_on_quit: false,
            confirm_close_over: 5,
            // On, for the same reason `block_content` is: WebKit's default
            // here is an embedded web view's, and shipping it means a browser
            // any page can make noise through (ADR-0074).
            block_audible_autoplay: true,
            // On, and for the third time the same argument: WebKit's default
            // is an embedded web view's, and a browser that ships with any
            // page allowed to open a window unprompted is one people learn to
            // distrust within a day (ADR-0075).
            block_unprompted_windows: true,
        }
    }
}

impl Preferences {
    /// Whether content blocking applies to this URL.
    ///
    /// An exception only counts if it is a host [`usable_exception`] would put
    /// into a rule. That is not belt and braces — it is what keeps this answer
    /// *true*. What the interface says here and what WebKit is actually
    /// enforcing are two separate mechanisms, and the only reason they agree is
    /// that both read the exception list through the same door (ADR-0058).
    /// Honour one here that the rule list skips, and the screen says "not
    /// blocked" over a page that is still being filtered.
    pub fn blocks(&self, url: &str) -> bool {
        if !self.block_content {
            return false;
        }
        match host_of(url) {
            Some(host) => !self
                .blocking_exceptions
                .iter()
                .filter_map(|e| usable_exception(e))
                .any(|e| host == e),
            None => true,
        }
    }

    /// Turn blocking off for a site, the way Orion's per-site settings work.
    ///
    /// A host that cannot become a rule is refused rather than stored: storing
    /// it would put a row in Settings that reads as a live exception and
    /// exempts nothing (AGENTS.md — refuse rather than repair).
    pub fn allow_blocking(&mut self, host: &str, blocking: bool) {
        let Some(host) = usable_exception(host) else {
            return;
        };
        self.blocking_exceptions
            .retain(|e| usable_exception(e).as_deref() != Some(host.as_str()));
        if !blocking {
            self.blocking_exceptions.push(host);
        }
    }
}

fn host_of(url: &str) -> Option<String> {
    url::Url::parse(url)
        .ok()
        .and_then(|u| u.host_str().map(str::to_lowercase))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn blocking_is_on_out_of_the_box() {
        // A browser shipping with blocking off ships with tracking on.
        let prefs = Preferences::default();
        assert!(prefs.block_content);
        assert!(prefs.blocks("https://example.com/"));
    }

    #[test]
    fn a_site_can_be_excepted_without_turning_blocking_off_everywhere() {
        let mut prefs = Preferences::default();

        prefs.allow_blocking("broken-site.com", false);

        assert!(!prefs.blocks("https://broken-site.com/page"));
        assert!(prefs.blocks("https://example.com/"));
    }

    #[test]
    fn an_exception_covers_the_host_regardless_of_case_or_path() {
        let mut prefs = Preferences::default();
        prefs.allow_blocking("Broken-Site.com", false);

        assert!(!prefs.blocks("https://BROKEN-SITE.com/deep/path?q=1"));
    }

    #[test]
    fn an_exception_does_not_leak_to_lookalike_hosts() {
        let mut prefs = Preferences::default();
        prefs.allow_blocking("site.com", false);

        assert!(prefs.blocks("https://notsite.com/"));
        assert!(prefs.blocks("https://site.com.evil.io/"));
    }

    #[test]
    fn re_enabling_a_site_removes_the_exception_rather_than_stacking() {
        let mut prefs = Preferences::default();
        prefs.allow_blocking("site.com", false);
        prefs.allow_blocking("site.com", false);

        prefs.allow_blocking("site.com", true);

        assert!(prefs.blocking_exceptions.is_empty());
        assert!(prefs.blocks("https://site.com/"));
    }

    #[test]
    fn turning_blocking_off_globally_beats_any_exception() {
        let mut prefs = Preferences::default();
        prefs.allow_blocking("site.com", false);
        prefs.block_content = false;

        assert!(!prefs.blocks("https://anything.com/"));
    }

    #[test]
    fn every_shipped_engine_has_a_query_placeholder() {
        // An engine without {} would silently search for nothing.
        for engine in search_engines() {
            assert!(
                engine.template.contains("{}"),
                "{} has no placeholder",
                engine.name
            );
            assert!(engine.template.starts_with("https://"));
        }
    }

    #[test]
    fn a_shipped_template_is_recognised_by_name() {
        assert_eq!(
            search_engine_name("https://duckduckgo.com/?q={}").as_deref(),
            Some("DuckDuckGo")
        );
        assert_eq!(search_engine_name("https://example.com/?q={}"), None);
    }

    /// The two mechanisms have to say the same thing about the same page.
    ///
    /// A host that cannot be written as a WebKit rule is skipped by the rule
    /// list, so honouring it here would put the screen and the engine into
    /// disagreement — the screen saying "blocking is off for this site" over a
    /// page WebKit is still filtering. Neither half is allowed to be lenient.
    #[test]
    fn an_exception_nobody_could_compile_exempts_nothing_here_either() {
        // Straight into the field, the way a hand-edited session file arrives
        // (ADR-0024). `[::1]` is the realistic one: a URL really does have that
        // host, and WebKit's pattern grammar really cannot express it.
        let prefs = Preferences {
            blocking_exceptions: vec!["[::1]".into(), "with space.com".into(), "*".into()],
            ..Preferences::default()
        };

        assert!(prefs.blocks("http://[::1]:8080/x"));
        assert!(prefs.blocks("https://example.com/"));
    }

    #[test]
    fn a_host_that_could_never_be_a_rule_is_not_recorded_at_all() {
        let mut prefs = Preferences::default();

        prefs.allow_blocking("*.example.com", false);
        prefs.allow_blocking("http://example.com", false);
        prefs.allow_blocking("exam ple.com", false);

        assert!(
            prefs.blocking_exceptions.is_empty(),
            "a row that exempts nothing is worse than no row: it looks like it works"
        );
    }

    #[test]
    fn an_empty_host_is_not_recorded_as_an_exception() {
        let mut prefs = Preferences::default();
        prefs.allow_blocking("   ", false);
        assert!(prefs.blocking_exceptions.is_empty());
    }
}
