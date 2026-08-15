//! Everything a running browser holds.
//!
//! Grouped into one struct so the reducer takes a single argument, and so
//! persistence has one thing to save and restore.

use std::collections::HashMap;

use crate::bookmarks::Bookmarks;
use crate::certificates::{CertificateReport, TrustExceptions};
use crate::chat::Chat;
use crate::downloads::Downloads;
use crate::extension_permissions::ExtensionConsent;
use crate::extension_pins::ExtensionPins;
use crate::history::History;
use crate::http_auth::HttpAuth;
use crate::icons::Icons;
use crate::mcp::McpRegistry;
use crate::model::{Browser, SpaceId, TabId, TabKind};
use crate::native_messaging::NativeHostLedger;
use crate::navigation_state::NavigationStates;
use crate::page_dialogs::PageDialogs;
use crate::preferences::Preferences;
use crate::routing::RoutingTable;
use crate::shortcuts::Keymap;
use crate::site_permissions::SitePermissions;

/// Enough of a closed tab to bring it back.
#[derive(Debug, Clone, PartialEq)]
pub struct ClosedTab {
    pub url: Option<String>,
    pub space: SpaceId,
    pub kind: TabKind,
}

/// How many closed tabs are worth remembering. Deep enough to undo a mistake,
/// shallow enough not to be a second history.
pub(crate) const CLOSED_TAB_MEMORY: usize = 25;

#[derive(Debug, Clone, PartialEq)]
pub struct Session {
    pub browser: Browser,
    pub history: History,
    /// Addresses somebody kept on purpose.
    ///
    /// Beside `history` rather than inside `browser`, because a bookmark is
    /// not a tab and must not be reachable from anything that iterates tabs.
    /// And beside it rather than inside a space: a bookmark has no space (see
    /// [`crate::bookmarks`]), so there is nowhere in `browser` it could
    /// honestly live.
    pub bookmarks: Bookmarks,
    /// Air-traffic rules: which space a URL belongs to.
    pub routes: RoutingTable,
    /// Keyboard shortcuts, so every platform shell agrees on them.
    pub keymap: Keymap,
    /// Everything the settings window can change.
    pub preferences: Preferences,
    /// What has come down, what is coming down now, and what went wrong.
    /// Outlives the view showing it, so it lives here.
    pub downloads: Downloads,
    /// What each installed extension was allowed to do. Here rather than in
    /// the engine's own permission store because that one is rebuilt from
    /// nothing on every launch, and a consent that resets on relaunch trains
    /// people to click through.
    pub extension_consent: ExtensionConsent,
    /// Which extension buttons are on show, and in what order.
    ///
    /// Beside the consent ledger rather than inside it, because the two answer
    /// different questions and one must not be able to imply the other: an
    /// extension can hold every permission it asked for and still be off the
    /// row, and taking it off the row grants and revokes nothing.
    pub extension_pins: ExtensionPins,
    /// Which programs outside the browser each extension may start.
    ///
    /// A third ledger rather than a field on the consent one, because it holds
    /// answers to a question that could not be asked when consent was given:
    /// `nativeMessaging` reads *"Talk to programs installed on this Mac"*, and
    /// which program is not knowable at install time. See ADR-0105.
    pub native_hosts: NativeHostLedger,
    /// One picture per site per cookie jar. Kept here rather than on a tab
    /// because an icon outlives every tab that ever showed it, and it is
    /// wanted for rows — history, the command bar — that are not tabs at all.
    ///
    /// Persisted separately from everything else in this struct; see ADR-0044.
    pub icons: Icons,
    /// Conversations, and what tools may run without asking.
    ///
    /// Here rather than beside the panel that draws one, because a reply keeps
    /// arriving while the panel is shut and a consent ledger that lived in a
    /// view would reset every time the view went away — which is the exact
    /// failure ADR-0028 names for extension permissions.
    pub chat: Chat,
    /// Which MCP servers are up, what tools they really offer, and what shape
    /// each remembered approval was given about.
    ///
    /// Beside [`Session::chat`] rather than inside it, because the two answer
    /// different questions and must not be able to drift: `chat` holds whether
    /// a tool may run, this holds what that answer was about. See
    /// [`crate::mcp`] and ADR-0050.
    pub mcp: McpRegistry,
    /// What each site was allowed to point at you, per space.
    ///
    /// Here for the reason [`Session::extension_consent`] is here, and against
    /// a worse version of the same failure: WebKit answers a capture request
    /// from whatever the delegate says and remembers nothing, so a consent that
    /// lived on that side would be re-asked on every launch — and this one is
    /// re-asked by a *page*, at a moment the page picks. See ADR-0056.
    pub site_permissions: SitePermissions,
    /// What pages have said to you and are waiting to hear back about:
    /// `alert()`, `confirm()`, `prompt()` and the file picker.
    ///
    /// Deliberately **not** persisted and deliberately not on the tab. Not
    /// persisted because a page frozen on a question in a previous run is not
    /// on the other end of it after a relaunch, and an answer to a question
    /// nobody is asking is worse than none. Not on the tab because the engine's
    /// completion handler lives on the host and this is the record of what is
    /// owed to it — the two have to be able to be counted against each other.
    pub page_dialogs: PageDialogs,
    /// The one HTTP-auth panel that is up, if any.
    ///
    /// Not persisted, for the reason `page_dialogs` is not: a server that was
    /// asking for a password in a previous run is not on the other end of the
    /// question after a relaunch. What *is* worth keeping — the credential —
    /// is already kept, in the Keychain, by the machinery ADR-0064 built.
    pub http_auth: HttpAuth,
    /// Certificates somebody deliberately waved through, this session only.
    ///
    /// Not persisted, and that is a decision rather than an omission: see
    /// [`crate::certificates::TrustExceptions`].
    pub trust_exceptions: TrustExceptions,
    /// What was wrong with the certificate that failed this tab's last
    /// navigation.
    ///
    /// Held here rather than on the tab because it is measured at a different
    /// moment from the failure it explains: the certificate exists while the
    /// trust challenge is open and is gone by the time `-1202` arrives. Cleared
    /// when the tab commits a page, so a screen never explains a connection
    /// that has since worked.
    pub certificate_reports: HashMap<TabId, CertificateReport>,
    /// Where each tab has been, as the engine wrote it down.
    ///
    /// Beside the tabs rather than on them, because a `Tab` crosses the FFI in
    /// every snapshot and this does not need to. See
    /// [`crate::navigation_state`].
    pub navigation_states: NavigationStates,
    /// Most recently closed first. Not persisted: reopening something from
    /// last week is what history is for.
    pub(crate) closed_tabs: Vec<ClosedTab>,
}

impl Session {
    /// Write down a *remembered* answer about a tool, bound to the tool it was
    /// given about.
    ///
    /// One function, because the answer and the shape it was given about are
    /// one decision and there must be no way to record half of it. Both halves
    /// live in this struct and nowhere else, so this is the only place that can
    /// write them — the reducer calls it when somebody chooses *always* or
    /// *never*, and the FFI calls it when Settings does.
    ///
    /// The two answers are not symmetrical, and the asymmetry is the point.
    ///
    /// **A yes binds or it is not written at all.** Returns `false` when there
    /// is no such tool to bind to, in which case nothing was written: a
    /// standing approval must never sit waiting for a server to supply a
    /// matching tool later. See ADR-0050 and
    /// `approving_a_tool_that_does_not_exist_binds_nothing`.
    ///
    /// **A no needs no shape.** `verdict` answers `Refused` from the ledger row
    /// alone, before it ever reads a fingerprint, so there is nothing a missing
    /// shape could let through — and requiring one would mean a *never* given
    /// while the server was dying is a *never* somebody has to give again.
    /// Whatever shape was bound before goes, because it described an approval
    /// that no longer exists.
    pub fn remember_tool_answer(
        &mut self,
        server: &str,
        tool: &str,
        allowed: bool,
        decided_at_ms: u64,
    ) -> bool {
        if allowed {
            if !self.mcp.remember_shape(server, tool) {
                return false;
            }
        } else {
            self.mcp.forget_shape(server, tool);
        }
        self.chat
            .consent_mut()
            .record(server, tool, allowed, decided_at_ms);
        true
    }

    /// Take a remembered answer back, both halves of it, so the next call asks
    /// again.
    pub fn forget_tool_answer(&mut self, server: &str, tool: &str) -> bool {
        self.mcp.forget_shape(server, tool);
        self.chat.consent_mut().forget(server, tool)
    }

    pub fn new(first_space_name: impl Into<String>, data_store_id: impl Into<String>) -> Self {
        Self {
            browser: Browser::new(first_space_name, data_store_id),
            history: History::new(),
            bookmarks: Bookmarks::new(),
            routes: RoutingTable::new(),
            keymap: Keymap::with_defaults(),
            preferences: Preferences::default(),
            downloads: Downloads::new(),
            extension_consent: ExtensionConsent::new(),
            extension_pins: ExtensionPins::new(),
            native_hosts: NativeHostLedger::new(),
            icons: Icons::new(),
            chat: Chat::new(),
            mcp: McpRegistry::new(),
            site_permissions: SitePermissions::new(),
            page_dialogs: PageDialogs::new(),
            http_auth: HttpAuth::new(),
            trust_exceptions: TrustExceptions::new(),
            certificate_reports: HashMap::new(),
            navigation_states: NavigationStates::new(),
            closed_tabs: Vec::new(),
        }
    }
}
