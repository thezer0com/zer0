# Security policy

zer0 is pre-release software. This page says what is in scope and how to
report, and nothing it cannot prove: no response-time promises, no bounties,
no dates.

## Reporting a vulnerability

Use [GitHub's private vulnerability reporting] on this repository — the
"Report a vulnerability" button on the Security tab. Do not open a public
issue for anything security-relevant; a bug report is the wrong door and the
issue tracker is public.

What happens after a report is a fact we cannot state in advance, so we do
not state it. No money is offered for reports.

## Scope

In scope:

- **The browser itself** — the Rust core, the macOS (Swift) and Linux (GTK)
  shells, and everything the binary does to a person's machine.
- **The extension install path** — installing a Chrome extension, the
  permission consent it gets, and what the extension can reach afterwards.
- **The update chain** — the stable and canary channels, their appcasts, and
  anything a malicious feed could push to an installed copy.
- **The assistant and its MCP gates** — ⌘E, the provider integrations, and
  the approval step that stands between a tool and execution.

Out of scope: vulnerabilities in WebKit itself (below), and anything already
publicly disclosed upstream.

## WebKit CVEs

zer0 does not use the system WebKit. It builds its own, pinned per channel in
[`scripts/webkit/version.txt`] — a `WebKit-*` source tag for stable, an exact
commit of `main` for canary. That file is the only place a revision is
written down; `webkit-bump.yml` rewrites the pins and opens the pull request,
and merging it is what makes `build-webkit.yml` rebuild both engines.

So an upstream WebKit security fix reaches zer0 when the pin moves, not when
Apple ships an OS update. If you are unsure whether a CVE affects zer0, check
the pinned tag/sha against the advisory's fixed versions and report anyway —
deciding that is our job, not yours.

## What a good report contains

- **Channel** — stable or canary.
- **Version** — the string from About (or the build you made, if you built
  from source, with the commit).
- **WebKit build** — also from About; with two engines in flight, the app
  version alone does not say which one you are running.
- **OS** — macOS or Linux, with version.
- **Steps to reproduce** — what you did, in order.
- **Impact** — what a person loses if this is exploited.

Partial reports are welcome. A report that is missing fields is a
conversation; a report that never arrives is a vulnerability with a delay on
it.

[GitHub's private vulnerability reporting]: https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability
[`scripts/webkit/version.txt`]: scripts/webkit/version.txt
