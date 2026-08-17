//! The surface the Apple shell talks to.
//!
//! Deliberately small: send an [`Action`], get back the [`EngineCommand`]s to
//! carry out, then read a snapshot to render. Everything that decides anything
//! stays on the Rust side, including where the session is stored.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};

use std::path::{Path, PathBuf};

use crate::blocking::{self, BlockingSummary};
use crate::bookmarks::Bookmark;
use crate::certificates::CertificateReport;
use crate::chat::{Conversation, ConversationId, ConversationScope, ToolDescriptor, ToolGrant};
use crate::command_bar::{self, CommandBarIntent, Suggestion};
use crate::downloads::{Download, DownloadId};
use crate::ext::{self, InstalledExtension, StoreHosts};
use crate::extension_api::{self, ExtensionApiAnswer, HostFacts};
use crate::extension_permissions::{
    self, ConsentDecision, ConsentRequest, ExtensionStanding, PermissionKind,
};
use crate::history::{HistoryEntry, HistoryRange};
use crate::http_auth::AuthPrompt;
use crate::icon_store::IconStore;
use crate::icons::IconKey;
use crate::model;
use crate::model::{NavigationError, Space, SpaceId, Tab, TabId, Window, WindowId};
use crate::native_messaging::{self, NativeHostDecision, NativeHostOutcome};
use crate::page_dialogs::PageDialog;
use crate::preferences::{self, Preferences, SearchEngine};
use crate::protocol::{Action, EngineCommand, HostCapabilities};
use crate::reducer;
use crate::routing::Route;
use crate::session::Session;
use crate::session_store::SessionStore;
use crate::shortcuts::{Binding, Chord, UiCommand};
use crate::site_permissions::{SiteCapability, SiteGrant, SitePermissionPrompt};
use crate::storable::StorableSession;
use crate::store::Store;

/// A flattened view of the browser, cheap enough to re-read after every
/// dispatch. SwiftUI diffs it; we do not maintain a delta protocol until
/// profiling says we need one.
#[derive(Debug, Clone, uniffi::Record)]
pub struct BrowserSnapshot {
    pub spaces: Vec<Space>,
    pub tabs: Vec<Tab>,
    /// Every open window, oldest first. A shell draws one view per entry.
    pub windows: Vec<Window>,
    /// Which of them is in front, as the core understands it.
    pub key_window: WindowId,
    /// The key window's space and tab.
    ///
    /// Derived rather than a second source of truth: a shell drawing a window
    /// that is *not* in front reads [`BrowserSnapshot::windows`] for its own
    /// row. These two are here because most of the interface is about the
    /// window you are looking at, and making every call site walk the list to
    /// say so would be noise.
    pub active_space: SpaceId,
    pub active_tab: Option<TabId>,
    pub routes: Vec<Route>,
    /// Newest first. In the snapshot rather than behind its own call because
    /// the shelf and the Downloads pane both redraw from it, and a second way
    /// to read the same state is a second thing to keep in step.
    pub downloads: Vec<Download>,
    /// Changes whenever any site icon does.
    ///
    /// The bytes are not in here on purpose: a snapshot is re-read after every
    /// dispatch, and copying every icon across the FFI four times a second to
    /// draw a 16pt square would be absurd. This is the cheap half — a number
    /// that tells the shell when the icons it drew as letters are worth asking
    /// about again, through [`Zer0::icon`].
    pub icon_revision: u64,
    /// The question a page is waiting on, if one is on screen.
    ///
    /// In the snapshot rather than behind an [`EngineCommand`], and that is the
    /// decision rather than a convenience: the snapshot is re-read after every
    /// dispatch, so there is exactly one answer to *is something being asked*
    /// and a sheet cannot outlive the request behind it. A command would let a
    /// shell keep its own copy, and a permission dialog that is still on screen
    /// after the core has answered the page is the worst possible second source
    /// of truth.
    pub site_permission_prompt: Option<SitePermissionPrompt>,
    /// What a page is saying to you and waiting to hear back about, if that
    /// page is one somebody can currently see.
    ///
    /// Here rather than behind an [`crate::EngineCommand`] for the reason
    /// [`BrowserSnapshot::site_permission_prompt`] is: a panel that outlived
    /// the request behind it would be a page already answered with its question
    /// still on screen. It carries its own `window`, and the shell draws it on
    /// that window and no other — a page in one window must not be able to take
    /// the keyboard in another.
    ///
    /// A dialog raised by a tab nobody is looking at is *not* here and is *not*
    /// answered: it waits, held, until that tab is the one its window is
    /// showing. See [`crate::page_dialogs`].
    ///
    /// A list rather than one, because two windows can each be showing a page
    /// that asked something. At most one entry per window, so a shell reads its
    /// own row and never has to decide between two.
    pub page_dialogs: Vec<PageDialog>,
    /// The server asking who you are, if anything is.
    ///
    /// Here rather than behind an [`crate::EngineCommand`] for the reason
    /// [`BrowserSnapshot::site_permission_prompt`] is: one answer to "is
    /// something being asked", so a panel cannot outlive the challenge behind
    /// it. There is exactly one at a time — see [`crate::http_auth::HttpAuth`].
    pub http_auth_prompt: Option<AuthPrompt>,
    /// What was wrong with the certificate that stopped the active tab, if a
    /// certificate is what stopped it.
    ///
    /// Beside `NavigationError` rather than inside it, because the two are
    /// measured at different moments: this is taken while the trust challenge
    /// is open, and the error arrives after it has been answered. The screen
    /// draws the error and reaches for this when the error is
    /// `certificateInvalid`.
    pub certificate_report: Option<CertificateReport>,
}

/// The version of the core itself, so a host can show or log which core it
/// linked without keeping a second copy of the string that can drift.
///
/// A free function for the same reason `mcp_protocol_version` is one: the
/// version is a fact about the core, and a host that hardcoded it would
/// report the core it shipped last month.
#[uniffi::export]
pub fn core_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

/// How far along a download is, or `None` when that cannot be worked out.
///
/// A free function because a uniffi record carries no methods across the FFI,
/// and this rule has to exist exactly once. Writing it again in Swift is how
/// one side ends up drawing a bar for a length nobody sent.
#[uniffi::export]
pub fn download_fraction(download: Download) -> Option<f64> {
    download.fraction()
}

/// Hold a split's divider inside its limits.
///
/// A free function for the same reason `download_fraction` is one: how far the
/// divider may be pushed is behaviour, and it has to exist exactly once. The
/// shell asks this on every frame of the drag and dispatches the answer on
/// release, so the pane never appears to collapse and then spring back.
#[uniffi::export]
pub fn clamp_split_ratio(ratio: f64) -> f64 {
    model::clamp_split_ratio(ratio)
}

/// Where a split's divider rests when nobody has moved it.
///
/// Exported rather than written as `0.5` in the shell for the same reason as
/// above, and because it is the value a double-click on the divider goes back
/// to: "reset" and "how a split opens" must be the same number or resetting
/// puts it somewhere it was never at.
#[uniffi::export]
pub fn default_split_ratio() -> f64 {
    model::DEFAULT_SPLIT_RATIO
}

/// The decision you get by accepting a consent dialog exactly as it opened.
///
/// A free function for the same reason as above: a uniffi record carries no
/// methods, and "what is ticked when the sheet appears" is one rule that must
/// exist once.
#[uniffi::export]
pub fn default_consent_decision(request: ConsentRequest, decided_at_ms: u64) -> ConsentDecision {
    request.default_decision(decided_at_ms)
}

/// One toggle flipped, returning the decision that results.
///
/// The shell never edits the lists directly. Granting is where the rule about
/// unreadable patterns lives, and a rule the caller can walk around is not a
/// rule.
#[uniffi::export]
pub fn consent_decision_setting(
    decision: ConsentDecision,
    kind: PermissionKind,
    key: String,
    granted: bool,
) -> ConsentDecision {
    let mut decision = decision;
    if granted {
        decision.allow(kind, &key);
    } else {
        decision.refuse(kind, &key);
    }
    decision
}

/// Whether a decision allowed nothing at all.
///
/// The extension is installed and does not run, and the interface has to say
/// so. In the core because "what counts as nothing" is behaviour: if site
/// access alone ever stopped being enough to run on, both platforms would have
/// to change their minds together.
#[uniffi::export]
pub fn consent_decision_grants_nothing(decision: ConsentDecision) -> bool {
    decision.grants_nothing()
}

/// How long a permission prompt has to have been on screen before an answer to
/// it counts.
///
/// Exported rather than written as `0.5` in the shell, for the reason
/// `default_split_ratio` is exported: this is the defence against a keystroke
/// that was already in flight when a page chose to interrupt, the core enforces
/// it by ignoring anything earlier, and a shell that picked its own number
/// would either enable a button that does nothing or disable one for longer
/// than the rule.
#[uniffi::export]
pub fn prompt_settle_ms() -> u64 {
    crate::site_permissions::PROMPT_SETTLE_MS
}

/// How much of a page's own text a panel will show.
///
/// Exported for the same reason as the settle window: a panel that says "more
/// than 2,000 characters" while the core cuts at some other number is a
/// sentence that goes wrong silently, and nothing goes red when it does.
#[uniffi::export]
pub fn dialog_message_limit() -> u64 {
    crate::page_dialogs::MESSAGE_LIMIT as u64
}

/// Whether a decision currently allows this permission.
#[uniffi::export]
pub fn consent_decision_grants(
    decision: ConsentDecision,
    kind: PermissionKind,
    key: String,
) -> bool {
    decision.grants(kind, &key)
}

/// What a thread would be called in a list of threads about one page.
///
/// A free function for the reason `download_fraction` is one: a uniffi record
/// carries no methods across, and this has to exist exactly once. A shell that
/// picked its own line out of a transcript would label the same thread
/// differently on each platform.
#[uniffi::export]
pub fn conversation_opening_question(conversation: Conversation) -> String {
    conversation.opening_question().to_string()
}

/// When anything last happened in a thread.
///
/// Exported rather than derived in the shell because it is the number the core
/// orders threads by. A list showing one answer beside an order computed from
/// another is two opinions about which conversation is the most recent, and
/// the one on screen is the one that gets believed.
#[uniffi::export]
pub fn conversation_last_activity_ms(conversation: Conversation) -> u64 {
    conversation.last_activity_ms()
}

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum Zer0Error {
    #[error("could not save the session: {message}")]
    Save { message: String },
    #[error("could not install the extension: {message}")]
    Extension { message: String },
}

pub(crate) struct State {
    // `pub(crate)` alongside `lock()` for the same reason: a second FFI surface
    // in another file needs the same session, not a second one.
    pub(crate) session: Session,
    /// What the host declared it can do, set once at the door and consulted
    /// before anything that needs a capability the host may not have. The
    /// shape rather than a checklist of `if`s scattered at call sites: one
    /// place holds the declaration, and a capability without a consumer here
    /// is a field nobody reads (ADR-0118).
    capabilities: HostCapabilities,
    /// Behind the trait rather than named as a concrete store: which backend
    /// holds the session is a decision taken once, in `open`, and nothing
    /// downstream of it gets to depend on the answer. `None` is a browser that
    /// writes nothing — either it was asked for that, or the stored session
    /// could not be read and ADR-0017 says do not write over it.
    store: Option<Box<dyn SessionStore + Send>>,
    /// A file of its own beside the session (ADR-0044). `None` means icons
    /// live for this run only, which costs a re-fetch and nothing else.
    icons: Option<IconStore>,
    /// Where unpacked extensions live. Beside the session file, so a profile
    /// directory holds everything about one browser.
    extensions_dir: PathBuf,
    /// The language the person reads, as the shell reports it.
    ///
    /// Set once rather than passed on every call. Which language a package's
    /// own strings should be read in is one fact about this browser, and a
    /// parameter on every call is a fact each caller gets a fresh chance to get
    /// wrong. `None` means read a package in whatever language it declares as
    /// its own, which is what every test wants and what a system with nothing
    /// to say gets.
    ui_locale: Option<String>,
    /// The platform's application-support root, as the shell reports it.
    ///
    /// Set once rather than passed on every call, for the same reason
    /// `ui_locale` is: where a platform keeps application data is one fact
    /// about this machine, and a parameter on every call is a fact each caller
    /// gets a fresh chance to get wrong. `None` is a browser that will not
    /// start any program at all, which is what an in-memory session and every
    /// test that has not said otherwise should be.
    application_support: Option<PathBuf>,
    /// Set when the stored session could not be read. Saving stays off while
    /// it is set, so a bad read cannot become a bad write.
    load_error: Option<String>,
}

/// Where an in-memory browser unpacks extensions.
///
/// An in-memory session has no profile directory, so this is scratch by
/// definition — but it has to be scratch *of its own*. It used to be the fixed
/// `<temp>/zer0-extensions`, which meant every in-memory `Zer0` in every
/// process shared one directory: installing in one was visible from all the
/// others, and the whole Swift suite builds one of these per test and runs
/// them in parallel. Nothing named the collision when it happened; a test
/// simply saw an extension it never installed, and the failure landed on
/// whichever one ran second.
///
/// Nothing is created here. `install_extension` makes the directory when there
/// is something to put in it, so a session that never installs anything leaves
/// nothing behind at all.
fn scratch_extensions_dir() -> PathBuf {
    static NEXT: AtomicU64 = AtomicU64::new(0);

    std::env::temp_dir().join(format!(
        "zer0-extensions-{}-{}",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    ))
}

/// The one place a capability retires a command from the keymap.
///
/// Called at every mint — both constructors (after any stored session was
/// loaded, so a custom binding saved on another host cannot survive the
/// trip) and `reset_keymap`, which mints the defaults again — and after
/// every bind and rebind, the doors that can hand a retired command a
/// chord at runtime — because a retirement any of them could resurrect
/// would be the gate reopening behind Handle held by the shell for the
/// lifetime of the app.
#[derive(uniffi::Object)]
pub struct Zer0 {
    // The shell calls in from the main thread today, but WKWebView delegates
    // can fire from elsewhere. A mutex costs nothing at this call volume and
    // removes the question entirely.
    state: Mutex<State>,
}

impl Zer0 {
    // `pub(crate)` so the MCP surface can live in `mcp_ffi.rs` rather than
    // growing this file. Same object, same lock, one more impl block.
    pub(crate) fn lock(&self) -> MutexGuard<'_, State> {
        self.state.lock().expect("state lock poisoned")
    }
}

impl State {
    /// Put whatever the reducer changed about icons onto disk, now.
    ///
    /// Not folded into `save()`, which rewrites the whole session every twenty
    /// seconds: a blob cache written on that schedule would rewrite every icon
    /// the browser has ever seen to record one arriving. A row here is written
    /// once, when it arrives, in its own file.
    ///
    /// Best effort throughout. A cache that cannot be written is a cache that
    /// re-fetches next launch, and that must never be a reason the browser
    /// stops working.
    fn flush_icons(&mut self) {
        let dropped = self.session.icons.take_dropped();
        let dirty = self.session.icons.take_dirty();
        let Some(store) = &mut self.icons else {
            return;
        };

        for data_store_id in dropped {
            let _ = store.forget_data_store(&data_store_id);
        }
        for icon in dirty {
            let _ = store.put(&icon);
        }
    }
}

#[uniffi::export]
impl Zer0 {
    /// Start without touching the disk. Everything is lost on quit.
    ///
    /// `capabilities` is the host's declaration, not a preference: whatever it
    /// leaves out is refused fail-closed by the calls that need it, so a host
    /// that says nothing gets a browser that answers "cannot" — with the
    /// reason — rather than one that half-works.
    #[uniffi::constructor]
    pub fn in_memory(
        first_space_name: String,
        data_store_id: String,
        capabilities: HostCapabilities,
    ) -> Arc<Self> {
        let mut session = Session::new(first_space_name, data_store_id);
        session.retire_what_the_host_cannot_run(capabilities);
        Arc::new(Self {
            state: Mutex::new(State {
                session,
                capabilities,
                store: None,
                icons: None,
                extensions_dir: scratch_extensions_dir(),
                ui_locale: None,
                application_support: None,
                load_error: None,
            }),
        })
    }

    /// Open the session at `db_path`, or start a fresh one there.
    ///
    /// A database that cannot be opened is not fatal: the browser starts empty
    /// rather than refusing to launch.
    ///
    /// A database that opens but fails to *read* is a different thing, and is
    /// treated as one. Starting empty and then saving over it would destroy
    /// the session on the first autosave, twenty seconds later, with no backup
    /// and no warning. So the store is detached instead: the browser runs, and
    /// refuses to write anything on top of a file it could not understand.
    #[uniffi::constructor]
    pub fn open(
        db_path: String,
        first_space_name: String,
        data_store_id: String,
        capabilities: HostCapabilities,
    ) -> Arc<Self> {
        // The one place in the browser that names a backend. Everything after
        // this line talks to whatever it opened through `SessionStore`.
        let store = Store::open(&db_path).ok();

        let (session, store, load_error) = match store {
            None => (
                None,
                None,
                Some("could not open the session file".to_string()),
            ),
            Some(store) => match store.load() {
                Ok(session) => (
                    session,
                    Some(Box::new(store) as Box<dyn SessionStore + Send>),
                    None,
                ),
                Err(error) => (None, None, Some(error.to_string())),
            },
        };

        let profile_dir = PathBuf::from(&db_path)
            .parent()
            .map(Path::to_path_buf)
            .unwrap_or_else(|| PathBuf::from("."));

        let mut session = session.unwrap_or_else(|| Session::new(first_space_name, data_store_id));

        // State reaches this browser two ways — an action, or this file — and
        // both are named by the same function. A chat tab's title is derived
        // from the thread it addresses, so the copy in the session file is a
        // snapshot of what that thread said last time: right in the ordinary
        // case, and wrong for a tab whose conversation did not survive the load
        // (ADR-0060 drops a thread whose address this build cannot read). The
        // pass costs one walk over the tabs at launch.
        reducer::name_our_pages(&mut session);
        // After the load, not before it: a keymap saved on a host that can
        // print may carry a print binding, and it must not arrive answered
        // on one that cannot.
        session.retire_what_the_host_cannot_run(capabilities);

        // Deliberately not gated on `load_error`. This is a different file
        // holding a cache, so an unreadable session cannot corrupt it and a
        // write here cannot be the write ADR-0006 refuses. Someone whose
        // session file went bad has enough going wrong without every row
        // losing its picture too.
        //
        // And if *this* file will not open, the answer is letters: an icon
        // cache is the one thing in the profile whose failure mode is already
        // the design.
        let icons = IconStore::open(profile_dir.join("icons.sqlite")).ok();
        if let Some(icons) = &icons
            && let Ok(stored) = icons.all()
        {
            session.icons = crate::icons::Icons::load(stored);
        }

        Arc::new(Self {
            state: Mutex::new(State {
                session,
                capabilities,
                store,
                icons,
                extensions_dir: ext::default_extension_directory(&profile_dir),
                ui_locale: None,
                application_support: None,
                load_error,
            }),
        })
    }

    /// Why the previous session could not be read, if it could not.
    ///
    /// When this is set, saving is off: the shell should say so rather than let
    /// someone browse for an hour and discover the loss at the next launch.
    pub fn load_error(&self) -> Option<String> {
        self.lock().load_error.clone()
    }

    /// Whether this browser is backed by a file on disk.
    pub fn is_persistent(&self) -> bool {
        self.lock().store.is_some()
    }

    /// Apply an action. The returned commands must be carried out in order.
    pub fn dispatch(&self, action: Action) -> Vec<EngineCommand> {
        let mut state = self.lock();
        let commands = reducer::dispatch(&mut state.session, action);
        state.flush_icons();
        commands
    }

    /// Commands that rebuild web views for a session restored from disk. Call
    /// once at launch, before anything else.
    pub fn rehydrate(&self) -> Vec<EngineCommand> {
        reducer::rehydrate(&self.lock().session)
    }

    pub fn save(&self) -> Result<(), Zer0Error> {
        let mut state = self.lock();
        let State { session, store, .. } = &mut *state;
        match store {
            // The one place a `Session` becomes something a store may keep.
            // Everything downstream of this line holds the projection, not the
            // session, so no backend is in a position to write what the
            // projection took out.
            Some(store) => {
                store
                    .save(&StorableSession::project(session))
                    .map_err(|e| Zer0Error::Save {
                        message: e.to_string(),
                    })
            }
            None => Ok(()),
        }
    }

    /// Record that this run ended properly. Call it last, on the way out.
    pub fn mark_clean_shutdown(&self) {
        if let Some(store) = &self.lock().store {
            let _ = store.mark_clean_shutdown();
        }
    }

    /// Whether the previous run ended properly.
    ///
    /// Reading it also clears it, so this run counts as unclean until it quits
    /// properly. Called once at launch.
    pub fn take_clean_shutdown(&self) -> bool {
        match &self.lock().store {
            // With no store there is nothing to lose, so nothing was lost.
            None => true,
            Some(store) => store.take_clean_shutdown().unwrap_or(false),
        }
    }

    pub fn snapshot(&self) -> BrowserSnapshot {
        let state = self.lock();
        BrowserSnapshot {
            spaces: state.session.browser.spaces().to_vec(),
            tabs: state
                .session
                .browser
                .all_tabs()
                .into_iter()
                .cloned()
                .collect(),
            windows: state.session.browser.windows().to_vec(),
            key_window: state.session.browser.key_window(),
            active_space: state.session.browser.active_space(),
            active_tab: state.session.browser.active_tab(),
            routes: state.session.routes.routes().to_vec(),
            downloads: state.session.downloads.all().to_vec(),
            icon_revision: state.session.icons.revision(),
            site_permission_prompt: state.session.site_permissions.pending().cloned(),
            page_dialogs: state.session.page_dialogs.on_screen(&state.session.browser),
            http_auth_prompt: state.session.http_auth.pending().cloned(),
            // The active tab's, because that is the screen being drawn. A
            // report for a tab nobody is looking at explains a page nobody can
            // see.
            certificate_report: state
                .session
                .browser
                .active_tab()
                .and_then(|tab| state.session.certificate_reports.get(&tab))
                .cloned(),
        }
    }

    /// This site's icon in this space, or `None` for one we have nothing for.
    ///
    /// Per space, because the cache is: ADR-0007 gives every space its own
    /// cookie jar, and an icon served across that line would mean a site
    /// visited at work needs no request at home — an absence the site can see.
    ///
    /// `None` covers three different situations on purpose, because the row
    /// draws the same thing for all three: never asked, asked and refused,
    /// asked and given something that was not an image. The badge's letter is
    /// the answer to every one of them.
    pub fn icon(&self, space: SpaceId, host: String) -> Option<Vec<u8>> {
        let state = self.lock();
        let data_store_id = &state.session.browser.space(space)?.data_store_id;
        state
            .session
            .icons
            .bytes(&IconKey::new(data_store_id, host.to_ascii_lowercase()))
            .map(<[u8]>::to_vec)
    }

    // MARK: - Conversations

    /// Every thread this browser is holding, oldest first.
    ///
    /// Not in [`BrowserSnapshot`], and that is the decision rather than an
    /// omission: the snapshot is re-read after every dispatch, and copying
    /// every word of every conversation across the FFI to redraw a sidebar
    /// row would be absurd. The panel asks for the one it is drawing.
    pub fn conversations(&self) -> Vec<Conversation> {
        self.lock().session.chat.all().to_vec()
    }

    /// One thread, as it stands right now.
    pub fn conversation(&self, id: ConversationId) -> Option<Conversation> {
        self.lock().session.chat.get(id).cloned()
    }

    /// The thread a space holds for questions about no page in particular.
    pub fn conversation_for_space(&self, space: SpaceId) -> Option<Conversation> {
        self.lock()
            .session
            .chat
            .latest_for_scope(&ConversationScope::Space { space })
            .cloned()
    }

    /// Every thread about the same page as this one, most recent first, this
    /// one among them.
    ///
    /// What the screen listing a page's conversations is drawn from. The order
    /// is the core's, because which thread is the most recent is the same
    /// question ⌘E answers and two surfaces must not answer it differently.
    /// A thread about no page in particular has exactly one sibling: itself.
    pub fn conversations_about(&self, conversation: ConversationId) -> Vec<Conversation> {
        self.lock()
            .session
            .chat
            .siblings_of(conversation)
            .into_iter()
            .cloned()
            .collect()
    }

    /// Whether a tab is currently showing the page this thread is about.
    ///
    /// `false` for a thread about no page at all, and for one whose page is
    /// simply not open — which is the state a week-old conversation comes back
    /// in, and the one thing the screen has to say out loud rather than let
    /// somebody discover by asking a question nothing is read for.
    ///
    /// Answered here because it is the same normalisation ⌘E anchors with, and
    /// a shell comparing URLs for itself would be a second opinion about what
    /// "the same page" means.
    pub fn conversation_page_is_open(&self, conversation: ConversationId) -> bool {
        let guard = self.lock();
        let Some(scope) = guard
            .session
            .chat
            .get(conversation)
            .map(|c| c.scope.clone())
        else {
            return false;
        };
        let ConversationScope::Page { space, page } = scope else {
            return false;
        };
        guard
            .session
            .browser
            .tabs_in(space)
            .iter()
            .any(|t| t.url.as_deref().is_some_and(|url| page.matches(url)))
    }

    /// What the page a thread is about calls itself, if anything can say.
    ///
    /// A person recognises a page by its title, its icon and its site — not by
    /// a percent-encoded path. The address is always available to a shell; this
    /// is the part that is not, because a title belongs to a *page* and the core
    /// only ever hears one from a tab or from a capture.
    ///
    /// Two sources, in this order, and nothing after them:
    ///
    /// - **a tab showing the page**, which is the title as it stands right now;
    /// - **the last capture of that exact page**, which is what it called itself
    ///   when it was read — the answer for a thread whose page is closed.
    ///
    /// `None` when neither has ever said, and it is never derived from the
    /// address. A title is the page's own claim about itself and a hostname is
    /// not one (ADR-0018): a shell with nothing here has the site to fall back
    /// on and should say that instead of dressing a URL up as a name.
    ///
    /// The capture is only believed when it is a capture of *this* page. A
    /// thread whose anchored tab was navigated carries a page reference for
    /// somewhere else (ADR-0076), and answering with that would name the wrong
    /// page confidently.
    pub fn conversation_page_title(&self, conversation: ConversationId) -> Option<String> {
        let guard = self.lock();
        let thread = guard.session.chat.get(conversation)?;
        let ConversationScope::Page { space, page } = &thread.scope else {
            return None;
        };

        let open = guard
            .session
            .browser
            .tabs_in(*space)
            .iter()
            .find(|t| t.url.as_deref().is_some_and(|url| page.matches(url)))
            .and_then(|t| t.title.clone());

        open.or_else(|| {
            thread
                .last_page()
                .filter(|read| page.matches(&read.url))
                .map(|read| read.title.clone())
        })
        .filter(|title| !title.trim().is_empty())
    }

    /// Every remembered answer about a tool, for the screen that reviews them.
    ///
    /// A grant nobody can find is a grant nobody can take back, which is the
    /// failure ADR-0028 spends a screen on for extensions.
    pub fn tool_grants(&self) -> Vec<ToolGrant> {
        self.lock().session.chat.consent().all().to_vec()
    }

    /// What the configured servers last said they could do.
    ///
    /// Everything the register holds, including tools somebody refused: a
    /// refusal you cannot see is a refusal you cannot take back, and this is
    /// what the screen that takes them back is drawn from. What a *model* is
    /// offered is a shorter list and comes from somewhere else — see
    /// `McpRegistry::offerable`.
    pub fn known_tools(&self) -> Vec<ToolDescriptor> {
        self.lock()
            .session
            .mcp
            .tools()
            .into_iter()
            .map(crate::mcp::McpTool::descriptor)
            .collect()
    }

    /// How many downloads are still running.
    ///
    /// Quitting stops every one of them, so the shell asks before it does.
    pub fn in_flight_download_count(&self) -> u32 {
        self.lock().session.downloads.in_flight_count() as u32
    }

    /// Ranked command-bar results for what the user has typed so far.
    pub fn suggest(&self, query: String, limit: u32) -> Vec<Suggestion> {
        let state = self.lock();
        command_bar::suggest(
            &state.session.browser,
            &state.session.bookmarks,
            &state.session.history,
            &query,
            limit as usize,
        )
    }

    // MARK: - Kept pages

    /// Everything kept, newest first.
    ///
    /// Not in [`BrowserSnapshot`], for the reason conversations are not: the
    /// snapshot is re-read after every dispatch, and copying a list that only
    /// changes when somebody presses ⌘D across the FFI four times a second to
    /// redraw a tab row would be absurd. The shelf asks when it is open.
    pub fn bookmarks(&self) -> Vec<Bookmark> {
        self.lock().session.bookmarks.all().to_vec()
    }

    /// What is kept for this exact address, if anything.
    ///
    /// The question ⌘D's confirmation asks to know whether it is saying "kept"
    /// or "already kept", and the question a page action asks to know which
    /// verb to draw. `None` is a page nobody has kept.
    pub fn bookmark_for(&self, url: String) -> Option<Bookmark> {
        self.lock().session.bookmarks.for_url(&url).cloned()
    }

    /// What is kept for the page a tab is showing.
    ///
    /// Separate from [`Zer0::bookmark_for`] because "the address of the page in
    /// this tab" is a question with an answer the shell should not be
    /// assembling itself — a tab mid-navigation has a `pending_url` that is not
    /// what would be kept.
    pub fn bookmark_for_tab(&self, tab: TabId) -> Option<Bookmark> {
        let state = self.lock();
        let url = state.session.browser.tab(tab)?.url.as_ref()?;
        state.session.bookmarks.for_url(url).cloned()
    }

    /// Every label in use, alphabetically. For anything offering completions.
    pub fn bookmark_tags(&self) -> Vec<String> {
        self.lock().session.bookmarks.tags()
    }

    /// What picking a command-bar row means, given what the bar was opened to
    /// do. Dispatch the result; the shell does not get to decide this.
    ///
    /// ⌘L navigates the tab you are on, ⌘T opens another one, and an already
    /// open tab is switched to either way.
    pub fn command_bar_action(&self, intent: CommandBarIntent, suggestion: Suggestion) -> Action {
        let state = self.lock();
        command_bar::accept(&state.session.browser, intent, &suggestion)
    }

    /// What the URL bar should show for a tab: the in-flight URL while loading,
    /// then the address that failed, then the committed one.
    ///
    /// The failed address matters more than it looks. A mistyped host leaves a
    /// tab with nothing committed, so without it ⌘L on an error screen would
    /// open an empty bar and the typo would have to be retyped from scratch.
    pub fn address_bar_text(&self, tab: TabId) -> String {
        self.lock()
            .session
            .browser
            .tab(tab)
            .and_then(|t| {
                t.pending_url
                    .clone()
                    .or_else(|| t.last_error.as_ref().and_then(|e| e.url.clone()))
                    .or_else(|| t.url.clone())
            })
            .unwrap_or_default()
    }

    /// Why the last navigation on a tab failed, if it did and the failure is
    /// still current. `None` means there is a page to show, or soon will be.
    ///
    /// The snapshot already carries this per tab; this is for the shell asking
    /// about one tab without walking the list.
    pub fn navigation_error(&self, tab: TabId) -> Option<NavigationError> {
        self.lock()
            .session
            .browser
            .tab(tab)
            .and_then(|t| t.last_error.clone())
    }

    /// Sidebar label for a tab: title, else URL, else a placeholder.
    pub fn display_title(&self, tab: TabId) -> String {
        self.lock()
            .session
            .browser
            .tab(tab)
            .map(|t| t.display_title().to_string())
            .unwrap_or_else(|| "New Tab".to_string())
    }

    /// Which space a URL would be routed to, if any. Lets the UI show where a
    /// link is about to land before it is followed.
    pub fn route_for(&self, url: String) -> Option<SpaceId> {
        self.lock().session.routes.route(&url)
    }

    pub fn set_search_template(&self, template: String) {
        self.lock().session.browser.set_search_template(template);
    }

    /// How long an untouched `Today` tab survives before it is archived.
    pub fn set_archive_after_ms(&self, ms: u64) {
        self.lock().session.browser.set_archive_after_ms(ms);
    }

    pub fn recent_history(&self, limit: u32) -> Vec<HistoryEntry> {
        self.lock()
            .session
            .history
            .recent(limit as usize)
            .into_iter()
            .cloned()
            .collect()
    }

    /// History ranked for what somebody typed, best first.
    ///
    /// The history page's search, and it is `command_bar`'s ranking rather than
    /// one of its own: the page and the bar are asking the same question, and
    /// two answers to it would disagree the first time either grew a tie-break.
    /// An empty query is the whole list, newest first.
    pub fn search_history(&self, query: String, limit: u32) -> Vec<HistoryEntry> {
        let state = self.lock();
        command_bar::search_history(&state.session.history, &query, limit as usize)
            .into_iter()
            .cloned()
            .collect()
    }

    /// Forget one page, for when you want that one gone and not the rest.
    pub fn forget_history(&self, url: String) {
        self.lock().session.history.forget(&url);
    }

    /// Forget a span of history.
    ///
    /// The only way history is cleared, [`HistoryRange::Everything`] included,
    /// so "the last hour" and "everything" are one path with a number on it. A
    /// second entry point would be a second confirmation dialog to keep in step
    /// with the first, and the one that drifts is never the one being read.
    ///
    /// `now_ms` comes from the shell, the way `mcp_handshake_expired` takes it:
    /// the core has no clock, and one that only exists in tests is a clock that
    /// lies in production.
    pub fn clear_history(&self, range: HistoryRange, now_ms: u64) {
        self.lock()
            .session
            .history
            .forget_since(range.cutoff_ms(now_ms));
    }

    // MARK: - Preferences

    pub fn preferences(&self) -> Preferences {
        self.lock().session.preferences.clone()
    }

    pub fn set_preferences(&self, preferences: Preferences) {
        self.lock().session.preferences = preferences;
    }

    /// Turn content blocking off for one site without turning it off globally.
    pub fn set_blocking(&self, host: String, blocking: bool) {
        self.lock()
            .session
            .preferences
            .allow_blocking(&host, blocking);
    }

    /// Whether this URL would have its content blocked.
    pub fn blocks(&self, url: String) -> bool {
        self.lock().session.preferences.blocks(&url)
    }

    /// The host an exception would be recorded against, or `None` when this
    /// page has no host that can carry one.
    ///
    /// Asked rather than derived in the shell, so "the site you are on" means
    /// the same thing to the menu item, to [`Self::blocks`] and to the rule
    /// list. A shell that took `URL(string:)?.host` would agree with the core
    /// most of the time, which is the worst of the three outcomes.
    pub fn blocking_host_for(&self, url: String) -> Option<String> {
        let host = url::Url::parse(&url).ok()?.host_str()?.to_string();
        blocking::usable_exception(&host)
    }

    /// The rule list for the engine host to compile, as WebKit
    /// content-blocker JSON. `None` when blocking is off — an empty list is not
    /// a thing WebKit will compile.
    pub fn content_rule_list_json(&self) -> Option<String> {
        blocking::rule_list_json(&self.lock().session.preferences)
    }

    /// What that list is cached under. Moves when, and only when, the JSON
    /// does, so a launch that changed nothing never pays to compile.
    pub fn content_rule_list_identifier(&self) -> Option<String> {
        blocking::rule_list_identifier(&self.lock().session.preferences)
    }

    /// What the interface is allowed to say about blocking. Deliberately
    /// carries no per-page count: WebKit has no public API that reports one,
    /// so there is none to report (ADR-0018, ADR-0058).
    pub fn blocking_summary(&self) -> BlockingSummary {
        blocking::summary(&self.lock().session.preferences)
    }

    /// How many hosts the shipped list covers.
    ///
    /// Exported so the settings pane can print the number rather than round it
    /// into "thousands of trackers". The difference between saying seventy and
    /// implying a hundred thousand is the whole of ADR-0018 on this screen.
    pub fn blocked_host_count(&self) -> u32 {
        blocking::shipped_host_count()
    }

    pub fn search_engines(&self) -> Vec<SearchEngine> {
        preferences::search_engines()
    }

    /// The current engine's name, if it is one we ship.
    pub fn current_search_engine(&self) -> Option<String> {
        let template = self.lock().session.browser.search_template().to_string();
        preferences::search_engine_name(&template)
    }

    pub fn search_template(&self) -> String {
        self.lock().session.browser.search_template().to_string()
    }

    pub fn archive_after_ms(&self) -> u64 {
        self.lock().session.browser.archive_after_ms()
    }

    // MARK: - Keyboard shortcuts

    /// Every binding, for building menus and for matching key presses.
    ///
    /// The shell renders these; it does not decide them. That is what keeps
    /// ⌘T meaning the same thing on macOS and Ctrl+T on Linux. A command
    /// this host declared it cannot run is not in the list at all — retired
    /// where the keymap is minted, so a menu built from this never wears a
    /// chord whose press does nothing (ADR-0118).
    pub fn keymap(&self) -> Vec<Binding> {
        self.lock().session.keymap.bindings().to_vec()
    }

    pub fn command_for_chord(&self, chord: Chord) -> Option<UiCommand> {
        self.lock().session.keymap.command_for(&chord)
    }

    /// What to print next to a menu item.
    pub fn chord_for_command(&self, command: UiCommand) -> Option<Chord> {
        self.lock().session.keymap.chord_for(&command)
    }

    /// Add a chord for a command, leaving any it already had.
    pub fn bind_shortcut(&self, chord: Chord, command: UiCommand) {
        let mut state = self.lock();
        state.session.keymap.bind(chord, command);
        // A bind can hand a chord to a command the mint retired; without
        // this, this door resurrects it — answered, advertised and, once
        // the chord differs from the default, saved (ADR-0118).
        let capabilities = state.capabilities;
        state.session.retire_what_the_host_cannot_run(capabilities);
    }

    /// Make this the command's only chord.
    pub fn rebind_shortcut(&self, command: UiCommand, chord: Chord) {
        let mut state = self.lock();
        state.session.keymap.rebind(command, chord);
        // Same rule as `bind_shortcut` above: a command this host cannot
        // run cannot come back by being given a different chord.
        let capabilities = state.capabilities;
        state.session.retire_what_the_host_cannot_run(capabilities);
    }

    pub fn unbind_shortcut(&self, chord: Chord) -> bool {
        self.lock().session.keymap.unbind(&chord)
    }

    pub fn reset_keymap(&self) {
        let mut state = self.lock();
        state.session.keymap.reset();
        // The defaults this just minted include every command; what this
        // host declared it cannot run goes back out again (ADR-0118).
        let capabilities = state.capabilities;
        state.session.retire_what_the_host_cannot_run(capabilities);
    }

    // MARK: - Extensions

    /// Where to fetch a package for `id`.
    ///
    /// The shell downloads it, because URLSession already honours the system's
    /// proxy and certificate settings.
    pub fn extension_download_url(&self, id: String) -> String {
        ext::download_url(&id)
    }

    /// The Chrome version [`Self::extension_download_url`] asks the store with.
    ///
    /// Exposed only so that the refusal a person reads when the store answers
    /// with nothing can *name* the number that has to move, rather than
    /// describing it. Nothing chooses it; there is one spelling of it and it is
    /// in the core (ADR-0078).
    pub fn extension_download_chrome_version(&self) -> String {
        ext::CHROME_VERSION_FOR_DOWNLOADS.to_string()
    }

    /// Tell the core which language the person reads.
    ///
    /// The one place this crosses. Only `_locales` resolution uses it: a
    /// manifest may write `"name": "__MSG_extName__"` and keep the real string
    /// in the package, and which bundle that is read from is the only thing
    /// this changes. Nothing else in the core is translated.
    ///
    /// Getting the locale is the platform's job; deciding what to do with it is
    /// not, which is why it arrives as a value and the fallback chain lives in
    /// `ext::i18n`.
    pub fn set_ui_locale(&self, locale: Option<String>) {
        self.lock().ui_locale = locale;
    }

    /// Tell the core where this platform keeps application data.
    ///
    /// The one thing about native messaging that is genuinely the host's to
    /// answer (ADR-0105). Which directories under it are read, in what order,
    /// and what is done with what is in them, is the core's — so this is a
    /// root and never a list of directories.
    ///
    /// Until it is set, [`Zer0::native_host`] refuses everything, which is the
    /// state every test and every in-memory session starts in.
    pub fn set_application_support_directory(&self, path: Option<String>) {
        self.lock().application_support = path.map(PathBuf::from);
    }

    /// Unpack a downloaded package and make it ready to load.
    ///
    /// Refused before anything touches the disk when this host declared no
    /// extension runtime. An install that unpacks and never runs is
    /// success-shaped silence — the row appears, the button does nothing — so
    /// the gate comes first and the sentence is the core's one vocabulary for
    /// *cannot*: the build, then the reason (ADR-0103, ADR-0118).
    pub fn install_extension(&self, package: Vec<u8>) -> Result<InstalledExtension, Zer0Error> {
        let (capabilities, dir, locale) = {
            let state = self.lock();
            (
                state.capabilities,
                state.extensions_dir.clone(),
                state.ui_locale.clone(),
            )
        };
        if !capabilities.extension_runtime {
            return Err(Zer0Error::Extension {
                message:
                    "this build of zer0 cannot run extensions — the host declared no extension runtime"
                        .into(),
            });
        }
        std::fs::create_dir_all(&dir).map_err(|e| Zer0Error::Extension {
            message: e.to_string(),
        })?;
        ext::install_extension(&package, &dir, locale.as_deref()).map_err(|e| {
            Zer0Error::Extension {
                message: e.to_string(),
            }
        })
    }

    /// The extension a Chrome Web Store page is showing, so the browser can
    /// offer to install what you are already looking at.
    pub fn extension_id_for_url(&self, url: String) -> Option<String> {
        ext::extension_id_from_store_url(&url)
    }

    /// The hosts the store is served from.
    ///
    /// The shell asks so that the script it injects into the store's pages is
    /// gated by the same rule `extension_id_for_url` applies, rather than by a
    /// second list somebody wrote from memory.
    pub fn extension_store_hosts(&self) -> StoreHosts {
        ext::store_hosts()
    }

    pub fn installed_extensions(&self) -> Vec<InstalledExtension> {
        let (dir, locale) = {
            let state = self.lock();
            (state.extensions_dir.clone(), state.ui_locale.clone())
        };
        ext::installed_extensions(&dir, locale.as_deref())
    }

    /// What this browser holds for one extension id.
    ///
    /// The question every surface that draws an extension asks — the row in
    /// Settings, the button injected into the store's page, the install banner
    /// — answered once, here. A button in somebody else's page must never work
    /// this out from the page (ADR-0062), and three surfaces working it out
    /// from the ledger separately is three chances to disagree about what
    /// "running" means.
    pub fn extension_standing(&self, id: String) -> ExtensionStanding {
        let Some(installed) = self.installed_extensions().into_iter().find(|e| e.id == id) else {
            return extension_permissions::standing(false, None, &[]);
        };
        let asked = extension_permissions::consent_request(
            &installed.id,
            &installed.manifest.name,
            &installed.manifest.permissions,
            &installed.manifest.host_permissions,
        )
        .requests;

        let state = self.lock();
        extension_permissions::standing(true, state.session.extension_consent.decision(&id), &asked)
    }

    pub fn uninstall_extension(&self, id: String) -> Result<(), Zer0Error> {
        let dir = self.lock().extensions_dir.clone();
        ext::uninstall_extension(&id, &dir).map_err(|e| Zer0Error::Extension {
            message: e.to_string(),
        })?;
        // A reinstall is different code and must not inherit an answer given
        // about the old code. Every ledger, for the same reason — and this one
        // most of all: it says a program outside the browser may be started.
        let mut state = self.lock();
        state.session.extension_consent.forget(&id);
        state.session.extension_pins.forget(&id);
        state.session.native_hosts.forget(&id);
        Ok(())
    }

    // MARK: - Which extension buttons are on show

    /// The extensions with a button on the row, in the order they are drawn.
    ///
    /// **One door, and this is it.** Four rules converge here, every one of them
    /// behaviour rather than appearance, so none may be applied by whoever
    /// happens to be drawing:
    ///
    /// - the order, which is what ⇧⌘1..⇧⌘9 index into;
    /// - that an extension with no `action` in its manifest is never on the row,
    ///   because a button that cannot be pressed is worse than no button;
    /// - that an extension which is not running is not on it either. Something
    ///   granted nothing is installed and deliberately not loaded (ADR-0028), so
    ///   its button would be a picture that swallows clicks;
    /// - that a pin naming something no longer on disk produces nothing rather
    ///   than a gap. The uninstall path forgets the pin, so this only matters
    ///   when a directory went away behind the browser's back — which is a
    ///   boundary, and boundaries are hostile (ADR-0024).
    ///
    /// **The list the row draws and the list the chords count through have to be
    /// the same list**, or ⇧⌘2 presses whichever button is second in the core's
    /// opinion while the person is looking at a different second button. That is
    /// the whole reason every one of these filters is here rather than in the
    /// view: a shell that drew "the pinned ones that are actually running" over
    /// a core that counted "the pinned ones" would be off by one for everybody
    /// with a switched-off extension, and nothing would look wrong.
    pub fn pinned_extensions(&self) -> Vec<InstalledExtension> {
        let installed = self.installed_extensions();
        let state = self.lock();
        state
            .session
            .extension_pins
            .pinned_ids()
            .into_iter()
            .filter_map(|id| installed.iter().find(|e| e.id == id).cloned())
            .filter(|e| e.manifest.has_action)
            .filter(|e| {
                // `standing` rather than a second reading of the ledger: what
                // "running" means is one answer in one place, and a row of
                // buttons that disagreed with the row in Settings about it
                // would be the drift that type exists to stop.
                let asked = extension_permissions::consent_request(
                    e.id.clone(),
                    e.manifest.name.clone(),
                    &e.manifest.permissions,
                    &e.manifest.host_permissions,
                )
                .requests;
                matches!(
                    extension_permissions::standing(
                        true,
                        state.session.extension_consent.decision(&e.id),
                        &asked,
                    ),
                    ExtensionStanding::Running { .. }
                )
            })
            .collect()
    }

    /// Whether this extension is on the row, for the control that says so.
    pub fn extension_is_pinned(&self, id: String) -> bool {
        self.lock().session.extension_pins.is_pinned(&id)
    }

    /// Somebody chose to show or hide a button.
    pub fn set_extension_pinned(&self, id: String, pinned: bool) {
        self.lock().session.extension_pins.decide(&id, pinned);
    }

    /// Put a newly running extension on the row, unless somebody already had an
    /// opinion about it.
    ///
    /// Called every time an extension starts, which is every launch, so the
    /// "unless" is the whole function: see [`crate::extension_pins`] for why the
    /// alternative — inferring "not pinned" from absence — re-shows the one
    /// extension somebody deliberately hid, once per launch, forever.
    ///
    /// Returns whether anything changed, so the caller can tell a first run from
    /// every run after it.
    pub fn adopt_extension_pin(&self, id: String) -> bool {
        self.lock().session.extension_pins.adopt(&id)
    }

    // MARK: - What an extension is allowed to do

    /// What this extension is asking for, in words and in danger order.
    ///
    /// The shell draws this; it does not write it. What `<all_urls>` means to
    /// a person is not something two platforms get to disagree about.
    pub fn extension_consent_request(&self, extension: InstalledExtension) -> ConsentRequest {
        extension_permissions::consent_request(
            extension.id,
            extension.manifest.name,
            &extension.manifest.permissions,
            &extension.manifest.host_permissions,
        )
    }

    /// What was decided about an extension, or `None` if nobody was ever asked.
    ///
    /// `None` is not an empty grant. It means the extension must not run until
    /// someone has seen the dialog — which is what happens to anything
    /// installed before this browser started asking.
    pub fn extension_consent(&self, id: String) -> Option<ConsentDecision> {
        self.lock().session.extension_consent.decision(&id).cloned()
    }

    /// Answer a `chrome.*` call an extension made over zer0's own channel.
    ///
    /// Everything an extension is told comes from here rather than from the
    /// shell, including every refusal: what an extension may call, which
    /// arguments this browser will honour and what a `DownloadItem` looks like
    /// are answers two platforms must not disagree about (AGENTS.md). The shell
    /// hands over the facts only it can measure and carries out the outcome.
    ///
    /// `body` is somebody else's JavaScript, verbatim, and is treated as
    /// hostile throughout.
    pub fn extension_api_call(
        &self,
        extension_id: String,
        method: String,
        body: String,
        host: HostFacts,
    ) -> ExtensionApiAnswer {
        let mut state = self.lock();
        let State { session, .. } = &mut *state;
        let decision = session.extension_consent.decision(&extension_id).cloned();
        let active_tab = session.browser.active_tab();
        extension_api::answer(
            &method,
            &body,
            decision.as_ref(),
            &mut session.downloads,
            active_tab,
            host,
        )
    }

    /// The answer to a `downloads.download` now that the download exists.
    ///
    /// Two calls rather than one because an extension is told the identity of a
    /// download, and there is no identity until the engine has taken the
    /// transfer on. The alternative — a hole in the JSON for the shell to fill
    /// — would put the shape of this answer in two languages.
    pub fn extension_api_download_started(&self, id: DownloadId) -> String {
        extension_api::download_started(&mut self.lock().session.downloads, &id)
    }

    /// Write down what someone chose. `decided_at_ms` comes from the shell for
    /// the same reason `Action::Tick` does: the core has no clock.
    pub fn record_extension_consent(&self, decision: ConsentDecision) {
        self.lock().session.extension_consent.record(decision);
    }

    /// Take a permission back. Returns whether anything changed, so the caller
    /// knows whether the live context needs updating.
    pub fn revoke_extension_permission(
        &self,
        id: String,
        kind: PermissionKind,
        key: String,
    ) -> bool {
        self.lock()
            .session
            .extension_consent
            .revoke(&id, kind, &key)
    }

    /// Give one back, from the same screen that took it away.
    pub fn grant_extension_permission(
        &self,
        id: String,
        kind: PermissionKind,
        key: String,
    ) -> bool {
        self.lock().session.extension_consent.grant(&id, kind, &key)
    }

    // MARK: - Talking to a program outside the browser

    /// What is to happen about an extension naming an application id.
    ///
    /// **The one door.** Nothing else in this browser turns an application id
    /// into a path, so there is no second place where the permission could go
    /// unchecked, the registration unread or the answer unasked.
    ///
    /// `application_id` is a string out of somebody else's JavaScript and is
    /// treated as one the whole way down.
    pub fn native_host(&self, extension_id: String, application_id: String) -> NativeHostOutcome {
        let state = self.lock();
        let Some(root) = state.application_support.clone() else {
            return native_messaging::outcome(
                Path::new(""),
                None,
                &state.session.native_hosts,
                &extension_id,
                &application_id,
            );
        };
        native_messaging::outcome(
            &root,
            state.session.extension_consent.decision(&extension_id),
            &state.session.native_hosts,
            &extension_id,
            &application_id,
        )
    }

    /// Write down what somebody said about one extension starting one program.
    ///
    /// `decided_at_ms` comes from the shell, for the reason every other clock
    /// in the core does: there is no clock here.
    pub fn record_native_host_decision(&self, decision: NativeHostDecision) {
        self.lock().session.native_hosts.record(decision);
    }

    /// The programs this extension has been allowed to start, for the screen
    /// that shows what an extension holds.
    pub fn allowed_native_host_programs(&self, extension_id: String) -> Vec<String> {
        self.lock()
            .session
            .native_hosts
            .allowed_programs(&extension_id)
    }

    // MARK: - What a site was allowed to point at you

    /// Every answer given to a site, for the screen that takes them back.
    ///
    /// Not in [`BrowserSnapshot`]: this is read by one pane in Settings and
    /// nothing else, and copying the whole ledger across the FFI after every
    /// dispatch to redraw a sidebar would be absurd — the same reasoning
    /// [`Zer0::conversations`] gives.
    ///
    /// Everything, including refusals. A refusal you cannot see is a refusal
    /// you cannot take back, and a pane that showed only the grants would let
    /// somebody block a site by accident with no way to find it again.
    pub fn site_permissions(&self) -> Vec<SiteGrant> {
        self.lock().session.site_permissions.all().to_vec()
    }

    /// Whether a page is currently holding this, for the row that says so.
    pub fn site_permission_allowed(
        &self,
        space: SpaceId,
        origin: String,
        capability: SiteCapability,
    ) -> bool {
        self.lock()
            .session
            .site_permissions
            .verdict(space, &origin, capability)
            == crate::site_permissions::SiteVerdict::Allowed
    }

    /// The engine refused a pattern the core accepted. Stop recording it as
    /// granted, so nothing ever shows it as approved.
    pub fn mark_extension_pattern_unreadable(&self, id: String, pattern: String) {
        self.lock()
            .session
            .extension_consent
            .mark_unreadable(&id, &pattern);
    }
}

#[cfg(test)]
#[path = "ffi_tests.rs"]
mod tests;
