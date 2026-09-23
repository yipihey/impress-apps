//! `SharedLayout`: the UniFFI surface Swift renders and drives the ADR-0031
//! layout tree through (work package L5 of `docs/plan-layout-tree.md`).
//!
//! # What crosses the boundary
//!
//! One object, and it holds no layout state of its own. Everything Swift can
//! ask for is derived from the live `impress/ui/layout@1.0.0` row that
//! `impress-layout-service` owns (ADR-0019 D3: the projection is derived, and
//! a view that holds layout state is the bug this whole plan removes). The
//! tree itself travels as JSON — `layout_json` is exactly
//! `serde_json::to_string(&impress_layout::Layout)` — because the arena is a
//! recursive value and mirroring it as thirty UniFFI records would be a
//! second definition of the same thing.
//!
//! The mutating surface is deliberately one verb wide: [`SharedLayout::apply`]
//! takes the serde form of an [`impress_layout::Verb`], so Swift, the MCP
//! tools and the CLI all speak the same closed vocabulary (ADR-0031 D8
//! invariant 6: no Swift-only layout operation). The typed convenience
//! methods below it — `focus_direction`, `select`, `resize_share` — are
//! spellings of that same verb set for the chords the GUI fires on every
//! keystroke, not new capability.
//!
//! # Threading
//!
//! Every method is synchronous at the boundary. `LayoutService` is `async`
//! only because `#[impress_service]` makes every method `async`; the bodies
//! are plain synchronous store work, so they are driven on the same shape of
//! runtime `ai_registry` already owns for the process (a shared, named,
//! multi-thread runtime — `block_on` from any thread, no re-entrancy rules for
//! Swift to learn).
//!
//! The invalidation feed is the one background thread: an ordinary
//! `std::thread` around `SqliteItemStore::subscribe_mutations()`, matching
//! `QuerySubscriptions<TileId>` built from the live tree. It debounces a burst
//! of mutations into one `panes_invalidated` call, and it honours a startup
//! grace during which invalidations are collected but NOT delivered — which is
//! CLAUDE.md's 60–90 s startup render-loop guard (ADR-0019 D6) applied at the
//! source rather than re-implemented in every Swift subscriber.
//!
//! # Liveness across processes (ADR-0033 D6)
//!
//! `subscribe_mutations()` is an in-process channel: it can only ever report
//! writes made through THIS `SqliteItemStore` handle, in THIS process. An
//! agent driving the suite from a chat writes through `impress-mcp`, a
//! separate process opening the same SQLite file — a layout or surface row it
//! writes is invisible to the running app's feed, and no amount of debounce
//! tuning fixes that, because the bus it is tuned on never receives the
//! event. ADR-0033 D6 fixes this at the store rather than by adding an HTTP
//! relay between the two processes: alongside the mutation channel, the feed
//! polls [`SqliteItemStore::data_version`] every [`EXTERNAL_POLL_MS`]
//! (settable via [`SharedLayout::set_external_poll_ms`]). `PRAGMA
//! data_version` is SQLite's own cheap (no I/O beyond the pragma itself),
//! per-connection counter that moves exactly when SOME OTHER connection has
//! committed — including another `SqliteItemStore` handle on the same file in
//! this process or another — and never for this connection's own writes, so
//! it is a free way to ask "did something else write since I last looked?"
//! without re-querying every row on a timer. 250 ms keeps a chat-driven
//! change visible in well under a second while costing nothing when nothing
//! external is happening (compare the 50 ms in-process debounce, which is
//! deliberately much tighter because it is reacting to a channel that only
//! fires on a real write, not polling blind).
//!
//! When the version moves, the feed reads `items_modified_since("impress/ui/",
//! high_water_mark)` and folds each row into the same `StoreMutation` /
//! `MutationKind` pipeline an in-process write would have produced (as
//! `MutationKind::Updated` — [`Invalidation::is_affected_by`] treats
//! `Created`, `Updated` and `Deleted` identically for the schema-ref and
//! anchor-row rules, so the distinction is not observable from a plain read
//! and is not worth reconstructing), then advances the mark to the latest
//! `modified` timestamp actually seen. The result goes through the SAME
//! debounce and startup-grace logic as an in-process mutation — this is an
//! additional source feeding `pending`, not a second delivery path.
//!
//! The `impress/ui/` prefix is deliberate, not a placeholder: it is the
//! agent-facing surface (layout, and — from work package S4,
//! `impress-surface-service` — capability surfaces under
//! `impress/ui/surface@1.0.0`) that a standalone chat process is expected to
//! write to. Other
//! record kinds keep their own liveness path — this poll does not become a
//! second general-purpose invalidation channel for the whole store, which
//! would make every write in the suite pay for a `PRAGMA` + query on a timer
//! whether or not anything outside this process is writing.

use std::collections::BTreeMap;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use impress_core::collection_ops::{
    self, CollectionSchemaBinding, FIGURE_COLLECTION, GENERIC_COLLECTION, IMBIB_COLLECTION,
    MANUSCRIPT_COLLECTION,
};
use impress_core::item::ItemId;
use impress_core::pane_query::invalidation::QuerySubscriptions;
use impress_core::pane_query::{
    builtin_manifest, compile, compile_with, Bindings, PaneQuery, ParamDecl, SubtreeResolver,
};
use impress_core::query::ItemQuery;
use impress_core::schemas;
use impress_core::sqlite_store::SqliteItemStore;
use impress_core::store::ItemStore;
use impress_layout::{
    ChannelId, Container, Direction, Layout, LinearDir, PaneRef, PaneSpec, Placement, Role, Tile,
    TileId, Verb, HIDDEN_SHARE,
};
use impress_layout_service::{
    DefaultLayoutService, LayoutService, LayoutStore, LayoutVerbResult, PaneRefDto,
};

use crate::{item_to_row, SharedItemRow, SharedStore};

// ─── Runtime ─────────────────────────────────────────────────────────────

/// One runtime for every layout call in the process, mirroring the shape
/// `ai_registry::runtime()` already established here: a named multi-thread
/// runtime, so `block_on` is legal from the Swift caller's thread AND from the
/// invalidation feed's thread at the same time. A current-thread runtime would
/// serialize those two, and the feed would stall behind a drag.
fn runtime() -> &'static tokio::runtime::Runtime {
    static RUNTIME: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
    RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .thread_name("impress-layout-ffi")
            .enable_all()
            .build()
            .expect("build the impress-layout FFI runtime")
    })
}

// ─── Errors ──────────────────────────────────────────────────────────────

/// One case per family of thing that can go wrong behind a layout call.
///
/// Separate from `SharedStoreError` for the same reason `AiError` is: the
/// Swift `catch` arms for the store are already spread across five apps, and a
/// refused *query* (an unknown record kind, an unbound required parameter) is
/// a different conversation from a refused *write*.
#[cfg_attr(feature = "native", derive(uniffi::Error))]
#[derive(Debug, Clone, thiserror::Error)]
pub enum SharedLayoutError {
    /// A verb was refused by the tree or the service: no such pane, the last
    /// pane of a window, a detach of a whole window.
    #[error("{message}")]
    Layout { message: String },
    /// A pane query did not compile — a typed refusal, never an empty list
    /// that reads as "no data yet".
    #[error("{message}")]
    Query { message: String },
    /// The store could not be read or written.
    #[error("{message}")]
    Store { message: String },
    /// A JSON argument or result would not parse.
    #[error("{message}")]
    Json { message: String },
}

impl SharedLayoutError {
    fn layout(message: impl Into<String>) -> Self {
        SharedLayoutError::Layout {
            message: message.into(),
        }
    }

    fn json(message: impl std::fmt::Display) -> Self {
        SharedLayoutError::Json {
            message: message.to_string(),
        }
    }

    fn store(message: impl std::fmt::Display) -> Self {
        SharedLayoutError::Store {
            message: message.to_string(),
        }
    }
}

type Result<T> = std::result::Result<T, SharedLayoutError>;

// ─── Records ─────────────────────────────────────────────────────────────

/// One window of the tree, flattened for a renderer that walks it.
#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct SharedWindow {
    pub id: u64,
    /// The root tile. Look it up in `layout_json`'s `tiles` map.
    pub root: u64,
    /// The focused leaf of this window.
    pub focused: Option<u64>,
    /// What `follow` resolves to here, `1..=8`.
    pub default_channel: u8,
    /// The tile shown alone, if any. Zoom is a window view state, not a
    /// mutation of the tree.
    pub maximized: Option<u64>,
    /// The device-scoped frame, as `impress_layout::Geometry` JSON.
    pub geometry_json: Option<String>,
    /// This window's leaves in tree order — the order h / l walks, and the
    /// order a flattened renderer should build panes in.
    pub leaves: Vec<u64>,
}

/// The whole tree as Swift receives it.
#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct SharedLayoutSnapshot {
    /// `serde_json::to_string(&impress_layout::Layout)` — windows, the tile
    /// arena and the channel state. The one place the recursive value lives.
    pub layout_json: String,
    /// The focused leaf of the current window.
    pub focused: Option<u64>,
    pub windows: Vec<SharedWindow>,
    /// The current window's leaves in tree order. Per-window lists are on
    /// [`SharedWindow::leaves`]; this is the one a single-window host wants.
    pub leaves: Vec<u64>,
    /// Bumped on every applied verb. A host that holds this number can skip a
    /// snapshot it has already rendered.
    pub version: u64,
}

/// What one verb changed — the renderer's whole input (ADR-0019 D3).
#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct SharedAppliedVerb {
    pub version: u64,
    pub focused: Option<u64>,
    /// The panes to redraw. For `select`, every pane whose bindings the
    /// publication changed; otherwise the tiles the patch touched.
    pub affected_panes: Vec<u64>,
    /// Every tile the patch touched, created and removed included — what a
    /// host diffing its view tree needs, as opposed to what it must re-query.
    pub changed_tiles: Vec<u64>,
    /// The tree afterwards, same shape as [`SharedLayoutSnapshot::layout_json`].
    pub layout_json: String,
}

/// One saved layout, in ⌃⌘1–9 order.
#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct SharedLayoutRow {
    pub id: String,
    /// 1-based; what `apply_layout("3")` recalls. Only the first nine have a
    /// chord.
    pub ordinal: u32,
    pub name: Option<String>,
    /// The user's own words for what the layout is for. Uninterpreted.
    pub purpose: Option<String>,
    /// RFC 3339.
    pub created: String,
    /// RFC 3339.
    pub modified: String,
}

/// One pane: what it shows, what the store will actually be asked, and what
/// its parameters resolve to right now.
#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct SharedPane {
    pub tile: u64,
    /// `impress_layout::PaneSpec` JSON.
    pub spec_json: String,
    /// The compiled `impress_core::query::ItemQuery` JSON — literally what
    /// the store is asked, which is how "why is this pane empty?" becomes a
    /// question with an answer.
    pub compiled_query_json: String,
    /// Parameter name → the item id it resolves to, as a JSON object.
    pub bindings_json: String,
    /// Set when the scope was a single item and it resolved: a detail pane
    /// short-circuits on this.
    pub single_item: Option<String>,
    /// Every schema ref the query can touch — the invalidation key.
    pub schema_refs: Vec<String>,
    /// The channel this pane publishes on, resolved against its window.
    pub channel: Option<u8>,
    pub view_kind: String,
    pub role: Option<String>,
}

// ─── The invalidation listener ───────────────────────────────────────────

/// What Swift implements to be told when panes go stale.
///
/// Both calls arrive on the feed's own thread, never on the caller's — hop to
/// the main actor before touching a view.
#[cfg_attr(feature = "native", uniffi::export(callback_interface))]
pub trait SharedLayoutListener: Send + Sync {
    /// These panes must re-run their queries. Deduplicated, and coalesced over
    /// the debounce window: a 500-row triage sweep wakes each pane once.
    fn panes_invalidated(&self, panes: Vec<u64>);
    /// The tree itself changed — re-read [`SharedLayout::snapshot`]. The
    /// number is the same counter the snapshot carries.
    fn layout_changed(&self, version: u64);
}

use crate::ui_feed::{self, ExternalPoll, Feed};

// ─── The object ──────────────────────────────────────────────────────────

/// The layout of one `(app_id, device)` scope, bound to an open
/// [`SharedStore`].
///
/// Construct it once per app launch and keep it: it holds the service's
/// session registry, which is where the two undo rings of ADR-0031 D7 live for
/// the duration of this sitting.
#[cfg_attr(feature = "native", derive(uniffi::Object))]
pub struct SharedLayout {
    store: Arc<SqliteItemStore>,
    service: DefaultLayoutService,
    app_id: String,
    device: Option<String>,
    version: Arc<AtomicU64>,
    debounce_ms: AtomicU64,
    startup_grace_secs: AtomicU64,
    external_poll_ms: AtomicU64,
    feed: Mutex<Option<Feed>>,
}

#[cfg_attr(feature = "native", uniffi::export)]
impl SharedLayout {
    /// Bind to the layout of `app_id` on `device` (`None` = this machine).
    ///
    /// The tree is not read here: the first `snapshot` or verb cold-starts the
    /// three-column preset and persists it, so a caller never has to ask
    /// whether a layout exists.
    #[cfg_attr(feature = "native", uniffi::constructor)]
    pub fn open(store: Arc<SharedStore>, app_id: String, device: Option<String>) -> Arc<Self> {
        let core = store.core();
        Arc::new(SharedLayout {
            service: DefaultLayoutService::with_store_and_sessions(
                core.clone(),
                store.layout_sessions(),
            ),
            store: core,
            app_id,
            device,
            version: Arc::new(AtomicU64::new(0)),
            debounce_ms: AtomicU64::new(DEFAULT_DEBOUNCE_MS),
            startup_grace_secs: AtomicU64::new(0),
            external_poll_ms: AtomicU64::new(EXTERNAL_POLL_MS),
            feed: Mutex::new(None),
        })
    }

    /// How long a burst of store mutations is coalesced before the feed calls
    /// `panes_invalidated`. Default 50 ms. Set before subscribing.
    pub fn set_debounce_ms(&self, millis: u32) {
        self.debounce_ms
            .store(millis.max(1) as u64, Ordering::SeqCst);
    }

    /// How often the feed polls `SqliteItemStore::data_version()` to notice
    /// writes made by another process or another store handle on the same
    /// file (ADR-0033 D6 — see the module docs). Default
    /// [`EXTERNAL_POLL_MS`]. Set before subscribing.
    pub fn set_external_poll_ms(&self, millis: u32) {
        self.external_poll_ms
            .store(millis.max(1) as u64, Ordering::SeqCst);
    }

    /// Collect invalidations for this many seconds after `subscribe_invalidations`
    /// without delivering any, then deliver one batch.
    ///
    /// The GUI passes 90; tests pass 0. This is CLAUDE.md's startup
    /// render-loop guard (ADR-0019 D6) at the source: a background service that
    /// wakes SwiftUI during the first ~90 s of launch compounds into a
    /// perpetual render loop, and the fix belongs here rather than in every
    /// subscriber. Set before subscribing.
    pub fn set_startup_grace_secs(&self, secs: u32) {
        self.startup_grace_secs.store(secs as u64, Ordering::SeqCst);
    }

    /// The counter the snapshot and every applied verb carry.
    pub fn version(&self) -> u64 {
        self.version.load(Ordering::SeqCst)
    }

    // ------------------------------------------------------------- reading

    /// The whole tree.
    pub fn snapshot(&self) -> Result<SharedLayoutSnapshot> {
        let layout = self.read_layout()?;
        Ok(self.snapshot_of(&layout))
    }

    /// One pane's spec, its compiled query and its resolved bindings.
    pub fn pane(&self, id: u64) -> Result<SharedPane> {
        let result = runtime().block_on(self.service.get_pane(
            self.app_id.clone(),
            self.device.clone(),
            PaneRefDto::tile(TileId::new(id)),
        ));
        if !result.ok {
            return Err(SharedLayoutError::layout(result.message));
        }
        let spec = result
            .spec
            .ok_or_else(|| SharedLayoutError::layout(format!("tile {id} is not a pane")))?;
        let query = result
            .query
            .ok_or_else(|| SharedLayoutError::layout(format!("pane {id} has no query")))?;
        if let Some(error) = query.error {
            return Err(SharedLayoutError::Query { message: error });
        }
        Ok(SharedPane {
            tile: result.tile.unwrap_or(id),
            spec_json: serde_json::to_string(&spec).map_err(SharedLayoutError::json)?,
            compiled_query_json: serde_json::to_string(&query.item_query)
                .map_err(SharedLayoutError::json)?,
            bindings_json: serde_json::to_string(&result.bindings)
                .map_err(SharedLayoutError::json)?,
            single_item: query.single_item,
            schema_refs: query.schema_refs,
            channel: result.channel,
            view_kind: spec.view_kind.to_string(),
            role: spec.role.map(|r| r.to_string()),
        })
    }

    /// Run a pane's compiled query. The read path every list pane uses.
    ///
    /// `limit` of 0 keeps whatever limit the pane's own query carries. Rows
    /// come back as the ordinary [`SharedItemRow`], so Swift reuses the
    /// payload decoders it already has.
    pub fn run_pane(&self, id: u64, offset: u32, limit: u32) -> Result<Vec<SharedItemRow>> {
        let pane = self.pane(id)?;
        let mut query: ItemQuery =
            serde_json::from_str(&pane.compiled_query_json).map_err(SharedLayoutError::json)?;
        if limit > 0 {
            query.limit = Some(limit as usize);
        }
        if offset > 0 {
            query.offset = Some(offset as usize);
        }
        let items = self.store.query(&query).map_err(SharedLayoutError::store)?;
        Ok(items.into_iter().map(item_to_row).collect())
    }

    /// Which pane holds `role` right now, if any.
    ///
    /// The universal chords act on roles, not slots (ADR-0031 D5): ⌃⌘S hides
    /// whichever pane carries `navigator`. This is how a host asks which tile
    /// that is — and then drives it with [`Self::resize_share`], which keeps
    /// the pane in the tree rather than closing it.
    pub fn pane_with_role(&self, role: String) -> Result<Option<u64>> {
        let layout = self.read_layout()?;
        Ok(layout.pane_with_role(&Role::from(role)).map(TileId::raw))
    }

    /// The saved layouts of this app, in ⌃⌘1–9 order.
    pub fn list_layouts(&self) -> Result<Vec<SharedLayoutRow>> {
        let store = LayoutStore::new(self.store.clone());
        let rows = store
            .list_named(&self.app_id)
            .map_err(SharedLayoutError::store)?;
        Ok(rows
            .into_iter()
            .enumerate()
            .map(|(index, row)| SharedLayoutRow {
                id: row.id.to_string(),
                ordinal: index as u32 + 1,
                name: row.name,
                purpose: row.purpose,
                created: row.created.to_rfc3339(),
                modified: row.modified.to_rfc3339(),
            })
            .collect())
    }

    // ------------------------------------------------------------ mutating

    /// Apply one verb, as the serde form of [`impress_layout::Verb`].
    ///
    /// This is the whole mutating surface. `actor` is `human` | `agent` |
    /// `system`; the GUI passes `human`.
    pub fn apply(&self, verb_json: String, actor: String) -> Result<SharedAppliedVerb> {
        match serde_json::from_str::<Verb>(&verb_json) {
            Ok(verb) => self.dispatch(verb, actor),
            // `Verb::Split` names the new pane; a bare "split this" does not,
            // and the service answers it by duplicating the pane being split.
            // That is the service's decision, not one taken again here — this
            // arm only recognizes the shape and forwards it.
            Err(e) => match bare_split(&verb_json) {
                Some(bare) => {
                    let result = runtime().block_on(self.service.split(
                        self.app_id.clone(),
                        self.device.clone(),
                        ref_dto(&bare.target),
                        linear_name(bare.dir).to_string(),
                        bare.after,
                        None,
                        Some(actor),
                    ));
                    self.finish(result)
                }
                None => Err(SharedLayoutError::json(e)),
            },
        }
    }

    /// Step focus: `left` | `right` | `up` | `down` | `next` | `prev`. The
    /// h / l grammar.
    pub fn focus_direction(&self, dir: String, actor: String) -> Result<SharedAppliedVerb> {
        let result = runtime().block_on(self.service.focus_direction(
            self.app_id.clone(),
            self.device.clone(),
            dir,
            Some(actor),
        ));
        self.finish(result)
    }

    /// Publish a selection of `kind` on a pane's channel — what clicking a row
    /// is. An empty `ids` is a real value: it says nothing of that kind is
    /// selected, which is what a detail pane renders its empty state from.
    pub fn select(
        &self,
        pane: u64,
        kind: String,
        ids: Vec<String>,
        actor: String,
    ) -> Result<SharedAppliedVerb> {
        let result = runtime().block_on(self.service.select(
            self.app_id.clone(),
            self.device.clone(),
            PaneRefDto::tile(TileId::new(pane)),
            kind,
            ids,
            Some(actor),
        ));
        self.finish(result)
    }

    /// Give one pane a relative share of its parent split, leaving its
    /// siblings' shares alone.
    ///
    /// This is what a role toggle is built from: ⌃⌘S sets the navigator's
    /// share to [`impress_layout::HIDDEN_SHARE`] and back. The tree refuses a
    /// share of exactly zero (`InvalidShares`: a weight must be positive and
    /// finite), so "hidden" is spelled as the smallest weight it accepts —
    /// sub-pixel against any realistic sum, and reversible by one `Resize`.
    /// Hiding a pane by *closing* it would take its session and its place in
    /// the tree with it, and a hidden-role set kept beside the tree would be
    /// exactly the view-held layout state ADR-0019 D3 exists to remove — so
    /// the pane stays in the tree with no width.
    pub fn resize_share(&self, pane: u64, share: f32, actor: String) -> Result<SharedAppliedVerb> {
        let layout = self.read_layout()?;
        let tile = TileId::new(pane);
        let parent = layout
            .parent_of(tile)
            .ok_or_else(|| SharedLayoutError::layout(format!("tile {pane} has no parent split")))?;
        let container = layout
            .tile(parent)
            .and_then(Tile::as_container)
            .ok_or_else(|| {
                SharedLayoutError::layout(format!("tile {parent} is not a container"))
            })?;
        if !matches!(container, Container::Linear { .. }) {
            return Err(SharedLayoutError::layout(format!(
                "tile {parent} is a {:?}, and only a split has shares",
                container.kind()
            )));
        }
        let index = container.index_of(tile).ok_or_else(|| {
            SharedLayoutError::layout(format!("tile {pane} is not a child of {parent}"))
        })?;
        let existing = container.shares().unwrap_or(&[]);
        let mut shares: Vec<f32> = (0..container.len())
            .map(|i| existing.get(i).copied().unwrap_or(1.0))
            .collect();
        shares[index] = share.max(HIDDEN_SHARE);
        let result = runtime().block_on(self.service.resize(
            self.app_id.clone(),
            self.device.clone(),
            parent.raw(),
            shares,
            Some(actor),
        ));
        self.finish(result)
    }

    /// Undo on one ring: `arrangement` (the window's shape) or `exploration`
    /// (one pane's bindings and view state). `pane` names the exploration
    /// ring's pane; `None` means the focused one.
    pub fn undo(
        &self,
        stack: String,
        pane: Option<u64>,
        actor: String,
    ) -> Result<SharedAppliedVerb> {
        let result = runtime().block_on(self.service.undo(
            self.app_id.clone(),
            self.device.clone(),
            stack,
            pane_ref(pane),
            Some(actor),
        ));
        self.finish(result)
    }

    /// Redo on one ring. Same stacks as [`Self::undo`].
    pub fn redo(
        &self,
        stack: String,
        pane: Option<u64>,
        actor: String,
    ) -> Result<SharedAppliedVerb> {
        let result = runtime().block_on(self.service.redo(
            self.app_id.clone(),
            self.device.clone(),
            stack,
            pane_ref(pane),
            Some(actor),
        ));
        self.finish(result)
    }

    /// Save the current arrangement under a name, durably. Re-saving a name
    /// overwrites it.
    pub fn save_layout(
        &self,
        name: String,
        purpose: Option<String>,
        actor: String,
    ) -> Result<SharedAppliedVerb> {
        let result = runtime().block_on(self.service.save_layout(
            self.app_id.clone(),
            self.device.clone(),
            name,
            purpose,
            Some(actor),
        ));
        self.finish(result)
    }

    /// Recall a saved layout by name, by id, or by ⌃⌘1–9 ordinal — a string
    /// that parses as a positive integer is read as the ordinal.
    pub fn apply_layout(
        &self,
        name_or_ordinal: String,
        actor: String,
    ) -> Result<SharedAppliedVerb> {
        let ordinal = name_or_ordinal
            .trim()
            .parse::<u32>()
            .ok()
            .filter(|n| *n > 0);
        let name = if ordinal.is_some() {
            None
        } else {
            Some(name_or_ordinal)
        };
        let result = runtime().block_on(self.service.apply_layout(
            self.app_id.clone(),
            self.device.clone(),
            name,
            ordinal,
            Some(actor),
        ));
        self.finish(result)
    }

    /// Remove a saved layout by name or id. Refuses the live arrangement and
    /// any preset (`reset-preset` is theirs); a name that does not exist
    /// comes back as an error carrying the service's message, same as every
    /// other refusal on this object.
    pub fn delete_layout(&self, name_or_id: String, actor: String) -> Result<SharedAppliedVerb> {
        let result = runtime().block_on(self.service.delete_layout(
            self.app_id.clone(),
            name_or_id,
            Some(actor),
        ));
        self.finish(result)
    }

    // ------------------------------------------------------------ the feed

    /// Start (or restart) the invalidation feed.
    ///
    /// One background thread per `SharedLayout`; subscribing again replaces
    /// the previous listener. See the module docs for the threading model.
    pub fn subscribe_invalidations(&self, listener: Box<dyn SharedLayoutListener>) -> Result<()> {
        let rx = self
            .store
            .subscribe_mutations()
            .map_err(SharedLayoutError::store)?;

        let running = Arc::new(AtomicBool::new(true));
        let worker = InvalidationFeed {
            running: running.clone(),
            listener: Arc::from(listener),
            version: self.version.clone(),
            service: self.service.clone(),
            store: self.store.clone(),
            app_id: self.app_id.clone(),
            device: self.device.clone(),
            debounce: Duration::from_millis(self.debounce_ms.load(Ordering::SeqCst)),
            grace: Duration::from_secs(self.startup_grace_secs.load(Ordering::SeqCst)),
            external_poll: Duration::from_millis(self.external_poll_ms.load(Ordering::SeqCst)),
        };
        let join = std::thread::Builder::new()
            .name("impress-layout-invalidation".into())
            .spawn(move || worker.run(rx))
            .map_err(SharedLayoutError::store)?;

        let mut slot = self.feed.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(previous) = slot.as_mut() {
            previous.stop();
        }
        *slot = Some(Feed {
            running,
            join: Some(join),
        });
        Ok(())
    }

    /// Stop the feed. Idempotent; `SharedLayout`'s `Drop` does it too.
    pub fn unsubscribe_invalidations(&self) {
        let mut slot = self.feed.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(mut feed) = slot.take() {
            feed.stop();
        }
    }
}

impl Drop for SharedLayout {
    fn drop(&mut self) {
        if let Ok(mut slot) = self.feed.lock() {
            if let Some(mut feed) = slot.take() {
                feed.stop();
            }
        }
    }
}

// ─── The private half ────────────────────────────────────────────────────

impl SharedLayout {
    fn read_layout(&self) -> Result<Layout> {
        read_layout(&self.service, &self.app_id, self.device.clone())
    }

    fn snapshot_of(&self, layout: &Layout) -> SharedLayoutSnapshot {
        snapshot_of(layout, self.version.load(Ordering::SeqCst))
    }

    /// Turn a service result into the FFI one, bumping the version.
    fn finish(&self, result: LayoutVerbResult) -> Result<SharedAppliedVerb> {
        if !result.ok {
            return Err(SharedLayoutError::layout(result.message));
        }
        let version = self.version.fetch_add(1, Ordering::SeqCst) + 1;
        let layout = self.read_layout()?;
        let changed_tiles = result
            .patch
            .as_ref()
            .map(|p| p.tiles.clone())
            .unwrap_or_default();
        Ok(SharedAppliedVerb {
            version,
            focused: result.focused,
            affected_panes: result.affected_panes,
            changed_tiles,
            layout_json: serde_json::to_string(&layout).map_err(SharedLayoutError::json)?,
        })
    }

    /// Every [`Verb`] variant, routed to the `layout-service` method that owns
    /// it. A translation table rather than a second applier: nothing here
    /// decides anything about the tree.
    fn dispatch(&self, verb: Verb, actor: String) -> Result<SharedAppliedVerb> {
        let app = self.app_id.clone();
        let device = self.device.clone();
        let actor = Some(actor);
        let service = &self.service;
        let rt = runtime();

        let result = match verb {
            Verb::Split {
                target,
                dir,
                after,
                new,
            } => rt.block_on(service.split(
                app,
                device,
                ref_dto(&target),
                linear_name(dir).to_string(),
                after,
                Some(new),
                actor,
            )),
            Verb::MoveTile {
                tile,
                target,
                placement,
            } => rt.block_on(service.move_tile(
                app,
                device,
                ref_dto(&tile),
                ref_dto(&target),
                placement_name(placement).to_string(),
                actor,
            )),
            Verb::Close { target } => {
                rt.block_on(service.close(app, device, ref_dto(&target), actor))
            }
            Verb::Swap { a, b } => {
                rt.block_on(service.swap(app, device, ref_dto(&a), ref_dto(&b), actor))
            }
            Verb::Resize { container, shares } => {
                rt.block_on(service.resize(app, device, container.raw(), shares, actor))
            }
            Verb::SetContainerKind { container, kind } => rt.block_on(service.set_container_kind(
                app,
                device,
                container.raw(),
                container_kind_name(kind).to_string(),
                actor,
            )),
            Verb::Maximize { target } => {
                rt.block_on(service.maximize(app, device, ref_dto(&target), actor))
            }
            Verb::Restore => rt.block_on(service.restore(app, device, actor)),
            Verb::Detach { target } => {
                rt.block_on(service.detach(app, device, ref_dto(&target), actor))
            }
            Verb::SetPane { target, spec } => {
                rt.block_on(service.set_pane(app, device, ref_dto(&target), spec, actor))
            }
            Verb::SetQuery { target, query } => {
                rt.block_on(service.set_query(app, device, ref_dto(&target), query, actor))
            }
            Verb::SetViewKind { target, view_kind } => rt.block_on(service.set_view_kind(
                app,
                device,
                ref_dto(&target),
                view_kind.to_string(),
                actor,
            )),
            Verb::BindParam {
                target,
                name,
                source,
            } => {
                rt.block_on(service.bind_param(app, device, ref_dto(&target), name, source, actor))
            }
            Verb::SetChannel { target, channel } => rt.block_on(service.set_channel(
                app,
                device,
                ref_dto(&target),
                channel_name(channel),
                actor,
            )),
            Verb::SetRole { target, role } => rt.block_on(service.set_role(
                app,
                device,
                ref_dto(&target),
                role.map(|r| r.to_string()),
                actor,
            )),
            Verb::Focus { target } => {
                rt.block_on(service.focus(app, device, ref_dto(&target), actor))
            }
            Verb::FocusDirection { direction } => rt.block_on(service.focus_direction(
                app,
                device,
                direction_name(direction).to_string(),
                actor,
            )),
            Verb::Select { target, kind, ids } => rt.block_on(service.select(
                app,
                device,
                ref_dto(&target),
                kind,
                ids.iter().map(ItemId::to_string).collect(),
                actor,
            )),
            Verb::SetWindowGeometry { window, geometry } => rt.block_on(
                service.set_window_geometry(app, device, Some(window.raw()), geometry, actor),
            ),
            Verb::SetDefaultChannel { window, channel } => {
                rt.block_on(service.set_default_channel(
                    app,
                    device,
                    Some(window.raw()),
                    channel_name(channel),
                    actor,
                ))
            }
        };
        self.finish(result)
    }
}

fn read_layout(
    service: &DefaultLayoutService,
    app_id: &str,
    device: Option<String>,
) -> Result<Layout> {
    let result = runtime().block_on(service.get_layout(app_id.to_string(), device));
    if !result.ok {
        return Err(SharedLayoutError::layout(result.message));
    }
    result
        .layout
        .ok_or_else(|| SharedLayoutError::layout("the layout service returned no tree"))
}

fn snapshot_of(layout: &Layout, version: u64) -> SharedLayoutSnapshot {
    let current = layout.current_window().ok();
    let windows: Vec<SharedWindow> = layout
        .windows
        .iter()
        .map(|w| SharedWindow {
            id: w.id.raw(),
            root: w.root.raw(),
            focused: w.focused.map(TileId::raw),
            default_channel: w.default_channel.resolve(ChannelId::ONE),
            maximized: w.maximized.map(TileId::raw),
            geometry_json: w
                .geometry
                .as_ref()
                .and_then(|g| serde_json::to_string(g).ok()),
            leaves: layout.leaves(w.id).iter().map(|t| t.raw()).collect(),
        })
        .collect();
    let leaves = current
        .map(|w| layout.leaves(w).iter().map(|t| t.raw()).collect())
        .unwrap_or_default();
    SharedLayoutSnapshot {
        layout_json: serde_json::to_string(layout).unwrap_or_else(|_| "{}".into()),
        focused: current
            .and_then(|w| layout.window(w))
            .and_then(|w| w.focused)
            .map(TileId::raw),
        windows,
        leaves,
        version,
    }
}

/// A bare `{"verb":"split", "target":…, "dir":…}` with no `new` pane.
struct BareSplit {
    target: PaneRef,
    dir: LinearDir,
    after: bool,
}

fn bare_split(verb_json: &str) -> Option<BareSplit> {
    let value: serde_json::Value = serde_json::from_str(verb_json).ok()?;
    if value.get("verb")?.as_str()? != "split" || value.get("new").is_some() {
        return None;
    }
    Some(BareSplit {
        target: match value.get("target") {
            Some(target) => serde_json::from_value(target.clone()).ok()?,
            None => PaneRef::Focused,
        },
        dir: serde_json::from_value(value.get("dir")?.clone()).ok()?,
        after: value
            .get("after")
            .and_then(serde_json::Value::as_bool)
            .unwrap_or(false),
    })
}

fn pane_ref(pane: Option<u64>) -> PaneRefDto {
    match pane {
        Some(id) => PaneRefDto::tile(TileId::new(id)),
        None => PaneRefDto::focused(),
    }
}

fn ref_dto(reference: &PaneRef) -> PaneRefDto {
    match reference {
        PaneRef::Id { tile } => PaneRefDto::tile(*tile),
        PaneRef::Role { role } => PaneRefDto::role(role.as_str()),
        PaneRef::Direction { direction } => PaneRefDto::direction(direction_name(*direction)),
        PaneRef::Focused => PaneRefDto::focused(),
    }
}

fn direction_name(direction: Direction) -> &'static str {
    match direction {
        Direction::Left => "left",
        Direction::Right => "right",
        Direction::Up => "up",
        Direction::Down => "down",
        Direction::Next => "next",
        Direction::Prev => "prev",
    }
}

fn linear_name(dir: LinearDir) -> &'static str {
    match dir {
        LinearDir::Horizontal => "horizontal",
        LinearDir::Vertical => "vertical",
    }
}

fn placement_name(placement: Placement) -> &'static str {
    match placement {
        Placement::Left => "left",
        Placement::Right => "right",
        Placement::Above => "above",
        Placement::Below => "below",
        Placement::IntoTabs => "into-tabs",
    }
}

fn container_kind_name(kind: impress_layout::ContainerKind) -> &'static str {
    use impress_layout::ContainerKind::*;
    match kind {
        Tabs => "tabs",
        Horizontal => "horizontal",
        Vertical => "vertical",
        Grid => "grid",
    }
}

fn channel_name(channel: ChannelId) -> String {
    match channel {
        ChannelId::Number(n) => n.to_string(),
        ChannelId::Follow => "follow".to_string(),
    }
}

// ─── The feed's worker ───────────────────────────────────────────────────

// The debounce/burst/external-poll cadence and the `Feed`/`ExternalPoll`
// mechanics are `crate::ui_feed`'s — shared with `surface.rs`'s feed (see
// that module's docs). These aliases keep every existing reference below
// (and every doc link to them) unchanged.
const DEFAULT_DEBOUNCE_MS: u64 = ui_feed::DEFAULT_DEBOUNCE_MS;
/// How often the worker wakes to check for a version change or a burst that
/// has gone quiet. Shorter than the default debounce, so a burst is flushed
/// one poll after it ends rather than one debounce late.
const POLL: Duration = ui_feed::POLL;
/// A burst that never goes quiet is flushed anyway after this many debounce
/// windows, so a continuous writer cannot starve the renderer.
const MAX_BURST_DEBOUNCES: u32 = ui_feed::MAX_BURST_DEBOUNCES;

/// Default interval between polls of [`SqliteItemStore::data_version`] for
/// the cross-process invalidation path (ADR-0033 D6, see the module docs).
/// `PRAGMA data_version` is a per-connection counter with no I/O beyond the
/// pragma itself, so polling it at this cadence is cheap; 250 ms keeps a
/// chat-driven write visible in well under a second.
const EXTERNAL_POLL_MS: u64 = ui_feed::EXTERNAL_POLL_MS;

struct InvalidationFeed {
    running: Arc<AtomicBool>,
    listener: Arc<dyn SharedLayoutListener>,
    version: Arc<AtomicU64>,
    service: DefaultLayoutService,
    store: Arc<SqliteItemStore>,
    app_id: String,
    device: Option<String>,
    debounce: Duration,
    grace: Duration,
    external_poll: Duration,
}

impl InvalidationFeed {
    fn run(self, rx: std::sync::mpsc::Receiver<impress_core::event::StoreMutation>) {
        let started = Instant::now();
        let mut subscriptions: QuerySubscriptions<u64> = QuerySubscriptions::new();
        let mut subscriptions_stale = true;
        let mut notified_version = self.version.load(Ordering::SeqCst);

        let mut pending: Vec<impress_core::event::StoreMutation> = Vec::new();
        let mut burst_started: Option<Instant> = None;
        let mut last_seen: Option<Instant> = None;
        // Panes invalidated but not yet delivered — non-empty only during the
        // startup grace, which is the whole point of holding them.
        let mut held: Vec<u64> = Vec::new();
        let mut grace_over = self.grace.is_zero();

        // Cross-process liveness (ADR-0033 D6, see the module docs): baselined
        // against this connection's own `data_version`/"now" before the loop
        // starts, so an `impress/ui/` row already in the file at subscribe
        // time is not replayed — only writes made from here on are external
        // mutations to this feed. `crate::ui_feed::ExternalPoll` is the same
        // mechanism `surface.rs`'s feed uses, narrowed to its own prefix.
        let mut external = ExternalPoll::baseline(&self.store);
        let mut last_external_poll = Instant::now();
        // In-process, cross-object liveness: the session registry is shared
        // with the surface executor (see `SharedStore::layout_sessions`), and
        // its generation moves on every mutation made through it. One this
        // handle made comes with a `self.version` bump from `finish`; one it
        // did NOT make — a surface's `open` or `publish` effect — moves the
        // generation alone, and that is the tree changing under the window.
        let sessions = self.service.sessions();
        let mut seen_generation = sessions.generation();
        let mut seen_version = self.version.load(Ordering::SeqCst);

        while self.running.load(Ordering::SeqCst) {
            match rx.recv_timeout(POLL) {
                Ok(mutation) => {
                    if burst_started.is_none() {
                        burst_started = Some(Instant::now());
                    }
                    last_seen = Some(Instant::now());
                    pending.push(mutation);
                }
                Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {}
                Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
            }

            if last_external_poll.elapsed() >= self.external_poll {
                last_external_poll = Instant::now();
                let mutations = external.check(&self.store, ui_feed::EXTERNAL_UI_PREFIX);
                if !mutations.is_empty() {
                    // A row under `impress/ui/` that ANOTHER process wrote can
                    // be the TREE itself, not just a pane's data — that is the
                    // whole D6 case: an agent calls `surface_show` (or any
                    // layout verb) from impress-mcp and the window must grow
                    // the pane. Only `self.version` drives `layout_changed`
                    // below, and nothing external bumps it: the verb ran in
                    // the other process, against its own `SharedLayout`. So
                    // the panes were invalidated and the tree was never
                    // re-read — the new pane sat in the store, correct and
                    // invisible, until something in THIS process happened to
                    // apply a verb.
                    //
                    // Bumping the version here is what a locally applied verb
                    // does in `finish`, and it is the same claim: "the tree
                    // you are holding is stale." The host reloads, sees the
                    // pane, and the number stays monotonic for the snapshot.
                    if mutations
                        .iter()
                        .any(|m| m.schema_ref.as_deref() == Some(schemas::ui::LAYOUT_SCHEMA_REF))
                    {
                        // Two things are stale, not one. The service caches a
                        // `LayoutSession` per (app, device) and only reads the
                        // row when it has none, so a reload triggered here
                        // would be answered from the session this process
                        // built — the window would redraw exactly what it
                        // already had. Drop the session first, THEN bump.
                        self.service
                            .forget_session(&self.app_id, self.device.as_deref());
                        self.version.fetch_add(1, Ordering::SeqCst);
                    }
                    if burst_started.is_none() {
                        burst_started = Some(Instant::now());
                    }
                    last_seen = Some(Instant::now());
                    pending.extend(mutations);
                }
            }

            let generation = sessions.generation();
            if generation != seen_generation {
                seen_generation = generation;
                let version_now = self.version.load(Ordering::SeqCst);
                if version_now == seen_version {
                    // Nobody bumped the version, so this was not one of our
                    // verbs: the session is already current (same registry),
                    // only the host does not know yet.
                    self.version.fetch_add(1, Ordering::SeqCst);
                }
                seen_version = self.version.load(Ordering::SeqCst);
            }

            // The tree changed under us: tell the host, and remember that the
            // dependency set has to be rebuilt before the next match. The
            // rebuild itself is deferred to the flush, because it reads the
            // store and a drag bumps the version every few milliseconds.
            let version = self.version.load(Ordering::SeqCst);
            if version != notified_version {
                notified_version = version;
                subscriptions_stale = true;
                self.listener.layout_changed(version);
            }

            let quiet = last_seen
                .map(|t| t.elapsed() >= self.debounce)
                .unwrap_or(false);
            let overdue = burst_started
                .map(|t| t.elapsed() >= self.debounce * MAX_BURST_DEBOUNCES)
                .unwrap_or(false);
            if !pending.is_empty() && (quiet || overdue) {
                if subscriptions_stale {
                    subscriptions = self.build_subscriptions();
                    subscriptions_stale = false;
                }
                for pane in subscriptions.affected_by_all(pending.iter()) {
                    if !held.contains(&pane) {
                        held.push(pane);
                    }
                }
                pending.clear();
                burst_started = None;
                last_seen = None;
            }

            if !grace_over && started.elapsed() >= self.grace {
                grace_over = true;
            }
            if grace_over && !held.is_empty() {
                self.listener.panes_invalidated(std::mem::take(&mut held));
            }
        }
    }

    /// Recompile every pane of the live tree and key the registry by tile id.
    ///
    /// A pane whose query does not compile (an unbound required parameter — a
    /// detail pane with nothing selected) is simply not registered: it has no
    /// result to invalidate, and it will be compiled again the moment a
    /// selection binds it, because publishing one bumps the version.
    fn build_subscriptions(&self) -> QuerySubscriptions<u64> {
        let mut subscriptions = QuerySubscriptions::new();
        let Ok(layout) = read_layout(&self.service, &self.app_id, self.device.clone()) else {
            return subscriptions;
        };
        let resolver = CollectionSubtrees::read(&self.store);
        let manifest = builtin_manifest();
        for tile in layout.panes() {
            let Some(spec) = layout.pane(tile) else {
                continue;
            };
            let bindings = layout.bindings_for(tile);
            let decls: Vec<ParamDecl> = spec.params.iter().map(|b| b.decl.clone()).collect();
            if let Ok(compiled) = compile_with(&spec.query, &decls, &bindings, &manifest, &resolver)
            {
                subscriptions.insert_compiled(tile.raw(), &compiled);
            }
        }
        subscriptions
    }
}

/// Expands a collection id into that collection and every collection beneath
/// it, for `Scope::CollectionSubtree`.
///
/// A copy of the resolver `impress-layout-service` builds inside `get_pane`,
/// because that one is private to the service and the feed has to compile the
/// same queries the service does — a pane scoped to a folder must be woken
/// when a paper is filed into a *descendant* of it. If the service ever
/// publishes its resolver, delete this.
struct CollectionSubtrees {
    children: BTreeMap<ItemId, Vec<ItemId>>,
}

impl CollectionSubtrees {
    fn read(store: &SqliteItemStore) -> Self {
        const BINDINGS: [CollectionSchemaBinding; 4] = [
            GENERIC_COLLECTION,
            IMBIB_COLLECTION,
            MANUSCRIPT_COLLECTION,
            FIGURE_COLLECTION,
        ];
        let mut children: BTreeMap<ItemId, Vec<ItemId>> = BTreeMap::new();
        for binding in BINDINGS {
            let Ok(rows) = collection_ops::list_tree(store, &binding) else {
                continue;
            };
            for row in rows {
                let (Ok(id), Some(Ok(parent))) = (
                    row.id.parse::<ItemId>(),
                    row.parent_id.as_deref().map(str::parse::<ItemId>),
                ) else {
                    continue;
                };
                children.entry(parent).or_default().push(id);
            }
        }
        Self { children }
    }
}

impl SubtreeResolver for CollectionSubtrees {
    fn subtree(&self, root: ItemId) -> Vec<ItemId> {
        let mut out = vec![root];
        let mut frontier = vec![root];
        // Depth-bounded by construction: a collection tree is finite and the
        // visited set is `out`, so a cycle in hand-edited data terminates.
        while let Some(next) = frontier.pop() {
            let Some(kids) = self.children.get(&next) else {
                continue;
            };
            for kid in kids {
                if !out.contains(kid) {
                    out.push(*kid);
                    frontier.push(*kid);
                }
            }
        }
        out
    }
}

// ─── Free functions: the query algebra without a pane ────────────────────

/// Compile a pane query against the built-in record-kind manifest.
///
/// `query_json` is an `impress_core::pane_query::PaneQuery`, `decls_json` a
/// `[ParamDecl]`, `bindings_json` an object of parameter name → item id.
/// Returns the `ItemQuery` JSON the store would be asked — which is what a
/// debug console shows when the question is "why is this pane empty?".
///
/// `Scope::CollectionSubtree` degrades to the named collection's own members
/// here: there is no store to read the tree from. Use
/// [`SharedLayout::pane`] when descendants matter.
#[cfg_attr(feature = "native", uniffi::export)]
pub fn compile_pane_query(
    query_json: String,
    decls_json: String,
    bindings_json: String,
) -> Result<String> {
    let query: PaneQuery = serde_json::from_str(&query_json).map_err(SharedLayoutError::json)?;
    let decls: Vec<ParamDecl> = if decls_json.trim().is_empty() {
        Vec::new()
    } else {
        serde_json::from_str(&decls_json).map_err(SharedLayoutError::json)?
    };
    let raw: BTreeMap<String, String> = if bindings_json.trim().is_empty() {
        BTreeMap::new()
    } else {
        serde_json::from_str(&bindings_json).map_err(SharedLayoutError::json)?
    };
    let mut bindings = Bindings::new();
    for (name, id) in raw {
        let id: ItemId = id.parse().map_err(|_| SharedLayoutError::Json {
            message: format!("binding '{name}' is not an item id: {id}"),
        })?;
        bindings = bindings.with(name, id);
    }
    let compiled = compile(&query, &decls, &bindings, &builtin_manifest()).map_err(|e| {
        SharedLayoutError::Query {
            message: e.to_string(),
        }
    })?;
    serde_json::to_string(&compiled.item_query).map_err(SharedLayoutError::json)
}

/// The record-kind manifest as JSON: kind id → the schema refs the store
/// matches by exact equality. The one place that mapping lives.
#[cfg_attr(feature = "native", uniffi::export)]
pub fn kind_manifest_json() -> String {
    serde_json::to_string(&builtin_manifest()).unwrap_or_else(|_| "{}".into())
}

/// The cold-start three-column preset as layout JSON, for a host that wants to
/// render before it has opened a store. Nothing persists it.
#[cfg_attr(feature = "native", uniffi::export)]
pub fn cold_start_layout_json() -> String {
    serde_json::to_string(&impress_layout_service::cold_start_layout())
        .unwrap_or_else(|_| "{}".into())
}

/// A pane spec's JSON, for a host building a `Split` verb's `new` pane without
/// hand-writing the shape.
#[cfg_attr(feature = "native", uniffi::export)]
pub fn pane_spec_json(query_json: String, view_kind: String) -> Result<String> {
    let query: PaneQuery = serde_json::from_str(&query_json).map_err(SharedLayoutError::json)?;
    let spec = PaneSpec::new(query, view_kind.into());
    serde_json::to_string(&spec).map_err(SharedLayoutError::json)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc;

    const PUBLICATION_SCHEMA: &str = "imbib/bibliography-entry";

    fn open() -> (Arc<SharedStore>, Arc<SharedLayout>) {
        let store = SharedStore::open_in_memory().expect("open");
        let layout = SharedLayout::open(store.clone(), "test-app".into(), Some("test".into()));
        (store, layout)
    }

    fn role_of(layout: &SharedLayout, role: &str) -> u64 {
        layout
            .pane_with_role(role.into())
            .expect("read roles")
            .unwrap_or_else(|| panic!("no pane holds the role '{role}'"))
    }

    fn seed_publication(store: &SharedStore, title: &str) -> String {
        let id = uuid::Uuid::new_v4().to_string();
        store
            .upsert_item(
                id.clone(),
                PUBLICATION_SCHEMA.into(),
                format!(r#"{{"title": "{title}"}}"#),
            )
            .expect("seed publication");
        id
    }

    #[test]
    fn a_cold_start_snapshot_is_the_three_column_tree() {
        let (_store, layout) = open();
        let snapshot = layout.snapshot().expect("snapshot");

        assert_eq!(snapshot.windows.len(), 1, "one window at cold start");
        assert_eq!(
            snapshot.leaves.len(),
            3,
            "navigator | list | detail, in tree order: {:?}",
            snapshot.leaves
        );
        assert_eq!(snapshot.windows[0].leaves, snapshot.leaves);
        assert_eq!(snapshot.version, 0, "no verb has been applied yet");

        // Focus starts on the list: it is the pane the triage grammar acts on.
        let list = role_of(&layout, "list");
        assert_eq!(snapshot.focused, Some(list));

        // The tree really is the crate's value, not a mirror of it.
        let parsed: Layout = serde_json::from_str(&snapshot.layout_json).expect("layout json");
        assert_eq!(parsed.panes().len(), 3);
    }

    #[test]
    fn a_split_arrives_as_json_and_a_focus_step_as_a_typed_call() {
        let (_store, layout) = open();
        let before = layout.snapshot().expect("snapshot");
        let list = role_of(&layout, "list");

        let applied = layout
            .apply(
                serde_json::json!({
                    "verb": "split",
                    "target": { "ref": "id", "tile": list },
                    "dir": "vertical",
                    "after": true,
                })
                .to_string(),
                "human".into(),
            )
            .expect("split");

        assert_eq!(applied.version, 1);
        assert!(
            !applied.changed_tiles.is_empty(),
            "a split touches tiles: {applied:?}"
        );
        let after = layout.snapshot().expect("snapshot");
        assert_eq!(after.leaves.len(), before.leaves.len() + 1);
        assert_eq!(
            applied.focused, after.focused,
            "focus follows the new pane, and the snapshot agrees"
        );

        // The same grammar, typed: stepping focus left from the new pane.
        let stepped = layout
            .focus_direction("left".into(), "human".into())
            .expect("focus left");
        assert_eq!(stepped.version, 2);
        assert_ne!(stepped.focused, applied.focused);

        // …and an unknown verb is a typed refusal, not a silent no-op.
        let refused = layout.apply(r#"{"verb":"teleport"}"#.into(), "human".into());
        assert!(matches!(refused, Err(SharedLayoutError::Json { .. })));
    }

    #[test]
    fn selecting_in_the_list_is_what_the_detail_pane_reads() {
        let (store, layout) = open();
        let list = role_of(&layout, "list");
        let detail = role_of(&layout, "detail");

        let wanted = seed_publication(&store, "Reionization");
        let _other = seed_publication(&store, "Something else");

        // Before a selection the detail pane's `$item` is unbound. ADR-0031
        // D3: an unfilled parameter renders the view kind's EMPTY STATE, so
        // this compiles — to a query narrowed to no ids at all. Both halves
        // matter: it is not a refusal (an unfilled pane is not a broken one),
        // and it is not an unconstrained query (a dropped predicate would
        // show the user every paper in the store and call it the selection).
        let unfilled = layout
            .pane(detail)
            .expect("an unfilled detail pane still compiles");
        assert!(unfilled.single_item.is_none());
        assert!(
            unfilled.compiled_query_json.contains(r#"{"In":["id",[]]}"#),
            "the unfilled detail pane must match NOTHING: {}",
            unfilled.compiled_query_json
        );
        assert!(
            layout
                .run_pane(detail, 0, 0)
                .expect("run an unfilled pane")
                .is_empty(),
            "and running it returns no rows, which is what the empty state draws"
        );

        let applied = layout
            .select(
                list,
                "publication".into(),
                vec![wanted.clone()],
                "human".into(),
            )
            .expect("select");
        assert!(
            applied.affected_panes.contains(&detail),
            "the detail pane follows channel 1: {applied:?}"
        );

        let pane = layout.pane(detail).expect("detail pane compiles now");
        assert_eq!(pane.single_item.as_deref(), Some(wanted.as_str()));

        let rows = layout.run_pane(detail, 0, 0).expect("run detail");
        assert_eq!(rows.len(), 1, "the detail pane shows exactly the selection");
        assert_eq!(rows[0].id, wanted);

        // And the list pane reads both, through the same path.
        let listed = layout.run_pane(list, 0, 0).expect("run list");
        assert_eq!(listed.len(), 2);
    }

    #[test]
    fn a_share_of_zero_hides_a_pane_without_taking_it_out_of_the_tree() {
        let (_store, layout) = open();
        let navigator = role_of(&layout, "navigator");

        let applied = layout
            .resize_share(navigator, 0.0, "human".into())
            .expect("resize");
        assert!(applied.version >= 1);

        let snapshot = layout.snapshot().expect("snapshot");
        assert!(
            snapshot.leaves.contains(&navigator),
            "the pane stays in the tree"
        );
        let parsed: Layout = serde_json::from_str(&snapshot.layout_json).expect("layout json");
        let root = parsed.parent_of(TileId::new(navigator)).expect("parent");
        let shares = parsed
            .tile(root)
            .and_then(Tile::as_container)
            .and_then(Container::shares)
            .expect("the root is a split")
            .to_vec();
        assert_eq!(shares[0], HIDDEN_SHARE, "shares: {shares:?}");

        // Undo puts the share back: an arrangement gesture lands on the
        // arrangement ring.
        layout
            .undo("arrangement".into(), None, "human".into())
            .expect("undo");
        let parsed: Layout =
            serde_json::from_str(&layout.snapshot().expect("snapshot").layout_json).unwrap();
        let shares = parsed
            .tile(root)
            .and_then(Tile::as_container)
            .and_then(Container::shares)
            .expect("the root is a split")
            .to_vec();
        assert_eq!(shares[0], 1.0);
    }

    #[test]
    fn a_layout_saves_and_lists_under_its_ordinal() {
        let (_store, layout) = open();
        layout
            .save_layout(
                "Triage".into(),
                Some("morning sweep".into()),
                "human".into(),
            )
            .expect("save");
        let rows = layout.list_layouts().expect("list");
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].ordinal, 1);
        assert_eq!(rows[0].name.as_deref(), Some("Triage"));
        assert_eq!(rows[0].purpose.as_deref(), Some("morning sweep"));
        assert!(!rows[0].created.is_empty());

        layout
            .apply_layout("1".into(), "human".into())
            .expect("recall by ordinal");
        layout
            .apply_layout("Triage".into(), "human".into())
            .expect("recall by name");
    }

    #[test]
    fn a_deleted_layout_leaves_the_list() {
        let (_store, layout) = open();
        layout
            .save_layout("Triage".into(), None, "human".into())
            .expect("save");
        assert_eq!(layout.list_layouts().expect("list").len(), 1);

        layout
            .delete_layout("Triage".into(), "human".into())
            .expect("delete");
        assert!(layout.list_layouts().expect("list").is_empty());
    }

    #[test]
    fn compiling_a_query_needs_no_pane() {
        let manifest = kind_manifest_json();
        assert!(manifest.contains(PUBLICATION_SCHEMA));

        let compiled = compile_pane_query(
            r#"{"kinds":["publication"]}"#.into(),
            String::new(),
            String::new(),
        )
        .expect("compile");
        assert!(
            compiled.contains(PUBLICATION_SCHEMA),
            "the compiled query names the schema ref: {compiled}"
        );

        // An unknown kind is refused, not silently empty.
        let refused = compile_pane_query(
            r#"{"kinds":["nonsense"]}"#.into(),
            String::new(),
            String::new(),
        );
        assert!(matches!(refused, Err(SharedLayoutError::Query { .. })));
    }

    // ---------------------------------------------------------- the feed

    #[derive(Debug)]
    struct Recorder {
        panes: mpsc::Sender<Vec<u64>>,
        versions: mpsc::Sender<u64>,
    }

    impl SharedLayoutListener for Recorder {
        fn panes_invalidated(&self, panes: Vec<u64>) {
            let _ = self.panes.send(panes);
        }
        fn layout_changed(&self, version: u64) {
            let _ = self.versions.send(version);
        }
    }

    fn recorder() -> (Box<dyn SharedLayoutListener>, mpsc::Receiver<Vec<u64>>) {
        let (panes, rx) = mpsc::channel();
        let (versions, _drop) = mpsc::channel();
        // The version feed is not under test here; keep the receiver alive so
        // the sender never errors, and let it be dropped with the test.
        std::mem::forget(_drop);
        (Box::new(Recorder { panes, versions }), rx)
    }

    /// Both channels, for the tests that care which one fired.
    fn recorder_with_versions() -> (
        Box<dyn SharedLayoutListener>,
        mpsc::Receiver<Vec<u64>>,
        mpsc::Receiver<u64>,
    ) {
        let (panes, panes_rx) = mpsc::channel();
        let (versions, versions_rx) = mpsc::channel();
        (
            Box::new(Recorder { panes, versions }),
            panes_rx,
            versions_rx,
        )
    }

    #[test]
    fn a_mutation_wakes_only_the_panes_that_query_it() {
        let (store, layout) = open();
        let list = role_of(&layout, "list");
        let navigator = role_of(&layout, "navigator");

        layout.set_debounce_ms(20);
        let (listener, panes) = recorder();
        layout.subscribe_invalidations(listener).expect("subscribe");

        seed_publication(&store, "First light");

        let batch = panes
            .recv_timeout(Duration::from_secs(5))
            .expect("one batch after the debounce");
        assert_eq!(
            batch,
            vec![list],
            "the list pane queries publications; the navigator queries collections"
        );
        assert!(!batch.contains(&navigator));

        // A burst coalesces: three inserts, one delivery.
        for i in 0..3 {
            seed_publication(&store, &format!("Burst {i}"));
        }
        let batch = panes
            .recv_timeout(Duration::from_secs(5))
            .expect("the burst lands");
        assert_eq!(batch, vec![list]);
        assert!(
            panes.recv_timeout(Duration::from_millis(300)).is_err(),
            "a burst wakes each pane once"
        );

        layout.unsubscribe_invalidations();
    }

    #[test]
    fn nothing_is_delivered_during_the_startup_grace() {
        let (store, layout) = open();
        let list = role_of(&layout, "list");

        layout.set_debounce_ms(20);
        layout.set_startup_grace_secs(1);
        let (listener, panes) = recorder();
        layout.subscribe_invalidations(listener).expect("subscribe");

        seed_publication(&store, "During the grace");
        assert!(
            panes.recv_timeout(Duration::from_millis(600)).is_err(),
            "the startup guard holds invalidations back (ADR-0019 D6)"
        );

        let batch = panes
            .recv_timeout(Duration::from_secs(5))
            .expect("one batch once the grace is over");
        assert_eq!(batch, vec![list]);
        assert!(
            panes.recv_timeout(Duration::from_millis(300)).is_err(),
            "the held invalidations arrive as ONE batch, not a replay"
        );

        layout.unsubscribe_invalidations();
    }

    /// ADR-0033 D6: a write from ANOTHER `SqliteItemStore` handle on the same
    /// file — the shape of `impress-mcp`, a separate process writing the same
    /// database — is picked up by the external `data_version` poll and
    /// delivered through the same `panes_invalidated` path as an in-process
    /// mutation, with no HTTP relay between the two.
    ///
    /// `:memory:` cannot show this (private to one connection), so this test
    /// opens a real temp file and a second `SharedStore` (which itself opens
    /// a second `SqliteItemStore` handle) on it. The tree needs a pane whose
    /// query actually matches the written kind for an invalidation to fire —
    /// the layout tree itself is not pane-queryable — so the list pane is
    /// retargeted at `"surface"` (`impress/ui/surface@1.0.0`, already in the
    /// built-in manifest per ADR-0033 D1), which is exactly the
    /// agent-facing-surface case D6 exists for.
    #[test]
    fn an_external_connections_write_is_seen_within_one_poll() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("external_poll.sqlite");
        let path_str = path.to_str().unwrap().to_string();

        let store = SharedStore::open(path_str.clone()).expect("open");
        let layout = SharedLayout::open(store.clone(), "test-app".into(), Some("test".into()));
        let list = role_of(&layout, "list");

        layout
            .apply(
                r#"{"verb":"set-query","target":{"ref":"role","role":"list"},"query":{"kinds":["surface"]}}"#.into(),
                "human".into(),
            )
            .expect("retarget the list pane at the surface kind");

        layout.set_debounce_ms(20);
        layout.set_startup_grace_secs(0);
        layout.set_external_poll_ms(20);
        let (listener, panes) = recorder();
        layout.subscribe_invalidations(listener).expect("subscribe");

        // A second handle on the SAME file — not the `store` the feed's own
        // `SharedLayout` was opened on.
        let external = SharedStore::open(path_str).expect("open a second handle");
        external
            .upsert_item(
                uuid::Uuid::new_v4().to_string(),
                "impress/ui/surface@1.0.0".into(),
                r#"{"title": "agent surface"}"#.into(),
            )
            .expect("external write");

        let batch = panes
            .recv_timeout(Duration::from_secs(1))
            .expect("the external write is seen within roughly one poll interval");
        assert_eq!(batch, vec![list]);

        layout.unsubscribe_invalidations();
    }

    /// ADR-0033 D6, the half the pane-invalidation test does not cover: when
    /// the other process writes the TREE — `surface_show`, or any layout verb
    /// from `impress-mcp` — the host must be told the tree changed, not merely
    /// that some pane's data did. Nothing external bumps this handle's
    /// version counter (the verb ran against another `SharedLayout`), so
    /// without the external poll bumping it the new pane sits in the store,
    /// correct and invisible, until this process happens to apply a verb of
    /// its own. Verified live on 2026-09-22: the pane appeared only after
    /// this fix.
    #[test]
    fn an_external_tree_write_tells_the_host_the_tree_changed() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("external_tree.sqlite");
        let path_str = path.to_str().unwrap().to_string();

        let store = SharedStore::open(path_str.clone()).expect("open the store");
        let layout = SharedLayout::open(store.clone(), "impress".into(), None);
        let before = layout.version();

        layout.set_debounce_ms(20);
        layout.set_startup_grace_secs(0);
        layout.set_external_poll_ms(20);
        let (listener, _panes, versions) = recorder_with_versions();
        layout.subscribe_invalidations(listener).expect("subscribe");

        // A second handle on the same file, applying a real verb: the shape of
        // an agent driving the suite from a chat.
        let external_store = SharedStore::open(path_str).expect("open a second handle");
        let external = SharedLayout::open(external_store, "impress".into(), None);
        let tiles_before = layout.snapshot().expect("snapshot").windows.len();
        let leaves_before = layout.snapshot().expect("snapshot").leaves.len();
        external
            .apply(
                r#"{"verb":"split","target":{"ref":"role","role":"detail"},"dir":"vertical",
                    "after":true,"new":{"view_kind":"surface","query":{"kinds":["surface"],
                    "scope":{"scope":"all"},"filters":[],"sort":[],"limit":null,
                    "relation":null,"text":null}}}"#
                    .into(),
                "agent".into(),
            )
            .expect("the other process splits a pane");

        let version = versions
            .recv_timeout(Duration::from_secs(2))
            .expect("the host is told the tree changed, within roughly one poll interval");
        assert!(
            version > before,
            "the version must move forward: {version} <= {before}"
        );

        // The notification is worth nothing if the reload it triggers answers
        // from a cached session: that is the second half of the same bug, and
        // the only observable difference is right here.
        let after = layout
            .snapshot()
            .expect("snapshot after the external split");
        assert!(
            after.leaves.len() > leaves_before,
            "the reloaded tree must contain the other process's pane: \
             {} leaves before, {} after ({} windows before)",
            leaves_before,
            after.leaves.len(),
            tiles_before
        );

        layout.unsubscribe_invalidations();
    }

    /// The in-process half of D6: another object on the SAME store and the
    /// SAME connection — the surface executor running an `open` effect —
    /// applies a verb through the shared session registry. `data_version`
    /// is silent for a connection's own writes and nothing bumps this
    /// handle's version, so before the registry's generation was watched the
    /// pane sat in the store, in this process, and the window never re-read
    /// the tree (2026-09-23, an `open` effect reported ok and drew nothing).
    #[test]
    fn a_verb_from_another_object_in_this_process_tells_the_host_the_tree_changed() {
        let (store, layout) = open();
        let leaves_before = layout.snapshot().expect("snapshot").leaves.len();

        layout.set_debounce_ms(20);
        layout.set_startup_grace_secs(0);
        let (listener, _panes, versions) = recorder_with_versions();
        layout.subscribe_invalidations(listener).expect("subscribe");

        // What `SharedSurface`'s executor does: the same store, the same
        // registry, a different service object.
        let other =
            DefaultLayoutService::with_store_and_sessions(store.core(), store.layout_sessions());
        let new_pane = PaneSpec::new(
            serde_json::from_value(serde_json::json!({
                "kinds": ["surface"], "scope": {"scope": "all"}, "filters": [],
                "sort": [], "limit": null, "relation": null, "text": null
            }))
            .unwrap(),
            impress_layout::ViewKindId::from("surface".to_string()),
        );
        let split = runtime().block_on(other.split(
            "test-app".into(),
            Some("test".into()),
            PaneRefDto::role("detail"),
            "vertical".into(),
            true,
            Some(new_pane),
            Some("agent".into()),
        ));
        assert!(split.ok, "{}", split.message);

        // Ten seconds, not two: the feed answers in milliseconds on a quiet
        // machine, but under a parallel release build on Linux this wait
        // missed a two-second window three runs out of three (2026-09-23) and
        // passed every time alone. The bound only has to be longer than a
        // starved scheduler, never a measure of the feed's own latency.
        versions
            .recv_timeout(Duration::from_secs(10))
            .expect("the host is told the tree changed");
        let after = layout.snapshot().expect("snapshot after");
        assert!(
            after.leaves.len() > leaves_before,
            "the reloaded tree must contain the pane the other object opened"
        );
        layout.unsubscribe_invalidations();
    }
}
