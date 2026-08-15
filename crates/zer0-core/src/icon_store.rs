//! Where site icons sit between launches.
//!
//! A file of its own, beside `session.sqlite` rather than inside it. The
//! reasoning is ADR-0044's, and it comes down to two things the session file
//! cannot afford:
//!
//! - **Blast radius.** ADR-0006 says a session file that opens but does not
//!   read detaches the store: the browser runs for the whole session writing
//!   nothing. Icons are the least important bytes in the browser, the largest,
//!   and the only ones that arrive from a stranger. Putting them in the
//!   session file lets the least important data cost the most important.
//! - **Write shape.** A session save is a full rewrite inside one transaction,
//!   every twenty seconds. Rewriting every icon on that schedule is the wrong
//!   shape for a blob cache; a row here is written once, when it arrives.

use std::path::Path;

use rusqlite::{Connection, params};

use crate::icons::StoredIcon;
use crate::store::{Result, StoreError};

/// Bumped whenever the shape changes. There is no migration step here either,
/// and unlike the session there does not need to be: this file is a cache, and
/// the recovery for one that cannot be read is to start it again.
const SCHEMA_VERSION: i64 = 1;

const SCHEMA: &str = "
CREATE TABLE IF NOT EXISTS icons (
    data_store_id TEXT    NOT NULL,
    host          TEXT    NOT NULL,
    bytes         BLOB    NOT NULL,
    fetched_at_ms INTEGER NOT NULL,
    PRIMARY KEY (data_store_id, host)
);
";

pub struct IconStore {
    conn: Connection,
}

impl IconStore {
    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        Self::prepare(Connection::open(path)?)
    }

    pub fn in_memory() -> Result<Self> {
        Self::prepare(Connection::open_in_memory()?)
    }

    fn prepare(conn: Connection) -> Result<Self> {
        conn.pragma_update(None, "journal_mode", "WAL")?;
        conn.execute_batch(SCHEMA)?;
        conn.pragma_update(None, "user_version", SCHEMA_VERSION)?;
        Ok(Self { conn })
    }

    /// Everything on disk, for warming the cache at launch.
    ///
    /// A row whose blob is not an image any more — a format we stopped
    /// accepting, a file someone edited by hand — is dropped rather than
    /// returned. ADR-0024: what comes off the disk is treated exactly as
    /// hostilely as what came off the wire, and it *did* come off the wire.
    /// An empty blob is kept, because an empty blob is the record of a site
    /// that had nothing and is the reason we are not asking it again.
    pub fn all(&self) -> Result<Vec<StoredIcon>> {
        let mut statement = self
            .conn
            .prepare("SELECT data_store_id, host, bytes, fetched_at_ms FROM icons")?;

        let rows = statement.query_map([], |row| {
            Ok(StoredIcon {
                data_store_id: row.get(0)?,
                host: row.get(1)?,
                bytes: row.get(2)?,
                fetched_at_ms: row.get::<_, i64>(3)?.max(0) as u64,
            })
        })?;

        let mut out = Vec::new();
        for row in rows {
            let icon = row?;
            if icon.is_missing() || crate::icons::is_image(&icon.bytes) {
                out.push(icon);
            }
        }
        Ok(out)
    }

    /// One icon, written now rather than at the next session save.
    ///
    /// A cache that only reached disk on a clean quit would be re-fetched
    /// after every crash, and a re-fetch is a network request to every site
    /// you had open.
    pub fn put(&mut self, icon: &StoredIcon) -> Result<()> {
        // Refusing here as well as in the reducer, because this is the last
        // place before the bytes are on disk and it costs one branch.
        if !icon.is_missing() && !crate::icons::is_image(&icon.bytes) {
            return Err(StoreError::Unusable);
        }
        self.conn.execute(
            "INSERT OR REPLACE INTO icons (data_store_id, host, bytes, fetched_at_ms)
             VALUES (?1, ?2, ?3, ?4)",
            params![
                icon.data_store_id,
                icon.host,
                icon.bytes,
                icon.fetched_at_ms as i64
            ],
        )?;
        Ok(())
    }

    /// Every row belonging to a cookie jar that is gone.
    pub fn forget_data_store(&mut self, data_store_id: &str) -> Result<()> {
        self.conn.execute(
            "DELETE FROM icons WHERE data_store_id = ?1",
            params![data_store_id],
        )?;
        Ok(())
    }
}

#[cfg(test)]
#[path = "icon_store_tests.rs"]
mod tests;
