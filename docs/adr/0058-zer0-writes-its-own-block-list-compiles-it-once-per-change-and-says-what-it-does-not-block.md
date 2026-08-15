# ADR-0058: zer0 writes its own block list, compiles it once per change, and says what it does not block

- **Status:** Accepted
- **Date:** 2026-06-22
- **Lock:** `crates/zer0-core/src/blocking.rs::an_exception_does_not_leak_to_a_lookalike_host`, `crates/zer0-core/src/blocking.rs::a_hostile_exception_never_reaches_the_rule_list`, `crates/zer0-core/src/preferences.rs::an_exception_nobody_could_compile_exempts_nothing_here_either`, `apple/Tests/Zer0ShellTests/ContentBlockingTests.swift::ContentBlockingTests/webKitCompilesWhatTheCoreEmits`, `apple/Tests/Zer0ShellTests/ContentBlockingTests.swift::ContentBlockingTests/aMalformedRuleListIsRefusedAndReported`, `apple/Tests/Zer0ShellTests/ContentBlockingTests.swift::ContentBlockingTests/aRuleStopsARealRequestAndAnExceptionLetsItThrough`

## Context

`Preferences` has carried `blocking_exceptions: Vec<String>` since it was
written, with a settings pane listing the hosts in it and a `blocks(url)` that
answered questions about them. There was no blocking. **The exception list
existed for a feature that did not.**

Doing it natively rather than leaving it to an extension is not a preference.
`WKContentRuleList` is compiled by WebKit into bytecode and evaluated in the
networking layer, ahead of the page: the rules never see the page and the page
never sees the rules. An extension doing the same job through
`declarativeNetRequest` goes through more machinery, and depends on an extension
being installed, which nobody has done in this browser yet. It also matters for
the premise — a browser lighter than Chromium that then loads every tracker has
handed the advantage back.

Four things had to be settled, and every one of them turned on a fact that had
to be measured rather than recalled.

### What the engine actually accepts

The format has specific and surprising limits, so the installed WebKit was
asked directly (`WKContentRuleListStore`, macOS 26.5 SDK, one throwaway store,
every claim below observed):

| Probe | Result |
|---|---|
| `block` + `ignore-previous-rules` with `if-top-url` | compiles |
| alternation `(a\|b)` in `url-filter` | **refused** — "Disjunctions are not supported yet" |
| bounded repeat `a{2,4}` | **refused** — "Arbitrary atom repetitions are not supported" |
| lookahead `a(?=b)` | **refused** — "Groups are not supported yet" |
| word boundary `\bads\b` | **refused** |
| `if-domain` with any uppercase | **refused**, and it fails the whole list |
| `if-domain` beside `unless-domain` | **refused** — conditions are mutually exclusive |
| `[]` | **refused** — "Empty extension" |
| one good rule beside one bad one | **the whole list is refused** |
| an unknown *trigger key* (`if-moon-phase`) | silently **accepted**, and does nothing |
| 100 / 1k / 5k / 20k / 50k rules, cold compile | 0.8 / 2.8 / 11.5 / 46 / **119 ms** |
| the same, warm `lookUpContentRuleList` | **0.1 ms at every size** |
| lookup of something never compiled | fails with `WKErrorContentRuleListStoreLookUpFailed` |

Two of those are the whole design. **One bad rule fails the entire list** — so a
single malformed exception does not lose one exception, it switches blocking
off. And **a warm lookup is free while a cold compile is not** — so the
identifier is the launch cost, and nothing else is.

Two more, from the headers and from WebKit's source rather than from a probe:
`ignore-previous-rules` is scoped to the list it appears in and can never reach
another list, so exceptions must live inside the same compiled list as the rules
they undo; and `WKContentRuleList` exposes exactly one member, `identifier`.

### The licence, which was very nearly the deciding constraint

The project is MIT (`docs/licensing.md`). Every list worth having was surveyed:

| List | Licence | Bundleable in an MIT binary |
|---|---|---|
| EasyList / EasyPrivacy | GPL-3.0-or-later **OR** CC-BY-SA-3.0-or-later (dual) | Yes, under the CC option, with attribution |
| AdGuard filters | GPL-3.0 | No |
| uBlock Origin `uAssets` | GPL-3.0 | No |
| Disconnect | CC-BY-**NC**-SA-4.0 | No — NC |
| Ghostery `trackerdb` | CC-BY-**NC**-SA-4.0 | No — NC |
| DuckDuckGo Tracker Radar | CC-BY-**NC**-SA-4.0 | No — NC |
| Peter Lowe's list | no licence at all | No |
| StevenBlack/hosts | MIT repo, **aggregating NC sources** | Only a hand-picked subset |
| Blocklist Project | Unlicense | Yes |

The finding that mattered most is the one that would have been missed by
assuming: **EasyList is dual-licensed, and the CC-BY-SA option makes it
shippable.** So the licence did *not* decide this on its own.

What decided it is the second half. Converting EasyList into WebKit's JSON is
an **adaptation**, not a collection — so a converted list distributed in the
binary would have to go out under CC-BY-SA. Compiling on-device avoids that, but
then the browser has to *fetch* a hundred thousand rules on first run: a network
request on somebody's behalf, a parser for a foreign syntax whose most common
constructs (`|` alternation, `$` options) WebKit's grammar refuses outright, a
first run that behaves differently online and offline, and a credits screen
which under CC-BY-SA is a contractual obligation rather than a nicety. That is
four decisions with four screens, and shipping half of them would be worse than
shipping none.

## Decision

**zer0 ships one hand-written list, compiles it on device, and fetches nothing.**

`crates/zer0-core/src/blocking.rs` holds about seventy third-party advertising,
analytics and cross-site-identity hosts, written in this repository. No public
list was copied or converted, which is why the file says so at the top: the
provenance is the licence position, and a list whose origin is unrecorded is a
licence problem waiting to be discovered by somebody else.

**The core emits the JSON; the shell compiles it.** Which rules are active,
which sites are excepted, and what may be said about either is
`blocking.rs`, tested with no window open. `ContentBlocking.swift` looks the
result up, compiles it on a miss, attaches it to every `WKUserContentController`
and reports what happened.

The *format* is written in the core, and that is a deliberate reading of the
tie-breaker in AGENTS.md — "if two platforms could reasonably disagree about it,
it belongs in the shell". They cannot disagree here. Both hosts are WebKit
(ADR-0001) and both take the same content-blocker JSON. Emitting it twice would
be two chances to anchor a host pattern differently, which is ADR-0026's bug
with a new hat on.

**Blocking is global, not per-Space.** A Space is a cookie jar and an identity
(ADR-0007); blocking is neither. The compiled list is one immutable artefact
that every controller shares, so a per-Space version would compile N identical
copies of the same bytecode to reach N identical answers — and it would put
"which rules are on" in a second place, when the thing people actually want,
*not on this site*, already exists per host and is finer-grained than a Space.
The counter-argument is real and worth naming: a Space dedicated to a broken
intranet application would like blocking off wholesale. It gets there one host
at a time instead, and if that becomes the common case this decision is the one
to revisit — `WKUserContentController` is already per-configuration, so only the
core's mind would have to change.

**Exceptions are exact hosts, and they go through one door.** `usable_exception`
is the only way a host becomes either an answer from `Preferences::blocks` or a
pattern in the rule list. That is not defence in depth; it is what keeps the two
in agreement. `blocks()` is what the interface says and the compiled list is
what WebKit does, and they are separate mechanisms — let one honour a host the
other skips and the screen reads "not blocked" over a page still being filtered.
It is also the guard on the failure that matters: a session file with `"))|.*"`
in its exception table would otherwise fail the whole compile and switch
blocking off silently on every launch (ADR-0024).

An exception pattern is `^https?://github\.com[:/]`. All three anchors are
load-bearing, and the trailing `[:/]` is the one the bug is always missing:
without it `github.com` matches `github.com.evil.io`, which is a name anybody
can register.

**The identifier is a hash of the JSON**, prefixed with a version. Measured with
the list that actually ships — 77 rules, 9,562 bytes of JSON, five cold compiles
and twenty warm lookups after warming the frameworks:

| | min | median | max |
|---|---|---|---|
| cold compile — first launch, and after an exception changes | 1.66 ms | **1.75 ms** | 2.17 ms |
| warm lookup — every other launch | 0.03 ms | **0.05 ms** | 0.09 ms |

So blocking costs a twentieth of a millisecond at launch, and under two
milliseconds on the one launch that has to build it. That is the reason the
identifier is a content hash rather than a constant: with a constant name the
cache could answer with the wrong rules, and with a name that changed every
launch this would be 1.75 ms every time and rising with the list.

Orphaned compiles are pruned by prefix, and only ours — the default store is
shared, and removing a name we do not recognise would be this browser reaching
into something that is not its own.

**Reaching it is a command, not a badge.** `UiCommand::ToggleBlockingHere`, on
⇧⌘K and in the Navigate menu, named after the site it is about — "Turn Off
Blocking on github.com" — and disabled when there is no host to file against,
because a menu item that takes the click and does nothing is a lie of affordance
(ADR-0018). It toggles, recompiles and reloads, because a content rule list only
applies to loads that start after it is attached and a toggle without the reload
looks like it did nothing.

**Nothing is added over the page.** ADR-0010 licenses three things to take space
and a shield badge is none of them.

### What it does not block, said out loud

Two claims are refused here, and both are refused on purpose.

**It does not say how many things were blocked on this page**, because that
cannot be known. `WKContentRuleList` was read in the installed SDK and carries
exactly one member, `identifier`. There is no counter, no delegate callback and
no notification in any public WebKit header. The only thing that reports a
blocked load is `_WKContentRuleListAction`, which is SPI. The number every other
browser prints on a shield badge is therefore not available honestly, and it is
not invented to fill the space — this is ADR-0018 applied to the surface where
it costs the most, because the count is the single thing people expect a blocker
to show. What the settings pane says instead is a fact about the *list* — how
many rules, how many exceptions — which is a different claim from a fact about
the page, and it is true.

**It does not claim to be a blocker.** The pane says the number of hosts, says
it is not EasyList, and says it will miss things. Seventy hosts against
EasyList's hundred thousand rules is a real difference, and a browser that says
"blocks trackers and ads" over a starter list is telling somebody they are
covered when they are not.

It also says the one genuinely reassuring thing that is free: WebKit's own
Intelligent Tracking Prevention is heuristic, on-device, always on, and needs no
list at all. It runs underneath this whether the list is on or off.

**A failed compile is a state with a screen.** If WebKit refuses the list, the
Settings switch is still on and nothing is being filtered. That is the worst
state this feature has, so it is the one that is displayed, in the warning
colour, with whatever WebKit said — which is only ever available as prose in
`NSHelpAnchorErrorKey`, since every compile failure collapses to one error code.

## Consequences

**What hurts:**

- **The list is small, and small is the honest word for it.** It stops the
  common advertising and analytics infrastructure and it will miss plenty. Anyone
  comparing against uBlock Origin will find zer0 worse, and they will be right.
- **There is no blocked count, and its absence reads as unfinished.** This is
  the same shape of cost ADR-0018 already paid on the find bar, and it is larger
  here: the count is the thing a shield badge exists to show, so the affordance
  most people look for is missing and the reason is invisible.
- **Maintaining a hand-written list is a recurring cost with no end date.**
  Tracker domains move. A list nobody updates decays into a list that mostly
  is not wrong yet, and there is no process here that keeps it current.
- **An exception is the exact host, so `github.com` does not cover
  `www.github.com`.** That will surprise people. It is the price of `blocks()`
  and the rule list agreeing by construction, and the surprise is at least
  consistent: the exception is filed against whatever host the page was on.
- **Every preference change recompiles.** Cheap because the identifier is a
  content hash, but it is a store round trip on a change that had nothing to do
  with blocking. The alternative was a list of fields somebody has to remember
  to extend, which is worse.
- **The failure state is asserted as a value, not as something a test drove the
  object into.** The honest routes to it — a corrupt store, a WebKit that
  changed its grammar — are not things a test can arrange, so what is covered is
  that the state says the right thing, not that it is reached at the right
  moment.

**What we get:**

- Blocking that runs in the networking layer, before the page, with no
  extension installed and no rules exposed to the page.
- An MIT binary with no licence obligation attached to it, and a survey written
  down so the next person does not redo it.
- A launch that pays 0.1 ms for blocking after the first run.
- One place that decides what an exception is, so the interface and the engine
  cannot disagree about a page.
- A blocker somebody can turn off from the broken site with one chord, and turn
  back on from a list that says where it came from.

## How this regresses

**By someone adding the count.** It is the most-requested thing in this feature
and there is SPI right there — `_WKContentRuleListAction` has `blockedLoad` on
it. Nothing goes red if somebody wires it up, the shield gets its number, and
the browser starts depending on a private header that breaks without warning
between releases. The number is not refused because it is hard. It is refused
because the public API does not have it.

**By loosening the exception anchor to be helpful.** "`github.com` should
obviously cover `www.github.com`" is a reasonable-sounding change that is one
character away from covering `github.com.evil.io`, and it also silently splits
`blocks()` from the rule list.
`an_exception_does_not_leak_to_a_lookalike_host` is what goes red.

**By letting a host skip `usable_exception` on one of the two paths.** The
tidier-looking version of `blocks()` compares strings directly. It passes every
obvious test, because a malformed host never equals a real one — and it puts a
row in Settings that exempts nothing, or a pattern in the list that fails the
whole compile. `a_hostile_exception_never_reaches_the_rule_list` and
`an_exception_nobody_could_compile_exempts_nothing_here_either` are the pair.

**By growing the list into a converted blocklist without re-measuring.** Seventy
rules compile in under a millisecond; fifty thousand take 119 ms on the main
thread, and WebKit parses the JSON *synchronously* there before handing the rest
to a work queue. `the_shipped_list_stays_far_under_webkits_ceiling` fails at
5,000 to force the conversation.

**By bundling a list because it is better.** It will be, and the licence is the
reason not to. AdGuard's and uBlock's are GPL-3.0 and would take the binary with
them; Disconnect's, Ghostery's and DuckDuckGo's are non-commercial, which would
reach zer0's own users downstream. No test can catch this. `docs/licensing.md`
is where it is written down.

**By deleting the failure state as noise.** `.failed` looks like a case that
never happens, and removing it turns "the switch is on and nothing is filtered"
into a silent condition.

## When to revisit

- **When somebody wants EasyList.** The path is established and the licence
  question is answered: take the CC-BY-SA-3.0 option, ship no converted list in
  the binary, fetch on first run, compile on device, and add the attribution
  screen — which is an obligation, not a courtesy. The engineering cost is the
  converter, not the licence: WebKit's grammar refuses alternation, so the
  translation from EasyList syntax is lossy and needs its own decision about
  what is dropped. And a first run that fetches needs the same honesty as
  everything else here — feedback while it downloads, and something that works
  offline.
- **When Apple publishes a blocked-resource count.** The moment there is a
  public API, the count is worth showing and this ADR's refusal expires.
- **When a Space wants blocking off wholesale**, often enough that per-host
  exceptions are visibly the wrong unit.
- **When the hand-written list is measurably stale** — a check that resolves the
  hosts and reports the ones that no longer exist would be cheap and is not
  written.
