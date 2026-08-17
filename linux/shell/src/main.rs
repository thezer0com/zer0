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
    // of truth (ADR-0040), parsed straight into the GSK path this shell draws
    // — no transcription, so no drift. A file GSK cannot parse refuses to
    // start rather than draw a wrong mark or none silently.
    let mark_data = match tokens::mark_path_data() {
        Ok(data) => data,
        Err(error) => refuse(&error),
    };
    let mark = match gtk::gsk::Path::parse(&mark_data) {
        Ok(path) => path,
        Err(error) => refuse(&format!(
            "design/logo/zer0.svg: GSK cannot parse the mark: {error}"
        )),
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

/// The one exit shape for a design artifact that will not load: say what and
/// why, and stop. Every caller is `main`.
fn refuse(error: &str) -> ! {
    eprintln!("zer0: {error}");
    std::process::exit(1);
}
