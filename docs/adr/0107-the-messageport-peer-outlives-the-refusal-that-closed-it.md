# ADR-0107: The MessagePort peer outlives the refusal that closed it — declared debt on a cosmetic bug the worker cannot read

- **Status:** Accepted, debt
- **Date:** 2026-08-11
- **Lock:** none — debt
- **Debt note:** the test that would defend this — `aRefusalFramesAReasonTheWorkerCanRead` in `apple/Tests/Zer0ShellTests/NativeMessagingTests.swift`, exercising `NativeMessagingHost.gate` — does not exist yet. This record names the bug it would defend, so the next time `gate` is touched the question of whether the reason still arrives is on this page rather than in nobody's memory.

## Context

ADR-0105 built the host and ADR-0106 made the extension ask for it. The path
from `chrome.runtime.connectNative` to a real `Process` is closed end to end,
including the part where the core says no: `native_messaging::outcome` returns
`.refused(extension_id, sentence)`, `NativeMessagingHost.gate` calls
`refuse(sentence)`, and the `opened` closure in
`ExtensionHost.webExtensionController(_:connectUsing:for:completionHandler:)`
runs `completionHandler(failure.map(NativeMessagingRefusal.said))`. By the type
in `ExtensionHost.swift:992`, `NativeMessagingRefusal.said(String)` is a
`LocalizedError` carrying that sentence. WebKit turns the error into the
`disconnectHandler` event the extension's worker reads on
`chrome.runtime.Port`.

That is the path **for the message**. There is a second path, for the **port**,
and on a refusal the two arrive apart.

`ExtensionHost.webExtensionController(_:connectUsing:for:completionHandler:)`
constructs the peer inline:

```swift
native.connect(
    extensionId: extensionId,
    applicationId: applicationId,
    peer: MessagePortPeer(port: port)
) { failure in
    completionHandler(failure.map(NativeMessagingRefusal.said))
}
```

`NativeMessagingHost.connect` builds a `Waiting` struct inside the `waitingFor`
closure it passes to `gate`, and that struct is what retains the peer for the
host's lifetime of a conversation:

```swift
func connect(...) {
    gate(extensionId: ..., applicationId: ..., refuse: opened) { host in
        Waiting(host: host, peer: peer, opened: opened, ...)
    }
}
```

`gate` only calls `waitingFor(host)` in the `.start` and `.ask` branches. The
`.refused` branch never builds the `Waiting`, never stores the peer in
`waiting[key]` or `connections[id]`, and returns. Nothing else retains the
`MessagePortPeer` after `connect` returns — the inline construction has no
strong reference outside the call frame, and the closure that captured it was
allocated only to be passed to `gate` and is released when `gate` returns.

So by the time WebKit services the `completionHandler(NativeMessagingRefusal.said(...))`
call, the `WKWebExtension.MessagePort` it holds inside `MessagePortPeer.port`
has been released by this browser. The port is still closed — the
`disconnectHandler` still fires — but `NativeMessagingRefusal.said(reason)`
was the reason carried by the *completion* of `connectNative`, not by the
lifetime end of the `MessagePort` itself. With the peer gone, WebKit reports
the disconnect as `Error: None` rather than the sentence the core framed.

Observed, on the path ADR-0106 unlocked: 1Password's worker prints
`onDisconnect: Error: None` in place of
`"This extension was not allowed to talk to programs on this Mac."` — the very
sentence `host_tests.rs::a_registration_that_lists_somebody_else_refuses_this_extension`
proved the core frames. The sentence is right; it just does not arrive.

## Decision

**This is declared debt, not fixed here.** Three reasons:

1. **Nothing functional is broken.** The port closes. The worker sees the
   close. The conversation does not leak, the program does not start, and no
   permission is granted that should not be. The bug is that the worker cannot
   read *why* it closed, which is a UX cost paid by an extension developer
   debugging `connectNative`, not by a person using the browser.

2. **The fix is one local, and one local is a shape we have refused before.**
   The minimal repair is to hold the `MessagePortPeer` in a `let` inside
   `webExtensionController(_:connectUsing:for:completionHandler:)` whose
   closure captures it, so ARC keeps the peer alive past the return from
   `connect` until WebKit calls `completionHandler`. That is the same shape as
   "extend a lifetime with an extra strong reference" — the shape ADR-0105's
   `Connection` and `Waiting` types exist to make structural rather than
   ad-hoc. The honest fix is to make the peer's lifetime *part of* the
   `gate`'s refusal branch, not bolted on at the call site, and that is more
   than this ADR is for.

3. **No extension on this browser today shows the sentence to a person.**
   1Password's popup reports `desktopAppState: Disconnected / PortClosed` and
   does not surface the disconnect reason at all. The sentence the worker
   cannot read is a sentence the worker would not show. That makes the cost of
   this bug "one paragraph in a future bug report" rather than "a person sees
   the wrong thing", and the same paragraph in this ADR is cheaper than the
   fix.

## Consequences

**What hurts:**

- **An extension debugging `connectNative` against this browser sees
  `Error: None` and has to read this ADR to learn why.** The error string the
  core's `host_tests` proved is the right one never reaches the only surface
  that could display it. The cost is paid entirely by whoever writes the next
  extension that uses native messaging, and only when that extension is
  refused.
- **The refusal path is the path that has no integration test of its own.**
  `NativeMessagingTests.swift` proves the *host* refuses; nothing proves the
  *peer* survives to carry that refusal to WebKit. The gap is the same shape
  AGENTS.md warns about: a lock pointing at the test that should defend the
  decision, with no test there yet.
- **A future change to `gate` could widen this bug from cosmetic to
  functional.** If the refusal branch ever needs the peer for anything other
  than carrying the reason — say, to send a final message before closing —
  releasing it before `completionHandler` runs will be a real bug, not a
  cosmetic one.

**What we keep:**

- The refusal still refuses. The port still closes. The program still does
  not start. The permission model ADR-0105 defended is intact; only the
  readability of one error string is not.

## How this regresses

**"The refusal stopped refusing."** The tempting path: somebody reads this
ADR, sees that the peer is released too early, and "fixes" it by retaining the
peer permanently inside `NativeMessagingHost` for every conversation — including
the refusals — to avoid having to think about lifetimes. That leaks: a peer
held past its disconnect is a peer whose `WKWebExtension.MessagePort` outlives
the extension that owns it, and the host's `connections` table is the only
place that should ever hold one. The fix the next ADR would make is the local
one named above, not a permanent one.

**"The error string changed and nobody noticed."** `NativeMessagingRefusal.said`
is a `LocalizedError` whose `errorDescription` is the sentence the core framed.
If somebody tidies that to a shorter string for the popup's benefit, the
worker reads a different sentence than `host_tests.rs` framed, and the only
test that would catch it is the one this ADR declines to write.

**"A second extension needed the reason and we still had not written the
test."** The revisit condition below, arriving. The honest move then is to
write `aRefusalFramesAReasonTheWorkerCanRead`, watch it go red, and fix the
peer's lifetime — in that order — rather than fix the lifetime and then write
a test that proves the fix.

## When to revisit

- **When any extension other than 1Password uses `connectNative` and surfaces
  the disconnect reason to anybody.** The cost of this bug moves from
  "paragraph in a bug report" to "a person sees the wrong thing", and the
  local fix is worth its weight.
- **When `NativeMessagingHost.gate` is rewritten for any other reason.** The
  refusal branch's lifetime rule is a paragraph of thinking that should be
  revisited while the file is open, and the test that defends it is cheap to
  write at that moment and expensive to write cold.
- **When WebKit ships a `WKWebExtension.MessagePort` whose disconnect reason
  is settable independent of the peer's lifetime.** The bug becomes
  unreachable by construction, and this ADR retires the same way ADR-0104
  will retire if WebKit ships a per-context User-Agent.
