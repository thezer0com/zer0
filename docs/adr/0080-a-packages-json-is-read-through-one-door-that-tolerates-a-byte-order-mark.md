# ADR-0080: A package's JSON is read through one door, which tolerates a byte-order mark

- **Status:** Accepted
- **Date:** 2026-08-10
- **Lock:** `crates/zer0-core/src/ext/ext_tests.rs::a_byte_order_mark_on_either_json_file_does_not_refuse_the_package`, `crates/zer0-core/src/ext/i18n.rs::a_message_bundle_that_starts_with_a_byte_order_mark_is_still_read`

## Context

Awesome Screenshot could not be installed at all. Not degraded, not missing a
feature — the install failed with
`UntranslatedName { key: "__MSG_extName__" }`, which is the refusal ADR-0028's
consent sheet requires when a package cannot say what it is.

The package is fine. It ships a UTF-8 byte-order mark at the front of all 54 of
its `_locales/<locale>/messages.json` files, measured on the untouched store
package. Chrome accepts that. `serde_json` does not — a leading `U+FEFF` is
`Error("expected value", line: 1, column: 1)` — so `read_messages` returned
`None`, the merged table came back empty, `substitute` found no `extName`, and
`localise` refused the package. Every step behaved correctly and the outcome was
that a working extension was unusable.

One package in the survey of 45 that use `_locales`, and the failure is total,
which is the shape that matters: this is not a cosmetic defect with a long tail,
it is a coin flip on whether an extension exists in this browser.

*Corrected in place, because the brief this work came from said otherwise:* the
manifest reader did **not** already handle a BOM. `read_manifest` read with
`fs::read_to_string` and handed the string straight to `serde_json`, exactly as
`i18n` did. There was no asymmetry to fix. Both readers had the same gap, and no
package measured happens to trip the manifest one — which is the more dangerous
version of the same bug, because it means the reported half could be fixed and
the other half would keep working right up until it did not.

## Decision

**`crates/zer0-core/src/ext/mod.rs::read_package_json` is the one place a JSON
file inside a package becomes a string to parse**, and it removes exactly one
leading byte-order mark. `read_manifest` and `i18n::read_messages` both go
through it.

Two things are being decided, and the second is the one that will be argued
with.

### It is a function, at the door, and not two corrected call sites

There are two JSON files a package is read for and there is no reason to think
there will never be a third. A rule enforced at N call sites has N−1 bugs
waiting, and this one already demonstrated it: the rule was at neither site, and
the temptation on finding that out is to write it at the one that was reported.

The door is `read_package_json` and it exists to hold a rule, which is why it
looks like a pointless wrapper around `fs::read_to_string` and is not one. That
sentence is in the code, where somebody about to delete it will read it.

### Tolerating is not repairing

AGENTS.md says refuse rather than repair, and stripping bytes off the front of a
hostile file deserves the challenge. It is not a repair, for one reason: a
byte-order mark has exactly one meaning and there is nothing to guess. It is an
encoding artefact an editor left behind, the file is well-formed under the
standard it was written for, and Chrome — the only implementation whose
acceptance the author was testing against — reads it. Refusing here would be
refusing a correct package over a byte, and calling that "failing closed" would
be dressing up a defect.

What is not tolerated is anything beyond that. **Exactly one** mark is removed:
a second is a malformed file, not a second artefact. Nothing else is trimmed —
`serde_json` already accepts leading whitespace, so there is nothing else this
could usefully forgive. And a UTF-16 file never arrives here at all, because
`read_to_string` refuses anything that is not UTF-8, so the scope of this is the
three bytes `EF BB BF` and nothing more.

## Consequences

**What hurts:**

- **A door whose whole body is three lines invites deletion.** It reads as
  indirection over a standard-library call, and the only thing preventing the
  inline is a comment and a test. That is the weakest kind of structural
  guarantee — AGENTS.md's preferred form is a type with no field for the bad
  state, and there is no type here, only a convention with a lock on it.
- **The lock does not hold the door, only the behaviour.** Inline the strip into
  both call sites and everything stays green while the N−1 problem comes back
  for the next reader. Declared, not solved.
- **It is one forgiveness, and forgivenesses accumulate.** The next package that
  fails on some other tolerated-by-Chrome quirk — a trailing comma, a comment in
  JSON, a lone surrogate — arrives with this decision as precedent, and the
  argument for each one will look like the argument for this one. The line drawn
  here is *unambiguous encoding artefact*, and it does not extend to syntax.
- **Nobody is told.** A package with a BOM installs exactly as if it had none,
  which is right, and means there is no signal anywhere about how many packages
  depend on this.

**What we get:**

- Awesome Screenshot installs, and so does the next package whose author's
  editor writes a BOM.
- Both readers have the rule because they share the read, not because two people
  remembered.
- The manifest half was fixed before anything tripped it, which is the only time
  that is cheap.

## How this regresses

**"This extension will not install and the name is a key."** The strip is
removed, most plausibly by somebody inlining `read_package_json` back into its
two callers on the grounds that a wrapper around `read_to_string` earns nothing.
Both locks go red: `a_message_bundle_that_starts_with_a_byte_order_mark_is_still_read`
at the unit level, and
`a_byte_order_mark_on_either_json_file_does_not_refuse_the_package` through the
whole install, which is the one that reproduces the reported defect.

That end-to-end test puts a mark on **both** files, and no measured package does
that. It is deliberate: `default_locale` is read off the manifest text a second
time, so a fix applied to one read and not the other still refuses the package,
and a test that only marked `messages.json` would not notice.

**"It accepts a file with three BOMs in it."** The strip is made a loop, or a
`trim_start_matches`, because one looks arbitrary. Nothing goes red. Declared
debt, and the reason it is only debt is that the failure is a package being
accepted rather than refused — the direction that costs nothing.

**The one no test catches:** the precedent being read as "make hostile JSON work
somehow". A trailing comma, a `//` comment, a `NaN` literal — each is a syntax
error rather than an encoding artefact, each needs a real decision, and none of
them is covered by anything here. If a future reader is quoting this ADR to
justify a lenient JSON parser, it is being quoted against its own text.

## When to revisit

- **When a third JSON file inside a package needs reading.** That is the moment
  the door pays for itself or is shown not to, and the new reader either goes
  through it or explains why not.
- **If a package fails to install on some other quirk Chrome tolerates.** The
  question then is whether it is an encoding artefact or a syntax extension, and
  this file is the line: the first is arguable, the second is not, and either
  way it is a new ADR rather than an edit to `read_package_json`.
- **If the core ever stops being the thing that reads a package off disk** —
  a `webkit2gtk` host doing its own unpacking, say. The rule crosses; the
  function does not.
