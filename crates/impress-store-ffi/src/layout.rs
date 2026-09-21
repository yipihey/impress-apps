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
    compile, compile_with, Bindings, KindManifest, PaneQuery, ParamDecl, SubtreeResolver,
};
use impress_core::query::ItemQuery;
use impress_core::sqlite_store::SqliteItemStore;
use impress_core::store::ItemStore;
use impress_layout::{
    ChannelId, Container, Direction, Layout, LinearDir, PaneRef, PaneSpec, Placement, Role, Tile,
    TileId, Verb,
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

struct Feed {
    running: Arc<AtomicBool>,
    join: Option<std::thread::JoinHandle<()>>,
}

impl Feed {
    fn stop(&mut self) {
        self.running.store(false, Ordering::SeqCst);
        if let Some(join) = self.join.take() {
            let _ = join.join();
        }
    }
}

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
            service: DefaultLayoutService::with_store(core.clone()),
            store: core,
            app_id,
            device,
            version: Arc::new(AtomicU64::new(0)),
            debounce_ms: AtomicU64::new(DEFAULT_DEBOUNCE_MS),
            startup_grace_secs: AtomicU64::new(0),
            feed: Mutex::new(None),
        })
    }

    /// How long a burst of store mutations is coalesced before the feed calls
    /// `panes_invalidated`. Default 50 ms. Set before subscribing.
    pub fn set_debounce_ms(&self, millis: u32) {
        self.debounce_ms
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
    /// share to [`MIN_SHARE`] and back. The tree refuses a share of exactly
    /// zero (`InvalidShares`: a weight must be positive and finite), so
    /// "hidden" is spelled as the smallest weight it accepts — sub-pixel
    /// against any realistic sum, and reversible by one `Resize`. Hiding a pane by *closing* it would take its
    /// session and its place in the tree with it, and a hidden-role set kept
    /// beside the tree would be exactly the view-held layout state ADR-0019 D3
    /// exists to remove — so the pane stays in the tree with no width.
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
        shares[index] = share.max(MIN_SHARE);
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

/// The smallest share a pane can be given. `impress_layout` requires a
/// positive, finite weight, so a "hidden" pane is a very small one rather
/// than a zero-width one — which is also what keeps it in the tree, with its
/// session and its place, instead of closing it.
pub const MIN_SHARE: f32 = 1e-4;

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

const DEFAULT_DEBOUNCE_MS: u64 = 50;
/// How often the worker wakes to check for a version change or a burst that
/// has gone quiet. Shorter than the default debounce, so a burst is flushed
/// one poll after it ends rather than one debounce late.
const POLL: Duration = Duration::from_millis(10);
/// A burst that never goes quiet is flushed anyway after this many debounce
/// windows, so a continuous writer cannot starve the renderer.
const MAX_BURST_DEBOUNCES: u32 = 10;

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
        let manifest = KindManifest::builtin();
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
    let compiled = compile(&query, &decls, &bindings, &KindManifest::builtin()).map_err(|e| {
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
    serde_json::to_string(&KindManifest::builtin()).unwrap_or_else(|_| "{}".into())
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

        // Before a selection the detail pane has an unbound required
        // parameter: a typed refusal, never an empty list called the truth.
        assert!(matches!(
            layout.pane(detail),
            Err(SharedLayoutError::Query { .. })
        ));

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
        assert_eq!(shares[0], MIN_SHARE, "shares: {shares:?}");

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
}
