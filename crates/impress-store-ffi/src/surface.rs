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
//! # Which pane, in which app
//!
//! [`impress_surface_service::runtime::SurfaceRuntime::pane`] is what
//! `publish`/`open` effects and param binding need. [`Self::render`] and
//! [`Self::dispatch`] take the calling pane's tile, and the handle knows the
//! app it serves ([`SharedSurface::open`]'s `app_id`): the pane is recorded
//! as `(app_id, this handle's host as the device, tile)`, so a publish from a
//! surface in implore's window selects on implore's channel (review RS-S4,
//! AC-F6 — it used to be impress's, whatever window showed it). A handle
//! opened with no app (an HTTP bridge in a process with no layout tree)
//! finds the pane that shows a surface in every app's layout on this device.
//!
//! # `host`
//!
//! The state instance, resolved once at [`SharedSurface::open`] with the rule
//! `SharedLayout`'s `device` uses ([`impress_layout_service::resolve_device`]):
//! every pane on this device that shows a surface shares one state row and
//! one runtime, and an agent that leaves `host` out reaches the same one
//! (`impress-surface-service`'s module docs, "host"). No FFI call takes a
//! `host`; the HTTP routes take `?host=` like the verbs do.
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
//!
//! A hard delete in another process leaves no row to read, so the feed
//! looks for the absence instead: a surface row by diffing the (few) surface
//! ids whenever `data_version` moves (reported `deleted`), and a kind a
//! query source reads by its row count (the sources that read it re-run) —
//! see `DomainPoll`.

use std::collections::BTreeSet;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use impress_core::event::StoreMutation;
use impress_core::item::{ActorKind, ItemId, Value as ItemValue};
use impress_core::schemas::{SURFACE_SCHEMA_REF, SURFACE_STATE_SCHEMA_REF};
use impress_core::sqlite_store::SqliteItemStore;
use impress_core::store::ItemStore;
use impress_layout_service::resolve_device;
use impress_service_core::refusal::codes;
use impress_service_core::Refusal;
use impress_surface_service::runtime::actor_name;
use impress_surface_service::store::actor_from;

use impress_surface::Event;
use impress_surface_service::dto::{SurfaceDispatchResult, SurfaceRenderResult};
use impress_surface_service::{
    call_verb_on, DefaultExecutor, DefaultImpressSurfaceService, ImpressSurfaceService, PaneHandle,
    SessionRegistry, SurfaceStore, VerbHost,
};

use crate::ui_feed::{self, ExternalPoll, Feed};
use crate::SharedStore;

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

/// A refusal as an HTTP reply: the wire's refusal envelope, `{"ok": false,
/// "code", "message", "wire_version": 1}`, at the status the code maps to
/// (`impress_service_core::refusal::http_status`).
fn refusal_reply(refusal: &Refusal) -> SharedHttpReply {
    log::info!(
        target: "surface",
        "http refused [{}]: {}",
        refusal.code,
        refusal.message
    );
    reply(
        refusal.http_status(),
        serde_json::json!({
            "ok": false,
            "code": refusal.code,
            "message": refusal.message,
            "wire_version": impress_service_core::wire::WIRE_VERSION,
        })
        .to_string(),
    )
}

fn error_reply(code: &str, message: impl Into<String>) -> SharedHttpReply {
    refusal_reply(&Refusal::new(code, message))
}

// ─── The invalidation listener ───────────────────────────────────────────

/// One surface that changed, and what about it moved — so a pane can tell
/// the feed's echo of its own write from anyone else's (review SK-K15): it
/// compares `revision` and `state_revision` with the ones its last render or
/// dispatch reply carried, and skips the render when neither is newer and
/// `sources_changed` is false.
#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SharedSurfaceChange {
    pub id: String,
    /// The spec's revision after the change, when the spec row moved (or
    /// was deleted: then the surface is gone and this is `None` with
    /// `deleted` set).
    pub revision: Option<u64>,
    /// The state row's revision after the change, when this handle's host's
    /// state row moved. Another host's state row is not reported.
    pub state_revision: Option<u64>,
    /// A store write named a kind one of its query sources reads: those
    /// sources re-run on the next render, whoever wrote.
    pub sources_changed: bool,
    pub deleted: bool,
}

/// What Swift implements to be told a surface changed — its spec, this
/// host's state, or data a query source reads. Arrives on the feed's own
/// thread; hop to the main actor before touching a view (same rule
/// `SharedLayoutListener` documents). An event appended to a surface's ring
/// changes nothing a render shows and is not reported.
#[cfg_attr(feature = "native", uniffi::export(callback_interface))]
pub trait SharedSurfaceListener: Send + Sync {
    /// Every surface that changed since the last delivery, one entry each,
    /// coalesced over the debounce window.
    fn surfaces_changed(&self, changes: Vec<SharedSurfaceChange>);
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
/// Why a [`SharedVerbHost`] did not answer a verb — structured, so Rust
/// words the refusal and gives it its code (review RS-S19: every host
/// failure used to arrive as a generic storage error, "Storage error:
/// imbib-x_y: imbib is not running, …").
#[cfg_attr(feature = "native", derive(uniffi::Error))]
#[derive(Debug, Clone, thiserror::Error)]
pub enum SharedVerbHostError {
    /// The app that owns the verb is not running (it may have quit since it
    /// was last reached). Refused as `host-unavailable`.
    #[error("{app} is not running, so {verb} is unavailable")]
    Unavailable { app: String, verb: String },
    /// The verb ran, or was reached, and failed. Refused as `verb-failed`.
    #[error("{message}")]
    Failed { message: String },
}

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
    ) -> std::result::Result<String, SharedVerbHostError>;
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
            match e {
                SharedVerbHostError::Unavailable { app, verb } => Refusal::new(
                    codes::HOST_UNAVAILABLE,
                    format!(
                        "{app} is not running, so {verb} is unavailable — open {app} to use it"
                    ),
                ),
                SharedVerbHostError::Failed { message } => {
                    Refusal::new(codes::VERB_FAILED, format!("{name}: {message}"))
                }
            }
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
    /// The app this handle serves (its panes' layout); empty for a handle
    /// that serves none — see the module docs.
    app_id: String,
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
    /// Bind to the surfaces of the given `store`, for the app `app_id` (the
    /// app whose window this handle's panes are in: `controller.appID`; empty
    /// for a handle that serves no window). `host` defaults to the layout
    /// device id when empty — see the module docs.
    #[cfg_attr(feature = "native", uniffi::constructor)]
    pub fn open(store: Arc<SharedStore>, host: String, app_id: String) -> Arc<Self> {
        let core = store.core();
        let host = resolve_device(Some(host.trim()).filter(|h| !h.is_empty()));
        let app_id = app_id.trim().to_string();
        // See `HostAdapter`'s docs: it reads `store`'s verb-host slot fresh
        // on every call, so a `set_verb_host` that runs after this `open`
        // still reaches the executor and the service built right here.
        let verb_host: Arc<dyn VerbHost> = Arc::new(HostAdapter {
            slot: store.verb_host_slot(),
        });
        let registry = store.surface_sessions();
        let executor =
            DefaultExecutor::with_store_and_sessions(core.clone(), store.layout_sessions())
                .with_verb_host(verb_host.clone())
                .with_app(app_id.clone());
        Arc::new(SharedSurface {
            core: SurfaceCore {
                surfaces: SurfaceStore::new(core.clone()),
                // The HTTP routes run the verbs through this service, which
                // runs sources, effects and `surface_show` through the SAME
                // executor the panes use: one layout registry, one verb
                // host, one app.
                service: DefaultImpressSurfaceService::with_store_and_sessions(
                    core.clone(),
                    registry.clone(),
                )
                .with_verb_host(verb_host)
                .with_executor(executor.clone()),
                executor,
                registry,
                store: core,
                host,
                app_id,
            },
            debounce_ms: AtomicU64::new(ui_feed::DEFAULT_DEBOUNCE_MS),
            startup_grace_secs: AtomicU64::new(0),
            external_poll_ms: AtomicU64::new(ui_feed::EXTERNAL_POLL_MS),
            feed: Mutex::new(None),
        })
    }

    /// The app this handle serves; empty when none.
    pub fn app_id(&self) -> String {
        self.core.app_id.clone()
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

    /// Render `(surface_id, this object's host)` for the pane `pane` of this
    /// handle's app, OFF the caller's thread (see the struct docs): runs
    /// every stale source, binds the surface's params from the pane, and
    /// answers [`SurfaceRenderResult`]'s JSON — `{"ok", "code", "message",
    /// "tree", "source_errors", "revision", "state_revision", "params",
    /// "wire_version"}`, the same document `surface_render` returns over MCP
    /// and HTTP. A refusal (no such surface) is `ok: false` in that document,
    /// not an `Err`.
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
    /// "source_errors", "revision", "state_revision", "params",
    /// "wire_version"}`), so Swift and MCP read one document; `ok` is true
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

    /// Route one `/api/surface/…` request, OFF the caller's thread. Every
    /// route runs the surface verb of the same name, through the same strict
    /// argument parser MCP uses, and answers that verb's result unchanged —
    /// `docs/agent-surfaces.md` has the table. The verb's arguments are the
    /// path's id, the query string (`?host=`, `?after_seq=`, `?timeout_ms=`,
    /// `?expected_revision=`, `?params=` as JSON), and the JSON body; an
    /// argument the verb does not take is refused with `invalid-argument`
    /// naming it. The status is 200 when `ok`, else the status its `code`
    /// maps to (`impress_service_core::refusal::http_status`).
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
        // Both cursors start HERE, before the thread does: a write or a
        // delete made after `subscribe` returns is one the feed reports.
        let store = &self.core.store;
        let external = ExternalPoll::baseline(store).track_deletes(store, SURFACE_SCHEMA_REF);
        let domain = DomainPoll::baseline(store, &self.core.registry.watched_refs());
        let worker = SurfaceFeed {
            running: running.clone(),
            external,
            domain,
            listener: Arc::from(listener),
            store: self.core.store.clone(),
            surfaces: self.core.surfaces.clone(),
            host: self.core.host.clone(),
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
        let dto = match self.render_dto(surface_id, pane).await {
            Ok(dto) => dto,
            Err(refusal) => SurfaceRenderResult::refused(refusal),
        };
        serde_json::to_string(&dto).map_err(SharedSurfaceError::json)
    }

    async fn render_dto(
        &self,
        surface_id: &str,
        pane: Option<u64>,
    ) -> std::result::Result<SurfaceRenderResult, Refusal> {
        let id = parse_surface_id(surface_id).map_err(|e| e.refusal())?;
        let pane = self.pane_handle(pane)?;
        let executor = self.executor.clone();
        let (tree, source_errors, revisions) = self
            .registry
            .with(&self.surfaces, id, &self.host, move |rt| {
                Box::pin(async move {
                    if let Some(pane) = pane {
                        rt.pane = Some(pane);
                    }
                    rt.bind_params(&executor, None).await?;
                    let tree = rt.render(&executor).await;
                    Ok((tree, rt.source_error_list(), rt.revisions()))
                })
            })
            .await?;
        Ok(SurfaceRenderResult {
            ok: true,
            code: None,
            message: "rendered".to_string(),
            tree: Some(tree),
            source_errors,
            revisions,
            wire_version: impress_service_core::wire::WIRE_VERSION,
        })
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
        let executor = self.executor.clone();
        let writer = self.surfaces.clone();
        let outcome = match self.pane_handle(pane) {
            Err(refusal) => Err(refusal),
            Ok(pane) => {
                self.registry
                    .with(&self.surfaces, id, &self.host, move |rt| {
                        Box::pin(async move {
                            if let Some(pane) = pane {
                                rt.pane = Some(pane);
                            }
                            rt.bind_params(&executor, None).await?;
                            let (tree, effects) =
                                rt.dispatch(&executor, &writer, &event, actor).await?;
                            Ok((tree, effects, rt.source_error_list(), rt.revisions()))
                        })
                    })
                    .await
            }
        };
        let dto = match outcome {
            Ok((tree, effects, source_errors, revisions)) => {
                SurfaceDispatchResult::dispatched(tree, effects, source_errors, revisions)
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

    /// The pane a render or dispatch comes from, as `(this handle's app,
    /// this handle's host as the device, tile)`. A tile with no app to put
    /// it in is refused: which layout it is in would be a guess.
    fn pane_handle(&self, tile: Option<u64>) -> std::result::Result<Option<PaneHandle>, Refusal> {
        match tile {
            None => Ok(None),
            Some(_) if self.app_id.is_empty() => Err(Refusal::invalid_argument(
                "a pane was given, but this handle serves no app: open it with the app id \
                 whose window the pane is in",
            )),
            Some(tile) => Ok(Some(PaneHandle {
                app_id: self.app_id.clone(),
                device: self.host.clone(),
                tile,
            })),
        }
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
        let body: Option<serde_json::Value> = if body.trim().is_empty() {
            None
        } else {
            match serde_json::from_str(body) {
                Ok(v) => Some(v),
                Err(e) => {
                    return error_reply(
                        codes::INVALID_ARGUMENT,
                        format!("the request body is not JSON: {e}"),
                    )
                }
            }
        };
        let rest = &segments[2..];
        let Some((verb, id, body_args)) = route_of(&method, rest, body) else {
            return error_reply(
                codes::NOT_FOUND,
                format!("no route {method} {path_only} (docs/agent-surfaces.md lists them)"),
            );
        };
        let mut args = match query_args(query) {
            Ok(args) => args,
            Err(refusal) => return refusal_reply(&refusal),
        };
        if let Some(id) = id {
            args.insert("id".into(), serde_json::Value::String(id));
        }
        match body_args {
            Some(serde_json::Value::Object(map)) => {
                for (key, value) in map {
                    if args.contains_key(&key) {
                        return error_reply(
                            codes::INVALID_ARGUMENT,
                            format!("`{key}` is given twice (path or query, and body)"),
                        );
                    }
                    args.insert(key, value);
                }
            }
            Some(other) => {
                return error_reply(
                    codes::INVALID_ARGUMENT,
                    format!("the request body must be a JSON object, got {other}"),
                )
            }
            None => {}
        }
        // This handle's own instance unless the caller names another: its
        // host (the state instance its panes use), and for `show` its app
        // and device (the window this process draws).
        let fill =
            |args: &mut serde_json::Map<String, serde_json::Value>, key: &str, value: &str| {
                if !value.is_empty() && !args.contains_key(key) {
                    args.insert(key.into(), serde_json::Value::String(value.to_string()));
                }
            };
        match verb {
            "surface_show" => {
                fill(&mut args, "app_id", &self.app_id);
                fill(&mut args, "device", &self.host);
            }
            "surface_render" | "surface_state_get" | "surface_state_set" | "surface_dispatch"
            | "surface_events" | "surface_wait" => fill(&mut args, "host", &self.host),
            _ => {}
        }
        let Some(answer) = call_verb_on(&self.service, verb, serde_json::Value::Object(args)).await
        else {
            return error_reply(codes::INTERNAL, format!("no verb {verb}"));
        };
        let status = match (
            answer.get("ok").and_then(serde_json::Value::as_bool),
            answer.get("code").and_then(serde_json::Value::as_str),
        ) {
            (Some(false), Some(code)) => impress_service_core::refusal::http_status(code),
            (Some(false), None) => 422,
            _ => 200,
        };
        if status != 200 {
            log::info!(
                target: "surface",
                "http {method} {path_only} → {status} [{}]: {}",
                answer.get("code").and_then(serde_json::Value::as_str).unwrap_or("?"),
                answer.get("message").and_then(serde_json::Value::as_str).unwrap_or("")
            );
        }
        reply(status, answer.to_string())
    }
}

/// The route table: `(verb, id from the path, arguments from the body)`
/// for one `/api/surface/…` request (after `/api/surface`). Two bodies have
/// a shorthand the verb's own shape does not: a spec on its own (it has a
/// `surface` key; the arguments never do) is `{"spec": …}`, and an event on
/// its own (a `widget` key) is `{"event": …}`.
fn route_of(
    method: &str,
    rest: &[&str],
    body: Option<serde_json::Value>,
) -> Option<(&'static str, Option<String>, Option<serde_json::Value>)> {
    fn spec_body(body: Option<serde_json::Value>) -> Option<serde_json::Value> {
        match body {
            Some(v) if v.get("surface").is_some() => Some(serde_json::json!({ "spec": v })),
            other => other,
        }
    }
    fn event_body(body: Option<serde_json::Value>) -> Option<serde_json::Value> {
        match body {
            Some(v) if v.get("widget").is_some() => Some(serde_json::json!({ "event": v })),
            other => other,
        }
    }
    let id = |s: &&str| Some(s.to_string());
    Some(match (method, rest) {
        ("GET", []) => ("surface_list", None, body),
        ("POST", []) => ("surface_create", None, spec_body(body)),
        ("GET", ["schema"]) => ("surface_schema", None, body),
        ("GET", ["examples"]) => ("surface_examples", None, body),
        ("POST", ["validate"]) => ("surface_validate", None, spec_body(body)),
        ("GET", [s]) => ("surface_get", id(s), body),
        ("PUT", [s]) => ("surface_update", id(s), spec_body(body)),
        ("DELETE", [s]) => ("surface_delete", id(s), body),
        ("POST", [s, "show"]) => ("surface_show", id(s), body),
        ("GET", [s, "render"]) => ("surface_render", id(s), body),
        ("POST", [s, "dispatch"]) => ("surface_dispatch", id(s), event_body(body)),
        ("GET", [s, "state"]) => ("surface_state_get", id(s), body),
        ("PUT", [s, "state"]) => ("surface_state_set", id(s), body),
        ("GET", [s, "events"]) => ("surface_events", id(s), body),
        ("GET", [s, "wait"]) => ("surface_wait", id(s), body),
        _ => return None,
    })
}

/// A query string as verb arguments: every key is an argument name (the
/// verb refuses one it does not take), `after_seq`/`timeout_ms`/
/// `expected_revision` are numbers, `params` is a JSON object, and anything
/// else is a string. Values are percent-decoded.
fn query_args(
    query: &str,
) -> std::result::Result<serde_json::Map<String, serde_json::Value>, Refusal> {
    let mut args = serde_json::Map::new();
    for pair in query.split('&').filter(|p| !p.is_empty()) {
        let (key, raw) = pair.split_once('=').unwrap_or((pair, ""));
        let key = percent_decode(key);
        let raw = percent_decode(raw);
        let value = match key.as_str() {
            "after_seq" | "timeout_ms" | "expected_revision" => raw
                .parse::<u64>()
                .map(serde_json::Value::from)
                .map_err(|_| Refusal::invalid_argument(format!("?{key}={raw} is not a number")))?,
            "params" => serde_json::from_str(&raw).map_err(|e| {
                Refusal::invalid_argument(format!("?params= must be a JSON object: {e}"))
            })?,
            _ => serde_json::Value::String(raw),
        };
        if args.insert(key.clone(), value).is_some() {
            return Err(Refusal::invalid_argument(format!("?{key} is given twice")));
        }
    }
    Ok(args)
}

fn percent_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'%' if i + 2 < bytes.len() => match u8::from_str_radix(&s[i + 1..i + 3], 16) {
                Ok(b) => {
                    out.push(b);
                    i += 3;
                    continue;
                }
                Err(_) => out.push(b'%'),
            },
            b'+' => out.push(b' '),
            b => out.push(b),
        }
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

// ─── The feed's worker ───────────────────────────────────────────────────

struct SurfaceFeed {
    running: Arc<AtomicBool>,
    /// Other connections' `impress/ui/surface*` writes, and hard deletes
    /// of surface rows (by id diff: there are few).
    external: ExternalPoll,
    /// Other connections' writes and deletes of the kinds query sources
    /// read.
    domain: DomainPoll,
    listener: Arc<dyn SharedSurfaceListener>,
    store: Arc<SqliteItemStore>,
    /// To read a surface row's revision for a change.
    surfaces: SurfaceStore,
    /// Only this host's state rows are this handle's panes' state.
    host: String,
    /// The store's one surface registry: the feed marks the runtimes whose
    /// query sources read a kind that was written (RS-S2) and reports those
    /// surfaces as changed.
    registry: Arc<SessionRegistry>,
    debounce: Duration,
    grace: Duration,
    external_poll: Duration,
}

impl SurfaceFeed {
    fn run(mut self, rx: std::sync::mpsc::Receiver<StoreMutation>) {
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
        let mut held: std::collections::BTreeMap<String, SharedSurfaceChange> =
            std::collections::BTreeMap::new();
        let mut grace_over = self.grace.is_zero();

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
                let mutations = self.external.check(&self.store, SURFACE_UI_PREFIX);
                if !mutations.is_empty() {
                    pending.extend(mutations);
                    touched = true;
                }
                let watched = self.registry.watched_refs();
                let refs = self.domain.check(&self.store, &watched);
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
                    if let Some(change) = self.change_of(&mutation) {
                        if change.deleted {
                            // Gone in another process too: its runtimes go
                            // now, not on their next (refused) call.
                            self.registry.forget_surface(mutation.item_id);
                        }
                        merge(&mut held, change);
                    }
                }
                for id in self
                    .registry
                    .invalidate_refs(&std::mem::take(&mut pending_refs))
                {
                    merge(
                        &mut held,
                        SharedSurfaceChange {
                            id: id.to_string(),
                            revision: None,
                            state_revision: None,
                            sources_changed: true,
                            deleted: false,
                        },
                    );
                }
                burst_started = None;
                last_seen = None;
            }

            if !grace_over && started.elapsed() >= self.grace {
                grace_over = true;
            }
            if grace_over && !held.is_empty() {
                let changes: Vec<SharedSurfaceChange> =
                    std::mem::take(&mut held).into_values().collect();
                log::debug!(
                    target: "surface",
                    "feed: {} surface(s) changed: {:?}",
                    changes.len(),
                    changes
                );
                self.listener.surfaces_changed(changes);
            }
        }
    }
}

/// The cross-process half of RS-S2: which of the schema refs some live query
/// source reads did ANOTHER connection (another app, `impress-mcp`) write
/// OR DELETE from since the last look. Its own cursor, separate from
/// [`ExternalPoll`]'s (which watches only `impress/ui/surface*` rows),
/// advanced only after every read succeeded so a failed read is retried,
/// not lost.
///
/// # Deletes
///
/// A hard delete leaves no row for `items_modified_since` to find (wave 7
/// found it: a paper deleted by another process stayed in a query source
/// until something else re-ran it). A kind is read by id diff nowhere here
/// — a library's worth of ids per poll is the wrong price — but by its row
/// count ([`ui_feed::count_of`], one indexed count per watched kind per
/// `data_version` move). A delete with nothing of that kind written in the
/// same window changes the count; a delete WITH a write of the kind in the
/// window is reported through the write. Either way the kind's sources
/// re-run. A kind is counted from the moment a source starts reading it.
struct DomainPoll {
    last_data_version: Option<i64>,
    high_water_mark: i64,
    /// Rows per watched kind as of the last successful look.
    counts: std::collections::BTreeMap<String, i64>,
}

impl DomainPoll {
    fn baseline(store: &SqliteItemStore, watched: &BTreeSet<String>) -> Self {
        let mut poll = DomainPoll {
            last_data_version: store.data_version().ok(),
            high_water_mark: chrono::Utc::now().timestamp_millis(),
            counts: Default::default(),
        };
        poll.count_new_kinds(store, watched);
        poll
    }

    /// Start counting every watched kind not counted yet, and stop counting
    /// the ones no source reads any more. Run before the `data_version`
    /// shortcut, so a kind's first count is taken as soon as a source reads
    /// it, not after the delete it should have caught.
    fn count_new_kinds(&mut self, store: &SqliteItemStore, watched: &BTreeSet<String>) {
        self.counts.retain(|kind, _| watched.contains(kind));
        for kind in watched {
            if !self.counts.contains_key(kind) {
                if let Ok(n) = ui_feed::count_of(store, kind) {
                    self.counts.insert(kind.clone(), n);
                }
            }
        }
    }

    fn check(&mut self, store: &SqliteItemStore, watched: &BTreeSet<String>) -> BTreeSet<String> {
        let mut written = BTreeSet::new();
        self.count_new_kinds(store, watched);
        let Ok(dv) = store.data_version() else {
            return written;
        };
        if self.last_data_version == Some(dv) {
            return written;
        }
        let mut mark = self.high_water_mark;
        let mut counts = std::collections::BTreeMap::new();
        for schema in watched {
            let Ok(items) = store.items_modified_since(schema, self.high_water_mark) else {
                return BTreeSet::new();
            };
            for item in items.iter().filter(|i| &i.schema == schema) {
                written.insert(item.schema.clone());
                mark = mark.max(item.modified.timestamp_millis());
            }
            let Ok(now) = ui_feed::count_of(store, schema) else {
                return BTreeSet::new();
            };
            // A delete made in THIS process moves the count too, and is
            // reported again here on the next foreign write: one extra
            // re-run, never a missed one.
            if self.counts.get(schema).is_some_and(|before| *before != now) {
                written.insert(schema.clone());
            }
            counts.insert(schema.clone(), now);
        }
        self.counts = counts;
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

impl SurfaceFeed {
    /// What a surface mutation changed, for this handle — `None` for one
    /// that changes nothing a render here shows: an event row (the ring is
    /// read by `surface_wait`, never drawn), another host's state row, or a
    /// row already gone.
    ///
    /// A `surface@1.0.0` row's own id IS the surface id; a
    /// `surface-state@1.0.0` row is read back for its `surface` and `host`
    /// fields and its revision (its logical clock, which every write moves —
    /// the same number a render or dispatch reply carries as
    /// `state_revision`).
    fn change_of(&self, mutation: &StoreMutation) -> Option<SharedSurfaceChange> {
        match mutation.schema_ref.as_deref() {
            Some(s) if s == SURFACE_SCHEMA_REF => {
                let row = self.surfaces.get(mutation.item_id).ok()?;
                Some(SharedSurfaceChange {
                    id: mutation.item_id.to_string(),
                    revision: row.as_ref().map(|r| r.revision),
                    state_revision: None,
                    sources_changed: false,
                    deleted: row.is_none(),
                })
            }
            Some(s) if s == SURFACE_STATE_SCHEMA_REF => {
                let item = self.store.get(mutation.item_id).ok().flatten()?;
                let field = |name: &str| match item.payload.get(name) {
                    Some(ItemValue::String(raw)) => Some(raw.clone()),
                    _ => None,
                };
                if field("host")? != self.host {
                    return None;
                }
                let surface: ItemId = field("surface")?.parse().ok()?;
                Some(SharedSurfaceChange {
                    id: surface.to_string(),
                    revision: None,
                    state_revision: Some(item.logical_clock),
                    sources_changed: false,
                    deleted: false,
                })
            }
            // `SURFACE_EVENT_SCHEMA_REF` and anything else.
            _ => None,
        }
    }
}

/// Fold `change` into what is held for its surface: the newest revisions,
/// and `sources_changed`/`deleted` if either said so.
fn merge(
    held: &mut std::collections::BTreeMap<String, SharedSurfaceChange>,
    change: SharedSurfaceChange,
) {
    let entry = held
        .entry(change.id.clone())
        .or_insert_with(|| SharedSurfaceChange {
            id: change.id.clone(),
            revision: None,
            state_revision: None,
            sources_changed: false,
            deleted: false,
        });
    entry.revision = entry.revision.max(change.revision);
    entry.state_revision = entry.state_revision.max(change.state_revision);
    entry.sources_changed |= change.sources_changed;
    entry.deleted |= change.deleted;
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

    use impress_surface::{example_signal_explorer, SurfaceSpec};

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
        let surface = SharedSurface::open(store.clone(), "test-host".into(), "impress".into());
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
        ) -> std::result::Result<String, SharedVerbHostError> {
            if name != FAKE_VERB {
                return Err(SharedVerbHostError::Failed {
                    message: format!("FakeVerbHost does not know '{name}'"),
                });
            }
            let args: serde_json::Value =
                serde_json::from_str(&args_json).map_err(|e| SharedVerbHostError::Failed {
                    message: format!("bad args: {e}"),
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
        assert_eq!(before.status, 422, "{}", before.body);
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
            "widget": "bins-slider",
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
        let bins_value =
            &tree["tree"]["root"]["node"]["items"][1]["node"]["items"][1]["node"]["value"];
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
        assert_eq!(validated.status, 422, "{}", validated.body);
        assert!(validated.body.contains("problems"), "{}", validated.body);
    }

    #[test]
    fn a_second_connections_write_is_seen_within_one_poll() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("surface_external_poll.sqlite");
        let path_str = path.to_str().unwrap().to_string();

        let store = SharedStore::open(path_str.clone()).expect("open");
        let surface = SharedSurface::open(store.clone(), "test-host".into(), "impress".into());

        surface.set_debounce_ms(20);
        surface.set_startup_grace_secs(0);
        surface.set_external_poll_ms(20);

        let (tx, rx) = mpsc::channel::<Vec<String>>();
        struct Recorder(mpsc::Sender<Vec<String>>);
        impl SharedSurfaceListener for Recorder {
            fn surfaces_changed(&self, changes: Vec<SharedSurfaceChange>) {
                let _ = self.0.send(changes.into_iter().map(|c| c.id).collect());
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
                split: Some(SplitTargetDto {
                    direction: "horizontal".into(),
                    from_focused: true,
                }),
                ..ShowTargetDto::default()
            },
            "impress".into(),
            None,
        ));
        assert!(shown.ok, "{}", shown.message);

        // A brand-new handle, as the HTTP bridge opens per request.
        let fresh = SharedSurface::open(store.clone(), "test-host".into(), "impress".into());
        fresh
            .render_now(id.clone(), None)
            .expect("render on the fresh handle");
        let event = serde_json::json!({
            "widget": "papers-table", // its on_select publishes
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
        let pane = SharedSurface::open(store.clone(), "test-host".into(), "impress".into());
        let bridge = SharedSurface::open(store.clone(), "test-host".into(), "impress".into());
        assert!(Arc::ptr_eq(&pane.core.registry, &bridge.core.registry));

        let id = created_id(&bridge.http_now(
            "POST".into(),
            "/api/surface".into(),
            titled_spec("first"),
        ));
        assert!(pane.render_now(id.clone(), None).unwrap().contains("first"));

        let put = SharedSurface::open(store.clone(), "test-host".into(), "impress".into())
            .http_now(
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

    fn insert_paper(store: &SqliteItemStore, title: &str) -> ItemId {
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
            .unwrap()
    }

    /// RS-S2 / AC-F16 through the feed: a paper written in this process, and
    /// one written by another connection, each re-run the query source that
    /// reads papers — the pane is told, and its next render shows the row.
    #[test]
    fn a_paper_written_anywhere_reaches_a_rendered_query_source() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("t2_feed.sqlite");
        let store = SharedStore::open(path.to_str().unwrap().into()).unwrap();
        let surface = SharedSurface::open(store.clone(), "test-host".into(), "impress".into());
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
            fn surfaces_changed(&self, changes: Vec<SharedSurfaceChange>) {
                let _ = self.0.send(changes.into_iter().map(|c| c.id).collect());
            }
        }
        surface.subscribe(Box::new(Recorder(tx))).unwrap();

        let _ = insert_paper(&store.core(), "In process");
        let told = rx
            .recv_timeout(std::time::Duration::from_secs(2))
            .expect("the feed reports the surface whose query reads papers");
        assert_eq!(told, vec![id.clone()]);
        let shown = surface.render_now(id.clone(), None).unwrap();
        assert!(shown.contains("In process"), "{shown}");

        let other = SharedStore::open(path.to_str().unwrap().into()).unwrap();
        let _ = insert_paper(&other.core(), "Another process");
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

    /// Wave 7's finding, closed: a hard delete made in ANOTHER process
    /// leaves no row to read, and reached neither the surface feed nor the
    /// query sources. Now a paper deleted over there re-runs the source that
    /// reads papers (and the next render no longer shows it), and a surface
    /// deleted over there is reported `deleted`.
    #[test]
    fn a_hard_delete_in_another_process_reaches_the_feed_and_the_sources() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("u1_deletes.sqlite");
        let store = SharedStore::open(path.to_str().unwrap().into()).unwrap();
        let surface = SharedSurface::open(store.clone(), "test-host".into(), "impress".into());
        surface.set_debounce_ms(20);
        surface.set_external_poll_ms(20);
        let surfaces = SurfaceStore::new(store.core());
        let papers = surfaces
            .create(&papers_spec(), None, &[], ActorKind::Agent)
            .unwrap()
            .id
            .to_string();
        let doomed_surface = surfaces
            .create(&publish_spec(), None, &[], ActorKind::Agent)
            .unwrap()
            .id;
        let _ = insert_paper(&store.core(), "Kept paper");
        let doomed = insert_paper(&store.core(), "Doomed paper");
        let shown = surface.render_now(papers.clone(), None).unwrap();
        assert!(shown.contains("Doomed paper"), "{shown}");

        let (tx, rx) = mpsc::channel::<Vec<SharedSurfaceChange>>();
        struct Recorder(mpsc::Sender<Vec<SharedSurfaceChange>>);
        impl SharedSurfaceListener for Recorder {
            fn surfaces_changed(&self, changes: Vec<SharedSurfaceChange>) {
                let _ = self.0.send(changes);
            }
        }
        surface.subscribe(Box::new(Recorder(tx))).unwrap();

        // Another process deletes a paper: nothing of that kind is written,
        // only one row fewer.
        let other = SharedStore::open(path.to_str().unwrap().into()).unwrap();
        other.core().delete(doomed).unwrap();
        let told = rx
            .recv_timeout(std::time::Duration::from_secs(2))
            .expect("the other process's delete re-runs the papers source");
        // The first foreign write also replays the surface rows written in
        // the poll's 10 s overlap before the feed started (`ExternalPoll`
        // reports a row it has not seen once, whenever it was stamped), so
        // the batch may name both surfaces; only `papers` re-runs a source.
        let rerun: Vec<&SharedSurfaceChange> = told.iter().filter(|c| c.sources_changed).collect();
        assert_eq!(rerun.len(), 1, "{told:?}");
        assert_eq!(rerun[0].id, papers);
        assert!(told.iter().all(|c| !c.deleted), "{told:?}");
        let shown = surface.render_now(papers.clone(), None).unwrap();
        assert!(!shown.contains("Doomed paper"), "{shown}");
        assert!(shown.contains("Kept paper"), "{shown}");

        // Another process deletes a surface.
        assert!(SurfaceStore::new(other.core())
            .delete(doomed_surface)
            .unwrap());
        let told = rx
            .recv_timeout(std::time::Duration::from_secs(2))
            .expect("the other process's surface delete reaches the feed");
        let change = told
            .iter()
            .find(|c| c.id == doomed_surface.to_string())
            .unwrap_or_else(|| panic!("{told:?}"));
        assert!(change.deleted && change.revision.is_none(), "{change:?}");

        // Nothing else moved: no further notification.
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
        ) -> std::result::Result<String, SharedVerbHostError> {
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
        // A render answers the wire's envelope, refusal included…
        let rendered = surface
            .render_now("00000000-0000-4000-8000-000000000000".into(), None)
            .unwrap();
        let rendered: serde_json::Value = serde_json::from_str(&rendered).unwrap();
        assert_eq!(rendered["ok"], false);
        assert_eq!(rendered["code"], "not-found");
        assert_eq!(rendered["wire_version"], 1);
        // …and a plain read throws with the code.
        match surface.spec("00000000-0000-4000-8000-000000000000".into()) {
            Err(SharedSurfaceError::Surface { code, .. }) => assert_eq!(code, "not-found"),
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

    // ── wave 7 T6a: the HTTP mirror, the echo marker ────────────────────────

    fn body(reply: &SharedHttpReply) -> serde_json::Value {
        serde_json::from_str(&reply.body).unwrap_or_else(|e| panic!("{e}: {}", reply.body))
    }

    /// AC-F9 + RS-S13: every route answers its verb's own result, with
    /// `wire_version`, and the routes the verbs had no HTTP form for exist.
    #[test]
    fn every_mirrored_route_answers_its_verbs_result() {
        let (store, surface) = open();
        let id = create(&store, &publish_spec());
        let http = |m: &str, p: String, b: &str| surface.http_now(m.into(), p, b.into());
        let routes: Vec<(&str, String, String, u16, &str)> = vec![
            ("GET", "/api/surface".into(), "".into(), 200, "surfaces"),
            (
                "GET",
                "/api/surface/schema".into(),
                "".into(),
                200,
                "schema",
            ),
            (
                "GET",
                "/api/surface/examples".into(),
                "".into(),
                200,
                "examples",
            ),
            (
                "POST",
                "/api/surface/validate".into(),
                serde_json::to_string(&publish_spec()).unwrap(),
                200,
                "problems",
            ),
            ("GET", format!("/api/surface/{id}"), "".into(), 200, "spec"),
            (
                "GET",
                format!("/api/surface/{id}/render"),
                "".into(),
                200,
                "tree",
            ),
            (
                "GET",
                format!("/api/surface/{id}/state"),
                "".into(),
                200,
                "state",
            ),
            (
                "PUT",
                format!("/api/surface/{id}/state"),
                r#"{"state": {"clicked": true}}"#.into(),
                200,
                "state",
            ),
            (
                "POST",
                format!("/api/surface/{id}/dispatch"),
                r#"{"event": {"widget": "go", "kind": "click"}}"#.into(),
                422,
                "effects",
            ),
            (
                "GET",
                format!("/api/surface/{id}/events?after_seq=0"),
                "".into(),
                200,
                "events",
            ),
            (
                "GET",
                format!("/api/surface/{id}/wait?after_seq=0&timeout_ms=10"),
                "".into(),
                200,
                "timed_out",
            ),
            (
                "PUT",
                format!("/api/surface/{id}?expected_revision=1"),
                serde_json::to_string(&publish_spec()).unwrap(),
                200,
                "revision",
            ),
            (
                "POST",
                format!("/api/surface/{id}/show"),
                r#"{"target": {"split": {"direction": "vertical"}}}"#.into(),
                200,
                "tile",
            ),
            ("DELETE", format!("/api/surface/{id}"), "".into(), 200, "ok"),
        ];
        for (method, path, request, status, key) in routes {
            let reply = http(method, path.clone(), &request);
            let answer = body(&reply);
            assert_eq!(reply.status, status, "{method} {path}: {}", reply.body);
            assert_eq!(answer["wire_version"], 1, "{method} {path}: {}", reply.body);
            assert!(
                answer.get(key).is_some(),
                "{method} {path} has no `{key}`: {}",
                reply.body
            );
        }
    }

    /// Strict over HTTP too: an argument the verb does not take — the old
    /// `?after=`, a misspelt body key — is a 400 naming it.
    #[test]
    fn an_unknown_http_argument_is_refused_naming_it() {
        let (store, surface) = open();
        let id = create(&store, &publish_spec());
        for (method, path, request, field) in [
            (
                "GET",
                format!("/api/surface/{id}/events?after=0"),
                "",
                "after",
            ),
            (
                "GET",
                format!("/api/surface/{id}/render?pane=3"),
                "",
                "pane",
            ),
            (
                "POST",
                format!("/api/surface/{id}/show"),
                r#"{"target": {"tile": 7}}"#,
                "tile",
            ),
            (
                "POST",
                "/api/surface".to_string(),
                r#"{"spec": {"surface": "1.0"}, "tagz": []}"#,
                "tagz",
            ),
        ] {
            let reply = surface.http_now(method.into(), path.clone(), request.into());
            let answer = body(&reply);
            assert_eq!(reply.status, 400, "{method} {path}: {}", reply.body);
            assert_eq!(answer["code"], "invalid-argument");
            assert!(
                answer["message"].as_str().unwrap().contains(field),
                "{method} {path} must name `{field}`: {}",
                reply.body
            );
        }
    }

    /// An invalid spec is refused at create over HTTP, with every problem.
    #[test]
    fn an_invalid_spec_is_refused_at_create_over_http() {
        let (_store, surface) = open();
        let reply = surface.http_now(
            "POST".into(),
            "/api/surface".into(),
            r#"{"surface": "1.0", "name": "x", "root": {"table": {"rows": []}}}"#.into(),
        );
        let answer = body(&reply);
        assert_eq!(reply.status, 422, "{}", reply.body);
        assert_eq!(answer["code"], "invalid-spec");
        assert_eq!(answer["problems"][0]["path"], "/root");
        let listed = body(&surface.http_now("GET".into(), "/api/surface".into(), String::new()));
        assert_eq!(listed["surfaces"], serde_json::json!([]));
    }

    /// SK-K15: a dispatch's reply carries the state revision it wrote, and
    /// the feed reports that same revision for the write — so the pane can
    /// tell its own echo from an agent's. An event appended by the same
    /// dispatch is not reported at all.
    #[test]
    fn the_feed_reports_the_state_revision_the_dispatch_reply_carried() {
        let (store, surface) = open();
        surface.set_debounce_ms(20);
        let id = create(&store, &publish_spec());
        let (tx, rx) = mpsc::channel::<Vec<SharedSurfaceChange>>();
        struct Recorder(mpsc::Sender<Vec<SharedSurfaceChange>>);
        impl SharedSurfaceListener for Recorder {
            fn surfaces_changed(&self, changes: Vec<SharedSurfaceChange>) {
                let _ = self.0.send(changes);
            }
        }
        surface.subscribe(Box::new(Recorder(tx))).unwrap();

        let reply: serde_json::Value = serde_json::from_str(
            &surface
                .dispatch_now(id.clone(), None, CLICK.into())
                .unwrap(),
        )
        .unwrap();
        let written = reply["state_revision"].as_u64().expect("a state revision");
        let changes = rx.recv_timeout(std::time::Duration::from_secs(2)).unwrap();
        assert_eq!(changes.len(), 1, "{changes:?}");
        assert_eq!(changes[0].id, id);
        assert_eq!(changes[0].state_revision, Some(written), "{changes:?}");
        assert!(!changes[0].sources_changed);

        // Another writer's state is newer than what the pane last saw.
        let other = SharedSurface::open(store.clone(), "test-host".into(), "impress".into());
        other.http_now(
            "PUT".into(),
            format!("/api/surface/{id}/state"),
            r#"{"state": {"clicked": false}}"#.into(),
        );
        let changes = rx.recv_timeout(std::time::Duration::from_secs(2)).unwrap();
        assert!(changes[0].state_revision.unwrap() > written, "{changes:?}");
        surface.unsubscribe();
    }

    /// RS-S4: the pane a render comes from is recorded in THIS handle's app.
    #[test]
    fn a_pane_with_no_app_is_refused_not_guessed() {
        let store = SharedStore::open_in_memory().expect("open");
        let appless = SharedSurface::open(store.clone(), "test-host".into(), String::new());
        let id = create(&store, &publish_spec());
        let rendered: serde_json::Value =
            serde_json::from_str(&appless.render_now(id, Some(3)).unwrap()).unwrap();
        assert_eq!(rendered["code"], "invalid-argument", "{rendered}");
    }

    /// RS-S19: a host that says the owning app is not running is refused as
    /// `host-unavailable`, worded by Rust, in the source's error.
    #[test]
    fn an_unavailable_app_is_host_unavailable_not_a_storage_error() {
        struct ClosedApp;
        impl SharedVerbHost for ClosedApp {
            fn has_verb(&self, name: String) -> bool {
                name == FAKE_VERB
            }
            fn call_verb(
                &self,
                name: String,
                _args_json: String,
            ) -> std::result::Result<String, SharedVerbHostError> {
                Err(SharedVerbHostError::Unavailable {
                    app: "imbib".into(),
                    verb: name,
                })
            }
        }
        let (store, surface) = open();
        store.set_verb_host(Box::new(ClosedApp));
        let id = create_fixture_surface(&store);
        let rendered: serde_json::Value =
            serde_json::from_str(&surface.render_now(id, None).unwrap()).unwrap();
        let why = rendered["source_errors"][0]["message"].as_str().unwrap();
        assert!(why.starts_with("imbib is not running"), "{rendered}");
    }
}
