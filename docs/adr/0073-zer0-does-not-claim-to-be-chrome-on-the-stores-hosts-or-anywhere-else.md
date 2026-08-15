# ADR-0073: zer0 does not claim to be Chrome, on the store's hosts or anywhere else

- **Status:** Accepted
- **Date:** 2026-08-06
- **Lock:** `apple/Tests/Zer0ShellTests/NavigationRoundTripTests.swift::UserAgentTests/theUserAgentNamesNoOtherBrowser`

## Context

Opening `https://chromewebstore.google.com/` draws Google's own modal:
**"Switch to Chrome? Google recommends using Chrome when using extensions and
themes."**, with *No thanks* and *Yes*, over a banner reading *"Switch to Chrome
to install extensions and themes"* and an **Install Chrome** button.

ADR-0062 already replaced the store's greyed-out install button with one of
ours, on the store's hosts and nowhere else, and it explicitly left this
contradiction standing: our button works and their banner says it cannot. It
also named the temptation and refused it in one sentence — *"somebody decides
the honest way to fix the greyed-out button is to send Chrome's User-Agent"* —
without any evidence about what that would actually do.

The obvious next move is the one ADR-0062 anticipated: present as Chrome-capable
on the store's hosts, which is the same host rule already argued for and locked.
There is a defensible case for it. We do install that store's extensions; on
that host the claim is true about the only thing being asked. And there is a
mechanism problem to solve, because `customUserAgent` is a property of the web
view and not of a navigation, so a tab that leaves the store must not carry it.

**None of that turned out to matter, because the premise is wrong.** Measured in
WebKit — the same engine, offscreen, on the real 1Password listing, one variable
changed at a time:

| | Safari UA (ours) | Chrome UA |
| --- | --- | --- |
| "Switch to Chrome?" modal | **present** | absent |
| Other banner | "Switch to Chrome to install extensions and themes" | **"Item currently unavailable. Please check the troubleshooting guide."** |
| The store's install button | disabled, "Add to Chrome" | **disabled, "Add to Chrome"** |
| Visible page CTA | "Install Chrome" | "View guide" |

Three things follow, and the third is the one that decides it.

**The store keys the modal off the User-Agent string.** `navigator.userAgentData`
is `undefined` in WebKit under both UAs, so it is not that. Injecting a
`window.chrome` object changed nothing in either direction. The UA is the whole
of the signal, which means the "root fix" would in fact have worked *as a way of
suppressing the modal*.

**And it does not enable the button.** The store's own install control stays
disabled either way, because installing from it needs `chrome.webstorePrivate`,
which is Chrome's and is not something a UA string produces. Everything that
actually installs an extension here is ours already.

**And what replaces the modal is worse.** *"Item currently unavailable"* is
false: the item is available, and zer0 downloads, unpacks and installs it in a
few seconds. We would be trading a banner that says something true about
Chrome for a banner that says something false about the extension — and we would
have caused it.

## Decision

**The User-Agent names Safari, because that is the engine, and zer0, because
that is the browser. It names no third thing, on any host.** ADR-0008 stands
unchanged and this is the first evidence for it rather than a restatement of it.

No code changed. What changed is that the refusal now has a measurement behind
it and a test under it.

The argument, since it was asked for. There is a version of "claim to be
Chrome" that is honest — a claim scoped to one host, about a capability we
really have. The reason to refuse it is not that scoped lying is worse than
unscoped lying; it is that **this particular claim buys nothing.** The button we
would be trying to un-grey stays grey. The only measurable effect is swapping
which untrue banner Google draws. A browser that lies about itself has started
down a road with no obvious stopping point, and the fare for the first mile here
is zero.

The mechanism problem — a per-view `customUserAgent` outliving the navigation
that justified it, and having to not fight the per-space `userAgent` someone set
themselves (`EngineHost.swift`) — is therefore not solved. It is not solved
because it does not need to be, and that is a better outcome than solving it.

**Editing Google's markup to hide the modal is refused separately and for a
different reason.** It is treating the symptom, it breaks on their next
redesign, and ADR-0062 already spent this project's whole appetite for editing a
page we did not write on the one edit that does something a person asked for.

## Consequences

**What hurts:**

- **The modal stays, and it is a modal.** ADR-0062 accepted a banner; this
  accepts something more intrusive sitting in front of the page on arrival, with
  a *Yes* button that installs a different browser. It is the single ugliest
  thing in this product and it is on somebody else's page.
- **We are choosing to look broken to be honest.** Someone landing on the store
  for the first time is told by Google that this browser cannot do the thing it
  is about to do. The injected button underneath is the whole answer to that and
  it is a smaller voice.
- **The measurement has a shelf life.** Google's store is generated and
  changes without notice. Every number in the table above is from one afternoon.
- **Nothing here helps the person who wants Chrome-only sites to work.** This is
  a decision about the store, and it generalises to a refusal that will cost
  something the first time a site we care about sniffs for Chrome and we have
  already written down that we will not pretend.

**What we get:**

- One User-Agent, everywhere, that is true. No host list to maintain, no
  per-navigation lifetime to get wrong, no interaction with the per-space
  override.
- The claim ADR-0008 makes is now defended by a test rather than by everyone
  remembering.
- The next person who has this idea finds the measurement instead of having to
  take it on trust — including the part where the idea *works*, which is the
  part that makes it tempting.

## How this regresses

**"The store stopped nagging me and now says the extension is unavailable."**
Somebody appends a Chrome token to `safariUserAgentToken`, or sets
`customUserAgent` on the store's hosts. `theUserAgentNamesNoOtherBrowser` goes
red on the token, by name, in the test that also prints the whole UA.

**"Some site thinks we are Edge."** The same lock covers `Edg/`, `Firefox/`,
`OPR/`, `CriOS/` and `Chromium/`, because the argument is about naming a browser
we are not, and Chrome is only the one that came up first.

**"The UA is fine and we lie somewhere else."** Not covered, and worth saying
plainly. A `WKUserScript` that defines `window.chrome`, or a shimmed
`navigator.userAgentData`, would be the same decision taken through a different
door, and nothing here would notice. Both were measured to be *ineffective* on
the store, which is the reason nobody has wanted one, and is not a guarantee.

**And the one no test catches:** somebody hides the modal by removing Google's
node from the DOM, in the script ADR-0062 already ships onto that host. It is
one selector, it is on an origin we already inject into, and every lock in
ADR-0062 stays green.

## When to revisit

- **When the store's install button stops depending on `chrome.webstorePrivate`**
  — that is, if a UA change ever begins to actually enable it. That is the
  premise this refusal rests on and the only thing that would overturn it.
- **When a site somebody needs refuses us by name.** This decision is cheap
  because the store costs us a banner. The first site that costs somebody their
  work is a different conversation, and it should be had per-site, in the open,
  and not by quietly widening the default UA.
- **If the modal starts appearing on more than the store's own hosts**, or
  begins blocking the page rather than sitting over it. The calculation here is
  "an ugly banner over a working button"; if the banner stops being dismissible
  the trade changes.
- When Linux is attempted. The UA is composed in the shell from
  `applicationNameForUserAgent`, which is a WebKit spelling; the rule that it
  names the engine and us, and nothing else, is the part that crosses.
