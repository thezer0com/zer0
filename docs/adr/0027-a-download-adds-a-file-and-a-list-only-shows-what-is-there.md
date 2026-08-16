# ADR-0027: A download adds a file, and the list only shows what is still there

- **Status:** Accepted
- **Date:** 2026-03-30
- **Lock:** `crates/zer0-core/src/downloads_tests.rs::a_suggested_name_cannot_climb_out_of_the_download_folder`, `crates/zer0-core/src/downloads_tests.rs::an_existing_file_is_never_written_over`, `crates/zer0-core/src/downloads_tests.rs::windows_forbidden_characters_are_replaced_not_dropped`, `crates/zer0-core/src/downloads_tests.rs::a_windows_device_name_is_refused_whatever_its_case_or_extension`, `crates/zer0-core/src/downloads_tests.rs::a_name_that_only_becomes_a_device_name_after_sanitising_is_refused`, `crates/zer0-core/src/download_reducer_tests.rs::an_entry_whose_file_is_gone_is_not_brought_back`, `crates/zer0-core/src/download_reducer_tests.rs::a_download_still_running_comes_back_as_interrupted_not_as_running`, `apple/Tests/Zer0ShellTests/DownloadTests.swift::DownloadHonestyTests/indeterminateStatusClaimsNothing`, `apple/Tests/Zer0ShellTests/DownloadTests.swift::DownloadHonestyTests/noTotalGetsTheSpinnerAndNotABar`, `apple/Tests/Zer0ShellTests/DownloadTests.swift::DownloadHonestyTests/aStoppedDownloadDrawsNothing`

## Context

A download is the one thing a browser does that writes to the person's disk with
a name somebody else chose. Every other surface renders hostile input; this one
*acts* on it.

There are three separate decisions inside "add downloads", and they are easy to
run together because they all look like plumbing:

1. **Where the file goes.** `WKDownloadDelegate` hands over a
   `suggestedFilename` and asks for a destination URL. That string comes from
   `Content-Disposition` — written by whoever is serving the file — and the
   header docs say plainly that "web content can specify the suggested download
   filename". It is attacker input with a filesystem call at the end of it.

2. **Whether the list survives a restart.** Downloads are state that outlives
   the view showing them, so by ADR-0002 they belong in the core, and the core
   already persists its state in SQLite. Persisting them is the default answer.
   But a download row is an *assertion about the filesystem* — "this file is at
   this path" — and a row whose Reveal in Finder does nothing is worse than no
   row, because it is the interface being confidently wrong about something the
   person can check in one click.

3. **What happens to a transfer when the app quits.** `WKDownload` lives in the
   web content process and dies with it. `resumeDownloadFromResumeData:` exists,
   but it needs resume data the server agreed to give, on a web view in the same
   session, and it produces `nil` "if no resume attempt is possible with this
   server". There is no honest way to promise a download survives ⌘Q.

The third one is where every browser cheats slightly. Chrome shows a paused row
and resumes it silently or fails silently. Whatever we do, the screen must not
claim something we cannot deliver.

## Decision

### A download adds a file. It can never replace one.

Two functions in `crates/zer0-core/src/downloads.rs` hold this, and both are in
the core because naming is behaviour, not appearance:

- **`safe_filename`** reduces the suggestion to a name that can only land inside
  the chosen directory. It takes the last component after splitting on `/` **and**
  `\`, replaces control characters, `:`, Unicode bidirectional overrides and the
  characters Windows refuses in a filename (`* ? " < > |`) with `-`, strips leading
  dots, caps the length at 240 bytes on a character boundary while keeping the
  extension, and falls back to `download` when nothing usable is left or when the
  stem before the first dot is a Windows device name (`CON`, `PRN`, `AUX`, `NUL`,
  `COM1`–`COM9`, `LPT1`–`LPT9`, matched without regard to case and extension — on
  NTFS `CON.tar.gz` is the console device, not a file). It deliberately does
  **not** percent-decode: decoding is exactly what puts `%2F` back to being a
  separator after the separators have been removed.
- **`destination_in`** never returns a path that is occupied. The second copy of
  `report.pdf` is `report-2.pdf`, which is what Safari does on the same machine,
  and after 999 attempts it returns `None` and the download is refused rather
  than a name being reused. Occupancy is checked with `symlink_metadata`, not
  `exists`, because `exists` follows the link: a dangling symlink planted at the
  destination would read as free and the file would be written *through* it.

The save-panel path goes through the same two functions. A panel will accept a
name carrying a bidi override as happily as a server will send one.

`EngineCommand::AcceptDownload` therefore carries a path the core guarantees two
things about — the directory exists, nothing is there yet — which is both what
`WKDownload` requires and the promise itself, stated as a type.

### Download history survives a restart, minus anything we cannot prove

Completed downloads are written to SQLite. At load, `Store::load_downloads`
drops every row whose path is no longer on disk.

The reason to persist at all is the reason the list exists: "where did that file
go" is a question asked tomorrow, not thirty seconds later. The reason to check
is ADR-0018 — a row asserts a file is at a path, and once it is not, the row is
a lie with a button on it. One `symlink_metadata` per row, once per launch, buys
a list where every entry is real.

Failures and cancellations are **not** persisted. There is no file at the end of
one, so the row would offer Reveal in Finder for something that was never there.
Within the session they are worth showing — you asked for something and it did
not arrive — and by the next launch that is over.

### A download in flight does not survive the quit, and we say so twice

**Before:** `SessionLifecycle.applicationShouldTerminate` asks when anything is
running, and says what is about to be lost by name — "*big.iso* is still
downloading… zer0 can't pick them up again next time, so they would have to
start over" — rather than "Are you sure?".

**After:** `Store::save` writes a running download as `interrupted`. If that save
turns out to be the last thing written, that is exactly what happened; if the
browser is still running, the in-memory state is untouched and the next save
corrects the row. So a kill -9 produces a list saying "Stopped when zer0 quit"
on a partial file the person can find and throw away, rather than a progress bar
for a transfer that ended hours ago.

`DownloadState::Interrupted` exists as its own case precisely so that sentence
can be written. `Failed` would be wrong: nothing went wrong with the transfer.
We did.

### Progress is stated, never estimated

`Download::total_bytes` is `Option<u64>`, and `Download::fraction()` returns
`None` when the total is missing, zero, or smaller than what has already
arrived. The shell draws a determinate bar when there is a fraction, and the
status line says "12.4 MB so far" instead of a percentage. Finishing sets
`total_bytes = Some(received_bytes)`: the file is whole, so its size stops being
a guess.

**When there is no fraction, the shell draws a spinner rather than an
indeterminate bar.** This paragraph used to say "an indeterminate one", and that
was the decision leaking back out through its own drawing. An indeterminate
linear `ProgressView` is the *same track as the determinate one at a different
fill*: it animates, so it is not a still screen, but its shape asserts a scale
we were never sent, and a person watching it reads the sweep as a position until
it passes the end and starts over. The two facts now get two shapes that cannot
be mistaken for one another — a bar that fills when there is something to fill
it, and the circular spinner the find bar already uses for "working, and nobody
knows how long" (ADR-0018). The byte count beside it carries the only number
anyone sent us.

`DownloadCopy.fraction` also narrows the core's answer to downloads that are
still arriving. `Download::fraction()` is computed from the byte counts alone,
so a transfer that stopped at 40% still has one; a bar left standing under a
download that ended hours ago is the same stale assertion as a match count for a
query nobody is asking anymore.

## Consequences

**What hurts:**

- **`report-2.pdf` is not what the person asked for.** They asked for
  `report.pdf` and got something else, with no dialog explaining why. The
  alternative is a replace prompt, which is a modal over a page for something
  they did not ask to be interrupted about, or silent overwriting, which is the
  thing this ADR exists to forbid.
- **A file moved in Finder disappears from the list.** That is correct and it
  will still read as data loss to somebody. There is no way to distinguish
  "moved" from "deleted" without tracking the file, which is a much larger
  promise than a browser should make.
- **The stat-per-row at load is a filesystem call in `Store::load`.** Bounded at
  200 rows, but it makes loading the session depend on the disk in a way it did
  not before. A network volume that is slow to answer makes launch slower.
- **No resume, at all.** Not across a quit, and not after a failure: Try Again
  starts the transfer from zero. For a large file on a bad connection that is a
  real loss compared to every other browser.
- **The quit dialog can be argued with.** Somebody who quits with four downloads
  running every day will find the alert an obstacle, and there is no "don't ask
  again".
- **`safe_filename` mangles legitimate names.** A file genuinely called
  `Q1:Q2.csv` becomes `Q1-Q2.csv`, and a Japanese filename long enough to exceed
  240 bytes loses characters that a 255-*character* limit would have kept.

**What we get:**

- A download can add a file to a folder and can do nothing else to it. That is a
  small enough claim to check, and the tests check it.
- Every row in the list is a file that is there.
- Nothing on screen claims a percentage, a size or a state that the layer under
  it cannot back up.

## How this regresses

The naming rules regress by being *simplified*. Every one of them looks like
paranoia in isolation, and each is one line to delete:

- **"Why are we not percent-decoding? The name shows up as `%20` sometimes."**
  True, and adding the decode puts `%2F` back to being a separator — after the
  separators have been stripped, so nothing downstream catches it. The person
  would notice a file appearing outside their Downloads folder, eventually, or
  never.
- **"`symlink_metadata` is odd, `exists` is what everyone uses."** The dangling
  symlink case is invisible in every test that does not plant one. The person
  would notice nothing at all; that is the point of the attack.
- **"Nobody puts a bidi override in a filename."** They do, and the whole
  purpose is that the name reads as `invoice.pdf` on screen and is not that on
  disk. This regression is invisible by construction.
- **"Why refuse `CON`? It is a perfectly good name on APFS."** It is, and on
  NTFS it is not a name at all — it is the console device, and what the person
  expected to be their file becomes a write to a device or an error. The core
  is hosted on Windows too, so the reservation travels with the name.
- **"Let it overwrite, the person picked the name."** They did not; the server
  did. This is the one that turns a download into a way to replace a file the
  person already had.

The persistence half regresses the other way — by somebody adding *more*:

- **"Failed downloads should persist too, so you can retry tomorrow."** Sounds
  helpful, and puts rows in the list with no file behind them and a Reveal in
  Finder that does nothing.
- **"Drop the existence check, it costs a stat per row."** The list becomes a
  graveyard within a month of ordinary tidying up, and the first dead row is the
  moment the person stops trusting the rest.
- **"Show `in progress` on restore, it looks better than `interrupted`."** A bar
  for a transfer that stopped last night, moving nowhere, forever.

And the progress half regresses exactly the way ADR-0018 describes: somebody
computes a plausible percentage from a rate, everyone praises it in the PR, and
it sits at 99% on every server that sends no length.

The shape regresses more quietly than that, and it already did once:

- **"Both cases should be a bar, the row looks lopsided otherwise."** It is one
  line — `ProgressView()` beside `ProgressView(value:)`, same style, same track
  — and it reads as a tidy-up rather than as a claim. What the person would
  notice is a bar that fills, reaches the end and starts again from the left,
  and the moment they see that they know the first pass meant nothing. That is
  the version this ADR shipped with, and it survived a year of screenshots
  because a still frame cannot tell the two apart.
- **"`DownloadCopy.fraction` just forwards to the core, drop it."** It does not:
  it drops the core's answer for anything that is no longer arriving. Without
  that guard a cancelled download keeps a bar frozen at 40%, which is the same
  "a bar for a transfer that stopped last night" this record already objects to
  two bullets up.

## When to revisit

- **If `WKDownload` gains real resumption across launches.** Then interrupted
  downloads should offer Resume rather than Try Again, and the quit dialog gets
  a third button. The rule does not change; what changes is what can be
  promised.
- **When somebody asks for a replace prompt.** The answer is not to allow silent
  overwriting; it is to decide whether an explicit "Replace" is worth a modal,
  and to keep the core's invariant by removing the file before the path reaches
  WebKit — which is what the save-panel path already does.
- **If the load-time stat shows up in launch profiling.** Moving it to a lazy
  per-row check at render time keeps the honesty and drops it off the launch
  path.
- **When a second thing on screen wants to show a rate or a time remaining.**
  Neither is derivable from what `NSProgress` gives us without smoothing over
  measurements we do not take. If they are wanted, they have to be measured
  first, not inferred.
