# Sparkle setup

How a release is signed for Sparkle, where the keys live, and what the
workflow writes into each channel's appcast. The *decision* behind this is
ADR-0109; this document is the operator-facing view, the way
[release-pipeline.md](release-pipeline.md) is for the bundle itself.

Sparkle 2 (not 3) is the choice. ADR-0109 has the reasoning; the short
version is that 2 is more stable and better documented, and the cost of
switching later is a version bump in `apple/Package.swift` rather than a
rewrite.

---

## EdDSA key pair

Sparkle verifies appcasts with an EdDSA public key compiled into the bundle
(`SUPublicEDKey` in `Info.plist`), and signs them with the matching private
key held in CI. The pair is generated once, owned by the project, and never
rotated without a release that carries the new public key.

### Generate the pair

Sparkle ships the key tools inside the release tarball, under `bin/`. On a
Mac, with the tarball matching the version resolved in `apple/Package.resolved`:

```sh
# 1. Download and extract. The tarball lays `bin/` out at the ROOT of the
#    extraction target, not under a Sparkle/ subdir.
curl -L https://github.com/sparkle-project/Sparkle/releases/download/2.9.5/Sparkle-2.9.5.tar.xz \
  -o /tmp/Sparkle.tar.xz
tar -xf /tmp/Sparkle.tar.xz -C /tmp

# 2. Generate the pair. generate_keys stores the private key in the login
#    keychain and prints only the PUBLIC key — the SUPublicEDKey value.
/tmp/bin/generate_keys

# 3. Export the private key to its master copy, outside the repo. This file
#    is what the ZER0_SPARKLE_PRIVATE_KEY CI secret is seeded from.
/tmp/bin/generate_keys -x ~/.config/zer0/sparkle/ed25519-private.key
chmod 600 ~/.config/zer0/sparkle/ed25519-private.key
```

The private key has no recovery path. If it is lost, every appcast it signed
becomes unverifiable and can never be re-signed; store the master copy, back
it up, and never print it.

### Where each half lives

| Half | Where | Who reads it |
| --- | --- | --- |
| **Private** | master copy `~/.config/zer0/sparkle/ed25519-private.key` (mode 600, outside the repo), seeded into CI secret `ZER0_SPARKLE_PRIVATE_KEY` | The release workflow, to sign each appcast entry |
| **Public** | `apple/scripts/bundle.sh` reads `ZER0_SPARKLE_PUBLIC_KEY` at build time and writes it into `Info.plist` as `SUPublicEDKey` | Sparkle, at runtime, to verify the appcast the app downloads |

The public key is not a secret. Embedding it in `Info.plist` is the design:
a stranger who reads the bundle learns nothing they could not learn by
downloading the appcast. The private key is.

### Rotation

A rotation is two releases, not one:

1. Cut a release that ships the **new** public key in `SUPublicEDKey`. Until
   every user has that release, the workflow must keep signing appcasts
   with the **old** private key — otherwise every binary still on the old
   public key refuses the update (ADR-0109: "the channel that was not
   updated stops updating").
2. Once the install base has moved past the rotation release, switch the
   workflow to sign with the new private key and retire the old one.

There is no test in the tree that catches a missed rotation. The defence is
operational: rotations are rare, they are a release step, and they touch
both channels in lockstep.

---

## Appcast

One appcast per channel, on a static host. ADR-0109: stable reads
`appcast-stable.xml`, canary reads `appcast-canary.xml`, both signed with the
same EdDSA key.

```
https://download.thezer0.app/appcast-stable.xml
https://download.thezer0.app/appcast-canary.xml
```

The workflow publishes both files on every release. The only difference
between them is which artifacts the enclosures list — the schema, the
signing key, and the host are the same.

### Template

```xml
<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
  <channel>
    <title>zer0</title>
    <item>
      <title>0.2.0</title>
      <pubDate>Mon, 01 Jan 2026 00:00:00 +0000</pubDate>
      <sparkle:version>2</sparkle:version>
      <sparkle:shortVersionString>0.2.0</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.4</sparkle:minimumSystemVersion>
      <!-- The enclosure URL is the signed archive the workflow uploaded.
           `sign_update` prints the sparkle:edSignature attribute and the
           length when invoked with the archive path. -->
      <enclosure
        url="https://download.thezer0.app/zer0-0.2.0.zip"
        sparkle:edSignature="BASE64_SIGNATURE"
        length="ARCHIVE_BYTE_LENGTH"
        type="application/octet-stream" />
    </item>
  </channel>
</rss>
```

### Signing an enclosure

```sh
# After the workflow produces zer0-0.2.0.zip:
/path/to/sign_update --ed-key-file ~/.config/zer0/sparkle/ed25519-private.key zer0-0.2.0.zip
# prints: sparkle:edSignature="..." length="12345678"
```

The printed line is what the `<enclosure>` element carries. Sparkle verifies
both the signature (against `SUPublicEDKey`) and the length (against
`length=`); a mismatch on either is a silent refusal.

In CI this is `scripts/publish-appcast.sh`'s job, not a step you run by hand:
the script finds (or fetches) `sign_update`, signs the exact archive the release
uploaded, and parses both attributes from its output. The one thing it will not
do is re-zip the `.app` -- the signature has to be over the bytes a user
downloads, which is the archive the release step already produced.

### One-time `gh-pages` setup

The publish script writes into a `gh-pages` branch that has to exist once
before the first release. It refuses to create the branch itself: two workflows
both inventing it is the race that loses appcast history, and a missing branch
is an operator step, not something a build should paper over.

The appcast files live at the **root** of `gh-pages` (not under `appcast/`),
because `SUFeedURL` reads `https://download.thezer0.app/appcast-<channel>.xml`
with no subpath. Run this once, from a clean tree:

```sh
git checkout --orphan gh-pages
git rm -rf .
echo "# zer0 appcast feeds" > README.md
cat > appcast-stable.xml <<'XML'
<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
  <channel>
    <title>zer0 stable</title>
  </channel>
</rss>
XML
cp appcast-stable.xml appcast-canary.xml
# the canary feed's title should name its channel
sed -i '' 's/zer0 stable/zer0 canary/' appcast-canary.xml
git add README.md appcast-stable.xml appcast-canary.xml
git commit -m "initial gh-pages branch with seed appcasts"
git push origin gh-pages
git checkout main
```

Then point a host at the branch so `download.thezer0.app` serves these two
files. GitHub Pages (repo Settings → Pages, source = `gh-pages` branch) serves
them at `https://<owner>.github.io/<repo>/appcast-<channel>.xml` out of the box
-- that URL works as an interim `SUFeedURL` until the custom domain is live.
The **enclosure** URLs do not need this host: they point at GitHub Releases
(`github.com/<owner>/<repo>/releases/download/...`), which is reachable the
moment the release step runs.

### Delta updates

ADR-0109 decided to **defer** delta updates until a first failure forces the
question: the binary diff is a size optimisation that trades reliability for
bandwidth, and the cost of getting it wrong on a real machine is a user who
cannot update. Sparkle 2 generates and serves deltas automatically when
`generateDeltaUpdates` is enabled in the appcast; the workflow does **not**
enable it today, and `UpdateHost` does not depend on it. When the first full
archive is large enough that the question returns, the decision is in ADR-0109
§"When to revisit", not here.

---

## CI integration

The release workflow (GitHub Actions, macOS runner per ADR-0109) is the only
caller of `sign_update`, and it calls it through `scripts/publish-appcast.sh`.
Steps 3 and 4 below are what that script automates -- the hand version is here
so the script's behaviour is checkable, not because anyone runs it by hand in
a release.

```sh
# 1. Build the bundle for the channel. ZER0_CHANNEL drives
#    apple/scripts/resolve-bundle.sh, which drives the bundle id and the
#    SUFeedURL default.
ZER0_CHANNEL=stable ./scripts/build.sh release
./apple/scripts/embed-webkit.sh /path/to/WebKitBuild/Release
ZER0_SIGN_IDENTITY="Developer ID Application: ..." ./scripts/sign.sh

# 2. Zip the signed .app.
ditto -c -k --keepParent apple/.build/Zer0.app zer0-0.2.0.zip

# 3. Sign the enclosure. ZER0_SPARKLE_PRIVATE_KEY is the CI secret; `-f -`
#    makes sign_update read it from stdin, which keeps it off the runner's
#    filesystem. (An exported env var does NOT work: with no -f, sign_update
#    reads the keychain, which CI does not have.)
ENCLOSURE="$(printf '%s\n' "$ZER0_SPARKLE_PRIVATE_KEY" \
  | /path/to/sign_update -f - zer0-0.2.0.zip)"

# 4. Patch the channel's appcast with the new <item> and upload it to the
#    static host. The public key embedded in the bundle is already there,
#    written at step 1 by apple/scripts/bundle.sh reading
#    ZER0_SPARKLE_PUBLIC_KEY.
```

In the actual workflow, the script takes the signed archive and the
`--download-url` of the GitHub Release that carries it, fetches `gh-pages`,
prepends the `<item>`, commits and pushes. The enclosure URL is the release
asset URL (`github.com/<owner>/<repo>/releases/download/<tag>/<archive>`), not
`download.thezer0.app`: only the **feed** (the `.xml`) lives behind that host,
the binaries ride GitHub's CDN.

The two secrets a release needs:

| Secret | Used by | Purpose |
| --- | --- | --- |
| `ZER0_SPARKLE_PRIVATE_KEY` | `sign_update` in the release workflow | Sign each enclosure's EdDSA signature |
| `ZER0_SPARKLE_PUBLIC_KEY` | `apple/scripts/bundle.sh` at build time | Embed in `Info.plist` as `SUPublicEDKey` |

Both secrets are project-scoped, not environment-scoped: the same pair signs
both channels (ADR-0109).

---

## What the shell does at runtime

`UpdateHost` (in `apple/Sources/Zer0Shell/UpdateHost.swift`) is the runtime
half. The summary a release operator needs:

- The channel is read from `Bundle.main.bundleIdentifier`. A canary id ends
  in `.canary`; everything else reads as stable. This is the second
  implementation of the channel mapping the shell door owns; the test
  `UpdateChannelTests/theCanaryBundleIdSuffixReadsAsTheCanaryChannel`
  defends the two against drift.
- The feed URL is set in code at launch, overriding the `SUFeedURL` default
  in `Info.plist`. The default still has to be correct because Sparkle reads
  it before `UpdateHost` runs.
- The feed a channel reads is the channel's own — stable reads
  `appcast-stable.xml`, canary reads `appcast-canary.xml`, and there is no
  toggle on stable that reaches across to the canary feed. ADR-0110 removed
  the peek that used to do this: an appcast enclosure is a whole `.app`, so
  a stable binary reading canary would have its bundle id mutate to
  `com.thezer0.canary` on the first canary update, orphaning the stable
  profile. Someone who wants canary installs `Zer0 Canary.app` (ADR-0109).

---

## When this breaks

- **`SUPublicEDKey` is empty, and an update is offered.** Sparkle refuses
  the update silently. This is the correct posture for a build with no
  signing story, and the wrong one for a release: the workflow has to
  substitute the real public key at build time via `ZER0_SPARKLE_PUBLIC_KEY`.
- **The private key in CI does not match the public key in the bundle.**
  Sparkle refuses the update. The rotation section above is the fix; there
  is no in-tree test that catches the mismatch.
- **The appcast enclosure's `length=` does not match the archive's byte
  count.** Sparkle refuses the update. Re-run `sign_update` against the
  final archive and patch the appcast.
- **A stable user wants to preview canary.** They install `Zer0 Canary.app`
  alongside stable (ADR-0109). There is no in-app path from the stable feed
  to the canary one, and ADR-0110 is why.
