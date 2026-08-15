# ADR-0053: A command crosses into another window only when its effect is visible there

- **Status:** Accepted — its single-window assumption superseded by ADR-0065
- **Date:** 2026-06-05
- **Lock:** `apple/Tests/Zer0ShellTests/ShortcutTests.swift::KeyPressTests/browserCommandsStayWithTheBrowser`, `apple/Tests/Zer0ShellTests/ShortcutTests.swift::KeyPressTests/closeTabIsAboutWhatIsInFront`, `apple/Tests/Zer0ShellTests/ShortcutTests.swift::KeyPressTests/editingKeysSurvive`, `apple/Tests/Zer0ShellTests/ShortcutTests.swift::KeyPressTests/escapeIsNotTakenFromAnotherWindow`

## Context

The owner reported one symptom: with the Settings window focused, ⌘W closed a
browser tab behind it instead of closing Settings.

The cause was that the key handler installed the day before dispatched **every**
key press in the application into the browser model, with no notion of which
window was key. So the symptom was one of forty-four: ⌘T opened tabs, ⌘R
reloaded a page nobody could see, ⌘L opened the command bar over a window
sitting behind the one being used, and ⌘1–⌘9 switched tabs invisibly.

That handler was not a mistake. It was the fix for a worse bug — before it,
there was no key handler at all and half the keyboard did nothing (ADR-0012).
It simply did not know where it was.

There is a second path, and missing it would have left the defect half-alive: a
menu item's key equivalent is matched **application-wide**, regardless of which
window is key. Handing an unwanted press back to the system would therefore let
`File ▸ Close Tab` close the same tab one layer down. Three platform facts were
measured, in a throwaway AppKit application rather than reasoned about:

- a local monitor runs **before** main-menu key equivalents, and returning `nil`
  suppresses them;
- a **disabled** menu item swallows its key equivalent and the next matching
  item never sees it — so greying items out would have made ⌘W do nothing at
  all;
- SwiftUI gives its stock `File ▸ Close` item ⌘W only when nothing else claims
  it.

## Decision

**A command crosses into an auxiliary window only when what it does appears in
front of the person who pressed it.**

The rule is `UiCommand.scope`, an exhaustive switch with no `default:`, so a new
command cannot compile without someone deciding where it may land:

- **`opensItsOwnWindow`** — Settings, Extensions, History, Downloads. All four
  raise the Settings window at a named pane, so pressing ⌘, from About is
  exactly as reasonable as pressing it from the browser.
- **`frontmost`** — `closeTab` alone. In the browser the front thing is a tab;
  in a window with no tabs, it is the window, and the monitor sends
  `performClose:` so the platform's own path runs and the window can still
  object.
- **`browserWindow`** — everything else. Pressed elsewhere it would act out of
  sight.

A browser window is identified by a **marker it carries**, not by its title,
its style mask, or its position in a list. Everything else is auxiliary by
omission, so a window nobody has thought about yet gets standard macOS
behaviour — which is the safe direction to fail in.

Browser-scoped chords pressed in an auxiliary window are **swallowed**, not
passed on, because passing them on hands them to the menu bar. And a menu item
never advertises a bare key: the Stop item showed plain Escape, which is an
application-global Escape, and now shows the first chord carrying a modifier.

## Consequences

**The shell decides more than ADR-0012 said it did.** That ADR describes
`Shortcuts.swift` as translating a `Chord` into a `KeyboardShortcut` and
supplying menu names. It now also decides which chords a menu may advertise and
which commands cross into a window that is not the browser. Both are platform
facts — menu key equivalents being application-global, and window focus — so
nothing moved out of the core, but the sentence in ADR-0012 is narrower than the
truth.

**Every new command costs a decision.** The exhaustive switch is the point, but
it means adding a command is never one line, and someone in a hurry will classify
by pattern-matching a neighbour rather than by thinking about where the effect
lands.

**Escape is now arbitrated in three places** — the monitor, the view hierarchy,
and whatever transient UI is open. Each is right on its own; together they are a
priority order nobody has written down in one place.

**Menu items stay enabled while an auxiliary window is key.** Choosing "New Tab"
with the mouse from Settings still works, deliberately: a mouse click is
unambiguous about intent in a way a key press is not. The cost is that the menu
bar offers commands whose keyboard equivalents are refused, which is a divergence
someone will eventually notice and read as a bug.

**⌘←/⌘→ remain ambiguous.** They are Back/Forward in the keymap and also
line-start/line-end in any text field, and the Navigate menu advertises them
application-wide. That predates this decision and belongs to ADR-0011's
Chrome-parity question, not to this one.

## How this regresses

Someone adds a window — a downloads window, a devtools window, a profile
switcher — and does not apply the browser marker. That window then behaves
correctly, because auxiliary is the default. **The dangerous direction is the
other one:** someone applies the marker to a window that is not the browser, or
classifies a new command as `browserWindow` when its effect is invisible there,
and the browser starts acting on a page the person is not looking at.

The failure is silent by construction. A tab closes, a page reloads, a zoom
changes — all in a window that is behind another one. Nobody reports it as a
bug; they report that the browser "did something weird", weeks later, without a
reproduction.

The lock sweeps **every binding in the keymap** from an auxiliary window and
asserts the browser is untouched — tab count, active tab, sidebar, zoom, command
bar, find bar. Reverting the role check turns it red on about forty chords.

The point of it is what it does to its predecessor: the older lock, `every chord
in the keymap reaches its command from a real key press`, **stayed green for the
entire life of this bug**, because it asked whether a press arrives and never
asked where it came from. Two locks on the same mechanism, one dimension apart.

## When to revisit

~~When a second browser window exists.~~ **This happened: ADR-0065.** The rule
above survived it — a command still crosses only when its effect is visible
where it was pressed — but the sentence "the browser window" did not.
`WindowRole.browser` now carries *which* window, because answering "yes, the
browser" for two windows let a press act on the one nobody was looking at; and
`browserCommandsStayWithTheBrowser` now reads the browser before each press
rather than once at the end, because ⌘N and ⇧⌘N are `opensItsOwnWindow` and are
supposed to change it.

The marker registered one window; multiple browser windows made "the browser
window" ambiguous, and `frontmost` and `browserWindow` stopped being
distinguishable in the way this decision assumed.

Also if the enabled-menu-item divergence turns out to confuse people in
practice: the alternative is disabling those items in auxiliary windows, which
costs the mouse path and requires care, since a disabled item swallows its key
equivalent rather than passing it along.
