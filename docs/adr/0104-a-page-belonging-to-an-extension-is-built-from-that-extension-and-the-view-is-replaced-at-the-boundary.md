# ADR-0104: A page belonging to an extension is built from that extension, and the view is replaced at the boundary

- **Status:** Accepted
- **Date:** 2026-08-10
- **Lock:** `crates/zer0-core/src/url_input.rs::an_address_inside_an_extension_is_never_searched_for`, `crates/zer0-core/src/extension_url.rs::the_host_is_what_tells_two_extensions_apart`, `crates/zer0-core/src/extension_url.rs::an_address_naming_no_context_is_not_repaired_into_one`, `crates/zer0-core/src/reducer_tests.rs::a_page_inside_an_extension_gets_a_view_built_for_that_extension`, `crates/zer0-core/src/reducer_tests.rs::leaving_an_extensions_page_puts_the_tab_back_in_its_spaces_jar`, `crates/zer0-core/src/reducer_tests.rs::moving_between_two_pages_of_one_extension_does_not_cost_the_view`, `crates/zer0-core/src/reducer_tests.rs::a_space_that_records_nothing_has_nowhere_to_put_an_extensions_page`, `crates/zer0-core/src/reducer_tests.rs::an_extension_address_naming_no_context_is_refused_rather_than_repaired`, `crates/zer0-core/src/reducer_tests.rs::crossing_into_an_extension_does_not_carry_the_back_list_over`, `crates/zer0-core/src/storable_tests.rs::an_address_inside_an_extension_is_not_written_down`, `apple/Tests/Zer0ShellTests/ExtensionPageTests.swift::ExtensionPageTests/anExtensionsOwnPageOpensAndRenders`, `apple/Tests/Zer0ShellTests/ExtensionPageTests.swift::ExtensionPageTests/anExtensionsOwnConfigurationIsWhatLoadsItsPages`, `apple/Tests/Zer0ShellTests/ExtensionPageTests.swift::ExtensionPageTests/anExtensionsPageKeepsTheStoreItArrivedWith`, `apple/Tests/Zer0ShellTests/ExtensionPageTests.swift::ExtensionPageTests/aBaseHostNoExtensionAnswersToIsRefused`, `apple/Tests/Zer0ShellTests/ExtensionPageTests.swift::ExtensionPageTests/aPrivateWindowRefusesAnExtensionsPage`, `apple/Tests/Zer0ShellTests/ExtensionPageTests.swift::ExtensionPageTests/oneExtensionCannotOpenAnothersPage`

## Context

**An extension could not open one of its own pages in `zer0` at all.** Not its
options screen, not its onboarding, not a welcome flow — no extension, not one
in particular. ADR-0086 enumerated it as a defect and named the two independent
breaks, both ours.

**The core turned the address into a web search.** `PASSTHROUGH_SCHEMES` had
five entries and `webkit-extension` was not among them, so
`resolve("webkit-extension://…/app.html#/page/welcome")` came back
`Search("https://duckduckgo.com/?q=webkit-extension%3A%2F%2F…")`. Every road to
one of these pages — `chrome.tabs.create`, a person pasting one, an extension
opening its own onboarding — runs through `Action::OpenTab`, and through that
one line.

**And the shell built the tab's view from the wrong configuration.**
`WKWebExtensionContext.h`: *"navigations will be canceled if a web view not
configured with this configuration attempts to navigate to a URL that does
originate from this extension's base URL"*, and *"the app must also swap web
views in tabs when navigating to and from web extension URLs."* Measured, same
address and same run:

| configuration | result |
| --- | --- |
| ordinary page configuration | `about:blank` — cancelled |
| `context.webViewConfiguration` | loads and renders, `title = 1Password` |

**Re-measured 2026-08-10, and the refusal is real but not universal.** In a
fresh process, sampled out to 34 seconds, with the extension controller attached
to the plain configuration and without it, the view stays at `about:blank` — the
reading above, twice over. Inside the Swift test process, where earlier suites
have already loaded extensions into the default controller configuration, the
same address loads in a plain configuration in under a second. Nothing in this
decision turns on which happens: a page built from the extension's own
configuration loads every time, in both processes, and that is the arm this ADR
uses. But it is why the "loads nothing" half is **not** locked — an assertion
either way would go red on how the run was scheduled.

### The measurement that decided the shape of this

The obvious way to keep ADR-0007's promise would be to take the extension's
configuration and put the space's cookie jar on it. **That is not available,
and it fails in the worst possible way.** Measured against a real package in a
real controller, one process per case, with the assignment made on the
configuration before the view is built:

| what was assigned to `context.webViewConfiguration.websiteDataStore` | `WKWebView.init` |
| --- | --- |
| nothing | returns; the page loads |
| the store it already had | returns; the page loads |
| `WKWebsiteDataStore.default()` | returns; the page loads |
| `WKWebsiteDataStore(forIdentifier:)` — what every space uses | **never returns** |
| `.nonPersistent()` — what an ephemeral space uses | **never returns** |

The instrument was checked before it was believed, because a hang is exactly
the reading a broken probe produces: **the same two assignments on an ordinary
`WKWebViewConfiguration` build a view and load `https://example.com` in the same
binary.** A sample of the wedged process shows the main thread idle in the run
loop and WebKit's `ServicesController` blocked in `dispatch_sync` on the main
queue.

Read off the configuration as it arrives: `websiteDataStore.isPersistent` is
`true` and it **is** `WKWebsiteDataStore.default()`, which is the extension
controller's default store and is not any space's. Two reads of
`context.webViewConfiguration` return different objects, so it is a copy per
call; the controller, the content controller and the User-Agent
`ExtensionHost.configuration` set are all already on it.

So: an extension's page is not in a space's cookie jar, it cannot be put in one,
and the only question left is what this browser does about that.

## Decision

**A page belonging to an extension is built from that extension's own
configuration, its view is replaced when a tab crosses the boundary in either
direction, and a space that records nothing refuses one outright.**

### The address is navigated, and only the shell may resolve it

`webkit-extension` joins `PASSTHROUGH_SCHEMES`. `crate::extension_url` is the
mirror of `crate::internal_url`, and the two must not be confused: `zer0://` is
**ours** and WebKit is never told it exists (ADR-0054); this scheme is
**WebKit's**, it owns every page under it, and the whole job is to stop mangling
it.

The host in one of these is a uuid **WebKit** minted for a live context — not
the id the browser installed under, and a different uuid on the next launch. So
nothing in the core maps a host to an extension. The core carries the host; the
shell, which is the only side that knows which contexts exist, resolves it or
refuses it. Three refusals, and each is a refusal rather than a repair:

- **An address naming no context** — `webkit-extension:///x` — fails as an
  extension's, the way `zer0://nonsense` fails as ours.
- **A host nothing loaded** gets `nil` from `pageConfiguration(forBaseHost:)`
  and the tab gets the failure screen, rather than a view built for whichever
  extension happened to be at hand.
- **An extension asking for a *different* extension's page** is refused at
  `openNewTabUsing`, which is the one delegate that knows who is asking. The
  page it would open carries that other extension's storage and origin.

### Two kinds of view, and neither can express the other

`EngineCommand::CreateWebView` stopped carrying `data_store_id` and `profile`
and now carries a `ViewConfiguration`:

```rust
pub enum ViewConfiguration {
    Space { data_store_id: String, profile: SpaceProfile },
    Extension { base_host: String },
}
```

**`Extension` has no field a data store fits in**, which is the guarantee rather
than a rule. It is not tidiness: given the measurement above, a `data_store_id`
on that arm would describe a state that cannot exist, and the code that tried to
honour it would hang rather than fail.

### The view is replaced at the boundary, in both directions

`start_navigation` is the one door — the same one ADR-0054's guard sits at, for
the same stated reason. It compares which extension's context the tab's view is
in with which one the destination needs, and replaces the view when those
differ. Two pages of one extension are one context and cost nothing.

**The leaving half is a security requirement and not symmetry.** Without it, a
link off an extension's own page loads the web into the extension's
configuration — whose store is WebKit's shared persistent one — which is exactly
the escape from the space's cookie jar that the arriving half exists to prevent.
That is also the flow that matters: ADR-0072 measured 1Password's welcome page
resolving its sign-in to `https://start.1password.com/signin/?auth-only=1`.

**This is the third crossing that costs a view and it is answered the way the
other two are.** A tab moving between spaces and a space changing profile both
go through `rebuild_view`, which has existed and been tested since ADR-0007. The
tab keeps its id, its place in the sidebar, its space, its window and its
conversation; only the view goes. What was described as needing a new
replacement path did not: the path was already there and already exercised.

**The back/forward list does not cross.** Every entry on one side of the
boundary is one the view on the other side refuses, so it is forgotten rather
than filtered — a history with the crossing cut out of it is a Back button that
skips a page.

### An extension's page does not go in a space that records nothing

An ephemeral space promises that nothing is written down (ADR-0023). An
extension's page runs in WebKit's shared, persistent store and cannot be made to
run anywhere else. So a private window has nowhere to put one, and it is refused
— not quietly excepted, and not repaired into a space that would take it.

The refusal is one predicate, `refuses_extension_page`, asked by both places
that could get it wrong: `open_in`, which aims a brand-new tab before building
its view, and `start_navigation`, which carries the refusal out. A condition
copied into the second is a tab whose view is built for an extension and whose
navigation is then refused, which is the interface and the engine disagreeing
about what a tab is.

**What this does not change**, and it would be dishonest to imply otherwise: an
extension's background worker and its popup already run in that same shared
store, in every window, always. This decision does not make extensions private,
it keeps a *tab* from being the thing that breaks the promise.

### An extension's address is not written down

The host is minted per context, so a stored address names nothing after a
relaunch — it would come back as a refusal screen where an options page used to
be. `storable_tab` drops the URL and its history and keeps the tab, which comes
back blank. That is also what makes `rehydrate` correct without knowing any of
this: no tab ever comes back holding one.

## Consequences

**What this costs:**

- **A tab crossing the boundary loses its back/forward list.** Stated above and
  unavoidable while the two sides are different browsing contexts. A person
  following a link out of an extension's page cannot press Back to it.
- **The refusal screen says "unsupported address" and not why.** A private
  window refusing an extension's page, and an address naming a dead context,
  both land on ADR-0016's screen with the wording every unsupported address
  gets. Saying the real reason needs a new `NavigationErrorKind` and a screen
  drawn for it, which is its own decision.
- **Extensions are told a tab closed and reopened when its view is replaced.**
  `notifyExtensions` reads `DestroyWebView` as `tabClosed` and `CreateWebView`
  as `tabOpened`, so a crossing looks like a replacement to `chrome.tabs`. This
  is not new — a tab dragged between spaces has always done it — but this makes
  it reachable more often. Declared debt, not covered by a lock here.
- **A pop-up opened *from* an extension's page inherits that page's
  configuration**, because ADR-0075's whole point is that the engine's
  configuration is used as given. So `window.open` from an extension's own page
  lands in the extension's store rather than the space's. Named because it is
  the one hole the boundary rule does not close, and closing it means refusing a
  pop-up the engine has already built.
- **`EngineCommand::CreateWebView` changed shape**, so every host that ever
  exists has to answer which of the two it is being asked for. That is the
  point, and it is the cost.

**What we get:**

- Every extension's options page and onboarding page opens, which is the whole
  of ADR-0086's entry.
- The escape it would have opened is closed in the same change rather than
  after somebody notices it.
- `webkit2gtk` inherits the rule and none of the WebKit in it: which
  configuration an extension's page needs is a platform answer, and *that a tab
  crossing the boundary gets a new view* is behaviour, tested without a window.

## How this regresses

**"My extension's options page opens a blank tab."** Somebody builds the view
from a configuration of their own — the tidy-looking change, because
`HostedWebView` builds configurations everywhere else, and this path visibly
does not. `anExtensionsOwnPageOpensAndRenders` is the lock, and
`anExtensionsOwnConfigurationIsWhatLoadsItsPages` is the instrument beneath it:
a bare `WKWebView` on the extension's configuration really does load one of
these, so a failure in the first is this browser's and not WebKit's.

**The control that was supposed to sit here lied twice, and both ways are worth
recording.** First it passed against a package that was no longer on disk — the
fixture deletes its own directory when it is released, and neither test held
one. Then, rewritten, it waited three seconds for a load *not* to happen: alone
that read as a refusal; under the full suite three seconds of wall clock were
not enough for anything at all. Chasing that is what turned up the re-measurement
in Context — the refusal does not reproduce inside the test process — so the
assertion was removed rather than made to pass. A lock that depends on which
suites ran first is worse than the debt of not having one.

**"The browser hangs when I open an extension's options page."** Somebody puts a
store on the extension's configuration, most plausibly while making it obey
ADR-0007, which is a completely reasonable thing to want. It does not fail, it
wedges — `WKWebView.init` never returns and a sample points at WebKit's
`ServicesController`, nowhere near the line.
`anExtensionsPageKeepsTheStoreItArrivedWith` says so where it happens, and the
measurement table above is why that test exists at all.

**"A private window wrote something down."** The ephemeral refusal is dropped as
over-cautious — it *reads* as over-cautious, because an extension's own screen
is not browsing. `a_space_that_records_nothing_has_nowhere_to_put_an_extensions_page`
holds the core half and `aPrivateWindowRefusesAnExtensionsPage` drives it
through the real browser.

**"A link off my password manager's page signed me in as somebody else."** The
leaving half is deleted as symmetry nobody asked for — it is the arm of the
comparison with no visible failure attached to it, because the page it breaks
loads fine either way. What it does is put a web page in the extension's shared
jar. `leaving_an_extensions_page_puts_the_tab_back_in_its_spaces_jar` is the
fence, and `moving_between_two_pages_of_one_extension_does_not_cost_the_view` is
what stops the fix for it being "always replace".

**"One extension opened another one's settings."** The `context` argument in
`openNewTabUsing` goes back to `_`, because the address is the core's business —
which is true of *web* addresses and not of these.
`oneExtensionCannotOpenAnothersPage` is the lock.

**"Every tab in my session came back as an error screen."** An extension's
address is written down after all, and the uuid it names is last run's.
`an_address_inside_an_extension_is_not_written_down` catches it at the
projection, where it holds for every backend rather than for SQLite.

**And the one no test catches:** somebody reads this and concludes that
extensions now work in private windows, or that an extension's page is isolated
per space. Neither is true, both are stated above, and the sentence that would
be wrong is the reassuring one.

## When to revisit

- **The scheme and the identity are both ours to choose, and today we take
  WebKit's defaults. That is a defect, not only a cosmetic one.** Measured on
  the macOS 26 SDK: `WKWebExtensionContext.baseURL` and `.uniqueIdentifier` are
  both settable — `copy`, not `readonly` — and the shell sets neither. It only
  ever reads `baseURL.host`.

  The headers say what that costs. `baseURL`: *"The default value is a unique
  URL using the `webkit-extension` scheme… The scheme cannot be a scheme that
  is already supported by `WKWebView`… Setting is only allowed when the context
  is not loaded."* `uniqueIdentifier`: *"The default value is a unique value
  that matches the host in the default base URL… This value is accessible by
  the extension via `browser.runtime.id`."*

  So **an extension's `chrome.runtime.id` and its whole origin are minted anew
  on every launch of `zer0`**, where Chrome's are permanent and derived from the
  package's signing key. The expectation when this was written was that anything
  an extension — or a web page it talks to — persisted against that identity
  would be orphaned each time the browser starts, making it a candidate cause
  for sign-in flows that complete and then have nothing to come back to.
  **Measured 2026-08-11, that premise is false for `storage.local` under the
  default store, and the measurement is recorded below.**

  The answer is the id `zer0` already computes and verifies at install
  (`SHA-256(public key)[..16]`, refused when the package disagrees), under a
  scheme of our own: `zer0-extension://aeblfdkhhhdcdjpifhhbdiojplfjncoa/`. That
  is stable across launches, matches Chrome's semantics, and stops naming the
  engine in an address a person can see — which is a separate rule from
  ADR-0054's, since this is an address WebKit owns rather than one it is never
  told about.

  **Measured 2026-08-11 by `ZZExtensionIdentityProbe`, and the orphan premise
  is false for `storage.local`.** Four cases ran through subprocess isolation,
  gated by `ZER0_SHOT=1`: same scheme different UUID, same identity, migration,
  control. The migration case — `webkit-extension://<uuid>/` write →
  `zer0-extension://<id>/` read — preserved data, which is the case the orphan
  hypothesis predicted it could not. Custom schemes registered via
  `WKWebExtension.MatchPattern.registerCustomURLScheme` appear to land in a
  different bucket than the native `webkit-extension` scheme; the bucketing
  rule is not yet characterised. Harness limitation:
  `BrowserModel(storagePath: <non-nil>)` was observed to kill the background
  worker, so the measurement ran against `WKWebsiteDataStore.default()` rather
  than a per-profile store — which is the same store an extension's contexts
  already run in (see Context), so the reading is about identity and not about
  a store no other code reaches.

- **When the back/forward list should cross the boundary.** It cannot today
  because the two sides are different browsing contexts. If WebKit ever grows a
  way to carry a list across, this is the entry that changes.
- **When a pop-up from an extension's page should land in the space.** Named in
  Consequences. It supersedes part of ADR-0075 rather than extending this, since
  the rule it breaks is "the configuration is used as given".
- **If refusing extension pages in private windows costs something real.** The
  exit condition is a report of somebody needing an extension's own screen in a
  private window. The replacement is not to allow it silently — it is to say, on
  the screen, that this page is not private, which is a sentence and a design.
- **When the refusal deserves its own screen.** Two different refusals share
  ADR-0016's generic wording today.
- **When Linux is attempted.** `webkit2gtk` has no `WKWebExtension` at all
  (ADR-0020), so the arm that names an extension has nothing to resolve against
  and the port either builds one or refuses every address in this scheme.
