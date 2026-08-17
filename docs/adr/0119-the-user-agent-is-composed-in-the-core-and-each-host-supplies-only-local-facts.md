# ADR-0119: The User-Agent is composed in the core, and each host supplies only local facts

- **Status:** Accepted
- **Date:** 2026-08-16
- **Lock:** `crates/zer0-core/src/ua_tests.rs::our_token_comes_after_the_safari_signature`, `crates/zer0-core/src/ua_tests.rs::extension_contexts_name_chrome_and_browsing_pages_do_not`, `crates/zer0-core/src/ua_tests.rs::without_an_installed_safari_the_signature_falls_back_rather_than_thins`

## Context

Since ADR-0008, the User-Agent has been composed in the Apple shell:
`EngineHost.swift` read the installed Safari's version out of its bundle,
hardcoded the `"18.3"` fallback, the fixed `Safari/605.1.15` suffix and the
`Chrome/138.0.0.0` marketplace token, and decided the order — Safari's
signature, then Chrome's in extension contexts (ADR-0106), then ours.

Every one of those is a decision about browser behaviour, not about macOS.
The test is ADR-0002's tie-breaker: could two platforms reasonably disagree
about the order the tokens come in, or whether extension contexts name
Chrome? No — a Linux host that put `zer0/` first would be breaking the same
sniffing, for the same reason, with nobody to notice the divergence. What a
host *can* legitimately disagree about is what is installed on the machine:
which Safari version to read, and where its own app version lives. Those are
inputs, and they are the only part of this that was ever the shell's to own.

The composition was also untested on the shell side except through live web
views. The exact strings — fallback included — had no test that could go red
without opening a window, which is why they are being moved rather than
rewritten: **the observable behaviour does not change.** Same string, same
situations, one new house.

## Decision

`crates/zer0-core/src/ua.rs::user_agent` is the one door. It takes the two
facts only a host can read — the installed Safari's version and this app's
own, both `Option` — plus a `UserAgentContext` (`Browsing` or
`WebExtension`), and returns the string:

- **The core owns every rule.** The order (`zer0/` last, always), the
  fallbacks (`"18.3"`, `"0.1.0"`), the fixed `Safari/605.1.15` suffix, the
  `Version/` and `zer0/` spellings, and `CHROME_MARKETPLACE_TOKEN`
  (`Chrome/138.0.0.0`, the recent-stable shape ADR-0106 chose — deliberately
  not ADR-0078's far-ahead store version, for the reason that constant's
  comment spells out).
- **The shell owns the reading and the applying.** `EngineHost.swift` reads
  `installedSafariVersion` and `appVersion` out of their bundles, calls the
  core once per context, and sets the two properties it always set:
  `applicationNameForUserAgent` on views it builds, and the Chrome-compatible
  token on the extension controller's configuration. A space's own
  `user_agent` still replaces the answer wholesale where it always did —
  ADR-0008's isolation half, untouched.

The strings ADR-0008 and ADR-0106 describe are unchanged, and their Swift
locks still defend them end to end: `ourTokenComesLast` reads a real page's
`navigator.userAgent`, `theUserAgentNamesNoOtherBrowser` and
`theExtensionContextNamesChromeButPagesDoNot` read a live worker and a live
page. This ADR adds the composition-level half those tests cannot be: the
same rules asserted against the function itself, red without a web view.

## Consequences

**What hurts:**

- **The core now knows the shape of a User-Agent**, which is a web-compat
  concern rather than browser state. It knows nothing about `WKWebView`, and
  the string is data — but a reader of `ua.rs` is entitled to ask why a
  browser core spells Safari's signature, and the answer is three ADRs long.
- **The shell constants the tests used to read are gone.** `safariSignature`,
  `browserToken` and `chromeMarketplaceToken` no longer exist in Swift;
  `signatureIsDerivedFromTheSystem` and `browserTokenHasAVersion` now assert
  against the composed token instead of the removed pieces. Same names, same
  protection, one indirection more.
- **One more FFI function**, and the enum it carries — the cost of every rule
  that crosses the boundary so it can be the same rule on both sides of it.

**What we get:**

- A Linux host cannot drift on UA policy. It reads its own inputs, calls the
  same function, and gets the same promise ADR-0008 made.
- The exact fallback strings are tested without a web view, which they never
  were: the `"18.3"` path had no red-able test on the machine that matters,
  only a live page that would never exercise it.
- The Chrome token sits in the core beside `CHROME_VERSION_FOR_DOWNLOADS`,
  where the comment can keep the two from being mistaken for one rule —
  which is a mistake the shell made easy by holding only one of them.

## How this regresses

**"The shell recomposes it, just locally, for this one fix."** Someone needs a
host-specific token yesterday, reinstates a Swift-side string, and the two
platforms are divergent the way this exists to prevent. Nothing here goes red
— the Rust tests still pass, and the Swift locks only see the page, which
still carries whatever the shell built. That gap is the same shape as
ADR-0078's "one no test catches" (a second spelling of the number somewhere
the tests are not), and it is watched the same way: nothing, until the
strings differ.

**"The two constants collapse."** A tidying reviewer points out that
`safariUserAgentToken` and `chromeCompatibleUserAgentToken` are now one call
with one argument between them and folds them into a single constant.
`theExtensionContextNamesChromeButPagesDoNot` goes red reading a live worker,
and `extension_contexts_name_chrome_and_browsing_pages_do_not` goes red
without opening a window. The argument *is* the split; deleting it is
deleting the decision.

**"The order flips in the core."** Same regression ADR-0008 named, one house
over. `our_token_comes_after_the_safari_signature` holds it in Rust and
`ourTokenComesLast` holds it in a real page; the first screams sooner, the
second is the one that proves the page agrees.

## When to revisit

- **When a host's engine stops being Safari-descended** — the Linux host, or
  a WebKit of our own (ADR-0008's own trigger, ADR-0005 leaving "in
  progress"). Then the Safari *signature* stops describing what is running,
  and the honest input is no longer "the installed Safari's version" but
  something the host must say about its engine. The door stays; the input's
  meaning is what moves.
- **When WebKit ships per-context UA** (ADR-0106's first exit). If the split
  narrows to per-extension, the context argument grows finer and the
  composition may want more than a two-way enum.
- **When a platform genuinely disagrees about a token** — if some host ever
  has a real reason to carry a different browser's name on pages, that is a
  disagreement the tie-breaker predicted, and it belongs in a new ADR rather
  than in a shell-side special case.
