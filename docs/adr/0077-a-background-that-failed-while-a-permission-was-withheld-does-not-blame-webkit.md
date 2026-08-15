# ADR-0077: A background that failed while a permission was withheld does not blame WebKit

- **Status:** Accepted, and partly superseded by ADR-0084 — the branch still
  exists and still says what it says, but it is entered on whether anything
  withheld is something this browser could provide, rather than on `held < asked`
- **Date:** 2026-08-10
- **Lock:** `apple/Tests/Zer0ShellTests/ExtensionTests.swift::ExtensionStatusTests/aWithheldPermissionIsNamedRatherThanBlamingTheEngine`, `apple/Tests/Zer0ShellTests/ExtensionTests.swift::ExtensionHostTests/aDeniedPermissionIsEnoughToKillTheBackground`, `apple/Tests/Zer0ShellTests/ExtensionTests.swift::ExtensionStatusTests/aBrokenBackgroundIsNotCalledRunning`

## Context

ADR-0072 stopped the browser vouching for an extension WebKit never started, and
the sentence it settled on was **"Not running. WebKit could not start its
background page."** That sentence is honest about 1Password. It is not honest
about every extension it gets printed over, and the reason was not known when it
was written.

Everything below was measured on macOS 26.6 / Xcode 26.6, by loading generated
extensions into a real `WKWebExtensionController` and asking the background
service worker what exists in its own JS context, with the answer carried out
over native messaging.

**A permission that is declared and not granted does not make its API fail — it
removes the API.** With every Chrome permission declared and granted, the worker
sees seventeen `chrome.*` namespaces. With the same manifest and nothing
granted, it sees eight. `alarms`, `contextMenus`, `cookies`,
`declarativeNetRequest`, `menus`, `scripting`, `storage`, `webNavigation` and
`webRequest` are all simply `undefined` until the grant exists. Only `action`,
`dom`, `extension`, `i18n`, `permissions`, `runtime`, `tabs` and `windows` are
unconditional.

**And an absent namespace is never a feature that quietly does nothing.** It is
a `TypeError` at the point of use. Whether that kills the worker is decided by
*where* the extension touches it, not by which namespace it is:

| Background worker does | Worker survives |
| --- | --- |
| `chrome.notifications.create(…)` at top level | no |
| `chrome.notifications.onClicked.addListener(…)` at top level | no |
| `if (chrome.notifications) { … }` | yes |
| touches it inside a handler that has not fired | yes |

The second row is the one that matters, because MV3 *requires* event listeners
to be registered synchronously while the worker starts. An extension that
listens for anything in a namespace this engine lacks is dead on arrival, and
that is precisely how 1Password dies — one unguarded
`chrome.notifications.onClicked.addListener` during module init.

Put those two measurements together and the consequence is ours, not Apple's:

> `chrome.storage.local.get(…)` at top level, `storage` declared and **denied**,
> produces `WKWebExtensionContextErrorDomain` code 6 —
> `backgroundContentFailedToLoad`. The same error, indistinguishable from the
> one an unimplemented API produces.

So somebody switches off a row in our own consent sheet, the extension stops
working, and this browser tells them WebKit could not start it. That sends them
to a bug report about the engine when the fix is a toggle on the screen they are
already looking at. It is the same defect ADR-0072 was written to fix, pointed
the other way: **the browser saying something it cannot prove.**

## Decision

**When the background failed and the person withheld something, the sentence
says both and blames neither.**

`ExtensionStatus.of(standing:backgroundFailed:)` keeps its shape — the platform
fact is still read first and still only ever moves the answer downward. What is
new is one branch inside it: if the standing is `running(held, asked)` with
`held < asked`, the row reads

> Not running. Its background page failed to start, and it is holding 13 of the
> 15 things it asked for — switching one off can be enough to cause this.

Three things about that wording are deliberate.

**It does not name a cause.** What is provable here is the shape: the background
failed, and something was withheld. Which of the two facts explains the other is
not knowable from this side — WebKit reports one error for every way a worker
can fail to come up, and the withheld thing may be a host pattern that has
nothing to do with it. "Can be enough" is a general fact that was measured; "is
why" would be a guess with a sentence around it.

**It does not name WebKit.** Not because the engine is blameless, but because
naming it in the one case where this browser may have caused the failure is the
lie. Where nothing was withheld, the old sentence is untouched and still names
WebKit, because there it is the only thing left to name.

**It carries the counts.** They are the whole of what makes it actionable —
they are the same numbers the running state prints, so the row someone was
reading a moment ago is the row that now explains itself.

Nothing else moves. The button still routes a press to the Extensions screen
rather than opening a popup nothing is behind, and the tooltip still says the
short version, because the tooltip's job is to send you where the explanation
is (ADR-0072).

## Consequences

**What hurts:**

- **A third sentence for one state.** Two shapes of "not running because the
  background died" is more vocabulary than one, and the difference between them
  is a comparison a reader has to trust rather than see.
- **It is right where it is vague.** Somebody who withheld one host pattern and
  is dead on `chrome.notifications` gets a sentence pointing at their toggle,
  which is not the cause. The alternative — saying nothing — is the state we
  came from, where the browser pointed at the engine instead. Pointing at the
  thing a person can change and admitting it might not be it beats pointing at
  the thing they cannot.
- **`held < asked` counts hosts as well as permissions.** A withheld host
  pattern does not remove a namespace, so it can put a row into this branch
  without being able to explain it. Splitting the count is more core surface than
  this is worth until somebody hits it.
- **It cannot say which permission.** The core knows what was denied; matching
  that against what the worker touched would need the worker to have run, and it
  did not.

**What we get:**

- The one case where this browser causes the failure is the one case it stops
  blaming the engine for.
- The sentence names something on the same screen that a person can act on.
- The mechanism is written down and under test, so the next person who reads
  `backgroundContentFailedToLoad` knows it has two very different causes.

## How this regresses

**"Why does it say WebKit when I'm the one who switched storage off?"** The
branch is deleted or moved below the `switch`, where it reads more naturally as
a special case after the ordinary ones.
`aWithheldPermissionIsNamedRatherThanBlamingTheEngine` goes red on all three
expectations, and the first — that the summary does not contain "WebKit" — is
the one worth breaking on purpose.

**"Every broken extension now blames the person."** The `held < asked` guard is
dropped as an unnecessary detail, so a fully-granted extension that WebKit
genuinely could not start gets told it withheld something.
`aBrokenBackgroundIsNotCalledRunning` is carried over from ADR-0072 as a lock
here for exactly that: it holds `held: 15, asked: 15` and demands the old
sentence verbatim.

**And the premise, which is the part a wording test cannot reach.** All of this
rests on a denied permission really being able to kill a worker. If it cannot,
this ADR is ceremony over a state that never happens.
`aDeniedPermissionIsEnoughToKillTheBackground` loads a real extension declaring
`storage`, grants it nothing, and requires WebKit to report the failure. Grant
the same fixture everything and it goes red after the full timeout — which is
the check that it is measuring the denial and not merely that a background
exists.

**The one no test catches:** somebody reads the table above, concludes the fix
is to define the missing namespaces before the worker runs, and writes a
polyfill whose functions return success. An extension told
`chrome.notifications.create` succeeded, when nothing was shown, is a silent
failure nobody can diagnose — strictly worse than the loud one it replaced.
Measured, and the reason this ADR does not do it: an *honest* stub, whose
methods reject with "zer0 does not implement this", revives 1Password's worker
exactly as well as a lying one. Nothing is bought by the lie. That the worker
then still gets nowhere is the subject of the note below.

## When to revisit

- **When a WebKit release implements more of these.** The measurement is a
  harness, not a constant. `notifications`, `downloads`, `idle`, `management`,
  `privacy`, `offscreen`, `bookmarks`, `history`, `sessions`, `topSites`,
  `sidePanel`, `userScripts`, `proxy` and `debugger` are all absent today; each
  one that lands makes this branch fire less often without making it wrong.
- **If a denied permission stops removing the namespace.** Then a person's
  choice can no longer produce this failure, the distinction is unnecessary, and
  `aDeniedPermissionIsEnoughToKillTheBackground` is the test that says so by
  going red.
- **If zer0 ever injects API of its own into an extension's context.** The rule
  it would have to satisfy is in this file and not in a comment: a stub that
  reports success for something that did not happen is not allowed, an honest
  refusal is, and either one is a modification to somebody else's package that
  the person has to be able to see.
- **1Password specifically: do not.** Reproduced here independently of
  ADR-0072 — its worker fails on `chrome.notifications`; with that stubbed the
  worker comes up clean and then makes no native-messaging attempt at all in 45
  seconds; and its desktop helper, spoken to directly in Chrome's framing,
  answers `{"type":"BrowserVerificationFailed","content":"UnknownBrowser"}` and
  closes the stream. The allowlist and the `SecRequirement` strings are still in
  the binary. Every link measured, and the last one is not an engineering task.
