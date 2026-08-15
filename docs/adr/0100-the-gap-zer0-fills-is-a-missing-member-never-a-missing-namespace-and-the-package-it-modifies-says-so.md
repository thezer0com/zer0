# ADR-0100: The gap zer0 fills is a missing member, never a missing namespace, and the package it modifies says so

- **Status:** Accepted
- **Date:** 2026-08-10
- **Lock:** `crates/zer0-core/src/ext/compat_tests.rs::a_modified_package_starts_at_zer0s_file_and_records_where_its_own_code_begins`, `crates/zer0-core/src/ext/compat_tests.rs::a_module_worker_is_re_entered_by_static_import_and_a_classic_one_by_import_scripts`, `crates/zer0-core/src/ext/compat_tests.rs::a_package_this_cannot_get_in_front_of_is_left_exactly_as_it_arrived`, `crates/zer0-core/src/ext/compat_tests.rs::a_package_claiming_a_modification_that_did_not_happen_is_not_believed`, `crates/zer0-core/src/ext/compat_tests.rs::an_entry_point_that_is_not_a_path_inside_the_package_is_refused`, `crates/zer0-core/src/ext/compat_tests.rs::an_entry_point_that_carries_javascript_becomes_a_string_rather_than_a_statement`, `crates/zer0-core/src/ext/compat_tests.rs::the_rewrite_moves_one_key_and_appends_one`, `crates/zer0-core/src/ext/compat_tests.rs::the_compatibility_file_states_no_capacity_it_cannot_back`, `crates/zer0-core/src/ext/compat_tests.rs::the_record_survives_a_restart`, `apple/Tests/Zer0ShellTests/ExtensionCompatTests.swift::ExtensionCompatTests/nothingIsInstalledOverSomethingThatAlreadyExists`, `apple/Tests/Zer0ShellTests/ExtensionCompatTests.swift::ExtensionCompatTests/nothingIsInventedBeyondWhatIsListed`, `apple/Tests/Zer0ShellTests/ExtensionCompatTests.swift::ExtensionCompatTests/anEnumIsItsValueAndCarriesEveryMemberChromeDocuments`, `apple/Tests/Zer0ShellTests/ExtensionCompatTests.swift::ExtensionCompatTests/anEventObjectRegistersAndSaysOnlyThatItRegistered`, `apple/Tests/Zer0ShellTests/ExtensionCompatTests.swift::ExtensionCompatTests/managedStorageIsEmptyAndRefusesToBeWrittenTo`, `apple/Tests/Zer0ShellTests/ExtensionCompatTests.swift::ExtensionCompatTests/aWithheldNamespaceIsNotHandedBackByTheCompatibilityFile`, `apple/Tests/Zer0ShellTests/ExtensionCompatTests.swift::ExtensionCompatTests/aModifiedPackageSaysSoAndNamesBothHalves`

## Context

ADR-0020 refused a `chrome.*` polyfill, and the argument was sound: what
`WKWebExtension` implements is Apple's to widen, reimplementing a namespace is
a treadmill, and every gap we filled would be ours to keep filling. ADR-0077
tested the obvious escape and refused that too — a stub whose methods report
success is a silent failure, strictly worse than the loud one it replaced.

Both of those are about **namespaces**. This is about something else, and the
difference is measured rather than argued.

Fifty-nine packages from the store were loaded into a real
`WKWebExtensionController` on macOS 26.6, with every permission granted, and
their background workers watched. **Fourteen never start.** Of those fourteen,
**six die on one member missing from a namespace that is present and otherwise
complete**:

| Package | What it touched | What it got |
| --- | --- | --- |
| React Developer Tools 7.0.1 | `chrome.scripting.ExecutionWorld.ISOLATED` | `TypeError: undefined is not an object` |
| Vimium 2.4.2 | `chrome.webNavigation.onHistoryStateUpdated.addListener` | the same |
| DuckDuckGo | `webRequest.OnHeadersReceivedOptions.EXTRA_HEADERS` | the same |
| LanguageTool | `chrome.storage.managed` | the same |
| Checker Plus for Gmail | `chrome.storage.managed` | the same |
| Privacy Badger 2026.8.7 | `chrome.scripting.ExecutionWorld.MAIN` | worker survives, the feature is dead |

`chrome.scripting` in React Developer Tools' context is present and has every
method it should. What it does not have is an object holding two strings. That
is not a namespace anyone would reimplement — it *is* its value, there is
nothing behind it to get wrong, and its absence costs the whole extension.

Three more — 1Password, Redux DevTools, Violentmonkey — die on
`notifications.onClicked.addListener` at the top level of their worker. MV3
requires listeners to be registered synchronously during startup, so an event
object that merely **exists** revives them; nothing has to fire, and nothing
does.

Counted across the corpus, the members most often absent are `storage.managed`
(12 packages), `tabs.executeScript` (11), `runtime.getContexts` (10),
`action.getUserSettings` (7), `runtime.OnInstalledReason` (6),
`i18n.detectLanguage` (5), `runtime.ContextType` (5),
`scripting.ExecutionWorld` (4) and `tabs.move` (4). Roughly half of that list
is a literal or an event object.

One instrument note, because it cost time: **`Object.keys(chrome)` is useless
here.** `chrome.scripting` reports zero keys and exists. Every member-level
claim above is a `typeof` per name.

## Decision

**zer0 writes one compatibility file into a package it installs, and that file
may contain three things and nothing else.**

### The three tiers, and why each one cannot lie

1. **Enums and constants whose value Chrome documents as a literal.**
   `scripting.ExecutionWorld`, `runtime.OnInstalledReason`,
   `runtime.ContextType`, the whole `webRequest.On*Options` family,
   `declarativeNetRequest.ResourceType` and the two ruleset ids. There is
   nothing to implement — the enum is its value — so there is nothing that can
   be claimed and not delivered. The table covers what the corpus was measured
   to touch **plus the rest of each family it lands in**: an extension reaching
   for `OnBeforeRequestOptions` fails identically to one reaching for
   `OnHeadersReceivedOptions`, and filling in eight of nine would be waiting to
   be bitten by the ninth for no saving at all.

2. **Event objects that only need to exist.** `addListener` registers and the
   event never fires. That is truthful in the way ADR-0018 means: it never
   claims the event happened. `hasListener` answers about registration, which
   is a fact.

3. **`chrome.storage.managed`, permanently empty and read-only.** Managed
   storage holds what an enterprise policy put there. zer0 has no mechanism by
   which a policy could put anything there, so it is empty — not
   "unimplemented", *empty*, and that is the correct answer rather than a
   stand-in for one. Writing to it rejects, which is what Chrome does too.

### And two rules that hold the whole thing up

**Nothing is installed over something that exists.** Every write is guarded on
the member being `undefined`. The day WebKit ships one of these, the real one
wins and this file goes quiet without anybody re-measuring it. Unguarded, a
working API would be shadowed by a plausible enum and an event that never fires
— a silent failure, which ADR-0077 established is the one outcome worse than
the loud one this replaces.

**Nothing is invented.** A member the file does not list stays `undefined`.
This is deliberate and it is the opposite of the obvious design. A stub
function that throws when called reads as friendlier and gives a better error
message — and it would defeat `if (chrome.notifications.create)`, which is the
extension's own way of finding out and taking another path, while asserting
that a method exists which does not. Leaving it `undefined` keeps that check
honest, and a call still fails loudly, at the call site, rather than at
startup. `chrome.notifications` is the one namespace created rather than added
to, because three packages need `onClicked` to exist during startup; what is
created carries three event objects and no methods at all.

**Capacity numbers are excluded**, and this is the sharpest line in the file.
`MAX_NUMBER_OF_DYNAMIC_RULES` is a claim about what *this* engine will accept.
Chrome's number is evidence about Chrome. Identifiers — `DYNAMIC_RULESET_ID` is
the string `_dynamic` — are not capacities and are stated. So are none of the
"type" names a source scan turns up: `chrome.tabs.Tab` is documentation and is
`undefined` in Chrome too.

### It has to happen on disk, and there is no second option

Measured, for reaching a background worker:

| Route | Worker | Extension pages | Content script |
| --- | --- | --- | --- |
| `Configuration.webViewConfiguration.userContentController` + `WKUserScript` | **does not reach** | reaches | no |
| `WKWebExtensionContext.unsupportedAPIs` | removes only | removes only | — |
| rewriting `background` in `manifest.json` at unpack | **reaches** | reaches | reaches |

So `ext::compat::inject` runs inside `install_extension`, in the staging
directory, before the swap — which means a package that could not be modified
leaves nothing behind and leaves any working version where it was, the
guarantee unpacking already had (ADR-0022).

**A module worker cannot be re-entered with `import()`.** The first version of
this did exactly that, and it was wrong in the most expensive way available:
measured on macOS 26.6, a module service worker reaching `await import()`
throws *"Dynamic-import is not available in Worklets or ServiceWorkers"*. The
worker then came up **clean** — no `backgroundContentFailedToLoad`, nothing in
`context.errors` — with the extension's own code never having run at all. It
was caught only by wrapping the hand-over and shipping the outcome out over
native messaging, because the instrument everything else uses cannot tell "the
extension started" from "our file ran and theirs did not".

The shipping shape, therefore:

| Background | Entry | Re-entry |
| --- | --- | --- |
| `service_worker`, classic | `zer0-compat.js` = the file + `importScripts("<original>")` | one file |
| `service_worker`, `type: module` | `zer0-compat.js` = `import "./zer0-compat-api.js"; import "./<original>";` | two files, because a module's own body runs *after* everything it imports |
| MV2 `background.scripts` | `zer0-compat.js` prepended to the list | one file |
| `background.page`, or none | untouched | — |

The module form is also strictly better than the `await` it replaced: nothing
is deferred past the startup turn MV3 requires listeners to be registered in.

### Somebody else's package, so the modification is bounded, named and stated

The unpacked tree stops being a copy of the archive, which ADR-0022 and
ADR-0024 both care about. Four things answer that:

- **One file, or two, under names no extension would choose.** A package
  already shipping either name is left completely alone rather than
  overwritten — refusing beats repairing, and overwriting somebody's file to
  install a compatibility layer becomes a bug report about them.
- **The rewrite moves one key and appends one.** `serde_json`'s
  `preserve_order` is switched on for this: without it every key comes back
  sorted, and a person diffing against the store's copy sees the whole file
  move instead of the two lines that changed.
- **The record is in the file it describes.** `manifest.json` gains
  `zer0_compat`, naming what was added and where the extension's own code still
  begins. It is only *believed* when the manifest's `background` really does
  start at the file it names — anybody can write that key into their own
  package, and printing it back unchecked would be this browser making a claim
  about its own conduct on the say-so of the thing being described (ADR-0024).
- **The Extensions screen prints it**, under the version and above the status:
  *"zer0 changed this package: it added zer0-compat.js, which runs before the
  extension's own build/background.js."* `CompatNotice` carries the fact and
  the names in one record, so no surface can draw "this was modified" without
  being handed what to say.

**What is deliberately not kept is the verified CRX.** The suggestion was to
hold the archive beside the unpacked tree so the two could be compared. That is
361 MB for AdBlock alone, for a comparison nothing performs and nobody is
offered. What makes this auditable is that the modification is small enough to
read: two files with fixed names and a manifest that says what it replaced. A
blob nobody diffs buys the feeling of an audit trail, not one.

### Measured, before and after

Real packages, pulled through this browser's own `install_extension` and loaded
into a real `WKWebExtensionController` with every permission granted. "starts"
means WebKit reported no `backgroundContentFailedToLoad` **and** a witness
placed after the hand-over confirmed the extension's own code ran.

| Package | Before | After | Why |
| --- | --- | --- | --- |
| React Developer Tools 7.0.1 | dies | **starts** | `scripting.ExecutionWorld` |
| Vimium 2.4.2 | dies | **starts** | `webNavigation.onHistoryStateUpdated` |
| DuckDuckGo | dies | **starts** | `webRequest.OnHeadersReceivedOptions` |
| LanguageTool 11.2.1 | dies | **starts** | `storage.managed` |
| 1Password 8.12.30.21 | dies | **starts** | `notifications.onClicked` |
| Redux DevTools | dies | **starts** | `notifications.onClicked` |
| Privacy Badger 2026.8.7 | starts | starts | worker was never the problem; `scripting.ExecutionWorld.MAIN` threw from a handler and its injection is what this fixes |
| Violentmonkey | dies | dies | `permissions.contains('webRequestBlocking')` — WebKit refuses the name |
| Stylus | dies | dies | the same |
| Checker Plus for Gmail | dies | dies | a resource missing from its own package |
| Clear Cache | dies | dies | `offscreen.Reason`, and an offscreen document has to exist |
| Phantom | dies | dies | `identity.getRedirectURL` |
| Proton Pass | dies | dies | throws with nothing said |
| Todoist | dies | dies | `declarativeNetRequest.updateSessionRules` refuses its rules |
| Bitwarden | dies | dies | reads its own User-Agent; the probe is not this browser |

**Six that never started now start**, and each was confirmed to have re-entered
the extension's own code rather than merely stopped throwing. The eight that
remain dead all need something to *do* something, which is the line this file
does not cross.

The witness is not decoration. An earlier build of this reported **nine**
starting — Clear Cache, Phantom, Todoist and Proton Pass among them — and all
four of those were workers that came up healthy having never run a line of the
extension. That build used `await import()`.

## Consequences

**What hurts:**

- **This browser modifies other people's software.** However well it is
  recorded, an extension's author did not write `zer0-compat.js` and cannot
  reproduce a bug report taken against it. The line on the Extensions screen is
  what a person needs; it is not what a maintainer needs, and nothing here
  produces the latter.
- **The list is a snapshot and it dates**, exactly like `ENGINE_PROVIDES` in
  ADR-0084 — with the same absence of anything going red when it stops being
  true. What is different here is the direction of the failure: a member WebKit
  implements is one this file stops writing, silently and correctly, because
  every write is guarded.
- **An extension installed before this shipped does not get it.** Injection
  happens at install, which is also upgrade, and nothing rewrites a package
  already on disk. Re-adding it is the fix and nothing says so.
- **The `manifest.json` on disk is no longer the one in the archive.** A future
  signature check has to be run against the archive, not against the tree, and
  whoever writes it has to know that. This file is where they find out.
- **A module worker gets two files**, which makes "one added file" untrue and
  made `CompatNotice` carry a list. The sentence on screen counts, so a person
  never has to know why.
- **Event objects that never fire are a new shape of not-working.** Vimium's
  worker now starts, and its `onHistoryStateUpdated` handler never runs. That
  is better than dead and it is not working, and the Extensions screen has no
  vocabulary for the difference.
- **Content scripts and extension pages are not covered.** Rewriting
  `content_scripts` would reach them and was not done: it would put our code
  into every page an extension touches, which is a far larger modification for
  no measured return in any of the named cases.

**What we get:**

- Nine packages whose background never started now start, for a table of
  literals and a handful of empty event objects.
- The one design that was available and dishonest — methods that resolve
  without doing anything — is refused, in a file whose shape makes it awkward
  to add one.
- The modification is visible in three places a person can reach: the file
  itself, the manifest that names it, and the row on the Extensions screen.

## How this regresses

**"It says zer0 cannot provide this, and my extension uses it."** Somebody
reads this file as licence to add a namespace, and `chrome.notifications`
acquires a `create` that resolves. Nothing is shown, the extension believes
otherwise, and the failure is undiagnosable — which is precisely the thing
ADR-0077 measured and refused. `nothingIsInventedBeyondWhatIsListed` is the
fence and it names `create` explicitly.

**"This extension worked and now it does nothing."** WebKit ships
`chrome.scripting.ExecutionWorld`, the guard in `define` has been dropped as
redundant, and our permanently-empty stand-in shadows the working one. There is
no error anywhere; the feature is simply gone.
`nothingIsInstalledOverSomethingThatAlreadyExists` is the lock and it is worth
breaking on purpose — delete the `if (namespace[member] !== undefined) return;`
line and it goes red on every expectation at once.

**"The extension loads and does nothing at all."** The re-entry stopped
reaching the extension's own code. This has already happened once, with
`await import()`, and it is invisible from every instrument the project has:
the worker reports healthy.
`a_module_worker_is_re_entered_by_static_import_and_a_classic_one_by_import_scripts`
holds both spellings and the order of the two imports, and its doc comment
carries the measurement so the next person does not re-derive it by shipping
it.

**"Something rewrote my manifest."** The rewrite grew — a key normalised, the
file reformatted, a second thing "while we are in there".
`the_rewrite_moves_one_key_and_appends_one` compares the key list before and
after, in order, and it is the only thing keeping the modification small enough
to read.

**"zer0 says it changed a package it never touched."** A package ships its own
`zer0_compat` key. `a_package_claiming_a_modification_that_did_not_happen_is_not_believed`
is the lock, and the guard it defends is one line in `manifest::parse`.

**"Somebody else's JavaScript ran before every extension I installed."** The
entry point is a string out of a hostile manifest that becomes a module
specifier.
`an_entry_point_that_carries_javascript_becomes_a_string_rather_than_a_statement`
puts a quote *and* a newline in one and asserts the re-entry is a single line;
`an_entry_point_that_is_not_a_path_inside_the_package_is_refused` covers `..`,
absolute paths and schemes, and refusing means installed untouched rather than
installed with a specifier nobody vetted.

**And the one no test catches:** the file grows a fourth tier. Nothing in the
build refuses a method that resolves; only the three-tier rule at the top of
`compat.js` does, and rules are wishes (AGENTS.md). The nearest thing to a
structural guarantee here is that the file has no plausible place to put one —
`ENUMS`, `CONSTANTS` and `EVENTS` are data, and adding behaviour means adding a
fourth table that a reviewer can see.

## When to revisit

- **On every macOS release**, with the same harness ADR-0084 names. Each member
  WebKit implements is one this file should stop writing — and it already does,
  silently, so the reason to re-measure is to *delete* entries rather than to
  fix a defect.
- **When a package in the corpus stops needing it.** Nine of fourteen is where
  this landed; the other five die on things that would have to *do* something
  (`identity.getRedirectURL`, an `offscreen` document, a native host that
  refuses to speak to an unknown browser). Each of those is its own decision
  with its own cost, and none is served by widening this file.
- **If signature verification lands.** The tree no longer matches the archive,
  so the check has to be against the CRX and before injection, and the question
  of whether to keep the archive reopens with an actual reader for it.
- **If an extension is reported behaving worse than dead** — a worker that
  starts and then does the wrong thing because an event it registered never
  fires. That is the one failure mode this trades for, and the answer would be
  to drop the event object rather than to add delivery.
- **When a Linux host is attempted.** The three tiers are a statement about what
  Apple's extension engine leaves out. A host embedding a different one needs
  its own measurement, and possibly no compatibility file at all.
