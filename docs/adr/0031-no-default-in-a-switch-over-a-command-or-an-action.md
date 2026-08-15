# ADR-0031: No `default:` in a switch over a command or an action

- **Status:** Accepted
- **Date:** 2026-04-08
- **Lock:** `apple/Tests/Zer0ShellTests/SourceRuleTests.swift::VocabularyExhaustivenessTests/noSwitchOverTheVocabularyCarriesADefault`

## Context

`UiCommand`, `EngineCommand` and `Action` are the vocabulary the core and the
shell share. They are defined once, in Rust, and consumed on both sides of the
FFI: `UiCommand` in `crates/zer0-core/src/shortcuts.rs`, `Action` and
`EngineCommand` in `crates/zer0-core/src/protocol.rs`.

Adding a variant to one of them is the most common way this project grows, and
it is a change whose consequences are spread across two languages. A new
`UiCommand` needs a keybinding, a menu label, a row in the keymap store, and
behaviour in the shell. Four places, two languages, one enum.

A wildcard arm — `default:` in Swift, `_ =>` in Rust — makes all four of those
optional. It converts "you forgot the shell half" from a compile error into a
command that is bound, appears in the menu, and does nothing when pressed. There
is no crash, no log line and nothing to report except that the menu item does
not work.

The exhaustive switch is the only mechanism in this codebase that makes an
incomplete change *impossible* rather than merely detectable.

## Decision

**A switch or match over a command or an action type lists every variant. No
`default:`, no `_ =>`.** When some variants genuinely have nothing to do, they
are still named, grouped into one arm that does nothing.

The distinction is the *type being matched*, not the syntax:

- **In scope:** `UiCommand`, `EngineCommand`, `Action`, `Suggestion` — the
  closed vocabularies this project owns and extends.
- **Out of scope:** `Int`, `String`, an AppKit selector, an `NSError` domain, a
  protobuf wire type, a value read back out of SQLite. These are open sets, and
  a wildcard is the only correct way to handle them. `TabKind` parsed from a
  database column *must* have a fallback; the same `TabKind` consumed in the UI
  must not.

The pattern to copy is `BrowserModel.notifyExtensions(of commands:)` at
`apple/Sources/Zer0Shell/BrowserModel.swift:210`, which ends with the variants
that have no work to do written out by name:

```swift
case .reload, .goBack, .goForward, .deleteDataStore, .setZoom:
    break
```

That is three extra words compared to `default: break`, and it is the entire
difference between "these five do nothing" and "everything I did not think about
does nothing".

The rule is stated in `CLAUDE.md` and its mechanics are described in ADR-0002.
This ADR exists to record it as a decision with a scope and a known cost, rather
than as a style preference.

## Consequences

**What it costs:**

- **Adding a variant is a multi-file, two-language chore.** A new `UiCommand`
  breaks `command_to_row` in the Rust store, `perform` in the Swift shell and
  `UiCommand.title`. That friction is the feature, and it is still friction —
  and it is felt most acutely when someone is trying to do something small.
- **Grouped no-op arms rot silently.** `case .reload, .goBack, ...: break` is
  correct today. When one of those variants grows a meaning, the compiler is
  satisfied and no longer helps: the variant is listed, so nothing breaks. The
  rule protects against *forgetting a variant*, not against *listing it wrongly*.
- **It only binds where the type is the enum.** The moment a command crosses a
  boundary as a string — a database column, a config file — exhaustiveness is
  gone and a wildcard is unavoidable. `command_from_row` at
  `crates/zer0-core/src/store.rs:687` is that boundary, and it is correct there.
- **It was unenforceable by test, and is not any more.** *Factual correction:
  this said the rule was held by two compilers and by review and nothing else.
  That was true when written and stopped being true.* Rust now denies
  `clippy::wildcard_enum_match_arm` from the workspace manifest, and the Swift
  half is a source scan that reads the vocabulary out of the generated bindings
  rather than listing it — a second copy of the enum would go stale for exactly
  the new variant the rule protects. Eleven wildcards in the shell survive it
  untouched, because a switch is judged by the type it matches: an `NSError`
  domain, an AppKit selector, an `OSStatus` and an HTTP status are all correct.

**What it buys:**

- A half-wired command does not exist. It either compiles everywhere or nowhere.
- The cost of a protocol change is paid at the moment of the change, by the
  person making it, instead of at runtime by whoever pressed the key.
- Every consumer of the vocabulary is discoverable by breaking the build.

## How this regresses

It regresses one `default: break` at a time, and every one of them is
individually reasonable.

- **Someone adds a variant, gets six compile errors, and adds a wildcard to
  five of them.** Each is honestly "nothing to do here". Together they undo the
  guarantee for every future variant, and nobody will ever see them again.
- **A new consumer of `UiCommand` is written wildcard-first.** Analytics,
  logging, a debug overlay — something that genuinely only cares about three
  variants. It ships with `default: break`, and the next command silently is
  not logged.
- **A refactor moves a switch into a generic helper.** The type gets erased, the
  exhaustiveness goes with it, and no line in the diff says so.
- **What a person would notice:** nothing, for a while. Then a menu item that
  does nothing when clicked. Or a keyboard shortcut that works everywhere except
  the one place it should. Or — the case already live in this repo — a browser
  extension that never learns a tab's favicon changed, with no error anywhere,
  because the notification path had a `default:` and the new fact fell into it.

**No lock — and this is the interesting part.** No test can observe the absence
of a `default:`. What enforces this rule is the compiler refusing to compile,
and a test cannot watch a compilation that never happened. Two existing tests
look like they cover it and do not:

- `apple/Tests/Zer0ShellTests/ShortcutTests.swift::ShortcutTests/everyBoundCommandIsHandled`
  iterates the keymap and calls `perform` on each bound command. It proves those
  commands do not blow up at runtime. It would stay green if `perform` grew a
  `default:` tomorrow, and it never exercises a `UiCommand` that has no default
  chord.
- `apple/Tests/Zer0ShellTests/ShortcutTests.swift::ChromeParityTests/pageActionsAreHandled`
  has the same shape and the same limit.

Naming either as this ADR's lock would be exactly the failure ADR-0018 is about:
claiming proof we do not have. So the field says debt.

**Known violation, named rather than hidden:**
`apple/Sources/Zer0Shell/BrowserModel.swift:197` — `default: break` in a switch
over `Action`, inside `notifyExtensions(of action: Action)`. It is a real
instance of the failure mode this ADR describes: an `Action` that should reach
the WebExtension API but is not listed will compile and never arrive. The fix is
the one its sibling function twelve lines below already uses — replace
`default: break` with the explicit list of variants that have nothing to do.
Every other switch over `UiCommand`, `EngineCommand` and `Action` in the shell,
and every `match` over them in the core, is exhaustive today.

A real lock is a lint rather than a test: something that walks the switches over
these types and fails on a wildcard arm. *That was written as the shape of the
debt; it has since been built, and is what the `Lock:` line now names.* Two
`#[allow]`s survive, each with a stated reason and each over a foreign enum —
`toml_edit::Item` and `serde_json::Value`, both parsing something a stranger
wrote. Every other site that was expected to need silencing turned out to be a
filter rather than a dispatch and was rewritten instead, which uncovered two
genuine violations of this ADR that nobody had noticed.

## When to revisit

- If a lint that can see wildcard arms over these types becomes cheap to write.
  That is what converts this ADR from debt into a lock, and it is the only thing
  that will.
- When the violation at `BrowserModel.swift:197` is fixed. This ADR should be
  superseded by one that can say the rule holds without an exception.
- If a command enum grows past the point where an exhaustive switch is
  readable. The answer is to split the vocabulary, not to add a wildcard.
- If a third host appears. The cost of a protocol change is currently two
  languages; at three, the friction may need tooling rather than discipline.
