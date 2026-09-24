//! The in-memory half of a layout: the tree, its two undo rings, and the
//! channel state that lives inside the tree already.
//!
//! A [`LayoutSession`] is one `(app_id, device)` scope. The store holds the
//! tree; the session holds the tree **plus the rings**, which are deliberately
//! not persisted: an undo ring is a record of what this sitting has done, and
//! restoring one from a file would let ⌘Z revert a gesture made on another
//! device last week (ADR-0031 D7 — undo never crosses a commit, and a quit is
//! at least as strong a boundary as a commit).
//!
//! Sessions live in a process-wide registry, the same shape
//! `impress_store_service::store_instance()` uses for the store: one map, one
//! mutex, entries created on first touch.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};

use impress_core::item::{ActorKind, ItemId};
use impress_layout::{
    stack_for, ChannelId, Layout, LayoutError, PaneRef, Patch, StackKind, TileId, UndoStacks, Verb,
    WindowId,
};

use crate::store::LayoutStore;

/// Which ring a verb's patch landed on — what a caller needs to know to route
/// the right ⌘Z back to it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Stack {
    /// The arrangement ring: split, move, close, resize, roles, geometry.
    Arrangement,
    /// One pane's exploration ring: query, view kind, bindings, selection.
    Exploration(TileId),
    /// Focus verbs record nothing (ADR-0031 D7): undoing a focus move is what
    /// the opposite focus move is for.
    Unrecorded,
}

impl Stack {
    pub fn name(&self) -> &'static str {
        match self {
            Stack::Arrangement => "arrangement",
            Stack::Exploration(_) => "exploration",
            Stack::Unrecorded => "none",
        }
    }

    pub fn pane(&self) -> Option<TileId> {
        match self {
            Stack::Exploration(tile) => Some(*tile),
            _ => None,
        }
    }
}

/// Which ring an `undo` / `redo` verb addresses.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum UndoTarget {
    Arrangement,
    /// The exploration ring of the pane this reference names.
    Exploration(PaneRef),
}

/// What applying a verb did — the renderer's whole input.
#[derive(Debug, Clone)]
pub struct AppliedVerb {
    pub patch: Patch,
    /// The window the verb resolved against.
    pub window: WindowId,
    /// The focused leaf afterwards.
    pub focused: Option<TileId>,
    /// The panes a renderer must redraw. For `select` this is
    /// [`Layout::affected_panes`] — every pane whose bindings the publication
    /// changed — plus the publishing pane itself; for every other verb it is
    /// the tiles the patch touched that are still panes.
    pub affected: Vec<TileId>,
    /// Which ring the patch went on.
    pub stack: Stack,
}

/// One `(app_id, device)` scope, live in memory.
pub struct LayoutSession {
    pub app_id: String,
    pub device: String,
    /// The `impress/ui/layout@1.0.0` row this session is the live value of.
    pub item_id: ItemId,
    pub layout: Layout,
    pub undo: UndoStacks,
    /// The registry's write generation, bumped by every mutation below so a
    /// renderer sharing the registry learns the tree moved under it. See
    /// [`SessionRegistry::generation`].
    pub(crate) generation: Arc<std::sync::atomic::AtomicU64>,
}

impl LayoutSession {
    fn note_write(&self) {
        self.generation
            .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
    }
}

impl LayoutSession {
    /// Apply a verb, recording its patch on the ring [`stack_for`] chooses.
    pub fn apply(&mut self, verb: Verb) -> Result<AppliedVerb, LayoutError> {
        let applied = self.apply_inner(verb)?;
        self.note_write();
        Ok(applied)
    }

    fn apply_inner(&mut self, verb: Verb) -> Result<AppliedVerb, LayoutError> {
        let window = self.layout.current_window()?;

        // Resolved BEFORE the verb runs, for the same reason `UndoStacks::apply`
        // resolves its own destination first: after a split or a move,
        // `Focused` and a direction mean something else.
        let stack = match stack_for(&verb) {
            StackKind::Arrangement => Stack::Arrangement,
            StackKind::Exploration(reference) => match self.layout.resolve(window, &reference) {
                Ok(tile) => Stack::Exploration(tile),
                Err(_) => Stack::Unrecorded,
            },
            StackKind::None => Stack::Unrecorded,
        };

        // A selection's fan-out is a property of the channel it is published
        // on, which is the publishing pane's channel — read before the verb,
        // because `Select` may be the thing that changes what is focused.
        let selection = match &verb {
            Verb::Select { target, kind, .. } => {
                self.layout.resolve(window, target).ok().and_then(|tile| {
                    self.layout
                        .pane(tile)
                        .map(|spec| (tile, spec.channel, kind.clone()))
                })
            }
            _ => None,
        };

        let patch = self.undo.apply(&mut self.layout, verb)?;

        let affected = match selection {
            Some((tile, channel, kind)) => {
                let mut out = vec![tile];
                for pane in self.layout.affected_panes(channel, &kind) {
                    if !out.contains(&pane) {
                        out.push(pane);
                    }
                }
                out
            }
            None => patch
                .tiles
                .keys()
                .copied()
                .filter(|tile| self.layout.pane(*tile).is_some())
                .collect(),
        };

        Ok(AppliedVerb {
            patch,
            window,
            focused: self.focused(window),
            affected,
            stack,
        })
    }

    /// Undo on one ring. `None` means the ring was empty — not an error: a ⌘Z
    /// with nothing to undo is a no-op everywhere else in macOS too.
    pub fn undo(&mut self, target: &UndoTarget) -> Result<Option<Patch>, LayoutError> {
        let pane = self.ring_pane(target)?;
        let stepped = match pane {
            Some(tile) => self.undo.undo_exploration(&mut self.layout, tile),
            None => self.undo.undo_arrangement(&mut self.layout),
        };
        if stepped.is_some() {
            self.note_write();
        }
        Ok(stepped)
    }

    /// Redo on one ring.
    pub fn redo(&mut self, target: &UndoTarget) -> Result<Option<Patch>, LayoutError> {
        let pane = self.ring_pane(target)?;
        let stepped = match pane {
            Some(tile) => self.undo.exploration_ring(tile).redo(&mut self.layout),
            None => self.undo.arrangement.redo(&mut self.layout),
        };
        if stepped.is_some() {
            self.note_write();
        }
        Ok(stepped)
    }

    /// Forget both rings.
    ///
    /// Called on a commit, because ADR-0031 D7 says undo never crosses one:
    /// after "save this arrangement as Triage", ⌘Z must not quietly take the
    /// user back through the gestures that produced it. Reverting a commit is
    /// the ordinary item-level `inverse_of` operation on the saved row.
    pub fn commit_boundary(&mut self) {
        self.undo = UndoStacks::new(self.undo.capacity);
    }

    /// Replace the whole tree (`apply_layout`). The rings go with it: the
    /// patches on them describe tiles that no longer exist.
    pub fn replace(&mut self, layout: Layout) {
        self.layout = layout;
        self.undo = UndoStacks::new(self.undo.capacity);
        self.note_write();
    }

    /// The focused leaf of `window`, or of whatever window survived.
    pub fn focused(&self, window: WindowId) -> Option<TileId> {
        self.layout
            .window(window)
            .and_then(|w| w.focused)
            .or_else(|| {
                self.layout
                    .current_window()
                    .ok()
                    .and_then(|w| self.layout.window(w))
                    .and_then(|w| w.focused)
            })
    }

    /// The channel a pane publishes on, resolved against its window's default.
    pub fn channel_of(&self, tile: TileId) -> Option<u8> {
        let spec = self.layout.pane(tile)?;
        let window = self.layout.window_of(tile)?;
        let default = self
            .layout
            .window(window)
            .map(|w| w.default_channel)
            .unwrap_or(ChannelId::ONE);
        Some(spec.channel.resolve(default))
    }

    fn ring_pane(&self, target: &UndoTarget) -> Result<Option<TileId>, LayoutError> {
        match target {
            UndoTarget::Arrangement => Ok(None),
            UndoTarget::Exploration(reference) => {
                let window = self.layout.current_window()?;
                Ok(Some(self.layout.resolve(window, reference)?))
            }
        }
    }
}

// ---------------------------------------------------------------------------
// The registry
// ---------------------------------------------------------------------------

type SessionMap = HashMap<(String, String), LayoutSession>;

/// The process-wide session table. Private sessions (tests, embedders) get
/// their own [`SessionRegistry`]; everything else shares this one.
#[derive(Default)]
pub struct SessionRegistry {
    sessions: Mutex<SessionMap>,
    /// Bumped by every session mutation made through this registry — see
    /// [`Self::generation`]. An `Arc` so each session can hold a handle and
    /// bump it without reaching back through the registry's lock.
    generation: Arc<std::sync::atomic::AtomicU64>,
}

impl SessionRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    /// How many live-row writes this registry has made. A renderer that
    /// SHARES the registry with other writers in its process (ADR-0033 D6:
    /// a surface's `open`/`publish` effect composes layout verbs) polls
    /// this to learn the tree changed under it — the in-process mutation
    /// channel reports the write as a pane invalidation, not as a tree
    /// change, and `PRAGMA data_version` is silent for the connection's own
    /// writes, so without this number a pane a surface opened sat in the
    /// store, in this very process, invisible to the window (2026-09-23).
    pub fn generation(&self) -> u64 {
        self.generation.load(std::sync::atomic::Ordering::SeqCst)
    }

    /// The shared registry, matching `store_instance()`'s shape.
    pub fn shared() -> Arc<SessionRegistry> {
        static GLOBAL: OnceLock<Arc<SessionRegistry>> = OnceLock::new();
        GLOBAL
            .get_or_init(|| Arc::new(SessionRegistry::new()))
            .clone()
    }

    /// Run `f` against the session for `(app_id, device)`, loading the live
    /// row (or cold-starting it) if this is the first touch.
    ///
    /// The lock is held for the whole closure — including the store write a
    /// verb makes — so two concurrent verbs on one scope cannot interleave
    /// into a tree that is neither's. The closure is synchronous on purpose:
    /// a guard must never be held across an `.await`.
    pub fn with<R>(
        &self,
        store: &LayoutStore,
        app_id: &str,
        device: &str,
        actor: ActorKind,
        f: impl FnOnce(&mut LayoutSession) -> R,
    ) -> Result<R, String> {
        let mut sessions = self.lock();
        let key = (app_id.to_string(), device.to_string());
        if !sessions.contains_key(&key) {
            let (item_id, mut layout) = store.load_live(app_id, device, actor)?;
            // A tree stored before its panes had sessions (or cold-started
            // from a preset, which carries none) is given them now, and saved
            // at once: a second process loading the same row must read the
            // SAME ids, or its next save would re-key every editor (D6).
            if layout.ensure_sessions() {
                store.save_live(
                    app_id,
                    device,
                    &layout,
                    actor,
                    "gave session-bearing panes their sessions",
                )?;
            }
            sessions.insert(
                key.clone(),
                LayoutSession {
                    app_id: app_id.to_string(),
                    device: device.to_string(),
                    item_id,
                    layout,
                    undo: UndoStacks::default(),
                    generation: self.generation.clone(),
                },
            );
        }
        let session = sessions
            .get_mut(&key)
            .expect("the session was just inserted");
        Ok(f(session))
    }

    /// Drop a scope's session, so the next touch re-reads the live row.
    ///
    /// L4: per-pane invalidation will let the projection do better than this —
    /// re-run the panes a mutation actually touched instead of dropping the
    /// whole session — but a session that another writer has overtaken has to
    /// be droppable today, and this is the one lever for it.
    // TODO(L4): subscribe to `impress_core::pane_query::invalidation` and
    // refresh the affected panes in place; add a test that a mutation on a
    // kind no pane queries leaves every session untouched.
    pub fn forget(&self, app_id: &str, device: &str) {
        self.lock()
            .remove(&(app_id.to_string(), device.to_string()));
    }

    /// How many scopes are live in memory. Diagnostics and tests.
    pub fn len(&self) -> usize {
        self.lock().len()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    fn lock(&self) -> MutexGuard<'_, SessionMap> {
        // A panic inside the closure cannot leave a session half-written — a
        // verb applies to a scratch clone and commits whole — so recover from
        // poisoning rather than propagate it, exactly as the store cell does.
        self.sessions
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}
