//! Text on disk to [`Config`], and a line number for everything refused.
//!
//! Walked as a document rather than deserialised into structs, and the reason
//! is the one thing a person needs when their config stops working: **where**.
//! A deserialiser reports "invalid value for field `kind`"; a document walk
//! reports "line 41, column 8", because it still has the span the value was
//! read from. That difference is worth the extra code.
//!
//! Two levels of refusal, following ADR-0024:
//!
//! - **The file is not TOML.** Nothing is loaded. The caller keeps whatever it
//!   had, which is what makes an editor's half-written save harmless.
//! - **One entry is wrong.** That entry is dropped, everything else loads, and
//!   a diagnostic names the line. Losing one provider must not cost the other
//!   four, and it must not cost the MCP servers underneath them.
//!
//! Nothing is ever guessed. An unreadable `kind` does not become
//! `openai-compatible`, an unreadable `enabled` does not become `true`. A key
//! that is *absent* has a documented default; a key that is *present and wrong*
//! takes its entry down.

use std::ops::Range;

use toml_edit::{Document, Item, Table, Value};

use super::{
    Config, ConfigDiagnostic, EnvVar, McpServerConfig, ParsedConfig, ProviderConfig, ProviderKind,
    SecretEnvVar, TransportKind, looks_like_a_secret,
};

const ROOT_KEYS: &[&str] = &["chat", "provider", "mcp_server"];
const CHAT_KEYS: &[&str] = &["default_provider"];
const PROVIDER_KEYS: &[&str] = &[
    "id",
    "name",
    "kind",
    "base_url",
    "credential",
    "models",
    "default_model",
    "enabled",
];
const MCP_KEYS: &[&str] = &[
    "id",
    "name",
    "transport",
    "command",
    "args",
    "env",
    "secret_env",
    "url",
    "credential",
    "enabled",
];

/// What `credential` is for, said the same way everywhere it is said.
const CREDENTIAL_IS_A_NAME: &str = "`credential` names a Keychain entry, it is not the key itself. \
     Put the key in the Keychain and write its name here — otherwise it ends up \
     in this file, and this file is meant to be committed.";

/// Read the whole file.
///
/// `Err` is a file that is not TOML at all, and its diagnostic already carries
/// the line `toml_edit` pointed at. `Ok` is a configuration plus everything
/// that had to be left out to produce it — an empty file gives
/// [`Config::default`] and no diagnostics, because a browser nobody has
/// configured yet is not a browser in trouble.
pub fn parse(text: &str) -> Result<ParsedConfig, ConfigDiagnostic> {
    let document = Document::parse(text).map_err(|error| {
        let (line, column) = match error.span() {
            Some(span) => position(text, span.start),
            None => (0, 0),
        };
        ConfigDiagnostic::error(line, column, error.message().to_string())
    })?;

    let mut reader = Reader {
        text,
        diagnostics: Vec::new(),
    };
    let root = document.as_table();
    reader.reject_unknown_keys(root, ROOT_KEYS, "the file");

    let default_provider = match root.get("chat") {
        None => None,
        Some(Item::Table(chat)) => {
            reader.reject_unknown_keys(chat, CHAT_KEYS, "[chat]");
            reader.string(chat, "default_provider")
        }
        Some(other) => {
            reader.error(other.span(), "`chat` has to be a table, written `[chat]`.");
            None
        }
    };

    let providers = reader.entries(root, "provider", "[[provider]]", read_provider);
    let mcp_servers = reader.entries(root, "mcp_server", "[[mcp_server]]", read_mcp_server);

    let config = Config {
        default_provider,
        providers,
        mcp_servers,
    };
    reader.check_default_provider(&config, root);

    Ok(ParsedConfig {
        config,
        diagnostics: reader.diagnostics,
    })
}

/// Byte offset to a 1-based line and column.
///
/// The column counts characters rather than bytes, because it is going in front
/// of a person looking at an editor's status bar and their editor counts
/// characters too.
fn position(text: &str, offset: usize) -> (u32, u32) {
    let offset = offset.min(text.len());
    let upto = &text[..offset];
    let line = upto.matches('\n').count() + 1;
    let line_start = upto.rfind('\n').map_or(0, |i| i + 1);
    let column = text[line_start..offset].chars().count() + 1;
    (line as u32, column as u32)
}

struct Reader<'a> {
    text: &'a str,
    diagnostics: Vec<ConfigDiagnostic>,
}

impl<'a> Reader<'a> {
    fn at(&self, span: Option<Range<usize>>) -> (u32, u32) {
        span.map_or((0, 0), |s| position(self.text, s.start))
    }

    fn error(&mut self, span: Option<Range<usize>>, message: impl Into<String>) {
        let (line, column) = self.at(span);
        self.diagnostics
            .push(ConfigDiagnostic::error(line, column, message));
    }

    fn warn(&mut self, span: Option<Range<usize>>, message: impl Into<String>) {
        let (line, column) = self.at(span);
        self.diagnostics
            .push(ConfigDiagnostic::warning(line, column, message));
    }

    /// Where a key was written, preferred over where its value was: a person
    /// looking for `credentail` wants the cursor on the typo.
    fn key_span(&self, table: &Table, key: &str) -> Option<Range<usize>> {
        table
            .key(key)
            .and_then(toml_edit::Key::span)
            .or_else(|| table.get(key).and_then(Item::span))
    }

    /// A misspelt key is a setting that silently does nothing, which is the
    /// worst way for a config to fail: everything looks right and nothing
    /// happens. A warning rather than an error, because the rest of the entry
    /// is perfectly good and refusing it would turn a typo into a lost provider.
    fn reject_unknown_keys(&mut self, table: &Table, known: &[&str], what: &str) {
        for (key, _) in table.iter() {
            if !known.contains(&key) {
                let span = self.key_span(table, key);
                self.warn(
                    span,
                    format!("`{key}` is not something zer0 reads in {what}, so it does nothing."),
                );
            }
        }
    }

    /// `None` for absent. A present non-string is reported and treated as
    /// absent, never coerced.
    fn string(&mut self, table: &Table, key: &str) -> Option<String> {
        match table.get(key) {
            None => None,
            Some(item) => match item.as_str() {
                Some(value) => Some(value.to_string()),
                None => {
                    let span = self.key_span(table, key);
                    self.error(span, format!("`{key}` has to be text in quotes."));
                    None
                }
            },
        }
    }

    fn bool_or(&mut self, table: &Table, key: &str, fallback: bool) -> bool {
        match table.get(key) {
            None => fallback,
            Some(item) => match item.as_bool() {
                Some(value) => value,
                None => {
                    let span = self.key_span(table, key);
                    self.error(span, format!("`{key}` has to be `true` or `false`."));
                    fallback
                }
            },
        }
    }

    fn string_array(&mut self, table: &Table, key: &str) -> Vec<String> {
        let Some(item) = table.get(key) else {
            return Vec::new();
        };
        let Some(array) = item.as_array() else {
            let span = self.key_span(table, key);
            self.error(span, format!("`{key}` has to be a list, written `[…]`."));
            return Vec::new();
        };
        let mut values = Vec::new();
        for entry in array.iter() {
            match entry.as_str() {
                Some(value) => values.push(value.to_string()),
                None => self.error(
                    entry.span(),
                    format!("every entry in `{key}` has to be text in quotes."),
                ),
            }
        }
        values
    }

    /// A `credential` value, refused when it looks like the credential itself.
    ///
    /// The one place a key can reach this file, and the one place it is caught.
    /// `Err(())` means the entry it belongs to is dropped — see the note in
    /// [`super`] on why the entry goes rather than just the field.
    fn credential(&mut self, table: &Table, key: &str) -> Result<Option<String>, ()> {
        let Some(value) = self.string(table, key) else {
            return Ok(None);
        };
        if looks_like_a_secret(&value) {
            let span = self.key_span(table, key);
            self.error(span, CREDENTIAL_IS_A_NAME);
            return Err(());
        }
        if value.trim().is_empty() {
            let span = self.key_span(table, key);
            self.error(
                span,
                format!("`{key}` is empty. Remove it, or name an entry."),
            );
            return Err(());
        }
        Ok(Some(value))
    }

    /// Read every `[[name]]` block, dropping the ones that do not survive
    /// `read` and the ones whose id repeats.
    fn entries<T: Entry>(
        &mut self,
        root: &Table,
        name: &str,
        what: &str,
        read: fn(&mut Reader<'a>, &Table) -> Option<T>,
    ) -> Vec<T> {
        let Some(item) = root.get(name) else {
            return Vec::new();
        };
        let Some(tables) = item.as_array_of_tables() else {
            let span = self.key_span(root, name);
            self.error(
                span,
                format!("`{name}` has to be written as {what} blocks."),
            );
            return Vec::new();
        };

        let mut entries: Vec<T> = Vec::new();
        for table in tables {
            let Some(entry) = read(self, table) else {
                continue;
            };
            if entries.iter().any(|existing| existing.id() == entry.id()) {
                let span = self.key_span(table, "id");
                self.error(
                    span,
                    format!(
                        "there is already a {what} with id `{}`. \
                         Ids have to be unique — this one is ignored.",
                        entry.id()
                    ),
                );
                continue;
            }
            entries.push(entry);
        }
        entries
    }

    /// A `default_provider` naming nothing is a warning, not an error.
    ///
    /// The browser carries on with the first enabled provider, so nothing is
    /// broken — but it is almost always a typo or a provider someone deleted
    /// and forgot about, and silently opening a different model than the file
    /// asks for is exactly the kind of surprise this project does not ship.
    fn check_default_provider(&mut self, config: &Config, root: &Table) {
        let Some(id) = &config.default_provider else {
            return;
        };
        if config.provider(id).is_some() {
            return;
        }
        let span = root
            .get("chat")
            .and_then(Item::as_table)
            .and_then(|chat| self.key_span(chat, "default_provider"));
        self.warn(
            span,
            format!(
                "`default_provider` names `{id}`, and no provider has that id. \
                 zer0 will use the first one that is switched on."
            ),
        );
    }
}

/// Just enough to spot a repeated id without writing the loop twice.
trait Entry {
    fn id(&self) -> &str;
}

impl Entry for ProviderConfig {
    fn id(&self) -> &str {
        &self.id
    }
}

impl Entry for McpServerConfig {
    fn id(&self) -> &str {
        &self.id
    }
}

/// An id, or nothing: an entry with no id cannot be pointed at, switched off,
/// or edited from settings, so there is nothing useful to keep.
fn read_id(reader: &mut Reader<'_>, table: &Table, what: &str) -> Option<String> {
    match reader.string(table, "id") {
        Some(id) if !id.trim().is_empty() => Some(id),
        Some(_) => {
            let span = reader.key_span(table, "id");
            reader.error(span, format!("{what} has an empty `id`."));
            None
        }
        None => {
            reader.error(
                table.span(),
                format!("{what} needs an `id` — a short name like `anthropic`."),
            );
            None
        }
    }
}

fn read_provider(reader: &mut Reader<'_>, table: &Table) -> Option<ProviderConfig> {
    reader.reject_unknown_keys(table, PROVIDER_KEYS, "a [[provider]] block");
    let id = read_id(reader, table, "a [[provider]] block")?;

    let kind = match reader.string(table, "kind") {
        None => {
            reader.error(
                table.span(),
                format!(
                    "provider `{id}` needs a `kind`. One of: {}.",
                    wire_list(ProviderKind::all().into_iter().map(ProviderKind::as_wire))
                ),
            );
            return None;
        }
        Some(raw) => match ProviderKind::from_wire(&raw) {
            Some(kind) => kind,
            None => {
                let span = reader.key_span(table, "kind");
                reader.error(
                    span,
                    format!(
                        "`{raw}` is not a provider kind zer0 knows. One of: {}.",
                        wire_list(ProviderKind::all().into_iter().map(ProviderKind::as_wire))
                    ),
                );
                return None;
            }
        },
    };

    let credential = reader.credential(table, "credential").ok()?;
    let base_url = reader.string(table, "base_url");

    // A kind that is only defined by its endpoint cannot be reached without
    // one, and "connection refused to https:///v1/chat/completions" is a worse
    // way to learn that than a line number.
    if kind.needs_base_url() && base_url.is_none() {
        reader.error(
            table.span(),
            format!(
                "provider `{id}` speaks `{}`, which many services do, so it needs a \
                 `base_url` saying which one.",
                kind.as_wire()
            ),
        );
        return None;
    }

    let name = reader.string(table, "name").unwrap_or_else(|| id.clone());
    let models = reader.string_array(table, "models");
    let default_model = reader.string(table, "default_model");

    if let Some(model) = &default_model
        && !models.is_empty()
        && !models.contains(model)
    {
        let span = reader.key_span(table, "default_model");
        reader.warn(
            span,
            format!("`{model}` is not in this provider's `models`, so it will not be offered."),
        );
    }

    Some(ProviderConfig {
        id,
        name,
        kind,
        base_url,
        credential,
        models,
        default_model,
        enabled: reader.bool_or(table, "enabled", true),
    })
}

fn read_mcp_server(reader: &mut Reader<'_>, table: &Table) -> Option<McpServerConfig> {
    reader.reject_unknown_keys(table, MCP_KEYS, "an [[mcp_server]] block");
    let id = read_id(reader, table, "an [[mcp_server]] block")?;

    let transport = match reader.string(table, "transport") {
        None => {
            reader.error(
                table.span(),
                format!(
                    "MCP server `{id}` needs a `transport`. One of: {}.",
                    wire_list(TransportKind::all().into_iter().map(TransportKind::as_wire))
                ),
            );
            return None;
        }
        Some(raw) => match TransportKind::from_wire(&raw) {
            Some(transport) => transport,
            None => {
                let span = reader.key_span(table, "transport");
                reader.error(
                    span,
                    format!(
                        "`{raw}` is not a transport zer0 knows. One of: {}.",
                        wire_list(TransportKind::all().into_iter().map(TransportKind::as_wire))
                    ),
                );
                return None;
            }
        },
    };

    let credential = reader.credential(table, "credential").ok()?;
    let command = reader.string(table, "command");
    let url = reader.string(table, "url");

    // Each transport needs exactly the one thing that makes it reachable.
    // Refused here rather than at connect time, because a server that silently
    // never starts is indistinguishable from one that has no tools.
    match transport {
        TransportKind::Stdio if command.is_none() => {
            reader.error(
                table.span(),
                format!("MCP server `{id}` is `stdio`, so it needs a `command` to run."),
            );
            return None;
        }
        TransportKind::Http if url.is_none() => {
            reader.error(
                table.span(),
                format!("MCP server `{id}` is `http`, so it needs a `url`."),
            );
            return None;
        }
        TransportKind::Stdio | TransportKind::Http => {}
    }

    let name = reader.string(table, "name").unwrap_or_else(|| id.clone());
    let args = reader.string_array(table, "args");
    let env = read_env(reader, table, &id);
    let secret_env = read_secret_env(reader, table, &id);

    Some(McpServerConfig {
        id,
        name,
        transport,
        command,
        args,
        env,
        secret_env,
        url,
        credential,
        enabled: reader.bool_or(table, "enabled", true),
    })
}

/// `[mcp_server.env]`, with the same refusal `credential` gets.
///
/// This is where the key would actually have gone. Almost every stdio MCP
/// server authenticates through an environment variable, so without this check
/// the careful work upstairs buys nothing: `GITHUB_TOKEN = "ghp_…"` sits in the
/// committed file and the design was decorative.
fn read_env(reader: &mut Reader<'_>, table: &Table, id: &str) -> Vec<EnvVar> {
    let mut vars = Vec::new();
    for (name, value, span) in pairs(reader, table, "env") {
        if looks_like_a_secret(&value) {
            reader.error(
                span,
                format!(
                    "`{name}` looks like a key, and `env` is written into this file. \
                     Move it to `[mcp_server.secret_env]` for `{id}`: \
                     `{name} = \"a-keychain-entry-name\"`."
                ),
            );
            continue;
        }
        vars.push(EnvVar { name, value });
    }
    vars
}

fn read_secret_env(reader: &mut Reader<'_>, table: &Table, id: &str) -> Vec<SecretEnvVar> {
    let mut vars = Vec::new();
    for (name, credential, span) in pairs(reader, table, "secret_env") {
        if looks_like_a_secret(&credential) {
            reader.error(span, CREDENTIAL_IS_A_NAME);
            continue;
        }
        if credential.trim().is_empty() {
            reader.error(
                span,
                format!("`{name}` in `secret_env` for `{id}` names no Keychain entry."),
            );
            continue;
        }
        vars.push(SecretEnvVar { name, credential });
    }
    vars
}

/// String pairs out of `key`, whether it was written as a `[table]` or inline
/// as `key = { … }`. Both are ordinary TOML and a person will use either.
fn pairs(
    reader: &mut Reader<'_>,
    table: &Table,
    key: &str,
) -> Vec<(String, String, Option<Range<usize>>)> {
    let Some(item) = table.get(key) else {
        return Vec::new();
    };

    let mut out = Vec::new();
    let mut take = |reader: &mut Reader<'_>, name: &str, value: Option<&Value>, span| match value
        .and_then(Value::as_str)
    {
        Some(text) => out.push((name.to_string(), text.to_string(), span)),
        None => reader.error(
            span,
            format!("`{name}` in `{key}` has to be text in quotes."),
        ),
    };

    // ADR-0031 draws its line at the type: a closed vocabulary this project
    // owns is listed out, an open set is not. `toml_edit::Item` is the second
    // kind twice over — it is somebody else's enum, and what it holds is
    // whatever a person typed into a file. Every shape that is not one of these
    // two is the same answer, and it is the answer ADR-0024 asks for: say what
    // was expected, point at the line, and read nothing.
    #[allow(
        clippy::wildcard_enum_match_arm,
        reason = "toml_edit::Item is a foreign enum over hostile input: everything that is \
                  not one of these two shapes is one error with one message (ADR-0024), and \
                  listing the rest would only be a longer way of writing the same arm"
    )]
    match item {
        Item::Table(inner) => {
            for (name, value) in inner.iter() {
                let span = inner
                    .key(name)
                    .and_then(toml_edit::Key::span)
                    .or_else(|| value.span());
                take(reader, name, value.as_value(), span);
            }
        }
        Item::Value(Value::InlineTable(inner)) => {
            for (name, value) in inner.iter() {
                take(reader, name, Some(value), value.span());
            }
        }
        other => {
            let span = reader.key_span(table, key).or_else(|| other.span());
            reader.error(
                span,
                format!("`{key}` has to be a table of name = \"value\"."),
            );
            return Vec::new();
        }
    }
    out
}

fn wire_list<'a>(values: impl Iterator<Item = &'a str>) -> String {
    values
        .map(|v| format!("`{v}`"))
        .collect::<Vec<_>>()
        .join(", ")
}
