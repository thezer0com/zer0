# Licensing of zer0

A survey of facts, not legal advice. Everything marked **verified on disk** was
read from the file named, at the path named, on the date named. Anything that is
interpretation is isolated in the final section.

- **Survey date:** 2026-08-09
- **WebKit inspected:** tag `WebKit-7624.4.5.14.1`, checkout at
  `~/.cache/zer0/webkit/src` (pinned in `scripts/webkit/version.txt`)
- **Rust:** 149 packages in `Cargo.lock`; licenses read from the `license` field
  of each crate's `Cargo.toml` in the registry cache (`~/.cargo/registry/src/`)

---

## Verdict

**MIT works for zer0's own code.** Nothing in the dependency tree forces the
project's own source to be copyleft — but the condition is that the
**distributed binary** carry notices, license texts, and an offer of WebKit
source, and, in embedded-engine mode, that a user be able to **replace the LGPL
frameworks inside the `.app` with a modified build and still have the app
launch**.

Put plainly: MIT describes what you grant over *your* code. It does not describe
or erase what you owe third parties when you ship a `.zip` with WebKit inside.

### Two things that have to change today

1. **`Cargo.toml` declared `license = "AGPL-3.0-or-later"`.** Changed to `MIT`
   as part of this work. The repository **has no commits at all**
   (`git rev-list` fails with "does not have any commits yet"), so the AGPL was
   never published and there is no outside contributor whose consent the
   relicensing would need. The relicensing is unconstrained — **this window
   closes the moment a first external contributor lands a patch.**
2. **`README.md` (around line 328) still says `AGPL-3.0-or-later`.** Not edited
   here (another agent owns that file). It must become MIT, or the repository
   declares two contradictory licenses.

---

## 1. Rust dependencies

### The short version

Of the 149 entries in `Cargo.lock`, **none is GPL, AGPL, LGPL-only, or SSPL**.
There is exactly **one copyleft family**: `uniffi`, under **MPL-2.0**.

| Family | License | Obligation |
|---|---|---|
| `uniffi`, `uniffi_bindgen`, `uniffi_core`, `uniffi_macros`, `uniffi_meta`, `uniffi_pipeline`, `uniffi_udl`, `uniffi_internal_macros` (0.32.0) | **MPL-2.0** | **File-level** copyleft. See detail below. |
| `icu_*`, `litemap`, `potential_utf`, `tinystr`, `writeable`, `yoke*`, `zerofrom*`, `zerotrie`, `zerovec*` | **Unicode-3.0** | Permissive. Requires reproducing the Unicode license text and data notice. |
| `unicode-ident` | **(MIT OR Apache-2.0) AND Unicode-3.0** | The `AND` is not optional: Unicode attribution is required even if you pick MIT. |
| `zopfli` | **Apache-2.0** | Attribution, preserve `NOTICE`, patent grant with defensive termination. |
| `foldhash`, `zlib-rs` | **Zlib** | Attribution; mark modified versions as modified. |
| `rusqlite` (0.40.2), `libsqlite3-sys` (0.38.2) | **MIT** | Attribution. |
| `zip`, `nom`, `bytes`, `goblin`, `scroll*`, `strsim`, `simd-adler32`, `siphasher`, `smawk`, `synstructure`, `textwrap`, `weedle2`, `winnow`, `zmij`, `cargo_metadata` | **MIT** | Attribution. |
| `rustix`, `linux-raw-sys` | `Apache-2.0 WITH LLVM-exception OR Apache-2.0 OR MIT` | `OR` — take MIT. |
| `r-efi` (6.0.0) | `MIT OR Apache-2.0 OR **LGPL-2.1-or-later**` | `OR` — take MIT. It is a UEFI-target dependency and never compiles on macOS. |
| `aho-corasick`, `memchr` | `Unlicense OR MIT` | `OR` — take MIT. |
| `adler2` | `0BSD OR MIT OR Apache-2.0` | `OR`. |
| `miniz_oxide` | `MIT OR Zlib OR Apache-2.0` | `OR`. |
| Remainder (~100 crates) | `MIT OR Apache-2.0` and variants | Attribution. |

Full per-crate listing: reproducible with the command in "Reproducing this
survey".

### uniffi (MPL-2.0) — the one that needs care

`uniffi` is pulled in **only with the `ffi` feature**, which is exactly what the
Apple app uses (`crates/zer0-core/Cargo.toml`). A core built without `ffi` — the
case for a future Linux host — has no MPL code in its tree at all.

**For someone who only *uses* the library** (zer0's case: `uniffi_core` is
statically linked into `libzer0_core.a`, with no crate files touched):

- MPL-2.0 §3.3 explicitly permits distributing the "Larger Work" (zer0) under
  **other terms**, including MIT. That is what makes MIT work here.
- MPL-2.0 §3.2 requires that, when distributing in Executable Form, you
  **inform recipients how to obtain the Source Form of the Covered Software**.
  Since uniffi is used unmodified and is public, a link in `THIRD-PARTY.md` to
  `https://github.com/mozilla/uniffi-rs` at tag `v0.32.0` discharges this.

**For someone who *modifies* the crate's files:** each modified file stays
MPL-2.0 and its source must be made available under MPL-2.0. Not the case today
— zer0 consumes uniffi unpatched.

**The genuine grey area, and it is real:** the file
`apple/Sources/Zer0Core/zer0_core.swift` (143 KB, checked into the repo) is
**template output from `uniffi-bindgen`** (askama templates living inside the
MPL crate). The generated file **carries no license header at all** — only
`// This file was autogenerated by some hot garbage in the uniffi crate.`
(verified on disk). Whether the output of an MPL template is a derivative work
of that template is unsettled across the ecosystem. See "What this does not
settle".

### rusqlite and the bundled SQLite

- `rusqlite` declares **MIT**. `libsqlite3-sys` declares **MIT**. Verified in
  the `license` field of each `Cargo.toml`.
- The actual SQLite ships as an amalgamation at
  `~/.cargo/registry/src/*/libsqlite3-sys-0.38.2/sqlite3/sqlite3.c`, **version
  3.53.2** (verified in the file header). Upstream SQLite is **public domain** —
  the crate's MIT covers the Rust wrapper, not the C.
- **Practical consequence: none.** Public domain obliges nothing. But
  `THIRD-PARTY.md` should list SQLite anyway, because the amalgamation is
  redistributed inside the binary and saying what is in there is the right
  practice.

### What is not compiled on macOS

`rsqlite-vfs`, `sqlite-wasm-rs`, `wasm-bindgen*`, and `js-sys` are `wasm32`
target dependencies of `rusqlite`. Licenses confirmed via the crates.io API
(**source: web, not disk**): `rsqlite-vfs` = MIT, `sqlite-wasm-rs` = MIT,
`js-sys` and `wasm-bindgen` = `MIT OR Apache-2.0`. None of them enters the
`.app`.

---

## 2. WebKit — the central question

### It is not one license, and it is not "WebCore is LGPL, the rest is BSD"

WebKit says so itself, in `~/.cache/zer0/webkit/src/Introduction.md:277-283`:

> Much of the code we inherited from KHTML is licensed under LGPL. New code
> contributed to WebKit will use the two clause BSD license. […] you should also
> not change the license, which may be **BSD or LGPL depending on a file**.

License files present in the tree (verified on disk):

| File | Actual content (first line read) |
|---|---|
| `Source/WebCore/LICENSE-LGPL-2.1` | `GNU LESSER GENERAL PUBLIC LICENSE Version 2.1, February 1999` |
| `Source/WebCore/LICENSE-LGPL-2` | `GNU LIBRARY GENERAL PUBLIC LICENSE Version 2, June 1991` (LGPL 2.0) |
| `Source/WebCore/LICENSE-APPLE` | BSD 2-clause, Apple Inc. |
| `Source/JavaScriptCore/COPYING.LIB` | `GNU LIBRARY GENERAL PUBLIC LICENSE Version 2, June 1991` (LGPL **2.0**, not 2.1) |
| `Source/WebKitLegacy/LICENSE` | BSD 2-clause, Apple Inc. |

There is no `COPYING` or `LICENSE` at the root of the checkout. **The license is
per file.**

### How many files, per component

Counted with `grep -l` for the license text over `*.cpp`, `*.h`, `*.mm`, `*.m`.
This is a textual scan, not an SPDX audit — but the order of magnitude is the
point:

| Component | Files | With LGPL header | With BSD header |
|---|---:|---:|---:|
| `Source/WTF` | 1,061 | **101** | 743 |
| `Source/JavaScriptCore` | 3,246 | **185** | 3,062 |
| `Source/WebCore` | 12,533 | **1,931** | 10,539 |
| `Source/WebKit` (WK2) | 5,608 | **640** | 4,963 |
| `Source/WebKitLegacy` | 763 | **8** | 750 |
| `Source/WebGPU` | 221 | **2** | 219 |
| `Source/bmalloc` | 562 | **0** | 561 |

**This is the answer to "which component falls under which".** The answer is:
**every component that goes into the bundle, except `bmalloc`, contains LGPL
files.** The headers read "version 2 of the License, or (at your option) any
later version" — that is **LGPL-2.0-or-later**, which permits treating the whole
set under **LGPL 2.1**, and that is what this document does.

Because those files compile together into a single dylib per framework, **each
framework binary is a combined work distributed under LGPL terms.** There is no
"WebCore.framework which is LGPL" next to a "WebKit.framework which is BSD".

### There is no pure GPL in what ships

Four findings that look like GPL and are not. All verified on disk:

- `Source/WebCore/xml/XPathGrammar.{cpp,h}` — GNU Bison 2.3 skeleton, GPL v2
  **with the Bison special exception** present at lines 27-38 / 29-40 ("you may
  create a larger work that contains part or all of the Bison parser skeleton
  and distribute that work under terms of your choice"). **No contamination.**
- `Source/WTF/wtf/DateMath.h`, `Source/JavaScriptCore/runtime/JSDateMath.h`,
  `Source/WebCore/platform/image-decoders/gif/GIFImageReader.{cpp,h}` — Mozilla
  tri-license `MPL 1.1/GPL 2.0/LGPL 2.1`. Take LGPL 2.1 and it disappears.
- `Source/bmalloc/bmalloc/valgrind.h` — the file states explicitly that "the
  following BSD-style license applies to this one file (valgrind.h) only".
  **BSD.**
- `Source/ThirdParty/libwebrtc/Source/third_party/yasm/COPYING` — **actual
  GPL.** `yasm` is the build-time assembler used by `libvpx`/`libaom`. A `yasm`
  binary does appear in `WebKitBuild/Release/`, but
  `apple/scripts/embed-webkit.sh` copies only named frameworks and two named
  dylibs, so **it does not reach the `.app`**. If anyone ever copies all of
  `WebKitBuild/Release/` into the bundle, that becomes shipped GPL.

### What LGPL 2.1 requires of whoever distributes a binary that embeds it

Text read from `Source/WebCore/LICENSE-LGPL-2.1`, section 6 (lines 271-320).
What section 6 asks, in order:

1. The terms of your work must **permit modification for the customer's own use
   and reverse engineering for debugging those modifications**. MIT permits
   modification without restriction — **satisfied**.
2. **Prominent notice with each copy** that the Library is used in it, that the
   Library and its use are covered by that license, and **supply a copy of the
   license**.
3. If the work displays copyright notices while running, **include the Library's
   copyright notice among them** and point at the copy of the license.
4. **And one more** of options (a) through (e).

The two that matter here, verbatim from disk:

> **a)** Accompany the work with the complete corresponding machine-readable
> source code for the Library including whatever changes were used in the work
> […] and, if the work is an executable linked with the Library, with the
> complete machine-readable "work that uses the Library", as object code and/or
> source code, **so that the user can modify the Library and then relink to
> produce a modified executable containing the modified Library**.

> **b)** Use a suitable shared library mechanism for linking with the Library.
> A suitable mechanism is one that (1) uses at run time a copy of the library
> already present on the user's computer system, rather than copying library
> functions into the executable, and (2) **will operate properly with a modified
> version of the library, if the user installs one**, as long as the modified
> version is interface-compatible with the version that the work was made with.

#### The concrete mechanism, inside a macOS `.app`

**The route is 6(b), and it is already the project's architecture.**

Verified fact: WebKit on macOS produces **separate dylibs per framework**. In
`~/.cache/zer0/webkit/src/WebKitBuild/Release`, `JavaScriptCore.framework` and
`WebGPU.framework` already have binaries and `file` reports
`Mach-O 64-bit dynamically linked shared library arm64`. The build in the cache
is incomplete (`WebKit`/`WebCore`/`WebKitLegacy` have no binary yet — ADR-0005
records that no build of our own has finished), so confirmation of the final
shape came from Orion's bundle, which has the same layout:
`/Applications/Orion.app/Contents/Frameworks/WebCore.framework/Versions/A/WebCore`
is a `Mach-O universal binary […] dynamically linked shared library`.

In other words: `Zer0.app/Contents/Frameworks/` carries `WebCore.framework`,
`JavaScriptCore.framework` and friends as separate dynamic libraries, and the
app resolves them through `LC_DYLD_ENVIRONMENT` →
`@executable_path/../Frameworks` (`scripts/build.sh`). Swapping the dylib and
relaunching is physically possible.

**What breaks 6(b) in practice, and this is the tedious obligation:**

- **Code signing.** An app signed with Developer ID and notarized has a sealed
  bundle. Replacing `Contents/Frameworks/WebCore.framework` **invalidates the
  signature** and the app stops launching. If the user cannot install the
  modified version, the 6(b) mechanism **is not "suitable"**.
  - **Mitigation:** ship with `com.apple.security.cs.disable-library-validation`
    and **document** that after swapping the framework the user must re-sign:
    `codesign --force --deep --sign - /Applications/Zer0.app`. This works today,
    because `apple/scripts/bundle.sh` already signs ad-hoc without the hardened
    runtime.
- **The XPC services are half the engine.** `WebKit.framework` carries
  `XPCServices/com.apple.WebKit.{WebContent,Networking,GPU}.xpc`, spawned by
  `launchd`, and WebKit **deliberately aborts** if the two halves disagree on
  version (`scripts/webkit/README.md`, ADR-0004). If a user swaps only
  `WebCore.framework` for a build from a different revision, it is plausible the
  app simply dies. **I do not know whether the relink works in that scenario —
  it was not tested here, and it is exactly what needs testing before the first
  embedded release.**

**The move that closes the question:** satisfy **6(a) as well**, not just 6(b) —
publish the WebKit source tarball used (exact tag) and the build script. It
costs one release asset and removes the whole argument over whether the 6(b)
mechanism is suitable enough. It is what practically everyone embedding WebKit
does.

### If the project uses the system WebKit instead, what changes

Both modes exist today: `./scripts/build.sh release` uses the system WebKit;
`ZER0_EMBED_WEBKIT=<dir> ./scripts/build.sh release` embeds one. The obligations
are **materially different**.

| | System WebKit | Embedded WebKit |
|---|---|---|
| Redistributes an LGPL binary? | **No.** Nothing in `Contents/Frameworks`. | **Yes.** ~387 MB of frameworks (ADR-0005). |
| Offer of WebKit source | Not owed — Apple distributed the Library, with macOS | **Owed.** 6(a), or 6(c)/6(d) |
| Relink mechanism (6b) | Already exists: dyld resolves `/System/…`; a user swaps via `DYLD_FRAMEWORK_PATH` | **Has to actually work inside the `.app`** |
| "Uses WebKit, LGPL" notice + license text | Prudent to keep | **Required** |
| ANGLE / libwebrtc / dav1d / libaom / opus / vpx / … | Not redistributed | **Redistributed.** BSD attribution required |
| Size of `THIRD-PARTY` | ~150 Rust crates | ~150 crates + WebKit + ~15 C/C++ libraries |
| Rebuild on a WebKit CVE | Apple's responsibility | **Yours** (ADR-0005) |

> **The point most often missed:** MIT on your code changes nothing in either
> column. The LGPL never asked you to change your own code's license — section 6
> literally says "distribute that work **under terms of your choice**". What it
> asks for is notice, a copy of the license, and a way for the user to swap the
> library. It is a *packaging* obligation, not a licensing one.

### What the WebKit build drags in and ships in the bundle

`apple/scripts/embed-webkit.sh` copies: frameworks `WebKit` (required),
`WebCore`, `JavaScriptCore`, `WebKitLegacy`, `WebGPU`, `WebInspectorUI`
(optional), plus the dylibs `libANGLE-shared.dylib` and `libwebrtc.dylib`.

| Component | License (verified on disk) | File | Obligation |
|---|---|---|---|
| **ANGLE** (`libANGLE-shared.dylib`) | **BSD 3-clause** | `Source/ThirdParty/ANGLE/LICENSE` | Reproduce copyright and conditions in the binary's documentation. Non-endorsement clause. |
| **libwebrtc** (`libwebrtc.dylib`) | **BSD 3-clause** + a separate **`PATENTS`** file | `Source/ThirdParty/libwebrtc/Source/webrtc/{LICENSE,PATENTS}` | Attribution. `PATENTS` is a Google patent grant **with defensive termination**: suing anyone over WebRTC patents terminates your patent license. |
| **dav1d** (`libdav1d*.a`, static, inside WebCore/PAL) | **BSD 2-clause** | `Source/WebCore/PAL/ThirdParty/dav1d/COPYING` | Attribution. **There is no `PATENTS` file in dav1d in this tree** — verified. dav1d is an AV1 decoder; AV1 patent rights come from AOMedia, not from dav1d. |
| **libaom** (`libaom.a`, via libwebrtc) | **BSD 2-clause** + **`PATENTS` = Alliance for Open Media Patent License 1.0** | `Source/ThirdParty/libwebrtc/Source/third_party/libaom/source/libaom/{LICENSE,PATENTS}` | Attribution **and** the AOM Patent License 1.0, which has defensive termination **and** a reciprocity condition: whoever distributes an Implementation must make their own Necessary Claims available under the same license. It is the only dependency here that imposes something beyond attribution. |

**The list of four you asked about is incomplete.** `libwebrtc.dylib` also
carries, verified under `Source/ThirdParty/libwebrtc/Source/third_party/`:

| Library | License |
|---|---|
| `abseil-cpp` | Apache-2.0 |
| `boringssl` | Apache-2.0 (with inherited OpenSSL/ISC fragments) |
| `libvpx` | BSD-3 + `PATENTS` |
| `libyuv` | BSD-3 + `PATENTS` |
| `opus` | BSD-3 (+ `LICENSE_PLEASE_READ.txt` on patents) |
| `libwebm` | BSD-3 |
| `libsrtp` | ISC |
| `crc32c` | BSD-3 |
| `pffft` | BSD-like |
| `rnnoise` | BSD |
| `json` | (not individually inspected) |
| `yasm` | **GPL** — build tool, **does not ship** |

`Source/ThirdParty/skia` exists in the tree (BSD-3) but is the GTK/WPE graphics
backend; it does not appear in the macOS Release output.

---

## 3. Swift / Apple

`apple/Package.swift` (verified): **zero external dependencies**. Four local
targets only — `Zer0CoreFFI`, `Zer0Core`, `Zer0Shell`, `Zer0` — plus one test
target. No `.package(url:)` anywhere.

Implications of using Apple's SDK and frameworks:

- **System frameworks** (`AppKit`, `Foundation`, `WebKit`) are linked, not
  redistributed. Nothing enters the bundle. They create no attribution
  obligation.
- **What you accept is the Apple Developer Program License Agreement**, not an
  open source license. It governs SDK use, signing, notarization, and
  distribution — including distribution outside the App Store when using
  Developer ID.
- **Do not redistribute Apple's binary frameworks.** That is precisely the point
  ADR-0005 and `scripts/webkit/README.md` record as resolved by building from a
  public tag. The Orion stand-in used today (`embed-webkit.sh --orion`) **is a
  third party's WebKit and is not yours to redistribute** — the script marks
  such bundles with `Contents/Resources/webkit-stand-in.txt`. **No bundle marked
  that way may leave the machine.**
- **Code generated by `uniffi-bindgen`** lives in `apple/Sources/Zer0Core/`. See
  the MPL grey area in section 1.

---

## 4. Chrome Web Store — Terms of Service, not licensing

**This is not a licensing question. It is kept separate on purpose.**

### Verifiable fact

`crates/zer0-core/src/ext/mod.rs::download_url` builds:

```
https://clients2.google.com/service/update2/crx?response=redirect&acceptformat=crx2,crx3&prodversion={CHROME_VERSION_FOR_DOWNLOADS}&x=id%3D{id}%26uc
```

*Corrected in place:* this used to cite `mod.rs:83-95` and to write the version
as a caller-supplied `{chrome_version}`. The line numbers moved, and ADR-0078
made the version a constant in that same file. Neither changes anything below.

The code comment already says it: *"this is not a documented public API, and the
Chrome Web Store terms do not grant third-party clients access to it."*
`README.md` repeats it under "Known limits".

No Google code is copied, embedded, or redistributed. **There is no copyright
obligation here.** Downloaded extensions have their own licenses, but the person
downloading them is the user, not zer0 — the project redistributes no extension.

### Risk (not a fact — a risk)

- The endpoint is Chrome's internal updater API. **Google can change it, block
  it by User-Agent, or require authentication at any time**, without notice and
  without breaching any agreement — because there is no agreement.
- The Chrome Web Store terms do not grant third-party clients access. Using it
  anyway is ToS exposure, not copyright exposure: the typical consequence is
  being blocked, not sued. But it is a product decision someone made, not a
  detail.
- **Do not conflate this with zer0's license.** MIT on zer0 stays valid whatever
  Google decides about that endpoint.
- Adjacent, and a security matter rather than a licensing one: `README.md`
  records that **CRX RSA/ECDSA signatures are not yet verified**. Installing
  unverified code from an endpoint you are not authorized to use is the worst of
  both worlds at once.

---

## 5. What the project must do to be compliant

Actionable items, ordered by when they hurt.

### Now, before the repository is published

- [x] **`LICENSE` at the root** with the MIT text,
      `Copyright (c) 2026 Thiago Avelino`.
- [x] **`Cargo.toml`**: `license` from `AGPL-3.0-or-later` → `MIT`.
- [ ] **`README.md`**: the "Licence" section from `AGPL-3.0-or-later` → `MIT`.
      *(not edited here — another agent owns that file)*
- [ ] **`THIRD-PARTY.md`** at the root, containing:
  - the ~150 Rust crates with version and license (generate it, do not hand-write
    it — see "Reproducing this survey");
  - the full text of Apache-2.0, Unicode-3.0, Zlib, 0BSD, MPL-2.0 and the BSD
    licenses, once each;
  - a link to `https://github.com/mozilla/uniffi-rs` tag `v0.32.0`, discharging
    MPL-2.0 §3.2;
  - a mention of SQLite 3.53.2 (public domain) bundled via `libsqlite3-sys`.

### Before the first `.app` leaves your machine — system WebKit mode

- [ ] Ship `THIRD-PARTY.md` **inside the bundle**, at
      `Contents/Resources/THIRD-PARTY.txt`. A file on GitHub does not accompany
      a `.dmg`.
- [ ] An **"Acknowledgements"** menu item (or an About tab) that opens that
      file. It is the LGPL §6 "prominent notice" and the BSD/Apache/Unicode
      attribution requirement in one move, and it is cheap.

### Before the first `.app` with an embedded WebKit — **this is where it hurts**

- [ ] **Publish the WebKit source used, at the exact tag.** Today:
      `WebKit-7624.4.5.14.1` (`scripts/webkit/version.txt`). A GitHub release
      asset with the tarball of `https://github.com/WebKit/WebKit` at that tag,
      **plus any local patches applied**, plus `scripts/webkit/` (fetch, build,
      version) so a user can reproduce the binary. That is option 6(a). **The
      tag must be published alongside every binary release — if the pin moves
      and the tarball does not, you fall out of compliance without noticing.**
      With the stable/canary split (ADR-0109), **both channels pin the same
      tag**, so one tarball per tag discharges 6(a) for both bundles — but each
      channel's release notes must reference it. See §6.
- [ ] **An LGPL notice inside the app**, containing at minimum: zer0 uses
      WebKit; WebKit is partly covered by LGPL 2.1; the full LGPL 2.1 text is
      included; where to obtain the source; how to replace the frameworks.
- [ ] **The full LGPL 2.1 text in `Contents/Resources/`.** Copy it from
      `~/.cache/zer0/webkit/src/Source/WebCore/LICENSE-LGPL-2.1`. The LGPL
      requires you to "supply a copy of this License" — a link is not a copy.
- [ ] **The relink mechanism has to actually work.** This is not a paragraph, it
      is a tested procedure:
      1. Do not enable library validation, or ship
         `com.apple.security.cs.disable-library-validation`.
      2. Document the steps: replace
         `Zer0.app/Contents/Frameworks/<X>.framework`, run
         `codesign --force --deep --sign - Zer0.app`, launch.
      3. **Test that procedure** with a genuinely modified WebKit and verify with
         `vmmap $(pgrep -x Zer0) | grep WebKit.framework` that the loaded
         framework is the replacement. Without that test, 6(b) compliance is an
         assertion, not a fact.
- [ ] **BSD attribution for ANGLE, libwebrtc, dav1d, libaom, libvpx, libyuv,
      opus, libwebm, libsrtp, abseil, boringssl, crc32c, pffft, rnnoise** in the
      bundle's `THIRD-PARTY.txt` — each with its copyright and conditions text.
      BSD 2-clause and 3-clause both require this explicitly for binary
      redistribution.
- [ ] **Include the `PATENTS` files** from libwebrtc, libaom, libvpx, and
      libyuv. These are not copyright licenses; they are conditional patent
      grants — libaom's (AOM Patent License 1.0) carries a reciprocity clause.
- [ ] **Never ship a bundle marked with
      `Contents/Resources/webkit-stand-in.txt`.** That is Orion's WebKit. It is
      not yours. Worth a check in `scripts/check.sh`.
- [ ] **Do not copy all of `WebKitBuild/Release/` into the bundle.** There is a
      GPL `yasm` in there. `embed-webkit.sh` copies explicit names today — keep
      it that way.

### Ongoing

- [ ] Regenerate `THIRD-PARTY.md` on every `Cargo.lock` change. A check in
      `scripts/check.sh` that fails when the file is stale solves it.
- [ ] When `scripts/webkit/version.txt` changes, update the published source
      tarball **in the same release**.

---

## 6. Stable and Canary — two channels, doubled obligations

ADR-0109 splits distribution into two `.app` bundles — stable
(`com.thezer0.browser`, "zer0") and canary (`com.thezer0.canary`, "zer0
Canary"). Both ship an embedded WebKit at the same pinned tag, both are
notarized `.dmg`s distributed outside the App Store. **Nothing in §1–5
changes per channel; everything doubles.**

### What doubling means, concretely

| Obligation | One bundle (before ADR-0109) | Two bundles (after ADR-0109) |
|---|---|---|
| LGPL §6(a) source offer | One tarball per release | **One tarball per tag**, referenced from both channels' release notes |
| LGPL §6(b) relink mechanism | Documented once | **Identical procedure per `.app`** — swap frameworks, re-sign ad-hoc, relaunch |
| `THIRD-PARTY.txt` inside the bundle | One file | **One per `.app`**, at `Contents/Resources/THIRD-PARTY.txt` |
| LGPL notice + license text in `Contents/Resources/` | One copy | **One per `.app`** |
| 1Password `browsers.other-trusted-apps` enrolment | One entry | **Two entries** — see ADR-0109 §"Consequences" and `docs/1password-enrolment.md` |

The licence obligations are per-binary. Stable and canary are two binaries;
each has to stand on its own.

### The source offer, satisfied structurally

`scripts/webkit/build.sh` already builds from a public tag pinned in
`scripts/webkit/version.txt` (today `WebKit-7624.4.5.14.1`), fetched by
`scripts/webkit/fetch.sh` from `https://github.com/WebKit/WebKit`. No private
fork, no local patches in the working tree. This is the structural fact that
makes 6(a) cheap: **the source we owe is the source we built from, which is
public already.**

What 6(a) asks beyond that is to *offer* it alongside the binary — not merely
to have built from it. Two ways to discharge that, in order of preference:

1. **GitHub release asset (implemented).** On every tag `v*` (stable) and on
   every canary publish, attach a tarball of
   `https://github.com/WebKit/WebKit` at the pinned `WebKit-*` tag, named
   `webkit-source-<WebKit-tag>.tar.zst`, plus a `SHA256SUMS`. The same asset
   is attached to both the stable and canary releases when they share a pin
   (the common case). Built by `scripts/source-offer.sh` — a `git archive` of
   the pinned tag, so build products cannot ride along — and attached by the
   stable and canary workflows right after the bundle upload, with the
   tarball cached per tag so only a pin bump pays the compression.
   - Pro: free hosting, immutable, content-addressed by the tag.
   - Con: GitHub can rate-limit a large pull; acceptable for source that is
     also reachable from the upstream repo.
2. **`source.thezer0.app` (future).** A static host (S3 + CloudFront, or a
   GitHub Pages redirect) serving the same tarballs at stable URLs of the form
   `https://source.thezer0.app/webkit/<WebKit-tag>.tar.zst`. Worth setting up
   the day a release notes link needs to be permanent independent of GitHub's
   release UI. Not needed for first ship.

**Option 1 is implemented** (`scripts/source-offer.sh`, plus the source-offer
steps in `stable.yml` and `canary.yml`): from the first release that carries
the asset, 6(a) is discharged per tag. Option 2 remains future and optional.

### The relink procedure, per channel

LGPL §6(b) asks that a user be able to replace the LGPL frameworks inside the
`.app` and relaunch. The mechanism is the same for both channels because the
bundle layout is the same (ADR-0109 §"Decision"). Documented once, executed
per `.app`:

```sh
# 1. Build WebKit from the same or a compatible tag (scripts/webkit/build.sh)
# 2. Replace the embedded frameworks:
cp -R build/WebKitBuild/Release/WebKit.framework \
      /Applications/zer0.app/Contents/Frameworks/WebKit.framework
# ... repeat for WebCore, JavaScriptCore, WebGPU, WebKitLegacy
# 3. Re-sign ad-hoc (the Developer-ID signature is now invalid by design):
codesign --force --deep --sign - /Applications/zer0.app
# 4. Launch and verify the replacement loaded:
vmmap $(pgrep -x zer0) | grep WebKit.framework
```

For canary, substitute `/Applications/zer0 Canary.app` and `pgrep -x "zer0
Canary"`. The procedure lives in `docs/webkit.md` (channel-agnostic) and is
referenced from the channel doc (`docs/stable-canary.md`).

**What is still untested:** whether the relink survives when only
`WebKit.framework` is swapped and the XPC services
(`com.apple.WebKit.{WebContent,Networking,GPU}.xpc`) are not. ADR-0005 flags
this; the first stable release is the deadline to test it.

### What does NOT double

- **The MIT licence on zer0's own code.** One `LICENSE` file, one copyright
  line. MIT does not care how many binaries you ship.
- **The WebKit tag.** ADR-0109 pins both channels to the same tag. One tarball
  per tag, not per channel.
- **The Rust / BSD / patent attributions.** They live in `THIRD-PARTY.txt`,
  which is per-bundle, but the *content* is generated from the same
  `Cargo.lock` and the same WebKit tag. One generator, two copies.
- **The Chromium ToS question (§4).** It is about an endpoint, not a binary.
  Unchanged by the channel split.

### The enrolment doubling, and why it is in this doc

ADR-0109 §"Consequences" names it: `browsers.other-trusted-apps` is a list of
**exact** bundle ids, not a prefix match. Enrolling `com.thezer0.browser`
does not enrol `com.thezer0.canary`. Both need their own entry, pinned to the
same Team ID (`24X5CQGA86`, ADR-0105). This is not a licence obligation — it
is a 1Password product decision — but it gates the 1Password extension, which
is a primary use case for the embedded engine, and the licence doc is where
someone tracing "what blocks ship" lands first. The hand-held enrolment
procedure is in `docs/1password-enrolment.md`.

---

## 7. Content blocklists — surveyed, and none of them shipped

Surveyed on **2026-08-09**, when native content blocking landed (ADR-0058).
Every licence below was read from the project's own `LICENSE` file or licence
page at the URL given, not inferred from reputation.

| List | Licence | Source | Bundleable in an MIT binary? |
|---|---|---|---|
| **EasyList / EasyPrivacy** | `GPL-3.0-or-later` **OR** `CC-BY-SA-3.0-or-later` (dual) | [easylist.to/pages/licence.html](https://easylist.to/pages/licence.html) | **Yes**, under the CC option, with attribution |
| AdGuard filters | `GPL-3.0` | `AdguardTeam/AdguardFilters/LICENSE` | No |
| uBlock Origin `uAssets` | `GPL-3.0` | `uBlockOrigin/uAssets/LICENSE` | No |
| Disconnect tracking protection | `CC-BY-NC-SA-4.0` | `disconnectme/disconnect-tracking-protection/LICENSE` | **No — NC** |
| Ghostery `trackerdb` | `CC-BY-NC-SA-4.0` | `ghostery/trackerdb/LICENSE` | **No — NC** |
| DuckDuckGo Tracker Radar / blocklists | `CC-BY-NC-SA-4.0` | `duckduckgo/tracker-radar` | **No — NC** |
| Peter Lowe's ad-server list | **no licence at all** | [pgl.yoyo.org/adservers](https://pgl.yoyo.org/adservers/) | No — informal permission is not a grant |
| Brave `adblock-lists` | `MPL-2.0` | `brave/adblock-lists` | Yes (per-file copyleft) |
| Blocklist Project | `Unlicense` | `blocklistproject/Lists/LICENSE` | Yes, no obligation |
| StevenBlack/hosts | MIT **repo**, aggregating NC sources | `StevenBlack/hosts/license.txt` + the source table in its readme | Only a hand-picked subset |

### The three findings that matter

**1. EasyList's dual licence is real, and it is the one everybody gets wrong.**
Verbatim: *"the contents of the EasyList repository is dual licensed under the
GNU General Public License version 3 … **and Creative Commons
Attribution-ShareAlike 3.0 Unported**"*. You may take the CC option. Under
CC-BY-SA, shipping the list **unmodified** beside a binary is a *Collection*,
not an *Adaptation*, so ShareAlike does not reach zer0's own source. The licence
alone therefore does **not** rule EasyList out.

**2. Converting a list to WebKit's JSON is an adaptation.** A converted
EasyList distributed inside the `.app` would have to go out under CC-BY-SA. The
way round it is to convert **on device** — `WKContentRuleListStore` compiles the
JSON locally and the artefact is never distributed — which is why any future
subscription feature must fetch the source list and compile it here rather than
ship a pre-converted blob.

**3. "It is only data" does not avoid copyleft.** GPLv3 §0 defines the Program
as *"any copyrightable work licensed under this License"*, and the FSF's own
guidance draws the line at aggregation versus combination: *"If the modules are
included in the same executable file, they are definitely combined in one
program."* An `include_bytes!` of a GPL list in `zer0-core` is precisely the case
the FSF names. In the EU the `sui generis` database right (Directive 96/9/EC)
gives such licences additional teeth that the US *Feist* argument does not
answer.

### What zer0 actually does

**It ships no third-party list at all.** `crates/zer0-core/src/blocking.rs`
holds about seventy hosts written by hand in this repository. Nothing was copied
or converted from any list above, which is recorded in the file itself because
provenance *is* the licence position.

**Consequence: no new obligation.** Nothing in section 5's checklist changes,
no attribution screen is owed, and `THIRD-PARTY.md` gains no entry.

**If a subscription is added later** (ADR-0058 records the conditions), the
obligations that arrive with it are:

- Fetch from the publisher; **never mirror the list on our own CDN** — mirroring
  is distributing it again.
- Compile on device; **never distribute a pre-converted JSON**.
- Under CC-BY-SA, attribute *"The EasyList authors ( https://easylist.to/ )"*
  visibly. That is a contractual condition, not a courtesy.
- Never default anything to a **NC** list. Non-commercial terms would restrict
  zer0's own users downstream, which contradicts the MIT label on everything
  else.

### The baseline that costs nothing

WebKit's **Intelligent Tracking Prevention** is not a list. It is an on-device
classifier, on by default in every `WKWebView`, with no licence attached and no
list to ship. It is the floor under all of the above whether blocking is on or
off, and the settings pane says so.

---

## 8. What this does not settle

Where fact ends and interpretation begins. **This is where a lawyer earns their
fee.**

**1. Whether the relink mechanism inside a signed `.app` satisfies LGPL 2.1
§6(b).** Fact: the frameworks are separate, replaceable dylibs. Fact: the
signature seals the bundle. Interpretation: whether "re-sign ad-hoc after
swapping" is an acceptable hurdle or whether it defeats the "suitable
mechanism". There is no case law. **The engineering answer — satisfying 6(a) by
publishing the source — makes the question academic, which is why it is on the
checklist.** If you want the legal answer instead of the workaround, this is the
point to consult a lawyer.

**2. Whether `uniffi-bindgen` output is a derivative work of the MPL templates.**
Fact: `apple/Sources/Zer0Core/zer0_core.swift` is generated by askama templates
inside MPL-2.0 crates and carries no license header. Interpretation: whether the
output inherits the template's license. The informal consensus in the Rust
ecosystem is that it does not, and Mozilla does not treat generated bindings as
MPL — but that is practice, not license text. **I am not certain here and will
not pretend otherwise.** What would settle it: an explicit statement from the
uniffi project (issue or FAQ), or a lawyer reading the templates. Meanwhile the
cost of being conservative is low: MPL-2.0 is file-level copyleft, so even in
the worst case the obligation would be to make the generated `.swift` available
under MPL — a file that is already public in the repo.

**3. Whether linking against the system WebKit creates a notice obligation.**
Fact: you do not distribute the library. Interpretation: LGPL §6 speaks of
distributing "a work that uses the Library", and it is not obvious that the
notice obligation vanishes merely because the Library shipped with the operating
system. **This document's practical recommendation is to ship the notice
either way** — it costs one text file and removes the question.

**4. The per-component LGPL file counts are a textual scan, not SPDX.** A
`grep -l` for a license phrase. Good enough for the conclusion this document
draws ("LGPL is spread across every component"), **not** for a file-by-file
compliance audit. If that audit is ever needed — due diligence, an acquisition,
an enterprise customer — run a real scanner (ScanCode Toolkit, FOSSology) over
the tree at the pinned tag.

**5. Use of the Chrome Web Store update API.** Not licensing, ToS, and the
answer depends on how the product is distributed and monetized. If zer0 becomes
a paid or commercial product, this moves from "risk of being blocked" to "risk
that someone will want to weigh in". Not assessed here.

**6. How distribution is done changes everything.** This document assumes
distribution of a `.dmg`/`.zip` outside the App Store. **The App Store is an
entirely separate conversation**: Apple's rules on downloaded executable code
and JIT, and the plain fact that the App Store gives you no way to deliver LGPL
source to the end user, likely make the embedded mode unworkable there. **Not
investigated.**

**7. None of this is legal advice.** It is a survey of files, done by reading
disk, with sources cited so you can check them. Before the first binary release
with an embedded WebKit, items 1 and 6 above are worth half an hour of a
software lawyer's time. The rest you settle with the checklist in section 5.

---

## Reproducing this survey

```sh
# Licenses of every crate in the lock, from the registry cache
python3 - <<'EOF'
import os, glob, tomllib
data = tomllib.load(open('Cargo.lock','rb'))
regs = glob.glob(os.path.expanduser('~/.cargo/registry/src/*/'))
for p in sorted(data['package'], key=lambda x: x['name']):
    lic = 'LOCAL'
    if 'source' in p:
        lic = 'NOT-IN-CACHE'
        for r in regs:
            ct = os.path.join(r, f"{p['name']}-{p['version']}", 'Cargo.toml')
            if os.path.exists(ct):
                lic = tomllib.load(open(ct, 'rb'))['package'].get('license', '?')
                break
    print(f"{p['name']}\t{p['version']}\t{lic}")
EOF

# License header counts per WebKit component
cd ~/.cache/zer0/webkit/src
for c in WTF JavaScriptCore WebCore WebKit WebKitLegacy bmalloc WebGPU; do
  tot=$(find Source/$c -type f \( -name '*.cpp' -o -name '*.h' -o -name '*.mm' -o -name '*.m' \) | wc -l)
  lgpl=$(grep -rl "Library General Public\|Lesser General Public" Source/$c \
    --include='*.cpp' --include='*.h' --include='*.mm' --include='*.m' | wc -l)
  echo "$c total=$tot lgpl=$lgpl"
done

# Every third-party license file in the WebKit tree
find ~/.cache/zer0/webkit/src/Source/ThirdParty \
     ~/.cache/zer0/webkit/src/Source/WebCore/PAL/ThirdParty \
  -maxdepth 4 \( -iname 'LICENSE*' -o -iname 'COPYING*' -o -iname 'PATENTS*' \)
```
