# ADR-0113: A CRX that fails its signature does not install

- **Status:** Accepted
- **Date:** 2026-08-14
- **Lock:** `crates/zer0-core/src/ext/crx.rs::a_real_store_package_verifies_violentmonkey`, `crates/zer0-core/src/ext/crx.rs::a_real_store_package_verifies_dark_reader`, `crates/zer0-core/src/ext/crx.rs::a_real_signature_with_a_flipped_byte_refuses_the_package`, `crates/zer0-core/src/ext/crx.rs::a_real_header_laid_over_someone_elses_archive_is_refused`

## Context

Until now the CRX parser checked ids and nothing else. A package's declared id
had to be derivable from one of the public keys in its header, which stopped a
swapped response from delivering *another extension* under the id you asked
for — but the id check cannot tell a key from its holder, because public keys
are public. Anyone could build a header carrying the real author's key (copied
out of any genuine package, or off the store page), declare the real
extension's id, and put any ZIP behind it. Nothing verified that the builder
held the private key, so the forgery installed. The README said so plainly:
"Package signatures are not verified yet."

Two beliefs about the CRX3 format made this look harder than it is, and both
turned out to be wrong. The field named `sha256_with_rsa` is **not** RSA-PSS;
it is PKCS#1 v1.5 with SHA-256 — the name misleads and Chromium's
`crx_verifier.cc` is the authority. And the signed payload is **not** just the
`signed_header_data`; it is the domain separator `"CRX3 SignedData\0"`, the
length of the signed header data as a little-endian `u32`, the signed header
data, and **the entire ZIP archive**. Both facts were measured against real
store packages (an RSA signature's recovered PKCS#1 block names its digest;
candidates were tried until the preimage matched) and then read off
Chromium's source to confirm this crate was implementing the format rather
than a guess at it. The second fact matters more than the first: it means a
signature binds the archive, so a genuine header laid over someone else's ZIP
fails verification. The one attack the old check could not stop is exactly the
one the signature kills.

## Decision

**`crx::parse` verifies every RSA and ECDSA proof in the header over
`"CRX3 SignedData\0" ‖ u32le(len) ‖ signed_header_data ‖ archive`, and a
package with any proof that does not verify — or with no signatures at all —
is refused with `CrxSignatureInvalid` and never installed.**

The rule lives inside `parse`, the one door every install already walks
through, so there is no code path that can obtain a `Crx` without the
signatures having been checked. This is the structural form of the guarantee:
a separate `verify` step beside `parse` would be a wish, one refactor away
from being skipped.

Three shape decisions inside that rule:

- **All proofs must verify, not some.** Chrome refuses a package if any proof
  fails, and no genuine store package has ever been observed carrying a broken
  proof — each carries two or three (Google's RSA publisher key, the author's
  RSA key, an ECDSA key). "At least one valid" would also keep forgers out,
  but it would accept packages Chrome refuses, and it is the shape a future
  "skip proofs we don't understand" request would find already half-built.
  Strict today is cheap; strict later is an argument.
- **One hash of the payload serves every proof.** The archive is hashed once
  (SHA-256 of a 20 MB Bitwarden costs about a hundred milliseconds) and each
  verifier is fed the digest: RSA verifies the digest inside a hand-built
  `DigestInfo`, ECDSA verifies it as a prehash. The `DigestInfo` prefix is
  spelled as nineteen constant bytes because the `rsa` crate's helper expects
  its own `sha2` version and ours is newer; the bytes are RFC 8017's either
  way, and the real-package tests would catch a wrong one.
- **The store's publisher proof is verified but not required.** A package
  signed only by its author installs. The gate this ADR builds is "the
  extension you asked for, unmodified", and the author's signature plus the
  id derivation delivers that; Chrome's publisher-key requirement answers a
  question ("did this pass through Google?") that is not the one zer0's
  install flow asks.

Two dependencies arrive with this: `rsa` (0.9) and `p256` (0.13), both
RustCrypto, both pure Rust, both behind the existing `ext` feature. No C
enters the tree, for the same reason the `comrak` entry in the manifest
argues: none belongs inside a browser.

## Consequences

**A forged package no longer installs, and neither does a modified one.** The
attack named in the context — real author's public key, real id, attacker's
ZIP — now fails twice over: the attacker cannot sign the payload (no private
key), and cannot transplant a header (the signature covers the archive).
`a_real_header_laid_over_someone_elses_archive_is_refused` holds the second
half with a real store package.

**Real packages install.** `testdata/` carries two complete CRXs pulled from
the store (Violentmonkey, 679 KB; Dark Reader, 839 KB) and two headers with
the archive cut off (1Password and Bitwarden, whose full packages are 17.8 MB
and 22.3 MB — too large to keep whole; the test names the regenerating URL).
The complete fixtures verify green; the truncated ones refuse, which is the
correct answer for a half a package.

**An author's own package still installs.** This is not a gate against the
*author*: anyone may sign a package with their own key, derive their own id,
and install it as their own extension. That was true before and stays true;
the change is that they can no longer install it as *someone else's*.

**The id check stays, in front of the signatures.** It is the cheap refusal
(al-N hashing versus hashing the archive) and the better error message, and it
carries the multi-key history recorded in `crx.rs`: a store package's id comes
from the author's key, which is not the first one in the header.

## How this regresses

**"Someone relaxes all-proofs-verify to any-proof-verifies."** The plausible
motive is a real extension that ships a proof this code cannot read — a new
key type, a new field. The lock tests catch the relaxation directly: comment
out the `verify_crx3_signatures` call and five tests go red, three of them
named in the Lock line above. What the tests do not catch is a *new* proof
kind being skipped "temporarily"; the argument against it is here, and the
revisit clause below is the door for doing it deliberately.

**"Someone swaps the payload layout and the verifier keeps verifying — against
the wrong bytes, or against a layout a future Chromium changed."** The
`"CRX3 SignedData\0"` separator, the little-endian length, and the archive
in the payload are each load-bearing; removing any one fails the two
real-package tests, which is the point of keeping real bytes in the
repository rather than only synthetic ones. Synthetic packages are built
through `test_support::signature_payload`, the public twin of the verifier's
layout, so the builder and the checker cannot quietly diverge.

**"The RSA `DigestInfo` constant is edited into something subtly wrong."** A
wrong prefix fails every RSA proof, which fails every real-package test — the
fixtures carry RSA proofs, so this cannot regress silently.

## When to revisit

- **When the store ships a proof kind this code does not read** (a new curve,
  a PSS variant, a CRX4). Then the strict-all rule above is the decision to
  reopen: widen the accepted kinds deliberately, with a real package in
  `testdata/` proving the new one, rather than by adding a skip.
- **When zer0 wants to require store provenance**, not just author
  authenticity. The publisher key (its SHA-256 is a constant in Chromium's
  verifier) is present in every store package and would slot into the same
  loop; that is a policy decision with an uninstallable tail (self-distributed
  extensions stop installing), so it earns its own ADR.
- **When measurements say the single archive hash is felt.** If install-time
  latency on a big package matters, the hash can overlap the download rather
  than follow it — an implementation change with no decision behind it, noted
  here only so nobody reads the current sequencing as one.
