# ADR-0002: The core is a pure reducer and the shell decides nothing

- **Status:** Accepted
- **Date:** 2026-01-05
- **Lock:** `crates/zer0-core/src/reducer_tests.rs::opening_a_tab_creates_a_webview_and_focuses_it`, `apple/Tests/Zer0ShellTests/NavigationRoundTripTests.swift::NavigationRoundTripTests/webViewLifecycleFollowsTheCore`

## Context

A browser has two very different halves: behavior (what happens when you close a
tab, where focus goes, which command bar suggestion wins) and presentation
(color, spacing, animation, label text). If both live in the same place, testing
behavior means opening a window, and porting to another platform means
rewriting.

The declared target list includes Linux with `webkit2gtk`. If behavior lived in
Swift, that port would be a rewrite.

## Decision

The flow is unidirectional and has exactly one shape:

```
Action ──► reducer::dispatch(&mut Session, Action) ──► Vec<EngineCommand>
```

`crates/zer0-core/src/reducer.rs` is the only thing that decides. It does not
know what a `WKWebView` is: it emits `CreateWebView`, `LoadUrl`,
`DestroyWebView`, `FocusWebView`, and it is up to the host to work out what that
means on its platform. `apple/Sources/Zer0Shell/EngineHost.swift` runs the
commands in order and reports facts back as `Action` (`NavigationCommitted`,
`TitleChanged`, `NavigationFailed`). The `switch` in `EngineHost.perform` has no
`default:`.

The corollary in `CLAUDE.md` is the tie-breaker: **if two platforms can
disagree, it is appearance and stays in the shell; if they cannot, it is
behavior and goes to the core.** We have already run that rule on cases that
look borderline and are not:

- **Navigation error category is behavior.** `NavigationErrorKind` lives in the
  core; the host only translates `NSURLErrorDomain -1009` into `Offline`,
  because the number belongs to the platform and the meaning does not.
- **URL vs. search is behavior.** The shell sends the raw text in
  `NavigateTo { input }` and the core resolves it.
- **Keymap is behavior.** The core hands back the bindings; the shell only draws
  the menu.
- **Clock and randomness belong to the shell**, because the core has to be
  deterministic: `Action::Tick { now_ms }` and `CreateSpace { data_store_id }`
  exist for that.

## Consequences

This costs, and it costs in places we can name:

- **A whole snapshot is re-read on every dispatch.** `BrowserSnapshot` copies
  every space, every tab and every route, and the comment in `ffi.rs` admits it:
  "cheap enough to re-read after every dispatch (...) we do not maintain a delta
  protocol until profiling says we need one". That is O(session) per action.
  With many tabs it becomes a per-keystroke cost in the command bar.
- **Every crossing is a copy.** No references, no `&str`. Each `snapshot()`
  allocates fresh vectors, and SwiftUI diffs the result.
- **One `Mutex` serializes everything.** `Zer0` keeps state behind a mutex
  because `WKWebView` delegates can fire off the main thread. It is cheap today
  and it is a declared contention point.
- **Adding a field costs three places.** Rust, regenerating the bindings, Swift.
  A field only the UI uses still pays that toll if it has to exist in the core.
- **The shell carries responsibility without getting to decide.** It has to send
  `now_ms` on a schedule and invent `data_store_id`, chores whose policy it does
  not control. If it stops sending `Tick`, tab archiving just stops happening
  and nothing complains.
- **A new command breaks the build on purpose.** With no `default:` in the
  `switch`, a new `EngineCommand` does not compile until it earns behavior in
  the host. That is intended, and it means any protocol change is a
  two-language job, never a one-language one.

## How this regresses

The symptom is decisions leaking into the shell. Concretely: `EngineHost.swift`
or `BrowserModel.swift` starting to pick which tab to focus, which URL to load,
or what a typed string means — instead of sending an `Action` and running
whatever comes back. The cheapest signal to spot is an `if` over navigation
state inside Swift, or a `default:` showing up in a `switch` over
`EngineCommand`/`UiCommand`.

The other symptom is the mirror image: `reducer.rs` picking up a `use` of
anything from the UI, or an appearance field (color, width, label string)
landing in `model.rs`.

`opening_a_tab_creates_a_webview_and_focuses_it` screams in the first case: it
proves that opening a tab emits `CreateWebView` followed by `FocusWebView`
**with no window anywhere**. If the decision migrates to the shell, the command
vector empties and the test fails. `webViewLifecycleFollowsTheCore` screams in
the mirror: the live `WKWebView` appears and disappears following the core, not
following SwiftUI.

## When to revisit

When the profiler points at `snapshot()` as a real cost (the trigger is
measuring, not guessing) — and then the change is a delta protocol, not moving
decisions to the shell. And when the Linux host exists: if `EngineCommand` needs
a command only one of the two platforms understands, the boundary is in the
wrong place and that command is the test case.
