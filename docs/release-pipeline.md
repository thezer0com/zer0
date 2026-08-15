# Release pipeline

How a build goes from this tree to a `.app` a stranger's Mac will run.

This is the sequence itself. The *decisions* behind it live in the ADRs
named below; this document is the operator-facing view that glue them
together.

- **ADR-0005** — building WebKit from source and embedding it in the bundle
- **ADR-0109** — two channels (stable, canary), hardened runtime + the
  `allow-dyld-environment-variables` entitlement, ad-hoc today and Developer
  ID when one exists
- **ADR-0102** — CI runs the one gate on the oldest macOS we claim

The cost split worth remembering: a clean WebKit build is ~35 min, a release
build of the Rust core + Swift shell + embedding + signing is ~10 min against
a cached engine. CI caches the engine on `scripts/webkit/version.txt`; a
release that does not bump the pin does not pay for the build.

---

## Dev / local

A debug build with the system WebKit, ad-hoc signed, runs on this machine
only. Nothing here touches Apple.

```sh
./scripts/build.sh debug
./apple/scripts/embed-webkit.sh --orion   # optional: stand-in engine, dev only
```

A release build that still runs ad-hoc -- the shape to reach for when
checking how the bundle behaves with optimisation, but before handing it to
anyone.

```sh
./scripts/build.sh release
./apple/scripts/embed-webkit.sh /path/to/WebKitBuild/Release
ZER0_SIGN_IDENTITY=- ./scripts/sign.sh
```

`-` is the ad-hoc identity. `codesign -dv --verbose=4` will report
`Signature=adhoc` and `TeamIdentifier=not set`, and `spctl --assess` will
reject -- both are expected, neither stops this Mac running it.

## Distribution

A release build with the embedded WebKit, signed with a real Developer ID
Application identity, notarised, stapled. This is what a stranger's Mac will
accept.

```sh
# 1. Build the bundle for the channel you are releasing.
ZER0_CHANNEL=stable ./scripts/build.sh release

# 2. Embed the pinned WebKit. Source it from the build cache the CI job
#    produces, or from scripts/webkit/build.sh output on this machine.
./apple/scripts/embed-webkit.sh /path/to/WebKitBuild/Release

# 3. Sign with hardened runtime + entitlements. Apple's timestamp server is
#    hit for a trusted timestamp, so this step is online.
ZER0_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/sign.sh

# 4. Notarise + staple. Stores the credentials once via:
#
#      xcrun notarytool store-credentials zer0-ci \
#        --apple-id ... --key-id ... --key ... --team-id ...
#
#    Then every release is:
ZER0_NOTARY_PROFILE=zer0-ci ./scripts/notarize.sh
```

Canary is the same sequence with `ZER0_CHANNEL=canary` and a different
bundle id (`com.thezer0.canary`). The two channels do not share a profile
directory, a Sparkle appcast, or a 1Password enrolment; ADR-0109 records
the full split.

## What each script decides

| Script | Decides |
| --- | --- |
| `scripts/build.sh` | Compiles the Rust core and the Swift shell, links the `LC_DYLD_ENVIRONMENT` load command that redirects WebKit loading at `Contents/Frameworks`. |
| `apple/scripts/bundle.sh` | Wraps the SwiftPM executable in a `.app` with the channel's bundle id (ADR-0109's one door, `build_bundle_id_parametrized`). |
| `apple/scripts/embed-webkit.sh` | Copies the pinned WebKit family + XPC services into `Contents/Frameworks`, signs them ad-hoc innermost-first with their own entitlements preserved. |
| `scripts/sign.sh` | Re-signs everything with a real identity, hardened runtime on, and the entitlements the embedded WebKit needs. Ad-hoc (`-`) is accepted for dev. |
| `scripts/notarize.sh` | Uploads the signed bundle to Apple, waits for a verdict, staples the ticket. Refuses ad-hoc inputs early. |

## Verifying a built bundle

```sh
# Signature + entitlements + hardened runtime flag
codesign -dv --verbose=4 --entitlements - apple/.build/Zer0.app

# Gatekeeper's view -- the check a stranger's Mac actually performs
spctl --assess --type execute --verbose apple/.build/Zer0.app

# The notarisation ticket, after scripts/notarize.sh has run
xcrun stapler validate apple/.build/Zer0.app

# Which WebKit is loaded at runtime (ADR-0005's expensive failure is
# loading the system engine silently)
./apple/scripts/embed-webkit.sh --check
```

## When this pipeline breaks

- **`spctl` rejects after notarise + staple.** The staple is malformed or the
  signature lost something notarisation requires. Re-run sign.sh, re-run
  notarize.sh. If it persists, `xcrun notarytool log <submission-id>` is
  Apple's verbose refusal.
- **`codesign --verify --deep --strict` fails inside embed-webkit.sh.** A
  framework link reaches outside `Contents/Frameworks`, or a `.tbd` stub
  survived. embed-webkit.sh refuses both; the message names the file.
- **The app loads the system WebKit after signing.** The
  `allow-dyld-environment-variables` entitlement is missing or got dropped.
  Check with `codesign -d --entitlements :- "$APP"` and confirm the
  entitlement is on the app executable, not only on a helper.
- **1Password's helper refuses to enrol.** ADR-0108 names the path; the
  short version is it inspects the signature and refuses ad-hoc. A real
  Developer ID signature is the fix, not a setting in 1Password.
