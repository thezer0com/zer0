# zer0-core

The pure reducer: an `Action` goes in, state changes, `EngineCommand`s come out. The core does not know what a `WKWebView` is, which is why behaviour is tested here without opening a window.

- No Apple, AppKit, UIKit, or WebKit type crosses this boundary. If a change needs a UI type to compile, the change is in the wrong crate.
- No `default:` or `_ =>` arm in a match over `Action` or `EngineCommand`. A new variant breaks the build until it earns behaviour — that break is the rule working, not friction to smooth over.
- Treat every boundary as hostile: disk, network, extensions, MCP servers, and the config someone hand-edited. Parse, validate, refuse.
- Refuse rather than repair, and fail closed. When a caller names something that does not exist, say so; fall back only when the thing was incidental to what they asked for. A repair that guesses is a bug with a delay on it.
- Ephemeral spaces persist nothing. `StorableSession` has no field for an ephemeral space's pages — the type is the guarantee, a comment would only be a wish.
- Tests cover behaviour, not pixels. Focus, order and selection are behaviour.
- One door per rule: put the rule where every caller converges. If no such place exists, making one is the work.
