//! `ImpressSurfaceService` — every ADR-0033 verb, as an `#[impress_method]`, over
//! [`crate::store::SurfaceStore`] and [`crate::runtime::SurfaceRuntime`].
//!
//! Modelled on `impress-layout-service/src/service.rs`: one trait, one
//! method per verb, so MCP, the CLI and impel's agent loop get all fifteen
//! together (ADR-0033 D8's five-verb loop plus the read/state/event half).
//! `host` mirrors `device` there: `None` means *this* device
//! ([`impress_layout_service::resolve_device`]), because ADR-0033 D5's
//! state/event rows are device-scoped exactly like the layout tree's live
//! row.

use std::sync::Arc;

use impress_core::item::{ActorKind, ItemId};
use impress_core::sqlite_store::SqliteItemStore;
use impress_layout_service::{resolve_device, DefaultLayoutService};
use impress_service_core::async_trait;
use impress_service_macros::{impress_service, impress_service_impl};

#[allow(unused_imports)]
use impress_service_macros::impress_method;

use impress_surface::{
    example_paper_triage, example_signal_explorer, validate, Action, Event, Node, NodeKind,
    Problem, Source, SurfaceSpec,
};
use serde_json::Value;

use crate::dto::{
    ShowTargetDto, SourceError, SurfaceDeleteResult, SurfaceDispatchResult, SurfaceEventDto,
    SurfaceEventsResult, SurfaceExamplesResult, SurfaceListResult, SurfaceRenderResult,
    SurfaceResult, SurfaceSchemaResult, SurfaceShowResult, SurfaceStateResult, SurfaceSummaryDto,
    SurfaceValidateResult, SurfaceWaitResult,
};
use crate::runtime::{
    show_in_pane, surface_item_query, verb_exists, DefaultExecutor, SessionRegistry, VerbHost,
};
use crate::store::SurfaceStore;

/// How often `surface_wait` polls the event ring (ADR-0033 D6 gives the app's
/// invalidation feed the same period; this crate has no feed to hook, so it
/// polls the store directly at the same cadence).
const WAIT_POLL_MS: u64 = 250;

/// The longest `surface_wait` holds a call open (AC-F2). Longer than this
/// outlives the request timeout of the MCP clients and HTTP callers in use,
/// which then retry a call that is still running.
pub const MAX_WAIT_MS: u64 = 55_000;

/// Agent surfaces: create/validate/store a [`SurfaceSpec`], show it in a
/// pane, render it headlessly, and drive it — `surface_render` is what an
/// agent calls to inspect its own GUI without a screenshot (ADR-0033 D2).
#[impress_service]
pub trait ImpressSurfaceService: Send + Sync + 'static {
    /// The `SurfaceSpec` JSON Schema plus a worked example, so an agent
    /// authoring in a chat never has to read Rust source to learn the
    /// vocabulary (ADR-0033 D8).
    #[impress_method]
    async fn surface_schema(&self) -> SurfaceSchemaResult;

    /// Every problem with a spec, named by path: `impress-surface`'s pure
    /// checks (version, state shape, paths, template refs, cycles, ids,
    /// per-kind invariants) PLUS one this crate adds — every `verb` a
    /// source or action names must exist in the linked
    /// `#[impress_service]` inventory (ADR-0033 D4).
    #[impress_method]
    async fn surface_validate(&self, spec: SurfaceSpec) -> SurfaceValidateResult;

    /// Store a spec as a new `impress/ui/surface@1.0.0` row. `name` overrides
    /// the row's label (the spec's own `name` is untouched); `tags` are
    /// free-text labels `surface_list` can filter by.
    #[impress_method]
    async fn surface_create(
        &self,
        spec: SurfaceSpec,
        name: Option<String>,
        tags: Option<Vec<String>>,
    ) -> SurfaceResult;

    /// Replace a surface's spec and bump its `revision`. The row's `name` is
    /// kept unless `name` is given. Pass the `revision` you last read as
    /// `expected_revision` to refuse (message starting `conflict:`) instead
    /// of overwriting a change someone else made since.
    #[impress_method]
    async fn surface_update(
        &self,
        id: String,
        spec: SurfaceSpec,
        name: Option<String>,
        expected_revision: Option<u64>,
    ) -> SurfaceResult;

    /// One surface row, spec included.
    #[impress_method]
    async fn surface_get(&self, id: String) -> SurfaceResult;

    /// Every stored surface, oldest first, without their specs (see
    /// `surface_get` for the full document).
    #[impress_method]
    async fn surface_list(&self) -> SurfaceListResult;

    /// Delete a surface and every state/event row that belongs to it.
    #[impress_method]
    async fn surface_delete(&self, id: String) -> SurfaceDeleteResult;

    /// Put a surface in a pane: `target` names a tile, a role, or a fresh
    /// split beside the focused pane. Composes ordinary `layout-service`
    /// verbs (split or resolve the role, `set_query` to `item(id)` of the
    /// `surface` kind, `set_view_kind` to `"surface"`) — a surface pane is
    /// not a special case of the layout tree (ADR-0033 D1).
    #[impress_method]
    async fn surface_show(
        &self,
        id: String,
        target: ShowTargetDto,
        app_id: Option<String>,
        device: Option<String>,
    ) -> SurfaceShowResult;

    /// The resolved render tree for one `(surface, host)` instance — exactly
    /// what a renderer would turn into pixels, so an agent inspects its own
    /// GUI headlessly (ADR-0033 D2). Runs every stale source through the
    /// linked inventory / the store first.
    #[impress_method]
    async fn surface_render(&self, id: String, host: Option<String>) -> SurfaceRenderResult;

    /// The working state of one `(surface, host)` instance — the spec's own
    /// initial `state` block if nothing has been dispatched to it yet.
    #[impress_method]
    async fn surface_state_get(&self, id: String, host: Option<String>) -> SurfaceStateResult;

    /// Overwrite the working state of one `(surface, host)` instance
    /// directly (bypassing `reduce` — for a host seeding a surface's state
    /// before first render, not for an ordinary field edit, which goes
    /// through `surface_dispatch`).
    #[impress_method]
    async fn surface_state_set(
        &self,
        id: String,
        state: Value,
        host: Option<String>,
    ) -> SurfaceStateResult;

    /// Reduce one renderer event, persist the resulting state, run every
    /// effect it produced, and re-render. This is the loop's "the human did
    /// something" step.
    #[impress_method]
    async fn surface_dispatch(
        &self,
        id: String,
        event: Event,
        host: Option<String>,
    ) -> SurfaceDispatchResult;

    /// A page of `(surface, host)`'s emitted events with `seq > after_seq`.
    #[impress_method]
    async fn surface_events(
        &self,
        id: String,
        after_seq: u64,
        host: Option<String>,
    ) -> SurfaceEventsResult;

    /// Long-poll for the next event past `after_seq`, up to `timeout_ms`
    /// (at most 55000). Returns as soon as one lands, or on timeout with
    /// `timed_out: true` and no events — the primitive the five-verb loop
    /// calls "wait" (ADR-0033 D5/D6).
    #[impress_method]
    async fn surface_wait(
        &self,
        id: String,
        after_seq: u64,
        timeout_ms: u64,
        host: Option<String>,
    ) -> SurfaceWaitResult;

    /// Every worked example this build ships — the signal explorer from
    /// `docs/plan-agent-surfaces.md` (S1) first, then the paper-triage
    /// surface over the user's own unread papers (wave 5 V3) — so an agent
    /// can start from a spec that already validates rather than the blank
    /// vocabulary.
    #[impress_method]
    async fn surface_examples(&self) -> SurfaceExamplesResult;
}

// ---------------------------------------------------------------------------
// Implementation
// ---------------------------------------------------------------------------

/// Store-backed `ImpressSurfaceService`. `new()` uses the process-wide store and
/// session registry, matching `impress-layout-service::DefaultLayoutService`;
/// `with_store` gives hermetic tests their own of each.
#[derive(Clone, Default)]
pub struct DefaultImpressSurfaceService {
    store: Option<Arc<SqliteItemStore>>,
    sessions: Option<Arc<SessionRegistry>>,
    /// See [`crate::runtime::VerbHost`]. Threaded into every [`DefaultExecutor`]
    /// this service builds ([`Self::executor`]) and consulted directly by
    /// [`Self::surface_validate`], so a spec naming a host-only verb both
    /// runs and validates clean once a host is installed.
    verb_host: Option<Arc<dyn VerbHost>>,
}

impl DefaultImpressSurfaceService {
    pub fn new() -> Self {
        Self {
            store: None,
            sessions: None,
            verb_host: None,
        }
    }

    pub fn with_store(store: Arc<SqliteItemStore>) -> Self {
        Self {
            store: Some(store),
            sessions: Some(Arc::new(SessionRegistry::new())),
            verb_host: None,
        }
    }

    /// An instance over `store` whose runtimes live in `sessions` — the one
    /// registry every other caller on that store in this process uses
    /// (RS-S1). `impress-store-ffi` builds its service this way.
    pub fn with_store_and_sessions(
        store: Arc<SqliteItemStore>,
        sessions: Arc<SessionRegistry>,
    ) -> Self {
        Self {
            store: Some(store),
            sessions: Some(sessions),
            verb_host: None,
        }
    }

    /// Install a [`VerbHost`] — builder style, matching
    /// [`DefaultExecutor::with_verb_host`].
    pub fn with_verb_host(mut self, host: Arc<dyn VerbHost>) -> Self {
        self.verb_host = Some(host);
        self
    }

    fn store_arc(&self) -> Arc<SqliteItemStore> {
        self.store
            .clone()
            .unwrap_or_else(impress_store_service::store_instance)
    }

    fn surfaces(&self) -> SurfaceStore {
        SurfaceStore::new(self.store_arc())
    }

    fn registry(&self) -> Arc<SessionRegistry> {
        self.sessions
            .clone()
            .unwrap_or_else(SessionRegistry::shared)
    }

    fn executor(&self) -> DefaultExecutor {
        let executor = match &self.store {
            Some(s) => DefaultExecutor::with_store(s.clone()),
            None => DefaultExecutor::new(self.store_arc()),
        };
        match &self.verb_host {
            Some(host) => executor.with_verb_host(host.clone()),
            None => executor,
        }
    }

    fn layout(&self) -> DefaultLayoutService {
        match &self.store {
            Some(s) => DefaultLayoutService::with_store(s.clone()),
            None => DefaultLayoutService::new(),
        }
    }
}

fn parse_id(id: &str) -> std::result::Result<ItemId, String> {
    id.trim()
        .parse::<ItemId>()
        .map_err(|_| format!("'{id}' is not a surface id"))
}

/// Every `verb` a spec's sources or actions name, paired with the JSON
/// pointer-flavoured path `surface_validate`/`impress-surface::validate`
/// already uses for its own problems — so a missing verb reads exactly like
/// every other validation finding.
fn verb_refs(spec: &SurfaceSpec) -> Vec<(String, String)> {
    let mut out = Vec::new();
    for (name, source) in &spec.sources {
        if let Source::Verb { verb, .. } = source {
            out.push((format!("/sources/{name}/verb"), verb.clone()));
        }
    }
    walk_node_verbs(&spec.root, "/root".to_string(), &mut out);
    out
}

fn walk_node_verbs(node: &Node, at: String, out: &mut Vec<(String, String)>) {
    collect_action_verbs(&node.on_change, &format!("{at}/on_change"), out);
    collect_action_verbs(&node.on_submit, &format!("{at}/on_submit"), out);
    match &node.kind {
        NodeKind::Column(items) => {
            for (i, child) in items.iter().enumerate() {
                walk_node_verbs(child, format!("{at}/column/{i}"), out);
            }
        }
        NodeKind::Row(items) => {
            for (i, child) in items.iter().enumerate() {
                walk_node_verbs(child, format!("{at}/row/{i}"), out);
            }
        }
        NodeKind::Grid(g) => {
            for (i, child) in g.items.iter().enumerate() {
                walk_node_verbs(child, format!("{at}/grid/items/{i}"), out);
            }
        }
        NodeKind::Section(s) => {
            walk_node_verbs(&s.body, format!("{at}/section/body"), out);
        }
        NodeKind::Tabs(tabs) => {
            for (i, tab) in tabs.iter().enumerate() {
                walk_node_verbs(&tab.body, format!("{at}/tabs/{i}/body"), out);
            }
        }
        NodeKind::Table(t) => {
            collect_action_verbs(&t.on_select, &format!("{at}/table/on_select"), out);
        }
        NodeKind::List(l) => {
            collect_action_verbs(&l.on_select, &format!("{at}/list/on_select"), out);
        }
        NodeKind::Button(b) => {
            collect_action_verbs(&b.on_click, &format!("{at}/button/on_click"), out);
        }
        _ => {}
    }
}

fn collect_action_verbs(actions: &[Action], at: &str, out: &mut Vec<(String, String)>) {
    for (i, action) in actions.iter().enumerate() {
        if let Action::Call { verb, .. } = action {
            out.push((format!("{at}/{i}/call/verb"), verb.clone()));
        }
    }
}

#[async_trait::async_trait]
impl ImpressSurfaceService for DefaultImpressSurfaceService {
    async fn surface_schema(&self) -> SurfaceSchemaResult {
        SurfaceSchemaResult {
            schema: serde_json::to_value(schemars::schema_for!(SurfaceSpec)).unwrap_or(Value::Null),
            example: example_signal_explorer(),
        }
    }

    async fn surface_validate(&self, spec: SurfaceSpec) -> SurfaceValidateResult {
        let mut problems = validate(&spec);
        for (path, verb) in verb_refs(&spec) {
            // A verb this process did not link but a host (ADR-0033 D4,
            // amended 2026-09-23) answers for is not a problem — it will
            // run through `DefaultExecutor::call_verb` exactly as a linked
            // one does.
            let known = verb_exists(&verb)
                || self
                    .verb_host
                    .as_ref()
                    .is_some_and(|host| host.has_verb(&verb));
            if !known {
                problems.push(Problem {
                    path,
                    message: format!("no such verb: {verb}"),
                });
            }
        }
        SurfaceValidateResult { problems }
    }

    async fn surface_create(
        &self,
        spec: SurfaceSpec,
        name: Option<String>,
        tags: Option<Vec<String>>,
    ) -> SurfaceResult {
        let tags = tags.unwrap_or_default();
        match self
            .surfaces()
            .create(&spec, name.as_deref(), &tags, ActorKind::Agent)
        {
            Ok(row) => SurfaceResult::from_row(&row),
            Err(e) => SurfaceResult::failed(e),
        }
    }

    async fn surface_update(
        &self,
        id: String,
        spec: SurfaceSpec,
        name: Option<String>,
        expected_revision: Option<u64>,
    ) -> SurfaceResult {
        let surface_id = match parse_id(&id) {
            Ok(id) => id,
            Err(e) => return SurfaceResult::failed(e),
        };
        // No registry forget: every runtime, in this process or another,
        // compares the stored spec on its next call and reloads it (RS-S1).
        match self.surfaces().update(
            surface_id,
            &spec,
            name.as_deref(),
            expected_revision,
            ActorKind::Agent,
        ) {
            Ok(row) => SurfaceResult::from_row(&row),
            Err(e) => SurfaceResult::failed(e),
        }
    }

    async fn surface_get(&self, id: String) -> SurfaceResult {
        let surface_id = match parse_id(&id) {
            Ok(id) => id,
            Err(e) => return SurfaceResult::failed(e),
        };
        match self.surfaces().get(surface_id) {
            Ok(Some(row)) => SurfaceResult::from_row(&row),
            Ok(None) => SurfaceResult::failed(format!("no surface {id}")),
            Err(e) => SurfaceResult::failed(e),
        }
    }

    async fn surface_list(&self) -> SurfaceListResult {
        match self.surfaces().list() {
            Ok(rows) => SurfaceListResult {
                ok: true,
                message: format!("{} surface(s)", rows.len()),
                surfaces: rows.iter().map(SurfaceSummaryDto::from).collect(),
            },
            Err(e) => SurfaceListResult {
                ok: false,
                message: e,
                surfaces: Vec::new(),
            },
        }
    }

    async fn surface_delete(&self, id: String) -> SurfaceDeleteResult {
        let surface_id = match parse_id(&id) {
            Ok(id) => id,
            Err(e) => {
                return SurfaceDeleteResult {
                    ok: false,
                    message: e,
                }
            }
        };
        match self.surfaces().delete(surface_id) {
            Ok(true) => {
                self.registry().forget_surface(surface_id);
                SurfaceDeleteResult {
                    ok: true,
                    message: format!("deleted surface {id}"),
                }
            }
            Ok(false) => SurfaceDeleteResult {
                ok: false,
                message: format!("no surface {id}"),
            },
            Err(e) => SurfaceDeleteResult {
                ok: false,
                message: e,
            },
        }
    }

    async fn surface_show(
        &self,
        id: String,
        target: ShowTargetDto,
        app_id: Option<String>,
        device: Option<String>,
    ) -> SurfaceShowResult {
        let surface_id = match parse_id(&id) {
            Ok(id) => id,
            Err(e) => return SurfaceShowResult::failed(e),
        };
        if let Ok(None) | Err(_) = self.surfaces().get(surface_id) {
            return SurfaceShowResult::failed(format!("no surface {id}"));
        }
        // ADR-0033 leaves which app a surface belongs to unspecified (a
        // surface has no app of its own the way a layout preset does) — see
        // this crate's report. `"impress"` is the neutral, appless scope the
        // root CLAUDE.md already gives the shell.
        let app_id = app_id
            .filter(|a| !a.trim().is_empty())
            .unwrap_or_else(|| "impress".to_string());
        let device = resolve_device(device.as_deref());
        let layout = self.layout();
        let query = surface_item_query(surface_id);

        match show_in_pane(
            &layout,
            &app_id,
            Some(device.clone()),
            query,
            "surface",
            &target,
            Some("agent".to_string()),
        )
        .await
        {
            Ok((tile, focused, affected)) => {
                // `host` defaults to the device (ADR-0033: "host = the
                // layout device id unless a caller passes one"), so the
                // instance `surface_render`/`surface_dispatch` reach with no
                // `host` argument is the one this call just showed.
                let registry = self.registry();
                let surfaces = self.surfaces();
                let pane = crate::runtime::PaneHandle {
                    app_id: app_id.clone(),
                    device: device.clone(),
                    tile,
                };
                let _ = registry
                    .with(&surfaces, surface_id, &device, move |runtime| {
                        runtime.pane = Some(pane.clone());
                        Box::pin(async move { Ok::<(), String>(()) })
                    })
                    .await;
                SurfaceShowResult {
                    ok: true,
                    message: format!("surface shown in tile {tile}"),
                    tile: Some(tile),
                    focused,
                    affected_panes: affected,
                }
            }
            Err(e) => SurfaceShowResult::failed(e),
        }
    }

    async fn surface_render(&self, id: String, host: Option<String>) -> SurfaceRenderResult {
        let surface_id = match parse_id(&id) {
            Ok(id) => id,
            Err(e) => return SurfaceRenderResult::failed(e),
        };
        let host = resolve_device(host.as_deref());
        let surfaces = self.surfaces();
        let registry = self.registry();
        let me = self.clone();
        let outcome = registry
            .with(&surfaces, surface_id, &host, move |runtime| {
                let me = me.clone();
                Box::pin(async move {
                    let executor = me.executor();
                    let tree = runtime.render(&executor).await;
                    let errors: Vec<SourceError> = runtime
                        .source_errors
                        .iter()
                        .map(|(name, message)| SourceError {
                            name: name.clone(),
                            message: message.clone(),
                        })
                        .collect();
                    Ok((tree, errors))
                })
            })
            .await;
        match outcome {
            Ok((tree, source_errors)) => SurfaceRenderResult {
                ok: true,
                message: "rendered".to_string(),
                tree: Some(tree),
                source_errors,
            },
            Err(e) => SurfaceRenderResult::failed(e),
        }
    }

    async fn surface_state_get(&self, id: String, host: Option<String>) -> SurfaceStateResult {
        let surface_id = match parse_id(&id) {
            Ok(id) => id,
            Err(e) => return SurfaceStateResult::failed(e),
        };
        let host = resolve_device(host.as_deref());
        let surfaces = self.surfaces();
        match surfaces.get_state(surface_id, &host) {
            Ok(Some(state)) => SurfaceStateResult {
                ok: true,
                message: "state".to_string(),
                state: Some(state),
            },
            Ok(None) => match surfaces.get(surface_id) {
                Ok(Some(row)) => SurfaceStateResult {
                    ok: true,
                    message: "no dispatch yet — the spec's own initial state".to_string(),
                    state: Some(row.spec.state),
                },
                Ok(None) => SurfaceStateResult::failed(format!("no surface {id}")),
                Err(e) => SurfaceStateResult::failed(e),
            },
            Err(e) => SurfaceStateResult::failed(e),
        }
    }

    async fn surface_state_set(
        &self,
        id: String,
        state: Value,
        host: Option<String>,
    ) -> SurfaceStateResult {
        let surface_id = match parse_id(&id) {
            Ok(id) => id,
            Err(e) => return SurfaceStateResult::failed(e),
        };
        let host = resolve_device(host.as_deref());
        let surfaces = self.surfaces();
        let written = state.clone();
        let writer = surfaces.clone();
        // Through the registry, so a dispatch already running on this
        // instance finishes first and this write is not overwritten by its
        // stale copy of the state.
        let outcome = self
            .registry()
            .with(&surfaces, surface_id, &host, move |runtime| {
                Box::pin(async move { runtime.set_state(&writer, written, ActorKind::Agent) })
            })
            .await;
        match outcome {
            Ok(()) => SurfaceStateResult {
                ok: true,
                message: "state set".to_string(),
                state: Some(state),
            },
            Err(e) if e.starts_with("no surface") => {
                SurfaceStateResult::failed(format!("no surface {id}"))
            }
            Err(e) => SurfaceStateResult::failed(e),
        }
    }

    async fn surface_dispatch(
        &self,
        id: String,
        event: Event,
        host: Option<String>,
    ) -> SurfaceDispatchResult {
        let surface_id = match parse_id(&id) {
            Ok(id) => id,
            Err(e) => return SurfaceDispatchResult::failed(e),
        };
        let host = resolve_device(host.as_deref());
        let surfaces = self.surfaces();
        let registry = self.registry();
        let me = self.clone();
        let outcome = registry
            .with(&surfaces, surface_id, &host, move |runtime| {
                let me = me.clone();
                let event = event.clone();
                Box::pin(async move {
                    let executor = me.executor();
                    let surfaces = me.surfaces();
                    runtime
                        .dispatch(&executor, &surfaces, &event, ActorKind::Agent)
                        .await
                })
            })
            .await;
        match outcome {
            Ok((tree, effects)) => SurfaceDispatchResult {
                ok: true,
                message: format!("dispatched; {} effect(s)", effects.len()),
                tree: Some(tree),
                effects,
            },
            Err(e) => SurfaceDispatchResult::failed(e),
        }
    }

    async fn surface_events(
        &self,
        id: String,
        after_seq: u64,
        host: Option<String>,
    ) -> SurfaceEventsResult {
        let surface_id = match parse_id(&id) {
            Ok(id) => id,
            Err(e) => return SurfaceEventsResult::failed(e),
        };
        let host = resolve_device(host.as_deref());
        let surfaces = self.surfaces();
        if !matches!(surfaces.get(surface_id), Ok(Some(_))) {
            return SurfaceEventsResult::failed(format!("no surface {id}"));
        }
        match surfaces.events_after(surface_id, &host, after_seq, 0) {
            Ok(rows) => {
                let (next_seq, gap) = cursor_after(&rows, after_seq);
                SurfaceEventsResult {
                    ok: true,
                    message: events_message(rows.len(), gap),
                    events: rows.iter().map(SurfaceEventDto::from).collect(),
                    next_seq,
                    gap,
                }
            }
            Err(e) => SurfaceEventsResult::failed(e),
        }
    }

    async fn surface_wait(
        &self,
        id: String,
        after_seq: u64,
        timeout_ms: u64,
        host: Option<String>,
    ) -> SurfaceWaitResult {
        let surface_id = match parse_id(&id) {
            Ok(id) => id,
            Err(e) => return SurfaceWaitResult::failed(e),
        };
        let host = resolve_device(host.as_deref());
        let surfaces = self.surfaces();
        if !matches!(surfaces.get(surface_id), Ok(Some(_))) {
            return SurfaceWaitResult::failed(format!("no surface {id}"));
        }

        let deadline = std::time::Instant::now()
            + std::time::Duration::from_millis(timeout_ms.min(MAX_WAIT_MS));
        loop {
            match surfaces.events_after(surface_id, &host, after_seq, 0) {
                Ok(rows) if !rows.is_empty() => {
                    let (next_seq, gap) = cursor_after(&rows, after_seq);
                    return SurfaceWaitResult {
                        ok: true,
                        message: events_message(rows.len(), gap),
                        events: rows.iter().map(SurfaceEventDto::from).collect(),
                        next_seq,
                        timed_out: false,
                        gap,
                    };
                }
                Ok(_) => {}
                Err(e) => return SurfaceWaitResult::failed(e),
            }
            if std::time::Instant::now() >= deadline {
                // Nothing past the cursor: the cursor stands. Never a second
                // read for it — an event landing between two reads would be
                // counted and never returned (AC-F2).
                return SurfaceWaitResult {
                    ok: true,
                    message: "timed out; nothing new".to_string(),
                    events: Vec::new(),
                    next_seq: after_seq,
                    timed_out: true,
                    gap: false,
                };
            }
            tokio::time::sleep(std::time::Duration::from_millis(WAIT_POLL_MS)).await;
        }
    }

    async fn surface_examples(&self) -> SurfaceExamplesResult {
        // Signal explorer first (S1's worked example, what `surface_schema`
        // also hands an authoring agent) — paper triage second (wave 5 V3,
        // `docs/agent-surfaces.md`'s second worked example).
        SurfaceExamplesResult {
            examples: vec![example_signal_explorer(), example_paper_triage()],
        }
    }
}

/// The cursor to hand back after reading `rows` past `after_seq`, and whether
/// the ring was pruned past the caller's cursor (events between it and the
/// first row returned are gone). Taken from the rows read — never from a
/// second read, which could count an event it did not return (AC-F2). `seq`
/// is gap-free (`SurfaceStore::append_event`), so a jump is pruning.
pub fn cursor_after(rows: &[crate::store::EventRow], after_seq: u64) -> (u64, bool) {
    match (rows.first(), rows.last()) {
        (Some(first), Some(last)) => (last.seq, after_seq > 0 && first.seq > after_seq + 1),
        _ => (after_seq, false),
    }
}

fn events_message(count: usize, gap: bool) -> String {
    if gap {
        format!("{count} event(s); older events past your cursor were pruned from the ring")
    } else {
        format!("{count} event(s)")
    }
}

fn impress_surface_service_instance() -> Arc<dyn ImpressSurfaceService> {
    Arc::new(DefaultImpressSurfaceService::new())
}

impress_service_impl! {
    service = ImpressSurfaceService,
    impl = DefaultImpressSurfaceService,
    instance = || impress_surface_service_instance(),
    methods = [
        surface_schema() -> SurfaceSchemaResult,
        surface_validate(spec: SurfaceSpec) -> SurfaceValidateResult,
        surface_create(
            spec: SurfaceSpec,
            name: Option<String>,
            tags: Option<Vec<String>>
        ) -> SurfaceResult,
        surface_update(
            id: String,
            spec: SurfaceSpec,
            name: Option<String>,
            expected_revision: Option<u64>
        ) -> SurfaceResult,
        surface_get(id: String) -> SurfaceResult,
        surface_list() -> SurfaceListResult,
        surface_delete(id: String) -> SurfaceDeleteResult,
        surface_show(
            id: String,
            target: ShowTargetDto,
            app_id: Option<String>,
            device: Option<String>
        ) -> SurfaceShowResult,
        surface_render(id: String, host: Option<String>) -> SurfaceRenderResult,
        surface_state_get(id: String, host: Option<String>) -> SurfaceStateResult,
        surface_state_set(
            id: String,
            state: Value,
            host: Option<String>
        ) -> SurfaceStateResult,
        surface_dispatch(
            id: String,
            event: Event,
            host: Option<String>
        ) -> SurfaceDispatchResult,
        surface_events(
            id: String,
            after_seq: u64,
            host: Option<String>
        ) -> SurfaceEventsResult,
        surface_wait(
            id: String,
            after_seq: u64,
            timeout_ms: u64,
            host: Option<String>
        ) -> SurfaceWaitResult,
        surface_examples() -> SurfaceExamplesResult,
    ],
}
