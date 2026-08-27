# ADR-0131: Copy Image cannot outlive its tab and its answer stays in the window that asked

- **Status:** Accepted
- **Date:** 2026-08-26
- **Lock:** `apple/Tests/Zer0ShellTests/ImageCopyTests.swift::ImageCopyTests/cancellationIsSilent`, `apple/Tests/Zer0ShellTests/ImageCopyTests.swift::ImageCopyTests/tabDestructionCancelsPublication`, `apple/Tests/Zer0ShellTests/ImageCopyTests.swift::ImageCopyTests/anInvalidAddressIsReportedThroughTheHost`, `apple/Tests/Zer0ShellTests/ImageCopyTests.swift::ImageCopyTests/cookieMatchingFollowsTheRules`, `apple/Tests/Zer0ShellTests/ImageCopyTests.swift::ImageCopyTests/redirectsCannotCarryAnIneligibleCookie`, `apple/Tests/Zer0ShellTests/ImageCopyTests.swift::ImageCopyTests/aPercentEncodedBinaryDataAddressLands`, `apple/Tests/Zer0ShellTests/ImageCopyTests.swift::ImageCopyTests/onePasteboardItemCarriesBothFormats`, `apple/Tests/Zer0ShellTests/ImageCopyNoticeTests.swift::ImageCopyNoticeTests/noticesStayInTheirOriginatingWindow`, `apple/Tests/Zer0ShellTests/ImageCopyNoticeTests.swift::ImageCopyNoticeTests/anOlderTimerLeavesANewerNoticeAlone`, `linux/shell/src/host/image_copy_tests.rs::cancellation_claims_no_tab_before_late_download_failure`, `linux/shell/src/host.rs::tab_scoped_items_take_only_the_destroyed_tabs_copies`

## Context

ADR-0130 made Copy Image a shell-owned fetch with a typed answer, but its first
implementation left two lifecycle gaps. A tab could disappear while its fetch
still held a task or WebKit download, and a result could arrive after the host
had forgotten which tab and window started it. The Apple implementation also
needed to reapply cookie policy after redirects, decode binary data URLs without
turning bytes into text, and publish clipboard formats as one atomic item.

The Linux host had the same ownership problem and reported only to stderr. That
made a successful or failed copy invisible in the browser, even though the row
had promised an answer.

## Decision

**The tab owns the copy, the destroy path cancels it, and the originating window owns its notice.**

Apple stores one cancellable task and generation per `TabId`. Linux stores one
active WebKit download and its completion state in a tab-scoped collection.
Both hosts cancel and remove those entries before removing the tab's view. The
terminal state is claimed before cancellation reaches WebKit, so a late failure
callback cannot publish a second or contradictory answer.

The Apple request rebuilds its explicit `Cookie` header for every redirect and
matches host, scheme, and percent-encoded path according to cookie rules. Binary
percent escapes in `data:` URLs are decoded into bytes directly. AppKit writes
TIFF and PNG through one `NSPasteboardItem` and one `writeObjects` call.

The host captures the originating `WindowId` at command time. Apple keeps one
replacement-and-generation timer per window; Linux uses a replacing GTK
`Revealer` notice with token-based styling and retains stderr as diagnostics.
No new core action or protocol field is introduced.

## Consequences

- Closing a tab cancels its image copy before the view is released. Apple stays
  silent after cancellation; Linux resolves the promise once as `NoTabPage`,
  while late callbacks cannot publish a second answer or clipboard bytes.
- A result cannot appear in another browser window merely because focus changed
  while the fetch was running.
- Redirects cannot carry a manually supplied cookie header to an unrelated
  host, scheme, or cookie path.
- Linux now has visible feedback, but its GTK notice still requires a rendered
  environment for visual verification.
- The shell keeps the existing shared default WebKitGTK session; per-space
  persistent storage remains outside this decision.

## How this regresses

Someone removes the tab ownership map or cancels after destroying the view. A
slow server then finishes into a dead tab, publishes bytes from a copy nobody
asked to keep, or replaces feedback in whichever window is currently focused.

Someone lets the redirect reuse its original `Cookie` header, converts a
percent-encoded payload through `String`, or writes clipboard formats in
separate operations. Private images can leak across origins, binary images stop
decoding, or a pasteboard observer can see a half-published image.

The locks above hold each person-visible failure: cancellation stays silent,
the tab-scoped collection removes only the destroyed tab's copies, redirect
cookies and binary data obey their boundaries, and each window receives only
its own answer.

## When to revisit

- If Copy Image becomes a core-visible state or gains a retry/open action, the
  outcome and lifecycle should be reconsidered as part of that new contract.
- If Linux gets per-space WebKit sessions, the copy must preserve this same
  tab-owned cancellation and add a session-identity lock without changing the
  notice contract.
- If the notice becomes interactive or persistent, replace the transient
  feedback decision rather than extending this one implicitly.
