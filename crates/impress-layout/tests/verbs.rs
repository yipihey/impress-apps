//! One test per ADR-0031 D8 verb, plus the reference-resolution rules.

mod common;

use common::{assert_arena_is_sound, assert_focus_is_a_leaf, scratch_pane, three_column};
use impress_layout::preset::DETAIL_PARAM;
use impress_layout::{
    ChannelId, Container, ContainerKind, Direction, Geometry, Layout, LayoutError, PaneQuery,
    PaneRef, PaneSpec, ParamSource, Placement, Role, Verb, ViewKindId,
};
use uuid::Uuid;

fn window_of(layout: &Layout) -> impress_layout::WindowId {
    layout.current_window().unwrap()
}

// ------------------------------------------------------------- arrangement

#[test]
fn split_inserts_beside_the_target_and_focuses_the_new_pane() {
    let (mut layout, parts) = three_column();
    let before = layout.leaves(parts.window).len();

    layout
        .apply(Verb::Split {
            target: PaneRef::role(Role::DETAIL),
            dir: impress_layout::LinearDir::Vertical,
            after: true,
            new: scratch_pane(),
        })
        .unwrap();

    let leaves = layout.leaves(parts.window);
    assert_eq!(leaves.len(), before + 1);
    let focused = layout.window(parts.window).unwrap().focused.unwrap();
    assert_eq!(
        layout.pane(focused).unwrap().view_kind,
        ViewKindId::PDF,
        "focus must follow the new pane"
    );
    // The new pane is below the detail pane, not beside the whole row.
    assert_eq!(
        layout.step(parts.window, parts.detail, Direction::Down),
        focused
    );
    assert_focus_is_a_leaf(&layout);
    assert_arena_is_sound(&layout);
}

#[test]
fn split_along_the_parents_direction_extends_it_rather_than_nesting() {
    let (mut layout, parts) = three_column();
    layout
        .apply(Verb::Split {
            target: PaneRef::id(parts.list),
            dir: impress_layout::LinearDir::Horizontal,
            after: true,
            new: scratch_pane(),
        })
        .unwrap();
    let root = layout.tile(parts.root).unwrap().as_container().unwrap();
    assert_eq!(root.len(), 4, "the row grew; it did not nest");
    let shares = root.shares().unwrap();
    assert!((shares[1] - 1.0).abs() < 1e-6, "the list's 2.0 was halved");
    assert!(
        (shares[2] - 1.0).abs() < 1e-6,
        "the newcomer took the other half"
    );
}

#[test]
fn move_tile_into_tabs_stacks_the_panes() {
    let (mut layout, parts) = three_column();
    layout
        .apply(Verb::MoveTile {
            tile: PaneRef::id(parts.navigator),
            target: PaneRef::id(parts.detail),
            placement: Placement::IntoTabs,
        })
        .unwrap();

    let parent = layout.parent_of(parts.navigator).unwrap();
    let container = layout.tile(parent).unwrap().as_container().unwrap();
    assert_eq!(container.kind(), ContainerKind::Tabs);
    assert!(matches!(
        container,
        Container::Tabs { active, .. } if *active == Some(parts.navigator)
    ));
    assert_eq!(layout.leaves(parts.window).len(), 3);
    assert_arena_is_sound(&layout);
}

#[test]
fn move_tile_refuses_to_move_a_tile_into_its_own_subtree() {
    let (mut layout, parts) = three_column();
    let err = layout
        .apply(Verb::MoveTile {
            tile: PaneRef::id(parts.root),
            target: PaneRef::id(parts.list),
            placement: Placement::Right,
        })
        .unwrap_err();
    assert_eq!(err, LayoutError::CyclicMove { tile: parts.root });
}

#[test]
fn close_removes_the_pane_and_focuses_the_neighbour() {
    let (mut layout, parts) = three_column();
    layout
        .apply(Verb::Close {
            target: PaneRef::role(Role::LIST),
        })
        .unwrap();

    assert!(layout.pane(parts.list).is_none());
    assert!(layout.pane_with_role(&Role::LIST).is_none());
    assert_eq!(
        layout.window(parts.window).unwrap().focused,
        Some(parts.detail),
        "focus moves to the next surviving pane"
    );
    assert_focus_is_a_leaf(&layout);
    assert_arena_is_sound(&layout);
}

#[test]
fn close_refuses_the_last_pane_of_a_window() {
    let mut layout = Layout::new_single_pane(scratch_pane());
    let err = layout
        .apply(Verb::Close {
            target: PaneRef::Focused,
        })
        .unwrap_err();
    assert_eq!(err, LayoutError::CannotCloseLastPane);
    assert_eq!(layout.panes().len(), 1, "the refusal changed nothing");
}

#[test]
fn close_refuses_a_subtree_holding_every_pane() {
    let (mut layout, parts) = three_column();
    let err = layout
        .apply(Verb::Close {
            target: PaneRef::id(parts.root),
        })
        .unwrap_err();
    assert_eq!(err, LayoutError::CannotCloseLastPane);
}

#[test]
fn swap_exchanges_two_panes_keeping_each_slots_share() {
    let (mut layout, parts) = three_column();
    layout
        .apply(Verb::Swap {
            a: PaneRef::id(parts.navigator),
            b: PaneRef::id(parts.detail),
        })
        .unwrap();
    let root = layout.tile(parts.root).unwrap().as_container().unwrap();
    assert_eq!(root.children(), [parts.detail, parts.list, parts.navigator]);
    assert_eq!(
        root.shares().unwrap(),
        [1.0, 2.0, 3.0],
        "shares belong to slots"
    );
}

#[test]
fn resize_sets_the_shares_and_rejects_the_wrong_number_of_them() {
    let (mut layout, parts) = three_column();
    layout
        .apply(Verb::Resize {
            container: parts.root,
            shares: vec![2.0, 3.0, 5.0],
        })
        .unwrap();
    let root = layout.tile(parts.root).unwrap().as_container().unwrap();
    assert_eq!(root.shares().unwrap(), [2.0, 3.0, 5.0]);

    let err = layout
        .apply(Verb::Resize {
            container: parts.root,
            shares: vec![1.0, 1.0],
        })
        .unwrap_err();
    assert!(matches!(err, LayoutError::InvalidShares { .. }));

    let err = layout
        .apply(Verb::Resize {
            container: parts.root,
            shares: vec![1.0, 0.0, 1.0],
        })
        .unwrap_err();
    assert!(matches!(err, LayoutError::InvalidShares { .. }));

    let err = layout
        .apply(Verb::Resize {
            container: parts.list,
            shares: vec![1.0],
        })
        .unwrap_err();
    assert_eq!(err, LayoutError::NotAContainer { tile: parts.list });
}

#[test]
fn set_container_kind_retypes_in_place() {
    let (mut layout, parts) = three_column();
    layout
        .apply(Verb::SetContainerKind {
            container: parts.root,
            kind: ContainerKind::Vertical,
        })
        .unwrap();
    let root = layout.tile(parts.root).unwrap().as_container().unwrap();
    assert_eq!(root.kind(), ContainerKind::Vertical);
    assert_eq!(
        root.shares().unwrap(),
        [1.0, 2.0, 3.0],
        "rotating keeps shares"
    );
    assert_eq!(root.children(), [parts.navigator, parts.list, parts.detail]);

    layout
        .apply(Verb::SetContainerKind {
            container: parts.root,
            kind: ContainerKind::Tabs,
        })
        .unwrap();
    let root = layout.tile(parts.root).unwrap().as_container().unwrap();
    assert_eq!(root.kind(), ContainerKind::Tabs);
    assert_focus_is_a_leaf(&layout);
}

#[test]
fn maximize_and_restore_do_not_touch_the_tree() {
    let (mut layout, parts) = three_column();
    let tiles_before = layout.tiles.clone();

    layout
        .apply(Verb::Maximize {
            target: PaneRef::role(Role::DETAIL),
        })
        .unwrap();
    assert_eq!(
        layout.window(parts.window).unwrap().maximized,
        Some(parts.detail)
    );
    assert_eq!(
        layout.window(parts.window).unwrap().focused,
        Some(parts.detail),
        "maximizing focuses what it shows"
    );
    assert_eq!(
        layout.tiles, tiles_before,
        "zoom is window state, not a mutation"
    );

    layout.apply(Verb::Restore).unwrap();
    assert_eq!(layout.window(parts.window).unwrap().maximized, None);
    assert_eq!(layout.tiles, tiles_before);
}

#[test]
fn restore_with_nothing_maximized_is_an_empty_patch() {
    let (mut layout, _) = three_column();
    let patch = layout.apply(Verb::Restore).unwrap();
    assert!(patch.is_empty());
}

// ----------------------------------------------------------------- content

#[test]
fn set_pane_replaces_the_whole_spec_and_refuses_a_container() {
    let (mut layout, parts) = three_column();
    let replacement = PaneSpec::new(PaneQuery::default(), ViewKindId::PLOT);
    layout
        .apply(Verb::SetPane {
            target: PaneRef::id(parts.detail),
            spec: replacement.clone(),
        })
        .unwrap();
    assert_eq!(layout.pane(parts.detail).unwrap(), &replacement);

    let err = layout
        .apply(Verb::SetPane {
            target: PaneRef::id(parts.root),
            spec: replacement,
        })
        .unwrap_err();
    assert_eq!(err, LayoutError::NotAPane { tile: parts.root });
}

#[test]
fn set_query_and_set_view_kind_patch_the_spec() {
    let (mut layout, parts) = three_column();
    let query = PaneQuery {
        kinds: vec!["manuscript".to_string()],
        text: Some("dark matter".to_string()),
        ..PaneQuery::default()
    };
    layout
        .apply(Verb::SetQuery {
            target: PaneRef::role(Role::LIST),
            query: query.clone(),
        })
        .unwrap();
    assert_eq!(layout.pane(parts.list).unwrap().query, query);

    layout
        .apply(Verb::SetViewKind {
            target: PaneRef::role(Role::LIST),
            view_kind: ViewKindId::PLOT,
        })
        .unwrap();
    assert_eq!(layout.pane(parts.list).unwrap().view_kind, ViewKindId::PLOT);
}

#[test]
fn bind_param_repoints_a_declared_parameter_and_rejects_an_undeclared_one() {
    let (mut layout, parts) = three_column();
    let pinned = Uuid::from_u128(42);
    layout
        .apply(Verb::BindParam {
            target: PaneRef::role(Role::DETAIL),
            name: DETAIL_PARAM.to_string(),
            source: ParamSource::Fixed { item: pinned },
        })
        .unwrap();
    assert_eq!(
        layout
            .pane(parts.detail)
            .unwrap()
            .param(DETAIL_PARAM)
            .unwrap()
            .source,
        ParamSource::Fixed { item: pinned }
    );
    assert_eq!(
        layout.bindings_for(parts.detail).get(DETAIL_PARAM),
        Some(pinned)
    );

    let err = layout
        .apply(Verb::BindParam {
            target: PaneRef::role(Role::DETAIL),
            name: "colormap".to_string(),
            source: ParamSource::Default,
        })
        .unwrap_err();
    assert_eq!(
        err,
        LayoutError::UnknownParam {
            tile: parts.detail,
            name: "colormap".to_string()
        }
    );
}

#[test]
fn set_channel_changes_where_a_pane_publishes() {
    let (mut layout, parts) = three_column();
    layout
        .apply(Verb::SetChannel {
            target: PaneRef::role(Role::LIST),
            channel: ChannelId::number(3),
        })
        .unwrap();
    layout
        .apply(Verb::Select {
            target: PaneRef::role(Role::LIST),
            kind: "publication".to_string(),
            ids: vec![Uuid::from_u128(7)],
        })
        .unwrap();
    assert_eq!(
        layout.channels.current(3, "publication"),
        Some(Uuid::from_u128(7))
    );
    assert_eq!(layout.channels.current(1, "publication"), None);
    // The detail pane still follows channel 1, so it is unaffected.
    assert_eq!(layout.bindings_for(parts.detail).get(DETAIL_PARAM), None);
}

#[test]
fn set_role_moves_the_role_off_whichever_pane_held_it() {
    let (mut layout, parts) = three_column();
    layout
        .apply(Verb::SetRole {
            target: PaneRef::id(parts.navigator),
            role: Some(Role::DETAIL),
        })
        .unwrap();
    assert_eq!(
        layout.pane(parts.navigator).unwrap().role,
        Some(Role::DETAIL)
    );
    assert_eq!(
        layout.pane(parts.detail).unwrap().role,
        None,
        "a role is unique per window, or ⌘0 would be a coin toss"
    );
    assert_eq!(
        layout
            .resolve(parts.window, &PaneRef::role(Role::DETAIL))
            .unwrap(),
        parts.navigator
    );

    layout
        .apply(Verb::SetRole {
            target: PaneRef::id(parts.navigator),
            role: None,
        })
        .unwrap();
    assert!(layout.pane_with_role(&Role::DETAIL).is_none());
    let err = layout
        .resolve(parts.window, &PaneRef::role(Role::DETAIL))
        .unwrap_err();
    assert_eq!(err, LayoutError::NoPaneWithRole { role: Role::DETAIL });
}

// -------------------------------------------------------- focus / selection

#[test]
fn focus_and_focus_direction_walk_the_leaves() {
    let (mut layout, parts) = three_column();
    layout
        .apply(Verb::Focus {
            target: PaneRef::role(Role::NAVIGATOR),
        })
        .unwrap();
    assert_eq!(
        layout.window(parts.window).unwrap().focused,
        Some(parts.navigator)
    );

    layout
        .apply(Verb::FocusDirection {
            direction: Direction::Right,
        })
        .unwrap();
    assert_eq!(
        layout.window(parts.window).unwrap().focused,
        Some(parts.list)
    );

    layout
        .apply(Verb::FocusDirection {
            direction: Direction::Left,
        })
        .unwrap();
    assert_eq!(
        layout.window(parts.window).unwrap().focused,
        Some(parts.navigator)
    );

    // At the edge, h stays put rather than failing.
    layout
        .apply(Verb::FocusDirection {
            direction: Direction::Left,
        })
        .unwrap();
    assert_eq!(
        layout.window(parts.window).unwrap().focused,
        Some(parts.navigator)
    );

    // Next wraps, as PaneFocusCycler does.
    layout
        .apply(Verb::Focus {
            target: PaneRef::role(Role::DETAIL),
        })
        .unwrap();
    layout
        .apply(Verb::FocusDirection {
            direction: Direction::Next,
        })
        .unwrap();
    assert_eq!(
        layout.window(parts.window).unwrap().focused,
        Some(parts.navigator)
    );
}

#[test]
fn focusing_a_container_focuses_the_pane_it_shows() {
    let (mut layout, parts) = three_column();
    layout
        .apply(Verb::Focus {
            target: PaneRef::id(parts.root),
        })
        .unwrap();
    assert_eq!(
        layout.window(parts.window).unwrap().focused,
        Some(parts.navigator)
    );
    assert_focus_is_a_leaf(&layout);
}

#[test]
fn select_publishes_on_the_panes_channel_and_drives_exactly_the_bound_panes() {
    let (mut layout, parts) = three_column();
    let chosen = Uuid::from_u128(1234);

    layout
        .apply(Verb::Select {
            target: PaneRef::role(Role::LIST),
            kind: "publication".to_string(),
            ids: vec![chosen, Uuid::from_u128(5678)],
        })
        .unwrap();

    assert_eq!(
        layout.channels.selection(1, "publication"),
        [chosen, Uuid::from_u128(5678)]
    );
    assert_eq!(
        layout.affected_panes(ChannelId::ONE, "publication"),
        vec![parts.detail],
        "only the detail pane binds a publication on channel 1"
    );
    assert_eq!(
        layout.bindings_for(parts.detail).get(DETAIL_PARAM),
        Some(chosen),
        "a single-valued parameter takes the first id of the selection"
    );
    // A selection of another kind on the same channel leaves it alone.
    layout
        .apply(Verb::Select {
            target: PaneRef::role(Role::LIST),
            kind: "manuscript".to_string(),
            ids: vec![Uuid::from_u128(9)],
        })
        .unwrap();
    assert_eq!(
        layout.bindings_for(parts.detail).get(DETAIL_PARAM),
        Some(chosen)
    );
    assert!(layout
        .affected_panes(ChannelId::ONE, "manuscript")
        .is_empty());
}

#[test]
fn an_empty_selection_is_a_value_and_unbinds_the_parameter() {
    let (mut layout, parts) = three_column();
    layout
        .apply(Verb::Select {
            target: PaneRef::role(Role::LIST),
            kind: "publication".to_string(),
            ids: vec![Uuid::from_u128(1)],
        })
        .unwrap();
    layout
        .apply(Verb::Select {
            target: PaneRef::role(Role::LIST),
            kind: "publication".to_string(),
            ids: vec![],
        })
        .unwrap();
    assert_eq!(layout.bindings_for(parts.detail).get(DETAIL_PARAM), None);
}

#[test]
fn follow_resolves_to_the_windows_default_channel() {
    let (mut layout, parts) = three_column();
    layout.window_mut(parts.window).unwrap().default_channel = ChannelId::number(4);
    layout
        .apply(Verb::BindParam {
            target: PaneRef::role(Role::DETAIL),
            name: DETAIL_PARAM.to_string(),
            source: ParamSource::follow(),
        })
        .unwrap();
    layout
        .apply(Verb::SetChannel {
            target: PaneRef::role(Role::LIST),
            channel: ChannelId::Follow,
        })
        .unwrap();
    let chosen = Uuid::from_u128(77);
    layout
        .apply(Verb::Select {
            target: PaneRef::role(Role::LIST),
            kind: "publication".to_string(),
            ids: vec![chosen],
        })
        .unwrap();

    assert_eq!(
        layout.channels.current(4, "publication"),
        Some(chosen),
        "the publishing pane's `follow` resolved to the window default"
    );
    assert_eq!(
        layout.bindings_for(parts.detail).get(DETAIL_PARAM),
        Some(chosen)
    );
    assert_eq!(
        layout.affected_panes(ChannelId::Follow, "publication"),
        vec![parts.detail]
    );
    assert_eq!(
        layout.affected_panes(ChannelId::number(4), "publication"),
        vec![parts.detail]
    );
    assert!(layout
        .affected_panes(ChannelId::ONE, "publication")
        .is_empty());
}

// ------------------------------------------------------------------ window

#[test]
fn set_window_geometry_stores_the_device_scoped_frame() {
    let (mut layout, parts) = three_column();
    let geometry = Geometry {
        x: 10.0,
        y: 20.0,
        w: 1440.0,
        h: 900.0,
        display: Some("Built-in".to_string()),
    };
    layout
        .apply(Verb::SetWindowGeometry {
            window: parts.window,
            geometry: Some(geometry.clone()),
        })
        .unwrap();
    assert_eq!(
        layout.window(parts.window).unwrap().geometry,
        Some(geometry)
    );

    let err = layout
        .apply(Verb::SetWindowGeometry {
            window: impress_layout::WindowId::new(99),
            geometry: None,
        })
        .unwrap_err();
    assert_eq!(
        err,
        LayoutError::UnknownWindow {
            window: impress_layout::WindowId::new(99)
        }
    );
}

// --------------------------------------------------------------- resolution

#[test]
fn resolve_finds_a_pane_by_role_by_id_and_by_focus() {
    let (layout, parts) = three_column();
    let window = window_of(&layout);
    assert_eq!(
        layout
            .resolve(window, &PaneRef::role(Role::NAVIGATOR))
            .unwrap(),
        parts.navigator
    );
    assert_eq!(
        layout
            .resolve(window, &PaneRef::role(Role::DETAIL))
            .unwrap(),
        parts.detail
    );
    assert_eq!(
        layout.resolve(window, &PaneRef::id(parts.list)).unwrap(),
        parts.list
    );
    assert_eq!(
        layout.resolve(window, &PaneRef::Focused).unwrap(),
        parts.list
    );
    assert_eq!(
        layout
            .resolve(window, &PaneRef::id(impress_layout::TileId::new(999)))
            .unwrap_err(),
        LayoutError::UnknownTile {
            tile: impress_layout::TileId::new(999)
        }
    );
}

#[test]
fn direction_right_from_the_navigator_is_the_list() {
    let (layout, parts) = three_column();
    let window = window_of(&layout);
    assert_eq!(
        layout.step(window, parts.navigator, Direction::Right),
        parts.list
    );
    assert_eq!(
        layout.step(window, parts.list, Direction::Right),
        parts.detail
    );
    assert_eq!(
        layout.step(window, parts.detail, Direction::Right),
        parts.detail
    );
    assert_eq!(
        layout.step(window, parts.detail, Direction::Left),
        parts.list
    );
    // The row is horizontal, so there is nothing above or below anything.
    assert_eq!(layout.step(window, parts.list, Direction::Up), parts.list);
    assert_eq!(layout.step(window, parts.list, Direction::Down), parts.list);
}

#[test]
fn direction_steps_into_a_tab_strips_visible_tab() {
    let (mut layout, parts) = three_column();
    let window = parts.window;
    // Tab a PDF pane over the detail pane and make it active.
    layout
        .apply(Verb::Split {
            target: PaneRef::id(parts.detail),
            dir: impress_layout::LinearDir::Vertical,
            after: true,
            new: scratch_pane(),
        })
        .unwrap();
    let pdf = layout.window(window).unwrap().focused.unwrap();
    layout
        .apply(Verb::MoveTile {
            tile: PaneRef::id(pdf),
            target: PaneRef::id(parts.detail),
            placement: Placement::IntoTabs,
        })
        .unwrap();
    assert_eq!(
        layout.step(window, parts.list, Direction::Right),
        pdf,
        "stepping into a tab strip lands on the tab it shows"
    );
}

#[test]
fn resolve_reports_no_focus_rather_than_guessing() {
    let (mut layout, parts) = three_column();
    layout.window_mut(parts.window).unwrap().focused = None;
    let err = layout.resolve(parts.window, &PaneRef::Focused).unwrap_err();
    assert_eq!(
        err,
        LayoutError::NoFocus {
            window: parts.window
        }
    );
}

// ------------------------------------------------------- detach / windows

#[test]
fn detach_moves_a_pane_into_a_new_window_and_focus_follows_it() {
    let (mut layout, parts) = three_column();
    layout
        .apply(Verb::Detach {
            target: PaneRef::role(Role::DETAIL),
        })
        .unwrap();

    assert_eq!(layout.windows.len(), 2);
    let detached = layout.window_of(parts.detail).unwrap();
    assert_ne!(detached, parts.window);
    assert_eq!(layout.window(detached).unwrap().root, parts.detail);
    assert_eq!(layout.window(detached).unwrap().focused, Some(parts.detail));
    assert_eq!(
        layout.leaves(parts.window),
        vec![parts.navigator, parts.list]
    );
    assert_eq!(
        layout.window(parts.window).unwrap().focused,
        Some(parts.list),
        "the window it left falls back to the neighbour"
    );
    assert_focus_is_a_leaf(&layout);
    assert_arena_is_sound(&layout);
}

#[test]
fn detach_refuses_a_tile_that_is_already_its_whole_window() {
    let (mut layout, parts) = three_column();
    let err = layout
        .apply(Verb::Detach {
            target: PaneRef::id(parts.root),
        })
        .unwrap_err();
    assert_eq!(err, LayoutError::CannotCloseLastPane);

    let mut single = Layout::new_single_pane(scratch_pane());
    let err = single
        .apply(Verb::Detach {
            target: PaneRef::Focused,
        })
        .unwrap_err();
    assert_eq!(err, LayoutError::CannotCloseLastPane);
}

#[test]
fn a_detached_pane_moves_back_and_its_empty_window_goes_with_it() {
    let (mut layout, parts) = three_column();
    layout
        .apply(Verb::Detach {
            target: PaneRef::id(parts.detail),
        })
        .unwrap();
    assert_eq!(layout.windows.len(), 2);

    // A tile id resolves across windows, so the move needs no window argument.
    layout
        .apply_in(
            parts.window,
            Verb::MoveTile {
                tile: PaneRef::id(parts.detail),
                target: PaneRef::id(parts.list),
                placement: Placement::Right,
            },
        )
        .unwrap();

    assert_eq!(
        layout.windows.len(),
        1,
        "a window with no tiles never persists"
    );
    assert_eq!(layout.window_of(parts.detail), Some(parts.window));
    assert_eq!(
        layout.leaves(parts.window),
        vec![parts.navigator, parts.list, parts.detail]
    );
    assert_focus_is_a_leaf(&layout);
    assert_arena_is_sound(&layout);
}

#[test]
fn closing_the_last_pane_of_a_second_window_closes_that_window() {
    let (mut layout, parts) = three_column();
    layout
        .apply(Verb::Detach {
            target: PaneRef::id(parts.detail),
        })
        .unwrap();
    let detached = layout.window_of(parts.detail).unwrap();

    layout
        .apply_in(
            detached,
            Verb::Close {
                target: PaneRef::id(parts.detail),
            },
        )
        .unwrap();

    assert_eq!(layout.windows.len(), 1);
    assert!(layout.window(detached).is_none());
    assert!(layout.tile(parts.detail).is_none());
    assert_eq!(
        layout.leaves(parts.window),
        vec![parts.navigator, parts.list]
    );
    assert_arena_is_sound(&layout);
}

#[test]
fn cannot_close_the_last_pane_in_the_whole_layout() {
    let mut layout = Layout::new_single_pane(scratch_pane());
    let first = layout.current_window().unwrap();
    let second_pane = layout.insert_pane(scratch_pane());
    let second = layout.add_window(second_pane);

    // Either window may lose its only pane while the other still has one.
    layout
        .apply_in(
            second,
            Verb::Close {
                target: PaneRef::id(second_pane),
            },
        )
        .unwrap();
    assert_eq!(layout.windows.len(), 1);

    let err = layout
        .apply_in(
            first,
            Verb::Close {
                target: PaneRef::Focused,
            },
        )
        .unwrap_err();
    assert_eq!(err, LayoutError::CannotCloseLastPane);
    assert_eq!(layout.panes().len(), 1);
}

#[test]
fn set_default_channel_moves_what_follow_means_and_refuses_follow_itself() {
    let (mut layout, parts) = three_column();
    layout
        .apply(Verb::SetDefaultChannel {
            window: parts.window,
            channel: ChannelId::number(5),
        })
        .unwrap();
    assert_eq!(
        layout.window(parts.window).unwrap().default_channel,
        ChannelId::number(5)
    );

    layout
        .apply(Verb::BindParam {
            target: PaneRef::role(Role::DETAIL),
            name: DETAIL_PARAM.to_string(),
            source: ParamSource::follow(),
        })
        .unwrap();
    layout
        .apply(Verb::SetChannel {
            target: PaneRef::role(Role::LIST),
            channel: ChannelId::Follow,
        })
        .unwrap();
    let chosen = Uuid::from_u128(5150);
    layout
        .apply(Verb::Select {
            target: PaneRef::role(Role::LIST),
            kind: "publication".to_string(),
            ids: vec![chosen],
        })
        .unwrap();
    assert_eq!(layout.channels.current(5, "publication"), Some(chosen));
    assert_eq!(
        layout.bindings_for(parts.detail).get(DETAIL_PARAM),
        Some(chosen)
    );

    let err = layout
        .apply(Verb::SetDefaultChannel {
            window: parts.window,
            channel: ChannelId::Follow,
        })
        .unwrap_err();
    assert_eq!(
        err,
        LayoutError::InvalidChannel {
            channel: ChannelId::Follow
        }
    );
    assert_eq!(
        layout.window(parts.window).unwrap().default_channel,
        ChannelId::number(5),
        "the refusal changed nothing"
    );

    let err = layout
        .apply(Verb::SetDefaultChannel {
            window: impress_layout::WindowId::new(99),
            channel: ChannelId::ONE,
        })
        .unwrap_err();
    assert!(matches!(err, LayoutError::UnknownWindow { .. }));
}
