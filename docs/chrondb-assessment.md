# ChronDB as zer0's session store — an assessment

- **Date:** 2026-08-09
- **Status:** Assessment. No production code was changed.
- **Question asked:** can ChronDB replace SQLite entirely, so that zer0 has no
  SQLite dependency?
- **Answer:** not today, and the blockers are not the ones the question
  expected. Two of them are architectural rather than immature, one is legal.

Everything below is marked **[MEASURED]** — I ran it on this machine and this is
what happened — or **[READ]** — I read it in source, docs, or a release
artifact. Where I could not establish something, it says so.

---

## 0. The headline

ChronDB is **much closer to embeddable than the brief assumed**, and much
further from being a session store than its documentation suggests.

The good news first, because it is real and it inverts the original premise:

> There is no JVM, no separate process, no socket, and no port. ChronDB ships a
> GraalVM native-image shared library with a published Rust crate. `ChronDB::open_path("./db")`
> then `put`/`get` — the same shape as opening a SQLite file. I built a Rust
> project against the crate from crates.io and it worked on the first run.
> **[MEASURED]**

So the three architectures in the original brief — embedded JVM, managed child
process, external server — are moot. That is a genuine and material finding: the
integration story is far cheaper than "bundle a JVM".

The bad news is that the two guarantees ADR-0006 and ADR-0017 exist to protect
are the two things this backend cannot currently provide, and I have a measured
failure for each:

1. **A save cannot be atomic.** ChronDB makes **one Git commit per key**. A zer0
   `save()` is hundreds of keys, so it is hundreds of commits. There is no
   boundary that makes them one. Interrupt it and you have half of two sessions
   — the precise thing ADR-0006 was written to prevent. **[MEASURED: 407 puts
   produced 407 commits.]**
2. **A corrupt store is indistinguishable from an empty one.** I corrupted the
   repository's `HEAD` and ChronDB opened it happily and reported **zero
   documents**. Under ADR-0017 that is the catastrophic path: the browser would
   conclude "fresh profile", run for twenty seconds, and autosave over a session
   it simply failed to read. **[MEASURED]**

And two things that would stop a ship regardless of engineering:

3. **The query layer does not work in the shipped library at all.** Every SQL
   statement and all eight Lucene query shapes I tried returned errors.
   `execute_sql` fails with a Clojure dynamic-loading error that is
   characteristic of GraalVM native-image. This also removes the "we get Lucene
   full-text search for free" upside — through the shipped `.dylib`, we do not.
   **[MEASURED]**
4. **ChronDB is AGPL-3.0.** zer0 ships as a binary to end users. This needs a
   licensing decision before it needs an engineering one. **[READ]**

**Recommendation: do not adopt ChronDB as the session store now.** Keep SQLite
behind the new `SessionStore` trait. If the goal is the Git-backed *product*
idea — and that idea is genuinely good — there is a cheaper way to get most of
it, described in §9. Revisit conditions are in §11.

---

## 1. What ChronDB actually is, operationally

**[READ]** ChronDB is a Clojure database that stores documents as JSON files in
a bare Git repository, with an Apache Lucene index alongside for search. Data
model: database → Git repo, branch → schema, directory → table, JSON file →
document, commit timeline → history.

It has four consumption modes. Only the last one matters for zer0:

| Mode | What it needs | Relevant? |
| --- | --- | --- |
| REST server (port 3000) | JVM | No |
| PostgreSQL wire server | JVM | No |
| Redis (RESP2) server | JVM | No |
| **`libchrondb` shared library** | **nothing at runtime** | **Yes** |

The shared library is built with GraalVM `native-image --shared`. It is AOT
compiled: the Clojure runtime, Lucene and JGit are all inside the `.dylib`, and
no JVM is installed or started. The C API is small and handle-based
(`chrondb_open_path` returns an `int`; everything else takes that handle and
exchanges JSON as C strings). **[READ: `include/libchrondb.h` from the release,
`dev/chrondb/shared_library.clj`]**

The Rust crate wraps this. It runs all FFI calls on a dedicated thread with a
**64 MB stack**, because Lucene and JGit recurse deeply. **[READ: crate docs;
the requirement is real enough that I gave my own C harness a 64 MB stack too.]**

### The in-process Clojure API in the docs does not exist

Worth recording because it affects how much of the documentation can be trusted.
The README and several docs pages show `(require '[chrondb.core :as chrondb])`
then `chrondb/create-chrondb`, `chrondb/save`, `chrondb/get-at`. **None of these
functions exist.** `src/chrondb/core.clj` is a 96-line CLI dispatcher.
`create-chrondb` exists only in a demo namespace. **[READ]**

This pattern repeats: the README advertises "ACID Transactions — Guaranteed
consistency and durability"; the code has no transactions (§4). The FAQ
advertises timestamp time-travel (`get-at db "user:1" "2023-07-15T…"`); the
implementation takes a **commit hash**, and the timestamp-resolving namespace
(`temporal/core.clj`) is dead code wired to no protocol. **[READ]** Take the
docs as intent, not as specification.

---

## 2. Method — what I actually ran

So the numbers below can be checked or disputed:

- **Machine:** this one. macOS (Darwin 25.6.0), Apple Silicon (arm64).
- **Artifact:** `libchrondb-latest-macos-aarch64.tar.gz` from the `latest`
  GitHub release, downloaded 2026-08-09.
- **Harness 1:** a C program against `libchrondb.h`, run on a pthread with a
  64 MB stack, timing with `CLOCK_MONOTONIC` and reading RSS via
  `task_info(MACH_TASK_BASIC_INFO)`.
- **Harness 2:** a Rust binary in a throwaway crate outside this repo, depending
  on `chrondb = "*"` from crates.io. This is the integration zer0 would actually
  use.
- Both harnesses and their databases live in the session scratchpad, outside the
  repository. Nothing was written into `zero-browser/` except this document.

I did **not** benchmark zer0's current SQLite `save()` head-to-head. Where I
compare, I say so and I do not invent a number for the SQLite side.

---

## 3. Measured results

### Size and platform

| Thing | Value | How |
| --- | --- | --- |
| Release tarball (macOS arm64) | 30,041,870 B (~30 MB) | [MEASURED] |
| **`libchrondb.dylib` on disk** | **88,636,944 B (~88.6 MB / 84.5 MiB)** | [MEASURED] |
| Architecture | arm64 only — **not universal** | [MEASURED] `file` |
| Minimum macOS declared | **14.0** (`LC_BUILD_VERSION minos 14.0`) | [MEASURED] `otool -l` |
| Published platforms | macOS arm64, Linux x86_64 **only** | [MEASURED] release asset list |

Two things to sit with. First, **88.6 MB is the cost of the database**, before
zer0's own code and before the embedded WebKit of ADR-0005. Second, the
`minos 14.0` line is *the same class of problem ADR-0006 already flags for the
bundled SQLite* — a binary whose declared minimum comes from the build machine,
not from our deployment target. Here we do not even control the build.

There is no macOS x86_64 build and no universal binary, so an Intel Mac is not
served by the published artifacts at all.

### Startup and memory

| Measurement | Value |
| --- | --- |
| `graal_create_isolate` | **2.6 ms** |
| `chrondb_open_path` — **cold**, first ever open | **3,049.8 ms** |
| `chrondb_open_path` — warm, 203 documents | **49.3 ms** |
| `open_path` via Rust crate, small fresh DB | 151.2 ms |
| RSS before isolate | 10.8 MB |
| RSS after isolate created | 14.4 MB |
| **RSS after opening the database** | **85.4 MB** |
| RSS after 200 writes | 173.3 MB |
| RSS at end of run | **289.1 MB** |

All **[MEASURED]**.

The isolate itself is cheap — 2.6 ms is a non-issue, and this is the number that
kills the "JVM cold start" worry stone dead. The cost is elsewhere: **the first
open of a fresh database takes three seconds** (Lucene index construction), and
the resident memory floor is **~85 MB just to have the store open**.

For CLAUDE.md's standard — *"a browser that takes seconds to show a window has
already lost"* — a 3-second first-run open is exactly that, and it lands on the
very first launch, which is the one that forms the impression. It is avoidable
by opening the store off the main thread, but then the first window has no
session in it.

The memory figure deserves care: 289 MB at the end of a run that wrote 400 small
JSON documents. I did not isolate how much of that is Lucene buffers that would
be released under pressure, so treat 85 MB as the reliable floor and 289 MB as
"it grows a lot and I did not find the ceiling".

### Operation latency

200 samples each, warm.

| Operation | p50 | p95 | max |
| --- | --- | --- | --- |
| `put` | **2.97 ms** | 3.50 ms | 61.07 ms |
| `get` | **0.86 ms** | 0.92 ms | 170.77 ms |
| `list_by_table` (203 docs) | 5.0 ms | — | — |
| `history` (2 versions) | 19.2 ms | — | 182.7 ms |

All **[MEASURED]**. The p50s are respectable for a Git-backed store. The maxima
are not: a 61 ms `put` and a 170 ms `get` are multi-frame stalls, and the save
path runs with the interface alive.

The author's own published benchmark says ~7.3 ms per write / ~137 writes/sec.
**[READ]** My 2.97 ms p50 is better than that, so I am not being unfair to the
project here.

### The shape that actually matters: a whole-session save

zer0's `save()` deletes and rewrites everything, every 20 seconds and on every
structural change (ADR-0006). I simulated that: 20 rounds of rewriting a 30-tab
session.

| Round | 30 writes took | DB on disk | Files in DB |
| --- | --- | --- | --- |
| 1 | 114 ms | 62 KB | 260 |
| 5 | 114 ms | 787 KB | 1,220 |
| 10 | 116 ms | 2,277 KB | 2,635 |
| 15 | 118 ms | 3,223 KB | 3,985 |
| 20 | 97 ms | **4,258 KB** | **5,335** |

**[MEASURED]**

Read the last two columns rather than the first. A **30-tab** session — smaller
than a real one, and with no history, routes, keybindings, downloads or consent
rows — costs **~207 KB and ~270 new files per save**. At zer0's 20-second timer
that is roughly **37 MB and 48,000 files per hour of browsing**, growing without
bound. `git count-objects` confirms 2,747 loose objects and **zero packs** in my
other database: nothing is packing them. **[MEASURED]**

There is no incremental path available to soften this, because history is
written by replacement on purpose (ADR-0006 explains why: upserting alone brought
forgotten pages back). Every save rewrites every key, and in a Git store every
rewritten key is a new object and a new commit.

### The query layer is broken in the shipped library

This is the most surprising measured result.

```
SQL SELECT * FROM tab
  -> {"type":"error","message":"Could not locate chrondb/api/sql/parser/statements__init.class,
      chrondb/api/sql/parser/statements.clj or chrondb/api/sql/parser/statements.cljc on classpath."}
```

Every SQL statement fails identically, including `BEGIN` and `COMMIT`. **[MEASURED]**

That error is the signature of Clojure's runtime `require` inside a GraalVM
native-image, and the mechanism is worth writing down because it determines
whether this is fixable.

`clojure.lang.RT.load` tries three things in order: find `x/y__init.class` as a
**resource**, then `Class.forName("x.y__init")`, then load `x/y.clj` as a
resource. In a native image the first and third fail — there is no classpath to
scan and the `.clj` is not embedded. The decisive step is the second, and it
**swallows `ClassNotFoundException` and returns null**. So `require` works fine
in a native image *if* the namespace was AOT-compiled **and survived
reachability analysis**; otherwise it fails silently and you get the
`FileNotFoundException` above. **[READ]**

Two consequences:

- **It is a build defect, not a design limit.** The fix is to make the SQL
  parser namespaces statically reachable from the entry point so they are
  compiled into the image. That is ChronDB's build to fix, not ours, but it
  means a from-source build could plausibly produce a working query layer.
- **Embedding the `.clj` as a resource is not the fix**, and would make things
  worse: `RT.load` would then reach step three, call `Compiler.load`, and try to
  `defineClass` at runtime — which native-image forbids outright. You would
  trade a clear `FileNotFoundException` for a stranger failure later. **[READ]**

Either way, the caller cannot work around it. There is no runtime escape hatch
short of shipping an interpreter.

The Lucene path fails too. I tried eight query shapes to be fair:

| Query shape | Result |
| --- | --- |
| `term` (exact case) | `operation failed: query failed` |
| `term` (lowercased) | `operation failed: query failed` |
| `match` | `operation failed: query failed` |
| `wildcard` | `operation failed: query failed` |
| `match_all` | `operation failed: query failed` |
| `range` | `operation failed: query failed` |
| `bool`/`must` | `operation failed: query failed` |
| raw query string | `operation failed: query failed` |

**[MEASURED]** — 8 of 8. And `last_error()` returned `None` every time, so there
is no diagnostic to act on either.

What *does* work through the shipped library: `put`, `get`, `delete`,
`list_by_prefix`, `list_by_table`, `history`, and the backup/export calls.
**[MEASURED]** That is a key/value store with per-key history. It is not a
queryable database.

---

## 4. The gap against what the core needs

The timing here is fortunate: another agent has just landed
`crates/zer0-core/src/session_store.rs`, which writes the persistence contract
down as a Rust trait with the reasoning in the doc comments. That gives this
assessment a precise standard instead of a vibe. Two clauses of that contract
are the ones at issue, and I am quoting the trait rather than paraphrasing it.

### 4.1 Atomicity — `SessionStore::save`

> **All of it or none of it.** A save that returns `Err`, or that is cut short
> by the process dying, must leave the previously stored session exactly as it
> was. […] **A backend that can leave half a session behind is not a legal
> implementation of this trait.**

**ChronDB cannot satisfy this.** `save-document` commits one file path per call,
so each `put` is its own Git commit. I verified this directly: 407 `put` calls
produced **407 commits** on `main`. **[MEASURED]**

`with-transaction` exists and looks like the answer, but it is **annotation
only** — a thread-local context whose values get written into Git notes. Its
rollback path is, in full:

```clojure
(defn- commit-rollback! [ctx]
  (-> ctx (assoc :status :rolled-back :ended-at (now-iso))
          (update :flags into (normalize-flags ["rollback"]))))
```

It sets a keyword and appends a string. **No data is reverted.** **[READ:
`src/chrondb/transaction/core.clj`]** Every call site wraps a single operation.
The author's own design blog post says it plainly: *"Git's concurrency model is
based on merges, not locks or ACID transactions"* — which contradicts the
README's ACID banner. **[READ]**

Could atomicity be built on top? In principle, yes, and Git is actually a decent
substrate for it: write everything to a branch, then move the ref once. But
`libchrondb`'s C API exposes no way to do that — there is no "commit these N
documents together" call, and no ref-manipulation primitive. It would need to be
built inside ChronDB and released. Batching writes into single commits is listed
in the project's own future work. **[READ]**

### 4.2 Corrupt vs empty — `SessionStore::load`

> `Ok(None)` and `Err` are different answers and must never be swapped. […] A
> backend that reports a read it could not perform as `Ok(None)` destroys the
> session on the first autosave twenty seconds later, with no backup and no
> warning.

The intuition in the brief was that a Git-backed store should be *good* at this —
an invalid repository is surely distinguishable from an empty one. I tested it
rather than assuming. It is not.

| Repository state | `open_path` | `list_by_table` |
| --- | --- | --- |
| Empty directory | **OK** (42.7 ms) | `[]` — correct |
| `HEAD` overwritten with binary garbage | **OK** (22.2 ms) | **`[]`** |
| `HEAD` truncated mid-ref | **OK** (21.6 ms) | **`[]`** |
| Every loose object overwritten with `CORRUPT` | **OK** (16.9 ms) | **returned the document** |

**[MEASURED]**

Rows two and three are the ADR-0017 catastrophe exactly: an unreadable store
reports itself as a fresh profile. zer0 would start empty, and twenty seconds
later autosave over it. The current SQLite backend fails loudly here, which is
the whole point of ADR-0006's third row.

Row four is its own kind of alarming. I destroyed every object in the Git store
and the document still came back — because the read was served by the **Lucene
index**, not by Git. The two halves can disagree with no detection and no
reconciliation. Whichever one you trust, the other can be silently wrong.

zer0 could partly defend itself: validate the repository independently before
handing it to ChronDB, and treat "opened but zero spaces" as suspicious when a
marker file says a session existed. But that is the core re-implementing the
guarantee its store is supposed to provide, and the marker file would itself
need to be... a file. Probably a SQLite one.

### 4.3 Query — the reducer's frecency ranking

`crates/zer0-core/src/command_bar.rs` ranks suggestions with a hand-written
fuzzy score plus `frecency_bonus(visit_count)`, over `session.history`.

Here the honest answer is that **this is not a problem**, and it is worth saying
because it cuts *for* ChronDB. The new `SessionStore` trait is explicit:

> The core does not know what a table is. It hands over a whole `Session` and
> asks for a whole one back […] So there is no query interface here, because
> there is nothing to query.

Ranking happens in memory over the loaded `History`. The store never has to sort
by frecency. So the broken query layer (§3) does not block *session persistence*
— it only kills the "we get Lucene search for free" upside.

Two things do follow, though. Full history is loaded into memory at launch and
rewritten on every save, so a Git backend inherits that whole-history rewrite as
per-entry commits — see the churn numbers. And if we ever *wanted* server-side
frecency ranking, ChronDB could not express it even with the query layer fixed:
sorting takes a field name, not an expression, so frecency would have to be
precomputed and stored — meaning a new commit for every entry whose score
decays. **[READ]**

### 4.4 Concurrency

zer0 today holds one connection in one process. **[READ]** ChronDB's concurrency
control is optimistic, with an **in-process** version tracker and an in-process
per-branch lock. It is safe across threads in one process; **across processes it
falls back to JGit and Lucene advisory file locks only.**

The author has published a candid postmortem of exactly these failures — two
isolates in one process overwriting each other, orphaned `.lock` files after
`kill -9` surfacing as `OpenFailed("")`, and data loss between two CLI runs
because `Git.init()` rewrote `HEAD` on open. Those are fixed, but they establish
the shape of the risk. **[READ]** `util/locks.clj` now deletes `.lock` files it
judges stale after 60 seconds — a heuristic that, on a machine where a second
zer0 is genuinely running, deletes a live lock. **[READ]**

Two zer0 windows in one process would be fine. Two launches would be a coin
flip. I did not get a clean measurement of the two-process case and am not going
to report one I do not have.

---

## 5. Distribution and reproducible builds

This is where ChronDB collides hardest with a decision this project has already
made. `scripts/webkit/README.md` opens with:

> zer0 must not depend on whichever WebKit happens to be installed on the
> machine that runs it. These scripts fetch a pinned WebKit revision and build
> it, so the engine the browser ships is the engine we chose.

The ChronDB Rust crate does the opposite. **[MEASURED]** After my first run,
this appeared:

```
~/.chrondb/lib/libchrondb.dylib     84.5 MB
```

The crate **downloads the native library from a GitHub release at first use**,
into the user's home directory. It pulls `ureq`, `rustls-webpki`, `tar`, `flate2`
and `dirs` into the dependency graph to do it. **[MEASURED: these crates compiled
as dependencies of `chrondb`.]**

For a shipped `.app` this is disqualifying as-is: a network fetch of an
unpinned artifact, landing outside the bundle, unsigned by us, into a path we do
not control. It is fixable — `CHRONDB_LIB_DIR` overrides the location at build
time **[READ]** — so we could vendor the `.dylib` into the bundle and codesign
it. But then we are shipping an 88.6 MB binary blob that we did not build.

Can we build it ourselves? **Yes, in principle.** `deps.edn` has a `:shared-lib`
alias, and `dev/chrondb/shared_library.clj` drives `native-image --shared`,
locating GraalVM via `GRAALVM_HOME` or `JAVA_HOME`. **[READ]** This machine has
Oracle GraalVM 21 installed, so the toolchain is obtainable. I did **not**
attempt the build — it is a long native-image compile and it was not the best
use of the time against the blockers already found. So "we can build it from
source" is **plausible but unverified**, and given that the *published* artifact
has a broken query layer, a from-source build would be mandatory rather than
optional.

Version discipline is also weak. crates.io's latest is `0.2.3-dev.ed9ada3` —
every recent version is a `-dev.<sha>` prerelease. Total downloads across all
versions: **1,187**. **[MEASURED]** The repo has one GitHub release, flagged
`prerelease: true`. The `CHANGELOG.md` still contains Leiningen template
boilerplate about "widget maker" under versions dated 2019. **[READ]**

---

## 6. Platforms, and whether iOS survives

| Platform | Published `libchrondb` |
| --- | --- |
| macOS arm64 | Yes |
| macOS x86_64 | **No** |
| Linux x86_64 | Yes |
| Linux arm64 | **No** |
| iOS / iPadOS | **No** |

**[MEASURED: release asset list.]**

On iOS specifically, the brief was right to flag it and right to demand
verification rather than assumption — but the reasoning needs correcting in both
directions.

**The JIT objection does not apply.** A GraalVM native-image is ahead-of-time
compiled; it does not generate code at runtime, so App Store rule 2.5.2 and the
absence of an iOS `allow-jit` entitlement are not what stands in the way. The
brief's assumption ("Apple does not permit JIT, which likely rules out a JVM
entirely") is correct *about a JVM* and is simply not the operative question for
an AOT shared library. I audited the two places in Substrate VM that actually
request executable memory: Truffle runtime compilation (opt-in, off by default)
and FFM upcall trampolines. The GC and the deoptimizer do not need W+X. **[READ]**

**Upstream GraalVM does not target iOS, and Oracle has declined to.**
`oracle/graal#8776` (2024-04-16) was opened and closed the same day: *"we don't
support iOS platform and we currently do not have any plans to support it in the
near future."* Re-raised in October 2025 with an offer of sponsorship — no
reply. Mandrel does not target Apple mobile either. **[READ]**

**But iOS is "unsupported and demonstrably feasible", not "blocked".** Two
independent working precedents:

- **Gluon's Substrate** does build iOS shared libraries — `gluonfx:sharedlib`,
  `-shared -undefined dynamic_lookup`, and the docs scope it to *pure Java
  libraries without any UI/JavaFX code*. It is **not** JavaFX-coupled, contrary
  to what I assumed when I wrote §6 the first time. The catch is age: Gluon's
  GraalVM fork's last release is **JDK 23, September 2024** — tooling alive,
  compiler frozen ~23 months. **[READ]**
- **`phronmophobic/grease`** runs **Clojure on iOS with stock Oracle GraalVM
  21**, no Gluon fork — its own static labs-openjdk build, its own CAP cache, and
  a hand-maintained 35.5 KB reflection config. README: *"Update - May 2026:
  Grease is back!"*, pushed 2026-06-28. **[READ]**

So the honest revision is: **iOS is possible, at the cost of becoming the
maintainer of a toolchain Oracle has twice refused to own.** That is a different
objection from "impossible", and a more serious one for a two-person project.

Three iOS-specific hazards worth recording, because two of them are the kind
that pass every test until a real device:

- **FFM upcall trampolines.** `TrampolineSet` allocates executable memory and
  writes instructions into it. It is write-then-protect (correct design), but on
  iOS an anonymous page cannot become executable without a signature, so it
  fails anyway. It compiles, it passes on macOS (where `MAP_JIT` works under
  `allow-jit`), and it breaks only on device. Substrate only requests `MAP_JIT`
  for `MACOS_AARCH64`; `IOS_AARCH64` is a sibling class, not a subclass, so it
  never even tries. **[READ]**
- **Default heap versus jetsam.** Native-image's Serial GC defaults max heap to
  **80% of physical memory**; iOS jetsam kills at roughly **50%**. On an 8 GB
  device that is a 6.4 GB heap ceiling against a ~4 GB kill threshold. An
  explicit `-Xmx` is a correctness requirement, not a tuning knob. Against our
  measured **~85 MB floor and 289 MB observed**, in a process that also hosts
  WebKit content processes, this is the hazard I would worry about most. **[READ
  + MEASURED]**
- **Thread stacks.** Substrate defaults `IOS_AARCH64` to the OS stack size;
  Apple gives secondary threads **512 KB**. ChronDB's Rust binding asks for
  **64 MB** because Lucene and JGit recurse deeply. Any entry into the isolate
  would need a dedicated thread with an explicit stack. **[READ + MEASURED]**

One genuinely favourable data point, which I want to record because it cuts for
ChronDB: **ChronDB pins Lucene 9.8.0** **[READ: `deps.edn`]**, and 9.8.0 is
exactly where both maintained Lucene-on-native-image precedents
(`quarkus-lucene`, and the Clojure one, `dainiusjocas/lucene-grep`) also pin.
Lucene 10 dropped the `ByteBuffer` fallback and is `MemorySegment`-only, which
native-image currently disallows in the image heap. ChronDB is on the last
version anyone has made work.

**The conclusion holds regardless:** there is no published iOS artifact today
**[MEASURED]**, so "no SQLite dependency" is not reachable on iOS in the near
term. Adopting ChronDB on macOS means running **two backends, not zero** — which
is an argument *for* the `SessionStore` trait and *against* deleting the SQLite
implementation behind it.

---

## 7. Licensing — decide this before anything else

**ChronDB is AGPL-3.0.** **[MEASURED: `LICENSE` reads "GNU AFFERO GENERAL PUBLIC
LICENSE"; 21 source files carry Affero headers.]**

Note that the project's own relicensing blog post says "GPLv3" — the file on disk
is AGPL, which is stricter. **[READ]** The relicense happened because JGit is
EDL-1.0 and Git itself is GPLv2-only; the post explicitly warns that closed
proprietary integrations need evaluation. **[READ]**

zer0 is open source, which helps, but AGPL is not a formality here:

- Linking `libchrondb` into `Zer0.app` makes the combined work subject to AGPL
  terms. zer0's current `LICENSE` needs to be checked for compatibility — I have
  not done that analysis and it is not an engineering question.
- AGPL's §13 network clause is usually discussed for servers. A browser is not a
  server, but ChronDB's remote-sync feature (`push`/`pull` to a Git remote) is
  exactly the kind of feature that invites the argument.

**This should be settled before any engineering effort is spent.** If the
licensing answer is no, nothing else in this document matters.

---

## 8. Latency and the socket question — resolved

For the record, since the original brief asked and the answer is now different:
there is **no socket**. `put` and `get` are in-process C calls across an FFI
boundary. The Rust binding's dedicated 64 MB-stack worker thread adds a message
hand-off per call, which the author measures at ~50–100 µs. **[READ]**

That overhead is irrelevant next to the 2.97 ms `put`. The cost is Git and
Lucene doing real work — writing objects, updating refs, reindexing — not
transport. No PostgreSQL wire client, no Redis client, no `tokio-postgres`,
no connection pool. That entire branch of the analysis is closed.

---

## 9. What we would genuinely gain

I want to state this at full strength, because it is the real reason to want
this and it deserves better than a grudging paragraph.

**Session history as a first-class product feature.** Every save is a commit.
That means "what did my browser look like last Tuesday" stops being impossible
and becomes a query. For a browser whose Spaces are *environments* rather than
tab groups, that is not a gimmick — it is the natural extension of the idea.
Restore a Space to how it was before you reorganised it. Diff two Spaces. Recover
the twelve tabs you closed on Friday without having kept a closed-tab ring alive
in memory. No mainstream browser has any of this, and the reason is that they all
chose stores that throw the past away.

The per-key history API works today: `history(id)` returns commits with author,
timestamp and the document at that point, and restoration is append-only so the
audit trail survives. **[MEASURED — `history` returned real commit metadata;
READ for restore semantics.]**

**Sync without building a sync service.** `setup_remote` / `push` / `pull` means
session sync across machines is a Git remote, not a backend we operate. For a
project without a server, that is a genuinely large shortcut.

Two honest deductions from the enthusiasm:

- **Lucene full-text search is not currently among the gains.** It is the item I
  most expected to be able to bank, and it does not work in the shipped library
  (§3). Even fixed, it would not serve the frecency ranking, which the core does
  in memory anyway.
- **Time travel is by commit hash, not timestamp.** "Last Tuesday" needs a
  timestamp→commit resolution step. `temporal/core.clj` has the code and it is
  wired to nothing. **[READ]** So the feature is closer than in SQLite, but it is
  not free either.

**And here is the part worth weighing hardest:** most of this is achievable
without replacing the store. `session.sqlite` is a file. A commit of that file
after each successful save gives version history, time travel by timestamp, and
`git push` sync — using the store we already trust for atomicity and corruption
detection. It costs a few hundred lines and no new dependency, and because a
save is already a full rewrite, a commit per save is the natural granularity.
It gives up per-key granular history, which is a real loss, but it gets the
headline feature at roughly 1% of the risk in this document.

That is the option I would put in front of the owner alongside "adopt ChronDB",
because it targets the thing that is actually wanted.

---

## 10. Recommendation

**Do not replace SQLite with ChronDB now.** Ranked by what would have to change:

1. **Licensing (AGPL).** Not an engineering problem. Settle first or stop.
2. **No atomic multi-key save.** Violates the `SessionStore` contract explicitly.
   Needs a new primitive inside ChronDB, released.
3. **Corrupt reads as empty.** Violates the other clause, and is the specific
   failure ADR-0017 exists to name. Measured, not theorised.
4. **Query layer non-functional in the shipped library.** Build defect; removes
   the Lucene upside.
5. **88.6 MB, arm64-only, macOS 14+, fetched over the network at first run.**
   Against ADR-0005's whole posture on shipping what we chose.
6. **Unbounded on-disk growth** under a 20-second full-rewrite save.
7. **No iOS artifact**, so the stated goal of zero SQLite is unreachable
   regardless.

**What I would do instead:**

- **Keep SQLite behind the new `SessionStore` trait.** That work is right on its
  own merits and this assessment strengthens it — it is what makes any future
  swap a contained decision instead of a rewrite.
- **Take the Git-history feature via `git`, not via a new database** (§9), if the
  version-history product idea is the actual goal. It is the cheap 90%.
- **Keep ChronDB in view as a second backend, not a replacement.** The trait
  makes an experimental `ChronDbSessionStore` possible behind a Cargo feature
  without touching the SQLite path. That is a reasonable thing to build when the
  blockers above clear — and it is exactly the kind of thing that proves the
  abstraction was worth having.

If the owner still wants ChronDB shipped despite this, the smallest honest
version is: **macOS only, vendored and self-built `.dylib`, SQLite retained for
iOS**, plus a zer0-side integrity marker to compensate for §4.2, and accepting
that a torn save is possible. I would want ADR-0006's atomicity guarantee
formally amended before that ships, not quietly broken.

---

## 11. When to revisit

Concrete triggers, in the style of the other ADRs:

1. **When ChronDB exposes a multi-document commit** in the C API — one call that
   makes N writes one commit, or a ref-move primitive we can build on.
2. **When a corrupt repository is reported as an error** rather than as an empty
   result. The test is in this document and takes a minute to re-run.
3. **When `execute_sql` and `query` work in a released `libchrondb`.** Same
   harness.
4. **When there is an iOS artifact.** The §6 question is now answered: it is
   buildable via Gluon's `sharedlib` or the `grease` route, and the cost is
   owning the toolchain. The trigger is therefore someone other than us shipping
   one — or ChronDB pinning a Lucene it can keep building, since 9.8.0 is
   already the last version anyone has made work under native-image.
5. **If the licensing analysis comes back clean** — because if it does not, none
   of the above matters.

---

## 12. What a migration would look like, if it goes ahead

Recorded so the option stays open, and because the shape informs how the
`SessionStore` trait should be judged.

### 12.1 Can both backends coexist?

**Yes, and they must.** `SessionStore` already makes this work: `load()` and
`save()` hand whole `Session` values across, and opening is deliberately *not*
on the trait — so a path-based backend and a directory-based one both fit
without a lowest-common-denominator address type. A `chrondb` Cargo feature
alongside `store` keeps the dependency out of default builds, exactly as `ffi`
and `ext` already do.

Coexistence is not optional anyway: iOS needs SQLite (§6), and the corrupt-read
gap (§4.2) means we would want to run both and compare before trusting either.

### 12.2 Data shape

ChronDB keys are `table:id`, stored as `table/table_COLON_id.json`. **[MEASURED]**
The mapping from the current eleven tables is mechanical:

| SQLite table | ChronDB key | Note |
| --- | --- | --- |
| `spaces` | `space:<id>` | `position` becomes a stored field — Git has no row order |
| `tabs` | `tab:<id>` | ditto; `space_id` is a field, no FK enforcement |
| `splits` | `split:<space_id>` | |
| `history` | `history:<hash(url)>` | URLs need hashing — `/` and `:` are escaped but keys get long |
| `routes` | `route:<position>` | order must be a field |
| `keybindings` | `keybinding:<chord>` | composite PK becomes a composed key |
| `downloads` | `download:<id>` | |
| `extension_consent` | `extconsent:<ext_id>` | |
| `extension_permissions` | `extperm:<ext_id>:<kind>:<value>` | no cascade — deletes become explicit |
| `blocking_exceptions` | `blockex:<host>` | |
| `meta` | `meta:<key>` | |

Three things stop being free and become our job: **ordering** (no `ORDER BY
position` — order is data), **cascading deletes** (no foreign keys), and
**replace-not-merge** (`save()` currently `DELETE`s then re-inserts; against
ChronDB, removing a key needs an explicit `delete` per absent key, which means
diffing the previous session against the new one *before* writing).

That last point compounds §4.1 badly: a full-rewrite save becomes N writes **and**
M deletes, each its own commit, with no boundary around them.

### 12.3 Order of work

1. **Settle the licence.** Everything else is wasted if this fails.
2. **Build `libchrondb` from source** and confirm the query layer works in our
   build. Concretely: make the SQL parser namespaces statically reachable so
   they are AOT-compiled into the image (§3), and use
   `-H:+PrintAnalysisCallTree` to tell "never compiled" apart from "compiled
   then pruned". `dainiusjocas/lucene-grep` is a working Clojure + Lucene 9.8.0
   native-image build and the closest available playbook. If the query layer
   still cannot be made to work, stop — the defect is then structural rather
   than a bad release.
3. **Vendor and codesign** the `.dylib` into `Zer0.app`; pin the revision in a
   `version.txt` the way `scripts/webkit/` does. No network fetch at build or run.
4. **Write `ChronDbSessionStore`** behind a feature flag, implementing the trait.
   Do not touch `store.rs`.
5. **Run the trait's contract tests against both backends.** The clauses in
   §4.1 and §4.2 need to be *tests*, not prose — including the corrupt-repository
   case, which currently has no test on the SQLite side either (ADR-0006 names
   this as its most dangerous debt).
6. **Dual-write behind a debug setting.** Write both, read SQLite, compare. This
   is how the corrupt/empty and torn-save risks get measured on real sessions
   instead of harnesses.
7. **Add `git gc`/packing**, or accept the growth in §3. This is not optional at
   the measured rate.
8. **Only then** consider making it the default on macOS — and even then, SQLite
   stays for iOS.

Steps 1–3 are all gating and none of them are code. That is the honest summary
of the cost.

---

## Appendix: reproducing this

The harnesses are in the session scratchpad, outside the repository:

- `libtest/bench.c` — C harness; `clang -I…/include -L…/lib -lchrondb`, run with
  `DYLD_LIBRARY_PATH` set. Times isolate creation, open, `put`/`get`
  distributions, `list_by_table`, `execute_sql`, `history`; reads RSS via
  `task_info`.
- `rusttoy/` — Rust crate depending on `chrondb = "*"`. Subcommands cover the
  corrupt-vs-empty cases, the churn simulation, and the query-shape matrix.

Nothing in `crates/zer0-core/` or `apple/` was modified. `store.rs`,
`shortcuts.rs` and `apple/Sources/Zer0Shell/` were read only.
