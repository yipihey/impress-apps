//! Tier A capabilities — pure Rust against the [`LayoutService`] trait over a
//! private in-memory store.
//!
//! No app, no UI, no network, no shared database: every capability opens its
//! own store and its own session registry, so they cannot see each other's
//! panes and can run in any order. This is the payoff of pushing the layout
//! into Rust — "does splitting a pane work?" is a two-millisecond assertion
//! instead of a click-through.
//!
//! The catalogue covers **every D8 verb**, the cold start, both undo rings,
//! ordinal recall, the one-live-row invariant, and the two failure modes that
//! matter: a reference that names nothing, and a query that will not compile.

use std::sync::Arc;

use impress_core::pane_query::{PaneQuery, Scope};
use impress_core::sqlite_store::SqliteItemStore;
use impress_layout::preset::DETAIL_PARAM;
use impress_layout::{
    ChannelId, Container, Geometry, Layout, PaneSpec, ParamSource, Role, Tile, TileId, ViewKindId,
};

use crate::dto::PaneRefDto;
use crate::report::{CapabilityResult, Tier};
use crate::service::{DefaultLayoutService, LayoutService};
use crate::store::{LayoutRow, LayoutStore};
use crate::{check, Result};

const APP: &str = "imbib";
/// Fixed, so the catalogue never depends on the host's name.
const DEVICE: &str = "selftest-device";

/// Run every Tier A capability and collect the results.
pub async fn run() -> Vec<CapabilityResult> {
    vec![
        cap_cold_start().await,
        cap_split().await,
        cap_move_tile().await,
        cap_close().await,
        cap_swap().await,
        cap_resize().await,
        cap_set_container_kind().await,
        cap_maximize_restore().await,
        cap_detach().await,
        cap_set_pane().await,
        cap_set_query().await,
        cap_set_view_kind().await,
        cap_bind_param().await,
        cap_set_channel().await,
        cap_set_default_channel().await,
        cap_set_role().await,
        cap_focus().await,
        cap_focus_direction().await,
        cap_select().await,
        cap_set_window_geometry().await,
        cap_save_and_apply_layout().await,
        cap_apply_layout_by_ordinal().await,
        cap_commit().await,
        cap_undo_redo_arrangement().await,
        cap_undo_redo_exploration().await,
        cap_get_layout().await,
        cap_get_pane_compiles_the_detail_query().await,
        cap_get_channel().await,
        cap_resolve_reference().await,
        cap_list_layouts().await,
        cap_one_live_row_per_scope().await,
        cap_misspelled_reference_is_refused().await,
    ]
}

// ---------------------------------------------------------------------------
// The world each capability runs in
// ---------------------------------------------------------------------------

struct World {
    service: DefaultLayoutService,
    store: Arc<SqliteItemStore>,
}

impl World {
    fn open() -> Result<Self> {
        let store =
            Arc::new(SqliteItemStore::open_in_memory().map_err(|e| format!("open store: {e}"))?);
        Ok(Self {
            service: DefaultLayoutService::with_store(store.clone()),
            store,
        })
    }

    fn device(&self) -> Option<String> {
        Some(DEVICE.to_string())
    }

    fn layouts(&self) -> LayoutStore {
        LayoutStore::new(self.store.clone())
    }

    /// The live tree as the STORE holds it — not as the session holds it.
    /// Every capability asserts against this at least once, because a verb
    /// that mutates memory and forgets to persist is the bug a Tier A test
    /// over an in-process session would otherwise never see.
    fn persisted(&self) -> Result<Layout> {
        self.layouts()
            .live_row(APP, DEVICE)?
            .map(|(_, layout)| layout)
            .ok_or_else(|| "no live row was persisted".to_string())
    }

    fn rows(&self) -> Result<Vec<LayoutRow>> {
        self.layouts().all_rows(APP)
    }

    /// The whole live tree, from the service.
    async fn layout(&self) -> Result<Layout> {
        let result = self.service.get_layout(APP.into(), self.device()).await;
        if !result.ok {
            return Err(result.message);
        }
        result
            .layout
            .ok_or_else(|| "get_layout returned no tree".to_string())
    }

    /// The tile carrying a role, from the live tree.
    async fn tile_with_role(&self, role: &str) -> Result<TileId> {
        let layout = self.layout().await?;
        layout
            .pane_with_role(&Role::from(role.to_string()))
            .ok_or_else(|| format!("no pane carries the role '{role}'"))
    }
}

fn want(condition: bool, message: impl Into<String>) -> Result<()> {
    if condition {
        Ok(())
    } else {
        Err(message.into())
    }
}

fn role_ref(role: &str) -> PaneRefDto {
    PaneRefDto::role(role)
}

/// Leaves of the first window, in tree order.
fn leaves(layout: &Layout) -> Result<Vec<TileId>> {
    let window = layout.current_window().map_err(|e| e.to_string())?;
    Ok(layout.leaves(window))
}

fn roles_in_order(layout: &Layout) -> Result<Vec<String>> {
    Ok(leaves(layout)?
        .into_iter()
        .map(|tile| {
            layout
                .pane(tile)
                .and_then(|p| p.role.as_ref())
                .map(|r| r.to_string())
                .unwrap_or_else(|| "-".to_string())
        })
        .collect())
}

// ---------------------------------------------------------------------------
// Capabilities
// ---------------------------------------------------------------------------

async fn cap_cold_start() -> CapabilityResult {
    check(
        "cold-start",
        "an app with no layout row gets the three-column preset, persisted as its live row",
        Tier::A,
        || async {
            let w = World::open()?;
            let layout = w.layout().await?;
            let roles = roles_in_order(&layout)?;
            want(
                roles == vec!["navigator", "list", "detail"],
                format!("expected navigator | list | detail, got {roles:?}"),
            )?;

            let rows = w.rows()?;
            want(
                rows.len() == 1 && rows[0].is_live,
                format!("expected exactly one live row, got {rows:?}"),
            )?;
            want(
                rows[0].device.as_deref() == Some(DEVICE),
                "the live row must carry its device tag (ADR-0019 D2)",
            )?;
            want(
                rows[0].name.is_none(),
                "the live row is distinguished by is_live, not by a reserved name",
            )?;
            // The persisted tree is the tree, not an empty shell.
            let persisted = w.persisted()?;
            want(
                persisted.panes().len() == 3,
                "the cold start must PERSIST the preset, not just return it",
            )?;
            Ok(format!("{} panes: {roles:?}", layout.panes().len()))
        },
    )
    .await
}

async fn cap_split() -> CapabilityResult {
    check(
        "split",
        "splitting the detail pane adds a pane, focuses it, and persists",
        Tier::A,
        || async {
            let w = World::open()?;
            let before = w.layout().await?.panes().len();
            let r = w
                .service
                .split(
                    APP.into(),
                    w.device(),
                    role_ref("detail"),
                    "vertical".into(),
                    true,
                    None,
                    Some("human".into()),
                )
                .await;
            want(r.ok, r.message.clone())?;
            let after = w.persisted()?;
            want(
                after.panes().len() == before + 1,
                format!("expected {} panes, got {}", before + 1, after.panes().len()),
            )?;
            let focused = r.focused.ok_or("split must report the focused pane")?;
            want(
                after.pane(TileId::new(focused)).is_some(),
                "focus must land on a pane that exists",
            )?;
            // A bare split duplicates the pane — but must not duplicate its
            // role: two panes cannot hold one role (D5).
            let detail_panes = after
                .panes()
                .into_iter()
                .filter(|t| after.pane(*t).and_then(|p| p.role.as_ref()) == Some(&Role::DETAIL))
                .count();
            want(
                detail_panes == 1,
                format!("the split copy must not carry the role too ({detail_panes} do)"),
            )?;
            want(
                !r.affected_panes.is_empty(),
                "split must report affected panes",
            )?;
            Ok(format!("{} panes, focus on {focused}", after.panes().len()))
        },
    )
    .await
}

async fn cap_move_tile() -> CapabilityResult {
    check(
        "move-tile",
        "moving the navigator to the right of the detail pane reorders the row",
        Tier::A,
        || async {
            let w = World::open()?;
            let r = w
                .service
                .move_tile(
                    APP.into(),
                    w.device(),
                    role_ref("navigator"),
                    role_ref("detail"),
                    "right".into(),
                    None,
                )
                .await;
            want(r.ok, r.message.clone())?;
            let roles = roles_in_order(&w.persisted()?)?;
            want(
                roles == vec!["list", "detail", "navigator"],
                format!("expected list | detail | navigator, got {roles:?}"),
            )?;
            Ok(format!("{roles:?}"))
        },
    )
    .await
}

async fn cap_close() -> CapabilityResult {
    check(
        "close",
        "closing the navigator leaves two panes and no navigator role",
        Tier::A,
        || async {
            let w = World::open()?;
            let r = w
                .service
                .close(APP.into(), w.device(), role_ref("navigator"), None)
                .await;
            want(r.ok, r.message.clone())?;
            let layout = w.persisted()?;
            want(
                layout.panes().len() == 2,
                format!("expected 2 panes, got {}", layout.panes().len()),
            )?;
            want(
                layout.pane_with_role(&Role::NAVIGATOR).is_none(),
                "the navigator must be gone",
            )?;
            Ok(format!("{:?}", roles_in_order(&layout)?))
        },
    )
    .await
}

async fn cap_swap() -> CapabilityResult {
    check(
        "swap",
        "swapping the list and detail panes exchanges their positions",
        Tier::A,
        || async {
            let w = World::open()?;
            let r = w
                .service
                .swap(
                    APP.into(),
                    w.device(),
                    role_ref("list"),
                    role_ref("detail"),
                    None,
                )
                .await;
            want(r.ok, r.message.clone())?;
            let roles = roles_in_order(&w.persisted()?)?;
            want(
                roles == vec!["navigator", "detail", "list"],
                format!("expected navigator | detail | list, got {roles:?}"),
            )?;
            Ok(format!("{roles:?}"))
        },
    )
    .await
}

async fn cap_resize() -> CapabilityResult {
    check(
        "resize",
        "the three-column shares can be reset to 3 : 2 : 1",
        Tier::A,
        || async {
            let w = World::open()?;
            let layout = w.layout().await?;
            let root = layout.windows.first().ok_or("no window")?.root;
            let r = w
                .service
                .resize(
                    APP.into(),
                    w.device(),
                    root.raw(),
                    vec![3.0, 2.0, 1.0],
                    None,
                )
                .await;
            want(r.ok, r.message.clone())?;
            let after = w.persisted()?;
            let shares = match after.tile(root) {
                Some(Tile::Container(container)) => {
                    container.shares().map(|s| s.to_vec()).unwrap_or_default()
                }
                _ => return Err("the root is no longer a container".to_string()),
            };
            want(
                shares == vec![3.0, 2.0, 1.0],
                format!("expected [3, 2, 1], got {shares:?}"),
            )?;
            Ok(format!("shares {shares:?}"))
        },
    )
    .await
}

async fn cap_set_container_kind() -> CapabilityResult {
    check(
        "set-container-kind",
        "the three columns can be retyped as a tab strip, children in order",
        Tier::A,
        || async {
            let w = World::open()?;
            let layout = w.layout().await?;
            let root = layout.windows.first().ok_or("no window")?.root;
            let before = leaves(&layout)?;
            let r = w
                .service
                .set_container_kind(APP.into(), w.device(), root.raw(), "tabs".into(), None)
                .await;
            want(r.ok, r.message.clone())?;
            let after = w.persisted()?;
            let is_tabs = matches!(
                after.tile(root),
                Some(Tile::Container(Container::Tabs { .. }))
            );
            want(is_tabs, "the root must now be a tab strip")?;
            want(
                leaves(&after)? == before,
                "retyping must keep the children in order",
            )?;
            Ok("root is now Tabs".to_string())
        },
    )
    .await
}

async fn cap_maximize_restore() -> CapabilityResult {
    check(
        "maximize-restore",
        "maximize records a zoomed tile and restore clears it, without touching the tree",
        Tier::A,
        || async {
            let w = World::open()?;
            let before = w.layout().await?;
            let detail = w.tile_with_role("detail").await?;

            let r = w
                .service
                .maximize(APP.into(), w.device(), role_ref("detail"), None)
                .await;
            want(r.ok, r.message.clone())?;
            let zoomed = w.persisted()?;
            want(
                zoomed.windows.first().and_then(|win| win.maximized) == Some(detail),
                "maximize must record the zoomed tile on the window",
            )?;
            want(
                zoomed.tiles == before.tiles,
                "maximize must not mutate the tree — every share and session survives it",
            )?;

            let r = w.service.restore(APP.into(), w.device(), None).await;
            want(r.ok, r.message.clone())?;
            want(
                w.persisted()?
                    .windows
                    .first()
                    .and_then(|win| win.maximized)
                    .is_none(),
                "restore must clear the zoom",
            )?;
            Ok(format!("zoomed tile {detail}, then restored"))
        },
    )
    .await
}

async fn cap_detach() -> CapabilityResult {
    check(
        "detach",
        "detaching the detail pane gives it a window of its own",
        Tier::A,
        || async {
            let w = World::open()?;
            let r = w
                .service
                .detach(APP.into(), w.device(), role_ref("detail"), None)
                .await;
            want(r.ok, r.message.clone())?;
            let layout = w.persisted()?;
            want(
                layout.windows.len() == 2,
                format!("expected 2 windows, got {}", layout.windows.len()),
            )?;
            want(
                layout.panes().len() == 3,
                "detaching moves a pane; it must not lose one",
            )?;
            Ok(format!("{} windows", layout.windows.len()))
        },
    )
    .await
}

async fn cap_set_pane() -> CapabilityResult {
    check(
        "set-pane",
        "a pane's whole spec can be replaced at once",
        Tier::A,
        || async {
            let w = World::open()?;
            let spec = PaneSpec::new(
                PaneQuery {
                    kinds: vec!["figure".into()],
                    ..PaneQuery::default()
                },
                ViewKindId::PLOT,
            )
            .with_role(Role::PREVIEW)
            .with_channel(ChannelId::number(3));

            let r = w
                .service
                .set_pane(APP.into(), w.device(), role_ref("list"), spec, None)
                .await;
            want(r.ok, r.message.clone())?;
            let layout = w.persisted()?;
            let tile = layout
                .pane_with_role(&Role::PREVIEW)
                .ok_or("the replacement spec's role is missing")?;
            let pane = layout.pane(tile).ok_or("not a pane")?;
            want(
                pane.view_kind == ViewKindId::PLOT
                    && pane.query.kinds == vec!["figure".to_string()],
                format!("unexpected spec: {pane:?}"),
            )?;
            Ok("list pane is now a figure plot on channel 3".to_string())
        },
    )
    .await
}

async fn cap_set_query() -> CapabilityResult {
    check(
        "set-query",
        "a pane can be re-pointed at a different query",
        Tier::A,
        || async {
            let w = World::open()?;
            let query = PaneQuery {
                kinds: vec!["manuscript".into()],
                scope: Scope::All,
                text: Some("dark matter".into()),
                ..PaneQuery::default()
            };
            let r = w
                .service
                .set_query(APP.into(), w.device(), role_ref("list"), query, None)
                .await;
            want(r.ok, r.message.clone())?;
            let layout = w.persisted()?;
            let tile = layout.pane_with_role(&Role::LIST).ok_or("no list pane")?;
            let pane = layout.pane(tile).ok_or("not a pane")?;
            want(
                pane.query.kinds == vec!["manuscript".to_string()]
                    && pane.query.text.as_deref() == Some("dark matter"),
                format!("unexpected query: {:?}", pane.query),
            )?;
            Ok("list now shows manuscripts matching 'dark matter'".to_string())
        },
    )
    .await
}

async fn cap_set_view_kind() -> CapabilityResult {
    check(
        "set-view-kind",
        "the detail pane can be re-rendered as a PDF view",
        Tier::A,
        || async {
            let w = World::open()?;
            let r = w
                .service
                .set_view_kind(
                    APP.into(),
                    w.device(),
                    role_ref("detail"),
                    "pdf".into(),
                    None,
                )
                .await;
            want(r.ok, r.message.clone())?;
            let layout = w.persisted()?;
            let tile = layout
                .pane_with_role(&Role::DETAIL)
                .ok_or("no detail pane")?;
            want(
                layout.pane(tile).map(|p| p.view_kind.clone()) == Some(ViewKindId::PDF),
                "the detail pane should render as 'pdf'",
            )?;
            want(
                r.stack.as_deref() == Some("exploration"),
                format!(
                    "a content verb belongs on the exploration ring, not {:?}",
                    r.stack
                ),
            )?;
            Ok("detail renders 'pdf'".to_string())
        },
    )
    .await
}

async fn cap_bind_param() -> CapabilityResult {
    check(
        "bind-param",
        "the detail pane's `item` parameter can be pinned to one publication",
        Tier::A,
        || async {
            let w = World::open()?;
            let pinned = uuid::Uuid::new_v4();
            let r = w
                .service
                .bind_param(
                    APP.into(),
                    w.device(),
                    role_ref("detail"),
                    DETAIL_PARAM.into(),
                    ParamSource::Fixed { item: pinned },
                    None,
                )
                .await;
            want(r.ok, r.message.clone())?;

            let pane = w
                .service
                .get_pane(APP.into(), w.device(), role_ref("detail"))
                .await;
            want(pane.ok, pane.message.clone())?;
            want(
                pane.bindings.get(DETAIL_PARAM) == Some(&pinned.to_string()),
                format!(
                    "expected {pinned} bound to `{DETAIL_PARAM}`, got {:?}",
                    pane.bindings
                ),
            )?;
            // A pinned parameter ignores the channel entirely — that is the
            // whole point of `Fixed`.
            let query = pane.query.ok_or("no compiled query")?;
            want(
                query.single_item.as_deref() == Some(pinned.to_string().as_str()),
                format!("the compiled query should short-circuit to {pinned}"),
            )?;
            Ok(format!("`{DETAIL_PARAM}` is pinned to {pinned}"))
        },
    )
    .await
}

async fn cap_set_channel() -> CapabilityResult {
    check(
        "set-channel",
        "a pane can be moved onto another channel",
        Tier::A,
        || async {
            let w = World::open()?;
            let r = w
                .service
                .set_channel(APP.into(), w.device(), role_ref("list"), "2".into(), None)
                .await;
            want(r.ok, r.message.clone())?;
            let layout = w.persisted()?;
            let tile = layout.pane_with_role(&Role::LIST).ok_or("no list pane")?;
            want(
                layout.pane(tile).map(|p| p.channel) == Some(ChannelId::Number(2)),
                "the list pane should publish on channel 2",
            )?;
            Ok("list publishes on channel 2".to_string())
        },
    )
    .await
}

async fn cap_set_default_channel() -> CapabilityResult {
    check(
        "set-default-channel",
        "a window's `follow` channel can be re-aimed",
        Tier::A,
        || async {
            let w = World::open()?;
            let r = w
                .service
                .set_default_channel(APP.into(), w.device(), None, "4".into(), None)
                .await;
            want(r.ok, r.message.clone())?;
            let layout = w.persisted()?;
            want(
                layout.windows.first().map(|win| win.default_channel) == Some(ChannelId::Number(4)),
                "the window should now follow channel 4",
            )?;
            Ok("follow = 4".to_string())
        },
    )
    .await
}

async fn cap_set_role() -> CapabilityResult {
    check(
        "set-role",
        "a role can be moved to another pane — the chords follow it",
        Tier::A,
        || async {
            let w = World::open()?;
            let r = w
                .service
                .set_role(
                    APP.into(),
                    w.device(),
                    role_ref("navigator"),
                    Some("console".into()),
                    None,
                )
                .await;
            want(r.ok, r.message.clone())?;
            let layout = w.persisted()?;
            want(
                layout.pane_with_role(&Role::CONSOLE).is_some(),
                "the console role should now exist",
            )?;
            want(
                layout.pane_with_role(&Role::NAVIGATOR).is_none(),
                "and the navigator role should have moved, not been copied",
            )?;
            want(
                r.stack.as_deref() == Some("arrangement"),
                format!(
                    "where a role lives is arrangement, not exploration: {:?}",
                    r.stack
                ),
            )?;
            Ok("navigator → console".to_string())
        },
    )
    .await
}

async fn cap_focus() -> CapabilityResult {
    check(
        "focus",
        "focus is a value in the layout, so an agent can set and read it",
        Tier::A,
        || async {
            let w = World::open()?;
            let navigator = w.tile_with_role("navigator").await?;
            let r = w
                .service
                .focus(APP.into(), w.device(), role_ref("navigator"), None)
                .await;
            want(r.ok, r.message.clone())?;
            want(
                r.focused == Some(navigator.raw()),
                format!("expected focus on {navigator}, got {:?}", r.focused),
            )?;
            want(
                r.stack.as_deref() == Some("none"),
                "focus records nothing: undoing a focus move is what the opposite move is for",
            )?;
            Ok(format!("focus on {navigator}"))
        },
    )
    .await
}

async fn cap_focus_direction() -> CapabilityResult {
    check(
        "focus-direction",
        "h / l walks the tree: right of the navigator is the list",
        Tier::A,
        || async {
            let w = World::open()?;
            w.service
                .focus(APP.into(), w.device(), role_ref("navigator"), None)
                .await;
            let list = w.tile_with_role("list").await?;
            let r = w
                .service
                .focus_direction(APP.into(), w.device(), "right".into(), None)
                .await;
            want(r.ok, r.message.clone())?;
            want(
                r.focused == Some(list.raw()),
                format!("expected focus on the list ({list}), got {:?}", r.focused),
            )?;
            Ok(format!("navigator → right → {list}"))
        },
    )
    .await
}

async fn cap_select() -> CapabilityResult {
    check(
        "select",
        "selecting in the list publishes on channel 1 and names the detail pane as affected",
        Tier::A,
        || async {
            let w = World::open()?;
            let detail = w.tile_with_role("detail").await?;
            let chosen = uuid::Uuid::new_v4();
            let r = w
                .service
                .select(
                    APP.into(),
                    w.device(),
                    role_ref("list"),
                    "publication".into(),
                    vec![chosen.to_string()],
                    Some("human".into()),
                )
                .await;
            want(r.ok, r.message.clone())?;
            want(
                r.affected_panes.contains(&detail.raw()),
                format!(
                    "the detail pane binds `item` on channel 1 and must be reported affected; \
                     got {:?}",
                    r.affected_panes
                ),
            )?;
            let persisted = w.persisted()?;
            want(
                persisted.channels.current(1, "publication") == Some(chosen),
                "channel 1 should carry the selection",
            )?;
            Ok(format!("channel 1 carries {chosen}"))
        },
    )
    .await
}

async fn cap_set_window_geometry() -> CapabilityResult {
    check(
        "set-window-geometry",
        "a window's frame is stored on the layout and can be cleared",
        Tier::A,
        || async {
            let w = World::open()?;
            let geometry = Geometry {
                x: 12.0,
                y: 34.0,
                w: 1440.0,
                h: 900.0,
                display: Some("built-in".into()),
            };
            let r = w
                .service
                .set_window_geometry(APP.into(), w.device(), None, Some(geometry), None)
                .await;
            want(r.ok, r.message.clone())?;
            let stored = w
                .persisted()?
                .windows
                .first()
                .and_then(|win| win.geometry.clone())
                .ok_or("the frame was not stored")?;
            want(stored.w == 1440.0, format!("unexpected frame {stored:?}"))?;

            let r = w
                .service
                .set_window_geometry(APP.into(), w.device(), None, None, None)
                .await;
            want(r.ok, r.message.clone())?;
            want(
                w.persisted()?
                    .windows
                    .first()
                    .and_then(|win| win.geometry.clone())
                    .is_none(),
                "passing null must clear the frame",
            )?;
            Ok("frame set, then cleared".to_string())
        },
    )
    .await
}

async fn cap_save_and_apply_layout() -> CapabilityResult {
    check(
        "save-and-apply-layout",
        "an arrangement saved by name comes back by name, without its window frame",
        Tier::A,
        || async {
            let w = World::open()?;
            w.service
                .set_window_geometry(
                    APP.into(),
                    w.device(),
                    None,
                    Some(Geometry {
                        x: 0.0,
                        y: 0.0,
                        w: 2560.0,
                        h: 1440.0,
                        display: None,
                    }),
                    None,
                )
                .await;
            let saved = w
                .service
                .save_layout(
                    APP.into(),
                    w.device(),
                    "Triage".into(),
                    Some("sorting the inbox".into()),
                    Some("human".into()),
                )
                .await;
            want(saved.ok, saved.message.clone())?;

            // Wreck the arrangement …
            w.service
                .close(APP.into(), w.device(), role_ref("navigator"), None)
                .await;
            want(
                w.persisted()?.panes().len() == 2,
                "the close should have landed",
            )?;

            // … and recall it.
            let applied = w
                .service
                .apply_layout(
                    APP.into(),
                    w.device(),
                    Some("Triage".into()),
                    None,
                    Some("human".into()),
                )
                .await;
            want(applied.ok, applied.message.clone())?;
            let layout = w.persisted()?;
            want(
                layout.panes().len() == 3,
                format!(
                    "expected the three columns back, got {}",
                    layout.panes().len()
                ),
            )?;
            want(
                layout
                    .windows
                    .first()
                    .and_then(|win| win.geometry.clone())
                    .is_none(),
                "a travelled layout must arrive WITHOUT its window frame (ADR-0019 D2)",
            )?;
            want(
                !applied.affected_panes.is_empty(),
                "applying a whole layout must ask the renderer to redraw every pane",
            )?;
            Ok(format!("recalled 'Triage': {:?}", roles_in_order(&layout)?))
        },
    )
    .await
}

async fn cap_apply_layout_by_ordinal() -> CapabilityResult {
    check(
        "apply-layout-by-ordinal",
        "⌃⌘2 recalls the second saved layout",
        Tier::A,
        || async {
            let w = World::open()?;
            // Layout 1: the three columns as they are.
            let first = w
                .service
                .save_layout(APP.into(), w.device(), "Alpha".into(), None, None)
                .await;
            want(first.ok, first.message.clone())?;

            // Layout 2: two panes.
            w.service
                .close(APP.into(), w.device(), role_ref("navigator"), None)
                .await;
            let second = w
                .service
                .save_layout(APP.into(), w.device(), "Beta".into(), None, None)
                .await;
            want(second.ok, second.message.clone())?;

            // Back to three, then recall #2 by ordinal.
            w.service
                .apply_layout(APP.into(), w.device(), Some("Alpha".into()), None, None)
                .await;
            want(
                w.persisted()?.panes().len() == 3,
                "Alpha should restore three panes",
            )?;

            let r = w
                .service
                .apply_layout(APP.into(), w.device(), None, Some(2), None)
                .await;
            want(r.ok, r.message.clone())?;
            want(
                r.message.contains("Beta"),
                format!("ordinal 2 should be 'Beta': {}", r.message),
            )?;
            want(
                w.persisted()?.panes().len() == 2,
                "Beta is the two-pane arrangement",
            )?;
            Ok("ordinal 2 → 'Beta'".to_string())
        },
    )
    .await
}

async fn cap_commit() -> CapabilityResult {
    check(
        "commit",
        "commit materializes the arrangement as a durable layout, and refuses the kinds that do not exist yet",
        Tier::A,
        || async {
            let w = World::open()?;
            let r = w
                .service
                .commit(
                    APP.into(),
                    w.device(),
                    "layout".into(),
                    "Reading".into(),
                    Some("two-up reading".into()),
                    Some("human".into()),
                )
                .await;
            want(r.ok, r.message.clone())?;
            let named = w.layouts().list_named(APP)?;
            want(
                named.iter().any(|row| row.name.as_deref() == Some("Reading")),
                format!("'Reading' is missing from {named:?}"),
            )?;
            want(
                named
                    .iter()
                    .any(|row| row.purpose.as_deref() == Some("two-up reading")),
                "the purpose the user typed must be stored",
            )?;

            let refused = w
                .service
                .commit(
                    APP.into(),
                    w.device(),
                    "figure".into(),
                    "Figure 1".into(),
                    None,
                    None,
                )
                .await;
            want(
                !refused.ok && refused.message.contains("figure"),
                format!("committing a figure should be refused, not approximated: {refused:?}"),
            )?;
            Ok("committed 'Reading'; 'figure' refused".to_string())
        },
    )
    .await
}

async fn cap_undo_redo_arrangement() -> CapabilityResult {
    check(
        "undo-redo-arrangement",
        "the arrangement ring reverts a split and re-applies it",
        Tier::A,
        || async {
            let w = World::open()?;
            let before = w.layout().await?.panes().len();
            w.service
                .split(
                    APP.into(),
                    w.device(),
                    role_ref("list"),
                    "horizontal".into(),
                    true,
                    None,
                    None,
                )
                .await;
            want(
                w.persisted()?.panes().len() == before + 1,
                "the split should have landed",
            )?;

            let undone = w
                .service
                .undo(
                    APP.into(),
                    w.device(),
                    "arrangement".into(),
                    PaneRefDto::focused(),
                    None,
                )
                .await;
            want(undone.ok, undone.message.clone())?;
            want(
                w.persisted()?.panes().len() == before,
                "undo must revert the split — and persist the reverted tree",
            )?;

            let redone = w
                .service
                .redo(
                    APP.into(),
                    w.device(),
                    "arrangement".into(),
                    PaneRefDto::focused(),
                    None,
                )
                .await;
            want(redone.ok, redone.message.clone())?;
            want(
                w.persisted()?.panes().len() == before + 1,
                "redo must re-apply it",
            )?;
            Ok(format!(
                "{before} → {} → {before} → {}",
                before + 1,
                before + 1
            ))
        },
    )
    .await
}

async fn cap_undo_redo_exploration() -> CapabilityResult {
    check(
        "undo-redo-exploration",
        "one pane's exploration ring is its own: undoing in the detail pane leaves the list alone",
        Tier::A,
        || async {
            let w = World::open()?;
            // Explore in BOTH panes, then undo only in the detail pane.
            w.service
                .set_view_kind(
                    APP.into(),
                    w.device(),
                    role_ref("list"),
                    "outline".into(),
                    None,
                )
                .await;
            w.service
                .set_view_kind(
                    APP.into(),
                    w.device(),
                    role_ref("detail"),
                    "pdf".into(),
                    None,
                )
                .await;

            let undone = w
                .service
                .undo(
                    APP.into(),
                    w.device(),
                    "exploration".into(),
                    role_ref("detail"),
                    None,
                )
                .await;
            want(undone.ok, undone.message.clone())?;

            let layout = w.persisted()?;
            let detail = layout
                .pane_with_role(&Role::DETAIL)
                .ok_or("no detail pane")?;
            let list = layout.pane_with_role(&Role::LIST).ok_or("no list pane")?;
            want(
                layout.pane(detail).map(|p| p.view_kind.clone()) == Some(ViewKindId::INFO),
                "the detail pane should be back to 'info'",
            )?;
            want(
                layout.pane(list).map(|p| p.view_kind.clone()) == Some(ViewKindId::OUTLINE),
                "exploring in one pane must not undo exploring in another",
            )?;

            let redone = w
                .service
                .redo(
                    APP.into(),
                    w.device(),
                    "exploration".into(),
                    role_ref("detail"),
                    None,
                )
                .await;
            want(redone.ok, redone.message.clone())?;
            let layout = w.persisted()?;
            let detail = layout
                .pane_with_role(&Role::DETAIL)
                .ok_or("no detail pane")?;
            want(
                layout.pane(detail).map(|p| p.view_kind.clone()) == Some(ViewKindId::PDF),
                "redo must restore 'pdf'",
            )?;
            Ok("detail: pdf → info → pdf; list untouched".to_string())
        },
    )
    .await
}

async fn cap_get_layout() -> CapabilityResult {
    check(
        "get-layout",
        "the whole tree reads back with its focus, its row id and its device",
        Tier::A,
        || async {
            let w = World::open()?;
            let r = w.service.get_layout(APP.into(), w.device()).await;
            want(r.ok, r.message.clone())?;
            want(r.focused.is_some(), "a window has a focused leaf")?;
            want(
                r.device.as_deref() == Some(DEVICE),
                format!("expected the device echoed back, got {:?}", r.device),
            )?;
            want(
                r.item_id.is_some(),
                "the row id is what the projection subscribes to",
            )?;
            want(
                r.affected_panes.len() == 3,
                "a full read asks for every pane to be drawn",
            )?;
            Ok(r.message)
        },
    )
    .await
}

async fn cap_get_pane_compiles_the_detail_query() -> CapabilityResult {
    check(
        "get-pane-compiles-the-detail-query",
        "with the list's selection published, the detail pane's query compiles to that one item",
        Tier::A,
        || async {
            let w = World::open()?;

            // Nothing selected yet: the required parameter is unbound, and
            // that is a TYPED refusal, not an empty result that reads as "no
            // data yet".
            let empty = w
                .service
                .get_pane(APP.into(), w.device(), role_ref("detail"))
                .await;
            want(empty.ok, empty.message.clone())?;
            let refused = empty.query.ok_or("no compiled query")?;
            want(
                refused.error.is_some(),
                "an unbound required parameter must compile to an error, not to everything",
            )?;

            // Select in the list — the chain sidebar → list → detail is just
            // three panes on one channel.
            let chosen = uuid::Uuid::new_v4();
            let selected = w
                .service
                .select(
                    APP.into(),
                    w.device(),
                    role_ref("list"),
                    "publication".into(),
                    vec![chosen.to_string()],
                    None,
                )
                .await;
            want(selected.ok, selected.message.clone())?;

            let pane = w
                .service
                .get_pane(APP.into(), w.device(), role_ref("detail"))
                .await;
            want(pane.ok, pane.message.clone())?;
            want(
                pane.bindings.get(DETAIL_PARAM) == Some(&chosen.to_string()),
                format!(
                    "`{DETAIL_PARAM}` should be bound to {chosen}, got {:?}",
                    pane.bindings
                ),
            )?;
            let compiled = pane.query.ok_or("no compiled query")?;
            want(
                compiled.error.is_none(),
                format!("the detail query should compile now: {:?}", compiled.error),
            )?;
            want(
                compiled.single_item.as_deref() == Some(chosen.to_string().as_str()),
                format!("expected a single-item query for {chosen}, got {compiled:?}"),
            )?;
            want(
                compiled
                    .schema_refs
                    .iter()
                    .any(|r| r == "imbib/bibliography-entry"),
                format!(
                    "the compiled query must name the CANONICAL publication ref; got {:?}",
                    compiled.schema_refs
                ),
            )?;
            Ok(format!(
                "detail compiles to item({chosen}) over {:?}",
                compiled.schema_refs
            ))
        },
    )
    .await
}

async fn cap_get_channel() -> CapabilityResult {
    check(
        "get-channel",
        "a channel reports what it carries per record kind, and which panes it drives",
        Tier::A,
        || async {
            let w = World::open()?;
            let chosen = uuid::Uuid::new_v4();
            w.service
                .select(
                    APP.into(),
                    w.device(),
                    role_ref("list"),
                    "publication".into(),
                    vec![chosen.to_string()],
                    None,
                )
                .await;
            let r = w
                .service
                .get_channel(APP.into(), w.device(), "1".into(), None)
                .await;
            want(r.ok, r.message.clone())?;
            want(
                r.channel == 1,
                format!("expected channel 1, got {}", r.channel),
            )?;
            want(
                r.selections.get("publication") == Some(&vec![chosen.to_string()]),
                format!("expected the publication selection, got {:?}", r.selections),
            )?;
            want(
                !r.affected_panes.is_empty(),
                "channel 1 drives the detail pane's `item` parameter",
            )?;

            // `follow` resolves against the window default rather than being a
            // channel of its own.
            let followed = w
                .service
                .get_channel(APP.into(), w.device(), "follow".into(), None)
                .await;
            want(
                followed.ok && followed.channel == 1,
                format!("'follow' should resolve to 1 here, got {followed:?}"),
            )?;
            Ok(format!("channel 1: {:?}", r.selections))
        },
    )
    .await
}

async fn cap_resolve_reference() -> CapabilityResult {
    check(
        "resolve-reference",
        "a reference resolves by role and by direction without touching anything",
        Tier::A,
        || async {
            let w = World::open()?;
            let detail = w.tile_with_role("detail").await?;
            let by_role = w
                .service
                .resolve_reference(APP.into(), w.device(), role_ref("detail"))
                .await;
            want(by_role.ok, by_role.message.clone())?;
            want(
                by_role.tile == Some(detail.raw()) && by_role.is_pane,
                format!("expected tile {detail}, got {by_role:?}"),
            )?;
            want(
                by_role.view_kind.as_deref() == Some("info"),
                format!("expected the detail view kind, got {:?}", by_role.view_kind),
            )?;

            // Focus starts on the list, so "right" is the detail pane.
            let by_direction = w
                .service
                .resolve_reference(APP.into(), w.device(), PaneRefDto::direction("right"))
                .await;
            want(by_direction.ok, by_direction.message.clone())?;
            want(
                by_direction.tile == Some(detail.raw()),
                format!("right of the list should be the detail pane, got {by_direction:?}"),
            )?;
            Ok(format!(
                "role 'detail' and direction 'right' are both tile {detail}"
            ))
        },
    )
    .await
}

async fn cap_list_layouts() -> CapabilityResult {
    check(
        "list-layouts",
        "saved layouts are listed in ⌃⌘1–9 order, and the live row is not one of them",
        Tier::A,
        || async {
            let w = World::open()?;
            w.service
                .save_layout(APP.into(), w.device(), "Alpha".into(), None, None)
                .await;
            w.service
                .save_layout(APP.into(), w.device(), "Beta".into(), None, None)
                .await;
            let r = w.service.list_layouts(APP.into()).await;
            want(r.ok, r.message.clone())?;
            let names: Vec<String> = r
                .layouts
                .iter()
                .map(|l| l.name.clone().unwrap_or_default())
                .collect();
            want(
                names == vec!["Alpha".to_string(), "Beta".to_string()],
                format!("expected [Alpha, Beta], got {names:?}"),
            )?;
            want(
                r.layouts.iter().map(|l| l.ordinal).collect::<Vec<_>>() == vec![1, 2],
                "ordinals are 1-based and dense",
            )?;
            want(
                r.layouts.iter().all(|l| !l.is_live),
                "the live arrangement is not a saved layout",
            )?;
            Ok(format!("{names:?}"))
        },
    )
    .await
}

async fn cap_one_live_row_per_scope() -> CapabilityResult {
    check(
        "one-live-row-per-scope",
        "a hundred gestures leave ONE live row — the invariant `is_live` exists to make visible",
        Tier::A,
        || async {
            let w = World::open()?;
            for _ in 0..10 {
                w.service
                    .focus_direction(APP.into(), w.device(), "next".into(), None)
                    .await;
                w.service
                    .select(
                        APP.into(),
                        w.device(),
                        role_ref("list"),
                        "publication".into(),
                        vec![uuid::Uuid::new_v4().to_string()],
                        None,
                    )
                    .await;
            }
            w.service
                .save_layout(APP.into(), w.device(), "Saved".into(), None, None)
                .await;

            let rows = w.rows()?;
            let live: Vec<&LayoutRow> = rows.iter().filter(|r| r.is_live).collect();
            want(
                live.len() == 1,
                format!(
                    "expected exactly one live row, got {}: {live:?}",
                    live.len()
                ),
            )?;
            want(
                rows.len() == 2,
                format!("expected the live row plus one saved layout, got {rows:?}"),
            )?;

            // A second device is a SECOND scope, not a second live row in the
            // first one.
            w.service
                .get_layout(APP.into(), Some("another-device".into()))
                .await;
            let rows = w.rows()?;
            want(
                rows.iter().filter(|r| r.is_live).count() == 2,
                "each device gets its own live row",
            )?;
            want(
                rows.iter()
                    .filter(|r| r.is_live && r.device.as_deref() == Some(DEVICE))
                    .count()
                    == 1,
                "…and this device still has exactly one",
            )?;
            Ok("1 live row here, 1 on the other device".to_string())
        },
    )
    .await
}

async fn cap_misspelled_reference_is_refused() -> CapabilityResult {
    check(
        "misspelled-reference-is-refused",
        "a reference that names nothing is a typed refusal, not a silent no-op",
        Tier::A,
        || async {
            let w = World::open()?;
            // Cold-start first: the assertion is that a REFUSED verb changes
            // nothing, which needs something to be unchanged.
            w.layout().await?;
            let before = w.persisted()?;

            let by_role = w
                .service
                .close(APP.into(), w.device(), role_ref("detial"), None)
                .await;
            want(
                !by_role.ok,
                "a misspelled role must fail loudly — a silent no-op here is a pane that \
                 mysteriously did not close",
            )?;
            want(
                by_role.message.contains("detial"),
                format!(
                    "the refusal should name what it could not find: {}",
                    by_role.message
                ),
            )?;

            let by_id = w
                .service
                .close(
                    APP.into(),
                    w.device(),
                    PaneRefDto::tile(TileId::new(9999)),
                    None,
                )
                .await;
            want(!by_id.ok, "an unknown tile id must fail too")?;

            want(
                w.persisted()? == before,
                "a refused verb must leave the tree byte-identical",
            )?;
            Ok("both refusals named their reference and changed nothing".to_string())
        },
    )
    .await
}
