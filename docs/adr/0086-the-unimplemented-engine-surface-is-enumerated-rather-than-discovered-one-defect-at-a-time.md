# ADR-0086: The unimplemented engine surface is enumerated rather than discovered one defect at a time

- **Status:** Accepted
- **Date:** 2026-08-10
- **Lock:** none — debt

## Context

Six defects reached the author the same way: he did an ordinary thing, nothing
happened, and there was no error. `window.open`, `target="_blank"`,
`<input type="file">`, `alert()`, `confirm()`, `prompt()`. Every one of them was
an optional WebKit delegate method nobody had written.

That shape is worth naming, because it is not a bug class — it is a *reporting*
class. Every protocol method in `WKUIDelegate`, `WKNavigationDelegate` and
`WKDownloadDelegate` is `@optional`, and WebKit's answer to an unimplemented
optional is a documented default chosen for an embedded web view inside somebody
else's app. For a browser those defaults are frequently the worst available
answer, and none of them raises, logs or returns an error. The absence is
invisible from inside the code: `grep` finds nothing, the suite is green, and
`./scripts/check.sh` cannot go red over a method that was never written.

ADR-0074 already made this argument for `WKWebViewConfiguration` and answered it
by writing down every setting, including the ones that agree with the default.
The delegates were never given the same treatment. Finding the seventh defect by
being bitten by it is what this record exists to stop.

## Decision

**The unimplemented engine surface is enumerated in one place, measured rather
than reasoned about, and each entry carries what a person would say broke, how
often they would hit it, and what it costs to fix.**

The enumeration was taken from the installed macOS 26.5 SDK headers, not from
memory, and the behaviour of each gap was measured by driving a real `WKWebView`
with exactly the delegate set the shell implements. Where a claim rests on
pixels, the instrument was shown photographing the thing before it was trusted
to report its absence — `cacheDisplay` was made to count 43,715 dark pixels on a
live page before it was allowed to report 0 on a crashed one.

Three findings change what we believed:

**A page that crashes leaves a tab that cannot be recovered by anything the
browser currently does.** `webViewWebContentProcessDidTerminate` is not
implemented, so there is no notification. Measured, after the web content
process dies: the view goes blank and `url` becomes `nil`. Left alone, the tab
is still blank eight seconds later.

**Corrected in place, 2026-08-10.** This paragraph went on to say that
`reload()` returns `nil` and produces no navigation, that an explicit `load()`
had still not committed after eight seconds, and therefore that *"recovery is a
replacement, not a reload"*. **That is wrong.** Re-measured with the web content
process killed by `SIGKILL` and the terminate callback watched rather than
assumed, `reload()` returns a `WKNavigation`, commits, finishes and comes back
with a fresh web process in under 50ms — from inside the callback, a run loop
later, and three seconds later, in a window and out of one. The likely cause of
the original reading is the instrument: `_killWebContentProcess`, the obvious
way to stage a crash, was measured doing nothing at all, leaving a live process
with its pid unchanged and no callback fired.

The correction is called out here rather than silently swapped because somebody
acting on the old sentence would have *decided differently* — they would have
built a view-replacement path nobody needs. ADR-0096 is the decision that
replaced this entry, and it carries the full measurement.

**Clicking a `mailto:` link destroys the page the person was reading.** The one
navigation-policy door answers `.allow` for every scheme it does not recognise;
WebKit then fails the provisional navigation with `NSURLErrorUnsupportedURL`,
which `HostedWebView.kind(of:)` maps to `.unsupportedUrl`. That is not
`.cancelled`, so the reducer sets `last_error`, clears the tint, and ADR-0016
gives the failure the whole screen. The same holds for `tel:`, App Store links,
and every application scheme a page can carry. Nothing is handed to
LaunchServices anywhere in the shell.

**A site behind HTTP Basic auth renders the server's raw 401 body.** With
`didReceive challenge:` unimplemented WebKit answers
`NSURLSessionAuthChallengeRejectProtectionSpace`, which the header documents. It
does not fail the load — measured, the response is committed and finished with
status 401, so the person reads whatever bytes the server sent with its refusal.
An untrusted certificate fails cleanly instead, with `-1202` reaching the error
screen as `.certificateInvalid`; that one *is* explained, and simply has no way
through.

**Added 2026-08-10, and it is not a `WKWebView` delegate at all.** An extension
opening one of its own pages gets a web search. The route is
`chrome.tabs.create` -> `openNewTabUsing:` -> `Action::OpenTab`, and it is
broken twice over, independently:

- `url_input::resolve` passes through five schemes — `http`, `https`, `file`,
  `about`, `data` — and `webkit-extension://` is none of them, is not
  `internal_url::claims_scheme`, and is not host-shaped. Measured, it comes back
  `Search("https://duckduckgo.com/?q=webkit-extension%3A%2F%2F…")`: the address
  of a page inside an extension is sent to a search engine, which is the failure
  ADR-0054's `is_ours` check exists to prevent for *our* addresses.
- Even carried intact it would be cancelled. `WKWebExtensionContext.h`:
  *"navigations will be canceled if a web view not configured with this
  configuration attempts to navigate to a URL that does originate from this
  extension's base URL"*, and *"the app must also swap web views in tabs when
  navigating to and from web extension URLs."* `EngineHost` builds every tab's
  view from a plain `WKWebViewConfiguration()`, never from
  `WKWebExtensionContext.webViewConfiguration`.

Measured, one run, same URL, same instant: in the ordinary page configuration
the view is left at `about:blank`; in `context.webViewConfiguration` it loads
and reports `title = 1Password`. The popup is unaffected and works, because
WebKit builds `action.popupWebView` itself.

What it costs: every extension's options page and every onboarding page it
opens for itself. 1Password is the worked example — refused a native host, it
opens `app/app.html#/page/migration`, and in this browser that becomes a search
result. Nothing anywhere says so. This entry is a defect and not a decision;
whoever fixes it inherits the second sentence of that header quotation, which is
a tab that changes its web view mid-life.

Some of the surface is absent for reasons that are not defects and must not be
re-litigated as ones. `WKURLSchemeHandler` is unimplemented because ADR-0054
decided WebKit is never told `zer0://` exists. Geolocation, notifications,
display capture and clipboard read have no delegate anywhere in the public
headers, as ADR-0056 established. Text-encoding override needs SPI that
`SourceRuleTests` forbids. Those are recorded as answered, not as owed.

## Consequences

The list is a work queue and it is ordered by what an ordinary week costs, not
by how interesting the code is. Its top is cheap: a scheme check at the one door
that already exists in `HostedWebView`, plus `NSWorkspace.open`, removes the
worst daily papercut in the browser for a few lines.

It also makes a claim we could not previously make: what is *not* broken. The
default context menu is rich and works — measured, a link offers Open Link, Open
Link in New Window, Download Linked File and Copy Link; a video offers Enter
Full Screen and Enter Picture in Picture; a text field offers real spelling
corrections; and Inspect Element is present because
`WebInspector.allowInspection` sets `developerExtrasEnabled`. ADR-0067 says the
contents of that menu could not be read short of a person right-clicking. That
was true of `menu(for:)`, which returns `nil`; it is not true of
`willOpenMenu(_:with:)` on a `WKWebView` subclass, which hands over the whole
menu. **Corrected here rather than in ADR-0067, which decided nothing on the
strength of it.**

What that measurement also shows is the menu's two lies: it offers no *tab* at
all, only "Open Link in New Window", and it offers "Search with Google"
regardless of which engine this browser is set to use.

The cost of the enumeration is that it dates. It was taken against one SDK on
one machine, and a WebKit that ships a new optional will not announce itself
here.

## How this regresses

Somebody implements one of these delegates, the compiler is satisfied, the suite
is green, and the person still gets nothing — because the method was written
against what the documentation implies rather than what WebKit does. The crash
handler that calls `reload()` is the worked example: it reads as a complete fix,
it reviews as a complete fix, and the tab stays blank.

The second regression is quieter. This record is prose with no test behind it,
so nothing goes red when an entry stops being true. Somebody reads "Basic auth
shows the raw 401 body", finds it fixed, and reasonably concludes the rest of
the list was fixed too.

## When to revisit

When any entry is implemented, it leaves this list and takes its own ADR with
its own lock — a survey must not be the record that a thing works.

Re-run the enumeration against the SDK whenever the deployment target moves, and
whenever a `WKWebView` is built anywhere but `HostedWebView.init`, since the
one-door assumption underneath every measurement here is what makes a single
answer true for every page.

Revisit the whole approach if a second host appears: the gaps are WebKit's, the
ranking is a person's week, and a Linux host inherits the second and not the
first.
