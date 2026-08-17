# ADR-0123: The shared shell set is locked by an iOS typecheck, and the iPhone host is a real browser at one screen

- **Status:** Accepted
- **Date:** 2026-08-16
- **Lock:** `apple/scripts/typecheck-ios.sh::typecheck_shared_shell`

## Context

ADR-0121 brought iOS in as a skeleton: two files, an in-memory core, a version
label. Its revisit clause named the moment this ADR answers — "when the iOS
host grows real behaviour: an engine, a store, a place for its data to live."

Growing it exposed a gap that was structural, not incidental. The macOS
package compiles all 78 files of `Zer0Shell/`; the iOS host compiles a *set* —
the 45 files that carry no macOS-only furniture. That set is the multi-platform
promise ("a new host, not a rewrite") made concrete, and **nothing held it**.
A file could gain a macOS-only import, or a new file could land in the set's
orbit without joining it, and every existing check stayed green: `swift build`
proves the macOS half, the iOS xcodebuild proves whatever the pbxproj happens
to list, and drift between the two lists is invisible to both. This is the
shape ADR-0116 caught with the SF Symbols budget: the port bill grows one
quiet keystroke at a time.

The second decision here is what the first screen of a phone browser is. The
macOS answer — no chrome, ⌘L summons a field — is built on a chord; a phone
has no chords. And the macOS sidebar is furniture beside a 1400-point window;
a 393-point one has no room beside anything.

## Decision

**1. The shared set is locked at the gate by `apple/scripts/typecheck-ios.sh`.**
The script carries the set's file list — the anti-drift, the same role the
pbxproj's Sources phase plays for the app — and does two things a laptop can
do in seconds without a simulator: emits the `Zer0Core` module for the iOS
target, then `swiftc -typecheck`s the whole set against the iPhoneSimulator
SDK at the 18.4 floor, **Swift 6, warnings-as-errors** — the strictness the
macOS package already demands of `Zer0Shell` (its `unsafeFlags`), so "shared"
means held to the same standard on both sides. A file renamed out from under
the list, a set file that reaches for a macOS-only API, a warning the macOS
build tolerates differently: each is a red `./scripts/check.sh`, which runs
this in its Darwin block, and a red `ios` CI job, which runs it before the
xcodebuild. The list is spelled in the script rather than globbed, on
purpose: a glob cannot refuse a file that *should* be in the set and is not,
and that is exactly the drift this exists to catch.

**2. The iPhone host is the shared `BrowserModel` over the real engine, not a
demo.** `Zer0IOSApp` builds `BrowserModel()` — which opens the core on
`defaultStoragePath()`'s Application Support session, rehydrates, and saves on
`scenePhase != .active` with the shared `SaveReason.backgrounded`. The
capabilities are declared at the model's door by SDK, not by host copy:
`#if canImport(AppKit)` keeps `true/true` on macOS and spells `false/false`
for iOS (no `WKWebExtensionController`, no `printOperation`, per ADR-0118),
so the one host that ever forgets its declaration has not two places to
forget it but zero.

**3. One screen, three answers to where things go.** The command bar is
*D2-visible*: a permanent field at the top, because a field that must be
summoned on a device with no summoning chord is a field nobody can reach. It
is the same bar the macOS palette is — `openCommandBar`'s intents, the
core's `suggest` ranking, `accept` on Enter — drawn inline instead of over a
dimmed window; a phone screen is already the whole window. The tab list is
*D1's drawer*: the same groups (favorites, pinned, today) in the same order
over the same space bar the macOS sidebar draws, a column on regular widths
and an over-presented drawer on compact ones — one `TabDrawer` view for both,
because two lists of the same tabs are two lists that drift. The page is the
engine's own `WKWebView` through a `UIViewRepresentable`, keyed by tab id,
navigated by `EngineCommand` through the same `perform` the macOS host runs.

## Consequences

The set is no longer trust. Adding a file to the shared set means adding it
to the script's list in the same commit, and the failure modes all have a red
build attached: a list entry with no file, a set file that broke iOS, an app
build that disagrees with the list in ci.yml *and* check.sh rather than in
one place only.

The iPhone app now does the thing its icon claims: pages load in it, tabs
and spaces are real and persist across launches, an address typed in the
field goes somewhere. The keyboard path (⌘T/⌘L's intents) maps onto the New
Tab button and a tap in the field respectively — carried by a counter and a
`draftingNewTab` flag rather than chord detection, because intent on a phone
is where the gesture began, not what keys it held.

**What hurts:** the set now has a list, and lists go stale. The script's
refusal names the missing file rather than guessing, so staleness is a
message, not a mystery — but the third hand-edit to that list is the same
moment ADR-0121 named for the pbxproj: the paid evidence for a generator or
a manifest-driven list.

## How this regresses

**"The typecheck list is replaced with a glob for self-maintenance."** A
glob keeps itself green while the set rots: a file nobody added to the app
target compiles fine in the glob and is absent from the phone. The refusal
here is the point — the list is the set's contract, and this ADR's lock names
the function that refuses to run without it.

**"The iOS host declares `extensionRuntime: true` now that it is a real
browser."** ADR-0121's revisit clause is unmet: no extension with a service
worker has survived iOS background reclamation on hardware. The declaration
moved to the model's `#if`, which makes the lie *harder* to tell, not easier
— it is one spelling shared by both hosts, and flipping the iOS half is a
one-line diff this ADR points at.

**"The permanent field is demoted to a button that opens the macOS-style
palette."** It has been tried in other browsers and it always reads as a
smaller browser: the field is the one control a phone user is guaranteed to
need and D2 is the decision. Reversing it is a new ADR, not a refactor.

**"The drawer gets its own file copy 'just for iPhone layout'."** The copy
is where the two hosts' tab lists start to disagree about order, groups, or
what a row wears. The macOS sidebar itself stays uncompilable on iOS (its
drag-and-drop is `NSView` plumbing); `TabDrawer` is a sibling view reading
the same model, and the shared `BrowserTabFields`/`SiteBadge`/`badge(for:)`
below it are what keep the rows identical.

## When to revisit

- **When the third hand-edit to the typecheck list lands.** That is the
  generator-or-manifest moment, the same threshold ADR-0121 set for the
  pbxproj.
- **When the pbxproj's file references and the script's list can be one
  artifact.** Today they name the same 45 files for different consumers
  (Xcode links, swiftc checks); a shared manifest both read would delete a
  whole class of drift. Not built now — one consumer is enough to justify a
  list, two are what justify a format.
- **When iOS internal pages (history, downloads) get real screens.** Today
  `PageArea` refuses them by name ("Not on this phone yet") rather than
  drawing a blank web view that claims a page loaded. Each real screen
  deletes a refusal, and the honest absence is what makes an accidental
  blank visible.
- **When ADR-0121's extension measurement exists.** The capabilities `#if`
  is where the flip lands, and ADR-0118's gates turn it into behaviour the
  moment it does.
