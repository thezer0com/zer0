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

use std::{
    io::Read,
    path::{Path, PathBuf},
};

use toml_edit::DocumentMut;

/// The palette tokens this shell paints chrome with, per appearance.
///
/// Not all seventeen: the image-copy notice now wears `warning`; the remaining
/// status colours and `companionRow` stay in the file until a surface needs
/// them.
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
    pub warning: String,
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

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MarkViewBox {
    pub width: u16,
    pub height: u16,
}

const MAX_MARK_BYTES: usize = 64 * 1024;
const MAX_MARK_LAYERS: usize = 16;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MarkColor {
    pub red: u8,
    pub green: u8,
    pub blue: u8,
}

impl MarkColor {
    pub fn from_hex(value: &str) -> Option<Self> {
        let looks_like_hex = value.len() == 7
            && value.starts_with('#')
            && value[1..].bytes().all(|byte| byte.is_ascii_hexdigit());
        looks_like_hex.then(|| Self {
            red: u8::from_str_radix(&value[1..3], 16).expect("hex shape was checked"),
            green: u8::from_str_radix(&value[3..5], 16).expect("hex shape was checked"),
            blue: u8::from_str_radix(&value[5..7], 16).expect("hex shape was checked"),
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MarkFillRule {
    Winding,
    EvenOdd,
}

#[derive(Clone)]
pub struct MarkLayer<P> {
    pub path: P,
    pub fill: MarkColor,
    pub fill_rule: MarkFillRule,
}

#[derive(Clone)]
pub struct Mark<P> {
    pub view_box: MarkViewBox,
    pub layers: Vec<MarkLayer<P>>,
}

#[derive(Clone)]
pub struct MarkSet<P> {
    pub canonical: Mark<P>,
    pub hinted: Mark<P>,
}

impl<P> MarkSet<P> {
    pub fn for_rendered_pixels(&self, pixels: u16) -> &Mark<P> {
        if pixels <= 32 {
            &self.hinted
        } else {
            &self.canonical
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MarkTreatment {
    Quiet,
    Brand,
}

impl MarkTreatment {
    pub fn fill(self, artwork: MarkColor, quiet: MarkColor) -> MarkColor {
        match self {
            Self::Quiet => quiet,
            Self::Brand => artwork,
        }
    }
}

impl<P> Mark<P> {
    pub fn layers_for(&self, treatment: MarkTreatment) -> &[MarkLayer<P>] {
        match treatment {
            MarkTreatment::Quiet => &self.layers[..self.layers.len().min(1)],
            MarkTreatment::Brand => &self.layers,
        }
    }
}

/// The zer0 mark, from the SVG that owns its geometry and colour.
pub fn mark() -> Result<MarkSet<String>, String> {
    let logo_dir = tokens_path()?
        .parent()
        .ok_or_else(|| "design/tokens.toml has no parent directory".to_string())?
        .join("logo");
    Ok(MarkSet {
        canonical: mark_from_path(&logo_dir.join("zer0.svg"))?,
        hinted: mark_from_path(&logo_dir.join("zer0-small.svg"))?,
    })
}

fn mark_from_path(path: &Path) -> Result<Mark<String>, String> {
    let file = std::fs::File::open(path)
        .map_err(|error| format!("could not read {}: {error}", path.display()))?;
    let mut bytes = Vec::new();
    file.take((MAX_MARK_BYTES + 1) as u64)
        .read_to_end(&mut bytes)
        .map_err(|error| format!("could not read {}: {error}", path.display()))?;
    if bytes.len() > MAX_MARK_BYTES {
        return Err(format!("{} exceeds {MAX_MARK_BYTES} bytes", path.display()));
    }
    let svg = String::from_utf8(bytes)
        .map_err(|error| format!("{} is not UTF-8: {error}", path.display()))?;
    mark_from_str(&svg, path)
}

fn mark_from_str(svg: &str, name: &Path) -> Result<Mark<String>, String> {
    if svg.len() > MAX_MARK_BYTES {
        return Err(format!("{} exceeds {MAX_MARK_BYTES} bytes", name.display()));
    }
    let document = after_markup_padding(svg, name)?;
    if !document.starts_with("<svg")
        || !document[4..]
            .chars()
            .next()
            .is_some_and(|next| next == '>' || next.is_whitespace())
    {
        return Err(format!("{} carries no `<svg>` root", name.display()));
    }
    let root_start = svg.len() - document.len();
    let root_end = document
        .find('>')
        .map(|offset| root_start + offset)
        .ok_or_else(|| format!("{} has an unterminated `<svg>` root", name.display()))?;
    let closing = svg[root_end + 1..]
        .find("</svg>")
        .map(|offset| root_end + 1 + offset)
        .ok_or_else(|| format!("{} carries no closing `</svg>`", name.display()))?;
    markup_padding(&svg[..root_start], name)?;
    markup_padding(&svg[closing + 6..], name)?;
    let root = &svg[root_start..=root_end];
    validate_attributes(root, "<svg", &["xmlns", "viewBox"], name)?;
    let view_box = parse_view_box(root, name)?;
    let body = &svg[root_end + 1..closing];
    let mut layers = Vec::new();
    let mut cursor = 0;
    while let Some(offset) = body[cursor..].find("<path") {
        let start = cursor + offset;
        markup_padding(&body[cursor..start], name)?;
        let after_name = body[start + 5..].chars().next();
        if !after_name.is_some_and(char::is_whitespace) {
            return Err(format!(
                "{} has a malformed `<path>` element",
                name.display()
            ));
        }
        let end = body[start..]
            .find("/>")
            .map(|offset| start + offset + 2)
            .ok_or_else(|| format!("{} has an unterminated `<path>` element", name.display()))?;
        let tag = &body[start..end];
        validate_attributes(tag, "<path", &["d", "fill", "fill-rule", "clip-rule"], name)?;
        if layers.len() == MAX_MARK_LAYERS {
            return Err(format!(
                "{} carries more than {MAX_MARK_LAYERS} path layers",
                name.display()
            ));
        }
        let path = required_attribute(tag, "d", name)?.to_string();
        let fill = parse_mark_color(required_attribute(tag, "fill", name)?, name)?;
        let fill_rule = match optional_attribute(tag, "fill-rule", name)? {
            None | Some("nonzero") => MarkFillRule::Winding,
            Some("evenodd") => MarkFillRule::EvenOdd,
            Some(value) => {
                return Err(format!(
                    "{} has unsupported path fill-rule {value:?}",
                    name.display()
                ));
            }
        };
        layers.push(MarkLayer {
            path,
            fill,
            fill_rule,
        });
        cursor = end;
    }
    markup_padding(&body[cursor..], name)?;
    if layers.is_empty() {
        return Err(format!("{} carries no `<path>` layers", name.display()));
    }
    Ok(Mark { view_box, layers })
}

fn validate_attributes(
    tag: &str,
    element: &str,
    allowed: &[&str],
    name: &Path,
) -> Result<(), String> {
    let mut rest = tag
        .strip_prefix(element)
        .ok_or_else(|| format!("{} has a malformed {element} element", name.display()))?;
    let mut seen = Vec::new();
    loop {
        rest = rest.trim_start();
        if rest == ">" || rest == "/>" {
            return Ok(());
        }
        let equals = rest
            .find('=')
            .ok_or_else(|| format!("{} has a malformed {element} attribute", name.display()))?;
        let attribute = &rest[..equals];
        if attribute.is_empty() || attribute.chars().any(char::is_whitespace) {
            return Err(format!(
                "{} has a malformed {element} attribute",
                name.display()
            ));
        }
        if !allowed.contains(&attribute) || seen.contains(&attribute) {
            return Err(format!(
                "{} has unsupported or duplicate {element} attribute {attribute:?}",
                name.display()
            ));
        }
        seen.push(attribute);
        let quoted = rest[equals + 1..]
            .strip_prefix('"')
            .ok_or_else(|| format!("{} has a non-double-quoted attribute", name.display()))?;
        let end = quoted
            .find('"')
            .ok_or_else(|| format!("{} has an unterminated attribute", name.display()))?;
        rest = &quoted[end + 1..];
    }
}

fn markup_padding(mut value: &str, name: &Path) -> Result<(), String> {
    value = after_markup_padding(value, name)?;
    if value.is_empty() {
        Ok(())
    } else {
        Err(format!("{} has unsupported SVG content", name.display()))
    }
}

fn after_markup_padding<'a>(mut value: &'a str, name: &Path) -> Result<&'a str, String> {
    loop {
        value = value.trim_start();
        if value.is_empty() {
            return Ok(value);
        }
        let Some(comment) = value.strip_prefix("<!--") else {
            return Ok(value);
        };
        let end = comment
            .find("-->")
            .ok_or_else(|| format!("{} has an unterminated comment", name.display()))?;
        value = &comment[end + 3..];
    }
}

fn parse_view_box(root: &str, name: &Path) -> Result<MarkViewBox, String> {
    let value = required_attribute(root, "viewBox", name)?;
    let mut parts = value.split_ascii_whitespace();
    let x = parts.next();
    let y = parts.next();
    let width = parts.next().and_then(|part| part.parse::<u16>().ok());
    let height = parts.next().and_then(|part| part.parse::<u16>().ok());
    if x != Some("0") || y != Some("0") || parts.next().is_some() {
        return Err(format!(
            "{} has unsupported viewBox {value:?}; expected `0 0 width height`",
            name.display()
        ));
    }
    match (width, height) {
        (Some(width), Some(height)) if width > 0 && height > 0 => Ok(MarkViewBox { width, height }),
        (Some(_), Some(_)) | (Some(_), None) | (None, Some(_)) | (None, None) => Err(format!(
            "{} has invalid viewBox dimensions in {value:?}",
            name.display()
        )),
    }
}

fn required_attribute<'a>(tag: &'a str, attribute: &str, name: &Path) -> Result<&'a str, String> {
    optional_attribute(tag, attribute, name)?.ok_or_else(|| {
        format!(
            "{} is missing required {attribute:?} attribute",
            name.display()
        )
    })
}

fn optional_attribute<'a>(
    tag: &'a str,
    attribute: &str,
    name: &Path,
) -> Result<Option<&'a str>, String> {
    let prefix = format!(" {attribute}=");
    let Some(start) = tag.find(&prefix) else {
        return Ok(None);
    };
    let rest = &tag[start + prefix.len()..];
    let quoted = rest.strip_prefix('"').ok_or_else(|| {
        format!(
            "{} has a non-double-quoted {attribute:?} attribute",
            name.display()
        )
    })?;
    let end = quoted.find('"').ok_or_else(|| {
        format!(
            "{} has an unterminated {attribute:?} attribute",
            name.display()
        )
    })?;
    let value = &quoted[..end];
    if value.is_empty() {
        return Err(format!(
            "{} has an empty {attribute:?} attribute",
            name.display()
        ));
    }
    Ok(Some(value))
}

fn parse_mark_color(value: &str, name: &Path) -> Result<MarkColor, String> {
    if value == "white" {
        return Ok(MarkColor {
            red: u8::MAX,
            green: u8::MAX,
            blue: u8::MAX,
        });
    }
    MarkColor::from_hex(value).ok_or_else(|| {
        format!(
            "{} has unsupported path fill {value:?}; expected `white` or `#RRGGBB`",
            name.display()
        )
    })
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
        warning: read("warning")?,
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

         /* A transient image-copy answer rests over the page in the same
            one-line language as the find bar (DESIGN.md §2, §4). */
         .zer0-image-copy-notice {{ font-size: {row_pt}pt; font-weight: {row_weight}; background-color: {chrome}; color: {ink}; border: {hairline}px solid {rule}; border-radius: {rm}px; padding: {tight}px {snug}px; }}
         .zer0-image-copy-notice image {{ color: {ink_secondary}; }}
         .zer0-image-copy-failure {{ color: {warning}; }}

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
        warning = p.warning,
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
    const SUPPLIED_MARK: &str = include_str!("../../../design/logo/zer0.svg");
    const SUPPLIED_HINTED_MARK: &str = include_str!("../../../design/logo/zer0-small.svg");

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
            css.contains(".zer0-image-copy-failure { color: #8F5600; }"),
            "{css}"
        );
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
    fn the_supplied_mark_keeps_layers_in_source_order() {
        let mark = mark_from_str(SUPPLIED_MARK, Path::new("design/logo/zer0.svg"))
            .expect("the supplied mark must load");

        assert_eq!(
            mark.view_box,
            MarkViewBox {
                width: 170,
                height: 199
            }
        );
        assert_eq!(mark.layers.len(), 2);
        assert!(mark.layers[0].path.starts_with("M30.9405"));
        assert!(mark.layers[1].path.starts_with("M140.998"));
        assert_eq!(mark.layers[0].fill_rule, MarkFillRule::EvenOdd);
        assert_eq!(mark.layers[1].fill_rule, MarkFillRule::Winding);
    }

    #[test]
    fn the_supplied_mark_keeps_declared_fills() {
        let mark = mark_from_str(SUPPLIED_MARK, Path::new("design/logo/zer0.svg"))
            .expect("the supplied mark must load");

        assert_eq!(
            mark.layers[0].fill,
            MarkColor {
                red: 0x63,
                green: 0x5b,
                blue: 0xc9,
            }
        );
        assert_eq!(
            mark.layers[1].fill,
            MarkColor {
                red: u8::MAX,
                green: u8::MAX,
                blue: u8::MAX,
            }
        );
    }

    #[test]
    fn the_quiet_mark_draws_only_the_zero() {
        let mark = mark_from_str(SUPPLIED_MARK, Path::new("zer0.svg"))
            .expect("the supplied mark must load");

        let layers = mark.layers_for(MarkTreatment::Quiet);
        let quiet = MarkColor {
            red: 0x72,
            green: 0x70,
            blue: 0x79,
        };

        assert_eq!(layers.len(), 1);
        assert_eq!(MarkTreatment::Quiet.fill(layers[0].fill, quiet), quiet);
    }

    #[test]
    fn the_brand_mark_keeps_the_complete_lockup() {
        let mark = mark_from_str(SUPPLIED_MARK, Path::new("zer0.svg"))
            .expect("the supplied mark must load");

        let layers = mark.layers_for(MarkTreatment::Brand);

        assert_eq!(layers.len(), 2);
        assert_eq!(layers[0].fill, mark.layers[0].fill);
        assert_eq!(layers[1].fill, mark.layers[1].fill);
    }

    #[test]
    fn small_renderings_select_the_hinted_master() {
        let marks = MarkSet {
            canonical: mark_from_str(SUPPLIED_MARK, Path::new("zer0.svg"))
                .expect("the supplied mark must load"),
            hinted: mark_from_str(SUPPLIED_HINTED_MARK, Path::new("zer0-small.svg"))
                .expect("the supplied hinted mark must load"),
        };

        assert_eq!(marks.for_rendered_pixels(16).layers.len(), 1);
        assert_eq!(marks.for_rendered_pixels(32).layers.len(), 1);
        assert_eq!(marks.for_rendered_pixels(33).layers.len(), 2);
    }

    #[test]
    fn unsupported_svg_content_refuses() {
        let error = mark_from_str(
            "<svg viewBox=\"0 0 1 1\"><circle/><path d=\"M0 0Z\" fill=\"white\"/></svg>",
            Path::new("zer0.svg"),
        )
        .err()
        .expect("an unsupported element must refuse");

        assert!(error.contains("unsupported SVG content"), "{error}");
    }

    #[test]
    fn unsupported_svg_attributes_refuse() {
        let error = mark_from_str(
            "<svg viewBox=\"0 0 1 1\"><path d=\"M0 0Z\" fill=\"white\" transform=\"scale(2)\"/></svg>",
            Path::new("zer0.svg"),
        )
        .err()
        .expect("an unsupported attribute must refuse");

        assert!(error.contains("unsupported or duplicate"), "{error}");
    }

    #[test]
    fn a_path_without_a_fill_refuses() {
        let error = mark_from_str(
            "<svg viewBox=\"0 0 1 1\"><path d=\"M0 0Z\"/></svg>",
            Path::new("zer0.svg"),
        )
        .err()
        .expect("a missing fill must refuse");

        assert!(error.contains("missing required \"fill\""), "{error}");
    }

    #[test]
    fn a_current_color_fill_refuses() {
        let error = mark_from_str(
            "<svg viewBox=\"0 0 1 1\"><path d=\"M0 0Z\" fill=\"currentColor\"/></svg>",
            Path::new("zer0.svg"),
        )
        .err()
        .expect("an inherited fill must refuse");

        assert!(error.contains("unsupported path fill"), "{error}");
    }

    #[test]
    fn an_unterminated_path_refuses() {
        let error = mark_from_str(
            "<svg viewBox=\"0 0 1 1\"><path d=\"M0 0Z\" fill=\"white\"></svg>",
            Path::new("zer0.svg"),
        )
        .err()
        .expect("a malformed path must refuse");

        assert!(error.contains("unterminated `<path>`"), "{error}");
    }

    #[test]
    fn a_missing_view_box_refuses() {
        let error = mark_from_str(
            "<svg><path d=\"M0 0Z\" fill=\"white\"/></svg>",
            Path::new("zer0.svg"),
        )
        .err()
        .expect("a missing viewBox must refuse");

        assert!(error.contains("missing required \"viewBox\""), "{error}");
    }

    #[test]
    fn an_oversized_mark_refuses() {
        let svg = format!(
            "{}<svg viewBox=\"0 0 1 1\"><path d=\"M0 0Z\" fill=\"white\"/></svg>",
            " ".repeat(64 * 1024)
        );
        let error = mark_from_str(&svg, Path::new("zer0.svg"))
            .err()
            .expect("an oversized mark must refuse before parsing");

        assert!(error.contains("exceeds 65536 bytes"), "{error}");
    }

    #[test]
    fn a_mark_with_too_many_layers_refuses() {
        let paths = "<path d=\"M0 0Z\" fill=\"white\"/>".repeat(17);
        let svg = format!("<svg viewBox=\"0 0 1 1\">{paths}</svg>");
        let error = mark_from_str(&svg, Path::new("zer0.svg"))
            .err()
            .expect("a mark with too many layers must refuse");

        assert!(error.contains("more than 16 path layers"), "{error}");
    }
}
