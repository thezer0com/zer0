# ADR-0132: A field that has lost the keyboard takes it back on the next sync

- **Status:** Accepted
- **Date:** 2026-09-01
- **Lock:** `apple/Tests/Zer0ShellTests/CommandBarFocusTests.swift::CommandBarFocusTests/focusReturnsAfterItIsLost`, `apple/Tests/Zer0ShellTests/CommandBarFocusTests.swift::CommandBarFocusTests/focusIsTakenOnce`

## Context

The find bar stays open while the person reads what it found — that is its
point, it covers a corner and not the page. So this sequence is ordinary:
⌘F, type, click into the page to scroll past a match, ⌘F again to refine.
In every browser the person has used, the second ⌘F puts the cursor back in
the field. In zer0 it did nothing visible: SwiftUI's update reached
`CommandBarField.sync`, and ADR-0013's guard — `hasTakenFocus`, set once,
never reset — returned without acting. The person starts typing, and the
first characters land on the page underneath or nowhere at all. ADR-0013
already documented how that failure goes unreported: nobody files "focus is
not in the field", they just find the browser slower.

The command bar has the same hole through ⌘L pressed twice.

## Decision

`sync`'s guard becomes a question about the present, not a memory of the
past:

- **The field already owns the keyboard** (`hasTakenFocus` and its borrowed
  editor is the window's first responder) — an ordinary redraw while the
  person types. Return. Taking again would redo select-all and the next
  keystroke would wipe the word, the "it deletes what I am typing" failure
  ADR-0013 guards against.
- **Anything else** — the first pass, or any sync after the web view or
  another control has taken the keyboard — arm `takeFocus`, exactly as the
  opening always did. A reopened bar comes back to the field.

The latch survives, and for a reason that is not sentiment: in a fresh
window AppKit's key-view lending can hand the field an editor **before any
sync runs**, with a bare caret. The opening take still has to fire, because
focus without the selection is halfway (ADR-0013). The latch is what
distinguishes "first sync, select everything" from "redraw mid-typing,
touch nothing" when both look like *field owns focus*. Collapsing the guard
to ownership alone breaks the opening contract; collapsing it to the latch
alone re-breaks the reopen.

`ownsFocus` compares the window's first responder against `currentEditor()`
because of the shared field editor: while editing, the responder is that
`NSTextView`, never the field itself.

## Consequences

**What hurts:**

- **The loaded gun now fires per sync, not once.** Any redraw while focus
  deliberately sits elsewhere — the checkbox on a `prompt()` sheet, a page
  the person scrolled — pulls the keyboard back to the field. Accepted on
  ADR-0013's premise: while the bar is open, the field is where typing
  goes. If a use ever appears where another control in the same panel must
  keep the keyboard, that use needs its own decision, not a quiet revert.
- **The tests got harder to keep honest, and that is AppKit's doing.** Two
  measured facts about the harness: `makeKeyAndOrderFront` lends the field
  an editor (it is the only key-view candidate) and selects all a turn
  later, on its own; and the main queue services `DispatchQueue.main.async`
  blocks several turns after they are queued — long enough for an opening
  take to land after a later steal and hand focus back with nothing
  implemented, which is why the first version of the reclaim test passed
  against the broken code. The tests now arm the opening take against a
  scratch field that never reaches a window (`takeFocus` refuses a field
  without one), and drain the queue with a FIFO marker before judging a
  selection. Both tricks are commented where they live; removing either
  reinstates a test that lies.
- **Instruments lie in both directions here.** The same `cacheDisplay`
  caveat as ADR-0013's timing note: the harness's window behaves like the
  app's only until it doesn't, and every focus test opens a real window for
  exactly that reason.

**What we get:**

- ⌘F and ⌘L are idempotent in the way fingers expect: press them again and
  you are typing in the bar again.
- The once-only invariant that matters — nothing touches the selection
  while the person types — is now asserted (a caret survives a sync) rather
  than assumed.

## How this regresses

- **"It deletes what I am typing."** Someone simplifies the guard to
  ownership alone or removes it: every redraw redoes select-all.
  `focusIsTakenOnce` goes red — it narrows the selection to a caret, syncs,
  and requires the caret to have survived every take the redraw could have
  armed.
- **"⌘F again does nothing."** Someone restores the pure latch, reading
  ADR-0013's "once only" as the whole rule: `focusReturnsAfterItIsLost`
  goes red — it steals focus to another control, syncs, and requires the
  field to take it back.
- Both locks have been watched red against exactly those two broken
  implementations; the guard is the only version under which both are green.

## When to revisit

- If SwiftUI's `@FocusState` starts beating `WKWebView` reliably, this file
  follows ADR-0013 out the door.
- If a panel appears where the field must share its window with another
  control that keeps the keyboard, the per-sync reclaim needs a signal
  from the caller rather than an inference from ownership.
