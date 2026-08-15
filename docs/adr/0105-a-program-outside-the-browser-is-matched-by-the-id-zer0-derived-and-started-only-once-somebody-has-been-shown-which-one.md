# ADR-0105: A program outside the browser is matched by the id zer0 derived, and started only once somebody has been shown which one

- **Status:** Accepted
- **Date:** 2026-08-11
- **Lock:** `crates/zer0-core/src/native_messaging/host_tests.rs::a_registration_that_lists_somebody_else_refuses_this_extension`, `crates/zer0-core/src/native_messaging/host_tests.rs::a_wildcard_origin_authorises_nobody`, `crates/zer0-core/src/native_messaging/host_tests.rs::nothing_but_a_whole_chrome_extension_origin_is_an_id`, `crates/zer0-core/src/native_messaging/host_tests.rs::our_own_directory_is_read_before_anybody_elses`, `crates/zer0-core/src/native_messaging/host_tests.rs::a_refusal_from_the_first_registration_is_not_shopped_around`, `crates/zer0-core/src/native_messaging/host_tests.rs::an_application_id_that_is_not_a_name_never_becomes_a_path`, `crates/zer0-core/src/native_messaging/host_tests.rs::a_program_that_is_not_named_absolutely_is_refused`, `crates/zer0-core/src/native_messaging/host_tests.rs::a_program_that_is_a_link_to_something_else_is_refused`, `crates/zer0-core/src/native_messaging/host_tests.rs::a_transport_that_is_not_stdio_is_refused_rather_than_guessed_at`, `crates/zer0-core/src/native_messaging/host_tests.rs::nothing_the_registration_says_about_itself_is_carried_out_of_here`, `crates/zer0-core/src/native_messaging/host_tests.rs::an_extension_that_was_not_granted_native_messaging_starts_nothing`, `crates/zer0-core/src/native_messaging/host_tests.rs::a_program_somebody_refused_is_refused_rather_than_asked_about_again`, `crates/zer0-core/src/native_messaging/host_tests.rs::an_answer_about_one_program_does_not_travel_to_another`, `crates/zer0-core/src/native_messaging/host_tests.rs::an_extensions_own_name_cannot_take_over_the_question`, `crates/zer0-core/src/native_messaging/wire_tests.rs::the_length_is_little_endian_and_not_big_endian`, `crates/zer0-core/src/native_messaging/wire_tests.rs::a_length_beyond_the_cap_ends_the_connection_rather_than_being_buffered`, `crates/zer0-core/src/native_messaging/wire_tests.rs::a_body_that_is_not_json_is_refused_rather_than_skipped`, `crates/zer0-core/src/native_messaging/ledger.rs::a_refusal_is_a_recorded_answer_and_not_an_absence`, `crates/zer0-core/src/store_tests.rs::an_answer_about_starting_a_program_survives_a_relaunch`, `apple/Tests/Zer0ShellTests/NativeMessagingTests.swift::NativeMessagingGateTests/aRefusalStartsNothingAndSaysWhy`, `apple/Tests/Zer0ShellTests/NativeMessagingTests.swift::NativeMessagingGateTests/aProgramNobodyHasBeenAskedAboutDoesNotStartYet`, `apple/Tests/Zer0ShellTests/NativeMessagingTests.swift::NativeMessagingGateTests/twoRequestsForOneProgramRaiseOneQuestionAndBothAreAnswered`, `apple/Tests/Zer0ShellTests/NativeMessagingTests.swift::NativeMessagingConversationTests/aProgramThatDiesEndsTheConversationAndSaysSo`, `apple/Tests/Zer0ShellTests/NativeMessagingTests.swift::NativeMessagingConversationTests/stoppingEverythingClosesEveryProgram`, `apple/Tests/Zer0ShellTests/NativeMessagingTests.swift::NativeHostFramingTests/aRealPipeRoundTripsAMessage`, `apple/Tests/Zer0ShellTests/NativeMessagingTests.swift::NativeHostRowTests/theProgramIsNamedRatherThanCounted`

## Context

ADR-0072 measured 1Password's extension asking for a native messaging host on
the first press of its button, twice, both times the port form:

```
connectUsingMessagePort -> com.1password.1password
connectUsingMessagePort -> com.1password.1password7
```

and said the feature was worth having and would not unlock that extension,
because 1Password's helper refused zer0 by identity. **That second half is now
wrong and this ADR is where it stops being repeated.** The refusal was a signing
flag: the bundle was `Signature=adhoc`, `TeamIdentifier=not set`. Signed with a
real identity, zer0 is enrolled — `browsers.other-trusted-apps` in 1Password's
own settings carries `com.thezer0.zer0`, the path
`/Users/avelino/Applications/Zer0.app`, and a `SecRequirement` pinned to Team ID
`24X5CQGA86`. Three agents concluded that link was a commercial dead end. It was
a flag.

What is left is ours: **zer0 implements neither of the two
`WKWebExtensionControllerDelegate` methods**, so every request goes nowhere and
1Password opens its own `#/page/migration` while the popup spins.

### What is on this machine, measured

Registrations exist for Chrome and three of its channels, Chromium, four Edges,
two Vivaldis, Brave, Opera, Arc, Orion and Mozilla. Every 1Password one is dated
29 July, the day it was installed. **None exists for zer0, and none can**:
1Password writes for a list of browsers compiled before this one existed, and
enrolling zer0 as a trusted app did not add one.

Chrome's copy, which is the shape being read:

```json
{ "name": "com.1password.1password",
  "description": "1Password BrowserSupport",
  "path": "/Applications/1Password.app/Contents/Library/LoginItems/…/1Password-BrowserSupport",
  "type": "stdio",
  "allowed_origins": ["chrome-extension://aeblfdkhhhdcdjpifhhbdiojplfjncoa/", …] }
```

Firefox's copy, in `Mozilla/NativeMessagingHosts`, carries `allowed_extensions`
with Firefox add-on ids instead.

### And the helper says how it decides

Measured against `1Password-BrowserSupport` from a bundle signed with the real
identity, reading its own log:

```
browser_verification/apple.rs:20] Verifying browser "<the parent process's executable>"
```

It resolves **the process that started it**, and validates that. A bundle at a
path other than the enrolled one gets `parent browser was not valid` and
`UnsupportedBrowser`. That settles a question the design would otherwise have to
guess at: WebKit never spawns a native host — `connectUsingMessagePort` is a
callback *into this process* — so whatever starts the program is zer0's own
child either way, and there is no arrangement in which some other process could
be the one inspected.

## Decision

**Native messaging is implemented, and every road to a process goes through one
function in the core that answers three questions in a fixed order: does this
extension hold the permission, does a registration name a program and list this
extension, and has somebody been shown that program and said yes.**

`native_messaging::outcome` is that function. `Start`, `Ask` and `Refused` are
the only three things it can answer, and the shell has no other way to learn a
path.

### The identity compared is the one zer0 derived, and it cannot be chosen

`allowed_origins` authorises by Chrome Web Store id. An extension's origin here
is `webkit-extension://<uuid>` and WebKit mints that uuid per launch, so no
stable origin of ours could ever appear in anybody's registration and there is
nothing to compare origins against.

What is compared is **the id derived from the package's signing key at
install**. `ext::crx::parse` refuses a package whose declared id is not the
first 16 bytes of the SHA-256 of a public key the package carries a proof for,
and `install_extension` names the directory after that verified id — so
claiming 1Password's id means finding a key whose digest collides with
1Password's over 128 bits. Locked already, by
`crx.rs::a_package_claiming_someone_elses_id_is_rejected`.

**The match is structural rather than careful.** `ExtensionId` is a newtype
whose only constructor takes exactly 32 characters drawn from `a`..`p`, and
`allowed_origins` is parsed into a `Vec<ExtensionId>`. A wildcard, a prefix, a
substring and an empty string have **no representation**, so "any extension may
talk to any host" is not a state this code can be simplified into.
`chrome-extension://*/` is not an id, is dropped, and a list with nothing
readable left in it authorises nobody. Firefox's `allowed_extensions` is a
different key and is never read as this one.

### Which directories are read, and the argument

**Ours first, then eight browsers that speak Chrome's dialect of this file.**

The case for reading only our own is real and it is ADR-0072's own note:
running a program another browser registered is that browser's answer, not
ours. The case against it is the measurement above — no installer has ever
written for zer0 and none will — which makes "ours only" a feature that never
runs for anybody, ever.

What resolves it is that **a borrowed registration is not the consent; the
person's answer is.** So both are read, and the thing that makes that safe is
the third gate below rather than the directory list. Ours is read first so that
anything which ever does register for zer0 wins.

**The search stops at the first directory holding a file with that name**,
including when that file says no. A second directory's registration is a
different answer to the same question, and carrying on because the first one
refused is shopping for a yes.

**Firefox's directory is deliberately absent.** Its files can only ever carry
Firefox ids, so reading it could produce nothing but refusals.

### The registration and the program it names are hostile input

Every one of these is a refusal, and none is a repair (ADR-0024):

| What | What happens |
| --- | --- |
| the application id is not `[a-z0-9._]+`, or has `..`, or a leading or trailing dot | refused before any path is built — this is what stops `connectNative("../../../../etc/passwd")` |
| the file is over 1 MiB | refused on its size, before it is read |
| not JSON, or JSON that is not an object | refused |
| no `path`, or `type` is not `stdio` | refused; Chrome has never defined a second transport and guessing at one is inventing a protocol |
| `path` is relative, or has a `..` component | refused. Nothing is normalised: the path is what a person is shown |
| `path` names nothing | refused |
| `path` names a **symbolic link** | refused. The program that would run is not the program named, and the name is the whole of what a person was shown |
| `path` is not an executable file | refused |
| the origin list does not contain this extension's derived id | refused |

**Nothing the registration says about itself reaches a screen.** A manifest
carries a `description`, it reads well on a sheet, and it is a sentence written
by whoever wrote the file — shown on the one screen where somebody decides
whether to run a program. `"1Password BrowserSupport"` and `"System update,
click Allow to continue"` are the same kind of string. `ResolvedHost` has no
field for it.

### Which program is said, because the permission could not have said it

`nativeMessaging` reads *"Talk to programs installed on this Mac"* and is
Critical (ADR-0028). That was the most that could honestly be said at install
time: the registration naming the program belongs to whatever installed the
desktop application and may not exist yet.

So the same grant is asked once more at the one moment its object exists, and
the sheet names the program, in mono, selectable, above the prose — plus the
sentence that earns the second question: *"'com.1password.1password' is
registered with Google Chrome, not with zer0."*

**The answer is keyed on the program, not on the application id.** That is not
tidiness: 1Password asks for two ids on one press and both resolve to one
program, so a ledger keyed on the id would put two sheets on screen for one
decision. It also means a registration later repointed at a different binary is
a new question.

Three answers, and they are different:

- **Allow** — recorded, survives a relaunch, and the program starts.
- **Don't Allow** — recorded, survives a relaunch. A refusal is stored rather
  than inferred from absence, because absence has to keep meaning *nobody was
  asked* (ADR-0028's argument, unchanged).
- **Escape** — refuses *this* request and writes nothing, so the next press
  asks again. It exists because the request is held open while the sheet is up:
  a sheet that could be dismissed without answering would be an extension
  waiting for ever.

The Extensions screen names the programs afterwards, in full rather than
counted — "may start 1 program" is true and the fact somebody needs is which
one (ADR-0018).

### Both delegate methods, and a child that cannot take the browser with it

`connectUsingMessagePort` and `sendMessage:toApplicationWithIdentifier:` are
both implemented. The one-shot form is what an extension reaches for when it
wants a single fact, and an unimplemented delegate is a promise that never
settles rather than a refusal anybody can read.

The framing — 4-byte little-endian length, then JSON — is in the core, like
`mcp_wire`, because it is Chrome's and not Apple's. A length past 16 MiB ends
the connection before a byte of the body is kept; a body that is not JSON ends
it too, because this format has no resynchronising mark and a reader that
carried on would hand the extension messages assembled out of the middle of
others. A one-shot exchange has a 30-second deadline. A program that exits is
quoted from its own stderr. Everything is closed when the browser quits, because
a child that outlives its parent is a program nothing will ever stop.

`McpHost`'s `StdioLink` was read and not reused: the framing differs, so sharing
it would mean a branch in the middle of a byte reassembler. What was taken from
it is the shape of the fix it needed — `DispatchQueue.main.async` inside
`readabilityHandler` rather than `MainActor.assumeIsolated`, which traps, and
rather than an unstructured `Task`, which loses the ordering a byte stream
depends on.

## Consequences

**What this costs:**

- **zer0 will start a program another browser registered.** Stated plainly
  because it is the part somebody will object to. What stands between that and
  a person's machine is a sheet naming the path, and a sheet is a sheet — people
  click through them. The mitigation is that the path is the loudest thing on
  it and that neither button is prominent or bound to Return, which is the same
  set of levers `SitePermissionSheet` has and no more.
- **A symlinked program is refused, and Chrome allows one.** A host installed
  through a package manager that links its binaries will not work here and the
  refusal will read as a bug in zer0. It is deliberate and it is the only way
  "the path you were shown is the program that ran" stays true.
- **The registration list is a snapshot and it dates**, exactly like ADR-0100's
  table and ADR-0084's `ENGINE_PROVIDES`. A browser that appears next year is
  one this file does not read, silently.
- **`installed_extensions` reads the directory name back and does not
  re-derive it.** So the identity this whole decision rests on is verified once,
  at install, against the signature material — and anybody who can write inside
  this browser's own profile can put code under a name the check would have
  refused. That is the same attacker who can rewrite the session database, and
  it is **declared debt** rather than something closed here. Re-deriving on load
  means keeping the CRX, which ADR-0100 already refused for 361 MB per package.
- **The sheet interrupts a gesture.** The person pressed an extension's button
  and got a question about a binary. There is no better moment and there is no
  moment that is not an interruption.
- **A second grant for one permission.** Somebody reading only the consent sheet
  will believe `nativeMessaging` was the whole answer, and it is not.
- **Nothing tells an extension why.** A refusal reaches JavaScript as an error
  on the port; the sentence explaining it is on the sheet or nowhere.

**What we get:**

- The last link between 1Password and this browser is built, and it is ours
  rather than a commercial conversation.
- One function decides, so the permission cannot go unchecked in one path, the
  registration unread in another and the answer unasked in a third.
- The framing, the limits, the refusals and the words are all testable without
  a window, and `webkit2gtk` inherits every one of them.

## How this regresses

**"Any extension on my machine can talk to my password manager."** The origin
parser is loosened — most plausibly to `contains` or to a prefix match, which
reads as robustness — or `chrome-extension://*/` acquires a meaning.
`a_wildcard_origin_authorises_nobody` and
`nothing_but_a_whole_chrome_extension_origin_is_an_id` are the two fences, and
the second is the one that survives a refactor of the first: it names thirteen
shapes, every one of which a looser reader lets through.

**"An extension read a file outside every directory zer0 meant to look in."**
The application id goes onto a path without being checked, because it "comes
from WebKit". It comes from the extension's own JavaScript.
`an_application_id_that_is_not_a_name_never_becomes_a_path` is the lock and it
names `../../../../etc/passwd`.

**"It ran something I never agreed to."** Either the ledger check is dropped as
redundant "because the permission was granted", or a refusal starts reading as
"not asked". `an_extension_that_was_not_granted_native_messaging_starts_nothing`
and `a_program_somebody_refused_is_refused_rather_than_asked_about_again` hold
the two halves in the core;
`aProgramNobodyHasBeenAskedAboutDoesNotStartYet` holds it in the shell, and it
is the one worth breaking on purpose — make `gate` treat `.ask` as `.start` and
it goes red while everything about the sheet still looks right.

**"It asks me every single time."** The refusal stops being written down, or the
answer starts being keyed on the application id again.
`a_refusal_is_a_recorded_answer_and_not_an_absence`,
`an_answer_about_starting_a_program_survives_a_relaunch` and
`twoRequestsForOneProgramRaiseOneQuestionAndBothAreAnswered` are the three, from
three different sides.

**"A registration in Chrome's folder overrode the one I made for zer0."** The
directory order is sorted, or made a set. `our_own_directory_is_read_before_anybody_elses`
pins it, and `a_refusal_from_the_first_registration_is_not_shopped_around` is
what stops the fix for a missing host being "keep looking".

**"The sheet said one thing and something else ran."** A symlink is followed
because refusing one looked over-cautious, or the path is normalised on the way
in. `a_program_that_is_a_link_to_something_else_is_refused` and
`a_program_that_is_not_named_absolutely_is_refused` are the pair.

**"A sheet appeared telling me to click Allow."** The registration's
`description` is put on the sheet, because it is friendlier than a path.
`nothing_the_registration_says_about_itself_is_carried_out_of_here` asserts a
crafted one never leaves the reader, and
`an_extensions_own_name_cannot_take_over_the_question` covers the other string
on that sheet somebody else wrote.

**"The browser used four gigabytes and died."** The cap is removed, or moved to
the shell where a second host will forget it.
`a_length_beyond_the_cap_ends_the_connection_rather_than_being_buffered` and
`aProgramThatDiesEndsTheConversationAndSaysSo` cover the two ways a program
misbehaves; `stoppingEverythingClosesEveryProgram` covers the third, which is
outliving the browser.

**"Nothing works and every instrument says it should."** The length is written
big-endian, or the reader is rewritten in the shell. Small messages on this
machine hide it, because every other byte is zero.
`the_length_is_little_endian_and_not_big_endian` uses a 400-byte body for
exactly that reason, and `aRealPipeRoundTripsAMessage` is the one that proves
the bytes reach a real process and come back.

**And the one no test catches:** somebody reads this and adds a browser to the
directory list because a host they want is registered there. Nothing goes red,
the list is a judgement, and the failure it produces is a program started from a
directory nobody argued about.

## When to revisit

- **If a host that matters ships its binary as a symlink.** The exit condition
  is one report. The replacement is not to follow the link silently — it is to
  show both the link and its target on the sheet, which is a sentence and a
  design.
- **If anything ever writes a registration for zer0.** Then the argument for
  reading other browsers' directories weakens, and the honest move is to prefer
  ours harder rather than to stop reading theirs: an application whose installer
  knows about zer0 is exactly the case "ours first" was built for.
- **When a second grant per permission turns out to be one too many.** If people
  are clicking through this sheet without reading it, the answer is not to
  remove it but to stop asking about programs registered *for zer0*, which are
  the ones somebody deliberately set up.
- **If `WKWebExtension` ever spawns the host itself.** Everything in the core
  survives; `NativeMessagingHost` does not, and the identity the helper inspects
  would stop being ours.
- **When Linux is attempted.** The registrar list is a statement about where
  macOS browsers keep things; XDG paths are different and Firefox's directory
  becomes the common one rather than the excluded one. The framing, the limits,
  the refusals and the ledger cross unchanged.
