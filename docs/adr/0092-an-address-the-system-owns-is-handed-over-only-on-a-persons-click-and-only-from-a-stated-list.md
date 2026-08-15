# ADR-0092: An address the system owns is handed over only on a person's click, and only from a stated list

- **Status:** Accepted
- **Date:** 2026-08-10
- **Lock:** `crates/zer0-core/src/external_scheme.rs::one_of_our_own_addresses_is_never_handed_to_the_system`, `crates/zer0-core/src/external_scheme.rs::an_application_scheme_is_not_handed_over`, `crates/zer0-core/src/external_scheme.rs::the_communication_schemes_are_handed_over`, `crates/zer0-core/src/external_scheme.rs::what_the_engine_loads_is_never_handed_over`, `crates/zer0-core/src/external_scheme.rs::nonsense_is_refused_rather_than_repaired`, `crates/zer0-core/src/external_scheme.rs::a_scheme_that_only_looks_like_one_on_the_list_is_refused`, `crates/zer0-core/src/external_scheme.rs::the_scheme_is_read_without_regard_to_case`, `apple/Tests/Zer0ShellTests/PageMenuTests.swift::ExternalSchemeTests/aSchemeTheSystemOwnsIsHandedOverOnlyWhenAPersonClicked`, `apple/Tests/Zer0ShellTests/PageMenuTests.swift::ExternalSchemeTests/oneOfOurOwnAddressesIsNeverHandedToTheSystem`, `apple/Tests/Zer0ShellTests/PageMenuTests.swift::ExternalSchemeTests/whatTheEngineLoadsIsLeftAlone`, `apple/Tests/Zer0ShellTests/PageMenuTests.swift::ExternalSchemeTests/aScriptedMailtoKeepsThePageItWasOn`, `apple/Tests/Zer0ShellTests/PageMenuTests.swift::ExternalSchemeDoorTests/exactlyOnePlaceHandsAnAddressToAnotherApplication`

## Context

`decidePolicyFor navigationAction` answered `.allow` for every scheme that was
not one of ours. Nothing in this browser had ever handled `mailto:`, `tel:`,
`sms:` or `facetime:`.

**The expectation going in was that clicking one did nothing. It is worse than
that**, and it was measured rather than assumed:

```
mailto:someone@example.com  ->  policy delegate answers .allow
                            ->  didFailProvisionalNavigation
                                NSURLErrorDomain -1002 "unsupported URL"
```

`-1002` is `NSURLErrorUnsupportedURL`. `EngineHost.urlErrorKind` maps it to
`.unsupportedUrl`, which is not `.cancelled`, so the reducer records it as a
navigation failure and ADR-0016 gives the failure the whole screen. **Clicking
"Contact us" replaced the page somebody was reading with an error.**

`tel:`, `sms:`, `facetime:` and every unregistered scheme fail identically.

Asked what opens each of them, on this machine:

| address | handler |
| --- | --- |
| `mailto:` | Mimestream |
| `tel:` | Phone |
| `facetime:` | FaceTime |
| `sms:` | Messages |
| `weirdscheme:` | **nothing on this Mac** |
| `zer0://` | **nothing on this Mac** |

So the handlers are there. Nothing was asking them.

The question this opens is not plumbing. `NSWorkspace.open` **starts another
program on somebody's behalf, with an argument a page wrote.** A page that can
reach it unprompted has a surface it should not have, and `mailto:` is not the
scheme anybody worries about — `ms-msdt:` is the one that became a CVE.

`WKNavigationAction` carries `navigationType`, and measured, it separates the
two cases: a pointer on a link reports `.linkActivated`, a script assigning
`location.href` reports `.other`.

## Decision

**Only a person's click, and only for schemes on a list in the core. Everything
else is left exactly as it was.**

### A click, and nothing else

`navigationType == .linkActivated` or the navigation is cancelled and nothing
happens. A page that scripts its way to a `mailto:` gets nothing and is told
nothing, exactly as a blocked pop-up is told nothing (ADR-0075).

That gate is doing two jobs. It stops a page starting a program unprompted, and
it stops a page **blanking a tab on a timer** — because a scripted navigation to
a scheme nothing loads is what put the error screen over the page in the first
place.

The cost is stated: an "Email us" button written as a script that assigns
`location.href` does nothing here. It does nothing useful today either — it
costs the page — so nothing that worked stops working.

### A list, in the core

`mailto`, `tel`, `sms`, `facetime`, `facetime-audio`, `webcal`, `maps`.

Every one names a **conversation**: a message, a call, an appointment. The
address is the whole payload; none of them carries an argument list or a file
path, so the worst a page can do with one is open a compose window addressed to
somebody.

`slack:`, `zoommtg:`, `vscode:`, `spotify:` and every other application scheme
are **off the list, and that is the part of this decision that is arguable.**
They are links people click on purpose every day, and refusing them is this
browser being worse than every other one at something ordinary. It is refused
anyway, because handing an arbitrary scheme to an arbitrary program is only safe
if a person reads which program before it happens — and the only honest way to
give them that is a sheet naming the application. That sheet is not designed,
and this project does not ship dialogs nobody drew (ADR-0075 refused the same
way for the JavaScript panels). Declared, counted, and named in "When to
revisit".

The list is in the core because two platforms could not reasonably disagree
about whether `mailto:` is handed over. Whether anything answers to it is the
host's question, and they could not agree about that.

### Everything else keeps today's behaviour, on purpose

A scheme not on the list falls straight through to `.allow`. So `weirdscheme:`
still fails, still reaches `.unsupportedUrl`, and still gets the screen that
already says **"That address can't be opened — zer0 doesn't know how to open an
address of this kind."**

That is the refusal, and it is a true sentence in the one place this browser has
for saying one. Cancelling it silently instead would have been the silent
nothing this work exists to remove. Nothing new was drawn for it because nothing
new was needed.

### Our own scheme, twice

`zer0://` is refused before this door is reached, by the check ADR-0054 put at
the top of the policy delegate. `may_hand_to_the_system` refuses it again, and
`zer0` is not on the list either. Three locks, because this is the one call in
the browser that starts another program, and "we never put it on the list" is an
absence rather than a guarantee.

### One door

`ExternalScheme.takeOver` is called from `decidePolicyFor navigationAction` and
nowhere else, and it is the only caller of the function that reaches
`NSWorkspace`. A second place would be a second answer to whether a script may
start a program, and every test here would stay green because they all ask the
first one. `exactlyOnePlaceHandsAnAddressToAnotherApplication` counts both.

### Refusing rather than repairing at the end

The workspace is asked what opens the address before it is asked to open it, so
a `webcal:` on a Mac with no calendar app is not handed over in the hope that
something turns up. There is no second guess and no fallback to a web search.

What a person gets in that case is a beep — this browser's existing answer to
"that did nothing", already what a failed Save Page As does. **It is not a
sentence, and the sentence is missing.** The browser has exactly two ways to
report a failed navigation, loud enough to cost the page or silent, and neither
fits "the link is real, nothing here opens it". Declared debt.

## Consequences

**`mailto:`, `tel:`, `sms:` and `facetime:` work, and the page stays where it
was.** That is the change most people notice, and none of them will call it a
feature.

**A `slack://` link does nothing visible.** Worse than Safari, better than
today's error screen, and the worst-reading consequence of this decision.

**A scheme nothing opens still costs the page.** Unchanged from today, and only
reachable from a click now that a script cannot get there.

**`NSSound.beep()` is in a browser's navigation path.** It is the honest sound
for "that did nothing" and it is the wrong amount of explanation.

## How this regresses

**Somebody drops the `.linkActivated` check.** It looks like an obstacle: the
"Email us" buttons that assign `location.href` are common, they are legitimate,
and removing one line makes them work. What it also does is let any page start
any listed application, unprompted, on a timer.
`aSchemeTheSystemOwnsIsHandedOverOnlyWhenAPersonClicked` asks about four
scripted navigation types; broken on purpose, three went red at once.

**Somebody grows the list.** One scheme at a time, each with a good reason, and
each is a program a page can name. The list is in one place with a comment
saying why it is short, and `an_application_scheme_is_not_handed_over` names
five that must stay off — including `ms-msdt:`.

**Somebody removes the explicit refusal of our own scheme** because `zer0` is
not on the list anyway. It is the second lock on ADR-0054's whole security
answer, and the failure it prevents is a page reaching one of the browser's own
addresses through the one call that leaves the browser.

**Somebody makes the refusal loud.** It reads as an improvement — the person
clicked, so tell them — and it hands every page a way to replace a tab's content
with an error screen. Which is exactly the defect this ADR fixes, rebuilt from
the other side.

**Somebody deletes the door in `decidePolicyFor`** while tidying the delegate.
`aScriptedMailtoKeepsThePageItWasOn` goes red with the original defect spelled
out in the failure: `NavigationError(kind: .unsupportedUrl, url:
"mailto:someone@example.com")`.

## When to revisit

- **When there is a sheet that names the application.** That is the day
  `slack:`, `zoommtg:` and `vscode:` can be handed over, and the day the list
  stops being the mechanism. It looks like ADR-0056's camera answer — a
  decision, per site or per space, that outlives the moment — and it is its own
  ADR rather than a wider version of this one.
- **When the browser has a way to say "that went nowhere" without costing the
  page.** Every part of this decision that is currently a beep or a silence is
  waiting on that surface, and so is the "nothing on this Mac opens it" sentence.
- **If a scripted navigation to an unloadable scheme should be cancelled
  outright.** A page can still blank its own tab by navigating to
  `weirdscheme:`. It is pre-existing, it is now the only remaining path to it,
  and closing it means deciding what an unknown scheme means rather than what a
  listed one does.
- **If `NSWorkspace` gains a way to open a URL and report that nothing did.**
  The pre-flight `urlForApplication(toOpen:)` is a check with a window between
  it and the act.
