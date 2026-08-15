# ADR-0062: The store's own install button becomes ours, on the store's hosts and nowhere else

- **Status:** Accepted
- **Date:** 2026-07-06
- **Lock:** `crates/zer0-core/src/ext/ext_tests.rs::the_published_hosts_are_the_ones_the_parser_accepts`, `crates/zer0-core/src/ext/ext_tests.rs::the_published_hosts_refuse_every_other_origin`, `crates/zer0-core/src/ext/ext_tests.rs::a_suffix_only_matches_a_real_subdomain`, `crates/zer0-core/src/ext/ext_tests.rs::the_host_rule_ignores_case`, `apple/Tests/Zer0ShellTests/StoreInstallTests.swift::StoreInstallHostRuleTests/theScriptRunsWhereTheInstallerLooks`, `apple/Tests/Zer0ShellTests/StoreInstallTests.swift::StoreInstallHostRuleTests/theScriptRefusesEveryOtherOrigin`, `apple/Tests/Zer0ShellTests/StoreInstallTests.swift::StoreInstallHostRuleTests/theScriptRefusesPlainHttp`, `apple/Tests/Zer0ShellTests/StoreInstallTests.swift::StoreInstallMessageTests/theIdComesFromTheUrl`, `apple/Tests/Zer0ShellTests/StoreInstallTests.swift::StoreInstallMessageTests/nothingButTheKindIsReadOutOfAMessage`, `apple/Tests/Zer0ShellTests/StoreInstallTests.swift::StoreInstallMessageTests/anUnknownMessageIsNotAMessage`, `apple/Tests/Zer0ShellTests/StoreInstallTests.swift::StoreInstallFallbackTests/aFinishedPageThatSaidNothingHasNoButton`, `apple/Tests/Zer0ShellTests/StoreInstallTests.swift::StoreInstallFallbackTests/noButtonMeansTheBannerOffers`, `apple/Tests/Zer0ShellTests/StoreInstallTests.swift::StoreInstallRequestTests/aFlowInProgressKeepsTheBannerMounted`

## Context

Everything under the install button already worked. ADR-0021 fetches the CRX and
recognises a store page, ADR-0022 unpacks it under limits, ADR-0028 asks before
granting anything, ADR-0020 loads it into `WKWebExtension`. Measured on the real
listing for 1Password, all of it works.

What a person saw was a button greyed out, under a banner reading **"Switch to
Chrome to install extensions and themes"**. Google draws that for anything that
is not Chrome, and it is drawn on top of a browser that could have installed the
thing in three seconds.

`InstallBanner` was the answer to that and it was not enough, for two measured
reasons.

**It was often not on screen at all.** It is mounted from
`offeredExtensionId`, which reads the *tab's* URL out of the core. The store is
a single-page app: arriving at a listing from search or from the front page is a
`pushState`, and `HostedWebView` observes `title` and `isLoading` and not `url`,
so no `NavigationCommitted` is ever emitted. The frame is showing a listing and
the core still holds the URL of the page before it. Nothing appears.

**Where it did appear, it was in the wrong place for the gesture.** A capsule at
the foot of the window, while the eye and the pointer are on the button in the
middle of the page that says the browser is wrong. Two offers, and the one that
works is the quiet one.

Orion solves this by replacing the store's button. That is the difference
between *there is a way* and *it worked the way I expected*.

## Decision

**A `WKUserScript` replaces the store's install control with one of ours, on the
store's hosts and nowhere else.** `apple/Sources/Zer0Shell/StoreInstall.swift`
is the whole of it, and it is the first `userContentController` script in this
project.

Four things make injecting into somebody else's page something we are willing to
have at all.

### The host rule has one home, and it is the core's

`crates/zer0-core/src/ext/mod.rs::store_hosts` returns a `StoreHosts` — exact
hosts and dot-anchored suffixes. `extension_id_from_store_url` reads it, and the
shell reads it over the FFI and writes it into the script's first statement:

```js
if (location.protocol !== "https:" || !isStoreHost(location.hostname)) return;
```

It is a value rather than a predicate because the second reader is JavaScript
inside a page and cannot call back into Rust. So the *data* has one home and a
test holds the two readers to the same answer, host by host, including the ones
built to look like the store. **A script that leaks onto another origin is a far
worse defect than a greyed-out button**, and there is no version of this where
the shell keeps a second list somebody wrote from memory.

The dot on the suffix is a decision on its own:
`evil-chromewebstore.google.com` ends with the store's name and is not the
store.

### The channel is not in the page's world

The script and its message handler live in
`WKContentWorld.world(name: "zer0.store-install")`. The DOM is shared; the
globals are not. `window.webkit.messageHandlers.zer0StoreInstall` does not exist
for anything the store loads, and the store loads plenty.

### The page never names the extension, and never decides it may offer one

The message carries no id. `StoreInstallHost.subject(ofFrameAt:)` is the only
reading there is, and it asks the core about the main frame's committed URL.

The script does not even decide *whether* to draw a button. It reports that it
found a control it could take over; the shell asks the core whether that URL is
a listing, and only then calls back into the script to adopt it. That is the
tie-breaker from `AGENTS.md` applied literally: *what may be installed and from
where* is behaviour and is the core's, *where a button goes in a page* is the
platform's and is the shell's.

### Consent is untouched

Pressing the button in the page runs the same function the banner's own Add
button runs. Download, `ExtensionConsentSheet`, `applyConsent`. There is no
second install path, and therefore no path that skips the sheet.

> **Superseded in part by ADR-0069.** That was true and the *mechanism* was
> broken: the press set `BrowserModel.pendingStoreInstall`, `InstallBanner`
> picked it up and ran its own `install()`, and the banner is unmounted by the
> install succeeding — so the sheet was never presented and the button waited
> for an outcome that could not arrive. The flow now lives on `BrowserModel` and
> the sheet is presented by `BrowserView`. What this section claims is
> unchanged; where it happens is not.

We are also not pretending to be Chrome. ADR-0008 stands: the User-Agent carries
Safari's signature and then `zer0/`. The fix is to replace their button, not to
lie about who we are.

### Finding the control: the only disabled button

Measured against the real page rather than guessed. In `en-US` the label reads
*"Add to Chrome"*; in `pt-BR`, *"Usar no Chrome"*. Matching the label would work
in one language and fail in the other, which is the worse of the two failures
because it looks fixed.

What survives translation is that **it is the page's only disabled button** —
one, in both locales, on a listing. So that is the rule, and it fails closed:

- **none** — the store changed its markup;
- **two or more** — we cannot tell which one it is;

and both answer nothing at all. Rewriting the wrong button is worse than
rewriting none.

### What is left when it does not work

`InstallBanner` is the fallback and stays exactly what it was. The state is
three-valued per tab — `unknown`, `adopted`, `absent` — and `unknown` is not a
synonym for `absent`:

- the script reports `absent` only once `document.readyState === "complete"`, so
  the banner does not appear and vanish while the store is still drawing;
- the shell resolves `unknown` to `absent` once the tab has finished loading,
  because a page that finished arriving in silence is a page where the script
  did not run at all.

Neither is a timer. A failed injection degrades to the offer that shipped
before it, not to nothing.

And because `offeredExtensionId` can be stale on a single-page navigation, the
banner is also mounted whenever there is a pending request. Otherwise the button
in the page would post a message that nothing carries out — which is exactly the
bug this ADR exists to fix, moved one layer down.

## Consequences

**What hurts:**

- **We are editing a page we did not write, and it will break.** The store's
  markup is generated and changes without notice. The day the install control
  stops being the only disabled button, the button silently stops appearing.
  Nothing goes red — the fallback simply starts carrying the whole load again,
  which is the good version of this failure and still a regression nobody is
  told about.
- **The contradiction on the page stays.** Google's *"Switch to Chrome to
  install extensions and themes"* banner sits above our working button, because
  hiding it is more of their markup to guess at. Our button works and their
  banner says it cannot. That is ugly and it was chosen over being more fragile.
- **A `MutationObserver` runs for the whole time a store page is open.** The
  store is a single-page app and a one-shot injection is right exactly once. It
  is rate-limited to one pass per frame, and it is still a cost paid on every
  store page whether or not anything changes.
- **A script now runs on an origin we do not control, in every web view.** It
  returns on its first statement everywhere else, and "it returns immediately"
  is a claim about correctness, not an absence of risk. This is the first one;
  the second will be argued as cheap because this one exists.
- **The label is English.** The button in a `pt-BR` page reads "Add to zer0"
  next to the store's Portuguese. The whole product is English today, so this is
  consistent rather than right.

**What we get:**

- The gesture people already make does what they expect, in the place they
  already look.
- One rule for what the store is, in the core, read by both things that need it.
- Two independent gates on the id, neither of which the page can influence.

## How this regresses

**"A random site added an extension I never asked for."** The host rule was
loosened, most plausibly by someone adding the host to the Swift side "so the
test passes" rather than to `store_hosts`. `the_published_hosts_refuse_every_
other_origin` and `theScriptRefusesEveryOtherOrigin` are the two halves, and
both have to be walked past.

**"Some page made zer0 install something."** Somebody adds `body["id"]` to the
channel because it is "already there in the message" and saves a lookup.
`nothingButTheKindIsReadOutOfAMessage` reads the source and goes red; it exists
because `theIdComesFromTheUrl` proves the current path is safe and proves
nothing about a second one.

**"The Add button disappeared from the store."** The store changed its markup
and the fallback did not take over — most likely because somebody decided
`unknown` and `absent` were the same thing, which reads like a simplification
and removes the only thing that covers the script not running at all.
`aFinishedPageThatSaidNothingHasNoButton` is the lock, and it is the one worth
breaking on purpose.

**"The button in the page does nothing."** `InstallBanner` stops being mounted
when the tab's URL is stale — someone tightens `BrowserView.installBanner` back
to the listing alone because the second condition looks redundant. It is not:
`aFlowInProgressKeepsTheBannerMounted` is the case where they differ.

**And the one no test catches:** somebody decides the honest way to fix the
greyed-out button is to send Chrome's User-Agent. Everything gets easier for one
afternoon. ADR-0008 is the decision that says no, and nothing here re-states it
as an assertion.

## When to revisit

- **When the store stops drawing exactly one disabled button.** That is the exit
  condition, and it fires as a support report rather than as a build failure.
  The replacement is not a cleverer selector; it is deciding whether replacing
  somebody else's button is still worth it.
- When same-document navigation reaches the core. `HostedWebView` observes
  `title` and `isLoading` and not `url`, so a `pushState` leaves the tab's URL —
  and the address bar, and history — behind what is on screen. Fixing that
  removes the need for the second mounting condition here and is a bigger
  decision than this one, because it changes what gets written to history.
- If a second injected script is ever wanted. One script that returns
  immediately on every other origin is arguable; a habit is not. The next one
  should be forced to argue for itself, and the world and the host rule here are
  the shape to copy.
- When Linux is attempted. There is no `WKUserScript` there, and the equivalent
  in `webkit2gtk` is a different mechanism with different isolation. The host
  rule crosses unchanged because it is in the core; nothing else here does.
