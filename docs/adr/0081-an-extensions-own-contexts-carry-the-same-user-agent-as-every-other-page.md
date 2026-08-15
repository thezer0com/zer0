# ADR-0081: An extension's own contexts carry the same User-Agent as every other page

- **Status:** Accepted
- **Date:** 2026-08-10
- **Lock:** `apple/Tests/Zer0ShellTests/ExtensionTests.swift::ExtensionHostTests/theExtensionContextCarriesTheBrowsersUserAgent`

## Context

ADR-0008 exists because a `WKWebView` inside a third-party app produces a
User-Agent ending at `(KHTML, like Gecko)` with no browser token at all, and the
web treats that as not-a-browser. `EngineHost` sets
`applicationNameForUserAgent` on the configuration of every view it builds, and
ADR-0073 later locked what that string may and may not name.

An extension's own contexts are not views this browser builds. They are created
by `WKWebExtensionController` from its configuration, and that configuration was
`.default()`. So the background service worker's User-Agent was, measured on
macOS 26.6 / Xcode 26.6:

```
Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko)
```

No product token. The exact string ADR-0008 was written to prevent, in the one
part of the browser ADR-0008 does not reach — which is what makes this a gap in
the rule rather than a second question about it.

What it costs, proven end to end on the **untouched** store package: Bitwarden
2026.7.0 asks its own User-Agent for ` Chrome/`, ` Safari/`, ` Firefox/`,
` Edg/`, ` OPR/`, ` Vivaldi/` and ` Gecko/`, matches none of them, and throws in
`this.device.toString` while the worker is starting. MV3 makes that fatal —
ADR-0077's measurement is that a throw during module init kills the worker — so
the extension does not load, and ADR-0072's screen correctly reports *"Not
running. WebKit could not start its background page."* That sentence was true
and the cause was ours.

## Decision

**Whatever the browsing views claim, the extension contexts claim the same
thing, for the same reason, from the same constant.**

`ExtensionHost.configuration()` builds the controller's configuration and sets
`webViewConfiguration.applicationNameForUserAgent` to
`HostedWebView.safariUserAgentToken` — the value, not a copy of the reasoning
that produces it. There is no second User-Agent policy, and there is no place a
second one could be written, which is the point: ADR-0073's whole argument is
that this browser has one answer to "who are you" and gives it everywhere.

The lever is the one measured to work. `WKWebExtensionController.Configuration`
`.webViewConfiguration` reaches the background worker **and** every extension
page — popup, options, any page the extension opens — with no modification to
the package. That last part matters: the alternative routes into an extension's
context all involve rewriting somebody else's signed code, which is the thing
ADR-0077 already refused to do for `chrome.*` shims.

The read-modify-write in that function is not ceremony.
`webViewConfiguration` is declared `copy` in
`WKWebExtensionControllerConfiguration.h`, so mutating what the getter hands back
is mutating a copy, and assigning it back is the only write WebKit is obliged to
observe.

**It stays optional the whole way through, and does not resolve to a
`WKWebViewConfiguration()` of its own.** The first attempt did, and
`EnginePolicyTests/theEnginePolicyIsAppliedWhereTheOnlyConfigurationIsBuilt`
refused it by name: ADR-0074 allows exactly one file to build a configuration,
because a second builder is a browsing context that missed
`EnginePolicy.apply`. That scan is a lock catching something real, in a file
nobody expected it to reach, and it is the reason the code reads the way it
does.

### What that turned up, and is not fixed here

The extension controller's `webViewConfiguration` **does not get
`EnginePolicy.apply`**. It never has; that is not a regression from this change.
An extension's popup and options pages are therefore running on WebKit's
embedded-web-view defaults — the exact thing ADR-0074 exists to refuse — while
every page a person opens is not.

It is left alone deliberately. Applying it means either giving this file the
right to build a configuration, which ADR-0074's one-door rule forbids, or
moving the door, which is a change to ADR-0074 and needs its own argument and
its own measurement of what an extension page actually loses. Neither belongs
inside a User-Agent fix. It is written down here so the next person finds it
rather than rediscovers it.

**A space's `profile.user_agent` does not reach here.** ADR-0008 lets a space
override the UA on its own views via `customUserAgent`; an extension is not in a
space — one controller serves the whole browser — so there is nothing to
override it with and nothing was invented to fill the gap.

## Consequences

**What hurts:**

- **We now claim to be Safari in one more place, and it is a place Apple's
  Safari is not.** An extension sniffing the UA to decide what to do will be
  told "Safari", and will get WebKit-shaped behaviour from `WKWebExtension`,
  which is a *subset* of what Safari's own extension support offers. Where those
  differ, the extension has been given a reason to guess wrong — and it is a
  more specific lie than the one ADR-0008 tells a website, because a website is
  only being told about the renderer.
- **`zer0/0.1.0` is now in every extension's reach**, which is a fingerprinting
  signal handed to third-party code running with whatever permissions ADR-0028
  granted it. ADR-0008 accepted that trade for websites; this extends it to a
  population that is smaller and closer in.
- **It fixes a class of failure, not Bitwarden's class of extension.** An
  extension that sniffs for ` Chrome/` specifically still finds nothing, by
  ADR-0073, and still dies. The UA now carries *a* browser; it does not carry
  the browser everyone tests against.
- **One more thing that can silently stop being set.** The controller is built
  once, in an initialiser, and nothing about a missing UA is visible until an
  extension refuses to start — at which point ADR-0072's screen blames WebKit,
  exactly as it did here.

**What we get:**

- Bitwarden's worker starts on the package as shipped.
- One User-Agent for this browser, with no host list, no per-context variant and
  no second constant — which is the claim ADR-0073 makes, now true in a place it
  previously was not.
- One less way for ADR-0072's sentence to name the engine for something this
  browser caused, which is the same correction ADR-0077 made from the permission
  side.

## How this regresses

**"Bitwarden stopped loading and the Extensions screen blames WebKit."** The
controller goes back to `.default()`, most plausibly in a cleanup — a
three-line factory returning a configuration that looks like the default one is
exactly what gets inlined. `theExtensionContextCarriesTheBrowsersUserAgent` goes
red, and it goes red printing the token the worker failed to find.

**Both halves of that test are the test.** It reads the UA from inside a real
background worker rather than off the configuration, because a configuration is
a copy of a copy and asserting on it would prove a property was set, not that
anything reads it. And it loads a second fixture demanding `Chrome/` — a token
this browser has promised never to send — which *must* fail. Without that half,
the first `#expect` stays green against a `backgroundContentFailed` that never
returns `true`, which is the instrument error ADR-0072's own tests were built to
avoid and AGENTS.md's rule about instruments in one sentence.

**"Extensions think we are Chrome now."** Somebody fixes a stubborn extension by
appending a Chrome token here rather than in `EngineHost`, on the reasoning that
it is scoped to extensions and therefore not the thing ADR-0073 refused.
`theUserAgentNamesNoOtherBrowser` does **not** cover this — it reads a real
page's `navigator.userAgent`, and an extension context is not a page it visits.
Declared debt, and the mitigation is that there is nothing to append *to* here:
the value is read from `HostedWebView.safariUserAgentToken`, so doing it would
mean writing a second string, which is visible in review in a way that editing a
literal is not.

**The one no test catches:** the popup and options pages. They were measured to
be reached by the same property and nothing here asserts it, because the worker
is the context with an observable failure mode and they are not.

## When to revisit

- **When a WebKit release changes how extension contexts are configured**, or
  gives them their own User-Agent property. The rule crosses unchanged; the
  spelling would not.
- **If an extension breaks *because* it is told Safari.** That is the cost named
  above arriving, and it should be handled per-extension and in the open, not by
  widening the string — the same exit condition ADR-0073 sets for websites.
- **If a space's User-Agent override ever needs to reach extensions.** It cannot
  today because one controller serves every space, and the moment that stops
  being true (a per-space controller, for a per-space extension set) this
  question reopens with ADR-0007 attached to it.
- **When somebody has a reason to want `EnginePolicy` on extension pages.**
  Named above and not fixed here. The trigger is an extension page that
  misbehaves in a way the embedded-view defaults explain — no Fullscreen API,
  autoplay restrictions — and the work is a change to ADR-0074's one door, not
  a line in this file.
- **When Linux is attempted.** `webkit2gtk` has no `WKWebExtensionController`
  and this ADR's mechanism has nowhere to land; the rule — extension contexts say
  what the browser says — is the part that crosses.
