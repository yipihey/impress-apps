//! Database access for the shared impress store (read-only).
//!
//! Opens `impress.sqlite` to look up publication metadata (title, authors,
//! year, cite_key) for items with `schema_ref LIKE '%bibliography-entry%'`.

use rusqlite::Connection;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::Path;
use std::time::Duration;

/// Minimal publication metadata extracted from the shared store.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct PublicationMeta {
    pub id: String,
    pub title: String,
    pub authors: String,
    pub year: Option<i32>,
    pub cite_key: String,
}

/// How long to wait for a lock before giving up. The app writes constantly;
/// waiting forever turns a busy database into a hung MCP session.
const BUSY_TIMEOUT: Duration = Duration::from_secs(5);

/// Open the main impress store for reading.
///
/// **Not** `SQLITE_OPEN_READ_ONLY`, despite only ever reading. The store runs in
/// WAL mode, and a read-only connection may not create or write the `-shm`
/// index that WAL readers use; SQLite then falls back to scanning the whole WAL
/// to build a private snapshot. Against the live store — ~317 MB with a 167 MB
/// WAL — that took minutes, which is why `impress://store/schemas` appeared to
/// hang and why opening the store at startup stalled `initialize`.
///
/// So: open read-write so WAL indexing works normally, then forbid writes with
/// `PRAGMA query_only`, which is enforced by SQLite itself rather than by
/// convention. Falls back to read-only if the file is genuinely not writable
/// (someone else's store, a locked volume), where slow-but-working beats
/// failing.
pub fn open_main_store(path: &Path) -> Result<Connection, String> {
    if !path.exists() {
        return Err(format!("Main store not found: {}", path.display()));
    }
    let read_write = rusqlite::OpenFlags::SQLITE_OPEN_READ_WRITE
        | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX
        | rusqlite::OpenFlags::SQLITE_OPEN_URI;
    let conn = match Connection::open_with_flags(path, read_write) {
        Ok(conn) => conn,
        Err(_) => Connection::open_with_flags(
            path,
            rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX,
        )
        .map_err(|e| format!("Failed to open main store: {}", e))?,
    };
    conn.busy_timeout(BUSY_TIMEOUT)
        .map_err(|e| format!("busy_timeout: {e}"))?;
    // Enforced by SQLite: any write on this connection now errors.
    conn.pragma_update(None, "query_only", "ON")
        .map_err(|e| format!("query_only: {e}"))?;
    Ok(conn)
}

/// Batch lookup of publication metadata by IDs.
pub fn list_publications_by_ids(
    conn: &Connection,
    ids: &[String],
) -> Result<HashMap<String, PublicationMeta>, String> {
    if ids.is_empty() {
        return Ok(HashMap::new());
    }

    // Build parameterized query with placeholders
    let placeholders: Vec<String> = ids
        .iter()
        .enumerate()
        .map(|(i, _)| format!("?{}", i + 1))
        .collect();
    let sql = format!(
        "SELECT id, payload FROM items WHERE id IN ({}) AND schema_ref LIKE '%bibliography-entry%'",
        placeholders.join(", ")
    );

    let mut stmt = conn
        .prepare(&sql)
        .map_err(|e| format!("Prepare error: {}", e))?;

    let params: Vec<&dyn rusqlite::types::ToSql> = ids
        .iter()
        .map(|s| s as &dyn rusqlite::types::ToSql)
        .collect();

    let rows = stmt
        .query_map(params.as_slice(), |row| {
            let id: String = row.get(0)?;
            let payload_json: String = row.get(1)?;
            Ok((id, payload_json))
        })
        .map_err(|e| format!("Query error: {}", e))?;

    let mut map = HashMap::new();
    for row in rows {
        let (id, payload_json) = row.map_err(|e| format!("Row error: {}", e))?;
        let meta = parse_publication_payload(&id, &payload_json);
        map.insert(id, meta);
    }
    Ok(map)
}

/// Parse the JSON payload from an items row into PublicationMeta.
fn parse_publication_payload(id: &str, payload_json: &str) -> PublicationMeta {
    let payload: serde_json::Value =
        serde_json::from_str(payload_json).unwrap_or(serde_json::Value::Null);

    let title = payload
        .get("title")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();

    let authors = payload
        .get("author_text")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();

    let year = payload
        .get("year")
        .and_then(|v| v.as_i64())
        .map(|y| y as i32);

    let cite_key = payload
        .get("cite_key")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();

    PublicationMeta {
        id: id.to_string(),
        title,
        authors,
        year,
        cite_key,
    }
}
