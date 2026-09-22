//! `SharedSurface`: the UniFFI surface Swift renders and drives an ADR-0033
//! agent surface through (work package S6 of `docs/plan-agent-surfaces.md`).
//!
//! # What crosses the boundary
//!
//! Modelled on [`crate::layout::SharedLayout`] (same file's module docs cover
//! the shared reasoning in full; this header only notes what differs):
//!
//! * A surface's document is never mirrored as UniFFI records — [`Self::spec`]
//!   hands back `serde_json::to_string(&impress_surface::SurfaceSpec)`
//!   verbatim, and [`Self::render`] the same for the resolved
//!   `impress_surface::RenderTree`, for the reason `layout.rs` gives for
//!   `layout_json`: the value is recursive, and a second Swift-side
//!   definition of the same tree just drifts.
//! * Every verb runs in Rust, through [`impress_surface_service::runtime`]'s
//!   [`impress_surface_service::SurfaceRuntime`] — never "an effect the host
//!   must carry out". `publish`/`open` compose ordinary `layout-service`
//!   verbs the same way `surface_show` does (ADR-0033 D2/D4); this object
//!   never hands Swift a to-do list.
//! * [`Self::dispatch`]'s JSON is exactly
//!   [`impress_surface_service::dto::SurfaceDispatchResult`]'s shape, so
//!   Swift, the CLI and MCP all read one document for "what happened".
//!
//! # Which pane a surface instance is "in"
//!
//! [`impress_surface_service::runtime::SurfaceRuntime::pane`] is what
//! `publish`/`open` effects need and is normally set by `surface_show` (a
//! `layout-service` composition this object does not re-implement — see
//! `docs/agent-surfaces.md`'s "5. surface-show", driven from Swift through
//! [`crate::layout::SharedLayout`] directly, or from a chat over MCP).
//! [`Self::render`]/[`Self::dispatch`] additionally accept an optional
//! `pane`: when given, it is recorded on the SAME [`PaneHandle`] shape
//! `surface_show` would have set — `app_id` "impress" (ADR-0033 leaves which
//! app a surface belongs to unspecified; `impress-surface-service::service`
//! already gives it this neutral, appless scope), `device` this object's
//! `host` — so a pane the Swift chassis already knows about (from its own
//! `SharedLayout` snapshot) can tell a surface instance which tile shows it
//! without a second `surface_show` round trip.
//!
//! # `host`
//!
//! One `SharedSurface` is opened per store, not per host: `host` is passed
//! per call (mirroring every `impress-surface-service` verb's own `host:
//! Option<String>`), defaulting to [`Self::host`] — resolved once at
//! [`Self::open`] with the exact rule `SharedLayout`'s `device` uses
//! ([`impress_layout_service::resolve_device`]), so a surface instance and
//! the layout tree on the same machine agree on which device they are.
//!
//! # Liveness (ADR-0033 D6)
//!
//! [`Self::subscribe`] starts one background thread, built from the same
//! [`crate::ui_feed`] pieces `SharedLayout`'s feed uses — see that module's
//! docs for why the mechanism is shared but each object keeps its own
//! thread. It watches `impress/ui/surface*` rows (the surface document
//! itself, its per-host state, and its event ring) rather than the layout
//! tree, in-process and across a second `SqliteItemStore` handle on the same
//! file (another process, e.g. `impress-mcp`) alike, and reports which
//! SURFACE ids changed — resolved from a `surface-state`/`surface-event`
//! row's own `surface` field when the mutated row is one of those, since the
//! row's own id is not the surface's id there.

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use impress_core::event::StoreMutation;
use impress_core::item::{ActorKind, ItemId, Value as ItemValue};
use impress_core::schemas::{
    SURFACE_EVENT_SCHEMA_REF, SURFACE_SCHEMA_REF, SURFACE_STATE_SCHEMA_REF,
};
use impress_core::sqlite_store::SqliteItemStore;
use impress_core::store::ItemStore;
use impress_layout_service::resolve_device;

use impress_surface::{Event, SurfaceSpec};
use impress_surface_service::dto::{SurfaceDispatchResult, SurfaceEventDto, SurfaceSummaryDto};
use impress_surface_service::{
    DefaultExecutor, DefaultImpressSurfaceService, ImpressSurfaceService, PaneHandle,
    SessionRegistry, SurfaceStore,
};

use crate::ui_feed::{self, ExternalPoll, Feed};
use crate::SharedStore;

/// The neutral, appless scope `impress-surface-service::service::surface_show`
/// gives a surface pane when no `app_id` is provided (ADR-0033 leaves which
/// app a surface belongs to unspecified). Used here so a `pane` argument to
/// [`SharedSurface::render`]/[`SharedSurface::dispatch`] resolves to the SAME
/// [`PaneHandle`] `surface_show` would already have set for this instance.
const APP_ID: &str = "impress";

/// Schema-ref prefix this object's own feed watches — narrower than
/// [`crate::ui_feed::EXTERNAL_UI_PREFIX`] (`layout.rs`'s feed also watches
/// `impress/ui/layout`/`impress/ui/preset`), since a surface's listener only
/// ever cares about its own three record kinds.
const SURFACE_UI_PREFIX: &str = "impress/ui/surface";

// ─── Runtime ─────────────────────────────────────────────────────────────

/// One runtime for every surface call in the process — the same shape
/// [`crate::layout`]'s `runtime()` establishes, kept separate rather than
/// shared because the two FFI objects are independent and neither should
/// block on the other's in-flight work.
fn runtime() -> &'static tokio::runtime::Runtime {
    static RUNTIME: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
    RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .thread_name("impress-surface-ffi")
            .enable_all()
            .build()
            .expect("build the impress-surface FFI runtime")
    })
}

// ─── Errors ──────────────────────────────────────────────────────────────

#[cfg_attr(feature = "native", derive(uniffi::Error))]
#[derive(Debug, Clone, thiserror::Error)]
pub enum SharedSurfaceError {
    /// A verb was refused by the store, the runtime, or the linked
    /// inventory: no such surface, a `reduce` error, a store write that
    /// failed.
    #[error("{message}")]
    Surface { message: String },
    /// A JSON argument or result would not parse.
    #[error("{message}")]
    Json { message: String },
}

impl SharedSurfaceError {
    fn surface(message: impl std::fmt::Display) -> Self {
        SharedSurfaceError::Surface {
            message: message.to_string(),
        }
    }

    fn json(message: impl std::fmt::Display) -> Self {
        SharedSurfaceError::Json {
            message: message.to_string(),
        }
    }
}

type Result<T> = std::result::Result<T, SharedSurfaceError>;

fn parse_surface_id(id: &str) -> Result<ItemId> {
    id.trim()
        .parse::<ItemId>()
        .map_err(|_| SharedSurfaceError::Surface {
            message: format!("'{id}' is not a surface id"),
        })
}

// ─── Records ─────────────────────────────────────────────────────────────

/// One surface row, for a picker or a pane's title — never the spec (see
/// [`SharedSurface::spec`] for the full document).
#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct SharedSurfaceRow {
    pub id: String,
    pub name: String,
    pub version: Option<String>,
    pub tags: Vec<String>,
}

/// [`SharedSurface::surface_http`]'s answer: enough for the Swift automation
/// router to hand straight to its own HTTP response type.
#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct SharedHttpReply {
    pub status: u16,
    pub body: String,
}

fn reply(status: u16, body: String) -> SharedHttpReply {
    SharedHttpReply { status, body }
}

fn error_reply(status: u16, message: impl Into<String>) -> SharedHttpReply {
    reply(
        status,
        serde_json::json!({ "error": message.into() }).to_string(),
    )
}

fn json_reply(status: u16, value: impl serde::Serialize) -> SharedHttpReply {
    match serde_json::to_string(&value) {
        Ok(body) => reply(status, body),
        Err(e) => error_reply(500, format!("encode response: {e}")),
    }
}

/// `"no surface …"` (the message every `SurfaceStore`/`SessionRegistry`
/// not-found path spells, copied verbatim rather than reinvented — see
/// `impress-surface-service/src/store.rs`) is a 404; anything else is a 400.
/// Not exhaustive by construction — a store-level failure not shaped like
/// "no surface" reads as a bad request rather than a 500, which is the
/// right default for an FFI boundary that has no independent way to tell
/// "the caller's fault" from "ours".
fn status_for(message: &str) -> u16 {
    if message.starts_with("no surface") {
        404
    } else {
        400
    }
}

// ─── The invalidation listener ───────────────────────────────────────────

/// What Swift implements to be told a surface changed — its spec, its state,
/// or its event ring. Arrives on the feed's own thread; hop to the main
/// actor before touching a view (same rule `SharedLayoutListener` documents).
#[cfg_attr(feature = "native", uniffi::export(callback_interface))]
pub trait SharedSurfaceListener: Send + Sync {
    /// Deduplicated surface ids (as strings) that changed since the last
    /// delivery, coalesced over the debounce window.
    fn surfaces_changed(&self, ids: Vec<String>);
}

// ─── The object ──────────────────────────────────────────────────────────

/// One store's worth of agent surfaces, bound to an open [`SharedStore`] and
/// a resolved `host`.
///
/// Construct it once per app launch and keep it: like `SharedLayout`, it
/// holds the session registry where each `(surface, host)` instance's live
/// state and source cache live for the duration of this sitting.
#[cfg_attr(feature = "native", derive(uniffi::Object))]
pub struct SharedSurface {
    store: Arc<SqliteItemStore>,
    surfaces: SurfaceStore,
    executor: DefaultExecutor,
    service: DefaultImpressSurfaceService,
    registry: Arc<SessionRegistry>,
    host: String,
    debounce_ms: AtomicU64,
    startup_grace_secs: AtomicU64,
    external_poll_ms: AtomicU64,
    feed: Mutex<Option<Feed>>,
}

#[cfg_attr(feature = "native", uniffi::export)]
impl SharedSurface {
    /// Bind to the surfaces of the given `store`. `host` defaults to the
    /// layout device id when empty — see the module docs.
    #[cfg_attr(feature = "native", uniffi::constructor)]
    pub fn open(store: Arc<SharedStore>, host: String) -> Arc<Self> {
        let core = store.core();
        let host = resolve_device(Some(host.trim()).filter(|h| !h.is_empty()));
        Arc::new(SharedSurface {
            surfaces: SurfaceStore::new(core.clone()),
            executor: DefaultExecutor::with_store(core.clone()),
            service: DefaultImpressSurfaceService::with_store(core.clone()),
            registry: Arc::new(SessionRegistry::new()),
            store: core,
            host,
            debounce_ms: AtomicU64::new(ui_feed::DEFAULT_DEBOUNCE_MS),
            startup_grace_secs: AtomicU64::new(0),
            external_poll_ms: AtomicU64::new(ui_feed::EXTERNAL_POLL_MS),
            feed: Mutex::new(None),
        })
    }

    /// This object's resolved host/device tag.
    pub fn host(&self) -> String {
        self.host.clone()
    }

    /// See `SharedLayout::set_debounce_ms`. Set before subscribing.
    pub fn set_debounce_ms(&self, millis: u32) {
        self.debounce_ms
            .store(millis.max(1) as u64, Ordering::SeqCst);
    }

    /// See `SharedLayout::set_external_poll_ms`. Set before subscribing.
    pub fn set_external_poll_ms(&self, millis: u32) {
        self.external_poll_ms
            .store(millis.max(1) as u64, Ordering::SeqCst);
    }

    /// See `SharedLayout::set_startup_grace_secs`. Set before subscribing.
    pub fn set_startup_grace_secs(&self, secs: u32) {
        self.startup_grace_secs.store(secs as u64, Ordering::SeqCst);
    }

    // ------------------------------------------------------------- reading

    /// The stored spec JSON of one surface — `serde_json::to_string(&SurfaceSpec)`.
    pub fn spec(&self, surface_id: String) -> Result<String> {
        let id = parse_surface_id(&surface_id)?;
        let row = self
            .surfaces
            .get(id)
            .map_err(SharedSurfaceError::surface)?
            .ok_or_else(|| SharedSurfaceError::surface(format!("no surface {surface_id}")))?;
        serde_json::to_string(&row.spec).map_err(SharedSurfaceError::json)
    }

    /// Every stored surface, for a pane's title or a picker.
    pub fn list(&self) -> Result<Vec<SharedSurfaceRow>> {
        let rows = self.surfaces.list().map_err(SharedSurfaceError::surface)?;
        Ok(rows
            .into_iter()
            .map(|r| SharedSurfaceRow {
                id: r.id.to_string(),
                name: r.name,
                version: r.version,
                tags: r.tags,
            })
            .collect())
    }

    /// The resolved render tree for `(surface_id, this object's host)` —
    /// exactly what a renderer turns into pixels, as JSON
    /// (`serde_json::to_string(&RenderTree)`). Runs every stale source
    /// through the linked inventory / the store first. When `pane` is given,
    /// records it as this instance's [`PaneHandle`] first (see the module
    /// docs) — so a `publish`/`open` action the render loop had queued from
    /// an EARLIER dispatch still has somewhere to land once a pane is known,
    /// and any renderer that shows this surface before its own `surface_show`
    /// leaves this object with an answer either way.
    pub fn render(&self, surface_id: String, pane: Option<u64>) -> Result<String> {
        let id = parse_surface_id(&surface_id)?;
        if let Some(tile) = pane {
            self.bind_pane(id, tile)?;
        }
        let registry = self.registry.clone();
        let surfaces = self.surfaces.clone();
        let executor = self.executor.clone();
        let host = self.host.clone();
        let tree = runtime()
            .block_on(async move {
                registry
                    .with(&surfaces, id, &host, move |rt| {
                        let executor = executor.clone();
                        Box::pin(async move { Ok(rt.render(&executor).await) })
                    })
                    .await
            })
            .map_err(SharedSurfaceError::surface)?;
        serde_json::to_string(&tree).map_err(SharedSurfaceError::json)
    }

    /// Reduce one renderer event, run its effects, and re-render — the JSON
    /// is exactly [`impress_surface_service::dto::SurfaceDispatchResult`]'s
    /// shape (`{"ok", "message", "tree", "effects"}`), so Swift and MCP read
    /// one document. `event_json` is `impress_surface::Event` JSON
    /// (`{"widget", "kind", "value"}`). `pane`, when given, is bound first —
    /// see [`Self::render`].
    ///
    /// Only a malformed `surface_id`/`event_json` fails as `Err`: a refused
    /// dispatch (no such surface, a `reduce` error) comes back `Ok` with
    /// `ok: false` in the JSON, because [`SurfaceDispatchResult`] always
    /// carries that field and a caller reading the same shape from MCP would
    /// see the same thing.
    pub fn dispatch(
        &self,
        surface_id: String,
        pane: Option<u64>,
        event_json: String,
    ) -> Result<String> {
        let id = parse_surface_id(&surface_id)?;
        let event: Event = serde_json::from_str(&event_json).map_err(SharedSurfaceError::json)?;
        if let Some(tile) = pane {
            self.bind_pane(id, tile)?;
        }
        let registry = self.registry.clone();
        let surfaces = self.surfaces.clone();
        let surfaces_for_dispatch = self.surfaces.clone();
        let executor = self.executor.clone();
        let host = self.host.clone();
        let outcome = runtime().block_on(async move {
            registry
                .with(&surfaces, id, &host, move |rt| {
                    let executor = executor.clone();
                    let surfaces_for_dispatch = surfaces_for_dispatch.clone();
                    let event = event.clone();
                    Box::pin(async move {
                        rt.dispatch(&executor, &surfaces_for_dispatch, &event, ActorKind::Agent)
                            .await
                    })
                })
                .await
        });
        let dto = match outcome {
            Ok((tree, effects)) => SurfaceDispatchResult {
                ok: true,
                message: format!("dispatched; {} effect(s)", effects.len()),
                tree: Some(tree),
                effects,
            },
            Err(e) => SurfaceDispatchResult::failed(e),
        };
        serde_json::to_string(&dto).map_err(SharedSurfaceError::json)
    }

    // ------------------------------------------------------------ the http surface

    /// Route one `/api/surface/*` request. `path` may carry a query string
    /// (`?pane=7`, `?after=12`); `body` is the raw request body, ignored for
    /// methods that do not take one. Every response is JSON; a failure is
    /// `{"error": "…"}` at 400 or 404 (see [`status_for`]) except
    /// `POST …/validate`, whose 400 carries `{"problems": […]}` — the same
    /// shape a 200 from it would, so a caller never has to branch on status
    /// to read what is wrong.
    pub fn surface_http(&self, method: String, path: String, body: String) -> SharedHttpReply {
        let method = method.to_ascii_uppercase();
        let (path_only, query) = match path.split_once('?') {
            Some((p, q)) => (p, q),
            None => (path.as_str(), ""),
        };
        let segments: Vec<&str> = path_only
            .trim_matches('/')
            .split('/')
            .filter(|s| !s.is_empty())
            .collect();
        if segments.len() < 2 || segments[0] != "api" || segments[1] != "surface" {
            return error_reply(404, "no such route");
        }
        let rest = &segments[2..];
        match (method.as_str(), rest) {
            ("GET", []) => self.http_list(),
            ("POST", []) => self.http_create(&body),
            ("GET", ["schema"]) => self.http_schema(),
            ("POST", ["validate"]) => self.http_validate(&body),
            ("GET", [id]) => self.http_spec(id),
            ("PUT", [id]) => self.http_update(id, &body),
            ("DELETE", [id]) => self.http_delete(id),
            ("GET", [id, "render"]) => self.http_render(id, query),
            ("POST", [id, "dispatch"]) => self.http_dispatch(id, query, &body),
            ("GET", [id, "events"]) => self.http_events(id, query),
            _ => error_reply(404, "no such route"),
        }
    }

    // ------------------------------------------------------------ the feed

    /// Start (or restart) the invalidation feed. See the module docs.
    pub fn subscribe(&self, listener: Box<dyn SharedSurfaceListener>) -> Result<()> {
        let rx = self
            .store
            .subscribe_mutations()
            .map_err(SharedSurfaceError::surface)?;

        let running = Arc::new(AtomicBool::new(true));
        let worker = SurfaceFeed {
            running: running.clone(),
            listener: Arc::from(listener),
            store: self.store.clone(),
            debounce: Duration::from_millis(self.debounce_ms.load(Ordering::SeqCst)),
            grace: Duration::from_secs(self.startup_grace_secs.load(Ordering::SeqCst)),
            external_poll: Duration::from_millis(self.external_poll_ms.load(Ordering::SeqCst)),
        };
        let join = std::thread::Builder::new()
            .name("impress-surface-invalidation".into())
            .spawn(move || worker.run(rx))
            .map_err(SharedSurfaceError::surface)?;

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

    /// Stop the feed. Idempotent; `SharedSurface`'s `Drop` does it too.
    pub fn unsubscribe(&self) {
        let mut slot = self.feed.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(mut feed) = slot.take() {
            feed.stop();
        }
    }
}

impl Drop for SharedSurface {
    fn drop(&mut self) {
        if let Ok(mut slot) = self.feed.lock() {
            if let Some(mut feed) = slot.take() {
                feed.stop();
            }
        }
    }
}

// ─── The private half ────────────────────────────────────────────────────

impl SharedSurface {
    /// Set `(id, self.host)`'s [`PaneHandle`] to tile `tile` under
    /// [`APP_ID`] — the same shape `surface_show` would already have set.
    fn bind_pane(&self, id: ItemId, tile: u64) -> Result<()> {
        let registry = self.registry.clone();
        let surfaces = self.surfaces.clone();
        let host = self.host.clone();
        let pane = PaneHandle {
            app_id: APP_ID.to_string(),
            device: host.clone(),
            tile,
        };
        runtime()
            .block_on(async move {
                registry
                    .with(&surfaces, id, &host, move |rt| {
                        Box::pin(async move {
                            rt.pane = Some(pane);
                            Ok::<(), String>(())
                        })
                    })
                    .await
            })
            .map_err(SharedSurfaceError::surface)
    }

    fn http_list(&self) -> SharedHttpReply {
        match self.surfaces.list() {
            Ok(rows) => {
                let summaries: Vec<SurfaceSummaryDto> =
                    rows.iter().map(SurfaceSummaryDto::from).collect();
                json_reply(200, serde_json::json!({ "surfaces": summaries }))
            }
            Err(e) => error_reply(status_for(&e), e),
        }
    }

    fn http_create(&self, body: &str) -> SharedHttpReply {
        let spec: SurfaceSpec = match serde_json::from_str(body) {
            Ok(s) => s,
            Err(e) => return error_reply(400, format!("invalid spec JSON: {e}")),
        };
        match self.surfaces.create(&spec, None, &[], ActorKind::Agent) {
            Ok(row) => json_reply(200, serde_json::json!({ "id": row.id.to_string() })),
            Err(e) => error_reply(status_for(&e), e),
        }
    }

    fn http_schema(&self) -> SharedHttpReply {
        let result = runtime().block_on(self.service.surface_schema());
        json_reply(200, result)
    }

    fn http_validate(&self, body: &str) -> SharedHttpReply {
        let spec: SurfaceSpec = match serde_json::from_str(body) {
            Ok(s) => s,
            Err(e) => return error_reply(400, format!("invalid spec JSON: {e}")),
        };
        let result = runtime().block_on(self.service.surface_validate(spec));
        let status = if result.ok() { 200 } else { 400 };
        json_reply(status, result)
    }

    fn http_spec(&self, id: &str) -> SharedHttpReply {
        match self.spec(id.to_string()) {
            Ok(body) => reply(200, body),
            Err(e) => error_reply(status_for(&e.to_string()), e.to_string()),
        }
    }

    fn http_update(&self, id: &str, body: &str) -> SharedHttpReply {
        let surface_id = match parse_surface_id(id) {
            Ok(id) => id,
            Err(e) => return error_reply(400, e.to_string()),
        };
        let spec: SurfaceSpec = match serde_json::from_str(body) {
            Ok(s) => s,
            Err(e) => return error_reply(400, format!("invalid spec JSON: {e}")),
        };
        match self.surfaces.update(surface_id, &spec, ActorKind::Agent) {
            Ok(row) => {
                self.registry.forget_surface(surface_id);
                match serde_json::to_string(&row.spec) {
                    Ok(body) => reply(200, body),
                    Err(e) => error_reply(500, format!("encode response: {e}")),
                }
            }
            Err(e) => error_reply(status_for(&e), e),
        }
    }

    fn http_delete(&self, id: &str) -> SharedHttpReply {
        let surface_id = match parse_surface_id(id) {
            Ok(id) => id,
            Err(e) => return error_reply(400, e.to_string()),
        };
        match self.surfaces.delete(surface_id) {
            Ok(true) => {
                self.registry.forget_surface(surface_id);
                json_reply(200, serde_json::json!({ "deleted": true }))
            }
            Ok(false) => error_reply(404, format!("no surface {id}")),
            Err(e) => error_reply(status_for(&e), e),
        }
    }

    fn http_render(&self, id: &str, query: &str) -> SharedHttpReply {
        let pane = query_param(query, "pane").and_then(|p| p.parse::<u64>().ok());
        match self.render(id.to_string(), pane) {
            Ok(body) => reply(200, body),
            Err(e) => error_reply(status_for(&e.to_string()), e.to_string()),
        }
    }

    fn http_dispatch(&self, id: &str, query: &str, body: &str) -> SharedHttpReply {
        let pane = query_param(query, "pane").and_then(|p| p.parse::<u64>().ok());
        match self.dispatch(id.to_string(), pane, body.to_string()) {
            Ok(json) => {
                // `dispatch` always answers `Ok` with the `SurfaceDispatchResult`
                // shape (see its own docs); the HTTP surface still owes a real
                // status code, so it reads the embedded `ok`/`message` back out.
                let status = match serde_json::from_str::<serde_json::Value>(&json) {
                    Ok(v) if v.get("ok").and_then(serde_json::Value::as_bool) == Some(false) => {
                        let message = v
                            .get("message")
                            .and_then(serde_json::Value::as_str)
                            .unwrap_or("");
                        status_for(message)
                    }
                    _ => 200,
                };
                reply(status, json)
            }
            Err(e) => error_reply(400, e.to_string()),
        }
    }

    fn http_events(&self, id: &str, query: &str) -> SharedHttpReply {
        let surface_id = match parse_surface_id(id) {
            Ok(id) => id,
            Err(e) => return error_reply(400, e.to_string()),
        };
        let after = query_param(query, "after")
            .and_then(|a| a.parse::<u64>().ok())
            .unwrap_or(0);
        match self.surfaces.get(surface_id) {
            Ok(Some(_)) => {}
            Ok(None) => return error_reply(404, format!("no surface {id}")),
            Err(e) => return error_reply(status_for(&e), e),
        }
        match self.surfaces.events_after(surface_id, &self.host, after, 0) {
            Ok(rows) => {
                let next_seq = self
                    .surfaces
                    .max_seq(surface_id, &self.host)
                    .unwrap_or(after);
                let events: Vec<SurfaceEventDto> = rows.iter().map(SurfaceEventDto::from).collect();
                json_reply(
                    200,
                    serde_json::json!({ "events": events, "next_seq": next_seq }),
                )
            }
            Err(e) => error_reply(status_for(&e), e),
        }
    }
}

fn query_param<'a>(query: &'a str, key: &str) -> Option<&'a str> {
    query.split('&').find_map(|pair| {
        let mut parts = pair.splitn(2, '=');
        let k = parts.next()?;
        if k == key {
            Some(parts.next().unwrap_or(""))
        } else {
            None
        }
    })
}

// ─── The feed's worker ───────────────────────────────────────────────────

struct SurfaceFeed {
    running: Arc<AtomicBool>,
    listener: Arc<dyn SharedSurfaceListener>,
    store: Arc<SqliteItemStore>,
    debounce: Duration,
    grace: Duration,
    external_poll: Duration,
}

impl SurfaceFeed {
    fn run(self, rx: std::sync::mpsc::Receiver<StoreMutation>) {
        let started = Instant::now();
        let mut pending: Vec<StoreMutation> = Vec::new();
        let mut burst_started: Option<Instant> = None;
        let mut last_seen: Option<Instant> = None;
        // Surface ids invalidated but not yet delivered — non-empty only
        // during the startup grace (CLAUDE.md's render-loop guard, ADR-0019
        // D6, applied here exactly as `layout.rs`'s feed applies it).
        let mut held: Vec<String> = Vec::new();
        let mut grace_over = self.grace.is_zero();

        let mut external = ExternalPoll::baseline(&self.store);
        let mut last_external_poll = Instant::now();

        while self.running.load(Ordering::SeqCst) {
            match rx.recv_timeout(ui_feed::POLL) {
                Ok(mutation) => {
                    if is_surface_mutation(&mutation) {
                        if burst_started.is_none() {
                            burst_started = Some(Instant::now());
                        }
                        last_seen = Some(Instant::now());
                        pending.push(mutation);
                    }
                }
                Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {}
                Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
            }

            if last_external_poll.elapsed() >= self.external_poll {
                last_external_poll = Instant::now();
                let mutations = external.check(&self.store, SURFACE_UI_PREFIX);
                if !mutations.is_empty() {
                    if burst_started.is_none() {
                        burst_started = Some(Instant::now());
                    }
                    last_seen = Some(Instant::now());
                    pending.extend(mutations);
                }
            }

            let quiet = last_seen
                .map(|t| t.elapsed() >= self.debounce)
                .unwrap_or(false);
            let overdue = burst_started
                .map(|t| t.elapsed() >= self.debounce * ui_feed::MAX_BURST_DEBOUNCES)
                .unwrap_or(false);
            if !pending.is_empty() && (quiet || overdue) {
                for mutation in pending.drain(..) {
                    if let Some(id) = surface_id_of(&self.store, &mutation) {
                        let id = id.to_string();
                        if !held.contains(&id) {
                            held.push(id);
                        }
                    }
                }
                burst_started = None;
                last_seen = None;
            }

            if !grace_over && started.elapsed() >= self.grace {
                grace_over = true;
            }
            if grace_over && !held.is_empty() {
                self.listener.surfaces_changed(std::mem::take(&mut held));
            }
        }
    }
}

/// Whether an IN-PROCESS mutation is one of this object's three record
/// kinds. Cheap and schema-only — no store read — because the in-process bus
/// already carries the schema ref on every mutation it can determine one
/// for.
fn is_surface_mutation(mutation: &StoreMutation) -> bool {
    mutation
        .schema_ref
        .as_deref()
        .map(|s| s.starts_with(SURFACE_UI_PREFIX))
        .unwrap_or(false)
}

/// Which surface a mutation is ABOUT. A `surface@1.0.0` row's own id IS the
/// surface id; a `surface-state@1.0.0` / `surface-event@1.0.0` row's id is
/// the STATE/EVENT row's own id, so this reads the row back for its
/// `surface` field (the same field name both schemas use — see
/// `impress-surface-service/src/store.rs`'s `field::state::SURFACE` /
/// `field::event::SURFACE`). `None` when the row is already gone (a pruned
/// event) or unreadable — dropping that one notification is acceptable: the
/// surface itself did not change.
fn surface_id_of(store: &SqliteItemStore, mutation: &StoreMutation) -> Option<ItemId> {
    match mutation.schema_ref.as_deref() {
        Some(s) if s == SURFACE_SCHEMA_REF => Some(mutation.item_id),
        Some(s) if s == SURFACE_STATE_SCHEMA_REF || s == SURFACE_EVENT_SCHEMA_REF => {
            let item = store.get(mutation.item_id).ok().flatten()?;
            match item.payload.get("surface") {
                Some(ItemValue::String(raw)) => raw.parse().ok(),
                _ => None,
            }
        }
        _ => None,
    }
}

// ─── Free functions ──────────────────────────────────────────────────────

/// The `SurfaceSpec` JSON Schema — `surface_schema`'s `schema` field alone,
/// for a host that wants it without opening a store (mirrors `layout.rs`'s
/// `compile_pane_query`-style free functions).
#[cfg_attr(feature = "native", uniffi::export)]
pub fn surface_schema_json() -> String {
    let result = runtime().block_on(DefaultImpressSurfaceService::new().surface_schema());
    serde_json::to_string(&result.schema).unwrap_or_else(|_| "{}".into())
}

/// The signal-explorer worked example's spec JSON — `surface_schema`'s
/// `example` field alone.
#[cfg_attr(feature = "native", uniffi::export)]
pub fn surface_example_json() -> String {
    let result = runtime().block_on(DefaultImpressSurfaceService::new().surface_schema());
    serde_json::to_string(&result.example).unwrap_or_else(|_| "{}".into())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc;

    use impress_surface::example_signal_explorer;

    fn open() -> (Arc<SharedStore>, Arc<SharedSurface>) {
        let store = SharedStore::open_in_memory().expect("open");
        let surface = SharedSurface::open(store.clone(), "test-host".into());
        (store, surface)
    }

    // `surface-demo-service_series`/`histogram` must be in the linked
    // inventory for the signal-explorer example to render/dispatch for
    // real. Unlike `impress-surface-service`'s own tests (which force-link
    // it as a `[dev-dependencies]`-only crate — it is not one of THAT
    // crate's normal deps), this crate already links it as a NORMAL
    // dependency transitively: `Cargo.toml` depends on `impress-capabilities`
    // with the `kit` feature (which enables `surface-demo`), and `lib.rs`
    // force-links `impress-capabilities` itself — so no separate force-link
    // is needed here.

    fn create_signal_explorer(store: &SharedStore) -> String {
        let core = store.core();
        let surfaces = SurfaceStore::new(core);
        let row = surfaces
            .create(&example_signal_explorer(), None, &[], ActorKind::Agent)
            .expect("create signal explorer");
        row.id.to_string()
    }

    #[test]
    fn render_resolves_the_signal_explorer_with_no_placeholder() {
        let (store, surface) = open();
        let id = create_signal_explorer(&store);

        let tree_json = surface.render(id, None).expect("render");
        assert!(
            !tree_json.contains("\"placeholder\""),
            "the tree contains a placeholder node: {tree_json}"
        );
    }

    #[test]
    fn dispatching_a_change_on_bins_is_seen_in_the_next_render() {
        let (store, surface) = open();
        let id = create_signal_explorer(&store);

        // Prime the runtime with a first render — the same order the real
        // loop follows (`impress-surface-service::tier_a::real_verb_loop`).
        surface.render(id.clone(), None).expect("first render");

        let event = serde_json::json!({
            "widget": "n0.1.1", // root/column -> row(1) -> bins field(1)
            "kind": "change",
            "value": 40
        })
        .to_string();
        let dispatched_json = surface.dispatch(id.clone(), None, event).expect("dispatch");
        let dispatched: serde_json::Value = serde_json::from_str(&dispatched_json).unwrap();
        assert_eq!(
            dispatched["ok"],
            serde_json::json!(true),
            "{dispatched_json}"
        );
        assert!(
            !dispatched_json.contains("\"placeholder\""),
            "dispatch's re-render has a placeholder: {dispatched_json}"
        );

        let rendered = surface.render(id, None).expect("render after dispatch");
        let tree: serde_json::Value = serde_json::from_str(&rendered).unwrap();
        let bins_value = &tree["root"]["node"]["items"][1]["node"]["items"][1]["node"]["value"];
        assert_eq!(
            bins_value,
            &serde_json::json!(40),
            "state.bins did not change: {rendered}"
        );
    }

    #[test]
    fn surface_http_lists_and_validates() {
        let (store, surface) = open();
        let id = create_signal_explorer(&store);

        let listed = surface.surface_http("GET".into(), "/api/surface".into(), String::new());
        assert_eq!(listed.status, 200);
        assert!(listed.body.contains(&id), "{}", listed.body);

        // Parses fine as a `SurfaceSpec` (unlike a structurally incomplete
        // document, which fails at JSON decode and is a DIFFERENT 400 body
        // — see `http_validate`'s own docs) but fails `impress_surface::validate`'s
        // very first check: `surface` must be exactly `SURFACE_VERSION`.
        let mut bad_spec = example_signal_explorer();
        bad_spec.surface = "0.1".to_string();
        let validated = surface.surface_http(
            "POST".into(),
            "/api/surface/validate".into(),
            serde_json::to_string(&bad_spec).unwrap(),
        );
        assert_eq!(validated.status, 400, "{}", validated.body);
        assert!(validated.body.contains("problems"), "{}", validated.body);
    }

    #[test]
    fn a_second_connections_write_is_seen_within_one_poll() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("surface_external_poll.sqlite");
        let path_str = path.to_str().unwrap().to_string();

        let store = SharedStore::open(path_str.clone()).expect("open");
        let surface = SharedSurface::open(store.clone(), "test-host".into());

        surface.set_debounce_ms(20);
        surface.set_startup_grace_secs(0);
        surface.set_external_poll_ms(20);

        let (tx, rx) = mpsc::channel::<Vec<String>>();
        struct Recorder(mpsc::Sender<Vec<String>>);
        impl SharedSurfaceListener for Recorder {
            fn surfaces_changed(&self, ids: Vec<String>) {
                let _ = self.0.send(ids);
            }
        }
        surface
            .subscribe(Box::new(Recorder(tx)))
            .expect("subscribe");

        // A second handle on the SAME file — not `store`, the one the
        // feed's own `SharedSurface` was opened on (ADR-0033 D6).
        let external = SharedStore::open(path_str).expect("open a second handle");
        let external_core = external.core();
        let external_surfaces = SurfaceStore::new(external_core);
        let created = external_surfaces
            .create(&example_signal_explorer(), None, &[], ActorKind::Agent)
            .expect("external create");

        let batch = rx
            .recv_timeout(std::time::Duration::from_secs(1))
            .expect("the external write is seen within roughly one poll interval");
        assert_eq!(batch, vec![created.id.to_string()]);

        surface.unsubscribe();
    }
}
