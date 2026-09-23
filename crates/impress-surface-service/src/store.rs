//! The store side of a surface: `impress/ui/surface@1.0.0`,
//! `impress/ui/surface-state@1.0.0` and `impress/ui/surface-event@1.0.0` rows
//! (ADR-0033 D1/D5).
//!
//! # Scope, mirroring `impress-layout-service/src/store.rs`
//!
//! * The **surface** row itself is `Private` + `Durable`, and syncs like a
//!   named layout: an agent-built surface is a durable artifact of the
//!   conversation, not scratch state (`impress-core/src/schemas/ui.rs`'s
//!   module docs).
//! * The **state** row is one per `(surface, host)`, `Private` +
//!   `Ephemeral`, device-scoped by `host` — the same shape the layout tree's
//!   *live* row uses for `device` (never synced, exists so a process in
//!   another chat can read back what the human changed).
//! * The **event** rows are append-only, `Private` + `Ephemeral`, pruned to
//!   the last 200 per `(surface, host)` (ADR-0033 D5) — the same privacy
//!   reasoning ADR-0031 D7 gives for exploration churn: nothing is recorded
//!   here that exists only to be analysed later.
//!
//! # Attribution
//!
//! Every write after the first goes through
//! [`SqliteItemStore::apply_operation`] exactly as the layout store's module
//! docs describe: an insert (the row's creation) is attributed on the
//! envelope but is not itself an operation, so there is no tier to set on
//! it; every later write picks [`RetentionTier::Durable`] +
//! [`OperationIntent::Editorial`] (the surface row's `spec`) or
//! [`RetentionTier::Ephemeral`] + [`OperationIntent::Routine`] (the state
//! row) explicitly. Event rows are never patched, only inserted and later
//! hard-deleted by pruning, so they carry no operation at all — the same
//! reasoning the layout store gives for why a row's *creation* is a plain
//! insert.

use std::collections::BTreeMap;
use std::sync::Arc;

use chrono::{DateTime, Utc};
// Aliased: this module's own public API speaks `serde_json::Value` (the
// shape every other module in this crate uses), and only converts to the
// store's own `impress_core::item::Value` at the point of writing a payload
// field — see `spec_json`/`parse_json` and the `ItemValue::String(...)`
// constructions below.
use impress_core::item::Value as ItemValue;
use impress_core::item::{ActorKind, Item, ItemId, Priority, Visibility};
use impress_core::operation::{OperationIntent, OperationSpec, OperationType, RetentionTier};
use impress_core::query::ItemQuery;
use impress_core::schemas::{
    SURFACE_EVENT_SCHEMA_REF, SURFACE_SCHEMA_REF, SURFACE_STATE_SCHEMA_REF,
};
use impress_core::sqlite_store::SqliteItemStore;
use impress_core::store::ItemStore;
use impress_surface::SurfaceSpec;
use serde_json::Value;

/// How many events a `(surface, host)` ring keeps. ADR-0033 D5.
pub const EVENT_RING_CAPACITY: usize = 200;

/// Payload field names, spelled once. Copy these, never retype the strings:
/// a reader that spells a field differently from its writer reads `None`
/// forever and looks exactly like "nothing saved yet" (root CLAUDE.md,
/// "Definition of done — schema refs").
pub mod field {
    pub mod surface {
        pub const NAME: &str = "name";
        pub const VERSION: &str = "version";
        pub const SPEC: &str = "spec";
        pub const TAGS: &str = "tags";
    }
    pub mod state {
        pub const SURFACE: &str = "surface";
        pub const HOST: &str = "host";
        pub const STATE: &str = "state";
        pub const CURSOR: &str = "cursor";
    }
    pub mod event {
        pub const SURFACE: &str = "surface";
        pub const HOST: &str = "host";
        pub const SEQ: &str = "seq";
        pub const NAME: &str = "name";
        pub const PAYLOAD: &str = "payload";
        pub const AT: &str = "at";
    }
}

/// What went wrong, as a sentence — the same `Result<T> = Result<T, String>`
/// shape every other store-generic `#[impress_service]` crate in the suite
/// uses.
pub type Result<T> = std::result::Result<T, String>;

/// One `impress/ui/surface@1.0.0` row, spec included.
#[derive(Debug, Clone, PartialEq)]
pub struct SurfaceRow {
    pub id: ItemId,
    pub name: String,
    pub version: Option<String>,
    pub spec: SurfaceSpec,
    pub tags: Vec<String>,
    pub created: DateTime<Utc>,
    pub modified: DateTime<Utc>,
}

/// One `impress/ui/surface-event@1.0.0` row.
#[derive(Debug, Clone, PartialEq)]
pub struct EventRow {
    pub surface: ItemId,
    pub host: String,
    pub seq: u64,
    pub name: String,
    pub payload: Value,
    pub at: DateTime<Utc>,
}

/// Store-backed access to a surface's three record kinds.
#[derive(Clone)]
pub struct SurfaceStore {
    store: Arc<SqliteItemStore>,
}

impl SurfaceStore {
    pub fn new(store: Arc<SqliteItemStore>) -> Self {
        Self { store }
    }

    pub fn store(&self) -> &Arc<SqliteItemStore> {
        &self.store
    }

    // ------------------------------------------------------------- surfaces

    /// Create a surface row. `name` overrides `spec.name` on the ROW's own
    /// `name` field when given; the spec's own `name` is untouched either
    /// way (it is the document's own title, the row's `name` is how
    /// `surface_list` labels it — the same distinction a saved layout's row
    /// `name` makes from nothing inside the tree it stores).
    pub fn create(
        &self,
        spec: &SurfaceSpec,
        name: Option<&str>,
        tags: &[String],
        actor: ActorKind,
    ) -> Result<SurfaceRow> {
        let name = name
            .map(str::trim)
            .filter(|n| !n.is_empty())
            .unwrap_or(spec.name.trim());
        if name.is_empty() {
            return Err("a surface needs a name (its own `name` field, or an override)".into());
        }
        let mut payload: BTreeMap<String, ItemValue> = BTreeMap::new();
        payload.insert(field::surface::NAME.into(), ItemValue::String(name.into()));
        payload.insert(
            field::surface::SPEC.into(),
            ItemValue::String(spec_json(spec)?),
        );
        if !tags.is_empty() {
            payload.insert(
                field::surface::TAGS.into(),
                ItemValue::Array(tags.iter().cloned().map(ItemValue::String).collect()),
            );
        }
        let now = Utc::now();
        let item = Item {
            id: uuid::Uuid::new_v4(),
            schema: SURFACE_SCHEMA_REF.into(),
            payload,
            created: now,
            modified: now,
            author: author_for(actor),
            author_kind: actor,
            logical_clock: 0,
            origin: None,
            canonical_id: None,
            tags: vec![],
            flag: None,
            is_read: false,
            is_starred: false,
            priority: Priority::None,
            visibility: Visibility::Private,
            message_type: None,
            produced_by: None,
            version: None,
            batch_id: None,
            references: vec![],
            parent: None,
        };
        let id = self
            .store
            .insert(item)
            .map_err(|e| format!("write surface: {e}"))?;
        self.get(id)?
            .ok_or_else(|| "surface vanished immediately after creation".to_string())
    }

    /// Replace a surface's spec (and re-derive the row's `name` from the
    /// new spec, since `surface_update` takes no separate name argument —
    /// the only remaining source of truth for it is the spec itself).
    /// `Durable` + `Editorial`: this is a commit, like `save_named` on a
    /// layout.
    pub fn update(&self, id: ItemId, spec: &SurfaceSpec, actor: ActorKind) -> Result<SurfaceRow> {
        let _existing = self
            .row_item(id)?
            .ok_or_else(|| format!("no surface {id}"))?;
        self.patch(
            id,
            field::surface::NAME,
            ItemValue::String(spec.name.trim().to_string()),
            actor,
            "renamed to match the updated spec",
            Ephemerality::Commit,
        )?;
        self.patch(
            id,
            field::surface::SPEC,
            ItemValue::String(spec_json(spec)?),
            actor,
            "updated the spec",
            Ephemerality::Commit,
        )?;
        self.get(id)?
            .ok_or_else(|| "surface vanished mid-update".to_string())
    }

    pub fn get(&self, id: ItemId) -> Result<Option<SurfaceRow>> {
        let Some(item) = self.row_item(id)? else {
            return Ok(None);
        };
        Ok(Some(surface_row_of(&item)?))
    }

    pub fn list(&self) -> Result<Vec<SurfaceRow>> {
        let query = ItemQuery {
            schema: Some(SURFACE_SCHEMA_REF.into()),
            include_tags: false,
            include_references: false,
            ..Default::default()
        };
        let mut rows: Vec<SurfaceRow> = self
            .store
            .query(&query)
            .map_err(|e| format!("read surfaces: {e}"))?
            .iter()
            .map(surface_row_of)
            .collect::<Result<Vec<_>>>()?;
        rows.sort_by_key(|r| r.created);
        Ok(rows)
    }

    /// Delete a surface AND every state/event row that belongs to it — an
    /// orphaned state/event row (whose `surface` names a row that no longer
    /// exists) is exactly the ambiguity `impress/ui/surface-state`'s module
    /// docs warn a required-but-dangling foreign key produces, so this
    /// crate never leaves one behind.
    pub fn delete(&self, id: ItemId) -> Result<bool> {
        if self.row_item(id)?.is_none() {
            return Ok(false);
        }
        for state in self.all_state_rows(id)? {
            self.store
                .delete(state.id)
                .map_err(|e| format!("delete surface state: {e}"))?;
        }
        for event in self.all_event_items(id)? {
            self.store
                .delete(event.id)
                .map_err(|e| format!("delete surface event: {e}"))?;
        }
        self.store
            .delete(id)
            .map_err(|e| format!("delete surface: {e}"))?;
        Ok(true)
    }

    fn row_item(&self, id: ItemId) -> Result<Option<Item>> {
        self.store
            .get(id)
            .map_err(|e| format!("read surface {id}: {e}"))
            .map(|item| item.filter(|i| i.schema == SURFACE_SCHEMA_REF))
    }

    fn patch(
        &self,
        id: ItemId,
        field: &str,
        value: ItemValue,
        actor: ActorKind,
        reason: &str,
        kind: Ephemerality,
    ) -> Result<()> {
        self.store
            .apply_operation(OperationSpec {
                target_id: id,
                op_type: OperationType::SetPayload(field.to_string(), value),
                intent: kind.intent(),
                reason: Some(reason.to_string()),
                batch_id: None,
                author: author_for(actor),
                author_kind: actor,
                retention: kind.retention(),
            })
            .map(|_| ())
            .map_err(|e| format!("write surface: {e}"))
    }

    // --------------------------------------------------------------- state

    /// The working state of one `(surface, host)` instance, as raw JSON —
    /// `None` when nothing has been dispatched to this instance yet, which
    /// means "run with the spec's own initial `state` block" (the same
    /// absent-means-cold-start reading the layout store gives its live row).
    pub fn get_state(&self, surface: ItemId, host: &str) -> Result<Option<Value>> {
        self.state_item(surface, host)?
            .and_then(|item| string_field(&item, field::state::STATE))
            .map(|text| parse_json(&text))
            .transpose()
    }

    /// Upsert the state row for `(surface, host)`. `Ephemeral` + `Routine`:
    /// this is exploration churn, the same tier `save_live` gives a layout's
    /// drag.
    pub fn set_state(
        &self,
        surface: ItemId,
        host: &str,
        state: &Value,
        actor: ActorKind,
    ) -> Result<()> {
        let text =
            serde_json::to_string(state).map_err(|e| format!("encode surface state: {e}"))?;
        match self.state_item(surface, host)? {
            Some(item) => self.patch(
                item.id,
                field::state::STATE,
                ItemValue::String(text),
                actor,
                "surface state changed",
                Ephemerality::Exploration,
            ),
            None => {
                let mut payload: BTreeMap<String, ItemValue> = BTreeMap::new();
                payload.insert(
                    field::state::SURFACE.into(),
                    ItemValue::String(surface.to_string()),
                );
                payload.insert(
                    field::state::HOST.into(),
                    ItemValue::String(host.to_string()),
                );
                payload.insert(field::state::STATE.into(), ItemValue::String(text));
                self.insert_ephemeral(SURFACE_STATE_SCHEMA_REF, payload, actor)?;
                Ok(())
            }
        }
    }

    fn state_item(&self, surface: ItemId, host: &str) -> Result<Option<Item>> {
        Ok(self
            .all_state_rows(surface)?
            .into_iter()
            .find(|i| string_field(i, field::state::HOST).as_deref() == Some(host)))
    }

    fn all_state_rows(&self, surface: ItemId) -> Result<Vec<Item>> {
        let query = ItemQuery {
            schema: Some(SURFACE_STATE_SCHEMA_REF.into()),
            include_tags: false,
            include_references: false,
            ..Default::default()
        };
        let surface_id = surface.to_string();
        Ok(self
            .store
            .query(&query)
            .map_err(|e| format!("read surface state: {e}"))?
            .into_iter()
            .filter(|item| {
                string_field(item, field::state::SURFACE).as_deref() == Some(&surface_id)
            })
            .collect())
    }

    // --------------------------------------------------------------- events

    /// Append one event, assigning the next `seq` for `(surface, host)`, and
    /// prune the ring to [`EVENT_RING_CAPACITY`] afterward. Returns the
    /// assigned `seq`.
    pub fn append_event(
        &self,
        surface: ItemId,
        host: &str,
        name: &str,
        payload: &Value,
        actor: ActorKind,
    ) -> Result<u64> {
        let mut existing = self.event_items_for(surface, host)?;
        existing.sort_by_key(|i| int_field(i, field::event::SEQ).unwrap_or(0));
        let next_seq = existing
            .last()
            .and_then(|i| int_field(i, field::event::SEQ))
            .unwrap_or(0)
            + 1;

        let payload_text =
            serde_json::to_string(payload).map_err(|e| format!("encode event payload: {e}"))?;
        let mut fields: BTreeMap<String, ItemValue> = BTreeMap::new();
        fields.insert(
            field::event::SURFACE.into(),
            ItemValue::String(surface.to_string()),
        );
        fields.insert(
            field::event::HOST.into(),
            ItemValue::String(host.to_string()),
        );
        fields.insert(field::event::SEQ.into(), ItemValue::Int(next_seq as i64));
        fields.insert(
            field::event::NAME.into(),
            ItemValue::String(name.to_string()),
        );
        fields.insert(
            field::event::PAYLOAD.into(),
            ItemValue::String(payload_text),
        );
        fields.insert(
            field::event::AT.into(),
            ItemValue::String(Utc::now().to_rfc3339()),
        );
        self.insert_ephemeral(SURFACE_EVENT_SCHEMA_REF, fields, actor)?;
        let _ = existing; // superseded by the insert above; pruning re-queries fresh
        self.prune(surface, host)?;
        Ok(next_seq)
    }

    /// Events for `(surface, host)` with `seq > after`, oldest first, capped
    /// at `limit` (0 means unbounded).
    pub fn events_after(
        &self,
        surface: ItemId,
        host: &str,
        after: u64,
        limit: usize,
    ) -> Result<Vec<EventRow>> {
        let mut rows: Vec<EventRow> = self
            .event_items_for(surface, host)?
            .iter()
            .filter_map(|item| event_row_of(item).ok())
            .filter(|row| row.seq > after)
            .collect();
        rows.sort_by_key(|r| r.seq);
        if limit > 0 && rows.len() > limit {
            rows.truncate(limit);
        }
        Ok(rows)
    }

    /// The highest `seq` this `(surface, host)` has ever emitted, 0 if none
    /// — what `surface_events`/`surface_wait` echo back as `next_seq`.
    pub fn max_seq(&self, surface: ItemId, host: &str) -> Result<u64> {
        Ok(self
            .event_items_for(surface, host)?
            .iter()
            .filter_map(|i| int_field(i, field::event::SEQ))
            .max()
            .unwrap_or(0))
    }

    fn event_items_for(&self, surface: ItemId, host: &str) -> Result<Vec<Item>> {
        let items = self.all_event_items(surface)?;
        Ok(items
            .into_iter()
            .filter(|item| string_field(item, field::event::HOST).as_deref() == Some(host))
            .collect())
    }

    fn all_event_items(&self, surface: ItemId) -> Result<Vec<Item>> {
        let query = ItemQuery {
            schema: Some(SURFACE_EVENT_SCHEMA_REF.into()),
            include_tags: false,
            include_references: false,
            ..Default::default()
        };
        let surface_id = surface.to_string();
        Ok(self
            .store
            .query(&query)
            .map_err(|e| format!("read surface events: {e}"))?
            .into_iter()
            .filter(|item| {
                string_field(item, field::event::SURFACE).as_deref() == Some(&surface_id)
            })
            .collect())
    }

    /// Drop the oldest rows of `(surface, host)` past [`EVENT_RING_CAPACITY`]
    /// (ADR-0033 D5). Hard deletes, not a tombstone: this ring exists only
    /// so a live agent can read back what just happened, not to be an
    /// auditable log.
    fn prune(&self, surface: ItemId, host: &str) -> Result<()> {
        let mut items = self.event_items_for(surface, host)?;
        if items.len() <= EVENT_RING_CAPACITY {
            return Ok(());
        }
        items.sort_by_key(|i| int_field(i, field::event::SEQ).unwrap_or(0));
        let overflow = items.len() - EVENT_RING_CAPACITY;
        for item in items.into_iter().take(overflow) {
            self.store
                .delete(item.id)
                .map_err(|e| format!("prune surface event: {e}"))?;
        }
        Ok(())
    }

    // ------------------------------------------------------------ internals

    /// A plain insert at `Private` visibility — the creation path every
    /// state/event row shares. Not an operation (there is nothing to
    /// revert: it is the row coming into being), matching the reasoning the
    /// layout store's module docs give for `insert_row`.
    fn insert_ephemeral(
        &self,
        schema: &str,
        payload: BTreeMap<String, ItemValue>,
        actor: ActorKind,
    ) -> Result<ItemId> {
        let now = Utc::now();
        let item = Item {
            id: uuid::Uuid::new_v4(),
            schema: schema.into(),
            payload,
            created: now,
            modified: now,
            author: author_for(actor),
            author_kind: actor,
            logical_clock: 0,
            origin: None,
            canonical_id: None,
            tags: vec![],
            flag: None,
            is_read: false,
            is_starred: false,
            priority: Priority::None,
            visibility: Visibility::Private,
            message_type: None,
            produced_by: None,
            version: None,
            batch_id: None,
            references: vec![],
            parent: None,
        };
        self.store
            .insert(item)
            .map_err(|e| format!("write {schema}: {e}"))
    }
}

/// Which side of the ADR-0031 D7 line a write is on — the same distinction
/// `impress-layout-service/src/store.rs`'s `Ephemerality` makes, copied
/// rather than shared because the two stores are otherwise unrelated and a
/// dependency just for one private enum would be the wrong trade.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Ephemerality {
    Exploration,
    Commit,
}

impl Ephemerality {
    fn retention(self) -> RetentionTier {
        match self {
            Ephemerality::Exploration => RetentionTier::Ephemeral,
            Ephemerality::Commit => RetentionTier::Durable,
        }
    }

    fn intent(self) -> OperationIntent {
        match self {
            Ephemerality::Exploration => OperationIntent::Routine,
            Ephemerality::Commit => OperationIntent::Editorial,
        }
    }
}

/// The author string written with an operation — `IMPRESS_AUTHOR` overrides,
/// same as `impress-layout-service::store::author_for`, copied for the same
/// reason `Ephemerality` is.
pub fn author_for(actor: ActorKind) -> String {
    if let Ok(author) = std::env::var("IMPRESS_AUTHOR") {
        let author = author.trim();
        if !author.is_empty() {
            return author.to_string();
        }
    }
    match actor {
        ActorKind::Human => "human:surface-service".to_string(),
        ActorKind::Agent => "agent:surface-service".to_string(),
        ActorKind::System => "system:surface-service".to_string(),
    }
}

/// Parse an actor argument the same way `impress-layout-service` does:
/// `None` means [`ActorKind::Agent`], because these verbs reach the store
/// over MCP and the CLI and an agent that forgets to say who it is must not
/// be recorded as the user.
pub fn actor_from(raw: Option<&str>) -> ActorKind {
    match raw.map(|a| a.trim().to_ascii_lowercase()).as_deref() {
        Some("human") | Some("user") | Some("person") => ActorKind::Human,
        Some("system") => ActorKind::System,
        _ => ActorKind::Agent,
    }
}

fn string_field(item: &Item, field: &str) -> Option<String> {
    match item.payload.get(field) {
        Some(ItemValue::String(s)) => Some(s.clone()),
        _ => None,
    }
}

fn int_field(item: &Item, field: &str) -> Option<u64> {
    match item.payload.get(field) {
        Some(ItemValue::Int(n)) if *n >= 0 => Some(*n as u64),
        _ => None,
    }
}

fn spec_json(spec: &SurfaceSpec) -> Result<String> {
    serde_json::to_string(spec).map_err(|e| format!("encode surface spec: {e}"))
}

fn parse_json(text: &str) -> Result<Value> {
    let json: serde_json::Value =
        serde_json::from_str(text).map_err(|e| format!("parse surface JSON: {e}"))?;
    serde_json::from_value(json).map_err(|e| format!("parse surface JSON: {e}"))
}

fn surface_row_of(item: &Item) -> Result<SurfaceRow> {
    let name = string_field(item, field::surface::NAME).unwrap_or_default();
    let version = string_field(item, field::surface::VERSION);
    let spec_text = item
        .payload
        .get(field::surface::SPEC)
        .and_then(|v| match v {
            ItemValue::String(s) => Some(s.clone()),
            _ => None,
        })
        .ok_or_else(|| format!("surface {} has no `spec` field", item.id))?;
    let spec: SurfaceSpec =
        serde_json::from_str(&spec_text).map_err(|e| format!("surface {} spec: {e}", item.id))?;
    let tags = match item.payload.get(field::surface::TAGS) {
        Some(ItemValue::Array(items)) => items
            .iter()
            .filter_map(|v| match v {
                ItemValue::String(s) => Some(s.clone()),
                _ => None,
            })
            .collect(),
        _ => Vec::new(),
    };
    Ok(SurfaceRow {
        id: item.id,
        name,
        version,
        spec,
        tags,
        created: item.created,
        modified: item.modified,
    })
}

fn event_row_of(item: &Item) -> Result<EventRow> {
    let surface_text = string_field(item, field::event::SURFACE)
        .ok_or_else(|| format!("event {} has no `surface` field", item.id))?;
    let surface: ItemId = surface_text
        .parse()
        .map_err(|e| format!("event {} surface id: {e}", item.id))?;
    let host = string_field(item, field::event::HOST).unwrap_or_default();
    let seq = int_field(item, field::event::SEQ).unwrap_or(0);
    let name = string_field(item, field::event::NAME).unwrap_or_default();
    let payload = match item.payload.get(field::event::PAYLOAD) {
        Some(ItemValue::String(s)) => parse_json(s)?,
        _ => Value::Null,
    };
    let at = string_field(item, field::event::AT)
        .and_then(|s| DateTime::parse_from_rfc3339(&s).ok())
        .map(|dt| dt.with_timezone(&Utc))
        .unwrap_or(item.modified);
    Ok(EventRow {
        surface,
        host,
        seq,
        name,
        payload,
        at,
    })
}
