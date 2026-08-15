//! The command bar: one input for navigating, searching and switching tabs.
//!
//! Lives in the core so every platform shell ranks results identically. The
//! shell renders the list and reports which one was picked; it never decides
//! what the list contains.

use crate::bookmarks::{Bookmark, Bookmarks};
use crate::chat::PageAnchor;
use crate::history::{History, HistoryEntry};
use crate::model::{Browser, TabId};
use crate::protocol::{Action, ChatSubject};
use crate::url_input::{self, Resolved};

#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum Suggestion {
    /// The page is already open. Switching beats opening a second copy.
    SwitchToTab {
        tab: TabId,
        title: String,
        url: Option<String>,
    },
    /// Somewhere you decided to be able to come back to.
    ///
    /// Above [`Suggestion::OpenHistory`] in the ranking, and that is the whole
    /// reason it is a variant of its own rather than a history row with a flag:
    /// history is a record of where you *went*, a bookmark is a record of where
    /// you decided you would want to return. When both match what was typed,
    /// the deliberate one is what was meant.
    OpenBookmark { url: String, title: String },
    /// Somewhere you have been before.
    OpenHistory { url: String, title: Option<String> },
    /// What was typed is an address.
    Navigate { url: String },
    /// What was typed is a query.
    Search { query: String, url: String },
    /// The way out of navigating: ask instead of going.
    ///
    /// Offered for anything typed, and never for an empty bar. It sits at the
    /// bottom of the list rather than competing with the ranked rows, because
    /// it is not a guess about what you meant — it is the second door, and a
    /// door that moves around is a door nobody learns. Last is where a door you
    /// take on purpose belongs: it is the row furthest from the one Enter is
    /// already on, and asking is never what a reflex meant (ADR-0082).
    AskChat { question: String },
}

/// What the bar was opened to do.
///
/// One bar serves two gestures, so the gesture has to travel with it: ⌘L is an
/// address bar and changes where *this* tab is pointing, ⌘T opens somewhere
/// new. The ranking is the same either way — only the destination differs, and
/// a destination is behaviour, so which one a gesture means is decided here
/// rather than in whichever shell drew the panel.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum CommandBarIntent {
    /// ⌘L. Replace what the current tab is showing, the way every address bar
    /// has always worked.
    NavigateCurrentTab,
    /// ⌘T, and the ⌘↩ escape hatch. Leave the page you are on where it is.
    OpenNewTab,
}

/// The action picking `suggestion` means, given what the bar was opened to do.
///
/// The whole point of it living here: with this in the shell, ⌘L would navigate
/// on macOS and open a tab on Linux, and nobody would notice until someone
/// switched machines.
pub fn accept(browser: &Browser, intent: CommandBarIntent, suggestion: &Suggestion) -> Action {
    let url = match suggestion {
        // A page that is already open is switched to whichever gesture opened
        // the bar. Neither ⌘L nor ⌘T should produce a second copy of it.
        Suggestion::SwitchToTab { tab, .. } => return Action::ActivateTab { tab: *tab },
        // Asking is asking, whichever key opened the bar. ⌘L means "put this
        // somewhere" and ⌘T means "put this somewhere new", and neither
        // sentence has anything to say about a question — so the intent is
        // deliberately not consulted here, and a test says so.
        Suggestion::AskChat { question } => {
            return Action::OpenChat {
                about: ChatSubject::Nothing,
                ask: Some(question.clone()),
            };
        }
        // A kept address is a destination like any other. Which space it lands
        // in is the routing table's business (ADR-0026), not the bookmark's —
        // the bookmark has no space to have an opinion with.
        Suggestion::OpenBookmark { url, .. } => url,
        Suggestion::OpenHistory { url, .. } => url,
        Suggestion::Navigate { url } => url,
        Suggestion::Search { url, .. } => url,
    };

    match intent {
        CommandBarIntent::NavigateCurrentTab => match browser.active_tab() {
            Some(tab) => Action::NavigateTo {
                tab,
                input: url.clone(),
            },
            // Nothing to navigate. "Go here" still has to get you there, so it
            // opens the tab it needs: doing nothing is the one outcome the
            // person pressing Enter never wants.
            None => open_new_tab(url),
        },
        CommandBarIntent::OpenNewTab => open_new_tab(url),
    }
}

fn open_new_tab(url: &str) -> Action {
    Action::OpenTab {
        space: None,
        url: Some(url.to_string()),
        parent: None,
    }
}

/// Rank suggestions for `query`.
///
/// Five tiers, in this order, and the order is the decision:
///
/// 1. **What was typed** (ADR-0082). Somebody who pressed ⌘L or ⌘T and typed
///    almost always meant "go here" or "search this", and Enter is a reflex —
///    it has to do the thing that was meant without anybody arrowing anywhere.
///    It is also the escape hatch that never fails, so it is never crowded out.
/// 2. **Open tabs.** The page is already there. Switching costs nothing and
///    opening a second copy of it is the bug, whichever key opened the bar —
///    which is why one of them takes the top slot back, below.
/// 3. **Bookmarks.** Somebody decided to be able to come back to this.
/// 4. **History.** Somewhere you went, which may or may not have been on
///    purpose.
/// 5. **The way into chat**, always last. A question is a door taken on
///    purpose, so it sits as far from the reflex as the list allows.
///
/// ADR-0059 records why bookmarks sit where they sit; ADR-0082 why what was
/// typed sits above them and what buys back the one case that costs.
///
/// Tiers rather than one blended score, which is the shape this file already
/// had for tabs against history. A blend is what produces the failure ADR-0015
/// names: nobody praises the right order, and one inversion sends somebody
/// somewhere they did not ask for on a key they pressed without looking. A
/// tier is at least a rule a person can learn once.
///
/// An address is offered once. A tab suppresses the bookmark and the history
/// row for the same URL, and a bookmark suppresses the history row — so the
/// page you kept *and* visited four hundred times is one row, at the higher
/// position, rather than three rows that all do the same thing.
pub fn suggest(
    browser: &Browser,
    bookmarks: &Bookmarks,
    history: &History,
    query: &str,
    limit: usize,
) -> Vec<Suggestion> {
    let trimmed = query.trim();
    let mut out = Vec::new();

    if trimmed.is_empty() {
        // An empty bar offers where you were, not a search for nothing — and
        // deliberately not what you kept. "Where was I" and "what did I file"
        // are different questions, and history is the one you cannot answer any
        // other way without typing: bookmarks have a list of their own, and
        // letting them take a list of eight would leave nothing of it.
        out.extend(
            history
                .recent(limit)
                .into_iter()
                .map(|e| Suggestion::OpenHistory {
                    url: e.url.clone(),
                    title: e.title.clone(),
                }),
        );
        return out;
    }

    // Lowercased once for the whole ranking pass instead of once per candidate:
    // with a full history this is the difference between a bar that keeps up
    // with typing and one that does not.
    let needle = lowered(trimmed);

    let mut tabs: Vec<(u32, &crate::model::Tab)> = browser
        .all_tabs()
        .into_iter()
        .filter_map(|t| best_score(&needle, t.display_title(), t.url.as_deref()).map(|s| (s, t)))
        .collect();
    tabs.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| a.1.id.cmp(&b.1.id)));

    let mut kept: Vec<(u32, &Bookmark)> = bookmarks
        .all()
        .iter()
        .filter_map(|b| bookmark_score(&needle, b).map(|s| (s, b)))
        .collect();
    // Ties go to the one kept most recently, which is the order the list is
    // already in, so a stable sort is the whole tie-break.
    kept.sort_by_key(|(score, _)| std::cmp::Reverse(*score));

    let entries = ranked_history(history, &needle);

    // What was typed, first and unconditionally: the row Enter is already on
    // when the bar opens is the one somebody meant nine times out of ten, and
    // it is the escape hatch that works with zero results. Pushed before any
    // ranked row rather than inserted afterwards, so there is no arithmetic
    // that can drop it.
    out.push(
        match url_input::resolve(trimmed, browser.search_template()) {
            Resolved::Navigate(url) => Suggestion::Navigate { url },
            Resolved::Search(url) => Suggestion::Search {
                query: trimmed.to_string(),
                url,
            },
        },
    );

    // Reserve the last slot for the way into chat. The other escape hatch is
    // already in `out`, which is what the missing second slot paid for: both
    // are doors rather than guesses, so neither competes for rank.
    let room = limit.saturating_sub(1);
    for (_, tab) in tabs.iter() {
        if out.len() >= room {
            break;
        }
        out.push(Suggestion::SwitchToTab {
            tab: tab.id,
            title: tab.display_title().to_string(),
            url: tab.url.clone(),
        });
    }

    // Every address already spoken for by a row above. Grown as the list is
    // built rather than computed per tier, so "an address appears once" is one
    // rule at one place instead of one rule per pair of tiers.
    let mut already: Vec<&str> = tabs.iter().filter_map(|(_, t)| t.url.as_deref()).collect();

    for (_, bookmark) in kept.iter() {
        if out.len() >= room {
            break;
        }
        // A page that is already open is switched to, not opened again — the
        // fact that it is also kept does not change that.
        if already.contains(&bookmark.url.as_str()) {
            continue;
        }
        already.push(&bookmark.url);
        out.push(Suggestion::OpenBookmark {
            url: bookmark.url.clone(),
            title: bookmark.display_title().to_string(),
        });
    }

    for entry in entries.iter() {
        if out.len() >= room {
            break;
        }
        // Do not offer to reopen a URL that is already in a listed tab or
        // already offered as something you kept.
        if already.contains(&entry.url.as_str()) {
            continue;
        }
        out.push(Suggestion::OpenHistory {
            url: entry.url.clone(),
            title: entry.title.clone(),
        });
    }

    // Only when there is room for both doors. A one-row list keeps the one
    // that always works.
    if limit >= 2 {
        out.push(Suggestion::AskChat {
            question: trimmed.to_string(),
        });
    }

    a_tab_already_on_that_address_takes_the_top_slot(&mut out);
    out
}

/// The one exception to what was typed ranking first (ADR-0082).
///
/// Ranking the typed interpretation above everything trades away ADR-0015's
/// strongest claim — that switching to an open tab beats opening a second copy
/// — for exactly the case where the two collide: you type an address you
/// already have open. This buys that case back and nothing else. Typing
/// anything the tabs do not already hold goes straight where you asked.
///
/// **Deliberately one function with one caller**, so preferring Chrome's plain
/// behaviour later is deleting this and its call, not unpicking the ranking.
///
/// The typed row is moved down rather than dropped: it is still the escape
/// hatch, and "open it again anyway" is a real thing to want from a bar that
/// just decided on your behalf. Everything else keeps its order.
///
/// Whether two addresses are the same page is [`PageAnchor`]'s answer and not a
/// second one — ADR-0060 decided that question, and a rule that disagreed with
/// it here would mean "the same page" meant one thing to the bar and another to
/// the conversation about the page the bar opened. It follows that `http` is
/// not folded into `https` and `www.` is not stripped: this compares what was
/// typed against an address a navigation already committed to.
fn a_tab_already_on_that_address_takes_the_top_slot(out: &mut [Suggestion]) {
    // A search is not an address, so there is nothing for a tab to already
    // hold. Only `Navigate` can name a page.
    let Some(Suggestion::Navigate { url }) = out.first() else {
        return;
    };
    let Some(anchor) = PageAnchor::of(url) else {
        return;
    };
    let found = out.iter().position(|row| {
        // `if let` rather than a match with a wildcard: this picks one variant
        // out of a list, and a wildcard over `Suggestion` is the shape ADR-0031
        // forbids whatever it is being used for.
        if let Suggestion::SwitchToTab {
            url: Some(open), ..
        } = row
        {
            anchor.matches(open)
        } else {
            false
        }
    });
    if let Some(at) = found {
        out[..=at].rotate_right(1);
    }
}

/// History, ranked for what somebody typed. Best first.
///
/// **The one ranking of history there is**, and the reason it is a function
/// rather than a loop inside [`suggest`]: the history *page* asks the same
/// question the command bar asks, and a page with a search of its own would be
/// a second opinion about which of two pages answers "gh" better. Two rankings
/// disagree the day one of them gains a tie-break, and nobody notices, because
/// nobody praises the right order (ADR-0015).
///
/// `None` for an empty query is not "everything": an empty query is not a
/// ranking question at all, and each caller answers it in its own terms — the
/// bar offers where you were, the page shows the lot, newest first.
pub fn search_history<'a>(
    history: &'a History,
    query: &str,
    limit: usize,
) -> Vec<&'a HistoryEntry> {
    let trimmed = query.trim();
    if trimmed.is_empty() {
        return history.recent(limit);
    }
    let mut ranked = ranked_history(history, &lowered(trimmed));
    ranked.truncate(limit);
    ranked
}

/// The ranking itself, with the needle already lowercased so a pass over a full
/// history pays for that once rather than once per candidate.
fn ranked_history<'a>(history: &'a History, needle: &[char]) -> Vec<&'a HistoryEntry> {
    let mut entries: Vec<(u32, &HistoryEntry)> = history
        .entries()
        .filter_map(|e| {
            best_score(needle, e.title.as_deref().unwrap_or(""), Some(&e.url))
                .map(|s| (s + frecency_bonus(e.visit_count), e))
        })
        .collect();
    entries.sort_by(|a, b| {
        b.0.cmp(&a.0)
            .then_with(|| b.1.last_visit_ms.cmp(&a.1.last_visit_ms))
            .then_with(|| a.1.url.cmp(&b.1.url))
    });
    entries.into_iter().map(|(_, e)| e).collect()
}

/// Frequently visited pages should float up, but a popular page must never
/// outrank a good text match, so the bonus is capped well below match scores.
fn frecency_bonus(visit_count: u32) -> u32 {
    visit_count.min(20) * 2
}

/// How well a kept address answers what was typed.
///
/// Its title and address score exactly as a tab's do. A **tag scores as a
/// title**, not as a weaker field: a tag is not metadata the browser inferred,
/// it is a word somebody typed about this page on purpose, and it is often the
/// only word they remember. Typing "rust" and being shown the four pages you
/// labelled `rust` is the entire reason the labels are there.
///
/// No frecency bonus, and that is the decision rather than an omission.
/// Frequency is evidence the browser collected about a page; a bookmark is
/// evidence the person gave. Adding a visit-count bump on top would let a page
/// you keep and never open be reordered by how often you happen to land on it,
/// which is history's ranking wearing a bookmark's hat.
fn bookmark_score(needle: &[char], bookmark: &Bookmark) -> Option<u32> {
    let text = best_score(needle, bookmark.display_title(), Some(&bookmark.url));
    let tag = bookmark
        .tags
        .iter()
        .filter_map(|t| score_lowered(t, needle))
        .max();
    text.max(tag)
}

fn best_score(needle: &[char], title: &str, url: Option<&str>) -> Option<u32> {
    let title_score = score_lowered(title, needle);
    // A title match is worth more than a URL match: it is what the user reads.
    let url_score = url
        .and_then(|u| score_lowered(u, needle))
        .map(|s| s * 3 / 4);
    title_score.max(url_score)
}

/// How much of one string we are willing to look at.
///
/// Two problems, one bound. The run bonus grows with the square of the match
/// length, so an unbounded haystack overflows the score: "View Source" puts
/// `data:text/html,...` URLs of hundreds of kilobytes into history, and pasting
/// one into the bar was enough to panic a debug build. And scanning that on
/// every keystroke is time nobody has. No title or address anyone recognizes
/// runs this long, so the cut costs nothing real.
const MAX_SCAN_CHARS: usize = 1024;

/// Score `needle` against `haystack`, or `None` if the characters do not all
/// appear in order.
///
/// Rewards matches at the start, at word boundaries, and in runs, which is
/// what makes "gh" rank github.com above a page that merely contains g...h.
pub fn fuzzy_score(haystack: &str, needle: &str) -> Option<u32> {
    score_lowered(haystack, &lowered(needle))
}

/// Lowercase into characters, cut at the scan bound: a needle longer than what
/// we are willing to read can never match anyway.
fn lowered(text: &str) -> Vec<char> {
    text.chars()
        .flat_map(char::to_lowercase)
        .take(MAX_SCAN_CHARS + 1)
        .collect()
}

/// The scoring itself, with the needle already lowercased so a ranking pass
/// over the whole history pays for that once rather than once per candidate.
fn score_lowered(haystack: &str, needle: &[char]) -> Option<u32> {
    // Titles and addresses are ASCII almost every time, and folding a byte is
    // an order of magnitude cheaper than walking the Unicode case tables. Only
    // the stretch we are going to read is checked, so a huge `data:` URL costs
    // the bound and not its length. Under the bound one byte is one character,
    // so the byte walk sees exactly the characters the other branch would.
    let head = &haystack.as_bytes()[..haystack.len().min(MAX_SCAN_CHARS)];
    if head.is_ascii() {
        score_chars(
            haystack.bytes().map(|b| b.to_ascii_lowercase() as char),
            needle,
        )
    } else {
        score_chars(haystack.chars().flat_map(char::to_lowercase), needle)
    }
}

fn score_chars(haystack: impl Iterator<Item = char>, needle: &[char]) -> Option<u32> {
    if needle.is_empty() {
        return Some(1);
    }
    if needle.len() > MAX_SCAN_CHARS {
        return None;
    }

    let mut wanted = needle.iter();
    let mut next = wanted.next();
    let mut score = 0u32;
    let mut run = 0u32;
    let mut matched = 0usize;
    let mut seen = 0usize;
    let mut prev = None;

    // Streamed rather than collected: the haystack is read once, with no
    // allocation, which is where the per-keystroke cost used to go.
    for ch in haystack.take(MAX_SCAN_CHARS) {
        seen += 1;
        if let Some(&want) = next {
            if ch == want {
                next = wanted.next();
                matched += 1;

                score = score.saturating_add(10);
                if seen == 1 {
                    score = score.saturating_add(20);
                } else if prev.is_some_and(is_boundary) {
                    score = score.saturating_add(10);
                }
                // Weighted above the boundary bonus on purpose: "git" inside
                // "github.com" must beat "git" scattered through "a-g-i-t-hub",
                // where every letter sits on a boundary.
                run += 1;
                score = score.saturating_add(run * 8);
            } else {
                run = 0;
            }
        }
        prev = Some(ch);
    }

    if next.is_some() {
        return None;
    }
    // Prefer the shorter of two candidates that both match: "gh" against
    // "github.com" should beat "gh" against a long URL that happens to contain
    // both letters.
    let density = (matched * 20 / seen.max(1)) as u32;
    Some(score.saturating_add(density))
}

fn is_boundary(c: char) -> bool {
    matches!(c, ' ' | '.' | '/' | '-' | '_' | ':' | '?' | '&' | '=' | '#')
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::Action;
    use crate::reducer::dispatch;
    use crate::session::Session;

    fn setup() -> Session {
        Session::new("Personal", "ds-1")
    }

    /// The history page and the command bar rank history the same way, because
    /// they are the same function. This is the lock on that: the page's order
    /// is read out of `search_history` and the bar's out of `suggest`, and they
    /// have to agree row for row.
    ///
    /// Written against the *observable* order rather than against the call, so
    /// it survives either one being rewritten and goes red the moment the page
    /// grows a ranking of its own — which is the change that looks like an
    /// improvement (ADR-0015).
    #[test]
    fn the_page_ranks_history_exactly_as_the_command_bar_does() {
        let mut s = setup();
        // A weak text match visited constantly, against a strong one visited
        // once: the case a second ranking would get wrong first, because the
        // frecency bonus is capped and the cap is the decision.
        for _ in 0..50 {
            s.history
                .record("https://g.example.com/h", Some("noise".into()), 100);
        }
        s.history
            .record("https://github.com/", Some("GitHub".into()), 200);
        s.history
            .record("https://gist.github.com/", Some("Gist".into()), 300);

        let page: Vec<&str> = search_history(&s.history, "gh", 8)
            .iter()
            .map(|e| e.url.as_str())
            .collect();
        let bar: Vec<String> = suggest(&s.browser, &s.bookmarks, &s.history, "gh", 8)
            .into_iter()
            .filter_map(|row| match row {
                Suggestion::OpenHistory { url, .. } => Some(url),
                Suggestion::SwitchToTab { .. }
                | Suggestion::OpenBookmark { .. }
                | Suggestion::Navigate { .. }
                | Suggestion::Search { .. }
                | Suggestion::AskChat { .. } => None,
            })
            .collect();

        assert!(
            !bar.is_empty(),
            "the bar offered no history, so this proves nothing"
        );
        assert_eq!(page[..bar.len()], bar[..], "two rankings of one history");
    }

    /// An empty search is not a ranking question, and the page answers it the
    /// way a history is read: everything, newest first.
    #[test]
    fn an_empty_search_is_the_whole_list_newest_first() {
        let mut s = setup();
        s.history.record("https://old.com/", None, 100);
        s.history.record("https://new.com/", None, 300);
        s.history.record("https://mid.com/", None, 200);

        let urls: Vec<&str> = search_history(&s.history, "   ", 10)
            .iter()
            .map(|e| e.url.as_str())
            .collect();

        assert_eq!(
            urls,
            ["https://new.com/", "https://mid.com/", "https://old.com/"]
        );
    }

    /// What does not match is not offered. A search that falls back to the
    /// whole list is a search that says "no matches" by showing you everything.
    #[test]
    fn a_search_that_matches_nothing_returns_nothing() {
        let mut s = setup();
        s.history
            .record("https://github.com/", Some("GitHub".into()), 100);

        assert!(search_history(&s.history, "zzzz", 10).is_empty());
    }

    #[test]
    fn characters_must_appear_in_order() {
        assert!(fuzzy_score("github.com", "ghb").is_some());
        assert!(fuzzy_score("github.com", "bhg").is_none());
        assert!(fuzzy_score("github.com", "xyz").is_none());
    }

    #[test]
    fn matching_is_case_insensitive() {
        assert!(fuzzy_score("GitHub", "gith").is_some());
        assert!(fuzzy_score("github", "GITH").is_some());
    }

    #[test]
    fn a_prefix_match_beats_a_scattered_one() {
        let prefix = fuzzy_score("github.com", "git").unwrap();
        let scattered = fuzzy_score("a-g-i-t-hub", "git").unwrap();
        assert!(prefix > scattered, "{prefix} should beat {scattered}");
    }

    #[test]
    fn a_shorter_match_beats_a_longer_one() {
        let short = fuzzy_score("news.com", "news").unwrap();
        let long = fuzzy_score("news.com/2026/08/some-very-long-slug", "news").unwrap();
        assert!(short > long, "{short} should beat {long}");
    }

    #[test]
    fn a_huge_string_scores_without_overflowing() {
        // "View Source" writes `data:text/html,...` URLs of this size into
        // history. Pasting one into the bar used to overflow the run bonus and
        // panic the debug build.
        let huge = "a".repeat(100_000);

        assert!(fuzzy_score(&huge, "aaa").is_some());
        assert!(fuzzy_score(&huge, &huge).is_none());
        assert!(fuzzy_score("github.com", &huge).is_none());
        assert!(fuzzy_score(&format!("data:text/html,{huge}"), "data").is_some());
    }

    #[test]
    fn a_huge_history_entry_does_not_break_ranking() {
        let mut s = setup();
        s.history.record(
            &format!("data:text/html,{}", "x".repeat(200_000)),
            None,
            100,
        );
        s.history.record("https://data.com/", None, 101);

        let hits = suggest(&s.browser, &s.bookmarks, &s.history, "data", 5);

        assert!(matches!(hits.first(), Some(Suggestion::Search { .. })));
        assert!(hits.iter().any(|h| matches!(
            h,
            Suggestion::OpenHistory { url, .. } if url == "https://data.com/"
        )));
    }

    #[test]
    fn an_open_tab_outranks_history_for_the_same_page() {
        let mut s = setup();
        dispatch(
            &mut s,
            Action::OpenTab {
                space: None,
                url: None,
                parent: None,
            },
        );
        let tab = s.browser.active_tab().unwrap();
        dispatch(
            &mut s,
            Action::NavigationCommitted {
                tab,
                url: "https://github.com/".into(),
            },
        );
        dispatch(
            &mut s,
            Action::TitleChanged {
                tab,
                title: "GitHub".into(),
            },
        );

        // "github" is a word, not an address, so what was typed is a search and
        // the tab is the first thing ranked under it. Which is the point: the
        // tier order below the typed row did not move (ADR-0082).
        let hits = suggest(&s.browser, &s.bookmarks, &s.history, "github", 10);

        assert_eq!(tiers(&hits), ["typed", "tab", "ask"], "got {hits:?}");
        assert!(
            matches!(hits.get(1), Some(Suggestion::SwitchToTab { tab: t, .. }) if *t == tab),
            "got {hits:?}"
        );
        // The same URL must not also be offered as history.
        assert!(!hits.iter().any(|x| matches!(
            x,
            Suggestion::OpenHistory { url, .. } if url == "https://github.com/"
        )));
    }

    // MARK: - Where what you kept sits

    /// The ordering that matters, stated as one function so every ranking test
    /// below reads the same way: which tier each row came from, in order.
    fn tiers(hits: &[Suggestion]) -> Vec<&'static str> {
        hits.iter()
            .map(|h| match h {
                Suggestion::SwitchToTab { .. } => "tab",
                Suggestion::OpenBookmark { .. } => "bookmark",
                Suggestion::OpenHistory { .. } => "history",
                Suggestion::AskChat { .. } => "ask",
                Suggestion::Navigate { .. } | Suggestion::Search { .. } => "typed",
            })
            .collect()
    }

    #[test]
    fn a_bookmark_outranks_history_and_loses_to_an_open_tab() {
        // The whole ranking decision in one list. Nobody praises the right
        // order and one inversion sends somebody somewhere else on a key they
        // pressed without looking (ADR-0015), so it is pinned as an order and
        // not as three separate comparisons that could each pass while the list
        // came out wrong.
        let mut s = setup();
        let tab = open_a_tab(&mut s);
        dispatch(
            &mut s,
            Action::NavigationCommitted {
                tab,
                url: "https://rust-lang.org/open".into(),
            },
        );
        s.bookmarks
            .save("https://rust-lang.org/kept", "Rust, kept", 100);
        s.history.record("https://rust-lang.org/visited", None, 100);

        let hits = suggest(&s.browser, &s.bookmarks, &s.history, "rust", 6);

        assert_eq!(
            tiers(&hits),
            ["typed", "tab", "bookmark", "history", "ask"],
            "got {hits:?}"
        );
    }

    #[test]
    fn a_page_you_kept_and_visited_is_one_row_not_two() {
        // Otherwise the list is three ways of saying the same sentence, and the
        // two rows below the first are pure noise on a list of five.
        let mut s = setup();
        s.bookmarks.save("https://avelino.run/", "Avelino", 100);
        for _ in 0..40 {
            s.history.record("https://avelino.run/", None, 200);
        }

        let hits = suggest(&s.browser, &s.bookmarks, &s.history, "avelino", 6);

        assert_eq!(tiers(&hits), ["typed", "bookmark", "ask"], "got {hits:?}");
    }

    #[test]
    fn a_page_that_is_open_is_switched_to_even_when_it_is_also_kept() {
        // Being kept does not make a second copy of an already-open page the
        // right answer.
        let mut s = setup();
        let tab = open_a_tab(&mut s);
        dispatch(
            &mut s,
            Action::NavigationCommitted {
                tab,
                url: "https://avelino.run/".into(),
            },
        );
        s.bookmarks.save("https://avelino.run/", "Avelino", 100);

        let hits = suggest(&s.browser, &s.bookmarks, &s.history, "avelino", 6);

        assert_eq!(tiers(&hits), ["typed", "tab", "ask"], "got {hits:?}");
    }

    #[test]
    fn a_tag_finds_a_page_whose_title_says_nothing_of_the_kind() {
        // The reason the labels exist: a word you remember about a page, when
        // its title is not a word you remember.
        let mut s = setup();
        let id = s
            .bookmarks
            .save("https://doc.example/9c1f", "Untitled document", 100)
            .unwrap();
        s.bookmarks.edit(id, "Untitled document", &["taxes".into()]);

        let hits = suggest(&s.browser, &s.bookmarks, &s.history, "taxes", 6);

        assert!(
            hits.iter().any(|h| matches!(
                h,
                Suggestion::OpenBookmark { url, .. } if url == "https://doc.example/9c1f"
            )),
            "got {hits:?}"
        );
    }

    #[test]
    fn what_you_kept_never_crowds_out_the_way_forward() {
        // The two escape hatches survive any number of bookmarks, exactly as
        // they survive any amount of history.
        let mut s = setup();
        for i in 0..20 {
            s.bookmarks
                .save(&format!("https://site{i}.com/test"), "Test", 100 + i);
        }

        let hits = suggest(&s.browser, &s.bookmarks, &s.history, "test", 5);

        assert_eq!(hits.len(), 5);
        assert!(matches!(hits[0], Suggestion::Search { .. }));
        assert!(matches!(hits[4], Suggestion::AskChat { .. }));
    }

    #[test]
    fn an_empty_bar_still_offers_where_you_were() {
        // Bookmarks deliberately stay out of the empty bar. "Where was I" is
        // the question ⌘T asks with nothing typed, and history is the only
        // thing that answers it.
        let mut s = setup();
        s.history.record("https://visited.com/", None, 100);
        s.bookmarks.save("https://kept.com/", "Kept", 100);

        let hits = suggest(&s.browser, &s.bookmarks, &s.history, "", 5);

        assert_eq!(tiers(&hits), ["history"], "got {hits:?}");
    }

    #[test]
    fn opening_something_you_kept_goes_where_the_gesture_meant() {
        // A bookmark is a destination like any other: ⌘L puts it in this tab,
        // ⌘T puts it in a new one. Nothing about having been kept changes that.
        let mut s = setup();
        let tab = open_a_tab(&mut s);
        let suggestion = Suggestion::OpenBookmark {
            url: "https://avelino.run/".into(),
            title: "Avelino".into(),
        };

        assert_eq!(
            accept(
                &s.browser,
                CommandBarIntent::NavigateCurrentTab,
                &suggestion
            ),
            Action::NavigateTo {
                tab,
                input: "https://avelino.run/".into(),
            }
        );
        assert_eq!(
            accept(&s.browser, CommandBarIntent::OpenNewTab, &suggestion),
            Action::OpenTab {
                space: None,
                url: Some("https://avelino.run/".into()),
                parent: None,
            }
        );
    }

    /// The replacement for `the_typed_interpretation_is_always_offered_last`,
    /// which defended the order ADR-0082 reversed. Same force, other direction:
    /// what was typed is offered, and it is offered first, whether it reads as
    /// an address or as a question — with an empty browser and with a browser
    /// full of better-scoring rows.
    #[test]
    fn the_typed_interpretation_is_always_offered_first() {
        let mut s = setup();

        for query in ["how do i center a div", "avelino.run"] {
            let hits = suggest(&s.browser, &s.bookmarks, &s.history, query, 5);
            assert_eq!(
                tiers(&hits).first(),
                Some(&"typed"),
                "{query:?} came back as {hits:?}"
            );
        }

        // Again with every other tier competing, because "first" is only worth
        // anything when there was something to be first of. None of these is
        // the address typed below, so nothing here takes the top slot back.
        let tab = open_a_tab(&mut s);
        dispatch(
            &mut s,
            Action::NavigationCommitted {
                tab,
                url: "https://avelino.run/posts".into(),
            },
        );
        s.bookmarks.save("https://avelino.run/kept", "Kept", 100);
        s.history.record("https://avelino.run/seen", None, 100);

        for query in ["avelino something", "avelino.run/new"] {
            let hits = suggest(&s.browser, &s.bookmarks, &s.history, query, 6);
            assert_eq!(
                tiers(&hits).first(),
                Some(&"typed"),
                "{query:?} came back as {hits:?}"
            );
        }
    }

    #[test]
    fn the_fallback_survives_a_full_result_list() {
        let mut s = setup();
        for i in 0..20 {
            s.history
                .record(&format!("https://site{i}.com/test"), None, 100 + i);
        }

        let hits = suggest(&s.browser, &s.bookmarks, &s.history, "test", 5);

        assert_eq!(hits.len(), 5);
        assert!(
            matches!(hits.first(), Some(Suggestion::Search { .. })),
            "the escape hatch must never be crowded out: {hits:?}"
        );
    }

    // MARK: - Typing an address you already have open

    /// The one exception, and the reason ADR-0082 does not simply hand
    /// ADR-0015's best claim away: an address you already have open still
    /// switches. This is the test that goes red if
    /// `a_tab_already_on_that_address_takes_the_top_slot` is deleted, which is
    /// exactly what somebody preferring Chrome's plain behaviour would delete.
    #[test]
    fn an_address_you_already_have_open_switches_instead_of_opening_a_second_copy() {
        let mut s = setup();
        let tab = open_a_tab(&mut s);
        dispatch(
            &mut s,
            Action::NavigationCommitted {
                tab,
                url: "https://github.com/".into(),
            },
        );

        let hits = suggest(&s.browser, &s.bookmarks, &s.history, "github.com", 5);

        assert!(
            matches!(hits.first(), Some(Suggestion::SwitchToTab { tab: t, .. }) if *t == tab),
            "got {hits:?}"
        );
        // Moved down, never dropped. "Open it again anyway" is one row away,
        // and the escape hatch is still on the list.
        assert!(
            matches!(hits.get(1), Some(Suggestion::Navigate { url }) if url == "https://github.com"),
            "got {hits:?}"
        );

        // An address no tab is on goes straight where it was asked to go,
        // which is the whole point of the change this qualifies.
        let elsewhere = suggest(&s.browser, &s.bookmarks, &s.history, "gitlab.com", 5);
        assert!(
            matches!(elsewhere.first(), Some(Suggestion::Navigate { .. })),
            "got {elsewhere:?}"
        );
    }

    /// Both sides of the comparison are normalised, and neither is normalised
    /// here: the address the tab committed to is spelled as loosely as the one
    /// somebody types, so a rule that only tidied the typed side — or that
    /// compared the two as strings — is red rather than accidentally green.
    #[test]
    fn an_address_spelled_two_ways_is_the_page_you_have_open() {
        let mut s = setup();
        let tab = open_a_tab(&mut s);
        dispatch(
            &mut s,
            Action::NavigationCommitted {
                tab,
                url: "https://GitHub.com/docs/".into(),
            },
        );
        let other = open_a_tab(&mut s);
        dispatch(
            &mut s,
            Action::NavigationCommitted {
                tab: other,
                url: "https://www.avelino.run/".into(),
            },
        );

        // The same page, decided by `PageAnchor` and by nothing else: host
        // case and a trailing slash are punctuation (ADR-0060).
        for typed in ["github.com/docs", "GitHub.com/docs/"] {
            let hits = suggest(&s.browser, &s.bookmarks, &s.history, typed, 6);
            assert!(
                matches!(hits.first(), Some(Suggestion::SwitchToTab { tab: t, .. }) if *t == tab),
                "{typed:?} came back as {hits:?}"
            );
        }

        // And the cost, asserted rather than left to be discovered: nothing is
        // folded that the site has not folded itself, so a scheme or a `www.`
        // spelled differently opens a second copy. The tab is still on the
        // list — it just does not hold the row Enter is on.
        for (typed, open) in [("http://github.com/docs", tab), ("avelino.run", other)] {
            let hits = suggest(&s.browser, &s.bookmarks, &s.history, typed, 6);
            assert!(
                matches!(hits.first(), Some(Suggestion::Navigate { .. })),
                "{typed:?} came back as {hits:?}"
            );
            assert!(
                hits.iter()
                    .any(|h| matches!(h, Suggestion::SwitchToTab { tab: t, .. } if *t == open)),
                "{typed:?} did not even offer the tab, so this proves nothing: {hits:?}"
            );
        }
    }

    #[test]
    fn an_empty_query_offers_recent_history_not_a_search() {
        let mut s = setup();
        s.history.record("https://a.com/", None, 100);

        let hits = suggest(&s.browser, &s.bookmarks, &s.history, "   ", 5);

        assert!(matches!(hits.as_slice(), [Suggestion::OpenHistory { .. }]));
    }

    #[test]
    fn frequently_visited_pages_float_up() {
        let mut s = setup();
        s.history.record("https://rare.com/rust", None, 100);
        for _ in 0..10 {
            s.history.record("https://often.com/rust", None, 100);
        }

        let hits = suggest(&s.browser, &s.bookmarks, &s.history, "rust", 10);

        // `if let` rather than a match with a wildcard: this is picking one
        // variant out of a list, not deciding what to do with each of them, and
        // a wildcard over `Suggestion` is the shape ADR-0031 forbids whatever
        // it is being used for.
        let first = hits
            .iter()
            .find_map(|x| {
                if let Suggestion::OpenHistory { url, .. } = x {
                    Some(url.as_str())
                } else {
                    None
                }
            })
            .unwrap();
        assert_eq!(first, "https://often.com/rust");
    }

    #[test]
    #[ignore]
    fn bench_suggest() {
        let mut s = setup();
        for i in 0..10_000u64 {
            s.history.record(
                &format!("https://site{i}.example.com/some/path/segment-{i}?q={i}"),
                Some(format!("Page number {i} of the example site")),
                100 + i,
            );
        }
        let n = 20;
        let start = std::time::Instant::now();
        for _ in 0..n {
            std::hint::black_box(suggest(&s.browser, &s.bookmarks, &s.history, "exam", 10));
        }
        let el = start.elapsed();
        println!("suggest(): {:?} total, {:?}/keystroke", el, el / n);
    }

    // MARK: - Where a chosen destination lands

    fn open_a_tab(s: &mut Session) -> TabId {
        dispatch(
            s,
            Action::OpenTab {
                space: None,
                url: None,
                parent: None,
            },
        );
        s.browser.active_tab().unwrap()
    }

    /// Every suggestion that means "somewhere new", so the intent is checked
    /// against all of them rather than against whichever one came to mind.
    fn destinations() -> Vec<Suggestion> {
        vec![
            Suggestion::OpenHistory {
                url: "https://avelino.run/".into(),
                title: None,
            },
            Suggestion::Navigate {
                url: "https://avelino.run/".into(),
            },
            Suggestion::Search {
                query: "avelino".into(),
                url: "https://avelino.run/".into(),
            },
        ]
    }

    #[test]
    fn open_location_navigates_the_tab_you_are_looking_at() {
        // The whole point: ⌘L is an address bar. Opening a second tab is what
        // Chrome users would call the browser being broken.
        let mut s = setup();
        let tab = open_a_tab(&mut s);

        for suggestion in destinations() {
            assert_eq!(
                accept(
                    &s.browser,
                    CommandBarIntent::NavigateCurrentTab,
                    &suggestion
                ),
                Action::NavigateTo {
                    tab,
                    input: "https://avelino.run/".into(),
                },
                "{suggestion:?} should have navigated this tab"
            );
        }
    }

    #[test]
    fn new_tab_leaves_the_page_you_are_on_alone() {
        let mut s = setup();
        open_a_tab(&mut s);

        for suggestion in destinations() {
            assert_eq!(
                accept(&s.browser, CommandBarIntent::OpenNewTab, &suggestion),
                Action::OpenTab {
                    space: None,
                    url: Some("https://avelino.run/".into()),
                    parent: None,
                },
                "{suggestion:?} should have opened a tab"
            );
        }
    }

    #[test]
    fn open_location_with_nothing_open_opens_a_tab() {
        // No tab to navigate, so "the current tab" has to become one. Enter
        // that does nothing is worse than Enter that does the obvious thing.
        let s = setup();
        assert_eq!(s.browser.active_tab(), None);

        let action = accept(
            &s.browser,
            CommandBarIntent::NavigateCurrentTab,
            &Suggestion::Navigate {
                url: "https://avelino.run/".into(),
            },
        );

        assert_eq!(
            action,
            Action::OpenTab {
                space: None,
                url: Some("https://avelino.run/".into()),
                parent: None,
            }
        );
    }

    #[test]
    fn picking_an_open_tab_switches_to_it_either_way() {
        // Switching beats opening a second copy, and which gesture opened the
        // bar has nothing to do with it.
        let mut s = setup();
        let tab = open_a_tab(&mut s);
        let other = open_a_tab(&mut s);
        let suggestion = Suggestion::SwitchToTab {
            tab,
            title: "GitHub".into(),
            url: Some("https://github.com/".into()),
        };
        assert_eq!(s.browser.active_tab(), Some(other));

        for intent in [
            CommandBarIntent::NavigateCurrentTab,
            CommandBarIntent::OpenNewTab,
        ] {
            assert_eq!(
                accept(&s.browser, intent, &suggestion),
                Action::ActivateTab { tab },
                "{intent:?} should have switched to the open tab"
            );
        }
    }

    #[test]
    fn open_location_does_not_pile_up_tabs() {
        // The same thing again, but carried through the reducer: the count is
        // what the person actually sees in the sidebar.
        let mut s = setup();
        let tab = open_a_tab(&mut s);

        let action = accept(
            &s.browser,
            CommandBarIntent::NavigateCurrentTab,
            &Suggestion::Navigate {
                url: "https://avelino.run/".into(),
            },
        );
        dispatch(&mut s, action);

        assert_eq!(s.browser.all_tabs().len(), 1);
        assert_eq!(s.browser.active_tab(), Some(tab));
        assert_eq!(
            s.browser.tab(tab).unwrap().pending_url.as_deref(),
            Some("https://avelino.run/")
        );
    }

    #[test]
    fn nothing_matching_still_gives_you_a_way_forward() {
        let s = setup();
        let hits = suggest(&s.browser, &s.bookmarks, &s.history, "zzzzqqq", 5);
        // Two ways forward, and the one that always works is the one Enter is
        // already on.
        assert_eq!(hits.len(), 2);
        assert!(matches!(hits[0], Suggestion::Search { .. }));
        assert!(matches!(hits[1], Suggestion::AskChat { .. }));
    }

    // MARK: - Falling into chat

    #[test]
    fn asking_is_offered_for_anything_typed_and_sits_last() {
        let s = setup();

        for query in ["how do i center a div", "avelino.run", "x"] {
            let hits = suggest(&s.browser, &s.bookmarks, &s.history, query, 5);
            let at = hits
                .iter()
                .position(|h| matches!(h, Suggestion::AskChat { .. }))
                .unwrap_or_else(|| panic!("no way into chat for {query:?}: {hits:?}"));

            assert_eq!(
                at,
                hits.len() - 1,
                "the chat row belongs at the bottom of the list: {hits:?}"
            );
            assert!(matches!(
                hits[at],
                Suggestion::AskChat { ref question } if question == query
            ));
        }

        // Again with every tier under it. "Last" is not a question an empty
        // browser can answer: with nothing ranked, a chat row pushed anywhere
        // still comes out at the end, and this test was green for that reason
        // while the row sat above history.
        let mut s = setup();
        let tab = open_a_tab(&mut s);
        dispatch(
            &mut s,
            Action::NavigationCommitted {
                tab,
                url: "https://avelino.run/one".into(),
            },
        );
        s.bookmarks.save("https://avelino.run/two", "Two", 100);
        s.history.record("https://avelino.run/three", None, 100);

        let hits = suggest(&s.browser, &s.bookmarks, &s.history, "avelino.run", 6);

        assert_eq!(
            tiers(&hits),
            ["typed", "tab", "bookmark", "history", "ask"],
            "got {hits:?}"
        );
    }

    #[test]
    fn an_empty_bar_offers_no_way_into_chat() {
        // There is nothing to ask. A row that sends an empty question to a
        // provider is a row that costs money to press by accident.
        let mut s = setup();
        s.history.record("https://a.com/", None, 100);

        let hits = suggest(&s.browser, &s.bookmarks, &s.history, "   ", 5);

        assert!(!hits.iter().any(|h| matches!(h, Suggestion::AskChat { .. })));
    }

    #[test]
    fn both_escape_hatches_survive_a_full_result_list() {
        let mut s = setup();
        for i in 0..20 {
            s.history
                .record(&format!("https://site{i}.com/test"), None, 100 + i);
        }

        let hits = suggest(&s.browser, &s.bookmarks, &s.history, "test", 5);

        assert_eq!(hits.len(), 5);
        assert!(matches!(hits[0], Suggestion::Search { .. }));
        assert!(matches!(hits[4], Suggestion::AskChat { .. }));
    }

    #[test]
    fn asking_means_the_same_thing_whichever_key_opened_the_bar() {
        // ⌘L says "put this somewhere" and ⌘T says "somewhere new". Neither
        // sentence has an opinion about a question, so neither changes it.
        let mut s = setup();
        open_a_tab(&mut s);
        let suggestion = Suggestion::AskChat {
            question: "why is the sky blue".into(),
        };

        for intent in [
            CommandBarIntent::NavigateCurrentTab,
            CommandBarIntent::OpenNewTab,
        ] {
            assert_eq!(
                accept(&s.browser, intent, &suggestion),
                Action::OpenChat {
                    about: ChatSubject::Nothing,
                    ask: Some("why is the sky blue".into()),
                },
                "{intent:?} should have asked"
            );
        }
    }

    #[test]
    fn asking_from_the_bar_never_touches_the_page_you_are_on() {
        // A question typed into the command bar is not about the page — the
        // person was navigating a second ago. Attaching whatever happened to be
        // open would send a page nobody mentioned to a provider.
        let mut s = setup();
        let tab = open_a_tab(&mut s);
        dispatch(
            &mut s,
            Action::NavigationCommitted {
                tab,
                url: "https://bank.example/statements".into(),
            },
        );

        let action = accept(
            &s.browser,
            CommandBarIntent::NavigateCurrentTab,
            &Suggestion::AskChat {
                question: "hello".into(),
            },
        );

        assert_eq!(
            action,
            Action::OpenChat {
                about: ChatSubject::Nothing,
                ask: Some("hello".into()),
            }
        );
    }
}
