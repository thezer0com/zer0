# Release checklist: v0.1.0

The ordered runbook from the first public commit to the announce. Steps are
`(human)` — a decision or a machine someone owns — or `(script)` — a command
that fails on its own. Steps marked **missing today** depend on something that
does not exist yet; this file doubles as the map of what is left.

Sources: ADR-0109, ADR-0110, [release-pipeline.md](release-pipeline.md),
[sparkle-setup.md](sparkle-setup.md), [ci-secrets.md](ci-secrets.md),
[licensing.md](licensing.md) §6, `.github/workflows/{build-webkit,canary,stable}.yml`.

## 0. What v0.1.0 is

One stable bundle: `com.thezer0.browser`, app `Zer0.app`, embedded WebKit at
the tag pinned in `scripts/webkit/version.txt` (today `WebKit-7624.4.5.14.1`),
Developer-ID signed, notarised, distributed as a zip on a GitHub Release,
advertised on `appcast-stable.xml` behind `https://download.thezer0.app/`.
Canary is not gated on this checklist; it appears here only as the dress
rehearsal.

## 1. Pre-conditions (human)

Repository state:

- [ ] (human) Working tree split into readable commits and pushed:
      `./scripts/commit-history.sh`, then `git push origin main`. At the time
      of writing the public repo holds one commit and the three release
      workflows are untracked — nothing below can fire until this lands.
- [ ] (human) `./scripts/check.sh` green on the tree that will be tagged.

Apple credentials (one-time, human):

- [ ] (human) Developer ID Application certificate issued, Team ID
      `24X5CQGA86` (ADR-0105). Verify it is in the keychain:
      `security find-identity -v -p codesigning`
- [ ] (human) App Store Connect API key with App Manager role created.
- [ ] (human) Notary profile stored once, name `zer0-ci` (the invocation is
      in the `scripts/notarize.sh` header):
      `xcrun notarytool store-credentials zer0-ci --apple-id ... --key-id ... --key ... --team-id ...`

GitHub secrets (Settings → Secrets and variables → Actions):

- [ ] (human) `ZER0_SIGN_IDENTITY_STABLE` — the identity *name*
      (`Developer ID Application: ... (24X5CQGA86)`). Required: `stable.yml`
      fails the job before the build without it.
- [ ] (human) `ZER0_SIGNING_CERT_P12_BASE64` and `ZER0_SIGNING_CERT_PASSWORD`
      — the .p12 behind that name, and its password. Both workflows import it
      into a temporary keychain (the `import signing certificate` step); an
      ephemeral runner has no other way to hold the identity.
- [ ] (human) Notarisation runs the App Store Connect API-key path, not a
      stored profile — a keychain profile never survives an ephemeral
      runner. Four secrets: `ZER0_APPLE_ID`, `ZER0_APPLE_KEY_ID`,
      `ZER0_NOTARY_KEY_P8_BASE64`, `ZER0_APPLE_TEAM_ID`. Required on stable;
      the detect step fails the job without all four.
- [ ] (human) `ZER0_SPARKLE_PRIVATE_KEY` — private half of the EdDSA pair
      (below). Gates the appcast publish; without it the release stops at the
      uploaded artefact.
- [ ] (human) Sparkle EdDSA pair generated with `sign_update -g` from the
      Sparkle 2.7.x tarball ([sparkle-setup.md](sparkle-setup.md) § "Generate
      the pair"); the public half reaches `apple/scripts/bundle.sh` as
      `ZER0_SPARKLE_PUBLIC_KEY` — both workflows pass it into the build
      step's env, so a CI-built bundle carries the real `SUPublicEDKey`.
      No recovery if the private key is lost.
- [ ] (human) Optional, for the canary rehearsal only:
      `ZER0_SIGN_IDENTITY_CANARY` (canary signs ad-hoc without it).

Feed host:

- [ ] (human) `gh-pages` branch created with the two seed appcasts — one-time
      commands in [sparkle-setup.md](sparkle-setup.md) § "One-time gh-pages
      setup". `scripts/publish-appcast.sh` refuses to create it.
- [ ] (human) GitHub Pages enabled on `gh-pages`, custom domain
      `download.thezer0.app` resolving. **Missing today (DNS)** — and it is a
      hard dependency *before the build*, not before the announce:
      `bundle.sh` bakes `SUFeedURL=https://download.thezer0.app/appcast-stable.xml`
      into `Info.plist` at build time. A bundle built before the DNS is live
      can never check for updates.

## 2. Infrastructure validation (script/human)

The WebKit build is the long pole (~35 min clean, ~30 s cached). Validate the
runner can produce and reuse it before anything depends on it.

- [ ] (human) Actions tab → `build-webkit` → *Run workflow* (`workflow_dispatch`).
      The first run validates, loudly: the pinned `DEVELOPER_DIR`
      (`/Applications/Xcode_26.3.app/...` — the job errors if the Blacksmith
      image dropped it) and the 100 GB free-disk floor (`scripts/webkit/build.sh`
      refuses to start below it).
- [ ] (human) Re-dispatch once green: the second run must report a cache hit
      and skip `fetch + build` — that is the path `stable.yml` depends on.
- [ ] (human) Confirm the cache entry `webkit-WebKit-7624.4.5.14.1` and the
      90-day artefact `webkit-build-WebKit-7624.4.5.14.1` exist on the run.
      `stable.yml` restores the cache with `fail-on-cache-miss: true` — no
      cache entry, no release.
- [ ] (human) Dress rehearsal: let one `canary.yml` run on `main` go green
      end to end. It exercises the same restore → build → archive path
      stable will take; its sign/notarize steps stay skipped until the
      canary secrets exist.

## 3. Release candidate (script) — the path that actually exists

`stable.yml` supports exactly one release shape: a tag `vX.Y.Z` with clean
three-component numbers. The `compute version` step refuses everything else —
`v0.1.0-rc.1` fails the `X.Y.Z` regex and the job dies after notarisation,
before `create release`. `workflow_dispatch` is no escape: it reads the
version off `GITHUB_REF_NAME` (a branch name) and dies at the same check.

So there is no RC tag and no draft-tag path — the workflow publishes the
release, not a draft, because the appcast enclosure URL must resolve the
moment the entry lands. Validation happens **before** the tag exists, on
machines we own; the local candidate *is* the RC:

- [ ] (script) Local candidate build — the full
      [release-pipeline.md](release-pipeline.md) distribution sequence:
      ```sh
      ZER0_CHANNEL=stable ./scripts/build.sh release
      ./apple/scripts/embed-webkit.sh ~/.cache/zer0/webkit/src/WebKitBuild/Release
      ZER0_SIGN_IDENTITY="Developer ID Application: ... (24X5CQGA86)" ./scripts/sign.sh
      ZER0_NOTARY_PROFILE=zer0-ci ./scripts/notarize.sh
      ```
- [ ] (script) `./apple/scripts/embed-webkit.sh --check` — the candidate
      loads the embedded engine, not the system one.
- [ ] (human) Exercise the candidate as a stranger would: install it on a
      machine (or clean macOS account) that did not build it.

If the candidate is good, the public release is one shot:

- [ ] (human) `git tag v0.1.0 && git push origin v0.1.0` — this fires
      `stable.yml` on the tag. If the job dies before `publish appcast`,
      nothing user-visible happened: delete tag and release, fix, re-tag.
      After `publish appcast` it is public — a rollback there is a `gh-pages`
      revert plus a `v0.1.1` re-release.

## 4. Final checks (script)

Against what the workflow produced — download `zer0-0.1.0.zip` from the
release page and unzip it:

- [ ] (script) `./scripts/check.sh` green on the tagged tree (it should be:
      `ci.yml` gates every push to `main`).
- [ ] (script) `codesign --verify --deep --strict Zer0.app` — on both
      channel bundles if canary shipped alongside.
- [ ] (script) `spctl --assess --type execute --verbose Zer0.app` →
      `accepted` — the stranger's-Mac check; only meaningful post-notarise.
- [ ] (script) `xcrun stapler validate Zer0.app` — the ticket travelled
      inside the zip.
- [ ] (script) `plutil -extract SUPublicEDKey raw Zer0.app/Contents/Info.plist`
      is non-empty and equals the public half generated in §1; then
      `curl -s https://download.thezer0.app/appcast-stable.xml` — the top
      `<item>` carries `sparkle:shortVersionString` `0.1.0` and
      `sparkle:version` `100` (0.1.0 packs to X*10000+Y*100+Z), signed by
      the matching private half.
- [ ] (script) `curl -fsI -L <enclosure-url-from-the-appcast>` → 200 — the
      bytes Sparkle will download exist.
- [ ] (human) LGPL source offer attached to the release — both workflows
      build it from the channel's own pin (`source-offer.sh`) and upload
      `webkit-source-*.tar.zst` plus `SHA256SUMS` with `gh release upload`.
      Per [licensing.md](licensing.md) §6: verify the asset name carries the
      pin `scripts/webkit/version.txt` names for the channel — stable the
      `WebKit-*` tag, canary the sha (ADR-0124). Compliance with LGPL §6(a)
      rides on this asset: the gating item, not a nice-to-have.
- [ ] (script) Licence furniture inside the bundle:
      `Contents/Resources/THIRD-PARTY.txt` and the LGPL 2.1 text present
      ([licensing.md](licensing.md) §5), and no
      `Contents/Resources/webkit-stand-in.txt` — a stand-in bundle may never
      leave the machine.

## 5. Go / No-Go (human)

Every row green, or the release does not get announced:

| # | Gate | How to check |
|---|---|---|
| 1 | Gatekeeper accepts on a clean VM | Fresh macOS VM; download the release zip; launch. No right-click-open, no `xattr -d`. |
| 2 | Sparkle updates into v0.1.0 | Install the §3 local candidate (its build number ranks below 100) on a real Mac, let Sparkle see the live feed, confirm it offers and installs v0.1.0. There is no `rc1` in the stable channel — the candidate is the RC. |
| 3 | The bundle runs the pinned WebKit | `vmmap $(pgrep -x Zer0) \| grep __TEXT \| grep WebKit.framework` points inside the `.app`; correlate the framework's `CFBundleVersion` ([stable-canary.md](stable-canary.md) § "WebKit version") with `scripts/webkit/version.txt`. |
| 4 | LGPL obligations shipped | Source-offer asset attached (§4); licence texts in the bundle; the release notes reference the source offer ([licensing.md](licensing.md) §6: "each channel's release notes must reference it"). |
| 5 | Update chain end to end | Appcast signed with the key whose public half is `SUPublicEDKey`; enclosure URL resolves; entry ranks above any prior build. |

## 6. Announce (human)

- [ ] (human) GitHub release notes: edit the auto-generated notes to name
      the channel model ([stable-canary.md](stable-canary.md)), the WebKit
      tag, and the source-offer asset.
- [ ] (human) Site: the download link is the release asset; the update
      channel is the appcast. Say both — the asset is what new users fetch,
      the appcast is what existing users ride.
- [ ] (human) Post-announce: `appcast-stable.xml` is the only update channel
      (ADR-0110 removed the cross-feed path on purpose). If v0.1.0 is wrong,
      the fix is a `v0.1.1` tag — the appcast ranks on `sparkle:version`,
      and 0.1.1 packs to 101.
