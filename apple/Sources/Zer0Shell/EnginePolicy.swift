import WebKit

/// What `zer0` tells WebKit about the kind of client it is (ADR-0074).
///
/// A fresh `WKWebViewConfiguration` is configured for an embedded web view
/// inside somebody's app — a help pane, a sign-in sheet — and every default it
/// carries was chosen for that. A browser is a different client, and the
/// difference is not stylistic: with the defaults untouched a page has no
/// Fullscreen API at all, may start playing audible media on its own, and stops
/// executing the moment its tab is not the front one.
///
/// So this is the sheet of answers, in one place, deliberately including the
/// ones that agree with WebKit's default. Agreeing with a default and never
/// having considered it look identical in the code, and only one of them
/// survives Apple changing the default.
///
/// Every value below was measured against the macOS 26.5 SDK rather than read
/// off the header comments; the numbers are in ADR-0074.
@MainActor
enum EnginePolicy {
    /// The one answer a person is allowed to change.
    ///
    /// A struct with the default spelled out, rather than an optional the host
    /// reads through, so a host nobody has configured still blocks. The safe
    /// direction is the shipped direction. It is a struct rather than a bare
    /// `Bool` because the second setting to earn a switch should not have to
    /// change three signatures to get here.
    struct Choices: Equatable {
        var blockAudibleAutoplay = true
        var blockUnpromptedWindows = true
    }

    /// Everything the engine is told before a view exists.
    ///
    /// Called from `HostedWebView.init`, which is the only place in the shell
    /// that builds a `WKWebViewConfiguration`. One door, so there is nowhere a
    /// page can come from that missed this.
    static func apply(to config: WKWebViewConfiguration, choices: Choices = Choices()) {
        let preferences = config.preferences

        // Off by default, and "off" is total: `Element.requestFullscreen` is
        // not present on the page at all. A video player's fullscreen button
        // either throws or is feature-detected away, so the button is missing
        // rather than broken and nobody files a bug.
        preferences.isElementFullscreenEnabled = true

        // Already WebKit's default, and written down because it is the phishing
        // and malware warning. A security guarantee inherited by silence is one
        // nobody would notice losing.
        preferences.isFraudulentWebsiteWarningEnabled = true

        // Also already the default. WebKit's per-site workarounds are a large
        // part of how the web renders correctly in Safari, and this switch
        // exists for people *testing* a site without them. A browser is not
        // that.
        preferences.isSiteSpecificQuirksModeEnabled = true

        // The pop-up blocker every browser ships. WebKit's macOS default is
        // `YES`, which lets a page call `window.open` with nobody having
        // touched anything — the embedded-view answer.
        //
        // ADR-0074 made this a constant because it was unobservable: no
        // `WKUIDelegate` implemented `webView(_:createWebViewWith:…)`, so
        // `window.open` returned nothing on either setting and a switch would
        // have been a control with no effect. One does now (ADR-0075), and
        // this is exactly where the difference lands — measured, WebKit checks
        // this preference *before* consulting the delegate, so with it on an
        // unprompted `window.open` is `null` and the delegate is never called
        // at all. That is a blocker rather than a policy we have to write.
        reapply(to: preferences, choices: choices)

        // Measured: with the default `.suspend`, a web view out of the window
        // for 20 seconds ran its 100ms interval four times and only ticked
        // again when something touched it. `zer0` shows one tab at a time, so
        // "out of the window" is what every tab that is not the front one looks
        // like — the default freezes them all.
        preferences.inactiveSchedulingPolicy = .throttle

        // Both already the default, both written down because they are the
        // kind of thing a future edit drops in passing: the first is the only
        // automatic HTTPS upgrade WebKit performs on its own, and the second is
        // whether the AirPlay route picker appears on a video at all.
        config.upgradeKnownHostsToHTTPS = true
        config.allowsAirPlayForMediaPlayback = true

        // The macOS 15 text features, all three off by default because an
        // embedded web view is usually not where somebody writes prose. In a
        // browser the page *is* where somebody writes prose, and a text field
        // that has none of what the same person gets in every native app reads
        // as the browser being behind.
        config.allowsInlinePredictions = true
        config.supportsAdaptiveImageGlyph = true
        config.writingToolsBehavior = .complete

        // HTTPS-First: try https for a typed http address and fall back rather
        // than fail. Measured both halves — `http://info.cern.ch` arrives as
        // https, `http://httpforever.com`, which has no https at all, still
        // loads over http.
        //
        // `.userMediatedFallbackToHTTP` was refused rather than overlooked: it
        // puts WebKit's own interstitial on screen, which is chrome we do not
        // draw and cannot restyle, over a failure ADR-0016 says gets our whole
        // screen.
        config.defaultWebpagePreferences.preferredHTTPSNavigationPolicy = .automaticFallbackToHTTP

        // `.audio`, never `.all`. Measured: `.audio` blocks an `<audio
        // autoplay>` with `NotAllowedError` and lets a muted element through,
        // which is what Safari and Chrome both do. `.all` additionally blocks
        // *silent* video, which is the muted hero video on a large share of the
        // web, and `[]` — WebKit's default — blocks nothing at all.
        //
        // Set here, at birth, because there is nowhere else it can be set:
        // `WKWebView.configuration` hands back a **copy**, and a write to it
        // afterwards is dropped on the floor — measured, the property reads
        // back its old value and the next page autoplays exactly as before. So
        // a change to this setting reaches pages opened from then on, and the
        // row in Settings says exactly that rather than implying more
        // (ADR-0018).
        config.mediaTypesRequiringUserActionForPlayback = choices.blockAudibleAutoplay ? .audio : []
    }

    /// The part of the sheet a page that is already open can still be told
    /// about.
    ///
    /// `WKWebView.configuration` hands back a **copy**, so a value written on
    /// the configuration afterwards is dropped on the floor — measured, and it
    /// is why the autoplay row promises only pages opened from now on
    /// (ADR-0074). `WKPreferences` is not copied with it: the same object is
    /// still reachable through that copy, and a write to it lands on the
    /// view's next page load. Measured, not assumed.
    ///
    /// So this exists to let one row make a better promise than the other,
    /// and it is called from both places rather than duplicated: `apply` runs
    /// it at birth, `EngineHost.policy` runs it over every live view when
    /// somebody changes the setting.
    static func reapply(to preferences: WKPreferences, choices: Choices) {
        preferences.javaScriptCanOpenWindowsAutomatically = !choices.blockUnpromptedWindows
    }
}
