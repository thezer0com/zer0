//! The wire between the core and whatever is hosting the web engine.
//!
//! Everything flows one way: an [`Action`] goes in, state changes, and zero or
//! more [`EngineCommand`]s come out. The host never decides anything, it
//! reports facts and carries out commands.

use crate::bookmarks::BookmarkId;
use crate::certificates::{ServerTrustRequest, TrustDecision};
use crate::chat::{
    ChatErrorKind, ConsentChoice, ConversationId, Message, MessageId, ToolCallId, ToolDescriptor,
    ToolInvocation,
};
use crate::downloads::{DownloadErrorKind, DownloadId};
use crate::http_auth::{AuthChoice, AuthDecision, HttpAuthRequest};
use crate::icons::IconCandidate;
use crate::mcp::ReportedTool;
use crate::model::{NavigationErrorKind, SpaceId, SpaceProfile, TabId, TabKind, WindowId};
use crate::page_dialogs::{PageDialogAnswer, PageDialogRequest};
use crate::page_menu::{PageMenuItem, PageTarget};
use crate::routing::RoutePattern;
use crate::site_permissions::{SiteCapability, SiteChoice, SiteDecision, SitePermissionRequest};
use crate::tint::DeclaredColor;

/// What a conversation is being opened about.
///
/// The tab is resolved in the core rather than passed in by whoever handled the
/// key press, so "the page you are on" means one thing on every platform — and
/// so the fallback when there is no page is a decision with a test rather than
/// whatever each shell does with a `nil`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum ChatSubject {
    /// ⌘E. The page in the active tab, or nothing at all when there is none.
    CurrentPage,
    /// From the command bar. A question about no page in particular, which
    /// lands in the active space's own thread.
    Nothing,
    /// A named tab: a context menu, or a panel being reopened.
    Page { tab: TabId },
}

/// What a new window opens onto.
///
/// An enum rather than an `Option<SpaceId>` because the two cases are two
/// decisions, and one of them creates a cookie jar. Spelled out, so a third
/// kind of window has to be argued for rather than smuggled in as a `None`.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum WindowContents {
    /// ⌘N. The space the window you pressed it in is showing, with one new tab.
    ///
    /// The same space and therefore the same cookie jar: a second window that
    /// logged you out of everything would be a private window nobody asked
    /// for. And one tab rather than none, because a window with nothing in it
    /// is a dead end you have to press something else to escape.
    CurrentSpace,
    /// ⇧⌘N. A fresh ephemeral space, and a window showing only that.
    ///
    /// Private browsing in this browser is not a second mechanism: an ephemeral
    /// space already is one (ADR-0007, ADR-0023) — its own jar, nothing written
    /// down. The shell supplies the jar's name for the same reason
    /// [`Action::CreateSpace`] does.
    NewPrivateSpace { name: String, data_store_id: String },
}

/// What a page stated when it asked for a view of its own, exactly as the
/// engine reported it and with nothing worked out yet.
///
/// Every field is `None` when the page said nothing about it. That distinction
/// is the whole content of this type: measured on WebKit, `window.open(url)`
/// with no feature string reports all seven empty, and
/// `window.open(url, 'oauth', 'width=480,height=640')` reports two of them —
/// so "did the page describe a window" is answerable, and it is the only thing
/// a browser has to go on.
///
/// Reported rather than interpreted. The host translates its own vocabulary
/// into these — `WKWindowFeatures` on Apple, `WebKitWindowProperties` on
/// webkit2gtk — and what they add up to is decided in
/// [`WindowRequest::asked_for_a_window`], here, so both hosts answer alike.
///
/// `allowsResizing` is deliberately not carried: a page that asked for a
/// resizable window asked for nothing about whether it wanted a window.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct WindowRequest {
    pub width: Option<f64>,
    pub height: Option<f64>,
    pub x: Option<f64>,
    pub y: Option<f64>,
    pub menu_bar_visible: Option<bool>,
    pub status_bar_visible: Option<bool>,
    pub toolbars_visible: Option<bool>,
}

impl WindowRequest {
    /// Whether the page asked for a **window** rather than for another tab.
    ///
    /// One sentence: a page that said anything about the shape of what it
    /// wanted — any size, any position, any piece of window chrome turned off
    /// — asked for a window. A page that said nothing asked for a tab.
    ///
    /// Chrome bar off is a request; chrome bar *on* is not. `window.open(url,
    /// name, 'toolbar=yes')` is a page asking for something that looks like an
    /// ordinary window, which is what a tab already is.
    pub fn asked_for_a_window(&self) -> bool {
        self.width.is_some()
            || self.height.is_some()
            || self.x.is_some()
            || self.y.is_some()
            || self.menu_bar_visible == Some(false)
            || self.status_bar_visible == Some(false)
            || self.toolbars_visible == Some(false)
    }
}

/// Why a reply stopped, as the provider host read it.
///
/// The distinction the core acts on is `ToolCalls` versus the rest; `MaxTokens`
/// exists so an answer the provider cut short is not drawn as a whole one.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum ReplyStop {
    /// The model finished saying what it had to say.
    EndOfTurn,
    /// It stopped because it wants tools run.
    ToolCalls,
    /// It ran out of room. The text is a fragment and must not read as final.
    MaxTokens,
}

/// Something that happened. Either the user did it, or the engine reported it.
#[derive(Debug, Clone, PartialEq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum Action {
    // --- user intents ---
    /// `space: None` means the active space.
    OpenTab {
        space: Option<SpaceId>,
        url: Option<String>,
        parent: Option<TabId>,
    },
    CloseTab {
        tab: TabId,
    },
    /// A page asked for a view of its own: `window.open`, or a link carrying
    /// `target="_blank"`.
    ///
    /// The engine has already built the view by the time this arrives — it has
    /// to, because the page's `window.open` call is waiting on the object — so
    /// what comes back is [`EngineCommand::AdoptWebView`] and never
    /// `CreateWebView`. See ADR-0075.
    PageOpenedWindow {
        opener: TabId,
        request: WindowRequest,
    },
    /// A page belonging to an extension sent **itself** somewhere its view
    /// cannot go: `window.location.href = …`, a plain link, a form post.
    ///
    /// The engine cannot carry this out and does not say so. Measured, in a
    /// view built from an extension's configuration: the navigation delegate is
    /// asked about `https://example.com/`, answers `.allow`, and then nothing
    /// happens at all — no start, no failure, no commit, and the tab sits on
    /// the extension's page. That is the mirror of the rule
    /// `WKWebExtensionContext.h` states in the other direction, and it is why
    /// ADR-0104's leaving half cannot be left to the engine.
    ///
    /// So the shell cancels it and says so here, and the crossing is made where
    /// every other crossing is made. See ADR-0104.
    PageLeftExtension {
        tab: TabId,
        url: String,
    },
    /// A page called `window.close()` on itself.
    ///
    /// Whether it is allowed to is decided here rather than by the engine,
    /// which is more permissive than a browser should be. See ADR-0075.
    PageClosedWindow {
        tab: TabId,
    },
    /// Somebody chose one of the rows this browser puts in the engine's context
    /// menu.
    ///
    /// The `target` the row was drawn for travels back with it, so the core
    /// never has to trust a second hit test taken at a different moment — and
    /// so it can check the row really belonged to that target before acting.
    /// See [`crate::page_menu`] and ADR-0091.
    ChosePageMenuItem {
        tab: TabId,
        item: PageMenuItem,
        target: PageTarget,
    },
    ActivateTab {
        tab: TabId,
    },
    /// Reorder within a space, or move across spaces. `index` is clamped.
    MoveTab {
        tab: TabId,
        space: SpaceId,
        index: u32,
    },
    /// A drag, stated the way the sidebar states it: a destination group, and
    /// the row the tab was let go above.
    ///
    /// [`Action::MoveTab`] takes an index into a space's whole order, which is
    /// the wrong unit for a drop. The sidebar draws three filtered lists, so
    /// the third row of "Today" is not the third entry of `tab_order`.
    /// Translating one into the other is behaviour, and so is landing in a
    /// group you were not in, which is what changes a tab from Today to Pinned.
    /// Both happen here rather than in the view that happened to know where
    /// the pointer was.
    MoveTabToGroup {
        tab: TabId,
        space: SpaceId,
        kind: TabKind,
        /// The row the tab lands above. `None` is the end of the group.
        before: Option<TabId>,
    },
    SetTabKind {
        tab: TabId,
        kind: TabKind,
    },
    SetTabMuted {
        tab: TabId,
        muted: bool,
    },
    SetTabZoom {
        tab: TabId,
        factor: f64,
    },
    /// Move focus by `delta` within the active space, wrapping around.
    CycleTab {
        delta: i32,
    },
    /// 1-based, as printed on the keyboard. Anything past the end selects the
    /// last tab, and so does the ninth slot itself however many tabs are open —
    /// ⌘9 means "the last one" in Chrome, Safari, Firefox and Edge alike.
    SelectTabByIndex {
        index: u32,
    },
    /// Bring back the most recently closed tab.
    ReopenClosedTab,
    /// Raw text from the command bar. The core decides URL vs. search.
    NavigateTo {
        tab: TabId,
        input: String,
    },
    /// Put one of the browser's own addresses on screen.
    ///
    /// What ⌘Y and ⇧⌘J dispatch. Distinct from [`Action::NavigateTo`] with the
    /// same address typed in, and the difference is the whole reason it exists:
    /// typing an address means *this tab*, while pressing the chord means "show
    /// me my history" and must not take the page you were reading. So this
    /// opens a tab, or returns to the one already showing that address, the way
    /// ⌘E returns to a conversation rather than opening a second copy of it.
    ///
    /// It carries an [`crate::InternalAddress`] rather than a URL string
    /// because a shell writing `"zer0://history"` out for itself would be a
    /// second spelling of an address the core already owns.
    OpenInternalPage {
        address: crate::internal_url::InternalAddress,
    },
    GoBack {
        tab: TabId,
    },
    GoForward {
        tab: TabId,
    },
    Reload {
        tab: TabId,
        from_origin: bool,
    },

    // --- two pages at once ---
    /// Show two pages side by side, or put the pair away.
    ///
    /// With a split up this dismisses it and the focused pane takes the whole
    /// area. Without one it pairs the active tab with the next tab in the
    /// space — and when the space has nothing else to pair with, it opens a
    /// tab to pair with, because asking for two panes and being given one is
    /// the browser ignoring you.
    ToggleSplit,
    /// Put `tab` beside the active one, which is what "Open in Split" means.
    /// Ignored for a tab in another space: two panes drawing from two cookie
    /// jars would be one window claiming to be two.
    SplitWith {
        tab: TabId,
    },
    /// Move the keyboard to the other pane. Nothing to do without a split.
    FocusOtherPane,
    /// Where the divider sits, as the leading pane's share of the width.
    /// Clamped, so neither side can be dragged out of existence.
    SetSplitRatio {
        space: SpaceId,
        ratio: f64,
    },

    ActivateSpace {
        space: SpaceId,
    },
    /// The shell supplies `data_store_id` so the core stays free of randomness
    /// and stays deterministic under test.
    ///
    /// `ephemeral` is decided **here**, at creation, and not by a
    /// `SetSpaceProfile` a moment later. A space is handed to the engine host
    /// the instant it has a tab, and the host turns a persistent
    /// `data_store_id` into a real directory on disk; flipping the flag
    /// afterwards rebuilds the views onto a non-persistent store and leaves
    /// that directory behind with nothing pointing at it. A cookie jar nobody
    /// can reach from the interface is exactly the leak ADR-0007 deletes jars
    /// to avoid.
    CreateSpace {
        name: String,
        data_store_id: String,
        ephemeral: bool,
    },
    RenameSpace {
        space: SpaceId,
        name: String,
    },
    /// Closes the space and every tab in it. Ignored for the last space.
    CloseSpace {
        space: SpaceId,
    },
    /// Move to the next or previous space, wrapping around.
    CycleSpace {
        delta: i32,
    },
    /// 1-based, as printed on the keyboard, over the spaces in the order the
    /// chips are drawn in.
    ///
    /// Deliberately **not** [`Action::SelectTabByIndex`]'s "the ninth slot is
    /// the last one". That rule is Chrome's, Safari's, Firefox's and Edge's
    /// about tabs, and a finger arrives already knowing it; nobody's browser
    /// has a chord for a space, so there is no memory to honour and inventing
    /// the rule here would mean ⌃9 landing somewhere the person did not name.
    /// An index past the end does nothing, and does it silently — the chips
    /// are on screen and visibly number fewer than what was pressed.
    SelectSpaceByIndex {
        index: u32,
    },
    /// User agent, ephemerality: the half of isolation the cookie jar does not
    /// cover. Existing web views are rebuilt so the change actually takes hold.
    SetSpaceProfile {
        space: SpaceId,
        profile: SpaceProfile,
    },

    // --- windows ---
    /// Open another window. See [`WindowContents`] for what goes in it.
    OpenWindow {
        onto: WindowContents,
    },
    /// Close a window and every tab in it. Ignored for the last window.
    CloseWindow {
        window: WindowId,
    },
    /// The platform says this window is in front now.
    ///
    /// Sent from the key monitor before the command it is about to run, and
    /// from `windowDidBecomeKey`. Without it every command would act on
    /// whichever window last happened to change something, which is the defect
    /// ADR-0053 fixed for auxiliary windows and did not have to think about
    /// between two browser windows.
    FocusWindow {
        window: WindowId,
    },

    // --- keeping a page without keeping a tab ---
    /// Keep the page a tab is showing. `None` means the active tab.
    ///
    /// Which tab "this page" means is resolved in the core, the same way
    /// [`ChatSubject::CurrentPage`] is and for the same reason: so that ⌘D
    /// means one thing on every platform, and so that the answer when there is
    /// no page is a decision with a test rather than whatever each shell does
    /// with a `nil`.
    ///
    /// Carries no space. A bookmark does not have one — see
    /// [`crate::bookmarks`] — so there is no field here for a shell to fill in
    /// with the wrong one.
    ///
    /// Keeping a page that is already kept changes nothing. It is deliberately
    /// not a toggle: a second ⌘D that deleted the bookmark would make the
    /// safest chord in the browser destructive on the press nobody was
    /// counting.
    SaveBookmark {
        tab: Option<TabId>,
    },
    /// Rename one, or relabel it. `tags` replaces whatever was there, and is
    /// lowercased and deduplicated by the core so two spellings of one label
    /// cannot become two labels.
    EditBookmark {
        bookmark: BookmarkId,
        title: String,
        tags: Vec<String>,
    },
    /// Stop keeping it. The only way a bookmark goes away, and nothing reaches
    /// it by accident.
    RemoveBookmark {
        bookmark: BookmarkId,
    },

    // --- air traffic ---
    /// Rules are evaluated in order, so a new one is appended last.
    AddRoute {
        pattern: RoutePattern,
        space: SpaceId,
    },
    RemoveRoute {
        index: u32,
    },
    SetRouteEnabled {
        index: u32,
        enabled: bool,
    },

    /// Advances the clock and archives whatever aged out. The shell sends this
    /// periodically; nothing else in the core reads wall time.
    Tick {
        now_ms: u64,
    },

    // --- downloads, asked for ---
    /// Stop it. The partial file is left where it is, so nothing disappears
    /// from disk without the person doing it themselves.
    CancelDownload {
        id: DownloadId,
    },
    /// Ask for the same URL again. The old entry is replaced rather than kept
    /// beside the new one: two rows for one file is noise.
    RetryDownload {
        id: DownloadId,
    },
    /// Carry on from where it stopped, keeping what already arrived.
    ///
    /// Distinct from `RetryDownload`, which throws the partial file away and
    /// starts at byte zero. Only ever answered for a download the host has said
    /// it can still resume — see [`Action::DownloadResumability`].
    ResumeDownload {
        id: DownloadId,
    },
    /// Forget one entry. The file stays on disk.
    RemoveDownload {
        id: DownloadId,
    },
    /// Forget everything that has stopped, leaving anything still running.
    ClearFinishedDownloads,

    // --- downloads, reported by the engine host ---
    /// The engine has a download and needs somewhere to put it. The core
    /// answers with `AcceptDownload`, `AskDownloadDestination` or
    /// `CancelDownload`, and the host holds the transfer until it does.
    ///
    /// `suggested_filename` comes from the server or from the page and is
    /// treated as hostile. `default_directory` is the host's own Downloads
    /// folder: the platform knows where that is, the core decides whether to
    /// use it.
    DownloadStarted {
        id: DownloadId,
        tab: Option<TabId>,
        url: String,
        suggested_filename: String,
        /// `None` when the server sent no length.
        total_bytes: Option<u64>,
        default_directory: String,
    },
    /// Where the person said to put it, after being asked.
    DownloadDestinationChosen {
        id: DownloadId,
        path: String,
    },
    DownloadProgressed {
        id: DownloadId,
        received_bytes: u64,
        /// Still `None` when the server never said.
        total_bytes: Option<u64>,
    },
    DownloadFinished {
        id: DownloadId,
    },
    DownloadFailed {
        id: DownloadId,
        kind: DownloadErrorKind,
        message: String,
    },
    /// Whether the host is holding what it would take to carry on from where
    /// this download stopped.
    ///
    /// A fact only the host can know: the engine decides whether a stopped
    /// transfer produced resume data at all, and the host is what holds it. It
    /// arrives *after* the stop it is about, because the engine hands the blob
    /// over asynchronously, and it can arrive as `false` later — when the host
    /// drops the blob to stay within its own bound, or when a resume it was
    /// asked for could not be started.
    ///
    /// Both directions matter. Without the `false` this becomes a Resume button
    /// that does nothing, which ADR-0018 forbids more strongly than it forbids
    /// no button at all.
    DownloadResumability {
        id: DownloadId,
        resumable: bool,
    },

    // --- printing ---
    /// The page called `window.print()`.
    ///
    /// A request rather than a command: the core decides whether a page is
    /// allowed to put a print panel up right now, on the same ground ADR-0089
    /// decides who a page's questions are shown to.
    PageAskedToPrint {
        tab: TabId,
    },

    // --- chat, asked for ---
    /// Open a conversation, and optionally ask it something in the same breath.
    ///
    /// `ask` carries the command bar's text so falling into chat from a
    /// half-typed query is one action rather than two. Two would mean an
    /// interface that opens an empty panel and then fills it, which is a
    /// flicker with a race in it.
    OpenChat {
        about: ChatSubject,
        ask: Option<String>,
    },
    /// Put a thread that already exists on screen.
    ///
    /// What the screen listing a page's conversations dispatches when one is
    /// picked. Distinct from [`Action::OpenChat`], which resolves a *subject*
    /// into whichever thread it opens with — here the thread is already known,
    /// because somebody read the list and chose it.
    ShowConversation {
        conversation: ConversationId,
    },
    /// Another thread about the same page as this one.
    ///
    /// The only way a page gets a second conversation, and it exists so that
    /// getting one is somebody's decision. Everything else that opens chat
    /// hands back the thread a page already has, because a browser that minted
    /// a fresh one each time would be indistinguishable from one that never
    /// remembered anything.
    StartAnotherConversation {
        like: ConversationId,
    },
    SendChatMessage {
        conversation: ConversationId,
        text: String,
    },
    /// Stop whatever this conversation is doing: the reply arriving, the tools
    /// running, the page being read. What has already arrived is kept.
    CancelChat {
        conversation: ConversationId,
    },
    /// Forget a thread outright. Destructive, and the only way to remove one
    /// short of closing what it is about.
    ClearConversation {
        conversation: ConversationId,
    },
    /// Answer a tool call the model asked for.
    ///
    /// The core does not run a tool until this arrives. There is no path that
    /// skips it: a call with no answer stays `AwaitingConsent` forever, which
    /// is the state a person can see and act on.
    DecideToolCall {
        call: ToolCallId,
        decision: ConsentChoice,
    },
    /// Change a remembered answer from Settings, without a call in flight.
    SetToolConsent {
        server: String,
        tool: String,
        allowed: bool,
    },
    /// Take a remembered answer back, so the next call asks again.
    ForgetToolConsent {
        server: String,
        tool: String,
    },

    // --- chat, reported by the hosts ---
    /// What the page said, after the browser was asked to attach it.
    ///
    /// The host must send this even when it read nothing — with `text` empty —
    /// because the conversation holds its question until it arrives. A page
    /// that could not be read still has an address worth telling the model.
    PageContextCaptured {
        conversation: ConversationId,
        url: String,
        title: String,
        text: String,
    },
    /// The request is out, and this is what actually answered it.
    ///
    /// `model` comes from the host because only the host knows what the
    /// configuration resolved to. It is recorded on the message rather than
    /// read from settings when drawn, so last week's answers keep last week's
    /// label (ADR-0018).
    ChatReplyStarted {
        message: MessageId,
        model: String,
    },
    /// Another piece of the reply. Appended in arrival order.
    ChatReplyDelta {
        message: MessageId,
        text: String,
    },
    /// The model wants a tool run. Nothing runs because of this: the core
    /// decides whether it may, and mostly the answer is "ask".
    ChatToolCallRequested {
        message: MessageId,
        invocation: ToolInvocation,
    },
    ChatReplyFinished {
        message: MessageId,
        stop: ReplyStop,
    },
    /// The reply could not be produced. `message` is `None` when it failed
    /// before there was anything to fail on — no provider configured at all.
    ChatFailed {
        conversation: ConversationId,
        message: Option<MessageId>,
        kind: ChatErrorKind,
        detail: String,
    },
    ToolCallFinished {
        call: ToolCallId,
        result: String,
    },
    ToolCallFailed {
        call: ToolCallId,
        kind: ChatErrorKind,
        detail: String,
    },
    /// What one server says it can do, as a whole list.
    ///
    /// Whole rather than incremental: a tool that has gone away has to stop
    /// being callable, and there is no "removed" event to rely on.
    ///
    /// [`ReportedTool`] and not [`ToolDescriptor`]: this is what came off a
    /// pipe, unnamed and unchecked. Sanitising the names, dropping the
    /// collisions, capping the list and taking the fingerprints all happen in
    /// [`crate::mcp`] when this arrives — once, in the core, so no host invents
    /// its own answer to what a tool is called (ADR-0050).
    ///
    /// A listing for a server nobody configured changes nothing. Adopting a
    /// server is a thing a person does, and a host that could add one by
    /// reporting about it would be an install path with no screen in front of
    /// it.
    ToolsListed {
        server: String,
        tools: Vec<ReportedTool>,
    },

    // --- facts reported by the engine host ---
    NavigationStarted {
        tab: TabId,
        url: String,
    },
    NavigationCommitted {
        tab: TabId,
        url: String,
    },
    NavigationFinished {
        tab: TabId,
    },
    /// `kind` is the host's reading of its own error domain, which is the one
    /// thing the core cannot work out for itself. `message` is whatever the
    /// engine said, kept for the cases the categories do not cover.
    NavigationFailed {
        tab: TabId,
        kind: NavigationErrorKind,
        message: String,
    },
    /// The process rendering this tab's page ended while the tab was open.
    ///
    /// A fact and nothing more: no reason, because the engine gives none. What
    /// the browser does about it is [`crate::reducer`]'s answer, and it is
    /// deliberately not "load it again" — a page that ends its process *while
    /// loading* would then do it forever.
    PageProcessEnded {
        tab: TabId,
    },
    /// Where this tab has been, as the engine wrote it down just now.
    ///
    /// Reported after a navigation settles rather than continuously: the state
    /// only changes when the back/forward list does, and one blob per page load
    /// is a cost the commit that caused it was already paying.
    NavigationStateChanged {
        tab: TabId,
        state: Vec<u8>,
    },
    /// The engine would not take the state it was handed with this tab's view.
    ///
    /// The bytes are opaque, so this is the only way to find out — nothing on
    /// the core's side can tell a truncated archive from a whole one, and the
    /// engine's answer to a bad one is to keep no history and say nothing. The
    /// core answers with the load it had held back, so a corrupt state costs
    /// the back list and not the tab (ADR-0024).
    NavigationStateRefused {
        tab: TabId,
    },
    TitleChanged {
        tab: TabId,
        title: String,
    },
    AudioStateChanged {
        tab: TabId,
        playing: bool,
    },
    /// What colour the page is, from every source the host can read.
    ///
    /// Three fields rather than one ordered list, because which rung a value
    /// came from is what decides whether it wins — and that decision is the
    /// core's (see [`crate::tint::tint_for`]). A host that flattened them would
    /// be choosing the fallback order for itself.
    ///
    /// Reported when the page commits and again when it finishes, and at no
    /// other moment. That is deliberate: a page that animates its `theme-color`
    /// gets two samples rather than a strobing window (ADR-0047).
    ColorsDeclared {
        tab: TabId,
        /// `<meta name="theme-color">`, in document order, each carrying the
        /// result of its own `media` query.
        theme_colors: Vec<DeclaredColor>,
        /// The computed background of `documentElement`, then of `body`.
        /// Usually `rgba(0, 0, 0, 0)` for both, which is why there is a rung
        /// below this one.
        element_backgrounds: Vec<String>,
        /// What the engine actually painted behind the page, when it can say.
        /// The rung that answers for the majority of the web, which declares
        /// nothing at all.
        canvas_background: Option<String>,
    },

    // --- site icons ---
    /// What the page says its icon is. Reported for every page, including one
    /// in an ephemeral space: reading the DOM sends nothing anywhere, and the
    /// core is where the decision not to fetch belongs.
    ///
    /// `candidates` comes out of a page, so it is hostile input: the list is
    /// capped, and every URL in it is checked before anything is fetched.
    IconsDeclared {
        tab: TabId,
        candidates: Vec<IconCandidate>,
    },
    /// The bytes came back. Filed under the key the command carried rather
    /// than under the tab, because a tab can navigate — or move to another
    /// space — while the request is out, and the icon belongs to the site that
    /// was asked for, not to wherever the tab has got to since.
    ///
    /// The bytes are not trusted: a 200 with a 404 page in it is the ordinary
    /// case, not the edge.
    IconFetched {
        data_store_id: String,
        host: String,
        bytes: Vec<u8>,
    },
    /// The request did not produce usable bytes: no route to the host, a
    /// timeout, a 404, a body over the limit. Recorded rather than forgotten,
    /// so a site with no icon is not asked again on every navigation.
    IconFetchFailed {
        data_store_id: String,
        host: String,
    },

    // --- what a page asked the machine for ---
    /// A page wants the camera, the microphone, or both.
    ///
    /// Reported rather than answered: the host is holding the engine's decision
    /// handler under `request.request` and does nothing with it until an
    /// [`EngineCommand::AnswerSitePermission`] comes back naming that number.
    /// **Every one of these produces exactly one answer**, including the ones
    /// refused on sight — a handler nobody calls is a page whose promise never
    /// settles, which is the one outcome worse than a refusal.
    ///
    /// `asked_at_ms` is the shell's clock rather than the core's, for the same
    /// reason `default_consent_decision` takes one: `Action::Tick` advances
    /// once a minute, and the window this is measured against is half a second
    /// (see [`crate::site_permissions::PROMPT_SETTLE_MS`]).
    ///
    /// Nothing in here is trusted. The origin came off a `WKSecurityOrigin`,
    /// the tab may have closed since, and the request may be the fortieth in a
    /// second: `site_permissions::gate` decides, and mostly the answer is no
    /// without anybody being asked.
    SitePermissionRequested {
        request: SitePermissionRequest,
    },
    /// Somebody answered the sheet.
    ///
    /// `decided_at_ms` is the shell's clock again, and the arithmetic against
    /// `asked_at_ms` is the defence against a keystroke that was already in
    /// flight when the page chose to interrupt. An answer inside that window
    /// changes nothing and leaves the question on screen.
    DecideSitePermission {
        request: u64,
        choice: SiteChoice,
        decided_at_ms: u64,
    },
    /// Change an answer from Settings, with no page waiting on it.
    ///
    /// `allowed: false` is a refusal that is written down, not an erasure —
    /// and it reaches the engine: whatever is capturing right now stops.
    SetSitePermission {
        space: SpaceId,
        origin: String,
        capability: SiteCapability,
        allowed: bool,
        decided_at_ms: u64,
    },
    /// Take an answer back entirely, so the site is asked again next time.
    ///
    /// Different from refusing it, and the screen offers both: "stop letting
    /// it" and "ask me again" are different things to want. Anything capturing
    /// under the old answer stops either way.
    ForgetSitePermission {
        space: SpaceId,
        origin: String,
        capability: SiteCapability,
    },

    // --- what the server asked of you ---
    /// A server will not serve this page to somebody who has not named
    /// themselves.
    ///
    /// Reported rather than answered, for the same reason
    /// [`Action::SitePermissionRequested`] is: the host is holding the engine's
    /// completion handler under `request.request` and does nothing with it
    /// until an [`EngineCommand::AnswerHttpAuth`] names that number. **Every
    /// one of these produces exactly one answer.** A dropped handler here is
    /// worse than elsewhere — measured, the navigation simply never finishes
    /// and never fails, so the tab sits on a white rectangle indefinitely.
    ///
    /// Nothing in it is trusted. The realm came off the wire and the origin off
    /// a protection space; [`crate::http_auth::gate`] decides, and most of the
    /// answers are no without anybody being asked.
    HttpAuthRequested {
        request: HttpAuthRequest,
    },
    /// Somebody answered the panel.
    ///
    /// **No password rides on this action, and none can**: `AuthChoice` has
    /// three cases and none of them carries a value. The shell holds what was
    /// typed and hands it straight to the engine's credential; the core is told
    /// only what was decided, which is the guarantee ADR-0064 made for form
    /// logins applied to this one.
    DecideHttpAuth {
        request: u64,
        choice: AuthChoice,
    },

    /// A server's certificate did not check out, with the facts.
    ///
    /// Emitted **before** the navigation fails, because that is when the engine
    /// has the certificate and afterwards nobody does. The reducer keeps the
    /// facts against the tab so that when `-1202` arrives a moment later the
    /// screen can say which thing is wrong instead of listing what it might be.
    ///
    /// Reported rather than answered: exactly one
    /// [`EngineCommand::AnswerServerTrust`] comes back naming `request`.
    ServerTrustRejected {
        request: ServerTrustRequest,
    },
    /// Somebody deliberately waved one certificate through.
    ///
    /// Named by fingerprint rather than by host, so this covers the certificate
    /// that was on screen and nothing else. It is not persisted; see
    /// [`crate::http_auth::TrustExceptions`].
    TrustThisCertificate {
        tab: TabId,
        origin: String,
        fingerprint: String,
    },

    // --- what a page said to you ---
    /// A page called `alert()`, `confirm()`, `prompt()`, or opened a file
    /// control.
    ///
    /// Reported rather than answered, exactly like
    /// [`Action::SitePermissionRequested`]: the host holds the engine's
    /// completion handler under `request.request` and does nothing with it
    /// until an [`EngineCommand::AnswerPageDialog`] names that number.
    ///
    /// **These block the page.** `alert()` does not return until the handler
    /// runs, so a request that produces no answer is not a dropped feature, it
    /// is a frozen tab with nothing on screen. Every one of these produces
    /// exactly one answer, including the ones nobody is ever shown.
    ///
    /// Nothing in here is trusted — the message is a string the page wrote and
    /// the origin came off a `WKSecurityOrigin`. `page_dialogs::gate` decides
    /// what happens to it.
    PageRaisedDialog {
        request: PageDialogRequest,
    },
    /// Somebody answered a page's dialog, or closed it.
    ///
    /// `silence` is the checkbox: when true, everything else this page asks is
    /// cancelled until the tab navigates. It rides on the answer rather than
    /// arriving as an action of its own so that a person can tick it and press
    /// Cancel in one gesture and have both land together — two actions would
    /// leave a window in which the page could ask again.
    AnsweredPageDialog {
        request: u64,
        answer: PageDialogAnswer,
        silence: bool,
        /// The shell's clock. Measured against the dialog's `asked_at_ms` by
        /// [`crate::site_permissions::answered_too_soon`] — the same defence,
        /// and the same half second, the camera sheet has. Two modal panels a
        /// page can summon at a moment of its own choosing, one of them guarded
        /// against a keystroke already in flight and the other not, is a gap
        /// with nothing but luck in it.
        decided_at_ms: u64,
    },
}

/// What a tab's view is built from.
///
/// **Two arms, and neither has a field the other's answer would fit in.** That
/// is the guarantee rather than a rule: a page of the web is built in its
/// space's cookie jar and cannot name an extension; a page belonging to an
/// extension is built from that extension's own configuration and has no data
/// store to give, so it cannot claim a space's.
///
/// The asymmetry is the engine's and was measured rather than assumed. An
/// extension's configuration arrives carrying `WKWebsiteDataStore.default()`,
/// and it will not take another: assigning a space's identified store — or a
/// non-persistent one — leaves `WKWebView.init` never returning, while the same
/// two assignments on an ordinary configuration build a view and load a page.
/// So there is no such thing as an extension's page in a space's jar, and a
/// `data_store_id` on this arm would be a field describing something that
/// cannot exist.
///
/// The consequence is carried in [`crate::reducer`] and not here: a space that
/// records nothing has nowhere to put a page whose store is shared and
/// persistent, so it refuses one (ADR-0023).
#[derive(Debug, Clone, PartialEq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum ViewConfiguration {
    /// An ordinary page, in the cookie jar of the space its tab is in.
    ///
    /// `data_store_id` identifies that jar. The Apple host feeds it to
    /// `WKWebsiteDataStore(forIdentifier:)`.
    Space {
        data_store_id: String,
        profile: SpaceProfile,
    },
    /// A page belonging to an extension: its options screen, its onboarding,
    /// anything it opens for itself.
    ///
    /// `base_host` is the host out of the address — a uuid **WebKit** minted
    /// for a live context, not the id this browser installed under, and a
    /// different one on the next launch. The core carries it and resolves
    /// nothing: which contexts exist is the shell's answer, and a host nothing
    /// answers to is refused there rather than attributed to whichever
    /// extension is at hand.
    Extension { base_host: String },
}

/// An instruction for the engine host. On Apple platforms these map onto
/// `WKWebView`; on Linux they will map onto `webkit2gtk`.
#[derive(Debug, Clone, PartialEq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum EngineCommand {
    /// Build this tab a view. What it is built from is
    /// [`ViewConfiguration`]'s answer and not the host's.
    CreateWebView {
        tab: TabId,
        configuration: ViewConfiguration,
        /// Where this tab has been, for the engine to put back. Opaque here and
        /// opaque to the host; see [`crate::navigation_state`].
        ///
        /// On this command rather than one of its own, because that makes it
        /// the one door: every view a host builds is built here, so a view that
        /// exists without having been offered its history is not a state this
        /// protocol can express. `None` is the ordinary case — a new tab, and
        /// every tab in a browser that has never saved.
        ///
        /// **When this is `Some`, no `LoadUrl` follows.** The state carries the
        /// address, and loading it on top would leave the person a Back press
        /// that lands on the page they are already reading — measured, the load
        /// appends a second entry for the same URL. A host that could not use
        /// the state says so with [`Action::NavigationStateRefused`] and is sent
        /// the `LoadUrl` then.
        navigation_state: Option<Vec<u8>>,
    },
    DestroyWebView {
        tab: TabId,
    },
    /// Keep the view the engine has already built, as this tab.
    ///
    /// The counterpart to `CreateWebView` for the one case where the host does
    /// not get to build anything: a page called `window.open`, and the engine
    /// handed the host a configuration and is waiting for a view made from
    /// **that** configuration. A view built any other way is a different
    /// browsing context — no `window.opener`, no `postMessage` home, no
    /// `window.close()` — which is every OAuth flow half-working.
    ///
    /// There is no `data_store_id` and no `profile` on it because there is
    /// nothing for the host to choose: the configuration the engine handed over
    /// already carries the opener's cookie jar. That is why a pop-up cannot
    /// escape its space, and why the guarantee is structural rather than a rule
    /// somebody has to remember (ADR-0075).
    ///
    /// No `LoadUrl` follows one of these. The engine navigates the view it made
    /// as soon as the host returns it.
    AdoptWebView {
        tab: TabId,
    },
    LoadUrl {
        tab: TabId,
        url: String,
    },
    Reload {
        tab: TabId,
        from_origin: bool,
    },
    /// Put the print panel up for this tab.
    ///
    /// Only ever issued for a page somebody is looking at. ⌘P does not come
    /// through here — a person pressing a key on the window in front of them has
    /// already answered the question this command exists to gate — so this is
    /// the page-initiated road and nothing else.
    PrintPage {
        tab: TabId,
    },
    GoBack {
        tab: TabId,
    },
    GoForward {
        tab: TabId,
    },
    FocusWebView {
        tab: TabId,
    },
    SetMuted {
        tab: TabId,
        muted: bool,
    },
    SetZoom {
        tab: TabId,
        factor: f64,
    },
    /// The space's cookie jar is gone for good; the host should delete the
    /// backing store rather than leave it orphaned on disk.
    DeleteDataStore {
        data_store_id: String,
    },

    /// Write this download to `path`.
    ///
    /// The core guarantees two things about it, because `WKDownload` requires
    /// both: the containing directory exists, and nothing is there yet. The
    /// second is not only an API contract — it is the promise that a download
    /// can add a file but never replace one.
    AcceptDownload {
        id: DownloadId,
        path: String,
    },
    /// Put a save panel up seeded with these, then report back with
    /// `DownloadDestinationChosen`, or `CancelDownload` if it is dismissed.
    AskDownloadDestination {
        id: DownloadId,
        directory: String,
        filename: String,
    },
    CancelDownload {
        id: DownloadId,
    },
    /// Fetch this URL as a file rather than as a page.
    ///
    /// Issued through a tab's web view, because that is what carries the
    /// space's cookies. Retrying a file that needed a login through the wrong
    /// jar fetches a sign-in page and calls it the download.
    StartDownload {
        tab: TabId,
        url: String,
    },
    /// Carry on with the download the host is holding resume data for.
    ///
    /// Through a tab's web view for the same reason `StartDownload` is: the
    /// resume goes out over the space's cookie jar, and the engine will only
    /// take resume data on a view in the session that produced it.
    ///
    /// No path comes with it. Measured: a resumed `WKDownload` is never asked
    /// where to write, because the destination the core chose the first time is
    /// inside the resume data — so there is nothing here for a second answer to
    /// disagree with.
    ResumeDownload {
        tab: TabId,
        id: DownloadId,
    },

    /// Fetch this site's icon, anonymously, and report back with
    /// [`Action::IconFetched`] or [`Action::IconFetchFailed`].
    ///
    /// Not routed through a tab's web view, and that is the decision rather
    /// than an omission. An icon fetched through a space's cookie jar is a
    /// request the site can attribute to whoever is logged in there; a request
    /// carrying no cookie, no credential and no cache entry tells the site
    /// strictly less than the page load it follows already did.
    ///
    /// `data_store_id` never leaves the machine. It says which space's cache
    /// the answer belongs in, and it comes back untouched.
    FetchIcon {
        data_store_id: String,
        host: String,
        url: String,
        /// Stop reading past this. The core re-checks what arrives, so this is
        /// a courtesy to memory rather than the guarantee.
        max_bytes: u32,
    },

    /// Ask a provider for a reply, and stream it back.
    ///
    /// The whole transcript travels with the request, so the host holds no
    /// conversation of its own. That is the same trade `BrowserSnapshot` makes
    /// and for the same reason: two copies of one thread eventually disagree,
    /// and the one that is wrong is always the one on screen.
    ///
    /// Nothing in here names a provider. Which one answers, with what key, at
    /// what address, under what model, is read from configuration by the host
    /// — the core knows only that it asked and what came back.
    ///
    /// The host reports [`Action::ChatReplyStarted`], then any number of
    /// [`Action::ChatReplyDelta`] and [`Action::ChatToolCallRequested`], then
    /// exactly one of [`Action::ChatReplyFinished`] or [`Action::ChatFailed`].
    /// A request that ends in neither leaves a thread that never stops
    /// spinning.
    StartChatReply {
        conversation: ConversationId,
        /// The assistant message the reply is being written into. Already in
        /// the conversation, already streaming, and not in `transcript`.
        message: MessageId,
        /// Everything said so far, oldest first.
        transcript: Vec<Message>,
        /// What may be called. A host must not offer the model anything that
        /// is not in here: the core refuses a call it cannot name, so offering
        /// more only produces calls that get thrown away.
        tools: Vec<ToolDescriptor>,
    },
    /// Stop a reply in flight. Whatever already arrived stays where it is.
    CancelChatReply {
        message: MessageId,
    },
    /// Run a tool. Only ever emitted after somebody said it may.
    RunToolCall {
        conversation: ConversationId,
        invocation: ToolInvocation,
    },
    CancelToolCall {
        call: ToolCallId,
    },
    /// Read the page in `tab` and report it with
    /// [`Action::PageContextCaptured`].
    ///
    /// Only ever emitted because somebody asked for chat about a page.
    /// Nothing here runs on navigation, on focus, or on a timer: page text
    /// leaves the page when it was asked for and at no other moment.
    CapturePageContext {
        conversation: ConversationId,
        tab: TabId,
        /// Stop reading past this. The core re-checks what arrives, so this is
        /// a courtesy to memory rather than the guarantee.
        max_chars: u32,
    },
    /// Ask a tool server what it can do, and report it with
    /// [`Action::ToolsListed`].
    ///
    /// `None` means every configured server, which is what a cold start needs:
    /// at that moment the core has adopted nobody and could not name one if it
    /// wanted to. A named server is what a reconnect needs — re-listing all of
    /// them because one came back would cost a round trip against every other
    /// server to learn what has not changed.
    ///
    /// A host answers with one [`Action::ToolsListed`] per server either way.
    /// There is no "and that was all of them": a server that answers nothing is
    /// reported as an empty list, and that is what stops its tools being
    /// callable.
    ListTools {
        server: Option<String>,
    },

    /// Bring up the window this command opens, and leave every tab alone.
    ///
    /// Emitted when one of the browser's own addresses resolves to a window
    /// rather than to a page — `zer0://settings` and, until they become pages
    /// of their own, `zer0://history` and `zer0://downloads` (ADR-0054).
    ///
    /// A [`crate::UiCommand`] rather than a window name, because the browser
    /// already has these commands, they already carry the rule about which
    /// window a command may land in (ADR-0053), and a second vocabulary for
    /// "open Settings at History" would be a second thing to keep in step.
    ///
    /// Not every `UiCommand` is meaningful here. Only the ones an address
    /// resolves to are ever emitted, and `internal_url::Effect` is the only
    /// thing that constructs one.
    RaiseWindow {
        command: crate::shortcuts::UiCommand,
    },

    /// Put a browser window on screen for `window`, and give it the keyboard.
    ///
    /// The core has already decided the window exists and what is in it; this
    /// says nothing about how big it is, where it sits or what it is made of,
    /// which are the shell's and which two platforms would reasonably disagree
    /// about.
    OpenBrowserWindow {
        window: WindowId,
    },
    /// Take a browser window off the screen. Its tabs have already been closed
    /// with their own `DestroyWebView`s, so this is the frame and nothing else.
    CloseBrowserWindow {
        window: WindowId,
    },

    /// Tell the page whether it may have what it asked for.
    ///
    /// `request` names the decision handler the host is holding. Exactly one of
    /// these is emitted per [`Action::SitePermissionRequested`], and the host
    /// calls that handler once and forgets it.
    ///
    /// [`crate::site_permissions::SiteDecision`] has two cases where
    /// `WKPermissionDecision` has three. The missing one is `Prompt`, which
    /// hands the question back to the engine's own dialog — the state this
    /// browser was in before ADR-0056, where the answer was chosen by nobody
    /// and recorded nowhere.
    AnswerSitePermission {
        request: u64,
        decision: SiteDecision,
    },

    /// Tell the server who you are, or that nobody answered.
    ///
    /// `request` names the completion handler the host is holding. Exactly one
    /// of these is emitted per [`Action::HttpAuthRequested`], including for the
    /// ones refused without anybody being asked — a handler nobody calls is a
    /// navigation that never finishes and never fails, which is measurably what
    /// this browser did before.
    ///
    /// **The credential is not in this command.** `UseCredential` says only
    /// "use what the panel collected"; the value never left the shell, which is
    /// what makes "a password cannot reach the core" structural rather than
    /// careful (ADR-0064).
    AnswerHttpAuth {
        request: u64,
        decision: AuthDecision,
    },

    /// Go on with this certificate, or refuse it.
    ///
    /// `Proceed` is only ever emitted when somebody already said yes to this
    /// exact certificate in this space. There is no path that produces it from
    /// a rule about a host.
    AnswerServerTrust {
        request: u64,
        decision: TrustDecision,
    },
    /// Stop this tab capturing, now.
    ///
    /// Emitted when an answer is taken back, so that revoking reaches the
    /// engine rather than repainting a row. Answering the *next* request with
    /// a refusal is not enough: a page that already holds a stream keeps it
    /// until something stops it, and the row would say "blocked" over a camera
    /// that is still on.
    StopCapture {
        tab: TabId,
        capability: SiteCapability,
    },

    /// Let the page carry on.
    ///
    /// `request` names the completion handler the host is holding for an
    /// `alert()`, a `confirm()`, a `prompt()` or a file control. Exactly one of
    /// these is emitted per [`Action::PageRaisedDialog`], and the host calls
    /// that handler once and forgets it.
    ///
    /// [`crate::page_dialogs::PageDialogAnswer`] has no variant that says yes
    /// on somebody's behalf, which is what stops the browser going back to
    /// answering `confirm()` with a Cancel nobody pressed.
    AnswerPageDialog {
        request: u64,
        answer: PageDialogAnswer,
    },
}
