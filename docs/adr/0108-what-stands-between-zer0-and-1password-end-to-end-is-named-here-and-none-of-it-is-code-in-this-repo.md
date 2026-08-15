# ADR-0108: What stands between zer0 and 1Password end to end is named here, and none of it is code in this repo

- **Status:** Accepted
- **Date:** 2026-08-11
- **Lock:** none — debt
- **Debt note:** the four blockers named below are release and commercial
  steps outside the repository, so no test in here could defend them; the
  next ADR that touches 1Password cites this one as the reason the gap was
  not closed in code.

## Context

ADR-0105 built the native messaging host. ADR-0106 made the extension ask
for it. ADR-0107 named the one cosmetic bug on the path back. **The technical
chain from `chrome.runtime.connectNative` in 1Password's worker to a real
`Process` on this Mac is closed end to end**, and verified by
`apple/Tests/Zer0ShellTests/ZZNativeMessagingProbe.swift` with a synthetic
extension against a synthetic host in zer0's own directory.

The real 1Password extension still does not connect. Measured 2026-08-11 by
`apple/Tests/Zer0ShellTests/ZZOnePasswordSignInProbe.swift`, the welcome page
loads, the worker starts (Bitwarden's class of failure is gone), and the
extension's runtime state reports `desktopAppState: Disconnected /
PortClosed`, `hasEverConnectedToDesktopApp: false`. The extension does not
even *try* `connectNative` against the host ADR-0105 ships — it never gets
that far, because 1Password's helper (`1Password-BrowserSupport`) refuses
zer0 as a parent process before a port is opened.

That refusal is not a bug in this code. It is four release-shaped steps that
have to happen before the helper's `browser_verification/apple.rs` will
recognise zer0 as a browser it is allowed to talk to. This ADR names them so
the next person looking at "why doesn't 1Password work" finds the answer on
this page rather than rediscovering it.

## Decision

**The gap is declared a release blocker, not technical debt.** None of the
four items below is a code change in this repository, and none is going to be.
The next move on 1Password end to end is commercial and operational, and the
role of this ADR is to stop a future contributor from looking for a bug in
the wrong place.

The four steps, in the order they bind:

1. **`Zer0.app` must live at a path 1Password's helper scans.** Today the
   bundle is built into `apple/.build/` and run from there. 1Password's
   helper walks a small list of paths (and a list configured in its own
   settings — see #3); a bundle under `.build/` is not on it. The likely
   target is `/Applications/Zer0.app`, the same place every other browser
   on this machine lives.

2. **The bundle must be signed with a Developer ID Application certificate
   owned by the same team that ships zer0.** Today the bundle is
   ad-hoc signed (`Signature=adhoc`, `TeamIdentifier=not set`). The helper's
   `browser_verification/apple.rs` validates the parent process against a
   `SecRequirement` pinned to a Team ID, and ad-hoc signatures fail that
   check by construction. The Team ID `24X5CQGA86` named in ADR-0105 is
   the one already on file with AgileBits in `browsers.other-trusted-apps`;
   whatever cert ships the bundle has to match it, or the entry has to be
   amended.

3. **The bundle has to be enrolled in 1Password's `browsers.other-trusted-apps`
   list.** This is a setting 1Password ships in its own app bundle, edited
   by AgileBits. Today that entry already carries `com.thezer0.zer0`, the
   path `/Users/avelino/Applications/Zer0.app`, and the `SecRequirement`
   pinned to Team ID `24X5CQGA86`. The entry exists because somebody asked
   AgileBits to add it — confirmed by ADR-0105 — and it is the commercial
   hinge the whole chain turns on. The path it names has to match where
   step 1 put the bundle.

4. **The helper's `browser_verification/apple.rs` has to accept the parent
   process against the pinned `SecRequirement`.** This is the step the
   other three exist to satisfy. It is the helper's code, not ours, and
   it runs in `1Password-BrowserSupport` before any native messaging port
   is opened. Today, with steps 1–3 unmet, it answers no and the worker
   sees `PortClosed`.

## Consequences

**What hurts:**

- **The chain works in the harness and not in the product.** ADR-0105 and
  ADR-0106 are validated by synthetic probes (`ZZNativeMessagingProbe`,
  `ZZOnePasswordSignInProbe`), and the validation is real. But a person
  installing zer0 today and pressing the 1Password button will not see
  what the harness sees, and the four-step gap above is why. The risk is
  that this reads as "the ADRs were wrong" — they were not, they were
  answering a different question than "does 1Password connect on a fresh
  install", and that difference is what this ADR exists to put on the page.
- **One of the four steps is not ours to schedule.** Step 3 is in
  AgileBits's hands. The entry in `browsers.other-trusted-apps` already
  exists, but the path inside it (`/Users/avelino/Applications/Zer0.app`)
  is specific to one developer's machine, and the path AgileBits will
  accept for a public release is a commercial conversation. The other
  three steps cannot unblock the chain until that one is.

**What we keep:**

- Every line of code ADR-0105 and ADR-0106 added stays. Nothing here
  supersedes them; the chain they close is the chain these four steps
  will turn on, when they are taken.
- The probes stay. `ZZNativeMessagingProbe` is the only way to exercise
  the path end to end without a signed bundle, and the only honest
  witness that the bug is not in this repo.

## How this regresses

**"Somebody tried to bridge the gap in code."** The tempting path: an
`init` script that copies the bundle to `/Applications`, or a wrapper that
re-signs on every launch, or a stub bundle shipped to fool the helper.
Each is a worse version of the four steps above: the bundle at `/Applications`
has to be the one the person installed, the signature has to be the real
one, and the helper is precisely the party that decides whether to trust
the parent. Anything invented here will be recognised as evasion and
refused harder.

**"The Team ID changed and the lock went silent."** `24X5CQGA86` is a
literal in this ADR and in `browsers.other-trusted-apps`. If zer0 ever
ships under a different team, both have to change in lockstep, and
nothing in this repo will catch the mismatch — the symptom will be
"1Password stopped connecting again", weeks later, the same failure mode
ADR-0106 §"How this regresses" warned about for the Chrome version token.

**"The path entry in `browsers.other-trusted-apps` was treated as the
release decision."** It is necessary, not sufficient. A future reader
sees the entry exists, concludes "we are enrolled", and stops. Steps 1,
2 and 4 still bind, and the helper still refuses.

## When to revisit

- **When zer0 ships a signed bundle.** Steps 1 and 2 close together; the
  moment they do, the only remaining technical question is whether the
  path AgileBits named matches the path the bundle lives at. This ADR
  retires when the chain works on a fresh install, not before.
- **When AgileBits changes the helper's verification rule.** Today it is
  `browser_verification/apple.rs` against a `SecRequirement`; if that
  moves to a notarisation check or a different stake, the four steps
  reshape, and the new shape belongs in a new ADR rather than an edit
  here.
- **When a second extension with the same commercial shape arrives.**
  Bitwarden, Dashlane, Kagi — any password manager or native-messaging
  helper that walks its own list of trusted browsers will hit the same
  four-step gap. The pattern is what this ADR generalises; the specifics
  for each new helper are their own page.
