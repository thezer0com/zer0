# ADR-0048: Configuration is a TOML file under `~/.config`, and a secret only ever lives in the Keychain

- **Status:** Accepted
- **Date:** 2026-05-18
- **Lock:** `crates/zer0-core/src/config/config_tests.rs::a_secret_can_never_reach_the_file_however_the_settings_window_asks`, `apple/Tests/Zer0ShellTests/ConfigTests.swift::ConfigTests/aSecretNeverReachesTheConfigFile`, `crates/zer0-core/src/config/config_tests.rs::a_key_written_into_credential_by_hand_is_refused_and_told_where_it_goes`, `crates/zer0-core/src/config/config_tests.rs::a_key_in_an_mcp_env_var_is_refused_and_points_at_secret_env`, `crates/zer0-core/src/config/config_tests.rs::the_path_prefers_an_explicit_override_then_xdg_then_home`, `crates/zer0-core/src/config/config_tests.rs::writing_through_a_symlinked_file_keeps_the_link_and_updates_the_checkout`, `crates/zer0-core/src/config/config_tests.rs::a_broken_file_does_not_replace_the_configuration_that_was_working`, `crates/zer0-core/src/config/config_tests.rs::a_settings_change_is_refused_while_the_file_has_a_syntax_error`, `crates/zer0-core/src/config/config_tests.rs::a_config_cloned_onto_a_new_machine_loads_and_says_which_keys_are_missing`, `apple/Tests/Zer0ShellTests/ConfigTests.swift::ConfigTests/aMissingCredentialIsNamedRatherThanEmpty`

## Context

Chat and MCP bring the first settings `zer0` has that somebody would want
identical on a second Mac: which LLM providers exist, which models they offer,
which MCP servers to start. Two requirements arrived with them, and they pull
against each other.

**Everything has to be configurable by clicking**, by somebody who will never
open a text editor to configure a browser.

**Everything has to be saved in a file**, so somebody who lives in a dotfiles
repository can put their browser's configuration in it and have the same
browser on every machine.

The second requirement is the dangerous one, because the thing that most wants
to be in that file is an API key. A file designed to be committed, with a
credential in it, is the single most common way credentials leak — and it does
not leak after a long chain of mistakes, it leaks on the first `git push`.

`session.sqlite` already exists and already holds preferences, keybindings and
routing rules. So there was a third question: whether this is a second store or
an extension of the first, and where the line goes.

## Decision

### TOML, in `~/.config/zer0/config.toml`

**TOML**, because the file has to be pleasant to hand-edit and to diff, and
those two constraints eliminate almost everything:

- **JSON** has no comments. A configuration file that cannot be documented in
  place is one that has to be documented somewhere else, and that copy is wrong
  within a month.
- **YAML** looks friendlier and is not. Indentation is load-bearing, so a
  misplaced space is a semantic change; and its type coercion turns `no` into
  `false` and `1.10` into a number that is not `1.10`. For a file people edit by
  hand under no supervision, both are unacceptable.
- **TOML** has comments, no significant whitespace, unambiguous types, and — the
  reason it wins rather than merely qualifies — `[[provider]]` gives one block
  per entry, so adding a provider is a pure addition in `git diff` and switching
  one off is a single line.

It is read with `toml_edit` walked as a **document**, not deserialised into
structs. A deserialiser reports "invalid value for field `kind`". A document
walk reports **line 41, column 8**, because it still holds the span the value
came from. That difference is the entire user experience of a broken config, and
it is worth the extra code.

**`~/.config/zer0/config.toml`**, honouring `XDG_CONFIG_HOME`, and *not*
`~/Library/Application Support/<bundle id>/` where `session.sqlite` lives
(per-channel under the bundle id; ADR-0109).

Application Support is right for `session.sqlite`: a database this app owns,
that nobody opens by hand. This file is the opposite kind of thing, and the
convention that applies to opaque state does not apply to it:

- **Nobody symlinks into `~/Library/Application Support`.** Every dotfiles tool
  in use — `stow`, `chezmoi`, `yadm`, home-manager — targets `~/.config`.
  Putting a file whose purpose is version control somewhere no version-control
  workflow reaches would be choosing the convention over the reason for it.
- **`~/Library` is hidden in Finder.** A non-technical person told "your
  settings are in a file" has to be able to find the file.
- **Application Support is what cleanup tools and migration assistants sweep.**
- The applications that have a file like this one — `git`, `ssh`, `nvim`,
  `ghostty`, `zed`, `wezterm` — put it under `~/.config` **on macOS**, because
  their users asked them to. That is the relevant precedent.

`ZER0_CONFIG` overrides everything, for a second profile and for tests.

### The file declares what exists; the session store records what happened

That sentence is the line, and it is meant to be usable by the next person
adding a setting.

| In the file | In `session.sqlite` |
| --- | --- |
| which providers exist, and their models | which provider this chat is using |
| which MCP servers to start | which tools were approved, and when |
| `default_provider` — a standing preference | the conversation itself |
| the name of each credential | tabs, spaces, history, downloads, icons |

`default_provider` is in the file because it is a standing preference somebody
would want on both machines. Which provider a particular chat is currently on is
not — that is this machine's afternoon.

`ProviderKind` in the file is close to `provider::WireFormat` and deliberately
not the same enum. `WireFormat` is about the shape on the wire, and by that
measure `openai` and `openai-compatible` are one thing. In the file they are
two, because `openai-compatible` is the one kind that *has to* carry a
`base_url` — nothing else can say which service it is — and because somebody
reading their own config wants the line to say which of the two they meant.
Both spellings of each are accepted on the way in, so a config written against
either vocabulary loads rather than dropping a provider over a synonym.

**Nothing moves out of the session store.** Preferences, keybindings and routing
rules stay where they are, and the file does not mention them. That is a
deliberate stopping point rather than the end state: by the rule above, a keymap
is exactly the sort of thing somebody wants identical on a second machine, and
it probably belongs here eventually. But moving it is a migration of live
settings, touching code three other people are inside today, in service of a
feature that does not need it. Doing it now would be paying a real risk for a
hypothetical benefit. There is no duplication and no ambiguity in the meantime:
a setting is in exactly one of the two stores, and which one is answered by
which store it is already in.

### A secret is never in the file, and the file has nowhere to put one

The file names a credential; the value is in the Keychain.

```toml
[[provider]]
id = "anthropic"
kind = "anthropic"
credential = "anthropic"      # a name. The key is in the Keychain.
```

The guarantee is **structural**, following `storable.rs` and ADR-0028: *a value
absent from the type cannot be written by mistake*, which is stronger than a
rule saying not to write it.

- No type in `zer0-core` has a field that can hold a credential value.
- No call on `Zer0Config` accepts one or returns one. The shell tells the core
  which credential *names* resolved; that is the whole traffic.
- The Keychain is reached only from `SecretStore` in the shell, and the one
  function that takes a secret writes to the Keychain and has no path to the
  file.

So "a key must not be written to the config file" is not a promise the writer
keeps. It is a sentence the writer cannot express.

One hole remains, because `credential` is a `String` and a person can type a key
into it. It is closed on both sides: `looks_like_a_secret` refuses a
key-shaped value **on the way in** from the file and **on the way out** from
the settings window, and says where the value belongs. The same check covers
`[mcp_server.env]`, which is where the key would actually have gone — nearly
every stdio MCP server authenticates through an environment variable, so without
`secret_env` the whole design would have been decorative.

**A named credential that is not on this machine is a state, not a failure.**
`Readiness::MissingCredential { credential }` carries the name, so the interface
says *"add a key named `anthropic`"* rather than *"not configured"*. This is the
normal state five minutes after cloning a dotfiles repository onto a new Mac —
every provider described perfectly, none of them with a key — and it is a to-do
list, not a fault. The browser stays useful: a chat opens on the first provider
that *is* usable rather than on a spinner and a 401.

The Keychain item is a generic password under service `zer0`, account = the
credential name, with a label and a comment naming the config file that refers
to it, so an entry found two years later can be traced. `kSecUseDataProtectionKeychain`
is deliberately **off**: it derives access from the `application-identifier`
entitlement, so an unsigned build — which is how `zer0` is built and run every
day — gets `errSecMissingEntitlement` and cannot store anything at all.

### Absence is the first-run state, and a broken file never replaces a good one

No file is normal and produces defaults with no diagnostics. **Opening never
creates one** — writing into `~/.config` uninvited puts a file in somebody's
dotfiles repository that they did not add.

Reloading happens three ways, because no one of them is enough: a watch on the
file, a watch on its **directory** (because `vim`, `git checkout` and every
atomic writer replace by rename, leaving an inode watch pointing at nothing),
and a re-read when the app comes back to the front, which costs one `stat` and
covers network mounts and a `git pull` that happened while zer0 was behind
another window. Events are coalesced over 250ms, because a save is a truncate
followed by a write and both fire.

Two refusals fall out of ADR-0017 and ADR-0024:

- **A file that does not parse never replaces one that did.** Catching an editor
  mid-save is ordinary, not rare; the last configuration that parsed stays in
  force and what changes is the diagnostics.
- **We never write over a file we could not read.** With a typo on line 3, a
  settings click must not rewrite from a model that never saw lines 4 to 90.

Writes are format-preserving and go through the parsed document, so comments,
order and blank lines survive — switching a provider off is one line in
`git diff`. And the write resolves symlinks first: the ordinary
write-a-temp-file-and-rename recipe would replace `~/.config/zer0/config.toml`
with a regular file and **orphan the dotfiles checkout it pointed at**, which is
silent until `git status` shows nothing and the next machine gets an old config.

## Consequences

**What hurts:**

- **Two stores instead of one**, with a line somebody has to learn. A setting
  added to the wrong one is not caught by anything; the table above is the only
  defence, and tables in ADRs are read less often than code.
- **The line is drawn where it is convenient, not where the rule points.**
  Keybindings satisfy "identical on a second machine" and are in the session
  store anyway. Anyone reading the rule and then the code will find the
  inconsistency, and the honest answer is scheduling, not principle.
- **`looks_like_a_secret` is a heuristic and will be wrong.** A credential
  actually named `sk-personal` is refused, and the fix — rename it — is not
  discoverable from the error. That is deliberately the direction the errors
  lean: a false positive costs a rename, a false negative is a key in a public
  repository.
- **A key in `[mcp_server.env]` is refused but not removed.** We warn; the bytes
  stay in the file, because silently deleting somebody's text is worse. So the
  window between pasting a key and reading the diagnostic is a window where the
  key is on disk and committable.
- **The unsigned-build decision has a cost.** Without the data-protection
  keychain, the app is in the legacy file keychain, which prompts whenever the
  signature changes — every rebuild during development.
- **The settings window and an editor can disagree for up to 250ms**, and for
  longer if a watch does not fire and the app is not focused.

**What this buys:** a browser configuration that can be committed, reviewed and
copied between machines, where the worst thing a `git push` can leak is the list
of services somebody uses — and never a key.

## How this regresses

Someone adds an `api_key` field to `ProviderConfig` because a provider needs a
second credential and a name felt like indirection. It works. Six weeks later
somebody pushes their dotfiles to a public repository with their Anthropic key
in it, finds out from an automated scan, and has to rotate every key the file
mentions. Nothing in the interface ever looked wrong.

The quieter version: somebody replaces the format-preserving writer with
"serialise the model back out", because it is less code. The first person who
clicks a toggle in Settings gets a diff that is their entire config file with
every comment gone. They do not notice until after the commit, and the reason
they wrote the comments is gone with them.

The third: somebody makes the writer create `~/.config/zer0/config.toml` at
launch so there is always something to write to. Now every `zer0` user with a
dotfiles repository has an untracked file appear in `git status`, and the ones
who `git add .` commit a file they never chose to keep.

And the one that costs the most and shows the least: somebody replaces the
symlink-resolving write with `fs::write` or a plain temp-and-rename, because it
is three lines instead of thirty. Everything keeps working. The dotfiles
checkout silently stops receiving changes, and it is discovered on the next new
machine, which comes up with a configuration from months ago.

## When to revisit

- **When the app has a signing identity in the ordinary build.** Then
  `kSecUseDataProtectionKeychain` should go on: it removes ACL prompts, survives
  re-signing, and is the supported path. It is one constant and the tests do not
  care.
- **When keybindings or preferences are next touched for another reason.** That
  is the moment moving them into the file is cheap, and the rule already says
  they belong there. Until then, moving them buys nothing.
- **When a second platform arrives.** `~/.config` and `XDG_CONFIG_HOME` already
  work on Linux; `SecretStore` will need an implementation over the Secret
  Service API, and if that turns out not to fit the protocol's shape, the seam
  is what should change, not the file.
- **When somebody hits a legitimate credential name that
  `looks_like_a_secret` refuses.** One report is a rename. Three are a signal
  that the heuristic should become a warning plus an explicit
  `credential_is_literally_this_name` escape hatch — but not before, because
  every loosening of this check is paid for in leaked keys.
- **When Gemini becomes configurable.** `provider/gemini.rs` exists and there is
  no `kind` that reaches it, so today a Gemini provider cannot be written down.
  Adding the variant is additive and correctly breaks every switch over
  `ProviderKind` until each earns behaviour (ADR-0031) — which is why it is a
  deliberate change rather than one made in passing.
- **When the file grows past what a person will read.** The format is fine at
  fifty lines and questionable at five hundred. An `include` directive, or a
  `conf.d` directory, is the next decision — and it is a new ADR, because it
  changes what "the config file" means.
