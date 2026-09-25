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

use std::collections::BTreeSet;
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
use impress_service_core::refusal::codes;
use impress_service_core::Refusal;
use impress_surface_service::runtime::actor_name;
use impress_surface_service::store::actor_from;

use impress_surface::{Event, SurfaceSpec};
use impress_surface_service::dto::{SurfaceDispatchResult, SurfaceEventDto, SurfaceSummaryDto};
use impress_surface_service::{
    DefaultExecutor, DefaultImpressSurfaceService, ImpressSurfaceService, PaneHandle,
    SessionRegistry, SurfaceStore, VerbHost,
};

use crate::ui_feed::{self, ExternalPoll, Feed};
use crate::{SharedStore, SharedStoreError};

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
    /// failed. `code` is its stable name (`not-found`, `invalid-argument`,
    /// `conflict`, `store-error`, a reduce error's own code, …), so Swift
    /// branches on it rather than on the prose (review AC-F19).
    #[error("{message}")]
    Surface { code: String, message: String },
    /// A JSON argument or result would not parse.
    #[error("{message}")]
    Json { message: String },
}

impl SharedSurfaceError {
    fn surface(refusal: Refusal) -> Self {
        SharedSurfaceError::Surface {
            code: refusal.code,
            message: refusal.message,
        }
    }

    fn internal(message: impl std::fmt::Display) -> Self {
        Self::surface(Refusal::internal(message))
    }

    /// The refusal this error carries, for an HTTP reply.
    fn refusal(&self) -> Refusal {
        match self {
            SharedSurfaceError::Surface { code, message } => Refusal::new(code, message),
            SharedSurfaceError::Json { message } => Refusal::invalid_argument(message),
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
    id.trim().parse::<ItemId>().map_err(|_| {
        SharedSurfaceError::surface(Refusal::invalid_argument(format!(
            "'{id}' is not a surface id"
        )))
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

/// A refusal as an HTTP reply: `{"error": <message>, "code": <code>}` at the
/// status the code maps to (`impress_service_core::refusal::http_status`).
fn refusal_reply(refusal: &Refusal) -> SharedHttpReply {
    log::info!(
        target: "surface",
        "http refused [{}]: {}",
        refusal.code,
        refusal.message
    );
    reply(
        refusal.http_status(),
        serde_json::json!({ "error": refusal.message, "code": refusal.code }).to_string(),
    )
}

fn error_reply(code: &str, message: impl Into<String>) -> SharedHttpReply {
    refusal_reply(&Refusal::new(code, message))
}

fn json_reply(status: u16, value: impl serde::Serialize) -> SharedHttpReply {
    match serde_json::to_string(&value) {
        Ok(body) => reply(status, body),
        Err(e) => error_reply(codes::INTERNAL, format!("encode response: {e}")),
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

// ─── The verb host bridge (ADR-0033 D4, amended 2026-09-23 for wave 5) ────

/// What the host process implements to answer a verb this crate's own
/// linked inventory (`impress-capabilities-kit`) does not have — imbib's
/// and imprint's own verbs, which cannot link into this crate a second time
/// (ADR-0033 D4 forbids a second domain core; `impress-store-ffi`'s
/// `Cargo.toml` has the cyclic-package details for why they cannot link
/// through `impress-capabilities` either). In the app this is implemented
/// over `impel-tools`' `call_tool`, which reaches imbib and imprint through
/// their own HTTP routers and refuses, by name, when the owning app is not
/// running.
///
/// `SharedStore::set_verb_host` installs one; [`HostAdapter`] (below) is
/// what [`SharedSurface::open`] wires it into
/// [`impress_surface_service::runtime::VerbHost`], the trait the executor
/// and the service actually consult. `call_verb` takes and returns JSON
/// STRINGS rather than a UniFFI record, for the same reason
/// [`Self::dispatch`](SharedSurface::dispatch)'s `event_json` does (module
/// docs above): the shape is `serde_json::Value`, recursive, and a callback
/// interface has no way to carry one directly.
#[cfg_attr(feature = "native", uniffi::export(callback_interface))]
pub trait SharedVerbHost: Send + Sync {
    /// Whether the host can answer this verb at all — checked before
    /// `call_verb` runs it, so `surface_validate` can say "no such verb"
    /// without a round trip through the host.
    fn has_verb(&self, name: String) -> bool;
    /// Run the verb by name; `args_json` and the successful return are both
    /// `serde_json::Value` JSON, exactly as every other verb call in the
    /// suite (MCP, the CLI, the linked inventory) speaks it.
    fn call_verb(
        &self,
        name: String,
        args_json: String,
    ) -> std::result::Result<String, SharedStoreError>;
}

/// Adapts whatever [`SharedVerbHost`] is currently installed on a
/// [`SharedStore`] (if any) to
/// [`impress_surface_service::runtime::VerbHost`] — the trait
/// `impress-surface-service`'s executor and service actually consult.
///
/// Holds a clone of [`SharedStore`]'s `verb_host` slot rather than a
/// snapshot of its contents, and reads it fresh on every call. That is what
/// makes late installation work: `SharedStore::set_verb_host` may run AFTER
/// a [`SharedSurface`] was already opened (its own docs say so), and every
/// [`HostAdapter`] this crate built before that call reads the SAME slot,
/// so it starts serving the host the moment it lands rather than staying
/// bound to "no host" forever.
struct HostAdapter {
    slot: Arc<Mutex<Option<Arc<dyn SharedVerbHost>>>>,
}

impl VerbHost for HostAdapter {
    fn has_verb(&self, name: &str) -> bool {
        let guard = self.slot.lock().unwrap_or_else(|e| e.into_inner());
        guard
            .as_ref()
            .is_some_and(|host| host.has_verb(name.to_string()))
    }

    fn call_verb(
        &self,
        name: &str,
        args: serde_json::Value,
    ) -> impress_surface_service::Result<serde_json::Value> {
        let host = {
            let guard = self.slot.lock().unwrap_or_else(|e| e.into_inner());
            guard.clone()
        };
        let Some(host) = host else {
            return Err(Refusal::new(
                "unknown-verb",
                format!("no verb host installed for '{name}'"),
            ));
        };
        let args_json = serde_json::to_string(&args)
            .map_err(|e| Refusal::internal(format!("encode args for '{name}': {e}")))?;
        let reply_json = host.call_verb(name.to_string(), args_json).map_err(|e| {
            log::warn!(target: "surface", "verb host refused '{name}': {e}");
            Refusal::new(codes::VERB_FAILED, e.to_string())
        })?;
        serde_json::from_str(&reply_json).map_err(|e| {
            Refusal::new(
                codes::VERB_FAILED,
                format!("'{name}': host reply was not JSON: {e}"),
            )
        })
    }
}

// ─── The object ──────────────────────────────────────────────────────────

/// One store's worth of agent surfaces, bound to an open [`SharedStore`] and
/// a resolved `host`.
///
/// Holds no surface state of its own: every `(surface, host)` runtime lives
/// in the store's ONE registry ([`SharedStore::surface_sessions`]), shared
/// by every handle opened on that store — each pane's, the HTTP bridge's —
/// and each runtime re-reads its rows on every call (wave 7, RS-S1). Opening
/// a handle is therefore cheap, and a handle opened per request serves the
/// same instance a pane renders.
///
/// # Off the main thread (SK-K2, AC-F10)
///
/// [`Self::render`], [`Self::dispatch`] and [`Self::surface_http`] are
/// `async` exports: they run sources and effects — verb calls that may be
/// HTTP round trips to another app — on this module's own Tokio runtime and
/// never block the calling thread. Swift `await`s them; the main actor is
/// suspended, not held, while a slow verb runs.
#[cfg_attr(feature = "native", derive(uniffi::Object))]
pub struct SharedSurface {
    core: SurfaceCore,
    debounce_ms: AtomicU64,
    startup_grace_secs: AtomicU64,
    external_poll_ms: AtomicU64,
    feed: Mutex<Option<Feed>>,
}

/// Everything a call needs, cheap to clone into the task that runs it.
#[derive(Clone)]
struct SurfaceCore {
    store: Arc<SqliteItemStore>,
    surfaces: SurfaceStore,
    executor: DefaultExecutor,
    service: DefaultImpressSurfaceService,
    registry: Arc<SessionRegistry>,
    host: String,
}

/// Run `work` on this module's runtime and await it from wherever the caller
/// is — a UniFFI foreign future, a test's `block_on`. Awaiting a Tokio
/// `JoinHandle` needs no Tokio context, so the caller's executor never runs
/// a verb itself.
async fn off_caller<T: Send + 'static>(
    work: impl std::future::Future<Output = T> + Send + 'static,
) -> std::result::Result<T, Refusal> {
    runtime()
        .spawn(work)
        .await
        .map_err(|e| Refusal::internal(format!("surface task failed: {e}")))
}

#[cfg_attr(feature = "native", uniffi::export)]
impl SharedSurface {
    /// Bind to the surfaces of the given `store`. `host` defaults to the
    /// layout device id when empty — see the module docs.
    #[cfg_attr(feature = "native", uniffi::constructor)]
    pub fn open(store: Arc<SharedStore>, host: String) -> Arc<Self> {
        let core = store.core();
        let host = resolve_device(Some(host.trim()).filter(|h| !h.is_empty()));
        // See `HostAdapter`'s docs: it reads `store`'s verb-host slot fresh
        // on every call, so a `set_verb_host` that runs after this `open`
        // still reaches the executor and the service built right here.
        let verb_host: Arc<dyn VerbHost> = Arc::new(HostAdapter {
            slot: store.verb_host_slot(),
        });
        let registry = store.surface_sessions();
        Arc::new(SharedSurface {
            core: SurfaceCore {
                surfaces: SurfaceStore::new(core.clone()),
                executor: DefaultExecutor::with_store_and_sessions(
                    core.clone(),
                    store.layout_sessions(),
                )
                .with_verb_host(verb_host.clone()),
                service: DefaultImpressSurfaceService::with_store_and_sessions(
                    core.clone(),
                    registry.clone(),
                )
                .with_verb_host(verb_host),
                registry,
                store: core,
                host,
            },
            debounce_ms: AtomicU64::new(ui_feed::DEFAULT_DEBOUNCE_MS),
            startup_grace_secs: AtomicU64::new(0),
            external_poll_ms: AtomicU64::new(ui_feed::EXTERNAL_POLL_MS),
            feed: Mutex::new(None),
        })
    }

    /// This object's resolved host/device tag.
    pub fn host(&self) -> String {
        self.core.host.clone()
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
        self.core.spec(&surface_id)
    }

    /// Every stored surface, for a pane's title or a picker.
    pub fn list(&self) -> Result<Vec<SharedSurfaceRow>> {
        let rows = self
            .core
            .surfaces
            .list()
            .map_err(SharedSurfaceError::surface)?;
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
    /// through the linked inventory / the store first, OFF the caller's
    /// thread (see the struct docs). When `pane` is given, records it as
    /// this instance's [`PaneHandle`] first (see the module docs).
    pub async fn render(&self, surface_id: String, pane: Option<u64>) -> Result<String> {
        let core = self.core.clone();
        off_caller(async move { core.render(&surface_id, pane).await })
            .await
            .map_err(SharedSurfaceError::surface)?
    }

    /// Reduce one renderer event, run its effects, and re-render — OFF the
    /// caller's thread. The JSON is exactly
    /// [`impress_surface_service::dto::SurfaceDispatchResult`]'s shape
    /// (`{"ok", "code", "message", "tree", "effects", "effects_failed",
    /// "source_errors"}`), so Swift and MCP read one document; `ok` is true
    /// only when every effect happened (see that type's docs).
    /// `event_json` is `impress_surface::Event` JSON (`{"widget", "kind",
    /// "value"}`). `pane`, when given, is bound first — see
    /// [`Self::render`].
    ///
    /// `actor` is who acted: the pane passes `human` for a person's click or
    /// edit, and the state write, every emitted event and every layout verb
    /// an effect runs are recorded as that actor (review SK-K5, AC-F5). The
    /// HTTP route dispatches as `agent`.
    ///
    /// Only a malformed `surface_id`/`event_json` fails as `Err`: a refused
    /// dispatch (no such surface, a `reduce` error) comes back `Ok` with
    /// `ok: false` in the JSON, because [`SurfaceDispatchResult`] always
    /// carries that field and a caller reading the same shape from MCP would
    /// see the same thing.
    pub async fn dispatch(
        &self,
        surface_id: String,
        pane: Option<u64>,
        event_json: String,
        actor: String,
    ) -> Result<String> {
        let core = self.core.clone();
        let actor = actor_from(Some(actor.as_str()));
        off_caller(async move { core.dispatch(&surface_id, pane, &event_json, actor).await })
            .await
            .map_err(SharedSurfaceError::surface)?
    }

    // ------------------------------------------------------------ the http surface

    // NOTE the `…` in the doc line below, where `/api/surface/*` would read
    // more naturally. uniffi-bindgen copies these docs verbatim into a Swift
    // `/** … */` block, and SWIFT BLOCK COMMENTS NEST: the `/*` inside
    // `surface/*` opens a nested comment that the block's own `*/` only
    // closes back to level one, so everything after it — 13,000 lines,
    // including `uniffiEnsureInitialized` — becomes comment. The binding then
    // fails to parse with "Unterminated '/*' comment" at the END of the file,
    // 13,000 lines from the cause. No `///` on a #[uniffi::export] item may
    // contain `/*`.

    /// Route one `/api/surface/…` request, OFF the caller's thread. `path`
    /// may carry a query string (`?pane=7`, `?after=12`,
    /// `?expected_revision=3`); `body` is the raw request body, ignored for
    /// methods that do not take one. Every response is JSON; a failure is
    /// `{"error": "…", "code": "…"}` at the status its code maps to
    /// (`impress_service_core::refusal::http_status`: `invalid-argument` 400,
    /// `not-found` 404, `conflict` 409, …), except `POST …/validate`, whose
    /// 400 carries `{"problems": […]}` — the same shape a 200 from it would,
    /// so a caller never has to branch on status to read what is wrong — and
    /// `POST …/dispatch`, whose body is always the dispatch result.
    pub async fn surface_http(
        &self,
        method: String,
        path: String,
        body: String,
    ) -> SharedHttpReply {
        let core = self.core.clone();
        off_caller(async move { core.route(&method, &path, &body).await })
            .await
            .unwrap_or_else(|e| refusal_reply(&e))
    }

    // ------------------------------------------------------------ the feed

    /// Start (or restart) the invalidation feed. See the module docs.
    pub fn subscribe(&self, listener: Box<dyn SharedSurfaceListener>) -> Result<()> {
        let rx = self
            .core
            .store
            .subscribe_mutations()
            .map_err(SharedSurfaceError::internal)?;

        let running = Arc::new(AtomicBool::new(true));
        let worker = SurfaceFeed {
            running: running.clone(),
            listener: Arc::from(listener),
            store: self.core.store.clone(),
            registry: self.core.registry.clone(),
            debounce: Duration::from_millis(self.debounce_ms.load(Ordering::SeqCst)),
            grace: Duration::from_secs(self.startup_grace_secs.load(Ordering::SeqCst)),
            external_poll: Duration::from_millis(self.external_poll_ms.load(Ordering::SeqCst)),
        };
        let join = std::thread::Builder::new()
            .name("impress-surface-invalidation".into())
            .spawn(move || worker.run(rx))
            .map_err(SharedSurfaceError::internal)?;

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

impl SurfaceCore {
    fn spec(&self, surface_id: &str) -> Result<String> {
        let id = parse_surface_id(surface_id)?;
        let row = self
            .surfaces
            .get(id)
            .map_err(SharedSurfaceError::surface)?
            .ok_or_else(|| {
                SharedSurfaceError::surface(Refusal::not_found(format!("no surface {surface_id}")))
            })?;
        serde_json::to_string(&row.spec).map_err(SharedSurfaceError::json)
    }

    async fn render(&self, surface_id: &str, pane: Option<u64>) -> Result<String> {
        let id = parse_surface_id(surface_id)?;
        if let Some(tile) = pane {
            self.bind_pane(id, tile).await?;
        }
        let executor = self.executor.clone();
        let tree = self
            .registry
            .with(&self.surfaces, id, &self.host, move |rt| {
                Box::pin(async move { Ok(rt.render(&executor).await) })
            })
            .await
            .map_err(SharedSurfaceError::surface)?;
        serde_json::to_string(&tree).map_err(SharedSurfaceError::json)
    }

    async fn dispatch(
        &self,
        surface_id: &str,
        pane: Option<u64>,
        event_json: &str,
        actor: ActorKind,
    ) -> Result<String> {
        let id = parse_surface_id(surface_id)?;
        let event: Event = serde_json::from_str(event_json).map_err(SharedSurfaceError::json)?;
        if let Some(tile) = pane {
            self.bind_pane(id, tile).await?;
        }
        let executor = self.executor.clone();
        let writer = self.surfaces.clone();
        let outcome = self
            .registry
            .with(&self.surfaces, id, &self.host, move |rt| {
                Box::pin(async move {
                    let (tree, effects) = rt.dispatch(&executor, &writer, &event, actor).await?;
                    Ok((tree, effects, rt.source_error_list()))
                })
            })
            .await;
        let dto = match outcome {
            Ok((tree, effects, source_errors)) => {
                SurfaceDispatchResult::dispatched(tree, effects, source_errors)
            }
            Err(e) => SurfaceDispatchResult::refused(e),
        };
        log::info!(
            target: "surface",
            "surface {surface_id} ({}): {} dispatch {}: {}",
            self.host,
            actor_name(actor),
            match (dto.ok, dto.code.as_deref()) {
                (true, _) => "ok".to_string(),
                // The event was applied and its state saved; an effect did
                // not happen. Not a refusal of the dispatch.
                (false, Some(code @ "effect-failed")) => {
                    format!("applied, but not ok [{code}]")
                }
                (false, code) => format!("refused [{}]", code.unwrap_or("?")),
            },
            dto.message
        );
        serde_json::to_string(&dto).map_err(SharedSurfaceError::json)
    }

    /// Set `(id, self.host)`'s [`PaneHandle`] to tile `tile` under
    /// [`APP_ID`] — the same shape `surface_show` would already have set.
    async fn bind_pane(&self, id: ItemId, tile: u64) -> Result<()> {
        let pane = PaneHandle {
            app_id: APP_ID.to_string(),
            device: self.host.clone(),
            tile,
        };
        self.registry
            .with(&self.surfaces, id, &self.host, move |rt| {
                Box::pin(async move {
                    rt.pane = Some(pane);
                    Ok::<(), Refusal>(())
                })
            })
            .await
            .map_err(SharedSurfaceError::surface)
    }

    async fn route(&self, method: &str, path: &str, body: &str) -> SharedHttpReply {
        let method = method.to_ascii_uppercase();
        let (path_only, query) = match path.split_once('?') {
            Some((p, q)) => (p, q),
            None => (path, ""),
        };
        let segments: Vec<&str> = path_only
            .trim_matches('/')
            .split('/')
            .filter(|s| !s.is_empty())
            .collect();
        if segments.len() < 2 || segments[0] != "api" || segments[1] != "surface" {
            return error_reply(codes::NOT_FOUND, "no such route");
        }
        let rest = &segments[2..];
        match (method.as_str(), rest) {
            ("GET", []) => self.http_list(),
            ("POST", []) => self.http_create(body),
            ("GET", ["schema"]) => self.http_schema().await,
            ("POST", ["validate"]) => self.http_validate(body).await,
            ("GET", [id]) => self.http_spec(id),
            ("PUT", [id]) => self.http_update(id, query, body),
            ("DELETE", [id]) => self.http_delete(id),
            ("GET", [id, "render"]) => self.http_render(id, query).await,
            ("POST", [id, "dispatch"]) => self.http_dispatch(id, query, body).await,
            ("GET", [id, "events"]) => self.http_events(id, query),
            _ => error_reply(codes::NOT_FOUND, "no such route"),
        }
    }

    fn http_list(&self) -> SharedHttpReply {
        match self.surfaces.list() {
            Ok(rows) => {
                let summaries: Vec<SurfaceSummaryDto> =
                    rows.iter().map(SurfaceSummaryDto::from).collect();
                json_reply(200, serde_json::json!({ "surfaces": summaries }))
            }
            Err(e) => refusal_reply(&e),
        }
    }

    fn http_create(&self, body: &str) -> SharedHttpReply {
        let spec: SurfaceSpec = match serde_json::from_str(body) {
            Ok(s) => s,
            Err(e) => {
                return error_reply(codes::INVALID_ARGUMENT, format!("invalid spec JSON: {e}"))
            }
        };
        match self.surfaces.create(&spec, None, &[], ActorKind::Agent) {
            Ok(row) => json_reply(
                200,
                serde_json::json!({ "id": row.id.to_string(), "revision": row.revision }),
            ),
            Err(e) => refusal_reply(&e),
        }
    }

    async fn http_schema(&self) -> SharedHttpReply {
        json_reply(200, self.service.surface_schema().await)
    }

    async fn http_validate(&self, body: &str) -> SharedHttpReply {
        let spec: SurfaceSpec = match serde_json::from_str(body) {
            Ok(s) => s,
            Err(e) => {
                return error_reply(codes::INVALID_ARGUMENT, format!("invalid spec JSON: {e}"))
            }
        };
        let result = self.service.surface_validate(spec).await;
        let status = if result.ok() { 200 } else { 400 };
        json_reply(status, result)
    }

    fn http_spec(&self, id: &str) -> SharedHttpReply {
        match self.spec(id) {
            Ok(body) => reply(200, body),
            Err(e) => refusal_reply(&e.refusal()),
        }
    }

    /// `PUT …/<id>`, with `?expected_revision=N` for optimistic concurrency
    /// (409 on a mismatch, nothing written). No registry forget: every
    /// runtime re-reads the spec on its next call.
    fn http_update(&self, id: &str, query: &str, body: &str) -> SharedHttpReply {
        let surface_id = match parse_surface_id(id) {
            Ok(id) => id,
            Err(e) => return refusal_reply(&e.refusal()),
        };
        let expected = match query_param(query, "expected_revision") {
            None => None,
            Some(raw) => match raw.parse::<u64>() {
                Ok(n) => Some(n),
                Err(_) => {
                    return error_reply(
                        codes::INVALID_ARGUMENT,
                        format!("expected_revision '{raw}' is not a number"),
                    )
                }
            },
        };
        let spec: SurfaceSpec = match serde_json::from_str(body) {
            Ok(s) => s,
            Err(e) => {
                return error_reply(codes::INVALID_ARGUMENT, format!("invalid spec JSON: {e}"))
            }
        };
        match self
            .surfaces
            .update(surface_id, &spec, None, expected, ActorKind::Agent)
        {
            Ok(row) => match serde_json::to_string(&row.spec) {
                Ok(body) => reply(200, body),
                Err(e) => error_reply(codes::INTERNAL, format!("encode response: {e}")),
            },
            Err(e) => refusal_reply(&e),
        }
    }

    fn http_delete(&self, id: &str) -> SharedHttpReply {
        let surface_id = match parse_surface_id(id) {
            Ok(id) => id,
            Err(e) => return refusal_reply(&e.refusal()),
        };
        match self.surfaces.delete(surface_id) {
            Ok(true) => {
                self.registry.forget_surface(surface_id);
                json_reply(200, serde_json::json!({ "deleted": true }))
            }
            Ok(false) => error_reply(codes::NOT_FOUND, format!("no surface {id}")),
            Err(e) => refusal_reply(&e),
        }
    }

    async fn http_render(&self, id: &str, query: &str) -> SharedHttpReply {
        let pane = query_param(query, "pane").and_then(|p| p.parse::<u64>().ok());
        match self.render(id, pane).await {
            Ok(body) => reply(200, body),
            Err(e) => refusal_reply(&e.refusal()),
        }
    }

    async fn http_dispatch(&self, id: &str, query: &str, body: &str) -> SharedHttpReply {
        let pane = query_param(query, "pane").and_then(|p| p.parse::<u64>().ok());
        // Over HTTP the dispatcher is an agent; only the pane passes `human`.
        match self.dispatch(id, pane, body, ActorKind::Agent).await {
            Ok(json) => {
                // `dispatch` always answers `Ok` with the `SurfaceDispatchResult`
                // shape (see its own docs); the HTTP surface still owes a real
                // status code, which its `code` decides: 200 when `ok`, else
                // the code's status — `effect-failed` is 422, with the
                // re-rendered tree and every effect's outcome in the body.
                let status = match serde_json::from_str::<serde_json::Value>(&json) {
                    Ok(v) if v.get("ok").and_then(serde_json::Value::as_bool) == Some(false) => v
                        .get("code")
                        .and_then(serde_json::Value::as_str)
                        .map(impress_service_core::refusal::http_status)
                        .unwrap_or(422),
                    _ => 200,
                };
                reply(status, json)
            }
            Err(e) => refusal_reply(&e.refusal()),
        }
    }

    fn http_events(&self, id: &str, query: &str) -> SharedHttpReply {
        let surface_id = match parse_surface_id(id) {
            Ok(id) => id,
            Err(e) => return refusal_reply(&e.refusal()),
        };
        let after = query_param(query, "after")
            .and_then(|a| a.parse::<u64>().ok())
            .unwrap_or(0);
        match self.surfaces.get(surface_id) {
            Ok(Some(_)) => {}
            Ok(None) => return error_reply(codes::NOT_FOUND, format!("no surface {id}")),
            Err(e) => return refusal_reply(&e),
        }
        match self.surfaces.events_after(surface_id, &self.host, after, 0) {
            Ok(rows) => {
                // The cursor comes from the rows just read (AC-F2).
                let (next_seq, gap) = impress_surface_service::service::cursor_after(&rows, after);
                let events: Vec<SurfaceEventDto> = rows.iter().map(SurfaceEventDto::from).collect();
                json_reply(
                    200,
                    serde_json::json!({ "events": events, "next_seq": next_seq, "gap": gap }),
                )
            }
            Err(e) => refusal_reply(&e),
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
    /// The store's one surface registry: the feed marks the runtimes whose
    /// query sources read a kind that was written (RS-S2) and reports those
    /// surfaces as changed.
    registry: Arc<SessionRegistry>,
    debounce: Duration,
    grace: Duration,
    external_poll: Duration,
}

impl SurfaceFeed {
    fn run(self, rx: std::sync::mpsc::Receiver<StoreMutation>) {
        let started = Instant::now();
        let mut pending: Vec<StoreMutation> = Vec::new();
        // Schema refs of non-surface records written since the last flush —
        // what a query source may read (RS-S2, AC-F16).
        let mut pending_refs: BTreeSet<String> = BTreeSet::new();
        let mut burst_started: Option<Instant> = None;
        let mut last_seen: Option<Instant> = None;
        // Surface ids invalidated but not yet delivered — non-empty only
        // during the startup grace (CLAUDE.md's render-loop guard, ADR-0019
        // D6, applied here exactly as `layout.rs`'s feed applies it).
        let mut held: Vec<String> = Vec::new();
        let mut grace_over = self.grace.is_zero();

        let mut external = ExternalPoll::baseline(&self.store);
        let mut external_domain = DomainPoll::baseline(&self.store);
        let mut last_external_poll = Instant::now();

        while self.running.load(Ordering::SeqCst) {
            let mut touched = false;
            match rx.recv_timeout(ui_feed::POLL) {
                Ok(mutation) => {
                    if is_surface_mutation(&mutation) {
                        pending.push(mutation);
                        touched = true;
                    } else if let Some(schema) = mutation.schema_ref {
                        if !schema.starts_with(ui_feed::EXTERNAL_UI_PREFIX) {
                            pending_refs.insert(schema);
                            touched = true;
                        }
                    }
                }
                Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {}
                Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
            }

            if last_external_poll.elapsed() >= self.external_poll {
                last_external_poll = Instant::now();
                let mutations = external.check(&self.store, SURFACE_UI_PREFIX);
                if !mutations.is_empty() {
                    pending.extend(mutations);
                    touched = true;
                }
                let refs = external_domain.check(&self.store, &self.registry.watched_refs());
                if !refs.is_empty() {
                    pending_refs.extend(refs);
                    touched = true;
                }
            }
            if touched {
                if burst_started.is_none() {
                    burst_started = Some(Instant::now());
                }
                last_seen = Some(Instant::now());
            }

            let quiet = last_seen
                .map(|t| t.elapsed() >= self.debounce)
                .unwrap_or(false);
            let overdue = burst_started
                .map(|t| t.elapsed() >= self.debounce * ui_feed::MAX_BURST_DEBOUNCES)
                .unwrap_or(false);
            if (!pending.is_empty() || !pending_refs.is_empty()) && (quiet || overdue) {
                for mutation in pending.drain(..) {
                    if let Some(id) = surface_id_of(&self.store, &mutation) {
                        let id = id.to_string();
                        if !held.contains(&id) {
                            held.push(id);
                        }
                    }
                }
                for id in self
                    .registry
                    .invalidate_refs(&std::mem::take(&mut pending_refs))
                {
                    let id = id.to_string();
                    if !held.contains(&id) {
                        held.push(id);
                    }
                }
                burst_started = None;
                last_seen = None;
            }

            if !grace_over && started.elapsed() >= self.grace {
                grace_over = true;
            }
            if grace_over && !held.is_empty() {
                log::debug!(
                    target: "surface",
                    "feed: {} surface(s) changed: {}",
                    held.len(),
                    held.join(", ")
                );
                self.listener.surfaces_changed(std::mem::take(&mut held));
            }
        }
    }
}

/// The cross-process half of RS-S2: which of the schema refs some live query
/// source reads did ANOTHER connection (another app, `impress-mcp`) write
/// since the last look. Its own cursor, separate from [`ExternalPoll`]'s
/// (which watches only `impress/ui/surface*` rows), advanced only after
/// every read succeeded so a failed read is retried, not lost.
struct DomainPoll {
    last_data_version: Option<i64>,
    high_water_mark: i64,
}

impl DomainPoll {
    fn baseline(store: &SqliteItemStore) -> Self {
        DomainPoll {
            last_data_version: store.data_version().ok(),
            high_water_mark: chrono::Utc::now().timestamp_millis(),
        }
    }

    fn check(&mut self, store: &SqliteItemStore, watched: &BTreeSet<String>) -> BTreeSet<String> {
        let mut written = BTreeSet::new();
        let Ok(dv) = store.data_version() else {
            return written;
        };
        if self.last_data_version == Some(dv) {
            return written;
        }
        let mut mark = self.high_water_mark;
        for schema in watched {
            let Ok(items) = store.items_modified_since(schema, self.high_water_mark) else {
                return BTreeSet::new();
            };
            for item in items.iter().filter(|i| &i.schema == schema) {
                written.insert(item.schema.clone());
                mark = mark.max(item.modified.timestamp_millis());
            }
        }
        self.last_data_version = Some(dv);
        // Nothing watched: move the mark to now, so a source that appears
        // later is not told about writes from before it existed.
        self.high_water_mark = if watched.is_empty() {
            chrono::Utc::now().timestamp_millis()
        } else {
            mark
        };
        written
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

    /// The async exports, driven to completion from a plain test thread —
    /// the way a Swift `await` drives them, minus Swift.
    impl SharedSurface {
        fn render_now(&self, id: String, pane: Option<u64>) -> Result<String> {
            futures_block(self.render(id, pane))
        }
        fn dispatch_now(&self, id: String, pane: Option<u64>, event: String) -> Result<String> {
            futures_block(self.dispatch(id, pane, event, "human".into()))
        }
        fn http_now(&self, method: String, path: String, body: String) -> SharedHttpReply {
            futures_block(self.surface_http(method, path, body))
        }
    }

    /// Not `runtime().block_on`: the exports must work from a thread that is
    /// NOT on the FFI's runtime, which is where a UniFFI foreign future polls
    /// them from.
    fn futures_block<F: std::future::Future>(future: F) -> F::Output {
        let driver = tokio::runtime::Builder::new_current_thread()
            .build()
            .expect("a bare driver");
        driver.block_on(future)
    }

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

    // ── V1: the host verb bridge (ADR-0033 D4, amended 2026-09-23) ────────

    /// A Rust-implemented [`SharedVerbHost`] that knows exactly one verb,
    /// standing in for the Swift `ImpelToolsVerbHost` this crate's own
    /// binding does not have to compile.
    struct FakeVerbHost;

    const FAKE_VERB: &str = "fake-service_echo";

    impl SharedVerbHost for FakeVerbHost {
        fn has_verb(&self, name: String) -> bool {
            name == FAKE_VERB
        }

        fn call_verb(
            &self,
            name: String,
            args_json: String,
        ) -> std::result::Result<String, SharedStoreError> {
            if name != FAKE_VERB {
                return Err(SharedStoreError::InvalidArgument {
                    message: format!("FakeVerbHost does not know '{name}'"),
                });
            }
            let args: serde_json::Value = serde_json::from_str(&args_json).map_err(|e| {
                SharedStoreError::InvalidArgument {
                    message: format!("bad args: {e}"),
                }
            })?;
            Ok(serde_json::json!({ "echoed": args }).to_string())
        }
    }

    /// A self-contained spec whose one source calls [`FAKE_VERB`] — nothing
    /// this crate's own linked inventory (`impress-capabilities-kit`) knows
    /// by that name, so it renders a placeholder without a host and the
    /// echoed value with one.
    fn fixture_host_spec() -> SurfaceSpec {
        serde_json::from_value(serde_json::json!({
            "surface": "1.0",
            "name": "Host verb bridge fixture",
            "state": {},
            "sources": {
                "echo": { "verb": FAKE_VERB, "args": { "x": 42 } }
            },
            "root": { "column": [
                { "text": "{{source.echo.echoed.x}}", "id": "echoed-text" }
            ] }
        }))
        .expect("fixture spec is well-formed JSON against SurfaceSpec")
    }

    fn create_fixture_surface(store: &SharedStore) -> String {
        let core = store.core();
        let surfaces = SurfaceStore::new(core);
        let row = surfaces
            .create(&fixture_host_spec(), None, &[], ActorKind::Agent)
            .expect("create fixture surface");
        row.id.to_string()
    }

    /// Late install: a handle opened BEFORE `set_verb_host` runs still picks
    /// up the host on its next call, because `HostAdapter` reads the SAME
    /// slot `SharedStore` writes rather than a snapshot taken at `open()`.
    #[test]
    fn a_host_installed_after_open_still_serves_an_existing_handle() {
        let (store, surface) = open();
        let id = create_fixture_surface(&store);

        let before = surface
            .render_now(id.clone(), None)
            .expect("render before install");
        assert!(
            before.contains("\"placeholder\""),
            "with no host installed, the unresolved verb source should degrade to a \
             placeholder rather than fail the whole render: {before}"
        );

        store.set_verb_host(Box::new(FakeVerbHost));

        let after = surface.render_now(id, None).expect("render after install");
        assert!(
            !after.contains("\"placeholder\""),
            "the same handle, opened before the host was installed, should resolve now: {after}"
        );
        assert!(
            after.contains('4') && after.contains('2'),
            "the echoed value is not in the render tree: {after}"
        );
    }

    /// `surface_http`'s `POST …/validate` route reports a host-only verb as
    /// missing with no host installed, and clean once one is — the same
    /// route `impress-surface-service_surface-validate` answers from the
    /// Swift automation router.
    #[test]
    fn surface_http_validate_accepts_a_host_verb_once_installed() {
        let (store, surface) = open();
        let spec_json = serde_json::to_string(&fixture_host_spec()).unwrap();

        let before = surface.http_now(
            "POST".into(),
            "/api/surface/validate".into(),
            spec_json.clone(),
        );
        assert_eq!(before.status, 400, "{}", before.body);
        assert!(before.body.contains(FAKE_VERB), "{}", before.body);

        store.set_verb_host(Box::new(FakeVerbHost));

        let after = surface.http_now("POST".into(), "/api/surface/validate".into(), spec_json);
        assert_eq!(after.status, 200, "{}", after.body);
    }

    #[test]
    fn render_resolves_the_signal_explorer_with_no_placeholder() {
        let (store, surface) = open();
        let id = create_signal_explorer(&store);

        let tree_json = surface.render_now(id, None).expect("render");
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
        surface.render_now(id.clone(), None).expect("first render");

        let event = serde_json::json!({
            "widget": "n0.1.1", // root/column -> row(1) -> bins field(1)
            "kind": "change",
            "value": 40
        })
        .to_string();
        let dispatched_json = surface
            .dispatch_now(id.clone(), None, event)
            .expect("dispatch");
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

        let rendered = surface.render_now(id, None).expect("render after dispatch");
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

        let listed = surface.http_now("GET".into(), "/api/surface".into(), String::new());
        assert_eq!(listed.status, 200);
        assert!(listed.body.contains(&id), "{}", listed.body);

        // Parses fine as a `SurfaceSpec` (unlike a structurally incomplete
        // document, which fails at JSON decode and is a DIFFERENT 400 body
        // — see `http_validate`'s own docs) but fails `impress_surface::validate`'s
        // very first check: `surface` must be exactly `SURFACE_VERSION`.
        let mut bad_spec = example_signal_explorer();
        bad_spec.surface = "0.1".to_string();
        let validated = surface.http_now(
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

    /// The live case behind `Executor::pane_showing`: `surface_show` ran
    /// through one instance (the service's, or the app's pane view), and a
    /// `publish`/`open` effect arrives through ANOTHER `SharedSurface` handle
    /// on the same surface — an HTTP dispatch. Before, that handle's instance
    /// had no pane and refused; now it recovers the pane from the layout.
    #[test]
    fn an_effect_on_a_fresh_handle_finds_the_pane_the_layout_shows() {
        use impress_surface_service::dto::{ShowTargetDto, SplitTargetDto};
        use impress_surface_service::{DefaultImpressSurfaceService, ImpressSurfaceService};

        let (store, _first) = open();
        let id = create_signal_explorer(&store);

        // Shown through the SERVICE — a different registry from any handle's.
        let service = DefaultImpressSurfaceService::with_store(store.core());
        let shown = runtime().block_on(service.surface_show(
            id.clone(),
            ShowTargetDto {
                role: None,
                tile: None,
                split: Some(SplitTargetDto {
                    direction: "horizontal".into(),
                    from_focused: true,
                }),
            },
            Some(impress_surface_service::runtime::SURFACE_APP_ID.into()),
            None,
        ));
        assert!(shown.ok, "{}", shown.message);

        // A brand-new handle, as the HTTP bridge opens per request.
        let fresh = SharedSurface::open(store.clone(), "test-host".into());
        fresh
            .render_now(id.clone(), None)
            .expect("render on the fresh handle");
        let event = serde_json::json!({
            "widget": "n0.3", // the table, whose on_select publishes
            "kind": "select",
            "value": ["2b995442-c45a-4922-8c22-600d98900fc1"]
        })
        .to_string();
        let out = fresh
            .dispatch_now(id, None, event)
            .expect("dispatch on the fresh handle");
        let dispatched: serde_json::Value = serde_json::from_str(&out).unwrap();
        let effects = dispatched["effects"].as_array().expect("effects");
        assert_eq!(effects.len(), 1, "{out}");
        assert_eq!(effects[0]["kind"], "publish", "{out}");
        assert_eq!(
            effects[0]["ok"],
            serde_json::json!(true),
            "the effect must find the pane the layout shows: {out}"
        );
    }

    // ── Wave 7 T2 ──────────────────────────────────────────────────────────

    fn titled_spec(title: &str) -> String {
        serde_json::json!({
            "surface": "1.0", "name": "T2 fixture", "state": {},
            "root": { "column": [ { "text": title, "id": "title" } ] }
        })
        .to_string()
    }

    fn created_id(reply: &SharedHttpReply) -> String {
        let v: serde_json::Value = serde_json::from_str(&reply.body).unwrap();
        v["id"].as_str().expect("an id").to_string()
    }

    /// RS-S1 / SK-K1 / AC-F1 in the app: the pane's handle and a handle the
    /// HTTP bridge opens per request share the store's registry, and an
    /// update through either — or through another process — is what the
    /// other renders next.
    #[test]
    fn an_update_through_any_handle_or_process_is_what_the_pane_renders() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("t2_handles.sqlite");
        let store = SharedStore::open(path.to_str().unwrap().into()).unwrap();
        let pane = SharedSurface::open(store.clone(), "test-host".into());
        let bridge = SharedSurface::open(store.clone(), "test-host".into());
        assert!(Arc::ptr_eq(&pane.core.registry, &bridge.core.registry));

        let id = created_id(&bridge.http_now(
            "POST".into(),
            "/api/surface".into(),
            titled_spec("first"),
        ));
        assert!(pane.render_now(id.clone(), None).unwrap().contains("first"));

        let put = SharedSurface::open(store.clone(), "test-host".into()).http_now(
            "PUT".into(),
            format!("/api/surface/{id}?expected_revision=1"),
            titled_spec("second"),
        );
        assert_eq!(put.status, 200, "{}", put.body);
        assert!(pane
            .render_now(id.clone(), None)
            .unwrap()
            .contains("second"));

        // Another process on the same file (impress-mcp).
        let mcp = SharedStore::open(path.to_str().unwrap().into()).unwrap();
        let mcp_surfaces = SurfaceStore::new(mcp.core());
        let spec: SurfaceSpec = serde_json::from_str(&titled_spec("third")).unwrap();
        mcp_surfaces
            .update(id.parse().unwrap(), &spec, None, Some(2), ActorKind::Agent)
            .unwrap();
        let third = pane.render_now(id.clone(), None).unwrap();
        assert!(third.contains("third"), "{third}");

        // A stale writer is refused with 409 and writes nothing.
        let stale = bridge.http_now(
            "PUT".into(),
            format!("/api/surface/{id}?expected_revision=2"),
            titled_spec("lost"),
        );
        assert_eq!(stale.status, 409, "{}", stale.body);
        assert!(pane.render_now(id, None).unwrap().contains("third"));
    }

    fn papers_spec() -> SurfaceSpec {
        serde_json::from_value(serde_json::json!({
            "surface": "1.0", "name": "Papers", "state": {},
            "sources": { "papers": { "query": { "kinds": ["publication"] } } },
            "root": { "table": { "columns": ["title"], "rows": "{{source.papers}}" },
                      "id": "papers" }
        }))
        .unwrap()
    }

    fn insert_paper(store: &SqliteItemStore, title: &str) {
        let mut payload = std::collections::BTreeMap::new();
        payload.insert("title".to_string(), ItemValue::String(title.into()));
        let now = chrono::Utc::now();
        store
            .insert(impress_core::item::Item {
                id: uuid::Uuid::new_v4(),
                schema: "imbib/bibliography-entry".into(),
                payload,
                created: now,
                modified: now,
                author: "test".into(),
                author_kind: ActorKind::Human,
                logical_clock: 0,
                origin: None,
                canonical_id: None,
                tags: vec![],
                flag: None,
                is_read: false,
                is_starred: false,
                priority: impress_core::item::Priority::None,
                visibility: impress_core::item::Visibility::Private,
                message_type: None,
                produced_by: None,
                version: None,
                batch_id: None,
                references: vec![],
                parent: None,
            })
            .unwrap();
    }

    /// RS-S2 / AC-F16 through the feed: a paper written in this process, and
    /// one written by another connection, each re-run the query source that
    /// reads papers — the pane is told, and its next render shows the row.
    #[test]
    fn a_paper_written_anywhere_reaches_a_rendered_query_source() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("t2_feed.sqlite");
        let store = SharedStore::open(path.to_str().unwrap().into()).unwrap();
        let surface = SharedSurface::open(store.clone(), "test-host".into());
        surface.set_debounce_ms(20);
        surface.set_external_poll_ms(20);
        let id = SurfaceStore::new(store.core())
            .create(&papers_spec(), None, &[], ActorKind::Agent)
            .unwrap()
            .id
            .to_string();
        let empty = surface.render_now(id.clone(), None).unwrap();
        assert!(!empty.contains("In process"), "{empty}");

        let (tx, rx) = mpsc::channel::<Vec<String>>();
        struct Recorder(mpsc::Sender<Vec<String>>);
        impl SharedSurfaceListener for Recorder {
            fn surfaces_changed(&self, ids: Vec<String>) {
                let _ = self.0.send(ids);
            }
        }
        surface.subscribe(Box::new(Recorder(tx))).unwrap();

        insert_paper(&store.core(), "In process");
        let told = rx
            .recv_timeout(std::time::Duration::from_secs(2))
            .expect("the feed reports the surface whose query reads papers");
        assert_eq!(told, vec![id.clone()]);
        let shown = surface.render_now(id.clone(), None).unwrap();
        assert!(shown.contains("In process"), "{shown}");

        let other = SharedStore::open(path.to_str().unwrap().into()).unwrap();
        insert_paper(&other.core(), "Another process");
        let told = rx
            .recv_timeout(std::time::Duration::from_secs(2))
            .expect("another connection's paper is seen by the poll");
        assert_eq!(told, vec![id.clone()]);
        let shown = surface.render_now(id, None).unwrap();
        assert!(shown.contains("Another process"), "{shown}");

        // A write nobody's query reads tells nobody.
        let mut unrelated = std::collections::BTreeMap::new();
        unrelated.insert("x".to_string(), ItemValue::Int(1));
        store
            .core()
            .insert(impress_core::item::Item {
                schema: "manuscript".into(),
                payload: unrelated,
                id: uuid::Uuid::new_v4(),
                ..placeholder_item()
            })
            .unwrap();
        assert!(rx
            .recv_timeout(std::time::Duration::from_millis(300))
            .is_err());
        surface.unsubscribe();
    }

    fn placeholder_item() -> impress_core::item::Item {
        let now = chrono::Utc::now();
        impress_core::item::Item {
            id: uuid::Uuid::nil(),
            schema: String::new(),
            payload: Default::default(),
            created: now,
            modified: now,
            author: "test".into(),
            author_kind: ActorKind::Human,
            logical_clock: 0,
            origin: None,
            canonical_id: None,
            tags: vec![],
            flag: None,
            is_read: false,
            is_starred: false,
            priority: impress_core::item::Priority::None,
            visibility: impress_core::item::Visibility::Private,
            message_type: None,
            produced_by: None,
            version: None,
            batch_id: None,
            references: vec![],
            parent: None,
        }
    }

    /// A verb host as slow as an HTTP round trip to a busy sibling app.
    struct SlowVerbHost;

    impl SharedVerbHost for SlowVerbHost {
        fn has_verb(&self, name: String) -> bool {
            name == FAKE_VERB
        }
        fn call_verb(
            &self,
            _name: String,
            args_json: String,
        ) -> std::result::Result<String, SharedStoreError> {
            std::thread::sleep(std::time::Duration::from_millis(400));
            Ok(format!("{{\"echoed\": {args_json}}}"))
        }
    }

    /// SK-K2 / AC-F10, the FFI half: while a render waits on a slow verb, the
    /// thread that awaits it keeps running other work — the way the main
    /// actor keeps drawing while a pane's render is in flight. Before, the
    /// export was a `block_on` and the caller's thread sat in it.
    #[test]
    fn a_slow_verb_does_not_hold_the_awaiting_thread() {
        let (store, surface) = open();
        store.set_verb_host(Box::new(SlowVerbHost));
        let id = create_fixture_surface(&store);

        let driver = tokio::runtime::Builder::new_current_thread()
            .enable_time()
            .build()
            .unwrap();
        let ticks = driver.block_on(async {
            let ticks = Arc::new(AtomicU64::new(0));
            let counter = ticks.clone();
            let ticker = tokio::spawn(async move {
                loop {
                    tokio::time::sleep(std::time::Duration::from_millis(10)).await;
                    counter.fetch_add(1, Ordering::SeqCst);
                }
            });
            let tree = surface.render(id, None).await.expect("render");
            assert!(tree.contains("42"), "{tree}");
            ticker.abort();
            ticks.load(Ordering::SeqCst)
        });
        assert!(
            ticks >= 10,
            "the awaiting thread ran only {ticks} ticks during a 400 ms verb"
        );
    }

    // ── wave 7 T5: codes, the dispatch rule, the actor, the log bridge ──

    /// A button that emits (always works) and publishes (fails: no layout
    /// shows the surface in a bare store).
    fn publish_spec() -> SurfaceSpec {
        serde_json::from_value(serde_json::json!({
            "surface": "1.0",
            "name": "T5",
            "state": { "clicked": false },
            "root": { "column": [
                { "button": { "label": "Go", "on_click": [
                    { "set": { "path": "state.clicked", "value": true } },
                    { "emit": { "name": "went", "payload": {} } },
                    { "publish": { "ids": "state.clicked" } }
                ] }, "id": "go" }
            ] }
        }))
        .unwrap()
    }

    const CLICK: &str = r#"{"widget":"go","kind":"click","value":null}"#;

    fn create(store: &Arc<SharedStore>, spec: &SurfaceSpec) -> String {
        SurfaceStore::new(store.core())
            .create(spec, None, &[], ActorKind::Agent)
            .unwrap()
            .id
            .to_string()
    }

    #[test]
    fn http_refusals_carry_a_code_and_the_status_it_maps_to() {
        let (_store, surface) = open();
        let missing = surface.http_now(
            "GET".into(),
            "/api/surface/00000000-0000-4000-8000-000000000000".into(),
            String::new(),
        );
        assert_eq!(missing.status, 404, "{}", missing.body);
        let body: serde_json::Value = serde_json::from_str(&missing.body).unwrap();
        assert_eq!(body["code"], "not-found");

        let malformed = surface.http_now("GET".into(), "/api/surface/nope".into(), String::new());
        assert_eq!(malformed.status, 400, "{}", malformed.body);
        let body: serde_json::Value = serde_json::from_str(&malformed.body).unwrap();
        assert_eq!(body["code"], "invalid-argument");
    }

    /// A dispatch whose effect failed answers `ok: false`, `effect-failed`,
    /// 422, with the tree and every effect's own outcome — it used to answer
    /// 200 "dispatched; 2 effect(s)" (review RS-S12, AC-F11).
    #[test]
    fn an_http_dispatch_whose_effect_failed_is_422_with_each_outcome() {
        let (store, surface) = open();
        let id = create(&store, &publish_spec());
        let reply = surface.http_now(
            "POST".into(),
            format!("/api/surface/{id}/dispatch"),
            CLICK.into(),
        );
        assert_eq!(reply.status, 422, "{}", reply.body);
        let body: serde_json::Value = serde_json::from_str(&reply.body).unwrap();
        assert_eq!(body["ok"], false);
        assert_eq!(body["code"], "effect-failed");
        assert_eq!(body["effects_failed"], 1);
        assert_eq!(body["effects"][0]["kind"], "emit");
        assert_eq!(body["effects"][0]["ok"], true);
        assert_eq!(body["effects"][1]["kind"], "publish");
        assert_eq!(body["effects"][1]["code"], "no-pane");
        assert!(body["tree"].is_object(), "the tree still comes back");
    }

    /// The pane's dispatch is the human's; the HTTP route's is the agent's —
    /// in the events an agent waits on, and in the state row's author.
    #[test]
    fn the_panes_dispatch_is_recorded_as_the_human() {
        let (store, surface) = open();
        let id = create(&store, &publish_spec());
        surface
            .dispatch_now(id.clone(), None, CLICK.into())
            .expect("the pane's dispatch");
        surface.http_now(
            "POST".into(),
            format!("/api/surface/{id}/dispatch"),
            CLICK.into(),
        );
        let events = surface.http_now(
            "GET".into(),
            format!("/api/surface/{id}/events"),
            String::new(),
        );
        let body: serde_json::Value = serde_json::from_str(&events.body).unwrap();
        let actors: Vec<&str> = body["events"]
            .as_array()
            .unwrap()
            .iter()
            .map(|e| e["actor"].as_str().unwrap())
            .collect();
        assert_eq!(actors, vec!["human", "agent"], "{}", events.body);
    }

    #[test]
    fn surface_errors_reach_swift_with_their_code() {
        let (_store, surface) = open();
        let err = surface
            .render_now("00000000-0000-4000-8000-000000000000".into(), None)
            .unwrap_err();
        match err {
            SharedSurfaceError::Surface { code, .. } => assert_eq!(code, "not-found"),
            other => panic!("{other:?}"),
        }
    }

    /// Rust's own lines reach the host's Console under `surface`: a dispatch
    /// and its failed effect (review RS-S11, AC-F18).
    #[test]
    fn a_dispatch_and_its_failed_effect_are_logged_under_surface() {
        let sink = crate::log_bridge::tests::captured();
        let (store, surface) = open();
        let id = create(&store, &publish_spec());
        surface
            .dispatch_now(id.clone(), None, CLICK.into())
            .unwrap();
        let lines = sink.0.lock().unwrap().clone();
        let mine: Vec<&(String, String, String)> =
            lines.iter().filter(|l| l.2.contains(&id)).collect();
        assert!(
            mine.iter()
                .any(|(level, category, message)| level == "warning"
                    && category == "surface"
                    && message.contains("publish effect failed [no-pane]")),
            "{mine:#?}"
        );
        assert!(
            mine.iter()
                .any(|(_, category, message)| category == "surface"
                    && message.contains("human dispatch applied, but not ok [effect-failed]")),
            "{mine:#?}"
        );
    }
}
