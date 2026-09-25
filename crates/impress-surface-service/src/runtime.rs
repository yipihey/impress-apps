//! The impure half of a surface: running its sources through the linked
//! `#[impress_service]` inventory and the store, and turning what the human
//! did into effects that actually happen (ADR-0033 D2/D4).
//!
//! [`impress_surface`] is pure — `plan`/`resolve`/`reduce` never touch a
//! store or call a verb themselves. This module is the other half: an
//! [`Executor`] that CAN, a [`SurfaceRuntime`] that holds one surface
//! instance's live state (spec, state, params, source cache) between calls,
//! and a [`SessionRegistry`] that holds one of those per `(surface, host)` —
//! the same shape `impress-layout-service/src/session.rs` gives the layout
//! tree, for the same reason: a process-wide table, one entry per scope,
//! created on first touch.
//!
//! # Where the linked inventory is reached
//!
//! `impress-capabilities` is the one crate meant to link every
//! `#[impress_service]` trait — but this crate cannot depend on it: its
//! `kit`/`surface` feature already depends on `impress-surface-service`
//! itself, and a dependency back would be a cycle. [`call_verb`] is
//! therefore the same body as `impress_capabilities::call_async`, copied
//! rather than shared: it walks the process-wide `McpToolDescriptor`
//! inventory and runs the matching handler future.

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};
use std::time::{Duration, Instant};

use impress_core::item::{ActorKind, ItemId};
use impress_core::pane_query::{Bindings, ItemRef, KindManifest, PaneQueryError, Scope};
use impress_core::sqlite_store::SqliteItemStore;
use impress_core::store::ItemStore;
use impress_layout::{PaneSpec, ViewKindId};
use impress_layout_service::dto::PaneRefDto as LayoutPaneRefDto;
use impress_layout_service::{DefaultLayoutService, LayoutService};
use impress_service_core::McpToolDescriptor;
use impress_surface::{
    plan, reduce, resolve_with_source_errors, CachedSource, Effect, Event, PaneQuery, ParamDecl,
    RenderTree, Source, SourceCache, SourceRequestKind, SurfaceSpec,
};
use serde_json::Value;

use crate::dto::{EffectOutcomeDto, ShowTargetDto, SplitTargetDto};
use crate::store::{SurfaceRow, SurfaceStore};
use impress_service_core::refusal::codes;
use impress_service_core::Refusal;

/// See [`crate::Result`]: a stable `code` and a sentence.
pub type Result<T> = crate::Result<T>;

/// A layout verb's refusal, carried into a surface's own result with the
/// code the layout service gave it.
fn layout_refused(code: Option<String>, message: String) -> Refusal {
    Refusal::new(code.unwrap_or_else(|| "refused".to_string()), message)
}

// ---------------------------------------------------------------------------
// The linked inventory
// ---------------------------------------------------------------------------

/// Run one linked verb by its MCP tool name. See the module docs for why
/// this is a copy of `impress_capabilities::call_async` rather than a
/// dependency on it.
pub(crate) async fn call_verb(name: &str, args: Value) -> Result<Value> {
    let descriptor = McpToolDescriptor::iter()
        .find(|d| d.name == name)
        .ok_or_else(|| Refusal::new("unknown-verb", format!("Unknown tool: {name}")))?;
    (descriptor.handler)(args)
        .await
        .map_err(|e| Refusal::new(codes::VERB_FAILED, format!("{}: {}", descriptor.name, e)))
}

/// Whether a verb name is in the linked inventory — what `surface_validate`
/// checks every `source`/`action` verb reference against (ADR-0033 D4: "a
/// source or action that names a verb calls it through the
/// `#[impress_service]` inventory in the host process").
pub fn verb_exists(name: &str) -> bool {
    McpToolDescriptor::iter().any(|d| d.name == name)
}

// ---------------------------------------------------------------------------
// VerbHost (ADR-0033 D4, amended 2026-09-23 for wave 5)
// ---------------------------------------------------------------------------

/// A second inventory the host process supplies for verbs this binary did
/// not link (ADR-0033 D4, amended 2026-09-23). Consulted only after the
/// linked inventory, so a linked verb is never shadowed.
///
/// In the app, `impress-store-ffi` implements this over `impel-tools`'
/// `call_tool` — the suite's already-linked full inventory, which reaches
/// imbib and imprint through their own HTTP routers and refuses, by name,
/// when the owning app is not running (see `impel_tools::ToolError`). A
/// domain core is therefore still linked once per app process, never twice
/// (ADR-0033 D4's own prohibition), and a verb whose app is down fails in
/// the source rather than silently writing the store behind the running
/// app's back.
///
/// Synchronous on purpose: the UniFFI callback into Swift is synchronous,
/// and the host's own `call_tool` blocks on its own Tokio runtime
/// (`impress_service_core::runtime::block_on`) rather than yielding to this
/// crate's. [`DefaultExecutor`] therefore runs a host call under
/// `tokio::task::spawn_blocking` (see its `call_verb`), so a slow host (an
/// HTTP round trip to imbib) never parks one of this runtime's own worker
/// threads.
pub trait VerbHost: Send + Sync {
    /// Whether the host can answer this verb at all — checked before
    /// [`Self::call_verb`], so `surface_validate` can report "no such verb"
    /// without actually calling it.
    fn has_verb(&self, name: &str) -> bool;
    /// Run the verb and return its JSON result.
    fn call_verb(&self, name: &str, args: Value) -> Result<Value>;
}

// ---------------------------------------------------------------------------
// Executor
// ---------------------------------------------------------------------------

/// Which pane, on which device, is currently showing a `(surface, host)`
/// instance — set by `surface_show`, consumed by the `publish`/`open`
/// effects. `None` until `surface_show` has run at least once for this
/// instance: a surface rendered headlessly (Tier A, `surface_render` with no
/// pane behind it) has nothing to publish a selection ON, and a `publish` or
/// `open` action against it fails cleanly rather than guessing a pane.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PaneHandle {
    pub app_id: String,
    pub device: String,
    pub tile: u64,
}

/// What runs a surface's sources and effects. [`DefaultExecutor`] is the
/// only implementation the suite ships; the trait exists so Tier A tests can
/// swap in a fixture that never touches the inventory or the store.
#[async_trait::async_trait]
pub trait Executor: Send + Sync {
    /// Call a linked verb by name.
    async fn call_verb(&self, name: &str, args: Value) -> Result<Value>;
    /// Run a pane query — the store read every list pane uses, compiled the
    /// same way `impress_store_ffi::layout::compile_pane_query` does. Rows
    /// come back as a JSON array (each item's own JSON shape), never a
    /// domain-specific projection.
    async fn run_query(&self, query: &PaneQuery, bindings: &Bindings) -> Result<Value>;
    /// Publish a selection on `pane`'s channel — `layout-service_select`.
    async fn publish(
        &self,
        pane: &PaneHandle,
        kind: &str,
        ids: Value,
        actor: ActorKind,
    ) -> Result<()>;
    /// Open a query in a pane — composes `layout-service` verbs exactly as
    /// `surface_show` does (see [`show_in_pane`]), so "a surface can drive
    /// the layout tree, not just itself" (`docs/agent-surfaces.md`) is the
    /// same code path either way.
    ///
    /// `actor` is whoever caused the dispatch — the human clicking in the
    /// pane, or an agent — and is the actor the layout verbs record, so a
    /// person's click lands on the person's undo ring (review AC-F5).
    async fn open(
        &self,
        pane: Option<&PaneHandle>,
        query: Value,
        view_kind: &str,
        target: Option<&str>,
        actor: ActorKind,
    ) -> Result<()>;
    /// Append an event row, attributed to `actor`, and return its `seq`.
    async fn emit(
        &self,
        surface: ItemId,
        host: &str,
        name: &str,
        payload: Value,
        actor: ActorKind,
    ) -> Result<u64>;
    /// Which pane, if any, is showing `surface` right now — recovered from
    /// the LAYOUT rather than remembered. A runtime instance only knows its
    /// pane if `surface_show` (or the FFI's `bind_pane`) ran on THIS
    /// instance, and instances are per `SharedSurface` handle: the pane view
    /// in the app has one, an HTTP dispatch on the same surface opens
    /// another, and the second answered every `publish`/`open` with "no pane
    /// shows this surface yet" while the pane sat on screen (verified live,
    /// 2026-09-23). The tree is the one source that cannot disagree with the
    /// window, so it is asked. Default `None`: a fixture that never shows a
    /// surface has nothing to find.
    async fn pane_showing(&self, _surface: ItemId) -> Option<PaneHandle> {
        None
    }
    /// Whether `pane` still shows `surface` — asked before a remembered
    /// pane is used for an effect (RS-S25): the pane may have been closed,
    /// or its tile given another query, since it was recorded. Default
    /// `true`: a fixture has no layout to disagree with.
    async fn pane_shows(&self, _pane: &PaneHandle, _surface: ItemId) -> bool {
        true
    }
}

/// Lift each row's `payload` object to the top of the row.
///
/// A store `Item` serializes as its ENVELOPE — `id`, `created`, `modified`,
/// `parent`, `is_read`, … — with the domain fields nested under `payload`. A
/// surface author writes `{"table": {"columns": ["title", "year"], "rows":
/// "{{source.papers}}"}}`, which is what the S1 golden's rows look like
/// (`{"title": …, "year": …}`): flat. Rendered against the real executor the
/// table drew its header and two empty rows, because `row["title"]` was
/// `null` — the title sat at `row["payload"]["title"]` (verified live in the
/// impress window, 2026-09-22).
///
/// The envelope WINS on a name collision, and `payload` is left in place: a
/// spec that already reads `{{source.papers.0.payload.title}}` keeps working,
/// and no envelope field can be shadowed by a domain field that happens to
/// share its name (`id` is the case that matters — selection publishes it).
fn flatten_payloads(rows: Value) -> Value {
    let Value::Array(items) = rows else {
        return rows;
    };
    Value::Array(
        items
            .into_iter()
            .map(|item| {
                let Value::Object(envelope) = item else {
                    return item;
                };
                let Some(Value::Object(payload)) = envelope.get("payload") else {
                    return Value::Object(envelope);
                };
                let mut flat = payload.clone();
                for (key, value) in envelope {
                    flat.insert(key, value);
                }
                Value::Object(flat)
            })
            .collect(),
    )
}

/// The real [`Executor`]: verbs through the linked inventory, queries and
/// events through the store, publish/open through `impress-layout-service`.
#[derive(Clone)]
pub struct DefaultExecutor {
    store: Arc<SqliteItemStore>,
    surfaces: SurfaceStore,
    layout: DefaultLayoutService,
    /// The second inventory consulted when a verb is not in this process's
    /// linked `#[impress_service]` set — see [`VerbHost`]. `None` in every
    /// binary that has not installed one (the CLI, MCP, and every Tier A
    /// test unless it opts in with [`Self::with_verb_host`]).
    verb_host: Option<Arc<dyn VerbHost>>,
}

impl DefaultExecutor {
    pub fn new(store: Arc<SqliteItemStore>) -> Self {
        Self {
            surfaces: SurfaceStore::new(store.clone()),
            // `DefaultLayoutService::new()` reaches the SAME process-wide
            // store and session registry every other layout verb does —
            // never a private one — so a surface shown here is the surface
            // the GUI (or the CLI, or another MCP call) already has open.
            layout: DefaultLayoutService::new(),
            store,
            verb_host: None,
        }
    }

    /// An instance over an explicit store — hermetic tests only, mirroring
    /// `impress-layout-service::DefaultLayoutService::with_store`.
    pub fn with_store(store: Arc<SqliteItemStore>) -> Self {
        Self {
            surfaces: SurfaceStore::new(store.clone()),
            layout: DefaultLayoutService::with_store(store.clone()),
            store,
            verb_host: None,
        }
    }

    /// An instance whose layout verbs run in `sessions` — the registry the
    /// renderer in this process reads from — so an `open`/`publish` effect
    /// changes the tree the window is showing, not a private copy of it.
    pub fn with_store_and_sessions(
        store: Arc<SqliteItemStore>,
        sessions: Arc<impress_layout_service::SessionRegistry>,
    ) -> Self {
        Self {
            surfaces: SurfaceStore::new(store.clone()),
            layout: DefaultLayoutService::with_store_and_sessions(store.clone(), sessions),
            store,
            verb_host: None,
        }
    }

    /// Install a [`VerbHost`] this executor consults for any verb its own
    /// linked inventory lacks (ADR-0033 D4, amended 2026-09-23). Builder
    /// style so `DefaultExecutor::new(store).with_verb_host(host)` reads as
    /// one setup step, matching every other `with_*` on this type.
    pub fn with_verb_host(mut self, host: Arc<dyn VerbHost>) -> Self {
        self.verb_host = Some(host);
        self
    }
}

#[async_trait::async_trait]
impl Executor for DefaultExecutor {
    async fn call_verb(&self, name: &str, args: Value) -> Result<Value> {
        if verb_exists(name) {
            // The inventory wins on a shared name: a verb linked into this
            // process is never shadowed by a host that happens to answer
            // for the same name too (ADR-0033's amendment is explicit about
            // this ordering).
            return call_verb(name, args).await;
        }
        let Some(host) = self.verb_host.clone() else {
            return Err(Refusal::new(
                "unknown-verb",
                format!(
                    "Unknown tool: {name} (not in this process's inventory; no verb host \
                     installed)"
                ),
            ));
        };
        if !host.has_verb(name) {
            return Err(Refusal::new(
                "unknown-verb",
                format!(
                    "Unknown tool: {name} (not in this process's inventory; host has no such \
                     verb)"
                ),
            ));
        }
        // Synchronous by design (see `VerbHost`'s docs): run it off this
        // runtime's own worker threads so a slow host call — an HTTP round
        // trip to imbib or imprint — cannot park one.
        let owned_name = name.to_string();
        tokio::task::spawn_blocking(move || host.call_verb(&owned_name, args))
            .await
            .map_err(|e| {
                Refusal::internal(format!("verb host call to {name}: task panicked: {e}"))
            })?
    }

    async fn run_query(&self, query: &PaneQuery, bindings: &Bindings) -> Result<Value> {
        // `decls` is empty: the Executor trait (by design, see this crate's
        // report) is handed only resolved `bindings`, not the surface's own
        // `ParamDecl`s, so a `required` param that is unbound cannot be
        // flagged as an error here — it simply compiles to an empty-set
        // predicate, the same "unfilled, not wrong" reading `compile`
        // already gives an optional unbound param.
        let compiled = impress_core::pane_query::compile(
            query,
            &[],
            bindings,
            &impress_core::pane_query::builtin_manifest(),
        )
        .map_err(|e: PaneQueryError| Refusal::new("query-refused", e.to_string()))?;
        let items = self
            .store
            .query(&compiled.item_query)
            .map_err(|e| Refusal::store(format!("run query: {e}")))?;
        let rows = serde_json::to_value(items)
            .map_err(|e| Refusal::internal(format!("encode query result: {e}")))?;
        Ok(flatten_payloads(rows))
    }

    async fn publish(
        &self,
        pane: &PaneHandle,
        kind: &str,
        ids: Value,
        actor: ActorKind,
    ) -> Result<()> {
        let id_strings: Vec<String> = match ids {
            Value::Array(items) => items
                .into_iter()
                .map(|v| match v {
                    Value::String(s) => s,
                    other => other.to_string(),
                })
                .collect(),
            Value::String(s) => vec![s],
            Value::Null => Vec::new(),
            other => vec![other.to_string()],
        };
        let result = self
            .layout
            .select(
                pane.app_id.clone(),
                Some(pane.device.clone()),
                LayoutPaneRefDto::tile(impress_layout::TileId::new(pane.tile)),
                kind.to_string(),
                id_strings,
                Some(actor_name(actor).to_string()),
            )
            .await;
        if result.ok {
            Ok(())
        } else {
            Err(layout_refused(result.code, result.message))
        }
    }

    async fn open(
        &self,
        pane: Option<&PaneHandle>,
        query: Value,
        view_kind: &str,
        target: Option<&str>,
        actor: ActorKind,
    ) -> Result<()> {
        let Some(pane) = pane else {
            return Err(Refusal::new(
                "no-pane",
                "this surface instance has no pane yet (surface_show has not run) — nothing to \
                 open a query beside",
            ));
        };
        let query: PaneQuery = serde_json::from_value(query)
            .map_err(|e| Refusal::invalid_argument(format!("open: query: {e}")))?;
        let show_target = match target {
            Some(role) => ShowTargetDto {
                role: Some(role.to_string()),
                tile: None,
                split: None,
            },
            None => ShowTargetDto {
                role: None,
                tile: None,
                split: Some(SplitTargetDto {
                    direction: "vertical".to_string(),
                    from_focused: true,
                }),
            },
        };
        show_in_pane(
            &self.layout,
            &pane.app_id,
            Some(pane.device.clone()),
            query,
            view_kind,
            &show_target,
            Some(actor_name(actor).to_string()),
        )
        .await
        .map(|_| ())
    }

    async fn emit(
        &self,
        surface: ItemId,
        host: &str,
        name: &str,
        payload: Value,
        actor: ActorKind,
    ) -> Result<u64> {
        self.surfaces
            .append_event(surface, host, name, &payload, actor)
    }

    async fn pane_showing(&self, surface: ItemId) -> Option<PaneHandle> {
        // The app that renders surfaces is the chassis shell, and the layout
        // is device-scoped: this machine's tree, the one the window draws.
        // `impress-store-ffi::surface` binds panes under the same app id.
        let app_id = SURFACE_APP_ID.to_string();
        let device = impress_layout_service::resolve_device(None);
        let result = self
            .layout
            .get_layout(app_id.clone(), Some(device.clone()))
            .await;
        let layout = result.layout?;
        let wanted = surface_item_query(surface);
        let tile = layout.panes().into_iter().find(|tile| {
            layout.pane(*tile).is_some_and(|spec| {
                spec.view_kind == ViewKindId::from(SURFACE_VIEW_KIND.to_string())
                    && spec.query == wanted
            })
        })?;
        Some(PaneHandle {
            app_id,
            device,
            tile: tile.raw(),
        })
    }

    async fn pane_shows(&self, pane: &PaneHandle, surface: ItemId) -> bool {
        let result = self
            .layout
            .get_layout(pane.app_id.clone(), Some(pane.device.clone()))
            .await;
        let Some(layout) = result.layout else {
            return false;
        };
        let wanted = surface_item_query(surface);
        layout
            .pane(impress_layout::TileId::new(pane.tile))
            .is_some_and(|spec| {
                spec.view_kind == ViewKindId::from(SURFACE_VIEW_KIND.to_string())
                    && spec.query == wanted
            })
    }
}

/// The app whose layout a surface pane lives in. One chassis shell renders
/// surfaces today; `impress-store-ffi` binds panes under the same id.
pub const SURFACE_APP_ID: &str = "impress";
/// `impress_layout::ViewKindId::SURFACE`'s spelling.
const SURFACE_VIEW_KIND: &str = "surface";

// ---------------------------------------------------------------------------
// Composing layout verbs — shared by `surface_show` (service.rs) and
// `DefaultExecutor::open`
// ---------------------------------------------------------------------------

/// Put a query+view-kind in the pane [`ShowTargetDto`] names, creating it
/// (a split) when the target says so. Returns `(tile, focused, affected_panes)`
/// — the same trio every layout verb answers with.
///
/// This is the one place `surface_show` and an `{"open": …}` action agree on
/// what "put this in a pane" means — see this crate's module docs and
/// `docs/agent-surfaces.md`'s "`open`" row.
pub(crate) async fn show_in_pane(
    layout: &DefaultLayoutService,
    app_id: &str,
    device: Option<String>,
    query: PaneQuery,
    view_kind: &str,
    target: &ShowTargetDto,
    actor: Option<String>,
) -> Result<(u64, bool, Vec<u64>)> {
    if let Some(tile) = target.tile {
        let pane_ref = LayoutPaneRefDto::tile(impress_layout::TileId::new(tile));
        let r1 = layout
            .set_query(
                app_id.to_string(),
                device.clone(),
                pane_ref.clone(),
                query,
                actor.clone(),
            )
            .await;
        if !r1.ok {
            return Err(layout_refused(r1.code, r1.message));
        }
        let r2 = layout
            .set_view_kind(
                app_id.to_string(),
                device.clone(),
                pane_ref,
                view_kind.to_string(),
                actor,
            )
            .await;
        if !r2.ok {
            return Err(layout_refused(r2.code, r2.message));
        }
        return Ok((tile, r2.focused == Some(tile), r2.affected_panes));
    }

    if let Some(role) = &target.role {
        let pane_ref = LayoutPaneRefDto::role(role);
        let resolved = layout
            .resolve_reference(app_id.to_string(), device.clone(), pane_ref.clone())
            .await;
        if !resolved.ok {
            return Err(layout_refused(resolved.code, resolved.message));
        }
        let tile = resolved.tile.ok_or_else(|| {
            Refusal::new(
                "no-pane-with-role",
                format!("role '{role}' does not resolve to a pane"),
            )
        })?;
        let r1 = layout
            .set_query(
                app_id.to_string(),
                device.clone(),
                pane_ref.clone(),
                query,
                actor.clone(),
            )
            .await;
        if !r1.ok {
            return Err(layout_refused(r1.code, r1.message));
        }
        let r2 = layout
            .set_view_kind(
                app_id.to_string(),
                device,
                pane_ref,
                view_kind.to_string(),
                actor,
            )
            .await;
        if !r2.ok {
            return Err(layout_refused(r2.code, r2.message));
        }
        return Ok((tile, r2.focused == Some(tile), r2.affected_panes));
    }

    // Split — the default when neither `tile` nor `role` is given, and the
    // only shape `SplitTargetDto` has. `from_focused` is documented on the
    // DTO as accepted-but-currently-equivalent to always-true (splitting the
    // focused pane is the only target this composition can resolve without
    // more state than a surface instance tracks).
    let direction = target
        .split
        .as_ref()
        .map(|s| s.direction.as_str())
        .unwrap_or("vertical");
    let new_pane = PaneSpec::new(query, ViewKindId::from(view_kind.to_string()));
    let split = layout
        .split(
            app_id.to_string(),
            device,
            LayoutPaneRefDto::focused(),
            direction.to_string(),
            true,
            Some(new_pane),
            actor,
        )
        .await;
    if !split.ok {
        return Err(layout_refused(split.code, split.message));
    }
    let tile = split
        .focused
        .ok_or_else(|| Refusal::internal("split produced no focused tile"))?;
    Ok((tile, true, split.affected_panes))
}

/// `item(id)` of the `surface` kind — the query every surface pane's spec is
/// (ADR-0033 D1). Kept here so `surface_show` (service.rs) and this module's
/// own tests build it identically.
pub(crate) fn surface_item_query(id: ItemId) -> PaneQuery {
    PaneQuery {
        kinds: vec!["surface".to_string()],
        scope: Scope::Item {
            id: ItemRef::Id { id },
        },
        ..PaneQuery::default()
    }
}

// ---------------------------------------------------------------------------
// SurfaceRuntime
// ---------------------------------------------------------------------------

/// How long a source that failed is left alone before a render asks for it
/// again with the same arguments (RS-S15). A render happens on every
/// dispatch and every feed notification; without this, a verb whose app is
/// not running was called again — synchronously, over HTTP — each time, and
/// up to `sources + 1` times within one render.
pub const FAILED_SOURCE_BACKOFF: Duration = Duration::from_secs(5);

/// A source fetch that failed, and with which arguments.
#[derive(Debug, Clone)]
struct FailedFetch {
    args_hash: u64,
    at: Instant,
}

/// One `(surface, host)` instance, live in memory: its spec, its working
/// state, the pane parameters bound to it, and the source cache
/// [`impress_surface::plan`] reads. Also the sole owner of which pane (if
/// any) `surface_show` last put it in.
///
/// A runtime is a CACHE of the store, never a second truth (RS-S1): every
/// [`SessionRegistry::with`] compares the stored spec and state with what
/// this runtime last loaded or wrote, and reloads whichever moved — so an
/// update or state write from another handle, an HTTP request or another
/// process is what the next render shows, and the next dispatch builds on.
pub struct SurfaceRuntime {
    pub surface_id: ItemId,
    pub host: String,
    pub spec: SurfaceSpec,
    pub state: Value,
    /// The pane parameters bound to this surface (ADR-0033's `param` root).
    /// No S4 verb currently sets this — the normative verb list
    /// (`docs/plan-agent-surfaces.md`) has no `params` argument anywhere —
    /// so it is `{}` until a later work package wires pane bindings through
    /// (see this crate's report).
    pub params: Value,
    pub cache: SourceCache,
    /// Why a source's last fetch failed, by name — cleared when it succeeds.
    /// `render` hands it to `resolve_with_source_errors` so the pane says
    /// "source 'libs' failed: imbib is not running" rather than the generic
    /// "did not resolve". Before this the error was dropped on the floor.
    pub source_errors: BTreeMap<String, String>,
    pub pane: Option<PaneHandle>,
    /// The spec text this runtime was loaded from (see the struct docs).
    spec_text: String,
    /// The state text last read from or written to the store — `None` while
    /// the instance has no state row (it runs on the spec's initial state).
    state_text: Option<String>,
    /// See [`FAILED_SOURCE_BACKOFF`].
    failed: BTreeMap<String, FailedFetch>,
}

impl SurfaceRuntime {
    fn load(surface_id: ItemId, host: String, row: SurfaceRow, state_text: Option<String>) -> Self {
        let mut runtime = Self {
            surface_id,
            host,
            state: row.spec.state.clone(),
            spec: row.spec,
            params: Value::Object(serde_json::Map::new()),
            cache: SourceCache::new(),
            source_errors: BTreeMap::new(),
            pane: None,
            spec_text: row.spec_text,
            state_text: None,
            failed: BTreeMap::new(),
        };
        runtime.adopt_state(state_text);
        runtime
    }

    /// Bring this runtime up to the store: a new spec replaces the old one
    /// (and every cached source, which may no longer mean what it did); a
    /// new state replaces the working state. Unchanged text is left alone,
    /// so a warm source cache survives every call that changed nothing.
    fn refresh(&mut self, row: SurfaceRow, state_text: Option<String>) {
        if row.spec_text != self.spec_text {
            self.spec = row.spec;
            self.spec_text = row.spec_text;
            self.cache.clear();
            self.source_errors.clear();
            self.failed.clear();
            // No state row: the instance runs on the spec's initial state,
            // which is the NEW spec's now.
            if state_text.is_none() {
                self.state = self.spec.state.clone();
            }
        }
        if state_text != self.state_text {
            self.adopt_state(state_text);
        }
    }

    fn adopt_state(&mut self, state_text: Option<String>) {
        self.state = match state_text.as_deref().map(serde_json::from_str::<Value>) {
            Some(Ok(state)) => state,
            // An unreadable state row is not a reason to refuse the surface:
            // it runs on the spec's initial state, and the next dispatch
            // writes a readable one over it.
            Some(Err(_)) | None => self.spec.state.clone(),
        };
        self.state_text = state_text;
    }

    /// The schema refs this runtime's `query` sources read — what a store
    /// invalidation has to name for [`Self::invalidate_sources`] to re-run
    /// one (RS-S2).
    pub fn query_refs(&self) -> BTreeSet<String> {
        let manifest = impress_core::pane_query::builtin_manifest();
        self.spec
            .sources
            .values()
            .filter_map(|source| match source {
                Source::Query { query } => Some(refs_read_by(query, &manifest)),
                _ => None,
            })
            .flatten()
            .collect()
    }

    /// Drop the cached value of every `query` source that reads one of
    /// `refs`, so the next render runs it again (ADR-0033 Defaults: sources
    /// re-run "when a store invalidation names a query"). Returns the names
    /// dropped. `verb` and `value` sources are untouched: an invalidation
    /// names record kinds, and what a verb reads is not declared anywhere —
    /// a verb source re-runs when its arguments change or an action
    /// refreshes it.
    pub fn invalidate_sources(&mut self, refs: &BTreeSet<String>) -> Vec<String> {
        let manifest = impress_core::pane_query::builtin_manifest();
        let names: Vec<String> = self
            .spec
            .sources
            .iter()
            .filter_map(|(name, source)| match source {
                Source::Query { query }
                    if refs_read_by(query, &manifest)
                        .iter()
                        .any(|r| refs.contains(r)) =>
                {
                    Some(name.clone())
                }
                _ => None,
            })
            .collect();
        for name in &names {
            self.cache.remove(name);
            self.failed.remove(name);
        }
        names
    }

    /// Fetch every stale/unfetched source (bounded rounds: a chain of N
    /// dependent sources settles in at most N rounds, and a round that
    /// fetches nothing new stops immediately rather than spinning on a
    /// permanently failing verb) and resolve the tree.
    ///
    /// A source that failed with the same arguments within
    /// [`FAILED_SOURCE_BACKOFF`] is not asked again — in a later round of
    /// this render or in a later render — and keeps its error (RS-S15).
    pub async fn render(&mut self, executor: &dyn Executor) -> RenderTree {
        let max_rounds = self.spec.sources.len() + 1;
        for _ in 0..max_rounds {
            let requests = plan(&self.spec, &self.state, &self.params, &self.cache);
            if requests.is_empty() {
                break;
            }
            let mut progressed = false;
            for request in requests {
                if self.failed.get(&request.name).is_some_and(|f| {
                    f.args_hash == request.args_hash && f.at.elapsed() < FAILED_SOURCE_BACKOFF
                }) {
                    continue;
                }
                let fetched = match &request.kind {
                    SourceRequestKind::Verb { verb, args } => {
                        executor.call_verb(verb, args.clone()).await
                    }
                    SourceRequestKind::Query { query } => {
                        let bindings = bindings_from_params(&self.spec.params, &self.params);
                        executor.run_query(query, &bindings).await
                    }
                };
                match fetched {
                    Ok(value) => {
                        self.source_errors.remove(&request.name);
                        self.failed.remove(&request.name);
                        self.cache.insert(
                            request.name.clone(),
                            CachedSource {
                                args_hash: request.args_hash,
                                value,
                            },
                        );
                        progressed = true;
                    }
                    Err(why) => {
                        log::warn!(
                            target: "surface",
                            "surface {} ({}): source '{}' failed [{}]: {}",
                            self.surface_id,
                            self.host,
                            request.name,
                            why.code,
                            why.message
                        );
                        self.source_errors.insert(request.name.clone(), why.message);
                        self.failed.insert(
                            request.name.clone(),
                            FailedFetch {
                                args_hash: request.args_hash,
                                at: Instant::now(),
                            },
                        );
                    }
                }
                // A failed fetch leaves the previous cache entry (if any) in
                // place — the last known value is still the best available
                // approximation (`plan.rs`'s own module docs make the same
                // call for a merely-stale entry).
            }
            if !progressed {
                break;
            }
        }
        // `{"value": …}` sources never go through `plan()`/fetch at all
        // (`impress_surface::plan`'s own module docs: "it has no request
        // kind to give the runtime... `resolve.rs` reads it straight out of
        // the spec") — so the source map handed to `resolve` has to include
        // them directly, not only what the fetch loop above cached.
        let mut source_values = serde_json::Map::new();
        for (name, source) in &self.spec.sources {
            if let Source::Value { value } = source {
                source_values.insert(name.clone(), value.clone());
            }
        }
        for (name, cached) in self.cache.iter() {
            source_values.insert(name.clone(), cached.value.clone());
        }
        resolve_with_source_errors(
            &self.spec,
            &self.state,
            &self.params,
            &Value::Object(source_values),
            Some(&self.source_errors),
        )
    }

    /// Every source that failed on the last render, in the wire's shape.
    pub fn source_error_list(&self) -> Vec<crate::dto::SourceError> {
        self.source_errors
            .iter()
            .map(|(name, message)| crate::dto::SourceError {
                name: name.clone(),
                message: message.clone(),
            })
            .collect()
    }

    /// Reduce an event, persist the resulting state, run every effect, and
    /// re-render. Persistence happens here (not in the caller) so a
    /// dispatch that runs zero effects still leaves the state row in sync
    /// with what `reduce` just decided.
    ///
    /// The state is written only when it differs from what is stored
    /// (RS-S14): once after `reduce`, before any effect runs — so an agent
    /// woken by an `emit` reads the state that produced it — and again only
    /// if a `call … into` changed it after that.
    pub async fn dispatch(
        &mut self,
        executor: &dyn Executor,
        surfaces: &SurfaceStore,
        event: &Event,
        actor: ActorKind,
    ) -> Result<(RenderTree, Vec<EffectOutcomeDto>)> {
        let (new_state, effects) = reduce(&self.spec, &self.state, &self.params, event)
            .map_err(|e| Refusal::new(e.code(), e.to_string()))?;
        self.state = new_state;
        self.persist_state(surfaces, actor)?;

        let mut outcomes = Vec::with_capacity(effects.len());
        for effect in effects {
            let outcome = self.run_effect(executor, effect, actor).await;
            if outcome.ok {
                log::debug!(
                    target: "surface",
                    "surface {} ({}): {} effect ok: {}",
                    self.surface_id,
                    self.host,
                    outcome.kind,
                    outcome.message
                );
            } else {
                log::warn!(
                    target: "surface",
                    "surface {} ({}): {} effect failed [{}]: {}",
                    self.surface_id,
                    self.host,
                    outcome.kind,
                    outcome.code.as_deref().unwrap_or("?"),
                    outcome.message
                );
            }
            outcomes.push(outcome);
        }
        self.persist_state(surfaces, actor)?;

        let tree = self.render(executor).await;
        Ok((tree, outcomes))
    }

    /// Write the working state if it differs from the stored one (or, with
    /// no state row yet, from the spec's initial state). Returns whether it
    /// wrote.
    fn persist_state(&mut self, surfaces: &SurfaceStore, actor: ActorKind) -> Result<bool> {
        let text = serde_json::to_string(&self.state)
            .map_err(|e| Refusal::internal(format!("encode surface state: {e}")))?;
        let unchanged = match &self.state_text {
            Some(stored) => *stored == text,
            None => serde_json::to_string(&self.spec.state).ok().as_deref() == Some(&text),
        };
        if unchanged {
            return Ok(false);
        }
        surfaces.set_state_text(self.surface_id, &self.host, text.clone(), actor)?;
        self.state_text = Some(text);
        Ok(true)
    }

    /// Set the working state directly (`surface_state_set`), writing it
    /// through so the runtime and the store agree.
    pub fn set_state(
        &mut self,
        surfaces: &SurfaceStore,
        state: Value,
        actor: ActorKind,
    ) -> Result<()> {
        let text = serde_json::to_string(&state)
            .map_err(|e| Refusal::internal(format!("encode surface state: {e}")))?;
        surfaces.set_state_text(self.surface_id, &self.host, text.clone(), actor)?;
        self.state = state;
        self.state_text = Some(text);
        Ok(())
    }

    /// The pane this instance is shown in — remembered from `surface_show`
    /// / `bind_pane` while the layout still shows it there (RS-S25), else
    /// recovered from the layout and remembered. See
    /// `Executor::pane_showing` for why the lookup exists.
    async fn pane_or_lookup(&mut self, executor: &dyn Executor) -> Option<PaneHandle> {
        if let Some(pane) = self.pane.clone() {
            if executor.pane_shows(&pane, self.surface_id).await {
                return Some(pane);
            }
            self.pane = None;
        }
        self.pane = executor.pane_showing(self.surface_id).await;
        self.pane.clone()
    }

    async fn run_effect(
        &mut self,
        executor: &dyn Executor,
        effect: Effect,
        actor: ActorKind,
    ) -> EffectOutcomeDto {
        match effect {
            Effect::Call { verb, args, into } => match executor.call_verb(&verb, args).await {
                Ok(value) => {
                    if let Some(path) = &into {
                        if let Err(e) = set_state_path(&mut self.state, path, value) {
                            return EffectOutcomeDto::failed("call", e);
                        }
                    }
                    EffectOutcomeDto::done("call", format!("called {verb}"))
                }
                Err(e) => EffectOutcomeDto::failed("call", e),
            },
            Effect::Publish { ids } => {
                let Some(pane) = self.pane_or_lookup(executor).await else {
                    return EffectOutcomeDto::failed(
                        "publish",
                        Refusal::new(
                            "no-pane",
                            "no pane shows this surface yet (surface_show has not run)",
                        ),
                    );
                };
                let (kind, ids) = publish_kind_and_ids(&self.spec, ids);
                match executor.publish(&pane, &kind, ids, actor).await {
                    Ok(()) => {
                        EffectOutcomeDto::done("publish", format!("published on kind '{kind}'"))
                    }
                    Err(e) => EffectOutcomeDto::failed("publish", e),
                }
            }
            Effect::Emit { name, payload } => {
                match executor
                    .emit(self.surface_id, &self.host, &name, payload, actor)
                    .await
                {
                    Ok(seq) => {
                        EffectOutcomeDto::done("emit", format!("emitted '{name}' (seq {seq})"))
                    }
                    Err(e) => EffectOutcomeDto::failed("emit", e),
                }
            }
            Effect::Open {
                query,
                view_kind,
                target,
            } => {
                let pane = self.pane_or_lookup(executor).await;
                match executor
                    .open(pane.as_ref(), query, &view_kind, target.as_deref(), actor)
                    .await
                {
                    Ok(()) => {
                        EffectOutcomeDto::done("open", format!("opened a '{view_kind}' pane"))
                    }
                    Err(e) => EffectOutcomeDto::failed("open", e),
                }
            }
            Effect::Refresh { source } => {
                self.cache.remove(&source);
                self.failed.remove(&source);
                EffectOutcomeDto::done(
                    "refresh",
                    format!("'{source}' will re-fetch on next render"),
                )
            }
        }
    }
}

/// `human` | `agent` | `system` — the spelling layout verbs take as `actor`.
pub fn actor_name(actor: ActorKind) -> &'static str {
    match actor {
        ActorKind::Human => "human",
        ActorKind::Agent => "agent",
        ActorKind::System => "system",
    }
}

/// Which record kind and which ids a `{"publish": {…}}` action resolves to.
///
/// `Action::Publish` carries no `kind` field (`impress-surface`'s
/// vocabulary — see `docs/plan-agent-surfaces.md`'s Actions table), so this
/// is a choice S4 had to make (see this crate's report): an explicit
/// `{"kind": ..., "ids": [...]}` object wins; otherwise the surface's FIRST
/// declared `params` entry names the kind a publish on this surface is FOR
/// (the same kind a downstream pane would bind `param.selected` to), falling
/// back to the generic `"item"` kind when the surface declares no params.
fn publish_kind_and_ids(spec: &SurfaceSpec, ids: Value) -> (String, Value) {
    if let Value::Object(map) = &ids {
        if let (Some(Value::String(kind)), Some(inner)) = (map.get("kind"), map.get("ids")) {
            return (as_layout_kind(kind), inner.clone());
        }
    }
    let kind = spec
        .params
        .first()
        .map(|p| as_layout_kind(&p.kind))
        .unwrap_or_else(|| "item".to_string());
    (kind, ids)
}

/// A channel key in the LAYOUT's vocabulary.
///
/// A pane parameter declares a `RecordKindId` from
/// `impress_core::pane_query::KindManifest` — `publication` — while a surface
/// spec's own `params` may name the schema ref instead
/// (`imbib/bibliography-entry`, which is what the worked example and the
/// agent-surfaces doc use). Publishing under the ref put
/// `{"imbib/bibliography-entry": [...]}` on the channel, where a detail pane
/// bound to `publication` looked and found nothing: the row was selected in
/// the surface and the detail pane kept saying "No Selection" (verified live
/// in the impress window, 2026-09-22).
///
/// Both spellings are accepted rather than one being declared wrong, because
/// the vocabulary is documented with the ref and a spec already written that
/// way must keep working. An unknown string passes through untouched — a
/// surface may publish a kind this build has never heard of.
fn as_layout_kind(kind: &str) -> String {
    let manifest = impress_core::pane_query::builtin_manifest();
    if manifest.kinds.contains_key(kind) {
        return kind.to_string();
    }
    let base = kind.split_once('@').map(|(head, _)| head).unwrap_or(kind);
    for (id, refs) in &manifest.kinds {
        if refs
            .iter()
            .any(|r| r == kind || r.split_once('@').map(|(head, _)| head).unwrap_or(r) == base)
        {
            return id.clone();
        }
    }
    kind.to_string()
}

/// The schema refs a pane query reads: those of each kind it names, by the
/// manifest (a name the manifest does not know is taken to be a ref itself),
/// or every kind's when it names none — the same "no kinds means all kinds"
/// the compiler applies.
fn refs_read_by(query: &PaneQuery, manifest: &KindManifest) -> Vec<String> {
    if query.kinds.is_empty() {
        return manifest.kinds.values().flatten().cloned().collect();
    }
    query
        .kinds
        .iter()
        .flat_map(|kind| {
            manifest
                .kinds
                .get(kind)
                .cloned()
                .unwrap_or_else(|| vec![kind.clone()])
        })
        .collect()
}

fn bindings_from_params(decls: &[ParamDecl], params: &Value) -> Bindings {
    let mut bindings = Bindings::new();
    if let Some(obj) = params.as_object() {
        for decl in decls {
            if let Some(Value::String(raw)) = obj.get(&decl.name) {
                if let Ok(id) = raw.parse::<ItemId>() {
                    bindings = bindings.with(decl.name.clone(), id);
                }
            }
        }
    }
    bindings
}

/// Write `value` at `path` (`state.a.b.c`), the same discipline
/// `impress_surface::reduce`'s own (private) `set_path` uses — duplicated
/// here in miniature because a `Call … into:` write happens AFTER `reduce`
/// has already returned, not inside it.
fn set_state_path(state: &mut Value, path: &str, value: Value) -> Result<()> {
    let mut parts = path.split('.');
    if parts.next() != Some("state") {
        return Err(Refusal::new(
            "invalid-path",
            format!("`into` path '{path}' must start with 'state.'"),
        ));
    }
    let segments: Vec<&str> = parts.collect();
    if segments.is_empty() {
        return Err(Refusal::new(
            "invalid-path",
            format!("`into` path '{path}' must start with 'state.'"),
        ));
    }
    if !state.is_object() {
        *state = Value::Object(serde_json::Map::new());
    }
    let mut cur = state;
    for (i, seg) in segments.iter().enumerate() {
        let map = match cur {
            Value::Object(m) => m,
            _ => {
                *cur = Value::Object(serde_json::Map::new());
                match cur {
                    Value::Object(m) => m,
                    _ => unreachable!("just assigned an object"),
                }
            }
        };
        if i + 1 == segments.len() {
            map.insert((*seg).to_string(), value);
            return Ok(());
        }
        cur = map
            .entry((*seg).to_string())
            .or_insert_with(|| Value::Object(serde_json::Map::new()));
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// SessionRegistry
// ---------------------------------------------------------------------------

/// One `(surface, host)` entry: the runtime behind an async lock, plus the
/// two sets the invalidation feed reads and writes WITHOUT that lock — so a
/// store write is recorded even while a render holds the runtime for the
/// length of a slow verb.
#[derive(Default)]
struct Slot {
    runtime: tokio::sync::Mutex<Option<SurfaceRuntime>>,
    /// The refs the runtime's query sources read (see
    /// [`SurfaceRuntime::query_refs`]), refreshed on every call.
    reads: Mutex<BTreeSet<String>>,
    /// Refs a store invalidation named since the runtime last ran; applied
    /// with [`SurfaceRuntime::invalidate_sources`] on the next call.
    dirty: Mutex<BTreeSet<String>>,
    /// Set by [`SessionRegistry::retry_failed_sources`]: forget every
    /// remembered failure on the next call.
    retry_failed: std::sync::atomic::AtomicBool,
}

type SessionMap = HashMap<(ItemId, String), Arc<Slot>>;

/// The `(surface, host)` runtime table — the same shape
/// `impress-layout-service::SessionRegistry` gives the layout tree.
///
/// # One per store per process (RS-S1, SK-K1, AC-F1)
///
/// Every caller that renders or drives a surface on one store in one process
/// shares one registry: `impress-store-ffi`'s `SharedStore` owns it and
/// hands it to every `SharedSurface` (each pane, the HTTP bridge), and the
/// store the process installed as its own (`impress_store_service`) uses
/// [`SessionRegistry::shared`], which is what `DefaultImpressSurfaceService::new`
/// reads. Each registry also re-checks the store on every call (see
/// [`Self::with`]), which is what keeps two PROCESSES — the app and
/// `impress-mcp` — from serving each other stale specs.
///
/// # Concurrency
///
/// A call holds its entry's async lock for its whole length, so two calls on
/// the same `(surface, host)` run one after the other and neither's result
/// is overwritten by the other's stale copy; calls on different entries run
/// in parallel.
#[derive(Default)]
pub struct SessionRegistry {
    sessions: Mutex<SessionMap>,
}

impl SessionRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn shared() -> Arc<SessionRegistry> {
        static GLOBAL: OnceLock<Arc<SessionRegistry>> = OnceLock::new();
        GLOBAL
            .get_or_init(|| Arc::new(SessionRegistry::new()))
            .clone()
    }

    /// Run `f` against the runtime for `(surface, host)`, after bringing it
    /// up to the store: loaded on first touch, and on every later touch the
    /// stored spec and state are read (two keyed reads) and whichever moved
    /// since this runtime last loaded or wrote it is reloaded. A surface
    /// that no longer exists is an error and its entry is dropped.
    pub async fn with<R>(
        &self,
        surfaces: &SurfaceStore,
        surface_id: ItemId,
        host: &str,
        f: impl for<'a> FnOnce(
            &'a mut SurfaceRuntime,
        ) -> std::pin::Pin<
            Box<dyn std::future::Future<Output = Result<R>> + Send + 'a>,
        >,
    ) -> Result<R> {
        let key = (surface_id, host.to_string());
        let slot = self.lock().entry(key.clone()).or_default().clone();
        let mut guard = slot.runtime.lock().await;

        let Some(row) = surfaces.get(surface_id)? else {
            *guard = None;
            drop(guard);
            self.forget(surface_id, host);
            return Err(Refusal::not_found(format!("no surface {surface_id}")));
        };
        let state_text = surfaces.get_state_text(surface_id, host)?;
        let runtime = match guard.as_mut() {
            Some(runtime) => {
                runtime.refresh(row, state_text);
                runtime
            }
            None => guard.insert(SurfaceRuntime::load(
                surface_id,
                host.to_string(),
                row,
                state_text,
            )),
        };
        *lock_set(&slot.reads) = runtime.query_refs();
        let dirty = std::mem::take(&mut *lock_set(&slot.dirty));
        if !dirty.is_empty() {
            runtime.invalidate_sources(&dirty);
        }
        if slot
            .retry_failed
            .swap(false, std::sync::atomic::Ordering::SeqCst)
        {
            runtime.failed.clear();
        }
        f(runtime).await
    }

    /// A store write touched records of these schema refs: mark every
    /// runtime whose query sources read one of them, so its next call
    /// re-runs those sources (RS-S2, AC-F16). Returns the surfaces marked —
    /// the ones a host should re-render. Never waits on a runtime in use.
    pub fn invalidate_refs(&self, refs: &BTreeSet<String>) -> Vec<ItemId> {
        if refs.is_empty() {
            return Vec::new();
        }
        let mut marked = Vec::new();
        for ((surface_id, _host), slot) in self.lock().iter() {
            let reads = lock_set(&slot.reads);
            let hit: BTreeSet<String> = reads.intersection(refs).cloned().collect();
            drop(reads);
            if hit.is_empty() {
                continue;
            }
            lock_set(&slot.dirty).extend(hit);
            if !marked.contains(surface_id) {
                marked.push(*surface_id);
            }
        }
        marked
    }

    /// What can answer a verb changed (a verb host was installed): let every
    /// runtime ask its failed sources again on its next call instead of
    /// waiting out [`FAILED_SOURCE_BACKOFF`].
    pub fn retry_failed_sources(&self) {
        for slot in self.lock().values() {
            slot.retry_failed
                .store(true, std::sync::atomic::Ordering::SeqCst);
        }
    }

    /// Every schema ref some live runtime's query sources read — what a feed
    /// watching other processes' writes needs to look for.
    pub fn watched_refs(&self) -> BTreeSet<String> {
        self.lock()
            .values()
            .flat_map(|slot| lock_set(&slot.reads).clone())
            .collect()
    }

    pub fn forget(&self, surface_id: ItemId, host: &str) {
        self.lock().remove(&(surface_id, host.to_string()));
    }

    /// Drop every `(surface_id, *)` runtime, on every host. Called after
    /// `surface_delete`. (An update needs no forget: the next call sees the
    /// new spec in the store and reloads it.)
    pub fn forget_surface(&self, surface_id: ItemId) {
        self.lock().retain(|(id, _), _| *id != surface_id);
    }

    pub fn len(&self) -> usize {
        self.lock().len()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    fn lock(&self) -> MutexGuard<'_, SessionMap> {
        self.sessions
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}

fn lock_set(set: &Mutex<BTreeSet<String>>) -> MutexGuard<'_, BTreeSet<String>> {
    set.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

#[cfg(test)]
mod flatten_tests {
    use super::flatten_payloads;
    use serde_json::json;

    /// The shape a `table`'s `columns` actually name — the S1 golden's rows
    /// are flat, and the live window drew two empty rows until they were.
    #[test]
    fn a_rows_payload_fields_read_at_the_top_of_the_row() {
        let rows = json!([{
            "id": "row-1",
            "created": "2026-09-22T00:00:00Z",
            "payload": {"title": "A dark matter survey", "year": 2024},
        }]);
        let flat = flatten_payloads(rows);
        let row = &flat[0];
        assert_eq!(row["title"], json!("A dark matter survey"));
        assert_eq!(row["year"], json!(2024));
        // The envelope survives: `id` is what a selection publishes.
        assert_eq!(row["id"], json!("row-1"));
        assert_eq!(row["payload"]["title"], json!("A dark matter survey"));
    }

    /// A domain field may not shadow an envelope field. `id` is the one that
    /// matters — publishing a payload's `id` would select the wrong item.
    #[test]
    fn the_envelope_wins_a_name_collision() {
        let rows = json!([{"id": "envelope", "payload": {"id": "domain", "title": "t"}}]);
        let flat = flatten_payloads(rows);
        assert_eq!(flat[0]["id"], json!("envelope"));
        assert_eq!(flat[0]["title"], json!("t"));
    }

    /// Anything that is not an array of objects with an object payload is
    /// returned untouched: a verb source's value passes through this path too.
    #[test]
    fn a_row_without_a_payload_object_is_unchanged() {
        for value in [json!([{"id": "x"}]), json!({"not": "an array"}), json!([7])] {
            assert_eq!(flatten_payloads(value.clone()), value);
        }
    }
}

#[cfg(test)]
mod publish_kind_tests {
    use super::as_layout_kind;

    /// The channel key a pane parameter can actually bind to.
    #[test]
    fn a_schema_ref_becomes_the_manifest_kind_id() {
        assert_eq!(as_layout_kind("imbib/bibliography-entry"), "publication");
        assert_eq!(as_layout_kind("task@1.0.0"), "task");
    }

    #[test]
    fn a_kind_id_passes_through() {
        assert_eq!(as_layout_kind("publication"), "publication");
        assert_eq!(as_layout_kind("collection"), "collection");
    }

    /// A surface may publish a kind this build has never heard of; that is
    /// the surface's business, not something to rewrite or refuse.
    #[test]
    fn an_unknown_kind_is_left_alone() {
        assert_eq!(as_layout_kind("nobody/owns-this"), "nobody/owns-this");
    }
}
