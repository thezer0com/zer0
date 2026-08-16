# ADR-0120: Background-tab throttling and HTTPS-first are decided in the core and the shell only applies them

- **Status:** Accepted
- **Date:** 2026-08-16
- **Lock:** `crates/zer0-core/src/store_tests.rs::background_tabs_throttle_out_of_the_box_and_survive_being_let_loose`, `crates/zer0-core/src/store_tests.rs::https_first_ships_on_and_survives_being_turned_off`, `apple/Tests/Zer0ShellTests/EnginePolicyTests.swift::EnginePolicyTests/engineBehaviourTheCoreDecidesReachesViewsBornAfterIt`, `apple/Tests/Zer0ShellTests/EnginePolicyTests.swift::EnginePolicyTests/everyPageIsBuiltForABrowserRatherThanForAnEmbeddedView`

## Context

ADR-0074 wrote the engine sheet, and everything on it was spelled in
`EnginePolicy.swift` — including two lines that are not rendering
configuration at all:

- `inactiveSchedulingPolicy = .throttle` — what a tab that is not the front
  one is allowed to do;
- `preferredHTTPSNavigationPolicy = .automaticFallbackToHTTP` — what happens
  to a typed `http://` address, silent fallback included.

Run ADR-0002's tie-breaker over them. Could two platforms reasonably
disagree about whether a background chat tab stays alive, or whether a typed
address is tried as https first? No — a Linux host that froze its background
tabs, or navigated typed http verbatim, would be breaking the same product
promise, for the same reason, with nobody to notice the divergence. What a
host *can* disagree about is how the answer is spelled for its engine:
`.throttle` is a WebKit word, and so is the whole shape of the silent
fallback. The decision and the spelling are different things, and they were
living in the same place.

The pattern to follow already existed beside them:
`block_audible_autoplay` and `block_unprompted_windows` live in the core's
`Preferences`, and `BrowserModel.applyEnginePolicy` derives from them
without deciding anything.

## Decision

`Preferences` gains `background_throttling` and `https_first`, both
defaulting to on — the values the sheet was already hardcoding, so **the
observable behaviour does not change.** They are stored like every other
preference (scalars in meta) even though no Settings row exists to change
them, so the day a host or a row wants to move them, storage is not the half
that turns out broken.

The shell keeps the spellings and loses the decisions.
`BrowserModel.applyEnginePolicy` reads both off `core.preferences()` the
same way it reads the pop-up blocker, and `EnginePolicy.Choices` carries
them into `apply`, which maps them to WebKit: `.throttle` or `.none` —
`.none`, not `.suspend`, because suspending is *more* throttling and the
word says less — and `.automaticFallbackToHTTP` or `.keepAsRequested`, the
mediated interstitial staying refused for the reason argued beside the call.
Off means a typed http address navigates as typed.

Everything else on the sheet stays in the shell — fullscreen, fraud warning,
site quirks, AirPlay, the text features — because those are engine rendering
configuration two platforms could reasonably disagree about.

## Consequences

**What hurts:**

- `Preferences` now carries two fields no Settings row can change. They are
  stored anyway, so a change made through the core's one door cannot quietly
  evaporate on relaunch — the "switch that forgets" shape, caught before it
  exists rather than after.
- `EnginePolicy.Choices` mixes two kinds of answer: rows a person flips and
  behaviour the core decided. The difference is invisible in the type, so the
  doc comment on `Choices` says it out loud.
- Two more fields cross the FFI — the cost of every rule that crosses the
  boundary so it can be the same rule on both sides of it.

**What we get:**

- A future host cannot drift on either policy. It reads the same
  `Preferences` every macOS build reads and spells the answer for its own
  engine.
- A hardcoded shell is now catchable. Until here, "the shell spells
  `.throttle` itself again" was invisible: the defaults agreed, so every
  value assertion stayed green. The derivation test flips the core's answer
  and asks the next view born, which a constant cannot satisfy.

## How this regresses

**"The shell re-spells the constant, just locally."** Somebody tidying
`EnginePolicy` puts `.throttle` back as a literal — the defaults agree, every
value assertion stays green — and the two platforms are divergent the way
this exists to prevent. `engineBehaviourTheCoreDecidesReachesViewsBornAfterIt`
is what goes red: it flips the core's answer and the view born afterwards
still throttles.

**"The silent fallback is improved into the mediated one."** The comfortable
direction: WebKit's own interstitial reads as more security and is chrome we
do not draw, over a failure ADR-0016 says gets our whole screen. The silent
shape is part of what `https_first` *means*, the refusal is argued where the
WebKit call is made, and the value assertion beside it names
`.automaticFallbackToHTTP` exactly.

**"Off becomes `.suspend`."** A reviewer maps `backgroundThrottling` false to
WebKit's own default — which freezes background tabs rather than freeing
them, the opposite of the word. The derivation test asks for `.none` by
name, and the comment at the call says why.

## When to revisit

- **When either earns a Settings row.** The preference is stored already; the
  row has to make the same honest promise the autoplay row makes — reaches
  views born after, not views already open — and say who it is for.
- **When a host's engine cannot express the answer.** If an engine has no
  notion of a throttled-but-alive background tab, that is a host capability
  question, and ADR-0118's declaration on the way in is the door it comes
  through.
- **When try-then-fallback stops being the https promise.** Refusing plain
  http outright is `.errorOnFailure` — a different promise, a different ADR,
  and not a reinterpretation of this field.
