//! zer0's design tokens as read at runtime from `design/tokens.toml`.
//!
//! The third consumer of one artifact (ADR-0117): the macOS shell's hand copy
//! is compared by the gate, and this shell refuses to carry a copy at all —
//! it reads the file, so there is nothing here to drift. A browser that cannot
//! find the file refuses to start rather than fall back to colours nobody
//! chose: a fallback palette would be exactly the second truth ADR-0117
//! exists to prevent.
//!
//! Every section the file names is loaded, whether a v1 surface wears it yet
//! or not — a token skipped at load time is invisible debt, and the TOML is
//! the source. [`css`] is the other discipline: it emits classes for what the
//! shell actually draws, so no rule exists unworn.

use std::path::{Path, PathBuf};

use toml_edit::DocumentMut;

/// The palette tokens this shell paints chrome with, per appearance.
///
/// Not all seventeen: the status colours and `companionRow` belong to surfaces
/// (consent tiers, split rows) this v1 has not drawn yet. They stay in the
/// file and arrive when a surface for them does.
pub struct Palette {
    pub background: String,
    pub chrome: String,
    // Loaded for completeness of the palette this shell paints from; worn the
    // day a grouped surface (a recessed list) exists to wear it.
    #[allow(dead_code)]
    pub recessed: String,
    pub recessed_inner: String,
    pub rule: String,
    pub ink: String,
    pub ink_secondary: String,
    pub ink_tertiary: String,
    pub accent: String,
    pub accent_hover: String,
    pub accent_pressed: String,
    pub on_accent: String,
    pub selected_row: String,
}

/// The spacing rungs this shell's layout consumes.
pub struct Spacing {
    pub hair: i64,
    pub tight: i64,
    pub snug: i64,
    pub regular: i64,
    // The rungs for screens that put air between major blocks; v1 has one
    // strip of chrome. Loaded so the debt ADR-0122 named stays dead.
    #[allow(dead_code)]
    pub loose: i64,
    pub section: i64,
    /// The one rung deliberately off the 4pt rhythm (DESIGN.md §2): the gap
    /// between the two lines of a single label, and the loading bar's height.
    pub line: i64,
}

pub struct Radius {
    pub small: i64,
    pub medium: i64,
    // The radius of a panel floating over the page; nothing floats in v1 yet.
    #[allow(dead_code)]
    pub large: i64,
}

/// Line weights, outside the spacing rhythm because a stroke is not a gap.
pub struct Stroke {
    pub hairline: i64,
    pub insertion: i64,
}

/// Picture sizes, outside the type scale because a picture does not grow with
/// someone's text size (DESIGN.md §2).
pub struct Glyph {
    // The empty-state icon and the control-strip glyph wait for surfaces of
    // their own; only the mark is drawn in v1.
    #[allow(dead_code)]
    pub icon: i64,
    pub mark: i64,
    #[allow(dead_code)]
    pub control: i64,
}

pub struct Durations {
    /// "Fast enough to feel instant, slow enough to be seen" — the `subtle`
    /// curve's length. Worn as CSS `transition` milliseconds.
    pub quick: f64,
    /// How long a notice lingers. No v1 surface lingers yet; loaded so the
    /// day one does, it does not re-invent the number.
    #[allow(dead_code)]
    pub linger: f64,
}

/// The `entrance` spring's parameters. GTK has no spring physics; the shell
/// wears `durations.quick` as an honest ease-out instead, and this stays
/// loaded so the approximation is named next to the data it approximates
/// (ADR-0122's amendment).
#[allow(dead_code)]
pub struct Spring {
    pub response: f64,
    pub damping: f64,
}

/// One step of the elevation scale: cast opacity, blur radius, y offset.
pub struct ElevationStep {
    pub opacity: f64,
    pub radius: i64,
    pub y: i64,
}

/// Three steps, because the shell has exactly three distances (DESIGN.md §2).
pub struct Elevation {
    pub resting: ElevationStep,
    pub floating: ElevationStep,
    pub overlay: ElevationStep,
}

/// A type token: the pt macOS resolves for the style, the weight it carries,
/// and the letter-spacing only the uppercase headings have. `pt` is worn
/// directly as CSS `pt` — the TOML states these are platform-resolved data
/// for exactly this mapping.
pub struct TypeToken {
    pub pt: f64,
    pub weight: Weight,
    // Letter-spacing arrives with the first uppercase group heading, per
    // DESIGN.md §2's `.sectionHeading()` — never spelled by hand at a site.
    #[allow(dead_code)]
    pub tracking: Option<f64>,
    pub monospaced: bool,
}

pub enum Weight {
    Regular,
    Medium,
    Semibold,
    Bold,
}

impl Weight {
    fn parse(value: &str) -> Result<Self, String> {
        match value {
            "regular" => Ok(Weight::Regular),
            "medium" => Ok(Weight::Medium),
            "semibold" => Ok(Weight::Semibold),
            "bold" => Ok(Weight::Bold),
            // A weight the CSS layer cannot spell is refused, not rounded to
            // the nearest guess: a new weight in the TOML is a design
            // decision that must be decided here, out loud.
            other => Err(format!(
                "type weight {other:?} is not one this shell can wear"
            )),
        }
    }

    fn css(&self) -> &'static str {
        match self {
            Weight::Regular => "400",
            Weight::Medium => "500",
            Weight::Semibold => "600",
            Weight::Bold => "700",
        }
    }
}

/// The two fixed point sizes an AppKit text field forces on macOS
/// (DESIGN.md §2). No GTK surface wears them; loaded, not transcribed.
#[allow(dead_code)]
pub struct FieldSizes {
    pub command: i64,
    pub strip: i64,
}

pub struct Types {
    pub row: TypeToken,
    // The unworn rungs of the scale — secondary lines, micro hints, group
    // headings, the command palette's own size, the About panel's display
    // size, the greeting. Loaded so the scale is whole; worn the day a
    // surface for each arrives.
    #[allow(dead_code)]
    pub label: TypeToken,
    #[allow(dead_code)]
    pub micro: TypeToken,
    #[allow(dead_code)]
    pub section_title: TypeToken,
    #[allow(dead_code)]
    pub command_input: TypeToken,
    pub detail: TypeToken,
    pub row_title: TypeToken,
    pub empty_title: TypeToken,
    #[allow(dead_code)]
    pub display: TypeToken,
    pub mono: TypeToken,
    /// The greeting line's pt, the one size in the scale that is a number on
    /// macOS too — a different kind of data, so a different kind of field.
    #[allow(dead_code)]
    pub greeting_pt: f64,
    #[allow(dead_code)]
    pub field: FieldSizes,
}

pub struct Pane {
    pub empty_state_min_height: i64,
}

pub struct Tokens {
    pub light: Palette,
    pub dark: Palette,
    pub spacing: Spacing,
    pub radius: Radius,
    pub stroke: Stroke,
    pub glyph: Glyph,
    pub durations: Durations,
    /// Loaded and not read, for the reason `Spring` itself is: GTK has no
    /// spring physics, so the approximation stays named next to the data it
    /// approximates rather than quietly absent.
    #[allow(dead_code)]
    pub spring: Spring,
    pub elevation: Elevation,
    pub types: Types,
    pub pane: Pane,
}

/// Where `design/tokens.toml` is: `$ZER0_TOKENS` if set, otherwise the first
/// `design/tokens.toml` found walking up from the working directory — the way
/// git finds its config, because a checkout is where this v1 runs from.
fn tokens_path() -> Result<PathBuf, String> {
    if let Ok(from_env) = std::env::var("ZER0_TOKENS") {
        return Ok(PathBuf::from(from_env));
    }
    let mut dir = std::env::current_dir().map_err(|e| format!("no working directory: {e}"))?;
    loop {
        let candidate = dir.join("design").join("tokens.toml");
        if candidate.is_file() {
            return Ok(candidate);
        }
        if !dir.pop() {
            return Err(
                "design/tokens.toml was not found (looked upward from the working \
                 directory; set ZER0_TOKENS to name it)"
                    .to_string(),
            );
        }
    }
}

/// The zer0 mark's geometry, from the SVG that owns it — `design/logo/zer0.svg`,
/// the source of truth ADR-0040 names. Derived from the same walk as the
/// tokens: whatever directory holds the TOML holds the logo, so there is one
/// search, one artifact, and no second truth to drift.
pub fn mark_path_data() -> Result<String, String> {
    let svg_path = tokens_path()?
        .parent()
        .ok_or_else(|| "design/tokens.toml has no parent directory".to_string())?
        .join("logo")
        .join("zer0.svg");
    let svg = std::fs::read_to_string(&svg_path)
        .map_err(|e| format!("could not read {}: {e}", svg_path.display()))?;
    path_data(&svg, &svg_path)
}

/// The one attribute this shell reads from the one file whose shape it knows:
/// a scan for ` d="…"`, not an XML parser — an XML dependency for one string
/// is ceremony, and any miss refuses rather than guesses.
fn path_data(svg: &str, name: &Path) -> Result<String, String> {
    let start = svg
        .find(" d=\"")
        .ok_or_else(|| format!("{} carries no path data (no ` d=\"…\"`)", name.display()))?;
    let rest = &svg[start + 4..];
    let end = rest
        .find('"')
        .ok_or_else(|| format!("{} has an unterminated path data attribute", name.display()))?;
    let data = &rest[..end];
    if data.is_empty() {
        return Err(format!("{} has empty path data", name.display()));
    }
    Ok(data.to_string())
}

fn color(document: &DocumentMut, appearance: &str, key: &str) -> Result<String, String> {
    let value = document
        .get("palette")
        .and_then(|palette| palette.get(appearance))
        .and_then(|table| table.get(key))
        .and_then(|item| item.as_str())
        .ok_or_else(|| format!("design token palette.{appearance}.{key} is missing"))?;
    let looks_like_hex = value.len() == 7
        && value.starts_with('#')
        && value[1..].bytes().all(|b| b.is_ascii_hexdigit());
    if !looks_like_hex {
        return Err(format!(
            "design token palette.{appearance}.{key} is {value:?}, which is not #RRGGBB"
        ));
    }
    Ok(value.to_string())
}

fn integer(document: &DocumentMut, section: &str, key: &str) -> Result<i64, String> {
    document
        .get(section)
        .and_then(|table| table.get(key))
        .and_then(|item| item.as_integer())
        .ok_or_else(|| format!("design token {section}.{key} is missing or not an integer"))
}

/// TOML integers and floats alike: `[durations] quick = 0.18` and
/// `[type.row] pt = 11` are the same kind of number to the CSS layer.
fn number(value: &toml_edit::Item) -> Option<f64> {
    if let Some(as_integer) = value.as_integer() {
        return Some(as_integer as f64);
    }
    value.as_float()
}

fn nested<'a>(
    document: &'a DocumentMut,
    section: &str,
    subsection: &str,
) -> Result<&'a toml_edit::Item, String> {
    document
        .get(section)
        .and_then(|table| table.get(subsection))
        .ok_or_else(|| format!("design token {section}.{subsection} is missing"))
}

fn nested_integer(
    document: &DocumentMut,
    section: &str,
    subsection: &str,
    key: &str,
) -> Result<i64, String> {
    nested(document, section, subsection)?
        .get(key)
        .and_then(|item| item.as_integer())
        .ok_or_else(|| {
            format!("design token {section}.{subsection}.{key} is missing or not an integer")
        })
}

fn type_token(document: &DocumentMut, name: &str) -> Result<TypeToken, String> {
    let table = nested(document, "type", name)?;
    let missing = |key: &str| format!("design token type.{name}.{key} is missing or not a number");
    let pt = table
        .get("pt")
        .and_then(number)
        .ok_or_else(|| missing("pt"))?;
    let weight = table
        .get("weight")
        .and_then(|item| item.as_str())
        .ok_or_else(|| format!("design token type.{name}.weight is missing"))?;
    let weight = Weight::parse(weight).map_err(|e| format!("design token type.{name}: {e}"))?;
    let tracking = table.get("tracking").and_then(number);
    let monospaced = match table.get("design").and_then(|item| item.as_str()) {
        None => false,
        Some("monospaced") => true,
        // Refused rather than ignored: an unknown design on a token is the
        // file saying something this consumer has not decided how to wear.
        Some(other) => {
            return Err(format!(
                "design token type.{name}.design is {other:?}, which this shell does not know"
            ));
        }
    };
    Ok(TypeToken {
        pt,
        weight,
        tracking,
        monospaced,
    })
}

fn elevation_step(document: &DocumentMut, name: &str) -> Result<ElevationStep, String> {
    Ok(ElevationStep {
        opacity: nested(document, "elevation", name)?
            .get("opacity")
            .and_then(number)
            .ok_or_else(|| format!("design token elevation.{name}.opacity is missing"))?,
        radius: nested_integer(document, "elevation", name, "radius")?,
        y: nested_integer(document, "elevation", name, "y")?,
    })
}

fn palette(document: &DocumentMut, appearance: &str) -> Result<Palette, String> {
    let read = |key: &str| color(document, appearance, key);
    Ok(Palette {
        background: read("background")?,
        chrome: read("chrome")?,
        recessed: read("recessed")?,
        recessed_inner: read("recessedInner")?,
        rule: read("rule")?,
        ink: read("ink")?,
        ink_secondary: read("inkSecondary")?,
        ink_tertiary: read("inkTertiary")?,
        accent: read("accent")?,
        accent_hover: read("accentHover")?,
        accent_pressed: read("accentPressed")?,
        on_accent: read("onAccent")?,
        selected_row: read("selectedRow")?,
    })
}

fn tokens_from_str(text: &str) -> Result<Tokens, String> {
    let document = text
        .parse::<DocumentMut>()
        .map_err(|e| format!("design/tokens.toml does not parse: {e}"))?;
    Ok(Tokens {
        light: palette(&document, "light")?,
        dark: palette(&document, "dark")?,
        spacing: Spacing {
            hair: integer(&document, "spacing", "hair")?,
            tight: integer(&document, "spacing", "tight")?,
            snug: integer(&document, "spacing", "snug")?,
            regular: integer(&document, "spacing", "regular")?,
            loose: integer(&document, "spacing", "loose")?,
            section: integer(&document, "spacing", "section")?,
            line: integer(&document, "spacing", "line")?,
        },
        radius: Radius {
            small: integer(&document, "radius", "small")?,
            medium: integer(&document, "radius", "medium")?,
            large: integer(&document, "radius", "large")?,
        },
        stroke: Stroke {
            hairline: integer(&document, "stroke", "hairline")?,
            insertion: integer(&document, "stroke", "insertion")?,
        },
        glyph: Glyph {
            icon: integer(&document, "glyph", "icon")?,
            mark: integer(&document, "glyph", "mark")?,
            control: integer(&document, "glyph", "control")?,
        },
        durations: Durations {
            quick: integer_or_float(&document, "durations", "quick")?,
            linger: integer_or_float(&document, "durations", "linger")?,
        },
        spring: Spring {
            response: nested_number_checked(&document, "motion", "spring", "response")?,
            damping: nested_number_checked(&document, "motion", "spring", "damping")?,
        },
        elevation: Elevation {
            resting: elevation_step(&document, "resting")?,
            floating: elevation_step(&document, "floating")?,
            overlay: elevation_step(&document, "overlay")?,
        },
        types: Types {
            row: type_token(&document, "row")?,
            label: type_token(&document, "label")?,
            micro: type_token(&document, "micro")?,
            section_title: type_token(&document, "sectionTitle")?,
            command_input: type_token(&document, "commandInput")?,
            detail: type_token(&document, "detail")?,
            row_title: type_token(&document, "rowTitle")?,
            empty_title: type_token(&document, "emptyTitle")?,
            display: type_token(&document, "display")?,
            mono: type_token(&document, "mono")?,
            greeting_pt: nested_number_checked(&document, "type", "greetingSize", "pt")?,
            field: FieldSizes {
                command: nested_integer(&document, "type", "field", "command")?,
                strip: nested_integer(&document, "type", "field", "strip")?,
            },
        },
        pane: Pane {
            empty_state_min_height: integer(&document, "pane", "emptyStateMinHeight")?,
        },
    })
}

fn integer_or_float(document: &DocumentMut, section: &str, key: &str) -> Result<f64, String> {
    document
        .get(section)
        .and_then(|table| table.get(key))
        .and_then(number)
        .ok_or_else(|| format!("design token {section}.{key} is missing or not a number"))
}

fn nested_number_checked(
    document: &DocumentMut,
    section: &str,
    subsection: &str,
    key: &str,
) -> Result<f64, String> {
    nested(document, section, subsection)?
        .get(key)
        .and_then(number)
        .ok_or_else(|| {
            format!("design token {section}.{subsection}.{key} is missing or not a number")
        })
}

pub fn load() -> Result<Tokens, String> {
    let path = tokens_path()?;
    let text = std::fs::read_to_string(&path)
        .map_err(|e| format!("could not read {}: {e}", path.display()))?;
    tokens_from_str(&text).map_err(|e| format!("{}: {e}", path.display()))
}

/// Whether the desktop asked for dark colours. Read from GNOME's own setting
/// because that is the cheap honest proxy on Linux; where `gsettings` is
/// absent the answer is light — stated, not guessed, and a follow-up can
/// listen for changes instead of asking once at launch.
pub fn system_prefers_dark() -> bool {
    std::process::Command::new("gsettings")
        .args(["get", "org.gnome.desktop.interface", "color-scheme"])
        .output()
        .is_ok_and(|out| {
            out.status.success() && String::from_utf8_lossy(&out.stdout).contains("prefer-dark")
        })
}

/// `#RRGGBB` split into channels, for the one place CSS needs the parts
/// rather than the whole: translucent ink for hover, DESIGN.md §4's
/// `.primary.opacity(0.06)`. Called only on values [`color`] validated at
/// load, so a channel that failed to parse would be a bug, not input —
/// loud, never a silent wrong colour.
fn rgb_channels(hex: &str) -> (i64, i64, i64) {
    let channel = |from: usize| {
        i64::from_str_radix(&hex[from..from + 2], 16)
            .expect("color() validated #RRGGBB before this was called")
    };
    (channel(1), channel(3), channel(5))
}

/// The shell's CSS, generated from the tokens. Solid colours only: the chrome
/// is painted, not blurred (ADR-0043), so a GTK surface states a colour and
/// GTK's own materials stay out of the window frame.
///
/// Motion is the honest approximation ADR-0122's amendment names: GTK has no
/// spring, so `subtle` (easeOut over `durations.quick`) is worn as a CSS
/// `transition` on the colour properties, and `entrance` — a thing arriving —
/// has no equivalent until a surface that arrives exists to wear one.
pub fn css(tokens: &Tokens, dark: bool) -> String {
    let p = if dark { &tokens.dark } else { &tokens.light };
    let s = &tokens.spacing;
    let r = &tokens.radius;
    let t = &tokens.types;
    let (ink_r, ink_g, ink_b) = rgb_channels(&p.ink);
    // DESIGN.md §4: hover is ink at 6%. The depth is stated in the design, not
    // yet in the TOML — debt the amendment names; the day the file carries
    // interaction alphas, this line reads them instead.
    let hover = format!("rgba({ink_r},{ink_g},{ink_b},0.06)");
    // The press dip doubles the hover depth; macOS states the dip as a
    // behaviour ("dimming"), not a number, so 2× is this shell's stated
    // approximation rather than a token.
    let pressed = format!("rgba({ink_r},{ink_g},{ink_b},0.12)");
    let quick_ms = (tokens.durations.quick * 1000.0).round() as i64;
    let subtle =
        format!("transition: background-color {quick_ms}ms ease-out, color {quick_ms}ms ease-out");
    // The chord hint's family follows the mono token's own `design` field
    // rather than a hardcoded family: the class says what the token says.
    let mono_family = if t.mono.monospaced {
        "monospace"
    } else {
        "inherit"
    };
    let resting = &tokens.elevation.resting;
    let floating = &tokens.elevation.floating;
    let overlay = &tokens.elevation.overlay;
    format!(
        "window {{ background-color: {background}; color: {ink}; }}
         headerbar {{ background-color: {chrome}; color: {ink}; }}

         /* The tab strip wears the sidebar's language (DESIGN.md §2, §4): a
            hairline rule below, hairline separators between tabs, the active
            tab on the selected-row band with ink on it — a pair the palette
            guarantees 4.5:1 by construction — and hover as translucent ink. */
         .zer0-tabbar {{ background-color: {chrome}; border-bottom: {hairline}px solid {rule}; padding: {hair}px {snug}px; }}
         .zer0-tabbar separator {{ background-color: {rule}; min-width: {hairline}px; }}
         button.zer0-tab {{ font-size: {row_pt}pt; font-weight: {row_weight}; color: {ink_secondary}; background-color: transparent; border-radius: {rs}px; padding: {hair}px {tight}px; {subtle}; }}
         button.zer0-tab:hover {{ background-color: {hover}; }}
         button.zer0-tab:active {{ background-color: {pressed}; }}
         button.zer0-tab:checked {{ background-color: {selected_row}; color: {ink}; }}

         /* Chrome controls (navigation, new tab): hover and press on the same
            recipe as tabs, on the small radius. */
         button.zer0-chrome-button {{ border-radius: {rs}px; {subtle}; }}
         button.zer0-chrome-button:hover {{ background-color: {hover}; }}
         button.zer0-chrome-button:active {{ background-color: {pressed}; }}

         /* The address field wears rowTitle — the name of the thing in front
            of you — and takes the accent only while it holds the keyboard.
            The border is always drawn, transparent until then, so focus does
            not shift the field by its own width. */
         entry {{ font-size: {row_title_pt}pt; font-weight: {row_title_weight}; background-color: {recessed_inner}; color: {ink}; border: {insertion}px solid transparent; border-radius: {rm}px; padding: {hair}px {regular}px; }}
         entry:focus-within {{ border-color: {accent}; }}

         /* The empty screen is a product screen (DESIGN.md §9): the mark at
            Glyph.mark, quiet in tertiary; emptyTitle over detail; one
            prominent action and its chord. */
         .zer0-empty {{ padding: {section}px; }}
         .zer0-empty-title {{ font-size: {empty_title_pt}pt; font-weight: {empty_title_weight}; }}
         .zer0-empty-detail {{ font-size: {detail_pt}pt; font-weight: {detail_weight}; color: {ink_secondary}; }}
         .zer0-chord {{ font-size: {mono_pt}pt; font-weight: {mono_weight}; font-family: {mono_family}; color: {ink_secondary}; }}
         button.zer0-action {{ background-color: {accent}; color: {on_accent}; border-radius: {rs}px; padding: {hair}px {regular}px; {subtle}; }}
         button.zer0-action:hover {{ background-color: {accent_hover}; }}
         button.zer0-action:active {{ background-color: {accent_pressed}; }}

         /* Elevation (DESIGN.md §2): the three steps as box-shadows, straight
            from the TOML. Emitted though nothing in v1 wears them — no
            surface here has left another yet, and \"a shadow is earned by
            distance\" — so the first popover that arrives finds its depth
            already correct and generated. */
         .elevation-resting {{ box-shadow: 0 {resting_y}px {resting_radius}px rgba(0,0,0,{resting_opacity}); }}
         .elevation-floating {{ box-shadow: 0 {floating_y}px {floating_radius}px rgba(0,0,0,{floating_opacity}); }}
         .elevation-overlay {{ box-shadow: 0 {overlay_y}px {overlay_radius}px rgba(0,0,0,{overlay_opacity}); }}
         ",
        background = p.background,
        chrome = p.chrome,
        recessed_inner = p.recessed_inner,
        rule = p.rule,
        ink = p.ink,
        ink_secondary = p.ink_secondary,
        accent = p.accent,
        accent_hover = p.accent_hover,
        accent_pressed = p.accent_pressed,
        on_accent = p.on_accent,
        selected_row = p.selected_row,
        hover = hover,
        pressed = pressed,
        subtle = subtle,
        rs = r.small,
        rm = r.medium,
        hairline = tokens.stroke.hairline,
        insertion = tokens.stroke.insertion,
        hair = s.hair,
        tight = s.tight,
        snug = s.snug,
        regular = s.regular,
        section = s.section,
        row_pt = t.row.pt,
        row_weight = t.row.weight.css(),
        row_title_pt = t.row_title.pt,
        row_title_weight = t.row_title.weight.css(),
        empty_title_pt = t.empty_title.pt,
        empty_title_weight = t.empty_title.weight.css(),
        detail_pt = t.detail.pt,
        detail_weight = t.detail.weight.css(),
        mono_pt = t.mono.pt,
        mono_weight = t.mono.weight.css(),
        resting_y = resting.y,
        resting_radius = resting.radius,
        resting_opacity = resting.opacity,
        floating_y = floating.y,
        floating_radius = floating.radius,
        floating_opacity = floating.opacity,
        overlay_y = overlay.y,
        overlay_radius = overlay.radius,
        overlay_opacity = overlay.opacity,
    )
}

#[cfg(test)]
mod tests {
    // These run wherever the crate compiles — a machine with the GTK headers,
    // via `cargo test -p zer0-linux`. CI compiles them under
    // `clippy --all-targets` but does not run them yet; that is a named debt
    // in ADR-0122's amendment. Every test parses strings, never the
    // filesystem, so none of them races another.
    use super::*;

    // The real artifact, at compile time: testing against a hand-typed TOML
    // would be the second copy ADR-0117 exists to prevent.
    const REAL: &str = include_str!("../../../design/tokens.toml");

    #[test]
    fn the_real_tokens_parse() {
        tokens_from_str(REAL).expect("the shipped tokens.toml must load");
    }

    #[test]
    fn css_wears_the_loaded_tokens() {
        let tokens = tokens_from_str(REAL).expect("the shipped tokens.toml must load");
        let css = css(&tokens, false);
        // Tabs wear `row`, the field wears `rowTitle`, the empty screen wears
        // `emptyTitle` over `detail`, the chord wears `mono` — and the active
        // tab sits on the selected-row band.
        assert!(
            css.contains("button.zer0-tab { font-size: 11pt; font-weight: 400;"),
            "{css}"
        );
        assert!(
            css.contains("entry { font-size: 13pt; font-weight: 500;"),
            "{css}"
        );
        assert!(
            css.contains(".zer0-empty-title { font-size: 17pt; font-weight: 600; }"),
            "{css}"
        );
        assert!(
            css.contains(".zer0-empty-detail { font-size: 12pt;"),
            "{css}"
        );
        assert!(css.contains("font-family: monospace;"), "{css}");
        assert!(css.contains("background-color: #837AE0;"), "{css}");
        assert!(
            css.contains("transition: background-color 180ms ease-out"),
            "{css}"
        );
        assert!(
            css.contains(".elevation-overlay { box-shadow: 0 12px 30px rgba(0,0,0,0.28); }"),
            "{css}"
        );
    }

    #[test]
    fn dark_css_wears_the_dark_palette() {
        let tokens = tokens_from_str(REAL).expect("the shipped tokens.toml must load");
        let css = css(&tokens, true);
        assert!(css.contains("background-color: #635BC9;"), "{css}");
        assert!(!css.contains("#837AE0"), "{css}");
    }

    #[test]
    fn a_weight_the_css_cannot_spell_refuses() {
        let broken = REAL.replace("weight = \"semibold\"", "weight = \"chunky\"");
        let Err(error) = tokens_from_str(&broken) else {
            panic!("an unknown weight must refuse, not round to a guess")
        };
        assert!(error.contains("chunky"), "{error}");
    }

    #[test]
    fn the_mark_path_data_is_extracted_and_a_miss_refuses() {
        let data = path_data(
            "<svg><path fill=\"currentColor\" d=\"M1 2L3 4Z\"/></svg>",
            Path::new("zer0.svg"),
        )
        .expect("the d attribute is present");
        assert_eq!(data, "M1 2L3 4Z");
        let error = path_data("<svg><circle/></svg>", Path::new("zer0.svg"))
            .expect_err("a file without path data must refuse");
        assert!(error.contains("no path data"), "{error}");
    }
}
