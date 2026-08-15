//! What colour a page is, and whether that colour can carry our controls.
//!
//! A page states its colour twice over. `<meta name="theme-color">` is the
//! author saying it outright, and the background the engine paints is the
//! author saying it by drawing. Which of those wins, what a translucent or
//! unreadable answer is worth, and what happens when there is nothing to read
//! are all *facts about the page* — so they are decided here rather than in a
//! view. Two platforms drawing the same page must not be free to disagree about
//! which colour it is.
//!
//! What is **not** here: which grey the chrome falls back to, how the colour
//! fades from one page to the next, and which ink is actually painted. Those are
//! appearance, and they stay in the shell (ADR-0002).
//!
//! Everything arriving here came out of a page, so none of it is trusted
//! (ADR-0024): the lists are capped, every string is parsed rather than
//! believed, and a colour that cannot carry legible controls is moved until it
//! can.

/// The contrast a tint must clear against the **extreme** ink on the side it
/// names — pure white for a dark tint, pure black for a light one.
///
/// The core cannot know which ink the shell paints; it only knows which *side*
/// of the ladder that ink is on. So the guarantee it can make is a margin
/// against the best ink that could possibly exist, wide enough that a real ink
/// a few steps in from the extreme still clears WCAG AA on top of it.
///
/// 6:1 is that margin, and the number is not arbitrary: at 4.5 the two sides
/// meet and every colour already clears against *pure* black or white, which
/// guarantees nothing about an ink that is merely near-black. 6:1 opens a band
/// between the two sides, and it is exactly that band that a real ink needs.
/// `apple/Tests/Zer0ShellTests/ChromeTintTests.swift` measures the shipped
/// palette against every tint this module can emit, so a palette that drifts out
/// of the band says so instead of shipping an unreadable strip.
pub const MIN_INK_CONTRAST: f64 = 6.0;

/// Light enough to take dark ink. Below this and above [`MAX_LUMINANCE_FOR_LIGHT_INK`]
/// is the band where neither ink clears the margin, and a tint landing in it is
/// moved to the nearer edge.
pub const MIN_LUMINANCE_FOR_DARK_INK: f64 = MIN_INK_CONTRAST * 0.05 - 0.05;

/// Dark enough to take light ink.
pub const MAX_LUMINANCE_FOR_LIGHT_INK: f64 = 1.05 / MIN_INK_CONTRAST - 0.05;

/// The most colour declarations one page may hand us.
///
/// The same reasoning as [`crate::icons::MAX_CANDIDATES`]: a page declaring ten
/// thousand `<meta name="theme-color">` elements should cost us a truncated
/// vector, not ten thousand parses.
pub const MAX_DECLARED_COLORS: usize = 8;

/// The longest colour string worth looking at. Every syntax CSS has fits in a
/// fraction of this; anything longer is not a colour.
const MAX_COLOR_LEN: usize = 64;

/// One colour a page declared, and whether it is the one for the appearance the
/// page is being drawn in.
///
/// `<meta name="theme-color">` may carry a `media` attribute, so a site can
/// state one colour for light and another for dark. Resolving that query needs
/// the page's own view of the world, so the host asks the page and reports the
/// answer; **which** of the matching declarations wins is decided here.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct DeclaredColor {
    /// Whatever was in the `content` attribute. Author input: parsed, not
    /// believed.
    pub value: String,
    /// The result of the element's `media` query, or `true` when it carries
    /// none. A declaration for the appearance we are not in is not a candidate.
    pub matches_appearance: bool,
}

/// The colour of the page a tab is showing, ready to be drawn on.
///
/// Packed rather than split into channels because it crosses the FFI and every
/// consumer wants it as one value: the shell builds a `Swatch` from it, and a
/// tint that could be half-assigned is a tint that can be wrong.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct PageTint {
    /// `0xRRGGBB`. Always opaque: a colour we could see through is not one we
    /// can stand a control on.
    pub rgb: u32,
    /// Whether what is drawn on this colour has to be dark. The shell owns
    /// *which* dark — this says only which end of the ladder is legible, which
    /// is a property of the colour rather than of a palette.
    pub prefers_dark_ink: bool,
}

impl PageTint {
    /// WCAG relative luminance, for tests and for the rule below.
    pub fn luminance(&self) -> f64 {
        luminance(self.rgb)
    }
}

/// The colour of a page, from what the page said about itself.
///
/// The chain, in order, and each rung exists because the one above it is
/// routinely absent:
///
/// 1. **`<meta name="theme-color">`**, first one whose `media` matches. The
///    author saying it outright, and the only rung that is a deliberate answer
///    to this exact question.
/// 2. **The computed background** of `documentElement`, then of `body`. Most of
///    the web has never heard of `theme-color`, so this is the common case
///    rather than the edge.
/// 3. **What the engine actually painted** behind the page. The rung that
///    catches the very large number of pages whose background is the default
///    canvas — neither element states a colour, and the page is still plainly
///    white or plainly dark.
///
/// `None` is the fourth rung and it is deliberate: a tab with nothing committed,
/// a page that failed, a document that is genuinely transparent. The shell wears
/// its own surface then, which is the honest answer to "we do not know".
pub fn tint_for(
    theme_colors: &[DeclaredColor],
    element_backgrounds: &[String],
    canvas_background: Option<&str>,
) -> Option<PageTint> {
    theme_colors
        .iter()
        .take(MAX_DECLARED_COLORS)
        .filter(|declared| declared.matches_appearance)
        .find_map(|declared| opaque(&declared.value))
        .or_else(|| {
            element_backgrounds
                .iter()
                .take(MAX_DECLARED_COLORS)
                .find_map(|value| opaque(value))
        })
        .or_else(|| canvas_background.and_then(opaque))
        .map(legible)
}

/// A colour, made safe to put a control on.
///
/// A page may declare any colour at all, including one chosen so that whatever
/// we draw on it disappears. The answer is not to refuse the colour — refusing
/// mid-tones would throw away a great many real brand colours, pure red among
/// them — but to move it the shortest distance that makes the strip readable,
/// along the one axis that keeps the page recognisable. Hue and saturation are
/// untouched; only lightness moves, and only when it has to.
fn legible(rgb: u32) -> PageTint {
    let light = luminance(rgb);

    if light >= MIN_LUMINANCE_FOR_DARK_INK {
        return PageTint {
            rgb,
            prefers_dark_ink: true,
        };
    }
    if light <= MAX_LUMINANCE_FOR_LIGHT_INK {
        return PageTint {
            rgb,
            prefers_dark_ink: false,
        };
    }

    // In the band neither ink clears the margin, so the colour moves to
    // whichever edge is nearer — the smallest change that can be made rather
    // than a house style imposed on the page.
    let up = MIN_LUMINANCE_FOR_DARK_INK - light;
    let down = light - MAX_LUMINANCE_FOR_LIGHT_INK;
    if up <= down {
        PageTint {
            rgb: moved(rgb, MIN_LUMINANCE_FOR_DARK_INK, Direction::Lighter),
            prefers_dark_ink: true,
        }
    } else {
        PageTint {
            rgb: moved(rgb, MAX_LUMINANCE_FOR_LIGHT_INK, Direction::Darker),
            prefers_dark_ink: false,
        }
    }
}

#[derive(Clone, Copy)]
enum Direction {
    Lighter,
    Darker,
}

/// The same colour at a stated luminance, reached by binary search.
///
/// Search rather than arithmetic because luminance is not linear in the channel
/// values, and the closed form for "scale three channels until the weighted sum
/// of their gamma-decoded values hits a target" is longer than the loop and
/// harder to read. Twenty-four halvings put the answer well inside the last bit
/// of an 8-bit channel.
fn moved(rgb: u32, target: f64, direction: Direction) -> u32 {
    let (mut low, mut high) = (0.0_f64, 1.0_f64);
    for _ in 0..24 {
        let middle = f64::midpoint(low, high);
        let candidate = scaled(rgb, middle, direction);
        if luminance(candidate) < target {
            match direction {
                Direction::Lighter => low = middle,
                Direction::Darker => high = middle,
            }
        } else {
            match direction {
                Direction::Lighter => high = middle,
                Direction::Darker => low = middle,
            }
        }
    }
    scaled(rgb, high, direction)
}

/// Every channel moved `amount` of the way toward white or toward black.
fn scaled(rgb: u32, amount: f64, direction: Direction) -> u32 {
    let channels = [
        f64::from((rgb >> 16) & 0xFF) / 255.0,
        f64::from((rgb >> 8) & 0xFF) / 255.0,
        f64::from(rgb & 0xFF) / 255.0,
    ];
    let moved = channels.map(|channel| match direction {
        Direction::Lighter => channel + (1.0 - channel) * amount,
        Direction::Darker => channel * (1.0 - amount),
    });
    pack(moved[0], moved[1], moved[2])
}

/// A parsed colour, alpha kept so a translucent one can be refused rather than
/// guessed at.
#[derive(Debug, Clone, Copy, PartialEq)]
struct Parsed {
    red: f64,
    green: f64,
    blue: f64,
    alpha: f64,
}

/// A colour string that is usable as a tint, or nothing.
///
/// Translucency is refused rather than composited. What sits behind a
/// half-transparent page background is the engine's canvas, which we would be
/// guessing at — and a guess that is wrong shows up as a strip that does not
/// match the page it is welded to. `rgba(0, 0, 0, 0)` is not an edge case here:
/// it is what `getComputedStyle` reports for the great majority of documents,
/// and falling through it is exactly how the chain reaches the rung that knows.
fn opaque(value: &str) -> Option<u32> {
    let parsed = parse(value)?;
    if parsed.alpha < 1.0 {
        return None;
    }
    Some(pack(parsed.red, parsed.green, parsed.blue))
}

fn parse(value: &str) -> Option<Parsed> {
    let value = value.trim();
    if value.is_empty() || value.len() > MAX_COLOR_LEN {
        return None;
    }
    if let Some(digits) = value.strip_prefix('#') {
        return hex(digits);
    }

    let lower = value.to_ascii_lowercase();
    if let Some(rest) = lower.strip_prefix("rgb") {
        return function(rest).and_then(|args| rgb_args(&args));
    }
    if let Some(rest) = lower.strip_prefix("hsl") {
        return function(rest).and_then(|args| hsl_args(&args));
    }
    named(&lower)
}

fn hex(digits: &str) -> Option<Parsed> {
    if !digits.bytes().all(|b| b.is_ascii_hexdigit()) {
        return None;
    }
    // Shorthand doubles each digit, which is what makes `#fff` white rather
    // than a very dark grey.
    let expand = |slice: &str| u8::from_str_radix(slice, 16).ok().map(f64::from);
    let (red, green, blue, alpha) = match digits.len() {
        3 | 4 => {
            let wide: String = digits.chars().flat_map(|c| [c, c]).collect();
            (
                expand(&wide[0..2])?,
                expand(&wide[2..4])?,
                expand(&wide[4..6])?,
                if digits.len() == 4 {
                    expand(&wide[6..8])?
                } else {
                    255.0
                },
            )
        }
        6 | 8 => (
            expand(&digits[0..2])?,
            expand(&digits[2..4])?,
            expand(&digits[4..6])?,
            if digits.len() == 8 {
                expand(&digits[6..8])?
            } else {
                255.0
            },
        ),
        _ => return None,
    };
    Some(Parsed {
        red: red / 255.0,
        green: green / 255.0,
        blue: blue / 255.0,
        alpha: alpha / 255.0,
    })
}

/// The arguments of `rgb(…)` / `hsl(…)`, whichever way the page spelled them.
///
/// Commas, spaces and the slash before alpha are all separators here. CSS gives
/// them different meanings and rejects the mixtures; we are reading rather than
/// validating, and a page that writes `rgb(1, 2 3)` meant a colour.
fn function(rest: &str) -> Option<Vec<String>> {
    let rest = rest.strip_prefix('a').unwrap_or(rest);
    let inside = rest.strip_prefix('(')?.strip_suffix(')')?;
    Some(
        inside
            .replace([',', '/'], " ")
            .split_whitespace()
            .map(str::to_string)
            .collect(),
    )
}

fn rgb_args(args: &[String]) -> Option<Parsed> {
    if args.len() < 3 {
        return None;
    }
    Some(Parsed {
        red: channel(&args[0])?,
        green: channel(&args[1])?,
        blue: channel(&args[2])?,
        alpha: args.get(3).map_or(Some(1.0), |a| alpha(a))?,
    })
}

fn hsl_args(args: &[String]) -> Option<Parsed> {
    if args.len() < 3 {
        return None;
    }
    let hue = args[0]
        .trim_end_matches("deg")
        .parse::<f64>()
        .ok()?
        .rem_euclid(360.0)
        / 360.0;
    let saturation = fraction(&args[1])?;
    let light = fraction(&args[2])?;
    let alpha = args.get(3).map_or(Some(1.0), |a| alpha(a))?;

    let chroma = (1.0 - (2.0 * light - 1.0).abs()) * saturation;
    let second = chroma * (1.0 - ((hue * 6.0).rem_euclid(2.0) - 1.0).abs());
    let base = light - chroma / 2.0;
    let (red, green, blue) = match (hue * 6.0) as u32 {
        0 => (chroma, second, 0.0),
        1 => (second, chroma, 0.0),
        2 => (0.0, chroma, second),
        3 => (0.0, second, chroma),
        4 => (second, 0.0, chroma),
        _ => (chroma, 0.0, second),
    };
    Some(Parsed {
        red: red + base,
        green: green + base,
        blue: blue + base,
        alpha,
    })
}

/// `120` or `47%`, as a 0–1 fraction.
fn channel(token: &str) -> Option<f64> {
    let value = match token.strip_suffix('%') {
        Some(percent) => percent.parse::<f64>().ok()? / 100.0,
        None => token.parse::<f64>().ok()? / 255.0,
    };
    Some(value.clamp(0.0, 1.0))
}

/// `0.5` or `50%`.
fn alpha(token: &str) -> Option<f64> {
    let value = match token.strip_suffix('%') {
        Some(percent) => percent.parse::<f64>().ok()? / 100.0,
        None => token.parse::<f64>().ok()?,
    };
    Some(value.clamp(0.0, 1.0))
}

fn fraction(token: &str) -> Option<f64> {
    let value = match token.strip_suffix('%') {
        Some(percent) => percent.parse::<f64>().ok()? / 100.0,
        None => token.parse::<f64>().ok()?,
    };
    Some(value.clamp(0.0, 1.0))
}

/// The colour keywords worth carrying.
///
/// Not all 148 of them. A `theme-color` is written by someone reaching for an
/// exact brand colour, and they reach for a hex; the keywords that show up in
/// the wild are the ones a person can name from memory. A page that says
/// `papayawhip` falls through to its background, which is the same colour
/// anyway.
fn named(name: &str) -> Option<Parsed> {
    const KEYWORDS: &[(&str, u32)] = &[
        ("black", 0x0000_0000),
        ("silver", 0x00C0_C0C0),
        ("gray", 0x0080_8080),
        ("grey", 0x0080_8080),
        ("white", 0x00FF_FFFF),
        ("maroon", 0x0080_0000),
        ("red", 0x00FF_0000),
        ("purple", 0x0080_0080),
        ("fuchsia", 0x00FF_00FF),
        ("magenta", 0x00FF_00FF),
        ("green", 0x0000_8000),
        ("lime", 0x0000_FF00),
        ("olive", 0x0080_8000),
        ("yellow", 0x00FF_FF00),
        ("navy", 0x0000_0080),
        ("blue", 0x0000_00FF),
        ("teal", 0x0000_8080),
        ("aqua", 0x0000_FFFF),
        ("cyan", 0x0000_FFFF),
        ("orange", 0x00FF_A500),
    ];

    if name == "transparent" {
        return Some(Parsed {
            red: 0.0,
            green: 0.0,
            blue: 0.0,
            alpha: 0.0,
        });
    }
    KEYWORDS
        .iter()
        .find(|(keyword, _)| *keyword == name)
        .map(|(_, value)| Parsed {
            red: f64::from((value >> 16) & 0xFF) / 255.0,
            green: f64::from((value >> 8) & 0xFF) / 255.0,
            blue: f64::from(value & 0xFF) / 255.0,
            alpha: 1.0,
        })
}

fn pack(red: f64, green: f64, blue: f64) -> u32 {
    let byte = |value: f64| (value.clamp(0.0, 1.0) * 255.0).round() as u32;
    (byte(red) << 16) | (byte(green) << 8) | byte(blue)
}

/// WCAG relative luminance, the same formula the shell's `Swatch` uses so both
/// sides of the FFI agree about what "light" means.
fn luminance(rgb: u32) -> f64 {
    let decode = |channel: u32| {
        let value = f64::from(channel) / 255.0;
        if value <= 0.040_45 {
            value / 12.92
        } else {
            ((value + 0.055) / 1.055).powf(2.4)
        }
    };
    0.2126 * decode((rgb >> 16) & 0xFF)
        + 0.7152 * decode((rgb >> 8) & 0xFF)
        + 0.0722 * decode(rgb & 0xFF)
}

#[cfg(test)]
#[path = "tint_tests.rs"]
mod tests;
