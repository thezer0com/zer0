# ADR-0013: Focus lands where the person is about to type, and the text comes selected

- **Status:** Accepted
- **Date:** 2026-02-12
- **Lock:** `apple/Tests/Zer0ShellTests/CommandBarFocusTests.swift::CommandBarFocusTests/fieldTakesFocus`

## Context

The person presses ⌘L. They pressed ⌘L because they are going to **type**. If the
field opens and the cursor is not in it, they have to reach for the mouse to click
a field that just appeared, on its own, in the middle of the screen, because of
something they did. That is not an inconvenience: it is the interface
contradicting their own intent.

And there is the second half. ⌘L opens the bar **with the current URL inside**
(ADR-0015). If the text does not come selected, typing appends to what is already
there. The person wanted to go somewhere else and ended up with
`https://avelino.run/github.com`. Every address bar in the world selects
everything on focus; not doing it is surprising people by omission.

The obstacle is technical and specific to WebKit: **SwiftUI's `@FocusState` loses
this fight.** The `WKWebView` underneath is already first responder, and asking
politely in `onAppear` does not take that away from it. The comment in the file is
blunt:

> A text field you have to click into first is not a text field, it is a chore.

## Decision

`CommandBarField` (`apple/Sources/Zer0Shell/CommandBarField.swift`) is an
`NSViewRepresentable` over `NSTextField`. It drops down to AppKit and **takes**
first responder instead of asking for it:

```swift
static func takeFocus(of field: NSTextField) {
    guard let window = field.window else { return }
    window.makeFirstResponder(field)
    field.currentEditor()?.selectAll(nil)
}
```

Three details that are the decision, not the implementation:

1. **One run loop cycle of delay.** The take happens inside
   `DispatchQueue.main.async`. At `sync` time the view is already in a window but
   still cannot become first responder. Without the deferral, `makeFirstResponder`
   returns and nothing happens.
2. **Once only.** `coordinator.hasTakenFocus` is the guard. Without it, every
   redraw would steal focus back — and the symptom would be the text selection
   being restored while the person types.
3. **`selectAll` together with focus, not after.** Focus without selection is
   halfway: it fixes the click and keeps the concatenation.

**AppKit lives in `buildField` and `sync`, not in the protocol methods.** That is
deliberate and commented: `Context` cannot be constructed in a test, and focus
behavior is exactly the kind of thing that needs one. The shape of the code was
chosen to be testable.

The component is reused wherever the same reasoning holds: command bar (20pt),
find bar (13pt) and the rename-space popover in `Sidebar` — that last one with the
comment "a rename that needs a click into the field and a ⌘A before you can type is
not a rename, it is paperwork".

Along with focus, the `Coordinator` intercepts the keys that make the bar operable
without a mouse: Enter confirms, Esc closes, ↑/↓ walk the list. `moveLeft` falls
through to `default` and returns `false`, because the left arrow belongs to the
text, not to the list.

## Consequences

**What hurts:**

- **We left SwiftUI and there is no cheap way back.** `CommandBarField` is pure
  AppKit. It inherits no styling, no `.focused`, no `@FocusState`, and no SwiftUI
  field accessibility for free. Every bit of styling is reassembled by hand
  (`isBordered = false`, `drawsBackground = false`, `focusRingType = .none`).
- **It is macOS. Only macOS.** This file does not cross to Linux. It is
  `NSTextField`, `NSResponder`, `currentEditor()`. The Linux shell will rediscover
  the problem from scratch, and the only shared thing will be this document.
- **It depends on run loop timing.** A `DispatchQueue.main.async` is a bet that one
  cycle is enough. It is enough today. A change in SwiftUI's window lifecycle could
  turn this into "sometimes the field does not take focus", which is the most
  expensive category of bug to reproduce there is.
- **The test is slow and fragile by nature.** `CommandBarFocusTests` opens a real
  `NSWindow` and sleeps 200ms. It needs a graphical session: it does not run in
  headless CI without care. That is the price of testing real focus instead of
  testing an abstraction of focus.
- **Stealing first responder is a loaded gun.** The `hasTakenFocus` guard is the
  only thing between this and a bar that never lets anything else be focused. A
  `Coordinator` recreated on a view identity change resets the guard.
- **Intercepting the arrows costs text navigation.** ↑/↓ do not move the cursor
  inside the field. In a single-line field that is acceptable — and that is why
  ←/→ were explicitly left out.

**What we get:**

- It opens, you type. No click, no ⌘A, no thinking.
- Focus became tested behavior, not a promise in code review.
- One component solves the problem in three different places.

## How this regresses

It regresses in the most invisible way of the whole set. **Nobody files a bug
saying "focus is not in the field anymore".** The person presses ⌘L, starts
typing, nothing shows up, they click the field and type again. That becomes a habit
in two days. They never report it. They just find the browser slower and cannot say
why.

What the person would notice:

- **"I have to click before typing."** The first character is lost — or worse, it
  becomes a shortcut on the page underneath, because the `WKWebView` is still first
  responder. Pressing ⌘L and having the following `f` open the page's own find is a
  real symptom of that failure mode.
- **"It keeps merging with the old address."** `selectAll` is gone. The person
  types `github.com` and lands on `https://avelino.run/github.com`. They will blame
  the URL, not the focus. And ADR-0015 (⌘L seeding the bar with the current URL)
  becomes a hated feature instead of a convenience.
- **"It deletes what I am typing."** The `hasTakenFocus` guard is gone, and every
  redraw redoes `selectAll`. The person types three letters, SwiftUI redraws, the
  three letters end up selected, the fourth letter wipes the others. It looks like
  data corruption, it is focus.
- **"Esc does not close anymore" / "Enter does nothing".** Somebody touches the
  `switch` in `doCommandBy` and a `return true`/`false` flips. The bar starts
  existing with no keyboard exit, and the person has to click outside.
- **"The arrows do not walk the list."** The suggestions (ADR-0015) are ranked
  perfectly and unreachable without a mouse.
- **Renaming a space became paperwork again.** The popover in `Sidebar` uses the
  same component. It regresses along with it, without anyone thinking about the
  sidebar.

**The locks:**

- `the field takes first responder without anyone clicking it` — mounts the field
  in a real `NSWindow` and checks `currentEditor() != nil` and
  `window.firstResponder is NSTextView`. The failure message is the decision
  written out: *"nothing took focus, so the user would have to click first"*.
- `the existing text comes selected, so typing replaces it` — the **second half**,
  just as loaded: `editor.selectedRange.length == url.utf16.count`, with the message
  *"the whole URL must be selected, or typing appends to it"*. Without it, ⌘L turns
  into concatenation.
- `focus is taken once, not stolen back on every redraw` — covers the guard.
- `escape cancels and enter submits` and
  `arrow keys move the highlight, but only up and down` — cover keyboard operation,
  including the assertion that ← is **not** intercepted (*"left arrow belongs to the
  text, not to the list"*).

## When to revisit

- If SwiftUI's `@FocusState` starts beating `WKWebView` reliably. Then this whole
  file goes away and we get styling, accessibility and Linux back. That is the
  desired ending.
- When there is a Linux shell. The problem will reappear under another name
  (GTK/Qt/wgpu) and this ADR is the statement of it, not the solution.
- If the field becomes multi-line in some use. Then intercepting ↑/↓ stops being
  acceptable and the decision needs context.
- If `CommandBarFocusTests` becomes flaky in CI. The answer is not deleting the
  test: it is understanding what changed in the timing, because flakiness in the
  test is flakiness in the product.
