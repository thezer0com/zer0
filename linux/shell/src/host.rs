//! The Linux host: GTK chrome on top, the core deciding everything underneath.
//!
//! An [`Action`] goes into `zer0_core::dispatch`, and the [`EngineCommand`]s
//! that come back are carried out on WebKitGTK. This file renders and reports;
//! it decides nothing (ADR-0002). The core is linked as a crate — no FFI, no
//! binding layer — because a Rust shell talking to a Rust core through a
//! generated C boundary would be ceremony with a build step, nothing more
//! (ADR-0122).

use std::cell::{Cell, RefCell};
use std::collections::{HashMap, VecDeque};
use std::rc::Rc;
use std::time::Duration;
use std::time::{SystemTime, UNIX_EPOCH};

use gtk::glib;
use gtk::glib::clone;
use gtk::prelude::*;
// Only the one trait, not the whole subclass prelude: `Mark::new` reaches its
// own implementation through `imp()` and nothing else out here is a subclass.
use gtk::subclass::prelude::ObjectSubclassIsExt;
use gtk4 as gtk;
use webkit6::prelude::WebViewExt;
use webkit6::{LoadEvent, WebView};
use zer0_core::{
    Action, Chord, EngineCommand, HostCapabilities, Key, Session, TabId, TabKind, UiCommand,
    ViewConfiguration, dispatch,
};

use crate::tokens;
use gtk::{gdk, gsk};

mod image_copy;

/// The host's facts and widgets, plus everything the window shows.
struct Host {
    session: Session,
    window: gtk::ApplicationWindow,
    stack: gtk::Stack,
    tab_bar: gtk::Box,
    entry: gtk::Entry,
    back: gtk::Button,
    forward: gtk::Button,
    reload: gtk::Button,
    /// The empty browser screen — a product screen, not a blank stack
    /// (DESIGN.md §9). A stack child so switching to it is one name.
    empty_hint: gtk::Label,
    /// 2pt of real engine progress laid over the very top of the page area —
    /// the one thing allowed to sit on a page, and only while loading
    /// (DESIGN.md §4). An overlay child, so it never takes space from a page.
    load_bar: gtk::DrawingArea,
    /// The active tab's engine estimate, shared with the bar's draw function.
    /// Width is never animated: a smoothed bar would claim progress WebKit
    /// did not report (ADR-0018's rule, one layer up).
    load_progress: Rc<Cell<f64>>,
    /// One web view per tab, as `CreateWebView`/`DestroyWebView` commanded.
    views: HashMap<TabId, WebView>,
    /// Active image copies keep their originating tab beside WebKit's transfer
    /// so destroying that tab can cancel exactly the work its page started.
    image_copies: TabScoped<image_copy::ActiveCopy>,
    next_image_copy_id: u64,
    image_copy_notice: gtk::Revealer,
    image_copy_notice_icon: gtk::Image,
    image_copy_notice_label: gtk::Label,
    image_copy_notice_state: ImageCopyNoticeState,
    image_copy_notice_retreat: Option<glib::SourceId>,
    image_copy_notice_linger: Duration,
}

struct TabScoped<T> {
    items: HashMap<u64, (TabId, T)>,
}

impl<T> Default for TabScoped<T> {
    fn default() -> Self {
        Self {
            items: HashMap::new(),
        }
    }
}

impl<T> TabScoped<T> {
    fn insert(&mut self, id: u64, tab: TabId, item: T) {
        self.items.insert(id, (tab, item));
    }

    fn remove(&mut self, id: u64) -> Option<T> {
        self.items.remove(&id).map(|(_, item)| item)
    }

    fn take_for_tab(&mut self, tab: TabId) -> Vec<T> {
        let ids = self
            .items
            .iter()
            .filter_map(|(id, (owner, _))| (*owner == tab).then_some(*id))
            .collect::<Vec<_>>();
        ids.into_iter().filter_map(|id| self.remove(id)).collect()
    }
}

#[derive(Default)]
struct ImageCopyNoticeState {
    generation: u64,
    current: Option<(u64, image_copy::Outcome)>,
}

impl ImageCopyNoticeState {
    fn replace(&mut self, outcome: image_copy::Outcome) -> u64 {
        self.generation = self.generation.wrapping_add(1);
        self.current = Some((self.generation, outcome));
        self.generation
    }

    fn retreat(&mut self, generation: u64) -> bool {
        if self
            .current
            .is_some_and(|(current, _)| current == generation)
        {
            self.current = None;
            true
        } else {
            false
        }
    }

    #[cfg(test)]
    fn outcome(&self) -> Option<image_copy::Outcome> {
        self.current.map(|(_, outcome)| outcome)
    }
}

/// The shared state every closure holds, split so a GTK signal arriving while
/// a dispatch is running cannot re-enter the session.
///
/// The whole shell runs on GTK's main thread, but "single threaded" is not
/// "non-reentrant": `perform` calls into WebKit, WebKit can emit a signal
/// synchronously, and the handler must not `borrow_mut` a `RefCell` the
/// dispatcher still holds. So the queue and the pumping flag live beside the
/// `RefCell`, not inside it — a handler can always reach them — and every
/// action, from wherever it comes, is queued and drained by one pump.
pub(crate) struct App {
    host: RefCell<Host>,
    queue: RefCell<VecDeque<Action>>,
    pumping: Cell<bool>,
}

/// The one door every action passes through, from a key press, a click, or a
/// page's own navigation.
fn run(app: &Rc<App>, action: Action) {
    app.queue.borrow_mut().push_back(action);
    pump(app);
}

fn pump(app: &Rc<App>) {
    if app.pumping.get() {
        // A signal that fired inside `perform`; the running loop drains it.
        return;
    }
    app.pumping.set(true);
    while let Some(action) = app.queue.borrow_mut().pop_front() {
        let commands = dispatch(&mut app.host.borrow_mut().session, action);
        for command in commands {
            perform(app, command);
        }
    }
    app.pumping.set(false);
    sync_chrome(app);
}

/// What the core told this host to do, carried out. Every variant is named:
/// the ones this v1 has no surface for say so through [`not_carried_out_yet`]
/// rather than a wildcard, so a new command breaks this build until it has
/// been decided here, out loud (ADR-0031's rule, held by the workspace lint).
fn perform(app: &Rc<App>, command: EngineCommand) {
    let mut host = app.host.borrow_mut();
    match command {
        EngineCommand::CreateWebView {
            tab,
            configuration,
            navigation_state,
        } => {
            // An extension's page cannot exist on a host that declared no
            // extension runtime, and a state blob belongs to a session this
            // in-memory v1 never saved — both are refused rather than papered
            // over with a wrong-jar view.
            match configuration {
                ViewConfiguration::Space { .. } => {}
                ViewConfiguration::Extension { base_host } => {
                    not_carried_out_yet(
                        "CreateWebView for an extension page",
                        &format!("host {base_host} has no runtime to build it from"),
                    );
                    return;
                }
            };
            if navigation_state.is_some() {
                not_carried_out_yet(
                    "CreateWebView with navigation state",
                    "this v1 keeps no session to restore from",
                );
                // Refused means refused: falling through would create a blank
                // view for a tab the core thinks carries state, the exact
                // wrong-jar view the comment above refuses.
                return;
            }
            let view = WebView::new();
            view.connect_load_changed(clone!(
                #[weak]
                app,
                move |view, event| {
                    report_load(&app, tab, view, event);
                }
            ));
            // The loading bar follows the engine's own estimate, never a
            // guess. Deferred to an idle because this notify can arrive while
            // the pump still holds the host borrow — the same reentrancy
            // shape the module header describes for `title`.
            view.connect_estimated_load_progress_notify(clone!(
                #[weak]
                app,
                move |_view| {
                    let app = app.clone();
                    gtk::glib::idle_add_local_once(move || {
                        sync_load_bar(&app.host.borrow());
                    });
                }
            ));
            view.connect_notify_local(
                Some("title"),
                clone!(
                    #[weak]
                    app,
                    move |view, _| {
                        if let Some(title) = view.title() {
                            run(
                                &app,
                                Action::TitleChanged {
                                    tab,
                                    title: title.to_string(),
                                },
                            );
                        }
                    }
                ),
            );
            host.stack.add_named(&view, Some(&tab_name(tab)));
            host.views.insert(tab, view);
        }
        EngineCommand::DestroyWebView { tab } => {
            for copy in host.image_copies.take_for_tab(tab) {
                copy.cancel();
            }
            if let Some(view) = host.views.remove(&tab) {
                host.stack.remove(&view);
            }
        }
        EngineCommand::AdoptWebView { tab } => not_carried_out_yet(
            "AdoptWebView",
            &format!("tab {tab:?}: window.open adoption needs the create signal, not wired yet"),
        ),
        EngineCommand::LoadUrl { tab, url } => {
            if let Some(view) = host.views.get(&tab) {
                view.load_uri(&url);
            }
        }
        EngineCommand::Reload { tab, from_origin } => {
            if let Some(view) = host.views.get(&tab) {
                if from_origin {
                    view.reload_bypass_cache();
                } else {
                    view.reload();
                }
            }
        }
        EngineCommand::GoBack { tab } => {
            if let Some(view) = host.views.get(&tab) {
                view.go_back();
            }
        }
        EngineCommand::GoForward { tab } => {
            if let Some(view) = host.views.get(&tab) {
                view.go_forward();
            }
        }
        EngineCommand::FocusWebView { tab } => {
            if let Some(view) = host.views.get(&tab) {
                host.stack.set_visible_child(view);
                view.grab_focus();
            }
        }
        EngineCommand::SetZoom { tab, factor } => {
            if let Some(view) = host.views.get(&tab) {
                view.set_zoom_level(factor);
            }
        }
        EngineCommand::SetMuted { tab, muted } => {
            if let Some(view) = host.views.get(&tab) {
                view.set_is_muted(muted);
            }
        }
        EngineCommand::OpenBrowserWindow { window } => {
            // v1 is one window; the core's own window is the one on screen.
            let ours = host.session.browser.windows().first().map(|w| w.id);
            if ours == Some(window) {
                host.window.present();
            } else {
                not_carried_out_yet(
                    "OpenBrowserWindow",
                    &format!("a second window ({window:?}) is not built yet"),
                );
            }
        }
        EngineCommand::CloseBrowserWindow { window } => not_carried_out_yet(
            "CloseBrowserWindow",
            // The core never closes the last window, so this names a second
            // one — which this host has no way to open either.
            &format!("single-window v1 has no window {window:?} to close"),
        ),
        EngineCommand::PrintPage { tab } => not_carried_out_yet(
            "PrintPage",
            // Unreachable by construction: the host declared page_printing
            // false, so the core retired the chord and never injects the
            // script channel that `window.print()` would need. The arm stays
            // so that nobody can "fix" the gap silently (ADR-0118).
            &format!("tab {tab:?} asked to print on a host that declared it cannot"),
        ),
        EngineCommand::DeleteDataStore { data_store_id } => not_carried_out_yet(
            "DeleteDataStore",
            // v1 puts every space on WebKitGTK's default session and owns no
            // directory on disk, so there is nothing of ours to delete —
            // named here so the day per-space data managers arrive, this arm
            // is already in the list to grow behaviour.
            &format!("this v1 owns no store for {data_store_id}"),
        ),
        EngineCommand::AcceptDownload { id, .. }
        | EngineCommand::AskDownloadDestination { id, .. }
        | EngineCommand::CancelDownload { id }
        | EngineCommand::ResumeDownload { id, .. } => not_carried_out_yet(
            "a download command",
            // One why for the family: no WebKitGTK download signal is
            // connected yet, so nothing can start, answer or resume.
            &format!("download {id:?}: WebKitGTK's download signals are not wired up"),
        ),
        // Named apart from its four siblings because it is the one with no
        // download to name: a download the core has not started has no id yet,
        // and the address is the only thing there is to say.
        EngineCommand::StartDownload { url, .. } => not_carried_out_yet(
            "StartDownload",
            &format!("no download of {url}: WebKitGTK's download signals are not wired up"),
        ),
        EngineCommand::CopyImage { tab, url } => {
            let copy_id = host.next_image_copy_id;
            host.next_image_copy_id = host.next_image_copy_id.wrapping_add(1);
            let Some(view) = host.views.get(&tab).cloned() else {
                report_image_copy(
                    app,
                    &mut host,
                    tab,
                    image_copy::Outcome::Failed(image_copy::Failure::NoTabPage),
                );
                return;
            };
            let app_for_report = Rc::downgrade(app);
            match image_copy::start(&view, &url, move |outcome| {
                let Some(app) = app_for_report.upgrade() else {
                    return;
                };
                gtk::glib::idle_add_local_once(move || {
                    let mut host = app.host.borrow_mut();
                    host.image_copies.remove(copy_id);
                    report_image_copy(&app, &mut host, tab, outcome);
                });
            }) {
                Ok(copy) => {
                    host.image_copies.insert(copy_id, tab, copy);
                }
                Err(failure) => {
                    report_image_copy(app, &mut host, tab, image_copy::Outcome::Failed(failure));
                }
            }
        }
        EngineCommand::FetchIcon { host: site, .. } => not_carried_out_yet(
            "FetchIcon",
            &format!("no icon fetch for {site} yet; the tab bar draws letters"),
        ),
        EngineCommand::StartChatReply { .. }
        | EngineCommand::CancelChatReply { .. }
        | EngineCommand::RunToolCall { .. }
        | EngineCommand::CancelToolCall { .. }
        | EngineCommand::CapturePageContext { .. }
        | EngineCommand::ListTools { .. } => not_carried_out_yet(
            "a chat or tool command",
            "no provider wiring and no chat surface exist on this host yet",
        ),
        EngineCommand::RaiseWindow { .. } => not_carried_out_yet(
            "RaiseWindow",
            "no internal page resolves to a window this host could raise",
        ),
        EngineCommand::AnswerSitePermission { .. }
        | EngineCommand::AnswerHttpAuth { .. }
        | EngineCommand::AnswerServerTrust { .. }
        | EngineCommand::AnswerPageDialog { .. }
        | EngineCommand::StopCapture { .. } => not_carried_out_yet(
            "a page's question",
            // Not "later, when convenient": until the permission and dialog
            // delegates are attached, the questions themselves cannot arrive,
            // the same door shape ADR-0118 uses for `window.print()`.
            "no permission or dialog delegate is attached, so nothing is waiting on an answer",
        ),
    }
}

/// The explicit "not here yet": one line on stderr, never silence. A command
/// nobody has built a surface for is a fact about this host, and pretending
/// otherwise is how affordance lies start (ADR-0018, ADR-0103).
fn not_carried_out_yet(what: &str, why: &str) {
    eprintln!("zer0-linux: no implementation yet for {what} — {why}");
}

fn report_image_copy(app: &Rc<App>, host: &mut Host, tab: TabId, outcome: image_copy::Outcome) {
    let (message, failed) = match outcome {
        image_copy::Outcome::Copied => ("Image copied", false),
        image_copy::Outcome::Failed(image_copy::Failure::InvalidAddress) => {
            ("The image's address couldn't be used.", true)
        }
        image_copy::Outcome::Failed(image_copy::Failure::NoTabPage) => {
            ("The tab closed before the image could be copied.", true)
        }
        image_copy::Outcome::Failed(image_copy::Failure::NotAnImage) => {
            ("What came back wasn't an image.", true)
        }
        image_copy::Outcome::Failed(image_copy::Failure::TooLarge) => {
            ("The image is too large to copy.", true)
        }
        image_copy::Outcome::Failed(image_copy::Failure::Unreachable) => {
            ("The image couldn't be fetched.", true)
        }
        image_copy::Outcome::Failed(image_copy::Failure::Clipboard) => {
            ("The clipboard refused the image.", true)
        }
    };
    match outcome {
        image_copy::Outcome::Copied => {
            eprintln!("zer0-linux: copied image in tab {tab:?}");
        }
        image_copy::Outcome::Failed(failure) => {
            eprintln!("zer0-linux: could not copy image in tab {tab:?}: {failure:?}");
        }
    }
    host.image_copy_notice_label.set_text(message);
    let announcement = if failed {
        format!("Couldn't copy the image. {message}")
    } else {
        message.to_string()
    };
    host.image_copy_notice
        .announce(&announcement, gtk::AccessibleAnnouncementPriority::Medium);
    if failed {
        host.image_copy_notice_label
            .add_css_class("zer0-image-copy-failure");
    } else {
        host.image_copy_notice_label
            .remove_css_class("zer0-image-copy-failure");
    }
    host.image_copy_notice_icon.set_visible(!failed);
    host.image_copy_notice.set_reveal_child(true);

    if let Some(retreat) = host.image_copy_notice_retreat.take() {
        retreat.remove();
    }
    let generation = host.image_copy_notice_state.replace(outcome);
    let app = Rc::downgrade(app);
    host.image_copy_notice_retreat = Some(glib::timeout_add_local_once(
        host.image_copy_notice_linger,
        move || {
            let Some(app) = app.upgrade() else {
                return;
            };
            let mut host = app.host.borrow_mut();
            if host.image_copy_notice_state.retreat(generation) {
                host.image_copy_notice.set_reveal_child(false);
                host.image_copy_notice_retreat = None;
            }
        },
    ));
}

/// Engine facts about a load, reported back as the actions the core expects.
/// `Started` and `Redirected` are both the beginning of a navigation as far as
/// the reducer is concerned, so both report `NavigationStarted`.
fn report_load(app: &Rc<App>, tab: TabId, view: &WebView, event: LoadEvent) {
    // WebKitGTK's enum is `#[non_exhaustive]`: the compiler demands an arm for
    // variants that do not exist yet, and listing the four known ones plus
    // the future-shaped one is the only spelling that compiles.
    #[allow(
        clippy::wildcard_enum_match_arm,
        reason = "LoadEvent is foreign and non_exhaustive: the four known variants are named, \
                  and the wildcard arm is what the compiler itself demands for the ones \
                  WebKitGTK has not added yet"
    )]
    match event {
        LoadEvent::Started | LoadEvent::Redirected => {
            if let Some(uri) = view.uri() {
                run(
                    app,
                    Action::NavigationStarted {
                        tab,
                        url: uri.to_string(),
                    },
                );
            }
        }
        LoadEvent::Committed => {
            if let Some(uri) = view.uri() {
                run(
                    app,
                    Action::NavigationCommitted {
                        tab,
                        url: uri.to_string(),
                    },
                );
            }
            report_stack(app, tab, view);
        }
        LoadEvent::Finished => {
            run(app, Action::NavigationFinished { tab });
            report_stack(app, tab, view);
        }
        _ => {}
    }
}

/// Whether this tab can now go back and forward, as WebKitGTK answers it —
/// core state, because ⌘[ doing something is behaviour (ADR-0002).
fn report_stack(app: &Rc<App>, tab: TabId, view: &WebView) {
    run(
        app,
        Action::NavigationStackChanged {
            tab,
            can_go_back: view.can_go_back(),
            can_go_forward: view.can_go_forward(),
        },
    );
}

/// A key chord resolved to a command: translate it into the action that
/// carries it out. Every command is named; the ones with no GTK surface yet
/// say so through [`not_carried_out_yet`], because a shortcut that does
/// nothing silently is the worst way to learn a browser is unfinished.
fn run_ui_command(app: &Rc<App>, command: UiCommand) {
    let action = {
        let host = app.host.borrow();
        let active = host.session.browser.active_tab();
        match command {
            UiCommand::NewTab => Some(Action::OpenTab {
                space: None,
                url: None,
                parent: None,
            }),
            UiCommand::CloseTab => active.map(|tab| Action::CloseTab { tab }),
            UiCommand::ReopenClosedTab => Some(Action::ReopenClosedTab),
            UiCommand::OpenLocation => {
                // The field opens with the cursor in it, and what was there
                // arrives selected: the premise this browser is built on.
                let entry = &host.entry;
                entry.grab_focus();
                // -1 is the end of the field, per the C convention GTK keeps.
                entry.select_region(0, -1);
                None
            }
            UiCommand::Back => active.map(|tab| Action::GoBack { tab }),
            UiCommand::Forward => active.map(|tab| Action::GoForward { tab }),
            UiCommand::Reload => active.map(|tab| Action::Reload {
                tab,
                from_origin: false,
            }),
            UiCommand::ReloadIgnoringCache => active.map(|tab| Action::Reload {
                tab,
                from_origin: true,
            }),
            UiCommand::CopyCurrentUrl => {
                let url = active
                    .and_then(|tab| host.session.browser.tab(tab))
                    .and_then(|tab| tab.url.clone());
                match url {
                    Some(url) => {
                        gtk::gdk::Display::default()
                            .expect("a window is on screen, so a display exists")
                            .clipboard()
                            .set_text(url.as_str());
                    }
                    None => not_carried_out_yet(
                        "CopyCurrentUrl",
                        "the active tab has nothing committed to copy",
                    ),
                }
                None
            }
            UiCommand::NextTab => Some(Action::CycleTab { delta: 1 }),
            UiCommand::PreviousTab => Some(Action::CycleTab { delta: -1 }),
            UiCommand::SelectTab { index } => Some(Action::SelectTabByIndex {
                index: u32::from(index),
            }),
            UiCommand::TogglePinTab => {
                active
                    .and_then(|tab| host.session.browser.tab(tab))
                    .map(|tab| Action::SetTabKind {
                        tab: tab.id,
                        kind: if tab.kind == TabKind::Pinned {
                            TabKind::Today
                        } else {
                            TabKind::Pinned
                        },
                    })
            }
            UiCommand::ToggleMuteTab => {
                active
                    .and_then(|tab| host.session.browser.tab(tab))
                    .map(|tab| Action::SetTabMuted {
                        tab: tab.id,
                        muted: !tab.muted,
                    })
            }
            UiCommand::ZoomIn => zoom_action(&host.session, 1.1),
            UiCommand::ZoomOut => zoom_action(&host.session, 1.0 / 1.1),
            UiCommand::ZoomReset => active.map(|tab| Action::SetTabZoom { tab, factor: 1.0 }),
            UiCommand::StopLoading => {
                // No `Action` carries "stop": the engine's own brake is the
                // host's to pull, like every engine fact is.
                let active = host.session.browser.active_tab();
                if let Some(view) = active.and_then(|tab| host.views.get(&tab)) {
                    view.stop_loading();
                }
                None
            }
            UiCommand::PrintPage => {
                // The keymap retired this chord at the door (page_printing
                // false), so a press cannot resolve here. Kept explicit so
                // nobody wires a panel nobody can put up (ADR-0118).
                not_carried_out_yet(
                    "PrintPage",
                    "the core retired the chord because this host cannot print",
                );
                None
            }
            UiCommand::RunPinnedExtension { .. } => {
                not_carried_out_yet(
                    "RunPinnedExtension",
                    "this host declared no extension runtime",
                );
                None
            }
            UiCommand::AddBookmark | UiCommand::ToggleBookmarks => {
                not_carried_out_yet("a bookmark command", "no bookmarks surface on GTK yet");
                None
            }
            UiCommand::ToggleBlockingHere => {
                not_carried_out_yet(
                    "ToggleBlockingHere",
                    "content blocking is not wired on GTK yet",
                );
                None
            }
            UiCommand::OpenChat => {
                not_carried_out_yet("OpenChat", "no chat surface on GTK yet");
                None
            }
            UiCommand::NewWindow | UiCommand::NewPrivateWindow | UiCommand::CloseWindow => {
                not_carried_out_yet("a window command", "this v1 is single-window by decision");
                None
            }
            UiCommand::NewSpace
            | UiCommand::NextSpace
            | UiCommand::PreviousSpace
            | UiCommand::SelectSpace { .. } => {
                not_carried_out_yet("a space command", "no space chrome on GTK yet");
                None
            }
            UiCommand::ToggleSplitView | UiCommand::FocusOtherPane => {
                not_carried_out_yet("a split command", "no split layout on GTK yet");
                None
            }
            UiCommand::ToggleSidebar => {
                not_carried_out_yet("ToggleSidebar", "no sidebar on GTK yet");
                None
            }
            UiCommand::SavePage | UiCommand::ViewSource | UiCommand::ToggleDevTools => {
                not_carried_out_yet("a page tool", "save/view-source/devtools are not wired yet");
                None
            }
            UiCommand::FindInPage | UiCommand::FindNext | UiCommand::FindPrevious => {
                not_carried_out_yet("a find command", "the find controller is not wired yet");
                None
            }
            UiCommand::ShowHistory
            | UiCommand::ShowDownloads
            | UiCommand::ShowSettings
            | UiCommand::ShowExtensions => {
                not_carried_out_yet(
                    "an internal page",
                    "the browser's own pages have no GTK rendering yet",
                );
                None
            }
        }
    };
    if let Some(action) = action {
        run(app, action);
    }
}

fn zoom_action(session: &Session, multiplier: f64) -> Option<Action> {
    let tab = session.browser.active_tab()?;
    let factor = session.browser.tab(tab)?.zoom_factor * multiplier;
    Some(Action::SetTabZoom { tab, factor })
}

/// Rebuild the tab strip and sync window, address field and navigation
/// buttons to what the core now holds. Called once per pump, after every
/// action has settled — the chrome is a projection of core state, never a
/// second copy of it.
fn sync_chrome(app: &Rc<App>) {
    let host = app.host.borrow();
    let window = host
        .session
        .browser
        .windows()
        .first()
        .map(|w| w.id)
        .expect("the core always keeps one window");
    // The one window is the key window, so this is the space in front.
    let space = host.session.browser.active_space();
    let tabs = host.session.browser.tabs_in_window(window, space);
    let active = host.session.browser.active_tab();

    // The chord printed under the empty screen's action is read from the live
    // keymap on every sync, never written by hand — a hard-coded chord is an
    // assertion with an expiry date (DESIGN.md §10).
    let new_tab_chord = host.session.keymap.chord_for(&UiCommand::NewTab);
    host.empty_hint
        .set_text(&new_tab_chord.as_ref().map(chord_text).unwrap_or_default());

    while let Some(child) = host.tab_bar.first_child() {
        host.tab_bar.remove(&child);
    }
    for (index, tab) in tabs.iter().enumerate() {
        // A hairline between tabs, not around the strip's edge: the sidebar's
        // seam, seen and not noticed (DESIGN.md §2, `rule` + `hairline`).
        if index > 0 {
            host.tab_bar
                .append(&gtk::Separator::new(gtk::Orientation::Vertical));
        }
        let button = gtk::ToggleButton::with_label(tab.display_title());
        button.add_css_class("zer0-tab");
        // `active` is an Option because a window with every tab closed is a
        // state the core keeps; Some(...) == active says "this is the one in
        // front" without unwrapping a thing that can be absent.
        button.set_active(Some(tab.id) == active);
        let id = tab.id;
        button.connect_clicked(clone!(
            #[weak]
            app,
            #[upgrade_or_panic]
            move |_| {
                run(&app, Action::ActivateTab { tab: id });
            }
        ));
        // A middle press on a tab closes it: the gesture every browser taught.
        let click = gtk::GestureClick::new();
        click.set_button(2);
        click.connect_pressed(clone!(
            #[weak]
            app,
            #[upgrade_or_panic]
            move |_, _, _, _| {
                run(&app, Action::CloseTab { tab: id });
            }
        ));
        button.add_controller(click);
        host.tab_bar.append(&button);
    }
    let new_tab = gtk::Button::from_icon_name("tab-new-symbolic");
    new_tab.add_css_class("zer0-chrome-button");
    // The tooltip reads the live keymap, so rebinding a chord cannot leave a
    // lie printed beside the button (DESIGN.md §10).
    let new_tab_tip = match new_tab_chord {
        Some(chord) => format!("New tab ({})", chord_text(&chord)),
        None => "New tab".to_string(),
    };
    new_tab.set_tooltip_text(Some(&new_tab_tip));
    new_tab.connect_clicked(clone!(
        #[weak]
        app,
        #[upgrade_or_panic]
        move |_| {
            run_ui_command(&app, UiCommand::NewTab);
        }
    ));
    host.tab_bar.append(&new_tab);

    let active_tab = active.and_then(|id| host.session.browser.tab(id));
    host.back
        .set_sensitive(active_tab.is_some_and(|t| t.can_go_back));
    host.forward
        .set_sensitive(active_tab.is_some_and(|t| t.can_go_forward));
    host.reload.set_sensitive(active_tab.is_some());

    let title = active_tab
        .and_then(|t| t.title.clone())
        .unwrap_or_else(|| "zer0".to_string());
    host.window.set_title(Some(&title));

    // Never clobber what the person is typing: the field follows the page
    // only when the keyboard is somewhere else.
    if !host.entry.has_focus() {
        let address = active_tab.and_then(|t| t.url.clone()).unwrap_or_default();
        if host.entry.text().as_str() != address {
            host.entry.set_text(&address);
        }
    }
    // `views.get` takes the id, not the Option around it: `active.and_then`
    // carries both facts — a tab in front, and a view created for it — in one
    // expression.
    if let Some(view) = active.and_then(|tab| host.views.get(&tab)) {
        host.stack.set_visible_child(view);
    } else {
        // No tab in front: the empty screen is the product's front door, not
        // a blank rectangle (DESIGN.md §9).
        host.stack.set_visible_child_name("empty");
    }

    // A tab with nowhere to go has the keyboard waiting in the address field.
    let addressless = active_tab.is_some_and(|t| t.url.is_none());
    if addressless && !host.entry.has_focus() {
        host.entry.grab_focus();
    }

    sync_load_bar(&host);
}

/// Point the loading bar at whatever the active tab's engine is reporting.
/// Called once per pump and from each progress notification (deferred to an
/// idle), so the bar never speaks for a tab that is not in front.
fn sync_load_bar(host: &Host) {
    let progress = host
        .session
        .browser
        .active_tab()
        .and_then(|tab| host.views.get(&tab))
        .map(|view| view.estimated_load_progress())
        .unwrap_or(0.0);
    host.load_progress.set(progress);
    let loading = (0.0..1.0).contains(&progress);
    host.load_bar.set_visible(loading);
    if loading {
        host.load_bar.queue_draw();
    }
}

fn tab_name(tab: TabId) -> String {
    format!("tab-{}", tab.0)
}

/// Build the window and hand back the shared state wired to it. The design
/// tokens and the parsed mark arrive from `main` — this file renders what
/// they say and decides nothing about either.
pub(crate) fn app_for(
    application: &gtk::Application,
    design: &tokens::Tokens,
    dark: bool,
    mark: &tokens::MarkSet<gsk::Path>,
) -> Rc<App> {
    let window = gtk::ApplicationWindow::new(application);
    window.set_default_size(1200, 800);

    let header = gtk::HeaderBar::new();

    let back = gtk::Button::from_icon_name("go-previous-symbolic");
    back.add_css_class("zer0-chrome-button");
    back.set_tooltip_text(Some("Back"));
    let forward = gtk::Button::from_icon_name("go-next-symbolic");
    forward.add_css_class("zer0-chrome-button");
    forward.set_tooltip_text(Some("Forward"));
    let reload = gtk::Button::from_icon_name("view-refresh-symbolic");
    reload.add_css_class("zer0-chrome-button");
    reload.set_tooltip_text(Some("Reload"));

    let entry = gtk::Entry::new();
    entry.set_hexpand(true);
    entry.set_placeholder_text(Some("Search or enter address"));

    header.pack_start(&back);
    header.pack_start(&forward);
    header.pack_start(&reload);
    header.set_title_widget(Some(&entry));

    let tab_bar = gtk::Box::new(gtk::Orientation::Horizontal, 4);
    tab_bar.add_css_class("zer0-tabbar");

    let appearance = if dark { &design.dark } else { &design.light };
    let quiet_mark_color = tokens::MarkColor::from_hex(&appearance.ink_tertiary)
        .expect("tokens::color validated #RRGGBB before this was called");
    let bar_color = gdk::RGBA::parse(appearance.accent.as_str())
        .expect("tokens::color validated #RRGGBB before this was called");

    // The empty browser screen: the mark at Glyph.mark, quiet in tertiary —
    // "large, quiet and low-contrast on purpose" (DESIGN.md §5) — the
    // emptyTitle headline over its detail line, and one prominent action
    // with the chord beneath, read from the live keymap.
    let empty_title = gtk::Label::new(Some("Nothing open"));
    empty_title.add_css_class("zer0-empty-title");
    let empty_detail = gtk::Label::new(Some(
        "A new tab opens with the cursor in the address field.",
    ));
    empty_detail.add_css_class("zer0-empty-detail");
    let empty_text = gtk::Box::new(gtk::Orientation::Vertical, design.spacing.line as i32);
    empty_text.append(&empty_title);
    empty_text.append(&empty_detail);

    let empty_hint = gtk::Label::new(None);
    empty_hint.add_css_class("zer0-chord");
    let new_tab_action = gtk::Button::with_label("New Tab");
    new_tab_action.add_css_class("zer0-action");
    // One primary action per surface, and it answers Return (DESIGN.md §5).
    // `receives_default` plus the window's default widget: proof needs a
    // running window, named as debt in ADR-0122's amendment.
    new_tab_action.set_receives_default(true);
    let empty_action = gtk::Box::new(gtk::Orientation::Vertical, design.spacing.hair as i32);
    empty_action.append(&new_tab_action);
    empty_action.append(&empty_hint);

    let empty = gtk::Box::new(gtk::Orientation::Vertical, design.spacing.regular as i32);
    empty.add_css_class("zer0-empty");
    empty.set_halign(gtk::Align::Center);
    empty.set_valign(gtk::Align::Center);
    // The floor an empty state gets (DESIGN.md §2): tall enough to read as a
    // screen, short enough that the chrome above it stays in view.
    empty.set_size_request(-1, design.pane.empty_state_min_height as i32);
    empty.append(&Mark::new(
        mark.clone(),
        tokens::MarkTreatment::Quiet,
        quiet_mark_color,
        design.glyph.mark as f64,
    ));
    empty.append(&empty_text);
    empty.append(&empty_action);

    // The loading bar: the spacing.line rung tall, laid over the page area's
    // top edge. Its fill is the engine's estimate and nothing else.
    let load_bar = gtk::DrawingArea::new();
    load_bar.set_hexpand(true);
    load_bar.set_valign(gtk::Align::Start);
    load_bar.set_size_request(-1, design.spacing.line as i32);
    let load_progress = Rc::new(Cell::new(0.0f64));
    let progress_for_draw = load_progress.clone();
    load_bar.set_draw_func(clone!(
        #[strong]
        progress_for_draw,
        #[strong]
        bar_color,
        move |_area, cr, width, height| {
            let fraction = progress_for_draw.get();
            if fraction <= 0.0 || width <= 0 {
                return;
            }
            // `gdk::RGBA` keeps its channels as `f32`; cairo takes `f64`.
            cr.set_source_rgba(
                bar_color.red().into(),
                bar_color.green().into(),
                bar_color.blue().into(),
                bar_color.alpha().into(),
            );
            cr.rectangle(0.0, 0.0, f64::from(width) * fraction, f64::from(height));
            let _ = cr.fill();
        }
    ));
    load_bar.set_visible(false);

    let stack = gtk::Stack::new();
    stack.add_named(&empty, Some("empty"));
    stack.set_vexpand(true);

    let overlay = gtk::Overlay::new();
    overlay.set_child(Some(&stack));
    overlay.add_overlay(&load_bar);

    let image_copy_notice_icon = gtk::Image::from_icon_name("object-select-symbolic");
    let image_copy_notice_label = gtk::Label::new(None);
    let image_copy_notice_row =
        gtk::Box::new(gtk::Orientation::Horizontal, design.spacing.tight as i32);
    image_copy_notice_row.add_css_class("zer0-image-copy-notice");
    image_copy_notice_row.add_css_class("elevation-resting");
    image_copy_notice_row.append(&image_copy_notice_icon);
    image_copy_notice_row.append(&image_copy_notice_label);

    let image_copy_notice = gtk::Revealer::new();
    image_copy_notice.set_transition_type(gtk::RevealerTransitionType::SlideUp);
    image_copy_notice.set_transition_duration((design.durations.quick * 1000.0).round() as u32);
    image_copy_notice.set_halign(gtk::Align::Start);
    image_copy_notice.set_valign(gtk::Align::End);
    image_copy_notice.set_margin_start(design.spacing.regular as i32);
    image_copy_notice.set_margin_bottom(design.spacing.loose as i32);
    image_copy_notice.set_child(Some(&image_copy_notice_row));
    image_copy_notice.set_reveal_child(false);
    overlay.add_overlay(&image_copy_notice);

    let column = gtk::Box::new(gtk::Orientation::Vertical, 0);
    column.append(&tab_bar);
    column.append(&overlay);

    window.set_titlebar(Some(&header));
    window.set_child(Some(&column));
    window.set_default_widget(Some(&new_tab_action));

    // The host's declaration, at the door, in the one place this shell states
    // what it is (ADR-0118): WebKitGTK has no public extension runtime, and
    // no print panel has been wired (WebKitPrintOperation exists; the wiring
    // is a named follow-up, and the declaration flips the day it lands).
    let mut session = Session::new("Personal", data_store_id());
    session.retire_what_the_host_cannot_run(HostCapabilities {
        extension_runtime: false,
        page_printing: false,
    });

    let app = Rc::new(App {
        host: RefCell::new(Host {
            session,
            window: window.clone(),
            stack,
            tab_bar,
            entry: entry.clone(),
            back: back.clone(),
            forward: forward.clone(),
            reload: reload.clone(),
            empty_hint: empty_hint.clone(),
            load_bar,
            load_progress,
            views: HashMap::new(),
            image_copies: TabScoped::default(),
            next_image_copy_id: 0,
            image_copy_notice,
            image_copy_notice_icon,
            image_copy_notice_label,
            image_copy_notice_state: ImageCopyNoticeState::default(),
            image_copy_notice_retreat: None,
            image_copy_notice_linger: Duration::from_secs_f64(design.durations.linger),
        }),
        queue: RefCell::new(VecDeque::new()),
        pumping: Cell::new(false),
    });

    back.connect_clicked(clone!(
        #[weak]
        app,
        #[upgrade_or_panic]
        move |_| {
            run_ui_command(&app, UiCommand::Back);
        }
    ));
    forward.connect_clicked(clone!(
        #[weak]
        app,
        #[upgrade_or_panic]
        move |_| {
            run_ui_command(&app, UiCommand::Forward);
        }
    ));
    reload.connect_clicked(clone!(
        #[weak]
        app,
        #[upgrade_or_panic]
        move |_| {
            run_ui_command(&app, UiCommand::Reload);
        }
    ));
    new_tab_action.connect_clicked(clone!(
        #[weak]
        app,
        #[upgrade_or_panic]
        move |_| {
            // The command, not a hand-built action: the core decides what a new
            // tab is, and the same door the shortcut uses is the one this button
            // uses.
            run_ui_command(&app, UiCommand::NewTab);
        }
    ));
    entry.connect_activate(clone!(
        #[weak]
        app,
        #[upgrade_or_panic]
        move |entry| {
            let tab = app.host.borrow().session.browser.active_tab();
            if let Some(tab) = tab {
                run(
                    &app,
                    Action::NavigateTo {
                        tab,
                        input: entry.text().to_string(),
                    },
                );
                if let Some(view) = app.host.borrow().views.get(&tab) {
                    view.grab_focus();
                }
            }
        }
    ));

    let keys = gtk::EventControllerKey::new();
    keys.connect_key_pressed(clone!(
        #[weak]
        app,
        #[upgrade_or]
        gtk::glib::Propagation::Proceed,
        move |_, keyval, _, state| key_pressed(&app, keyval, state)
    ));
    window.add_controller(keys);

    window.present();

    // The browser opens on a fresh tab with the cursor in the address field.
    run(
        &app,
        Action::OpenTab {
            space: None,
            url: None,
            parent: None,
        },
    );
    app
}

/// A key press becomes a chord the core's keymap answers. Primary is Ctrl on
/// Linux — the keymap is minted knowing that, and the test that holds it
/// (`every_command_is_still_reachable_where_control_is_primary`) is the core's.
fn key_pressed(
    app: &Rc<App>,
    keyval: gtk::gdk::Key,
    state: gtk::gdk::ModifierType,
) -> gtk::glib::Propagation {
    if keyval == gtk::gdk::Key::Escape {
        let view = {
            let host = app.host.borrow();
            if !host.entry.has_focus() {
                None
            } else {
                // Esc closes what is open; an address field is open, so the
                // page gets the keyboard back.
                host.session
                    .browser
                    .active_tab()
                    .and_then(|tab| host.views.get(&tab))
                    .cloned()
            }
        };
        match view {
            Some(view) => {
                view.grab_focus();
                gtk::glib::Propagation::Stop
            }
            None => gtk::glib::Propagation::Proceed,
        }
    } else {
        chord_pressed(app, keyval, state)
    }
}

/// A key press becomes a chord the core's keymap answers.
fn chord_pressed(
    app: &Rc<App>,
    keyval: gtk::gdk::Key,
    state: gtk::gdk::ModifierType,
) -> gtk::glib::Propagation {
    let Some(key) = key_for_keyval(keyval) else {
        return gtk::glib::Propagation::Proceed;
    };
    let chord = zer0_core::Chord::new(
        key,
        zer0_core::Modifiers {
            primary: state.contains(gtk::gdk::ModifierType::CONTROL_MASK),
            shift: state.contains(gtk::gdk::ModifierType::SHIFT_MASK),
            alt: state.contains(gtk::gdk::ModifierType::ALT_MASK),
            // Linux has no second control key: Ctrl is primary, and the
            // `control` field is the macOS distinction this host cannot make.
            control: false,
        },
    );
    // The collapsed door, not the exact one: Ctrl is primary here, and the
    // keymap holds control-only chords (Ctrl+Tab, the ⌃digits) that an exact
    // `command_for` leaves bound but unanswerable — the chord in the table
    // while the press does nothing, the failure AGENTS.md carries the keymap
    // lock for. The core built this door for exactly this platform.
    let command = app
        .host
        .borrow()
        .session
        .keymap
        .command_for_collapsed(&chord);
    match command {
        Some(command) => {
            run_ui_command(app, command);
            gtk::glib::Propagation::Stop
        }
        None => gtk::glib::Propagation::Proceed,
    }
}

/// The core's side of a keysym: pure keysym-to-`Key`, no GTK state, so a test
/// can hold every mapping without a display.
///
/// `to_unicode` answers nothing from 0xff00 up, which is exactly where the
/// keymap's named keys live — arrows, Tab, Escape, Return, Backspace — so the
/// printable-only door dropped every named chord while the keymap held it
/// bound: Esc-to-stop, Ctrl+arrows and Ctrl+Tab never arrived. The brackets
/// are named for the same reason: the alphanumeric gate on the character path
/// refuses them, and Ctrl+[ / Ctrl+] are Back and Forward in the shipped
/// keymap. Shift+Tab arrives as `ISO_Left_Tab` (the X11 convention); the
/// shift rides in the modifiers, so it is the same Tab. A keysym with no
/// `Key` to be (Home, Delete, PageUp…) returns `None` — the shell refuses
/// rather than invents a key the core never heard of.
fn key_for_keyval(keyval: gdk::Key) -> Option<Key> {
    match keyval {
        gdk::Key::Left => Some(Key::Left),
        gdk::Key::Right => Some(Key::Right),
        gdk::Key::Up => Some(Key::Up),
        gdk::Key::Down => Some(Key::Down),
        gdk::Key::Tab | gdk::Key::ISO_Left_Tab => Some(Key::Tab),
        gdk::Key::Escape => Some(Key::Escape),
        gdk::Key::Return | gdk::Key::KP_Enter => Some(Key::Enter),
        gdk::Key::BackSpace => Some(Key::Backspace),
        gdk::Key::bracketleft => Some(Key::character("[")),
        gdk::Key::bracketright => Some(Key::character("]")),
        // The gate below refuses it, and Ctrl+. is StopLoading in the shipped
        // keymap — the last punctuation chord the menu prints.
        gdk::Key::period => Some(Key::character(".")),
        _ => {
            let character = keyval.to_unicode()?.to_ascii_lowercase();
            if !character.is_ascii_alphanumeric() {
                return None;
            }
            Some(Key::character(&character.to_string()))
        }
    }
}

/// The first space's cookie jar id, minted by the shell because the core stays
/// deterministic under test (see `Action::CreateSpace`). This v1 keeps no
/// store on disk, so the id names a jar only WebKitGTK's default session
/// holds; per-space `NetworkSession`s are the follow-up that make it mean
/// more.
fn data_store_id() -> String {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or_default();
    format!("linux-{nanos}")
}

/// A chord as this platform writes it. The words are the shell's — copy is
/// (DESIGN.md §1) — but the chord itself is always read from the core's live
/// keymap by whoever calls this, never typed here. `primary` is Control on
/// Linux (ADR-0112), so it is spelled Ctrl.
fn chord_text(chord: &Chord) -> String {
    let mut parts: Vec<String> = Vec::new();
    if chord.modifiers.primary {
        parts.push("Ctrl".to_string());
    }
    if chord.modifiers.shift {
        parts.push("Shift".to_string());
    }
    if chord.modifiers.alt {
        parts.push("Alt".to_string());
    }
    match &chord.key {
        Key::Char { value } => parts.push(value.to_uppercase()),
        Key::Enter => parts.push("Return".to_string()),
        Key::Escape => parts.push("Esc".to_string()),
        Key::Tab => parts.push("Tab".to_string()),
        Key::Space => parts.push("Space".to_string()),
        Key::Backspace => parts.push("Backspace".to_string()),
        Key::Left => parts.push("Left".to_string()),
        Key::Right => parts.push("Right".to_string()),
        Key::Up => parts.push("Up".to_string()),
        Key::Down => parts.push("Down".to_string()),
    }
    parts.join("+")
}

/// The zer0 mark, drawn from the SVG's ordered path layers.
///
/// macOS ports the geometry into a SwiftUI `Shape`; GSK already speaks SVG
/// path syntax, so this shell parses every `d` attribute and its declared fill
/// straight from `design/logo/zer0.svg` (ADR-0040's source of truth).
mod mark {
    // A child module cannot see its parent's `use gtk4 as gtk`, and every item
    // below speaks GTK types, so the alias is restated here the way `main.rs`
    // states its own.
    use gtk::{gdk, glib, graphene, gsk, prelude::*, subclass::prelude::*};
    use gtk4 as gtk;
    use std::cell::{Cell, OnceCell};

    use crate::tokens;

    pub struct Mark {
        pub(super) artwork: OnceCell<tokens::MarkSet<gsk::Path>>,
        pub(super) treatment: OnceCell<tokens::MarkTreatment>,
        pub(super) quiet_color: OnceCell<tokens::MarkColor>,
        pub(super) side: Cell<f64>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for Mark {
        // The name GObject registers the type under, and it is a process-wide
        // namespace shared with GTK's own types — so it carries the shell's
        // prefix rather than a bare `Mark`, which is the kind of collision
        // that shows up as a widget nobody can explain.
        const NAME: &'static str = "Zer0Mark";
        type Type = super::Mark;
        type ParentType = gtk::Widget;

        fn class_init(klass: &mut Self::Class) {
            klass.set_css_name("zer0-mark");
        }

        fn new() -> Self {
            // GTK demands a no-argument constructor, so the cells start empty
            // and `super::Mark::new` fills them before the widget can be
            // measured or drawn.
            Self {
                artwork: OnceCell::new(),
                treatment: OnceCell::new(),
                quiet_color: OnceCell::new(),
                side: Cell::new(0.0),
            }
        }
    }

    impl ObjectImpl for Mark {}

    impl WidgetImpl for Mark {
        fn measure(&self, _orientation: gtk::Orientation, _for_size: i32) -> (i32, i32, i32, i32) {
            let side = self.side.get() as i32;
            (side, side, -1, -1)
        }

        fn snapshot(&self, snapshot: &gtk::Snapshot) {
            let Some(artwork) = self.artwork.get() else {
                return;
            };
            let Some(treatment) = self.treatment.get() else {
                return;
            };
            let Some(quiet_color) = self.quiet_color.get() else {
                return;
            };
            let instance = self.obj();
            let width = f64::from(instance.width());
            let height = f64::from(instance.height());
            if width <= 0.0 || height <= 0.0 {
                return;
            }
            let pixels = (width.min(height) * f64::from(instance.scale_factor())).round() as u16;
            let master = artwork.for_rendered_pixels(pixels);
            // Centred in whatever it was given, on the selected SVG's own grid.
            let view_width = f64::from(master.view_box.width);
            let view_height = f64::from(master.view_box.height);
            let scale = (width / view_width).min(height / view_height) as f32;
            let offset_x = ((width as f32 - view_width as f32 * scale) / 2.0).max(0.0);
            let offset_y = ((height as f32 - view_height as f32 * scale) / 2.0).max(0.0);
            snapshot.save();
            snapshot.translate(&graphene::Point::new(offset_x, offset_y));
            snapshot.scale(scale, scale);
            for layer in master.layers_for(*treatment) {
                let fill = treatment.fill(layer.fill, *quiet_color);
                let color = gdk::RGBA::new(
                    f32::from(fill.red) / 255.0,
                    f32::from(fill.green) / 255.0,
                    f32::from(fill.blue) / 255.0,
                    1.0,
                );
                let fill_rule = match layer.fill_rule {
                    tokens::MarkFillRule::Winding => gsk::FillRule::Winding,
                    tokens::MarkFillRule::EvenOdd => gsk::FillRule::EvenOdd,
                };
                snapshot.append_fill(&layer.path, fill_rule, &color);
            }
            snapshot.restore();
        }
    }
}

glib::wrapper! {
    /// The mark as a widget: SVG layers and colours at the `Glyph.mark` side.
    ///
    /// The three interfaces are not decoration: `WidgetImpl` is only
    /// implementable for a type that carries all of them, because every
    /// `GtkWidget` implements them in C, and a wrapper that names fewer than
    /// the parent has is a type GTK cannot treat as a widget.
    pub struct Mark(ObjectSubclass<mark::Mark>)
        @extends gtk::Widget,
        @implements gtk::Accessible, gtk::Buildable, gtk::ConstraintTarget;
}

impl Mark {
    fn new(
        artwork: tokens::MarkSet<gsk::Path>,
        treatment: tokens::MarkTreatment,
        quiet_color: tokens::MarkColor,
        side: f64,
    ) -> Self {
        let widget: Self = glib::Object::new();
        let imp = widget.imp();
        let _ = imp.artwork.set(artwork);
        let _ = imp.treatment.set(treatment);
        let _ = imp.quiet_color.set(quiet_color);
        imp.side.set(side);
        widget
    }
}

#[cfg(test)]
mod tests {
    use super::{ImageCopyNoticeState, Key, TabScoped, UiCommand, image_copy, key_for_keyval};
    // A child module cannot see its parent's `use gtk4 as gtk`, so this names
    // the crate rather than the parent's alias.
    use gtk4::gdk;

    // These hold the keysym door the keymap's non-printable chords arrive
    // through. They construct constants only — no GTK initialisation, no
    // display — so the CI job that can compile GTK runs them headless. Every
    // mapping below answers a binding in the core's shipped keymap; the lock
    // for "the press arrives" lives in this package because only this
    // package ever sees a keysym.

    #[test]
    fn arrows_map_to_core_arrow_keys() {
        // Ctrl+Left and Ctrl+Right are Back and Forward in the shipped keymap.
        assert_eq!(key_for_keyval(gdk::Key::Left), Some(Key::Left));
        assert_eq!(key_for_keyval(gdk::Key::Right), Some(Key::Right));
        assert_eq!(key_for_keyval(gdk::Key::Up), Some(Key::Up));
        assert_eq!(key_for_keyval(gdk::Key::Down), Some(Key::Down));
    }

    #[test]
    fn tab_maps_to_core_tab() {
        // Ctrl+Tab is NextTab in the shipped keymap.
        assert_eq!(key_for_keyval(gdk::Key::Tab), Some(Key::Tab));
    }

    #[test]
    fn shift_tab_spelling_maps_to_core_tab() {
        // GTK reports Shift+Tab as ISO_Left_Tab (the X11 convention); without
        // this arm Ctrl+Shift+Tab never reaches PreviousTab.
        assert_eq!(key_for_keyval(gdk::Key::ISO_Left_Tab), Some(Key::Tab));
    }

    #[test]
    fn escape_maps_to_core_escape() {
        // Bare Esc is StopLoading in the shipped keymap.
        assert_eq!(key_for_keyval(gdk::Key::Escape), Some(Key::Escape));
    }

    #[test]
    fn both_enter_spellings_map_to_core_enter() {
        assert_eq!(key_for_keyval(gdk::Key::Return), Some(Key::Enter));
        // The keypad's Enter is the same gesture to the person pressing it.
        assert_eq!(key_for_keyval(gdk::Key::KP_Enter), Some(Key::Enter));
    }

    #[test]
    fn backspace_maps_to_core_backspace() {
        assert_eq!(key_for_keyval(gdk::Key::BackSpace), Some(Key::Backspace));
    }

    #[test]
    fn brackets_map_to_core_characters() {
        // The alphanumeric gate on the character path refuses them, and
        // Ctrl+[ / Ctrl+] are Back and Forward in the shipped keymap.
        assert_eq!(
            key_for_keyval(gdk::Key::bracketleft),
            Some(Key::character("["))
        );
        assert_eq!(
            key_for_keyval(gdk::Key::bracketright),
            Some(Key::character("]"))
        );
        // Same gate, same reason: Ctrl+. is StopLoading.
        assert_eq!(key_for_keyval(gdk::Key::period), Some(Key::character(".")));
    }

    #[test]
    fn an_ascii_letter_keeps_the_to_unicode_path() {
        // Ctrl is a modifier, not part of the keysym: 'a' arrives as the same
        // keyval with and without it.
        assert_eq!(key_for_keyval(gdk::Key::a), Some(Key::character("a")));
    }

    #[test]
    fn keysyms_the_core_has_no_key_for_refuse() {
        // Home and Delete have no Key variant; refusing beats inventing one.
        assert_eq!(key_for_keyval(gdk::Key::Home), None);
        assert_eq!(key_for_keyval(gdk::Key::Delete), None);
        // F1 is printable nowhere: to_unicode cannot answer it either.
        assert_eq!(key_for_keyval(gdk::Key::F1), None);
    }

    #[test]
    fn ctrl_tab_spelled_primary_answers_through_the_collapsed_door() {
        // This host reports Ctrl as primary, and the keymap binds Ctrl+Tab
        // with the control modifier, so the exact-match door returns None for
        // this spelling (the core's own
        // `primary_and_control_are_not_the_same_modifier`). The collapsed door
        // is the contract this shell depends on.
        let map = zer0_core::Keymap::with_defaults();
        let ctrl_tab = zer0_core::Chord::new(Key::Tab, zer0_core::Modifiers::primary());
        assert_eq!(
            map.command_for_collapsed(&ctrl_tab),
            Some(UiCommand::NextTab)
        );
    }

    #[test]
    fn tab_scoped_items_take_only_the_destroyed_tabs_copies() {
        let first_tab = zer0_core::TabId(1);
        let second_tab = zer0_core::TabId(2);
        let mut copies = TabScoped::default();
        copies.insert(7, first_tab, "first");
        copies.insert(8, second_tab, "second");
        copies.insert(9, first_tab, "third");

        let mut removed = copies.take_for_tab(first_tab);
        removed.sort_unstable();

        assert_eq!(removed, vec!["first", "third"]);
        assert_eq!(copies.remove(8), Some("second"));
    }

    #[test]
    fn an_older_retreat_cannot_clear_a_replacing_image_copy_notice() {
        let mut notice = ImageCopyNoticeState::default();
        let older = notice.replace(image_copy::Outcome::Copied);
        let newer = notice.replace(image_copy::Outcome::Failed(image_copy::Failure::TooLarge));

        assert!(!notice.retreat(older));
        assert_eq!(
            notice.outcome(),
            Some(image_copy::Outcome::Failed(image_copy::Failure::TooLarge))
        );
        assert!(notice.retreat(newer));
        assert_eq!(notice.outcome(), None);
    }
}
