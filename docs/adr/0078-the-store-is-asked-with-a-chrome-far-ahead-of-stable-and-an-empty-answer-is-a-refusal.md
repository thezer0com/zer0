# ADR-0078: The store is asked with a Chrome far ahead of stable, and an empty answer is a refusal

- **Status:** Accepted
- **Date:** 2026-08-10
- **Lock:** `crates/zer0-core/src/ext/ext_tests.rs::the_chrome_version_asked_with_is_ahead_of_the_stable_it_could_be_mistaken_for`, `apple/Tests/Zer0ShellTests/ExtensionTests.swift::ExtensionDownloadRefusalTests/nothingFromTheStoreIsARefusal`, `apple/Tests/Zer0ShellTests/ExtensionTests.swift::ExtensionDownloadRefusalTests/aFailedRequestIsStillAFailedRequest`, `apple/Tests/Zer0ShellTests/ExtensionTests.swift::ExtensionDownloadRefusalTests/bytesFromTheStoreAreNotARefusal`

## Context

ADR-0021 decided we call the endpoint Chrome's updater calls, and named the
number it hands over: `chromeVersionForDownloads = "131.0.0.0"`, in
`BrowserModel.swift`, with the comment *"Too old a value and it serves nothing;
this is a recent stable release."* It was a recent stable release. It stopped
being one, and the comment stopped being a description and became a promise
nobody was keeping.

Everything below was measured against the live endpoint on 2026-08-10, one id
per request, reading the first response without following the redirect —
`302` means there is a package, `204 No Content` means there is not.

**At `120.0.0.0`, 15 of 18 popular ids answer `204`.** uBlock Origin Lite,
MetaMask, 1Password, Privacy Badger, DuckDuckGo, Adblock Plus, AdBlock, AdGuard,
Violentmonkey, Stylus, Wappalyzer, Refined GitHub, Web Vitals, Pocket and
Enhancer for YouTube.

**At the shipping `131.0.0.0`, Violentmonkey still answers `204`.** Its floor
sits between `132.0.0.0` (`204`) and `135.0.0.0` (`302`). So the defect was not
hypothetical and was not only in a test fixture: one measured extension in
eighteen was uninstallable in the shipping build, and nothing said so.

*Corrected in place, because the survey this work came from said otherwise:*
`download_url` never sent `120.0.0.0`. That value appeared only as an argument
in `the_download_url_names_the_extension_being_asked_for`. The shipping caller
sent `131.0.0.0`, and the 15-of-18 figure is what `120.0.0.0` would have cost,
not what was being paid.

**The endpoint enforces a floor and has no ceiling.** Asking with
`151.0.7922.109` — Chrome stable for macOS that day, read from
`versionhistory.googleapis.com` — with `200.0.0.0` and with `999.0.0.0` returned
byte-identical packages for uBlock Origin Lite, Bitwarden and Violentmonkey,
down to the blob filename. There is no "too new".

**And some ids answer `204` at every version.** Web Vitals and Pocket did at
`120`, `131` and `140`. Whatever number is chosen, this state exists, and today
it is not reported: `204` is a *success* status, so the range check waves it
through, an empty buffer reaches `install_extension`, and the person is told
**"not a CRX package"** about a file they never had.

## Decision

Two things, and they are one decision because the second is what keeps the
first honest.

### The version lives in the core and is set far ahead of stable

`crates/zer0-core/src/ext/mod.rs::CHROME_VERSION_FOR_DOWNLOADS` is `200.0.0.0`,
and `download_url(id)` no longer takes a version at all.

The argument for a large value is the measurement: since the endpoint only ever
refuses downward, being wrong is only possible in one direction, and the cost of
being wrong in it is whole extensions. An extension's `minimum_chrome_version`
can never usefully exceed Chrome stable — requiring an unreleased Chrome would
make it uninstallable for everyone — so **any value above stable is sufficient,
and stays sufficient until Chrome catches up.** Chrome reaches 200 around 2030.

What is refused is the alternative that reads as the responsible one: track the
current stable release. That is what `131.0.0.0` was. A number whose correctness
is a function of the calendar, held in a file nothing recalculates, is a number
that rots, and it rotted silently for eighteen months.

Dropping the parameter is the structural half. The number that decides whether a
quarter of the store answers at all was held by the shell, where nothing tests
it and where two platforms would each keep their own copy — and two hosts cannot
reasonably disagree about what Google's endpoint wants. There is now no field a
stale version fits in.

### An answer with no package is a refusal that names both the id and the version

`ExtensionInstallError.refusal(toStoreResponse:status:id:chromeVersion:)` is the
one door, sitting on the single `URLSession` call every install in the product
goes through. A successful status carrying no bytes produces:

> The Chrome Web Store has no package for `ddkjiahejlhfcafbddmgiahcphecmpfh`. It
> answered with nothing and did not say why — the two reasons it does that are
> an item that is no longer offered, and one it will not serve to Chrome
> 200.0.0.0, which is the version zer0 asks with.

Three things about that are deliberate.

**It is keyed on there being no bytes, not on the status.** That is exactly the
fact the sentence claims, and it is the fact that makes the next step
impossible. Keying on `204` would be keying on the mechanism.

**It does not say which of the two reasons applies**, because this side cannot
tell them apart. Both were measured and both are real; picking one would be a
guess with a sentence around it.

**It names the version.** That is the whole answer to *"how does the next person
know to move it"*. A unit test cannot notice that the endpoint's floor has risen
past our claim — that needs a network — so staleness is caught in the product
instead, by a report that arrives already carrying the number to change.

## Consequences

**What hurts:**

- **We are now claiming to be a Chrome that does not exist.** ADR-0021 said the
  sentence "we tell that endpoint we are a Chrome" should be uncomfortable to
  read. This is more uncomfortable, not less. It is also a trivial filter: if
  Google ever wants to shut third-party clients out of this endpoint, "asking
  with a prodversion above current stable" is one line of theirs.
- **The refusal names two reasons and commits to neither**, which is a worse
  sentence to read than a diagnosis. It is the true one. The alternative was a
  parser error about a file that was never downloaded.
- **Nothing detects staleness before a person hits it.** The 204 refusal is a
  report, not a monitor. The first anyone knows is somebody failing to install
  something, and the only thing that improves on that is a network call in CI
  against an endpoint we are not authorised to use.
- **A withdrawn extension and a version floor read identically**, so the sentence
  will sometimes point at a number that is fine. Web Vitals and Pocket are that
  case today.
- **`200.0.0.0` is still a constant with an expiry**, just a distant one. It is
  the same class of thing as `131.0.0.0` and the honest claim is that the fuse is
  longer and now attached to an alarm.

**What we get:**

- Every extension measured except the two that are unavailable at any version
  now downloads, including the most-installed content blocker on the store.
- The number is spelled once, in the layer that is tested, with the measurement
  next to it.
- A person who cannot install something is told what happened and is holding the
  evidence for the fix.

## How this regresses

**"Add says the store has nothing, for everything."** Someone reads
`200.0.0.0`, concludes it is a typo or a fingerprint risk, and corrects it to
whatever Chrome is current — which is precisely the reasoning that produced
`131.0.0.0` and lost Violentmonkey. It will read as tidying up.
`the_chrome_version_asked_with_is_ahead_of_the_stable_it_could_be_mistaken_for`
goes red naming the major it was handed and the stable it is behind, and it is
the one worth breaking on purpose.

**"It says the package is corrupt and I never got a package."** The empty-answer
guard is dropped, most plausibly by somebody simplifying `refusal` back into the
status-range check it grew out of — a `204` *is* a success, so the shorter code
looks right. `nothingFromTheStoreIsARefusal` holds it, and asserts the id and the
version are in the sentence rather than only that an error was thrown.

**"Every install fails now."** The guard is inverted or widened to any response,
and nothing installs. `bytesFromTheStoreAreNotARefusal` is the other half and is
one line.

**"A 404 tells me to check the Chrome version."** The new sentence is printed
over an HTTP failure it cannot explain, because the empty-body branch was moved
above the status check. `aFailedRequestIsStillAFailedRequest` matches on the case
rather than on the text.

**The one no test catches:** the version being read from somewhere else again. A
second constant in Swift, a value in the config file, a `prodversion` spelled
into a URL somewhere outside `download_url` — nothing goes red and the one door
is gone. It is the same quiet regression ADR-0021 already named for
`clients2.google.com`, and it has the same absent grep in `check.sh`.

## When to revisit

- **When a 204 is reported for an extension the store shows as available.** That
  is the exit condition firing, the fix is to raise the constant, and the report
  already contains the current value.
- **If the endpoint starts refusing implausible versions.** Then the argument
  inverts — the floor still has to be cleared, but from below rather than from
  far above, and tracking stable becomes the only option along with whatever
  keeps it tracked.
- **When Chrome stable approaches 200.** Around 2030 at the present cadence.
  Raising the constant then is a one-line change and this file is the reason it
  is allowed to be one.
- **If the store is ever swapped for another source** (ADR-0021's own exit).
  Both halves of this go with it: another source has its own idea of what
  identifies a client, and probably its own way of saying "nothing here".
