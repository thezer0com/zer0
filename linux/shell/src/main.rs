//! The Linux shell's entry point: load the tokens, paint the chrome from
//! them, and hand the window to `host`.

mod host;
mod tokens;

use gtk::prelude::*;
use gtk4 as gtk;

fn main() {
    // Before the window, because a browser whose colours come from anywhere
    // but this file is not this browser (ADR-0117) — refusing to start is the
    // honest failure, not a fallback palette.
    let design = match tokens::load() {
        Ok(design) => design,
        Err(error) => refuse(&error),
    };
    // The mark is the same class of artifact: the SVG on disk is the source
    // of truth (ADR-0040). Every layer keeps its declared fill and is parsed
    // into the GSK path this shell draws — no transcription, so no drift.
    let mark = match tokens::mark() {
        Ok(mark) => mark,
        Err(error) => refuse(&error),
    };
    let mark = match parse_mark_paths(mark) {
        Ok(mark) => mark,
        Err(error) => refuse(&error),
    };
    let dark = tokens::system_prefers_dark();

    let application = gtk::Application::new(
        Some("com.thezer0.browser"),
        gtk::gio::ApplicationFlags::empty(),
    );

    {
        // `connect_activate` takes `Fn`, so the tokens travel by clone into a
        // second closure that hands them to the one activation there is.
        let css = tokens::css(&design, dark);
        let prefer_dark = dark;
        application.connect_activate(move |application| {
            if let Some(settings) = gtk::Settings::default() {
                settings.set_property("gtk-application-prefer-dark-theme", prefer_dark);
            }
            let display =
                gtk::gdk::Display::default().expect("activation means a display opened the window");
            let provider = gtk::CssProvider::new();
            provider.load_from_string(&css);
            gtk::style_context_add_provider_for_display(
                &display,
                &provider,
                gtk::STYLE_PROVIDER_PRIORITY_APPLICATION,
            );
            host::app_for(application, &design, dark, &mark);
        });
    }

    let status: i32 = application.run().into();
    std::process::exit(status);
}

fn parse_mark_paths(
    mark: tokens::MarkSet<String>,
) -> Result<tokens::MarkSet<gtk::gsk::Path>, String> {
    Ok(tokens::MarkSet {
        canonical: parse_mark_master(mark.canonical, "design/logo/zer0.svg")?,
        hinted: parse_mark_master(mark.hinted, "design/logo/zer0-small.svg")?,
    })
}

fn parse_mark_master(
    mark: tokens::Mark<String>,
    name: &str,
) -> Result<tokens::Mark<gtk::gsk::Path>, String> {
    let layers = mark
        .layers
        .into_iter()
        .enumerate()
        .map(|(index, layer)| {
            gtk::gsk::Path::parse(&layer.path)
                .map(|path| tokens::MarkLayer {
                    path,
                    fill: layer.fill,
                    fill_rule: layer.fill_rule,
                })
                .map_err(|error| format!("{name}: GSK cannot parse layer {}: {error}", index + 1))
        })
        .collect::<Result<Vec<_>, _>>()?;
    Ok(tokens::Mark {
        view_box: mark.view_box,
        layers,
    })
}

/// The one exit shape for a design artifact that will not load: say what and
/// why, and stop. Every caller is `main`.
fn refuse(error: &str) -> ! {
    eprintln!("zer0: {error}");
    std::process::exit(1);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_layer_gsk_cannot_parse_refuses() {
        let mark = tokens::Mark {
            view_box: tokens::MarkViewBox {
                width: 170,
                height: 199,
            },
            layers: vec![tokens::MarkLayer {
                path: "not SVG path data".to_string(),
                fill: tokens::MarkColor {
                    red: 0x63,
                    green: 0x5b,
                    blue: 0xc9,
                },
                fill_rule: tokens::MarkFillRule::Winding,
            }],
        };

        let error = parse_mark_master(mark, "design/logo/zer0.svg")
            .err()
            .expect("GSK must refuse malformed path data");

        assert!(error.contains("GSK cannot parse layer 1"), "{error}");
    }
}
