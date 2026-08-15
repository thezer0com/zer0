# ADR-0021: Installing an extension fetches the CRX from Chrome's update endpoint

- **Status:** Accepted, and the Chrome version it names is superseded by ADR-0078
- **Date:** 2026-03-09
- **Lock:** `crates/zer0-core/src/ext/ext_tests.rs::the_download_url_names_the_extension_being_asked_for`, `crates/zer0-core/src/ext/crx.rs::a_package_claiming_someone_elses_id_is_rejected`, `crates/zer0-core/src/ext/ext_tests.rs::the_store_over_plain_http_offers_nothing`, `crates/zer0-core/src/ext/ext_tests.rs::another_site_cannot_pass_itself_off_as_the_store`, `crates/zer0-core/src/ext/ext_tests.rs::a_second_id_planted_deeper_in_the_path_does_not_win`

## Context

ADR-0020 decided extensions run on `WKWebExtension`, which takes an unpacked
directory. It says nothing about where that directory comes from, and there is
no legitimate answer.

The Chrome Web Store has no public download API. There is no "give me the CRX
for this id" endpoint documented for anyone outside Chrome. What exists is the
URL Chrome's own updater calls:

```
https://clients2.google.com/service/update2/crx?response=redirect
  &acceptformat=crx2,crx3&prodversion=<chrome version>&x=id%3D<id>%26uc
```

Three options were on the table:

1. **Sideloading only.** The person downloads a `.crx` or a folder somewhere
   else and points us at it. Legally clean, and it means the feature does not
   exist for anyone who is not already an enthusiast. "Paste a store link" is
   the only flow a normal person will complete.
2. **Our own store.** Host reviewed packages ourselves. That is a business, not
   a feature, and it is empty on day one.
3. **Call the endpoint Chrome calls.** Works immediately, for every extension,
   with the flow people already understand.

## Decision

We call the endpoint. `crates/zer0-core/src/ext/mod.rs::download_url` builds it,
and the docstring on that function is the decision, written where someone will
find it:

> Note this is not a documented public API, and the Chrome Web Store terms do
> not grant third-party clients access to it. It is behind one function so that
> swapping to a different source is a new implementation rather than a refactor.

The product owner took this decision with the exposure known. It is recorded
here so that nobody later "discovers" it and treats it as an oversight, and so
that whoever inherits this repository is told before a lawyer tells them.

### What is actually being claimed

This is not a grey area we are describing generously. Stated plainly:

- The endpoint is **not a public, authorised API** for third-party clients. It
  exists to serve Chrome.
- The Web Store terms of service **do not permit** what we do with it.
- Google can change it, gate it on a token, key it to a Chrome build, or turn it
  off for us specifically, at any time and with no notice. Nothing we hold
  entitles us to it.
- The exposure is **legal, not technical**. There is no engineering fix. The
  code works; that was never the question.

`apple/Sources/Zer0Shell/BrowserModel.swift` carries the last piece of the
pretence: `chromeVersionForDownloads = "131.0.0.0"`, with the comment *"The
update endpoint keys off a Chrome version. Too old a value and it serves
nothing."* We tell that endpoint we are a Chrome. That sentence should be
uncomfortable to read, because it is an accurate description of what the code
does.

### The mitigation, which is a seam and not a defence

Everything store-shaped lives behind two functions in `crates/zer0-core/src/ext/`:

| Function | What it owns |
| --- | --- |
| `download_url(id, chrome_version)` | the only place the endpoint is spelled |
| `extension_id_from_store_url(url)` | the only place a store page is recognised |

Nothing else in the core or the shell knows the store exists. Swapping to our
own store, to a mirror, or to sideloading-only is one function body and one
error path — a new implementation, not a refactor across the codebase.

That is worth exactly what it is worth: it caps the cost of the day this stops
being possible. It does nothing about the day itself.

### Downloading happens in Swift, on purpose

`BrowserModel.installExtension(id:)` does the fetch with `URLSession` so the
system's proxy and certificate settings apply, then hands the bytes to
`Zer0::install_extension`. Everything after the download is in Rust, where it
can be tested without a network.

### What authenticity we actually have

The bytes that come back are checked for one thing: the id declared inside the
CRX header must match the id derived from **one of the signing keys the header
carries** (`crates/zer0-core/src/ext/crx.rs`). That stops a swapped response
from installing a *different* extension under the id you asked for.

*Corrected in place:* this used to read "its signing key", and the code read
the **first** proof in the header. A package straight from the store carries
more than one, and the extension's own key is not the one in front — uBlock
Origin Lite as served today has Google's Web Store publisher key first and the
author's second, so the check refused every genuine extension in the store. The
sentence was wrong about CRX3 rather than wrong about the decision, and
`a_real_store_package_is_signed_by_more_than_one_key_and_still_installs` is the
test that now says so.

It is not a signature check. The RSA and ECDSA signatures are not verified —
doing it properly means a signature-verification dependency and careful handling
of both key types, and it has not been done. So the authenticity guarantee is
**HTTPS plus that id check**, and nothing more. An attacker who can serve bytes
signs with their own key, the derived id matches their own declared id, and the
package sails through. That is precisely why everything downstream treats the
archive as hostile input (ADR-0022).

Recognising a store page is treated as a security boundary for the same reason,
because its output is an id we then go and install:

- HTTPS only. `http://chromewebstore.google.com/...` is whatever the network
  says it is, and `javascript://chromewebstore.google.com/detail/<id>` is not a
  page at all.
- The id must sit in one of the two path segments right after `detail`. Scanning
  the whole path for the last id-shaped segment would let
  `/detail/slug/<real>/x/<planted>` offer the planted one.

## Consequences

**What hurts:**

- **The feature can be switched off by someone who is not us, without warning.**
  Not degraded — switched off. Every install path in the product dies at once,
  and the only thing left is the error string from a failed HTTP request.
- **The exposure is legal and unbounded.** A takedown, a cease and desist, or a
  store-terms enforcement action is a real outcome, and it lands on whoever
  publishes `zer0` rather than on the code. There is no configuration that
  mitigates it and no test that measures it.
- **We are identifying as Chrome to get served.** `prodversion=131.0.0.0` is a
  number we picked because the endpoint rejects old ones. It will go stale, and
  the failure when it does is a download that returns nothing useful, surfaced
  to the person as an HTTP error with no explanation of what actually happened.
- **Extension authors did not agree to this.** Their package is distributed
  through a channel they chose, under terms they accepted, and we take it out of
  that channel. "It is publicly downloadable" is a technical statement, not
  consent.
- **No updates.** Reinstalling is how you upgrade (`install_extension` replaces
  any previous copy), and nothing checks for a new version. An extension with a
  security fix sits at the old version until someone reinstalls it by hand —
  which is worse for the user than the store they came from.
- **The signature is still not verified.** HTTPS plus an id check is a real
  guarantee against a swapped package and no guarantee at all against a hostile
  one. This is stated in the module docs, in the README's known limits, and here,
  because it is the kind of gap that gets forgotten precisely because it is
  written down once.

**What we get:**

- Paste a store link, press Add, the extension is running. That is the entire
  justification, and it is a real one: it is the difference between a browser
  people can switch to and a browser people admire from a distance.
- One seam. When this ends, it ends in one function.

## How this regresses

The regression that matters here is not a broken test. It is **the seam
dissolving**, and it dissolves the way all seams do: someone needs the store
URL in one more place and writes it there.

What a person would notice, in order of how bad it is:

- **"Add does nothing, it just says HTTP 403."** Google changed or gated the
  endpoint. No test can predict this and no test can catch it; it is the
  decision's cost arriving.
- **"It installed the wrong extension."** The id check in `crx.rs` was removed
  or weakened — most plausibly by someone making a test fixture pass.
  `a_package_claiming_someone_elses_id_is_rejected` is the lock, and it is the
  single most important test in the extension code.
- **"A link on a random site added an extension I never asked for."** The store
  URL parser was loosened — a scheme check dropped in a refactor, or the
  `detail`-anchored scan replaced with "find the last id-shaped segment because
  it is simpler". `the_store_over_plain_http_offers_nothing`,
  `another_site_cannot_pass_itself_off_as_the_store` and
  `a_second_id_planted_deeper_in_the_path_does_not_win` each cover one of those
  three, and each of the three is a plausible, well-meant change.
- **The quiet one:** `clients2.google.com` appearing anywhere outside
  `download_url`. Nothing breaks, nothing goes red, and the mitigation this ADR
  claims stops being true. A `grep` in `scripts/check.sh` for that host outside
  `crates/zer0-core/src/ext/mod.rs` would lock it and does not exist.

**Note what the locks do and do not hold.** They hold the shape of the URL and
the checks around it. **No test holds the decision itself**, because the decision
is a legal risk knowingly accepted, and there is no assertion that expresses
that. If this ADR reads comfortably, it has been edited into something other
than what was decided.

## When to revisit

- **The moment the endpoint stops answering, or answers with a demand.** That is
  not a revisit, it is the exit condition firing, and the plan is already known:
  reimplement `download_url` against another source.
- If `zer0` is ever distributed at a scale where it is worth someone's attention.
  The risk is not linear in users; it steps.
- Before signature verification is added. That is a separate decision with its
  own dependency and its own ADR, and adding it does not change anything in this
  one — a verified package from an unauthorised channel is still from an
  unauthorised channel.
- If sideloading plus a small curated set turns out to be enough for the people
  actually using this. Then the trade stops being worth it, and the seam is
  there to make that switch cheap.
