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

use std::collections::HashMap;
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};

use impress_core::item::{ActorKind, ItemId};
use impress_core::pane_query::{Bindings, ItemRef, PaneQueryError, Scope};
use impress_core::sqlite_store::SqliteItemStore;
use impress_core::store::ItemStore;
use impress_layout::{PaneSpec, ViewKindId};
use impress_layout_service::dto::PaneRefDto as LayoutPaneRefDto;
use impress_layout_service::{DefaultLayoutService, LayoutService};
use impress_service_core::McpToolDescriptor;
use impress_surface::{
    plan, reduce, resolve_with_source_errors, CachedSource, Effect, Event, PaneQuery, ParamDecl,
    RenderTree, SourceCache, SourceRequestKind, SurfaceSpec,
};
use serde_json::Value;

use crate::dto::{EffectOutcomeDto, ShowTargetDto, SplitTargetDto};
use crate::store::SurfaceStore;

/// What went wrong, as a sentence — the shape every store-generic
/// `#[impress_service]` crate in the suite uses.
pub type Result<T> = std::result::Result<T, String>;

// ---------------------------------------------------------------------------
// The linked inventory
// ---------------------------------------------------------------------------

/// Run one linked verb by its MCP tool name. See the module docs for why
/// this is a copy of `impress_capabilities::call_async` rather than a
/// dependency on it.
pub(crate) async fn call_verb(name: &str, args: Value) -> Result<Value> {
    let descriptor = McpToolDescriptor::iter()
        .find(|d| d.name == name)
        .ok_or_else(|| format!("Unknown tool: {name}"))?;
    (descriptor.handler)(args)
        .await
        .map_err(|e| format!("{}: {}", descriptor.name, e))
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
    async fn publish(&self, pane: &PaneHandle, kind: &str, ids: Value) -> Result<()>;
    /// Open a query in a pane — composes `layout-service` verbs exactly as
    /// `surface_show` does (see [`show_in_pane`]), so "a surface can drive
    /// the layout tree, not just itself" (`docs/agent-surfaces.md`) is the
    /// same code path either way.
    async fn open(
        &self,
        pane: Option<&PaneHandle>,
        query: Value,
        view_kind: &str,
        target: Option<&str>,
    ) -> Result<()>;
    /// Append an event row and return its assigned `seq`.
    async fn emit(&self, surface: ItemId, host: &str, name: &str, payload: Value) -> Result<u64>;
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
            return Err(format!(
                "Unknown tool: {name} (not in this process's inventory; no verb host installed)"
            ));
        };
        if !host.has_verb(name) {
            return Err(format!(
                "Unknown tool: {name} (not in this process's inventory; host has no such verb)"
            ));
        }
        // Synchronous by design (see `VerbHost`'s docs): run it off this
        // runtime's own worker threads so a slow host call — an HTTP round
        // trip to imbib or imprint — cannot park one.
        let owned_name = name.to_string();
        tokio::task::spawn_blocking(move || host.call_verb(&owned_name, args))
            .await
            .map_err(|e| format!("verb host call to {name}: task panicked: {e}"))?
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
        .map_err(|e: PaneQueryError| e.to_string())?;
        let items = self
            .store
            .query(&compiled.item_query)
            .map_err(|e| format!("run query: {e}"))?;
        let rows = serde_json::to_value(items).map_err(|e| format!("encode query result: {e}"))?;
        Ok(flatten_payloads(rows))
    }

    async fn publish(&self, pane: &PaneHandle, kind: &str, ids: Value) -> Result<()> {
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
                Some("agent".to_string()),
            )
            .await;
        if result.ok {
            Ok(())
        } else {
            Err(result.message)
        }
    }

    async fn open(
        &self,
        pane: Option<&PaneHandle>,
        query: Value,
        view_kind: &str,
        target: Option<&str>,
    ) -> Result<()> {
        let Some(pane) = pane else {
            return Err(
                "this surface instance has no pane yet (surface_show has not run) — nothing to \
                 open a query beside"
                    .to_string(),
            );
        };
        let query: PaneQuery =
            serde_json::from_value(query).map_err(|e| format!("open: query: {e}"))?;
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
            Some("agent".to_string()),
        )
        .await
        .map(|_| ())
    }

    async fn emit(&self, surface: ItemId, host: &str, name: &str, payload: Value) -> Result<u64> {
        self.surfaces
            .append_event(surface, host, name, &payload, ActorKind::Agent)
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
            return Err(r1.message);
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
            return Err(r2.message);
        }
        return Ok((tile, r2.focused == Some(tile), r2.affected_panes));
    }

    if let Some(role) = &target.role {
        let pane_ref = LayoutPaneRefDto::role(role);
        let resolved = layout
            .resolve_reference(app_id.to_string(), device.clone(), pane_ref.clone())
            .await;
        if !resolved.ok {
            return Err(resolved.message);
        }
        let tile = resolved
            .tile
            .ok_or_else(|| format!("role '{role}' does not resolve to a pane"))?;
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
            return Err(r1.message);
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
            return Err(r2.message);
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
        return Err(split.message);
    }
    let tile = split
        .focused
        .ok_or_else(|| "split produced no focused tile".to_string())?;
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

/// One `(surface, host)` instance, live in memory: its spec, its working
/// state, the pane parameters bound to it, and the source cache
/// [`impress_surface::plan`] reads. Also the sole owner of which pane (if
/// any) `surface_show` last put it in.
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
    pub source_errors: std::collections::BTreeMap<String, String>,
    pub pane: Option<PaneHandle>,
}

impl SurfaceRuntime {
    fn new(surface_id: ItemId, host: String, spec: SurfaceSpec, state: Value) -> Self {
        Self {
            surface_id,
            host,
            spec,
            state,
            params: Value::Object(serde_json::Map::new()),
            cache: SourceCache::new(),
            source_errors: std::collections::BTreeMap::new(),
            pane: None,
        }
    }

    /// Fetch every stale/unfetched source (bounded rounds: a chain of N
    /// dependent sources settles in at most N rounds, and a round that
    /// fetches nothing new stops immediately rather than spinning on a
    /// permanently failing verb) and resolve the tree.
    pub async fn render(&mut self, executor: &dyn Executor) -> RenderTree {
        let max_rounds = self.spec.sources.len() + 1;
        for _ in 0..max_rounds {
            let requests = plan(&self.spec, &self.state, &self.params, &self.cache);
            if requests.is_empty() {
                break;
            }
            let mut progressed = false;
            for request in requests {
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
                        self.source_errors.insert(request.name.clone(), why);
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
            if let impress_surface::Source::Value { value } = source {
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

    /// Reduce an event, persist the resulting state, run every effect, and
    /// re-render. Persistence happens here (not in the caller) so a
    /// dispatch that runs zero effects still leaves the state row in sync
    /// with what `reduce` just decided.
    pub async fn dispatch(
        &mut self,
        executor: &dyn Executor,
        surfaces: &SurfaceStore,
        event: &Event,
        actor: ActorKind,
    ) -> Result<(RenderTree, Vec<EffectOutcomeDto>)> {
        let (new_state, effects) =
            reduce(&self.spec, &self.state, &self.params, event).map_err(|e| e.to_string())?;
        self.state = new_state;
        surfaces.set_state(self.surface_id, &self.host, &self.state, actor)?;

        let mut outcomes = Vec::with_capacity(effects.len());
        for effect in effects {
            outcomes.push(self.run_effect(executor, effect).await);
        }
        // A `call` with `into` may have written more state; persist again if
        // anything changed it beyond the reduce step above.
        surfaces.set_state(self.surface_id, &self.host, &self.state, actor)?;

        let tree = self.render(executor).await;
        Ok((tree, outcomes))
    }

    /// The pane this instance is shown in — remembered from `surface_show`
    /// / `bind_pane`, else recovered from the layout once and cached. See
    /// `Executor::pane_showing` for why the lookup exists.
    async fn pane_or_lookup(&mut self, executor: &dyn Executor) -> Option<PaneHandle> {
        if self.pane.is_none() {
            self.pane = executor.pane_showing(self.surface_id).await;
        }
        self.pane.clone()
    }

    async fn run_effect(&mut self, executor: &dyn Executor, effect: Effect) -> EffectOutcomeDto {
        match effect {
            Effect::Call { verb, args, into } => match executor.call_verb(&verb, args).await {
                Ok(value) => {
                    if let Some(path) = &into {
                        if let Err(e) = set_state_path(&mut self.state, path, value) {
                            return EffectOutcomeDto {
                                kind: "call".into(),
                                ok: false,
                                message: e,
                            };
                        }
                    }
                    EffectOutcomeDto {
                        kind: "call".into(),
                        ok: true,
                        message: format!("called {verb}"),
                    }
                }
                Err(e) => EffectOutcomeDto {
                    kind: "call".into(),
                    ok: false,
                    message: e,
                },
            },
            Effect::Publish { ids } => {
                let Some(pane) = self.pane_or_lookup(executor).await else {
                    return EffectOutcomeDto {
                        kind: "publish".into(),
                        ok: false,
                        message: "no pane shows this surface yet (surface_show has not run)".into(),
                    };
                };
                let (kind, ids) = publish_kind_and_ids(&self.spec, ids);
                match executor.publish(&pane, &kind, ids).await {
                    Ok(()) => EffectOutcomeDto {
                        kind: "publish".into(),
                        ok: true,
                        message: format!("published on kind '{kind}'"),
                    },
                    Err(e) => EffectOutcomeDto {
                        kind: "publish".into(),
                        ok: false,
                        message: e,
                    },
                }
            }
            Effect::Emit { name, payload } => {
                match executor
                    .emit(self.surface_id, &self.host, &name, payload)
                    .await
                {
                    Ok(seq) => EffectOutcomeDto {
                        kind: "emit".into(),
                        ok: true,
                        message: format!("emitted '{name}' (seq {seq})"),
                    },
                    Err(e) => EffectOutcomeDto {
                        kind: "emit".into(),
                        ok: false,
                        message: e,
                    },
                }
            }
            Effect::Open {
                query,
                view_kind,
                target,
            } => {
                let pane = self.pane_or_lookup(executor).await;
                match executor
                    .open(pane.as_ref(), query, &view_kind, target.as_deref())
                    .await
                {
                    Ok(()) => EffectOutcomeDto {
                        kind: "open".into(),
                        ok: true,
                        message: format!("opened a '{view_kind}' pane"),
                    },
                    Err(e) => EffectOutcomeDto {
                        kind: "open".into(),
                        ok: false,
                        message: e,
                    },
                }
            }
            Effect::Refresh { source } => {
                self.cache.remove(&source);
                EffectOutcomeDto {
                    kind: "refresh".into(),
                    ok: true,
                    message: format!("'{source}' will re-fetch on next render"),
                }
            }
        }
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
        return Err(format!("`into` path '{path}' must start with 'state.'"));
    }
    let segments: Vec<&str> = parts.collect();
    if segments.is_empty() {
        return Err(format!("`into` path '{path}' must start with 'state.'"));
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

type SessionMap = HashMap<(ItemId, String), SurfaceRuntime>;

/// The process-wide `(surface, host)` runtime table — the same shape
/// `impress-layout-service::SessionRegistry` gives the layout tree.
///
/// Unlike that registry, [`with`](Self::with) is async (loading a surface's
/// spec is a store read, and the caller's closure runs an async executor),
/// so the entry is TAKEN OUT of the map for the duration of the call rather
/// than held under the lock across an `.await` (a `MutexGuard` cannot cross
/// one). Two concurrent calls for the SAME `(surface, host)` therefore do
/// not interleave into a state neither produced — the second finds the key
/// missing and reloads from the store instead of racing the first — at the
/// cost of the second seeing a cold reload rather than the first's
/// in-progress edit. Acceptable for a Tier A crate with no live-app
/// concurrency yet; S6/S7 (the FFI and the Swift host) are the point this
/// gets revisited if it matters there.
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

    /// Run `f` against the runtime for `(surface, host)`, loading the spec
    /// and any persisted state on first touch. See the struct docs for the
    /// take-out-and-put-back locking shape.
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
        let mut runtime = match self.lock().remove(&key) {
            Some(runtime) => runtime,
            None => {
                let row = surfaces
                    .get(surface_id)?
                    .ok_or_else(|| format!("no surface {surface_id}"))?;
                let state = surfaces
                    .get_state(surface_id, host)?
                    .unwrap_or_else(|| row.spec.state.clone());
                SurfaceRuntime::new(surface_id, host.to_string(), row.spec, state)
            }
        };
        let result = f(&mut runtime).await;
        self.lock().insert(key, runtime);
        result
    }

    pub fn forget(&self, surface_id: ItemId, host: &str) {
        self.lock().remove(&(surface_id, host.to_string()));
    }

    /// Drop every `(surface_id, *)` runtime, on every host. Called after
    /// `surface_update`/`surface_delete` so a cached runtime never keeps
    /// serving a spec the store no longer has — the registry has no other
    /// index of "every host this surface is currently live on", so this
    /// scans the (small) live set rather than tracking one.
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
