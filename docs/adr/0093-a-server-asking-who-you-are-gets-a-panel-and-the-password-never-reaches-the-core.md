# ADR-0093: A server asking who you are gets a panel over the page, and the password never reaches the core

- **Status:** Accepted
- **Date:** 2026-08-10
- **Lock:** `crates/zer0-core/src/http_auth_tests.rs::nothing_here_can_produce_a_credential_on_its_own`, `crates/zer0-core/src/http_auth_tests.rs::a_page_you_are_not_looking_at_is_refused_without_a_panel`, `crates/zer0-core/src/http_auth_tests.rs::a_second_challenge_is_refused_rather_than_stacked`, `crates/zer0-core/src/http_auth_tests.rs::a_server_that_keeps_saying_no_stops_being_asked_about`, `crates/zer0-core/src/http_auth_tests.rs::the_shapes_that_are_not_origins_are_all_refused`, `crates/zer0-core/src/http_auth_tests.rs::a_scheme_whose_answer_is_not_a_password_is_refused_rather_than_asked_about`, `crates/zer0-core/src/http_auth_tests.rs::a_password_going_out_in_the_clear_is_said_so_and_never_offered_to_be_kept`, `crates/zer0-core/src/http_auth_tests.rs::a_loopback_sign_in_is_neither_warned_about_nor_refused_a_keychain_item`, `crates/zer0-core/src/http_auth_tests.rs::an_ephemeral_space_is_never_offered_the_chance_to_write_one_down`, `crates/zer0-core/src/http_auth_tests.rs::a_proxy_is_named_as_one_and_nothing_is_kept_for_it`, `crates/zer0-core/src/http_auth_tests.rs::an_internationalised_host_is_keyed_by_the_spelling_that_cannot_be_faked`, `crates/zer0-core/src/http_auth_tests.rs::the_servers_realm_is_carried_apart_from_every_sentence_we_wrote`, `crates/zer0-core/src/http_auth_tests.rs::a_realm_cannot_draw_itself_as_a_second_line_or_push_the_buttons_off`, `crates/zer0-core/src/reducer_tests.rs::a_challenge_nobody_is_asked_about_is_still_answered`, `crates/zer0-core/src/reducer_tests.rs::closing_a_tab_answers_the_server_it_was_being_asked_by`, `crates/zer0-core/src/reducer_tests.rs::a_panel_that_was_already_answered_answers_nothing_a_second_time`, `apple/Tests/Zer0ShellTests/AuthChallengeTests.swift::AuthLedgerTests/signingInAnswersOnce`, `apple/Tests/Zer0ShellTests/AuthChallengeTests.swift::AuthLedgerTests/cancellingStillAnswers`, `apple/Tests/Zer0ShellTests/AuthChallengeTests.swift::AuthLedgerTests/answeringTwiceCallsTheHandlerOnce`, `apple/Tests/Zer0ShellTests/AuthChallengeTests.swift::AuthLedgerTests/nothingSuppliedCancels`, `apple/Tests/Zer0ShellTests/AuthChallengeTests.swift::AuthLedgerTests/defaultHandlingIsNeverTheAnswer`, `apple/Tests/Zer0ShellTests/AuthChallengeTests.swift::AuthSourceRuleTests/realmIsNeverOurs`, `apple/Tests/Zer0ShellTests/AuthChallengeTests.swift::AuthSourceRuleTests/noPasswordEscapes`

## Context

`grep` across `apple/Sources` found no implementation of
`webView(_:didReceive:completionHandler:)`. There was no way to enter a username
and password anywhere in this browser: a staging server, an internal dashboard,
a router's admin page were all simply unreachable.

**What that actually looked like was measured, and it is not what it sounds
like.** A `WKWebView` with no authentication delegate does not fail the
navigation. Against a real server sending
`WWW-Authenticate: Basic realm="Staging"`:

| stage | what arrived |
| --- | --- |
| `didStartProvisionalNavigation` | yes |
| `decidePolicyFor response` | **status 401** |
| `didCommit` | yes |
| `didFinish` | yes |
| body | the server's refusal bytes, rendered as a page |

So the navigation *succeeded*. Nothing failed, nothing was reported, and
ADR-0016's error screen never got a turn — because from the engine's point of
view nothing had gone wrong. The person is looking at whatever the server sends
with a 401, which for most servers is a blank page or the string
`401 Unauthorized`. That is exactly the white rectangle ADR-0016 exists to
abolish, arriving through a door ADR-0016 does not cover.

The measurement was itself hard-won and the failure is worth recording, because
it is the shape AGENTS.md warns about. Three separate instrument faults produced
three confident wrong answers before any of the above was true:

1. The probe's delegate method was written without `@MainActor` on the
   completion handler. On this SDK that is a **different selector**, so the
   method silently was not a conformance and WebKit never called it. Reported as
   "the callback does not fire".
2. The probe did not retain its `WKWebView`. A fast loopback 200 finished before
   the view was released; every slower path — TLS handshake, auth challenge —
   returned nothing at all. Reported as "nothing arrives for any of these".
3. Only after a plain HTTPS control page loaded successfully was any negative
   result worth reading.

### What the platform hands over

Established from a live challenge rather than from recollection:

- `URLAuthenticationChallenge.protectionSpace` carries `host`, `port`,
  `protocol`, `realm`, `authenticationMethod` and `isProxy()`.
- `previousFailureCount` counts rejections within one navigation.
- `NSURLAuthenticationMethod*` is an **open set of strings**, including
  `ServerTrust`, which is not a password question at all (ADR-0094).
- The realm arrives verbatim off the wire. A server sending
  `realm="Staging <script>alert(1)</script> "quoted""` delivered
  `Staging <script>alert(1)</script> ` — markup intact, and truncated wherever
  the quoting happened to end.

## Decision

**A server asking for a password is a routine request, so it gets a panel over
the page it belongs to; the rules about whether to ask at all are in the core;
and no password crosses into the core at any point.**

### It is a panel, and the certificate screen is a screen

The two arrive on one engine callback and they are not the same kind of event.
Being asked to name yourself is something you do while browsing. Being told a
site cannot be shown to be itself is a security decision, and ADR-0016 gives
that the whole area.

One surface for both would fail in a specific direction: the routine thing
happens hundreds of times more often, so a shared surface teaches the reflex
that dismisses it — and that reflex then fires on the warning. They are kept
apart so that the rare one does not inherit the habits of the common one.

### The words and the gate are in the core

`crates/zer0-core/src/http_auth.rs`, the same shape ADR-0056 uses for the
camera. `gate` answers most challenges with no panel at all, and **every silent
answer is a refusal** — there is no path through that function that produces a
credential, which is what makes "a page cannot get itself signed in" structural:

- a tab nobody is looking at, so a background reload cannot put a password field
  in front of the page being read;
- an origin nobody could read;
- a scheme whose answer is not a username and a password — a client-certificate
  request gets refused rather than drawn as a login box;
- a server that has already refused three times, because a panel that always
  comes back is how somebody ends up typing their real password into it;
- anything arriving while a panel is up. **One, not a queue**: a page with
  twenty subresources behind one realm would otherwise stack twenty panels.

### Every challenge is answered exactly once

This is the invariant with the worst failure in the change, and the reason it is
worth a rule rather than care: **a completion handler that is never called
produces no `didFinish`, no `didFail` and no timeout.** The tab holds a white
rectangle for as long as the browser is open, indistinguishable from a slow page,
and no error screen can catch it because no error exists.

So the handlers live on `EngineHost` rather than on the per-tab delegate, a tab
closing mid-question emits its refusal *before* `DestroyWebView`, and
`AuthChallengeLedger.answer` removes before it calls. The one door that answers
everything a closing tab owed — a camera prompt, a page dialog, and now this —
is `answer_pending_for`.

`AuthDecision` has two cases where `URLSession.AuthChallengeDisposition` has
four. `performDefaultHandling` is missing because it is measurably the state
this browser was in; `rejectProtectionSpace` is missing because it is a decision
about the protocol rather than about the person.

### The password never reaches the core

`AuthChoice` has three cases and **none of them carries a value**. The shell
puts what was typed into the ledger, tells the core only that somebody answered,
and the core answers `UseCredential` — a decision, not a credential. No type in
`http_auth.rs` has a field a password fits in. That is ADR-0064's guarantee for
form logins, held one layer up, and by the same means.

### Remembering goes through ADR-0064's machinery, or not at all

An HTTP-auth credential is keyed by the same canonical origin a form login is,
so `https://staging.example` has **one** account list rather than two. It is a
`kSecClassInternetPassword` item with `kSecAttrSecurityDomain` naming the Space,
which is what makes Work and Personal two logins.

`may_remember` is false, from the core, for three separate reasons the panel
must not work out for itself: a **proxy** credential is not keyed to a site at
all; an **unencrypted origin off loopback** is one we would be writing down a
password we had just watched go out in the clear; and an **ephemeral Space**
promised to leave nothing behind (ADR-0023). Loopback is the exception on the
second, because there is no network between the two ends — the same line
`passwords.rs` already draws.

### The realm is the server's text and is drawn as the server's

Carried separately from every sentence this browser wrote, stripped of control
characters — a realm containing a newline can draw itself as two lines and make
the second look like ours — and capped at 120 characters so a server cannot push
the buttons off the panel with a paragraph.

The panel draws it indented behind a quotation rule, under the label *"The
server calls this area"*. Its markup is **shown, not interpreted**. A realm
interpolated into one of our sentences would be a stranger writing in the
browser's voice, which is the defect ADR-0089 exists to prevent for `alert()`.

### Return signs in, and that is a deliberate departure from ADR-0056

`SitePermissionSheet` refuses a default action, because a page chose the moment
and a Return already in flight would land on a camera. This panel is the answer
to an address somebody typed, the caret is in the field, and every password box
anybody has ever used submits on Return. Refusing it here would be applying a
rule past its reason, against AGENTS.md's own instruction that a shortcut
already in the fingers should do what the fingers expect. Nothing is granted by
pressing it: the worst case is a wrong password and a second panel.

## Consequences

**What hurts:**

- **A second place credentials live, again.** ADR-0064 already booked the cost
  of zer0 keeping passwords itself; this widens it to HTTP auth. There is still
  no import, no export and no sync.
- **A proxy sign-in is asked for on every launch**, because nothing is written
  down for one and there is nowhere honest to put it.
- **An unencrypted intranet login is never remembered**, so a router admin page
  is retyped every time. Correct, and it will read as a missing feature.
- **Three failures and the panel stops coming back**, which means somebody who
  mistypes slowly loses the navigation and has to reload. A limit that is high
  enough to never annoy anybody is not a limit.
- **A background tab is refused silently.** A page reloading on a timer behind a
  realm simply does not load, with nothing on screen saying why until it is
  brought to the front.
- **The panel is one question at a time**, so a page with several protected
  subresources gets one asked and the rest refused. A queue would be worse; this
  is still a page that half-loads.
- **NTLM and Negotiate collect a username and a password**, which is the right
  shape for the fallback and is not integrated Windows authentication. Somebody
  on a domain will expect single sign-on and will not get it.
- **The realm is drawn even when it is nonsense**, because it is what the server
  said. A server sending a paragraph gets 120 characters of paragraph.

**What we get:**

- A browser somebody can use against a staging server, which it was not before.
- A 401 that is a question rather than a blank page.
- The one guarantee that matters holds at the write: no password can reach a
  log, a file or the core, because nothing there can hold one.
- Two identities on one protected host, which is this product's premise.
- All of the rules — who is asked, when, and what may be kept — are testable
  without a window and port to Linux unchanged.

## How this regresses

**"The page went blank and never loaded."** The most likely regression, and the
one with no visible cause: somebody returns early from a branch of the delegate
or of `gate` without emitting an answer. There is no error, no timeout and
nothing on screen. `a_challenge_nobody_is_asked_about_is_still_answered` asserts
the command for the silent refusals, `closing_a_tab_answers_the_server_it_was_being_asked_by`
covers the tab that goes away mid-question, and `cancellingStillAnswers` holds
the shell end.

**"It signed me in without asking."** `gate` grows a convenience path — most
plausibly "if we have a saved login for this origin, just use it", which reads as
an obvious improvement and is the whole feature undone.
`nothing_here_can_produce_a_credential_on_its_own` reads the module's own source
and fails on the appearance of a credential-producing answer anywhere in it.

**"A password box appeared over the page I was reading."** The visibility check
is dropped because it looks like defensive programming.
`a_page_you_are_not_looking_at_is_refused_without_a_panel`.

**"It kept asking and I typed my real password to make it stop."**
`MAX_FAILURES` is raised or removed, most plausibly by somebody who hit the
limit while testing. `a_server_that_keeps_saying_no_stops_being_asked_about`
asserts both ends: that it asks up to the limit, and that it stops after.

**"My password went out in the clear and zer0 saved it."** `may_remember` is
simplified to `!is_proxy && records` during a cleanup that finds `secure`
redundant. `a_password_going_out_in_the_clear_is_said_so_and_never_offered_to_be_kept`
and `a_loopback_sign_in_is_neither_warned_about_nor_refused_a_keychain_item`
are the pair, and the second is what stops the fix being "refuse all http".

**"My private space remembered a login."** `records_to_disk` stops being asked
through the one door ADR-0023 named.
`an_ephemeral_space_is_never_offered_the_chance_to_write_one_down`.

**"The server put its own words in zer0's voice."** The realm is interpolated
into the title, because the sentence reads better with it in.
`the_servers_realm_is_carried_apart_from_every_sentence_we_wrote` asserts the
absence from all three of our strings, and `realmIsNeverOurs` reads the panel's
source for the spellings that would do it in the view instead.

**"A password turned up in a log."** A `print` for debugging, never removed.
`noPasswordEscapes` reads both files. It matches on a word boundary, because the
first version matched `print(` inside `fingerprint(of:)` and failed on code that
records nothing — a rule that cries wolf is a rule the next person deletes.

**And the one with no lock:** nothing asserts that the panel's *field* has focus
when it opens. It is `.onAppear { focus = .username }`, it is the difference
between a keyboard question and a mouse one, and a refactor that moves the
`@FocusState` would break it silently. Declared debt.

## When to revisit

- **If Negotiate or NTLM turns out to matter to somebody on a domain.** What
  they want is single sign-on against the system's credentials, which is a
  different mechanism and a different decision, not a better panel.
- **When there is a signing identity.** ADR-0064's revisit conditions all apply
  here unchanged, and an external password manager would supply this panel too.
- **If the one-at-a-time rule breaks a real site.** The answer is not a queue;
  it is to ask once per protection space and reuse the answer for the rest of
  that navigation, which is a decision about scope rather than about stacking.
- **If somebody wants a saved HTTP-auth login offered rather than retyped.**
  Filling this panel from the Keychain is not what ADR-0064 refused — that ADR
  is about pages, and this is our own panel — but "offered" and "filled
  automatically" are different, and only the first is safe here.
- **When a Linux host is attempted.** `webkit2gtk` signals this through
  `authenticate` with a `WebKitAuthenticationRequest`, which is a different
  shape; the core's half ports unchanged and whatever replaces
  `AuthChallengeLedger` has to keep "exactly one answer per challenge" true.
