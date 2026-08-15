# ADR-0052: Settings configures chat by clicking, and says so where it cannot

- **Status:** Accepted
- **Date:** 2026-06-02
- **Lock:** `apple/Tests/Zer0ShellTests/ChatSettingsTests.swift::ChatSettingsTests/aRefusedKeyIsNotStored`, `apple/Tests/Zer0ShellTests/ChatSettingsTests.swift::ChatSettingsTests/aWorkingKeyIsStored`, `apple/Tests/Zer0ShellTests/ChatSettingsTests.swift::ChatSettingsTests/unreachableIsNotRefused`, `apple/Tests/Zer0ShellTests/ChatSettingsTests.swift::ChatSettingsTests/theKeyIsNotInTheFile`, `apple/Tests/Zer0ShellTests/ChatSettingsTests.swift::ChatSettingsTests/theWrongProvidersKeyIsCaught`, `apple/Tests/Zer0ShellTests/ChatSettingsTests.swift::ChatSettingsTests/addingAndRemovingAConnection`, `apple/Tests/Zer0ShellTests/ChatSettingsTests.swift::ChatSettingsTests/aConnectionsKeyIsNotInTheFile`, `apple/Tests/Zer0ShellTests/ChatSettingsTests.swift::ChatSettingsTests/aPastedTokenNeverReachesTheFile`, `apple/Tests/Zer0ShellTests/ChatSettingsTests.swift::ChatSettingsTests/removingAConnectionForgetsItsKey`, `apple/Tests/Zer0ShellTests/ChatSettingsTests.swift::ChatSettingsTests/toolConsentReachesTheCore`, `apple/Tests/Zer0ShellTests/ChatSettingsTests.swift::ChatSettingsTests/undecidedIsNotRefused`, `apple/Tests/Zer0ShellTests/ChatSettingsTests.swift::ChatSettingsTests/nothingIsClaimedBeforeConnecting`, `apple/Tests/Zer0ShellTests/ChatSettingsTests.swift::ChatSettingsTests/nothingConfiguredYet`, `apple/Tests/Zer0ShellTests/ChatSettingsTests.swift::ChatSettingsTests/disablingIsNotDeleting`

## Context

ADR-0048 put configuration in a TOML file and secrets in the Keychain, and it
is a good file: commented, version-controllable, diagnosable. ADR-0049 through
ADR-0051 gave chat a core that decides everything worth deciding.

None of that is a product. The constraint that governs this one is one
sentence from the person building it:

> it is a browser and the focus is not only technical people; everything that
> gets configured must have a visual interface in settings — including MCP
> servers, all by clicking, thinking of the end user.

The difficulty is not layout. It is that the underlying objects are developer
objects and they do not become anything else by being drawn nicely:

- **An API key** is a forty-character string that has to be fetched from
  another company's website, cannot be validated by looking at it, and fails
  much later with a message from an HTTP API.
- **A model** is an identifier like `claude-opus-4-20250514`. Nobody types that
  from memory, and getting it wrong fails the same way.
- **An MCP server over stdio** is a program, a list of arguments and a set of
  environment variables. Every published server is distributed as a JSON block
  to paste into a config file.

The failure this ADR exists to prevent is a settings window that *looks*
approachable and drops somebody at a text field with `npx -y @scope/pkg` as
placeholder text. That is not a visual interface for a command line; it is a
command line with better spacing, and it teaches the person that the friendly
part was a decoration.

## Decision

**Two panes — Chat and Connections — where everything that can be a click is
one, and where the things that cannot be are named as such rather than
disguised.**

Six parts.

### 1. The empty state is the chooser

Nobody has configured anything on day one, so the first screen is not a form
with empty fields: it is four cards, one per `ProviderKind`, each carrying what
picking it costs. One click sets it up and puts the cursor in the key field.

The card that matters most is *"On this Mac"* — a local model through Ollama,
no account and no key. For somebody who has never held an API key, that entry
existing at the top level is the most useful sentence on the pane.

### 2. A key is checked before it is stored, and the check is what fills the
model menu

`submit(key:for:)` probes the provider and **only writes to the Keychain if the
provider accepted the key**. A key stored without being checked is one somebody
discovers is wrong in the middle of a conversation three days later, which is
the single most likely way this feature fails a person.

The probe is `GET /v1/models`, which answers both questions in one request:
whether the key works, and what it can run. So the model menu fills as a
*consequence* of the key going green rather than as a second thing to press —
and there is never a menu offering models a key cannot reach.

Three verdicts, not two. `refused` and `unreachable` are separate states
because they call for different actions, and telling somebody to go and make a
new key because their wifi dropped is how a settings screen loses trust for
good.

Before the network, a prefix check catches the commonest paste mistake — an
OpenAI key under Claude. It is a **hint and never a refusal**: a provider is
free to change its prefix, and rejecting a working key for looking unusual is
worse than letting the provider answer.

### 3. A model is picked from a list, never typed

Typing a model identifier is a developer interface: it fails on a typo, with a
message from an API, and the person who typed it has no way to find out what
the right string was.

### 4. An MCP server has three doors, and the third one is admitted to be a
command line

- **Ready to add.** zer0 ships the recipe. Click a name, answer the one or two
  things it genuinely needs — and each of those is *the control the answer is*:
  a folder is an `NSOpenPanel`, a token is a secure field with one button to
  the page that issues one. Then read what it will be able to do. **This path
  is fully clickable**, which is why it is first and largest.
- **Paste what the instructions gave you.** Every MCP server on the web ships
  an `mcpServers` block to copy. Copying a block of text out of a page is
  something almost anybody can do; composing the same block is not. The paste
  is parsed and lands on the *same* review screen the catalogue produces.
- **By hand.** Program and arguments, behind a disclosure, with a sentence
  saying what it is: *"There is no way around knowing what it is — a command is
  a command."*

**What we are refusing to build is a wizard for door three.** Walking somebody
through inventing a command line for a program they have never heard of is a
longer road to the same dead end, and it would be the one dishonest screen in
the product.

Three things the sheet does that the catalogue alone would not:

- **A literal token in a pasted block is lifted out.** READMEs routinely show
  `"env": { "GITHUB_TOKEN": "ghp_…" }`. Written through, that key would land in
  a file built to be committed. Anything `looks_like_a_secret` calls a secret
  becomes a `SecretEnvVar` naming a Keychain credential, and the value goes to
  the Keychain. The review screen says so, which is also the only way anybody
  learns the file is safe to commit.
- **The runtime is checked first.** `npx` or `uvx` may not be on the machine at
  all. `command not found` two screens later is the likeliest way somebody who
  did everything right gets stuck, and it is not their mistake. Add is
  disabled, the missing thing is named as a product rather than as a binary,
  and there is a link — and a plain statement that zer0 will not install
  software on their behalf.
- **The exact command is shown, whole.** The core's `mcp_exact_command`, never
  elided, beside the core's pinned `STDIO_CONSEQUENCE`. Somebody is about to
  let code start on their Mac; hiding which code is what would make them right
  to distrust the sheet afterwards.

### 5. What a connection may do is reviewable and revocable, in three states

Per `(server, tool)`, through `Action::SetToolConsent` — the core's own door
for *"change a remembered answer from Settings, without a call in flight"*. Not
a switch but a three-way menu: **Ask each time / Always allow / Never**,
because `ToolConsent::decision` returns `Option<bool>` and *nobody was asked*
is not *no*. Collapsing them would turn every un-asked tool into a refusal
nobody made.

A server that has not connected yet gets **no invented list**. It says it has
not said what it can do, and that nothing is allowed in advance. Its own
description of its own tools is shown as its own words — *"files describes this
as: …"* — and never in the browser's voice or with a risk colour, because a
server describing its tool as harmless is the thing being trusted describing
itself (ADR-0028, ADR-0018).

### 6. The file is named, and editing it is stated to be legitimate

Path in monospace, a Reveal button, and: *"Plain text. Editing it by hand is
fine — zer0 reads it again when it changes."* Diagnostics from the core appear
with their line number, so the row is actionable in the editor about to be
opened.

What the pane deliberately **does not** do is offer to edit the file in a text
view. That would be a worse editor than the one they already have, and it would
turn the GUI into a front end for a file rather than the normal way to do this.

## Consequences

**What hurts:**

- **The catalogue is a maintained list and it will go stale.** Three entries,
  each a promise that an `npx` package still takes those arguments. When one
  changes upstream, the click path silently produces a server that will not
  start, and the person sees a failure rather than a wrong recipe.
- **The consequence sentences for catalogue entries are written by us and are
  not checked against the server.** *"Read any file in the folder you chose"*
  is what `server-filesystem` does today. If it grows a tool, our sentence is
  quietly incomplete — mitigated only by the new tool arriving un-approved.
- **Door three is still a command line**, and everybody who needs a server we
  did not ship a recipe for either finds a block to paste or is a developer.
  That is the honest state of the ecosystem and not something a settings pane
  can fix.
- **The probe spends somebody's money and their rate limit.** One `GET
  /v1/models` per key entry. Cheap, but not free, and it is a network request
  made from a settings window.
- **`GET /v1/models` is not the endpoint chat uses.** A key scoped to allow
  listing and not completion would pass this check and fail later. Verifying
  with a real completion would cost tokens on every key paste; we took the
  cheaper check and this is what it does not cover.
- **The runtime check does not run a login shell.** Somebody whose Node lives
  somewhere unusual and is only on `PATH` inside `zsh` is told it is missing.
  A false negative here blocks Add, which is the worse direction.
- **Two panes, not one.** "Chat" and "Connections" are one feature split for
  the sake of two empty states, and somebody looking for MCP under Chat has to
  look twice.

**What we get:**

- Somebody who has never opened Terminal can reach a working assistant: pick a
  card, paste a key, watch it go green, pick a model from a list.
- A wrong key is found out **before the window closes**, in a sentence about
  what to do.
- A key never reaches the file — proved by reading the bytes off the disk, not
  by trusting an API.
- Every connection's access is listed, three-state, and revocable at any time
  through the same ledger a live tool call reads.
- The file stays first-class: named, revealed, diagnosed, and stated to be
  editable.

## How this regresses

**"It saved a key that does not work."** Somebody separates storing from
checking — a Save button beside the field, or an early write "so it is not
lost". `aRefusedKeyIsNotStored` goes red, and so does `aWorkingKeyIsStored`,
which pins that the model list arrives on the same call.

**"It told me my key was bad and my key was fine."** The two failure verdicts
are collapsed into one because "it is simpler". `unreachableIsNotRefused` is
the fence.

**"My API key is in my dotfiles repository."** The worst outcome available
here, and it has two doors. Somebody writes the key into `credential`, or a
pasted `env` value goes through verbatim. `theKeyIsNotInTheFile`,
`aConnectionsKeyIsNotInTheFile` and `aPastedTokenNeverReachesTheFile` all read
the file off the disk and look for the characters, which is the only assertion
that cannot be satisfied by an API that merely claims not to store it.

**"I removed the connection and the token is still in my Keychain."** A secret
under a name nothing points at is one nobody can find in order to delete it.
`removingAConnectionForgetsItsKey`.

**"I switched it off and it kept being used."** A revoke that repaints the row
and never reaches the ledger, which looks correct in every screenshot.
`toolConsentReachesTheCore` asserts the `Action`, and `undecidedIsNotRefused`
holds the three-state distinction that a Bool binding would quietly destroy.

**"It listed things the server can do before it had connected."** Somebody
fills the gap from the catalogue because an empty list looks unfinished.
`nothingIsClaimedBeforeConnecting`.

**"Turning a connection off deleted it."** `disablingIsNotDeleting`.

**"There is nothing on the screen on a new Mac."** The empty state stops being
reachable because the condition drifts. `nothingConfiguredYet` is what makes
`isConfigured` a named property rather than an inline check.

**And the ones no test catches**, named here because they are the expensive
class (ADR-0018): a catalogue recipe going stale upstream; a consequence
sentence softening back into a category name; and door two quietly becoming the
primary path because nobody maintained the catalogue. `ZZChatSettingsShots`
renders all nine screens light and dark, which is how the third one gets
noticed by a person rather than by an assertion.

## When to revisit

- **When the MCP registry lands.** A published, signed index of servers with
  declared inputs would replace the hand-maintained catalogue with something
  that cannot go stale silently, and would turn door two from "paste this" into
  "search for it".
- **When a provider offers a cheaper proof than `/v1/models`.** A zero-token
  auth endpoint would close the gap between "the key lists models" and "the key
  can hold a conversation".
- **When `McpHost` reports live state.** Today `status(of:)` is derived from
  `Readiness` plus what has been published; once a server's real connection
  state crosses the FFI, "Ready" can stop meaning "configured correctly" and
  start meaning "connected".
- **If a second platform arrives.** The catalogue's `command`/`args` and the
  runtime check are both macOS-shaped and both sit in the shell. They are the
  first thing a Linux host would have to disagree with, which is the signal
  that building a command line from answers belongs in the core.
- **If the two panes prove to be one.** If nobody ever configures a connection
  without a provider, the split costs a click and buys a second empty state,
  and that trade is worth re-measuring once there are people to watch.
