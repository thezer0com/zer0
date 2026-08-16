# ADR-0118: A host declares what it can do on the way in, and the core refuses what that host cannot run

- **Status:** Accepted
- **Date:** 2026-08-16
- **Lock:** `crates/zer0-core/src/ffi_tests.rs::a_host_that_declared_no_extension_runtime_is_refused_installation`, `crates/zer0-core/src/ffi_tests.rs::a_host_that_declared_an_extension_runtime_installs`

## Context

zer0 is going multi-platform — iOS, Android, Linux, Windows are the direction,
and ADR-0116 already treats that as the premise behind an icon budget. ADR-0086
said of a Linux host that it "inherits the ranking and not the gaps": the gaps
were WebKit's. What the audit of the core/shell boundary found is the gap that
*is* ours: **the core never asks what the host can do.**

`install_extension` is the worked defect. On a host with no extension runtime —
a Linux shell with no `WKWebExtensionController`, an embedded core in a test
harness — the call succeeds: the package unpacks, the directory appears,
`installed_extensions` grows a row, the Settings screen draws it, and nothing
runs. It is success-shaped silence, and it is ADR-0086's reporting class one
boundary up: not an optional delegate nobody wrote, but a capability nobody
asked about, discovered one defect at a time by whatever went looking for the
extension that was promised.

The vocabulary for the fix already exists in this record. ADR-0086: the
unimplemented surface is enumerated, not discovered. ADR-0103: a *cannot* that
is really ours is **answered with a reason** rather than stated, and never
wearing silence. This decision is those two rules applied to the host boundary.

Why one capability and not a list: `extension_runtime` is the only capability
with a consumer in the code today. Nothing else branches on what the host can
do — native messaging has its own door (`set_application_support_directory`,
refusing everything until set, ADR-0105), and it already works the way this
record generalises.

## Decision

**The host declares its capabilities once, at the door, and the core refuses
fail-closed whatever the declaration left out.**

`HostCapabilities` is a UniFFI record in `protocol.rs` — the wire where the
host reports facts — carried by both constructors, `Zer0::open` and
`Zer0::in_memory`. It is a constructor parameter and deliberately not a setter:

- `set_ui_locale` and `set_application_support_directory` are setters because
  they carry optional facts a subsystem *may* consult.
- A capability is a fact a subsystem *hangs on*, and a host that forgets a
  setter discovers the omission at runtime, one defect at a time — exactly the
  discovery ADR-0086 exists to stop. A parameter makes forgetting a **compile
  error on every host**, the same day, at the place the host is being built.

The record is one field wide:

- `extension_runtime: bool` — because `install_extension` is the one consumer.
  A field with no consumer is a switch that changes nothing: the drift ADR-0103
  names for `ZER0_PROVIDES`, wearing a struct. A capability joins the record in
  the same commit as the behaviour that asks about it, or not at all. This is
  the growth rule, and it is the reason there is no `data_stores`, no
  `native_messaging`, no `notifications` field here today — each arrives with
  its consumer or arrives as a dead number.

`Default` is not derived, on purpose. `..Default::default()` would let a new
field arrive already answered, and the whole point of the type is that every
host says every field out loud.

### The one enforcement: `install_extension`

When `extension_runtime` is false, the call refuses **before anything touches
the disk** — no directory is created, no bytes are parsed, `installed_extensions`
stays empty. The sentence is `Zer0Error::Extension` carrying:

> this build of zer0 cannot run extensions — the host declared no extension
> runtime

which is ADR-0103's shape: *cannot*, then the reason, with the blame on the
boundary that actually decided it. The existing error variant is reused because
the refusal *is* the install's outcome for the caller, and the sentence carries
the distinction a second variant would have bought; a `HostRefused` case nobody
switches on differently would be a second spelling of one fact.

Reads stay ungated. A host without a runtime can still ask where the store
lives, what a package would request, and can uninstall: those are questions and
removals, not runs. The macOS shell declares `extension_runtime: true` at both
doors (`BrowserModel.init`), in the one place the shell states what it is.

## Consequences

**The FFI surface breaks**, and every constructor call site now states its
facts. That is the point: nine Swift test call sites and the shell's two were
touched by this change, and each one had to say something. The tests that never
install declare `false` — the honest answer, and a standing exercise of the
fact that reading the store's hosts and building consent requests do not need a
runtime.

**A new host gets refusals by default.** A Linux shell that links the core
tomorrow gets a browser that opens, browses, saves — and answers "cannot run
extensions" with the reason the moment somebody tries. That is the honest state
of that host, stated in one sentence, instead of a Settings row that installs
and never runs. Turning it on is one line in that host's own door, which is the
whole ceremony.

**The declaration is per-construction, not per-machine.** Nothing stops one
shell from opening two cores with different declarations; nothing needs to,
because the core that was told less simply does less.

**What hurts:** the capability is a bool, so "cannot run extensions" cannot
distinguish "no runtime yet" from "no runtime ever". ADR-0103 spent a whole
record splitting that difference for permissions, and this one collapses it
back — because at the host boundary the distinction is a fact about a *host
that does not exist yet*, and writing its sentences now would be deciding its
position for it. The host that arrives will word its own truth, and if it needs
a field richer than a bool, that is the revisit.

## How this regresses

**"The gate is dead weight — install works fine on my machine."** The mac host
declares true, so the check reads as code that never fires, and the obvious
tidy-up is to delete it.
`a_host_that_declared_no_extension_runtime_is_refused_installation` goes red
the same day, and asserts both halves: the sentence says *cannot* **and** names
the reason, and nothing is left on disk to draw a row from. A gate that refused
but still unpacked would pass a test that only checked the message.

**"Somebody flips the default to true so a new host 'just works'."** Same test,
same red. There is no default to flip — `Default` is not derived — so the
regression arrives as a host passing `true` it cannot honour, which is a lie
told in that host's source, at its own door, where its own review sees it.

**"The gate starts refusing everything."** A check that never lets anything
through would pass the refusal test alone, which is why the lock names two
tests: `a_host_that_declared_an_extension_runtime_installs` installs the same
genuinely signed package through the same door with the capability declared,
and asserts the row exists afterwards.

**"A second field arrives with no consumer."** No test can catch a dead field —
the compiler is happy, the record just grows. The fence is this record's growth
rule, the same way ADR-0116's budget cannot stop a constant being edited. A
field nobody reads is a number somebody believes.

**"The check moves to the call site that complained."** Someone hits the
refusal during bring-up, finds the gate in `ffi.rs`, and adds a parameter or a
boolean to bypass it for "just this host". That is the declaration wearing a
second door, and the fix is one line in that host's constructor instead —
which is cheaper than the bypass and reviewable in one place.

## When to revisit

- **When a host without an extension runtime is actually built.** Its first
  line past the constructor is the declaration, and the wording of what its
  person sees on refusal ("this build of zer0 cannot run extensions") is then
  a claim about a real product rather than a placeholder — re-measure it
  against a real screen.
- **When a second capability gains a consumer.** The field joins the record in
  the same commit as the behaviour that consults it. If two arrive close
  together, check whether the consumer is really the core's question or the
  host's — ADR-0105's door is the shape for facts that stay optional.
- **When a capability needs to be more than a bool** — versioned runtimes,
  partial support, "background workers but no popups". A richer field is a new
  decision about what the core is allowed to refuse on, not a refactor.
