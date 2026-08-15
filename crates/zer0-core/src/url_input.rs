//! Deciding whether what the user typed is an address or a search.
//!
//! This is the command bar's whole job and it belongs in the core, not the UI:
//! every platform shell must resolve input identically.

use url::Url;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Resolved {
    Navigate(String),
    Search(String),
}

/// Schemes we hand straight to the engine.
///
/// `webkit-extension` is the address of a page **inside an extension**, and it
/// is here for the reason the others are: the engine owns it and can load it.
/// Searching for one is the same failure [`is_ours`] exists to prevent one step
/// over — the address of a page inside the browser handed to a search engine —
/// and it is the failure that was actually happening, because every extension's
/// options page and every onboarding page an extension opens for itself arrives
/// through here (ADR-0086).
///
/// What it does **not** decide is which extension may be reached: this list is
/// about shape, and the host in one of these addresses is a uuid WebKit minted
/// for a live context. Whether one exists is the shell's answer and nobody
/// else's — see [`crate::extension_url`].
const PASSTHROUGH_SCHEMES: [&str; 6] = [
    "http",
    "https",
    "file",
    "about",
    "data",
    crate::extension_url::SCHEME,
];

/// Whether typed text is one of the browser's own addresses.
///
/// Checked before the passthrough list rather than added to it, because these
/// are the one family of addresses that must never reach an engine — see
/// [`crate::internal_url`]. Anything claiming the scheme is navigated, page or
/// not: `zer0://nonsense` is our refusal to make, and turning it into a web
/// search would send the address of a page inside the browser to a search
/// engine.
fn is_ours(input: &str) -> bool {
    crate::internal_url::claims_scheme(input)
}

/// Resolve raw command-bar text.
///
/// `search_template` is a URL with `{}` where the query goes.
pub fn resolve(input: &str, search_template: &str) -> Resolved {
    let trimmed = input.trim();

    if trimmed.is_empty() {
        return Resolved::Search(String::new());
    }

    // Ours first, and before the passthrough list. These are the one family of
    // addresses that must never reach a web engine, and an unrecognised one is
    // still ours to refuse: searching for `zer0://nonsense` would put the
    // address of a page inside the browser into a search engine.
    if is_ours(trimmed) {
        return Resolved::Navigate(trimmed.to_string());
    }

    // An explicit scheme is the user being unambiguous. Respect it, but only
    // for schemes we know — otherwise "note:buy milk" would try to navigate.
    if let Ok(parsed) = Url::parse(trimmed)
        && PASSTHROUGH_SCHEMES.contains(&parsed.scheme())
    {
        return Resolved::Navigate(trimmed.to_string());
    }

    if looks_like_host(trimmed) {
        let scheme = if is_loopback(trimmed) {
            "http"
        } else {
            "https"
        };
        let candidate = format!("{scheme}://{trimmed}");
        if Url::parse(&candidate).is_ok() {
            return Resolved::Navigate(candidate);
        }
    }

    Resolved::Search(search_for(trimmed, search_template))
}

/// Search for this text, whatever it looks like.
///
/// Separate from [`resolve`] on purpose. `resolve` asks "did somebody type an
/// address or a query", which is the command bar's question; this one is asked
/// where the answer is already known — the page menu's "Search for …" row was
/// drawn over a selection, so selecting the words `example.com` and choosing it
/// must search for them rather than navigate somewhere the row did not offer.
///
/// The same function either way, so the search URL is spelled once.
pub fn search_for(query: &str, template: &str) -> String {
    template.replace("{}", &percent_encode(query))
}

/// A whitespace-bearing string is a search, never a host. Beyond that we want a
/// dot with something on both sides ("example.com"), or a loopback address.
fn looks_like_host(input: &str) -> bool {
    if input.chars().any(char::is_whitespace) {
        return false;
    }
    if is_loopback(input) {
        return true;
    }

    let host = input.split(['/', '?', '#']).next().unwrap_or(input);
    let host = host.split(':').next().unwrap_or(host);

    match host.rsplit_once('.') {
        // A trailing dot ("hello.") or an all-numeric TLD is not a hostname.
        Some((left, tld)) => {
            !left.is_empty() && !tld.is_empty() && tld.chars().all(|c| c.is_ascii_alphabetic())
        }
        None => false,
    }
}

fn is_loopback(input: &str) -> bool {
    let host = input.split(['/', '?', '#']).next().unwrap_or(input);
    let host = host.split(':').next().unwrap_or(host);
    host == "localhost" || host == "127.0.0.1" || host == "[::1]"
}

/// Minimal percent-encoding for query strings. Everything outside the
/// unreserved set gets escaped, which is stricter than needed but never wrong.
fn percent_encode(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for byte in s.as_bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(*byte as char);
            }
            b' ' => out.push('+'),
            other => out.push_str(&format!("%{other:02X}")),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    const DDG: &str = "https://duckduckgo.com/?q={}";

    fn nav(input: &str) -> Option<String> {
        match resolve(input, DDG) {
            Resolved::Navigate(u) => Some(u),
            Resolved::Search(_) => None,
        }
    }

    #[test]
    fn explicit_scheme_passes_through() {
        assert_eq!(
            nav("https://avelino.run").as_deref(),
            Some("https://avelino.run")
        );
        assert_eq!(nav("about:blank").as_deref(), Some("about:blank"));
        assert_eq!(
            nav("file:///tmp/a.html").as_deref(),
            Some("file:///tmp/a.html")
        );
    }

    /// The address of a page inside an extension is navigated to, never
    /// searched for. Measured before this: it came back
    /// `Search("https://duckduckgo.com/?q=webkit-extension%3A%2F%2F…")`, which
    /// is every extension's options page and every onboarding page it opens for
    /// itself arriving as a search result (ADR-0086).
    #[test]
    fn an_address_inside_an_extension_is_never_searched_for() {
        let page =
            "webkit-extension://142b180d-a643-4516-9b24-1cc01d08d781/app/app.html#/page/welcome";
        assert_eq!(nav(page).as_deref(), Some(page));
        // Including one naming a context that may not exist. Whether it does is
        // not a question this side can answer, and a search is the wrong answer
        // either way.
        assert_eq!(
            nav("webkit-extension://nothing-loaded-this/x.html").as_deref(),
            Some("webkit-extension://nothing-loaded-this/x.html")
        );
    }

    #[test]
    fn unknown_scheme_is_a_search() {
        // Otherwise a note-taking habit like "todo:call mom" would navigate.
        assert!(nav("todo:call mom").is_none());
        assert!(nav("mailto:a@b.com").is_none());
    }

    #[test]
    fn bare_host_gets_https() {
        assert_eq!(nav("avelino.run").as_deref(), Some("https://avelino.run"));
        assert_eq!(
            nav("github.com/avelino/zer0-browser").as_deref(),
            Some("https://github.com/avelino/zer0-browser")
        );
    }

    #[test]
    fn loopback_gets_http() {
        assert_eq!(
            nav("localhost:3000").as_deref(),
            Some("http://localhost:3000")
        );
        assert_eq!(
            nav("127.0.0.1:8080").as_deref(),
            Some("http://127.0.0.1:8080")
        );
    }

    #[test]
    fn prose_is_a_search() {
        assert!(nav("how to build a browser").is_none());
        assert!(nav("rust vs swift").is_none());
        // A sentence that happens to contain a dot is still a sentence.
        assert!(nav("i think. therefore i am").is_none());
    }

    #[test]
    fn near_miss_hostnames_are_searches() {
        assert!(nav("hello.").is_none());
        assert!(nav(".com").is_none());
        assert!(nav("version 1.2").is_none());
    }

    #[test]
    fn empty_input_searches_for_nothing() {
        assert_eq!(resolve("   ", DDG), Resolved::Search(String::new()));
    }

    #[test]
    fn search_query_is_encoded() {
        let Resolved::Search(url) = resolve("rust & swift", DDG) else {
            panic!("expected a search");
        };
        assert_eq!(url, "https://duckduckgo.com/?q=rust+%26+swift");
    }

    /// The command bar and the page menu ask different questions, and the row
    /// that says "Search for …" must not navigate.
    #[test]
    fn searching_for_something_that_looks_like_a_host_still_searches() {
        assert_eq!(
            search_for("example.com", DDG),
            "https://duckduckgo.com/?q=example.com"
        );
        // The same text through the command bar's question goes the other way.
        assert_eq!(nav("example.com").as_deref(), Some("https://example.com"));
    }

    #[test]
    fn surrounding_whitespace_is_ignored() {
        assert_eq!(
            nav("  avelino.run  ").as_deref(),
            Some("https://avelino.run")
        );
    }
}
