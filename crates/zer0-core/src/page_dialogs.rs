//! What a page said to the person, in the page's own words.
//!
//! `alert()`, `confirm()`, `prompt()` and `<input type="file">` all arrive on
//! the same `WKUIDelegate` as the camera (ADR-0056), and until now none of them
//! was implemented. An unimplemented optional is not a refusal: measured, the
//! engine answers `alert()` by doing nothing, `confirm()` with **false**,
//! `prompt()` with **null**, and a file control by never opening a panel. All
//! four are silent, and the middle two are the browser answering a question on
//! somebody's behalf without telling them.
//!
//! ## Why any of this is in the core
//!
//! The words on these panels are the *site's*, not ours, and that is the one
//! thing here a platform cannot be allowed to vary: which origin gets named,
//! how much of the page's text is shown, whether a background tab may
//! interrupt, and that a cancel still answers. What is drawn — the material,
//! the buttons' labels, the spacing — is the shell's, per ADR-0053.
//!
//! ## The invariant
//!
//! **Every request is answered exactly once.** These calls are synchronous
//! inside the page: `alert()` blocks the script until the handler runs and
//! never otherwise, so a handler dropped on the floor is a page frozen with
//! nothing on screen — the same failure ADR-0056 keeps the permission ledger on
//! the host to avoid, one method along.
//!
//! ## What is decided without anybody being asked
//!
//! - **A tab you are not looking at does not interrupt you.** It is *held*
//!   rather than answered: a background page calling `alert()` is blocked
//!   already, which is what `alert()` means, and it gets its panel when you
//!   look at the tab. Answering it silently is the defect this file exists to
//!   end, and the browser must not commit it in the name of fixing it.
//! - **A second question from a tab that is already holding one is cancelled.**
//!   Not queued: a queue of page dialogs is a page with a waiting room.
//! - **A page somebody silenced is cancelled**, until that tab navigates. That
//!   is not a silent answer — it is the answer they gave, on a control that
//!   said what it would do.

use crate::model::{Browser, TabId, WindowId};
use crate::site_permissions::{ReportedOrigin, canonical_origin};

/// How many dialogs one page may raise before it is offered a way to be
/// stopped.
///
/// Two, so the control appears on the *second* one. A checkbox on the first
/// `alert()` a site ever shows is the browser suggesting the page is hostile
/// before it has done anything; a page that has interrupted twice in one
/// reading has, and by then the offer is the thing the person is looking for.
pub const DIALOGS_BEFORE_SILENCE: u32 = 2;

/// The longest run of the page's own text this browser will draw.
///
/// A cap rather than a scroll view alone, because the string crosses an FFI
/// boundary and is re-read on every dispatch, and a page is free to hand over
/// megabytes. Long enough that no honest `confirm()` is ever cut — the longest
/// in the wild are a paragraph — and short enough that the pathological one
/// costs nothing. What is cut is *said* to be cut: see
/// [`PageDialog::message_truncated`].
pub const MESSAGE_LIMIT: usize = 2_000;

/// Which of the four panels this is.
///
/// An enum with fields rather than four flat cases plus four optional
/// side-fields: `default_text` means nothing on an alert and `multiple` means
/// nothing on a prompt, and a record with three fields that are only sometimes
/// real is a record every reader has to be told how to read. It also makes the
/// shell's `switch` exhaustive, so a fifth panel breaks the build until it
/// earns behaviour (AGENTS.md).
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum PageDialogKind {
    /// `alert(message)`. There is nothing to decide; the page is waiting to be
    /// told it was read.
    Alert,
    /// `confirm(message)`. **The one that was dangerous.** Unimplemented, the
    /// engine answers `false` — a Cancel nobody pressed. Today that fails safe
    /// for "delete this?"; it fails the other way the first time a page phrases
    /// the question as "keep my changes?".
    Confirm,
    /// `prompt(message, default)`. `default_text` is the page's suggestion and
    /// is the page's words, not ours.
    Prompt { default_text: String },
    /// `<input type="file">`, which is not a dialog we draw: the panel is the
    /// system's file picker. It is in this vocabulary because the two rules
    /// that matter are the same two — a background tab must not open one, and
    /// a cancel must still answer, or the page's `change` event never comes and
    /// the upload button stays dead forever.
    ///
    /// `multiple` is `<input multiple>` and `directories` is
    /// `<input webkitdirectory>`, both measured off `WKOpenPanelParameters`.
    /// **There is no third field for `accept`** and that is not an omission:
    /// the public interface carries exactly these two booleans, so this browser
    /// cannot filter by type and does not pretend to (ADR-0018).
    ChooseFiles { multiple: bool, directories: bool },
}

/// The longest extension name this browser will draw on a panel.
///
/// Shorter than [`MESSAGE_LIMIT`] and for a different reason. A message is
/// content and scrolls; a name sits on the identity line, which is one line, and
/// a package free to write a paragraph there could push everything the browser
/// says off the panel. Long enough for every real extension name — the longest
/// on the Chrome store are a short sentence — and the cut is not announced,
/// because the identity line is not a quotation the person is meant to read to
/// the end. Whether it was cut is [`PageDialogSpeaker::Extension::name_truncated`].
pub const EXTENSION_NAME_LIMIT: usize = 80;

/// Where a request came from, before anything has been decided about it.
///
/// **The extension case has no field an origin fits in, and that is the whole
/// design.** An extension popup's document really does have an origin —
/// `webkit-extension://` and a UUID, measured — and it is worse than nothing on
/// a panel: it looks like a domain, it is not one, and no person has ever seen
/// it before. A shape that carried both would leave somebody a choice about
/// which to draw, and the wrong choice reads as an address (AGENTS.md: a
/// guarantee is structural or it is not a guarantee).
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum PageDialogSource {
    /// A frame in a page. Uninterpreted; [`canonical_origin`] is what decides
    /// whether it is an origin at all.
    Frame { origin: ReportedOrigin },
    /// An extension's own popup, named by the name the person installed it
    /// under — already resolved through `_locales`, so it is the name on the
    /// button rather than `__MSG_extName__`.
    ///
    /// **The name is the extension's own string and is treated as one.** See
    /// [`PageDialogSpeaker::Extension`].
    Extension { name: String },
}

/// Who is talking, in the only spelling that cannot be faked.
///
/// Three cases rather than an `Option<String>`, because each has something the
/// others do not. A `file://` page, a `data:` URL and a sandboxed frame all
/// report an origin that is empty or shared with every other document of their
/// shape, and a panel that left the line blank for them would be a panel whose
/// identity line is sometimes absent — which is the line a spoof needs.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum PageDialogSpeaker {
    /// `scheme://host[:port]`, canonically spelled. The host is punycode where
    /// the real one was not ASCII, so a string of Cyrillic that draws as
    /// `apple.com` arrives as `xn--80ak6aa92e.com` and says so.
    ///
    /// `host` is the same string without the scheme, for the sentence the panel
    /// opens with. Both, rather than the shell splitting one: which part of an
    /// origin is the host is a question with exactly one right answer, and a
    /// second implementation of it in a shell is a second answer waiting to
    /// disagree with `site_permissions::host_of`.
    Site { origin: String, host: String },
    /// An extension the person installed, asking from its own popup.
    ///
    /// **This is not a `Site` with a different string in it**, and the
    /// difference is the point. An origin is a fact the browser derived from an
    /// address it fetched; an extension's name is a string the extension wrote
    /// about itself, and an extension may call itself `google.com`. So the name
    /// is carried on its own, it is never enough on its own to say who is
    /// talking, and whatever draws it has to say "an extension" in the
    /// browser's own words first.
    ///
    /// `name` may be **empty**, and that is not repaired. A package is free to
    /// declare no name; inventing one, or falling back to the id — which is 32
    /// letters nobody recognises — would be the repair-that-guesses AGENTS.md
    /// warns about, on the one line that exists to say who is responsible.
    Extension { name: String, name_truncated: bool },
    /// A page with no origin anybody could act on. Named as what it is rather
    /// than as a name it does not have.
    Nameless { note: String },
}

/// What the engine reported, before anything has been decided about it.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct PageDialogRequest {
    /// The host's handle for the completion handler it is holding.
    pub request: u64,
    pub tab: TabId,
    pub kind: PageDialogKind,
    /// Whether a page's frame asked, or an extension's own popup did.
    pub source: PageDialogSource,
    /// The page's own words, exactly as the page wrote them. Empty for a file
    /// control, which says nothing.
    pub message: String,
    /// The shell's clock, at the moment the engine asked. The core has none
    /// (ADR-0002), and the settle window below is measured against this.
    pub asked_at_ms: u64,
}

/// A question on screen, or waiting for its tab to come to the front.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct PageDialog {
    pub request: u64,
    pub tab: TabId,
    /// The window this belongs on. A panel raised by a tab in another window is
    /// that window's business; drawing it on all of them would let a page in
    /// one window take the keyboard in another.
    pub window: WindowId,
    pub kind: PageDialogKind,
    pub speaker: PageDialogSpeaker,
    /// The page's own words, capped at [`MESSAGE_LIMIT`] characters.
    ///
    /// **Never the browser's.** Whatever draws this must keep it visibly a
    /// quotation: a site's string that reads as the browser talking is how a
    /// page gets to say "your password has expired" in our voice.
    pub message: String,
    /// Whether the cap above cut anything off. Said out loud rather than
    /// trailing an ellipsis nobody can tell from the page's own: a panel that
    /// silently shows part of a sentence is asserting it showed all of it.
    pub message_truncated: bool,
    /// Whether this page has interrupted often enough to be worth offering to
    /// stop. See [`DIALOGS_BEFORE_SILENCE`].
    pub offers_silence: bool,
    /// When the question went up, by the shell's clock.
    ///
    /// The same defence, and the same number, as the camera sheet's: a page
    /// picks the moment it interrupts, so the Return that lands first is the
    /// one that was already on its way down when it did.
    /// [`crate::site_permissions::answered_too_soon`] is what enforces it, and
    /// it is that function rather than a second copy of the arithmetic because
    /// two panels a page can summon must not disagree about how long half a
    /// second is (ADR-0056).
    pub asked_at_ms: u64,
}

/// What the person said back.
///
/// Four cases and not two, because the panels carry different things home and
/// a single "ok plus an optional string plus an optional list" is a shape every
/// reader has to be told how to read.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum PageDialogAnswer {
    /// OK, with nothing to carry: an alert that was read, a confirm accepted.
    Accepted,
    /// What was typed into a `prompt()`. Empty is a real answer and is not the
    /// same as [`PageDialogAnswer::Cancelled`].
    Typed { text: String },
    /// The files that were picked. Never empty — picking nothing is a cancel.
    Chose { paths: Vec<String> },
    /// Cancel, Escape, the tab closing, or the page being silenced. `confirm()`
    /// is told no, `prompt()` that nothing was typed, and the file control that
    /// nothing was picked.
    Cancelled,
}

/// What to do about a request that just arrived.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DialogGate {
    /// Answer the page now, with nobody asked. Always
    /// [`PageDialogAnswer::Cancelled`] — there is no path here that says yes on
    /// somebody's behalf.
    Answer(PageDialogAnswer),
    /// Hold it against its tab. It goes on screen when that tab is the one its
    /// window is showing, which for a foreground tab is immediately.
    Hold(Box<PageDialog>),
}

/// Every page dialog waiting on an answer, and what pages have been silenced.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct PageDialogs {
    /// At most one per tab, oldest first. Order is what decides which of two
    /// visible tabs gets the screen, and it must not depend on a hash walk.
    held: Vec<PageDialog>,
    /// Tabs whose page was told to stop asking, until the tab navigates.
    silenced: Vec<TabId>,
    /// How many dialogs each tab's page has raised since it last navigated.
    /// Never persisted: this is about one page's behaviour right now.
    raised: Vec<(TabId, u32)>,
}

impl PageDialogs {
    pub fn new() -> Self {
        Self::default()
    }

    /// The ones that are on screen: at most one per window, oldest first.
    ///
    /// **Per window, not one for the whole browser.** Two windows can each be
    /// showing a page that asked something, and they are two people's-worth of
    /// screen — a single answer here would leave the second window's page
    /// frozen until the first was dealt with, which is a browser one page can
    /// stop.
    ///
    /// Within a window it *is* one, because a split shows two pages at once and
    /// two sheets over one window is one sheet nobody can reach. Oldest wins,
    /// so a page cannot jump the queue by being clicked on.
    pub fn on_screen(&self, browser: &Browser) -> Vec<PageDialog> {
        let mut out: Vec<PageDialog> = Vec::new();
        for dialog in &self.held {
            if !is_on_screen(browser, dialog.tab) {
                continue;
            }
            if out.iter().any(|shown| shown.window == dialog.window) {
                continue;
            }
            out.push(dialog.clone());
        }
        out
    }

    /// Everything held, for the tests and for the reducer's lifecycle arms.
    pub fn held(&self) -> &[PageDialog] {
        &self.held
    }

    pub fn is_silenced(&self, tab: TabId) -> bool {
        self.silenced.contains(&tab)
    }

    /// How many times this tab's page has interrupted since it last navigated.
    pub fn raised_by(&self, tab: TabId) -> u32 {
        self.raised
            .iter()
            .find(|(t, _)| *t == tab)
            .map_or(0, |(_, n)| *n)
    }

    pub(crate) fn hold(&mut self, dialog: PageDialog) {
        self.held.push(dialog);
    }

    pub(crate) fn count_raise(&mut self, tab: TabId) -> u32 {
        match self.raised.iter_mut().find(|(t, _)| *t == tab) {
            Some((_, n)) => {
                *n += 1;
                *n
            }
            None => {
                self.raised.push((tab, 1));
                1
            }
        }
    }

    /// Take the dialog with this number, if it is still held.
    ///
    /// By request number rather than by tab, so an answer to a question that
    /// has already gone answers nothing.
    pub(crate) fn take(&mut self, request: u64) -> Option<PageDialog> {
        let at = self.held.iter().position(|d| d.request == request)?;
        Some(self.held.remove(at))
    }

    /// Take everything this tab was asking. Called where the web view goes, so
    /// nothing is left holding a handler that died with it.
    pub(crate) fn take_all_for(&mut self, tab: TabId) -> Vec<PageDialog> {
        let mut taken = Vec::new();
        let mut i = 0;
        while i < self.held.len() {
            if self.held[i].tab == tab {
                taken.push(self.held.remove(i));
            } else {
                i += 1;
            }
        }
        taken
    }

    pub(crate) fn silence(&mut self, tab: TabId) {
        if !self.silenced.contains(&tab) {
            self.silenced.push(tab);
        }
    }

    /// A new page in this tab is a new page. Silence, the count and nothing
    /// else: whatever is still held is a question the old page asked and it is
    /// answered where the navigation is handled, not forgotten here.
    pub(crate) fn tab_navigated(&mut self, tab: TabId) {
        self.silenced.retain(|t| *t != tab);
        self.raised.retain(|(t, _)| *t != tab);
    }

    /// The tab is gone for good. Called after its dialogs have been answered.
    pub(crate) fn forget_tab(&mut self, tab: TabId) {
        self.silenced.retain(|t| *t != tab);
        self.raised.retain(|(t, _)| *t != tab);
    }
}

/// Whether this tab is one somebody can see right now.
///
/// Per **window**, deliberately, and this is not the same question
/// `site_permissions::is_visible` asks. That one is about the key window only
/// and refuses anything else, which is correct for a camera: an answer nobody
/// is looking at should fail closed. A page dialog cannot fail closed and stay
/// honest — the page is frozen until it is answered — so what matters here is
/// whether the tab is the one its own window is showing. A second window's
/// front tab is on somebody's screen even when the keyboard is elsewhere.
///
/// Also asked by `Action::PageAskedToPrint`, which is the same question about
/// the same kind of caller: a page asking for a modal on a window. Shared rather
/// than copied, because two answers to "can somebody see this tab" would drift
/// and only one of them would ever be tested.
pub(crate) fn is_on_screen(browser: &Browser, tab: TabId) -> bool {
    let Some(entry) = browser.tab(tab) else {
        return false;
    };
    let Some(window) = browser.window(entry.window) else {
        return false;
    };
    if window.active_tab == Some(tab) {
        return true;
    }
    // A split shows two pages at once, and both are pages you are looking at.
    // The split belongs to the space, so it only counts for a window that is
    // showing that space.
    browser
        .space(window.active_space)
        .and_then(|space| space.split.as_ref())
        .is_some_and(|split| split.leading == tab || split.trailing == tab)
}

/// Decide what happens to a request the engine just handed over.
///
/// Every refusal here is a *cancel* — the neutral answer, the one that grants
/// nothing and types nothing. There is no branch that accepts on somebody's
/// behalf, which is the whole difference between this and the engine's own
/// defaults.
pub fn gate(browser: &Browser, dialogs: &PageDialogs, request: &PageDialogRequest) -> DialogGate {
    let Some(tab) = browser.tab(request.tab) else {
        return DialogGate::Answer(PageDialogAnswer::Cancelled);
    };

    // Somebody asked for this page to stop, on a control that said what it
    // would do. It lasts until the tab navigates.
    if dialogs.is_silenced(request.tab) {
        return DialogGate::Answer(PageDialogAnswer::Cancelled);
    }

    // One per tab. `alert()` blocks the script that called it, so a page
    // cannot normally reach here twice — but a cross-origin frame runs in a
    // process of its own, and "cannot normally" is not a guarantee.
    if dialogs.held.iter().any(|d| d.tab == request.tab) {
        return DialogGate::Answer(PageDialogAnswer::Cancelled);
    }

    let (message, message_truncated) = cap(&request.message);

    DialogGate::Hold(Box::new(PageDialog {
        request: request.request,
        tab: request.tab,
        window: tab.window,
        kind: request.kind.clone(),
        speaker: speaker(&request.source),
        message,
        message_truncated,
        asked_at_ms: request.asked_at_ms,
        // The count includes this one, so the offer appears on the second.
        offers_silence: dialogs.raised_by(request.tab) + 1 >= DIALOGS_BEFORE_SILENCE,
    }))
}

/// The page's words, cut to [`MESSAGE_LIMIT`], and whether anything was cut.
fn cap(message: &str) -> (String, bool) {
    cut(message, MESSAGE_LIMIT)
}

/// The first `limit` characters of an untrusted string, and whether there were
/// more.
///
/// **Characters, not bytes**: a cut in the middle of a UTF-8 sequence is a panel
/// drawing a replacement glyph, and `String::truncate` would panic on one.
///
/// One function for both strings a package or a page can make arbitrarily long,
/// because two copies of this arithmetic is two places a limit can be raised
/// and only one of them noticed.
fn cut(text: &str, limit: usize) -> (String, bool) {
    let mut kept = String::new();
    for (taken, ch) in text.chars().enumerate() {
        if taken == limit {
            return (kept, true);
        }
        kept.push(ch);
    }
    (kept, false)
}

/// Who is talking.
///
/// [`canonical_origin`] is the same function the camera sheet is keyed by, and
/// reusing it is the point: two spellings of "which site is this" is two
/// answers, and the one that matters is the one that turns an
/// internationalised host into punycode.
///
/// **An extension does not go through it at all.** Its popup's origin is a UUID
/// under a scheme the person has never seen, so there is nothing for
/// `canonical_origin` to make readable and every answer it could give would be
/// wrong on the line that says who is responsible.
fn speaker(source: &PageDialogSource) -> PageDialogSpeaker {
    let origin = match source {
        PageDialogSource::Frame { origin } => origin,
        PageDialogSource::Extension { name } => {
            let (name, name_truncated) = cut(name, EXTENSION_NAME_LIMIT);
            return PageDialogSpeaker::Extension {
                name,
                name_truncated,
            };
        }
    };
    match canonical_origin(origin) {
        Some(origin) => PageDialogSpeaker::Site {
            host: crate::site_permissions::host_of(&origin),
            origin,
        },
        // Deliberately does not name the scheme it saw. `file`, `data`,
        // `about` and a sandboxed frame's empty string are all the same fact
        // from the person's side — there is nothing here to hold responsible —
        // and a panel that printed `data:` would be handing a hostile page a
        // place to write.
        None => PageDialogSpeaker::Nameless {
            note: "This page has no address of its own, so there is nobody to \
                   hold to what it says."
                .to_string(),
        },
    }
}

#[cfg(test)]
#[path = "page_dialogs_tests.rs"]
mod tests;
