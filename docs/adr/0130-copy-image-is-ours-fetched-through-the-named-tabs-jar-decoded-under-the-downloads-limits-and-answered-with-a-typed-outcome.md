# ADR-0130: Copy Image is ours — fetched through the named tab's jar, decoded under the download's limits, and answered with a typed outcome

- **Status:** Superseded by ADR-0131
- **Date:** 2026-08-26
- **Lock:** `apple/Tests/Zer0ShellTests/ImageCopyTests.swift::ImageCopyTests/anAuthenticatedImageLands`, `apple/Tests/Zer0ShellTests/ImageCopyTests.swift::ImageCopyTests/aCopyThatLandsSaysSo`, `apple/Tests/Zer0ShellTests/ImageCopyTests.swift::ImageCopyTests/aRefusalNamesItsReason`, `apple/Tests/Zer0ShellTests/ImageCopyNoticeTests.swift::ImageCopyNoticeTests/anOlderTimerLeavesANewerNoticeAlone`, `apple/Tests/Zer0ShellTests/ImageCopyNoticeTests.swift::ImageCopyNoticeTests/theNoticeRetreatsOnItsOwn`

## Context

ADR-0091 left "Copy Image" as the engine's row and said so in as many words:
a row of our own "would have to fetch the bytes through the space's cookie
jar and put decoded image data on the pasteboard, which is a second download
machine — and ADR-0027 says there is one." Its revisit clause named the day
that would change: when the fetch is ADR-0027's machinery *pointed somewhere
new*, not a wider version of that decision.

That is what this is. The row existed, the fetch existed, and the failure
mode was the one ADR-0011 calls the worst there is: a menu item that
promises something and then, when the site refuses or the bytes are not a
picture, changes nothing anyone can see. Silence after a promise.

## Decision

**The copy is ours, end to end, and it answers.**

### The fetch is ADR-0027's, pointed at the pasteboard

`ImageCopy` rides the tab the command named — the same jar a download rides,
read off that view's configuration and no other's — over an ephemeral
`URLSession` that refuses to carry any identity of its own: no cookie
storage, no credential storage, no cache, the jar's matching cookies folded
into one explicit `Cookie` header (RFC 6265 applied by hand, because
`HTTPCookie` exposes no matching). Two floors, both from the download's own
argument that nothing a person asked for is worth unbounded memory for:
32 MiB on the wire, refused from the declared length before a byte is read
and again per byte as the body streams; 80 million decoded pixels. Only a
2xx is an image — a sign-in page's bytes are not a picture whatever the menu
said — and the clipboard is written only after a real decode answered.

### The answer is a closed, typed outcome — not a new core action

`ImageCopy.Outcome` is `.copied` or `.failed(...)` with six reasons:
`invalidAddress`, `noTabPage`, `notAnImage`, `tooLarge`, `unreachable`,
`clipboard`. Categories, deliberately: the interface may say what *kind* of
thing went wrong and never what a server or a socket said on the way
through (ADR-0018, pointed at a failure nobody could otherwise name).
`.copied` is claimed only after the pasteboard write answered, so success
said with nothing on the clipboard is not expressible.

The outcome is **not** an `Action`. Nothing about the browser moved — the
core decides behaviour, and bytes on a pasteboard are none — so the host
forwards it to `BrowserModel` through one closure, the model turns it into a
transient observable notice, and the core stays untouched. The tab being
gone is a failure said out loud (`.noTabPage`) rather than a silent drop,
because the row had already promised something.

### The notice is the shell's, and it leaves on its own

`BrowserModel.imageCopyNotice` replaces whatever came before it — the newest
outcome is the one being waited on — and retreats after
`Design.Duration.linger`. The timer carries the notice's id and may clear
only that notice, so an older copy's late timer cannot blink a newer one's
feedback off; the id comparison is the guarantee, the cancellation is the
optimisation. `DownloadsView` refuses to let a *failure* leave by itself;
this one is allowed to because it carries no action — the thing to do about
a copy that did not land is to choose the row again, which no notice was
holding open. The strip is drawn in the find bar's language for a status
claim (a secondary-coloured check for success, the warning tier's colour for
a refusal) and is announced to assistive technology on arrival, since a
notice that leaves by itself is one a screen reader otherwise never meets.

### Both hosts compile it, one pipeline

The fetch, the limits and the decode are shared; only the clipboard is the
platform's — `NSPasteboard` with TIFF and PNG on the Mac, `UIPasteboard`
with a `UIImage` on the phone — and neither SDK's types cross their `#if`.
`ImageCopy` joined the shared set `typecheck-ios.sh` holds in the same
commit, per that gate's own rule. The iOS arm of the command executes
rather than `break`-ing: the gesture that reaches it is still macOS's
context menu (ADR-0091 stands on that), and a future iOS surface inherits
an executor that already answers.

## Consequences

- `ImageCopy` is in the iOS shared set, so a change that leans on AppKit
  from the shared pipeline fails `typecheck-ios.sh` rather than shipping
  until someone notices.
- The old contract's doc — "no report back, because nothing is claimed" —
  is gone. Every caller now owes an answer, and the report arrives exactly
  once, on the main actor, after the clipboard write answered.
- A notice per outcome means two quick copies show one notice: the second.
  That is the decision, not an accident — a queue of copy confirmations is
  furniture.

## How this regresses

**Somebody makes the fetch anonymous** — shared store, or the active tab's
jar instead of the named one — and private images copy as nobody. Reads as
a simplification of "why does a copy need a *tab*?". `anAuthenticatedImageLands`
and `anUnauthenticatedCopyLandsNothing` are the fence: the same request
must land through the jar and be refused without it.

**Somebody lets success be claimed before the write** — reporting on
dispatch, or dropping the `setData` answer — and "Image copied" becomes a
hope. `aCopyThatLandsSaysSo` holds the claim to the bytes, and
`aRefusalNamesItsReason` catches an inverted one immediately: a refusal path
reporting `.copied` is red on the first expectation.

**Somebody replaces the id compare with a bare clear** — "the cancellation
already handles the old timer" — and a copy made in the second half of
`linger` has its feedback blinked off by the first one's timer. Broken on
purpose (`|| true` in the guard), `anOlderTimerLeavesANewerNoticeAlone`
went red on both expectations; the cancellation alone is exactly the
optimisation that reads as sufficient.

**Somebody makes the notice permanent, or clears it without a timer at all**
— the first because feedback feels safer kept, the second because a
`DispatchQueue.asyncAfter` looks simpler. The first turns news into
furniture, the second races the model's lifetime.
`theNoticeRetreatsOnItsOwn` pays `linger`'s five seconds to hold the first;
the id-carrying `Task` and the weak self are what hold the second, and the
guard test above is the one that notices them being "simplified".

## When to revisit

- **When the notice should offer something** — a retry, an "open image in a
  new tab" — it stops being a notice that may leave by itself, and the
  `DownloadsView` rule it is excepted from becomes the rule it follows.
- **When iOS grows its context menu**, the executor is ready and only the
  gesture is new; if that surface wants a different notice shape, the
  outcome and the model state are shared and the drawing is the host's.
- **If the core ever needs to know about copies** (a "recently copied"
  surface, a policy on image origins), the outcome becomes an `Action` and
  this decision is superseded, not widened.
