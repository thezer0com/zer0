# linux/

The GTK host: a Rust shell that carries out the core's commands on WebKitGTK.

- The core is consumed as a crate (`zer0-core`, path dependency). There is no binding layer to write and none to generate — Rust calls Rust.
- The vocabulary is the core's: `Action` in, `EngineCommand` out, through `zer0_core::dispatch`. This shell invents no command types and extends no enums; a command the core does not emit does not exist here.
- Tokens come from `design/tokens.toml` like every other shell (ADR-0117). `src/tokens.rs` parses; it does not invent values.
- Decisions — ranking, keymap, lifecycle, what is stored — live in the core. This shell owns GTK, windowing, and platform spelling only.
