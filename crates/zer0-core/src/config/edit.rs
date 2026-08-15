//! Changing the file from the settings window without rewriting it.
//!
//! A person who keeps this file in a repository has comments in it, an order
//! they chose, and blank lines where they wanted them. Serialising the model
//! back over the top would destroy all three the first time somebody clicked a
//! toggle, and the diff would be the whole file. Nobody would forgive that
//! twice, and most would not notice until after the commit.
//!
//! So edits are applied to the parsed document: `toml_edit` keeps every byte it
//! did not need to change, and switching a provider off is one line in
//! `git diff`. Keys we do not read are left exactly where they were — we warned
//! about them at load, and deleting somebody's text because we did not
//! recognise it is not ours to do.
//!
//! The other half of this file is the second half of the secrets boundary.
//! Reading refuses a key written into `credential` (see [`super::parse`]);
//! writing refuses one passed in from the settings window. Both directions,
//! because a rule enforced on one side of a round trip is not enforced.

use toml_edit::{Array, ArrayOfTables, DocumentMut, Item, Table, Value, value};

use super::{McpServerConfig, ProviderConfig, ProviderKind, TransportKind, looks_like_a_secret};

/// Why an edit was refused before it touched the document.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EditRefusal {
    /// Something that is meant to be the name of a credential is a credential.
    Secret { field: String },
    /// The file has `provider = "…"` where zer0 expects `[[provider]]`, so
    /// there is nowhere to put this. Rewriting it into the right shape would
    /// throw away whatever they meant by it.
    WrongShape { key: String },
    /// Nothing in the file has this id.
    NotFound { id: String },
}

impl EditRefusal {
    pub fn message(&self) -> String {
        match self {
            Self::Secret { field } => format!(
                "`{field}` is the name of a Keychain entry, not the key itself. \
                 zer0 will not write a key into a file that is meant to be committed."
            ),
            Self::WrongShape { key } => format!(
                "`{key}` in the config file is not in the shape zer0 writes. \
                 Fix it by hand and try again — zer0 will not reshape it and risk \
                 losing what is there."
            ),
            Self::NotFound { id } => format!("there is nothing in the config file with id `{id}`."),
        }
    }
}

type Refused<T> = Result<T, EditRefusal>;

/// Every value in a provider that has to be a name and not a key.
///
/// Called before anything is written. There is exactly one such field today;
/// it is a function so that adding a second one has an obvious home rather than
/// being remembered.
fn check_provider(provider: &ProviderConfig) -> Refused<()> {
    if let Some(credential) = &provider.credential
        && looks_like_a_secret(credential)
    {
        return Err(EditRefusal::Secret {
            field: "credential".to_string(),
        });
    }
    Ok(())
}

fn check_server(server: &McpServerConfig) -> Refused<()> {
    if let Some(credential) = &server.credential
        && looks_like_a_secret(credential)
    {
        return Err(EditRefusal::Secret {
            field: "credential".to_string(),
        });
    }
    for var in &server.env {
        if looks_like_a_secret(&var.value) {
            return Err(EditRefusal::Secret {
                field: format!("env.{}", var.name),
            });
        }
    }
    for var in &server.secret_env {
        if looks_like_a_secret(&var.credential) {
            return Err(EditRefusal::Secret {
                field: format!("secret_env.{}", var.name),
            });
        }
    }
    Ok(())
}

pub fn set_default_provider(document: &mut DocumentMut, id: Option<&str>) -> Refused<()> {
    match id {
        None => {
            if let Some(chat) = document.get_mut("chat").and_then(Item::as_table_mut) {
                chat.remove("default_provider");
            }
            Ok(())
        }
        Some(id) => {
            let chat = table_at(document, "chat")?;
            chat["default_provider"] = value(id);
            Ok(())
        }
    }
}

pub fn upsert_provider(document: &mut DocumentMut, provider: &ProviderConfig) -> Refused<()> {
    check_provider(provider)?;
    write_provider(entry_for(document, "provider", &provider.id)?, provider);
    Ok(())
}

pub fn upsert_mcp_server(document: &mut DocumentMut, server: &McpServerConfig) -> Refused<()> {
    check_server(server)?;
    let table = entry_for(document, "mcp_server", &server.id)?;
    write_server(table, server);
    Ok(())
}

pub fn remove_entry(document: &mut DocumentMut, key: &str, id: &str) -> Refused<()> {
    let tables = array_of_tables(document, key)?;
    let Some(index) = index_of(tables, id) else {
        return Err(EditRefusal::NotFound { id: id.to_string() });
    };
    tables.remove(index);
    if tables.is_empty() {
        document.remove(key);
    }
    Ok(())
}

/// Flip `enabled` without touching anything else in the block.
///
/// Separate from `upsert_*` because it is the edit that happens most, and going
/// through a whole record would rewrite every key in the block — turning a
/// one-line diff into a twelve-line one for a checkbox.
pub fn set_enabled(document: &mut DocumentMut, key: &str, id: &str, enabled: bool) -> Refused<()> {
    let tables = array_of_tables(document, key)?;
    let Some(index) = index_of(tables, id) else {
        return Err(EditRefusal::NotFound { id: id.to_string() });
    };
    let table = tables.get_mut(index).expect("index came from this array");
    if enabled {
        // The default is on, so writing `enabled = true` adds a line that says
        // nothing. Switching something back on should leave the file as it was
        // before it was switched off.
        table.remove("enabled");
    } else {
        table["enabled"] = value(false);
    }
    Ok(())
}

// MARK: - Document plumbing

fn table_at<'a>(document: &'a mut DocumentMut, key: &str) -> Refused<&'a mut Table> {
    if document.get(key).is_none() {
        let mut table = Table::new();
        table.set_implicit(false);
        document.insert(key, Item::Table(table));
    }
    document
        .get_mut(key)
        .and_then(Item::as_table_mut)
        .ok_or_else(|| EditRefusal::WrongShape {
            key: key.to_string(),
        })
}

fn array_of_tables<'a>(document: &'a mut DocumentMut, key: &str) -> Refused<&'a mut ArrayOfTables> {
    if document.get(key).is_none() {
        document.insert(key, Item::ArrayOfTables(ArrayOfTables::new()));
    }
    document
        .get_mut(key)
        .and_then(Item::as_array_of_tables_mut)
        .ok_or_else(|| EditRefusal::WrongShape {
            key: key.to_string(),
        })
}

fn index_of(tables: &ArrayOfTables, id: &str) -> Option<usize> {
    tables
        .iter()
        .position(|t| t.get("id").and_then(Item::as_str) == Some(id))
}

/// The existing block for `id`, or a new one appended at the end.
///
/// Appended rather than inserted anywhere clever: a new provider showing up at
/// the bottom of the file is what someone reading the diff expects, and it
/// keeps the order they arranged.
fn entry_for<'a>(document: &'a mut DocumentMut, key: &str, id: &str) -> Refused<&'a mut Table> {
    let tables = array_of_tables(document, key)?;
    let index = match index_of(tables, id) {
        Some(index) => index,
        None => {
            tables.push(Table::new());
            tables.len() - 1
        }
    };
    Ok(tables.get_mut(index).expect("index came from this array"))
}

fn write_provider(table: &mut Table, provider: &ProviderConfig) {
    table["id"] = value(&provider.id);
    // A name equal to the id is what the reader defaults to, so writing it
    // would be a line that carries no information.
    set_or_clear(
        table,
        "name",
        (provider.name != provider.id).then(|| value(&provider.name)),
    );
    table["kind"] = value(provider.kind.as_wire());
    set_or_clear(table, "base_url", provider.base_url.as_deref().map(value));
    set_or_clear(
        table,
        "credential",
        provider.credential.as_deref().map(value),
    );
    set_or_clear(
        table,
        "models",
        (!provider.models.is_empty()).then(|| string_array(&provider.models)),
    );
    set_or_clear(
        table,
        "default_model",
        provider.default_model.as_deref().map(value),
    );
    set_or_clear(table, "enabled", (!provider.enabled).then(|| value(false)));
}

fn write_server(table: &mut Table, server: &McpServerConfig) {
    table["id"] = value(&server.id);
    set_or_clear(
        table,
        "name",
        (server.name != server.id).then(|| value(&server.name)),
    );
    table["transport"] = value(server.transport.as_wire());

    // Only the fields the chosen transport uses. Leaving a stale `url` on a
    // server that now runs a command would be a line that reads as true and is
    // not, which is the thing ADR-0018 is about.
    let (command, args, url) = match server.transport {
        TransportKind::Stdio => (server.command.as_deref(), Some(&server.args), None),
        TransportKind::Http => (None, None, server.url.as_deref()),
    };
    set_or_clear(table, "command", command.map(value));
    set_or_clear(
        table,
        "args",
        args.filter(|a| !a.is_empty()).map(|a| string_array(a)),
    );
    set_or_clear(table, "url", url.map(value));
    set_or_clear(table, "credential", server.credential.as_deref().map(value));

    write_pairs(
        table,
        "env",
        server
            .env
            .iter()
            .map(|v| (v.name.as_str(), v.value.as_str())),
    );
    write_pairs(
        table,
        "secret_env",
        server
            .secret_env
            .iter()
            .map(|v| (v.name.as_str(), v.credential.as_str())),
    );

    set_or_clear(table, "enabled", (!server.enabled).then(|| value(false)));
}

/// Write a name-to-string block, keeping whichever shape the file already used.
///
/// Somebody who wrote `env = { A = "b" }` gets it back inline; somebody who
/// wrote `[mcp_server.env]` keeps the block. A new one is a block, because that
/// is the shape where adding a variable is one added line in the diff.
fn write_pairs<'a>(table: &mut Table, key: &str, pairs: impl Iterator<Item = (&'a str, &'a str)>) {
    let pairs: Vec<(&str, &str)> = pairs.collect();
    if pairs.is_empty() {
        table.remove(key);
        return;
    }

    let inline = matches!(table.get(key), Some(Item::Value(Value::InlineTable(_))));
    if inline {
        let mut inline_table = toml_edit::InlineTable::new();
        for (name, text) in pairs {
            inline_table.insert(name, text.into());
        }
        table[key] = Item::Value(Value::InlineTable(inline_table));
        return;
    }

    let mut inner = Table::new();
    inner.set_implicit(false);
    for (name, text) in pairs {
        inner[name] = value(text);
    }
    table[key] = Item::Table(inner);
}

/// Set a key, or take it out when there is nothing to say.
///
/// Clearing rather than writing an empty string matters for how the file reads:
/// `base_url = ""` looks like a setting somebody made, and an absent `base_url`
/// looks like the default, which is what it is.
fn set_or_clear(table: &mut Table, key: &str, item: Option<Item>) {
    match item {
        Some(item) => table[key] = item,
        None => {
            table.remove(key);
        }
    }
}

fn string_array(values: &[String]) -> Item {
    let mut array = Array::new();
    for entry in values {
        array.push(entry.as_str());
    }
    Item::Value(Value::Array(array))
}

impl ProviderKind {
    /// Guard against the wire spellings drifting from the enum: a round trip
    /// through the file has to come back as what went in.
    #[cfg(test)]
    pub(crate) fn round_trips(self) -> bool {
        Self::from_wire(self.as_wire()) == Some(self)
    }
}
