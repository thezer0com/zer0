# ADR-0022: Unpacking a CRX runs under explicit limits

- **Status:** Accepted, and the three numbers it names are superseded by ADR-0079
- **Date:** 2026-03-12
- **Lock:** `crates/zer0-core/src/ext/ext_tests.rs::a_package_declaring_an_absurd_size_is_refused_rather_than_allocated_for`, `crates/zer0-core/src/ext/ext_tests.rs::a_real_compression_bomb_is_stopped_by_the_total_limit`, `crates/zer0-core/src/ext/ext_tests.rs::an_entry_that_keeps_sending_bytes_past_its_declared_size_is_cut_off`, `crates/zer0-core/src/ext/ext_tests.rs::undeclared_bytes_across_entries_still_hit_the_total_limit`, `crates/zer0-core/src/ext/ext_tests.rs::entries_that_are_each_small_enough_but_add_up_are_refused`, `crates/zer0-core/src/ext/ext_tests.rs::a_package_with_an_absurd_number_of_entries_is_refused`, `crates/zer0-core/src/ext/ext_tests.rs::an_extension_the_size_of_a_real_one_still_installs`

## Context

ADR-0021 leaves us with a bag of bytes from a source that is not authorised, is
not signature-verified, and answers to an id anyone can craft a package for. The
id check proves the package is internally consistent. It proves nothing about
its author: an attacker signs with their own key, the derived id matches their
own declared id, and the package is accepted.

So from `crx::parse` onwards the archive is hostile input, and the first thing
hostile input does to a ZIP reader is cost you everything.

There were two live failures, and only one of them is the famous one.

**The declared size.** Every number in a ZIP header is written by whoever built
the file. `entry.size()` is a claim. Sizing a buffer from it — the obvious
`Vec::with_capacity(entry.size())` — hands an attacker a call to
`handle_alloc_error`, which **aborts the process**. Not an unwind, not an error
the FFI can report to Swift: the browser is gone, with every open tab. A ZIP64
extra field lets a package under 512 bytes declare an entry of 9 223 372 036
854 775 000 bytes.

**The real bomb.** Deflate reaches roughly 1000:1 on repetitive input, so a
100 MB download expands to around 100 GB. Nothing is malformed; the reader is
doing exactly what it was told.

And the mirror image of the first: a package whose headers say an entry is empty
and then keeps sending bytes. Nothing declared is over any limit, so a check that
reads headers passes it through.

## Decision

Unpacking runs under `UnpackLimits` in `crates/zer0-core/src/ext/mod.rs`. The
shipping values, and where each number comes from:

| Limit | Value | Why that number |
| --- | --- | --- |
| `max_total_bytes` | 256 MiB | several times the fattest extension anyone actually ships, and small enough that a hostile package cannot quietly fill a laptop's disk |
| `max_entry_bytes` | 64 MiB | no legitimate resource comes close; it bounds one entry before the running total notices |
| `max_entries` | 10 000 | an order of magnitude above the busiest real extension; each entry costs a file creation and an inode |

Sized against reality, not against a round number: uBlock Origin unpacks to
about 5 MB across a couple of hundred files, and the heavy end of the store —
bundled models, video assets, one message bundle per locale — reaches a few tens
of MB and a few thousand files.

### Two passes, because one is not enough

**First pass, over the central directory only.** The declared sizes are used to
refuse a package early and cheaply, and for nothing else. An honest compression
bomb declares its real size and dies here without a byte being decompressed.

**Second pass, counting bytes that actually arrive.** A package that lies low
about its sizes gets past the first pass, so the running total is what holds the
line.

### `io::copy` over `Read::take`, never a sized buffer

`entry.size()` never touches an allocation. The entry is streamed:

```rust
let total_left = limits.max_total_bytes.saturating_sub(unpacked_total);
let budget = limits.max_entry_bytes.min(total_left);
let written = io::copy(
    &mut Read::by_ref(&mut entry).take(budget.saturating_add(1)),
    &mut file,
)?;
```

The cap is **one byte past the budget**, so landing exactly on the limit is
legal and exceeding it is detectable. Both counters are then checked against
`written` — the bytes that really turned up — and `unpacked_total` carries
forward.

Alongside the limits, and for the same reason, `enclosed_name()` returning
`None` refuses the entry outright: an entry named `../../.zshrc` must never be
written just because a package asked for it.

### Failure leaves nothing behind

`install_extension` unpacks into `base_dir/.<id>.incoming` and renames on
success. A refused package leaves no staging directory, and a failed upgrade
leaves the working version exactly where it was.

## Consequences

**What hurts:**

- **The limits are a guess about other people's software.** 256 MiB is sized
  from extensions we looked at. A legitimate extension that ships a large model
  or a video asset gets refused, and the person sees "the package unpacks to
  more than the 268435456 bytes allowed" — a true sentence that tells them
  nothing they can act on. There is no override, no "install anyway", and no
  path in the UI to raise the ceiling.
- **A refused package looks like a broken browser.** From the outside, Add
  failed. The error names a limit, not a reason, and certainly not "this package
  is probably hostile". We cannot tell those two apart either.
- **The first pass costs a full walk of the central directory.** Every install
  reads every entry header twice. Irrelevant at these sizes, and it is still
  work done on the promise of a threat.
- **A partly-written file is left on disk when an entry is cut off.**
  `io::copy` writes as it goes, so the over-budget entry exists on disk at the
  moment the error is raised. The staging directory is removed afterwards, which
  means the cleanup path is what saves us — and a refactor that returns early
  without it leaks disk on every hostile package.
- **`max_entry_bytes` is checked against `written`, which was already written.**
  The defence bounds the damage at one entry's budget; it does not prevent
  spending it. On a package with 10 000 entries each pushed to the cap, the
  first-pass check is what has to catch it, not the second.
- **Signatures are still not verified.** These limits are what we have *instead*
  of knowing who built the package. They bound the cost of running a hostile
  archive through a ZIP reader. They do nothing about a hostile extension that
  unpacks to 200 KB and then does whatever it likes with the permissions
  ADR-0020 grants it. This is the smaller half of the problem.

**What we get:**

- A hostile package costs a bounded amount of disk and CPU and then an error
  value, which is the whole point: an error crosses the FFI, an abort does not.
- The bomb that was found is closed in both directions — the one that lies large
  and the one that lies small.

## How this regresses

**"The browser vanished when I added an extension."** No crash report worth
reading, no error dialog, no log line: the process aborted inside the
allocator. This is what `Vec::with_capacity(entry.size())` buys, and it comes
back the day someone "optimises" the streaming copy into a preallocated buffer
because the profiler pointed at `io::copy`. That change looks like a performance
win in review. `a_package_declaring_an_absurd_size_is_refused_rather_than_allocated_for`
is a 512-byte package that fails it.

**"My disk filled up."** The total counter was dropped, or moved to trust
declared sizes only. The install appears to hang while tens of gigabytes are
written. `a_real_compression_bomb_is_stopped_by_the_total_limit` runs real
deflate over real zeros with shrunk limits — the mechanism is the shipping one.

**"It said the file was empty and it wrote a megabyte."** The second pass was
removed as redundant once the first pass existed. That is the exact refactor to
expect, because the first pass looks like it covers everything.
`an_entry_that_keeps_sending_bytes_past_its_declared_size_is_cut_off` and
`undeclared_bytes_across_entries_still_hit_the_total_limit` exist as a pair for
this: one holds the per-entry counter, one holds the running total.

**"uBlock Origin will not install anymore."** Somebody tightened the numbers
after a scare. `an_extension_the_size_of_a_real_one_still_installs` is the lock
in the other direction, and it is the reason the limits can be argued about
without anyone having to guess whether a real extension still fits.

**"There is a `.abcdef.incoming` folder eating 200 MB."** The staging cleanup
was lost on an error path. `a_failed_install_leaves_no_staging_directory_behind`
and `a_failed_upgrade_leaves_the_working_version_in_place` cover it, and both
are in `ext_tests.rs`.

**The one with no lock:** `enclosed_name()` being swapped for manual path
joining. `an_entry_escaping_the_directory_is_refused` and
`an_absolute_entry_path_cannot_write_outside_the_directory` do exist and are not
on the `Lock:` line above only because the line is already long — they belong to
the same decision and should be treated as part of it.

## When to revisit

- When a legitimate extension is refused. That is the signal the numbers are
  wrong, and the fix is to move a number with a reason written next to it — not
  to remove the check.
- When signature verification lands. The limits do not become unnecessary; they
  become the second line instead of the first, and the error message can finally
  distinguish "too big" from "not who it claims to be".
- If the store starts shipping genuinely large packages as a norm. Then 256 MiB
  is a product problem, and the answer is probably an explicit confirmation with
  the real size shown, rather than a higher silent ceiling.
- If install latency ever matters. The two-pass walk is the obvious thing to
  question, and the answer is that the first pass is what makes an honest bomb
  free to refuse.
