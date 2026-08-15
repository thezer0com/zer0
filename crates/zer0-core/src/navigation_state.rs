//! Where a tab has been, in the engine's own words.
//!
//! A tab's back and forward list is not something this core can describe. The
//! engine holds it — scroll offsets, form values, the document identifiers that
//! make going back restore a page rather than fetch it again — and the only
//! handle either engine offers is an opaque archive: `WKWebView.interactionState`
//! on Apple, the session state on webkit2gtk. So the core stores bytes it cannot
//! read, keyed by the tab they belong to, and hands them back when that tab's
//! view is built.
//!
//! **Not a field on [`Tab`].** A `Tab` crosses the FFI in every
//! [`BrowserSnapshot`], several times a second, and a blob measured at 340 bytes
//! per history entry would be copied out of the core on every redraw to draw a
//! row in a sidebar that has no use for it. The same argument ADR-0044 makes for
//! icons: the thing itself lives to one side, and only what a shell needs to
//! draw travels.
//!
//! **The size cap is here and nowhere else.** This is the one door: the live
//! report from the engine and the read from a session file both arrive through
//! [`NavigationStates::set`], so an absurd blob cannot enter by either. It is
//! the only check available — the bytes are opaque, so "is this a valid state"
//! is a question nothing on this side of the FFI can answer, and the engine's
//! answer is that it silently keeps nothing (measured: a truncated one, a random
//! one and an empty one all leave a working view with no history on it).
//!
//! [`Tab`]: crate::model::Tab
//! [`BrowserSnapshot`]: crate::ffi::BrowserSnapshot

use std::collections::HashMap;

use crate::model::TabId;

/// The most a single tab's navigation state may weigh.
///
/// Measured on macOS 26.5: a fresh `WKWebView` reports 137 bytes, one page 730,
/// three pages 1,406 and twelve pages 4,457 — a little over 340 bytes per entry
/// after the fixed header. WebKit caps a back/forward list at 100 entries, so
/// the largest state a real tab can produce is on the order of 35 KB, and this
/// clears that by roughly thirty times.
///
/// It is a ceiling on damage, not a validity test: a file that hands over four
/// megabytes for one tab is a file that has been tampered with or corrupted, and
/// the cost of taking it is real memory in every future snapshot, and a real
/// slice of every save, for a tab whose history cannot be that long.
pub const MAX_STATE_BYTES: usize = 1024 * 1024;

/// One opaque navigation state per tab, for the tabs that have one.
///
/// Absent is the ordinary case: a tab that has not navigated yet, one whose
/// state was refused, and every tab in a browser that has never saved.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct NavigationStates {
    by_tab: HashMap<TabId, Vec<u8>>,
}

impl NavigationStates {
    pub fn new() -> Self {
        Self::default()
    }

    /// What came off disk. Every entry goes through [`NavigationStates::set`],
    /// so a stored blob is held to the same limit a live one is (ADR-0024).
    pub fn load(entries: impl IntoIterator<Item = (TabId, Vec<u8>)>) -> Self {
        let mut states = Self::new();
        for (tab, state) in entries {
            states.set(tab, state);
        }
        states
    }

    /// Remember this tab's state, or forget it.
    ///
    /// Empty is forget rather than store: an engine with nothing to say hands
    /// back nothing, and a zero-length archive restores no history anyway. The
    /// oversized case is also forget, and deliberately not "store a truncated
    /// copy" — half an archive is not a shorter history, it is one the engine
    /// refuses whole, and keeping it would cost the bytes and buy nothing.
    pub fn set(&mut self, tab: TabId, state: Vec<u8>) {
        if state.is_empty() || state.len() > MAX_STATE_BYTES {
            self.by_tab.remove(&tab);
            return;
        }
        self.by_tab.insert(tab, state);
    }

    /// The tab's state, if there is one worth handing to an engine.
    pub fn get(&self, tab: TabId) -> Option<&[u8]> {
        self.by_tab.get(&tab).map(|s| s.as_slice())
    }

    /// The tab is gone, and so is anything the engine knew about it.
    pub fn forget(&mut self, tab: TabId) {
        self.by_tab.remove(&tab);
    }

    /// How many tabs have one. For tests and for whoever wonders what this
    /// costs.
    pub fn len(&self) -> usize {
        self.by_tab.len()
    }

    pub fn is_empty(&self) -> bool {
        self.by_tab.is_empty()
    }
}

#[cfg(test)]
#[path = "navigation_state_tests.rs"]
mod tests;
