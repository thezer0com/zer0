# ADR-0028: An extension holds only what someone approved

- **Status:** Accepted, and partly superseded by ADR-0084 — "everything the
  browser can describe arrives ticked" now has a second exception: a permission
  this browser cannot provide arrives unticked and cannot be ticked
- **Date:** 2026-04-02
- **Lock:** `crates/zer0-core/src/extension_permissions_tests.rs::all_urls_is_described_by_what_it_costs_you_not_by_its_name`, `crates/zer0-core/src/extension_permissions_tests.rs::the_dangerous_ones_come_first`, `crates/zer0-core/src/extension_permissions_tests.rs::an_unreadable_pattern_is_never_offered_for_approval`, `crates/zer0-core/src/extension_permissions_tests.rs::an_unreadable_pattern_cannot_be_granted_even_when_asked_for_directly`, `crates/zer0-core/src/store_tests.rs::a_denied_extension_permission_stays_denied_across_a_relaunch`, `crates/zer0-core/src/store_tests.rs::an_extension_that_was_granted_nothing_is_still_a_decision_after_a_relaunch`, `apple/Tests/Zer0ShellTests/ExtensionTests.swift::ExtensionConsentTests/refusingEverythingGrantsNothing`, `apple/Tests/Zer0ShellTests/ExtensionTests.swift::ExtensionConsentTests/refusalIsExplicit`, `apple/Tests/Zer0ShellTests/ExtensionTests.swift::ExtensionConsentTests/revokingReachesTheContext`, `apple/Tests/Zer0ShellTests/ExtensionTests.swift::ExtensionConsentTests/partialGrantsRunWithWhatTheyHold`, `apple/Tests/Zer0ShellTests/ExtensionTests.swift::ExtensionConsentTests/refusalsSurviveARelaunch`, `apple/Tests/Zer0ShellTests/ExtensionTests.swift::ExtensionConsentTests/undecidedExtensionsDoNotRun`

## Context

ADR-0020 shipped extensions with a placeholder where consent belonged, and
said so in a comment: `load(_:)` walked the manifest and called
`setPermissionStatus(.grantedExplicitly, ...)` for every API permission and
every host pattern in it. Nobody was asked, nothing was written down, and there
was no screen anywhere that would tell you afterwards.

For an adblocker that manifest says `<all_urls>`. So installing one from the
Chrome Web Store handed a stranger's code the ability to read and change every
page in the browser — including a bank, including anything behind a login —
and the only way to find out was to go read a JSON file inside the package.

Two smaller things made it worse. A host pattern WebKit could not parse was
dropped silently, so an extension could run with less access than anyone
believed it had, with nothing said. And there was no record: had a prompt been
bolted onto the Swift side, its answer would have lived in
`WKWebExtensionContext`, which is rebuilt from nothing on every launch. A
consent that resets on relaunch is worse than none, because it teaches people
that the dialog does not matter.

Chrome and Firefox both ask at install time and both use the vocabulary of the
manifest ("Read and change all your data on all websites"). That is the right
moment and the wrong words: `<all_urls>` and `webRequest` are names, and a
person needs a consequence.

## Decision

**Nothing is granted that nobody approved, and the approval is written down in
the core.**

Four parts.

**The words are behaviour, so they live in the core.**
`crates/zer0-core/src/extension_permissions.rs` turns a manifest's two lists
into a `ConsentRequest`: one `PermissionRequest` per thing to say yes to,
carrying a `title` (the consequence, in the second person), a `detail` (what
that means for someone who does not know what a content script is) and a
`PermissionRisk`. `<all_urls>` reads *"Read and change everything you do on
every site"*, and its detail names a bank. What a permission costs you is not
something macOS and Linux get to disagree about, so the shell draws these and
does not write them.

**Ranking is behaviour too.** `Critical → High → Unknown → Moderate → Low`,
sites before APIs at equal risk, then alphabetical so the same manifest always
produces the same screen. Access to every site is not the same as putting
something on the clipboard, and a flat alphabetical list is exactly how the
worst item hides in the middle of the harmless ones. An unknown permission
ranks with the moderate ones rather than the bottom, because not knowing is not
the same as being harmless.

**A pattern nobody could read is never presented as approved.** The core parses
match patterns itself and refuses anything outside Chrome's grammar; those go
into `unreadable_hosts`, which the dialog lists as skipped and gives no control
to. `ConsentDecision::allow` refuses to grant them even when asked directly,
which is the last gate before the ledger. And because the engine has the final
say, `ExtensionHost.apply` returns every pattern WebKit refused and the model
calls `markExtensionPatternUnreadable`, so a grant nobody could apply stops
reading as a grant.

**The record is session state.** `Session.extension_consent` holds one
`ConsentDecision` per extension — granted, *explicitly* denied, and unreadable
— saved in the session database beside preferences (schema 3, tables
`extension_consent` and `extension_permissions`). Denials are stored rather
than inferred from absence, because absence has to keep meaning "nobody was
asked", which is what happens when a manifest grows a permission after the
install. ADR-0002 is the reason it is here and not in Swift: this is state, and
the core owns state.

`ExtensionHost.load(_:granting:)` takes the decision as a parameter rather than
looking it up, so there is no call anywhere that loads an extension without
one. Denied permissions are set to `.deniedExplicitly` rather than left alone,
because "unknown" is a status WebKit is free to resolve in the extension's
favour when the extension asks again.

### What refusing does

Refusing is a real option with a stated outcome, not a way to break the install.

- **Refuse some.** The extension installs and runs holding exactly what was
  approved. Whatever it needed from the rest does not work, and the row in
  Settings says *"Running with 2 of the 5 permissions it asked for."*
- **Refuse everything.** The extension installs and does not run. The decision
  is recorded, so nobody is asked twice and nothing is granted on the next
  launch. The row says *"Not running. You granted it nothing."*
- **Close the dialog.** Nobody agreed to have it, so it is removed from disk.
- **Never asked.** Anything installed before this browser started asking has no
  decision, which is not an empty one: it does not run, and the row offers
  *Review…*.

Everything the browser can describe arrives ticked, because an extension that
installs switched off is an extension that looks broken. Anything it *cannot*
describe arrives unticked — there is no informed consent to be had for a
sentence nobody can write.

Revoking later is the same path in reverse: `ExtensionsView` expands a row into
what it holds, and a switch goes through the core and into the live
`WKWebExtensionContext`, then back to disk. It is not a repaint.

## Consequences

**What hurts:**

- **The vocabulary is a maintained list and it will go stale.** Roughly fifty
  permissions have hand-written descriptions. Chrome adds APIs; each new one
  falls to the "zer0 cannot explain this" branch, arrives unticked, and the
  extension that needed it quietly does less until somebody writes a sentence.
  That is the failure we chose, and it is still a failure.
- **Risk tiers are a judgement, argued in a table.** `clipboardRead` is High
  and `bookmarks` is Moderate because of what a password manager copies, not
  because of anything measurable. Someone will disagree, reasonably.
- **A dialog is a dialog.** People click through them. Everything arriving
  ticked makes that cheaper, and the honest description of what we built is
  "informed consent for whoever reads it, and Chrome's behaviour for whoever
  does not". The critical tier is tinted and first because that is the only
  lever left when nobody reads.
- **Two parsers now read match patterns**, ours and WebKit's, and they can
  disagree. We made the engine authoritative and reconcile after the fact, so
  disagreement costs a correction rather than a lie — but the correction lands
  after the dialog was already shown.
- **The install got a step.** It is one sheet, and it is a step between wanting
  an extension and having one.
- **Schema 3.** A session written by this version does not lose anything to an
  older build, but the older build ignores the ledger entirely — and a browser
  that ignores the ledger is a browser that grants everything again.
- **A revoked permission is a broken extension with no explanation inside it.**
  The API silently does nothing, which ADR-0020 already calls the hardest kind
  of extension bug to diagnose. We now cause it deliberately.

**What we get:**

- Nobody has to read a manifest to find out what they agreed to.
- A refusal survives a relaunch, which is the only thing that makes a dialog
  worth reading twice.
- Site access is reviewable and revocable from a screen, at any time.
- The behaviour is testable without a window: what is granted, what is refused
  and what is unreadable are all core state.

## How this regresses

**"My extension stopped working after an update."** The manifest grew a
permission the vocabulary has no sentence for. It arrives unticked, so the
feature that needed it silently does nothing.
`a_permission_nobody_can_explain_is_not_pre_approved` proves that is
deliberate; nothing proves the sentence got written.

**"It asked me, and then granted everything anyway."** Somebody adds a
convenience path that loads an extension without a decision — a second `load`
overload, or a default argument. The signature is the defence: there is no way
to call it without one. `refusingEverythingGrantsNothing` and
`undecidedExtensionsDoNotRun` are what go red.

**"I turned it off and it kept working."** A revoke that updates the ledger and
never reaches `WKWebExtensionContext`, which looks correct in every screenshot.
`revokingReachesTheContext` asserts against the live context, not the row.

**"It forgot what I said."** The ledger stops being saved, or an empty grant
stops being written down and comes back looking like "never asked".
`refusalsSurviveARelaunch`, `a_denied_extension_permission_stays_denied_across_a_relaunch`
and `an_extension_that_was_granted_nothing_is_still_a_decision_after_a_relaunch`
hold that line from both sides of the FFI.

**"It showed me a site rule it had not actually granted."** The parser is
loosened to be "more forgiving", and a pattern nobody understands gets a
description and a switch.
`an_unreadable_pattern_is_never_offered_for_approval`,
`the_shapes_that_are_not_patterns_are_all_refused` and
`an_unreadable_pattern_cannot_be_granted_even_when_asked_for_directly` are the
three fences, and the last one is the one that survives a refactor of the other
two.

**"The scary one is in the middle of the list."** Ranking moves to the shell,
or a new risk tier is added without a severity. `the_dangerous_ones_come_first`
pins the exact order.

**And the one no test catches:** a description drifting from a consequence back
into a name. Nothing goes red when *"Read and change everything you do on every
site"* becomes *"Access to all websites"*, and the second one is a phrase that
has never stopped anybody. `all_urls_is_described_by_what_it_costs_you_not_by_its_name`
pins that one string and no others — see ADR-0018 for why this class of
regression is the expensive one.

## When to revisit

- If `WKWebExtension` gains its own consent flow, or a delegate callback for
  permission requests at runtime. Today an extension gets its answer at install
  time and asking again mid-session has nowhere to go; Safari asks per site,
  per visit, and that is a better model than ours for anything short of
  `<all_urls>`.
- If `activeTab` plus a click turns out to cover what most extensions actually
  need. Then the default could be "this site only, when you click", and
  `<all_urls>` becomes the exception someone opts into rather than the norm
  they accept.
- When Apple publishes what `WKWebExtension` implements. A permission the
  engine does not support is one we are asking about for nothing, and saying so
  in the dialog would be strictly better than asking.
- When a Linux host is attempted. The vocabulary and the ledger port unchanged;
  `ExtensionHost.apply` does not, and whatever replaces it has to keep
  "explicitly denied" meaning denied.
