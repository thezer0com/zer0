# ADR-0112: The Keychain isolates by channel and stable inherits the legacy entries

- **Status:** Accepted
- **Date:** 2026-08-13
- **Lock:** `apple/Tests/Zer0ShellTests/SecretStoreChannelTests.swift::SecretStoreChannelTests/stableAndCanaryServicesDoNotCollide`, `apple/Tests/Zer0ShellTests/SecretStoreChannelTests.swift::SecretStoreChannelTests/onlyStableInheritsTheLegacyJarAndOnlyOnce`

## Context

ADR-0109 split the app into two bundles and made the isolation structural:
"The isolation is structural, not a preference", with the promise spelled out
as "a person who installs both can be confident that a canary crash does not
eat their stable tabs". The profile followed the bundle id
(`BrowserModel.storageDir(forBundleId:)`, locked by
`defaultStoragePathFollowsTheBundleIdRule`), and with it everything the
profile holds — cookie jars, history, sessions.

The Keychain did not follow. `Keychain.service` was the literal `"zer0"` for
every channel, so the generic-password jar — the credentials the config file
names, `anthropic` and friends — was one jar. Stable and canary read and
wrote the *same items*. A canary bug that churned a credential, or a future
"reset credentials" affordance that deleted one, would reach straight into
stable's keys. That is the class of failure ADR-0109 promised to keep out:
canary touching stable's state through a door the profile split forgot. The
SQLite storage was the second-to-last such door (closed under ADR-0109 and
the `defaultStoragePath` fix); this one is the last known.

One part of the Keychain was already isolated, and it is worth naming so
this ADR is not read as wider than it is. Saved website logins are
`kSecClassInternetPassword` items keyed by origin and the Space's keychain
scope, and the scope is the Space's `data_store_id` (`passwords_ffi.rs`) —
per-profile state, so stable's logins and canary's logins are different
items from the day the profiles split. The collision this ADR closes is the
service-keyed credential jar, and only that.

## Decision

**The service a channel's credentials live under is the channel's bundle
id.** `Keychain.service` is no longer a literal. It is
`service(forBundleId:)` applied to `Bundle.main.bundleIdentifier` — the same
shape `BrowserModel.storageDir(forBundleId:)` set for the profile directory,
for the same reason: the rule is a pure function, so it is locked against
the rule rather than against the test runner's own bundle id. Stable's
credentials live under `com.thezer0.browser`, canary's under
`com.thezer0.canary`, and neither has a query that can reach the other's
items — not because a rule says so, but because no code path spells the
other's service.

**Stable inherits the legacy jar, once, by copy.** On the first launch
after this change, if the new service is empty and the legacy `"zer0"`
service has entries, the entries are copied across. The carry-over is
one-shot: the moment the new service holds anything, it never runs again.
And it is a copy, not a move — the legacy jar is never deleted. The person
keeps a complete, untouched jar under `zer0`, so rolling this decision back
is editing one line, not excavating a keychain.

**Canary inherits nothing.** The carry-over is refused for any service
other than `com.thezer0.browser`, structurally, inside the same function
that decides whether it runs at all (`shouldMigrate`). Canary is a new
bundle id and starts clean: the shared-era jar was written by whatever
binary the person ran before the split, and stable — the historical id, the
one `resolve-bundle.sh` defaults to — is that jar's continuation. A canary
that imported it would be canary touching stable's history, one launch
earlier than the failure this ADR exists to close, plus a second copy of
every key for a real bug to corrupt.

## Consequences

**Keychain Access shows two jars where it showed one.** A person looking
for their keys finds the channel's bundle id in the Where column. The error
messages already interpolate `Keychain.service`, so the recovery
suggestions name the channel's own service without any change. The legacy
`zer0` jar sits next to them, labelled the way the item comments left it;
it is the rollback, and it costs one search.

**The carry-over is item-by-item and refuses rather than repairs.** One
entry the Keychain will not hand over — a Deny click on the access prompt —
does not stop the rest, and deletes nothing: an entry that fails to cross
stays where it always was. A partially-migrated jar is therefore terminal
by design — the next launch sees a non-empty service and never runs the
carry-over again. A merge that "topped up" the missing names would be a
repair that guesses which of two jars is ahead; the honest failure is a
missing name in Settings, rendering as the `notFound` to-do list it already
renders as.

**Reading legacy values can prompt once.** The file-based keychain trusts
the app that created an item and asks when the signature changes; zer0 is
ad-hoc-signed day to day. The carry-over reads values, so a changed
signature may cost one Always Allow. This is the annoyance
`SecretStore.swift` already records choosing over the hard failure of the
data-protection keychain, and it inherits that trade unchanged.

**The Rust core still cannot spell a service.** The service is decided in
the shell, from the shell's bundle — a platform fact the core has no type
for, which keeps "a key cannot reach the config file" a property of the
seam rather than a rule somebody has to keep.

## How this regresses

**"Someone needs both channels to share a key and reinstates a literal."**
The cheap shape is `service = "zer0"` back, or a defaults-backed override
"for dev machines". The lock `stableAndCanaryServicesDoNotCollide` holds
the rule's outputs — distinct per bundle id, and `Keychain.service` equal
to the rule applied to this process's id — so a literal fails the build.
What it does not catch is a *second* resolution surface consulted instead
of `service(forBundleId:)`; that is code review's job, and this ADR is the
argument against it. (The same shape of named gap ADR-0110 records.)

**"Canary quietly inherits the jar."** The tempting version is "canary
users would love their keys too" — a widened `shouldMigrate` that drops the
stable-only check. The lock `onlyStableInheritsTheLegacyJarAndOnlyOnce`
holds the truth table, canary included, so the widening fails the build.
What the lock cannot see is the copy loop itself being handed a different
decision at its call site; the check living *inside* `shouldMigrate` is
what makes bypassing it a change to the locked function, not a forgotten
flag at a door.

**"Someone tidies the legacy jar away."** A few weeks in, the `zer0`
service reads as dead weight and deleting it looks like cleanup. It is the
rollback: delete it and this decision has no undo. No code path deletes it,
and no test can watch an absence — this ADR is what stands there.

**"The one-shot check rots into a merge."** A future bug report — "one of
my keys didn't cross" — will invite `shouldMigrate` to grow an "only the
missing ones" branch. That is the repair-that-guesses this ADR refused; the
honest fix for a key that did not cross is adding it again in Settings,
which costs the same two clicks the key cost the first time.

## When to revisit

- **When a signing identity lands and the data-protection keychain flips
  on** — `SecretStore.swift` names that day as one constant. Access is then
  derived from the app's entitlement rather than item ownership, and the
  whole service-naming question, including whether channels still need it,
  should be re-asked rather than inherited.
- **When a third channel exists** (ADR-0109 §"When to revisit" names the
  `main`-tracking build). It gets its own bundle id and its own service and
  inherits nothing; the stable-only check in `shouldMigrate` is the
  decision that says so, and a third channel is the moment to re-read it.
- **When a credential export/import UI lands.** "Never delete legacy"
  exists because rollback had to be free and the interface had no opinion.
  A UI that moves credentials on purpose supersedes it — as a new ADR, not
  an edit.
- **When the Linux port starts in earnest.** Secret Service is not the
  Keychain and the channel mechanism is not a bundle id there (ADR-0109's
  own revisit names this). The isolation stance crosses; the
  `service(forBundleId:)` shape does not, and the Linux host decides its
  own door.
