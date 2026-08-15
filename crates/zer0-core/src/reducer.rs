//! The reducer. All browser behaviour lives here, and nothing here knows what
//! a `WKWebView` is, which is exactly why it can be tested without a UI.

use crate::certificates::TrustDecision;
use crate::chat::{
    self, ChatError, ChatErrorKind, ConsentChoice, Conversation, ConversationId, ConversationScope,
    Message, MessageId, MessageRole, MessageState, PageReference, ToolCall, ToolCallId,
    ToolCallState, ToolInvocation,
};
use crate::downloads::{
    self, Download, DownloadError, DownloadErrorKind, DownloadId, DownloadState,
};
use crate::extension_url;
use crate::http_auth::{AuthChoice, AuthDecision, AuthGate};
use crate::icons;
use crate::internal_url;
use crate::mcp::ToolVerdict;
use crate::model::{
    Browser, DEFAULT_SPLIT_RATIO, NavigationError, NavigationErrorKind, SpaceId, SpaceProfile, Tab,
    TabId, TabKind, WindowId,
};
use crate::page_dialogs::{DialogGate, PageDialogAnswer, PageDialogKind};
use crate::page_menu::{self, PageMenuItem, PageTarget};
use crate::protocol::{
    Action, ChatSubject, EngineCommand, ReplyStop, ViewConfiguration, WindowContents, WindowRequest,
};
use crate::routing::Route;
use crate::session::Session;
use crate::session::{CLOSED_TAB_MEMORY, ClosedTab};
use crate::site_permissions::{
    Gate, SiteCapability, SiteChoice, SiteDecision, SitePermissionPrompt,
};
use crate::tint;
use crate::url_input::{self, Resolved};

/// The numbered slot that means "the last tab" rather than "the ninth tab".
///
/// Chrome ("jump to the last tab"), Safari ("select your last tab"), Firefox
/// and Edge all publish the same rule for the ninth slot, and none of them make
/// it conditional on having fewer than ten tabs open.
const LAST_TAB_SLOT: u32 = 9;

/// Apply an action and return what the engine host should do about it.
///
/// Actions naming a tab that no longer exists are dropped. That is not
/// defensive programming: engine events arrive asynchronously, so a
/// `TitleChanged` for a tab the user just closed is expected traffic, not a bug.
///
/// Every action leaves through here, which is why [`name_our_pages`] is here
/// and not at the four places a tab is pointed at one of our addresses.
pub fn dispatch(session: &mut Session, action: Action) -> Vec<EngineCommand> {
    let out = apply(session, action);
    name_our_pages(session);
    out
}

/// Name every tab showing one of the browser's own addresses.
///
/// **One door, and the alternative is what makes it worth one.** A chat tab's
/// name depends on the *thread*, not on the address: it is "Chat about
/// github.com" when the thread is minted and becomes the question the moment
/// somebody asks one. Spelled at the places a tab is pointed at a conversation
/// — the address bar, ⌘E, the thread list, and again when a question lands —
/// that is four sites that have to agree, and the one that is forgotten is a
/// row that keeps saying "Chat about github.com" under a conversation forty
/// messages long.
///
/// So nothing sets these titles; they are re-derived after every action, from
/// the thread, which is the only thing that knows. It costs one pass over the
/// open tabs per dispatch and buys a name that cannot go stale.
///
/// A web page's title is *not* touched here — that one is the page's own claim
/// about itself, arrives as `TitleChanged`, and this only ever looks at tabs
/// whose address is ours.
pub(crate) fn name_our_pages(session: &mut Session) {
    let named: Vec<(TabId, String)> = session
        .browser
        .all_tabs()
        .iter()
        .filter_map(|t| {
            let address = internal_url::parse(t.url.as_deref()?)?;
            let title = match &address {
                internal_url::InternalAddress::Chat { conversation } => {
                    internal_url::conversation_title(
                        conversation.and_then(|id| session.chat.get(id)),
                    )
                }
                named @ (internal_url::InternalAddress::Settings
                | internal_url::InternalAddress::History
                | internal_url::InternalAddress::Downloads) => named.title()?,
            };
            (t.title.as_deref() != Some(title.as_str())).then_some((t.id, title))
        })
        .collect();

    for (tab, title) in named {
        if let Some(t) = session.browser.tab_mut(tab) {
            t.title = Some(title);
        }
    }
}

fn apply(session: &mut Session, action: Action) -> Vec<EngineCommand> {
    match action {
        Action::OpenTab { space, url, parent } => {
            let space = space.unwrap_or_else(|| session.browser.active_space());
            // Every other action validates its SpaceId. Without this, a stale
            // id from a snapshot creates a tab no space owns: invisible in the
            // sidebar, never saved, and with no cookie jar.
            if session.browser.space(space).is_none() {
                return Vec::new();
            }

            // Route before creating anything, so a routed URL never briefly
            // exists in the wrong space's cookie jar.
            if let Some(input) = url.as_deref() {
                let resolved = resolve(session, input);
                if let Some(target) = session.routes.route(&resolved)
                    && target != space
                {
                    return open_in(session, target, Some(resolved), None);
                }
            }
            open_in(session, space, url.map(|u| resolve(session, &u)), parent)
        }

        Action::CloseTab { tab } => close_tabs(session, &[tab]),

        Action::PageOpenedWindow { opener, request } => open_from_page(session, opener, request),

        Action::PageLeftExtension { tab, url } => leave_extension(session, tab, url),

        Action::PageClosedWindow { tab } => close_from_page(session, tab),

        Action::ChosePageMenuItem { tab, item, target } => {
            choose_page_menu_item(session, tab, item, &target)
        }

        Action::ActivateTab { tab } => {
            if session.browser.tab(tab).is_none() {
                return Vec::new();
            }
            session.browser.set_active_tab(Some(tab));
            vec![EngineCommand::FocusWebView { tab }]
        }

        Action::MoveTab { tab, space, index } => relocate(session, tab, space, index as usize),

        Action::MoveTabToGroup {
            tab,
            space,
            kind,
            before,
        } => {
            // Checked up front so a drop that cannot land leaves nothing
            // behind: changing `kind` on a tab that never moved would pin a
            // page the person only dragged past.
            if session.browser.tab(tab).is_none() || session.browser.space(space).is_none() {
                return Vec::new();
            }
            let index = drop_index(&session.browser, tab, space, kind, before);
            let out = relocate(session, tab, space, index);
            if let Some(t) = session.browser.tab_mut(tab) {
                t.kind = kind;
            }
            out
        }

        Action::SetTabKind { tab, kind } => {
            if let Some(t) = session.browser.tab_mut(tab) {
                t.kind = kind;
            }
            Vec::new()
        }

        Action::SetTabMuted { tab, muted } => {
            let Some(t) = session.browser.tab_mut(tab) else {
                return Vec::new();
            };
            t.muted = muted;
            vec![EngineCommand::SetMuted { tab, muted }]
        }

        Action::SetTabZoom { tab, factor } => {
            // NaN survives clamp, and SQLite refuses it in a NOT NULL REAL
            // column: one NaN would fail every save from then on, silently.
            if factor.is_nan() {
                return Vec::new();
            }
            // Clamped so a stuck key cannot leave a page unreadable in either
            // direction.
            let factor = factor.clamp(0.25, 5.0);
            let Some(t) = session.browser.tab_mut(tab) else {
                return Vec::new();
            };
            t.zoom_factor = factor;
            vec![EngineCommand::SetZoom { tab, factor }]
        }

        Action::CycleTab { delta } => {
            // This window's tabs. Cycling over the space's would step onto a
            // tab another window is showing, and `set_active_tab` would then
            // pull that page across the screen — ⌃Tab taking a page out of the
            // window behind this one (ADR-0065).
            let space = session.browser.active_space();
            let order: Vec<TabId> = session
                .browser
                .tabs_in_window(session.browser.key_window(), space)
                .iter()
                .map(|t| t.id)
                .collect();
            let Some(next) = step(&order, session.browser.active_tab(), delta) else {
                return Vec::new();
            };
            session.browser.set_active_tab(Some(next));
            vec![EngineCommand::FocusWebView { tab: next }]
        }

        Action::SelectTabByIndex { index } => {
            // This window's tabs, for the reason `CycleTab` above uses them:
            // ⌘1 means the first row of the list in front of you, and the list
            // in front of you is this window's.
            let space = session.browser.active_space();
            let order: Vec<TabId> = session
                .browser
                .tabs_in_window(session.browser.key_window(), space)
                .iter()
                .map(|t| t.id)
                .collect();
            if order.is_empty() || index == 0 {
                return Vec::new();
            }
            // The ninth slot is "the last tab", not "the ninth tab". Chrome,
            // Safari, Firefox and Edge all agree on that, and they agree on it
            // *unconditionally*: with twelve tabs open, ⌘9 goes to the twelfth.
            // Clamping alone would only get this right below ten tabs, and the
            // people who would notice are exactly the ones who keep enough tabs
            // open to need the shortcut.
            let at = if index == LAST_TAB_SLOT {
                order.len() - 1
            } else {
                (index as usize - 1).min(order.len() - 1)
            };
            let tab = order[at];
            session.browser.set_active_tab(Some(tab));
            vec![EngineCommand::FocusWebView { tab }]
        }

        Action::ReopenClosedTab => {
            let Some(closed) = session.closed_tabs.pop() else {
                return Vec::new();
            };
            // If the space it lived in is gone, it comes back in the current
            // one rather than vanishing again.
            let space = match session.browser.space(closed.space) {
                Some(_) => closed.space,
                None => session.browser.active_space(),
            };
            let mut out = open_in(session, space, closed.url, None);
            if closed.kind != TabKind::Today
                && let Some(tab) = session.browser.active_tab()
                && let Some(t) = session.browser.tab_mut(tab)
            {
                t.kind = closed.kind;
            }
            out.extend(Vec::new());
            out
        }

        Action::CycleSpace { delta } => {
            let ids: Vec<SpaceId> = session.browser.spaces().iter().map(|s| s.id).collect();
            let Some(next) = step(&ids, Some(session.browser.active_space()), delta) else {
                return Vec::new();
            };
            if !session.browser.set_active_space(next) {
                return Vec::new();
            }
            focus_entry_tab(session, next)
        }

        Action::SelectSpaceByIndex { index } => {
            // `spaces()` is the order the chips are drawn in, so the digits
            // count through the list that is on screen (ADR-0087). Two lists
            // would put ⌃3 somewhere nothing points at.
            //
            // Refuse rather than repair: clamping would make ⌃9 mean "the last
            // space", a rule nobody's fingers have, and would move somebody to
            // a space they did not name.
            let Some(space) = index
                .checked_sub(1)
                .and_then(|at| session.browser.spaces().get(at as usize))
                .map(|s| s.id)
            else {
                return Vec::new();
            };
            if !session.browser.set_active_space(space) {
                return Vec::new();
            }
            focus_entry_tab(session, space)
        }

        Action::NavigateTo { tab, input } => {
            let Some(from) = session.browser.tab(tab).map(|t| t.space) else {
                return Vec::new();
            };
            let url = resolve(session, &input);

            // Skip routing, and only routing. An air-traffic rule sends a
            // *site* to the space that owns it, and none of the browser's own
            // addresses belongs to a space — routing `zer0://chat` would move
            // the tab somewhere on the strength of a pattern that happened to
            // match our scheme.
            //
            // It still goes through `start_navigation`, which is the one door
            // where an address of ours is acted on. Calling `go_internal`
            // straight from here would be a second door, and a second door is
            // one somebody can leave open — proved by breaking the guard in
            // `start_navigation` and watching this path carry on working.
            if internal_url::claims_scheme(&url) {
                return start_navigation(session, tab, url);
            }

            match session.routes.route(&url) {
                Some(target) if target != from => hand_off(session, tab, target, url),
                _ => start_navigation(session, tab, url),
            }
        }

        Action::OpenInternalPage { address } => show_internal_page(session, address),

        Action::GoBack { tab } => guard(session, tab, EngineCommand::GoBack { tab }),
        Action::GoForward { tab } => guard(session, tab, EngineCommand::GoForward { tab }),
        Action::Reload { tab, from_origin } => match retry_url(session, tab) {
            // A navigation that failed before committing left the engine with
            // no page to reload, so asking it to reload does nothing at all.
            // Re-issuing the load is the only thing that can work, and it is
            // what both ⌘R and the retry button on the error screen mean.
            Some(url) => start_navigation(session, tab, url),
            None => guard(session, tab, EngineCommand::Reload { tab, from_origin }),
        },

        Action::ToggleSplit => {
            let space = session.browser.active_space();
            if session.browser.clear_split(space) {
                // Focus does not move: the pane you were reading is the one
                // that takes the whole area.
                return Vec::new();
            }
            let Some(active) = session.browser.active_tab() else {
                return Vec::new();
            };
            match neighbour_of(&session.browser, active) {
                Some(other) => {
                    session
                        .browser
                        .set_split(space, active, other, DEFAULT_SPLIT_RATIO);
                    // The tab already in hand keeps the keyboard; the other
                    // pane arrived to be read, not typed into.
                    vec![EngineCommand::FocusWebView { tab: active }]
                }
                None => {
                    // Nothing to pair with, so the second pane is a new tab.
                    // A blank pane is where you are about to type, so unlike
                    // the case above the keyboard follows it.
                    let out = open_in(session, space, None, None);
                    let Some(opened) = session.browser.active_tab() else {
                        return out;
                    };
                    session
                        .browser
                        .set_split(space, active, opened, DEFAULT_SPLIT_RATIO);
                    out
                }
            }
        }

        Action::SplitWith { tab } => {
            let space = session.browser.active_space();
            let Some(active) = session.browser.active_tab() else {
                return Vec::new();
            };
            if !session
                .browser
                .set_split(space, active, tab, DEFAULT_SPLIT_RATIO)
            {
                return Vec::new();
            }
            // You named this tab, so it is the one you meant to look at, the
            // same as clicking it in the sidebar would have been.
            session.browser.set_active_tab(Some(tab));
            vec![EngineCommand::FocusWebView { tab }]
        }

        Action::FocusOtherPane => {
            let space = session.browser.active_space();
            let Some(other) = session
                .browser
                .active_tab()
                .and_then(|active| session.browser.split(space)?.other(active))
            else {
                return Vec::new();
            };
            session.browser.set_active_tab(Some(other));
            vec![EngineCommand::FocusWebView { tab: other }]
        }

        Action::SetSplitRatio { space, ratio } => {
            session.browser.set_split_ratio(space, ratio);
            Vec::new()
        }

        Action::ActivateSpace { space } => {
            if !session.browser.set_active_space(space) {
                return Vec::new();
            }
            focus_entry_tab(session, space)
        }

        Action::CreateSpace {
            name,
            data_store_id,
            ephemeral,
        } => {
            let space = session.browser.add_space(name, data_store_id);
            if ephemeral {
                session.browser.set_space_profile(
                    space,
                    SpaceProfile {
                        ephemeral: true,
                        ..SpaceProfile::default()
                    },
                );
            }
            // A brand new space with no tabs is a dead end, so seed one.
            open_in(session, space, None, None)
        }

        Action::OpenWindow { onto } => open_window(session, onto),

        Action::CloseWindow { window } => close_window(session, window),

        Action::FocusWindow { window } => {
            session.browser.set_key_window(window);
            // Nothing to carry out: the window is already in front on screen,
            // which is how the shell knew to send this. All that changed is
            // which window the next command with nobody named in it acts on.
            Vec::new()
        }

        Action::RenameSpace { space, name } => {
            session.browser.rename_space(space, name);
            Vec::new()
        }

        Action::SetSpaceProfile { space, profile } => {
            if !session.browser.set_space_profile(space, profile) {
                return Vec::new();
            }
            // The profile is baked into a web view at creation, so every open
            // page in the space has to be rebuilt for the change to mean
            // anything.
            let tabs: Vec<TabId> = session
                .browser
                .tabs_in(space)
                .iter()
                .map(|t| t.id)
                .collect();
            tabs.into_iter()
                .flat_map(|tab| rebuild_view(session, tab))
                .collect()
        }

        Action::CloseSpace { space } => {
            let data_store_id = session
                .browser
                .space(space)
                .map(|s| s.data_store_id.clone());
            // A thread outlives the tab its page was open in, but never the
            // space: what it holds is the material that space has its own
            // cookie jar for (ADR-0007), and there is nowhere left to reach it
            // from once the space is gone.
            let conversations = session.chat.ids_for_space(space);

            let Some(orphaned) = session.browser.remove_space(space) else {
                // Refused: this was the last space.
                return Vec::new();
            };
            let mut ended = end_conversations(session, &conversations);
            // Rules pointing at a space that no longer exists would route into
            // the void.
            let remaining: Vec<SpaceId> = session.browser.spaces().iter().map(|s| s.id).collect();
            session.routes.retain_spaces(&remaining);

            // The jar is deleted below with no undo (ADR-0007). An approval
            // that outlived the identity it was given by is an approval nobody
            // can find, and one the next space to reuse the name inherits.
            session.site_permissions.forget_space(space);
            // And the same for a certificate somebody waved through in it. An
            // exception belonging to an identity that no longer exists is one
            // nobody can find, and one the next space to reuse the name would
            // inherit.
            session.trust_exceptions.forget_space(space);

            let mut out: Vec<EngineCommand> = Vec::new();
            for tab in orphaned {
                out.extend(answer_pending_for(session, tab));
                out.push(EngineCommand::DestroyWebView { tab });
            }
            ended.append(&mut out);
            let mut out = ended;
            if let Some(id) = data_store_id {
                // Its icons go with its cookies. A cache row keyed by a jar
                // nothing owns any more is the same leak ADR-0007 deletes the
                // jar to avoid, only smaller.
                session.icons.forget_data_store(&id);
                out.push(EngineCommand::DeleteDataStore { data_store_id: id });
            }
            if session.browser.active_tab().is_none() {
                let active = session.browser.active_space();
                out.extend(focus_entry_tab(session, active));
            }
            out
        }

        Action::SaveBookmark { tab } => {
            // "The page you are on" resolves here rather than in whichever
            // shell handled the key press, so ⌘D means the same thing on every
            // platform.
            let Some(tab) = tab.or_else(|| session.browser.active_tab()) else {
                return Vec::new();
            };
            let Some(tab) = session.browser.tab(tab) else {
                return Vec::new();
            };
            // A tab with nothing committed has no address to come back to.
            // Refuse rather than repair: keeping `pending_url` would file a
            // bookmark for a page that may be about to fail, and keeping the
            // placeholder title would file one called "New Tab".
            let Some(url) = tab.url.clone() else {
                return Vec::new();
            };
            let title = tab.title.clone().unwrap_or_default();
            let now = session.browser.now_ms();

            // Deliberately not asked whether this space records to disk.
            // ADR-0023 promises an ephemeral space leaves no trace of the pages
            // it *visited* — every one of those traces is taken by the browser
            // on its own. This one is somebody pressing a key that means "keep
            // this". A `Bookmark` has no space to have come from, so there is
            // nothing here that could say which one it was.
            session.bookmarks.save(&url, &title, now);
            Vec::new()
        }

        Action::EditBookmark {
            bookmark,
            title,
            tags,
        } => {
            session.bookmarks.edit(bookmark, &title, &tags);
            Vec::new()
        }

        Action::RemoveBookmark { bookmark } => {
            session.bookmarks.remove(bookmark);
            Vec::new()
        }

        Action::AddRoute { pattern, space } => {
            if session.browser.space(space).is_some() {
                session.routes.push(Route {
                    pattern,
                    space,
                    enabled: true,
                });
            }
            Vec::new()
        }

        Action::RemoveRoute { index } => {
            session.routes.remove(index as usize);
            Vec::new()
        }

        Action::SetRouteEnabled { index, enabled } => {
            session.routes.set_enabled(index as usize, enabled);
            Vec::new()
        }

        Action::Tick { now_ms } => {
            session.browser.set_now(now_ms);
            let stale = session.browser.stale_today_tabs();
            if stale.is_empty() {
                return Vec::new();
            }
            close_tabs(session, &stale)
        }

        Action::DownloadStarted {
            id,
            tab,
            url,
            suggested_filename,
            total_bytes,
            default_directory,
        } => {
            // A repeated id would overwrite a live download's record, and the
            // one that lost would keep writing bytes nothing on screen knows
            // about.
            if session.downloads.get(&id).is_some() {
                return Vec::new();
            }
            let directory = download_directory(session, default_directory);
            let filename = downloads::safe_filename(&suggested_filename);

            let mut record = new_download(session, &id, tab, url, &filename, total_bytes);

            // Nowhere to put it. `WKDownload` requires a destination whose
            // directory exists, so this has to be caught before we answer.
            if !downloads::is_usable_directory(&directory) {
                record.state = DownloadState::Failed;
                record.error = Some(DownloadError {
                    kind: DownloadErrorKind::CannotWrite,
                    message: directory,
                });
                session.downloads.begin(record);
                return vec![EngineCommand::CancelDownload { id }];
            }

            // Asked for in Settings. Until now that toggle wrote a row in
            // SQLite and changed nothing.
            if session.preferences.ask_where_to_save {
                session.downloads.begin(record);
                return vec![EngineCommand::AskDownloadDestination {
                    id,
                    directory,
                    filename,
                }];
            }

            let reserved = session.downloads.reserved_paths();
            match downloads::destination(&directory, &filename, &reserved) {
                Some(path) => {
                    record.path = path.to_string_lossy().into_owned();
                    record.filename = file_name_of(&record.path, &filename);
                    session.downloads.begin(record);
                    vec![EngineCommand::AcceptDownload {
                        id,
                        path: path.to_string_lossy().into_owned(),
                    }]
                }
                None => {
                    record.state = DownloadState::Failed;
                    record.error = Some(DownloadError {
                        kind: DownloadErrorKind::NameUnavailable,
                        message: directory,
                    });
                    session.downloads.begin(record);
                    vec![EngineCommand::CancelDownload { id }]
                }
            }
        }

        Action::DownloadDestinationChosen { id, path } => {
            if !session
                .downloads
                .get(&id)
                .is_some_and(Download::is_in_flight)
            {
                return Vec::new();
            }
            // The panel gives back a folder the person picked and a name they
            // may have typed. The folder is theirs to choose; the name still
            // goes through the same sanitising, because a save panel will
            // happily accept one carrying a bidi override.
            let chosen = std::path::PathBuf::from(&path);
            let directory = chosen
                .parent()
                .map(|d| d.to_string_lossy().into_owned())
                .unwrap_or_default();
            let filename = chosen
                .file_name()
                .map(|f| f.to_string_lossy().into_owned())
                .unwrap_or_default();

            if !downloads::is_usable_directory(&directory) {
                fail_download(session, &id, DownloadErrorKind::CannotWrite, directory);
                return vec![EngineCommand::CancelDownload { id }];
            }

            let reserved = session.downloads.reserved_paths();
            match downloads::destination(&directory, &filename, &reserved) {
                Some(destination) => {
                    let path = destination.to_string_lossy().into_owned();
                    if let Some(d) = session.downloads.get_mut(&id) {
                        d.filename = file_name_of(&path, &filename);
                        d.path = path.clone();
                    }
                    vec![EngineCommand::AcceptDownload { id, path }]
                }
                None => {
                    fail_download(session, &id, DownloadErrorKind::NameUnavailable, directory);
                    vec![EngineCommand::CancelDownload { id }]
                }
            }
        }

        Action::DownloadProgressed {
            id,
            received_bytes,
            total_bytes,
        } => {
            let Some(d) = session.downloads.get_mut(&id) else {
                return Vec::new();
            };
            // A progress report about a download that already stopped is
            // ordinary late traffic, not a reason to un-finish it.
            if !d.is_in_flight() {
                return Vec::new();
            }
            // Never let the count run backwards: a late report would make a
            // bar retreat for no reason anybody could explain.
            d.received_bytes = d.received_bytes.max(received_bytes);
            if total_bytes.is_some() {
                d.total_bytes = total_bytes;
            }
            Vec::new()
        }

        Action::DownloadFinished { id } => {
            let Some(d) = session.downloads.get_mut(&id) else {
                return Vec::new();
            };
            if !d.is_in_flight() {
                return Vec::new();
            }
            d.state = DownloadState::Completed;
            // The file is whole, so its size is now known even when the server
            // never said. This is the one moment an unknown total becomes a
            // fact rather than a guess.
            d.total_bytes = Some(d.received_bytes);
            d.error = None;
            Vec::new()
        }

        Action::DownloadFailed { id, kind, message } => {
            fail_download(session, &id, kind, message);
            Vec::new()
        }

        Action::CancelDownload { id } => {
            let Some(d) = session.downloads.get_mut(&id) else {
                return Vec::new();
            };
            if !d.is_in_flight() {
                return Vec::new();
            }
            // Recorded here rather than waiting for the engine to confirm: the
            // person stopping it is the fact, and a cancel the engine never
            // answers would otherwise leave a row claiming to be running.
            d.state = DownloadState::Cancelled;
            vec![EngineCommand::CancelDownload { id }]
        }

        Action::RetryDownload { id } => {
            let Some(d) = session.downloads.get(&id) else {
                return Vec::new();
            };
            // Retrying something still running would start a second copy of it.
            if d.is_in_flight() {
                return Vec::new();
            }
            // The tab it came from if that is still open, so the retry goes
            // through the same cookie jar; else wherever the person is now.
            let Some(tab) = d
                .tab
                .filter(|t| session.browser.tab(*t).is_some())
                .or_else(|| session.browser.active_tab())
            else {
                return Vec::new();
            };
            let url = d.url.clone();
            session.downloads.remove(&id);
            vec![EngineCommand::StartDownload { tab, url }]
        }

        Action::ResumeDownload { id } => {
            let Some(d) = session.downloads.get(&id) else {
                return Vec::new();
            };
            // Resuming something still arriving would open a second connection
            // for the same file, and both would write to the same path.
            if d.is_in_flight() {
                return Vec::new();
            }
            // The one gate. `resumable` is only ever set by the host saying it
            // still holds the blob, so a Resume that reaches here can be carried
            // out; a row whose data has gone offers Try Again instead.
            if !d.resumable {
                return Vec::new();
            }
            let Some(tab) = d
                .tab
                .filter(|t| session.browser.tab(*t).is_some())
                .or_else(|| session.browser.active_tab())
            else {
                return Vec::new();
            };

            // The record is kept, unlike a retry: what already arrived is on
            // disk under this row's name, and the transfer carries on into the
            // same file. Byte counts are left alone for the same reason — the
            // bar must not drop back to zero for bytes nobody threw away.
            let Some(d) = session.downloads.get_mut(&id) else {
                return Vec::new();
            };
            d.state = DownloadState::InProgress;
            d.error = None;
            // The host is about to spend the blob. Saying so here means a
            // second press cannot ask for the same resume twice.
            d.resumable = false;
            vec![EngineCommand::ResumeDownload { tab, id }]
        }

        Action::DownloadResumability { id, resumable } => {
            let Some(d) = session.downloads.get_mut(&id) else {
                return Vec::new();
            };
            // A download that is running has nothing to carry on from, and one
            // that finished has nothing left to fetch. Only a stopped, unfinished
            // transfer can be offered a Resume.
            if d.state == DownloadState::InProgress || d.state == DownloadState::Completed {
                return Vec::new();
            }
            d.resumable = resumable;
            Vec::new()
        }

        Action::PageAskedToPrint { tab } => {
            // A page may print the page you are looking at, and nothing else.
            // The panel is a sheet on the window its tab is in, so a background
            // tab printing itself would put a modal over whatever you were
            // reading, in the name of a page you cannot see.
            //
            // Refused rather than held, which is where this parts company with
            // ADR-0089: an `alert()` blocks the script until it is answered, so
            // holding it costs nothing, while `window.print()` returns straight
            // away here — nothing is waiting, and a panel that arrived minutes
            // later when you happened to look at the tab would be a modal with
            // no cause anybody could name.
            if !crate::page_dialogs::is_on_screen(&session.browser, tab) {
                return Vec::new();
            }
            vec![EngineCommand::PrintPage { tab }]
        }

        Action::RemoveDownload { id } => {
            // Only the entry. Deleting the file is the Finder's job, and a
            // browser that quietly removes files people already have is a
            // browser nobody should trust.
            session.downloads.remove(&id);
            Vec::new()
        }

        Action::ClearFinishedDownloads => {
            session.downloads.retain_in_flight();
            Vec::new()
        }

        Action::OpenChat { about, ask } => open_chat(session, about, ask),

        Action::ShowConversation { conversation } => switch_to_conversation(session, conversation),

        Action::StartAnotherConversation { like } => start_another(session, like),

        Action::SendChatMessage { conversation, text } => ask(session, conversation, text),

        Action::CancelChat { conversation } => cancel_chat(session, conversation),

        Action::ClearConversation { conversation } => {
            // Stopped before it is forgotten: a reply still arriving for a
            // thread nobody holds would write into nothing, and the host would
            // keep paying for it. The same path a closing tab takes.
            end_conversations(session, &[conversation])
        }

        Action::DecideToolCall { call, decision } => decide_tool_call(session, &call, decision),

        Action::SetToolConsent {
            server,
            tool,
            allowed,
        } => {
            let now = session.browser.now_ms();
            // Through the same door the consent prompt uses. An answer written
            // from Settings without a shape behind it is an answer that reads
            // as `Changed` for ever, and a bulk "approve everything" that only
            // wrote ledger rows is the convenience path ADR-0050 names as the
            // way this regresses. A tool the browser does not have binds
            // nothing and records nothing.
            session.remember_tool_answer(&server, &tool, allowed, now);
            Vec::new()
        }

        Action::ForgetToolConsent { server, tool } => {
            session.forget_tool_answer(&server, &tool);
            Vec::new()
        }

        Action::PageContextCaptured {
            conversation,
            url,
            title,
            text,
        } => page_captured(session, conversation, url, title, text),

        Action::ChatReplyStarted { message, model } => {
            let Some(m) = find_message_mut(session, message) else {
                return Vec::new();
            };
            // Late traffic about a reply that already stopped is not a reason
            // to relabel it.
            if !m.is_in_flight() {
                return Vec::new();
            }
            m.model = Some(model);
            Vec::new()
        }

        Action::ChatReplyDelta { message, text } => {
            let Some(m) = find_message_mut(session, message) else {
                return Vec::new();
            };
            if !m.is_in_flight() {
                return Vec::new();
            }
            m.append_delta(&text);
            Vec::new()
        }

        Action::ChatToolCallRequested {
            message,
            invocation,
        } => tool_call_requested(session, message, invocation),

        Action::ChatReplyFinished { message, stop } => reply_finished(session, message, stop),

        Action::ChatFailed {
            conversation,
            message,
            kind,
            detail,
        } => chat_failed(session, conversation, message, kind, detail),

        Action::ToolCallFinished { call, result } => {
            settle_call(session, &call, ToolCallState::Completed, result)
        }

        Action::ToolCallFailed { call, kind, detail } => {
            let Some(conversation) = session.chat.conversation_of_call(&call) else {
                return Vec::new();
            };
            if let Some(c) = session.chat.get_mut(conversation) {
                c.error = Some(ChatError {
                    kind,
                    detail: detail.clone(),
                });
            }
            settle_call(session, &call, ToolCallState::Failed, detail)
        }

        Action::ToolsListed { server, tools } => {
            // The register adopts the list: names are sanitised, collisions are
            // dropped, the count is capped and every survivor is fingerprinted.
            // A tool that changed shape since somebody approved it stops being
            // approved here, at the moment the new definition arrives, without
            // anything else having to notice.
            session.mcp.set_tools(&server, &tools);
            Vec::new()
        }

        Action::NavigationStarted { tab, url } => {
            if let Some(t) = session.browser.tab_mut(tab) {
                t.pending_url = Some(url);
                t.loading_complete = false;
                // Another attempt is under way, so the previous failure is no
                // longer what this tab is showing.
                t.last_error = None;
            }
            Vec::new()
        }

        Action::NavigationCommitted { tab, url } => {
            let now = session.browser.now_ms();
            // A page visited in an ephemeral space must not reach history:
            // history is written to disk, and that space promised it would
            // leave nothing behind.
            let remember = session
                .browser
                .tab(tab)
                .and_then(|t| session.browser.space(t.space))
                .is_none_or(|s| !s.profile.ephemeral);

            if let Some(t) = session.browser.tab_mut(tab) {
                t.url = Some(url.clone());
                t.pending_url = None;
                // The old title belongs to the old page. Holding onto it would
                // show a stale title while the new page loads.
                t.title = None;
                // And so does the old colour, more visibly: keeping it would
                // paint the window in the last site's brand while the next one
                // loads, then change again when it arrives. One change is
                // honest, two is a flicker.
                t.tint = None;
                // Bytes arrived: whatever failed before is over.
                t.last_error = None;
                t.last_active_at = now;
            }
            if remember {
                session.history.record(&url, None, now);
            }
            // A new page is a new question. Whatever this tab dismissed on the
            // last one stops holding, or Escape becomes permanent by accident.
            session.site_permissions.clear_mutes(tab);
            // A page committed, so whatever was wrong with the certificate that
            // stopped the *last* attempt is no longer what this tab is showing.
            // Left behind, it would explain a connection that has since worked.
            session.certificate_reports.remove(&tab);
            // The same sentence for page dialogs, plus one more: a question the
            // *old* page asked is moot, and the handler behind it still has to
            // be told something. Silence there is a tab frozen on a page that
            // is no longer loaded.
            let out = cancel_dialogs_for(session, tab);
            session.page_dialogs.tab_navigated(tab);
            out
        }

        Action::NavigationFinished { tab } => {
            if let Some(t) = session.browser.tab_mut(tab) {
                t.loading_complete = true;
            }
            Vec::new()
        }

        Action::NavigationFailed { tab, kind, message } => {
            let Some(t) = session.browser.tab_mut(tab) else {
                return Vec::new();
            };
            // Read where we were going before clearing it: on a tab that never
            // committed anything, `pending_url` is the only record of it.
            let url = t.pending_url.take().or_else(|| t.url.clone());
            t.loading_complete = true;
            // Nothing was painted, so there is no page colour to carry. The
            // error screen is ours and wears our own surface.
            t.tint = None;

            // A cancelled navigation is not a failure the user should be told
            // about: every download, every redirect and every link opened
            // elsewhere produces one. Showing a screen for those would put an
            // error over pages that are working.
            if kind != NavigationErrorKind::Cancelled {
                t.last_error = Some(NavigationError { kind, url, message });
            }
            Vec::new()
        }

        // The page died; the tab did not. Measured on macOS 26.5 with the web
        // content process killed outright: the view goes blank and `url` drops
        // to `nil`, and an ordinary load into that same view recovers it in
        // under 50ms — from inside this callback, a run loop later, or three
        // seconds later, and whether or not the view is on screen. So there is
        // nothing to rebuild here. What the tab needs is to say what happened
        // and to offer the one action, which is exactly the screen ADR-0016
        // already draws for a page that failed.
        //
        // **Deliberately no reload.** A page that ends its process while
        // loading would be reloaded into the same crash forever, and the
        // browser would sit there burning a core with nothing on screen to say
        // why. So the retry is a person's, through the same `Reload` every
        // other failed page uses.
        Action::PageProcessEnded { tab } => {
            let Some(t) = session.browser.tab_mut(tab) else {
                return Vec::new();
            };
            // The address to try again, read before `pending_url` is cleared:
            // a page that died mid-load has it in `pending_url` and nowhere
            // else.
            let url = t.pending_url.take().or_else(|| t.url.clone());
            t.loading_complete = true;
            t.playing_audio = false;
            // Nothing is painted any more, so the window stops wearing the
            // colour of a page that is gone.
            t.tint = None;
            t.last_error = Some(NavigationError {
                kind: NavigationErrorKind::PageProcessEnded,
                url,
                // Empty, because the engine says nothing about why and this is
                // not the place to invent it (ADR-0018).
                message: String::new(),
            });
            Vec::new()
        }

        // Where the tab has been, in bytes only the engine can read.
        //
        // Not classified as structural by the shell, and it does not need to
        // be: this arrives on the heels of the navigation that caused it, and
        // that commit already scheduled the write this rides out on.
        Action::NavigationStateChanged { tab, state } => {
            // A state for a tab that has gone is a state nothing can ever hand
            // back, so it is dropped rather than kept against a tab id that may
            // be reused.
            if session.browser.tab(tab).is_some() {
                session.navigation_states.set(tab, state.clone());
            }
            Vec::new()
        }

        // The engine would not take it. Nothing here tries to work out why —
        // the bytes are opaque and always were. What is owed is the load that
        // was held back when the state was handed over, so the tab comes back
        // on its page with no history rather than on nothing at all.
        Action::NavigationStateRefused { tab } => {
            session.navigation_states.forget(tab);
            let Some(url) = session.browser.tab(tab).and_then(|t| t.url.clone()) else {
                return Vec::new();
            };
            load_command(tab, url).into_iter().collect()
        }

        Action::TitleChanged { tab, title } => {
            let Some(t) = session.browser.tab_mut(tab) else {
                return Vec::new();
            };
            t.title = if title.is_empty() {
                None
            } else {
                Some(title.clone())
            };
            // Titles arrive after the commit, so the history entry is back-filled.
            if let Some(url) = t.url.clone() {
                session.history.set_title(&url, &title);
            }
            Vec::new()
        }

        Action::AudioStateChanged { tab, playing } => {
            if let Some(t) = session.browser.tab_mut(tab) {
                t.playing_audio = playing;
            }
            Vec::new()
        }

        Action::ColorsDeclared {
            tab,
            theme_colors,
            element_backgrounds,
            canvas_background,
        } => {
            if let Some(t) = session.browser.tab_mut(tab) {
                t.tint = tint::tint_for(
                    &theme_colors,
                    &element_backgrounds,
                    canvas_background.as_deref(),
                );
            }
            Vec::new()
        }

        Action::IconsDeclared { tab, candidates } => declare_icons(session, tab, &candidates),

        Action::IconFetched {
            data_store_id,
            host,
            bytes,
        } => {
            // Both halves are checked here rather than at the sender. What
            // came back is bytes from a stranger, and where it goes is a
            // promise: an ephemeral space records nothing, and a jar no live
            // space claims is not a place to write to.
            if !session.browser.data_store_records_to_disk(&data_store_id) {
                return Vec::new();
            }
            let now = session.browser.now_ms();
            // A refused body is stored as a miss rather than dropped, so the
            // site that served us a 404 page is not asked again on the next
            // navigation, and the next, and the next.
            let bytes = if icons::is_image(&bytes) {
                bytes
            } else {
                Vec::new()
            };
            session
                .icons
                .record(icons::IconKey::new(data_store_id, host), bytes, now);
            Vec::new()
        }

        Action::IconFetchFailed {
            data_store_id,
            host,
        } => {
            if !session.browser.data_store_records_to_disk(&data_store_id) {
                return Vec::new();
            }
            let now = session.browser.now_ms();
            session
                .icons
                .record(icons::IconKey::new(data_store_id, host), Vec::new(), now);
            Vec::new()
        }

        Action::SitePermissionRequested { request } => {
            match crate::site_permissions::gate(
                &session.browser,
                &session.site_permissions,
                &request,
            ) {
                Gate::Answer(decision) => vec![EngineCommand::AnswerSitePermission {
                    request: request.request,
                    decision,
                }],
                Gate::Ask(prompt) => {
                    session.site_permissions.raise(*prompt);
                    // No command. The question reaches the shell through the
                    // snapshot, which is re-read after every dispatch — so
                    // there is one answer to "is something being asked", and a
                    // sheet cannot outlive the request behind it.
                    Vec::new()
                }
            }
        }

        Action::DecideSitePermission {
            request,
            choice,
            decided_at_ms,
        } => decide_site_permission(session, request, choice, decided_at_ms),

        Action::SetSitePermission {
            space,
            origin,
            capability,
            allowed,
            decided_at_ms,
        } => {
            if session.browser.space(space).is_none() {
                return Vec::new();
            }
            session
                .site_permissions
                .record(space, &origin, capability, allowed, decided_at_ms);
            if allowed {
                return Vec::new();
            }
            stop_capture(session, space, &origin, &[capability])
        }

        Action::ForgetSitePermission {
            space,
            origin,
            capability,
        } => {
            if !session.site_permissions.forget(space, &origin, capability) {
                return Vec::new();
            }
            stop_capture(session, space, &origin, &[capability])
        }

        Action::HttpAuthRequested { request } => {
            match crate::http_auth::gate(&session.browser, &session.http_auth, &request) {
                AuthGate::Answer(decision) => vec![EngineCommand::AnswerHttpAuth {
                    request: request.request,
                    decision,
                }],
                AuthGate::Ask(prompt) => {
                    session.http_auth.raise(*prompt);
                    // No command. The question reaches the shell through the
                    // snapshot, so there is one answer to "is something being
                    // asked" and a panel cannot outlive the request behind it.
                    Vec::new()
                }
            }
        }

        Action::DecideHttpAuth { request, choice } => {
            // Taken before anything is emitted: a panel that has already been
            // answered must not be answerable twice, and the engine's handler
            // is called exactly once per challenge.
            let Some(_prompt) = session.http_auth.take_pending(request) else {
                return Vec::new();
            };
            vec![EngineCommand::AnswerHttpAuth {
                request,
                decision: match choice {
                    // The shell is holding what was typed and hands it to the
                    // engine itself. Whether it is *also* written down is the
                    // shell's next step and not a thing the core can do — there
                    // is nothing here that could hold a password (ADR-0064).
                    AuthChoice::Supply | AuthChoice::SupplyAndRemember => {
                        AuthDecision::UseCredential
                    }
                    AuthChoice::Cancel => AuthDecision::Cancel,
                },
            }]
        }

        Action::ServerTrustRejected { request } => {
            let Some(tab) = session.browser.tab(request.tab) else {
                // Still answered. A dropped handler is a navigation that never
                // finishes and never fails.
                return vec![EngineCommand::AnswerServerTrust {
                    request: request.request,
                    decision: TrustDecision::Refuse,
                }];
            };
            let space = tab.space;
            let origin = crate::certificates::certificate_origin(&request.host, request.port);

            // The only route to `Proceed`: somebody already said yes to this
            // exact certificate, in this space. There is no rule about a host
            // that can reach here.
            if session
                .trust_exceptions
                .holds(space, &origin, &request.certificate.fingerprint)
            {
                session.certificate_reports.remove(&request.tab);
                return vec![EngineCommand::AnswerServerTrust {
                    request: request.request,
                    decision: TrustDecision::Proceed,
                }];
            }

            // Kept against the tab so the failure screen that arrives a moment
            // later can say what is wrong. By then the certificate is gone.
            let now = session.browser.now_ms();
            session.certificate_reports.insert(
                request.tab,
                crate::certificates::certificate_report(
                    &request.host,
                    request.port,
                    &request.certificate,
                    now,
                ),
            );
            vec![EngineCommand::AnswerServerTrust {
                request: request.request,
                decision: TrustDecision::Refuse,
            }]
        }

        Action::TrustThisCertificate {
            tab,
            origin,
            fingerprint,
        } => {
            let Some(t) = session.browser.tab(tab) else {
                return Vec::new();
            };
            let space = t.space;
            session
                .trust_exceptions
                .record(space, &origin, &fingerprint);
            session.certificate_reports.remove(&tab);
            // The navigation never committed, so there is nothing to reload:
            // the address that failed has to be requested again, which is the
            // same path "Try Again" takes (ADR-0016).
            match retry_url(session, tab).or_else(|| session.browser.tab(tab)?.url.clone()) {
                Some(url) => start_navigation(session, tab, url),
                None => Vec::new(),
            }
        }

        Action::PageRaisedDialog { request } => {
            match crate::page_dialogs::gate(&session.browser, &session.page_dialogs, &request) {
                DialogGate::Answer(answer) => vec![EngineCommand::AnswerPageDialog {
                    request: request.request,
                    answer,
                }],
                DialogGate::Hold(dialog) => {
                    // Counted before it is held, so the count includes this
                    // one and the offer to stop the page appears on the second
                    // interruption rather than the third.
                    session.page_dialogs.count_raise(dialog.tab);
                    session.page_dialogs.hold(*dialog);
                    // No command. Which question is on screen reaches the shell
                    // through the snapshot, so there is one answer to *is a page
                    // asking something* and a panel cannot outlive the request
                    // behind it.
                    Vec::new()
                }
            }
        }

        Action::AnsweredPageDialog {
            request,
            answer,
            silence,
            decided_at_ms,
        } => answer_page_dialog(session, request, answer, silence, decided_at_ms),
    }
}

// MARK: - What a page said to you

/// Whether the half second applies to this answer at all.
///
/// It exists to stop a keystroke that was already in flight **committing**
/// something on a panel a page chose the moment for. Two things are outside it,
/// and both were found by driving the real thing:
///
/// - **A cancel.** It commits nothing — it is the answer a closing tab, a
///   silenced page and a crashed window all give — and the shell leaves Cancel
///   and Escape live from the first frame. A core that dropped an early cancel
///   would leave a person pressing a live button that does nothing, with a page
///   frozen behind it.
/// - **The file picker.** That panel is the system's own modal window with its
///   own focus; nobody can type into a page and into an open panel at once, so
///   there is no keystroke to defend against. Measured: with the window applied,
///   a picker closed inside half a second left the page waiting forever and
///   WebKit raised `NSInternalInconsistencyException` when the handler was
///   finally released uncalled.
fn guarded_by_the_settle_window(kind: &PageDialogKind, answer: &PageDialogAnswer) -> bool {
    match answer {
        PageDialogAnswer::Cancelled => return false,
        PageDialogAnswer::Accepted
        | PageDialogAnswer::Typed { .. }
        | PageDialogAnswer::Chose { .. } => {}
    }
    match kind {
        PageDialogKind::Alert | PageDialogKind::Confirm | PageDialogKind::Prompt { .. } => true,
        PageDialogKind::ChooseFiles { .. } => false,
    }
}

/// Answer one page, and — if that is what was asked for — stop it asking again.
///
/// The order matters. The dialog is taken first, so an answer that arrives
/// twice finds nothing the second time; and the page is answered whatever
/// happens to the rest, because a page waiting inside `alert()` is frozen and
/// nothing below is worth a frozen tab.
fn answer_page_dialog(
    session: &mut Session,
    request: u64,
    answer: PageDialogAnswer,
    silence: bool,
    decided_at_ms: u64,
) -> Vec<EngineCommand> {
    // A keystroke that was already on its way down when the page chose to
    // interrupt. The same window, enforced by the same function, as the camera
    // sheet's: the question stays exactly where it is and nothing is sent
    // (ADR-0056). Ignored rather than turned into a cancel, because a page that
    // could force an answer by racing would have found a way to answer for you.
    if let Some(pending) = session
        .page_dialogs
        .held()
        .iter()
        .find(|d| d.request == request)
        && guarded_by_the_settle_window(&pending.kind, &answer)
        && crate::site_permissions::answered_too_soon(pending.asked_at_ms, decided_at_ms)
    {
        return Vec::new();
    }

    let Some(dialog) = session.page_dialogs.take(request) else {
        // An answer to a question that has already gone. The engine was
        // answered when it went, and answering again would call a handler
        // twice.
        return Vec::new();
    };

    if silence {
        session.page_dialogs.silence(dialog.tab);
    }

    // Picking nothing is a cancel, not an empty selection. An empty list handed
    // to a file control reads as "clear what was there", which is not what
    // pressing Cancel means.
    let answer = match answer {
        PageDialogAnswer::Chose { paths } if paths.is_empty() => PageDialogAnswer::Cancelled,
        PageDialogAnswer::Chose { paths } => PageDialogAnswer::Chose { paths },
        PageDialogAnswer::Accepted => PageDialogAnswer::Accepted,
        PageDialogAnswer::Typed { text } => PageDialogAnswer::Typed { text },
        PageDialogAnswer::Cancelled => PageDialogAnswer::Cancelled,
    };

    vec![EngineCommand::AnswerPageDialog { request, answer }]
}

// MARK: - What a page asked the machine for

/// Answer the sheet, and the page behind it.
///
/// Two things must be true of every path out of here. The engine is answered
/// exactly once, because it is holding a decision handler and a promise nobody
/// settles is worse than a refusal. And nothing is written down that somebody
/// did not choose — which is why an answer arriving inside
/// [`crate::site_permissions::PROMPT_SETTLE_MS`] leaves with no commands at
/// all, rather than being turned into a refusal a page could have forced.
fn decide_site_permission(
    session: &mut Session,
    request: u64,
    choice: SiteChoice,
    decided_at_ms: u64,
) -> Vec<EngineCommand> {
    let Some(pending) = session.site_permissions.pending() else {
        return Vec::new();
    };
    if pending.request != request {
        // An answer to a question that has already been replaced. Whatever it
        // was about is gone, and the engine has been answered already.
        return Vec::new();
    }
    if crate::site_permissions::answered_too_soon(pending.asked_at_ms, decided_at_ms) {
        // A keystroke that was already on its way down when the page chose to
        // interrupt. The question stays exactly where it is.
        return Vec::new();
    }

    let Some(prompt) = session.site_permissions.take_pending(request) else {
        return Vec::new();
    };
    let Some(space) = session.browser.tab(prompt.tab).map(|t| t.space) else {
        // The tab went between the question and the answer. The page is still
        // owed one.
        return vec![EngineCommand::AnswerSitePermission {
            request,
            decision: SiteDecision::Deny,
        }];
    };
    let capabilities = prompt.capture.capabilities();

    match choice {
        SiteChoice::Allow => {
            for &capability in capabilities {
                session.site_permissions.record(
                    space,
                    &prompt.origin,
                    capability,
                    true,
                    decided_at_ms,
                );
            }
            vec![EngineCommand::AnswerSitePermission {
                request,
                decision: SiteDecision::Allow,
            }]
        }
        SiteChoice::Block => {
            for &capability in capabilities {
                session.site_permissions.record(
                    space,
                    &prompt.origin,
                    capability,
                    false,
                    decided_at_ms,
                );
            }
            let mut out = vec![EngineCommand::AnswerSitePermission {
                request,
                decision: SiteDecision::Deny,
            }];
            // A refusal that only covers the next request would leave a stream
            // this page already holds running behind a row that says "blocked".
            out.extend(stop_capture(session, space, &prompt.origin, capabilities));
            out
        }
        SiteChoice::Dismiss => {
            // Closing a window is not an instruction, so nothing is recorded.
            // But it has to cost the page something, or Escape is a key you
            // hold down while a loop asks again.
            for &capability in capabilities {
                session
                    .site_permissions
                    .mute(prompt.tab, &prompt.origin, capability);
            }
            vec![EngineCommand::AnswerSitePermission {
                request,
                decision: SiteDecision::Deny,
            }]
        }
    }
}

/// Stop every tab in this space that is on this origin from capturing.
///
/// This is what makes taking an answer back reach the engine rather than
/// repaint a row (ADR-0028's `revokingReachesTheContext`, one layer down).
/// Matched on the tab's committed address, because that is what a live stream
/// is attached to — a tab part-way through navigating somewhere else is not
/// the one holding the camera.
fn stop_capture(
    session: &Session,
    space: SpaceId,
    origin: &str,
    capabilities: &[SiteCapability],
) -> Vec<EngineCommand> {
    session
        .browser
        .tabs_in(space)
        .into_iter()
        .filter(|tab| {
            tab.url
                .as_deref()
                .and_then(crate::site_permissions::origin_of)
                .is_some_and(|o| o == origin)
        })
        .flat_map(|tab| {
            capabilities
                .iter()
                .map(move |&capability| EngineCommand::StopCapture {
                    tab: tab.id,
                    capability,
                })
        })
        .collect()
}

/// The engine is holding handlers for a tab that is going away.
///
/// Emitted *before* `DestroyWebView`, so nothing depends on whether the host
/// keeps its handlers beside the view or beside itself.
///
/// **Every kind, at the one door.** A camera prompt left unanswered is a page
/// whose `getUserMedia` promise never settles; a page dialog left unanswered is
/// a page frozen inside `alert()`; an HTTP-auth panel left unanswered is a
/// navigation that — measured — neither finishes nor fails, so the tab holds a
/// white rectangle for as long as the browser is open. They are the same
/// failure and there is one place that prevents it, because a rule enforced at
/// four call sites is three bugs waiting and this one is invisible from the
/// outside.
fn answer_pending_for(session: &mut Session, tab: TabId) -> Vec<EngineCommand> {
    let mut out: Vec<EngineCommand> = session
        .site_permissions
        .drop_pending_for(tab)
        .map(
            |prompt: SitePermissionPrompt| EngineCommand::AnswerSitePermission {
                request: prompt.request,
                decision: SiteDecision::Deny,
            },
        )
        .into_iter()
        .collect();
    out.extend(session.http_auth.drop_pending_for(tab).map(|prompt| {
        EngineCommand::AnswerHttpAuth {
            request: prompt.request,
            decision: AuthDecision::Cancel,
        }
    }));
    session.certificate_reports.remove(&tab);
    out.extend(cancel_dialogs_for(session, tab));
    session.page_dialogs.forget_tab(tab);
    // Not a handler, and here because this is the one place a tab leaving the
    // model already converges. Where it has been is worth up to a megabyte
    // (see [`crate::navigation_state`]), it can never be handed to a view
    // again, and the alternative is remembering to forget it at each of the
    // three places a tab is closed.
    session.navigation_states.forget(tab);
    out
}

/// Tell every page this tab is holding a question for that the answer is no.
///
/// Cancelled rather than accepted, everywhere: `confirm()` hears false and
/// `prompt()` hears nothing typed, which is what the person's *absence* means.
/// The one thing that must not happen is silence.
fn cancel_dialogs_for(session: &mut Session, tab: TabId) -> Vec<EngineCommand> {
    session
        .page_dialogs
        .take_all_for(tab)
        .into_iter()
        .map(|dialog| EngineCommand::AnswerPageDialog {
            request: dialog.request,
            answer: PageDialogAnswer::Cancelled,
        })
        .collect()
}

// MARK: - Chat

/// What the model is told when the browser will not run something it asked for.
///
/// Written for a model rather than for a person, which is why it lives here
/// with the protocol and not in a shell: it is part of the conversation, and
/// two platforms telling a model two different things about the same refusal
/// would produce two different answers.
const REFUSED_BY_PERSON: &str = "The person declined this tool call. Do not retry it.";

/// The same, when nothing was ever asked because there was nothing to ask about.
const REFUSED_UNKNOWN_TOOL: &str =
    "zer0 has no such tool configured, so it was not run and nobody was asked.";

/// The same again, when the tool exists but the program behind it does not.
///
/// A separate sentence from [`REFUSED_UNKNOWN_TOOL`] because they suggest
/// different next moves: one means the model invented a name, the other means
/// it did not and the tool may work in a minute.
const REFUSED_SERVER_DOWN: &str =
    "That tool's server is not connected, so it was not run and nobody was asked.";

/// Open a conversation, and ask it something if a question came with it.
///
/// Which tab "the page you are on" means is resolved here rather than by
/// whoever handled the key press, and so is what happens when there is no page:
/// the question still lands somewhere, because ⌘E that does nothing is the one
/// outcome nobody wants — the same rule ADR-0019 applies to ⌘L.
fn open_chat(
    session: &mut Session,
    about: ChatSubject,
    question: Option<String>,
) -> Vec<EngineCommand> {
    let now = session.browser.now_ms();

    // ⌘E while a conversation is already the page you are on means *that*
    // conversation. Without this, "the page you are on" resolves to the chat
    // tab itself and every press starts a new thread about the thread — which
    // is what happened the first time a conversation became a tab (ADR-0054).
    if about == ChatSubject::CurrentPage
        && let Some(existing) = conversation_shown_by_active_tab(session)
    {
        let mut out = show_conversation(session, existing);
        if let Some(text) = question {
            out.extend(ask(session, existing, text));
        }
        return out;
    }

    let scope = match about {
        ChatSubject::Page { tab } => match scope_of_tab(session, tab) {
            Some(scope) => scope,
            // A tab that is not there names no page and no space. Refuse rather
            // than repair: opening a thread about the active tab instead would
            // be a thread about a page nobody asked about.
            None => return Vec::new(),
        },
        ChatSubject::CurrentPage => match session.browser.active_tab().and_then(|tab| {
            // A tab is how "the page you are on" is *found*; it is not what the
            // thread is about. Once the address is in hand the tab has done its
            // job, which is why closing it later changes nothing.
            scope_of_tab(session, tab)
        }) {
            Some(scope) => scope,
            None => ConversationScope::Space {
                space: session.browser.active_space(),
            },
        },
        // A question typed into the command bar is not about whatever happened
        // to be open. Attaching that page would send something nobody
        // mentioned to a provider.
        ChatSubject::Nothing => ConversationScope::Space {
            space: session.browser.active_space(),
        },
    };

    let conversation = session.chat.ensure(scope, now);
    let mut out = show_conversation(session, conversation);
    if let Some(text) = question {
        out.extend(ask(session, conversation, text));
    }
    out
}

/// Start a second thread about whatever `like` is about.
fn start_another(session: &mut Session, like: ConversationId) -> Vec<EngineCommand> {
    let Some(scope) = session.chat.get(like).map(|c| c.scope.clone()) else {
        return Vec::new();
    };
    let now = session.browser.now_ms();
    let started = session.chat.start(scope, now);
    switch_to_conversation(session, started)
}

/// Put a thread on screen, taking over the chat tab somebody is already looking
/// at rather than opening another beside it.
///
/// Moving between the threads about one page happens *inside* a chat tab, so
/// this is the one entry that re-points instead of opening: a second tab per
/// thread visited would turn "which of these three conversations did I mean" —
/// the question the list exists to answer — into three tabs answering it at
/// once. ⌘E does not come through here, so what that chord opens is unchanged.
fn switch_to_conversation(
    session: &mut Session,
    conversation: ConversationId,
) -> Vec<EngineCommand> {
    if session.chat.get(conversation).is_none() {
        return Vec::new();
    }
    let already_shown_elsewhere = session
        .browser
        .all_tabs()
        .iter()
        .any(|t| conversation_shown_by_url(t.url.as_deref()) == Some(conversation));

    if !already_shown_elsewhere
        && let Some(active) = session.browser.active_tab()
        && conversation_shown_by(session, active).is_some()
        && let Some(t) = session.browser.tab_mut(active)
    {
        t.url = Some(
            internal_url::InternalAddress::Chat {
                conversation: Some(conversation),
            }
            .url(),
        );
        return Vec::new();
    }
    show_conversation(session, conversation)
}

/// What a thread opened from this tab is about.
///
/// `None` only when the tab does not exist. A tab showing nothing anchorable —
/// a blank tab, a `data:` URL, one of the browser's own pages — resolves to its
/// space's thread, which is the honest answer: there is no page here, so the
/// question is about no page in particular.
///
/// The one place a tab becomes a subject. Every entry into chat comes through
/// here, so what "the page you are on" means cannot drift between them.
fn scope_of_tab(session: &Session, tab: TabId) -> Option<ConversationScope> {
    let t = session.browser.tab(tab)?;
    let space = t.space;
    let anchored = t
        .url
        .as_deref()
        .and_then(chat::PageAnchor::of)
        .map(|page| ConversationScope::Page { space, page });
    Some(anchored.unwrap_or(ConversationScope::Space { space }))
}

/// A tab in `space` currently showing this page, if one is.
///
/// The thread is anchored to an address rather than to a view of it, so any tab
/// showing the page will do and the one it was opened from has no standing.
/// `None` is a real answer and not a failure: the page is simply not open, and
/// nothing will be read for the next question.
fn tab_showing(session: &Session, space: SpaceId, page: &chat::PageAnchor) -> Option<TabId> {
    session
        .browser
        .tabs_in(space)
        .iter()
        .find(|t| t.url.as_deref().is_some_and(|url| page.matches(url)))
        .map(|t| t.id)
}

/// The conversation the active tab is already showing, if it is showing one.
fn conversation_shown_by_active_tab(session: &Session) -> Option<ConversationId> {
    conversation_shown_by(session, session.browser.active_tab()?)
}

/// The conversation this tab is showing, if it is a chat tab addressing one.
///
/// `Some` only for a thread that still exists: a chat tab whose conversation
/// was cleared is addressing nothing, and ⌘E there should start a thread rather
/// than resolve to a dead id.
fn conversation_shown_by(session: &Session, tab: TabId) -> Option<ConversationId> {
    let id = conversation_shown_by_url(session.browser.tab(tab)?.url.as_deref())?;
    session.chat.get(id).map(|c| c.id)
}

/// The conversation a URL addresses, whether or not that thread still exists.
fn conversation_shown_by_url(url: Option<&str>) -> Option<ConversationId> {
    let url = url?;
    match internal_url::parse(url)? {
        internal_url::InternalAddress::Chat {
            conversation: Some(id),
        } => Some(id),
        internal_url::InternalAddress::Chat { conversation: None }
        | internal_url::InternalAddress::Settings
        | internal_url::InternalAddress::History
        | internal_url::InternalAddress::Downloads => None,
    }
}

/// Put a conversation on screen, in a tab of its own.
///
/// A conversation is a tab because everything a person already knows how to do
/// with a tab is something they want to do with a thread: pin it, put it beside
/// the page it is about, close it with ⌘W, find it again after a restart
/// (ADR-0054).
///
/// Pressing ⌘E twice does not open a second tab. `Chat::ensure` already hands
/// back the same conversation, and this hands back the same tab — two tabs
/// showing one thread would be two views of one state, and the one that is
/// stale is always the one being read.
fn show_conversation(session: &mut Session, conversation: ConversationId) -> Vec<EngineCommand> {
    let url = internal_url::InternalAddress::Chat {
        conversation: Some(conversation),
    }
    .url();

    // Anywhere in the browser, not just this space: the thread is already
    // isolated to one space by its scope, so a tab showing it cannot be in the
    // wrong one — and hunting it down beats opening a duplicate.
    if let Some(existing) = session
        .browser
        .all_tabs()
        .iter()
        .find(|t| t.url.as_deref() == Some(url.as_str()))
        .map(|t| t.id)
    {
        let space = session.browser.tab(existing).map(|t| t.space);
        if let Some(space) = space {
            session.browser.set_active_space(space);
        }
        session.browser.set_active_tab(Some(existing));
        return vec![EngineCommand::FocusWebView { tab: existing }];
    }

    // A tab sitting on the bare `zer0://chat` is a chat page that has not been
    // given a thread yet — the empty state somebody just typed their first
    // question into. It becomes this thread rather than being left behind while
    // a second tab opens beside it holding the answer.
    if let Some(active) = session.browser.active_tab()
        && session
            .browser
            .tab(active)
            .and_then(|t| t.url.as_deref())
            .and_then(internal_url::parse)
            == Some(internal_url::InternalAddress::Chat { conversation: None })
    {
        if let Some(t) = session.browser.tab_mut(active) {
            t.url = Some(url);
        }
        return Vec::new();
    }

    // The space the thread belongs to, never the active one. A conversation
    // carries page text and typed questions, which is the material every space
    // has its own cookie jar for (ADR-0007) — a tab drawing it from another
    // space would put a work page in front of a personal one.
    let space = session
        .chat
        .get(conversation)
        .map_or_else(|| session.browser.active_space(), |c| c.scope.space());
    open_in(session, space, Some(url), None)
}

/// Put a question to a conversation, reading the page first if it is about one.
fn ask(session: &mut Session, conversation: ConversationId, text: String) -> Vec<EngineCommand> {
    let text = text.trim().to_string();
    if text.is_empty() {
        return Vec::new();
    }
    let now = session.browser.now_ms();

    let Some(existing) = session.chat.get(conversation) else {
        return Vec::new();
    };
    // A thread already working does not take a second question: two replies
    // writing into one transcript interleave, and neither is readable.
    if existing.is_busy() {
        return Vec::new();
    }
    let scope = existing.scope.clone();

    if let Some(c) = session.chat.get_mut(conversation) {
        // Another attempt is under way, so the previous failure is no longer
        // what this thread is showing.
        c.error = None;
    }
    session
        .chat
        .append(conversation, MessageRole::User, text, now);

    if let Some(tab) = page_worth_attaching(session, conversation, &scope) {
        if let Some(c) = session.chat.get_mut(conversation) {
            c.awaiting_page = true;
        }
        return vec![EngineCommand::CapturePageContext {
            conversation,
            tab,
            max_chars: chat::MAX_PAGE_CONTEXT_CHARS,
        }];
    }
    advance(session, conversation)
}

/// The tab whose page should be attached before this question is sent, if any.
///
/// `None` for a thread that is about no page, for a page that no tab is
/// currently showing, and for a page this thread has already been told about —
/// asking a follow-up about the same page must not re-read and re-send it.
///
/// **A thread whose page is not open reads nothing, and says nothing instead.**
/// That is the honest shape of a conversation revisited a week later: the
/// address is a fact, whatever is at it today is not, and inventing a capture
/// out of a tab that happens to be in front of somebody would answer about a
/// page nobody mentioned.
///
/// One of the browser's own pages never reaches here, because
/// [`chat::PageAnchor`] refuses `zer0://` outright: there is no document behind
/// an internal page — it is drawn natively — so a capture would come back empty
/// at best, and at worst a future internal page would quietly start posting its
/// own contents to a provider. ADR-0054 wrote that as a guard; it is now a
/// scheme that cannot be anchored, which is the same rule with nothing left to
/// delete.
fn page_worth_attaching(
    session: &Session,
    conversation: ConversationId,
    scope: &ConversationScope,
) -> Option<TabId> {
    let ConversationScope::Page { space, page } = scope else {
        return None;
    };
    let tab = tab_showing(session, *space, page)?;
    let url = session.browser.tab(tab)?.url.clone()?;
    let already = session
        .chat
        .get(conversation)
        .and_then(Conversation::last_page)
        .map(|p| p.url.clone());

    (already.as_deref() != Some(url.as_str())).then_some(tab)
}

/// The page came back. Put it in front of the question and get on with it.
fn page_captured(
    session: &mut Session,
    conversation: ConversationId,
    url: String,
    title: String,
    text: String,
) -> Vec<EngineCommand> {
    let now = session.browser.now_ms();
    let id = session.chat.next_message_id();

    let Some(c) = session.chat.get_mut(conversation) else {
        return Vec::new();
    };
    // Not waiting for this any more: the question was cancelled, or answered
    // without it. Filing it now would attach a page to whatever came next.
    if !c.awaiting_page {
        return Vec::new();
    }
    c.awaiting_page = false;

    let mut message = Message::page(id, text, now);
    // The address and the title come from the capture rather than from the
    // tab, because the tab may have navigated while the page was being read
    // and the text in hand belongs to the page that was read.
    message.page = Some(PageReference { url, title });
    c.insert_page_before_question(message);

    advance(session, conversation)
}

/// Ask a provider for the next reply, if this thread is waiting for one.
///
/// The one place a request is made, so the round bound and the assistant
/// message are impossible to route around.
fn advance(session: &mut Session, conversation: ConversationId) -> Vec<EngineCommand> {
    let now = session.browser.now_ms();
    let Some(c) = session.chat.get(conversation) else {
        return Vec::new();
    };
    if !c.wants_a_reply() {
        return Vec::new();
    }
    // One question, one bound. A model that calls a tool, reads the answer and
    // calls it again is otherwise an unattended loop spending someone's money.
    if c.rounds_since_user() >= chat::MAX_TOOL_ROUNDS {
        if let Some(c) = session.chat.get_mut(conversation) {
            c.error = Some(ChatError {
                kind: ChatErrorKind::ToolLoop,
                detail: String::new(),
            });
        }
        return Vec::new();
    }

    let transcript = c.messages.clone();
    // What may be offered, which is not everything that exists. A tool
    // somebody refused is not described to the model at all: describing it and
    // refusing the call afterwards would burn a turn, disclose that the tool
    // exists, and teach the model to keep asking (ADR-0050).
    let tools = session.mcp.offerable(session.chat.consent());
    let Some(message) =
        session
            .chat
            .append(conversation, MessageRole::Assistant, String::new(), now)
    else {
        return Vec::new();
    };
    vec![EngineCommand::StartChatReply {
        conversation,
        message,
        transcript,
        tools,
    }]
}

/// Whether this tool may be called, and on what terms.
///
/// **The only door.** Every path that could put a tool call in front of a host
/// asks this first, and there is deliberately no second way to reach the same
/// answer: the ledger says whether a tool was approved, the register says what
/// was approved, and only [`McpRegistry::verdict`] holds both at once. Reading
/// the ledger alone gives an answer keyed by name — which is exactly the
/// answer a server that redefined its tool would like everyone to use.
///
/// [`McpRegistry::verdict`]: crate::mcp::McpRegistry::verdict
fn tool_verdict(session: &Session, server: &str, tool: &str) -> ToolVerdict {
    session.mcp.verdict(session.chat.consent(), server, tool)
}

/// The model wants a tool run. Nothing runs because of that alone.
fn tool_call_requested(
    session: &mut Session,
    message: MessageId,
    invocation: ToolInvocation,
) -> Vec<EngineCommand> {
    let now = session.browser.now_ms();
    let Some(conversation) = session.chat.conversation_of_message(message) else {
        return Vec::new();
    };
    let verdict = tool_verdict(session, &invocation.server, &invocation.tool);

    let invocation = ToolInvocation {
        id: invocation.id,
        server: invocation.server,
        tool: invocation.tool,
        arguments: chat::clamp_payload(invocation.arguments),
    };
    let id = invocation.id.clone();

    let (state, result) = match verdict {
        ToolVerdict::Approved => (ToolCallState::Running, String::new()),
        // Nobody has answered, or what they answered was about a different
        // tool. Both put the arguments on screen and wait; only the sentence
        // beside them differs, and that sentence is the shell's.
        ToolVerdict::MustConfirm | ToolVerdict::Changed => {
            (ToolCallState::AwaitingConsent, String::new())
        }
        // The browser will not run a tool it cannot name. Consenting to
        // something nobody could describe is not consent, which is the rule
        // ADR-0028 already applies to a match pattern nobody could parse.
        ToolVerdict::Unknown => (ToolCallState::Refused, REFUSED_UNKNOWN_TOOL.to_string()),
        ToolVerdict::NotReady => (ToolCallState::Refused, REFUSED_SERVER_DOWN.to_string()),
        ToolVerdict::Refused => (ToolCallState::Refused, REFUSED_BY_PERSON.to_string()),
    };

    let Some(c) = session.chat.get_mut(conversation) else {
        return Vec::new();
    };
    // A call already known by this id is a repeat, and running it twice is
    // running it twice.
    if c.find_call_mut(&id).is_some() {
        return Vec::new();
    }
    let Some(target) = c.message_mut(message) else {
        return Vec::new();
    };
    // Late traffic for a reply that already stopped.
    if !target.is_in_flight() {
        return Vec::new();
    }
    if target.tool_calls.len() >= chat::MAX_TOOL_CALLS_PER_REPLY {
        return Vec::new();
    }
    target.tool_calls.push(ToolCall {
        invocation: invocation.clone(),
        state,
        result: result.clone(),
        requested_at_ms: now,
    });

    match state {
        ToolCallState::Running => vec![EngineCommand::RunToolCall {
            conversation,
            invocation,
        }],
        // A refusal is still an answer the model has to be given, so it is
        // filed as a result rather than left as a gap in the transcript.
        ToolCallState::Refused => {
            record_tool_result(session, conversation, &id, result);
            Vec::new()
        }
        ToolCallState::AwaitingConsent
        | ToolCallState::Completed
        | ToolCallState::Failed
        | ToolCallState::Cancelled => Vec::new(),
    }
}

/// Somebody answered a consent prompt.
fn decide_tool_call(
    session: &mut Session,
    call: &ToolCallId,
    decision: ConsentChoice,
) -> Vec<EngineCommand> {
    let now = session.browser.now_ms();
    let Some(conversation) = session.chat.conversation_of_call(call) else {
        return Vec::new();
    };
    let Some(c) = session.chat.get_mut(conversation) else {
        return Vec::new();
    };
    let Some(target) = c.find_call_mut(call) else {
        return Vec::new();
    };
    // Only a call that is actually waiting can be answered. Deciding one that
    // already ran would run it a second time.
    if target.state != ToolCallState::AwaitingConsent {
        return Vec::new();
    }
    let invocation = target.invocation.clone();

    let allow = matches!(decision, ConsentChoice::Once | ConsentChoice::Always);
    // Remembered per tool and never per server. Approving a server is
    // approving tools it has not published yet.
    //
    // Both halves in one call: the answer and the shape it was given about.
    // A remembered *yes* recorded without a shape would read as `Changed` on
    // the next call and re-ask forever; a path that wrote only the ledger row
    // is the one that would fail open if `verdict` ever stopped checking.
    match decision {
        ConsentChoice::Always => {
            session.remember_tool_answer(&invocation.server, &invocation.tool, true, now);
        }
        ConsentChoice::Never => {
            session.remember_tool_answer(&invocation.server, &invocation.tool, false, now);
        }
        ConsentChoice::Once | ConsentChoice::Refuse => {}
    }

    if !allow {
        return settle_call(
            session,
            call,
            ToolCallState::Refused,
            REFUSED_BY_PERSON.to_string(),
        );
    }

    // Asked again after the answer, not instead of it. Between the prompt going
    // up and somebody pressing a key the server can have died, been switched
    // off in Settings, or published a different tool under the same name — and
    // a yes about a tool that is no longer there is a yes about nothing. This
    // is the second of the two doors, and it is the same door.
    let verdict = tool_verdict(session, &invocation.server, &invocation.tool);
    let refusal = match verdict {
        ToolVerdict::Unknown => Some(REFUSED_UNKNOWN_TOOL),
        ToolVerdict::NotReady => Some(REFUSED_SERVER_DOWN),
        ToolVerdict::Refused => Some(REFUSED_BY_PERSON),
        // Answered just now, about the tool as it is right now.
        ToolVerdict::Approved | ToolVerdict::MustConfirm | ToolVerdict::Changed => None,
    };
    if let Some(result) = refusal {
        return settle_call(session, call, ToolCallState::Refused, result.to_string());
    }

    if let Some(c) = session.chat.get_mut(conversation)
        && let Some(target) = c.find_call_mut(call)
    {
        target.state = ToolCallState::Running;
    }
    vec![EngineCommand::RunToolCall {
        conversation,
        invocation,
    }]
}

/// A tool call reached its end, whatever kind of end that was.
fn settle_call(
    session: &mut Session,
    call: &ToolCallId,
    state: ToolCallState,
    result: String,
) -> Vec<EngineCommand> {
    let Some(conversation) = session.chat.conversation_of_call(call) else {
        return Vec::new();
    };
    let result = chat::clamp_payload(result);
    let Some(c) = session.chat.get_mut(conversation) else {
        return Vec::new();
    };
    let Some(target) = c.find_call_mut(call) else {
        return Vec::new();
    };
    // A result for a call that already stopped is ordinary late traffic.
    if target.state.is_settled() {
        return Vec::new();
    }
    target.state = state;
    target.result = result.clone();

    record_tool_result(session, conversation, call, result);
    advance(session, conversation)
}

/// File what a tool answered as a turn in the conversation.
fn record_tool_result(
    session: &mut Session,
    conversation: ConversationId,
    call: &ToolCallId,
    result: String,
) {
    let now = session.browser.now_ms();
    let Some(id) = session
        .chat
        .append(conversation, MessageRole::ToolResult, result, now)
    else {
        return;
    };
    if let Some(c) = session.chat.get_mut(conversation)
        && let Some(m) = c.message_mut(id)
    {
        m.answers = Some(call.clone());
    }
}

/// The reply is over. Whether anything follows depends on what it asked for.
fn reply_finished(
    session: &mut Session,
    message: MessageId,
    stop: ReplyStop,
) -> Vec<EngineCommand> {
    let Some(conversation) = session.chat.conversation_of_message(message) else {
        return Vec::new();
    };
    let Some(m) = find_message_mut(session, message) else {
        return Vec::new();
    };
    if !m.is_in_flight() {
        return Vec::new();
    }
    m.state = match stop {
        ReplyStop::EndOfTurn | ReplyStop::ToolCalls => MessageState::Complete,
        // The provider cut it off. Drawing that as a finished answer is the
        // interface asserting something it cannot back up (ADR-0018).
        ReplyStop::MaxTokens => MessageState::Truncated,
    };

    match stop {
        // A cut-off answer is not carried on with. Continuing would be the
        // browser deciding to spend more of someone's budget without being
        // asked; the person can ask again, and now they know why.
        ReplyStop::MaxTokens => Vec::new(),
        ReplyStop::EndOfTurn | ReplyStop::ToolCalls => advance(session, conversation),
    }
}

/// The provider could not produce a reply.
fn chat_failed(
    session: &mut Session,
    conversation: ConversationId,
    message: Option<MessageId>,
    kind: ChatErrorKind,
    detail: String,
) -> Vec<EngineCommand> {
    let mut out = Vec::new();
    if let Some(message) = message
        && let Some(m) = find_message_mut(session, message)
        && m.is_in_flight()
    {
        m.state = MessageState::Failed;
        // Calls it had already asked for are moot: there is no turn left for
        // their answers to go into.
        out.extend(abandon_calls(m));
    }
    if let Some(c) = session.chat.get_mut(conversation) {
        c.awaiting_page = false;
        c.error = Some(ChatError { kind, detail });
    }
    out
}

/// Stop everything a conversation has in flight, keeping what already arrived.
fn cancel_chat(session: &mut Session, conversation: ConversationId) -> Vec<EngineCommand> {
    let Some(c) = session.chat.get_mut(conversation) else {
        return Vec::new();
    };
    // Reading a page is something in flight too. Without this, Escape during
    // a capture leaves a thread that never sends and never says why.
    c.awaiting_page = false;

    let mut out = Vec::new();
    for message in &mut c.messages {
        if message.is_in_flight() {
            message.state = MessageState::Cancelled;
            out.push(EngineCommand::CancelChatReply {
                message: message.id,
            });
        }
        out.extend(abandon_calls(message));
    }
    out
}

/// Mark every unfinished call on a message cancelled, and stop the ones that
/// were running.
///
/// A call still waiting on somebody is cancelled without ever being asked
/// about, because the reply it belonged to is gone: a prompt for a turn that
/// no longer exists is a prompt whose Yes does nothing anyone can see.
fn abandon_calls(message: &mut Message) -> Vec<EngineCommand> {
    let mut out = Vec::new();
    for call in &mut message.tool_calls {
        match call.state {
            ToolCallState::Running => {
                call.state = ToolCallState::Cancelled;
                out.push(EngineCommand::CancelToolCall {
                    call: call.invocation.id.clone(),
                });
            }
            ToolCallState::AwaitingConsent => call.state = ToolCallState::Cancelled,
            ToolCallState::Completed
            | ToolCallState::Failed
            | ToolCallState::Refused
            | ToolCallState::Cancelled => {}
        }
    }
    out
}

/// Every conversation these tabs own, stopped and forgotten.
///
/// A conversation about a page is over when the page is: nothing in the
/// interface can reach it any more, and a reply still arriving for it would be
/// bytes paid for and thrown away.
fn end_conversations(session: &mut Session, ids: &[ConversationId]) -> Vec<EngineCommand> {
    let mut out = Vec::new();
    for id in ids {
        out.extend(cancel_chat(session, *id));
        session.chat.remove(*id);
    }
    out
}

fn find_message_mut(session: &mut Session, message: MessageId) -> Option<&mut Message> {
    let conversation = session.chat.conversation_of_message(message)?;
    session.chat.get_mut(conversation)?.message_mut(message)
}

/// Work out whether this page's icon is worth going and getting.
///
/// Every refusal in here is the point of the function rather than a guard on
/// the way to the interesting part:
///
/// - **An ephemeral space fetches nothing.** ADR-0023 keeps that promise at
///   the write; a favicon request is a *network* write, seen by the site, and
///   it has to be refused here rather than hidden in the interface. It is the
///   case ADR-0023 named in advance — "a favicon store" — as the next place
///   the promise would have to be spelled out.
/// - **A page with no site on the web is not asked about.** `about:blank` and
///   a local file have nothing to fetch from.
/// - **A site we already have, or already asked about, is left alone.**
fn declare_icons(
    session: &mut Session,
    tab: TabId,
    candidates: &[icons::IconCandidate],
) -> Vec<EngineCommand> {
    let Some(t) = session.browser.tab(tab) else {
        return Vec::new();
    };
    let Some(page_url) = t.url.clone() else {
        return Vec::new();
    };
    let space = t.space;

    if !session.browser.records_to_disk(space) {
        return Vec::new();
    }
    let Some(data_store_id) = session
        .browser
        .space(space)
        .map(|s| s.data_store_id.clone())
    else {
        return Vec::new();
    };
    let Some(host) = icons::host_of(&page_url) else {
        return Vec::new();
    };

    let key = icons::IconKey::new(&data_store_id, &host);
    let now = session.browser.now_ms();
    if !session.icons.wants(&key, now) {
        return Vec::new();
    }
    let Some(url) = icons::choose(candidates, &page_url) else {
        return Vec::new();
    };

    session.icons.begin(key);
    vec![EngineCommand::FetchIcon {
        data_store_id,
        host,
        url,
        max_bytes: icons::MAX_ICON_BYTES,
    }]
}

/// Open a tab in `space`, focus it, and start loading if a URL was given.
fn open_in(
    session: &mut Session,
    space: SpaceId,
    url: Option<String>,
    parent: Option<TabId>,
) -> Vec<EngineCommand> {
    let tab = session.browser.insert_tab(space, TabKind::Today, parent);
    // The tab is told where it is going *before* its view is built, and that is
    // not tidiness. A view is bound to the configuration it was made with, and
    // a page belonging to an extension needs one built from that extension's;
    // a tab that opened blank and was pointed at the address a line later would
    // have its view torn down and built again inside this one dispatch. The
    // navigation below writes the same field again, which is why this reads as
    // removable and is not.
    //
    // Aimed only where the navigation will really go. An address about to be
    // refused must not decide what this view is built from, or a refusal would
    // leave a tab holding a view built for an extension it was never allowed to
    // reach.
    if let Some(url) = url.as_deref()
        && !refuses_extension_page(session, tab, url)
        && let Some(t) = session.browser.tab_mut(tab)
    {
        t.pending_url = Some(url.to_string());
    }
    let mut out = vec![create_view(session, tab)];

    if let Some(url) = url {
        out.extend(start_navigation(session, tab, url));
    }
    session.browser.set_active_tab(Some(tab));
    out.push(EngineCommand::FocusWebView { tab });
    out
}

/// A page asked for a view of its own, and the engine already built it.
///
/// Three things are decided here, and none of them by the host.
///
/// **The space is the opener's**, read off the tab that asked rather than off
/// whatever is active. A page in an ephemeral space whose pop-up landed in a
/// persistent one would write a private session's cookies to disk, which is
/// the leak ADR-0007 and ADR-0065 both exist to prevent — and the answer must
/// not depend on which space happened to be in front when the page ran.
///
/// **The window is the opener's**, for the same shape of reason: the page that
/// asked is the one somebody is looking at.
///
/// **What the page asked for decides tab or window**, from what it stated
/// rather than from a guess. See [`WindowRequest::asked_for_a_window`].
///
/// No `LoadUrl` comes out of this, and that is not an omission. The engine
/// navigates the view it made as soon as the host hands it back — measured —
/// so a load from here would be a second visit, and a second visit to a
/// single-use OAuth address is a flow that fails on the screen rather than in
/// a log.
fn open_from_page(
    session: &mut Session,
    opener: TabId,
    request: WindowRequest,
) -> Vec<EngineCommand> {
    // Refuse rather than repair. A page whose tab has gone has nothing left to
    // say where its window belongs, and falling back to the active space would
    // choose a cookie jar on its behalf.
    let Some(page) = session.browser.tab(opener) else {
        return Vec::new();
    };
    let space = page.space;
    let opener_window = page.window;

    let mut out = Vec::new();
    if request.asked_for_a_window() {
        let Some(window) = session.browser.add_window(space) else {
            return Vec::new();
        };
        session.browser.set_key_window(window);
        out.push(EngineCommand::OpenBrowserWindow { window });
    } else {
        // `insert_tab` puts a tab in the key window, so the key window has to
        // move first — the same ordering `open_window` depends on, one
        // direction along. The window that must receive this is the one holding
        // the page that asked, and not whichever was in front: a pop-up landing
        // in a window the person is not looking at is a flow they cannot
        // finish and cannot see.
        session.browser.set_key_window(opener_window);
    }

    let tab = session
        .browser
        .insert_tab(space, TabKind::Today, Some(opener));
    if let Some(t) = session.browser.tab_mut(tab) {
        // The one thing this records, and the only thing it is read for: a
        // script may close this tab later. See `close_from_page`.
        t.opened_by_page = true;
    }
    session.browser.set_active_tab(Some(tab));
    out.push(EngineCommand::AdoptWebView { tab });
    out.push(EngineCommand::FocusWebView { tab });
    out
}

/// A page called `window.close()`.
///
/// **Only a tab a page opened.** The engine's own gate is wider than that:
/// measured on WebKit, a view whose back-forward list holds a single entry can
/// close itself whoever opened it — so a page you typed the address of, in a
/// tab you opened, can make that tab disappear. Safari inherits that; this does
/// not. A tab vanishing under somebody is a loss no key brings back, and
/// `opened_by_page` is a fact this browser already has.
///
/// A page that is refused is not told, because there is nothing to tell it:
/// `window.close()` returns nothing and reports nothing on any browser.
fn close_from_page(session: &mut Session, tab: TabId) -> Vec<EngineCommand> {
    let Some(page) = session.browser.tab(tab).filter(|t| t.opened_by_page) else {
        return Vec::new();
    };
    let window = page.window;

    // The window goes with the page when the page was the only thing in it.
    // Closing only the tab would leave an empty frame with no page in it and
    // no tab to press — and for a window a page opened, that frame is the
    // whole of what somebody saw. Guarded on there being another window,
    // because `close_window` refuses the last one and would leave the tab
    // open with nothing having happened.
    if session.browser.windows().len() > 1 && session.browser.tabs_in_window_all(window).len() == 1
    {
        return close_window(session, window);
    }
    close_tabs(session, &[tab])
}

/// Somebody chose one of our rows in the engine's context menu.
///
/// **The row is checked against the target it was drawn for.** Nothing here
/// trusts that the host asked for something the menu offered: `additions_for`
/// is the one place that decides what a target earns, so asking it again is how
/// a row that was never on offer is refused rather than performed. Without it,
/// a host that sent `OpenLinkInNewTab` for a target with no link would reach
/// the fall-through below, and a host that sent it for a `zer0://` link would
/// reach one of the browser's own addresses through a door ADR-0054 closed.
///
/// **The space is the tab's, and never `active_space`.** Exactly the reasoning
/// in [`open_from_page`]: the page that was right-clicked is the one somebody
/// is looking at, and a link from an ephemeral space opening in a persistent
/// one would write a private session's cookies to disk.
///
/// **The window is the tab's**, set before anything is inserted, because
/// `insert_tab` puts a tab in the key window. Right-clicking almost always
/// makes that window key already; "almost always" is what ADR-0075 learned not
/// to build on.
fn choose_page_menu_item(
    session: &mut Session,
    tab: TabId,
    item: PageMenuItem,
    target: &PageTarget,
) -> Vec<EngineCommand> {
    let Some(page) = session.browser.tab(tab) else {
        return Vec::new();
    };
    let (space, window) = (page.space, page.window);

    if !page_menu::additions_for(target).contains(&item) {
        return Vec::new();
    }

    match item {
        PageMenuItem::OpenLinkInNewTab | PageMenuItem::OpenImageInNewTab => {
            let Some(url) = page_menu::address_for(item, target) else {
                return Vec::new();
            };
            session.browser.set_key_window(window);
            // Through `OpenTab` rather than around it. That road already routes
            // an address to the space that owns it (ADR-0026) and already
            // refuses one of ours, and a second road would be a second answer.
            dispatch(
                session,
                Action::OpenTab {
                    space: Some(space),
                    url: Some(url),
                    parent: Some(tab),
                },
            )
        }

        PageMenuItem::OpenLinkInNewWindow => {
            let Some(url) = page_menu::address_for(item, target) else {
                return Vec::new();
            };
            let Some(opened) = session.browser.add_window(space) else {
                return Vec::new();
            };
            // The key window moves first, before anything is inserted — the
            // same ordering `open_window` and `open_from_page` both depend on.
            session.browser.set_key_window(opened);
            let mut out = vec![EngineCommand::OpenBrowserWindow { window: opened }];
            // No `parent`: the tab tree is drawn per window, and a child whose
            // parent is in another window is a row pointing at nothing.
            out.extend(dispatch(
                session,
                Action::OpenTab {
                    space: Some(space),
                    url: Some(url),
                    parent: None,
                },
            ));
            out
        }

        PageMenuItem::SaveLinkedFile | PageMenuItem::SaveImage => {
            let Some(url) = page_menu::address_for(item, target) else {
                return Vec::new();
            };
            // Through the tab it came from, so the space's cookies come with
            // it — the same reason `RetryDownload` picks a tab (ADR-0027).
            vec![EngineCommand::StartDownload { tab, url }]
        }

        PageMenuItem::SearchForSelection => {
            let Some(text) = page_menu::search_query(target) else {
                return Vec::new();
            };
            // `search_for` rather than `resolve`: the row says "Search for", so
            // selecting the words `example.com` and choosing it must search for
            // them. The URL itself is spelled once, where the command bar
            // spells it.
            let url = url_input::search_for(&text, session.browser.search_template());
            session.browser.set_key_window(window);
            dispatch(
                session,
                Action::OpenTab {
                    space: Some(space),
                    url: Some(url),
                    parent: Some(tab),
                },
            )
        }

        // The engine's own menu carries only Reload, so these two are ours to
        // add — and they go through the same actions ⌘[ and ⌘] do.
        PageMenuItem::Back => guard(session, tab, EngineCommand::GoBack { tab }),
        PageMenuItem::Forward => guard(session, tab, EngineCommand::GoForward { tab }),
    }
}

/// Open a window and seed it with the one tab that makes it usable.
///
/// The key window moves **first**, before anything is inserted. That ordering
/// is load-bearing and reads like an accident: `insert_tab` puts a tab in the
/// key window, so seeding before the move would put the new window's first page
/// in the old window and leave the new one empty.
fn open_window(session: &mut Session, onto: WindowContents) -> Vec<EngineCommand> {
    let space = match onto {
        WindowContents::CurrentSpace => session.browser.active_space(),
        WindowContents::NewPrivateSpace {
            name,
            data_store_id,
        } => {
            let space = session.browser.add_space(name, data_store_id);
            // Ephemeral from the first instant it exists. The host is handed
            // the profile with the first `CreateWebView` below, and a space
            // that was persistent for one dispatch would have a directory on
            // disk that nothing ever points at again.
            session.browser.set_space_profile(
                space,
                SpaceProfile {
                    ephemeral: true,
                    ..SpaceProfile::default()
                },
            );
            space
        }
    };

    let Some(window) = session.browser.add_window(space) else {
        return Vec::new();
    };
    session.browser.set_key_window(window);

    let mut out = vec![EngineCommand::OpenBrowserWindow { window }];
    out.extend(open_in(session, space, None, None));
    out
}

/// Close a window, its tabs, and any private space that only it was showing.
fn close_window(session: &mut Session, window: WindowId) -> Vec<EngineCommand> {
    // What this window was showing, read before it is gone.
    let spaces: Vec<SpaceId> = session
        .browser
        .tabs_in_window_all(window)
        .iter()
        .map(|t| t.space)
        .chain(session.browser.active_space_in(window))
        .collect();

    let Some(orphaned) = session.browser.remove_window(window) else {
        // Refused: this was the last window. Closing it would leave nowhere to
        // draw a page, and the platform's answer to closing the last window is
        // quitting, which is not this action's to decide.
        return Vec::new();
    };

    // The tabs are already gone from the model; the views are not.
    let mut out: Vec<EngineCommand> = Vec::new();
    for tab in &orphaned {
        out.extend(answer_pending_for(session, *tab));
        out.push(EngineCommand::DestroyWebView { tab: *tab });
    }
    out.push(EngineCommand::CloseBrowserWindow { window });

    // A private window's space goes with it, jar and all. Leaving it behind
    // would leave an unreachable cookie jar on disk — the leak ADR-0007 deletes
    // a space's store to avoid — and an empty space in everyone's sidebar
    // saying somebody browsed privately.
    let mut orphan_spaces: Vec<SpaceId> = spaces
        .into_iter()
        .filter(|s| {
            session
                .browser
                .space(*s)
                .is_some_and(|s| s.profile.ephemeral)
                && session.browser.tabs_in(*s).is_empty()
        })
        .collect();
    orphan_spaces.sort_unstable();
    orphan_spaces.dedup();
    for space in orphan_spaces {
        out.extend(dispatch(session, Action::CloseSpace { space }));
    }
    out
}

/// Air traffic: send this URL to the space that owns it.
///
/// The page is reopened rather than moved, because a web view is bound to the
/// cookie jar it was built with. A tab that never went anywhere is closed
/// behind us so routing from a fresh tab does not litter the old space.
fn hand_off(
    session: &mut Session,
    from_tab: TabId,
    target: SpaceId,
    url: String,
) -> Vec<EngineCommand> {
    let was_blank = session
        .browser
        .tab(from_tab)
        .is_some_and(|t| t.url.is_none() && t.kind == TabKind::Today);

    let mut out = Vec::new();
    if was_blank && session.browser.remove_tab(from_tab).is_some() {
        out.push(EngineCommand::DestroyWebView { tab: from_tab });
    }
    out.extend(open_in(session, target, Some(url), None));
    out
}

/// Move a tab, and rebuild its view if that crossed a cookie-jar boundary.
///
/// The single path a move takes, whether it came from the context menu, from a
/// drag, or from anywhere else that grows one later.
fn relocate(session: &mut Session, tab: TabId, space: SpaceId, index: usize) -> Vec<EngineCommand> {
    let from = session.browser.tab(tab).map(|t| t.space);
    if !session.browser.move_tab(tab, space, index) {
        return Vec::new();
    }
    // Crossing a space boundary means a different cookie jar, and a web view
    // cannot change the store it was built with.
    match from {
        Some(from) if from != space => rebuild_view(session, tab),
        _ => Vec::new(),
    }
}

/// Where a dropped tab goes in `space`'s order.
///
/// The dragged tab is discounted, because `move_tab` lifts it out before it
/// puts it back: counting it would land every downward drag one row short.
fn drop_index(
    browser: &Browser,
    tab: TabId,
    space: SpaceId,
    kind: TabKind,
    before: Option<TabId>,
) -> usize {
    let rows: Vec<(TabId, TabKind)> = browser
        .tabs_in(space)
        .iter()
        .filter(|t| t.id != tab)
        .map(|t| (t.id, t.kind))
        .collect();

    if let Some(anchor) = before
        && let Some(at) = rows.iter().position(|(id, _)| *id == anchor)
    {
        return at;
    }
    // Either the drop was past the last row, or it named a row that is not in
    // this space. Both mean the end of the group — and the end of the *group*
    // rather than of the space, so the three sections stay contiguous in the
    // order ⌃Tab and ⌘1..⌘9 walk.
    rows.iter()
        .rposition(|(_, k)| *k == kind)
        .map(|at| at + 1)
        .unwrap_or(rows.len())
}

/// Tear a web view down and build it again, for when the store or profile
/// behind it changed.
fn rebuild_view(session: &mut Session, tab: TabId) -> Vec<EngineCommand> {
    if session.browser.tab(tab).is_none() {
        return Vec::new();
    }
    let mut out = vec![EngineCommand::DestroyWebView { tab }];
    out.extend(create_and_fill_view(session, tab));
    out.extend(restore_view_state(session, tab));
    if session.browser.active_tab() == Some(tab) {
        out.push(EngineCommand::FocusWebView { tab });
    }
    out
}

/// Everything a fresh web view has to be told to look like the tab it is for.
///
/// A `WKWebView` is built at the engine's defaults, and every piece of per-tab
/// state the core holds is a piece the new view does not have. That is not a
/// list to remember at each call site: there are two places a view comes back
/// — [`rehydrate`] at launch and [`rebuild_view`] when the store changed — and
/// a rule enforced at two call sites has one bug waiting (AGENTS.md). This is
/// the one door, so a fourth piece of state added later reaches both.
///
/// It emits only what differs from the engine's own default, so an ordinary
/// tab costs nothing at launch.
///
/// The zoom half is the one that had already gone wrong: `zoom_factor` is
/// persisted and comes back in the model, and nothing pushed it at the view. A
/// tab left at 150% reopened with the core saying 1.5 and the page drawn at
/// 1.0 — a value the interface holds and the screen contradicts, which is the
/// shape ADR-0018 exists to forbid.
fn restore_view_state(session: &Session, tab: TabId) -> Vec<EngineCommand> {
    let Some(t) = session.browser.tab(tab) else {
        return Vec::new();
    };
    let mut out = Vec::new();
    if t.muted {
        out.push(EngineCommand::SetMuted { tab, muted: true });
    }
    // Compared against the engine's default rather than against 1.0 by
    // spelling, so this stays right if the default ever moves.
    if t.zoom_factor != Tab::DEFAULT_ZOOM {
        out.push(EngineCommand::SetZoom {
            tab,
            factor: t.zoom_factor,
        });
    }
    out
}

/// Which extension's context this tab's view has to belong to, if any.
///
/// **The one expression that answers it**, read by both the place a view is
/// built and the place one is replaced, so those two can never disagree about
/// what a tab's view is for. Deriving it rather than storing it is what makes
/// that true: a remembered answer is a second source, and the version that goes
/// wrong is always the one nobody looked at.
///
/// `pending_url` before `url`, because a view has to be built for where the tab
/// is going rather than for where it has been — the address is committed only
/// once the engine has loaded it, and by then the view is long since made.
fn extension_context_of(session: &Session, tab: TabId) -> Option<String> {
    let t = session.browser.tab(tab)?;
    let showing = t.pending_url.as_deref().or(t.url.as_deref())?;
    extension_url::base_host(showing)
}

fn create_view(session: &Session, tab: TabId) -> EngineCommand {
    EngineCommand::CreateWebView {
        tab,
        configuration: view_configuration(session, tab),
        navigation_state: session.navigation_states.get(tab).map(|s| s.to_vec()),
    }
}

/// What this tab's view has to be built from to show what the tab is showing.
fn view_configuration(session: &Session, tab: TabId) -> ViewConfiguration {
    if let Some(base_host) = extension_context_of(session, tab) {
        return ViewConfiguration::Extension { base_host };
    }
    let space = session
        .browser
        .tab(tab)
        .and_then(|t| session.browser.space(t.space));
    ViewConfiguration::Space {
        data_store_id: space.map(|s| s.data_store_id.clone()).unwrap_or_default(),
        profile: space.map(|s| s.profile.clone()).unwrap_or_default(),
    }
}

/// Build a view for a tab that already has a page, and put that page back in
/// it.
///
/// The one door for the two places a view comes back with something already on
/// it — [`rehydrate`] at launch and [`rebuild_view`] when the store changed —
/// because the choice between the two ways of putting a page back is a choice
/// neither of them should be making for itself.
///
/// **A navigation state is a load and a history; a URL is a load.** So when
/// there is a state, that is the whole of it: measured, setting the state and
/// then loading the same address leaves the engine with two entries for one
/// page, and the person's first Back press goes from the page they are reading
/// to the page they are reading. The `LoadUrl` is not lost, it is held: if the
/// engine will not take the state, [`Action::NavigationStateRefused`] brings
/// this tab back here with nothing to restore and it is sent then.
fn create_and_fill_view(session: &Session, tab: TabId) -> Vec<EngineCommand> {
    let create = create_view(session, tab);
    let carries_history = matches!(
        &create,
        EngineCommand::CreateWebView {
            navigation_state: Some(_),
            ..
        }
    );
    let mut out = vec![create];
    if carries_history {
        return out;
    }
    if let Some(url) = session.browser.tab(tab).and_then(|t| t.url.clone())
        && let Some(load) = load_command(tab, url)
    {
        out.push(load);
    }
    out
}

fn focus_entry_tab(session: &mut Session, space: SpaceId) -> Vec<EngineCommand> {
    match session.browser.entry_tab_of(space) {
        Some(tab) => {
            session.browser.set_active_tab(Some(tab));
            vec![EngineCommand::FocusWebView { tab }]
        }
        None => {
            session.browser.set_active_tab(None);
            Vec::new()
        }
    }
}

/// Close a batch of tabs, tearing down their views and refocusing once.
fn close_tabs(session: &mut Session, tabs: &[TabId]) -> Vec<EngineCommand> {
    let active_was_closed = session
        .browser
        .active_tab()
        .is_some_and(|a| tabs.contains(&a));
    // Read the successor before anything is removed, or the neighbour may
    // already be gone when we look for it.
    let successor = session
        .browser
        .active_tab()
        .filter(|_| active_was_closed)
        .and_then(|a| session.browser.successor_of(a))
        .filter(|s| !tabs.contains(s));

    // A thread is about a page, not about a tab, so closing a tab forgets
    // nothing. What it does end is anything still arriving into a thread that
    // has just lost the only view of it: a reply nobody can read is bytes
    // somebody is paying for, which is ADR-0049's sentence with the noun
    // corrected. Read before the tabs go, because a closed tab has no address
    // to resolve a conversation from.
    let mut out: Vec<EngineCommand> = tabs
        .iter()
        .filter_map(|tab| conversation_shown_by(session, *tab))
        .collect::<Vec<_>>()
        .into_iter()
        .flat_map(|id| cancel_chat(session, id))
        .collect();
    let mut removed_any = false;

    for tab in tabs {
        if let Some(removed) = session.browser.remove_tab(*tab) {
            removed_any = true;
            // Remember it so ⇧⌘T has something to bring back. Blank tabs are
            // not worth remembering.
            if removed.url.is_some() {
                session.closed_tabs.push(ClosedTab {
                    url: removed.url,
                    space: removed.space,
                    kind: removed.kind,
                });
                if session.closed_tabs.len() > CLOSED_TAB_MEMORY {
                    session.closed_tabs.remove(0);
                }
            }
            out.extend(answer_pending_for(session, *tab));
            out.push(EngineCommand::DestroyWebView { tab: *tab });
        }
    }
    if !removed_any || !active_was_closed {
        return out;
    }

    match successor {
        Some(next) => {
            session.browser.set_active_tab(Some(next));
            out.push(EngineCommand::FocusWebView { tab: next });
        }
        None => {
            let active = session.browser.active_space();
            out.extend(focus_entry_tab(session, active));
        }
    }
    out
}

/// Command-bar text to a URL, using the configured search engine.
fn resolve(session: &Session, input: &str) -> String {
    match url_input::resolve(input, session.browser.search_template()) {
        Resolved::Navigate(u) | Resolved::Search(u) => u,
    }
}

fn start_navigation(session: &mut Session, tab: TabId, url: String) -> Vec<EngineCommand> {
    if internal_url::claims_scheme(&url) {
        return go_internal(session, tab, &url);
    }

    // Which extension's context this tab's view is in, and which it has to be
    // in. Read *before* the write below, because that write is what moves the
    // second of the two.
    let leaving = extension_context_of(session, tab);
    let arriving = extension_url::base_host(&url);

    if refuses_extension_page(session, tab, &url) {
        return refuse_extension_page(session, tab, &url);
    }

    let Some(t) = session.browser.tab_mut(tab) else {
        return Vec::new();
    };
    t.pending_url = Some(url.clone());
    t.loading_complete = false;
    // Clear here rather than waiting for the engine to report the start: the
    // retry button would otherwise leave its own error screen on the page for
    // as long as the round trip takes.
    t.last_error = None;

    let mut out = Vec::new();
    if leaving != arriving {
        out.extend(reface_view(session, tab));
    }
    out.push(EngineCommand::LoadUrl { tab, url });
    out
}

/// A page belonging to an extension sent itself out of that extension.
///
/// **The crossing is the same crossing**, so it is made in the same place: this
/// hands straight to [`start_navigation`], which compares the two sides,
/// replaces the view, and loads. What is new is only the way in — a navigation
/// the *page* started never reached the reducer at all, so ADR-0104's leaving
/// half held for a person typing an address and not for a link on the page.
///
/// Two conditions, and neither is defensive tidiness:
///
/// - **The tab has to be in an extension's view.** This exists to answer a
///   navigation the engine refused to carry out; a tab already on the web is
///   one where the engine did carry it out, and answering it here would load
///   the address a second time.
/// - **The destination has to be outside that extension.** Two pages of one
///   extension are one context and cost nothing (ADR-0104), and re-entering
///   here would replace the view for a move that never needed one.
///
/// Anything else is ignored rather than repaired: the shell only sends this
/// from the one delegate that sees a cancelled crossing, so a call that does
/// not describe one is a caller that has drifted, not a case to guess at.
fn leave_extension(session: &mut Session, tab: TabId, url: String) -> Vec<EngineCommand> {
    let Some(leaving) = extension_context_of(session, tab) else {
        return Vec::new();
    };
    if extension_url::base_host(&url).as_deref() == Some(leaving.as_str()) {
        return Vec::new();
    }
    start_navigation(session, tab, url)
}

/// Whether this browser will not show `url` in this tab at all.
///
/// **The one door**, asked by both readers there are: [`open_in`], which aims a
/// brand-new tab at an address before building its view, and
/// [`start_navigation`], which is where the refusal is carried out. A condition
/// copied into the second of those is a tab whose view is built for an
/// extension and whose navigation is then refused, or the reverse — and both
/// are states where the interface and the engine disagree about what a tab is.
///
/// Two refusals, and they are different things:
///
/// - **An address claiming the scheme and naming no context.**
///   `webkit-extension:///x` names no extension. There is nothing to repair it
///   into, and an engine handed it reports it as a site that does not exist.
/// - **Any of them, in a space that records nothing.** An extension's page is
///   built from that extension's own configuration, which carries WebKit's
///   shared, persistent data store and will not take another — measured,
///   assigning a space's store or a non-persistent one leaves `WKWebView.init`
///   never returning, while the same assignments on an ordinary configuration
///   build a view and load a page. So a private window has nowhere to put one,
///   and it is refused rather than quietly excepted from ADR-0023.
fn refuses_extension_page(session: &Session, tab: TabId, url: &str) -> bool {
    if !extension_url::claims_scheme(url) {
        return false;
    }
    extension_url::base_host(url).is_none()
        || !session
            .browser
            .tab(tab)
            .is_some_and(|t| session.browser.records_to_disk(t.space))
}

/// Refuse an address inside an extension, as an extension's rather than as a
/// site.
///
/// The same shape as [`refuse_internal`] and for the same reason: the tab keeps
/// its place and gets the failure screen, rather than the address being handed
/// to a search engine or to a web engine that would call it a host that does
/// not resolve.
fn refuse_extension_page(session: &mut Session, tab: TabId, url: &str) -> Vec<EngineCommand> {
    if let Some(t) = session.browser.tab_mut(tab) {
        t.pending_url = None;
        t.loading_complete = true;
        t.last_error = Some(NavigationError {
            kind: NavigationErrorKind::UnsupportedUrl,
            message: String::new(),
            url: Some(url.to_string()),
        });
    }
    Vec::new()
}

/// Replace this tab's view with one built for where the tab is going.
///
/// **A view is bound to the configuration it was made with**, and crossing into
/// or out of an extension changes which configuration that has to be —
/// `WKWebExtensionContext.h` is explicit that a navigation to an extension's
/// address is *cancelled* in a view built from any other configuration, and
/// that the app must swap views when navigating to **and from** one. Measured,
/// same address and same instant: in an ordinary page configuration the view is
/// left at `about:blank`; in the extension's it loads and reports its title.
///
/// The leaving half is not symmetry for its own sake. Without it, a link off an
/// extension's own page loads the web into the extension's configuration, whose
/// store is WebKit's shared persistent one — which is the escape from the
/// space's cookie jar that the arriving half exists to avoid.
///
/// The tab is untouched: same id, same place in the sidebar, same space, same
/// window, same conversation. This is the third crossing that costs a view, and
/// the third to be answered the same way — a space move and a profile change
/// are the other two, both through [`rebuild_view`].
///
/// **The back/forward list does not cross.** It belongs to the view that is
/// going: every entry on one side of the boundary is one the view on the other
/// side refuses. Forgotten rather than filtered, because a history with the
/// crossing cut out of it is a Back button that skips a page.
fn reface_view(session: &mut Session, tab: TabId) -> Vec<EngineCommand> {
    session.navigation_states.forget(tab);
    let mut out = vec![EngineCommand::DestroyWebView { tab }];
    out.push(create_view(session, tab));
    // The same list `rebuild_view` restores, through the same door: a fresh
    // view is at the engine's defaults, and mute and zoom are the tab's.
    out.extend(restore_view_state(session, tab));
    out
}

/// Go to one of the browser's own addresses.
///
/// The single place a `zer0://` URL is acted on, and the single place one is
/// refused. Everything that navigates goes through [`start_navigation`], so
/// there is no second path where an address of ours could be handed to a web
/// engine by somebody who did not know about this one.
///
/// Three outcomes, and they are three different things:
///
/// - a **page** commits here and now. There is no engine to ask and nothing to
///   wait for, so the tab is already showing it by the time this returns —
///   which is why no `LoadUrl` is emitted and no `NavigationStarted` is ever
///   reported for one.
/// - a **window** address leaves the tab exactly where it was. Going to
///   `zer0://settings` from a page you are reading puts Settings in front of
///   that page, the way ⌘, does; a tab that went blank to open a window would
///   be the browser losing your place in order to obey you.
/// - an address that names **nothing we have** fails as ours. It is not
///   repaired into the nearest one, and it is not passed to an engine that
///   would report it as a site that does not exist.
fn go_internal(session: &mut Session, tab: TabId, url: &str) -> Vec<EngineCommand> {
    let Some(address) = internal_url::parse(url) else {
        return refuse_internal(session, tab, url);
    };

    match address.effect() {
        internal_url::Effect::Window { command } => {
            vec![EngineCommand::RaiseWindow { command }]
        }
        internal_url::Effect::Page => {
            // Canonical, not what was typed. `zer0://CHAT/` and `zer0://chat`
            // are one address, and a tab holding the spelling somebody used
            // would round-trip that spelling through the session file for ever.
            let url = address.url();
            let Some(t) = session.browser.tab_mut(tab) else {
                return Vec::new();
            };
            t.pending_url = None;
            t.url = Some(url);
            // The old page's title, cleared rather than replaced here: what one
            // of our addresses is called is `name_our_pages`', and it runs
            // before this dispatch returns. Naming it here as well would be the
            // second of the four sites that decision exists to collapse.
            t.title = None;
            t.loading_complete = true;
            t.last_error = None;
            // An internal page has no page colour to declare, and keeping the
            // last site's would leave the chrome wearing the tint of whatever
            // was open before (ADR-0047).
            t.tint = None;
            Vec::new()
        }
    }
}

/// Put one of the browser's own addresses on screen, without spending the tab
/// somebody was reading.
///
/// The chord's answer, where [`go_internal`] is the address bar's. Typing
/// `zer0://history` means "this tab, now"; pressing ⌘Y means "show me my
/// history", and a browser that answered by replacing the page you were on
/// would be obeying you by losing your place.
///
/// The shape of it is [`show_conversation`]'s, deliberately: find the tab
/// already showing this address and go back to it, otherwise open one. Two tabs
/// showing one list are two views of one state, and the stale one is always the
/// one being read.
///
/// A window address still raises its window. It is the same decision
/// `InternalAddress::effect` makes everywhere else, made in one place, so a
/// fifth address cannot arrive here and quietly become a tab.
fn show_internal_page(
    session: &mut Session,
    address: internal_url::InternalAddress,
) -> Vec<EngineCommand> {
    match address.effect() {
        internal_url::Effect::Window { command } => vec![EngineCommand::RaiseWindow { command }],
        internal_url::Effect::Page => {
            let url = address.url();

            // Anywhere in this *window*, not just this space. History and
            // downloads are one list across every space (a download is a file
            // on the disk, and the disk is not partitioned by cookie jar), so
            // the copy in another space is the copy, and hunting it down beats
            // opening a duplicate.
            //
            // A window boundary is different from a space boundary, though: a
            // copy in another window is on another screen, and reusing it would
            // take that page off that screen to answer a key press over here
            // (ADR-0065). Each window gets at most one.
            if let Some(existing) = session
                .browser
                .tabs_in_window_all(session.browser.key_window())
                .iter()
                .find(|t| t.url.as_deref() == Some(url.as_str()))
                .map(|t| t.id)
            {
                if let Some(space) = session.browser.tab(existing).map(|t| t.space) {
                    session.browser.set_active_space(space);
                }
                session.browser.set_active_tab(Some(existing));
                return vec![EngineCommand::FocusWebView { tab: existing }];
            }

            let space = session.browser.active_space();
            open_in(session, space, Some(url), None)
        }
    }
}

/// An address of ours that names nothing we have.
///
/// Reported as a navigation failure so it lands on the screen every other
/// failed navigation lands on, rather than doing nothing — a tab that swallows
/// an address is a tab that looks broken. `UnsupportedUrl` is the honest
/// category: the browser knows the scheme and does not know the page.
fn refuse_internal(session: &mut Session, tab: TabId, url: &str) -> Vec<EngineCommand> {
    if let Some(t) = session.browser.tab_mut(tab) {
        t.pending_url = None;
        t.loading_complete = true;
        t.last_error = Some(NavigationError {
            kind: NavigationErrorKind::UnsupportedUrl,
            message: String::new(),
            url: Some(url.to_string()),
        });
    }
    Vec::new()
}

/// Ask the engine to load this, unless it is one of ours.
///
/// The other door: [`rehydrate`] and [`rebuild_view`] put a tab back to the
/// address it was already holding, and neither goes through
/// [`start_navigation`]. A tab restored on `zer0://chat` is already showing it,
/// because the shell draws it from the tab's own URL — there is nothing to
/// load.
fn load_command(tab: TabId, url: String) -> Option<EngineCommand> {
    (!internal_url::claims_scheme(&url)).then_some(EngineCommand::LoadUrl { tab, url })
}

/// The address to re-request for a tab whose last navigation failed, if there
/// is one. `None` means an ordinary reload is the right thing.
fn retry_url(session: &Session, tab: TabId) -> Option<String> {
    session.browser.tab(tab)?.last_error.as_ref()?.url.clone()
}

/// The tab a split would pair this one with when nobody said which.
///
/// The next one in the space, wrapping — the same order ⌃Tab walks, so the
/// pane that appears is the one you would have reached anyway. `None` means
/// the space holds nothing else.
fn neighbour_of(browser: &Browser, tab: TabId) -> Option<TabId> {
    let space = browser.tab(tab)?.space;
    let order: Vec<TabId> = browser.tabs_in(space).iter().map(|t| t.id).collect();
    step(&order, Some(tab), 1).filter(|next| *next != tab)
}

/// Move `delta` places through `items`, wrapping at both ends.
fn step<T: Copy + PartialEq>(items: &[T], current: Option<T>, delta: i32) -> Option<T> {
    if items.is_empty() {
        return None;
    }
    let at = current
        .and_then(|c| items.iter().position(|i| *i == c))
        .unwrap_or(0) as i32;
    let len = items.len() as i32;
    // rem_euclid so going back from the first lands on the last.
    Some(items[(at + delta).rem_euclid(len) as usize])
}

/// Emit `command` only if the tab is still around.
fn guard(session: &Session, tab: TabId, command: EngineCommand) -> Vec<EngineCommand> {
    if session.browser.tab(tab).is_some() {
        vec![command]
    } else {
        Vec::new()
    }
}

/// Where downloads go: the configured folder if it is still there, else the
/// host's own.
///
/// A folder that was deleted, renamed or unmounted is not worth failing a
/// download over, and it is certainly not worth writing into whatever now sits
/// at that path.
fn download_directory(session: &Session, default_directory: String) -> String {
    session
        .preferences
        .download_directory
        .as_deref()
        .filter(|d| downloads::is_usable_directory(d))
        .map(str::to_string)
        .unwrap_or(default_directory)
}

fn new_download(
    session: &Session,
    id: &DownloadId,
    tab: Option<TabId>,
    url: String,
    filename: &str,
    total_bytes: Option<u64>,
) -> Download {
    Download {
        id: id.clone(),
        url,
        // A tab that has already been closed is no longer somewhere to point
        // back to, and the download outlives it either way.
        tab: tab.filter(|t| session.browser.tab(*t).is_some()),
        filename: filename.to_string(),
        path: String::new(),
        state: DownloadState::InProgress,
        received_bytes: 0,
        total_bytes,
        error: None,
        started_at_ms: session.browser.now_ms(),
        // Nothing has stopped yet, so there is nothing to carry on from.
        resumable: false,
    }
}

/// Record a failure, unless the download already stopped for another reason.
///
/// Cancelling produces a failure from the engine a moment later. Letting it
/// through would turn "you stopped it" into "it broke", which is a different
/// thing to be told.
fn fail_download(session: &mut Session, id: &DownloadId, kind: DownloadErrorKind, message: String) {
    let Some(d) = session.downloads.get_mut(id) else {
        return;
    };
    if !d.is_in_flight() {
        return;
    }
    d.state = DownloadState::Failed;
    d.error = Some(DownloadError { kind, message });
}

/// The last component of a path, falling back to a name we already trust.
fn file_name_of(path: &str, fallback: &str) -> String {
    std::path::Path::new(path)
        .file_name()
        .map(|f| f.to_string_lossy().into_owned())
        .unwrap_or_else(|| fallback.to_string())
}

/// Commands that bring a restored session back to life.
///
/// A session loaded from disk has tabs but no web views behind them. This
/// rebuilds one per tab, restores what each was showing, and focuses whatever
/// was active when the browser closed.
pub fn rehydrate(session: &Session) -> Vec<EngineCommand> {
    // First, because a tool call arriving before the browser knows what tools
    // exist is refused rather than queued, and the fastest question anyone can
    // ask is the one they typed before the window finished opening.
    // `None`, because at this moment the core has adopted no servers: the
    // configuration that names them is the shell's and has not been read yet.
    let mut out = vec![EngineCommand::ListTools { server: None }];
    for tab in session.browser.all_tabs() {
        out.extend(create_and_fill_view(session, tab.id));
        out.extend(restore_view_state(session, tab.id));
    }
    if let Some(tab) = session.browser.active_tab() {
        out.push(EngineCommand::FocusWebView { tab });
    }
    out
}

#[cfg(test)]
#[path = "reducer_tests.rs"]
mod tests;

#[cfg(test)]
#[path = "download_reducer_tests.rs"]
mod download_tests;
