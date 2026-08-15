# ADR-0074: The engine is configured for a browser, not for an embedded web view

- **Status:** Accepted, and partly superseded by ADR-0075 — everything about the
  engine sheet stands; the two paragraphs refusing pop-up blocking a Settings
  row do not. They rested on no `WKUIDelegate` implementing
  `webView(_:createWebViewWith:…)`, which was true when this was written and is
  not now, and this file names that as the condition under which the row is
  earned.
- **Date:** 2026-08-07
- **Lock:** `apple/Tests/Zer0ShellTests/EnginePolicyTests.swift::EnginePolicyTests/aPageGetsTheFullscreenApi`, `apple/Tests/Zer0ShellTests/EnginePolicyTests.swift::EnginePolicyTests/audibleMediaWaitsForAPersonAndMutedMediaDoesNot`, `apple/Tests/Zer0ShellTests/EnginePolicyTests.swift::EnginePolicyTests/everyPageIsBuiltForABrowserRatherThanForAnEmbeddedView`, `apple/Tests/Zer0ShellTests/EnginePolicyTests.swift::EnginePolicyTests/turningAPageSettingOffReachesTheEngine`, `apple/Tests/Zer0ShellTests/EnginePolicyTests.swift::EnginePolicyTests/theEnginePolicyIsAppliedWhereTheOnlyConfigurationIsBuilt`, `crates/zer0-core/src/store_tests.rs::autoplay_blocking_ships_on_and_survives_being_turned_off`

## Context

Until this ADR, the whole of what `zer0` set on a `WKWebViewConfiguration` was
the data store, `applicationNameForUserAgent`, the extension controller, the
inspector switches and a per-space `customUserAgent`. Everything else sat at
`WKWebView`'s defaults.

Those defaults are not neutral. They are the defaults for **an embedded web view
inside somebody's app** — a help pane, a sign-in sheet, a release-notes window —
and each was chosen for that. A browser is a different client, and accepting a
default chosen for a different client is a decision made by omission.

Every number below was measured on the macOS 26.5 SDK (macOS 26.6, Xcode's
`WKPreferences.h` / `WKWebViewConfiguration.h` / `WKWebpagePreferences.h`) by
reading the properties off a fresh `WKWebViewConfiguration()`, not read off the
header comments.

| `WKPreferences` | default |
| --- | --- |
| `minimumFontSize` | `0` |
| `javaScriptCanOpenWindowsAutomatically` | **`true`** |
| `isFraudulentWebsiteWarningEnabled` | `true` |
| `shouldPrintBackgrounds` | `false` |
| `tabFocusesLinks` | `false` |
| `isTextInteractionEnabled` | `true` |
| `isSiteSpecificQuirksModeEnabled` | `true` |
| `isElementFullscreenEnabled` | **`false`** |
| `inactiveSchedulingPolicy` | **`.suspend`** (raw `0`) |

| `WKWebViewConfiguration` | default |
| --- | --- |
| `suppressesIncrementalRendering` | `false` |
| `allowsAirPlayForMediaPlayback` | `true` |
| `showsSystemScreenTimeBlockingView` | `true` |
| `upgradeKnownHostsToHTTPS` | `true` |
| `mediaTypesRequiringUserActionForPlayback` | **`[]`** (raw `0`) |
| `limitsNavigationsToAppBoundDomains` | `false` |
| `allowsInlinePredictions` | **`false`** |
| `supportsAdaptiveImageGlyph` | **`false`** |
| `userInterfaceDirectionPolicy` | `.content` |
| `writingToolsBehavior` | `.default` (raw `0`; the header says the behaviour is `limited`) |

| `defaultWebpagePreferences` | default |
| --- | --- |
| `allowsContentJavaScript` | `true` |
| `isLockdownModeEnabled` | follows the system |
| `preferredHTTPSNavigationPolicy` | **`.keepAsRequested`** |
| `securityRestrictionMode` (macOS 26.5) | `.none` |

Three corrections to what was believed when this work started, all found by
reading the headers rather than a list:

- **`allowsInlineMediaPlayback` does not exist on macOS.** It sits inside
  `#if TARGET_OS_IPHONE` in `WKWebViewConfiguration.h`. There is nothing to
  turn on.
- **`upgradeKnownHostsToHTTPS` is on the configuration only**, not on
  `WKPreferences`.
- The list of properties worth deciding was longer than the one we started
  with: `limitsNavigationsToAppBoundDomains`, `userInterfaceDirectionPolicy`,
  `preferredHTTPSNavigationPolicy` and `securityRestrictionMode` were all
  sitting at defaults nobody had looked at.

### Fullscreen was in fact broken, and worse than "broken"

`elementFullscreenEnabled` defaults to `NO`. That much was suspected. What was
not is that `NO` does not mean the request is refused — measured in a real page
in a real window, with the preference at its default:

```
typeof Element.prototype.requestFullscreen   -> undefined
document.fullscreenEnabled                   -> undefined
```

The API is **absent**, not denied. A video player feature-detects that and hides
its own fullscreen button, so the symptom is a control that was never there
rather than one that does nothing, and nobody reports it as a bug. With the
preference on, in the same probe, the method is a `function` and
`document.fullscreenEnabled` is `true`.

**What was not measured, and so is not claimed:** an actual transition into
fullscreen. Every run of the probe reported `document.visibilityState ===
"hidden"` — the probe's window was occluded by the author's own screen — and
WebKit refuses with *"Cannot request fullscreen in a hidden document."* That
refusal arrives **after** the user-activation check, which is itself a finding
worth keeping: `evaluateJavaScript` carries a user gesture, so any question
about what a page may do unprompted has to be asked by the page.

### Autoplay: the default lets any page make noise

Measured with the page starting playback itself, in a `<script>` at load, with
nobody having touched anything:

| `mediaTypesRequiringUserActionForPlayback` | audible `<audio>` | muted `<audio>` | silent video |
| --- | --- | --- | --- |
| `[]` — **the default** | **played** | played | played |
| `.audio` | blocked, `NotAllowedError` | played | played |
| `.video` | **played** | played | blocked |
| `.all` | blocked | played | blocked |

Two things fall out of that table. The gate is on **sound**, not on media: muted
media plays under every setting, including `.all`. And `.all` is the wrong
reading of "block autoplay" — the only thing it adds over `.audio` is blocking
*silent* video, which is the muted hero video on a large share of the web.

### A background tab is frozen, not throttled

`zer0` draws one tab at a time, so every tab that is not the front one has its
web view out of the window — exactly the state `inactiveSchedulingPolicy`
governs. Measured with a 100ms `setInterval`, the view removed from its window
for 20 seconds:

| policy | ticks in 20s | last tick, at the moment of reading |
| --- | --- | --- |
| `.suspend` — **the default** | 4 | 0ms ago |
| `.throttle` | 20 | 909ms ago |
| `.none` | 21 | 988ms ago |

"0ms ago" is the finding: the page had stopped, and the read is what woke it.
`.throttle` and `.none` are indistinguishable here because WebKit already
throttles a hidden document's timers to about 1Hz on its own, which is what
Chrome and Safari do to a background tab.

### HTTPS-First is available and off

Measured over the network, comparing final URLs:

| policy | `http://info.cern.ch` | `http://httpforever.com` (no https at all) |
| --- | --- | --- |
| `.keepAsRequested` — **the default**, and `zer0` today | `http://` | `http://` |
| `.automaticFallbackToHTTP` | **`https://`** | `http://` |

`upgradeKnownHostsToHTTPS`, which is already on, upgraded neither: its list of
known hosts is much narrower than it sounds.

### Half of this can be changed on a page that is already open, and half cannot

This is what decides whether a Settings switch can be honest, so it was
measured rather than assumed:

| changed after the view exists | reaches the open page | reaches its next page load |
| --- | --- | --- |
| a `WKPreferences` value (`isElementFullscreenEnabled`) | **no** | **yes** |
| a `WKWebViewConfiguration` value (`mediaTypesRequiringUserActionForPlayback`) | no | **no** |



The configuration row is the sharp one, and the reason is in the header:
`WKWebView.configuration` is declared `copy`. The write does not merely fail to
take effect — it is **dropped**, and the property reads back its old value.
Measured: a view built with `[]`, set to `.audio` afterwards, reported `0` and
went on autoplaying through a reload and a fresh page load.

So a setting on `WKPreferences` can be re-applied to every live view and lands
on the next load; a setting on the configuration reaches views built afterwards
and nothing else. A switch that claimed otherwise would be exactly the kind of
statement ADR-0018 forbids, which is why the one switch this ADR ships says
"pages you open from now on" in as many words.

## Decision

**Every answer lives in `apple/Sources/Zer0Shell/EnginePolicy.swift`, applied
from `HostedWebView.init`, which is the only place in the shell that builds a
`WKWebViewConfiguration`.** One door, so there is nowhere a page can come from
that missed it.

The sheet deliberately includes settings that agree with WebKit's default.
Agreeing with a default and never having considered it look identical in the
code, and only one of the two survives Apple changing the default.

**Turned on:**

| setting | from | to | what a person notices |
| --- | --- | --- | --- |
| `isElementFullscreenEnabled` | `false` | `true` | video players get their fullscreen button back |
| `inactiveSchedulingPolicy` | `.suspend` | `.throttle` | a background chat or mail tab still receives while you are elsewhere |
| `javaScriptCanOpenWindowsAutomatically` | `true` | `false` | a page cannot open a window with nobody having touched anything |
| `allowsInlinePredictions` | `false` | `true` | inline predictive text in a page's fields, as in every native app |
| `supportsAdaptiveImageGlyph` | `false` | `true` | Genmoji inserted at their real size instead of as flat images |
| `writingToolsBehavior` | `.default` | `.complete` | the full Writing Tools experience in a page's text, not the cut-down one |
| `preferredHTTPSNavigationPolicy` | `.keepAsRequested` | `.automaticFallbackToHTTP` | a typed `http://` address arrives over https where https exists |

**Written down at the value it already had**, because these are guarantees we
depend on rather than coincidences: `isFraudulentWebsiteWarningEnabled`,
`isSiteSpecificQuirksModeEnabled`, `upgradeKnownHostsToHTTPS`,
`allowsAirPlayForMediaPlayback`.

**Every capability is on out of the box, and the one restriction that a person
can see gets a switch.**

`block_audible_autoplay` is a field in `crates/zer0-core/src/preferences.rs`,
defaulting to on, rendered in Settings as **"Block sound that starts on its
own"**. It sits beside `block_content`, which already set the pattern and
already ships on for the same argument: a browser whose default is to be tracked
is a broken default, and so is a browser whose default is that any page may make
noise. A session file written before it existed has no row for it, and a missing
row leaves the default — so upgrading does not quietly switch anybody's blocking
off.

**`.audio`, never `.all`.** With the switch on the value is `.audio`: muted media
still autoplays, which is what Safari and Chrome do. `.all` was refused in the
other direction — it blocks *silent* video, which is the muted hero video on a
large share of the web, and is the wrong reading of "block autoplay".

**The row promises pages opened from now on, and no sooner.** Autoplay is a
configuration value that `WKWebView` copies at birth, so an open tab cannot be
told about it at all. That sentence is in the row rather than in this file
because the person changing it is the one who needs it.

**Pop-up blocking deliberately gets no switch**, and this is the sharper half of
the same principle. `javaScriptCanOpenWindowsAutomatically = false` is a
constant in `EnginePolicy`, not a preference, because **no `WKUIDelegate` in
this shell implements `webView(_:createWebViewWith:…)`** — so `window.open`
returns nothing whether the preference is on or off. A row in Settings for it
would be a control a person can toggle all day with no effect anywhere, which is
the shape of defect ADR-0018 exists to forbid and which this project has already
shipped once, when the theme preference was persisted and rendered nothing. The
value is set now so that the day windows can open, unprompted ones already
cannot; that is the day it earns a row.

**Deliberately left at the default, each for a reason:**

- `suppressesIncrementalRendering` — `true` is a blank window until the last
  byte lands.
- `limitsNavigationsToAppBoundDomains` — `true` confines a browser to a list in
  a plist.
- `isTextInteractionEnabled` — `false` is a page whose text cannot be selected.
- `userInterfaceDirectionPolicy` — `.content` is right: a page's direction comes
  from the page.
- `allowsContentJavaScript` — a global "no JavaScript" switch is not a thing a
  browser has. If this ever moves it is per-site or per-space, not here.
- `isLockdownModeEnabled` — follows the system, and it must. Overriding it in
  either direction answers for a person who has already answered.
- `showsSystemScreenTimeBlockingView` — `true` already, and a browser that
  silently ignores Screen Time is one nobody can put on a family Mac. Not
  written down only because it is macOS 26.0+ against a 15.4 deployment target,
  and an availability branch that writes the value already there buys nothing.
- `minimumFontSize`, `tabFocusesLinks`, `shouldPrintBackgrounds` — **these
  belong in Settings, not in this file**, and they are the next three rows when
  somebody wants them. A hard-coded minimum font size overrides every site's
  design for everyone; tab-focuses-links is a preference Safari exposes and
  macOS has a system switch for; printing backgrounds is a checkbox in a print
  sheet, which is where Chrome puts it. All three are the right default today
  and the wrong thing to freeze. None got a switch now because none of them has
  a wrong default to protect somebody from — unlike autoplay, which does.
- `securityRestrictionMode` (macOS 26.5) — `.maximizeCompatibility` turns off
  JIT in exchange for hardening. That is a real trade and **the author's call,
  not this ADR's**; it is a Settings candidate under a name like "Enhanced
  security", per-site or per-space rather than global.
- `allowsMagnification` on `WKWebView` — `false`, so pinch-to-zoom does nothing
  today, and turning it on here would be a trap rather than a feature. It is a
  **second** zoom factor sitting beside `pageZoom`, which the core owns and which
  ⌘+, ⌘− and ⌘0 drive. Switch it on alone and a pinch magnifies a page that ⌘0
  then cannot reset, because ⌘0 resets the factor the core knows about and the
  magnification is not it — a page stuck at 1.4× with no keyboard way back. That
  is the state drift ADR-0002 exists to prevent, and undoing it means deciding
  what pinch *means* here: scale, like Safari, or reflow, like Chrome. Its own
  decision, not a line on this sheet.
- **Feature flags.** `WKPreferences._features`, `_WKFeature` and every
  underscored spelling stay out, which is ADR-0001 as narrowed by ADR-0067 and
  not reopened here.

**Per-space.** Two of these would sit naturally on `SpaceProfile` beside
`userAgent`, and neither is built: the autoplay policy (a work space where
nothing ever plays) and `allowsContentJavaScript`. Both are core-side decisions
if they happen — the shell would carry them the way it already carries the user
agent.

## Consequences

Pages get an API surface they did not have. That is the point, and it is also
the exposure: fullscreen, Writing Tools, adaptive image glyphs and inline
predictions are all engine code paths this project was not exercising before.
The failure mode of each is contained to the feature — a Writing Tools bug is a
bad rewrite, not a page that will not load.

Two behaviour changes are visible immediately and are meant to be:

- **A page that used to start playing with sound now waits.** Some site
  somewhere will look broken to somebody who liked that it played. That is the
  trade, taken knowingly.
- **A background tab keeps running.** `.throttle` costs battery relative to
  `.suspend` — a suspended tab costs nothing at all. The measured cost is about
  one timer callback per second per background tab, which is what every other
  browser spends, and the thing bought is a tab that has your messages in it
  when you come back.

`.automaticFallbackToHTTP` adds a round trip on the http-only sites that remain.
`.userMediatedFallbackToHTTP` was refused rather than overlooked: it puts
WebKit's own interstitial on screen, which is chrome we do not draw and cannot
restyle, over a failure ADR-0016 says gets our whole screen.

`javaScriptCanOpenWindowsAutomatically = false` **changes nothing observable
today**, and that is said here rather than left to be discovered: the shell
implements no `webView(_:createWebViewWith:…)`, so `window.open` returns nothing
either way. It is set now so that the day windows can open, unprompted ones
already cannot — and it is the reason that one is not in Settings.

## How this regresses

**Somebody clears the autoplay field.** It is the single line on the sheet that
does not read as "turn the browser feature on", so it is the one a later pass
tidies for consistency — and the tidier-looking version is a browser that starts
making noise. `audibleMediaWaitsForAPersonAndMutedMediaDoesNot` goes red on the
page itself.

**Somebody swings the other way, to `.all`.** This one is worth spelling out
because the obvious lock does not catch it, and that was found by breaking the
decision on purpose rather than by reasoning: under `.all`, muted *audio* still
plays, so the behavioural test above stays **green**. The only thing `.all`
blocks that `.audio` does not is silent **video**, which needs a real video
source this suite cannot produce without a fixture or a byte off the network.
So the `.all` direction is held by two value assertions that name `.audio`
exactly — in `everyPageIsBuiltForABrowserRatherThanForAnEmbeddedView` and in
`turningAPageSettingOffReachesTheEngine` — and the gap is written into the test's
own comment so the next person does not have to rediscover it.

**The switch stops reaching disk.** A preference the store writes and never
reads back looks right in Settings for the rest of the session and is gone on
the next launch, which reads as "it forgot" rather than as a missing line.
`autoplay_blocking_ships_on_and_survives_being_turned_off` asserts the default
and the round trip in one, and was watched going red with the read deleted.

**The switch becomes a value written to disk and applied to nothing.** This has
already happened once in this repository — the theme preference was persisted
and rendered nothing — and it is the default outcome for a setting whose apply
path is a second thing to remember. `applyEnginePolicy` sits beside
`applyBlockingChange` at the one door every preference goes through, and
`turningAPageSettingOffReachesTheEngine` opens a tab after the change and asks
the engine what it got.

**Somebody gives pop-up blocking a switch to match.** It reads like an oversight
and it is not one: nothing in this shell can open a window, so the control would
do nothing on either setting. The guard is the paragraph above and the comment at
the line itself; there is no test, because a test cannot see a control that does
nothing — which is exactly why the rule had to be written down instead.

**The suite starts failing somewhere else.** This one already happened while
this ADR was being written, and it is recorded because the symptom pointed at
innocent code. Five of these tests running at once — three `BrowserModel`s,
three page loads and a window — starved the two-second debounce that
`SessionPersistenceTests/aStructuralChangeIsWrittenWithoutWaitingForTheTimer`
waits fifteen seconds for. Measured: 0 failures in 3 runs without this file, 2
in 3 with it, and the red test was always the *other* one. `EnginePolicyTests`
is `@Suite(.serialized)` for that reason and no other; 6 runs clean afterwards.
Anything added here that loads a page should stay inside that.

**A second door opens.** Someone builds a `WKWebViewConfiguration` somewhere
else — an icon fetcher, a print view, a preview — and that page silently gets
the embedded-view defaults back, while every property assertion in the test file
stays green because they all ask the model for the tab it made.
`theEnginePolicyIsAppliedWhereTheOnlyConfigurationIsBuilt` counts the doors
rather than trusting there is one, and fails naming the file.

**The sheet is trimmed.** Four lines write the value WebKit already has, and
they look like waste. They are the difference between a default we chose and a
default we inherited, and they are what notices the day Apple changes one.
`everyPageIsBuiltForABrowserRatherThanForAnEmbeddedView` reads them off a live
tab, so deleting a line and losing the value both go red — and it also asserts
the four we deliberately do *not* set, which is the same check pointed the other
way.

**Fullscreen quietly stops working again.** `elementFullscreenEnabled` is the
kind of line that gets moved to "the first time somebody presses fullscreen",
which is the mistake ADR-0067 already paid for once with the inspector: a
preference set after a page has loaded does not reach it.
`aPageGetsTheFullscreenApi` asks the page for the method rather than asking the
configuration for the flag, so a flag that is set but did not arrive fails.

**A test is written with `evaluateJavaScript`.** It carries a user gesture. Any
future question of the form "may a page do this unprompted" that is driven from
the test rather than from a `<script>` in the page will pass while the browser
does the wrong thing. The comment at the top of `EnginePolicyTests` says so;
there is no lock for it, because it is a way of asking rather than a value.

## When to revisit

- **A property on this sheet stops behaving as measured.** All of these are
  system-WebKit behaviour, and the whole record above is a snapshot of macOS
  26.5. `everyPageIsBuiltForABrowserRatherThanForAnEmbeddedView` catches a
  changed *default*; a changed *behaviour* behind an unchanged value is what
  the two behavioural tests are for.
- **A public API appears for something currently absent.** Muting a page still
  has none (ADR-0001), and the injected-JavaScript mute in `EngineHost` is the
  standing reminder.
- **`securityRestrictionMode`, `allowsMagnification`, `minimumFontSize` or
  `tabFocusesLinks` gets an owner.** Each is named above as somebody's decision
  rather than nobody's; the moment Settings has a place for it, it stops being
  a default by omission and this ADR should be superseded rather than edited.
- **A per-space autoplay or JavaScript switch is wanted.** That is a `SpaceProfile`
  field and a core decision, and it supersedes the global answer here.
- **We ship a WebKit of our own (ADR-0005).** Feature flags are excluded above
  because they are SPI against a binary that updates underneath us. In a build
  we ship they are configuration, not SPI, and the argument in ADR-0001 stops
  applying on its own terms. That is the one condition under which the flag
  question is worth reopening, and it should be reopened as its own ADR rather
  than folded into this one.
