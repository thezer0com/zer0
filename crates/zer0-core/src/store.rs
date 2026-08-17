//! Session persistence, in SQLite.
//!
//! The [`SessionStore`] implementation the browser ships with. One file holds
//! everything a restart needs to look like nothing happened: spaces, tabs,
//! history and routing rules.
//!
//! Writes go through a single transaction, so a crash mid-save leaves the
//! previous session intact rather than half of two. That is not a detail of
//! this file: it is the atomicity the trait requires, and a transaction is
//! only how this backend gets it.

use std::collections::HashMap;
use std::path::Path;

use rusqlite::{Connection, OptionalExtension, params};

use crate::bookmarks::{Bookmark, BookmarkId, Bookmarks};
use crate::certificates::TrustExceptions;
use crate::chat::{
    Chat, Conversation, ConversationId, ConversationScope, Message, MessageId, MessageRole,
    MessageState, PageAnchor, PageReference, ToolConsent, ToolGrant,
};
use crate::downloads::{Download, DownloadId, DownloadState, Downloads};
use crate::extension_permissions::{ConsentDecision, ExtensionConsent, PermissionKind};
use crate::extension_pins::{ExtensionPin, ExtensionPins};
use crate::history::{History, HistoryEntry};
use crate::http_auth::HttpAuth;
use crate::icons::Icons;
use crate::mcp::{ApprovedShape, McpRegistry};
use crate::model::{
    Browser, Space, SpaceId, SpaceProfile, Split, Tab, TabId, TabKind, Window, WindowId,
    clamp_split_ratio,
};
use crate::native_messaging::{NativeHostDecision, NativeHostLedger};
use crate::navigation_state::NavigationStates;
use crate::page_dialogs::PageDialogs;
use crate::preferences::{Preferences, StartupBehaviour, ThemePreference};
use crate::routing::{Route, RoutePattern, RoutingTable};
use crate::session::Session;
use crate::session_store::SessionStore;
use crate::shortcuts::{Binding, Chord, Key, Keymap, Modifiers, UiCommand};
use crate::site_permissions::{SiteCapability, SiteGrant, SitePermissions};
use crate::storable::{
    StorableDownloadState, StorableMessage, StorableMessageState, StorableSession,
};

// Re-exported because the icon store (ADR-0044) is SQLite too and fails the
// same ways, so it reads the error from beside the connection it uses rather
// than from a trait it does not implement.
pub use crate::session_store::{Result, StoreError};

/// Anything rusqlite refuses is this backend refusing.
///
/// Written out rather than derived with `#[from]` on the enum, so that
/// [`StoreError`] — which belongs to the abstraction — never has to name
/// SQLite. The driver's own message is carried through: it is the only part of
/// the failure that says anything useful, and it ends up in front of a person.
impl From<rusqlite::Error> for StoreError {
    fn from(error: rusqlite::Error) -> Self {
        StoreError::Backend(error.to_string())
    }
}

/// Bumped whenever the schema changes shape. 2 added `downloads`, 3 added the
/// extension consent ledger, 4 added `splits`, 5 added the conversations and
/// `tool_consent`, 6 added `tool_shapes`, 7 added `conversation_pages`, 8 added
/// `bookmarks` and `bookmark_tags`, 9 added `site_permissions`, 10 added
/// `windows` and `tab_windows`, 11 added `extension_pins`, 12 added
/// `tab_navigation_states`, 13 added `native_host_consent`.
///
/// Written to `user_version` on open and never read back, which is the honest
/// state of things: there is no migration step, so nothing branches on it. It
/// is here so that a person — or a future migration that finally needs one —
/// can tell which shape a file on disk was written by. That is worth a line,
/// and pretending it does more than that would not be.
const SCHEMA_VERSION: i64 = 13;

const SCHEMA: &str = "
CREATE TABLE IF NOT EXISTS meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS spaces (
    id              INTEGER PRIMARY KEY,
    position        INTEGER NOT NULL,
    name            TEXT    NOT NULL,
    data_store_id   TEXT    NOT NULL,
    user_agent      TEXT,
    ephemeral       INTEGER NOT NULL DEFAULT 0,
    last_active_tab INTEGER
);
CREATE TABLE IF NOT EXISTS windows (
    id           INTEGER PRIMARY KEY,
    position     INTEGER NOT NULL,
    active_space INTEGER NOT NULL,
    active_tab   INTEGER
);
CREATE TABLE IF NOT EXISTS tabs (
    id             INTEGER PRIMARY KEY,
    space_id       INTEGER NOT NULL REFERENCES spaces(id) ON DELETE CASCADE,
    position       INTEGER NOT NULL,
    parent_id      INTEGER,
    kind           TEXT    NOT NULL,
    url            TEXT,
    title          TEXT,
    muted          INTEGER NOT NULL DEFAULT 0,
    zoom_factor    REAL    NOT NULL DEFAULT 1.0,
    last_active_at INTEGER NOT NULL
);
-- A table of its own rather than three columns on `spaces`, and that is the
-- decision rather than the tidiness: this schema is created with
-- CREATE TABLE IF NOT EXISTS and has no migration step, so a column added to
-- an existing table would never appear on a database that already exists. Every
-- read and write of `spaces` would then fail on the machines that have most to
-- lose, and by ADR-0017 a failed read detaches the store — costing the session
-- of everyone who had one.
CREATE TABLE IF NOT EXISTS splits (
    space_id INTEGER PRIMARY KEY REFERENCES spaces(id) ON DELETE CASCADE,
    leading  INTEGER NOT NULL,
    trailing INTEGER NOT NULL,
    ratio    REAL    NOT NULL
);
-- Which window a tab was in, for the same reason `splits` is a table: a
-- `window_id` column on `tabs` would never appear on a database that already
-- exists, and every read of `tabs` would then fail on exactly the machines with
-- a session worth keeping.
-- ON UPDATE CASCADE as well as ON DELETE: a hand-edited or corrupt `tabs.id`
-- would otherwise fail the constraint and take the whole read with it, and by
-- ADR-0017 a failed read detaches the store. Following the id is the repair;
-- refusing to load is not.
CREATE TABLE IF NOT EXISTS tab_windows (
    tab_id    INTEGER PRIMARY KEY
              REFERENCES tabs(id) ON DELETE CASCADE ON UPDATE CASCADE,
    window_id INTEGER NOT NULL
);
-- Where a tab has been, in the engine's own opaque archive. A table of its own
-- for the reason `tab_windows` is one -- a column added to `tabs` never appears
-- on a database that already exists -- and for a second reason that is this
-- table's alone: these rows are the only ones here that are bytes nothing can
-- read. Read in a pass of their own, a blob that is not what it claims costs
-- the back list of one tab, and cannot take the read of `tabs` down with it and
-- detach the store from a whole session (ADR-0017, ADR-0024).
CREATE TABLE IF NOT EXISTS tab_navigation_states (
    tab_id INTEGER PRIMARY KEY
           REFERENCES tabs(id) ON DELETE CASCADE ON UPDATE CASCADE,
    state  BLOB NOT NULL
);
CREATE TABLE IF NOT EXISTS history (
    url           TEXT PRIMARY KEY,
    title         TEXT,
    visit_count   INTEGER NOT NULL,
    last_visit_ms INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS routes (
    position TEXT    PRIMARY KEY,
    kind     TEXT    NOT NULL,
    value    TEXT    NOT NULL,
    space_id INTEGER NOT NULL,
    enabled  INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS keybindings (
    key_kind    TEXT    NOT NULL,
    key_value   TEXT    NOT NULL DEFAULT '',
    primary_mod INTEGER NOT NULL,
    shift       INTEGER NOT NULL,
    alt         INTEGER NOT NULL,
    control     INTEGER NOT NULL,
    command     TEXT    NOT NULL,
    command_arg INTEGER,
    PRIMARY KEY (key_kind, key_value, primary_mod, shift, alt, control)
);
CREATE TABLE IF NOT EXISTS blocking_exceptions (
    host TEXT PRIMARY KEY
);
CREATE TABLE IF NOT EXISTS downloads (
    id            TEXT PRIMARY KEY,
    position      INTEGER NOT NULL,
    url           TEXT    NOT NULL,
    filename      TEXT    NOT NULL,
    path          TEXT    NOT NULL,
    state         TEXT    NOT NULL,
    received      INTEGER NOT NULL,
    total         INTEGER,
    started_at_ms INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS extension_consent (
    extension_id  TEXT PRIMARY KEY,
    decided_at_ms INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS extension_permissions (
    extension_id TEXT NOT NULL REFERENCES extension_consent(extension_id) ON DELETE CASCADE,
    kind         TEXT NOT NULL,
    value        TEXT NOT NULL,
    status       TEXT NOT NULL,
    PRIMARY KEY (extension_id, kind, value)
);
CREATE TABLE IF NOT EXISTS extension_pins (
    extension_id TEXT PRIMARY KEY,
    position     INTEGER NOT NULL,
    pinned       INTEGER NOT NULL
);
-- Which programs outside the browser an extension may start (ADR-0105).
--
-- A table of its own rather than a column anywhere, for the reason `splits`
-- states: `CREATE TABLE IF NOT EXISTS` is a no-op on a database that already
-- exists, so a new column would be missing on exactly the machines with a
-- session worth keeping. A new table is created on the next open and is
-- simply empty.
--
-- Keyed on the program and not on the application id the extension asked for.
-- Two ids resolving to one program are one decision; see the ledger's own
-- module docs.
--
-- Deliberately not `REFERENCES extension_consent`: `save` replaces that table
-- wholesale, and a cascade would take these rows with it every time anything
-- was written.
CREATE TABLE IF NOT EXISTS native_host_consent (
    extension_id  TEXT    NOT NULL,
    program       TEXT    NOT NULL,
    allowed       INTEGER NOT NULL,
    decided_at_ms INTEGER NOT NULL,
    PRIMARY KEY (extension_id, program)
);
CREATE TABLE IF NOT EXISTS conversations (
    id            INTEGER PRIMARY KEY,
    position      INTEGER NOT NULL,
    scope_kind    TEXT    NOT NULL,
    scope_id      INTEGER NOT NULL,
    created_at_ms INTEGER NOT NULL
);
-- The page a thread is anchored to, for the rows whose `scope_kind` is `page`.
--
-- A table of its own rather than a `url` column on `conversations`, for the
-- reason spelled out above `splits`: this schema is created with
-- CREATE TABLE IF NOT EXISTS and has no migration step, so a column added to a
-- table that already exists would never appear on the databases belonging to
-- people who have been using this — and every read of `conversations` would
-- then fail there, which by ADR-0017 detaches the store and costs the whole
-- session.
--
-- A `page` conversation with no row here names no page, and is dropped rather
-- than repaired into a thread about nothing (ADR-0045, clause 2).
CREATE TABLE IF NOT EXISTS conversation_pages (
    conversation_id INTEGER PRIMARY KEY REFERENCES conversations(id) ON DELETE CASCADE,
    url             TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS chat_messages (
    id              INTEGER PRIMARY KEY,
    conversation_id INTEGER NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    position        INTEGER NOT NULL,
    role            TEXT    NOT NULL,
    text            TEXT    NOT NULL DEFAULT '',
    -- Only ever set on a `page` row, and never accompanied by its body: the
    -- projection has no field for one, so there is no column for one either.
    url             TEXT,
    title           TEXT,
    state           TEXT    NOT NULL,
    model           TEXT,
    created_at_ms   INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS tool_consent (
    server        TEXT    NOT NULL,
    tool          TEXT    NOT NULL,
    allowed       INTEGER NOT NULL,
    decided_at_ms INTEGER NOT NULL,
    PRIMARY KEY (server, tool)
);
-- What each row of `tool_consent` was an answer *about* (ADR-0050): a hash over
-- the tool's name, description and input schema at the moment it was answered.
--
-- A table of its own rather than a `fingerprint` column on `tool_consent`, for
-- the reason spelled out above `splits`: this schema is created with
-- CREATE TABLE IF NOT EXISTS and has no migration step, so a column added to a
-- table that already exists would never appear on the databases that have most
-- to lose — the ones belonging to people who have been using this. Every read
-- and write of `tool_consent` would then fail there, and by ADR-0017 a failed
-- read detaches the store and costs the whole session.
--
-- A missing row is not an error and never becomes an approval. `verdict` reads
-- a grant with no shape as `Changed`, which asks again — so a file written by
-- schema 5, or one where this table was emptied, degrades into re-confirming
-- rather than into running something nobody approved.
CREATE TABLE IF NOT EXISTS tool_shapes (
    server      TEXT NOT NULL,
    tool        TEXT NOT NULL,
    fingerprint TEXT NOT NULL,
    PRIMARY KEY (server, tool)
);
-- Kept addresses (ADR-0059). Two tables rather than a `tags` column holding a joined
-- string, and both of them new rather than anything added to an existing one —
-- the reason is spelled out above `splits`: this schema is created with
-- CREATE TABLE IF NOT EXISTS and has no migration step, so a column added to a
-- table that already exists would never appear on the databases belonging to
-- people who have been using this, and by ADR-0017 the failed read that
-- followed would detach the store and cost them the whole session. A new table
-- is created on the next open of an old file and is simply empty.
--
-- No `position` column, unlike every other ordered table here. Bookmark order
-- is newest-kept-first, which is derivable from `saved_at_ms` — and a stored
-- order that can disagree with the data it is meant to describe is a second
-- source of truth. `Bookmarks::load` sorts, so the order is recomputed rather
-- than trusted.
--
-- And no `space_id`, which is the decision this whole feature rests on: a
-- bookmark does not belong to a space, so there is no column here in which a
-- backend could record that it did.
CREATE TABLE IF NOT EXISTS bookmarks (
    id          INTEGER PRIMARY KEY,
    url         TEXT    NOT NULL,
    title       TEXT    NOT NULL,
    saved_at_ms INTEGER NOT NULL
);
-- Deliberately not UNIQUE on `bookmarks(url)`. One bookmark per address is an
-- invariant `Bookmarks` already holds, and a constraint here would turn a
-- duplicate into a failed transaction — which by ADR-0017 is the whole session
-- lost to save a row nobody would have noticed. A file that somehow holds two
-- collapses to one on load instead.
CREATE TABLE IF NOT EXISTS bookmark_tags (
    bookmark_id INTEGER NOT NULL REFERENCES bookmarks(id) ON DELETE CASCADE,
    position    INTEGER NOT NULL,
    tag         TEXT    NOT NULL,
    PRIMARY KEY (bookmark_id, tag)
);
-- What a site was allowed to point at you (ADR-0056).
--
-- Keyed by space as well as by origin, and the space is the decision rather
-- than a detail: ADR-0007 makes a space a cookie jar, a cookie jar is an
-- identity, and a camera grant is a grant to whoever you are on that site.
--
-- `allowed` is a column rather than an absence, for the reason
-- `extension_permissions` records denials: absence has to keep meaning that
-- nobody was asked, or a fresh question is indistinguishable from an answered
-- one.
--
-- A row for an ephemeral space cannot appear here, and not because this file
-- checks: `StorableSession::project` is never handed one.
CREATE TABLE IF NOT EXISTS site_permissions (
    space_id      INTEGER NOT NULL,
    origin        TEXT    NOT NULL,
    capability    TEXT    NOT NULL,
    allowed       INTEGER NOT NULL,
    decided_at_ms INTEGER NOT NULL,
    PRIMARY KEY (space_id, origin, capability)
);
CREATE INDEX IF NOT EXISTS tabs_by_space ON tabs(space_id, position);
CREATE INDEX IF NOT EXISTS chat_by_conversation ON chat_messages(conversation_id, position);
CREATE INDEX IF NOT EXISTS history_by_visit ON history(last_visit_ms DESC);
";

// Written to disk, so these strings are a format and not an implementation
// detail. Renaming one silently drops every row that used the old spelling.
const PERMISSION_API: &str = "api";
const PERMISSION_SITE: &str = "site";
const STATUS_GRANTED: &str = "granted";
const STATUS_DENIED: &str = "denied";
const STATUS_UNREADABLE: &str = "unreadable";

fn permission_kind_from_str(value: &str) -> Option<PermissionKind> {
    match value {
        PERMISSION_API => Some(PermissionKind::Api),
        PERMISSION_SITE => Some(PermissionKind::Site),
        _ => None,
    }
}

/// Which statuses one pass over the permission rows is allowed to apply.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum PermissionPass {
    Decided,
    Unreadable,
}

pub struct Store {
    conn: Connection,
}

impl Store {
    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        Self::prepare(Connection::open(path)?)
    }

    /// For tests, and for a browser told never to touch the disk.
    pub fn in_memory() -> Result<Self> {
        Self::prepare(Connection::open_in_memory()?)
    }

    fn prepare(conn: Connection) -> Result<Self> {
        // WAL keeps a save from blocking reads, and matters the moment saving
        // happens on a timer while the UI is live.
        conn.pragma_update(None, "journal_mode", "WAL")?;
        conn.pragma_update(None, "foreign_keys", "ON")?;
        conn.execute_batch(SCHEMA)?;
        conn.pragma_update(None, "user_version", SCHEMA_VERSION)?;
        Ok(Self { conn })
    }
}

impl SessionStore for Store {
    /// One transaction, so the whole session lands or none of it does.
    ///
    /// Everything here is "how to write it down". Nothing here is "whether it
    /// deserves writing down": that was settled by
    /// [`StorableSession::project`] before this backend was handed anything,
    /// which is why a second backend inherits the content rules instead of
    /// having to remember them.
    fn save(&mut self, session: &StorableSession) -> Result<()> {
        let tx = self.conn.transaction()?;

        tx.execute("DELETE FROM tabs", [])?;
        // Before `spaces`, whose cascade would take these anyway. Spelled out
        // so the order of the deletes stops being load-bearing.
        tx.execute("DELETE FROM splits", [])?;
        // The cascade off `tabs` has already emptied this; spelled out anyway
        // so the order of the deletes stops being load-bearing.
        tx.execute("DELETE FROM tab_windows", [])?;
        // Same again: a cascade already took these, and saying so keeps a
        // stored back/forward list from outliving the tab it belongs to if the
        // order above is ever shuffled.
        tx.execute("DELETE FROM tab_navigation_states", [])?;
        tx.execute("DELETE FROM windows", [])?;
        tx.execute("DELETE FROM spaces", [])?;
        tx.execute("DELETE FROM routes", [])?;
        tx.execute("DELETE FROM keybindings", [])?;
        tx.execute("DELETE FROM downloads", [])?;
        // The permission rows cascade off this one, so deleting it is enough.
        tx.execute("DELETE FROM extension_consent", [])?;
        tx.execute("DELETE FROM extension_pins", [])?;
        tx.execute("DELETE FROM native_host_consent", [])?;
        // Likewise: the messages cascade off their conversation.
        tx.execute("DELETE FROM conversations", [])?;
        tx.execute("DELETE FROM tool_consent", [])?;
        tx.execute("DELETE FROM tool_shapes", [])?;
        // History is replaced, not merged. Upserting alone meant a cleared or
        // forgotten page came back on the next launch: the row was still on
        // disk and nothing ever deleted it.
        tx.execute("DELETE FROM history", [])?;
        // The tag rows cascade off their bookmark, so deleting this is enough.
        tx.execute("DELETE FROM bookmarks", [])?;
        tx.execute("DELETE FROM site_permissions", [])?;

        for (position, space) in session.spaces.iter().enumerate() {
            tx.execute(
                "INSERT INTO spaces
                 (id, position, name, data_store_id, user_agent, ephemeral, last_active_tab)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
                params![
                    space.id.0 as i64,
                    position as i64,
                    space.name,
                    space.data_store_id,
                    space.profile.user_agent,
                    space.profile.ephemeral,
                    space.last_active_tab.map(|t| t.0 as i64),
                ],
            )?;

            // No test for `ephemeral` here, and that is the point: an ephemeral
            // space arrives with no tabs and no split, so the loop below writes
            // nothing without this backend having to know why.
            if let Some(split) = &space.split {
                tx.execute(
                    "INSERT INTO splits (space_id, leading, trailing, ratio)
                     VALUES (?1, ?2, ?3, ?4)",
                    params![
                        space.id.0 as i64,
                        split.leading.0 as i64,
                        split.trailing.0 as i64,
                        split.ratio,
                    ],
                )?;
            }
            for (position, kept) in space.tabs.iter().enumerate() {
                let tab = &kept.tab;
                tx.execute(
                    "INSERT INTO tabs
                     (id, space_id, position, parent_id, kind, url, title, muted,
                      zoom_factor, last_active_at)
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
                    params![
                        tab.id.0 as i64,
                        tab.space.0 as i64,
                        position as i64,
                        tab.parent.map(|p| p.0 as i64),
                        kind_to_str(tab.kind),
                        tab.url,
                        tab.title,
                        tab.muted,
                        tab.zoom_factor,
                        tab.last_active_at as i64,
                    ],
                )?;
                tx.execute(
                    "INSERT INTO tab_windows (tab_id, window_id) VALUES (?1, ?2)",
                    params![tab.id.0 as i64, tab.window.0 as i64],
                )?;
                // No branch on the space here either: an ephemeral space
                // arrives with no tabs, so this loop never runs for one and
                // there is no back/forward list of its to leave out.
                if let Some(state) = &kept.navigation_state {
                    tx.execute(
                        "INSERT INTO tab_navigation_states (tab_id, state)
                         VALUES (?1, ?2)",
                        params![tab.id.0 as i64, state],
                    )?;
                }
            }
        }

        for (position, window) in session.windows.iter().enumerate() {
            tx.execute(
                "INSERT INTO windows (id, position, active_space, active_tab)
                 VALUES (?1, ?2, ?3, ?4)",
                params![
                    window.id.0 as i64,
                    position as i64,
                    window.active_space.0 as i64,
                    window.active_tab.map(|t| t.0 as i64),
                ],
            )?;
        }

        for (position, route) in session.routes.iter().enumerate() {
            let (kind, value) = pattern_to_row(&route.pattern);
            tx.execute(
                "INSERT INTO routes (position, kind, value, space_id, enabled)
                 VALUES (?1, ?2, ?3, ?4, ?5)",
                params![
                    format!("{position:08}"),
                    kind,
                    value,
                    route.space.0 as i64,
                    route.enabled,
                ],
            )?;
        }

        // Already only what differs from the shipped defaults; writing the
        // whole keymap is not a mistake this backend is in a position to make.
        for binding in &session.keybindings {
            let (kind, value) = key_to_row(&binding.chord.key);
            let (command, arg) = command_to_row(&binding.command);
            tx.execute(
                "INSERT INTO keybindings
                 (key_kind, key_value, primary_mod, shift, alt, control, command, command_arg)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
                params![
                    kind,
                    value,
                    binding.chord.modifiers.primary,
                    binding.chord.modifiers.shift,
                    binding.chord.modifiers.alt,
                    binding.chord.modifiers.control,
                    command,
                    arg,
                ],
            )?;
        }

        for entry in &session.history {
            tx.execute(
                "INSERT INTO history (url, title, visit_count, last_visit_ms)
                 VALUES (?1, ?2, ?3, ?4)",
                params![
                    entry.url,
                    entry.title,
                    entry.visit_count,
                    entry.last_visit_ms as i64
                ],
            )?;
        }

        // Written in list order for readability of the file, and read back
        // without relying on it: the order is recomputed from `saved_at_ms`.
        for bookmark in &session.bookmarks {
            tx.execute(
                "INSERT INTO bookmarks (id, url, title, saved_at_ms) VALUES (?1, ?2, ?3, ?4)",
                params![
                    bookmark.id.0 as i64,
                    bookmark.url,
                    bookmark.title,
                    bookmark.saved_at_ms as i64,
                ],
            )?;
            for (position, tag) in bookmark.tags.iter().enumerate() {
                // OR IGNORE rather than a plain insert: the primary key already
                // says one tag once, and `Bookmarks` has already deduplicated,
                // so a collision here would only ever be a corrupt in-memory
                // list — and failing the transaction over it would cost the
                // whole session to protect one label.
                tx.execute(
                    "INSERT OR IGNORE INTO bookmark_tags (bookmark_id, position, tag)
                     VALUES (?1, ?2, ?3)",
                    params![bookmark.id.0 as i64, position as i64, tag],
                )?;
            }
        }

        for grant in &session.site_permissions {
            tx.execute(
                "INSERT OR REPLACE INTO site_permissions
                     (space_id, origin, capability, allowed, decided_at_ms)
                 VALUES (?1, ?2, ?3, ?4, ?5)",
                params![
                    grant.space.0 as i64,
                    grant.origin,
                    grant.capability.as_str(),
                    grant.allowed as i64,
                    grant.decided_at_ms as i64,
                ],
            )?;
        }

        for (position, download) in session.downloads.iter().enumerate() {
            tx.execute(
                "INSERT INTO downloads
                 (id, position, url, filename, path, state, received, total, started_at_ms)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
                params![
                    download.id.0,
                    position as i64,
                    download.url,
                    download.filename,
                    download.path,
                    download_state_to_str(download.state),
                    download.received_bytes as i64,
                    download.total_bytes.map(|t| t as i64),
                    download.started_at_ms as i64,
                ],
            )?;
        }

        // Extension consent. The extension gets a row of its own even when it
        // was granted nothing, because "asked, and the answer was no" has to
        // survive a relaunch as something other than "never asked".
        for decision in &session.extension_consent {
            tx.execute(
                "INSERT INTO extension_consent (extension_id, decided_at_ms) VALUES (?1, ?2)",
                params![decision.extension_id, decision.decided_at_ms as i64],
            )?;

            let rows = [
                (
                    PERMISSION_API,
                    STATUS_GRANTED,
                    &decision.granted_permissions,
                ),
                (PERMISSION_API, STATUS_DENIED, &decision.denied_permissions),
                (PERMISSION_SITE, STATUS_GRANTED, &decision.granted_hosts),
                (PERMISSION_SITE, STATUS_DENIED, &decision.denied_hosts),
                (
                    PERMISSION_SITE,
                    STATUS_UNREADABLE,
                    &decision.unreadable_hosts,
                ),
            ];
            for (kind, status, keys) in rows {
                for key in keys {
                    tx.execute(
                        "INSERT OR REPLACE INTO extension_permissions
                         (extension_id, kind, value, status)
                         VALUES (?1, ?2, ?3, ?4)",
                        params![decision.extension_id, kind, key, status],
                    )?;
                }
            }
        }

        // Which extension buttons are on show. `position` is the column that
        // makes the order data rather than whatever SQLite feels like handing
        // back (ADR-0045 clause 3): the row is indexed by ⇧⌘1..⇧⌘9, so an order
        // that drifts between launches re-points every one of those chords.
        //
        // A `pinned: false` row is written like any other. It is the record
        // that somebody hid this one on purpose, and dropping it because it
        // looks like an absence is how the next launch puts it back.
        for (position, pin) in session.extension_pins.iter().enumerate() {
            tx.execute(
                "INSERT INTO extension_pins (extension_id, position, pinned) VALUES (?1, ?2, ?3)",
                params![pin.extension_id, position as i64, pin.pinned],
            )?;
        }

        // A `allowed: false` row is written like any other, for the reason the
        // consent ledger's denials are: absence has to keep meaning "nobody was
        // asked", which is what happens the first time an extension reaches for
        // a program it has never reached for before.
        for host in &session.native_hosts {
            tx.execute(
                "INSERT OR REPLACE INTO native_host_consent \
                 (extension_id, program, allowed, decided_at_ms) VALUES (?1, ?2, ?3, ?4)",
                params![
                    host.extension_id,
                    host.program,
                    host.allowed,
                    host.decided_at_ms as i64
                ],
            )?;
        }

        // Conversations. What may be written down was decided in
        // `StorableSession::project`: an ephemeral space's threads never reach
        // here, a tool call cannot be spelled in this schema because the
        // projection has no value for one, and a `page` row has columns for an
        // address and a title and none for what was on the page.
        for (position, conversation) in session.conversations.iter().enumerate() {
            let (scope_kind, scope_id) = scope_to_row(&conversation.scope);
            tx.execute(
                "INSERT INTO conversations (id, position, scope_kind, scope_id, created_at_ms)
                 VALUES (?1, ?2, ?3, ?4, ?5)",
                params![
                    conversation.id.0 as i64,
                    position as i64,
                    scope_kind,
                    scope_id,
                    conversation.created_at_ms as i64,
                ],
            )?;
            if let Some(page) = conversation.scope.page() {
                tx.execute(
                    "INSERT INTO conversation_pages (conversation_id, url) VALUES (?1, ?2)",
                    params![conversation.id.0 as i64, page.as_str()],
                )?;
            }
            for (position, message) in conversation.messages.iter().enumerate() {
                let row = message_to_row(message);
                tx.execute(
                    "INSERT INTO chat_messages
                     (id, conversation_id, position, role, text, url, title, state, model,
                      created_at_ms)
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
                    params![
                        message.id().0 as i64,
                        conversation.id.0 as i64,
                        position as i64,
                        row.role,
                        row.text,
                        row.url,
                        row.title,
                        row.state,
                        row.model,
                        row.created_at_ms as i64,
                    ],
                )?;
            }
        }

        for grant in &session.tool_consent {
            tx.execute(
                "INSERT OR REPLACE INTO tool_consent (server, tool, allowed, decided_at_ms)
                 VALUES (?1, ?2, ?3, ?4)",
                params![
                    grant.server,
                    grant.tool,
                    grant.allowed,
                    grant.decided_at_ms as i64
                ],
            )?;
        }

        for shape in &session.tool_shapes {
            tx.execute(
                "INSERT OR REPLACE INTO tool_shapes (server, tool, fingerprint)
                 VALUES (?1, ?2, ?3)",
                params![shape.server, shape.tool, shape.fingerprint],
            )?;
        }

        // Preferences: scalars in meta, the exception list in its own table.
        let prefs = &session.preferences;
        set_meta(&tx, "theme", theme_to_str(prefs.theme))?;
        set_meta(&tx, "startup", &startup_to_str(&prefs.startup))?;
        set_meta(
            &tx,
            "download_directory",
            prefs.download_directory.as_deref().unwrap_or(""),
        )?;
        set_meta(
            &tx,
            "ask_where_to_save",
            &prefs.ask_where_to_save.to_string(),
        )?;
        set_meta(&tx, "block_content", &prefs.block_content.to_string())?;
        set_meta(
            &tx,
            "send_do_not_track",
            &prefs.send_do_not_track.to_string(),
        )?;
        set_meta(
            &tx,
            "clear_data_on_quit",
            &prefs.clear_data_on_quit.to_string(),
        )?;
        set_meta(
            &tx,
            "confirm_close_over",
            &prefs.confirm_close_over.to_string(),
        )?;
        set_meta(
            &tx,
            "block_audible_autoplay",
            &prefs.block_audible_autoplay.to_string(),
        )?;
        set_meta(
            &tx,
            "block_unprompted_windows",
            &prefs.block_unprompted_windows.to_string(),
        )?;
        set_meta(
            &tx,
            "background_throttling",
            &prefs.background_throttling.to_string(),
        )?;
        set_meta(&tx, "https_first", &prefs.https_first.to_string())?;

        tx.execute("DELETE FROM blocking_exceptions", [])?;
        for host in &prefs.blocking_exceptions {
            tx.execute(
                "INSERT OR IGNORE INTO blocking_exceptions (host) VALUES (?1)",
                params![host],
            )?;
        }

        set_meta(&tx, "key_window", &session.key_window.0.to_string())?;
        set_meta(&tx, "search_template", &session.search_template)?;
        set_meta(
            &tx,
            "archive_after_ms",
            &session.archive_after_ms.to_string(),
        )?;

        tx.commit()?;
        Ok(())
    }

    /// An empty `spaces` table is what "nothing has ever been stored here"
    /// looks like in this schema: the tables are created on open, so a fresh
    /// file is a full set of empty ones rather than an absent anything.
    fn load(&self) -> Result<Option<Session>> {
        let spaces = self.load_spaces()?;
        if spaces.is_empty() {
            return Ok(None);
        }
        let tabs = self.load_tabs()?;
        let windows = self.load_windows()?;

        // A file written before windows existed has none, and `Browser::restore`
        // makes one rather than refusing: the pages are the thing worth keeping.
        let key_window = WindowId(
            get_meta(&self.conn, "key_window")?
                .and_then(|v| v.parse().ok())
                .unwrap_or_default(),
        );

        // Unreachable today: `restore` only refuses an empty list of spaces,
        // and that was ruled out above. It is `Err` anyway, because the day
        // `restore` learns a second reason to refuse, `Ok(None)` would report
        // "there was a session and it is not usable" as "there was never a
        // session" — and by ADR-0045 that is the answer the caller writes over.
        // Nobody would be adding that second refusal while thinking about this
        // line, which is what makes a dead branch worth closing rather than
        // commenting.
        let Some(mut browser) = Browser::restore(spaces, tabs, windows, key_window) else {
            return Err(StoreError::Unusable);
        };
        if let Some(template) = get_meta(&self.conn, "search_template")?.filter(|t| !t.is_empty()) {
            browser.set_search_template(template);
        }
        if let Some(ms) = get_meta(&self.conn, "archive_after_ms")?.and_then(|v| v.parse().ok()) {
            browser.set_archive_after_ms(ms);
        }

        let mut routes = self.load_routes()?;
        let existing: Vec<SpaceId> = browser.spaces().iter().map(|s| s.id).collect();
        routes.retain_spaces(&existing);

        Ok(Some(Session {
            browser,
            history: History::load(self.load_history()?),
            bookmarks: Bookmarks::load(self.load_bookmarks()?),
            routes,
            keymap: Keymap::load(self.load_keybindings()?),
            preferences: self.load_preferences()?,
            downloads: Downloads::load(self.load_downloads()?),
            extension_consent: ExtensionConsent::load(self.load_extension_consent()?),
            extension_pins: ExtensionPins::load(self.load_extension_pins()?),
            native_hosts: NativeHostLedger::load(self.load_native_host_consent()?),
            site_permissions: SitePermissions::load(self.load_site_permissions()?),
            // Icons live in a file of their own (ADR-0044) and are loaded over
            // the top of this by whoever opened both.
            icons: Icons::new(),
            chat: Chat::load(self.load_conversations()?, self.load_tool_consent()?),
            // Which servers exist and what they offer is rebuilt from
            // configuration at launch, never from the session file: what a
            // server can do is a fact about a process that is not running yet,
            // and a call answered against a remembered list would run a tool
            // the server may no longer have.
            //
            // The bound shapes do come back, and they are the opposite kind of
            // fact: not what a tool is, but what somebody was looking at when
            // they answered about it. Without them every remembered approval
            // reads as `Changed` on the first call after a relaunch — safe, and
            // an interrogation nobody deserves twice a day.
            mcp: {
                let mut registry = McpRegistry::new();
                registry.load_shapes(self.load_tool_shapes()?);
                registry
            },
            // Nothing to restore, and nothing that could be. A page frozen
            // inside `alert()` in a previous run is not on the other end of
            // that call now, and the engine holds no handler to answer.
            page_dialogs: PageDialogs::new(),
            // Same reason, one layer along: a server that was asking for a
            // password last week is not waiting on this launch's answer. The
            // credential itself is not lost by that — it is in the Keychain,
            // where ADR-0064 put it.
            http_auth: HttpAuth::new(),
            // Deliberately empty on every launch. An exception that survived a
            // relaunch would be a hole in the browser's own guarantee with
            // nothing on any screen to show it was there.
            trust_exceptions: TrustExceptions::new(),
            certificate_reports: std::collections::HashMap::new(),
            navigation_states: NavigationStates::load(self.load_navigation_states()?),
            closed_tabs: Vec::new(),
        }))
    }

    /// Written after everything else in the same file, so its presence means
    /// the rest of the save reached disk.
    fn mark_clean_shutdown(&self) -> Result<()> {
        set_meta(&self.conn, "clean_shutdown", "1")
    }

    fn take_clean_shutdown(&self) -> Result<bool> {
        let was_clean = get_meta(&self.conn, "clean_shutdown")?.as_deref() == Some("1");
        set_meta(&self.conn, "clean_shutdown", "0")?;
        Ok(was_clean)
    }

    fn forget_history_before(&mut self, before_ms: u64) -> Result<usize> {
        Ok(self.conn.execute(
            "DELETE FROM history WHERE last_visit_ms < ?1",
            params![before_ms as i64],
        )?)
    }
}

/// The readers `load` is assembled from.
///
/// Private and inherent rather than part of the trait: how many reads a load
/// takes, and in what order, is the backend's own business. Another one could
/// answer the whole thing from a single document.
impl Store {
    fn load_spaces(&self) -> Result<Vec<Space>> {
        let mut stmt = self.conn.prepare(
            "SELECT id, name, data_store_id, user_agent, ephemeral, last_active_tab
             FROM spaces ORDER BY position",
        )?;
        let rows = stmt.query_map([], |row| {
            Ok(Space {
                id: SpaceId(row.get::<_, i64>(0)?.max(0) as u64),
                name: row.get(1)?,
                data_store_id: row.get(2)?,
                profile: SpaceProfile {
                    user_agent: row.get(3)?,
                    ephemeral: row.get(4)?,
                },
                tab_order: Vec::new(),
                last_active_tab: row.get::<_, Option<i64>>(5)?.map(|t| TabId(t as u64)),
                split: None,
            })
        })?;
        let mut spaces: Vec<Space> = rows.collect::<rusqlite::Result<_>>()?;

        // Attached here rather than joined, so a `splits` row for a space that
        // is gone simply finds nobody to attach to. `Browser::restore` throws
        // out anything left over that names a tab it cannot see.
        for (space, split) in self.load_splits()? {
            if let Some(s) = spaces.iter_mut().find(|s| s.id == space) {
                s.split = Some(split);
            }
        }
        Ok(spaces)
    }

    fn load_splits(&self) -> Result<Vec<(SpaceId, Split)>> {
        let mut stmt = self
            .conn
            .prepare("SELECT space_id, leading, trailing, ratio FROM splits")?;
        let rows = stmt.query_map([], |row| {
            Ok((
                SpaceId(row.get::<_, i64>(0)?.max(0) as u64),
                Split {
                    leading: TabId(row.get::<_, i64>(1)?.max(0) as u64),
                    trailing: TabId(row.get::<_, i64>(2)?.max(0) as u64),
                    // A hand-edited ratio outside the limits, or a NaN, would
                    // lay the divider out past the edge of the window.
                    ratio: clamp_split_ratio(row.get(3)?),
                },
            ))
        })?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    /// Windows in the order they were opened.
    ///
    /// A left join is deliberately not used to attach tabs: a tab already
    /// carries its window, and reading it twice would be two answers that can
    /// disagree.
    fn load_windows(&self) -> Result<Vec<Window>> {
        let mut stmt = self
            .conn
            .prepare("SELECT id, active_space, active_tab FROM windows ORDER BY position")?;
        let rows = stmt.query_map([], |row| {
            Ok(Window {
                id: WindowId(row.get::<_, i64>(0)?.max(0) as u64),
                active_space: SpaceId(row.get::<_, i64>(1)?.max(0) as u64),
                active_tab: row
                    .get::<_, Option<i64>>(2)?
                    .filter(|t| *t > 0)
                    .map(|t| TabId(t as u64)),
            })
        })?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    /// Where each tab had been, as far as this file can be believed.
    ///
    /// A pass of its own, after the tabs, and that separation is the decision:
    /// these are the only bytes in this database nothing on either side of the
    /// FFI can read, so there is no repair available and no validity to check.
    /// What there is, is a bound — [`NavigationStates::set`] refuses anything
    /// absurd — and the guarantee that a row that will not come off the disk at
    /// all costs one tab's back list rather than the read of `tabs`, which by
    /// ADR-0017 would cost the whole session's saving.
    ///
    /// A row naming a tab that is not in this file is simply never asked for:
    /// `Browser::restore` has already dropped such tabs, and a state handed to
    /// [`NavigationStates`] for a tab nobody holds is unreachable rather than
    /// dangerous. It goes at the next save, with the tab it was never on.
    fn load_navigation_states(&self) -> Result<Vec<(TabId, Vec<u8>)>> {
        let mut stmt = self
            .conn
            .prepare("SELECT tab_id, state FROM tab_navigation_states")?;
        let rows = stmt.query_map([], |row| {
            Ok((
                // Same reasoning as `load_tabs`: a negative id is corrupt, and
                // casting it would produce one near u64::MAX.
                TabId(row.get::<_, i64>(0)?.max(0) as u64),
                row.get::<_, Vec<u8>>(1)?,
            ))
        })?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    fn load_tabs(&self) -> Result<Vec<Tab>> {
        // Left join rather than an inner one: a tab whose window row is missing
        // is a page somebody kept, and `Browser::restore` puts it in the first
        // window rather than losing it over the bookkeeping.
        let mut stmt = self.conn.prepare(
            "SELECT t.id, t.space_id, t.parent_id, t.kind, t.url, t.title, t.muted,
                    t.zoom_factor, t.last_active_at, w.window_id
             FROM tabs t LEFT JOIN tab_windows w ON w.tab_id = t.id
             ORDER BY t.space_id, t.position",
        )?;
        let rows = stmt.query_map([], |row| {
            Ok(Tab {
                // Ids are positive by construction. A negative one is corrupt
                // or hand-edited, and casting it to u64 would produce a value
                // near u64::MAX that poisons the id counter for good.
                id: TabId(row.get::<_, i64>(0)?.max(0) as u64),
                space: SpaceId(row.get::<_, i64>(1)?.max(0) as u64),
                // Zero is not a live id, so a missing row lands on one no
                // window has and gets repaired into the first.
                window: WindowId(row.get::<_, Option<i64>>(9)?.unwrap_or(0).max(0) as u64),
                parent: row
                    .get::<_, Option<i64>>(2)?
                    .filter(|p| *p > 0)
                    .map(|p| TabId(p as u64)),
                kind: kind_from_str(&row.get::<_, String>(3)?),
                // Deliberately not a column. It says a page is on the other
                // end of this tab and may close it, and after a relaunch no
                // page is: the script that opened it is gone with the process
                // it ran in (ADR-0075).
                opened_by_page: false,
                url: row.get(4)?,
                title: row.get(5)?,
                // Deliberately not a column, for the same reason `last_error`
                // is not one: it describes a page that is not loaded yet. The
                // restored tab reports its colour again the moment it does.
                tint: None,
                pending_url: None,
                muted: row.get(6)?,
                playing_audio: false,
                zoom_factor: row.get(7)?,
                loading_complete: true,
                // Deliberately not columns, like the tint: they describe the
                // engine view this run built, and the restored view reports
                // its own answer when it commits. A stored `true` would be a
                // claim about an engine that has not said anything yet.
                can_go_back: false,
                can_go_forward: false,
                // Deliberately not a column. A restored tab is loaded again on
                // launch, so last night's "you are offline" would be shown
                // over a page that is about to load fine. The page gets to
                // fail again on its own if it still fails.
                last_error: None,
                last_active_at: row.get::<_, i64>(8)? as u64,
            })
        })?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    /// Kept addresses, with their labels attached.
    ///
    /// No `ORDER BY`: the order is newest-kept-first and `Bookmarks::load`
    /// computes it from `saved_at_ms`. Sorting here as well would be a second
    /// place that has an opinion about it, and the two would eventually
    /// disagree on a file somebody hand-edited.
    /// Every answer given to a site, as far as this file can be believed.
    ///
    /// A row whose capability is a word this build does not know is **dropped**
    /// rather than repaired (ADR-0024). The two failure modes are not
    /// symmetrical: dropping a grant costs one prompt, and guessing at one
    /// hands a camera to a site over a string nobody wrote.
    fn load_site_permissions(&self) -> Result<Vec<SiteGrant>> {
        let mut stmt = self.conn.prepare(
            "SELECT space_id, origin, capability, allowed, decided_at_ms FROM site_permissions",
        )?;
        let rows = stmt.query_map([], |row| {
            Ok((
                row.get::<_, i64>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, i64>(3)?,
                row.get::<_, i64>(4)?,
            ))
        })?;

        let mut grants = Vec::new();
        for row in rows {
            let (space, origin, capability, allowed, decided_at_ms) = row?;
            let Some(capability) = SiteCapability::from_stored(&capability) else {
                continue;
            };
            // An origin that no longer canonicalises the way it did when it was
            // written is an origin this build cannot match a page against, so a
            // grant keyed by it could never be honoured and could never be found
            // on the screen that takes it back.
            if origin.is_empty() {
                continue;
            }
            grants.push(SiteGrant {
                space: SpaceId(space.max(0) as u64),
                origin,
                capability,
                allowed: allowed != 0,
                decided_at_ms: decided_at_ms.max(0) as u64,
            });
        }
        Ok(grants)
    }

    fn load_bookmarks(&self) -> Result<Vec<Bookmark>> {
        let mut tags = self
            .conn
            .prepare("SELECT bookmark_id, tag FROM bookmark_tags ORDER BY bookmark_id, position")?;
        let tag_rows: Vec<(i64, String)> = tags
            .query_map([], |row| Ok((row.get(0)?, row.get(1)?)))?
            .collect::<rusqlite::Result<_>>()?;

        let mut stmt = self
            .conn
            .prepare("SELECT id, url, title, saved_at_ms FROM bookmarks")?;
        let rows = stmt.query_map([], |row| {
            // Ids are positive by construction. A negative one is corrupt or
            // hand-edited, and casting it to u64 would produce a value near
            // u64::MAX that poisons the id counter for good.
            let id: i64 = row.get::<_, i64>(0)?.max(0);
            Ok(Bookmark {
                id: BookmarkId(id as u64),
                url: row.get(1)?,
                title: row.get(2)?,
                tags: tag_rows
                    .iter()
                    .filter(|(owner, _)| *owner == id)
                    .map(|(_, tag)| tag.clone())
                    .collect(),
                saved_at_ms: row.get::<_, i64>(3)?.max(0) as u64,
            })
        })?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    fn load_history(&self) -> Result<Vec<HistoryEntry>> {
        let mut stmt = self
            .conn
            .prepare("SELECT url, title, visit_count, last_visit_ms FROM history")?;
        let rows = stmt.query_map([], |row| {
            Ok(HistoryEntry {
                url: row.get(0)?,
                title: row.get(1)?,
                visit_count: row.get(2)?,
                last_visit_ms: row.get::<_, i64>(3)? as u64,
            })
        })?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    /// Downloads that are still worth showing.
    ///
    /// A row asserts "this file is at this path". When the file is not there
    /// any more — moved, renamed, thrown away — the row cannot back that up,
    /// and a list of entries whose Reveal in Finder does nothing is worse than
    /// no list at all. So the check happens here, once, at load.
    fn load_downloads(&self) -> Result<Vec<Download>> {
        let mut stmt = self.conn.prepare(
            "SELECT id, url, filename, path, state, received, total, started_at_ms
             FROM downloads ORDER BY position",
        )?;
        let rows = stmt.query_map([], |row| {
            Ok(Download {
                id: DownloadId(row.get(0)?),
                url: row.get(1)?,
                tab: None,
                filename: row.get(2)?,
                path: row.get(3)?,
                state: download_state_from_str(&row.get::<_, String>(4)?),
                received_bytes: row.get::<_, i64>(5)?.max(0) as u64,
                total_bytes: row
                    .get::<_, Option<i64>>(6)?
                    .filter(|t| *t >= 0)
                    .map(|t| t as u64),
                // A failure is not written down, so a restored row never
                // carries one.
                error: None,
                started_at_ms: row.get::<_, i64>(7)?.max(0) as u64,
                // Resume data lives in the host and dies with the process, so
                // a row read back from disk can never carry on from anywhere.
                // There is no column to read it from either: `StorableDownload`
                // has no field for it (ADR-0101).
                resumable: false,
            })
        })?;

        Ok(rows
            .collect::<rusqlite::Result<Vec<Download>>>()?
            .into_iter()
            .filter(|d| std::fs::symlink_metadata(&d.path).is_ok())
            .collect())
    }

    /// Every decision made about an extension, denials included.
    ///
    /// A row whose status this version does not recognise is dropped rather
    /// than guessed at: the two ways to guess are "granted", which hands out
    /// access nobody approved, and "denied", which is at least honest but
    /// still invents an answer. Dropping it leaves the permission unmentioned,
    /// which is the one state that already means "nobody was asked".
    fn load_extension_consent(&self) -> Result<Vec<ConsentDecision>> {
        let mut stmt = self
            .conn
            .prepare("SELECT extension_id, decided_at_ms FROM extension_consent")?;
        let rows = stmt.query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, i64>(1)?.max(0) as u64,
            ))
        })?;

        let mut decisions = Vec::new();
        for row in rows {
            let (extension_id, decided_at_ms) = row?;
            decisions.push(ConsentDecision::refusing_everything(
                extension_id,
                decided_at_ms,
                Vec::new(),
            ));
        }

        let mut stmt = self
            .conn
            .prepare("SELECT extension_id, kind, value, status FROM extension_permissions")?;
        let rows = stmt.query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, String>(3)?,
            ))
        })?;
        let rows: Vec<(String, String, String, String)> = rows.collect::<rusqlite::Result<_>>()?;

        // Two passes, because "unreadable" has to win over the other two and
        // SQLite promises no row order. One pass would make the outcome depend
        // on which row came back first, which is the kind of bug that only
        // shows up on someone else's disk.
        for pass in [PermissionPass::Decided, PermissionPass::Unreadable] {
            for (extension_id, kind, value, status) in &rows {
                let Some(decision) = decisions
                    .iter_mut()
                    .find(|d| &d.extension_id == extension_id)
                else {
                    continue;
                };
                let Some(kind) = permission_kind_from_str(kind) else {
                    continue;
                };
                match (pass, status.as_str()) {
                    (PermissionPass::Decided, STATUS_GRANTED) => decision.allow(kind, value),
                    (PermissionPass::Decided, STATUS_DENIED) => decision.refuse(kind, value),
                    (PermissionPass::Unreadable, STATUS_UNREADABLE) => {
                        decision.mark_unreadable(value)
                    }
                    _ => continue,
                }
            }
        }

        Ok(decisions)
    }

    /// Which extension buttons are on show, back in the order they were drawn.
    ///
    /// `ORDER BY position` rather than trusting the table: order is what a
    /// chord indexes into, and a medium with no inherent order has to be told
    /// (ADR-0045 clause 3).
    ///
    /// Nothing here is repaired. A row this version cannot read comes back as
    /// no row at all, which means "nobody has decided about this extension" —
    /// the one state that is honest about not knowing, and the one the adoption
    /// rule is allowed to act on.
    fn load_extension_pins(&self) -> Result<Vec<ExtensionPin>> {
        let mut stmt = self
            .conn
            .prepare("SELECT extension_id, pinned FROM extension_pins ORDER BY position")?;
        let rows = stmt.query_map([], |row| {
            Ok(ExtensionPin {
                extension_id: row.get(0)?,
                pinned: row.get(1)?,
            })
        })?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    /// Which programs each extension may start.
    ///
    /// A row this version cannot read comes back as no row at all, which means
    /// "nobody has been asked" — and being asked again is the fail-closed
    /// answer, because nothing runs until somebody says yes.
    fn load_native_host_consent(&self) -> Result<Vec<NativeHostDecision>> {
        let mut stmt = self.conn.prepare(
            "SELECT extension_id, program, allowed, decided_at_ms FROM native_host_consent",
        )?;
        let rows = stmt.query_map([], |row| {
            Ok(NativeHostDecision {
                extension_id: row.get(0)?,
                program: row.get(1)?,
                allowed: row.get(2)?,
                decided_at_ms: row.get::<_, i64>(3)?.max(0) as u64,
            })
        })?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    fn load_preferences(&self) -> Result<Preferences> {
        // Anything missing or unreadable falls back to the default rather than
        // failing the load: a bad preference must not cost you your session.
        let mut prefs = Preferences::default();

        if let Some(v) = get_meta(&self.conn, "theme")? {
            prefs.theme = theme_from_str(&v);
        }
        if let Some(v) = get_meta(&self.conn, "startup")? {
            prefs.startup = startup_from_str(&v);
        }
        prefs.download_directory =
            get_meta(&self.conn, "download_directory")?.filter(|v| !v.is_empty());
        if let Some(v) = get_meta(&self.conn, "ask_where_to_save")?.and_then(|v| v.parse().ok()) {
            prefs.ask_where_to_save = v;
        }
        if let Some(v) = get_meta(&self.conn, "block_content")?.and_then(|v| v.parse().ok()) {
            prefs.block_content = v;
        }
        if let Some(v) = get_meta(&self.conn, "send_do_not_track")?.and_then(|v| v.parse().ok()) {
            prefs.send_do_not_track = v;
        }
        if let Some(v) = get_meta(&self.conn, "clear_data_on_quit")?.and_then(|v| v.parse().ok()) {
            prefs.clear_data_on_quit = v;
        }
        if let Some(v) = get_meta(&self.conn, "confirm_close_over")?.and_then(|v| v.parse().ok()) {
            prefs.confirm_close_over = v;
        }
        // A session written before this existed has no row, which leaves the
        // default — and the default is "on". A browser that quietly started
        // letting every page make noise for everyone who upgraded would be the
        // worst way to learn that.
        if let Some(v) =
            get_meta(&self.conn, "block_audible_autoplay")?.and_then(|v| v.parse().ok())
        {
            prefs.block_audible_autoplay = v;
        }
        // Same shape, same reason: no row means the default, and the default
        // blocks. Upgrading must not quietly open the pop-up gate.
        if let Some(v) =
            get_meta(&self.conn, "block_unprompted_windows")?.and_then(|v| v.parse().ok())
        {
            prefs.block_unprompted_windows = v;
        }
        // Same shape once more. These two have no row a person can change yet,
        // but they are stored like every other preference so the day a host or
        // a Settings row wants to move them, storage is not the half that is
        // missing (ADR-0120).
        if let Some(v) = get_meta(&self.conn, "background_throttling")?.and_then(|v| v.parse().ok())
        {
            prefs.background_throttling = v;
        }
        if let Some(v) = get_meta(&self.conn, "https_first")?.and_then(|v| v.parse().ok()) {
            prefs.https_first = v;
        }

        let mut stmt = self.conn.prepare("SELECT host FROM blocking_exceptions")?;
        let rows = stmt.query_map([], |row| row.get::<_, String>(0))?;
        prefs.blocking_exceptions = rows.collect::<rusqlite::Result<_>>()?;

        Ok(prefs)
    }

    fn load_keybindings(&self) -> Result<Vec<Binding>> {
        let mut stmt = self.conn.prepare(
            "SELECT key_kind, key_value, primary_mod, shift, alt, control, command, command_arg
             FROM keybindings",
        )?;
        let rows = stmt.query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                Modifiers {
                    primary: row.get(2)?,
                    shift: row.get(3)?,
                    alt: row.get(4)?,
                    control: row.get(5)?,
                },
                row.get::<_, String>(6)?,
                row.get::<_, Option<i64>>(7)?,
            ))
        })?;

        let mut bindings = Vec::new();
        for row in rows {
            let (kind, value, modifiers, command, arg) = row?;
            // A key or command this version does not know is skipped rather
            // than failing the load: better to lose one rebind than a session.
            let (Some(key), Some(command)) =
                (key_from_row(&kind, value), command_from_row(&command, arg))
            else {
                continue;
            };
            bindings.push(Binding {
                chord: Chord { key, modifiers },
                command,
            });
        }
        Ok(bindings)
    }

    fn load_routes(&self) -> Result<RoutingTable> {
        let mut stmt = self
            .conn
            .prepare("SELECT kind, value, space_id, enabled FROM routes ORDER BY position")?;
        let rows = stmt.query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, i64>(2)?,
                row.get::<_, bool>(3)?,
            ))
        })?;

        let mut routes = Vec::new();
        for row in rows {
            let (kind, value, space, enabled) = row?;
            // An unknown rule kind means a downgrade. Skipping it is better
            // than refusing to load the whole session.
            if let Some(pattern) = pattern_from_row(&kind, value) {
                routes.push(Route {
                    pattern,
                    space: SpaceId(space as u64),
                    enabled,
                });
            }
        }
        Ok(RoutingTable::load(routes))
    }

    /// Threads, oldest first, with their messages in order.
    ///
    /// Two passes rather than a join, so the outcome does not depend on the
    /// order rows come back in (ADR-0045, clause 4).
    fn load_conversations(&self) -> Result<Vec<Conversation>> {
        let pages = self.load_conversation_pages()?;
        let mut stmt = self.conn.prepare(
            "SELECT id, scope_kind, scope_id, created_at_ms FROM conversations ORDER BY position",
        )?;
        let rows = stmt.query_map([], |row| {
            Ok((
                row.get::<_, i64>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, i64>(2)?,
                row.get::<_, i64>(3)?,
            ))
        })?;

        let mut conversations = Vec::new();
        for row in rows {
            let (id, scope_kind, scope_id, created_at_ms) = row?;
            // A scope this version does not understand means a downgrade, and
            // so does a page row whose address this version cannot read.
            // Skipping the thread is better than refusing the whole session.
            let Some(scope) =
                scope_from_row(&scope_kind, scope_id, pages.get(&id).map(String::as_str))
            else {
                continue;
            };
            let messages = self.load_chat_messages(id)?;
            // Never written empty, so an empty one is a half-written file.
            // Repair, do not invent (ADR-0045, clause 2).
            if messages.is_empty() {
                continue;
            }
            conversations.push(Conversation {
                id: ConversationId(id as u64),
                scope,
                messages,
                error: None,
                awaiting_page: false,
                created_at_ms: created_at_ms as u64,
            });
        }
        Ok(conversations)
    }

    /// The address each page-anchored thread is about, by conversation id.
    ///
    /// Read whole and up front rather than one query per thread, so
    /// reconstruction does not depend on the order rows come back in
    /// (ADR-0045, clause 4).
    fn load_conversation_pages(&self) -> Result<HashMap<i64, String>> {
        let mut stmt = self
            .conn
            .prepare("SELECT conversation_id, url FROM conversation_pages")?;
        let rows = stmt.query_map([], |row| {
            Ok((row.get::<_, i64>(0)?, row.get::<_, String>(1)?))
        })?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    fn load_chat_messages(&self, conversation: i64) -> Result<Vec<Message>> {
        let mut stmt = self.conn.prepare(
            "SELECT id, role, text, url, title, state, model, created_at_ms
             FROM chat_messages WHERE conversation_id = ?1 ORDER BY position",
        )?;
        let rows = stmt.query_map([conversation], |row| {
            Ok((
                row.get::<_, i64>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, Option<String>>(3)?,
                row.get::<_, Option<String>>(4)?,
                row.get::<_, String>(5)?,
                row.get::<_, Option<String>>(6)?,
                row.get::<_, i64>(7)?,
            ))
        })?;

        let mut messages = Vec::new();
        for row in rows {
            let (id, role, text, url, title, state, model, created_at_ms) = row?;
            let Some(role) = role_from_row(&role) else {
                continue;
            };
            let page = (role == MessageRole::PageContext).then(|| PageReference {
                url: url.unwrap_or_default(),
                title: title.unwrap_or_default(),
            });
            messages.push(Message {
                id: MessageId(id as u64),
                role,
                text,
                page,
                state: message_state_from_row(&state),
                // Unrepresentable in the projection, so there is nothing here
                // to read back. A restored thread holds no live call and no
                // consent prompt waiting for an answer nobody remembers giving.
                tool_calls: Vec::new(),
                answers: None,
                model,
                created_at_ms: created_at_ms as u64,
            });
        }
        Ok(messages)
    }

    fn load_tool_consent(&self) -> Result<ToolConsent> {
        let mut stmt = self
            .conn
            .prepare("SELECT server, tool, allowed, decided_at_ms FROM tool_consent")?;
        let rows = stmt.query_map([], |row| {
            Ok(ToolGrant {
                server: row.get(0)?,
                tool: row.get(1)?,
                allowed: row.get(2)?,
                decided_at_ms: row.get::<_, i64>(3)? as u64,
            })
        })?;
        Ok(ToolConsent::load(rows.collect::<rusqlite::Result<_>>()?))
    }

    /// The shapes, read whole and never joined against `tool_consent`.
    ///
    /// A shape with no grant beside it is harmless — it grants nothing — and a
    /// grant with no shape is the state that fails closed. Filtering either
    /// against the other here would be this backend deciding what a missing row
    /// means, and that decision belongs to `McpRegistry::verdict`.
    fn load_tool_shapes(&self) -> Result<Vec<ApprovedShape>> {
        let mut stmt = self
            .conn
            .prepare("SELECT server, tool, fingerprint FROM tool_shapes")?;
        let rows = stmt.query_map([], |row| {
            Ok(ApprovedShape {
                server: row.get(0)?,
                tool: row.get(1)?,
                fingerprint: row.get(2)?,
            })
        })?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }
}

/// How a conversation's scope is spelled in this schema.
///
/// Both kinds carry a space in `scope_id`; only a `page` row carries an address
/// too, and it goes in `conversation_pages`.
fn scope_to_row(scope: &ConversationScope) -> (&'static str, i64) {
    match scope {
        ConversationScope::Page { space, .. } => ("page", space.0 as i64),
        ConversationScope::Space { space } => ("space", space.0 as i64),
    }
}

/// `None` for a row this version cannot make sense of, which drops the one
/// conversation and keeps the session (ADR-0045, clause 2).
///
/// `page` is re-read through [`PageAnchor::of`] rather than trusted as written.
/// A file is a boundary like any other: a hand-edited row, or one written by a
/// version whose idea of "the same page" was not this one, would otherwise key
/// a thread on an address that this build can never produce again — a thread
/// that exists, holds a URL, and can never be reached from the page it names.
fn scope_from_row(kind: &str, id: i64, page: Option<&str>) -> Option<ConversationScope> {
    match kind {
        "page" => Some(ConversationScope::Page {
            space: SpaceId(id as u64),
            page: PageAnchor::of(page?)?,
        }),
        "space" => Some(ConversationScope::Space {
            space: SpaceId(id as u64),
        }),
        _ => None,
    }
}

/// One message flattened into columns.
struct MessageRow<'a> {
    role: &'static str,
    text: &'a str,
    url: Option<&'a str>,
    title: Option<&'a str>,
    state: &'static str,
    model: Option<&'a str>,
    created_at_ms: u64,
}

/// How a message is spelled in this schema.
///
/// No judgement in any arm. What is written down at all, and what a reply that
/// was still arriving is written down as, were decided in
/// [`StorableSession::project`]; by the time a value reaches here there is
/// nothing left to decide — which is why a page carries no text and a tool
/// result has no arm.
fn message_to_row(message: &StorableMessage) -> MessageRow<'_> {
    match message {
        StorableMessage::User {
            text,
            created_at_ms,
            ..
        } => MessageRow {
            role: "user",
            text,
            url: None,
            title: None,
            state: "complete",
            model: None,
            created_at_ms: *created_at_ms,
        },
        StorableMessage::Assistant {
            text,
            state,
            model,
            created_at_ms,
            ..
        } => MessageRow {
            role: "assistant",
            text,
            url: None,
            title: None,
            state: match state {
                StorableMessageState::Complete => "complete",
                StorableMessageState::Interrupted => "interrupted",
            },
            model: model.as_deref(),
            created_at_ms: *created_at_ms,
        },
        StorableMessage::Page {
            url,
            title,
            created_at_ms,
            ..
        } => MessageRow {
            role: "page",
            text: "",
            url: Some(url),
            title: Some(title),
            state: "complete",
            model: None,
            created_at_ms: *created_at_ms,
        },
    }
}

fn role_from_row(role: &str) -> Option<MessageRole> {
    match role {
        "user" => Some(MessageRole::User),
        "assistant" => Some(MessageRole::Assistant),
        "page" => Some(MessageRole::PageContext),
        // Including "tool", which this schema never writes. A row spelling one
        // is a hand-edited file or a future version, and either way an answer
        // to a call nothing can produce is not something to bring back.
        _ => None,
    }
}

fn message_state_from_row(state: &str) -> MessageState {
    match state {
        "interrupted" => MessageState::Interrupted,
        // Anything unrecognised reads as finished, which is the only reading
        // that cannot make a stored thread look like it is still working.
        _ => MessageState::Complete,
    }
}

fn set_meta(conn: &Connection, key: &str, value: &str) -> Result<()> {
    conn.execute(
        "INSERT INTO meta (key, value) VALUES (?1, ?2)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        params![key, value],
    )?;
    Ok(())
}

fn get_meta(conn: &Connection, key: &str) -> Result<Option<String>> {
    Ok(conn
        .query_row("SELECT value FROM meta WHERE key = ?1", params![key], |r| {
            r.get(0)
        })
        .optional()?)
}

fn theme_to_str(theme: ThemePreference) -> &'static str {
    match theme {
        ThemePreference::System => "system",
        ThemePreference::Light => "light",
        ThemePreference::Dark => "dark",
    }
}

fn theme_from_str(value: &str) -> ThemePreference {
    match value {
        "light" => ThemePreference::Light,
        "dark" => ThemePreference::Dark,
        _ => ThemePreference::System,
    }
}

/// `urls:` followed by newline-separated URLs, since a URL cannot contain one.
fn startup_to_str(startup: &StartupBehaviour) -> String {
    match startup {
        StartupBehaviour::RestoreSession => "restore".to_string(),
        StartupBehaviour::NewTab => "new_tab".to_string(),
        StartupBehaviour::SpecificUrls { urls } => format!("urls:{}", urls.join("\n")),
    }
}

fn startup_from_str(value: &str) -> StartupBehaviour {
    match value {
        "new_tab" => StartupBehaviour::NewTab,
        v if v.starts_with("urls:") => StartupBehaviour::SpecificUrls {
            urls: v[5..]
                .split('\n')
                .filter(|u| !u.trim().is_empty())
                .map(str::to_string)
                .collect(),
        },
        _ => StartupBehaviour::RestoreSession,
    }
}

fn key_to_row(key: &Key) -> (&'static str, String) {
    match key {
        Key::Char { value } => ("char", value.clone()),
        Key::Enter => ("enter", String::new()),
        Key::Escape => ("escape", String::new()),
        Key::Tab => ("tab", String::new()),
        Key::Space => ("space", String::new()),
        Key::Backspace => ("backspace", String::new()),
        Key::Left => ("left", String::new()),
        Key::Right => ("right", String::new()),
        Key::Up => ("up", String::new()),
        Key::Down => ("down", String::new()),
    }
}

fn key_from_row(kind: &str, value: String) -> Option<Key> {
    Some(match kind {
        "char" => Key::Char { value },
        "enter" => Key::Enter,
        "escape" => Key::Escape,
        "tab" => Key::Tab,
        "space" => Key::Space,
        "backspace" => Key::Backspace,
        "left" => Key::Left,
        "right" => Key::Right,
        "up" => Key::Up,
        "down" => Key::Down,
        _ => return None,
    })
}

fn command_to_row(command: &UiCommand) -> (&'static str, Option<i64>) {
    match command {
        UiCommand::NewTab => ("new_tab", None),
        UiCommand::CloseTab => ("close_tab", None),
        UiCommand::ReopenClosedTab => ("reopen_closed_tab", None),
        UiCommand::OpenLocation => ("open_location", None),
        UiCommand::Back => ("back", None),
        UiCommand::Forward => ("forward", None),
        UiCommand::Reload => ("reload", None),
        UiCommand::ReloadIgnoringCache => ("reload_ignoring_cache", None),
        UiCommand::CopyCurrentUrl => ("copy_current_url", None),
        UiCommand::NextTab => ("next_tab", None),
        UiCommand::PreviousTab => ("previous_tab", None),
        UiCommand::SelectTab { index } => ("select_tab", Some(*index as i64)),
        UiCommand::RunPinnedExtension { index } => ("run_pinned_extension", Some(*index as i64)),
        UiCommand::AddBookmark => ("add_bookmark", None),
        UiCommand::ToggleBookmarks => ("toggle_bookmarks", None),
        UiCommand::TogglePinTab => ("toggle_pin_tab", None),
        UiCommand::ToggleMuteTab => ("toggle_mute_tab", None),
        UiCommand::ToggleBlockingHere => ("toggle_blocking_here", None),
        UiCommand::OpenChat => ("open_chat", None),
        UiCommand::NewWindow => ("new_window", None),
        UiCommand::CloseWindow => ("close_window", None),
        UiCommand::NewPrivateWindow => ("new_private_window", None),
        UiCommand::NewSpace => ("new_space", None),
        UiCommand::NextSpace => ("next_space", None),
        UiCommand::PreviousSpace => ("previous_space", None),
        UiCommand::SelectSpace { index } => ("select_space", Some(*index as i64)),
        UiCommand::ToggleSplitView => ("toggle_split_view", None),
        UiCommand::FocusOtherPane => ("focus_other_pane", None),
        UiCommand::ToggleSidebar => ("toggle_sidebar", None),
        UiCommand::SavePage => ("save_page", None),
        UiCommand::PrintPage => ("print_page", None),
        UiCommand::ViewSource => ("view_source", None),
        UiCommand::ToggleDevTools => ("toggle_dev_tools", None),
        UiCommand::StopLoading => ("stop_loading", None),
        UiCommand::FindInPage => ("find_in_page", None),
        UiCommand::FindNext => ("find_next", None),
        UiCommand::FindPrevious => ("find_previous", None),
        UiCommand::ShowHistory => ("show_history", None),
        UiCommand::ShowDownloads => ("show_downloads", None),
        UiCommand::ShowSettings => ("show_settings", None),
        UiCommand::ShowExtensions => ("show_extensions", None),
        UiCommand::ZoomIn => ("zoom_in", None),
        UiCommand::ZoomOut => ("zoom_out", None),
        UiCommand::ZoomReset => ("zoom_reset", None),
    }
}

fn command_from_row(command: &str, arg: Option<i64>) -> Option<UiCommand> {
    Some(match command {
        "new_tab" => UiCommand::NewTab,
        "close_tab" => UiCommand::CloseTab,
        "reopen_closed_tab" => UiCommand::ReopenClosedTab,
        "open_location" => UiCommand::OpenLocation,
        "back" => UiCommand::Back,
        "forward" => UiCommand::Forward,
        "reload" => UiCommand::Reload,
        "reload_ignoring_cache" => UiCommand::ReloadIgnoringCache,
        "copy_current_url" => UiCommand::CopyCurrentUrl,
        "next_tab" => UiCommand::NextTab,
        "previous_tab" => UiCommand::PreviousTab,
        "select_tab" => UiCommand::SelectTab {
            index: u8::try_from(arg?).ok()?,
        },
        "run_pinned_extension" => UiCommand::RunPinnedExtension {
            index: u8::try_from(arg?).ok()?,
        },
        "add_bookmark" => UiCommand::AddBookmark,
        "toggle_bookmarks" => UiCommand::ToggleBookmarks,
        "toggle_pin_tab" => UiCommand::TogglePinTab,
        "toggle_mute_tab" => UiCommand::ToggleMuteTab,
        "toggle_blocking_here" => UiCommand::ToggleBlockingHere,
        "open_chat" => UiCommand::OpenChat,
        "new_window" => UiCommand::NewWindow,
        "close_window" => UiCommand::CloseWindow,
        "new_private_window" => UiCommand::NewPrivateWindow,
        "new_space" => UiCommand::NewSpace,
        "next_space" => UiCommand::NextSpace,
        "previous_space" => UiCommand::PreviousSpace,
        "select_space" => UiCommand::SelectSpace {
            index: u8::try_from(arg?).ok()?,
        },
        "toggle_split_view" => UiCommand::ToggleSplitView,
        "focus_other_pane" => UiCommand::FocusOtherPane,
        "toggle_sidebar" => UiCommand::ToggleSidebar,
        "save_page" => UiCommand::SavePage,
        "print_page" => UiCommand::PrintPage,
        "view_source" => UiCommand::ViewSource,
        "toggle_dev_tools" => UiCommand::ToggleDevTools,
        "stop_loading" => UiCommand::StopLoading,
        "find_in_page" => UiCommand::FindInPage,
        "find_next" => UiCommand::FindNext,
        "find_previous" => UiCommand::FindPrevious,
        "show_history" => UiCommand::ShowHistory,
        "show_downloads" => UiCommand::ShowDownloads,
        "show_settings" => UiCommand::ShowSettings,
        "show_extensions" => UiCommand::ShowExtensions,
        "zoom_in" => UiCommand::ZoomIn,
        "zoom_out" => UiCommand::ZoomOut,
        "zoom_reset" => UiCommand::ZoomReset,
        _ => return None,
    })
}

/// How a download is spelled in this schema.
///
/// Two arms and no judgement in either. Which downloads are written down at
/// all, and what a still-running one is written down as, are decided in
/// [`StorableSession::project`]; by the time a state reaches this function
/// there is nothing left to decide, which is why it can no longer return
/// `None`.
fn download_state_to_str(state: StorableDownloadState) -> &'static str {
    match state {
        StorableDownloadState::Completed => "completed",
        StorableDownloadState::Interrupted => "interrupted",
    }
}

/// Anything unrecognised reads as interrupted: the honest reading of a row we
/// cannot interpret is "something was going on and we do not know how it
/// ended", which is what interrupted means.
fn download_state_from_str(value: &str) -> DownloadState {
    match value {
        "completed" => DownloadState::Completed,
        _ => DownloadState::Interrupted,
    }
}

fn kind_to_str(kind: TabKind) -> &'static str {
    match kind {
        TabKind::Favorite => "favorite",
        TabKind::Pinned => "pinned",
        TabKind::Today => "today",
    }
}

/// Unrecognised values become `Today`, the safest kind to be wrong about: it
/// expires rather than pinning something forever.
fn kind_from_str(s: &str) -> TabKind {
    match s {
        "favorite" => TabKind::Favorite,
        "pinned" => TabKind::Pinned,
        _ => TabKind::Today,
    }
}

fn pattern_to_row(pattern: &RoutePattern) -> (&'static str, String) {
    match pattern {
        RoutePattern::Domain { host } => ("domain", host.clone()),
        RoutePattern::DomainContains { fragment } => ("domain_contains", fragment.clone()),
        RoutePattern::UrlContains { fragment } => ("url_contains", fragment.clone()),
        RoutePattern::Regex { pattern } => ("regex", pattern.clone()),
    }
}

fn pattern_from_row(kind: &str, value: String) -> Option<RoutePattern> {
    Some(match kind {
        "domain" => RoutePattern::Domain { host: value },
        "domain_contains" => RoutePattern::DomainContains { fragment: value },
        "url_contains" => RoutePattern::UrlContains { fragment: value },
        "regex" => RoutePattern::Regex { pattern: value },
        _ => return None,
    })
}

#[cfg(test)]
#[path = "store_tests.rs"]
mod tests;
