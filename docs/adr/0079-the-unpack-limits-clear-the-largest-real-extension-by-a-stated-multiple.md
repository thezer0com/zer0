# ADR-0079: The unpack limits clear the largest real extension by a stated multiple

- **Status:** Accepted
- **Date:** 2026-08-10
- **Lock:** `crates/zer0-core/src/ext/ext_tests.rs::every_extension_measured_on_the_store_fits_inside_the_limits`, `crates/zer0-core/src/ext/ext_tests.rs::a_package_with_as_many_entries_as_the_busiest_real_extension_installs`, `crates/zer0-core/src/ext/ext_tests.rs::a_package_with_an_absurd_number_of_entries_is_refused`, `crates/zer0-core/src/ext/ext_tests.rs::entries_that_are_each_small_enough_but_add_up_are_refused`

## Context

ADR-0022 put unpacking under `UnpackLimits` because a CRX is hostile input, and
it sized the numbers against reality as reality was then understood: *"several
times the fattest extension anyone actually ships"*, *"an order of magnitude
above the busiest real extension"*. It named its own exit condition in one
sentence — **"when a legitimate extension is refused"** — and expected to hear
about it from a bug report.

Nobody reported it, because the extensions it refused are ones you install once.
Real packages, downloaded through this crate's own `install_extension` on
2026-08-10, unpacked bytes as they actually arrived:

| Package | Unpacks to | Entries | Largest entry | Under the old limits |
| --- | --- | --- | --- | --- |
| AdBlock | 361,445,737 | 443 | 18.7 MB | **refused** |
| Adblock Plus | 355,798,527 | 355 | 18.7 MB | **refused** |
| Keeper | 231,578,760 | 887 | 23.8 MB | 86% of the ceiling |
| Screencastify | 221,579,594 | 152 | **32.2 MB** | 83% of the ceiling |
| Bitwarden | 80,491,018 | 263 | 10.9 MB | ok |
| Wappalyzer | 76,953,181 | **13,244** | 1.8 MB | **refused** |
| uBlock Origin Lite | 36,221,511 | 1,021 | 2.1 MB | ok |
| Awesome Screenshot | 19,248,655 | 837 | 1.8 MB | ok |
| Violentmonkey | 1,943,462 | 108 | 0.3 MB | ok |

So 256 MiB was not "several times the fattest extension"; it was **0.74× the
fattest extension**, and had been below a package that already existed on the
day it was written. The two biggest content blockers on the Chrome Web Store
could not be installed in this browser, and the message they produced —
*"the package unpacks to more than the 268435456 bytes allowed"* — is the one
ADR-0022 already admitted "tells them nothing they can act on".

10,000 entries was not an order of magnitude above the busiest real extension
either. Wappalyzer ships 13,244.

## Decision

The numbers move, and each one is now stated as a multiple of the worst real
package rather than as a round number with an adjective.

| Limit | Was | Is | Multiple of the worst measured |
| --- | --- | --- | --- |
| `max_total_bytes` | 256 MiB | **512 MiB** | 1.48× AdBlock |
| `max_entry_bytes` | 64 MiB | **64 MiB** | 2.08× Screencastify's `ffmpeg-core.wasm` |
| `max_entries` | 10 000 | **32 768** | 2.47× Wappalyzer |

**`max_entry_bytes` does not move.** It already had the headroom ADR-0022
claimed for it, the survey confirmed it, and not changing a number is cheaper
than changing it.

**512 MiB is a bound on us, not a description of the store.** The threat is
unchanged: deflate reaches roughly 1000:1, so what this stops is a 100 MB
download expanding to ~100 GB, and half a gigabyte of staging that is deleted on
refusal is four orders of magnitude short of what that bomb wanted. It is a cost
a laptop notices and survives, which is the property that matters — the failure
being defended against is *quietly* filling a disk.

**32,768 entries is raised rather than removed**, and the distinction is the
whole of it. Entries cost an inode and a `create` and *no bytes*, so
`max_entries` is the only thing standing between this browser and a one-megabyte
archive declaring a million empty files; `max_total_bytes` cannot see that attack
at all. Wappalyzer is an outlier by 7.5× over the next busiest package measured
(Coinbase Wallet, 1,762), so this ceiling is set against the outlier and not
against the norm.

**The headroom is proportional and deliberate, not "just above today's
largest".** Setting a ceiling immediately above the biggest thing you can
currently see is how 256 MiB happened, and its cost was two years of an
uninstallable uBlock-class extension that nobody diagnosed.

Nothing about the mechanism changes. Two passes, `io::copy` over `Read::take`,
never a sized buffer, `enclosed_name()` refusing an escaping entry, staging
directory removed on failure. ADR-0022 is the decision; this only moves three of
its numbers.

## Consequences

**What hurts:**

- **A hostile package now costs twice the disk before it is stopped.** That is
  the trade, stated plainly: 512 MiB of transient writes instead of 256 MiB.
  There is no version of "admit AdBlock" that does not buy this.
- **A worst case that is now genuinely slow.** 32,768 file creations is seconds
  of syscalls before `TooManyEntries` fires — and it fires from the central
  directory before anything is unpacked, so the flood attack is refused early;
  what is slow is the *legitimate* Wappalyzer-shaped install, and it is slow
  every time.
- **The refusal message is no better than it was.** It still names a limit and
  not a reason, there is still no override and no "install anyway", and a person
  refused at 512 MiB is in exactly the position ADR-0022 described. All that
  changed is that far fewer people are in it.
- **These are still a guess about other people's software**, taken from nine
  packages on one afternoon. AdBlock at 361 MB is mostly locale bundles and rule
  sets, both of which grow, and there is no growth rate here to extrapolate from
  — one measurement is a point, not a trend.
- **The primary lock asserts against constants rather than unpacking 361 MB.**
  That is a real gap and it is deliberate; see below.

**What we get:**

- Every extension measured installs, including three that did not.
- Each number now has a multiple and a named package behind it, so the next
  argument about them starts from evidence instead of adjectives.
- The zip-bomb defence is intact in both directions, and the entry-count defence
  is intact against the attack it actually exists for.

## How this regresses

**"AdBlock will not install anymore."** Somebody halves the ceiling after a
scare about disk usage, or rounds 512 back to 256 because the old number looks
more deliberate. `every_extension_measured_on_the_store_fits_inside_the_limits`
goes red *naming the extension that stopped installing* and the two numbers
involved, which is the whole reason it is a table of measured packages and not
three assertions about constants.

That test is asserting against constants rather than unpacking 361 MB in CI, and
the trade is worth stating: a synthetic 300 MB unpack would stay green against a
ceiling of 310 MB, which still refuses AdBlock. The mechanism at scale is held
next door — `a_package_with_as_many_entries_as_the_busiest_real_extension_installs`
really does put 13,244 entries through `install_extension`, and ADR-0022's
`an_extension_the_size_of_a_real_one_still_installs` and
`a_real_compression_bomb_is_stopped_by_the_total_limit` hold the byte path.

**"My disk filled up."** `max_entries` is removed as redundant, on the reasoning
that the byte counter covers everything. It does not: empty entries cost no
bytes. `a_package_with_an_absurd_number_of_entries_is_refused` is carried over
from ADR-0022 as a lock here, because raising a limit is exactly the moment
somebody asks why it exists.

**And the one that already happened once, silently.**
`entries_that_are_each_small_enough_but_add_up_are_refused` was eight fixed
48 MiB chunks — comfortably over 256 MiB, and quietly *under* 512 MiB the moment
the ceiling moved. It did not fail loudly; it fell through to `NoManifest`,
which is a test that has stopped testing and says something else instead. Its
chunk count is now derived from `UnpackLimits::DEFAULT`, and it is on the `Lock:`
line above because a test that silently stops defending a decision is worse than
one that never defended it.

**The one no test catches:** somebody raises the ceilings again, for a real
extension, without measuring — the numbers here are only worth something because
each is a multiple of something that was weighed. A number moved to fit one
package is the same mistake in the other direction.

## When to revisit

- **When a legitimate extension is refused**, which is ADR-0022's exit condition
  and remains the right one. What is new is that the answer is a multiple and a
  measurement, not a bigger round number.
- **If AdBlock-class packages pass ~400 MB.** The headroom here is 1.48× and
  that is one release of growth away from being 1.1×. This should be measured
  again, not reasoned about, and the table above is what to re-run.
- **If install latency ever matters**, which is now a live question rather than
  a theoretical one: 32,768 entries is real work on every Wappalyzer install.
- **If the store starts shipping genuinely large packages as a norm**, ADR-0022's
  own answer still stands and is better than a higher ceiling: show the real size
  and ask.
- **When signature verification lands.** These stop being the first line and
  become the second, and the error can finally distinguish "too big" from "not
  who it claims to be".
