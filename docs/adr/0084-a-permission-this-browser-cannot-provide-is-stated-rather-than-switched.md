# ADR-0084: A permission this browser cannot provide is stated rather than switched

- **Status:** Accepted; its single sentence for an unprovidable permission is superseded by ADR-0103, which splits it into a gap and a refusal and takes `downloads` and `idle` out of the list entirely
- **Date:** 2026-08-10
- **Lock:** `crates/zer0-core/src/extension_permissions_tests.rs::a_permission_this_browser_cannot_provide_is_stated_rather_than_switched`, `crates/zer0-core/src/extension_permissions_tests.rs::a_permission_this_browser_cannot_provide_is_never_recorded_as_granted`, `crates/zer0-core/src/extension_permissions_tests.rs::a_permission_this_browser_does_provide_keeps_its_switch`, `crates/zer0-core/src/extension_permissions_tests.rs::site_access_is_never_marked_as_something_this_browser_cannot_provide`, `crates/zer0-core/src/extension_permissions_tests.rs::nothing_is_listed_as_working_that_the_vocabulary_has_never_heard_of`, `crates/zer0-core/src/extension_permissions_tests.rs::what_is_withheld_is_read_by_whether_a_switch_could_have_helped`, `crates/zer0-core/src/extension_permissions_tests.rs::the_permissions_real_packages_declare_all_have_a_sentence`, `apple/Tests/Zer0ShellTests/ExtensionTests.swift::ExtensionStatusTests/nothingProvidableWithheldPointsAtNoSwitch`, `apple/Tests/Zer0ShellTests/ExtensionTests.swift::ExtensionStatusTests/aWithheldPermissionIsNamedRatherThanBlamingTheEngine`, `apple/Tests/Zer0ShellTests/ExtensionTests.swift::ExtensionStatusTests/aBrokenBackgroundIsNotCalledRunning`

## Context

The Extensions screen showed 1Password holding fifteen of the seventeen things
it asked for, and the two it was not holding were labelled **"Something zer0
cannot explain"**: `offscreen` and `webRequestAuthProvider`. The status line
underneath, from ADR-0077, read *"switching one off can be enough to cause
this."*

Three separate things were wrong, and only the first is the one anybody would
guess.

**`offscreen` is a documented Chrome permission with a precise meaning**, and so
were most of the others falling to the `Unknown` arm. The policy that puts them
there — `default_granted: risk != Unknown`, *"there is no informed consent to a
sentence nobody wrote"* — is right and is untouched by this ADR. What was wrong
is that the sentence had not been written. Calling `offscreen` unexplainable is
a statement about us, and its effect was that this browser denied by default a
thing it could have described perfectly well.

**A permission WebKit does not implement was being offered as a live switch.**
Measured here on macOS 26.6, by loading a generated MV3 extension into a real
`WKWebExtensionController`, granting every permission it declares, and asking
its background service worker `typeof chrome[name]` for each: **seventeen
namespaces exist and nothing else does.** `action`, `alarms`, `contextMenus`,
`cookies`, `declarativeNetRequest`, `dom`, `extension`, `i18n`, `menus`,
`permissions`, `runtime`, `scripting`, `storage`, `tabs`, `webNavigation`,
`webRequest` and `windows`. Everything else — `bookmarks`, `browsingData`,
`contentSettings`, `debugger`, `desktopCapture`, `downloads`, `fontSettings`,
`history`, `identity`, `idle`, `management`, `notifications`, `offscreen`,
`pageCapture`, `power`, `privacy`, `proxy`, `search`, `sessions`, `sidePanel`,
`tabCapture`, `tabGroups`, `topSites`, `userScripts`, `webAuthenticationProxy` —
is `undefined` whatever is granted. Flipping their switch changed nothing at
all, which is the same lie of affordance ADR-0018 refuses when it disables
`Close Space…` rather than letting the core ignore it.

**And the status sentence blamed the wrong thing.** ADR-0077 is right that a
denied permission really does remove a namespace and really does produce the
identical `backgroundContentFailedToLoad`. But it decided on `held < asked`,
which is arithmetic, and arithmetic cannot tell the difference between a switch
that would have helped and a switch that could not. One of the two things
1Password was not holding is `offscreen`, whose namespace is absent whatever
this browser records — so at least half of what that sentence invited somebody
to go and change could not have changed anything, and the browser had no way to
know which half. It is ADR-0072's defect pointed a third way: the browser saying
something it cannot back up.

## Decision

**A permission this browser cannot provide is stated, not offered — and it is
never what a failure points at.**

### The words that were missing

`offscreen`, `sidePanel`, `userScripts` and `webRequestAuthProvider` get
descriptions in the same vocabulary as their neighbours: the consequence, in the
second person, with a risk tier. That empties the `Unknown` arm of every
permission the packages this browser installs actually declare.

### One measured list, of what works

`ENGINE_PROVIDES` names the permissions whose API this engine really installs.
**A list of what works, deliberately, and not the other way round.** A permission
nobody has measured is one this browser has no evidence about, and the
fail-closed answer to no evidence is to keep offering the switch — the inverted
list would silently mark every permission Chrome adds after today as something we
can prove is inert.

Only a permission the vocabulary already describes can be called unprovidable.
One with no arm at all keeps saying that we cannot explain it, because that is
the true statement about it, and "zer0 cannot provide this" about a key nobody
measured would be a second thing asserted without evidence.

Eleven described permissions gate something that is not a namespace —
`activeTab`, `background`, `clipboardRead`, `clipboardWrite`,
`declarativeNetRequestFeedback`, `favicon`, `geolocation`, `nativeMessaging`,
`unlimitedStorage`, `webRequestAuthProvider`, `webRequestBlocking` — so their
absence is not something this measurement can see. They keep their switch.
`webRequestAuthProvider` is the interesting one: granting it and withholding it
produce a byte-identical `chrome.webRequest`, `onAuthRequired` included, which
is evidence that it gates nothing here and is not proof of it. Marking it inert
would take away a person's ability to grant something that might work, on a
measurement of a surface rather than of a behaviour. It stays live.

### What an unprovidable permission does instead

`PermissionRequest.cannot_provide` is `Option<String>`, holding the sentence,
rather than a flag beside a string somewhere else. One field, so a row cannot be
marked inert without carrying the reason, and the shell has no way to draw the
state without printing why.

- **It arrives unticked**, and `ConsentDecision::allow` refuses it — the same
  gate, in the same function, that has always refused an unreadable host
  pattern. That is what makes the missing switch a consequence rather than a
  promise: a recorded approval that reaches nothing would be read back by every
  screen as a grant, and if the measurement above is ever wrong, this is the
  direction that withholds rather than the one that exposes.
- **It keeps its risk tier and its place in the ranking.** What the extension
  wanted is worth reading even where it cannot have it; the row says only that
  it does not get it here.
- **The consent sheet and the Permissions block draw a sentence where the switch
  was.** The same treatment as a host pattern nobody could parse, one block down
  on the same sheet, and for the reason written there: an approval the browser
  could not act on would be a lie with a control next to it.

### What a failure is allowed to point at

`ExtensionStanding::Running` carries a third field, `Withheld`, and the shell
switches over it exhaustively instead of comparing two numbers:

| `Withheld` | The row says |
| --- | --- |
| `Nothing` | *Not running. WebKit could not start its background page.* |
| `SomethingProvidable` | *Not running. Its background page failed to start, and it is holding 13 of the 15 things it asked for — switching one off can be enough to cause this.* |
| `OnlyTheUnprovidable` | *Not running. WebKit could not start its background page. It is holding 15 of the 17 things it asked for, and zer0 cannot provide what is missing — no switch here would change that.* |

The third arm names no cause. What is provable is the shape — the background
failed, and everything missing is something this browser does not implement —
and a worker has plenty of other ways to die. It names WebKit because in that
arm the engine really is the only thing left to name, which is ADR-0072's
position and the one ADR-0077 correctly withdrew for the middle row only. It
carries the counts because they are the same numbers the running state prints,
so the row somebody was reading a moment ago is the row that now explains
itself. What it drops is the invitation to go and flip something.

## Consequences

**What hurts:**

- **The measured list is a snapshot of one OS on one day, baked into the
  interface.** Every WebKit release that implements one of these turns a true
  sentence into a false one, and nothing goes red when it happens — the same
  shape of staleness ADR-0028 already declared for the vocabulary, now with a
  stronger claim attached to it. `ENGINE_PROVIDES` has to be re-measured, and
  the harness that measures it is a throwaway test rather than something that
  runs.
- **A permission that becomes providable stays denied.** `allow` refuses it
  today, so a ledger written today records a refusal, and the build that gains
  the API will let it be switched on again but will not switch it on. Somebody
  has to notice.
- **Twenty-five described permissions now arrive unticked**, where ADR-0028's
  rule was that everything describable arrives ticked so an extension does not
  install looking broken. An extension asking for six of them shows *"holding
  11 of 17"* on the day it is added, which reads as a partial install and is
  really a full one.
- **It is a strong claim in a quiet voice.** *"zer0 cannot provide this"* next to
  *"Take complete control of the browser"* is the browser telling somebody a
  Critical permission is inert. If the measurement is wrong about one of those,
  it is wrong in the most expensive place. The `allow` gate is why being wrong
  costs a withheld permission rather than an exposed one.
- **`Withheld` is a third field on a type five surfaces read**, and computing it
  needs the described request rather than a count of it — so `standing` takes a
  slice where it took a `usize`, at both call sites.

**What we get:**

- Nothing on the Extensions screen is a control that accepts a press and does
  nothing.
- The one sentence in the browser that told somebody to go and flip a switch now
  only says it where a switch exists that could change the outcome.
- A permission the engine does not implement cannot be recorded as granted, by
  any path, so no screen can be talked into reporting one.
- The `Unknown` tier is back to meaning what it says — a permission nobody has
  looked at — rather than being where eight documented Chrome APIs were parked.

## How this regresses

**"It says zer0 cannot provide this, and it works."** A WebKit release
implements one of the twenty-five and `ENGINE_PROVIDES` is not re-measured. The
row says the browser cannot do something it can, and the switch stays gone. No
test sees it; the measurement is the only thing that would.

**"Why has this extension got no switches?"** A typo in `ENGINE_PROVIDES` —
`webrequest` for `webRequest` — silently moves a permission into the inert list,
and the screen tells somebody this browser cannot do the one thing a blocker is
for. `nothing_is_listed_as_working_that_the_vocabulary_has_never_heard_of` is
the fence, and it is worth breaking on purpose: change one letter and it names
the entry.

**"It told me it could not provide it and then granted it anyway."** Somebody
adds a convenience path that writes `granted_permissions` directly, or removes
the second guard in `allow` as a duplicate of the check in `describe_api`.
`a_permission_this_browser_cannot_provide_is_never_recorded_as_granted` is what
goes red, and it is the lock that survives a refactor of the views — the missing
switch is a rendering fact and this is not.

**"Now nothing has a switch."** The inert branch is applied to the whole
vocabulary, or `cannot_provide` is set from something other than the measured
list. `a_permission_this_browser_does_provide_keeps_its_switch` and
`site_access_is_never_marked_as_something_this_browser_cannot_provide` are the
two halves of that, and without them the test above stays green over a browser
that offers nothing at all.

**"It still sends me to a toggle that does nothing."** `Withheld` is collapsed
back to `held < asked`, most plausibly by somebody who reads the two counts in
the sentence and concludes the enum is redundant with them.
`nothingProvidableWithheldPointsAtNoSwitch` goes red on the phrase, and
`aWithheldPermissionIsNamedRatherThanBlamingTheEngine` and
`aBrokenBackgroundIsNotCalledRunning` hold the other two arms so the fix cannot
be to give every row the same sentence.

**"Something zer0 cannot explain" comes back.** A permission gets its arm
deleted, or the vocabulary is trimmed as unused.
`the_permissions_real_packages_declare_all_have_a_sentence` names the ones
measured across the packages this browser installs.

**And the one no test catches**, which is the same one ADR-0028 names: the
sentence for a *new* permission never gets written. Nothing here makes anybody
write it. What is new is that the failure is now quieter — an undescribed
permission keeps its switch, so it no longer stands out as the only thing on
the sheet that arrived off.

## When to revisit

- **On every macOS release.** The list is a measurement, not a constant. The
  harness is twenty lines: a fixture declaring every permission, granted, whose
  background worker writes `typeof chrome[name]` for each into
  `chrome.action.setTitle` — which is the one channel out of a service worker
  that needs neither a native host nor a network.
- **If `chrome.declarativeNetRequest` grows methods.** It exists today and its
  static rulesets work, which is why the permission keeps its switch, but every
  method Chrome documents on it is absent. If the API stays a stub while the
  manifest key keeps working, "provided" is too coarse a word and this file
  needs a third state rather than two.
- **If `webRequestAuthProvider` turns out to gate nothing.** Measuring the
  behaviour rather than the surface — whether a listener registered for
  `onAuthRequired` is ever called — would settle it, and settle it in the
  direction of one more inert row.
- **If a person ever needs to grant one of these anyway**, to satisfy an
  extension that checks `chrome.permissions.contains` before doing something
  else. Then the ledger has to be able to hold a grant the API does not honour,
  and the sentence on the row has to change with it.
- **When a Linux host is attempted.** `ENGINE_PROVIDES` is a statement about the
  extension engine this browser embeds, not about `zer0`, and a host that
  embeds a different one needs its own measurement rather than this one.
