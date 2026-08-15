use super::*;
use crate::model::NavigationErrorKind;
use crate::protocol::Action;
use crate::reducer::dispatch;
use crate::session::Session;

fn declared(value: &str) -> DeclaredColor {
    DeclaredColor {
        value: value.into(),
        matches_appearance: true,
    }
}

fn for_appearance(value: &str, matches: bool) -> DeclaredColor {
    DeclaredColor {
        value: value.into(),
        matches_appearance: matches,
    }
}

/// The tint a page of exactly this description would get.
fn tint(theme: &[DeclaredColor], backgrounds: &[&str], canvas: Option<&str>) -> Option<PageTint> {
    let backgrounds: Vec<String> = backgrounds.iter().map(|b| (*b).to_string()).collect();
    tint_for(theme, &backgrounds, canvas)
}

fn contrast(one: f64, other: f64) -> f64 {
    let lighter = one.max(other);
    let darker = one.min(other);
    (lighter + 0.05) / (darker + 0.05)
}

// MARK: - The chain

#[test]
fn a_declared_theme_colour_beats_the_background() {
    let tint = tint(
        &[declared("#0b3d91")],
        &["rgb(255, 255, 255)"],
        Some("rgb(255, 255, 255)"),
    )
    .expect("a page that states its colour has one");

    assert_eq!(tint.rgb, 0x000B_3D91);
}

/// A site may state one colour for light and another for dark. Taking the first
/// tag rather than the matching one paints a dark window in the light brand.
#[test]
fn the_declaration_for_this_appearance_wins_not_the_first_one() {
    let tint = tint(
        &[
            for_appearance("#ffffff", false),
            for_appearance("#101014", true),
        ],
        &[],
        None,
    )
    .expect("one of the two declarations matches");

    assert_eq!(tint.rgb, 0x0010_1014);
}

/// Most of the web has never heard of `theme-color`, so this rung is the common
/// case and not the edge.
#[test]
fn without_a_theme_colour_the_page_background_is_the_colour() {
    let tint = tint(&[], &["rgb(18, 18, 24)", "rgb(255, 0, 0)"], None)
        .expect("the document element states a background");

    assert_eq!(tint.rgb, 0x0012_1218);
}

/// `rgba(0, 0, 0, 0)` is what `getComputedStyle` reports for the great majority
/// of documents. Falling through it is how the chain reaches the rung that
/// knows what was actually painted.
#[test]
fn a_transparent_background_falls_through_to_what_was_painted() {
    let tint = tint(
        &[],
        &["rgba(0, 0, 0, 0)", "rgba(0, 0, 0, 0)"],
        Some("rgb(255, 255, 255)"),
    )
    .expect("the engine can say what it painted");

    assert_eq!(tint.rgb, 0x00FF_FFFF);
    assert!(tint.prefers_dark_ink);
}

#[test]
fn a_page_that_says_nothing_has_no_colour() {
    assert_eq!(tint(&[], &[], None), None);
    assert_eq!(tint(&[], &["rgba(0, 0, 0, 0)"], None), None);
    assert_eq!(tint(&[declared("transparent")], &[], None), None);
}

/// What sits behind a half-transparent background is the engine's canvas, and a
/// guess about it shows up as a strip that does not match the page it is welded
/// to. Refused rather than composited.
#[test]
fn a_translucent_colour_is_not_a_colour_we_can_use() {
    assert_eq!(
        tint(&[declared("rgba(255, 0, 0, 0.5)")], &["#00ff00"], None)
            .expect("the background is opaque")
            .rgb,
        0x0000_FF00
    );
    assert_eq!(tint(&[declared("#ff000080")], &[], None), None);
}

/// A declaration that does not parse is skipped rather than allowed to end the
/// chain: a page with a typo in one meta tag still has a background.
#[test]
fn an_unreadable_declaration_does_not_stop_the_chain() {
    let tint = tint(
        &[declared("papayawhip"), declared("#not-a-colour")],
        &["#123456"],
        None,
    )
    .expect("the background is readable");

    assert_eq!(tint.rgb, 0x0012_3456);
}

/// Hostile input: a page declaring thousands of colours costs a truncated
/// vector, not thousands of parses.
#[test]
fn only_the_first_few_declarations_are_read() {
    let mut many: Vec<DeclaredColor> = (0..MAX_DECLARED_COLORS)
        .map(|_| declared("not a colour"))
        .collect();
    many.push(declared("#ff0000"));

    assert_eq!(tint(&many, &["#0000ff"], None).map(|t| t.rgb), Some(0xFF));
}

// MARK: - Reading a colour

#[test]
fn every_syntax_a_page_might_write_is_read() {
    let cases: &[(&str, u32)] = &[
        ("#fff", 0x00FF_FFFF),
        ("#FFF", 0x00FF_FFFF),
        ("#ffff", 0x00FF_FFFF),
        ("#0b3d91", 0x000B_3D91),
        ("#0b3d91ff", 0x000B_3D91),
        ("  #0b3d91  ", 0x000B_3D91),
        ("rgb(11, 61, 145)", 0x000B_3D91),
        ("rgb(11 61 145)", 0x000B_3D91),
        ("rgb(11 61 145 / 1)", 0x000B_3D91),
        ("rgba(11, 61, 145, 1.0)", 0x000B_3D91),
        ("rgb(100%, 0%, 0%)", 0x00FF_0000),
        ("hsl(0, 100%, 50%)", 0x00FF_0000),
        ("hsl(120deg 100% 25%)", 0x0000_8000),
        ("hsla(240, 100%, 50%, 1)", 0x0000_00FF),
        ("white", 0x00FF_FFFF),
        ("BLACK", 0x0000_0000),
        ("orange", 0x00FF_A500),
    ];

    // `opaque` rather than the whole chain: this is about what a string means,
    // and a colour read correctly may still be adjusted for legibility
    // afterwards — `rgb(100%, 0%, 0%)` among them.
    for (value, expected) in cases {
        assert_eq!(opaque(value), Some(*expected), "reading {value}");
    }
}

#[test]
fn nonsense_is_not_read_as_a_colour() {
    for value in [
        "",
        "   ",
        "#",
        "#12345",
        "#gggggg",
        "rgb(11, 61)",
        "rgb 11 61 145",
        "hsl(a, b, c)",
        "javascript:alert(1)",
        &"#".repeat(300),
    ] {
        assert_eq!(
            tint(&[declared(value)], &[], None),
            None,
            "reading {value:?}"
        );
    }
}

// MARK: - Legibility

#[test]
fn a_near_black_page_asks_for_light_ink() {
    let tint = tint(&[declared("#0a0a0c")], &[], None).expect("a colour");
    assert!(!tint.prefers_dark_ink);
    assert_eq!(tint.rgb, 0x000A_0A0C, "a dark page is not touched");
}

#[test]
fn a_near_white_page_asks_for_dark_ink() {
    let tint = tint(&[declared("#fdfdfb")], &[], None).expect("a colour");
    assert!(tint.prefers_dark_ink);
    assert_eq!(tint.rgb, 0x00FD_FDFB, "a light page is not touched");
}

/// The whole reason this is a rule rather than a threshold: a page may state a
/// colour on which *neither* ink can be read, and the chrome still has to carry
/// a control.
#[test]
fn every_colour_a_page_can_state_ends_up_legible() {
    let mut moved = 0;
    for red in (0..=255).step_by(17) {
        for green in (0..=255).step_by(17) {
            for blue in (0..=255).step_by(17) {
                let stated = (red << 16) | (green << 8) | blue;
                let tint = tint(&[declared(&format!("#{stated:06x}"))], &[], None)
                    .expect("every hex is a colour");

                // The extreme ink on the side the tint named.
                let ink = if tint.prefers_dark_ink { 0.0 } else { 1.0 };
                assert!(
                    contrast(tint.luminance(), ink) >= MIN_INK_CONTRAST - 0.001,
                    "#{stated:06x} became #{:06x}, which carries no ink",
                    tint.rgb
                );
                if tint.rgb != stated {
                    moved += 1;
                }
            }
        }
    }
    // A sanity check on the check: if nothing ever moved, the rule above would
    // pass for a module that does nothing.
    assert!(moved > 0, "no colour was ever adjusted");
}

/// Moving a colour is a repair, not a restyle. Only lightness may move, and only
/// as far as it has to: the page has to stay recognisable in its own chrome.
#[test]
fn a_colour_that_has_to_move_keeps_its_hue() {
    let stated = 0x00FF_0000;
    let tint = tint(&[declared("#ff0000")], &[], None).expect("a colour");

    assert_ne!(tint.rgb, stated, "pure red sits where neither ink reads");

    let red = (tint.rgb >> 16) & 0xFF;
    let green = (tint.rgb >> 8) & 0xFF;
    let blue = tint.rgb & 0xFF;
    assert!(red > green && red > blue, "it is still red");
    assert_eq!(green, blue, "the hue did not rotate");

    // The nearer edge, which for pure red is upwards.
    assert!(tint.prefers_dark_ink);
    assert!(
        (tint.luminance() - MIN_LUMINANCE_FOR_DARK_INK).abs() < 0.01,
        "moved further than it had to: {}",
        tint.luminance()
    );
}

#[test]
fn a_colour_below_the_band_moves_down_not_up() {
    // Just inside the band from below, so the nearer edge is the dark one.
    let below = f64::midpoint(MAX_LUMINANCE_FOR_LIGHT_INK, MIN_LUMINANCE_FOR_DARK_INK) - 0.01;
    let grey = (0..=255)
        .map(|value| (value << 16) | (value << 8) | value)
        .find(|value| luminance(*value) >= below)
        .expect("a grey in the band");

    let tint = tint(&[declared(&format!("#{grey:06x}"))], &[], None).expect("a colour");
    assert!(!tint.prefers_dark_ink);
    assert!(tint.luminance() <= MAX_LUMINANCE_FOR_LIGHT_INK + 0.001);
}

// MARK: - Reaching the tab

fn session_with_a_tab() -> (Session, crate::model::TabId) {
    let mut session = Session::new("Personal", "ds-personal");
    dispatch(
        &mut session,
        Action::OpenTab {
            space: None,
            url: None,
            parent: None,
        },
    );
    let tab = session.browser.active_tab().expect("a new tab is active");
    (session, tab)
}

fn report(session: &mut Session, tab: crate::model::TabId, colour: &str) {
    dispatch(
        session,
        Action::ColorsDeclared {
            tab,
            theme_colors: vec![declared(colour)],
            element_backgrounds: Vec::new(),
            canvas_background: None,
        },
    );
}

#[test]
fn the_colour_travels_to_the_tab() {
    let (mut session, tab) = session_with_a_tab();
    report(&mut session, tab, "#0b3d91");

    assert_eq!(
        session.browser.tab(tab).expect("the tab").tint,
        Some(PageTint {
            rgb: 0x000B_3D91,
            prefers_dark_ink: false
        })
    );
}

/// Keeping it would paint the window in the last site's brand while the next
/// one loads, and change again when it arrives.
#[test]
fn navigating_away_takes_the_colour_with_it() {
    let (mut session, tab) = session_with_a_tab();
    report(&mut session, tab, "#0b3d91");

    dispatch(
        &mut session,
        Action::NavigationCommitted {
            tab,
            url: "https://example.com".into(),
        },
    );

    assert_eq!(session.browser.tab(tab).expect("the tab").tint, None);
}

/// Nothing was painted, so there is no page colour to carry: the error screen
/// is ours.
#[test]
fn a_page_that_failed_has_no_colour() {
    let (mut session, tab) = session_with_a_tab();
    report(&mut session, tab, "#0b3d91");

    dispatch(
        &mut session,
        Action::NavigationFailed {
            tab,
            kind: NavigationErrorKind::HostNotFound,
            message: "no such host".into(),
        },
    );

    assert_eq!(session.browser.tab(tab).expect("the tab").tint, None);
}

/// Engine events arrive asynchronously, so a colour for a tab that has just
/// been closed is expected traffic rather than a bug.
#[test]
fn a_colour_for_a_tab_that_is_gone_is_dropped() {
    let (mut session, tab) = session_with_a_tab();
    dispatch(&mut session, Action::CloseTab { tab });
    report(&mut session, tab, "#0b3d91");
}
