//! Browser state model.
//!
//! Field choices here are constrained by two things at once: the Arc-style UX
//! (tab tree, pinned tabs, per-space isolation) and the `WKWebExtensionTab`
//! protocol, which requires the shell to answer a fixed set of per-tab
//! questions. Both want the same shape, so the model serves both.

use std::collections::HashMap;

use crate::tint::PageTint;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct TabId(pub u64);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct SpaceId(pub u64);

/// A browser window: one place on screen where pages are shown.
///
/// Windows are in the core rather than the shell because *which windows exist
/// and what is in each of them* is behaviour — a key press has to land in the
/// window the person is looking at, and a restart has to put the same tabs back
/// in the same windows. `NSWindow` is the shell's business; this is not.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct WindowId(pub u64);

#[cfg(feature = "ffi")]
uniffi::custom_newtype!(TabId, u64);
#[cfg(feature = "ffi")]
uniffi::custom_newtype!(SpaceId, u64);
#[cfg(feature = "ffi")]
uniffi::custom_newtype!(WindowId, u64);

/// Where a tab sits in its lifecycle. Drives sidebar placement and expiry:
/// only `Today` tabs are ever archived.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum TabKind {
    /// Global across every space, always visible at the top of the sidebar.
    Favorite,
    /// Belongs to one space, survives restarts.
    Pinned,
    /// Ephemeral. The default for a newly opened tab.
    Today,
}

/// Why a navigation failed, in terms the interface can act on.
///
/// The category is decided here rather than in the shell because what the user
/// is told and what they are offered are behaviour, not looks: "you are
/// offline" and "this certificate is not trusted" are different screens with
/// different actions on every platform. Only the wording belongs to the shell.
///
/// A raw platform string is not enough on its own. `NSURLErrorDomain -1009` is
/// precise and useless, and it is not something any UI can branch on.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum NavigationErrorKind {
    /// There is no network at all.
    Offline,
    /// The name does not resolve.
    HostNotFound,
    /// The host resolves but refused, reset or could not be reached.
    ConnectionFailed,
    Timeout,
    /// TLS failed: untrusted, expired or mismatched certificate.
    CertificateInvalid,
    /// The address itself is not something the engine can load.
    UnsupportedUrl,
    /// Superseded, or handed off to something else. Ordinary traffic rather
    /// than a failure: every download and every redirect produces one, so the
    /// reducer records nothing for it.
    Cancelled,
    /// The process rendering this page ended while it was open.
    ///
    /// Not a navigation failure at all — nothing was being fetched — and it is
    /// in this enum because it produces the same state and wants the same
    /// screen: a tab whose page is gone, an address to try again, and one
    /// action. Both engines report it (`webViewWebContentProcessDidTerminate`,
    /// `WebKitWebView::web-process-terminated`).
    ///
    /// Nothing here says *why*. WebKit hands over the fact and no reason, and
    /// a message inventing one — "the page used too much memory" — would be the
    /// find bar's match count in another shape (ADR-0018).
    PageProcessEnded,
    Unknown,
}

/// The last navigation failure on a tab.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct NavigationError {
    pub kind: NavigationErrorKind,
    /// Where the tab was going. Kept because a failure clears `pending_url`
    /// and a tab that never committed anything has no `url` to fall back on:
    /// without this the error screen could neither name the site nor retry it.
    pub url: Option<String>,
    /// What the engine said, verbatim. Only worth showing when `kind` is
    /// `Unknown` and we have nothing better to say.
    pub message: String,
}

#[derive(Debug, Clone, PartialEq)]
// Exposed as `BrowserTab` because SwiftUI already owns the name `Tab` on
// macOS 15+, and an ambiguous type lookup is a miserable thing to debug.
#[cfg_attr(feature = "ffi", derive(uniffi::Record), uniffi(name = "BrowserTab"))]
pub struct Tab {
    pub id: TabId,
    pub space: SpaceId,
    /// Which window this tab is shown in.
    ///
    /// A tab is in exactly one window, and that is not a preference: a
    /// `WKWebView` is one `NSView` and an `NSView` has one superview, so a tab
    /// drawn in two windows at once would be the same page yanked out of the
    /// first the moment the second asked for it. One field, so the state that
    /// would allow it cannot be written down.
    ///
    /// The space is orthogonal. Two windows can show the same space — that is
    /// what ⌘N is — and they see the same cookie jar with different tabs of it.
    pub window: WindowId,
    /// Set when this tab was opened from another one. Feeds both the sidebar
    /// tree and `WKWebExtensionTab.parentTab`.
    pub parent: Option<TabId>,
    /// Whether a page asked for this tab — `window.open`, or a link carrying
    /// `target="_blank"` — rather than a person.
    ///
    /// The one thing it decides is whether a script may close this tab. It is
    /// deliberately not restored from disk: a page that opened a tab in a
    /// previous run is not on the other end of it after a relaunch, and a
    /// permission that outlives the thing it was granted to is not a
    /// permission (ADR-0075).
    pub opened_by_page: bool,
    pub kind: TabKind,
    /// Last committed URL. `None` until the first navigation commits.
    pub url: Option<String>,
    /// Navigation in flight. Cleared on commit or failure.
    pub pending_url: Option<String>,
    pub title: Option<String>,
    /// What colour the page is, when the page said. `None` is a tab with
    /// nothing committed, a page that failed, or one whose background we could
    /// not read — and the shell wears its own surface for all three.
    ///
    /// It sits beside `title` because it is the same kind of thing: a fact the
    /// engine reported about the page this tab is showing, useful anywhere the
    /// tab is drawn. See [`crate::tint`].
    pub tint: Option<PageTint>,
    pub muted: bool,
    pub playing_audio: bool,
    pub zoom_factor: f64,
    pub loading_complete: bool,
    /// Whether the engine says this tab can go back and forward, as reported
    /// by the host when the back/forward list moved.
    ///
    /// Core state rather than a question the shell puts to the engine, because
    /// the answer is behaviour: it decides what ⌘[ does and what the chrome
    /// offers, and two platforms could not disagree about it (ADR-0002). The
    /// *reading* is the host's — only it can ask its engine — which is why
    /// these arrive as [`crate::protocol::Action::NavigationStackChanged`]
    /// rather than being derived here.
    ///
    /// `false` until the engine has spoken: for a fresh tab, and after a
    /// restore, until the restored view reports. A stored `true` would be a
    /// claim about an engine that has not said anything yet, which is why
    /// neither the tab's constructor nor the store ever writes one.
    pub can_go_back: bool,
    pub can_go_forward: bool,
    /// Why the last navigation failed, if it did. Cleared the moment another
    /// attempt starts, so a tab that reloaded successfully never keeps showing
    /// an error.
    pub last_error: Option<NavigationError>,
    /// Milliseconds since the epoch, as reported by the shell. Drives
    /// archiving; see [`Browser::stale_today_tabs`].
    pub last_active_at: u64,
}

impl Tab {
    /// What a page is drawn at when nobody has said otherwise, and what ⌘0
    /// goes back to.
    ///
    /// Named rather than spelled `1.0` at each use because it is the value a
    /// fresh `WKWebView` already has: the restore path compares against it to
    /// decide whether the engine needs telling anything at all, and a second
    /// literal somewhere would be free to disagree with the engine's default.
    pub const DEFAULT_ZOOM: f64 = 1.0;

    fn new(
        id: TabId,
        space: SpaceId,
        window: WindowId,
        kind: TabKind,
        parent: Option<TabId>,
        now: u64,
    ) -> Self {
        Self {
            id,
            space,
            window,
            parent,
            opened_by_page: false,
            kind,
            url: None,
            pending_url: None,
            title: None,
            tint: None,
            muted: false,
            playing_audio: false,
            zoom_factor: Self::DEFAULT_ZOOM,
            loading_complete: true,
            can_go_back: false,
            can_go_forward: false,
            last_error: None,
            last_active_at: now,
        }
    }

    /// `WKWebExtensionTab.isPinned`. Derived rather than stored so it can never
    /// drift out of sync with `kind`.
    pub fn is_pinned(&self) -> bool {
        matches!(self.kind, TabKind::Favorite | TabKind::Pinned)
    }

    /// What the sidebar shows: title, else URL, else a placeholder.
    pub fn display_title(&self) -> &str {
        self.title
            .as_deref()
            .filter(|t| !t.is_empty())
            .or(self.url.as_deref())
            .unwrap_or("New Tab")
    }
}

/// Environment settings that apply to every page in a space.
///
/// The cookie jar is only half of isolation. A work space that reports a
/// corporate user agent, or a throwaway space that keeps nothing at all, is
/// the other half.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct SpaceProfile {
    /// Replaces the default User-Agent for pages in this space.
    pub user_agent: Option<String>,
    /// Nothing is written to disk: no cookies, no cache, no local storage.
    /// Closing the browser leaves no trace of this space's browsing.
    pub ephemeral: bool,
}

/// Two tabs shown side by side in the page area.
///
/// A split is deliberately *not* a property of a tab. Everything the second
/// page needs — its own address, title, history, zoom, mute, error — is
/// everything [`Tab`] already holds, so a tab carrying a second page would be
/// a second tab wearing a different name. Two tabs displayed together keeps
/// one meaning of "tab" for the sidebar, for the session and for
/// `WKWebExtensionTab`, and costs one optional field on the space.
///
/// It lives on the [`Space`] because a space is the workspace: leave it and
/// come back, and the pair you left is still there.
///
/// There is no `focused` field. The focused pane is [`Browser::active_tab`],
/// which is already what ⌘L, ⌘F and ⌘R aim at — a second notion of focus
/// would be a second thing to keep in step, and it would drift.
#[derive(Debug, Clone, PartialEq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct Split {
    pub leading: TabId,
    pub trailing: TabId,
    /// The leading pane's share of the width, between [`MIN_SPLIT_RATIO`] and
    /// [`MAX_SPLIT_RATIO`].
    pub ratio: f64,
}

impl Split {
    pub fn contains(&self, tab: TabId) -> bool {
        self.leading == tab || self.trailing == tab
    }

    /// The pane that is not `tab`, or `None` if `tab` is not in this split.
    pub fn other(&self, tab: TabId) -> Option<TabId> {
        match tab {
            t if t == self.leading => Some(self.trailing),
            t if t == self.trailing => Some(self.leading),
            _ => None,
        }
    }
}

/// Where the divider starts: down the middle, because nothing yet says one
/// side matters more than the other.
pub const DEFAULT_SPLIT_RATIO: f64 = 0.5;
/// How far the divider can be pushed before it stops.
///
/// A pane at a fifth of the window is narrow but still a page. Letting a drag
/// run to the edge would leave one side at zero width — a split that looks
/// exactly like a rendering bug, and that has to be repaired by dragging a
/// divider nobody can see.
pub const MIN_SPLIT_RATIO: f64 = 0.2;
pub const MAX_SPLIT_RATIO: f64 = 1.0 - MIN_SPLIT_RATIO;

/// Hold a divider position inside its limits.
///
/// Free function rather than a method so the shell can ask the same question
/// mid-drag that the reducer asks on drop. Where the divider may go is
/// behaviour; one answer, in one place.
pub fn clamp_split_ratio(ratio: f64) -> f64 {
    // NaN survives clamp, and a NaN width lays out as nothing at all.
    if ratio.is_nan() {
        return DEFAULT_SPLIT_RATIO;
    }
    ratio.clamp(MIN_SPLIT_RATIO, MAX_SPLIT_RATIO)
}

/// A space owns its own cookie jar. `data_store_id` is handed to the engine
/// host, which on Apple platforms maps it to `WKWebsiteDataStore(forIdentifier:)`.
/// That is what makes two spaces able to hold two logins to the same site.
#[derive(Debug, Clone, PartialEq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct Space {
    pub id: SpaceId,
    pub name: String,
    pub data_store_id: String,
    pub profile: SpaceProfile,
    /// Display order of this space's tabs. The index here is what
    /// `WKWebExtensionTab.indexInWindow` reports.
    pub tab_order: Vec<TabId>,
    /// Returning to a space restores the tab you left it on.
    pub last_active_tab: Option<TabId>,
    /// The two tabs currently shown side by side, if any.
    pub split: Option<Split>,
}

/// One window onto the browser.
///
/// A window holds no tabs of its own — [`Tab::window`] is where that lives — so
/// there is one answer to "which window is this tab in" rather than two that
/// can disagree. What a window owns is where you are looking: the space it is
/// showing, and the tab inside it that has the keyboard.
///
/// Both are per window, and that is the whole point. While there was one
/// window, "the active tab" was a property of the browser; with two, a browser
/// that had one active tab would act on the window you are not looking at
/// (ADR-0065).
#[derive(Debug, Clone, PartialEq)]
#[cfg_attr(
    feature = "ffi",
    derive(uniffi::Record),
    uniffi(name = "BrowserWindow")
)]
pub struct Window {
    pub id: WindowId,
    /// The space this window is showing. Another window may be showing the
    /// same one; they share its cookie jar and not its tabs.
    pub active_space: SpaceId,
    /// The tab with the keyboard in this window, which is always one of this
    /// window's own tabs.
    pub active_tab: Option<TabId>,
}

/// How long an untouched `Today` tab survives. Twelve hours means the tabs you
/// opened this morning are still there after lunch, and gone tomorrow.
pub const DEFAULT_ARCHIVE_AFTER_MS: u64 = 12 * 60 * 60 * 1000;

/// Overridable via [`Browser::set_search_template`].
const DEFAULT_SEARCH: &str = "https://www.google.com/search?q={}";

#[derive(Debug, Clone, PartialEq)]
pub struct Browser {
    tabs: HashMap<TabId, Tab>,
    spaces: Vec<Space>,
    /// Open windows, in the order they were opened.
    windows: Vec<Window>,
    /// The window a command with nobody named in it acts on.
    ///
    /// Kept in step with the platform's own idea of the key window by
    /// `Action::FocusWindow`, sent from the one place that already knows: the
    /// key monitor, which is handed the window the press came from.
    key_window: WindowId,
    next_id: u64,
    search_template: String,
    /// Wall clock, supplied by the shell via `Action::Tick`. Keeping time out
    /// of the reducer is what makes archiving testable.
    now_ms: u64,
    archive_after_ms: u64,
}

impl Browser {
    /// A browser always has at least one space, so there is never a state where
    /// opening a tab has nowhere to put it.
    pub fn new(first_space_name: impl Into<String>, data_store_id: impl Into<String>) -> Self {
        let id = SpaceId(1);
        let window = WindowId(2);
        Self {
            tabs: HashMap::new(),
            spaces: vec![Space {
                id,
                name: first_space_name.into(),
                data_store_id: data_store_id.into(),
                profile: SpaceProfile::default(),
                tab_order: Vec::new(),
                last_active_tab: None,
                split: None,
            }],
            // A browser always has at least one window for the same reason it
            // always has at least one space: a tab with nowhere to be drawn is
            // not a state worth representing.
            windows: vec![Window {
                id: window,
                active_space: id,
                active_tab: None,
            }],
            key_window: window,
            next_id: 3,
            search_template: DEFAULT_SEARCH.to_string(),
            now_ms: 0,
            archive_after_ms: DEFAULT_ARCHIVE_AFTER_MS,
        }
    }

    /// Rebuild a browser from stored data.
    ///
    /// Storage can be stale, hand-edited or half-written, so anything
    /// inconsistent is dropped rather than trusted: tabs in spaces that no
    /// longer exist, parents that point nowhere, ids listed in a space's order
    /// with no tab behind them. Returns `None` only when there is no space at
    /// all, since a browser with nowhere to put a tab is not representable.
    ///
    /// A stored session with no windows in it is repaired rather than refused:
    /// the pages are the thing worth keeping, and a file written by a build
    /// that had one window is exactly that case. Every tab then lands in the
    /// one window this makes.
    pub fn restore(
        spaces: Vec<Space>,
        tabs: Vec<Tab>,
        windows: Vec<Window>,
        key_window: WindowId,
    ) -> Option<Self> {
        if spaces.is_empty() {
            return None;
        }
        let space_ids: Vec<SpaceId> = spaces.iter().map(|s| s.id).collect();

        let tabs: HashMap<TabId, Tab> = tabs
            .into_iter()
            .filter(|t| space_ids.contains(&t.space))
            .map(|mut t| {
                // A navigation cannot be in flight across a restart.
                t.pending_url = None;
                t.loading_complete = true;
                t.playing_audio = false;
                // Nor can the engine's back/forward answer: it describes a
                // view that no longer exists, and the restored view reports
                // its own the moment it is built.
                t.can_go_back = false;
                t.can_go_forward = false;
                // Nor can a failure outlive one. Every restored tab is loaded
                // again on launch, so a stored error would be a claim about a
                // network that may well be back, shown over a page that is
                // about to work.
                t.last_error = None;
                (t.id, t)
            })
            .collect();

        let mut spaces: Vec<Space> = spaces
            .into_iter()
            .map(|mut s| {
                s.tab_order
                    .retain(|id| tabs.get(id).is_some_and(|t| t.space == s.id));
                s.last_active_tab = s.last_active_tab.filter(|id| s.tab_order.contains(id));
                // A split naming a tab that is gone, one that belongs to
                // another space, or the same tab twice would lay out as a pane
                // showing nothing. Dropping it costs the layout; keeping it
                // costs the screen.
                let space_id = s.id;
                let split = s.split.take();
                s.split = split.filter(|split| {
                    split.leading != split.trailing
                        && [split.leading, split.trailing]
                            .iter()
                            .all(|id| tabs.get(id).is_some_and(|t| t.space == space_id))
                });
                s
            })
            .collect();

        // Any tab the stored order forgot still belongs somewhere, otherwise it
        // would be invisible but alive.
        for space in &mut spaces {
            let mut missing: Vec<TabId> = tabs
                .values()
                .filter(|t| t.space == space.id && !space.tab_order.contains(&t.id))
                .map(|t| t.id)
                .collect();
            missing.sort_unstable();
            space.tab_order.extend(missing);
        }

        let mut tabs = tabs;
        let known: Vec<TabId> = tabs.keys().copied().collect();
        for tab in tabs.values_mut() {
            tab.parent = tab.parent.filter(|p| known.contains(p) && *p != tab.id);
        }

        // saturating: a hand-edited or corrupt row can hold a value that
        // overflows on +1, and panicking on load would cost the whole session.
        let mut next_id = known
            .iter()
            .map(|t| t.0)
            .chain(space_ids.iter().map(|s| s.0))
            .chain(windows.iter().map(|w| w.id.0))
            .max()
            .unwrap_or(0)
            .saturating_add(1);

        // A window naming a space that is gone still has tabs in it, so it is
        // pointed at a space that exists rather than dropped. A file with no
        // windows at all gets one, for the same reason.
        let mut windows: Vec<Window> = windows
            .into_iter()
            .map(|mut w| {
                if !space_ids.contains(&w.active_space) {
                    w.active_space = space_ids[0];
                }
                w
            })
            .collect();
        if windows.is_empty() {
            windows.push(Window {
                id: WindowId(next_id),
                active_space: space_ids[0],
                active_tab: None,
            });
            next_id = next_id.saturating_add(1);
        }

        // A tab whose window is not in the file is still a page somebody kept.
        // Which window it was in is incidental to that, so it is repaired into
        // the first one rather than thrown away with the page.
        let window_ids: Vec<WindowId> = windows.iter().map(|w| w.id).collect();
        let first_window = window_ids[0];
        for tab in tabs.values_mut() {
            if !window_ids.contains(&tab.window) {
                tab.window = first_window;
            }
        }

        // A window's active tab has to be a tab that window actually has.
        // Anything else draws a page in the window next door.
        for window in &mut windows {
            window.active_tab = window
                .active_tab
                .filter(|t| tabs.get(t).is_some_and(|tab| tab.window == window.id));
        }

        let key_window = if window_ids.contains(&key_window) {
            key_window
        } else {
            first_window
        };

        Some(Self {
            tabs,
            spaces,
            windows,
            key_window,
            next_id,
            search_template: DEFAULT_SEARCH.to_string(),
            now_ms: 0,
            archive_after_ms: DEFAULT_ARCHIVE_AFTER_MS,
        })
    }

    /// A URL with `{}` marking where the query goes.
    pub fn search_template(&self) -> &str {
        &self.search_template
    }

    pub fn set_search_template(&mut self, template: impl Into<String>) {
        self.search_template = template.into();
    }

    pub fn archive_after_ms(&self) -> u64 {
        self.archive_after_ms
    }

    pub fn set_archive_after_ms(&mut self, ms: u64) {
        self.archive_after_ms = ms;
    }

    pub fn now_ms(&self) -> u64 {
        self.now_ms
    }

    /// Open windows, oldest first.
    pub fn windows(&self) -> &[Window] {
        &self.windows
    }

    pub fn window(&self, id: WindowId) -> Option<&Window> {
        self.windows.iter().find(|w| w.id == id)
    }

    /// The window a command acts on when nobody named one.
    pub fn key_window(&self) -> WindowId {
        self.key_window
    }

    /// Which window a tab is drawn in.
    pub fn window_of(&self, tab: TabId) -> Option<WindowId> {
        Some(self.tabs.get(&tab)?.window)
    }

    /// The space `window` is showing.
    pub fn active_space_in(&self, window: WindowId) -> Option<SpaceId> {
        Some(self.window(window)?.active_space)
    }

    /// The tab with the keyboard in `window`.
    pub fn active_tab_in(&self, window: WindowId) -> Option<TabId> {
        self.window(window)?.active_tab
    }

    /// The space the key window is showing.
    ///
    /// Every reducer arm that does not name a window reads this, which is what
    /// makes "act on the window in front" one rule in one place rather than a
    /// parameter forty actions would have to carry (ADR-0065).
    pub fn active_space(&self) -> SpaceId {
        // A key window that is not in the list cannot happen: `set_key_window`
        // refuses an unknown id and `remove_window` moves it. The fallback is
        // here because the alternative is a panic in a getter.
        self.active_space_in(self.key_window)
            .unwrap_or_else(|| self.spaces[0].id)
    }

    /// The tab with the keyboard in the key window.
    pub fn active_tab(&self) -> Option<TabId> {
        self.active_tab_in(self.key_window)
    }

    /// A space's tabs that are drawn in this window, in display order.
    ///
    /// The order is the space's, filtered rather than re-derived: dragging a
    /// tab up the sidebar of one window must not shuffle the other's.
    pub fn tabs_in_window(&self, window: WindowId, space: SpaceId) -> Vec<&Tab> {
        self.tabs_in(space)
            .into_iter()
            .filter(|t| t.window == window)
            .collect()
    }

    /// Every tab in this window, across every space, in display order.
    pub fn tabs_in_window_all(&self, window: WindowId) -> Vec<&Tab> {
        self.all_tabs()
            .into_iter()
            .filter(|t| t.window == window)
            .collect()
    }

    pub fn tab(&self, id: TabId) -> Option<&Tab> {
        self.tabs.get(&id)
    }

    pub fn spaces(&self) -> &[Space] {
        &self.spaces
    }

    pub fn space(&self, id: SpaceId) -> Option<&Space> {
        self.spaces.iter().find(|s| s.id == id)
    }

    pub fn tab_count(&self) -> usize {
        self.tabs.len()
    }

    /// Whether anything derived from browsing in this space may be written
    /// down.
    ///
    /// ADR-0023 keeps its promise at the write, and names this helper as the
    /// debt it left behind: the branch is spelled out independently at every
    /// writer, and nothing makes a new writer ask the question. This is the
    /// question, asked once.
    ///
    /// A space that does not exist answers `false`. A caller holding an id for
    /// a space that is gone has no business writing anything on its behalf.
    pub fn records_to_disk(&self, space: SpaceId) -> bool {
        self.space(space).is_some_and(|s| !s.profile.ephemeral)
    }

    /// The same question asked about a cookie jar rather than a space, for the
    /// caches that are keyed by one.
    ///
    /// An id no live space claims answers `false`: an ephemeral space's jar,
    /// a closed space's jar and a fabricated one all end in the same place,
    /// which is nothing being written.
    pub fn data_store_records_to_disk(&self, data_store_id: &str) -> bool {
        self.spaces
            .iter()
            .any(|s| s.data_store_id == data_store_id && !s.profile.ephemeral)
    }

    /// The two tabs `space` is showing side by side, if it is showing two.
    pub fn split(&self, space: SpaceId) -> Option<&Split> {
        self.space(space)?.split.as_ref()
    }

    /// The split on screen in the key window right now.
    ///
    /// A split lives on the space (ADR-0042), so a second window showing the
    /// same space could otherwise be told to draw a pair of tabs it does not
    /// have. It sees no split instead, which is the truth about that window.
    pub fn active_split(&self) -> Option<&Split> {
        self.split_in(self.key_window, self.active_space())
    }

    /// The split `window` is showing in `space`, which is a split only if both
    /// of its panes are that window's tabs.
    pub fn split_in(&self, window: WindowId, space: SpaceId) -> Option<&Split> {
        let split = self.split(space)?;
        [split.leading, split.trailing]
            .iter()
            .all(|id| self.tabs.get(id).is_some_and(|t| t.window == window))
            .then_some(split)
    }

    /// The tab sharing the screen with this one, if any.
    pub fn split_companion(&self, tab: TabId) -> Option<TabId> {
        let space = self.tabs.get(&tab)?.space;
        self.split(space)?.other(tab)
    }

    /// Show `leading` and `trailing` side by side in `space`.
    ///
    /// Refuses anything that could not be drawn: a tab paired with itself, or
    /// a tab that does not live in this space. Returns whether it took.
    pub(crate) fn set_split(
        &mut self,
        space: SpaceId,
        leading: TabId,
        trailing: TabId,
        ratio: f64,
    ) -> bool {
        if leading == trailing {
            return false;
        }
        // Same space, and the same window: two panes side by side is one
        // window's layout, and a pane belonging to the window next door cannot
        // be drawn here without taking it off that screen.
        let window = self.tabs.get(&leading).map(|t| t.window);
        let both_here = [leading, trailing].iter().all(|id| {
            self.tabs
                .get(id)
                .is_some_and(|t| t.space == space && Some(t.window) == window)
        });
        if !both_here {
            return false;
        }
        let Some(s) = self.spaces.iter_mut().find(|s| s.id == space) else {
            return false;
        };
        s.split = Some(Split {
            leading,
            trailing,
            ratio: clamp_split_ratio(ratio),
        });
        true
    }

    pub(crate) fn clear_split(&mut self, space: SpaceId) -> bool {
        match self.spaces.iter_mut().find(|s| s.id == space) {
            Some(s) => s.split.take().is_some(),
            None => false,
        }
    }

    pub(crate) fn set_split_ratio(&mut self, space: SpaceId, ratio: f64) -> bool {
        let Some(split) = self
            .spaces
            .iter_mut()
            .find(|s| s.id == space)
            .and_then(|s| s.split.as_mut())
        else {
            return false;
        };
        split.ratio = clamp_split_ratio(ratio);
        true
    }

    /// Drop `space`'s split if `tab` was one of its panes.
    ///
    /// The one place a split ends because a tab went away, so a tab that is
    /// closed, archived or dragged elsewhere can never leave a pane pointing
    /// at nothing.
    fn dissolve_split_holding(&mut self, space: SpaceId, tab: TabId) {
        if let Some(s) = self.spaces.iter_mut().find(|s| s.id == space)
            && s.split.as_ref().is_some_and(|split| split.contains(tab))
        {
            s.split = None;
        }
    }

    /// Tabs of a space in display order.
    pub fn tabs_in(&self, space: SpaceId) -> Vec<&Tab> {
        self.space(space)
            .map(|s| {
                s.tab_order
                    .iter()
                    .filter_map(|id| self.tabs.get(id))
                    .collect()
            })
            .unwrap_or_default()
    }

    /// Every tab, ordered space by space. Used for snapshots and search.
    pub fn all_tabs(&self) -> Vec<&Tab> {
        self.spaces
            .iter()
            .flat_map(|s| self.tabs_in(s.id))
            .collect()
    }

    /// `WKWebExtensionTab.indexInWindow`.
    pub fn index_in_space(&self, id: TabId) -> Option<usize> {
        let tab = self.tabs.get(&id)?;
        self.space(tab.space)?
            .tab_order
            .iter()
            .position(|t| *t == id)
    }

    /// `Today` tabs that have gone untouched past the archive window.
    ///
    /// The active tab is never stale: you should not lose the page you are
    /// looking at because you read it for a long time.
    pub fn stale_today_tabs(&self) -> Vec<TabId> {
        // Active in *any* window: the page somebody is looking at in the window
        // behind this one is still a page somebody is looking at.
        self.all_tabs()
            .iter()
            .filter(|t| t.kind == TabKind::Today)
            .filter(|t| !self.windows.iter().any(|w| w.active_tab == Some(t.id)))
            .filter(|t| self.now_ms.saturating_sub(t.last_active_at) >= self.archive_after_ms)
            .map(|t| t.id)
            .collect()
    }

    pub(crate) fn set_now(&mut self, now_ms: u64) {
        // Never let the clock run backwards; a stale Tick arriving late would
        // otherwise un-age every tab.
        self.now_ms = self.now_ms.max(now_ms);
    }

    /// Hand out the next id.
    ///
    /// Saturating rather than wrapping: a corrupt row can push the counter to
    /// the top, and wrapping to zero would start handing out ids that collide
    /// with live tabs. Saturating means the last id repeats, which
    /// `insert_tab` and `add_space` overwrite in place, and which nobody will
    /// ever reach honestly.
    fn take_id(&mut self) -> u64 {
        let id = self.next_id;
        self.next_id = self.next_id.saturating_add(1);
        id
    }

    pub(crate) fn insert_tab(
        &mut self,
        space: SpaceId,
        kind: TabKind,
        parent: Option<TabId>,
    ) -> TabId {
        let id = TabId(self.take_id());
        let now = self.now_ms;
        // The window in front. A tab opens where you are — including a tab
        // opened into another space by a routing rule, which shows up in the
        // window you were in rather than somewhere you would have to go and
        // find.
        let window = self.key_window;
        self.tabs
            .insert(id, Tab::new(id, space, window, kind, parent, now));

        if let Some(s) = self.spaces.iter_mut().find(|s| s.id == space) {
            // A child tab opens directly below its parent, the way Arc nests
            // tabs, instead of jumping to the end of the list.
            let at = parent
                .and_then(|p| s.tab_order.iter().position(|t| *t == p))
                .map(|i| i + 1)
                .unwrap_or(s.tab_order.len());
            s.tab_order.insert(at, id);
        }
        id
    }

    pub(crate) fn remove_tab(&mut self, id: TabId) -> Option<Tab> {
        let tab = self.tabs.remove(&id)?;

        if let Some(s) = self.spaces.iter_mut().find(|s| s.id == tab.space) {
            s.tab_order.retain(|t| *t != id);
            if s.last_active_tab == Some(id) {
                s.last_active_tab = None;
            }
        }
        // Closing one side of a split gives the other side the whole area.
        self.dissolve_split_holding(tab.space, id);
        // Orphaned children reattach to their grandparent so the tree never
        // points at a tab that no longer exists.
        for t in self.tabs.values_mut() {
            if t.parent == Some(id) {
                t.parent = tab.parent;
            }
        }
        for window in &mut self.windows {
            if window.active_tab == Some(id) {
                window.active_tab = None;
            }
        }
        Some(tab)
    }

    /// Move a tab within its space or into another one, clamping the index.
    pub(crate) fn move_tab(&mut self, id: TabId, to: SpaceId, index: usize) -> bool {
        let Some(tab) = self.tabs.get(&id) else {
            return false;
        };
        let from = tab.space;
        if self.space(to).is_none() {
            return false;
        }

        if let Some(s) = self.spaces.iter_mut().find(|s| s.id == from) {
            s.tab_order.retain(|t| *t != id);
            if s.last_active_tab == Some(id) {
                s.last_active_tab = None;
            }
        }
        if let Some(s) = self.spaces.iter_mut().find(|s| s.id == to) {
            let at = index.min(s.tab_order.len());
            s.tab_order.insert(at, id);
        }

        if let Some(t) = self.tabs.get_mut(&id) {
            t.space = to;
            // A tab dragged out of its old space cannot keep a parent that
            // stayed behind.
            if from != to {
                t.parent = None;
            }
        }
        if from != to {
            // A pane that left the space cannot still be half of its split.
            self.dissolve_split_holding(from, id);
            // Children would otherwise point across a space boundary.
            let orphans: Vec<TabId> = self
                .tabs
                .values()
                .filter(|t| t.parent == Some(id) && t.space == from)
                .map(|t| t.id)
                .collect();
            for child in orphans {
                if let Some(t) = self.tabs.get_mut(&child) {
                    t.parent = None;
                }
            }
        }
        true
    }

    pub(crate) fn add_space(&mut self, name: String, data_store_id: String) -> SpaceId {
        let id = SpaceId(self.take_id());
        self.spaces.push(Space {
            id,
            name,
            data_store_id,
            profile: SpaceProfile::default(),
            tab_order: Vec::new(),
            last_active_tab: None,
            split: None,
        });
        id
    }

    /// Remove a space and report which tabs went with it.
    ///
    /// Refuses to remove the last space: a browser with nowhere to put a tab is
    /// not a state worth representing.
    pub(crate) fn remove_space(&mut self, id: SpaceId) -> Option<Vec<TabId>> {
        if self.spaces.len() <= 1 {
            return None;
        }
        let position = self.spaces.iter().position(|s| s.id == id)?;
        let removed = self.spaces.remove(position);

        for tab in &removed.tab_order {
            self.tabs.remove(tab);
        }
        let fallback = self.spaces[position.min(self.spaces.len() - 1)].id;
        for window in &mut self.windows {
            if window.active_space == id {
                window.active_space = fallback;
            }
            if window
                .active_tab
                .is_some_and(|t| removed.tab_order.contains(&t))
            {
                window.active_tab = None;
            }
        }
        Some(removed.tab_order)
    }

    /// Open another window onto `active_space`.
    ///
    /// Refuses a space that does not exist rather than picking one: a caller
    /// naming a space that is gone has not decided where this window goes, and
    /// guessing for them is a bug with a delay on it.
    pub(crate) fn add_window(&mut self, active_space: SpaceId) -> Option<WindowId> {
        self.space(active_space)?;
        let id = WindowId(self.take_id());
        self.windows.push(Window {
            id,
            active_space,
            active_tab: None,
        });
        Some(id)
    }

    /// Close a window and report which tabs went with it.
    ///
    /// Refuses to close the last one, the same way `remove_space` refuses the
    /// last space: a browser with nowhere to draw a page is not a state worth
    /// representing, and the platform's own answer to closing the last window
    /// is quitting, which is `applicationShouldTerminate`'s decision and not
    /// this one's.
    pub(crate) fn remove_window(&mut self, id: WindowId) -> Option<Vec<TabId>> {
        if self.windows.len() <= 1 {
            return None;
        }
        let position = self.windows.iter().position(|w| w.id == id)?;
        self.windows.remove(position);

        let mut orphaned: Vec<TabId> = self
            .tabs
            .values()
            .filter(|t| t.window == id)
            .map(|t| t.id)
            .collect();
        // The map has no order, and which tabs a caller is told to tear down
        // has to be the same on every run or a test is a coin toss.
        orphaned.sort_unstable();
        for tab in &orphaned {
            self.remove_tab(*tab);
        }

        if self.key_window == id {
            self.key_window = self.windows[position.min(self.windows.len() - 1)].id;
        }
        Some(orphaned)
    }

    /// Point the browser at the window the platform says is in front.
    pub(crate) fn set_key_window(&mut self, id: WindowId) -> bool {
        if self.window(id).is_some() {
            self.key_window = id;
            true
        } else {
            false
        }
    }

    pub(crate) fn rename_space(&mut self, id: SpaceId, name: String) -> bool {
        match self.spaces.iter_mut().find(|s| s.id == id) {
            Some(space) => {
                space.name = name;
                true
            }
            None => false,
        }
    }

    pub(crate) fn set_space_profile(&mut self, id: SpaceId, profile: SpaceProfile) -> bool {
        match self.spaces.iter_mut().find(|s| s.id == id) {
            Some(space) => {
                space.profile = profile;
                true
            }
            None => false,
        }
    }

    pub(crate) fn tab_mut(&mut self, id: TabId) -> Option<&mut Tab> {
        self.tabs.get_mut(&id)
    }

    /// Give the keyboard to a tab in the key window.
    ///
    /// The tab is brought *into* the key window if it was somewhere else. That
    /// is what a command bar result, a routed URL and ⌘1 all mean when they
    /// name a tab: show it to me, here. Moving it is the only honest answer,
    /// because one web view cannot be in two windows (ADR-0065).
    pub(crate) fn set_active_tab(&mut self, id: Option<TabId>) {
        let key = self.key_window;
        if let Some(w) = self.windows.iter_mut().find(|w| w.id == key) {
            w.active_tab = id;
        }

        let Some(id) = id else { return };
        let now = self.now_ms;
        let Some((space, left_behind)) = self.tabs.get_mut(&id).map(|t| {
            t.last_active_at = now;
            let left_behind = (t.window != key).then_some(t.window);
            t.window = key;
            (t.space, left_behind)
        }) else {
            return;
        };
        // The window it came from cannot keep pointing at it, and cannot keep
        // it as half of a pair it no longer has.
        if let Some(previous) = left_behind {
            if let Some(w) = self.windows.iter_mut().find(|w| w.id == previous)
                && w.active_tab == Some(id)
            {
                w.active_tab = None;
            }
            self.dissolve_split_holding(space, id);
        }
        if let Some(w) = self.windows.iter_mut().find(|w| w.id == key) {
            w.active_space = space;
        }
        if let Some(s) = self.spaces.iter_mut().find(|s| s.id == space) {
            s.last_active_tab = Some(id);
            // A split only lives while the tab you are in is one of its panes.
            // Going anywhere else puts it away, so the row the sidebar marks
            // as selected is always a row that is on screen. Enforced here
            // rather than in each caller: ⌘1, ⌃Tab, a click and a route all
            // arrive through this one door.
            if s.split.as_ref().is_some_and(|split| !split.contains(id)) {
                s.split = None;
            }
        }
    }

    pub(crate) fn set_active_space(&mut self, id: SpaceId) -> bool {
        if self.space(id).is_none() {
            return false;
        }
        let key = self.key_window;
        if let Some(w) = self.windows.iter_mut().find(|w| w.id == key) {
            w.active_space = id;
        }
        true
    }

    /// Which tab to focus when the key window enters a space: the one it was
    /// left on, else the first of that space's tabs **in this window**.
    ///
    /// The filter is the multi-window half. `last_active_tab` is the space's,
    /// shared by every window showing it, so without this the second window
    /// would open a space by stealing the page out of the first.
    pub(crate) fn entry_tab_of(&self, space: SpaceId) -> Option<TabId> {
        let window = self.key_window;
        let s = self.space(space)?;
        let mine = |id: &TabId| self.tabs.get(id).is_some_and(|t| t.window == window);
        s.last_active_tab
            .filter(mine)
            .or_else(|| s.tab_order.iter().find(|id| mine(id)).copied())
    }

    /// The tab that should take focus after `closing` goes away: the next one
    /// in the same space, else the previous one, else nothing.
    pub(crate) fn successor_of(&self, closing: TabId) -> Option<TabId> {
        let tab = self.tabs.get(&closing)?;
        let space = self.space(tab.space)?;
        // Closing one side of a split hands the area to the other side, so
        // that is where the keyboard goes — not to whatever row happens to sit
        // below in the sidebar, which is not even on screen.
        if let Some(other) = space.split.as_ref().and_then(|s| s.other(closing)) {
            return Some(other);
        }
        // Only this window's tabs are candidates. The row below in the space's
        // order may belong to the window behind this one, and focusing it would
        // pull that page across the screen to fill a gap it never made.
        let window = tab.window;
        let order: Vec<TabId> = space
            .tab_order
            .iter()
            .copied()
            .filter(|id| *id == closing || self.tabs.get(id).is_some_and(|t| t.window == window))
            .collect();
        let pos = order.iter().position(|t| *t == closing)?;
        order
            .get(pos + 1)
            .or_else(|| pos.checked_sub(1).and_then(|prev| order.get(prev)))
            .copied()
    }
}
