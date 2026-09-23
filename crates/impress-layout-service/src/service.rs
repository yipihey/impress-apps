//! `LayoutService` — every ADR-0031 D8 verb, as an `#[impress_method]`.
//!
//! One trait, one method per gesture, so MCP, the CLI and impel's agent loop
//! get split / move / retype / re-link / save / recall together and nobody
//! keeps a translation table in their head (invariant 6: every layout gesture
//! is a `layout-service` verb; no Swift-only layout operation).
//!
//! # The shape every verb has
//!
//! * `app_id` — which preset family this window belongs to (`imbib`,
//!   `imprint`, …). It scopes the live row and the saved layouts.
//! * `device` — `null` means *this* device; see [`crate::device`].
//! * a **pane reference** ([`PaneRefDto`]) where the verb acts on a pane:
//!   by tile id, by role, by direction from the focused leaf, or the focused
//!   leaf itself. Resolution happens once, in Rust.
//! * `actor` — `human` | `agent` | `system`, defaulting to **agent**, because
//!   these verbs arrive over MCP and the CLI and an agent that forgets to say
//!   who it is must not be recorded as the user. The GUI passes `human`.
//!
//! and every result carries `focused` and `affected_panes`, which is the whole
//! of what a renderer needs to know what to redraw.

use std::collections::BTreeMap;
use std::sync::Arc;

use impress_core::collection_ops::{
    self, CollectionSchemaBinding, FIGURE_COLLECTION, GENERIC_COLLECTION, IMBIB_COLLECTION,
    MANUSCRIPT_COLLECTION,
};
use impress_core::item::{ActorKind, ItemId};
use impress_core::pane_query::{
    builtin_manifest, compile_with, Bindings, PaneQuery, ParamDecl, SubtreeResolver,
};
use impress_core::sqlite_store::SqliteItemStore;
use impress_layout::{ChannelId, Geometry, PaneSpec, ParamSource, Role, TileId, Verb, WindowId};
use impress_service_core::async_trait;
use impress_service_macros::{impress_service, impress_service_impl};

#[allow(unused_imports)]
use impress_service_macros::impress_method;

use crate::device::resolve_device;
use crate::dto::{
    parse_channel, parse_container_kind, parse_direction, parse_ids, parse_linear_dir,
    parse_placement, parse_stack, raw_tiles, view_kind, ChannelResult, CompiledQueryDto,
    LayoutListResult, LayoutResult, LayoutVerbResult, MaterializeFirstDto, PaneRefDto, PaneResult,
    PresetDto, PresetListResult, PresetResult, ReferenceResult, SavedLayoutDto,
};
use crate::presets::{self, PresetRow, PresetStore};
use crate::session::{LayoutSession, SessionRegistry, Stack, UndoTarget};
use crate::store::{actor_from, LayoutRow, LayoutStore};

/// The workspace layout: every gesture that shapes a window, as a verb.
///
/// A **pane** is a query rendered by a view kind, with its parameters filled
/// from channels (ADR-0031 D1). A **layout** is a tree of containers over
/// panes. There is no sidebar type, no list type and no detail type — the
/// difference between them is entirely the value of a pane's spec, which is
/// why the same thirty verbs serve every app.
#[impress_service]
pub trait LayoutService: Send + Sync + 'static {
    // ----------------------------------------------------------- arrangement

    /// Split a pane, putting a new pane beside it. Focus follows the new pane.
    ///
    /// `direction` is `horizontal` (side by side) or `vertical` (stacked).
    /// `after` puts the new pane on the right / below; false puts it before.
    /// `new_pane` is a whole pane spec; omit it to duplicate the pane being
    /// split, which is what a bare "split this" gesture means.
    #[impress_method]
    async fn split(
        &self,
        app_id: String,
        device: Option<String>,
        target: PaneRefDto,
        direction: String,
        after: bool,
        new_pane: Option<PaneSpec>,
        actor: Option<String>,
    ) -> LayoutVerbResult;

    /// Move a pane (or a whole subtree) next to another, or into its tabs.
    ///
    /// `placement` is `left` | `right` | `above` | `below` | `into-tabs`.
    #[impress_method]
    async fn move_tile(
        &self,
        app_id: String,
        device: Option<String>,
        tile: PaneRefDto,
        target: PaneRefDto,
        placement: String,
        actor: Option<String>,
    ) -> LayoutVerbResult;

    /// Close a pane or a whole subtree. Never the last pane of the layout.
    #[impress_method]
    async fn close(
        &self,
        app_id: String,
        device: Option<String>,
        target: PaneRefDto,
        actor: Option<String>,
    ) -> LayoutVerbResult;

    /// Exchange two tiles' positions, each keeping the share of the position
    /// it lands in.
    #[impress_method]
    async fn swap(
        &self,
        app_id: String,
        device: Option<String>,
        a: PaneRefDto,
        b: PaneRefDto,
        actor: Option<String>,
    ) -> LayoutVerbResult;

    /// Set a split container's relative shares — one per child, positive.
    ///
    /// They are weights, not fractions: `1 2 3` means the three-column
    /// chassis, and the renderer divides by their sum.
    #[impress_method]
    async fn resize(
        &self,
        app_id: String,
        device: Option<String>,
        container: u64,
        shares: Vec<f32>,
        actor: Option<String>,
    ) -> LayoutVerbResult;

    /// Retype a container, keeping its children in order: `tabs` |
    /// `horizontal` | `vertical` | `grid`.
    #[impress_method]
    async fn set_container_kind(
        &self,
        app_id: String,
        device: Option<String>,
        container: u64,
        kind: String,
        actor: Option<String>,
    ) -> LayoutVerbResult;

    /// Show one pane alone in its window. Zoom is a view state, not a mutation
    /// of the tree: every share and every session survives it.
    #[impress_method]
    async fn maximize(
        &self,
        app_id: String,
        device: Option<String>,
        target: PaneRefDto,
        actor: Option<String>,
    ) -> LayoutVerbResult;

    /// Undo a maximize. A no-op when nothing is maximized.
    #[impress_method]
    async fn restore(
        &self,
        app_id: String,
        device: Option<String>,
        actor: Option<String>,
    ) -> LayoutVerbResult;

    /// Move a pane out into a new window whose root it becomes — the detached
    /// PDF. Refused when the pane is already the whole of its window.
    #[impress_method]
    async fn detach(
        &self,
        app_id: String,
        device: Option<String>,
        target: PaneRefDto,
        actor: Option<String>,
    ) -> LayoutVerbResult;

    // --------------------------------------------------------------- content

    /// Replace a pane's whole spec: query, view kind, parameters, channel,
    /// role and view state at once.
    #[impress_method]
    async fn set_pane(
        &self,
        app_id: String,
        device: Option<String>,
        target: PaneRefDto,
        spec: PaneSpec,
        actor: Option<String>,
    ) -> LayoutVerbResult;

    /// Point a pane at a different query. The query algebra is closed
    /// (ADR-0031 D2): kinds, a scope, filters, a text term, one relation walk,
    /// sort and limit. Anything it cannot express is materialized in the store
    /// first and queried from there.
    #[impress_method]
    async fn set_query(
        &self,
        app_id: String,
        device: Option<String>,
        target: PaneRefDto,
        query: PaneQuery,
        actor: Option<String>,
    ) -> LayoutVerbResult;

    /// Re-render a pane with a different view kind: `outline`, `list`, `info`,
    /// `pdf`, `editor`, `plot`, `console`, `legacy`, `placeholder`.
    #[impress_method]
    async fn set_view_kind(
        &self,
        app_id: String,
        device: Option<String>,
        target: PaneRefDto,
        view_kind: String,
        actor: Option<String>,
    ) -> LayoutVerbResult;

    /// Re-point one of a pane's declared parameters: follow a channel, pin it
    /// to one item, or fall back to the view kind's default.
    #[impress_method]
    async fn bind_param(
        &self,
        app_id: String,
        device: Option<String>,
        target: PaneRefDto,
        name: String,
        source: ParamSource,
        actor: Option<String>,
    ) -> LayoutVerbResult;

    /// Change the channel a pane publishes its selection on: `1`–`8`, or
    /// `follow` for the window's default.
    #[impress_method]
    async fn set_channel(
        &self,
        app_id: String,
        device: Option<String>,
        target: PaneRefDto,
        channel: String,
        actor: Option<String>,
    ) -> LayoutVerbResult;

    /// Set what `follow` means in one window. `follow` itself is refused: a
    /// window default that follows itself is not a value.
    #[impress_method]
    async fn set_default_channel(
        &self,
        app_id: String,
        device: Option<String>,
        window: Option<u64>,
        channel: String,
        actor: Option<String>,
    ) -> LayoutVerbResult;

    /// Give, move or clear a role — `navigator`, `list`, `detail`, `preview`,
    /// `console`, or one of your own. The universal chords act on whichever
    /// pane holds the role, so this is how ⌃⌘S is re-aimed.
    #[impress_method]
    async fn set_role(
        &self,
        app_id: String,
        device: Option<String>,
        target: PaneRefDto,
        role: Option<String>,
        actor: Option<String>,
    ) -> LayoutVerbResult;

    // ------------------------------------------------------- focus/selection

    /// Focus a pane. Focus is a value in the layout, so it is legible to
    /// agents and tests rather than living in a view.
    #[impress_method]
    async fn focus(
        &self,
        app_id: String,
        device: Option<String>,
        target: PaneRefDto,
        actor: Option<String>,
    ) -> LayoutVerbResult;

    /// Step focus: `left` | `right` | `up` | `down` | `next` | `prev`. This is
    /// the h / l grammar, as a tree walk rather than a geometric one.
    #[impress_method]
    async fn focus_direction(
        &self,
        app_id: String,
        device: Option<String>,
        direction: String,
        actor: Option<String>,
    ) -> LayoutVerbResult;

    /// Publish a selection of `kind` on a pane's channel — what "clicking a
    /// row" is.
    ///
    /// A channel carries one current value PER RECORD KIND, so publishing a
    /// manuscript leaves a publication parameter on the same channel
    /// untouched. An empty `ids` is a real value: it records that nothing of
    /// that kind is selected, which is what a detail pane renders its empty
    /// state from.
    #[impress_method]
    async fn select(
        &self,
        app_id: String,
        device: Option<String>,
        target: PaneRefDto,
        kind: String,
        ids: Vec<String>,
        actor: Option<String>,
    ) -> LayoutVerbResult;

    /// Replace (or clear, with null) a window's frame. Device-scoped: it
    /// persists locally and is filtered out before a layout is applied
    /// somewhere else.
    #[impress_method]
    async fn set_window_geometry(
        &self,
        app_id: String,
        device: Option<String>,
        window: Option<u64>,
        geometry: Option<Geometry>,
        actor: Option<String>,
    ) -> LayoutVerbResult;

    // ----------------------------------------------------------- persistence

    /// Materialize the current arrangement as a durable, attributed record —
    /// the commit of ADR-0031 D7, which undo never crosses.
    ///
    /// `as_kind` is `layout` today, which saves the tree under `name`.
    /// Committing a set of bindings as a **figure** or a **collection** is the
    /// same verb with a different `as_kind` and arrives with the implore and
    /// preset work (L7); asking for one now is refused rather than
    /// approximated.
    #[impress_method]
    async fn commit(
        &self,
        app_id: String,
        device: Option<String>,
        as_kind: String,
        name: String,
        purpose: Option<String>,
        actor: Option<String>,
    ) -> LayoutVerbResult;

    /// Save the current arrangement under a name, durably. Re-saving an
    /// existing name overwrites it.
    #[impress_method]
    async fn save_layout(
        &self,
        app_id: String,
        device: Option<String>,
        name: String,
        purpose: Option<String>,
        actor: Option<String>,
    ) -> LayoutVerbResult;

    /// Recall a saved layout by `name` (or id), or by `ordinal` 1–9 — the
    /// ⌃⌘1–9 chords.
    ///
    /// An ordinal numbers ONE union: this app's **presets** first, in the
    /// shipped table's order, then its named layouts, oldest first. So ⌃⌘1 is
    /// always the app's default arrangement and ⌃⌘2 its Triage, whatever the
    /// user has saved since. A `name` that is a preset rather than a layout
    /// applies that preset, for the same reason: a palette types into one
    /// name space.
    ///
    /// Window geometry is dropped on the way in: the logical tree is what
    /// ports between devices, and a 27" frame has no business landing on a
    /// laptop (ADR-0019 D2).
    #[impress_method]
    async fn apply_layout(
        &self,
        app_id: String,
        device: Option<String>,
        name: Option<String>,
        ordinal: Option<u32>,
        actor: Option<String>,
    ) -> LayoutVerbResult;

    /// Undo on one ring: `arrangement` (the window's shape) or `exploration`
    /// (one pane's bindings and view state, named by `target`).
    ///
    /// These are two of the three stacks of ADR-0031 D7. The third — the
    /// editor session's own undo manager — is never ours and is not reachable
    /// from here.
    #[impress_method]
    async fn undo(
        &self,
        app_id: String,
        device: Option<String>,
        stack: String,
        target: PaneRefDto,
        actor: Option<String>,
    ) -> LayoutVerbResult;

    /// Redo on one ring. Same stacks as `undo`.
    #[impress_method]
    async fn redo(
        &self,
        app_id: String,
        device: Option<String>,
        stack: String,
        target: PaneRefDto,
        actor: Option<String>,
    ) -> LayoutVerbResult;

    // ------------------------------------------------------------------ read

    /// The whole live tree for this scope: windows, the tile arena, channel
    /// state. Creates the three-column preset on a cold start, so a caller
    /// never has to ask whether a layout exists.
    #[impress_method]
    async fn get_layout(&self, app_id: String, device: Option<String>) -> LayoutResult;

    /// One pane: its spec, its query COMPILED against the record-kind manifest
    /// with its parameters bound, and what those parameters currently resolve
    /// to.
    ///
    /// The compiled `item_query` is literally what the store will be asked —
    /// which is how "why is this pane empty?" becomes a question with an
    /// answer instead of a debugging session.
    #[impress_method]
    async fn get_pane(
        &self,
        app_id: String,
        device: Option<String>,
        target: PaneRefDto,
    ) -> PaneResult;

    /// What a channel currently carries, per record kind, and which panes it
    /// drives. `channel` is `1`–`8` or `follow`.
    #[impress_method]
    async fn get_channel(
        &self,
        app_id: String,
        device: Option<String>,
        channel: String,
        kind: Option<String>,
    ) -> ChannelResult;

    /// What a pane reference resolves to right now — "which pane is `right`?"
    /// answered without doing anything to it.
    #[impress_method]
    async fn resolve_reference(
        &self,
        app_id: String,
        device: Option<String>,
        target: PaneRefDto,
    ) -> ReferenceResult;

    /// The saved layouts of an app, in ⌃⌘1–9 order.
    ///
    /// Their ordinals are OFFSET by the app's presets, which come first in
    /// the union `apply_layout(ordinal:)` recalls — see `list_presets`.
    #[impress_method]
    async fn list_layouts(&self, app_id: String) -> LayoutListResult;

    // --------------------------------------------------------------- presets

    /// The presets of an app — what the app IS, as arrangements the user can
    /// recall (ADR-0031 D10): its default, plus Triage / Reading / Full /
    /// Writing where the table ships them, plus any the user saved.
    ///
    /// Seeds the shipped presets if this workspace has never seen them, so a
    /// caller never has to ask whether they exist. Ordinals are the ⌃⌘1–9
    /// chords: presets first, then named layouts. The answer also carries the
    /// sections this app permits that are NOT expressible as queries, with
    /// the reason (ADR-0031 D2).
    #[impress_method]
    async fn list_presets(&self, app_id: String) -> PresetListResult;

    /// Apply a preset: the live arrangement becomes its tree, and the live
    /// row records a `DerivedFrom` edge to the preset it came from — which is
    /// what makes "reset to the preset" a graph walk rather than a remembered
    /// string.
    ///
    /// Window geometry is dropped on the way in, exactly as `apply_layout`
    /// drops it: the logical tree is what ports between devices (ADR-0019
    /// D2).
    #[impress_method]
    async fn apply_preset(
        &self,
        app_id: String,
        device: Option<String>,
        name: String,
        actor: Option<String>,
    ) -> LayoutVerbResult;

    /// Save the live arrangement AS a preset, durably — a preset of the
    /// user's own, or an edit to one the suite ships.
    ///
    /// `from_live` must be true today: the live tree is the only source a
    /// preset can be built from here, and asking for another is refused
    /// rather than approximated. Editing a shipped preset leaves its
    /// `version` alone, so "the user edited Triage" stays distinguishable
    /// from "we shipped a newer Triage" and `reset_preset` can undo it.
    #[impress_method]
    async fn save_preset(
        &self,
        app_id: String,
        device: Option<String>,
        name: String,
        purpose: Option<String>,
        from_live: bool,
        actor: Option<String>,
    ) -> PresetResult;

    /// Restore the shipped revision of a preset over a user-edited row.
    ///
    /// Refused for a name the suite does not ship: there would be nothing to
    /// restore it to, and the refusal names what IS shipped.
    #[impress_method]
    async fn reset_preset(
        &self,
        app_id: String,
        name: String,
        actor: Option<String>,
    ) -> PresetResult;
}

// ---------------------------------------------------------------------------
// Implementation
// ---------------------------------------------------------------------------

/// Store-backed `LayoutService`.
///
/// `new()` uses the process-wide store and the process-wide session registry —
/// the same singletons every other store-generic service uses, so a
/// `--store-path` parsed by `impress-cli` applies here too. `with_store` takes
/// an explicit store AND gives the instance its own session registry, which is
/// what makes the tests hermetic: no test can see another's panes.
#[derive(Clone, Default)]
pub struct DefaultLayoutService {
    store: Option<Arc<SqliteItemStore>>,
    sessions: Option<Arc<SessionRegistry>>,
}

impl DefaultLayoutService {
    pub fn new() -> Self {
        Self {
            store: None,
            sessions: None,
        }
    }

    /// An instance over an explicit store, with a private session registry.
    pub fn with_store(store: Arc<SqliteItemStore>) -> Self {
        Self::with_store_and_sessions(store, Arc::new(SessionRegistry::new()))
    }

    /// An instance over an explicit store AND an explicit registry — for the
    /// several objects one process opens on one store (the FFI's
    /// `SharedLayout` and the surface executor) to share their sessions, so
    /// a verb one of them applies is the tree the other one reads.
    pub fn with_store_and_sessions(
        store: Arc<SqliteItemStore>,
        sessions: Arc<SessionRegistry>,
    ) -> Self {
        Self {
            store: Some(store),
            sessions: Some(sessions),
        }
    }

    /// The registry this instance's sessions live in.
    pub fn sessions(&self) -> Arc<SessionRegistry> {
        self.registry()
    }

    /// Drop the cached session for one scope, so the next read re-reads the
    /// stored row.
    ///
    /// The registry keeps a `LayoutSession` per (app, device) and only loads
    /// from the store when there is none — which is right for this process's
    /// own verbs and wrong the moment ANOTHER process writes the same row
    /// (ADR-0033 D6). The FFI's invalidation feed calls this when its external
    /// `data_version` poll sees a layout write it did not make; without it the
    /// host reloads, the service answers from the stale session, and the
    /// window redraws exactly what it already had — verified live on
    /// 2026-09-22, where `surface_show` from `impress-mcp` reached the store
    /// and the window kept rendering four leaves.
    pub fn forget_session(&self, app_id: &str, device: Option<&str>) {
        self.registry().forget(app_id, &resolve_device(device));
    }

    fn layout_store(&self) -> LayoutStore {
        LayoutStore::new(
            self.store
                .clone()
                .unwrap_or_else(impress_store_service::store_instance),
        )
    }

    fn registry(&self) -> Arc<SessionRegistry> {
        self.sessions
            .clone()
            .unwrap_or_else(SessionRegistry::shared)
    }

    /// Apply one verb and persist the live row.
    ///
    /// `build` gets the session because some verbs need it to fill in a
    /// default the caller left out — "this window" for the geometry and
    /// default-channel verbs, "the pane I am splitting" for a bare split.
    fn apply_verb(
        &self,
        app_id: &str,
        device: Option<String>,
        actor: Option<String>,
        build: impl FnOnce(&LayoutSession) -> Result<Verb, String>,
    ) -> LayoutVerbResult {
        let actor_kind = actor_from(actor.as_deref());
        let device = resolve_device(device.as_deref());
        let store = self.layout_store();
        let outcome = self.registry().with(
            &store,
            app_id,
            &device,
            actor_kind,
            |session| -> Result<(String, crate::session::AppliedVerb), String> {
                let verb = build(session)?;
                let intent = intent_text(&verb);
                let applied = session.apply(verb).map_err(|e| e.to_string())?;
                // Ephemeral retention, coalescing left to the caller: see
                // `store`'s module docs and ADR-0019 D6.
                store.save_live(
                    &session.app_id,
                    &session.device,
                    &session.layout,
                    actor_kind,
                    &intent,
                )?;
                Ok((intent, applied))
            },
        );
        match flatten(outcome) {
            Ok((intent, applied)) => LayoutVerbResult::applied(intent, &applied),
            Err(message) => LayoutVerbResult::failed(message),
        }
    }

    /// Run `f` against the session without applying a verb — the reads, and
    /// the persistence verbs that replace the tree wholesale.
    ///
    /// `actor` is carried because a read that finds no live row **writes one**
    /// (the cold start), and that row is the user's workspace: attributing it
    /// to `System` would claim the chassis arranged it, and attributing an
    /// agent's read to the human would be worse.
    fn with_session<R>(
        &self,
        app_id: &str,
        device: Option<String>,
        actor: ActorKind,
        f: impl FnOnce(&mut LayoutSession, &LayoutStore) -> Result<R, String>,
    ) -> Result<R, String> {
        let device = resolve_device(device.as_deref());
        let store = self.layout_store();
        flatten(
            self.registry()
                .with(&store, app_id, &device, actor, |session| f(session, &store)),
        )
    }
}

fn flatten<T>(outcome: Result<Result<T, String>, String>) -> Result<T, String> {
    outcome.and_then(|inner| inner)
}

/// The sentence recorded as the operation's `reason` (ADR-0019 D4: *why* was
/// this change made). One place, so the log reads consistently whether the
/// gesture came from a chord, an agent or a test.
fn intent_text(verb: &Verb) -> String {
    match verb {
        Verb::Split { dir, .. } => format!("split a pane {dir:?} and focused the new one"),
        Verb::MoveTile { placement, .. } => format!("moved a tile {placement:?}"),
        Verb::Close { .. } => "closed a pane".to_string(),
        Verb::Swap { .. } => "swapped two tiles".to_string(),
        Verb::Resize { container, .. } => format!("resized container {container}"),
        Verb::SetContainerKind { container, kind } => {
            format!("retyped container {container} as {kind:?}")
        }
        Verb::Maximize { .. } => "maximized a pane".to_string(),
        Verb::Restore => "restored from maximize".to_string(),
        Verb::Detach { .. } => "detached a pane into its own window".to_string(),
        Verb::SetPane { .. } => "replaced a pane's spec".to_string(),
        Verb::SetQuery { .. } => "re-pointed a pane's query".to_string(),
        Verb::SetViewKind { view_kind, .. } => format!("re-rendered a pane as '{view_kind}'"),
        Verb::BindParam { name, .. } => format!("re-bound the parameter '{name}'"),
        Verb::SetChannel { channel, .. } => format!("moved a pane to channel {channel}"),
        Verb::SetRole { role, .. } => match role {
            Some(role) => format!("gave a pane the role '{role}'"),
            None => "cleared a pane's role".to_string(),
        },
        Verb::Focus { .. } => "focused a pane".to_string(),
        Verb::FocusDirection { direction } => format!("stepped focus {direction:?}"),
        Verb::Select { kind, ids, .. } => {
            format!("selected {} {kind}(s) on a pane's channel", ids.len())
        }
        Verb::SetWindowGeometry { window, geometry } => match geometry {
            Some(_) => format!("moved window {window}"),
            None => format!("cleared window {window}'s frame"),
        },
        Verb::SetDefaultChannel { window, channel } => {
            format!("window {window} now follows channel {channel}")
        }
    }
}

/// A saved layout's label: its name, or its id when a hand-edited row has
/// none.
fn label_of(row: &LayoutRow) -> String {
    row.name.clone().unwrap_or_else(|| row.id.to_string())
}

/// Make `layout` the live arrangement of this session and persist it.
///
/// ADR-0019 D2: the logical tree ports between devices; the window frame does
/// not, so geometry is dropped on the way in — a 27" frame has no business
/// landing on a laptop.
fn apply_tree(
    session: &mut LayoutSession,
    store: &LayoutStore,
    mut layout: impress_layout::Layout,
    label: &str,
    actor: ActorKind,
    what: &str,
) -> Result<LayoutVerbResult, String> {
    for window in &mut layout.windows {
        window.geometry = None;
    }
    session.replace(layout);
    store.save_live(
        &session.app_id,
        &session.device,
        &session.layout,
        actor,
        &format!("applied the {what} '{label}'"),
    )?;
    Ok(LayoutVerbResult::from_layout(
        format!("Applied '{label}'."),
        &session.layout,
        None,
        None,
    ))
}

/// Apply one preset and record where the live arrangement came from.
///
/// Shared by `apply_preset` and by `apply_layout`'s ordinal path, so a preset
/// recalled by ⌃⌘2 leaves exactly the same `DerivedFrom` edge as one applied
/// by name. A preset row with no tree is refused rather than approximated: an
/// inheriting preset (one that overrides only queries or roles) is a shape
/// `schemas/ui.rs` allows and nothing composes yet.
fn apply_preset_row(
    session: &mut LayoutSession,
    store: &LayoutStore,
    presets: &PresetStore,
    name: &str,
    actor: ActorKind,
) -> Result<LayoutVerbResult, String> {
    let (row, stored) = presets
        .load(&session.app_id, name)?
        .ok_or_else(|| format!("no preset named '{name}' for {}", session.app_id))?;
    let layout = stored.layout.ok_or_else(|| {
        format!(
            "the preset '{}' carries no tree of its own (it inherits one), which nothing \
             composes yet",
            row.name
        )
    })?;
    let result = apply_tree(session, store, layout, &row.name, actor, "preset")?;
    presets::record_derived_from(
        store.store(),
        session.item_id,
        row.id,
        actor,
        &format!("this arrangement came from the preset '{}'", row.name),
    )?;
    Ok(result)
}

/// One preset row, as the wire shows it.
fn preset_dto(presets: &PresetStore, row: &PresetRow, ordinal: u32) -> Result<PresetDto, String> {
    let (_, stored) = presets
        .load(&row.app_id, &row.id.to_string())?
        .ok_or_else(|| format!("preset {} vanished", row.id))?;
    let edited = presets.matches_shipped(row, &stored).map(|same| !same);
    let panes = stored
        .layout
        .as_ref()
        .map(|layout| layout.panes().len() as u32)
        .unwrap_or(0);
    let mut roles: Vec<String> = stored.roles.keys().cloned().collect();
    roles.sort();
    Ok(PresetDto {
        id: row.id.to_string(),
        ordinal,
        name: row.name.clone(),
        app_id: row.app_id.clone(),
        purpose: row.purpose.clone(),
        version: row.version,
        shipped: presets::shipped_preset(&row.app_id, &row.name).is_some(),
        edited,
        panes,
        roles,
        modified: row.modified.to_rfc3339(),
    })
}

#[async_trait::async_trait]
impl LayoutService for DefaultLayoutService {
    async fn split(
        &self,
        app_id: String,
        device: Option<String>,
        target: PaneRefDto,
        direction: String,
        after: bool,
        new_pane: Option<PaneSpec>,
        actor: Option<String>,
    ) -> LayoutVerbResult {
        self.apply_verb(&app_id, device, actor, |session| {
            let reference = target.to_pane_ref()?;
            let dir = parse_linear_dir(&direction)?;
            let new = match new_pane {
                Some(spec) => spec,
                None => {
                    // A bare "split this" duplicates the pane being split: it
                    // is the only spec that is certainly renderable here, and
                    // the user re-points one half immediately.
                    let window = session.layout.current_window().map_err(|e| e.to_string())?;
                    let tile = session
                        .layout
                        .resolve(window, &reference)
                        .map_err(|e| e.to_string())?;
                    let mut spec = session
                        .layout
                        .pane(tile)
                        .ok_or_else(|| format!("tile {tile} is a container, not a pane"))?
                        .clone();
                    // Two panes cannot hold one role (D5) and two panes must
                    // not share one session (D6) — the copy gets neither.
                    spec.role = None;
                    spec.session = None;
                    spec
                }
            };
            Ok(Verb::Split {
                target: reference,
                dir,
                after,
                new,
            })
        })
    }

    async fn move_tile(
        &self,
        app_id: String,
        device: Option<String>,
        tile: PaneRefDto,
        target: PaneRefDto,
        placement: String,
        actor: Option<String>,
    ) -> LayoutVerbResult {
        self.apply_verb(&app_id, device, actor, |_| {
            Ok(Verb::MoveTile {
                tile: tile.to_pane_ref()?,
                target: target.to_pane_ref()?,
                placement: parse_placement(&placement)?,
            })
        })
    }

    async fn close(
        &self,
        app_id: String,
        device: Option<String>,
        target: PaneRefDto,
        actor: Option<String>,
    ) -> LayoutVerbResult {
        self.apply_verb(&app_id, device, actor, |_| {
            Ok(Verb::Close {
                target: target.to_pane_ref()?,
            })
        })
    }

    async fn swap(
        &self,
        app_id: String,
        device: Option<String>,
        a: PaneRefDto,
        b: PaneRefDto,
        actor: Option<String>,
    ) -> LayoutVerbResult {
        self.apply_verb(&app_id, device, actor, |_| {
            Ok(Verb::Swap {
                a: a.to_pane_ref()?,
                b: b.to_pane_ref()?,
            })
        })
    }

    async fn resize(
        &self,
        app_id: String,
        device: Option<String>,
        container: u64,
        shares: Vec<f32>,
        actor: Option<String>,
    ) -> LayoutVerbResult {
        self.apply_verb(&app_id, device, actor, |_| {
            Ok(Verb::Resize {
                container: TileId::new(container),
                shares,
            })
        })
    }

    async fn set_container_kind(
        &self,
        app_id: String,
        device: Option<String>,
        container: u64,
        kind: String,
        actor: Option<String>,
    ) -> LayoutVerbResult {
        self.apply_verb(&app_id, device, actor, |_| {
            Ok(Verb::SetContainerKind {
                container: TileId::new(container),
                kind: parse_container_kind(&kind)?,
            })
        })
    }

    async fn maximize(
        &self,
        app_id: String,
        device: Option<String>,
        target: PaneRefDto,
        actor: Option<String>,
    ) -> LayoutVerbResult {
        self.apply_verb(&app_id, device, actor, |_| {
            Ok(Verb::Maximize {
                target: target.to_pane_ref()?,
            })
        })
    }

    async fn restore(
        &self,
        app_id: String,
        device: Option<String>,
        actor: Option<String>,
    ) -> LayoutVerbResult {
        self.apply_verb(&app_id, device, actor, |_| Ok(Verb::Restore))
    }

    async fn detach(
        &self,
        app_id: String,
        device: Option<String>,
        target: PaneRefDto,
        actor: Option<String>,
    ) -> LayoutVerbResult {
        self.apply_verb(&app_id, device, actor, |_| {
            Ok(Verb::Detach {
                target: target.to_pane_ref()?,
            })
        })
    }

    async fn set_pane(
        &self,
        app_id: String,
        device: Option<String>,
        target: PaneRefDto,
        spec: PaneSpec,
        actor: Option<String>,
    ) -> LayoutVerbResult {
        self.apply_verb(&app_id, device, actor, |_| {
            Ok(Verb::SetPane {
                target: target.to_pane_ref()?,
                spec,
            })
        })
    }

    async fn set_query(
        &self,
        app_id: String,
        device: Option<String>,
        target: PaneRefDto,
        query: PaneQuery,
        actor: Option<String>,
    ) -> LayoutVerbResult {
        self.apply_verb(&app_id, device, actor, |_| {
            Ok(Verb::SetQuery {
                target: target.to_pane_ref()?,
                query,
            })
        })
    }

    async fn set_view_kind(
        &self,
        app_id: String,
        device: Option<String>,
        target: PaneRefDto,
        view_kind_id: String,
        actor: Option<String>,
    ) -> LayoutVerbResult {
        self.apply_verb(&app_id, device, actor, |_| {
            Ok(Verb::SetViewKind {
                target: target.to_pane_ref()?,
                view_kind: view_kind(&view_kind_id)?,
            })
        })
    }

    async fn bind_param(
        &self,
        app_id: String,
        device: Option<String>,
        target: PaneRefDto,
        name: String,
        source: ParamSource,
        actor: Option<String>,
    ) -> LayoutVerbResult {
        self.apply_verb(&app_id, device, actor, |_| {
            Ok(Verb::BindParam {
                target: target.to_pane_ref()?,
                name,
                source,
            })
        })
    }

    async fn set_channel(
        &self,
        app_id: String,
        device: Option<String>,
        target: PaneRefDto,
        channel: String,
        actor: Option<String>,
    ) -> LayoutVerbResult {
        self.apply_verb(&app_id, device, actor, |_| {
            Ok(Verb::SetChannel {
                target: target.to_pane_ref()?,
                channel: parse_channel(&channel)?,
            })
        })
    }

    async fn set_default_channel(
        &self,
        app_id: String,
        device: Option<String>,
        window: Option<u64>,
        channel: String,
        actor: Option<String>,
    ) -> LayoutVerbResult {
        self.apply_verb(&app_id, device, actor, |session| {
            Ok(Verb::SetDefaultChannel {
                window: window_or_current(session, window)?,
                channel: parse_channel(&channel)?,
            })
        })
    }

    async fn set_role(
        &self,
        app_id: String,
        device: Option<String>,
        target: PaneRefDto,
        role: Option<String>,
        actor: Option<String>,
    ) -> LayoutVerbResult {
        self.apply_verb(&app_id, device, actor, |_| {
            Ok(Verb::SetRole {
                target: target.to_pane_ref()?,
                role: role
                    .map(|r| r.trim().to_string())
                    .filter(|r| !r.is_empty())
                    .map(Role::from),
            })
        })
    }

    async fn focus(
        &self,
        app_id: String,
        device: Option<String>,
        target: PaneRefDto,
        actor: Option<String>,
    ) -> LayoutVerbResult {
        self.apply_verb(&app_id, device, actor, |_| {
            Ok(Verb::Focus {
                target: target.to_pane_ref()?,
            })
        })
    }

    async fn focus_direction(
        &self,
        app_id: String,
        device: Option<String>,
        direction: String,
        actor: Option<String>,
    ) -> LayoutVerbResult {
        self.apply_verb(&app_id, device, actor, |_| {
            Ok(Verb::FocusDirection {
                direction: parse_direction(&direction)?,
            })
        })
    }

    async fn select(
        &self,
        app_id: String,
        device: Option<String>,
        target: PaneRefDto,
        kind: String,
        ids: Vec<String>,
        actor: Option<String>,
    ) -> LayoutVerbResult {
        self.apply_verb(&app_id, device, actor, |_| {
            Ok(Verb::Select {
                target: target.to_pane_ref()?,
                kind: kind.trim().to_string(),
                ids: parse_ids(&ids)?,
            })
        })
    }

    async fn set_window_geometry(
        &self,
        app_id: String,
        device: Option<String>,
        window: Option<u64>,
        geometry: Option<Geometry>,
        actor: Option<String>,
    ) -> LayoutVerbResult {
        self.apply_verb(&app_id, device, actor, |session| {
            Ok(Verb::SetWindowGeometry {
                window: window_or_current(session, window)?,
                geometry,
            })
        })
    }

    async fn commit(
        &self,
        app_id: String,
        device: Option<String>,
        as_kind: String,
        name: String,
        purpose: Option<String>,
        actor: Option<String>,
    ) -> LayoutVerbResult {
        match as_kind.trim().to_ascii_lowercase().as_str() {
            "layout" | "" => self.save_layout(app_id, device, name, purpose, actor).await,
            // L7: a preset IS a materializable commit of the current
            // arrangement, so the verb that promised it now keeps its word.
            // The result envelope differs, so this reports what `save_preset`
            // said rather than returning its row.
            "preset" => {
                let saved = self
                    .save_preset(app_id, device, name, purpose, true, actor)
                    .await;
                if saved.ok {
                    LayoutVerbResult {
                        ok: true,
                        message: saved.message,
                        focused: None,
                        affected_panes: Vec::new(),
                        window: None,
                        stack: None,
                        stack_pane: None,
                        patch: None,
                    }
                } else {
                    LayoutVerbResult::failed(saved.message)
                }
            }
            other => LayoutVerbResult::failed(format!(
                "cannot commit the current bindings as a '{other}' yet — only 'layout' and \
                 'preset' are materializable today. Committing a figure or a collection is the \
                 same verb with a different `as_kind` and arrives with the implore work."
            )),
        }
    }

    async fn save_layout(
        &self,
        app_id: String,
        device: Option<String>,
        name: String,
        purpose: Option<String>,
        actor: Option<String>,
    ) -> LayoutVerbResult {
        let actor_kind = actor_from(actor.as_deref());
        let outcome = self.with_session(&app_id, device, actor_kind, |session, store| {
            let intent = format!("committed the arrangement as '{}'", name.trim());
            let row = store.save_named(
                &session.app_id,
                &name,
                purpose.as_deref(),
                &session.layout,
                actor_kind,
                &intent,
            )?;
            // ADR-0031 D7: undo never crosses a commit.
            session.commit_boundary();
            Ok(LayoutVerbResult::from_layout(
                format!("Saved '{}' ({}).", row.name.unwrap_or_default(), row.id),
                &session.layout,
                None,
                None,
            ))
        });
        outcome.unwrap_or_else(LayoutVerbResult::failed)
    }

    async fn apply_layout(
        &self,
        app_id: String,
        device: Option<String>,
        name: Option<String>,
        ordinal: Option<u32>,
        actor: Option<String>,
    ) -> LayoutVerbResult {
        let actor_kind = actor_from(actor.as_deref());
        let outcome = self.with_session(&app_id, device, actor_kind, |session, store| {
            // An ordinal spans the SAME union `list_presets` numbers: this
            // app's presets, then its named layouts (`presets::ordinal_targets`).
            // So ⌃⌘1 is the app's default preset on a machine that has never
            // saved a layout and on one that has saved nine.
            if let (None, Some(ordinal)) = (
                name.as_deref().map(str::trim).filter(|n| !n.is_empty()),
                ordinal,
            ) {
                if ordinal == 0 {
                    return Err("layout ordinals are 1-based (⌃⌘1–9)".to_string());
                }
                let presets = PresetStore::new(store.store().clone());
                let targets = presets::ordinal_targets(&presets, store, &session.app_id)?;
                let target = targets.get(ordinal as usize - 1).ok_or_else(|| {
                    format!(
                        "no preset or saved layout at ordinal {ordinal}; this app has {}",
                        targets.len()
                    )
                })?;
                return match target {
                    presets::OrdinalTarget::Preset(row) => {
                        apply_preset_row(session, store, &presets, &row.name, actor_kind)
                    }
                    presets::OrdinalTarget::Layout(row) => {
                        let id = row.id.to_string();
                        let (row, layout) = store
                            .load_named(&session.app_id, &id)?
                            .ok_or_else(|| format!("saved layout {id} vanished"))?;
                        apply_tree(
                            session,
                            store,
                            layout,
                            &label_of(&row),
                            actor_kind,
                            "saved layout",
                        )
                    }
                };
            }

            let Some(name) = name.as_deref().map(str::trim).filter(|n| !n.is_empty()) else {
                return Err("apply_layout needs a name or an ordinal".to_string());
            };
            let (row, layout) = match store.load_named(&session.app_id, name)? {
                Some(found) => found,
                // A name that is not a saved layout may be a PRESET — the two
                // share the ⌃⌘1–9 union, so they must share the name space a
                // palette types into as well. Refusing "Triage" because it is
                // a preset rather than a layout would be a distinction only
                // this crate can see.
                None => {
                    let presets = PresetStore::new(store.store().clone());
                    presets.ensure_shipped(&session.app_id)?;
                    if presets.load(&session.app_id, name)?.is_some() {
                        return apply_preset_row(session, store, &presets, name, actor_kind);
                    }
                    return Err(format!("no saved layout or preset named '{name}'"));
                }
            };
            apply_tree(
                session,
                store,
                layout,
                &label_of(&row),
                actor_kind,
                "saved layout",
            )
        });
        outcome.unwrap_or_else(LayoutVerbResult::failed)
    }

    async fn undo(
        &self,
        app_id: String,
        device: Option<String>,
        stack: String,
        target: PaneRefDto,
        actor: Option<String>,
    ) -> LayoutVerbResult {
        self.step_ring(&app_id, device, &stack, target, actor, true)
    }

    async fn redo(
        &self,
        app_id: String,
        device: Option<String>,
        stack: String,
        target: PaneRefDto,
        actor: Option<String>,
    ) -> LayoutVerbResult {
        self.step_ring(&app_id, device, &stack, target, actor, false)
    }

    async fn get_layout(&self, app_id: String, device: Option<String>) -> LayoutResult {
        let device_tag = resolve_device(device.as_deref());
        let outcome = self.with_session(
            &app_id,
            Some(device_tag.clone()),
            ActorKind::Agent,
            |session, _| {
                let window = session.layout.current_window().ok();
                Ok(LayoutResult {
                    ok: true,
                    message: format!(
                        "{} window(s), {} pane(s).",
                        session.layout.windows.len(),
                        session.layout.panes().len()
                    ),
                    focused: window.and_then(|w| session.focused(w)).map(TileId::raw),
                    affected_panes: raw_tiles(&session.layout.panes()),
                    window: window.map(WindowId::raw),
                    item_id: Some(session.item_id.to_string()),
                    device: Some(session.device.clone()),
                    layout: Some(session.layout.clone()),
                })
            },
        );
        outcome.unwrap_or_else(LayoutResult::failed)
    }

    async fn get_pane(
        &self,
        app_id: String,
        device: Option<String>,
        target: PaneRefDto,
    ) -> PaneResult {
        let outcome = self.with_session(&app_id, device, ActorKind::Agent, |session, store| {
            let window = session.layout.current_window().map_err(|e| e.to_string())?;
            let reference = target.to_pane_ref()?;
            let tile = session
                .layout
                .resolve(window, &reference)
                .map_err(|e| e.to_string())?;
            let spec = session
                .layout
                .pane(tile)
                .ok_or_else(|| format!("tile {tile} is a container, not a pane"))?
                .clone();

            let bindings = session.layout.bindings_for(tile);
            let decls: Vec<ParamDecl> = spec.params.iter().map(|b| b.decl.clone()).collect();
            let resolver = CollectionSubtrees::read(store.store());
            let compiled = match compile_with(
                &spec.query,
                &decls,
                &bindings,
                &builtin_manifest(),
                &resolver,
            ) {
                Ok(compiled) => CompiledQueryDto::compiled(&compiled),
                Err(e) => CompiledQueryDto::refused(&e),
            };

            Ok(PaneResult {
                ok: true,
                message: format!("pane {tile} renders '{}'", spec.view_kind),
                tile: Some(tile.raw()),
                query: Some(compiled),
                bindings: binding_map(&bindings),
                channel: session.channel_of(tile),
                focused: session.focused(window).map(TileId::raw),
                affected_panes: vec![tile.raw()],
                spec: Some(spec),
            })
        });
        outcome.unwrap_or_else(PaneResult::failed)
    }

    async fn get_channel(
        &self,
        app_id: String,
        device: Option<String>,
        channel: String,
        kind: Option<String>,
    ) -> ChannelResult {
        let outcome = self.with_session(&app_id, device, ActorKind::Agent, |session, _| {
            let id = parse_channel(&channel)?;
            let window = session.layout.current_window().ok();
            let default = window
                .and_then(|w| session.layout.window(w))
                .map(|w| w.default_channel)
                .unwrap_or(ChannelId::ONE);
            let number = id.resolve(default);
            let wanted = kind.as_deref().map(str::trim).filter(|k| !k.is_empty());

            let mut selections: BTreeMap<String, Vec<String>> = BTreeMap::new();
            if let Some(per_kind) = session.layout.channels.channels.get(&number) {
                for (record_kind, ids) in per_kind {
                    if wanted.map(|w| w != record_kind).unwrap_or(false) {
                        continue;
                    }
                    selections.insert(
                        record_kind.clone(),
                        ids.iter().map(|id| id.to_string()).collect(),
                    );
                }
            }

            let mut affected: Vec<TileId> = Vec::new();
            let kinds: Vec<String> = match wanted {
                Some(k) => vec![k.to_string()],
                None => selections.keys().cloned().collect(),
            };
            for record_kind in &kinds {
                for tile in session
                    .layout
                    .affected_panes(ChannelId::Number(number), record_kind)
                {
                    if !affected.contains(&tile) {
                        affected.push(tile);
                    }
                }
            }

            Ok(ChannelResult {
                ok: true,
                message: format!("channel {number} carries {} kind(s)", selections.len()),
                channel: number,
                selections,
                affected_panes: raw_tiles(&affected),
                focused: window.and_then(|w| session.focused(w)).map(TileId::raw),
            })
        });
        outcome.unwrap_or_else(ChannelResult::failed)
    }

    async fn resolve_reference(
        &self,
        app_id: String,
        device: Option<String>,
        target: PaneRefDto,
    ) -> ReferenceResult {
        let outcome = self.with_session(&app_id, device, ActorKind::Agent, |session, _| {
            let window = session.layout.current_window().map_err(|e| e.to_string())?;
            let reference = target.to_pane_ref()?;
            let tile = session
                .layout
                .resolve(window, &reference)
                .map_err(|e| e.to_string())?;
            let spec = session.layout.pane(tile);
            Ok(ReferenceResult {
                ok: true,
                message: format!("{reference:?} is tile {tile}"),
                tile: Some(tile.raw()),
                role: spec.and_then(|s| s.role.as_ref()).map(|r| r.to_string()),
                view_kind: spec.map(|s| s.view_kind.to_string()),
                is_pane: spec.is_some(),
                focused: session.focused(window).map(TileId::raw),
                affected_panes: vec![tile.raw()],
            })
        });
        outcome.unwrap_or_else(ReferenceResult::failed)
    }

    async fn list_layouts(&self, app_id: String) -> LayoutListResult {
        let store = self.layout_store();
        // The presets hold the first ordinals of the union (see
        // `presets::ordinal_targets`), so a saved layout's chord starts after
        // them. Seeding here is what makes the offset the same number on
        // every machine rather than "however many presets happen to exist".
        let presets = PresetStore::new(store.store().clone());
        let offset = match presets.ensure_shipped(&app_id) {
            Ok(rows) => rows.len() as u32,
            Err(e) => return LayoutListResult::failed(e),
        };
        match store.list_named(&app_id) {
            Ok(rows) => {
                let layouts: Vec<SavedLayoutDto> = rows
                    .into_iter()
                    .enumerate()
                    .map(|(index, row)| SavedLayoutDto {
                        id: row.id.to_string(),
                        ordinal: offset + index as u32 + 1,
                        name: row.name,
                        purpose: row.purpose,
                        app_id: row.app_id,
                        device: row.device,
                        is_live: row.is_live,
                        modified: row.modified.to_rfc3339(),
                    })
                    .collect();
                LayoutListResult {
                    ok: true,
                    message: format!("{} saved layout(s).", layouts.len()),
                    layouts,
                }
            }
            Err(e) => LayoutListResult::failed(e),
        }
    }

    // --------------------------------------------------------------- presets

    async fn list_presets(&self, app_id: String) -> PresetListResult {
        let store = self.layout_store();
        let presets = PresetStore::new(store.store().clone());
        let rows = match presets.ensure_shipped(&app_id) {
            Ok(rows) => rows,
            Err(e) => return PresetListResult::failed(e),
        };
        let mut dtos: Vec<PresetDto> = Vec::with_capacity(rows.len());
        for (index, row) in rows.iter().enumerate() {
            match preset_dto(&presets, row, index as u32 + 1) {
                Ok(dto) => dtos.push(dto),
                Err(e) => return PresetListResult::failed(e),
            }
        }
        let known = presets::named_queries(&app_id);
        PresetListResult {
            ok: true,
            message: format!("{} preset(s), {} named quer(ies).", dtos.len(), known.len()),
            presets: dtos,
            materialize_first: presets::MATERIALIZE_FIRST
                .iter()
                .map(|(section, reason)| MaterializeFirstDto {
                    section: (*section).to_string(),
                    reason: (*reason).to_string(),
                })
                .collect(),
        }
    }

    async fn apply_preset(
        &self,
        app_id: String,
        device: Option<String>,
        name: String,
        actor: Option<String>,
    ) -> LayoutVerbResult {
        let actor_kind = actor_from(actor.as_deref());
        let outcome = self.with_session(&app_id, device, actor_kind, |session, store| {
            let presets = PresetStore::new(store.store().clone());
            presets.ensure_shipped(&session.app_id)?;
            apply_preset_row(session, store, &presets, &name, actor_kind)
        });
        outcome.unwrap_or_else(LayoutVerbResult::failed)
    }

    async fn save_preset(
        &self,
        app_id: String,
        device: Option<String>,
        name: String,
        purpose: Option<String>,
        from_live: bool,
        actor: Option<String>,
    ) -> PresetResult {
        if !from_live {
            return PresetResult::failed(
                "save_preset builds a preset from the LIVE arrangement, so `from_live` must be \
                 true. Building one from a saved layout or from another preset is a different \
                 verb and does not exist yet.",
            );
        }
        let actor_kind = actor_from(actor.as_deref());
        let outcome = self.with_session(&app_id, device, actor_kind, |session, store| {
            let presets = PresetStore::new(store.store().clone());
            presets.ensure_shipped(&session.app_id)?;
            let roles = presets::roles_of(&session.layout);
            let queries = presets::named_queries(&session.app_id);
            let intent = format!("saved the arrangement as the preset '{}'", name.trim());
            let row = presets.save(
                &session.app_id,
                &name,
                purpose.as_deref(),
                &session.layout,
                &queries,
                &roles,
                // The shipped revision is NOT rewritten by a user's edit:
                // keeping it is what lets `reset_preset` undo this and what
                // distinguishes "the user edited Triage" from "we shipped a
                // newer Triage" (`schemas/ui.rs`, `version`).
                None,
                actor_kind,
                &intent,
            )?;
            // ADR-0031 D7: undo never crosses a commit, and a preset is one.
            session.commit_boundary();
            presets::record_derived_from(
                store.store(),
                session.item_id,
                row.id,
                actor_kind,
                &intent,
            )?;
            let ordinal = ordinal_of(&presets, store, &session.app_id, row.id)?;
            Ok(PresetResult {
                ok: true,
                message: format!("Saved the preset '{}' ({}).", row.name, row.id),
                preset: Some(preset_dto(&presets, &row, ordinal)?),
            })
        });
        outcome.unwrap_or_else(PresetResult::failed)
    }

    async fn reset_preset(
        &self,
        app_id: String,
        name: String,
        actor: Option<String>,
    ) -> PresetResult {
        let actor_kind = actor_from(actor.as_deref());
        let store = self.layout_store();
        let presets = PresetStore::new(store.store().clone());
        if let Err(e) = presets.ensure_shipped(&app_id) {
            return PresetResult::failed(e);
        }
        let row = match presets.reset(&app_id, &name, actor_kind) {
            Ok(row) => row,
            Err(e) => return PresetResult::failed(e),
        };
        let ordinal = match ordinal_of(&presets, &store, &app_id, row.id) {
            Ok(ordinal) => ordinal,
            Err(e) => return PresetResult::failed(e),
        };
        match preset_dto(&presets, &row, ordinal) {
            Ok(dto) => PresetResult {
                ok: true,
                message: format!(
                    "Reset '{}' to the revision the suite ships (v{}).",
                    row.name,
                    row.version.unwrap_or(0)
                ),
                preset: Some(dto),
            },
            Err(e) => PresetResult::failed(e),
        }
    }
}

/// Where a preset sits in the ⌃⌘1–9 union, 1-based. `0` when it is somehow
/// not in it at all, which a caller reads as "no chord" rather than as a
/// claim about position one.
fn ordinal_of(
    presets: &PresetStore,
    layouts: &LayoutStore,
    app_id: &str,
    id: ItemId,
) -> Result<u32, String> {
    Ok(presets::ordinal_targets(presets, layouts, app_id)?
        .iter()
        .position(|target| match target {
            presets::OrdinalTarget::Preset(row) => row.id == id,
            presets::OrdinalTarget::Layout(row) => row.id == id,
        })
        .map(|index| index as u32 + 1)
        .unwrap_or(0))
}

impl DefaultLayoutService {
    fn step_ring(
        &self,
        app_id: &str,
        device: Option<String>,
        stack: &str,
        target: PaneRefDto,
        actor: Option<String>,
        undo: bool,
    ) -> LayoutVerbResult {
        let actor_kind = actor_from(actor.as_deref());
        let outcome = self.with_session(app_id, device, actor_kind, |session, store| {
            let arrangement = parse_stack(stack)?;
            let ring = if arrangement {
                UndoTarget::Arrangement
            } else {
                UndoTarget::Exploration(target.to_pane_ref()?)
            };
            let stepped = if undo {
                session.undo(&ring).map_err(|e| e.to_string())?
            } else {
                session.redo(&ring).map_err(|e| e.to_string())?
            };
            let word = if undo { "undo" } else { "redo" };
            let Some(patch) = stepped else {
                // An empty ring is a no-op, not a failure: ⌘Z with nothing to
                // undo does nothing everywhere else in macOS too.
                return Ok(LayoutVerbResult::from_layout(
                    format!("nothing to {word} on the {} ring", ring_name(&ring)),
                    &session.layout,
                    None,
                    None,
                ));
            };
            let intent = format!("{word}: {}", intent_text(&patch.verb));
            store.save_live(
                &session.app_id,
                &session.device,
                &session.layout,
                actor_kind,
                &intent,
            )?;
            let named = match &ring {
                UndoTarget::Arrangement => Stack::Arrangement,
                UndoTarget::Exploration(_) => session
                    .layout
                    .current_window()
                    .ok()
                    .and_then(|w| match &ring {
                        UndoTarget::Exploration(reference) => {
                            session.layout.resolve(w, reference).ok()
                        }
                        UndoTarget::Arrangement => None,
                    })
                    .map(Stack::Exploration)
                    .unwrap_or(Stack::Unrecorded),
            };
            Ok(LayoutVerbResult::from_layout(
                intent,
                &session.layout,
                Some(&patch),
                Some(&named),
            ))
        });
        outcome.unwrap_or_else(LayoutVerbResult::failed)
    }
}

fn ring_name(target: &UndoTarget) -> &'static str {
    match target {
        UndoTarget::Arrangement => "arrangement",
        UndoTarget::Exploration(_) => "exploration",
    }
}

fn window_or_current(session: &LayoutSession, window: Option<u64>) -> Result<WindowId, String> {
    match window {
        Some(raw) => Ok(WindowId::new(raw)),
        None => session.layout.current_window().map_err(|e| e.to_string()),
    }
}

fn binding_map(bindings: &Bindings) -> BTreeMap<String, String> {
    bindings
        .values
        .iter()
        .map(|(name, id)| (name.clone(), id.to_string()))
        .collect()
}

/// The collection tree, flattened into a parent → children map, so
/// `Scope::CollectionSubtree` compiles to "this folder and everything under
/// it" instead of degrading to the folder's own members.
///
/// Every binding is read, because a pane's scope names a collection id and not
/// which hierarchy it belongs to — and the ids are unique across all of them,
/// so the union is unambiguous. A binding that fails to read contributes
/// nothing rather than failing the compile: a pane scoped to a collection in
/// *another* hierarchy must still resolve.
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
        // The root is always included: a subtree contains its own root, and a
        // resolver that returned only descendants would silently drop the
        // folder's own members.
        let mut out = vec![root];
        let mut cursor = 0;
        while cursor < out.len() {
            let node = out[cursor];
            cursor += 1;
            if let Some(kids) = self.children.get(&node) {
                for kid in kids {
                    if !out.contains(kid) {
                        out.push(*kid);
                    }
                }
            }
        }
        out
    }
}

impress_service_impl! {
    service = LayoutService,
    impl = DefaultLayoutService,
    instance = DefaultLayoutService::new,
    methods = [
        split(
            app_id: String,
            device: Option<String>,
            target: PaneRefDto,
            direction: String,
            after: bool,
            new_pane: Option<PaneSpec>,
            actor: Option<String>
        ) -> LayoutVerbResult,
        move_tile(
            app_id: String,
            device: Option<String>,
            tile: PaneRefDto,
            target: PaneRefDto,
            placement: String,
            actor: Option<String>
        ) -> LayoutVerbResult,
        close(
            app_id: String,
            device: Option<String>,
            target: PaneRefDto,
            actor: Option<String>
        ) -> LayoutVerbResult,
        swap(
            app_id: String,
            device: Option<String>,
            a: PaneRefDto,
            b: PaneRefDto,
            actor: Option<String>
        ) -> LayoutVerbResult,
        resize(
            app_id: String,
            device: Option<String>,
            container: u64,
            shares: Vec<f32>,
            actor: Option<String>
        ) -> LayoutVerbResult,
        set_container_kind(
            app_id: String,
            device: Option<String>,
            container: u64,
            kind: String,
            actor: Option<String>
        ) -> LayoutVerbResult,
        maximize(
            app_id: String,
            device: Option<String>,
            target: PaneRefDto,
            actor: Option<String>
        ) -> LayoutVerbResult,
        restore(
            app_id: String,
            device: Option<String>,
            actor: Option<String>
        ) -> LayoutVerbResult,
        detach(
            app_id: String,
            device: Option<String>,
            target: PaneRefDto,
            actor: Option<String>
        ) -> LayoutVerbResult,
        set_pane(
            app_id: String,
            device: Option<String>,
            target: PaneRefDto,
            spec: PaneSpec,
            actor: Option<String>
        ) -> LayoutVerbResult,
        set_query(
            app_id: String,
            device: Option<String>,
            target: PaneRefDto,
            query: PaneQuery,
            actor: Option<String>
        ) -> LayoutVerbResult,
        set_view_kind(
            app_id: String,
            device: Option<String>,
            target: PaneRefDto,
            view_kind: String,
            actor: Option<String>
        ) -> LayoutVerbResult,
        bind_param(
            app_id: String,
            device: Option<String>,
            target: PaneRefDto,
            name: String,
            source: ParamSource,
            actor: Option<String>
        ) -> LayoutVerbResult,
        set_channel(
            app_id: String,
            device: Option<String>,
            target: PaneRefDto,
            channel: String,
            actor: Option<String>
        ) -> LayoutVerbResult,
        set_default_channel(
            app_id: String,
            device: Option<String>,
            window: Option<u64>,
            channel: String,
            actor: Option<String>
        ) -> LayoutVerbResult,
        set_role(
            app_id: String,
            device: Option<String>,
            target: PaneRefDto,
            role: Option<String>,
            actor: Option<String>
        ) -> LayoutVerbResult,
        focus(
            app_id: String,
            device: Option<String>,
            target: PaneRefDto,
            actor: Option<String>
        ) -> LayoutVerbResult,
        focus_direction(
            app_id: String,
            device: Option<String>,
            direction: String,
            actor: Option<String>
        ) -> LayoutVerbResult,
        select(
            app_id: String,
            device: Option<String>,
            target: PaneRefDto,
            kind: String,
            ids: Vec<String>,
            actor: Option<String>
        ) -> LayoutVerbResult,
        set_window_geometry(
            app_id: String,
            device: Option<String>,
            window: Option<u64>,
            geometry: Option<Geometry>,
            actor: Option<String>
        ) -> LayoutVerbResult,
        commit(
            app_id: String,
            device: Option<String>,
            as_kind: String,
            name: String,
            purpose: Option<String>,
            actor: Option<String>
        ) -> LayoutVerbResult,
        save_layout(
            app_id: String,
            device: Option<String>,
            name: String,
            purpose: Option<String>,
            actor: Option<String>
        ) -> LayoutVerbResult,
        apply_layout(
            app_id: String,
            device: Option<String>,
            name: Option<String>,
            ordinal: Option<u32>,
            actor: Option<String>
        ) -> LayoutVerbResult,
        undo(
            app_id: String,
            device: Option<String>,
            stack: String,
            target: PaneRefDto,
            actor: Option<String>
        ) -> LayoutVerbResult,
        redo(
            app_id: String,
            device: Option<String>,
            stack: String,
            target: PaneRefDto,
            actor: Option<String>
        ) -> LayoutVerbResult,
        get_layout(app_id: String, device: Option<String>) -> LayoutResult,
        get_pane(
            app_id: String,
            device: Option<String>,
            target: PaneRefDto
        ) -> PaneResult,
        get_channel(
            app_id: String,
            device: Option<String>,
            channel: String,
            kind: Option<String>
        ) -> ChannelResult,
        resolve_reference(
            app_id: String,
            device: Option<String>,
            target: PaneRefDto
        ) -> ReferenceResult,
        list_layouts(app_id: String) -> LayoutListResult,
        list_presets(app_id: String) -> PresetListResult,
        apply_preset(
            app_id: String,
            device: Option<String>,
            name: String,
            actor: Option<String>
        ) -> LayoutVerbResult,
        save_preset(
            app_id: String,
            device: Option<String>,
            name: String,
            purpose: Option<String>,
            from_live: bool,
            actor: Option<String>
        ) -> PresetResult,
        reset_preset(
            app_id: String,
            name: String,
            actor: Option<String>
        ) -> PresetResult,
    ],
}
