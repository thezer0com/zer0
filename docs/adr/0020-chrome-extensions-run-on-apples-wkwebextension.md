# ADR-0020: Chrome extensions run on Apple's `WKWebExtension`

- **Status:** Accepted, and partly superseded by ADR-0100 — extensions still run
  on `WKWebExtension` and no namespace is reimplemented, but "no `chrome.*`
  polyfill of our own" is no longer true of a **member** missing from a
  namespace that exists
- **Date:** 2026-03-05
- **Lock:** `apple/Tests/Zer0ShellTests/ExtensionTests.swift::ExtensionHostTests/extensionLoads`, `apple/Tests/Zer0ShellTests/ExtensionTests.swift::ExtensionHostTests/webViewsJoinTheController`, `apple/Tests/Zer0ShellTests/ExtensionTests.swift::ExtensionHostTests/permissionsAreGranted`, `apple/Tests/Zer0ShellTests/ExtensionTests.swift::ExtensionTabTests/tabReflectsCoreState`, `apple/Tests/Zer0ShellTests/ExtensionTests.swift::ExtensionTabTests/closingFromAnExtensionUsesTheSamePath`

## Context

A browser with no extensions is a demo. Whatever else `zer0` gets right, someone
arriving from Chrome or Arc expects their blocker, their password manager and
their two utilities to keep working, and the answer "we have our own extension
system" is the answer nobody wants.

There were two ways to have them.

**Write our own.** Parse the manifest ourselves, implement the `chrome.*`
namespaces on top of `WKUserScript` and message handlers, and grow the surface
one API at a time as extensions break. This is months of work before the first
extension loads, it is permanently behind, and every gap is a bug report we own.

**Use `WKWebExtension`.** Public API since macOS 15.4 / iOS 18.4 — the version
floor in `apple/Package.swift` is `.macOS("15.4")` for exactly this reason. It
loads Manifest V2 and V3 and it was built by Apple for third-party browsers,
not just for Safari. It is also the only path where an extension's view of the
browser is maintained by the same people who maintain the engine.

The catch is not subtle and it is the reason this ADR exists.

## Decision

Extensions run on `WKWebExtension`. There is no reimplementation, no shim layer
that "fills the gaps", and no `chrome.*` polyfill of our own.

`apple/Sources/Zer0Shell/ExtensionHost.swift` holds the whole of it:

- one `WKWebExtensionController`, attached to every web view's configuration
  before it loads anything (`attach(to:)`). A page outside the controller is a
  page no content script ever reaches;
- `ExtensionTab` implements `WKWebExtensionTab`, and every answer it gives is
  read from the Rust snapshot rather than from state kept on the Swift side, so
  an extension and the sidebar cannot disagree about what is open;
- every request an extension makes — close, navigate, pin, mute, activate —
  goes back through `model.send(...)` into the reducer. An extension takes the
  same path a click in the sidebar takes, so it cannot reach a state the
  interface could not.

### And the limit is said out loud, in the product

This is the part that is a product decision rather than a technical one.

`WKWebExtension` covers a large part of the Chrome API surface and not all of
it. Blockers and utilities run. Anything leaning on `chrome.debugger` or the
devtools APIs does not, and the set of what is missing is Apple's to define and
is not enumerated anywhere we control.

So the product never says "Chrome extensions work". It says what is true, in
the two places a person meets the feature:

- `ExtensionsView` header: *"Chrome extensions run on WebKit's implementation,
  which covers a large part of the API surface but not all of it. Some will not
  work."*
- `InstallBanner` detail line: *"You will be asked what it may do. Runs on
  WebKit; some extensions will not work."* — the first sentence arrived with
  ADR-0028; the second is this decision's, and it is the one that must not be
  softened.

Promising full compatibility would be a promise that cannot be kept by anyone
here, because keeping it is not within our reach. Setting the expectation
before the install is the only honest place to set it — after the install, the
person has already decided we are broken.

## Consequences

**What hurts:**

- **Coverage is a subset, and it is not our subset.** When an extension does not
  work, there is nothing to fix. We cannot ship the missing API, we cannot
  estimate when Apple will, and "file a radar" is not an answer a user accepts.
  Every one of those is a support conversation that ends with no.
- **The failure is silent inside the extension.** A missing API does not raise
  anything the browser can see. The extension loads, its icon appears, and the
  one feature the person installed it for quietly does nothing. From the outside
  that reads as *our* bug.
- **Permissions were granted wholesale, and now are not.** `load(_:)` used to
  call `setPermissionStatus(.grantedExplicitly, ...)` for every API permission
  and every host pattern in the manifest, with a comment admitting a consent
  prompt belonged there. It does not any more: `load(_:granting:)` takes a
  decision and grants what is in it. **ADR-0028** is that decision and carries
  its own consequences; what remains true here is that the permission model is
  WebKit's, so what can be granted, and how finely, is not ours to widen.
- **A host pattern WebKit cannot parse is still WebKit's call.** It is no longer
  dropped in silence — `apply` reports every pattern the engine refused and the
  record is corrected — but the browser cannot make such a pattern work, and an
  extension whose manifest contains one runs with less site access than it asked
  for. See ADR-0028 for what is said about it and where.
- **Extensions only see the active space.** `tabs(for:)` filters to
  `model.snapshot.activeSpace`, because tabs in other spaces are in other cookie
  jars (ADR-0007). Correct, and it means `chrome.tabs.query` under-reports
  against what the sidebar shows. A tab-manager extension will look broken.
- **Reparenting from an extension is a deliberate no-op.**
  `setParentTab(_:for:)` neither works nor throws. Accepting it silently is bad;
  throwing breaks callers that set it as a hint. We picked the least-bad of
  three bad options and it is still a lie of affordance.
- **This is the Apple host only.** `WKWebExtension` has no equivalent in
  `webkit2gtk`. A Linux host either does the reimplementation this ADR refused,
  or ships without extensions.

**What we get:**

- Extensions on day one instead of in a year, and maintained by the people who
  maintain the engine.
- No second source of truth: an extension's view of tabs is the reducer's view
  of tabs, by construction rather than by synchronisation.
- Nothing in the core knows extensions exist. `crates/zer0-core/src/ext/` deals
  in bytes, directories and manifests; `WKWebExtension` is named only in the
  shell.

## How this regresses

**"My extension used to work and now it does nothing."** The controller stopped
being attached to new web views — a refactor of the `WKWebViewConfiguration`
path, or a view built somewhere that skips `EngineHost.configureExtensions`.
Content scripts stop running and there is no error anywhere: the page is simply
outside the controller's world. `webViewsJoinTheController` is the test that
goes red, and it is the cheapest one in this file.

**"The extension's popup shows tabs I closed ten minutes ago."** Somebody caches
tab state on the Swift side "to avoid hitting the snapshot", and the cache goes
stale. `tabReflectsCoreState` catches exactly this: it drives the reducer and
asserts the adapter reports the new title and URL.

**"Closing a tab from the extension left a ghost in the sidebar."** An adapter
method starts mutating Swift state instead of dispatching an action.
`closingFromAnExtensionUsesTheSamePath` asserts both that the tab count drops
*and* that the web view went with it.

**"The extension says it has no permissions."** Something approved fails to
reach the context: `apply` stops being called on a path that loads, or a
granted key is dropped between the ledger and `setPermissionStatus`. The API
does not error — it silently does nothing, which is the hardest kind of
extension bug to diagnose. `permissionsAreGranted` and
`hostPermissionsAreGranted` hold that line. Note what they no longer say: that
the *manifest* was granted. What the manifest asked for and what the extension
holds stopped being the same thing in ADR-0028, and the tests that guard the
gap between them live there.

**And the one no test can catch:** the marketing sentence changing from "some
will not work" to "Chrome extensions work". Nothing goes red, the screenshot
looks better, and every incompatible extension from then on is a person who was
told otherwise. The wording in `ExtensionsView.header` and
`InstallBanner.detail` is a decision, not copy, and it is not covered — see
ADR-0018 for why that class of regression is the expensive one.

## When to revisit

- If `WKWebExtension` falls far enough behind that the main blockers stop
  loading. That is the same trigger as ADR-0001 and it would reopen the engine
  choice, not just this one.
- ~~When a consent prompt is built.~~ Built: **ADR-0028**. It changed what
  "installed" means, exactly as this line expected — an extension can now be on
  disk, decided about, and deliberately not running.
- When a Linux host is attempted. There is no `WKWebExtension` there, and the
  decision that was easy on Apple is the hardest single item in that port.
- If Apple publishes a machine-readable statement of what is implemented. Then
  "some will not work" can become a real answer per extension, at install time,
  which is strictly better than a warning that applies to everything equally.
