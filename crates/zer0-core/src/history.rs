//! Visit history.
//!
//! Kept separate from [`crate::model::Browser`] because it outlives any
//! session: tabs come and go, history accumulates.

use std::collections::HashMap;

#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct HistoryEntry {
    pub url: String,
    pub title: Option<String>,
    pub visit_count: u32,
    pub last_visit_ms: u64,
}

/// How far back "clear my history" reaches.
///
/// Spans, not calendar days, and that is the decision rather than a shortcut.
/// "Today" is a question about a timezone and a calendar; the core has neither
/// and should not grow one to answer a delete. "The last hour" and "the last
/// 24 hours" mean the same thing in every timezone there is, so they can be
/// arithmetic on the clock the shell already hands in — and a person clearing
/// history wants a span they can reason about, not a boundary that moves at
/// midnight while they are still working.
///
/// A closed set for the usual reason: a range nobody wrote a cutoff for would
/// have to fall through to something, and every something here deletes either
/// too much or too little.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum HistoryRange {
    LastHour,
    LastDay,
    Everything,
}

impl HistoryRange {
    /// The instant this range starts at. Everything visited at or after it goes.
    ///
    /// `now_ms` is handed in rather than read, the same way
    /// `mcp_handshake_expired` takes it: the core has no clock, and one that
    /// only exists in tests is a clock that lies in production.
    pub fn cutoff_ms(self, now_ms: u64) -> u64 {
        const HOUR_MS: u64 = 60 * 60 * 1000;
        match self {
            HistoryRange::LastHour => now_ms.saturating_sub(HOUR_MS),
            HistoryRange::LastDay => now_ms.saturating_sub(24 * HOUR_MS),
            // Not `now_ms - something_large`: a subtraction that saturates is a
            // range that happens to reach far enough, and "far enough" is a
            // property of the numbers rather than of the decision.
            HistoryRange::Everything => 0,
        }
    }
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct History {
    by_url: HashMap<String, HistoryEntry>,
}

impl History {
    pub fn new() -> Self {
        Self::default()
    }

    /// Record a visit. Revisiting a URL bumps its count rather than adding a
    /// duplicate, which is what makes frecency ranking possible later.
    pub fn record(&mut self, url: &str, title: Option<String>, now_ms: u64) {
        if url.is_empty() {
            return;
        }
        self.by_url
            .entry(url.to_string())
            .and_modify(|e| {
                e.visit_count += 1;
                e.last_visit_ms = now_ms;
                if title.is_some() {
                    e.title = title.clone();
                }
            })
            .or_insert_with(|| HistoryEntry {
                url: url.to_string(),
                title,
                visit_count: 1,
                last_visit_ms: now_ms,
            });
    }

    /// Titles arrive after the navigation commits, so they are filled in late.
    pub fn set_title(&mut self, url: &str, title: &str) {
        if let Some(entry) = self.by_url.get_mut(url) {
            entry.title = if title.is_empty() {
                None
            } else {
                Some(title.to_string())
            };
        }
    }

    pub fn get(&self, url: &str) -> Option<&HistoryEntry> {
        self.by_url.get(url)
    }

    pub fn len(&self) -> usize {
        self.by_url.len()
    }

    pub fn is_empty(&self) -> bool {
        self.by_url.is_empty()
    }

    pub fn entries(&self) -> impl Iterator<Item = &HistoryEntry> {
        self.by_url.values()
    }

    /// Restore from storage without counting the load as a visit.
    pub fn load(entries: Vec<HistoryEntry>) -> Self {
        Self {
            by_url: entries.into_iter().map(|e| (e.url.clone(), e)).collect(),
        }
    }

    /// Most recently visited first. Ties broken by URL so the order is stable.
    pub fn recent(&self, limit: usize) -> Vec<&HistoryEntry> {
        let mut all: Vec<&HistoryEntry> = self.by_url.values().collect();
        all.sort_by(|a, b| {
            b.last_visit_ms
                .cmp(&a.last_visit_ms)
                .then_with(|| a.url.cmp(&b.url))
        });
        all.truncate(limit);
        all
    }

    pub fn forget(&mut self, url: &str) {
        self.by_url.remove(url);
    }

    /// Forget everything last visited at or after `cutoff_ms`.
    ///
    /// The one way history is cleared, so "clear the last hour" and "clear
    /// everything" are one path with a number on it rather than two paths that
    /// drift. An entry is judged by its *last* visit: a page first seen a year
    /// ago and opened again ten minutes ago is part of the last ten minutes,
    /// which is what somebody clearing the last hour means.
    pub fn forget_since(&mut self, cutoff_ms: u64) {
        self.by_url.retain(|_, e| e.last_visit_ms < cutoff_ms);
    }

    pub fn clear(&mut self) {
        self.by_url.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn revisiting_bumps_the_count_instead_of_duplicating() {
        let mut h = History::new();
        h.record("https://a.com/", None, 100);
        h.record("https://a.com/", None, 200);

        assert_eq!(h.len(), 1);
        let entry = h.get("https://a.com/").unwrap();
        assert_eq!(entry.visit_count, 2);
        assert_eq!(entry.last_visit_ms, 200);
    }

    #[test]
    fn titles_can_be_filled_in_after_the_visit() {
        let mut h = History::new();
        h.record("https://a.com/", None, 100);

        h.set_title("https://a.com/", "Hello");

        assert_eq!(
            h.get("https://a.com/").unwrap().title.as_deref(),
            Some("Hello")
        );
    }

    #[test]
    fn an_empty_title_clears_rather_than_stores_blank() {
        let mut h = History::new();
        h.record("https://a.com/", Some("Hello".into()), 100);

        h.set_title("https://a.com/", "");

        assert_eq!(h.get("https://a.com/").unwrap().title, None);
    }

    #[test]
    fn a_revisit_without_a_title_keeps_the_one_we_had() {
        let mut h = History::new();
        h.record("https://a.com/", Some("Hello".into()), 100);

        h.record("https://a.com/", None, 200);

        assert_eq!(
            h.get("https://a.com/").unwrap().title.as_deref(),
            Some("Hello")
        );
    }

    #[test]
    fn empty_urls_are_not_recorded() {
        let mut h = History::new();
        h.record("", None, 100);
        assert!(h.is_empty());
    }

    #[test]
    fn recent_is_newest_first() {
        let mut h = History::new();
        h.record("https://old.com/", None, 100);
        h.record("https://new.com/", None, 300);
        h.record("https://mid.com/", None, 200);

        let urls: Vec<_> = h.recent(2).iter().map(|e| e.url.as_str()).collect();
        assert_eq!(urls, vec!["https://new.com/", "https://mid.com/"]);
    }

    /// A range clears what falls inside it and leaves the rest, and the widest
    /// range is still the same one path.
    #[test]
    fn a_range_clears_only_what_falls_inside_it() {
        const HOUR: u64 = 60 * 60 * 1000;
        let now = 1_000 * HOUR;

        let mut h = History::new();
        h.record("https://minutes-ago.com/", None, now - 60_000);
        h.record("https://this-morning.com/", None, now - 5 * HOUR);
        h.record("https://last-week.com/", None, now - 200 * HOUR);

        h.forget_since(HistoryRange::LastHour.cutoff_ms(now));
        assert!(h.get("https://minutes-ago.com/").is_none());
        assert!(h.get("https://this-morning.com/").is_some());

        h.forget_since(HistoryRange::LastDay.cutoff_ms(now));
        assert!(h.get("https://this-morning.com/").is_none());
        assert!(h.get("https://last-week.com/").is_some());

        h.forget_since(HistoryRange::Everything.cutoff_ms(now));
        assert!(h.is_empty());
    }

    /// A page revisited a minute ago is part of the last hour however long ago
    /// it was first seen. Judging by a first visit would leave the page
    /// somebody just opened sitting in a history they just cleared.
    #[test]
    fn a_range_judges_an_entry_by_its_last_visit() {
        const HOUR: u64 = 60 * 60 * 1000;
        let now = 1_000 * HOUR;

        let mut h = History::new();
        h.record("https://a.com/", None, now - 90 * HOUR);
        h.record("https://a.com/", None, now - 60_000);

        h.forget_since(HistoryRange::LastHour.cutoff_ms(now));

        assert!(h.is_empty());
    }

    /// The spans are the spans they are named after, to the millisecond. A
    /// "last hour" that quietly reached back ninety minutes would delete more
    /// than anybody agreed to, and nothing on screen would say so.
    #[test]
    fn a_span_reaches_back_exactly_as_far_as_it_says() {
        const HOUR: u64 = 60 * 60 * 1000;
        let now = 1_000 * HOUR;

        assert_eq!(HistoryRange::LastHour.cutoff_ms(now), now - HOUR);
        assert_eq!(HistoryRange::LastDay.cutoff_ms(now), now - 24 * HOUR);
        assert_eq!(HistoryRange::Everything.cutoff_ms(now), 0);
    }

    #[test]
    fn loading_from_storage_does_not_count_as_a_visit() {
        let h = History::load(vec![HistoryEntry {
            url: "https://a.com/".into(),
            title: None,
            visit_count: 7,
            last_visit_ms: 100,
        }]);

        assert_eq!(h.get("https://a.com/").unwrap().visit_count, 7);
    }
}
