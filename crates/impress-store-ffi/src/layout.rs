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
//! # Whose change is it?
//!
//! Every chassis app opens the same SQLite file, and every verb writes its
//! app's live row — a focus keystroke included. So "a layout row changed
//! elsewhere" is not "my tree changed": the feed reacts to a layout row only
//! when it is THIS scope's live row (`is_live`, this `app_id`, this device)
//! at a revision this object has not already told its host about. A named
//! layout or a preset of this app changes the saved-layouts list, not the
//! tree, and is reported as [`SharedLayoutListener::layouts_changed`]; any
//! other app's row is none of this window's business (review RL-L2: an h in
//! impress used to make every other running app drop its undo rings and
//! reload its whole tree). The service reloads a session whose row moved on
//! its own (`SessionRegistry::with` checks the revision on every touch), so
//! the feed no longer forgets sessions at all.
//!
//! "Already told" is one number per object: the live row's revision (its
//! `logical_clock`) the host last received with a tree. A verb records the
//! revision it produced under the same lock the feed checks under, so the
//! feed can never mistake this object's own verb for someone else's, nor a
//! write that lands during a verb for this object's own (review RL-L9); and a
//! verb that changed nothing moves no revision and bumps no version.
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

use impress_core::item::ActorKind;
use impress_core::item::{ItemId, Value};
use impress_core::pane_query::invalidation::QuerySubscriptions;
use impress_core::pane_query::{
    builtin_manifest, compile, compile_with, Bindings, PaneQuery, ParamDecl,
};
use impress_core::schemas;
use impress_core::sqlite_store::SqliteItemStore;
use impress_core::store::ItemStore;
use impress_layout::{
    ChannelId, Container, Layout, PaneRef, PaneSpec, Role, Tile, TileId, Verb, HIDDEN_SHARE,
};
use impress_layout_service::device::resolve_device;
use impress_layout_service::{
    CollectionSubtrees, DefaultLayoutService, LayoutService, LayoutStore, LayoutVerbResult,
    PaneRefDto,
};

use crate::{item_to_row, SharedItemRow, SharedStore};
use impress_service_core::Refusal;

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
    /// pane of a window, a detach of a whole window. `code` is the refusal's
    /// stable name — a `LayoutError` tag (`unknown-tile`,
    /// `cannot-close-last-pane`, …) or a generic code (`invalid-argument`,
    /// `not-found`, `conflict`, `store-error`, `store-unavailable`) — so a
    /// caller branches on it, never on the prose (review RL-L11).
    #[error("{message}")]
    Layout { code: String, message: String },
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
    fn layout(refusal: Refusal) -> Self {
        SharedLayoutError::Layout {
            code: refusal.code,
            message: refusal.message,
        }
    }

    /// A service result's refusal, code and all.
    fn refused(code: Option<String>, message: String) -> Self {
        SharedLayoutError::Layout {
            code: code.unwrap_or_else(|| "refused".to_string()),
            message,
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
    /// The live layout row's revision (its `logical_clock`) this tree is —
    /// the number an agent passes back as `expected_revision`. Unlike
    /// `version`, which counts this object's redraws, it is the store's, the
    /// same in every process.
    pub revision: Option<u64>,
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
    /// The live row's revision after the verb (see
    /// [`SharedLayoutSnapshot::revision`]).
    pub revision: Option<u64>,
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

/// One page of a pane's rows, and how many the pane's query has in all —
/// so a list pane can say "showing 500 of 2,657" instead of presenting a
/// cut list as the whole result (review PH-H4, SK-K9).
#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct SharedPaneRows {
    pub rows: Vec<SharedItemRow>,
    /// Every row the pane's query would show: the store's count, capped by
    /// the query's own `limit` when it has one.
    pub total: u64,
    /// Where this page starts.
    pub offset: u32,
    /// The page size actually used: the caller's `limit`, or the query's own
    /// when that is smaller; `None` when neither limits it.
    pub limit: Option<u32>,
    /// The query's own `limit`, which is honoured — a page never shows more.
    pub query_limit: Option<u32>,
    /// `offset + rows.len() < total`: there is more than this page shows.
    pub truncated: bool,
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
    /// number is the same counter the snapshot carries. Only for THIS
    /// scope's live row: another app's keystroke is not this window's change.
    fn layout_changed(&self, version: u64);
    /// A saved layout or preset of this app was written or deleted elsewhere
    /// — re-read [`SharedLayout::list_layouts`]. The tree did not change.
    fn layouts_changed(&self);
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
    /// `device` resolved the way the service resolves it — the key of this
    /// scope's session and the `device` its live row carries.
    device_tag: String,
    version: Arc<AtomicU64>,
    /// The live row revision the host last received a tree at — see the
    /// module docs ("Whose change is it?"). Held across a whole verb, and by
    /// the feed while it compares.
    told: Arc<Mutex<Option<u64>>>,
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
            // Every verb answers with the tree it left, so `verb` below
            // never re-reads it (review RL-L14).
            service: DefaultLayoutService::with_store_and_sessions(
                core.clone(),
                store.layout_sessions(),
            )
            .with_tree_in_results(),
            store: core,
            device_tag: resolve_device(device.as_deref()),
            app_id,
            device,
            version: Arc::new(AtomicU64::new(0)),
            told: Arc::new(Mutex::new(None)),
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
        let mut told = self.told.lock().unwrap_or_else(|e| e.into_inner());
        let layout = self.read_layout()?;
        let revision = self.session_revision();
        *told = revision.or(*told);
        let mut snapshot = self.snapshot_of(&layout)?;
        snapshot.revision = revision;
        Ok(snapshot)
    }

    /// One pane's spec, its compiled query and its resolved bindings.
    pub fn pane(&self, id: u64) -> Result<SharedPane> {
        let pane = self.compiled_pane(id)?;
        let compiled = pane.compiled.map_err(|e| SharedLayoutError::Query {
            message: e.to_string(),
        })?;
        let bindings: BTreeMap<String, String> = pane
            .bindings
            .values
            .iter()
            .map(|(name, id)| (name.clone(), id.to_string()))
            .collect();
        Ok(SharedPane {
            tile: pane.tile.raw(),
            spec_json: serde_json::to_string(&pane.spec).map_err(SharedLayoutError::json)?,
            compiled_query_json: serde_json::to_string(&compiled.item_query)
                .map_err(SharedLayoutError::json)?,
            bindings_json: serde_json::to_string(&bindings).map_err(SharedLayoutError::json)?,
            single_item: compiled.single_item.map(|id| id.to_string()),
            schema_refs: compiled.schema_refs,
            channel: pane.channel,
            view_kind: pane.spec.view_kind.to_string(),
            role: pane.spec.role.map(|r| r.to_string()),
        })
    }

    /// Run a pane's compiled query, one page. The read path every list pane
    /// uses.
    ///
    /// `limit` is the page size; 0 means none. The pane's own query limit is
    /// always honoured — a page is the smaller of the two — and the answer
    /// says how many rows the query has in all (`total`) and whether this
    /// page is all of them (`truncated`), so a host never shows a cut list
    /// as if it were the whole (review PH-H4, SK-K9: the kit's page of 500
    /// used to REPLACE the query's own limit, and nothing said 2,657 rows
    /// had become 500). Rows come back as the ordinary [`SharedItemRow`].
    pub fn run_pane(&self, id: u64, offset: u32, limit: u32) -> Result<SharedPaneRows> {
        let mut query = self
            .compiled_pane(id)?
            .compiled
            .map_err(|e| SharedLayoutError::Query {
                message: e.to_string(),
            })?
            .item_query;
        let query_limit = query.limit;
        let page = match (limit, query_limit) {
            (0, own) => own,
            (page, Some(own)) => Some((page as usize).min(own)),
            (page, None) => Some(page as usize),
        };
        query.limit = page;
        query.offset = (offset > 0).then_some(offset as usize);
        let items = self.store.query(&query).map_err(SharedLayoutError::store)?;
        let shown = items.len() as u64;
        // Counting costs a second query, so only when the page came back
        // full — a short page is the end of the result.
        let full = page.is_some_and(|p| items.len() >= p);
        let total = if full {
            let mut all = query.clone();
            all.limit = None;
            all.offset = None;
            let count = self.store.count(&all).map_err(SharedLayoutError::store)? as u64;
            query_limit.map_or(count, |own| count.min(own as u64))
        } else {
            offset as u64 + shown
        };
        Ok(SharedPaneRows {
            rows: items.into_iter().map(item_to_row).collect(),
            total,
            offset,
            limit: page.map(|p| p as u32),
            query_limit: query_limit.map(|l| l as u32),
            truncated: offset as u64 + shown < total,
        })
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
    /// `system`; the GUI passes `human`. The object may also carry
    /// `"expected_revision": N` — refused `conflict`, nothing written, unless
    /// the live row is still at revision `N` (what `/api/layout/verb` takes).
    ///
    /// Parsed strictly (review RL-L3): a field the verb's schema does not
    /// name is refused `invalid-argument` naming it, and a pane reference is
    /// written one way — `{"id": 7}`, `{"role": "detail"}`,
    /// `{"direction": "left"}` or `{"focused": true}`. A split with no `new`
    /// duplicates its target; that rule is the verb's, not this function's
    /// (review RL-L20).
    pub fn apply(&self, verb_json: String, actor: String) -> Result<SharedAppliedVerb> {
        let (verb, expected) = parse_verb(&verb_json)?;
        self.dispatch(verb, actor, expected)
    }

    /// Apply several verbs as ONE gesture: all or none, one undo step
    /// (review PH-M2) — what an outline click is. `verbs_json` is a JSON
    /// array of verbs, each as [`Self::apply`] takes one, or an object
    /// `{"verbs": [...], "expected_revision": N}`.
    pub fn apply_all(&self, verbs_json: String, actor: String) -> Result<SharedAppliedVerb> {
        let value: serde_json::Value =
            serde_json::from_str(&verbs_json).map_err(SharedLayoutError::json)?;
        let (items, expected) = match value {
            serde_json::Value::Array(items) => (items, None),
            serde_json::Value::Object(mut object) => {
                let expected = take_expected(&mut object)?;
                let Some(serde_json::Value::Array(items)) = object.remove("verbs") else {
                    return Err(invalid(
                        "apply_all takes an array of verbs, or {\"verbs\": […]}",
                    ));
                };
                if let Some(key) = object.keys().next() {
                    return Err(invalid(format!(
                        "unknown field '{key}' (apply_all takes: verbs, expected_revision)"
                    )));
                }
                (items, expected)
            }
            _ => return Err(invalid("apply_all takes an array of verbs")),
        };
        let schema = verb_schema();
        let mut verbs = Vec::with_capacity(items.len());
        for (index, item) in items.into_iter().enumerate() {
            let verb = impress_service_core::strict::args::<Verb>(
                &format!("verb {}", index + 1),
                item,
                schema,
            )
            .map_err(SharedLayoutError::layout)?;
            verbs.push(verb);
        }
        let app = self.app_id.clone();
        let device = self.device.clone();
        let actor = actor_from(Some(&actor));
        self.verb(|| {
            self.service
                .apply_verbs_as(&app, device, actor, expected, verbs)
        })
    }

    /// Step focus: `left` | `right` | `up` | `down` | `next` | `prev`. The
    /// h / l grammar.
    pub fn focus_direction(&self, dir: String, actor: String) -> Result<SharedAppliedVerb> {
        self.verb(|| {
            runtime().block_on(self.service.focus_direction(
                self.app_id.clone(),
                self.device.clone(),
                dir,
                Some(actor),
                None,
            ))
        })
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
        self.verb(|| {
            runtime().block_on(self.service.select(
                self.app_id.clone(),
                self.device.clone(),
                PaneRefDto::tile(TileId::new(pane)),
                kind,
                ids,
                Some(actor),
                None,
            ))
        })
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
        let app = self.app_id.clone();
        let device = self.device.clone();
        let actor = actor_from(Some(&actor));
        // The shares are read from the session the verb applies to, under
        // its lock: reading the tree first and resizing after let a verb in
        // between turn this into "N shares for M children" (review RL-L13).
        self.verb(|| {
            self.service
                .apply_verb_as(&app, device, actor, None, |session| {
                    resize_one_share(&session.layout, TileId::new(pane), share)
                })
        })
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
        self.verb(|| {
            runtime().block_on(self.service.undo(
                self.app_id.clone(),
                self.device.clone(),
                stack,
                Some(pane_ref(pane)),
                Some(actor),
                None,
            ))
        })
    }

    /// Redo on one ring. Same stacks as [`Self::undo`].
    pub fn redo(
        &self,
        stack: String,
        pane: Option<u64>,
        actor: String,
    ) -> Result<SharedAppliedVerb> {
        self.verb(|| {
            runtime().block_on(self.service.redo(
                self.app_id.clone(),
                self.device.clone(),
                stack,
                Some(pane_ref(pane)),
                Some(actor),
                None,
            ))
        })
    }

    /// Save the current arrangement under a name, durably. Re-saving a name
    /// overwrites it.
    pub fn save_layout(
        &self,
        name: String,
        purpose: Option<String>,
        actor: String,
    ) -> Result<SharedAppliedVerb> {
        self.verb(|| {
            runtime().block_on(self.service.save_layout(
                self.app_id.clone(),
                self.device.clone(),
                name,
                purpose,
                Some(actor),
            ))
        })
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
        self.verb(|| {
            runtime().block_on(self.service.apply_layout(
                self.app_id.clone(),
                self.device.clone(),
                name,
                ordinal,
                Some(actor),
                None,
            ))
        })
    }

    /// Remove a saved layout by name or id. Refuses the live arrangement and
    /// any preset (`reset-preset` is theirs); a name that does not exist
    /// comes back as an error carrying the service's message, same as every
    /// other refusal on this object.
    pub fn delete_layout(&self, name_or_id: String, actor: String) -> Result<SharedAppliedVerb> {
        self.verb(|| {
            runtime().block_on(self.service.delete_layout(
                self.app_id.clone(),
                name_or_id,
                Some(actor),
            ))
        })
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
            told: self.told.clone(),
            service: self.service.clone(),
            store: self.store.clone(),
            app_id: self.app_id.clone(),
            device: self.device.clone(),
            device_tag: self.device_tag.clone(),
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

    fn snapshot_of(&self, layout: &Layout) -> Result<SharedLayoutSnapshot> {
        snapshot_of(layout, self.version.load(Ordering::SeqCst))
    }

    /// Run one verb and turn its result into the FFI one.
    ///
    /// The version moves only when the live row's revision did — a verb
    /// that changed nothing (focus on the focused pane, ⌘Z on an empty
    /// ring, a save) bumps nothing (review RL-L9). The revision it produced
    /// is recorded under the same lock the feed compares under, so the feed
    /// never reports this verb back as someone else's change.
    ///
    /// The tree comes back in the verb's own result, serialized under the
    /// lock the verb held (review RL-L14): no second registry lock, no clone,
    /// and it is the tree this verb left rather than whatever a verb from the
    /// surface executor made of it in between. Only a verb that leaves no tree
    /// (`delete_layout`) reads it again.
    fn verb(&self, call: impl FnOnce() -> LayoutVerbResult) -> Result<SharedAppliedVerb> {
        let mut told = self.told.lock().unwrap_or_else(|e| e.into_inner());
        let mut result = call();
        if !result.ok {
            return Err(SharedLayoutError::refused(result.code, result.message));
        }
        let revision = self.session_revision();
        let moved = revision.is_some() && revision != *told;
        *told = revision.or(*told);
        let version = if moved {
            self.version.fetch_add(1, Ordering::SeqCst) + 1
        } else {
            self.version.load(Ordering::SeqCst)
        };
        let layout_json = match result.tree_json.take() {
            Some(json) => json,
            None => serde_json::to_string(&self.read_layout()?).map_err(SharedLayoutError::json)?,
        };
        drop(told);
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
            layout_json,
            revision: result.revision.or(revision),
        })
    }

    /// The revision this scope's session holds in the shared registry.
    fn session_revision(&self) -> Option<u64> {
        self.service
            .sessions()
            .revision_of(&self.app_id, &self.device_tag)
    }

    fn compiled_pane(&self, id: u64) -> Result<impress_layout_service::CompiledPane> {
        self.service
            .compiled_pane(
                &self.app_id,
                self.device.clone(),
                &PaneRef::Id {
                    tile: TileId::new(id),
                },
                ActorKind::Human,
            )
            .map_err(SharedLayoutError::layout)
    }

    /// Apply one parsed [`Verb`] through the service — the same path, checks
    /// and log line an MCP verb takes (`DefaultLayoutService::apply_verb_as`),
    /// with no translation table in between: nothing here decides anything
    /// about the tree.
    fn dispatch(
        &self,
        verb: Verb,
        actor: String,
        expected_revision: Option<u64>,
    ) -> Result<SharedAppliedVerb> {
        let app = self.app_id.clone();
        let device = self.device.clone();
        let actor = actor_from(Some(&actor));
        self.verb(|| {
            self.service
                .apply_verb_as(&app, device, actor, expected_revision, |_| Ok(verb))
        })
    }
}

/// `human` | `agent` | `system` — the service's own reading of the string.
fn actor_from(actor: Option<&str>) -> ActorKind {
    impress_layout_service::store::actor_from(actor)
}

fn invalid(message: impl Into<String>) -> SharedLayoutError {
    SharedLayoutError::layout(Refusal::invalid_argument(message))
}

/// `Verb`'s JSON schema, for the strict check (generated once).
fn verb_schema() -> &'static serde_json::Value {
    static SCHEMA: OnceLock<serde_json::Value> = OnceLock::new();
    SCHEMA.get_or_init(|| {
        serde_json::to_value(impress_service_core::schemars::schema_for!(Verb))
            .unwrap_or(serde_json::Value::Null)
    })
}

/// Take `expected_revision` out of a verb object, if it is there.
fn take_expected(object: &mut serde_json::Map<String, serde_json::Value>) -> Result<Option<u64>> {
    match object.remove("expected_revision") {
        None | Some(serde_json::Value::Null) => Ok(None),
        Some(value) => value.as_u64().map(Some).ok_or_else(|| {
            invalid(format!(
                "expected_revision must be a non-negative integer, not {value}"
            ))
        }),
    }
}

/// A verb as `apply` and `/api/layout/verb` take it: the verb's own fields,
/// strictly, plus an optional `expected_revision`.
fn parse_verb(verb_json: &str) -> Result<(Verb, Option<u64>)> {
    let value: serde_json::Value =
        serde_json::from_str(verb_json).map_err(SharedLayoutError::json)?;
    let serde_json::Value::Object(mut object) = value else {
        return Err(invalid("a verb is a JSON object with a \"verb\" field"));
    };
    let expected = take_expected(&mut object)?;
    let verb = impress_service_core::strict::args::<Verb>(
        "verb",
        serde_json::Value::Object(object),
        verb_schema(),
    )
    .map_err(SharedLayoutError::layout)?;
    Ok((verb, expected))
}

/// The `Resize` that gives one pane `share` in its parent split and leaves
/// its siblings alone — computed from the tree the verb will apply to.
fn resize_one_share(
    layout: &Layout,
    tile: TileId,
    share: f32,
) -> std::result::Result<Verb, Refusal> {
    let parent = layout.parent_of(tile).ok_or_else(|| {
        Refusal::new("not-in-a-split", format!("tile {tile} has no parent split"))
    })?;
    let container = layout
        .tile(parent)
        .and_then(Tile::as_container)
        .ok_or_else(|| {
            Refusal::new(
                "not-a-container",
                format!("tile {parent} is not a container"),
            )
        })?;
    if !matches!(container, Container::Linear { .. }) {
        return Err(Refusal::new(
            "not-in-a-split",
            format!(
                "tile {parent} is a {:?}, and only a split has shares",
                container.kind()
            ),
        ));
    }
    let index = container.index_of(tile).ok_or_else(|| {
        Refusal::new(
            "unknown-tile",
            format!("tile {tile} is not a child of {parent}"),
        )
    })?;
    let existing = container.shares().unwrap_or(&[]);
    let mut shares: Vec<f32> = (0..container.len())
        .map(|i| existing.get(i).copied().unwrap_or(1.0))
        .collect();
    shares[index] = share.max(HIDDEN_SHARE);
    Ok(Verb::Resize {
        container: parent,
        shares,
    })
}

fn read_layout(
    service: &DefaultLayoutService,
    app_id: &str,
    device: Option<String>,
) -> Result<Layout> {
    // As the human: a read that finds no live row cold-starts one, and that
    // row is the user's workspace (review RL-L15).
    let result = service.get_layout_as(app_id, device, ActorKind::Human);
    if !result.ok {
        return Err(SharedLayoutError::refused(result.code, result.message));
    }
    result.layout.ok_or_else(|| {
        SharedLayoutError::layout(Refusal::internal("the layout service returned no tree"))
    })
}

/// The FFI snapshot of `layout`. A tree that does not serialize is an error,
/// never `"{}"`, which reads as an empty tree (review RL-L21).
fn snapshot_of(layout: &Layout, version: u64) -> Result<SharedLayoutSnapshot> {
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
            geometry_json: w.geometry.as_ref().and_then(|g| {
                serde_json::to_string(g)
                    .map_err(|e| {
                        log::warn!(target: "layout", "window {} geometry does not encode: {e}", w.id)
                    })
                    .ok()
            }),
            leaves: layout.leaves(w.id).iter().map(|t| t.raw()).collect(),
        })
        .collect();
    let leaves = current
        .map(|w| layout.leaves(w).iter().map(|t| t.raw()).collect())
        .unwrap_or_default();
    Ok(SharedLayoutSnapshot {
        layout_json: serde_json::to_string(layout).map_err(SharedLayoutError::json)?,
        focused: current
            .and_then(|w| layout.window(w))
            .and_then(|w| w.focused)
            .map(TileId::raw),
        windows,
        leaves,
        version,
        revision: None,
    })
}

fn pane_ref(pane: Option<u64>) -> PaneRefDto {
    match pane {
        Some(id) => PaneRefDto::tile(TileId::new(id)),
        None => PaneRefDto::focused(),
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
    told: Arc<Mutex<Option<u64>>>,
    service: DefaultLayoutService,
    store: Arc<SqliteItemStore>,
    app_id: String,
    device: Option<String>,
    device_tag: String,
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
        let mut external = ExternalPoll::baseline(&self.store)
            .track_deletes(&self.store, schemas::ui::LAYOUT_SCHEMA_REF);
        let mut last_external_poll = Instant::now();
        // In-process, cross-object liveness: the session registry is shared
        // with the surface executor and the inventory (see
        // `SharedStore::layout_sessions`). A write this object did NOT make —
        // a surface's `open` or `publish` effect — moves the session's
        // revision past the one this object last told its host about.
        let sessions = self.service.sessions();
        // Baselined on what the host was TOLD, not on the session now: a verb
        // another object made between `subscribe` and this thread starting
        // is still news.
        let mut session_seen = *self.told.lock().unwrap_or_else(|e| e.into_inner());
        let mut layouts_held = false;

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
                let batch = external.check_rows(&self.store, ui_feed::EXTERNAL_UI_PREFIX);
                if !batch.deleted.is_empty() {
                    // A saved layout deleted elsewhere (`impress-cli
                    // delete-layout`). The row is gone, so whose it was is
                    // unknowable; the list is cheap to re-read.
                    log::info!(
                        target: "layout",
                        "{}/{}: {} layout row(s) deleted elsewhere; the saved-layout list reloads",
                        self.app_id,
                        self.device_tag,
                        batch.deleted.len()
                    );
                    layouts_held = true;
                }
                let mut mutations = Vec::with_capacity(batch.rows.len());
                for item in batch.rows {
                    match self.whose(&item) {
                        RowOwner::ThisTree => {
                            // This scope's live row, written by another
                            // connection. News only at a revision the host
                            // has not already been given — the overlap
                            // window re-reads rows, and a write this object
                            // made itself is not an external change.
                            let mut told = self.told.lock().unwrap_or_else(|e| e.into_inner());
                            if *told != Some(item.logical_clock) {
                                log::info!(
                                    target: "layout",
                                    "{}/{}: live row {} changed elsewhere (revision {:?} → {}); \
                                     the window reloads",
                                    self.app_id,
                                    self.device_tag,
                                    item.id,
                                    *told,
                                    item.logical_clock
                                );
                                *told = Some(item.logical_clock);
                                self.version.fetch_add(1, Ordering::SeqCst);
                            }
                        }
                        RowOwner::ThisAppsLayouts => {
                            log::debug!(
                                target: "layout",
                                "{}: saved layout or preset {} changed elsewhere",
                                self.app_id,
                                item.id
                            );
                            layouts_held = true
                        }
                        RowOwner::Elsewhere => {}
                    }
                    mutations.push(impress_core::event::StoreMutation::new(
                        item.id,
                        Some(item.schema),
                        impress_core::event::MutationKind::Updated,
                    ));
                }
                if !mutations.is_empty() {
                    if burst_started.is_none() {
                        burst_started = Some(Instant::now());
                    }
                    last_seen = Some(Instant::now());
                    pending.extend(mutations);
                }
            }

            {
                // News only when the session's revision itself MOVED since the
                // last look, and to one the host has not been given. A session
                // still at its old revision after the external branch above
                // recorded the row's new one is not a change — it is the
                // reload that has not happened yet — and reporting it cost
                // every external write two extra reloads.
                let mut told = self.told.lock().unwrap_or_else(|e| e.into_inner());
                let now = sessions.revision_of(&self.app_id, &self.device_tag);
                if now != session_seen {
                    session_seen = now;
                    match (*told, now) {
                        // First sight: whatever the host read, it read this.
                        (None, Some(now)) => *told = Some(now),
                        (Some(previous), Some(now)) if previous != now => {
                            log::debug!(
                                target: "layout",
                                "{}/{}: another object in this process moved the tree \
                                 ({previous} → {now})",
                                self.app_id,
                                self.device_tag
                            );
                            *told = Some(now);
                            self.version.fetch_add(1, Ordering::SeqCst);
                        }
                        _ => {}
                    }
                }
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
            if grace_over && layouts_held {
                layouts_held = false;
                self.listener.layouts_changed();
            }
        }
    }

    /// Whether an `impress/ui/` row another connection wrote is this
    /// window's tree, this app's saved layouts, or somebody else's business
    /// (module docs, "Whose change is it?").
    fn whose(&self, item: &impress_core::item::Item) -> RowOwner {
        let text = |field: &str| match item.payload.get(field) {
            Some(Value::String(s)) => Some(s.trim().to_string()),
            _ => None,
        };
        let app = text("app_id");
        let this_app = app
            .as_deref()
            .map(|a| a == self.app_id.trim())
            .unwrap_or(true);
        if item.schema == schemas::ui::LAYOUT_SCHEMA_REF {
            let live = matches!(item.payload.get("is_live"), Some(Value::Bool(true)));
            if live {
                if this_app
                    && app.is_some()
                    && text("device").as_deref() == Some(self.device_tag.as_str())
                {
                    RowOwner::ThisTree
                } else {
                    RowOwner::Elsewhere
                }
            } else if this_app {
                RowOwner::ThisAppsLayouts
            } else {
                RowOwner::Elsewhere
            }
        } else if item.schema == schemas::ui::PRESET_SCHEMA_REF && this_app {
            RowOwner::ThisAppsLayouts
        } else {
            RowOwner::Elsewhere
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
        let layout = match read_layout(&self.service, &self.app_id, self.device.clone()) {
            Ok(layout) => layout,
            Err(e) => {
                // No pane is invalidated until the next version bump rebuilds
                // this: say so, rather than go quiet (review RL-L6).
                log::warn!(
                    target: "layout",
                    "{}/{}: could not read the tree to rebuild pane subscriptions ({e}); \
                     no pane is refreshed by store writes until the tree changes again",
                    self.app_id,
                    self.device_tag
                );
                return subscriptions;
            }
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

/// What an externally written `impress/ui/` row is to this feed.
enum RowOwner {
    /// This scope's live row: the tree.
    ThisTree,
    /// A saved layout or preset of this app: the list, not the tree.
    ThisAppsLayouts,
    /// Another app's or device's row, or not a layout at all.
    Elsewhere,
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
/// The layout's written vocabulary, owned by Rust (review PH-M7):
/// `{"wire_version": 1, "view_kinds": [...], "session_bearing": [...],
/// "view_state_keys": [...]}`. A host pins its own registrations to this in a
/// test, so a view kind or a `view_state` key spelled on one side only fails
/// the build rather than rendering a placeholder.
#[cfg_attr(feature = "native", uniffi::export)]
pub fn layout_vocabulary_json() -> String {
    encode_static(
        &serde_json::json!({
            "wire_version": impress_service_core::wire::WIRE_VERSION,
            "view_kinds": impress_layout::ViewKindId::KNOWN
                .iter()
                .map(|k| k.as_str())
                .collect::<Vec<_>>(),
            "session_bearing": impress_layout::ViewKindId::SESSION_BEARING
                .iter()
                .map(|k| k.as_str())
                .collect::<Vec<_>>(),
            "view_state_keys": impress_layout::view_state::KNOWN,
        }),
        "the layout vocabulary",
    )
}

#[cfg_attr(feature = "native", uniffi::export)]
pub fn kind_manifest_json() -> String {
    encode_static(&builtin_manifest(), "the kind manifest")
}

/// Encode a value built into this binary (a manifest, a shipped preset). It
/// cannot fail short of a bug, and the export's signature has no error arm,
/// so a failure is logged at error level and asserted in debug builds rather
/// than answered as a silent `"{}"` that reads as "empty" (review RL-L21).
fn encode_static(value: &impl serde::Serialize, what: &str) -> String {
    match serde_json::to_string(value) {
        Ok(json) => json,
        Err(e) => {
            log::error!(target: "layout", "{what} does not encode: {e}");
            debug_assert!(false, "{what} does not encode: {e}");
            "{}".into()
        }
    }
}

/// The cold-start three-column preset as layout JSON, for a host that wants to
/// render before it has opened a store. Nothing persists it.
#[cfg_attr(feature = "native", uniffi::export)]
pub fn cold_start_layout_json() -> String {
    encode_static(
        &impress_layout_service::cold_start_layout(),
        "the cold-start layout",
    )
}

/// A pane spec's JSON, for a host building a `Split` verb's `new` pane without
/// hand-writing the shape.
#[cfg_attr(feature = "native", uniffi::export)]
pub fn pane_spec_json(query_json: String, view_kind: String) -> Result<String> {
    let query: PaneQuery = serde_json::from_str(&query_json).map_err(SharedLayoutError::json)?;
    let spec = PaneSpec::new(query, view_kind.into());
    serde_json::to_string(&spec).map_err(SharedLayoutError::json)
}

// ─── The outline sidebar (plan wave 6, W3) ──────────────────────────────

/// The sections `app_id`'s outline shows, as JSON: `[{"section": <case
/// name>, "legacy": bool}]`. The host shows exactly these and drops (and
/// logs) any other section the chassis would draw.
#[cfg_attr(feature = "native", uniffi::export)]
pub fn outline_sections_json(app_id: String) -> String {
    serde_json::to_string(&impress_layout_service::outline_sections(&app_id))
        .unwrap_or_else(|_| "[]".into())
}

/// The record kind each section serves in `app_id`'s shipped shell, as JSON:
/// `{"<SidebarSectionType case>": "<kind short id>"}` — `{}` for an app that
/// ships no preset. `AppShellConfiguration`'s shipped presets read their
/// `sectionBindings` from this (plan wave 6 W5), so the table has one
/// definition, beside the named queries it must agree with.
#[cfg_attr(feature = "native", uniffi::export)]
pub fn section_bindings_json(app_id: String) -> String {
    encode_static(
        &impress_layout_service::section_bindings(&app_id),
        "the section bindings",
    )
}

/// What selecting an outline row does, decided in Rust
/// (`impress_layout_service::outline`).
///
/// * `node_json` — an `OutlineNode` (`{"node": "collection", "id": …}`).
/// * `bindings_json` — parameter name → item id the host knows for a section
///   query (`{"library": <inbox library>}`); empty string for none.
/// * `list_spec_json` / `detail_spec_json` — the panes with the `list` and
///   `detail` roles as they are now; empty string when the layout has none.
/// * `initial` — the chassis' own launch selection, which applies only to a
///   list still on the preset's query.
///
/// Returns `{"target": OutlineTarget, "applies": bool, "verbs": [Verb]}`. The
/// verbs are `impress_layout::Verb`'s serde form, for `SharedLayout::apply`
/// one at a time; the host adds nothing to them.
#[cfg_attr(feature = "native", uniffi::export)]
pub fn outline_row_verbs_json(
    app_id: String,
    node_json: String,
    bindings_json: String,
    list_spec_json: String,
    detail_spec_json: String,
    initial: bool,
) -> Result<String> {
    use impress_layout_service::{
        initial_selection_applies, outline_target, outline_verbs, OutlineNode, OutlinePanes,
    };
    let node: OutlineNode = serde_json::from_str(&node_json).map_err(SharedLayoutError::json)?;
    let bindings: BTreeMap<String, ItemId> = if bindings_json.trim().is_empty() {
        BTreeMap::new()
    } else {
        serde_json::from_str(&bindings_json).map_err(SharedLayoutError::json)?
    };
    let spec = |json: &str| -> Result<Option<PaneSpec>> {
        if json.trim().is_empty() {
            Ok(None)
        } else {
            serde_json::from_str(json)
                .map(Some)
                .map_err(SharedLayoutError::json)
        }
    };
    let panes = OutlinePanes {
        list: spec(&list_spec_json)?,
        detail: spec(&detail_spec_json)?,
    };
    let target = outline_target(&app_id, &node, &bindings);
    let applies = !initial || initial_selection_applies(&app_id, &panes);
    let verbs = if applies {
        outline_verbs(&node, &target, &panes)
    } else {
        Vec::new()
    };
    serde_json::to_string(&serde_json::json!({
        "target": target,
        "applies": applies,
        "verbs": verbs,
    }))
    .map_err(SharedLayoutError::json)
}

/// What the tree does when the outline's selected library or collection is
/// deleted, decided in Rust (`impress_layout_service::outline_cleared_verbs`,
/// plan wave 6 W5): the navigator's channel stops carrying the dead row and
/// the detail pane empties — the chassis' own "No Selection", with no
/// fallback to a parent.
///
/// * `node_json` — the `OutlineNode` that was selected.
/// * `list_spec_json` / `detail_spec_json` — as for [`outline_row_verbs_json`].
///
/// Returns `{"verbs": [Verb]}`, for `SharedLayout::apply` one at a time.
#[cfg_attr(feature = "native", uniffi::export)]
pub fn outline_cleared_verbs_json(
    node_json: String,
    list_spec_json: String,
    detail_spec_json: String,
) -> Result<String> {
    use impress_layout_service::{outline_cleared_verbs, OutlineNode, OutlinePanes};
    let node: OutlineNode = serde_json::from_str(&node_json).map_err(SharedLayoutError::json)?;
    let spec = |json: &str| -> Result<Option<PaneSpec>> {
        if json.trim().is_empty() {
            Ok(None)
        } else {
            serde_json::from_str(json)
                .map(Some)
                .map_err(SharedLayoutError::json)
        }
    };
    let panes = OutlinePanes {
        list: spec(&list_spec_json)?,
        detail: spec(&detail_spec_json)?,
    };
    serde_json::to_string(&serde_json::json!({
        "verbs": outline_cleared_verbs(&node, &panes),
    }))
    .map_err(SharedLayoutError::json)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc;

    #[test]
    fn an_outline_collection_row_comes_back_as_verbs_the_layout_applies() {
        let (_store, layout) = open();
        let list = layout.pane(role_of(&layout, "list")).expect("list pane");
        let detail = layout
            .pane(role_of(&layout, "detail"))
            .expect("detail pane");
        let collection = uuid::Uuid::new_v4();
        let out = outline_row_verbs_json(
            "test-app".into(),
            format!(r#"{{"node":"collection","id":"{collection}"}}"#),
            String::new(),
            list.spec_json.clone(),
            detail.spec_json,
            false,
        )
        .expect("verbs");
        let parsed: serde_json::Value = serde_json::from_str(&out).expect("json");
        assert_eq!(parsed["target"]["target"], "query");
        let verbs = parsed["verbs"].as_array().expect("verbs array");
        assert!(!verbs.is_empty());
        for verb in verbs {
            layout
                .apply(verb.to_string(), "human".into())
                .expect("every outline verb is a verb the layout takes");
        }
        let after = layout.pane(role_of(&layout, "list")).expect("list pane");
        assert!(
            after.spec_json.contains(&collection.to_string()),
            "the list pane's query names the collection: {}",
            after.spec_json
        );
    }

    #[test]
    fn a_deleted_outline_selection_comes_back_as_verbs_the_layout_applies() {
        let (_store, layout) = open();
        let list = layout.pane(role_of(&layout, "list")).expect("list pane");
        let detail = layout
            .pane(role_of(&layout, "detail"))
            .expect("detail pane");
        let collection = uuid::Uuid::new_v4();
        let out = outline_cleared_verbs_json(
            format!(r#"{{"node":"collection","id":"{collection}"}}"#),
            list.spec_json,
            detail.spec_json,
        )
        .expect("verbs");
        let parsed: serde_json::Value = serde_json::from_str(&out).expect("json");
        let verbs = parsed["verbs"].as_array().expect("verbs array");
        assert_eq!(verbs.len(), 2, "{verbs:?}");
        for verb in verbs {
            layout
                .apply(verb.to_string(), "human".into())
                .expect("every cleared verb is a verb the layout takes");
        }
    }

    #[test]
    fn section_bindings_come_back_as_a_flat_map() {
        let implore: BTreeMap<String, String> =
            serde_json::from_str(&section_bindings_json("implore".into())).expect("json");
        assert_eq!(implore.get("tags").map(String::as_str), Some("figure"));
        assert_eq!(section_bindings_json("nobody".into()), "{}");
    }

    #[test]
    fn outline_sections_are_the_apps_table() {
        let impress: serde_json::Value =
            serde_json::from_str(&outline_sections_json("impress".into())).expect("json");
        let sections = impress.as_array().expect("array");
        assert_eq!(sections.len(), 16, "impress shows every section");
        assert_eq!(
            sections.iter().filter(|s| s["legacy"] == true).count(),
            4,
            "sharedWithMe, scixLibraries, tags, reviewQueue (search is a query; its forms are rows)"
        );
    }

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
                    "target": {"id": list},
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
        assert!(
            matches!(&refused, Err(SharedLayoutError::Layout { code, .. }) if code == "invalid-argument"),
            "{refused:?}"
        );
    }

    /// The written contract on the FFI path (review RL-L3, RL-L20, RL-L1):
    /// a strict parse, one reference spelling, `expected_revision` in the
    /// verb object, and a split whose `new` is omitted.
    #[test]
    fn a_verb_is_parsed_strictly_and_a_stale_revision_is_a_conflict() {
        let (_store, layout) = open();
        let code_of = |r: Result<SharedAppliedVerb>| match r {
            Err(SharedLayoutError::Layout { code, message }) => (code, message),
            other => panic!("expected a refusal, got {other:?}"),
        };
        let (code, message) = code_of(layout.apply(
            r#"{"verb":"close","target":{"ref":"id","tile":1}}"#.into(),
            "human".into(),
        ));
        assert_eq!(code, "invalid-argument");
        assert!(
            message.contains("unknown field 'ref' in 'target'"),
            "{message}"
        );
        let (code, message) = code_of(layout.apply(
            r#"{"verb":"focus","target":{"role":"list"},"targett":{}}"#.into(),
            "human".into(),
        ));
        assert_eq!(code, "invalid-argument");
        assert!(message.contains("'targett'"), "{message}");
        let (code, _) =
            code_of(layout.apply(r#"{"verb":"close","target":{}}"#.into(), "human".into()));
        assert_eq!(code, "invalid-argument");
        let (code, message) = code_of(layout.apply(
            r#"{"verb":"set-view-kind","target":{"role":"detail"},"view_kind":"editor"}"#.into(),
            "human".into(),
        ));
        assert_eq!(code, "unknown-view-kind", "{message}");

        // Read the revision, let someone else write, then act on the read.
        let read = layout
            .service
            .get_layout_as("test-app", Some("test".into()), ActorKind::Agent);
        let revision = read.revision.expect("revision");
        layout
            .apply(
                r#"{"verb":"split","target":{"role":"list"},"dir":"vertical"}"#.into(),
                "human".into(),
            )
            .expect("a split with no `new` duplicates its target");
        let (code, message) = code_of(layout.apply(
            format!(
                r#"{{"verb":"focus","target":{{"role":"detail"}},"expected_revision":{revision}}}"#
            ),
            "agent".into(),
        ));
        assert_eq!(code, "conflict", "{message}");
        let now = layout
            .service
            .get_layout_as("test-app", Some("test".into()), ActorKind::Agent)
            .revision
            .expect("revision");
        layout
            .apply(
                format!(
                    r#"{{"verb":"focus","target":{{"role":"detail"}},"expected_revision":{now}}}"#
                ),
                "agent".into(),
            )
            .expect("the current revision goes through");
    }

    /// An outline click as one gesture (review PH-M2): one call, one undo
    /// step, nothing applied when any verb is refused.
    #[test]
    fn apply_all_is_one_gesture_and_one_undo_step() {
        let (_store, layout) = open();
        let list = role_of(&layout, "list");
        let detail = role_of(&layout, "detail");
        let before = layout.pane(detail).expect("detail").view_kind;
        let applied = layout
            .apply_all(
                format!(
                    r#"[{{"verb":"focus","target":{{"id":{list}}}}},
                        {{"verb":"set-view-kind","target":{{"id":{list}}},"view_kind":"info"}},
                        {{"verb":"set-view-kind","target":{{"id":{detail}}},"view_kind":"bibtex"}}]"#
                ),
                "human".into(),
            )
            .expect("one gesture");
        assert_eq!(applied.version, 1, "one gesture, one version");
        layout
            .undo("exploration".into(), Some(list), "human".into())
            .expect("one undo");
        assert_eq!(layout.pane(detail).expect("detail").view_kind, before);
        assert_eq!(layout.pane(list).expect("list").view_kind, "list");

        let refused = layout.apply_all(
            format!(
                r#"[{{"verb":"set-view-kind","target":{{"id":{detail}}},"view_kind":"notes"}},
                    {{"verb":"close","target":{{"id":4242}}}}]"#
            ),
            "human".into(),
        );
        assert!(
            matches!(&refused, Err(SharedLayoutError::Layout { code, .. }) if code == "unknown-tile"),
            "{refused:?}"
        );
        assert_eq!(layout.pane(detail).expect("detail").view_kind, before);
    }

    /// A page says how many rows there are in all, and the query's own limit
    /// is honoured (review PH-H4, SK-K9).
    #[test]
    fn a_page_of_rows_says_how_many_there_are_in_all() {
        let (store, layout) = open();
        let list = role_of(&layout, "list");
        for n in 0..7 {
            seed_publication(&store, &format!("paper {n}"));
        }
        layout
            .apply(
                format!(
                    r#"{{"verb":"set-query","target":{{"id":{list}}},"query":{{"kinds":["publication"]}}}}"#
                ),
                "human".into(),
            )
            .expect("list every publication");
        let page = layout.run_pane(list, 0, 3).expect("a page");
        assert_eq!(page.rows.len(), 3);
        assert_eq!(page.total, 7);
        assert!(page.truncated);
        assert_eq!(page.limit, Some(3));
        let rest = layout.run_pane(list, 6, 3).expect("the last page");
        assert_eq!(rest.rows.len(), 1);
        assert!(!rest.truncated);
        let all = layout.run_pane(list, 0, 0).expect("unpaged");
        assert_eq!((all.rows.len(), all.total, all.truncated), (7, 7, false));

        // The pane's own limit wins over a larger page.
        layout
            .apply(
                format!(
                    r#"{{"verb":"set-query","target":{{"id":{list}}},"query":{{"kinds":["publication"],"limit":5}}}}"#
                ),
                "human".into(),
            )
            .expect("a limited query");
        let limited = layout.run_pane(list, 0, 500).expect("a page");
        assert_eq!(limited.rows.len(), 5);
        assert_eq!(limited.query_limit, Some(5));
        assert_eq!(limited.total, 5, "the query shows five, so five is all");
        assert!(!limited.truncated);
    }

    /// ⌃⌘S as the tree's decision (review RL-L13).
    #[test]
    fn set_collapsed_hides_and_restores_the_navigator() {
        let (_store, layout) = open();
        let navigator = role_of(&layout, "navigator");
        let share = |layout: &SharedLayout| {
            let tree: Layout =
                serde_json::from_str(&layout.snapshot().unwrap().layout_json).unwrap();
            let parent = tree.parent_of(TileId::new(navigator)).unwrap();
            let c = tree.tile(parent).unwrap().as_container().unwrap();
            c.shares().unwrap()[c.index_of(TileId::new(navigator)).unwrap()]
        };
        let before = share(&layout);
        let toggle = r#"{"verb":"set-collapsed","target":{"role":"navigator"}}"#;
        layout.apply(toggle.into(), "human".into()).expect("hide");
        assert!(impress_layout::is_hidden(share(&layout)));
        layout.apply(toggle.into(), "human".into()).expect("show");
        assert!((share(&layout) - before).abs() < 1e-6);
    }

    #[test]
    fn the_vocabulary_is_exported_from_rust() {
        let vocabulary: serde_json::Value =
            serde_json::from_str(&layout_vocabulary_json()).expect("json");
        assert_eq!(vocabulary["wire_version"], 1);
        let kinds: Vec<&str> = vocabulary["view_kinds"]
            .as_array()
            .unwrap()
            .iter()
            .map(|k| k.as_str().unwrap())
            .collect();
        assert!(
            kinds.contains(&"notes") && kinds.contains(&"surface") && kinds.contains(&"bibtex")
        );
        assert_eq!(vocabulary["session_bearing"], serde_json::json!(["source"]));
        assert_eq!(
            vocabulary["view_state_keys"],
            serde_json::json!(["section", "node", "reason", "tab"])
        );
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
                .rows
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

        let rows = layout.run_pane(detail, 0, 0).expect("run detail").rows;
        assert_eq!(rows.len(), 1, "the detail pane shows exactly the selection");
        assert_eq!(rows[0].id, wanted);

        // And the list pane reads both, through the same path.
        let listed = layout.run_pane(list, 0, 0).expect("run list");
        assert_eq!(listed.rows.len(), 2);
        assert_eq!(listed.total, 2);
        assert!(!listed.truncated);
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

    /// RL-L14: a verb's `layout_json` is the tree it left, carried in its
    /// own result — and still the tree for the verb that leaves none
    /// (`delete_layout`), which reads it instead.
    #[test]
    fn a_verbs_tree_is_the_tree_a_snapshot_reads() {
        let (_store, layout) = open();
        let tree = || layout.snapshot().expect("snapshot").layout_json;
        let list = role_of(&layout, "list");

        let focused = layout
            .apply(
                format!(r#"{{"verb":"focus","target":{{"id":{list}}}}}"#),
                "human".into(),
            )
            .expect("focus");
        assert_eq!(focused.layout_json, tree());
        let stepped = layout
            .focus_direction("right".into(), "human".into())
            .expect("step");
        assert_eq!(stepped.layout_json, tree());
        let saved = layout
            .save_layout("Kept".into(), None, "human".into())
            .expect("save");
        assert_eq!(saved.layout_json, tree());
        let recalled = layout
            .apply_layout("Kept".into(), "human".into())
            .expect("recall");
        assert_eq!(recalled.layout_json, tree());
        let deleted = layout
            .delete_layout("Kept".into(), "human".into())
            .expect("delete");
        assert_eq!(deleted.layout_json, tree());
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
        layouts: mpsc::Sender<()>,
    }

    impl SharedLayoutListener for Recorder {
        fn panes_invalidated(&self, panes: Vec<u64>) {
            let _ = self.panes.send(panes);
        }
        fn layout_changed(&self, version: u64) {
            let _ = self.versions.send(version);
        }
        fn layouts_changed(&self) {
            let _ = self.layouts.send(());
        }
    }

    fn recorder() -> (Box<dyn SharedLayoutListener>, mpsc::Receiver<Vec<u64>>) {
        let (listener, panes, versions, layouts) = recorder_with_all();
        // The version and list feeds are not under test here; keep the
        // receivers alive so the senders never error.
        std::mem::forget(versions);
        std::mem::forget(layouts);
        (listener, panes)
    }

    /// Both channels, for the tests that care which one fired.
    fn recorder_with_versions() -> (
        Box<dyn SharedLayoutListener>,
        mpsc::Receiver<Vec<u64>>,
        mpsc::Receiver<u64>,
    ) {
        let (listener, panes, versions, layouts) = recorder_with_all();
        std::mem::forget(layouts);
        (listener, panes, versions)
    }

    /// A listener and the receiving end of each of its three calls.
    type Recorded = (
        Box<dyn SharedLayoutListener>,
        mpsc::Receiver<Vec<u64>>,
        mpsc::Receiver<u64>,
        mpsc::Receiver<()>,
    );

    /// Every channel, the saved-layouts signal included.
    fn recorder_with_all() -> Recorded {
        let (panes, panes_rx) = mpsc::channel();
        let (versions, versions_rx) = mpsc::channel();
        let (layouts, layouts_rx) = mpsc::channel();
        (
            Box::new(Recorder {
                panes,
                versions,
                layouts,
            }),
            panes_rx,
            versions_rx,
            layouts_rx,
        )
    }

    /// A store file and two `SharedStore` handles on it: two processes.
    fn two_processes() -> (tempfile::TempDir, Arc<SharedStore>, Arc<SharedStore>) {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("two_processes.sqlite");
        let path = path.to_str().unwrap().to_string();
        let first = SharedStore::open(path.clone()).expect("open");
        let second = SharedStore::open(path).expect("open a second handle");
        (dir, first, second)
    }

    fn fast_feed(layout: &SharedLayout) {
        layout.set_debounce_ms(20);
        layout.set_startup_grace_secs(0);
        layout.set_external_poll_ms(20);
    }

    const RETARGET_LIST: &str = r#"{"verb":"set-query","target":{"role": "list"},
        "query":{"kinds":["manuscript"]}}"#;

    /// Review RL-L2: every chassis app opens one file and every verb writes
    /// that app's live row, a focus keystroke included. A write to ANOTHER
    /// app's row must not tell this window its tree changed, and must not
    /// cost it its undo rings.
    #[test]
    fn another_apps_write_leaves_this_tree_and_its_undo_rings_alone() {
        let (_dir, here, there) = two_processes();
        let layout = SharedLayout::open(here, "impress".into(), Some("desk".into()));
        let before = layout.snapshot().expect("snapshot");
        // An exploration step to undo later.
        layout
            .apply(RETARGET_LIST.into(), "human".into())
            .expect("set-query");

        fast_feed(&layout);
        let (listener, _panes, versions, layouts) = recorder_with_all();
        layout.subscribe_invalidations(listener).expect("subscribe");
        while versions.recv_timeout(Duration::from_millis(100)).is_ok() {}

        // Another chassis app, same file, same device: keystrokes and a split.
        let imbib = SharedLayout::open(there, "imbib".into(), Some("desk".into()));
        imbib
            .focus_direction("left".into(), "human".into())
            .expect("imbib focus");
        imbib
            .apply(
                r#"{"verb":"split","target":{"role": "list"},"dir":"vertical"}"#.into(),
                "human".into(),
            )
            .expect("imbib split");

        assert!(
            versions.recv_timeout(Duration::from_millis(600)).is_err(),
            "imbib's write is not impress's tree changing"
        );
        assert!(
            layouts.recv_timeout(Duration::from_millis(50)).is_err(),
            "nor impress's saved layouts"
        );
        // The undo ring is still there: ⌘Z in the list puts its query back.
        layout
            .undo(
                "exploration".into(),
                Some(role_of(&layout, "list")),
                "human".into(),
            )
            .expect("undo");
        let list = layout.pane(role_of(&layout, "list")).expect("list pane");
        assert!(
            list.spec_json.contains("publication"),
            "the list's own query is back: {}",
            list.spec_json
        );
        assert_eq!(layout.snapshot().unwrap().leaves, before.leaves);
        layout.unsubscribe_invalidations();
    }

    /// Review RL-L2's other half: a named layout saved elsewhere changes this
    /// app's saved-layouts list, not its tree.
    #[test]
    fn a_layout_saved_elsewhere_signals_the_list_not_the_tree() {
        let (_dir, here, there) = two_processes();
        let layout = SharedLayout::open(here, "impress".into(), Some("desk".into()));
        layout.snapshot().expect("snapshot");
        fast_feed(&layout);
        let (listener, _panes, versions, layouts) = recorder_with_all();
        layout.subscribe_invalidations(listener).expect("subscribe");
        while versions.recv_timeout(Duration::from_millis(100)).is_ok() {}

        let cli = SharedLayout::open(there, "impress".into(), Some("desk".into()));
        cli.save_layout("From the CLI".into(), None, "agent".into())
            .expect("save elsewhere");
        layouts
            .recv_timeout(Duration::from_secs(2))
            .expect("the saved-layouts list is told");
        assert!(
            versions.recv_timeout(Duration::from_millis(300)).is_err(),
            "and the tree is not"
        );
        assert_eq!(layout.list_layouts().unwrap().len(), 1);

        // A delete elsewhere leaves no row to read; it is still seen.
        cli.delete_layout("From the CLI".into(), "agent".into())
            .expect("delete elsewhere");
        layouts
            .recv_timeout(Duration::from_secs(2))
            .expect("a delete elsewhere is told too");
        assert!(layout.list_layouts().unwrap().is_empty());
        layout.unsubscribe_invalidations();
    }

    /// Review RL-L9: a verb that changed nothing moves no version, and a verb
    /// this object applied is never reported back as a change made elsewhere
    /// (the feed used to race `finish` and add a spurious bump).
    #[test]
    fn a_local_verb_is_never_reported_back_and_a_no_op_bumps_nothing() {
        let (_store, layout) = open();
        layout.snapshot().expect("snapshot");
        fast_feed(&layout);
        let (listener, _panes, versions) = recorder_with_versions();
        layout.subscribe_invalidations(listener).expect("subscribe");

        let list = role_of(&layout, "list");
        let focused = layout
            .apply(
                format!(r#"{{"verb":"focus","target":{{"id": {list}}}}}"#),
                "human".into(),
            )
            .expect("focus the focused pane");
        assert_eq!(
            focused.version, 0,
            "focusing the focused pane changed nothing"
        );

        let mut last = 0;
        for _ in 0..20 {
            last = layout
                .focus_direction("next".into(), "human".into())
                .expect("step")
                .version;
        }
        assert_eq!(
            last, 20,
            "each step that moved focus moved the version once"
        );
        std::thread::sleep(Duration::from_millis(300));
        let reported: Vec<u64> = versions.try_iter().collect();
        assert!(
            reported.iter().all(|v| *v <= last),
            "the feed invented a version after the verbs: {reported:?} (last {last})"
        );
        assert_eq!(layout.version(), last);
        layout.unsubscribe_invalidations();
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
                r#"{"verb":"set-query","target":{"role": "list"},"query":{"kinds":["surface"]}}"#
                    .into(),
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
                r#"{"verb":"split","target":{"role": "detail"},"dir":"vertical",
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
        assert_eq!(
            version,
            before + 1,
            "one write elsewhere moves the version exactly once"
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

        // One change elsewhere, one reload: the reload itself moves this
        // object's session to the new revision, and that is not news.
        let extra: Vec<u64> = versions
            .recv_timeout(Duration::from_millis(600))
            .into_iter()
            .collect();
        assert!(
            extra.is_empty(),
            "one external write reported more than once: {version} then {extra:?}"
        );
        assert_eq!(layout.version(), version);

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
            None,
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

    /// A refused verb reaches Swift with its `LayoutError` tag as `code`,
    /// names the verb, and leaves a `layout` line in the Console (reviews
    /// RL-L11, RL-L6).
    #[test]
    fn a_refused_verb_carries_its_code_and_is_logged() {
        let sink = crate::log_bridge::tests::captured();
        let store = SharedStore::open_in_memory().expect("open");
        let layout = SharedLayout::open(store, "t5-refusal".into(), Some("t5".into()));
        let err = layout
            .apply(
                r#"{"verb":"close","target":{"id": 4242}}"#.into(),
                "agent".into(),
            )
            .unwrap_err();
        match &err {
            SharedLayoutError::Layout { code, message } => {
                assert_eq!(code, "unknown-tile");
                assert!(message.starts_with("close "), "{message}");
            }
            other => panic!("{other:?}"),
        }
        let lines = sink.0.lock().unwrap().clone();
        assert!(
            lines
                .iter()
                .any(|(level, category, message)| level == "warning"
                    && category == "layout"
                    && message.contains("t5-refusal")
                    && message.contains("refused [unknown-tile]")),
            "{lines:#?}"
        );
        assert!(
            lines
                .iter()
                .any(|(_, category, message)| category == "layout"
                    && message.contains("t5-refusal")
                    && message.contains("cold-started")),
            "the cold start is logged too: {lines:#?}"
        );
    }
}
