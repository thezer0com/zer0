# ADR-0094: A certificate says which fact is wrong, and the way past one exists only where nobody can be in between

- **Status:** Accepted
- **Date:** 2026-08-10
- **Lock:** `crates/zer0-core/src/certificates_tests.rs::a_self_signed_certificate_and_one_from_an_unknown_authority_are_different_facts`, `crates/zer0-core/src/certificates_tests.rs::an_expired_certificate_says_when_rather_than_that`, `crates/zer0-core/src/certificates_tests.rs::a_clock_that_is_wrong_is_named_as_a_clock_rather_than_as_an_attack`, `crates/zer0-core/src/certificates_tests.rs::a_certificate_for_another_name_leads_and_says_which_name`, `crates/zer0-core/src/certificates_tests.rs::a_certificate_that_is_wrong_twice_says_so_twice`, `crates/zer0-core/src/certificates_tests.rs::a_window_that_could_not_be_read_is_not_called_valid`, `crates/zer0-core/src/certificates_tests.rs::something_rejected_for_a_reason_we_cannot_name_still_says_something`, `crates/zer0-core/src/certificates_tests.rs::no_sentence_on_this_screen_lists_what_it_might_be`, `crates/zer0-core/src/certificates_tests.rs::only_a_host_with_no_network_between_the_ends_is_offered_a_way_through`, `crates/zer0-core/src/certificates_tests.rs::a_host_somebody_else_can_be_on_is_offered_no_way_through_at_all`, `crates/zer0-core/src/certificates_tests.rs::a_certificate_with_no_fingerprint_is_not_waved_through_even_on_loopback`, `crates/zer0-core/src/certificates_tests.rs::an_exception_covers_one_certificate_and_not_the_host_it_arrived_on`, `crates/zer0-core/src/certificates_tests.rs::an_exception_given_in_one_space_does_not_follow_you_into_another`, `crates/zer0-core/src/certificates_tests.rs::closing_a_space_takes_its_exceptions_with_it`, `crates/zer0-core/src/certificates_tests.rs::nothing_is_pinned_to_an_empty_fingerprint`, `crates/zer0-core/src/reducer_tests.rs::a_rejected_certificate_is_refused_and_its_faults_are_kept_for_the_screen`, `crates/zer0-core/src/reducer_tests.rs::a_certificate_somebody_waved_through_is_not_asked_about_again_in_that_space`, `apple/Tests/Zer0ShellTests/AuthChallengeTests.swift::CertificateFactsTests/selfSignedForTheRightName`, `apple/Tests/Zer0ShellTests/AuthChallengeTests.swift::CertificateFactsTests/wrongName`, `apple/Tests/Zer0ShellTests/AuthChallengeTests.swift::CertificateFactsTests/expired`, `apple/Tests/Zer0ShellTests/AuthChallengeTests.swift::CertificateFactsTests/privateAuthority`, `apple/Tests/Zer0ShellTests/AuthChallengeTests.swift::CertificateFactsTests/fingerprintsDiffer`, `apple/Tests/Zer0ShellTests/AuthChallengeTests.swift::AuthLedgerTests/proceedingUsesTheTrust`, `apple/Tests/Zer0ShellTests/AuthChallengeTests.swift::AuthLedgerTests/refusingACertificateAnswers`, `apple/Tests/Zer0ShellTests/AuthChallengeTests.swift::AuthLedgerTests/proceedingWithNothingRefuses`, `apple/Tests/Zer0ShellTests/AuthChallengeTests.swift::AuthSourceRuleTests/continuingIsNotOnAKey`, `apple/Tests/Zer0ShellTests/AuthChallengeTests.swift::ServerTrustGateTests/anAcceptedCertificateIsNotReported`, `apple/Tests/Zer0ShellTests/AuthChallengeTests.swift::ServerTrustGateTests/aRefusedCertificateStillReachesTheCore`

## Context

ADR-0016 already routes a TLS failure to the whole-screen explanation, and it
already booked the missing half as a known cost:

> **`certificateInvalid` does not offer "proceed anyway".** The right security
> decision and a real UX cost: anyone dealing with a self-signed cert in
> development has no path in the browser.

So the screen was not missing. What it said was:

> **This connection isn't private.**
> This site's certificate can't be trusted, so the page was not loaded. It may
> be expired, or someone may be impersonating the site.

That second sentence is a **list of guesses**, and by ADR-0018's own test it is
the interface asserting something it cannot back up: it does not know which of
the two it is, and a person reading it cannot act on either. Expired means an
administrator forgot. Impersonation means leave. Presenting them as
interchangeable is the same defect as an invented match count, wearing a
security badge.

### The facts are separable, and this was measured

Four servers were stood up on loopback and a real `WKWebView` was pointed at
each, and the `SecTrust` it handed to the delegate was taken apart with **public
API only**:

| server | self-signed | reaches an anchor | name matches | dates |
| --- | --- | --- | --- | --- |
| a real public site | no | **yes** | yes | valid |
| self-signed `localhost` | **yes** | no | yes | valid |
| self-signed, `CN=not-the-host.example` | yes | no | **no** | valid |
| self-signed, valid 2020-01-01→02 | yes | no | yes | **expired** |
| leaf under a private CA | **no** | **no** | yes | valid |

The last row is the one that forced the design. A company's internal CA produces
"reaches no anchor" **and not** "self-signed", so collapsing them into one fault
would tell somebody their corporate certificate signed itself, which is untrue.

Two things had to be measured rather than reasoned about to get that table:

- **`SecTrustCopyResult` does separate the cases** — its `TrustResultDetails`
  carries `AnchorTrusted`, `SSLHostname`, `TemporalValidity` — and **those keys
  are in no public header.** ADR-0067 spends this project's one
  reached-by-name-at-runtime SPI on the Web Inspector, and this does not spend a
  second. Everything below uses documented API.
- **The verify date has to be pinned inside the leaf's own window** before
  asking whether the chain reaches an anchor, or an expired certificate fails
  that check too and reports two faults where one is true. Same for the name
  check, with the chain's own root installed as the only anchor.

An early cert generation also produced a confound worth recording: certificates
made without `extendedKeyUsage=serverAuth` report an EKU failure on *every* row,
which looked like a fact about the servers and was a fact about `openssl`.

## Decision

**The shell measures the certificate, the core names every fault it has, and a
way past one is offered only where there is no network between the two ends.**

### The shell measures and the core decides

`ReportedCertificate` is geometry, the way `passwords::ReportedField` is:
fingerprint, subject, issuer, the names it covers, the validity window, whether
it signed itself, whether the chain reaches a trusted anchor, whether the
platform's SSL policy accepts it for this host. Every field is something the
platform answered, not something the shell concluded.

`CertificateFault` is the decision, in the core, closed, so a new fact must earn
a sentence before it compiles (ADR-0031): `WrongHost`, `Expired`,
`NotYetValid`, `SelfSigned`, `UnknownIssuer`, `Unreadable`.

### Only a certificate this machine refuses ever reaches the core

**Corrected in place, after it broke every page in the browser.** This ADR was
written believing that a server-trust challenge arrives only for a certificate
the engine would have refused, and the first implementation reported every one
it saw. That belief is wrong: **once `didReceive:challenge:` exists, WebKit
hands it a server-trust challenge on every TLS connection**, valid or not.

What that produced, measured on `example.com`, `linkedin.com` and
`www.linkedin.com` through the real shell: a certificate nothing objects to was
reported as `ServerTrustRejected`, the core found no exception for it and
answered `Refuse` — which is exactly right for the question it was asked — and
WebKit failed the navigation as `NSURLErrorCancelled`. The reducer deliberately
draws no screen for a cancellation, because every download and every redirect
produces one. So **no https page in this browser loaded at all**, and the way it
failed was a tab that opened, said "New Tab", and stayed white, with no error
anywhere in the model. `file://` was unaffected, which is what made it look like
a defect in whatever had last been touched.

So `AuthChallengeHost` asks the platform first — one `SecTrustEvaluateWithError`
on the trust object the challenge arrived with — and reports only what comes
back false. Nothing else about the design moves: a chain this machine does not
accept still goes to the core with the facts below, still gets refused without an
exception, and still gets the screen.

**This is a measurement and not a decision**, in the same sense every field of
`ReportedCertificate` is one: the only thing holding the answer to "does this
machine trust this chain" is this machine's trust store, and a Linux host asks
its own. What to do about a chain that fails is untouched and entirely the
core's.

And it is asked of the platform rather than derived from the facts below,
which would have been the tidier-looking version. Those facts are measured with
the verify date pinned and the anchors substituted precisely so each fault can be
named on its own — so a chain that looks clean by all three of them can still be
revoked, weakly signed, or short of this OS's certificate-transparency
requirement. Deriving `Proceed` from them would be a check weaker than the
platform's own, in the one place in this browser where weaker means "waved
through".

### All the faults, most actionable first

**Not the first one.** A certificate is easily both expired and for the wrong
name, and a screen that named one would send somebody to fix half of it and
surprise them again with the rest.

The order is what somebody can do about it. `WrongHost` leads because it is the
only one of these a stranger on the network produces on purpose. Dates come
next, because they have a fix and because `NotYetValid` is almost always this
Mac's clock — a sentence that saves somebody an afternoon.

`Unreadable` is the branch that keeps this honest. A window that would not parse
is not a window we may call valid, and a connection the engine refused for a
reason none of the clauses explain still says something rather than nothing.

### Revocation is declared debt rather than an empty case

A revoked certificate is a genuinely different fact and a person could act on
it. The trust object does not carry a revocation verdict readable without
another network fetch, and inventing a variant nothing can produce would be a
branch that reads as covered and is not. It lands in `Unreadable` today, and
that is said here rather than hidden in an enum.

### "Proceed anyway" exists on loopback and nowhere else

This is the decision in the ADR, and it is a refusal almost everywhere.

Every mainstream browser puts a way through on this screen. The result is a
generation who have learned that the certificate warning is a door with an
awkward handle. **The button is not harmful because it exists; it is harmful
because it exists in the one place a warning is being read**, so pressing it
becomes the way to make the warning go away — and once that reflex is built it
fires on the bank too.

zer0 offers it in exactly one situation: **the host cannot be reached across a
network.** `localhost`, `127.0.0.1`, `::1`, anything under `.localhost`. There,
the sentence every other browser has to write — *"someone may be impersonating
this site"* — does not describe something unlikely, it describes something that
**cannot happen**: there is no network segment for anybody to sit on. A
self-signed certificate on loopback is somebody's own development server, and
refusing it costs them the use of this browser for their job while protecting
them from no one.

**Everywhere else the answer is no, including an internal host on a private
network**, and that boundary is the part worth being explicit about. `10.x`,
`192.168.x` and `staging.corp` all sit on a network somebody else can be on; a
wrong certificate there is exactly as likely to be interception as
misconfiguration and we cannot tell which. The way in for those is to fix the
certificate or to trust its authority on the machine — both outside the
browser, both deliberate. That is what "it must cost something deliberate"
buys: **clicking through the warning is not one of the things you can do while
reading it.**

A typed per-host exception in Settings is where this should go next, and the
screen deliberately **does not** name it yet. An earlier draft of the sentence
did, and that was this ADR committing the defect it is about: a security screen
naming a way out that does not exist is an invented match count wearing a
padlock, and worse than the usual kind because somebody would go looking for
it.

The screen says so, rather than simply having no button. A screen with no way
forward reads as a browser that cannot do something; this one has decided not
to, and saying which is the difference between a limitation and a position
(ADR-0018).

### An exception is one certificate, in one Space, for one session

Pinned to the leaf's SHA-256, **not to the host**. That is the whole of why it
is safe to have: an exception for the certificate on a development box does not
cover a different certificate arriving from that host tomorrow, which is
precisely the shape interception takes. A host-keyed exception turns one
deliberate decision into a standing invitation.

Per Space, because a Space is an identity and closing one takes what it decided
with it (ADR-0007, ADR-0056).

**Never written to disk**, and that is a decision rather than an omission. A
stored exception is a hole in the browser's own guarantee that outlives every
memory of making it: months later the box has been rebuilt, the certificate
belongs to somebody else, and no screen says the browser stopped checking that
host. In memory it costs a developer one click per launch and cannot rot.

### The facts reach the screen through the tab, not through the error

The certificate exists while the trust challenge is open and is gone by the time
`-1202` arrives, so the report is kept against the tab and cleared when the tab
commits a page. `NavigationError` is untouched, and the existing failure path —
which works — is not disturbed: the challenge is refused, WebKit fails the
navigation exactly as before, and the screen that was already there now has
something true to say.

The way through was measured end to end rather than assumed: answering with
`URLCredential(trust:)` against the self-signed, wrong-host and expired servers
loaded the page in all three.

## Consequences

**What hurts:**

- **An internal host with a private CA still cannot be reached from this
  screen.** This is the deliberate cost and the one people will complain about
  first. The honest answer is "install the CA, or type the fingerprint into
  Settings", and both are more work than a button.
- **There is no way past a bad certificate on a non-loopback host at all.** Not
  a hard one, not a typed one: none. The honest instruction is "fix the
  certificate or install its authority", which is real advice and is more work
  than a button. This is the sharpest cost in the ADR and it is not softened.
- **An exception dies on quit**, so a developer working all day across restarts
  clicks through once per launch. Correct, and irritating in exactly the way a
  security decision is.
- **Six faults, six sentences.** Every new one costs copy, and the closed enum
  guarantees coverage rather than quality — an empty string compiles.
- **Revocation is not reported**, and somebody will reasonably expect it.
- **The faults are drawn as a list under a headline**, and a certificate wrong
  in three ways is a wall of small text on a screen whose job is one sentence.
- **The measurement is four `SecTrust` evaluations per rejected certificate**,
  three of them constructed on the spot. It happens only on failure, and it is
  more work than reading two undocumented dictionary keys would have been.
- **Every TLS connection now costs one `SecTrustEvaluateWithError`**, on the
  main thread, before the handshake completes. That is the gate above and it is
  not free — it is the same evaluation WebKit would have done for us had this
  delegate not existed, so the honest description is that implementing this
  method moved the cost rather than added it, and that nothing profiles it.

**What we get:**

- A screen that names what is wrong instead of listing what it might be.
- A development workflow that is possible at all, without a button that teaches
  anybody to click through a warning about a bank.
- An exception that cannot silently widen: not to another certificate, not to
  another Space, not to next week.
- All of it testable without a network, and portable: what does not port is
  about eighty lines of `AuthChallengeHost.swift`.

## How this regresses

**"Nothing loads. Every tab is blank and says New Tab."** The gate goes, most
plausibly because a delegate method that reports "rejected" reads as though it
only fires on a rejection — which is what this ADR itself said until the browser
proved otherwise. The failure is silent in every direction: no error in the
model, no screen, no log, and `file://` pages carry on working, so it reads as a
defect in whatever was touched last.
`anAcceptedCertificateIsNotReported` drives the real delegate with a chain the
platform accepts and demands that nothing was reported and that the engine was
answered, and `aRefusedCertificateStillReachesTheCore` holds the other half so
the gate cannot be "fixed" by never reporting anything.

**"It says the connection isn't private and nothing else."** Somebody
simplifies `faults` to return one value, or the screen stops reading the report.
`a_certificate_that_is_wrong_twice_says_so_twice` covers the first and asserts
on the report the screen is actually handed.

**"It told me my company's certificate signed itself."** The `self_signed` and
`unknown_issuer` branches are folded together, which looks like tidying two
cases that always co-occur — they do not.
`a_self_signed_certificate_and_one_from_an_unknown_authority_are_different_facts`
is built from the private-CA row precisely so that merge reddens, and
`privateAuthority` holds the same line against a real chain.

**"It said the certificate was untrusted when it had only expired."** The verify
date stops being pinned before the anchor check — the most likely edit, because
pinning it looks redundant. `expired` asserts against a real 2020 certificate
that the name check still passes.

**"I clicked through a warning on a bank."** The loopback condition is loosened,
most plausibly to "private network too" by somebody who works on `192.168.x`.
`a_host_somebody_else_can_be_on_is_offered_no_way_through_at_all` lists seven
hosts including the private ranges and the `localhost.evil.tld` lookalike.

**"I pressed Return on the warning and it loaded."** A `.defaultAction` is added
to the way-through button, or it becomes `.borderedProminent` because a link
looks unfinished. `continuingIsNotOnAKey` reads the source, because the rule is
an absence and no assertion can watch one.

**"An exception I made for my dev box covered somebody else's certificate."**
`holds` drops the fingerprint during a refactor that notices two of three
columns find the row. They do — the wrong one.
`an_exception_covers_one_certificate_and_not_the_host_it_arrived_on`, and
`a_certificate_somebody_waved_through_is_not_asked_about_again_in_that_space`
holds the same line through the reducer with a swapped fingerprint.

**"My work exception showed up in my personal space."**
`an_exception_given_in_one_space_does_not_follow_you_into_another`.

**"Exceptions started surviving relaunches."** Somebody persists them as an
obvious convenience. **No lock**: nothing fails if a `trust_exceptions` table
appears, because the decision not to store something cannot be observed by a
test of what is stored. The nearest fence is that `StorableSession` has no field
for one, which is a guarantee only while nobody adds it. Declared debt.

**And the second one with no lock:** nothing stops the sentence regaining a
pointer to a Settings control before that control exists. `no_exception_note` is
one string and no test reads what it names. Declared debt, and the reason the
comment above it is as long as it is.

## When to revisit

- **For a typed exception in Settings › Privacy**, which is the right next
  step: it keeps the cost deliberate while making an internal host reachable.
  The sentence on the screen gains its pointer on the day the control lands,
  and not before.
- **If revocation becomes readable** without a second network fetch, or if
  spending one is judged worth it. It is a real fault and it deserves a
  sentence.
- **If the internal-host refusal turns out to block real work for somebody who
  is not the author.** The answer is not to widen the loopback rule; it is to
  make the typed exception fast enough that it is not the reason anybody
  reaches for another browser.
- **If a session-lived exception proves too expensive in practice.** The next
  step is a longer-lived one that *shows itself* — a standing list somebody sees
  and can revoke — rather than one that quietly persists.
- **When there is a second host.** `webkit2gtk` reports this through
  `load-failed-with-tls-errors` with a `GTlsCertificateFlags`, which is a
  coarser answer than a `SecTrust`. The faults the core names would have to be
  derived from fewer facts, and any it cannot establish must become
  `Unreadable` rather than a guess.
