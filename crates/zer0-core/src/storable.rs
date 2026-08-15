//! What is worth writing down, decided once, before any backend sees it.
//!
//! Two of the promises this browser makes are about *what* is persisted rather
//! than *how*: an ephemeral space leaves no trace of its pages (ADR-0023), and
//! a download that failed or was cancelled is not carried into the next launch
//! while one still running is written down as interrupted (ADR-0027). Both used
//! to live inside the SQLite backend's `save`, which meant a second backend
//! would have to reimplement them from a reading of somebody else's file — and
//! getting the first one wrong is an ephemeral space quietly writing history to
//! disk, with nothing outside the SQLite test suite to catch it.
//!
//! So they moved above the backend. [`SessionStore::save`] does not take a
//! [`Session`]; it takes a [`StorableSession`], and the only way to obtain one
//! is [`StorableSession::project`]. A backend cannot write an ephemeral space's
//! tabs because it is never handed them, and it cannot write a failed download
//! because there is no value in this module that can say "failed". That is the
//! test the shape has to pass: not that a backend author is told the rule, but
//! that they could not break it if they tried.
//!
//! **This type is a leaf, not a mirror of [`Session`].** What it leaves out is
//! as deliberate as what it keeps: no icon cache (ADR-0044 gives icons a store
//! of their own), no closed-tab ring (deliberately forgotten on quit), no live
//! handles, no state that belongs to the run rather than to the page. A field
//! that is absent here cannot be written down by accident.
//!
//! [`SessionStore::save`]: crate::session_store::SessionStore::save

use crate::bookmarks::Bookmark;
use crate::chat::{
    Conversation, ConversationId, ConversationScope, Message, MessageId, MessageRole, MessageState,
    ToolGrant,
};
use crate::downloads::{Download, DownloadId, DownloadState};
use crate::extension_permissions::ConsentDecision;
use crate::extension_pins::ExtensionPin;
use crate::history::HistoryEntry;
use crate::mcp::ApprovedShape;
use crate::model::{Browser, Space, SpaceId, SpaceProfile, Split, Tab, TabId, Window, WindowId};
use crate::native_messaging::NativeHostDecision;
use crate::navigation_state::NavigationStates;
use crate::preferences::Preferences;
use crate::routing::Route;
use crate::session::Session;
use crate::shortcuts::Binding;
use crate::site_permissions::SiteGrant;

/// A session with everything that must not be stored already gone.
///
/// Every field is public because a backend has nothing to gain by lying to
/// itself: it receives one of these and writes it down. What it cannot do is
/// build one out of a [`Session`] — [`StorableSession::project`] is the only
/// constructor, and `save` is the only place one arrives.
#[derive(Debug, Clone, PartialEq)]
pub struct StorableSession {
    /// Every space, in sidebar order, ephemeral ones included: the space
    /// survives a quit even when what happened inside it does not.
    pub spaces: Vec<StorableSpace>,
    /// The windows worth bringing back, in the order they were opened.
    ///
    /// **A private window is not one of them, and that is structural rather
    /// than a rule somebody remembers.** A window is written down only if it
    /// has a tab a backend was handed, and an ephemeral space hands over no
    /// tabs at all (see [`StorableSpace`]). So the window a private space was
    /// opened in has nothing in it to store, and never reaches this list —
    /// there is no field here that could carry it and no branch anywhere
    /// testing for it.
    pub windows: Vec<StorableWindow>,
    /// Which of them was in front. Names a window that is in
    /// [`StorableSession::windows`], or the first one when the window in front
    /// was private and therefore not written down.
    pub key_window: WindowId,
    pub search_template: String,
    pub archive_after_ms: u64,
    /// In match order. The order is the data; a store whose medium has none has
    /// to write it down.
    pub routes: Vec<Route>,
    /// Only the bindings that differ from the shipped defaults.
    ///
    /// Storing the whole keymap would freeze it: a later change to the default
    /// shortcuts would never reach anyone who had ever quit the browser. So the
    /// delta is what a backend is given, and writing "everything the keymap
    /// holds" is not a mistake available to it.
    pub keybindings: Vec<Binding>,
    pub history: Vec<HistoryEntry>,
    /// Every kept address, newest first.
    ///
    /// Unfiltered, and that is the decision. Everything else in this struct
    /// that touches a page is filtered by whether its space records to disk,
    /// because every one of those traces is taken by the browser on its own:
    /// history is written by visiting, a tab is written by existing, a
    /// conversation is written by asking. A bookmark is written by somebody
    /// pressing a key that means "keep this", which is the same category as a
    /// download — and a download from an ephemeral space still puts a file on
    /// disk, because the person asked for the file.
    ///
    /// There is nothing here to filter *by*, either: [`Bookmark`] has no space
    /// field, so this list cannot record which space a page was kept from even
    /// if a backend wanted to. The promise ADR-0023 makes is about traces of
    /// what happened in a space; an address with nothing attached saying where
    /// it came from is not one.
    pub bookmarks: Vec<Bookmark>,
    pub downloads: Vec<StorableDownload>,
    pub extension_consent: Vec<ConsentDecision>,
    /// Which extension buttons are on show, in the order they are drawn.
    ///
    /// Unfiltered, like the consent ledger above it and for the same reason:
    /// this is browser-wide rather than a property of a space, so there is
    /// nothing here an ephemeral space could leak through. A row that is
    /// `pinned: false` is carried through deliberately — dropping it would turn
    /// a deliberate refusal back into "never asked", which is the next launch
    /// putting a hidden extension back on the row.
    pub extension_pins: Vec<ExtensionPin>,
    /// Which programs each extension may start. Unfiltered, like the two
    /// ledgers above it and for the same reason: this is browser-wide rather
    /// than a property of a space, so there is nothing here an ephemeral space
    /// could leak through.
    pub native_hosts: Vec<NativeHostDecision>,
    /// Threads worth bringing back, oldest first. Never one belonging to an
    /// ephemeral space, and never one belonging to a space that is gone.
    ///
    /// A thread outlives every tab that showed its page (ADR-0060), so "is a
    /// tab still open" is not a question asked here any more — the space is.
    pub conversations: Vec<StorableConversation>,
    /// Which tools may run without asking, and which may never run.
    ///
    /// Not scoped to a space: a tool server is configured for the browser, and
    /// a refusal that only held in the space it was given in would ask again in
    /// the next one — which is the "consent that resets" ADR-0028 exists to
    /// stop.
    pub tool_consent: Vec<ToolGrant>,
    /// What each remembered answer in [`StorableSession::tool_consent`] was
    /// given *about*: a hash over the tool's name, description and input
    /// schema, taken at the moment the answer was recorded (ADR-0050).
    ///
    /// Stored beside the grants rather than folded into them, because the two
    /// are answers to different questions and must not be able to drift into
    /// disagreeing. A row here is not permission to do anything; it is only the
    /// shape a permission was about, and a grant whose shape is missing reads
    /// as `Changed` and asks again.
    ///
    /// Not scoped to a space, for the same reason the grants are not.
    pub tool_shapes: Vec<ApprovedShape>,
    /// What each site was allowed to point at you.
    ///
    /// **Never a grant belonging to an ephemeral space, and never one naming a
    /// space that is gone.** The first is ADR-0023 applied to the one kind of
    /// state that could survive a throwaway space and still be about you: a
    /// grant is only worth having because it is remembered, so remembering one
    /// from a space that promised to remember nothing is not a smaller version
    /// of the promise, it is the promise broken. The second is a grant nobody
    /// could reach from any screen — unreachable is unrevokable, and an
    /// approval nobody can take back is the thing ADR-0028 spends a pane on
    /// preventing.
    ///
    /// The filtering happens here rather than inside a backend for the reason
    /// this whole module exists: a store cannot leave out a rule it was never
    /// given.
    pub site_permissions: Vec<SiteGrant>,
    pub preferences: Preferences,
}

/// A conversation as it may be kept.
///
/// Everything about the run is already gone by the time one of these exists:
/// no tool calls, no consent prompt waiting on an answer, no reply still
/// arriving. See [`StorableMessage`] for why each of those is unrepresentable
/// rather than merely filtered.
#[derive(Debug, Clone, PartialEq)]
pub struct StorableConversation {
    pub id: ConversationId,
    /// What the thread is about — and, for a page thread, the second place in
    /// this file a URL is written down.
    ///
    /// Said plainly rather than left to be discovered: anchoring a thread to a
    /// page means the address is part of its identity, so it is on disk whether
    /// or not the conversation ever captured anything. The address is
    /// [`crate::chat::PageAnchor`]'s, which is why a password in userinfo and a
    /// token in a fragment cannot be here — and why a token in a *query string*
    /// can. History holds the same URL in the same plain text; this is a second
    /// copy in a second table, and clearing the thread is what removes it.
    pub scope: ConversationScope,
    /// Oldest first. Empty conversations are not stored at all, so this is
    /// never empty.
    pub messages: Vec<StorableMessage>,
    pub created_at_ms: u64,
}

/// How a reply ended, in the only two shapes that outlive the run.
///
/// The same two a download has, for the same reason: a process that has gone
/// away is not still streaming.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StorableMessageState {
    Complete,
    Interrupted,
}

/// A message as it may be kept — which is three shapes and not four.
///
/// **A tool result cannot be stored**, because there is no variant for one.
/// Its call is gone, its answer is stale, and a transcript that carries an
/// answer to a question nobody can see is a transcript that reads as a bug.
///
/// **A page's text cannot be stored**, because `Page` has no field for it. The
/// address and the title are facts the browser already keeps in history; the
/// body of every page anyone ever asked about is a shadow archive far past
/// what this browser has ever written down, and it is the single most
/// sensitive thing chat could put on disk. A restored thread names its page
/// and reads it again if the conversation goes on.
///
/// **A user message cannot be interrupted**, because only `Assistant` carries
/// a state. Nobody's typing is ever half-arrived.
#[derive(Debug, Clone, PartialEq)]
pub enum StorableMessage {
    User {
        id: MessageId,
        text: String,
        created_at_ms: u64,
    },
    Assistant {
        id: MessageId,
        text: String,
        state: StorableMessageState,
        /// What answered, as reported at the time. Kept so a restored thread
        /// does not relabel last week's answers with this week's settings.
        model: Option<String>,
        created_at_ms: u64,
    },
    /// A page a conversation was told about. Its address and its title, and
    /// deliberately not a word of what was on it.
    Page {
        id: MessageId,
        url: String,
        title: String,
        created_at_ms: u64,
    },
}

impl StorableMessage {
    pub fn id(&self) -> MessageId {
        match self {
            StorableMessage::User { id, .. }
            | StorableMessage::Assistant { id, .. }
            | StorableMessage::Page { id, .. } => *id,
        }
    }
}

/// A window worth reopening.
///
/// It names no tabs: a tab already says which window it is in, and a second
/// list would be a second answer that can disagree with the first. What it
/// carries is where that window was looking.
#[derive(Debug, Clone, PartialEq)]
pub struct StorableWindow {
    pub id: WindowId,
    pub active_space: SpaceId,
    /// Always a tab that was written down. A window whose active tab was in an
    /// ephemeral space comes back on whatever it has left rather than on an
    /// integer with nothing behind it.
    pub active_tab: Option<TabId>,
}

impl StorableWindow {
    /// `None` for a window with nothing to bring back.
    ///
    /// This is where the private window stops. A window is worth reopening
    /// because of what is in it, and a window whose every page was in an
    /// ephemeral space has, by the time this runs, nothing in it at all. No
    /// branch tests for "private": the pages are simply not there.
    fn project(window: &Window, kept: &[Tab]) -> Option<Self> {
        let mut mine = kept.iter().filter(|t| t.window == window.id).peekable();
        mine.peek()?;
        let active_tab = window
            .active_tab
            .filter(|id| kept.iter().any(|t| t.id == *id && t.window == window.id));
        Some(Self {
            id: window.id,
            active_space: window.active_space,
            active_tab,
        })
    }
}

/// A space, and the pages in it that may be written down.
///
/// Not a [`Space`] with extras: a `Space` carries `tab_order` and `split`, and
/// handing one over whole would put an ephemeral space's pages back within
/// reach of a backend through the side door.
#[derive(Debug, Clone, PartialEq)]
pub struct StorableSpace {
    pub id: SpaceId,
    pub name: String,
    pub data_store_id: String,
    pub profile: SpaceProfile,
    pub last_active_tab: Option<TabId>,
    /// In display order. Always empty when the space is ephemeral.
    pub tabs: Vec<StorableTab>,
    /// Always `None` when the space is ephemeral.
    pub split: Option<Split>,
}

/// A tab as it may be kept, and where it has been.
///
/// **The navigation state is on the tab and there is nowhere else it could
/// be.** That is the whole reason this type exists rather than a
/// `Vec<(TabId, Vec<u8>)>` beside the spaces in [`StorableSession`]: a private
/// space's back/forward list is the most detailed record of a private session
/// this browser could produce — every address, in order, with the scroll
/// positions and form values the engine kept — and a second list at the top
/// level would need a filter, and a filter is a line somebody can delete.
///
/// Here, there is no filter. An ephemeral space's `tabs` is `Vec::new()` by
/// construction (see [`StorableSpace::project`]), a navigation state can only
/// travel inside one of these, and one of these can only travel inside a
/// space's `tabs`. So an ephemeral space's history cannot reach a backend, for
/// the same structural reason its pages cannot, and it stops being true only if
/// somebody adds a field somewhere that can hold one — which is a change nobody
/// makes by accident.
#[derive(Debug, Clone, PartialEq)]
pub struct StorableTab {
    pub tab: Tab,
    /// Opaque. `None` for a tab that has not navigated, one whose state the
    /// engine never reported, and every tab in a session written before this
    /// was stored at all.
    pub navigation_state: Option<Vec<u8>>,
}

/// How a download ended, in the only two shapes that outlive the run.
///
/// A separate enum from [`DownloadState`] rather than a note saying which
/// variants are allowed. `InProgress` cannot be stored because a process that
/// has gone away is not still downloading; `Failed` and `Cancelled` cannot be
/// stored because there is no file at the end of them. Making them
/// unrepresentable here is what keeps a backend from writing one.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StorableDownloadState {
    Completed,
    Interrupted,
}

/// A download worth bringing back, without the parts that belong to the run.
///
/// No `tab`: the tab it was started from may be long closed. No `error`: a
/// failure is not stored at all, so a stored row can never carry one.
#[derive(Debug, Clone, PartialEq)]
pub struct StorableDownload {
    pub id: DownloadId,
    pub url: String,
    pub filename: String,
    pub path: String,
    pub state: StorableDownloadState,
    pub received_bytes: u64,
    pub total_bytes: Option<u64>,
    pub started_at_ms: u64,
}

impl StorableSession {
    /// Everything in `session` that a store may keep, and nothing else.
    ///
    /// Computed once, so the judgement happens in one place at one moment
    /// rather than once per backend. `session` is borrowed and never touched:
    /// what is on screen is unaffected by having been written down.
    pub fn project(session: &Session) -> Self {
        let browser = &session.browser;
        let spaces: Vec<StorableSpace> = browser
            .spaces()
            .iter()
            .map(|space| StorableSpace::project(space, browser, &session.navigation_states))
            .collect();
        // The tabs a backend is actually being handed. An ephemeral space
        // contributes none, so nothing derived from this can name one.
        let kept: Vec<Tab> = spaces
            .iter()
            .flat_map(|s| s.tabs.iter().map(|t| t.tab.clone()))
            .collect();
        let windows: Vec<StorableWindow> = browser
            .windows()
            .iter()
            .filter_map(|w| StorableWindow::project(w, &kept))
            .collect();
        // A key window that was private is not in the list, so the first one
        // that survived takes the front. Falling back to the live id would
        // write down the number of a window nobody can reach.
        let key_window = windows
            .iter()
            .map(|w| w.id)
            .find(|id| *id == browser.key_window())
            .or_else(|| windows.first().map(|w| w.id))
            .unwrap_or(browser.key_window());
        Self {
            spaces,
            windows,
            key_window,
            search_template: browser.search_template().to_string(),
            archive_after_ms: browser.archive_after_ms(),
            routes: session.routes.routes().to_vec(),
            keybindings: session.keymap.customisations(),
            history: session.history.entries().cloned().collect(),
            bookmarks: session.bookmarks.all().to_vec(),
            downloads: session
                .downloads
                .all()
                .iter()
                .filter_map(StorableDownload::project)
                .collect(),
            extension_consent: session.extension_consent.all().to_vec(),
            extension_pins: session.extension_pins.all().to_vec(),
            native_hosts: session.native_hosts.all().to_vec(),
            conversations: session
                .chat
                .all()
                .iter()
                .filter_map(|c| StorableConversation::project(c, browser))
                .collect(),
            tool_consent: session.chat.consent().all().to_vec(),
            // Every bound shape, including ones whose server is not running:
            // the register is empty at launch and fills as servers connect, so
            // dropping the shapes of anything not currently up would throw away
            // exactly the answers a relaunch is meant to bring back.
            tool_shapes: session.mcp.shapes().to_vec(),
            site_permissions: session
                .site_permissions
                .all()
                .iter()
                .filter(|grant| {
                    browser
                        .space(grant.space)
                        .is_some_and(|space| !space.profile.ephemeral)
                })
                .cloned()
                .collect(),
            preferences: session.preferences.clone(),
        }
    }
}

impl StorableConversation {
    /// `None` for a conversation that is not written down at all.
    ///
    /// Two reasons, and both are promises rather than tidiness:
    ///
    /// **An ephemeral space leaves no trace of its pages (ADR-0023),** and a
    /// conversation is the most detailed trace of a page this browser can
    /// produce — it holds what was said about the page *and, since threads were
    /// anchored to URLs, the page's address in its own identity*. A space whose
    /// tabs are not written must not have its threads written either, and the
    /// check is here, above every backend, for the same reason the tab rule is.
    ///
    /// Anchoring made that stronger rather than weaker, and it is worth saying
    /// how. A scope used to name a tab, so the space had to be found by hopping
    /// through one — and a thread whose tab had been closed since the last
    /// dispatch resolved to no space at all, which happened to fail closed.
    /// [`ConversationScope::space`] is total now: every thread names its space
    /// outright, the lookup cannot miss, and **the URL cannot reach a backend
    /// without passing the space that decides whether it may.** There is no
    /// arrangement of open and closed tabs that routes around this line.
    fn project(conversation: &Conversation, browser: &Browser) -> Option<Self> {
        // A space that is gone takes its threads with it. `?` rather than a
        // default, because the safe direction is not writing something down.
        if browser.space(conversation.scope.space())?.profile.ephemeral {
            return None;
        }

        let messages: Vec<StorableMessage> = conversation
            .messages
            .iter()
            .filter_map(StorableMessage::project)
            .collect();
        // A thread with nothing readable in it is not a thread. Most often
        // this is one that was opened and never asked anything.
        if messages.is_empty() {
            return None;
        }

        Some(Self {
            id: conversation.id,
            scope: conversation.scope.clone(),
            messages,
            created_at_ms: conversation.created_at_ms,
        })
    }
}

impl StorableMessage {
    /// `None` for a message that is not written down at all.
    ///
    /// **A tool result is never stored.** The call it answers is gone — no
    /// backend can hold one — so the answer would sit in the transcript
    /// replying to nothing.
    ///
    /// **A reply with no text is never stored.** An assistant turn that only
    /// asked for tools has nothing a person read, and without its calls there
    /// is nothing to bring back.
    ///
    /// **A reply still arriving is stored as interrupted**, on the same
    /// reasoning as a download: if this save turns out to be the last thing we
    /// write, that is exactly what happened.
    fn project(message: &Message) -> Option<Self> {
        match message.role {
            MessageRole::ToolResult => None,
            MessageRole::User => (!message.text.is_empty()).then(|| StorableMessage::User {
                id: message.id,
                text: message.text.clone(),
                created_at_ms: message.created_at_ms,
            }),
            MessageRole::Assistant => {
                (!message.text.is_empty()).then(|| StorableMessage::Assistant {
                    id: message.id,
                    text: message.text.clone(),
                    state: match message.state {
                        MessageState::Complete => StorableMessageState::Complete,
                        MessageState::Streaming
                        | MessageState::Cancelled
                        | MessageState::Failed
                        | MessageState::Interrupted
                        | MessageState::Truncated => StorableMessageState::Interrupted,
                    },
                    model: message.model.clone(),
                    created_at_ms: message.created_at_ms,
                })
            }
            // The page's text stops here. What survives is the address and the
            // title, which history already holds anyway.
            MessageRole::PageContext => message.page.as_ref().map(|page| StorableMessage::Page {
                id: message.id,
                url: page.url.clone(),
                title: page.title.clone(),
                created_at_ms: message.created_at_ms,
            }),
        }
    }
}

impl StorableSpace {
    fn project(space: &Space, browser: &Browser, states: &NavigationStates) -> Self {
        // ADR-0023. An ephemeral space promises to leave no trace of its pages,
        // so its tabs are not written down even though the space itself is. Its
        // split goes with them: a pair naming two tabs nobody stored is not a
        // layout, it is two empty panes.
        //
        // The back/forward lists go with them too, and by the same line rather
        // than by a second one: `states` is only ever read through a tab in the
        // loop below, so a branch that produces no tabs produces no history
        // either. See [`StorableTab`].
        let (tabs, split) = if space.profile.ephemeral {
            (Vec::new(), None)
        } else {
            (
                browser
                    .tabs_in(space.id)
                    .into_iter()
                    .map(|tab| storable_tab(tab, states))
                    .collect(),
                space.split.clone(),
            )
        };
        Self {
            id: space.id,
            name: space.name.clone(),
            data_store_id: space.data_store_id.clone(),
            profile: space.profile.clone(),
            // Cleared for an ephemeral space along with the tabs it names. It
            // is only an id, it is dropped on load, and no page can be
            // recovered from it — but "an ephemeral space leaves nothing
            // behind" is a promise someone has to be able to check by reading
            // the file, and "nothing except one integer nobody reads" is not a
            // sentence that survives being checked.
            last_active_tab: if space.profile.ephemeral {
                None
            } else {
                space.last_active_tab
            },
            tabs,
            split,
        }
    }
}

/// A tab as it is worth storing: what the page is, not what this run was doing
/// with it.
///
/// A navigation cannot still be in flight across a restart, audio cannot still
/// be playing, and last night's "you are offline" would be drawn over a page
/// that is about to load fine. `Browser::restore` already clears all four on
/// the way back in; clearing them here means a backend never holds them long
/// enough to write one down.
///
/// The back/forward list is the one thing here that *is* worth carrying whole:
/// unlike the four above it describes the page rather than the run, and losing
/// it is the difference between a tab coming back and everything you did to
/// reach it coming back.
fn storable_tab(tab: &Tab, states: &NavigationStates) -> StorableTab {
    let mut kept = tab.clone();
    kept.pending_url = None;
    kept.playing_audio = false;
    kept.loading_complete = true;
    kept.last_error = None;
    // An address inside an extension is not written down, and its history goes
    // with it. The host in one is a uuid **WebKit** minted for a live context
    // and mints again on the next launch, so a stored one names nothing — it
    // would come back as a tab whose address resolves to no extension, which is
    // a refusal screen where an options page used to be. The tab itself is kept
    // and comes back blank, which is where it was before anybody opened one.
    if crate::extension_url::claims_scheme(kept.url.as_deref().unwrap_or_default()) {
        kept.url = None;
        kept.title = None;
        return StorableTab {
            navigation_state: None,
            tab: kept,
        };
    }
    StorableTab {
        navigation_state: states.get(tab.id).map(|s| s.to_vec()),
        tab: kept,
    }
}

impl StorableDownload {
    /// `None` for a download that is not written down at all.
    ///
    /// **A download still running is stored as interrupted.** If this save
    /// turns out to be the last thing we write, that is exactly what happened:
    /// the process went away and `WKDownload` went with it. Writing "in
    /// progress" would leave the next launch showing a bar for a transfer that
    /// stopped hours ago, which is the interface asserting something it cannot
    /// back up. If we are still running, the in-memory state is untouched and
    /// the next save corrects the row.
    ///
    /// **Failures and cancellations are not stored.** There is no file at the
    /// far end of them, so a row would offer Reveal in Finder for nothing.
    /// Within the session they are worth showing — you asked for something and
    /// it did not arrive — and by the next launch that is over.
    fn project(download: &Download) -> Option<Self> {
        let state = match download.state {
            DownloadState::Completed => StorableDownloadState::Completed,
            DownloadState::InProgress | DownloadState::Interrupted => {
                StorableDownloadState::Interrupted
            }
            DownloadState::Cancelled | DownloadState::Failed => return None,
        };
        Some(Self {
            id: download.id.clone(),
            url: download.url.clone(),
            filename: download.filename.clone(),
            path: download.path.clone(),
            state,
            received_bytes: download.received_bytes,
            total_bytes: download.total_bytes,
            started_at_ms: download.started_at_ms,
        })
    }
}

#[cfg(test)]
#[path = "storable_tests.rs"]
mod tests;
