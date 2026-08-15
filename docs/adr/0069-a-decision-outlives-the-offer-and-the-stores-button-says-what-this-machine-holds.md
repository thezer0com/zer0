# ADR-0069: A decision outlives the offer that led to it, and the store's button says what this machine holds

- **Status:** Accepted
- **Date:** 2026-07-30
- **Lock:** `apple/Tests/Zer0ShellTests/StoreInstallTests.swift::StoreInstallRequestTests/anInstallStartedFromThePageSurvivesTheOfferDisappearing`, `apple/Tests/Zer0ShellTests/StoreInstallTests.swift::StoreInstallRequestTests/aFlowInProgressKeepsTheBannerMounted`, `apple/Tests/Zer0ShellTests/StoreInstallTests.swift::StoreInstallButtonStateTests/theButtonSaysWhatThisMachineHolds`, `apple/Tests/Zer0ShellTests/StoreInstallTests.swift::StoreInstallButtonStateTests/refusalIsAnOutcomeAndNotAFailure`, `apple/Tests/Zer0ShellTests/StoreInstallTests.swift::StoreInstallButtonStateTests/everyOutcomeHasALabel`, `apple/Tests/Zer0ShellTests/StoreInstallTests.swift::StoreInstallButtonStateTests/aPressMeansWhatTheBrowserHolds`, `crates/zer0-core/src/extension_permissions_tests.rs::installed_and_never_asked_is_a_state_of_its_own`, `crates/zer0-core/src/extension_permissions_tests.rs::granting_nothing_is_a_decision_and_not_an_absent_one`, `crates/zer0-core/src/extension_permissions_tests.rs::holding_more_than_was_asked_about_never_reports_a_count_it_cannot_justify`, `crates/zer0-core/src/extension_permissions_tests.rs::no_two_permissions_are_described_by_the_same_sentence`, `crates/zer0-core/src/ext/i18n.rs::a_name_that_is_a_placeholder_becomes_the_real_name`, `crates/zer0-core/src/ext/i18n.rs::a_malformed_locale_falls_back_instead_of_throwing`, `crates/zer0-core/src/ext/i18n.rs::a_message_that_refers_to_itself_expands_once_and_stops`, `crates/zer0-core/src/ext/i18n.rs::a_locale_that_is_a_path_is_never_followed`, `crates/zer0-core/src/ext/ext_tests.rs::an_extension_that_names_itself_in_locales_installs_under_its_real_name`, `crates/zer0-core/src/ext/ext_tests.rs::a_package_whose_name_resolves_to_nothing_is_refused`

## Context

ADR-0062 put a working install button into the store's own page. Measured on the
real 1Password listing, pressing it did this:

- the extension downloaded, unpacked and landed on disk;
- the consent sheet never appeared;
- Settings showed the row, correctly, as **"Not running. You have not said what
  it may do yet."** with a *Review…* button;
- the button in the page stayed on **"Adding…"** for as long as the page was
  open.

Every part of that is one bug. `InstallBanner` owned the install: the `@State`
phase, the `PendingConsent`, and the `.sheet` that presented
`ExtensionConsentSheet`. And `InstallBanner` is mounted from
`offeredExtensionId`, which is *the listing, and not already installed*.

So the offer stops existing exactly halfway through the thing it started.
`installExtension` updates `installedExtensions`; `offeredExtensionId` goes
`nil`; the banner unmounts; the state and the sheet go with it. The download had
already succeeded, so the package stayed. **The install completed and the
decision was thrown away**, and the only surface that said so was a settings
pane nobody had a reason to open.

The same hole was in the banner's own Add button, for the same reason and by the
same line of code. It was never two bugs.

Two smaller things were on the same screens.

**An extension's name was whatever the manifest literally said.** Most of the
store writes `"name": "__MSG_extName__"` and keeps the real string in
`_locales/<locale>/messages.json`. So the Settings row read `__MSG_extName__`,
and so — worse — did the consent sheet. A permission prompt that cannot name
what is asking is a prompt nobody can answer.

**Two permissions shared one sentence.** `storage` and `unlimitedStorage` both
read *"Store its own settings on this Mac"*, so a manifest declaring both drew
the identical row twice with a switch beside each. On a consent sheet that reads
as a rendering fault, and a rendering fault is a reason to stop trusting the
sheet.

And once the button could be trusted at all, it was still wrong in the other
direction: it said **"Add to zer0"** on a listing for something installed
yesterday. That is the page lying about the state of your own browser.

## Decision

Three parts, and they are one decision because they are one screen.

### A flow lives in the browser, not in the thing that offered it

`BrowserModel.extensionFlow` holds an install or a review from the press that
started it to the decision that ends it, and `BrowserView` presents the consent
sheet. `InstallBanner` draws; it decides nothing and holds nothing.

This is `AGENTS.md`'s structural rule applied to a lifetime. Saying "do not
unmount the banner mid-install" would be a wish. Moving the state to something
whose lifetime is the window is a guarantee, and it is why the banner now has no
`@State` at all: there is nothing left in it for an unmount to take.

`pendingStoreInstall` / `takeStoreInstall` went with it. They existed so the
page's press could be handed to a view that would carry it out, and once the
model carries it out, a hand-off to a view is exactly the indirection that
caused this. `StoreInstallHost` calls `model.beginExtensionFlow(id:from:)`, and
so does the banner's Add. One function; still no second install path, and still
no path that reaches an extension without the sheet (ADR-0028).

**This supersedes ADR-0062's mechanism and not its decision.** The property that
ADR still names — *the button in the page must never post a message nothing
carries out* — is now held by
`anInstallStartedFromThePageSurvivesTheOfferDisappearing` and
`aFlowInProgressKeepsTheBannerMounted`, and its `Lock:` line was moved to them.

### The button says what this machine holds

`extension_standing` in the core answers one question — is it here, was it
decided, is it running, holding how much of what it asked for — and the row in
Settings, the banner and the injected button all read it. It used to be counted
in Swift, in `ExtensionsView`, which was fine while one screen asked. Three
screens asking is three chances to disagree about what "running" means, and the
copy that would be wrong is always the one on screen.

The button's states, and what each one is:

| Standing | Button | |
| --- | --- | --- |
| not installed | *Add to zer0* | |
| installed, undecided | *Finish setting up* | leads to the sheet |
| installed, decided | *Remove from zer0* | either way it was decided |
| — | *Adding…* / *Removing…* | in flight, disabled |
| just decided, holding something | *Added to zer0* | disabled |
| just decided, holding nothing | *Added, not running* | disabled |
| the download failed | *Could not add* | pressing retries |

Two kinds of state, and the split is the design. **What the machine holds** is
read when the page loads. **What you just did** is shown afterwards and is
*disabled*, because the pointer is still over the button and a second click
landing on "Remove" would undo the first. The confirmation is worth one state;
it is not worth a timer, and it is gone by the next page load, when the button
goes back to reflecting the machine.

*Added, not running* is the brief's "refused", and it is a state of its own
rather than a spelling of `failed`. Refusing everything installs the extension
and leaves it holding nothing — all of which somebody chose. Reporting a
decision as an error tells them their answer did not work.

**The page reports a press and never what it was showing.** The message is
`press`, not `install`, and what a press *does* is read from
`model.standing(of:)` against the id the core parsed out of the frame's URL.
That is ADR-0062's rule extended by one step: the page could already not name
the extension, and now it cannot claim one is or is not present either.

**Removing asks first.** It takes everything the extension stored with it and
there is no undo, and this project's rule is that a destructive state warns
before rather than after. `DestructiveButton` is that rule for a button in one
of our windows; it cannot be *used* here, because the button raising the
question is drawn inside somebody else's page and a page cannot host a dialog.
So the question is model state and `BrowserView` presents it, in the same
grammar — a question, a consequence, a destructive verb. `ExtensionsView`'s own
Remove, which had no confirmation at all, now uses `DestructiveButton`: one act,
one wording, wherever it is pressed. Asking also closes the only race the page
opens — the button reflects what was true at page load, so confirming means the
worst a stale press can do is raise a question about something that is not
there.

### An extension is called what it calls itself

`ext::i18n` resolves `__MSG_*__` against the package's `_locales`, at
`read_manifest` — **the one place a directory on disk becomes an
`ExtensionManifest`**, so there is no way to obtain one whose name is still a
key. The locale is merged best-last across the requested locale, its language
without the region, `default_locale`, and *its* language; so a translation
covering the name and not the description falls back per string rather than
all-or-nothing, which is Chrome's own behaviour.

`Zer0::set_ui_locale` is where the system's language crosses, once, at startup.
A parameter on every call would be a fact each caller gets a fresh chance to get
wrong.

`_locales` is hostile input like the rest of the package (ADR-0022):

- a locale is checked before it is used as a path — `default_locale` is a string
  the package wrote, and `../../..` is a string;
- `messages.json` has a ceiling of its own, because `UnpackLimits`' 64 MiB is
  right for a resource nobody parses and wrong for JSON we index;
- substitution is **one pass**, so a message reading `__MSG_extName__` expands
  once and stops. Recursion is impossible rather than guarded against.

A locale that cannot be read is a locale that is not there, and the next
candidate answers. **A name that resolves to nothing refuses the package** —
fail closed, the same treatment an unparseable `manifest.json` already gets, and
what Chrome does with the same package. A *description* that cannot be resolved
is dropped instead: it is incidental to the ask, which is the exact distinction
`AGENTS.md`'s fallback rule turns on.

Finally, `storage` and `unlimitedStorage` — and `pageCapture`/`tabCapture`, and
`contextMenus`/`menus` — got sentences of their own.

## Consequences

**What hurts:**

- **The offer and the flow are two mounting conditions, and both are load
  bearing.** `listingExtensionId ?? extensionFlow?.id`. Anyone tidying that to
  one is either back to the original bug or has a banner that never appears.
  The comment says so and a test holds it, and it still reads as redundant.
- **`ExtensionsView` runs a second install flow.** It has its own `deciding`
  state, because a settings pane is not mounted from a listing and does not have
  this problem. Both go through `installExtension` and `applyConsent`, so
  nothing can skip consent — but there are two pieces of code that sequence a
  download and a sheet, and only one of them is described here.
- **A confirmed removal is two gestures where Chrome has one**, on a control we
  put into somebody else's page. Chrome's *Remove from Chrome* also asks; ours
  asks in a native dialog over a web page, which is a seam.
- **The button's "you just did this" state is lost on reload.** Press Add,
  answer the sheet, refresh: it reads *Remove from zer0*. That is correct and it
  is still a confirmation quietly disappearing.
- **An extension whose name will not resolve cannot be uninstalled from
  Settings.** `installed_extensions` skips anything `read_manifest` refuses, so
  it has no row. That was already true of an unparseable manifest; this widens
  the door it comes through. The directory has to be deleted by hand.
- **The manifest is read twice on every install and every listing.** Once for
  the manifest, once for `default_locale`, because `manifest::parse` belongs to
  a feature another change is live in and its signature was left alone. Small,
  and it is a second parse that exists for a reason that will not survive
  review.
- **The vocabulary is checked for duplicates by reading its own source.** It is
  drift-free, which a hand-maintained list would not be, and it is a test that
  parses Rust with `strip_suffix`. Reformat the match arms and it silently finds
  nothing — which is why it asserts it found more than forty keys.
- **`menus` now says something Chrome does not.** Firefox's spelling of
  `contextMenus` gets its own row explaining that granting it changes nothing
  here. That is true and it is one more sentence to maintain against a browser
  we do not ship.

**What we get:**

- The decision is asked for where the person is, over the page they were on, and
  cannot be discarded by the offer that led to it.
- Refusing reads as refusing, everywhere, including in the page.
- No surface offers to add something this machine already has.
- The consent sheet can name what is asking.
- What "running" means has one definition, in the core, with the counting in it.

## How this regresses

**"I pressed Add and nothing happened."** The consent sheet moves back into
`InstallBanner`, because that is where the banner's other state is and it looks
tidier there. Everything works right up to the moment the download succeeds.
`anInstallStartedFromThePageSurvivesTheOfferDisappearing` reads both files and
goes red; it is the one worth breaking on purpose, because the symptom is three
layers away from the cause.

**"The button in the page does nothing."** The banner stops being mounted while
a flow is in progress — somebody tightens `BrowserView.installBanner` back to
the listing alone because the second condition looks redundant. It is not:
`aFlowInProgressKeepsTheBannerMounted` is the case where they differ.

**"It says Add to zer0 on something I already have."** Somebody caches the
button's state from the last press instead of asking the core on each page load,
or adds an outcome without a label and it falls through to the default.
`theButtonSaysWhatThisMachineHolds` and `everyOutcomeHasALabel` are the two
halves.

**"It told me the install failed and it had actually installed."** `refused` is
folded back into `failed` as a simplification — two states, one sentence, and
the sentence is a lie about somebody's own decision.
`refusalIsAnOutcomeAndNotAFailure` pins them apart.

**"A page uninstalled something."** The press starts carrying what the button
was showing, because reading it saves a lookup. `aPressMeansWhatTheBrowserHolds`
asserts the press is resolved through `model.standing(of:)`, and
`nothingButTheKindIsReadOutOfAMessage` (ADR-0062) holds the body to its kind.

**"An extension is called `__MSG_extName__` again."** Somebody adds a second way
to build an `ExtensionManifest` — a cheaper listing path that parses
`manifest.json` without going through `read_manifest`.
`an_extension_that_names_itself_in_locales_installs_under_its_real_name` is the
end-to-end one and is why the unit tests are not enough: a correct resolver
nothing calls still ships the key to the sheet.

**"Adding an extension hung the browser."** `_locales` starts being read
eagerly, or the size ceiling on `messages.json` is dropped as paranoid, or
substitution is made recursive so `__MSG_a__` can expand to `__MSG_b__`.
`a_message_that_refers_to_itself_expands_once_and_stops`,
`a_message_bundle_bigger_than_the_ceiling_is_not_read` and
`a_manifest_with_nothing_to_resolve_never_touches_the_disk` are the three.

**"It read a file outside the package."** `safe_locale` is loosened so an
unusual locale name works. `a_locale_that_is_a_path_is_never_followed` is the
fence.

**"The same sentence twice again."** A new permission is added by copying the
arm above it and editing the key.
`no_two_permissions_are_described_by_the_same_sentence` covers every arm without
anyone having to remember to add it to a list.

**And the one no test catches:** the button's disabled confirmation being
"improved" into a timed transition to *Remove from zer0*, so the person gets
both the reassurance and the steady state. It reads as strictly better, and it
is a moving target under a pointer that is already there — ADR-0046's argument
about motion that is not feedback, applied to a control instead of a curve.

## When to revisit

- **When `ExtensionsView` and the banner are worth merging.** Two flows
  sequencing a download and a sheet is the debt this change did not pay. The
  right shape is probably that `extensionFlow` is the only one and Settings
  reads it too, which means Settings and a browser window sharing a sheet — a
  bigger question than this one.
- When same-document navigation reaches the core. ADR-0062 already names this;
  it also removes the second mounting condition here and lets the button be
  re-read on a `pushState` rather than only on a load, which is the honest fix
  for the confirmation disappearing.
- If Chrome's `@@` predefined messages (`@@extension_id`, `@@ui_locale`) start
  turning up in manifest names. They are refused today, which means the package
  is refused; supporting them is a small addition and a real widening of what we
  interpret out of a hostile file.
- When an extension is refused for a name nobody can resolve. That is the signal
  the fail-closed choice is costing a real install, and the answer is probably a
  row that names the id and offers to remove it — not a name invented from the
  key.
- When a Linux host is attempted. `extension_standing` and `_locales` cross
  unchanged, because they are in the core. The button in the page does not:
  there is no `WKUserScript` there, and the confirmation over it is AppKit.
