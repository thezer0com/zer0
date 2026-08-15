# ADR-0054: `zer0://` is an address space, and WebKit is never told it exists

- **Status:** In progress — the scheme, its four addresses and the chat page are built; conversations are still anchored to a tab rather than to a URL
- **Date:** 2026-06-09
- **Lock:** `apple/Tests/Zer0ShellTests/InternalPageTests.swift::InternalPageTests/webKitIsNeverToldOurSchemeExists`, `apple/Tests/Zer0ShellTests/InternalPageTests.swift::InternalPageTests/nothingRegistersASchemeHandler`, `apple/Tests/Zer0ShellTests/InternalPageTests.swift::InternalPageTests/goingToOneOfOurAddressesNeverReachesAnEngine`, `apple/Tests/Zer0ShellTests/InternalPageTests.swift::InternalPageTests/aWindowAddressRaisesAWindowAndLeavesTheTabAlone`, `apple/Tests/Zer0ShellTests/InternalPageTests.swift::InternalPageTests/everyAddressInTheSchemeRoutes`, `apple/Tests/Zer0ShellTests/InternalPageTests.swift::InternalPageTests/anAddressDecidesWhetherItIsAPageOrAWindow`, `apple/Tests/Zer0ShellTests/InternalPageTests.swift::InternalPageTests/aConversationNeverSendsThePageThatIsShowingIt`, `apple/Tests/Zer0ShellTests/InternalPageTests.swift::InternalPageTests/askingAboutAPageOpensOneTabAndReturnsToIt`, `crates/zer0-core/src/reducer_tests.rs::an_address_of_ours_never_reaches_a_web_engine`, `crates/zer0-core/src/reducer_tests.rs::an_address_that_names_nothing_fails_as_ours_rather_than_as_a_site`, `crates/zer0-core/src/reducer_tests.rs::a_restored_internal_tab_is_never_reloaded`, `crates/zer0-core/src/reducer_tests.rs::an_air_traffic_rule_cannot_route_one_of_our_addresses`, `crates/zer0-core/src/reducer_tests.rs::an_address_commits_canonically_however_it_was_typed`, `crates/zer0-core/src/reducer_tests.rs::no_address_in_the_scheme_is_dead`, `crates/zer0-core/src/internal_url.rs::an_address_we_do_not_recognise_is_still_never_the_webs`, `crates/zer0-core/src/internal_url.rs::every_address_round_trips_through_its_own_url`, `crates/zer0-core/src/internal_url.rs::a_conversation_that_is_not_a_number_is_dropped_rather_than_repaired`

## Context

ADR-0049 gave chat a core and said a conversation is opened with ⌘E. It did not
say where the conversation is *drawn*, and the honest answer for a while was
nowhere: the chord worked, the reducer minted a thread, and no view in the shell
had ever heard of one.

The obvious answers were a panel beside the page or an overlay over it, and both
fight decisions this project has already taken. ADR-0010 is a spending limit on
anything that sits over a page. ADR-0042 says a split is two tabs shown together,
so a split cannot hold something that is not a tab. And a panel has to grow, one
at a time, everything a tab already has: somewhere to live when you switch away,
a way to be closed, a way to come back after a restart, a place in the sidebar.

Meanwhile three other surfaces have the same problem from the other end.
Settings, history and downloads are all reachable only by chord or menu. None of
them has an address, so none of them can be linked to, typed, bookmarked or
restored.

Both problems are one missing thing: **the browser has no way to address
itself.**

The moment you decide to fix that, the question stops being a layout question
and becomes a security question, because a URL scheme is an attack surface. A
page can put a URL in an `<iframe>`, redirect to it, or fetch it as a
subresource. If any of those can reach a page holding somebody's conversations,
that is a worse bug than anything chat could otherwise have.

The SDK settles it, and it was read rather than recalled.
`WKURLSchemeTask` — the object a registered handler is given — carries exactly
one thing about the request: `request`. No frame, no initiator, no navigation
type. So a handler **cannot distinguish** a person typing an address from
`evil.com` framing it. The only place that distinction exists is
`decidePolicyFor navigationAction`, which has `sourceFrame`, `targetFrame` and
`navigationType` — and a subresource load never reaches a navigation delegate at
all. The header even says the quiet part: *"Cross-origin requests require CORS
header fields"*, which is a sentence about a handler being invoked by content
that is not ours.

## Decision

**`zer0://` is an address space owned by the core, and WebKit is never told it
exists.**

Four parts.

### The scheme is not registered, and that is the whole security answer

Nothing calls `setURLSchemeHandler`. `WKWebView` cannot resolve `zer0:`, and
every question about the attack surface is answered by that one fact rather than
by a filter somebody has to maintain:

- **Can a page navigate to one?** No. The navigation policy delegate cancels any
  request claiming our scheme, and there would be nothing to load it with if it
  did not.
- **Can a page frame one?** No — a subframe navigation reaches the same delegate,
  and is cancelled by the same line.
- **Can a redirect reach one?** No, for the same reason.
- **Can a subresource load reach one?** This is the case a delegate cannot see,
  and it is the reason the scheme is unregistered rather than filtered: with no
  handler there is nothing for the load to reach.
- **What origin does an internal page get?** None, because an internal page is
  not web content. It is drawn natively in SwiftUI. There is no document, no
  script, no `window.webkit`, and therefore nothing to reach *through*.

The delegate check is deliberately kept even though it is redundant today. "We
never gave WebKit the scheme" is an absence, and an absence is not a guarantee.
The cancel is the sentence that says no on purpose, and it is what keeps saying
no if a handler is ever registered for some unrelated reason.

### An address space, not a page type

Four addresses, and **what an address does is that address's decision, not the
scheme's**:

| Address | Effect |
|---|---|
| `zer0://chat` | a page, drawn in the tab |
| `zer0://history` | a page, drawn in the tab (was a window; ADR-0063) |
| `zer0://downloads` | a page, drawn in the tab (was a window; ADR-0063) |
| `zer0://settings` | raises the Settings window |

`InternalAddress::effect()` returns `Page` or `Window { command }`, and there is
no default — a new address does not compile until somebody chooses.

Configuration is a window you keep beside your work and then close; a
conversation is a thing you keep, revisit, pin and put next to the page it is
about, which is a tab. Forcing one shape on all four would give either a settings
*tab* competing with the window ⌘, already opens, or a conversation trapped in a
window that cannot be pinned, split or restored.

`Window` carries a `UiCommand` rather than a window name, because the browser
already has those four commands and they already carry ADR-0053's rule about
which window a command may land in. A window address never commits a navigation:
going to `zer0://settings` from a page leaves you on that page with Settings in
front of it, which is what ⌘, does.

**History and downloads were `Window` here and are `Page` since ADR-0063.**
They are long lists with searching and scrolling in them. Routing them at the
window they were built inside kept every address in the scheme alive until the
pages existed; the panes they came from are now deleted.

### A conversation is a tab

`⌘E` opens a tab at `zer0://chat?conversation=7`, and the conversation inherits
everything a tab already does: the sidebar lists it, ⌘W closes it, a split puts
it beside the page it is about, the session restores it. Pressing ⌘E again
returns to that tab rather than opening a second — and pressing it *while
already in one* means that conversation, not a new thread about the thread.

The core acts on an internal address itself: there is nothing to load, so the
tab is already showing it when the navigation returns. No `LoadUrl` is emitted,
no `NavigationStarted` is ever reported, and the address commits under its
canonical spelling rather than whatever was typed.

### An internal page is never read for a conversation

`page_worth_attaching` refuses any tab whose URL claims our scheme. An internal
page has no document, so a capture would come back empty at best — and at worst
a future internal page would quietly start posting its own contents to a
provider.

## Consequences

**What this costs:**

- **An internal page cannot be built out of HTML, and every one is written again
  for a second shell.** That is the price of a page a hostile site cannot
  address. For surfaces holding conversations, history and downloads it is worth
  paying; for a page that was mostly a document it would not be.
- **A chat tab still owns a `WKWebView` that is never navigated.** The tab is an
  ordinary tab, so `CreateWebView` is emitted for it and the native page is drawn
  over the top. That is a wasted view per chat tab. Removing it means teaching
  tab creation about internal addresses, which is a bigger change than the one it
  saves.
- **`EngineCommand` grew a command that is not about an engine.** `RaiseWindow`
  is an instruction to the shell, not to WebKit. `AskDownloadDestination` already
  set that precedent, but the type's name is now one step further from the truth.
- **A `zer0://` URL is visible in the command bar and will be typed wrong.**
  `zer0://nonsense` is refused as ours rather than searched for, which is right,
  but it produces an error screen for what looks like a typo.
- **The address is a second place a conversation id is written down.** A tab's
  URL now names a thread, so a session file that disagrees with the chat table
  produces a chat tab addressing nothing. It fails to an empty state rather than
  to a wrong thread, which is the safe direction.
- **Two panes had to leave Settings.** They did, in ADR-0063. See
  "When to revisit".

**What we get:**

- Every surface in the browser can be addressed, linked and restored.
- A conversation gets pinning, splitting, closing and restoring for free, and
  none of it had to be built.
- ADR-0010 stops being in tension with chat entirely: nothing sits over the page,
  because the conversation *is* a page.
- The security posture is a property of what was never built rather than of a
  filter somebody maintains.

## How this regresses

**"A web page opened my conversations."** Somebody registers a scheme handler —
most plausibly while making an internal page out of HTML, which is the reasonable
thing to want. `nothingRegistersASchemeHandler` names the file, and
`webKitIsNeverToldOurSchemeExists` covers the platform half. Both were watched
going red against a real `setURLSchemeHandler` call before this was written.

**"Typing an internal address searched for it."** Or worse, handed it to an
engine that reported it as a site that does not exist.
`an_address_of_ours_never_reaches_a_web_engine` and
`an_address_that_names_nothing_fails_as_ours_rather_than_as_a_site` hold both
ends. The guard is in `start_navigation` and nowhere else on purpose: an earlier
draft checked in `NavigateTo` as well, and breaking the real guard left that path
working — which is exactly how a second door hides a missing one.

**"It opened Settings and blanked my tab."** Somebody makes every address a page
because the enum is simpler with one shape.
`aWindowAddressRaisesAWindowAndLeavesTheTabAlone` is the fence.

**"It sent my chat page to the model."** `page_worth_attaching` loses its
internal check during a refactor of what counts as a page worth attaching.
`aConversationNeverSendsThePageThatIsShowingIt` is the lock, and it is written
against the browser rather than the reducer so it covers the whole path.

**"⌘E opened forty tabs."** The chord resolves "the page you are on" to the chat
tab it just opened. This happened during development and was caught by
`pressing_it_twice_on_one_tab_is_one_thread`, which had been written for a
different reason entirely.

**And the one no test catches:** an internal page that grows a way to reach the
web — a link, an embed, an image loaded from a URL in a conversation. The moment
one does, an internal page is a place remote content is rendered, and every
question this ADR answered by construction has to be asked again.

## When to revisit

- ~~**When history or downloads becomes a page.**~~ **Settled by ADR-0063.**
  Both became pages, and both panes were deleted rather than left unreachable.
  What this bullet predicted is what happened: the shape change was one match
  arm, and the whole of the work was the product decision about the pane — where
  "Clear History…" lives, whether a day header earns its space, and what a list
  with no rows in it should say.
- **When conversations are anchored to a URL rather than to a tab.** The owner
  has asked for this and it supersedes part of ADR-0049: opening chat on a page
  discussed before should bring the thread back, a second thread about one page
  should be deliberate, and where a page has several the most recent opens with
  the others listed. That needs a `ConversationScope` keyed on a normalised URL,
  a decision about what counts as the same page, and a rule about which URLs may
  be written down at all — magic links and signed URLs carry secrets in the query
  string, and an ephemeral space must still record nothing (ADR-0023). The
  address `zer0://chat?conversation=` is deliberately shaped to survive that
  change.
- **If a second shell arrives.** Every internal page is written again in that
  shell's toolkit. If that cost turns out to dominate, the alternative is not a
  registered scheme — it is a local renderer with no network reachability at all,
  which is a different decision with the same security requirement.
- **If an internal page ever needs remote content.** See "How this regresses".
  That is a new ADR, not a change to this one.
