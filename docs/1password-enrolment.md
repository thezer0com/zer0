# 1Password enrolment

1Password does not know zer0 by default. Without this enrolment, the
1Password extension installs and detects Chrome correctly, but
`chrome.runtime.connectNative` is rejected by `1Password-BrowserSupport`
with `UnknownBrowser` / `BrowserSignatureInvalid` because zer0's bundle id
is not in the helper's whitelist and zer0 is not paired as a trusted app.

This is a **one-time manual step per macOS account**. There is no API; the
enrolment lives in `browsers.other-trusted-apps` inside 1Password.app's
settings, persisted as a list of bundle ids pinned to a Team ID via a
`SecRequirement`.

The decision that makes this work is
[ADR-0105](adr/0105-a-program-outside-the-browser-is-matched-by-the-id-zer0-derived-and-started-only-once-somebody-has-been-shown-which-one.md).
The two-bundle consequence (enrol stable and canary separately) is in
[ADR-0109](adr/0109-two-bundles-stable-and-canary-each-with-its-own-bundle-id-profile-and-update-channel.md)
§"Consequences".

## Prerequisites

- **1Password.app installed** at `/Applications/1Password.app`.
- **zer0 installed**:
  - stable at `/Applications/zer0.app` (bundle id `com.thezer0.browser`), or
  - canary at `/Applications/zer0 Canary.app` (bundle id `com.thezer0.canary`).
- **The installed zer0 is signed with Team ID `24X5CQGA86`** — verify before
  you enrol, because 1Password pins the enrolment to the Team ID and a
  mismatch surfaces as `BrowserSignatureInvalid`:

  ```sh
  codesign -dv --verbose=4 /Applications/zer0.app 2>&1 | grep -E '^(Identifier|TeamIdentifier)'
  # Expected for stable:
  #   Identifier=com.thezer0.browser
  #   TeamIdentifier=24X5CQGA86
  ```

  An ad-hoc signed build (`TeamIdentifier=not set`) cannot be enrolled. Wait
  for a signed release, or [sign a local build with your own Developer ID
  application certificate](https://developer.apple.com/developer-id/) — but
  then the Team ID you enrol must be *yours*, not `24X5CQGA86`.

## Steps

> **UI paths below are inferred from the 1Password.app binary strings, not
> confirmed against a live Settings window.** The helper's settings key is
> `browsers.other-trusted-apps` (verified in `index.node`), the Settings
> route is `settingsBrowser` (verified in `primaryRenderer.js`), and the
> section uses CSS classes `TrustedBrowsers_*` with action handlers
> `AddTrustedBrowser` / `RemoveTrustedBrowser` (verified in `index.node`).
> If your 1Password version surfaces this elsewhere, trust the window over
> this doc and PR the correction.

1. **Open 1Password.app** and unlock your vault.
2. **Open Settings** — `⌘,` or **1Password › Settings** in the menu bar.
3. **Go to the Browser panel** (the route named `settingsBrowser`; the
   sidebar item labelled **Browser**). If you do not see it, look under
   **Advanced** or **Developer** — the panel's visibility has historically
   moved between 1Password releases.
4. **Find the "Trusted Browsers" section** (CSS class `TrustedBrowsers_*`,
   plural). It lists currently-paired browsers with their icons and bundle
   paths.
5. **Click the add button** — the action is `AddTrustedBrowser(<PathBuf>)`,
   which opens a file picker.
6. **Select `/Applications/zer0.app`** in the file picker. Confirm.
7. **Repeat for canary** if installed: pick `/Applications/zer0 Canary.app`.
   The two bundle ids are enrolled as separate entries; neither inherits
   from the other (ADR-0109).

## Verifying

After enrolment, in zer0:

1. Install the 1Password extension from the Chrome Web Store. **This works
   even without enrolment** — the extension installs and detects Chrome's
   framing; the rejection happens later, at `connectNative`.
2. Click the 1Password toolbar icon.
3. **You should see the desktop-app pairing screen** — not `UnknownBrowser`,
   not `BrowserSignatureInvalid`. Approve the pairing in 1Password.app when
   prompted.
4. The extension should now unlock with the desktop app, fill credentials,
   and show the desktop app's account.

If `UnknownBrowser` persists, the enrolment did not take. Re-check:

```sh
# zer0 is signed with the expected bundle id and Team ID:
codesign -dv --verbose=4 /Applications/zer0.app 2>&1 | grep -E '^(Identifier|TeamIdentifier)'
# Expected:
#   Identifier=com.thezer0.browser
#   TeamIdentifier=24X5CQGA86

# The installed 1Password.app is recent enough to surface the Trusted
# Browsers section — older versions (pre-8.x) handled this differently.
defaults read /Applications/1Password.app/Contents/Info.plist CFBundleShortVersionString
```

If the Team ID on your zer0 does not match `24X5CQGA86`, the enrolment will
appear to succeed but pairing will fail on first use with
`BrowserSignatureInvalid`. Re-install zer0 from an official signed release.

## Why this is necessary

1Password's desktop helper (`1Password-BrowserSupport`) keeps a hardcoded
whitelist of ~27 known browser bundle ids paired with ~7 vendor Team IDs.
Read directly out of the helper binary: a `SecRequirement` format string
built per browser, plus imports of `SecCodeCopyGuestWithAttributes` and
`SecCodeCheckValidity` — i.e. it checks the calling process's code signature
against a pinned identity before answering `connectNative`. Anything not on
that list — which includes every WebKit browser that is not Safari — has to
go through the `browsers.other-trusted-apps` enrolment route, which is what
the Settings UI exposes.

The full reasoning, including why "ad-hoc signed" was the whole of an
earlier refusal and why a real Developer-ID signature unlocks it, is in
[ADR-0072](adr/0072-an-extension-webkit-could-not-start-is-not-reported-as-running.md)
§"Corrected in place, 2026-08-11". The short version: zer0 is a browser
1Password does not ship a whitelist entry for, so each user (or each macOS
account) adds it themselves, once.
