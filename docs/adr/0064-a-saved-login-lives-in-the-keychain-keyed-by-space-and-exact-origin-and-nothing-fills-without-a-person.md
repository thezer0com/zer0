# ADR-0064: A saved login lives in the Keychain, keyed by Space and exact origin, and nothing fills without a person

- **Status:** Accepted
- **Date:** 2026-07-13
- **Lock:** `crates/zer0-core/src/passwords_tests.rs::a_lookalike_origin_is_offered_nothing`, `crates/zer0-core/src/passwords_tests.rs::a_field_nobody_can_see_is_filled_with_nothing`, `crates/zer0-core/src/passwords_tests.rs::an_ephemeral_space_writes_no_password_down`, `crates/zer0-core/src/passwords_tests.rs::an_ephemeral_space_cannot_be_given_a_keychain_scope_to_write_into`, `crates/zer0-core/src/passwords_tests.rs::a_cross_origin_frame_is_refused_even_when_the_frame_is_genuine`, `crates/zer0-core/src/passwords_tests.rs::an_idn_lookalike_does_not_borrow_the_latin_spellings_credential`, `crates/zer0-core/src/passwords_tests.rs::every_origin_the_core_produces_can_be_taken_back_apart`, `crates/zer0-core/src/passwords_tests.rs::no_type_in_this_module_can_hold_a_password`, `apple/Tests/Zer0ShellTests/PasswordTests.swift::PasswordTests/aPageCannotAskToBeFilled`, `apple/Tests/Zer0ShellTests/PasswordTests.swift::PasswordTests/twoSpacesHoldTwoLogins`, `apple/Tests/Zer0ShellTests/PasswordTests.swift::PasswordTests/anEphemeralSpaceReadsNothing`, `apple/Tests/Zer0ShellTests/PasswordTests.swift::PasswordTests/noPasswordIsInterpolatedIntoScriptSource`, `apple/Tests/Zer0ShellTests/PasswordTests.swift::PasswordTests/theOriginsComeFromWebKit`

## Context

zer0 had no password handling at all, which is plausibly the largest single
thing standing between it and being somebody's only browser. A browser where you
retype your password at every login loses to Chrome on the second login,
whatever else it does well.

The obvious answer — "just defer to 1Password, the owner already uses it" — is
the right instinct and it is **closed on this platform today**. That is a
finding, and it changed the shape of what got built, so it is recorded before
the decision rather than after it. Everything below was read out of the macOS
26.5 SDK headers or measured on the machine, not recalled.

### What the platform offers a browser, measured

**WebKit offers nothing.** Grepping every public header in
`WebKit.framework` for credential, password, autofill and auth turns up exactly
one thing: `didReceiveAuthenticationChallenge`, which is HTTP auth, not form
fill. There is no `WKWebView` API for saved passwords. Safari's autofill is
Safari's, built on SPI that is not in the SDK.

Loading a login form into a real `WKWebView` and asking the DOM confirms it from
the other side:

| Asked | Answer |
| --- | --- |
| `CSS.supports("selector(:-webkit-autofill)")` | `true` — the selector parses |
| `password.matches(":-webkit-autofill")` | `false` — nothing ever fills |
| `password.value` after load | `""` |
| `window.PasswordCredential` | `undefined` |
| `window.PublicKeyCredential` | `defined` |
| `password.autocomplete` | `"current-password"` — reflected correctly |

So the engine gives us the *metadata* to drive an autofill and none of the
*mechanism*. That is the gap this ADR fills.

**AuthenticationServices offers a browser passkeys, and passwords only to
providers.**

- `ASCredentialIdentityStore` and `ASCredentialProviderViewController` are the
  API for *being* 1Password, not for *asking* it. The read method's own
  documentation says "saved in the store **for your extension**".
- `ASAuthorizationPasswordRequest` (macOS 10.15+) returns credentials for the
  calling app's own associated domains — it needs a `webcredentials:`
  entitlement, a Team ID and an `apple-app-site-association` file hosted on each
  domain. It is an app-login API. A browser cannot use it to reach the passwords
  somebody saved for the sites they visit.
- `ASCredentialDataManager.save(password:for:title:anchor:)` — the new
  browser-hands-a-password-to-the-user's-provider call — is
  `@available(macOS, unavailable)`. So are `ASSavePasswordRequest` and
  `ASGeneratePasswordsRequest`, both `API_UNAVAILABLE(macos)`, iOS 26.2 only.
- `ASAuthorizationWebBrowserPublicKeyCredentialManager` is real on macOS 13.3+
  and is the one browser-facing credential API — and it is **passkeys**, behind
  a restricted entitlement Apple grants to browsers case by case.

**Safari's saved passwords cannot be read.** Measured directly:

| Query | Result |
| --- | --- |
| internet passwords, file keychain | `errSecSuccess`, legacy items only |
| internet passwords, data-protection keychain | `errSecItemNotFound`, 0 items |
| access group `com.apple.safari.credentials` | **`errSecMissingEntitlement` (-34018)** |
| `SecItemAdd` to the data-protection keychain | **`errSecMissingEntitlement` (-34018)** |
| `SecItemAdd` to the file keychain | `errSecSuccess` |

The last two rows are the ones that shaped the design: an unsigned binary — which
is how zer0 is built and run every day — can write to the **file-based login
keychain and nowhere else**. That is exactly the constraint `SecretStore.swift`
already records for API keys, now measured a second time for this.

There *is* a bridge to Apple's own passwords, and it is instructive that it is
not an API:
`/System/Cryptexes/App/.../PasswordManagerBrowserExtensionHelper.app`, reachable
only by Chrome-style native messaging from two hard-coded extension IDs, holding
`com.apple.authentication-services.access-credential-identities` and
`com.apple.private.Safari.PasswordBreachHelper`, with a `LaunchConstraintVerifier`
inside it. Apple ships iCloud Passwords to Chrome as an extension plus a
privileged helper, because the API to do it properly does not exist.

**Extension-based managers cannot reach their apps from inside zer0.** Two
independent blocks, either sufficient:

1. `WKWebExtensionPermissionNativeMessaging` is documented as "send messages to
   **the App Extension bundle**". That is not Chrome's native messaging — no
   host manifest, no helper process. 1Password's extension talks to
   `1Password-BrowserSupport` through a Chrome-style manifest, and that
   transport does not exist in `WKWebExtension`.
2. Even with the transport, 1Password refuses. Its helper binary carries these
   error variants: `BrowserVerificationFailed`, `UnsupportedBrowser`,
   `InvalidBrowserMapping`, `UnknownBrowser`, `InvalidBrowserSignature`,
   `NotSigned`, `MissingRequirementInfo`, `CodeSignatureHasMatchingTeamId`,
   `NotInApplicationsDirectory`, `AppBundleIsSymlinked`. An unsigned zer0 built
   into `apple/.build/` fails four of those independently.

## Decision

**zer0 saves passwords itself, in the Keychain it already uses, and it does not
become a vault.**

### Why not defer to a password manager, given the owner uses one

Because deferring is not currently a thing that can be built. It is gated on a
Developer ID signature, notarisation, *and* a third party adding zer0 to a
browser allowlist we do not control. Writing a bridge today produces code that
returns `NotSigned` on every call.

That does not make it the wrong destination — it is the right one, and this
decision is arranged so it stays reachable. What may be offered for an origin is
a core question with a core answer; where the value comes from is a shell
detail. When signing lands, an external provider becomes a second
implementation behind `PasswordStore`, and nothing in `passwords.rs` changes.

### Why not defer to the system's saved passwords

Not a judgement call. `errSecMissingEntitlement`.

### The Keychain is the store, and there is no second index

An internet-password item is *already* keyed by server, port, protocol and
account. So there is no table in `session.sqlite`, no field on
`StorableSession`, no schema bump, and nothing to filter on the way to disk.

This is not laziness about persistence, it is the ADR-0023 argument applied
before the fact: an index in `session.sqlite` would be **a plaintext list of
every site you hold an account with**, in a file this project already treats as
readable by anyone holding the disk. The passwords would be safe and the list
would not be, and the list is most of the privacy loss. Two stores would also be
two stores that can disagree — the failure `SecretStore.swift` already records
once, where two Keychain implementations under different service names meant a
key stored successfully and never found again.

`kSecUseDataProtectionKeychain` stays **off**, for the reason measured above.

### A Space is an identity, so a Space is part of the key

`kSecAttrSecurityDomain` carries `zer0.space.<data_store_id>`, and it is part of
an internet-password item's primary key on macOS. So `github.com` in Work and
`github.com` in Personal are two items that **cannot** collide — not because
this code is careful, but because the platform's uniqueness rule says they are
different items. ADR-0007 made a Space a cookie jar and a cookie jar an
identity; this is that premise enforced one level below us.

The ephemeral half is structural rather than checked. `keychain_scope` returns
`None` for a space that records nothing, and without that string the shell has
no query to build and no value it could reasonably substitute. A private Space
does not save a password, and it does not read one either — it never reaches the
store at all.

### An origin is matched exactly, and this is the decision most likely to be "improved"

ADR-0026 matches a routing rule against a host **or any subdomain of it**, and
that is right there: `gist.github.com` belonging to the same Space as
`github.com` is what somebody writing the rule meant.

It is wrong here. A routing mistake opens a tab in the wrong Space; a credential
mistake hands a password to somebody else. Subdomain matching is only safe with
a public suffix list — without one, a rule for `github.io` matches
`anybody.github.io`, and `s3.amazonaws.com`, `blogspot.com` and every other host
where strangers are handed a subdomain behave the same way. zer0 ships no public
suffix list, so the honest boundary is the exact origin: scheme, host and port,
canonicalised through the same `canonical_origin` the camera ledger uses, so an
internationalised domain is keyed by its punycode and a Cyrillic `аpple.com`
cannot borrow the Latin one's login.

### Nothing fills without a person, and the type system says so

The claim has to be stated precisely, because the loose version of it is false.
**A page can make zer0 look. It cannot make zer0 fill.**

Looking is triggered by `focusin` on a password field, and a page can call
`field.focus()` itself — so the caret is *not* a trusted gesture and is not
treated as one. What a page gets for forcing it is a `PasswordPrompt` in Swift
state listing which usernames match. That never goes back into the document, so
the page learns nothing it did not already know.

Filling is a different path and the page is not on it.
`PasswordChannel.message(named:)` accepts exactly `caret` and `submitted`, both
*reports*; there is no `fill` verb in either direction. The script lives in a
content world of its own, and this was measured rather than assumed:
`typeof window.__zer0Passwords` is `undefined` from `WKContentWorld.page`. A
value is put into a field only when somebody picks an entry out of zer0's own
interface, and `fill_verdict` is re-asked at that moment against the geometry
as it is *then* — because a form that was visible when the caret landed in it
is exactly what a page would swap for a hidden one.

Saving pulls rather than receives, for the same reason. The `submitted` message
carries no values; the shell reads them out of the DOM itself through
`callAsyncJavaScript` in the isolated world. If the values rode in on the
message, a page could invent a submission with an account name of its choosing
and get zer0 to offer to overwrite a real saved login for its own origin.

### The hidden-field attack, and how each shape of it dies

`usable()` is the second, independent condition, and it is in the core so it can
be tested without a browser. Every clause is separately sufficient, and they are
separate clauses rather than one score so that two of them cannot pass by being
individually mild:

| Shape | Clause |
| --- | --- |
| `display: none` reported as a zero box | `width`/`height` minimums |
| a one-pixel field | same |
| `opacity: 0`, or `0.001` | `MIN_OPACITY`, with ancestors multiplied in |
| a computed style that produced `NaN` | `is_nan()`, spelled out — `NaN < 0.1` is `false` |
| `left: -9999px` | viewport intersection |
| covered by an overlay (clickjacking) | `topmost`, via `elementFromPoint` |
| `disabled` / `readonly` | refused outright |

The page reports **measurements, never judgements**. A `visible: bool` computed
in JavaScript would put the decision inside the page's own document, which is
the one place it must not be, and would be untestable without a browser.

Each of those shapes was then built as a real form and loaded into a real
`WKWebView`, because reasoning about the numbers was not enough:

| Field | measured | refused by |
| --- | --- | --- |
| ordinary login | 240×32, opacity 1, topmost | — it fills |
| `width:1px;height:1px` | **14×8** | `MIN_WIDTH` |
| `opacity: 0` | opacity 0 | `MIN_OPACITY` |
| `opacity: 0` on an **ancestor** | effective opacity 0 | `MIN_OPACITY` |
| `position:absolute;left:-9999px` | x = −9999 | viewport intersection |
| covered by an overlay | topmost `false` | `topmost` |

The second row is why `MIN_WIDTH` is 24 rather than something smaller.
**A field styled `width: 1px` measures 14px**, because WebKit gives an `input`
an intrinsic minimum. A threshold picked by reasoning about the CSS — "nothing
real is under 8px" — would have let the textbook harvesting form straight
through, and no test written from the same reasoning would have caught it.

The isolation claim was measured the same way rather than assumed:
`typeof window.__zer0Passwords` evaluated in `WKContentWorld.page` is
`undefined`, while the same expression in `zer0.passwords` is `object`. The
page cannot reach the entry point that fills.

Both origins come from WebKit — `frameInfo.securityOrigin` for the frame and the
web view's committed URL for the page — and neither is ever read out of the
message body. A page that could name its own origin could name somebody else's.

### What happens on a phishing lookalike

**Nothing appears, and nothing is said.**

There is no warning, because we cannot prove `github.com.evil.tld` is a phishing
site — only that we have nothing saved for it. ADR-0018 says the interface
asserts only what it can back up, and "this looks like phishing" is not backed.

What *is* backed is the absence. Somebody who reaches a lookalike expecting
their usual one-key login instead sees an empty list, which is the strongest
honest signal available and costs nothing. The list also names the origin each
entry belongs to, so the mismatch is visible when it matters most.

### The password itself

No type in `zer0-core` has a field a password fits in, no call takes one and no
call returns one — the same guarantee ADR-0048 made for API keys, held by a test
that reads the module's own source. Everything crossing the FFI is a *decision*:
an origin to key by, a refusal to explain, a list of usernames.

`SavedPassword` in the shell is deliberately not `Codable`, not `Equatable` and
not `CustomStringConvertible`: each of those is a route to a log line, a crash
report or a test failure message. The fill goes through
`callAsyncJavaScript(arguments:)` rather than string interpolation, so the value
never becomes JavaScript source and never lands in anything recording what was
evaluated.

## Consequences

**What hurts:**

- **This is a second place credentials live, with its own migration story and
  its own breach surface.** Somebody who uses 1Password now has passwords in two
  places, and zer0 has no import, no export and no sync. That is the real cost
  of this decision and it is not softened.
- **No sync, on purpose, and therefore no answer for a second Mac.** ADR-0048's
  whole premise is a config that follows you; passwords deliberately do not.
  Somebody with two machines logs in twice.
- **A site that puts sign-in on a different origin in an iframe will not fill.**
  Refusing cross-origin frames is a real cost paid to a real attack, and this is
  the shape people will hit.
- **A `readonly` field is refused, and some real sites use one.** Setting
  `readonly` until focus is a known anti-autofill trick, and refusing it is the
  safe direction — but it will read as "zer0 does not work on this site".
- **Subdomains are separate logins.** `accounts.google.com` and
  `mail.google.com` are two entries. Correct, and it will feel like a bug.
- **Nothing is offered on `http://` except loopback**, so a router admin page or
  an intranet host gets no fill.
- **The Keychain prompts when the signature changes**, which is every rebuild of
  an unsigned app. A person clicks Always Allow, repeatedly, during development.
- **A password saved in one Space is invisible from another even when it is the
  same account.** That is the premise working, and it means saving twice.
- **Closing a Space destroys its logins with no undo**, matching what ADR-0007
  already does to the cookie jar, and it is just as final.

**What we get:**

- Logging in without retyping, which is the whole point.
- The one guarantee that matters holds at the write: no password can reach a
  file, a log or the core, because nothing there can hold one.
- Two identities on one site, which no mainstream browser does well and which is
  this product's premise.
- A private Space that saves nothing, enforced by an absent key rather than a
  remembered rule.
- A shape that does not have to be undone when signing lands: an external
  provider is another `PasswordStore`.

## How this regresses

**"My GitHub password got offered to a phishing site."** `matches` grows a
suffix rule, almost certainly by somebody making it consistent with
`routing.rs` — which is a real inconsistency, and the tidier-looking fix is the
catastrophic one. `a_lookalike_origin_is_offered_nothing` fails, and it asserts
`gist.github.com` alongside `github.com.evil.tld` precisely so that "just allow
subdomains" reddens rather than passing.

**"A site silently read my saved password."** The `topmost` or geometry clauses
get folded into one heuristic during a cleanup, or `!(x >= y)` gets tidied into
`x < y` and `NaN` starts passing. `a_field_nobody_can_see_is_filled_with_nothing`
covers nine separate shapes and names each one in its failure message; both of
those edits redden it. The other half — a `fill` verb appearing on the message
channel — is `aPageCannotAskToBeFilled`, which asserts the *absence* of six
verbs rather than the presence of two, so a new one has to be added deliberately.

**"My private space remembered a login."** The `records_to_disk` question gets
answered in the shell instead of through the core, or `keychain_scope` grows a
fallback for the empty case. `an_ephemeral_space_writes_no_password_down` and
`an_ephemeral_space_cannot_be_given_a_keychain_scope_to_write_into` are the pair;
`anEphemeralSpaceReadsNothing` covers the read side by asserting the store is
never even asked.

**"Work and personal got mixed up."** `kSecAttrSecurityDomain` drops out of
`identity(fields:scope:username:)` — most plausibly during a refactor that finds
it redundant, since queries "work" without it. They work by returning the wrong
Space's login. `twoSpacesHoldTwoLogins` fails.

**"A password turned up in a log."** String interpolation replaces
`callAsyncJavaScript(arguments:)`, or `SavedPassword` gains `Codable` because
something wanted to cache it. `noPasswordIsInterpolatedIntoScriptSource` reads
the source and fails.

**"A page filled itself with somebody else's credential."** The origin starts
being read from the message body — the obvious fix when `frameInfo` is awkward
in a subframe. `theOriginsComeFromWebKit` asserts the absence of four spellings
of that.

**And the one with no lock:** `every_origin_the_core_produces_can_be_taken_back_apart`
holds `canonical_origin` and `keychain_fields` together as inverses, but only
across the hosts it happens to list. A canonicalisation change that breaks a
shape not in that list would store under one key and look under another —
silent, and it looks like "the password just did not save". Declared debt.

## When to revisit

- **The day there is a signing identity and notarisation.** Three things unlock
  at once and all three should be taken: `kSecUseDataProtectionKeychain` on, the
  web-browser passkey entitlement requested, and a real conversation with
  1Password about their browser allowlist. If deferring to an external manager
  becomes possible, it should become the default and this store should become
  the fallback — the reverse of today.
- **If `ASCredentialDataManager.save(password:)` ever loses its
  `@available(macOS, unavailable)`.** That is Apple building the handshake this
  ADR wants, and the day it lands on macOS the save path should go through it
  rather than through our own Keychain items.
- **When passkeys are worth having**, which is sooner than it looks — the
  browser-facing API already exists and is the only credential API Apple offers
  a browser. It is a different decision, not an extension of this one.
- **If the cross-origin-iframe refusal turns out to break sites people actually
  use.** The answer is not to relax it; it is to fill the sign-in origin
  directly when the person navigates there, which is a product decision of its
  own.
- **If somebody asks for import from 1Password or Chrome.** Today the honest
  answer is that there is no importer, and building one is a decision about
  becoming a vault that this ADR deliberately declined.
