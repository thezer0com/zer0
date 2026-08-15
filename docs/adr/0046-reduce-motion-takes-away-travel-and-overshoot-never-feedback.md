# ADR-0046: Reduce Motion takes away travel and overshoot, never feedback

- **Status:** Accepted
- **Date:** 2026-05-11
- **Lock:** `apple/Tests/Zer0ShellTests/MotionTests.swift::MotionTests/reduceMotionFlattensEntrance`, `apple/Tests/Zer0ShellTests/MotionTests.swift::MotionTests/reduceMotionKeepsFeedback`, `apple/Tests/Zer0ShellTests/MotionTests.swift::MotionTests/thereAreOnlyTwoCurves`, `apple/Tests/Zer0ShellTests/MotionTests.swift::MotionTests/directionSurvivesEveryPath`, `apple/Tests/Zer0ShellTests/SourceRuleTests.swift::DesignVocabularyTests/noViewWritesItsOwnAnimationCurve`, `apple/Tests/Zer0ShellTests/SourceRuleTests.swift::DesignVocabularyTests/noViewInventsADepth`

## Context

DESIGN.md §3 has said since the beginning that the shell has exactly two
curves — `entrance` for a thing that arrived, `subtle` for a thing that
adjusted — and that motion which does not answer "where did that come from"
does not go in. That part held.

What did not hold is §13, which recorded, under things not decided:

> **Reduced motion, reduced transparency, colour-blind-safe status.** Nothing
> in the shell reads those environment values today.

Nothing did. Every animation in `apple/Sources/Zer0Shell/` was written as
`.animation(Design.entrance, value:)` against a global constant, and every
transition was written as a literal `.move(edge:).combined(with: .opacity)` at
its call site. A person with Reduce Motion switched on in System Settings got
the springs, the slides and the scale changes exactly as everyone else did.

That was already wrong with the motion the shell had. It becomes worse the
moment there is more of it, and there is now more of it: the sidebar's tab list
slides sideways when a space changes, the marker under the current tab travels
between rows, the command bar comes forward out of the window. A browser is not
a screen someone visits — it is the window they have open all day. Motion that
is merely tiring for one person is unusable for someone whose vestibular
disorder is what the setting exists for.

There were three shapes an answer could take:

1. **Switch motion off.** `.animation(nil, value:)` everywhere the setting is
   on. Simple, and wrong: with no animation at all a list reordering after a
   drop, a panel resizing under a new result count, and a marker changing rows
   all become single-frame jumps. That is not less motion, it is less
   information — and Apple's own guidance is to substitute a cross-fade, not to
   substitute nothing.
2. **A third curve.** A "reduced" animation beside the two. Rejected on the
   same grounds `settle` was deleted for: the shell has two curves *because*
   the choice between them means something, and a third one nobody could
   describe the criterion for is how a system stops being one.
3. **Resolve the two curves against the setting.** One rule, applied to the
   vocabulary rather than to the call sites.

## Decision

**Reduce Motion takes away travel and overshoot. It never takes away
feedback.**

Concretely, and there is nothing else to it:

- **`entrance` loses its spring.** With the setting on it resolves to the same
  ease-out `subtle` already is. A panel still arrives, over the same 180ms; it
  simply stops bouncing.
- **`subtle` does not change at all.** It is what a row lighting under the
  pointer, a panel resizing and a divider waking up already use. Someone who
  asked for less movement did not ask for a less responsive interface, and
  slowing feedback down or removing it would be answering a question they did
  not ask.
- **A transition loses its edge and keeps its fade.** `arrival(from:)` is
  `.move(edge:).combined(with: .opacity)` normally and plain `.opacity` when
  reduced. The thing still arrives; it fades up where it is going to live
  instead of flying there.
- **A press keeps its dimming and loses its scale.** `PressFeedback` is the
  answer to "did it hear me", so the opacity dip survives; the 3% squeeze does
  not.

The rule is enforced by making the raw curves unreachable. `Design.entrance`
and `Design.subtle` are `fileprivate`. Outside `DesignSystem.swift` there are
exactly three ways to spell motion, and all three read
`\.accessibilityReduceMotion` from the environment on the way through:

```swift
.motion(.entrance, value: something)   // declaring a change
.arrives(from: .top)                   // a transition that carries a direction
@Curves private var motion             // for withAnimation(motion.entrance)
```

A curve written out at a call site no longer compiles. That is the point: this
decision cannot be forgotten by omission, only reverted on purpose.

### The direction a space change went is a fact, not an appearance

`BrowserModel.spaceTravel` is `1`, `-1` or `0`, read off two consecutive
snapshots after every dispatch. The sidebar consumes it to pick which edge the
tab list arrives from.

It is in `BrowserModel` rather than in `Sidebar` because a space changes from
four places — a chip, `NextSpace`/`PreviousSpace` through the keymap, the menu,
and a space closing under you — and a view that watched only its own buttons
would get three of the four wrong. It is in the shell rather than in the core
because it is derived, not decided: the core already published both snapshots.
A shell that wanted no such animation ignores the property, which is the test
for whether something is appearance.

`0` is deliberate and is not "unknown". Closing the space you are in moves you
somewhere without you having gone anywhere, so the list fades rather than
sliding: an animation that claimed travel there would be asserting a gesture
nobody made, which is ADR-0018's rule applied to motion.

## Consequences

- With Reduce Motion on, `entrance` and `subtle` are the same curve. That reads
  as a loss of vocabulary and is not one: what separated them was the
  overshoot, and the overshoot is precisely the part being declined.
- Every view that animates now reads an environment value, so a view rendered
  outside a hosting environment gets `false` — full motion — rather than
  crashing or going still. There is no way to bypass the environment from a
  view: `Design.Motion(reduced:)` can be built directly, and the only thing
  that does is the test that has to check both states.
- The setting is live: `accessibilityReduceMotion` invalidates the views that
  read it, so switching it in System Settings changes the running app without a
  relaunch. Reading `NSWorkspace` once at launch would not have done that.
- **Reduced transparency and colour-blind-safe status are still open.** This
  ADR closes one third of the §13 entry and no more. The materials in this
  shell are still unconditional.
- A new animation cannot be added without answering the question, because the
  only spellings that compile are the ones that ask.

## How this regresses

`MotionTests` runs on every `check.sh` and holds the rule itself: that
`entrance` flattens into `subtle` when reduced, that `subtle` is untouched, that
there are two curves and both resolve in both modes, and that `spaceTravel`
reports the right direction whether the change came from a chip or from the
keymap.

**Factual correction, to the record and to one test.** "There are two curves"
was on the `Lock:` line and was not held by anything. `thereAreOnlyTwoCurves`
read `let all: [Design.Curve] = [.entrance, .subtle]` and then checked that
`all.count == 2` — true of the array it had just written down, and true no
matter how many cases `Design.Curve` grows. A third curve left it green, which
is the single thing it exists to catch. It now reads `Design.Curve.allCases`,
and `Curve` is `CaseIterable` for that reason and no other.

The claim is in fact defended twice, and it is worth saying which is which. The
compiler catches it first: `Design.Motion.callAsFunction` switches over `Curve`
with no `default:` (ADR-0031), so a third case does not compile until somebody
decides what it does under Reduce Motion — which is exactly the conversation
this ADR wants to force. The test is what catches a third case that *was*
given a resolution, silently, by whoever added it. Neither replaces the other,
and the lock now names one instead of appearing to name it.

What those cannot see is whether anything moves on screen, and that gap is the
reason this project already carries a doc comment recording an animation that
was described three ways in prose and never shifted a pixel. So the frames are
checked too: `apple/Tests/Zer0ShellTests/ZZMotionShots.swift` drives the real
views with the real curve and reads the position of the thing across every
layout pass — including one case that renders with Reduce Motion forced on and
fails if the panel is laid out at more than one position. It reads geometry
rather than pixels, and that is itself a finding: `cacheDisplay` on an
`NSHostingView` draws the *model* layer, so a view part way through a
transform-based transition rasterises where it is going to be. Five probes of a
working animation — including a plain rectangle with no AppKit in it — all
photographed as "never moved". Those are harnesses, gated behind `ZER0_SHOT=1` by the rule
in `check.sh`, because they pump the run loop for seconds and would starve the
timing suites. They are evidence on demand, not a gate.

## When to revisit

- **When reduced transparency is decided.** It is the neighbouring third of the
  same §13 entry and it will want the same shape: one rule, applied to the
  vocabulary, not to the call sites. If it turns out to want something else,
  the shape here is worth re-examining.
- **If a curve appears that is neither an arrival nor an adjustment.** The two
  curves are load-bearing for this decision — the reduced form of `entrance`
  is defined as "whatever `subtle` is". A third curve makes that definition
  ambiguous and this ADR needs rewriting before the curve lands.
- **When there is a second shell.** Linux has its own accessibility settings
  and its own name for this one. `Design.Motion` is the seam that would take
  the translation; if it turns out the two platforms disagree about what the
  setting *means*, then the rule, not just the plumbing, is in the wrong place.
