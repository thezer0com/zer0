# Stable and Canary

zer0 ships in two channels. Pick one, install both side by side, or switch
between them — they do not touch each other's state.

The split, the bundle ids, and the update cadences are locked in
[ADR-0109](adr/0109-two-bundles-stable-and-canary-each-with-its-own-bundle-id-profile-and-update-channel.md).
This doc is the user-facing version of it.

## What you get

| Channel | Bundle id | WebKit | Update frequency | Stability |
|---|---|---|---|---|
| **Stable** (`zer0`) | `com.thezer0.browser` | Pinned upstream `WebKit-*` tag, chosen for release fitness | On `v*` tags (monthly or slower) | Production-grade |
| **Canary** (`zer0 Canary`) | `com.thezer0.canary` | The same pinned tag, at the time the canary build runs | Every push to `main` (daily or faster when the trunk is hot) | Bleeding edge; may break between fixes |

Both bundles carry their own embedded WebKit. Neither depends on the version
your macOS happens to have installed. The engine is the project's
responsibility either way (ADR-0005); the channel split is what lets that
responsibility land at two different cadences.

## Side by side

Stable installs at `/Applications/zer0.app`; canary at
`/Applications/zer0 Canary.app`. zer0 appends its bundle id to the
`Application Support` directory macOS provides, and depends on that rather
than adding a `--profile-dir` override. The two never share state:

- `~/Library/Application Support/com.thezer0.browser/` — stable
- `~/Library/Application Support/com.thezer0.canary/` — canary

Cookie jars, history, sessions, downloaded extensions, saved logins — all
isolated. The Keychain splits the same way
([ADR-0112](adr/0112-the-keychain-isolates-by-channel-and-stable-inherits-the-legacy-entries.md)):
each channel keeps its credentials — assistant API keys and the like — under
its own bundle id, stable inherited the entries from before the split, and
canary started empty. A canary crash cannot eat your stable tabs.
Uninstalling canary is
`rm -rf ~/Library/Application\ Support/com.thezer0.canary` and the directory
it names, with nothing to think about regarding stable.

## Updates

Updates are delivered by [Sparkle 2](sparkle-setup.md). Each channel reads
its own signed appcast:

- stable: `appcast-stable.xml`
- canary: `appcast-canary.xml`

Both are signed with the same EdDSA key; both appcasts and binaries are
produced by the same GitHub Actions workflow, the only difference being the
trigger (`v*` tag vs push to `main`). Sparkle checks every 24h.

In **Settings › Updates** you can:

- **Check for updates manually** — pulls the appcast now instead of waiting
  for the next scheduled check.

There is no "receive canary updates" toggle on stable, and
[ADR-0110](adr/0110-the-stable-bundle-does-not-peek-at-the-canary-feed.md) is
why: an appcast enclosure is a whole `.app`, so a stable binary that read the
canary feed would have its bundle id silently mutate to `com.thezer0.canary`
on the first canary update — orphaning the stable profile and breaking the
1Password enrolment. The honest way to preview canary is the second `.app`
above; a toggle that promised a preview while swapping the bundle was a
one-way door dressed as a reversible switch.

## WebKit version

Both channels ship the same `WebKit-*` upstream tag at any given time. The
tag is pinned in [`scripts/webkit/version.txt`](../scripts/webkit/version.txt)
and refreshed when a new upstream tag passes the project's release bar.
ADR-0109 §"Decision" records why there is no "canary on `main`, stable on the
pin" split: `WebKit-*` tags are the only revisions that have been through a
release cycle, and the cost of running a third engine track is the cost of
running a third browser.

To read which WebKit is in an installed bundle:

```sh
defaults read /Applications/zer0.app/Contents/Frameworks/WebKit.framework/Versions/A/Resources/Info.plist \
  CFBundleVersion
```

For canary, substitute `/Applications/zer0 Canary.app`. The result is the
upstream `WebKit-*` tag's numeric components; correlate it with the tag in
`scripts/webkit/version.txt` to confirm the channel is current.

## When canary breaks

Canary can break — that is its job. When it does:

1. **Report it** at <https://github.com/avelino/zero-browser/issues> with the
   bundle's WebKit version (above) and the canary build timestamp.
2. **Use stable in the meantime.** It does not share state with canary, so a
   broken canary does not affect your stable tabs, logins, or history.
3. **To downgrade canary**, uninstall the broken `.app` and install a previous
   build from <https://download.thezer0.app/canary> (history kept for 90
   days). The canary profile is preserved across reinstalls.

A canary user who wanted stable behaviour installed the wrong binary — the
app name, the icon and the profile directory all name the channel
unambiguously, by design (ADR-0109 §"Consequences").

## Replacing the embedded WebKit

Both channels carry WebKit under `Contents/Frameworks/` as separate dylibs
(ADR-0005). LGPL §6(b) asks that a user be able to swap those dylibs for a
modified build and relaunch. The procedure is documented in
[`docs/webkit.md`](webkit.md) and is identical for both channels save for the
`.app` path. In short: replace the frameworks, re-sign ad-hoc
(`codesign --force --deep --sign -`), relaunch, verify with `vmmap`.

The source code offer (LGPL §6(a)) is satisfied by publishing the tarball of
the pinned `WebKit-*` tag alongside each release. See
[`docs/licensing.md`](licensing.md) §6.
