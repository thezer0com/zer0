//! Deliberately lopsided, the same way `site_permissions_tests` is and for a
//! different reason.
//!
//! Almost nothing here is about a panel being answered. Almost everything is
//! about a page that is **waiting** — because these calls block the script that
//! made them, and the failure this whole file exists to prevent is a handler
//! nobody calls. That failure shows up as a tab that has simply stopped, with
//! nothing on screen saying why, on some other day, in some other file.

use super::*;

use crate::protocol::{Action, EngineCommand, WindowContents};
use crate::session::Session;

fn session() -> Session {
    let mut session = Session::new("Personal", "jar-personal");
    open(&mut session, "https://example.com/");
    session
}

/// Through the reducer, so every test starts from a browser that got where it
/// is the way the browser does.
fn open(session: &mut Session, url: &str) -> TabId {
    crate::reducer::dispatch(
        session,
        Action::OpenTab {
            space: None,
            url: Some(url.to_string()),
            parent: None,
        },
    );
    session.browser.active_tab().expect("a tab")
}

fn origin(host: &str) -> ReportedOrigin {
    ReportedOrigin {
        scheme: "https".into(),
        host: host.into(),
        port: 0,
    }
}

fn request(id: u64, tab: TabId, kind: PageDialogKind) -> PageDialogRequest {
    PageDialogRequest {
        request: id,
        tab,
        kind,
        source: PageDialogSource::Frame {
            origin: origin("example.com"),
        },
        message: "the site wrote this".into(),
        // Far enough back that every answer below is outside the settle window
        // by default; the one test that is about the window sets its own.
        asked_at_ms: 1_000,
    }
}

/// What the engine was told, out of whatever the reducer produced.
fn answers(commands: &[EngineCommand]) -> Vec<(u64, PageDialogAnswer)> {
    let mut out = Vec::new();
    for command in commands {
        if let EngineCommand::AnswerPageDialog { request, answer } = command {
            out.push((*request, answer.clone()));
        }
    }
    out
}

/// The dialog a person can see, if there is one. Everything below asks about
/// one window's worth of screen.
fn showing(session: &Session) -> Option<PageDialog> {
    session
        .page_dialogs
        .on_screen(&session.browser)
        .into_iter()
        .next()
}

fn raise(session: &mut Session, request: PageDialogRequest) -> Vec<EngineCommand> {
    crate::reducer::dispatch(session, Action::PageRaisedDialog { request })
}

// MARK: - Every request is answered exactly once

/// The whole file in one test. Before this existed the engine's own answer to
/// an unimplemented `confirm()` was `false` — a Cancel nobody pressed — and to
/// an unimplemented `alert()` was nothing at all.
#[test]
fn a_page_that_asks_is_asked_about_and_told_nothing_until_somebody_answers() {
    let mut session = session();
    let tab = session.browser.active_tab().expect("a tab");

    let commands = raise(&mut session, request(1, tab, PageDialogKind::Confirm));

    assert!(
        answers(&commands).is_empty(),
        "the page was answered by the browser rather than by a person"
    );
    let showing = showing(&session).expect("the question has to be on screen");
    assert_eq!(showing.request, 1);
    assert_eq!(showing.message, "the site wrote this");
}

#[test]
fn an_answer_reaches_the_page_and_the_question_goes() {
    let mut session = session();
    let tab = session.browser.active_tab().expect("a tab");
    raise(&mut session, request(1, tab, PageDialogKind::Confirm));

    let commands = crate::reducer::dispatch(
        &mut session,
        Action::AnsweredPageDialog {
            request: 1,
            answer: PageDialogAnswer::Accepted,
            silence: false,
            decided_at_ms: 1_000_000,
        },
    );

    assert_eq!(answers(&commands), vec![(1, PageDialogAnswer::Accepted)]);
    assert!(showing(&session).is_none());
}

/// The one that would have been the old behaviour dressed up. Cancel has to be
/// an *answer*, not a way of not answering.
#[test]
fn cancelling_still_answers_the_page() {
    let mut session = session();
    let tab = session.browser.active_tab().expect("a tab");
    raise(
        &mut session,
        request(
            1,
            tab,
            PageDialogKind::Prompt {
                default_text: "ada".into(),
            },
        ),
    );

    let commands = crate::reducer::dispatch(
        &mut session,
        Action::AnsweredPageDialog {
            request: 1,
            answer: PageDialogAnswer::Cancelled,
            silence: false,
            decided_at_ms: 1_000_000,
        },
    );

    assert_eq!(answers(&commands), vec![(1, PageDialogAnswer::Cancelled)]);
    assert!(session.page_dialogs.held().is_empty());
}

/// Empty is a real answer to `prompt()` and is not the same as pressing Cancel.
#[test]
fn typing_nothing_is_not_the_same_as_cancelling() {
    let mut session = session();
    let tab = session.browser.active_tab().expect("a tab");
    raise(
        &mut session,
        request(
            1,
            tab,
            PageDialogKind::Prompt {
                default_text: String::new(),
            },
        ),
    );

    let commands = crate::reducer::dispatch(
        &mut session,
        Action::AnsweredPageDialog {
            request: 1,
            answer: PageDialogAnswer::Typed {
                text: String::new(),
            },
            silence: false,
            decided_at_ms: 1_000_000,
        },
    );

    assert_eq!(
        answers(&commands),
        vec![(
            1,
            PageDialogAnswer::Typed {
                text: String::new()
            }
        )]
    );
}

/// Picking nothing in a file panel is a cancel. An empty list handed to a file
/// control reads as "clear what was there", which is not what Cancel means.
#[test]
fn choosing_no_files_is_a_cancel_rather_than_an_empty_selection() {
    let mut session = session();
    let tab = session.browser.active_tab().expect("a tab");
    raise(
        &mut session,
        request(
            1,
            tab,
            PageDialogKind::ChooseFiles {
                multiple: false,
                directories: false,
            },
        ),
    );

    let commands = crate::reducer::dispatch(
        &mut session,
        Action::AnsweredPageDialog {
            request: 1,
            answer: PageDialogAnswer::Chose { paths: Vec::new() },
            silence: false,
            decided_at_ms: 1_000_000,
        },
    );

    assert_eq!(answers(&commands), vec![(1, PageDialogAnswer::Cancelled)]);
}

#[test]
fn a_second_answer_to_the_same_question_calls_nothing() {
    let mut session = session();
    let tab = session.browser.active_tab().expect("a tab");
    raise(&mut session, request(1, tab, PageDialogKind::Alert));

    let answer = |session: &mut Session| {
        crate::reducer::dispatch(
            session,
            Action::AnsweredPageDialog {
                request: 1,
                answer: PageDialogAnswer::Accepted,
                silence: false,
                decided_at_ms: 1_000_000,
            },
        )
    };
    assert_eq!(answers(&answer(&mut session)).len(), 1);
    assert!(
        answers(&answer(&mut session)).is_empty(),
        "a completion handler called twice is a crash in the engine, not a duplicate"
    );
}

/// The same defence the camera sheet has, enforced by the same function. A page
/// picks the moment it interrupts, so the Return that lands first is the one
/// that was already on its way down when it did.
#[test]
fn an_answer_nobody_could_have_given_in_the_time_changes_nothing() {
    let mut session = session();
    let tab = session.browser.active_tab().expect("a tab");
    let mut asked = request(1, tab, PageDialogKind::Confirm);
    asked.asked_at_ms = 10_000;
    raise(&mut session, asked);

    let commands = crate::reducer::dispatch(
        &mut session,
        Action::AnsweredPageDialog {
            request: 1,
            answer: PageDialogAnswer::Accepted,
            silence: false,
            decided_at_ms: 10_000 + crate::site_permissions::PROMPT_SETTLE_MS - 1,
        },
    );

    assert!(
        answers(&commands).is_empty(),
        "a keystroke already in flight said yes to a question the page chose the moment for"
    );
    assert!(
        showing(&session).is_some(),
        "the question has to still be on screen, or a race silently answered it"
    );
}

/// The half second guards the **committing** side and nothing else. A cancel
/// commits nothing, the shell leaves Cancel and Escape live from the first
/// frame, and a core that dropped an early one would leave a live button doing
/// nothing with a frozen page behind it.
#[test]
fn a_cancel_is_never_too_soon() {
    let mut session = session();
    let tab = session.browser.active_tab().expect("a tab");
    let mut asked = request(1, tab, PageDialogKind::Confirm);
    asked.asked_at_ms = 10_000;
    raise(&mut session, asked);

    let commands = crate::reducer::dispatch(
        &mut session,
        Action::AnsweredPageDialog {
            request: 1,
            answer: PageDialogAnswer::Cancelled,
            silence: false,
            decided_at_ms: 10_001,
        },
    );

    assert_eq!(answers(&commands), vec![(1, PageDialogAnswer::Cancelled)]);
    assert!(showing(&session).is_none());
}

/// The file picker is the system's own modal window with its own focus, so
/// there is no keystroke to defend against — and applying the window there is
/// how a picker somebody shut quickly left the page waiting forever.
#[test]
fn a_file_picker_answered_quickly_still_answers() {
    let mut session = session();
    let tab = session.browser.active_tab().expect("a tab");
    let mut asked = request(
        1,
        tab,
        PageDialogKind::ChooseFiles {
            multiple: false,
            directories: false,
        },
    );
    asked.asked_at_ms = 10_000;
    raise(&mut session, asked);

    let commands = crate::reducer::dispatch(
        &mut session,
        Action::AnsweredPageDialog {
            request: 1,
            answer: PageDialogAnswer::Chose {
                paths: vec!["/tmp/notes.txt".to_string()],
            },
            silence: false,
            decided_at_ms: 10_001,
        },
    );

    assert_eq!(
        answers(&commands),
        vec![(
            1,
            PageDialogAnswer::Chose {
                paths: vec!["/tmp/notes.txt".to_string()]
            }
        )],
        "a file somebody picked was dropped for arriving too fast"
    );
}

// MARK: - A tab you are not looking at does not interrupt you

/// The rule that stops a background tab taking the keyboard off the page you
/// are reading — **and** the rule that stops the fix being a silent answer.
#[test]
fn a_page_you_are_not_looking_at_waits_rather_than_interrupting_or_being_answered() {
    let mut session = session();
    let background = session.browser.active_tab().expect("a tab");
    let front = open(&mut session, "https://other.example/");
    assert_ne!(front, background);

    let commands = raise(
        &mut session,
        request(1, background, PageDialogKind::Confirm),
    );

    assert!(
        answers(&commands).is_empty(),
        "a background tab was answered on the person's behalf, which is the defect this \
         whole file exists to end"
    );
    assert!(
        showing(&session).is_none(),
        "a tab nobody is looking at put a panel in front of the page somebody is"
    );
    assert_eq!(
        session.page_dialogs.held().len(),
        1,
        "and it is still owed one"
    );
}

#[test]
fn a_question_that_waited_arrives_when_you_look_at_the_tab() {
    let mut session = session();
    let background = session.browser.active_tab().expect("a tab");
    open(&mut session, "https://other.example/");
    raise(&mut session, request(1, background, PageDialogKind::Alert));
    assert!(showing(&session).is_none());

    crate::reducer::dispatch(&mut session, Action::ActivateTab { tab: background });

    assert_eq!(showing(&session).map(|d| d.request), Some(1));
}

/// A split shows two pages at once, and both of them are pages you are looking
/// at. Refusing everything but the active tab would leave the left-hand pane
/// frozen with nothing on screen.
#[test]
fn a_pane_of_a_split_is_a_page_you_are_looking_at() {
    let mut session = session();
    let leading = session.browser.active_tab().expect("a tab");
    let trailing = open(&mut session, "https://other.example/");
    // Through the reducer, so the split is the one the browser would make. The
    // active tab is `trailing`; `leading` is the pane beside it.
    crate::reducer::dispatch(&mut session, Action::SplitWith { tab: leading });
    let split = session
        .browser
        .space(session.browser.active_space())
        .and_then(|s| s.split.clone())
        .expect("a split is what this test is about");
    assert!(split.leading == trailing || split.trailing == trailing);
    // The keyboard went to the pane that was just put beside the other one, so
    // `trailing` is the half of the split that is *not* the active tab — which
    // is exactly the case this test is about.
    assert_eq!(session.browser.active_tab(), Some(leading));

    raise(&mut session, request(1, trailing, PageDialogKind::Alert));

    assert_eq!(
        showing(&session).map(|d| d.request),
        Some(1),
        "the pane beside the active one is on screen, and its page froze with nothing on it"
    );
}

/// The panel belongs to the window its tab is in. A tab in a second window is
/// on somebody's screen even when the keyboard is in the first, and a panel
/// drawn on every window would let one window's page take another's keyboard.
#[test]
fn a_question_is_addressed_to_the_window_its_tab_is_in() {
    let mut session = session();
    let first = session.browser.active_tab().expect("a tab");
    let first_window = session.browser.tab(first).expect("a tab").window;
    crate::reducer::dispatch(
        &mut session,
        Action::OpenWindow {
            onto: WindowContents::CurrentSpace,
        },
    );
    let second = session.browser.active_tab().expect("a tab");
    let second_window = session.browser.tab(second).expect("a tab").window;
    assert_ne!(first_window, second_window);

    raise(&mut session, request(1, second, PageDialogKind::Alert));

    let showing =
        showing(&session).expect("the second window's front tab is a page somebody is looking at");
    assert_eq!(showing.window, second_window);
}

/// Two windows are two people's-worth of screen. One answer for the whole
/// browser would leave the second window's page frozen until the first was
/// dealt with, which is a browser one page can stop.
#[test]
fn two_windows_each_showing_a_question_each_get_theirs() {
    let mut session = session();
    let first = session.browser.active_tab().expect("a tab");
    let first_window = session.browser.tab(first).expect("a tab").window;
    crate::reducer::dispatch(
        &mut session,
        Action::OpenWindow {
            onto: WindowContents::CurrentSpace,
        },
    );
    let second = session.browser.active_tab().expect("a tab");
    let second_window = session.browser.tab(second).expect("a tab").window;

    raise(&mut session, request(1, first, PageDialogKind::Alert));
    raise(&mut session, request(2, second, PageDialogKind::Alert));

    let shown = session.page_dialogs.on_screen(&session.browser);
    assert_eq!(
        shown.len(),
        2,
        "one of the two windows was left with a frozen page"
    );
    assert!(
        shown
            .iter()
            .any(|d| d.window == first_window && d.request == 1)
    );
    assert!(
        shown
            .iter()
            .any(|d| d.window == second_window && d.request == 2)
    );
}

// MARK: - One at a time, and a way out of a loop

#[test]
fn a_second_question_from_one_tab_is_cancelled_rather_than_stacked() {
    let mut session = session();
    let tab = session.browser.active_tab().expect("a tab");
    raise(&mut session, request(1, tab, PageDialogKind::Alert));

    let commands = raise(&mut session, request(2, tab, PageDialogKind::Confirm));

    assert_eq!(answers(&commands), vec![(2, PageDialogAnswer::Cancelled)]);
    assert_eq!(
        showing(&session).map(|d| d.request),
        Some(1),
        "the first question was replaced by the second, which is how a page overwrites what \
         you were about to answer"
    );
}

/// The offer appears on the second interruption, not the first. A checkbox on
/// the first `alert()` a site ever shows is the browser calling it hostile
/// before it has done anything.
#[test]
fn the_offer_to_stop_a_page_appears_once_it_has_interrupted_twice() {
    let mut session = session();
    let tab = session.browser.active_tab().expect("a tab");

    raise(&mut session, request(1, tab, PageDialogKind::Alert));
    assert_eq!(showing(&session).map(|d| d.offers_silence), Some(false));
    crate::reducer::dispatch(
        &mut session,
        Action::AnsweredPageDialog {
            request: 1,
            answer: PageDialogAnswer::Accepted,
            silence: false,
            decided_at_ms: 1_000_000,
        },
    );

    raise(&mut session, request(2, tab, PageDialogKind::Alert));
    assert_eq!(showing(&session).map(|d| d.offers_silence), Some(true));
}

#[test]
fn a_page_told_to_stop_is_cancelled_without_being_shown() {
    let mut session = session();
    let tab = session.browser.active_tab().expect("a tab");
    raise(&mut session, request(1, tab, PageDialogKind::Alert));
    crate::reducer::dispatch(
        &mut session,
        Action::AnsweredPageDialog {
            request: 1,
            answer: PageDialogAnswer::Accepted,
            silence: true,
            decided_at_ms: 1_000_000,
        },
    );

    let commands = raise(&mut session, request(2, tab, PageDialogKind::Confirm));

    assert_eq!(answers(&commands), vec![(2, PageDialogAnswer::Cancelled)]);
    assert!(
        showing(&session).is_none(),
        "silencing a page has to stop the panels, or it is a checkbox that does nothing"
    );
}

/// Silence belongs to the page, not to the tab. A new page in the same tab has
/// not done anything yet.
#[test]
fn a_silenced_page_is_heard_again_once_the_tab_goes_somewhere_else() {
    let mut session = session();
    let tab = session.browser.active_tab().expect("a tab");
    raise(&mut session, request(1, tab, PageDialogKind::Alert));
    crate::reducer::dispatch(
        &mut session,
        Action::AnsweredPageDialog {
            request: 1,
            answer: PageDialogAnswer::Accepted,
            silence: true,
            decided_at_ms: 1_000_000,
        },
    );

    crate::reducer::dispatch(
        &mut session,
        Action::NavigationCommitted {
            tab,
            url: "https://example.com/next".into(),
        },
    );
    raise(&mut session, request(2, tab, PageDialogKind::Alert));

    assert!(showing(&session).is_some());
    assert_eq!(
        showing(&session).map(|d| d.offers_silence),
        Some(false),
        "the count has to start again with the page, or the second page a site serves \
         arrives already accused"
    );
}

// MARK: - Nothing is left waiting

#[test]
fn a_tab_that_closes_mid_question_does_not_leave_the_page_waiting_forever() {
    let mut session = session();
    let tab = session.browser.active_tab().expect("a tab");
    open(&mut session, "https://other.example/");
    raise(&mut session, request(1, tab, PageDialogKind::Confirm));

    let commands = crate::reducer::dispatch(&mut session, Action::CloseTab { tab });

    assert_eq!(answers(&commands), vec![(1, PageDialogAnswer::Cancelled)]);
    assert!(session.page_dialogs.held().is_empty());
}

#[test]
fn closing_a_space_answers_every_page_its_tabs_were_asking() {
    let mut session = session();
    crate::reducer::dispatch(
        &mut session,
        Action::CreateSpace {
            name: "Throwaway".into(),
            data_store_id: "jar-throwaway".into(),
            ephemeral: false,
        },
    );
    let space = session.browser.active_space();
    let tab = open(&mut session, "https://example.com/");
    raise(&mut session, request(1, tab, PageDialogKind::Alert));

    let commands = crate::reducer::dispatch(&mut session, Action::CloseSpace { space });

    assert_eq!(answers(&commands), vec![(1, PageDialogAnswer::Cancelled)]);
}

/// Closing the window a page is asking in. The same door as closing the tab —
/// `answer_pending_for` — and it is asserted separately because "the tabs went
/// with the window" is exactly the kind of thing that is true until somebody
/// takes a shortcut through it.
#[test]
fn closing_a_window_answers_every_page_its_tabs_were_asking() {
    let mut session = session();
    crate::reducer::dispatch(
        &mut session,
        Action::OpenWindow {
            onto: WindowContents::CurrentSpace,
        },
    );
    let tab = session.browser.active_tab().expect("a tab");
    let window = session.browser.tab(tab).expect("a tab").window;
    raise(&mut session, request(1, tab, PageDialogKind::Confirm));

    let commands = crate::reducer::dispatch(&mut session, Action::CloseWindow { window });

    assert_eq!(
        answers(&commands),
        vec![(1, PageDialogAnswer::Cancelled)],
        "a window closed over a page that was waiting inside `confirm()`, and nothing told it"
    );
    assert!(session.page_dialogs.held().is_empty());
}

/// The old page's question is about a page that is no longer loaded, and the
/// handler behind it still has to be told something.
#[test]
fn navigating_away_answers_the_question_the_old_page_was_asking() {
    let mut session = session();
    let tab = session.browser.active_tab().expect("a tab");
    raise(&mut session, request(1, tab, PageDialogKind::Confirm));

    let commands = crate::reducer::dispatch(
        &mut session,
        Action::NavigationCommitted {
            tab,
            url: "https://example.com/somewhere-else".into(),
        },
    );

    assert_eq!(answers(&commands), vec![(1, PageDialogAnswer::Cancelled)]);
    assert!(session.page_dialogs.held().is_empty());
}

#[test]
fn a_question_from_a_tab_that_is_already_gone_is_answered_and_not_held() {
    let mut session = session();
    let tab = session.browser.active_tab().expect("a tab");
    open(&mut session, "https://other.example/");
    crate::reducer::dispatch(&mut session, Action::CloseTab { tab });

    let commands = raise(&mut session, request(1, tab, PageDialogKind::Alert));

    assert_eq!(answers(&commands), vec![(1, PageDialogAnswer::Cancelled)]);
    assert!(session.page_dialogs.held().is_empty());
}

// MARK: - Whose words are whose

/// The identity line is the whole defence against a page writing in the
/// browser's voice, so it is the core that decides what it says — and it says
/// the punycode, which is the spelling that cannot be drawn as somebody else.
/// An extension is named as an extension, and never as a site.
///
/// The name below is the whole reason this is a separate case: a package is
/// free to call itself `google.com`, and if it arrived as
/// `PageDialogSpeaker::Site` every sentence the panel builds about a site would
/// be built about it.
#[test]
fn an_extension_is_named_as_an_extension_rather_than_as_a_site() {
    let mut session = session();
    let tab = session.browser.active_tab().expect("a tab");
    let mut asked = request(1, tab, PageDialogKind::Confirm);
    asked.source = PageDialogSource::Extension {
        name: "google.com".into(),
    };

    raise(&mut session, asked);

    let showing = showing(&session).expect("a dialog");
    assert_eq!(
        showing.speaker,
        PageDialogSpeaker::Extension {
            name: "google.com".into(),
            name_truncated: false,
        }
    );
}

/// A package free to write a paragraph on the identity line could push
/// everything the browser says off the panel.
#[test]
fn an_extension_that_calls_itself_a_paragraph_is_cut() {
    let mut session = session();
    let tab = session.browser.active_tab().expect("a tab");
    let mut asked = request(1, tab, PageDialogKind::Alert);
    asked.source = PageDialogSource::Extension {
        name: "é".repeat(EXTENSION_NAME_LIMIT + 40),
    };

    raise(&mut session, asked);

    let showing = showing(&session).expect("a dialog");
    match &showing.speaker {
        PageDialogSpeaker::Extension {
            name,
            name_truncated,
        } => {
            // Characters, not bytes: cut by bytes this name would end mid
            // sequence and draw a replacement glyph.
            assert_eq!(name.chars().count(), EXTENSION_NAME_LIMIT);
            assert!(name_truncated);
        }
        // Named rather than swept up: a fourth kind of speaker has to be
        // decided about here rather than land silently in a panic.
        other @ (PageDialogSpeaker::Site { .. } | PageDialogSpeaker::Nameless { .. }) => {
            panic!("named as {other:?}")
        }
    }
}

/// A package that declares no name gets no name. Falling back to the id — 32
/// letters nobody recognises — or to a word the browser made up would be a
/// repair that guesses, on the one line that says who is responsible.
#[test]
fn an_extension_with_no_name_is_not_given_one() {
    let mut session = session();
    let tab = session.browser.active_tab().expect("a tab");
    let mut asked = request(1, tab, PageDialogKind::Alert);
    asked.source = PageDialogSource::Extension {
        name: String::new(),
    };

    raise(&mut session, asked);

    let showing = showing(&session).expect("a dialog");
    assert_eq!(
        showing.speaker,
        PageDialogSpeaker::Extension {
            name: String::new(),
            name_truncated: false,
        }
    );
}

#[test]
fn an_internationalised_host_is_named_by_the_spelling_that_cannot_be_faked() {
    let mut session = session();
    let tab = session.browser.active_tab().expect("a tab");
    let mut asked = request(1, tab, PageDialogKind::Alert);
    // Draws as "рaypal.com" with a Cyrillic first letter.
    asked.source = PageDialogSource::Frame {
        origin: ReportedOrigin {
            scheme: "https".into(),
            host: "\u{440}aypal.com".into(),
            port: 0,
        },
    };

    raise(&mut session, asked);

    let showing = showing(&session).expect("a dialog");
    assert_eq!(
        showing.speaker,
        PageDialogSpeaker::Site {
            origin: "https://xn--aypal-uye.com".into(),
            host: "xn--aypal-uye.com".into(),
        }
    );
}

/// A page with no origin anybody could act on still gets a line saying so. A
/// panel whose identity line is sometimes simply absent is a panel with a
/// blank a spoof can stand in.
#[test]
fn a_page_with_no_address_of_its_own_says_so_rather_than_leaving_the_line_blank() {
    let mut session = session();
    let tab = session.browser.active_tab().expect("a tab");
    let mut asked = request(1, tab, PageDialogKind::Alert);
    asked.source = PageDialogSource::Frame {
        origin: ReportedOrigin {
            scheme: "file".into(),
            host: String::new(),
            port: 0,
        },
    };

    raise(&mut session, asked);

    let showing = showing(&session).expect("a dialog");
    match &showing.speaker {
        PageDialogSpeaker::Site { origin, .. } => panic!("a file page was named as {origin}"),
        PageDialogSpeaker::Extension { name, .. } => panic!("a file page was named as {name}"),
        PageDialogSpeaker::Nameless { note } => {
            assert!(!note.is_empty());
            // Naming the scheme would hand a hostile page a place to write.
            assert!(
                !note.contains("file"),
                "the note quotes the page's own scheme"
            );
        }
    }
}

#[test]
fn a_page_that_writes_a_book_is_cut_and_the_panel_knows_it_was() {
    let mut session = session();
    let tab = session.browser.active_tab().expect("a tab");
    let mut asked = request(1, tab, PageDialogKind::Alert);
    asked.message = "\u{e9}".repeat(MESSAGE_LIMIT + 500);

    raise(&mut session, asked);

    let showing = showing(&session).expect("a dialog");
    assert_eq!(showing.message.chars().count(), MESSAGE_LIMIT);
    assert!(
        showing.message_truncated,
        "a panel showing part of a sentence while asserting it showed all of it"
    );
}

#[test]
fn an_ordinary_message_is_carried_whole_and_unmarked() {
    let mut session = session();
    let tab = session.browser.active_tab().expect("a tab");
    let mut asked = request(1, tab, PageDialogKind::Alert);
    asked.message = "Your changes will be lost.".into();

    raise(&mut session, asked);

    let showing = showing(&session).expect("a dialog");
    assert_eq!(showing.message, "Your changes will be lost.");
    assert!(!showing.message_truncated);
}

/// What the file control asked for, carried and not interpreted.
#[test]
fn what_a_file_control_allows_is_carried_exactly_as_the_engine_reported_it() {
    let mut session = session();
    let tab = session.browser.active_tab().expect("a tab");
    raise(
        &mut session,
        request(
            1,
            tab,
            PageDialogKind::ChooseFiles {
                multiple: true,
                directories: true,
            },
        ),
    );

    let showing = showing(&session).expect("a dialog");
    assert_eq!(
        showing.kind,
        PageDialogKind::ChooseFiles {
            multiple: true,
            directories: true
        }
    );
}

// MARK: - window.print() (ADR-0101)

/// `window.print()` is the same kind of caller as `alert()` — a page asking for
/// a modal on a window — so it is asked the same question, through the same
/// function.
#[test]
fn a_page_may_print_the_page_you_are_looking_at() {
    let mut session = session();
    let tab = session.browser.active_tab().expect("a tab");

    let commands = crate::reducer::dispatch(&mut session, Action::PageAskedToPrint { tab });

    assert_eq!(commands, vec![EngineCommand::PrintPage { tab }]);
}

/// The panel is a sheet on the window its tab is in. A background tab printing
/// itself would put a modal over whatever you were actually reading, on behalf
/// of a page you cannot see.
///
/// Refused rather than held, which is where printing parts company with
/// `alert()`: nothing is blocked waiting for it, so a panel that arrived when
/// you next looked at the tab would be a modal with no cause anybody could name.
#[test]
fn a_page_you_are_not_looking_at_does_not_print_itself() {
    let mut session = session();
    let background = session.browser.active_tab().expect("a tab");
    let front = open(&mut session, "https://other.example/");
    assert_ne!(front, background);

    let commands =
        crate::reducer::dispatch(&mut session, Action::PageAskedToPrint { tab: background });

    assert!(commands.is_empty());
}

/// Both panes of a split are pages somebody is looking at, and the same
/// function says so for a dialog.
#[test]
fn a_pane_of_a_split_may_print_itself() {
    let mut session = session();
    let leading = session.browser.active_tab().expect("a tab");
    let trailing = open(&mut session, "https://other.example/");
    crate::reducer::dispatch(&mut session, Action::SplitWith { tab: leading });
    // The keyboard went to `leading`, so `trailing` is the pane beside the
    // active one — which is the case worth asking about.
    assert_eq!(session.browser.active_tab(), Some(leading));

    let commands =
        crate::reducer::dispatch(&mut session, Action::PageAskedToPrint { tab: trailing });

    assert_eq!(commands, vec![EngineCommand::PrintPage { tab: trailing }]);
}

/// A tab that closed between the page asking and the core answering.
#[test]
fn a_tab_that_is_gone_prints_nothing() {
    let mut session = session();
    let tab = session.browser.active_tab().expect("a tab");
    crate::reducer::dispatch(&mut session, Action::CloseTab { tab });

    let commands = crate::reducer::dispatch(&mut session, Action::PageAskedToPrint { tab });

    assert!(commands.is_empty());
}
