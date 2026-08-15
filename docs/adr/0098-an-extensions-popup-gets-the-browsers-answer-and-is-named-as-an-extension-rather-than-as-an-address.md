# ADR-0098: An extension's popup gets the browser's answer, and is named as an extension rather than as an address

- **Status:** Accepted
- **Date:** 2026-08-10
- **Lock:** `crates/zer0-core/src/page_dialogs_tests.rs::an_extension_is_named_as_an_extension_rather_than_as_a_site`, `crates/zer0-core/src/page_dialogs_tests.rs::an_extension_that_calls_itself_a_paragraph_is_cut`, `crates/zer0-core/src/page_dialogs_tests.rs::an_extension_with_no_name_is_not_given_one`, `apple/Tests/Zer0ShellTests/ExtensionTests.swift::ExtensionPopupDialogTests/anExtensionPopupIsAnsweredAndNamed`, `apple/Tests/Zer0ShellTests/PageDialogTests.swift::PageDialogSourceRuleTests/theTitleNeverCarriesAnExtensionsOwnName`

## Context

ADR-0089 left one entry open, and this is it. Two things it said about an
extension's popup were measured here, and **one of them is wrong.**

### The report that started all of this was never about a popup

The defect the author reported is **"Import preferences" in Simplify Gmail does
nothing — no file picker."** Read out of the installed package rather than
guessed at: that control is not in the extension's popup. `misc/popup.html` is
six links and none of them is it. "Import preferences" is built by
`js/simplifyGmail.js`, the **content script** the manifest injects into
`https://mail.google.com/*`, and `preferences.selectImportFile` does this:

```js
const fileInput = make("input", { type: "file", accept: ".json,…", style: "display:none" });
document.body.appendChild(fileInput);
fileInput.addEventListener("change", …);
fileInput.click();
```

That is an **ordinary page's file control**, in Gmail's own document, in the
tab's own web view — reached through `SitePermissionDelegate`, which is exactly
where ADR-0089 put `runOpenPanelWith`. Driven in the real browser on a real page
over `http://127.0.0.1`, with a real click on the menu item so the user
activation a file control needs is live, the core raises:

```
ChooseFiles { multiple: false, directories: false }
```

**So the reported defect was already fixed, and this ADR is not the fix for it.**
Recorded here because ADR-0089's own "When to revisit" says the opposite, and
because two agents in a row have reasoned about that button without opening the
package it is in.

### What an extension popup actually is, measured

`WKWebExtensionAction.popupPopover` really does build its own web view and this
shell really does not set a `uiDelegate` on it. Both facts are as ADR-0089
guessed. What it guessed wrong is what that costs. Measured on the real object —
a private `_WKWebExtensionActionWebView` carrying a private
`_WKWebExtensionActionWebViewDelegate`:

| asked of the delegate WebKit installed | answer |
| --- | --- |
| `webView:runOpenPanelWithParameters:initiatedByFrame:completionHandler:` | **yes** |
| `webView:createWebViewWithConfiguration:forNavigationAction:windowFeatures:` | **yes** |
| `webViewDidClose:` | **yes** |
| `webView:runJavaScriptAlertPanelWithMessage:…` | no |
| `webView:runJavaScriptConfirmPanelWithMessage:…` | no |
| `webView:runJavaScriptTextInputPanelWithPrompt:…` | no |

And driven from inside a real popup, the same way ADR-0089 drove a real page:

| the popup calls | evaluated to | what a person saw |
| --- | --- | --- |
| `alert('x')` | returned at once | nothing at all |
| `confirm('q?')` | **`false`** | nothing, and the answer was Cancel |
| `prompt('q?', 'ada')` | **`null`** | nothing, and the answer was Cancel |
| clicking `<input type="file">` | — | **a real `NSOpenPanel`** |

**The instrument was established before any absence was believed**, as
AGENTS.md requires: the same four calls in the same process on an ordinary page
all reach the shell's delegate, so "nothing happened" here is about the popup
and not about the harness. The file picker is the control: it *does* happen, in
the same run, through WebKit's own delegate.

So an extension popup could already open a file picker. What it could not do was
say anything — and `confirm()` in a popup was being answered `false` by nobody,
which is the same silent wrong answer ADR-0089 exists to end, one delegate along.

## Decision

**An extension's popup gets this browser's answer to the three the engine does
not answer, keeps the engine's answer to everything else, and is named as an
extension rather than by an address.**

### An addition, not a substitution

`uiDelegate` is one property. Taking it for the three script panels takes away
the file picker, the link that opens a tab, and `window.close()` — and Simplify
Gmail's *own* popup calls `window.close()` in three of its menu items. A popup
that gained an `alert()` and lost its close button would be this change shipping
the defect it came to fix.

So `ExtensionPopupDialogDelegate` **keeps the delegate WebKit installed** and
forwards to it through `forwardingTarget(for:)` everything it does not implement
itself. Two facts make that safe and both were measured rather than reasoned:

- **Assigning `uiDelegate` does not deallocate WebKit's own object.** It is
  retained by the action; a weak reference to it survives the assignment.
- **WebKit does not put its own back**, not when `popupPopover` is built and not
  when `popupWebView` is read again.

Forwarding rather than a list of methods to pass on, because the list is the
part that goes stale. A method WebKit adds to that private delegate in a point
release keeps working here with nobody noticing; a hand-written list keeps
working right up until it silently does not.

`responds(to:)` is overridden with it, and that is not decoration.
**`WKWebView` asks it once, when the delegate is assigned, and caches the
answers** — a forwarding target the receiver does not admit to is a method WebKit
never calls, which is precisely how the popup would lose its file picker while
every behavioural test stayed green.

### The one door is where an action is obtained, not where a popup is shown

`ExtensionHost.action(for:tab:)` is the only place in this shell that ever gets
a `WKWebExtension.Action`, so it is where the delegate is attached. Every road to
a popup — a click on the row, ⇧⌘1..9, an extension opening its own — arrives at
`popupPopover` through an action from that method, so a popup that has not been
through it does not exist.

The alternative was the places that *show* a popup, which is the same rule at N
call sites and therefore N−1 popups asking questions nobody hears (AGENTS.md).

It is idempotent, because it runs on every draw of every button, and the
delegate is **held on the host** because `WKWebView.uiDelegate` is weak — an
unheld one is deallocated immediately and the popup goes straight back to being
answered by nobody, which looks exactly like the defect.

### Who is asking, and why the answer is not an origin

This is the part that is a decision rather than plumbing.

A popup's document does have an origin. Measured, it is
`webkit-extension://8486efcd-97b1-494d-ba20-cae7ba79e8e9/popup.html`. Drawn on
the identity line that is **worse than nothing**: it has the shape of an address,
it is not one, and no person has ever seen it before or will recognise it again.
What somebody needs to know is which extension is talking, by the name they
installed it under.

But an extension's name is a string the extension wrote about itself. A package
may call itself `google.com`. So the rule that makes a site's origin safe to draw
— *it is a fact the browser derived and nobody chose* — does not hold for a name,
and drawing the two the same way would hand every extension the browser's voice.

Three things, and the first two are structural rather than a rule somebody has to
remember:

1. **`PageDialogSource::Extension` has no field an origin fits in.** The request
   the shell sends carries either a frame's `ReportedOrigin` or an extension's
   name, never both, so there is no arrangement of this code in which a popup's
   UUID reaches a panel. `PageDialogSpeaker::Extension` is likewise not a `Site`
   with a different string in it.
2. **The name never reaches the title.** The title is the browser talking —
   "example.com is asking", our type, our weight. An extension gets
   **"An extension is asking"**, a phrase only the browser can assert, and its
   own name goes on the identity line below. `theTitleNeverCarriesAnExtensionsOwnName`
   reads the source, because no assertion can watch a string *not* being
   interpolated.
3. **The name is drawn as a quotation and never as an address.** `ExtensionName`
   leads with "An extension you installed" in the browser's voice and then draws
   the name `Text(verbatim:)` in a recessed block — `SiteWords`' treatment, for
   `SiteWords`' reason: `Text(_:)` parses markdown at runtime, so a package named
   `**Trusted**` would arrive bold. It is deliberately **not**
   `Design.Text.mono`, which is what an origin wears on this sheet and on
   `SitePermissionSheet`; a name in mono is an address to anybody reading at a
   glance, which is everybody.

The glyph changes too, and only here: the puzzle piece outranks the speech
bubble. It is the fastest read on the panel and "this is not a web page" is the
fact somebody most needs first. It is `ExtensionConsentSheet`'s glyph, so the two
panels an extension can put in front of you are visibly about the same thing.

**A package that declares no name gets no name.** Not the id, which is 32 letters
nobody recognises, and not a word the browser made up. The panel says it does not
say what it is called, which is true and is a fact about the package.
`an_extension_with_no_name_is_not_given_one` holds it in the core, where both
hosts inherit it.

**The name is cut at `EXTENSION_NAME_LIMIT`**, which is 80 and not
`MESSAGE_LIMIT`'s 2,000. A message is content and scrolls; a name sits on one
line, and a package free to write a paragraph there could push everything the
browser says off the panel. The cut is not announced the way a message's is,
because the identity line is not something anybody reads to the end.

### A panel closes the popover, and that is accepted

Measured: `beginSheet` on the window while the `.transient` popover is up closes
the popover at once, and it does not come back when the sheet ends. The popup's
web view survives, so the script that asked is still there and still gets its
answer.

Not fought, for two reasons. Making it survive means `.applicationDefined`
behaviour plus closing it by hand, which trades a popover that goes for a popover
this browser has to remember to dismiss — and a popover floating over a modal
sheet is two surfaces claiming the same attention.

**And it is what makes naming the extension load-bearing rather than nice.** With
the popover gone the panel is the only thing on screen saying where the question
came from. A panel that named the popup's UUID, or named nothing, would be a
question with no visible source at all.

### The file picker in a popup stays WebKit's

It is already implemented, it already works, and it arrives through the delegate
this change deliberately keeps. Routing it through `FilePanelPresenter` instead
would gain the panel's identity line and lose nothing visible — and it would mean
taking a working thing apart to make it look like the rest, which is a change
with a risk and no report behind it. Named in *When to revisit* rather than done.

## Consequences

**An extension popup can ask a question and be answered.** `confirm()` in one
stops being told no by nobody. This is the change that matters and, like ADR-0089's,
nobody will describe it as a feature.

**Two panels, one vocabulary.** A popup's question is a `PageDialog` like any
other: it is held against a tab, drawn on that tab's window, cancelled when the
tab goes, and subject to the same settle window. Nothing about the lifecycle is
new, which is the whole reason this is small.

**A popup's question is scoped to a tab it is not part of.** `PageDialogRequest`
is tab-shaped, and the tab a popup's question is filed under is the active one at
the moment it is asked. That is right for the window it is drawn on and it is
loose in one place: the core's "one dialog per tab" rule now means a popup and
the page under it cannot both be asking, and the second is cancelled. A cancel is
the safe direction, and it is a state nobody has reported.

**One popup test per process, and it is WebKit's limit rather than ours.**
Releasing a `BrowserModel` with a live extension popup and then building a
second one takes the process down inside WebKit — `EXC_BREAKPOINT` in
`WebProcessPool::~WebProcessPool` → `IPC::MessageReceiverMap::invalidate()`,
with nothing of ours on the stack and no output at all. So the Swift lock is one
test making four claims rather than four tests, and the reason is written where
the next person will add a fifth.

**A popup with no browser window in front is refused rather than guessed at.**
An extension may open its own popup, and there may be no active tab. The three
answer immediately with the neutral answer instead of naming a window nobody
chose.

**The popover goes when a panel arrives.** Above.

**`PageDialogRequest.origin` is now `source`.** Every existing caller is a page
and passes `.frame(origin:)`, so nothing about a page's panel changed — but it is
a shape change across the FFI and an older shell cannot send the new request.

## How this regresses

**Somebody replaces the popup's delegate instead of adding to it.** The most
likely single mistake, and it reads as a tidy-up: the forwarding is Objective-C
machinery in a Swift file and deleting it makes the class ordinary. What it costs
is invisible — a file control in a popup opens nothing, a link in one goes
nowhere, `window.close()` leaves the popover up — and every behavioural test here
stays green, because they all drive the three this object implements.
`anExtensionPopupIsAnsweredAndNamed` asks `responds(to:)` for the three that
are WebKit's, which is what a replacement cannot answer.

**Somebody drops the `responds(to:)` override** because `forwardingTarget(for:)`
looks like it should be enough. It is not: `WKWebView` caches the answers when
the delegate is assigned, so the forwarding is live and never consulted. The same
test covers it, and it is the sharper half — this one still forwards correctly to
anybody who asks, and WebKit never asks.

**Somebody puts the extension's name in the title.** It is the natural sentence —
"Simplify Gmail is asking" reads better than "An extension is asking", and for
every honest extension it is better. It is also the entire spoof: a package named
`google.com` gets our voice. `theTitleNeverCarriesAnExtensionsOwnName` scans the
body of `title` and fails on a binding of the name there, while deliberately
allowing `ExtensionName` a few lines away to bind it.

**Somebody draws the name in `Design.Text.mono`** to match the site case, because
the identity line "should look consistent". Mono is what an origin wears here and
on `SitePermissionSheet`, and a name in it is an address to a person reading at a
glance. Nothing goes red; this one is honest debt, and it is written at the top of
`ExtensionName` where a reader will look.

**Somebody gives `PageDialogSource::Extension` an origin field**, most plausibly
"so the shell can tell popups apart" or "for the tests". Then there is a choice
about which to draw and the wrong one reads as an address.
`an_extension_is_named_as_an_extension_rather_than_as_a_site` uses `google.com`
as the extension's name for exactly this — so does the Swift test, through a
real package — and both go red as `PageDialogSpeaker::Site` the moment the two
collapse.

**Somebody makes the missing name fall back to the extension id.** It looks like
filling a hole and it is 32 letters of gibberish on the line that says who is
responsible — the same shape as drawing the popup's UUID.
`an_extension_with_no_name_is_not_given_one` holds the blank.

**Somebody attaches the delegate where the popup is shown** rather than where the
action is obtained, because that is where the popover is and it reads as the
natural place. Then an extension that opens its own popup, or the ⇧⌘ chord, or
whichever path somebody forgot, is back to being answered by nobody — and only on
that path, which is how it survives review.

**Somebody adopts twice and stacks a delegate on a delegate.** Each round adds a
layer of forwarding and the popup grows a chain as long as the number of times
its button was drawn. The same test asks for the action twice and asserts the
delegate is the same object afterwards.

## When to revisit

- **If a popup's file picker should carry the panel's identity line.** It is
  WebKit's `NSOpenPanel` today, with no message on it, so nothing names the
  extension that is about to read a file off this Mac —
  `FilePanelPresenter.message(for:)` already has the wording and is unreachable
  from a popup. That means unhooking a working picker to route it through ours,
  which is a risk taken for a line of text, and it should be a measurement about
  whether the missing line matters rather than a tidy-up.
- **If a popup's question should be its own thing rather than a tab's.**
  `PageDialogRequest` carries a `TabId` and a popup is not a tab. Today that is
  right for the window and loose for the "one per tab" rule; a browser where
  popups ask often enough for that to bite wants a window-scoped request, and it
  supersedes part of ADR-0089 rather than extending this.
- **If the popover should survive a panel.** `.applicationDefined` and closing it
  by hand is the shape. It buys the popup staying on screen behind its own
  question and costs a popover this browser has to remember to dismiss.
- **When `webViewDidClose:` on a popup should be ours.** It is WebKit's and it
  closes the popover, which is right. The day this browser wants to know that a
  popup closed itself — to move focus, or to report it — that is a method to
  implement rather than forward, and the forwarding makes taking one back cheap.
- **When a Linux host is attempted.** `PageDialogSource` and every rule about
  what may be drawn port unchanged. `WKWebExtensionAction` does not, and neither
  does forwarding to a delegate the engine installed: `webkit2gtk` has no
  equivalent of an engine-built popup web view, so the host will have to build
  and own that view itself.
