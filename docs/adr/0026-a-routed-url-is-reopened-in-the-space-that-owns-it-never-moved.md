# ADR-0026: A routed URL is reopened in the Space that owns it, never moved

- **Status:** Accepted
- **Date:** 2026-03-26
- **Lock:** `crates/zer0-core/src/reducer_tests.rs::a_routed_page_loads_in_the_target_spaces_cookie_jar`, `crates/zer0-core/src/reducer_tests.rs::a_routed_url_opens_in_the_space_that_owns_it`, `crates/zer0-core/src/reducer_tests.rs::routing_from_a_blank_tab_does_not_litter_the_old_space`, `crates/zer0-core/src/reducer_tests.rs::a_url_already_in_its_own_space_is_not_bounced_again`, `crates/zer0-core/src/routing.rs::a_regex_rule_is_compiled_once_not_once_per_url`, `crates/zer0-core/src/routing.rs::adding_a_rule_takes_effect_on_an_already_used_table`, `crates/zer0-core/src/routing.rs::a_domain_rule_refuses_lookalike_hosts`, `crates/zer0-core/src/routing.rs::an_idn_rule_matches_both_spellings_of_the_host`

## Context

Two accounts on the same site, work and personal in the same window, a client's
dashboard that must never see the other client's cookies. ADR-0007 gave that a
mechanism: a Space owns a cookie jar. What it did not give it is a habit —
somebody still has to remember to be in the right Space before clicking the
link, every time, forever. Nobody does.

This is ported from the idea behind `avelino/firefox-airtraffic`, which routes
URLs into Firefox containers. It lands better here than it does in Firefox: a
Space already *is* a container, so routing to a Space is routing to a container,
and there is no pairing between two concepts to keep in sync.

The mechanism is a small ordered table — first match wins — evaluated on every
navigation. Everything interesting is in what "send it to that Space" is allowed
to mean, and in what it costs to ask the question that often.

## Decision

`crates/zer0-core/src/routing.rs` holds the table; the reducer holds what
happens when it matches.

### The tab is reopened, not moved

This is the finding that shaped the behaviour, and it is not a design
preference. **A `WKWebView` is bound to its data store from creation.** There is
no API to change the jar under a live view. So "route this URL to Work" cannot
mean "move this tab to Work" — the moved tab would still be carrying the
personal jar.

`reducer.rs::hand_off`:

> The page is reopened rather than moved, because a web view is bound to the
> cookie jar it was built with. A tab that never went anywhere is closed behind
> us so routing from a fresh tab does not litter the old space.

Which produces three behaviours worth naming:

- **Routing on `NavigateTo`** opens a new tab in the target Space and loads
  there. If the tab it came from was blank — no URL and `TabKind::Today` — it is
  removed and its view destroyed, so ⌘T-then-type does not leave an empty tab
  behind. If the tab had a page on it, it stays exactly as it was: *you did not
  ask to lose the page you were reading.*
- **Routing on `OpenTab`** happens **before anything is created**, so a routed
  URL never briefly exists in the wrong Space's cookie jar. Not "is moved
  quickly" — never exists there.
- **A URL already in its own Space is not bounced again.** `target != from` is
  the loop guard, and without it every navigation inside the Work Space would
  open a fresh tab in the Work Space.

The same constraint shows up wherever a tab crosses a jar boundary for any other
reason: `relocate` rebuilds the view on a cross-Space move, and
`SetSpaceProfile` rebuilds every view in the Space. Both destroy and recreate,
and both lose the back/forward history, the scroll position and any half-filled
form — the cost ADR-0007 already booked.

### The prepared form is a derived cache behind a `OnceLock`

`route` runs on **every navigation, every new tab, and every keystroke in the
command bar** — `CommandBar.swift` calls `routeDestination(for:)` to show where
a link would land before it is followed. Compiling a regex there costs hundreds
of microseconds per rule and buys nothing, because the pattern cannot change
between two calls.

So every rule gets a `Prepared` form, built once on first use and held in a
`OnceLock`, index-aligned with `routes`. Any edit — `push`, `remove`,
`set_enabled`, `retain_spaces` — calls `invalidate()`, which takes the cell.
Alignment by index is what makes the zip in `route` correct, and it is also what
makes a stale cache dangerous rather than merely slow: a stale cache routes by
the wrong rule.

`Prepared` also resolves the failure cases once. A malformed domain, an empty
fragment or a regex that does not compile becomes `Prepared::Never` — *"Keeping
it as a value is what preserves 'a broken rule matches nothing' without a
special case at match time."* A pattern that will not compile is remembered as
never matching, never retried, and the rules behind it keep working.

One more thing is hoisted: `url.to_lowercase()` is computed once per `route`
call, and **only if some rule is a `UrlContains`**, because a `data:` URL out of
view-source runs to hundreds of kilobytes and lowercasing it on every keystroke
for rules that never look at it is pure waste.

### `PartialEq` on the cache is always `true`

```rust
impl PartialEq for PreparedCache {
    fn eq(&self, _other: &Self) -> bool { true }
}
```

Subtle enough to deserve the record, because it looks exactly like a bug.

The cache is **derived state**. Two `RoutingTable`s with the same rules are the
same table, whatever either has happened to compile so far. If equality
compared the compiled forms, then two identical tables would compare unequal
purely because one had been used and the other had not — and `Session` equality,
which tests lean on, would depend on evaluation history. `Regex` does not
implement `PartialEq` either, so the derive would not compile at all; the
alternative is not "compare properly", it is "do not derive `PartialEq` on
`RoutingTable`".

It is separated into its own type for exactly this: so `RoutingTable` keeps
deriving `Clone` and `PartialEq` and the one dishonest-looking `impl` is
isolated where it can be read with its reason next to it.

### Matching fails closed

- **`Domain` matches the host or a subdomain, and the boundary must be a dot.**
  `github.com` matches `gist.github.com`, never `fakegithub.com` and never
  `github.com.evil.io`. Getting this wrong sends session cookies to a phishing
  domain's Space.
- **IDN is normalised through `url::Url`**, so a rule typed `münchen.de` and a
  host arriving as `xn--mnchen-3ya.de` are the same domain. Comparing raw text
  matches neither spelling and the page lands in the wrong Space with nothing
  said — an isolation control that fails silently.
- **A `Domain` rule carrying anything but a host matches nothing.** Userinfo, a
  port, a path, a query: malformed, and guessing what it meant would route more
  than it says.

## Consequences

**What hurts:**

- **Routing costs you the page's state.** A new tab, a new view, a fresh load.
  Back/forward history, scroll position, form contents, the state of any web app
  — all gone, every time a rule fires. There is no way around it and no warning
  before it happens.
- **A POST cannot be routed.** Reopening means a fresh `GET`. Submit a form on a
  page whose result URL matches a rule and the routed tab loads something else,
  or nothing. Nothing detects this.
- **Two tabs where the person expected one.** Routing away from a tab that has a
  page on it leaves that tab where it was, on purpose — and the person now has
  the old page in one Space and the new one in another, plus a Space switch they
  did not ask for. Correct, and surprising the first several times.
- **`DomainContains` is a footgun with a warning label.** `fragment: "github"`
  matches `fakegithub.com`. It is documented as "looser, and deliberately so",
  and it is one typo away from routing a phishing domain into the Space that
  holds the real credentials.
- **The cache is only as correct as `invalidate()`.** Four mutators call it
  today. A fifth that forgets produces a table that routes by rules that are no
  longer there — and the symptom is a page in the wrong cookie jar, which is the
  worst symptom this codebase has.
- **`PartialEq` returning `true` is a lie in the small to tell the truth in the
  large.** It is correct for derived state and it will read as a bug to every
  new person, forever. It is also unlockable: no test asserts it, because the
  behaviour it protects is "two tables with the same rules compare equal", which
  is what a derive would give you anyway if `Regex` allowed one.
- **A rule can send you somewhere you did not intend and there is no undo.**
  There is no "open here anyway" for a single navigation, and no indication in
  the moment that a rule was what moved you.

**What we get:**

- Work URLs land in the work jar without anyone remembering to switch first, and
  they were never anywhere else, not for an instant.
- Ten non-trivial regex rules evaluated on every keystroke cost nothing
  measurable.
- A broken rule is inert instead of contagious.

## How this regresses

**"I logged into the client's dashboard and it had the other client's
session."** The routed page was created in the wrong jar. The path there is
short: `hand_off` becomes a `MoveTab`, because moving looks obviously cheaper
than reopening and the web-view binding is invisible from the reducer.
`a_routed_page_loads_in_the_target_spaces_cookie_jar` asserts positively that a
`CreateWebView` carrying `ds-work` was emitted **and** negatively that none
carrying `ds-personal` was. It is the most important assertion in this ADR.

**"Every link I click opens a new tab."** The `target != from` guard went
missing and every navigation inside a routed Space re-routes to itself.
`a_url_already_in_its_own_space_is_not_bounced_again` asserts the tab count is
unchanged and the command list is exactly one `LoadUrl`.

**"I have twenty empty tabs in Personal."** The blank-tab cleanup in `hand_off`
was dropped — plausible, because it looks like an optimisation rather than
behaviour. Every ⌘T-then-type that routes leaves a corpse behind.
`routing_from_a_blank_tab_does_not_litter_the_old_space` asserts both the
`DestroyWebView` command and the tab count going down.

**"I lost the page I was reading."** The opposite: the cleanup grows to cover
tabs that *had* a page. `routing_away_from_a_used_tab_leaves_it_where_it_was`
holds that line and is not on the `Lock:` line only because that line is already
long — it belongs to this decision.

**"Typing in the address bar got slow."** The `OnceLock` was removed, or
`prepare` moved back inside the match loop, because the caching looked like
premature optimisation. `a_regex_rule_is_compiled_once_not_once_per_url` is a
behavioural stand-in: ten non-trivial patterns, a thousand URLs, 2000
evaluations, bounded at one second. Recompiling per call took **seconds** there;
reusing the compiled form takes **milliseconds**. The bound is deliberately
loose so a busy machine does not turn it red for the wrong reason.

**"I added a rule and it did nothing until I restarted."** `invalidate()` was
missed on a new mutator, or the cache was moved somewhere it is not taken on
edit. `adding_a_rule_takes_effect_on_an_already_used_table` routes once first —
forcing the cache to build — and only then pushes the rule. Its siblings
`removing_a_rule_takes_effect_on_an_already_used_table`,
`disabling_a_rule_takes_effect_on_an_already_used_table` and
`rules_pointing_at_a_deleted_space_are_dropped` do the same for the other three
mutators, and each of them routes before mutating for the same reason.

**"github.com.evil.io opened in my work Space."** Domain matching became a
`contains` or a `ends_with` without the dot. This is the phishing case and it
looks like a simplification. `a_domain_rule_refuses_lookalike_hosts` names three
variants explicitly.

**"My rule for münchen.de stopped matching."** The `url::Url` round trip in
`normalized_host` was replaced with a lowercase comparison, which is faster,
simpler, and matches neither spelling of an IDN host consistently.
`an_idn_rule_matches_both_spellings_of_the_host` covers both encodings in both
directions, including the negative cases.

**"One bad regex broke all my routing."** `Prepared::Never` was replaced with an
error path that bails out of `route`.
`a_broken_regex_matches_nothing_instead_of_breaking_routing` checks that the
rules *after* the broken one still fire, and loops ten times to prove the
failure is remembered rather than retried.

**No lock:** the `PartialEq` impl. Nothing asserts that two tables with the same
rules compare equal after only one of them has routed. It is two lines in
`routing.rs`'s test module and it is declared debt here rather than covered by a
lock that does not exist.

## When to revisit

- If reopening's cost becomes the top complaint. The only real answer is a way
  to hand a live view to another store, which is Apple's to provide; a
  workaround that preserves history across a rebuild would be a new decision.
- If a POST that should have been routed causes real damage. Then routing needs
  to know the navigation is not a plain `GET` and refuse rather than reopen.
- When the Linux host arrives. Whether `webkit2gtk` binds a view to its data
  manager the same way is the question that decides whether "reopen, not move"
  was a WebKit constraint or a universal one.
- If the rule set ever gets large enough that a linear scan matters. The
  prepared cache makes each rule cheap; nothing makes the scan sublinear, and a
  host index would be the obvious next step.
- If somebody proposes deleting the `PartialEq` impl. Read this section first —
  the alternative is dropping `PartialEq` from `RoutingTable` entirely, and that
  reaches `Session`.
