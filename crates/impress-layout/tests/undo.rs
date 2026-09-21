//! The undo rings (ADR-0031 D7): arrangement on one ring, exploration on one
//! ring per pane, focus on neither.

mod common;

use common::{scratch_pane, three_column};
use impress_layout::{
    stack_for, ChannelId, Direction, LinearDir, PaneRef, ParamSource, Role, StackKind, UndoRing,
    UndoStacks, Verb, ViewKindId,
};
use uuid::Uuid;

#[test]
fn the_classifier_puts_each_verb_on_the_right_ring() {
    assert_eq!(
        stack_for(&Verb::Close {
            target: PaneRef::Focused
        }),
        StackKind::Arrangement
    );
    assert_eq!(stack_for(&Verb::Restore), StackKind::Arrangement);
    assert_eq!(
        stack_for(&Verb::Detach {
            target: PaneRef::Focused
        }),
        StackKind::Arrangement
    );
    assert_eq!(
        stack_for(&Verb::SetDefaultChannel {
            window: impress_layout::WindowId::new(1),
            channel: ChannelId::ONE
        }),
        StackKind::Arrangement
    );
    assert_eq!(
        stack_for(&Verb::SetRole {
            target: PaneRef::Focused,
            role: None
        }),
        StackKind::Arrangement
    );
    assert_eq!(
        stack_for(&Verb::SetQuery {
            target: PaneRef::role(Role::LIST),
            query: Default::default()
        }),
        StackKind::Exploration(PaneRef::role(Role::LIST))
    );
    assert_eq!(
        stack_for(&Verb::Select {
            target: PaneRef::Focused,
            kind: "publication".into(),
            ids: vec![]
        }),
        StackKind::Exploration(PaneRef::Focused)
    );
    assert_eq!(
        stack_for(&Verb::Focus {
            target: PaneRef::Focused
        }),
        StackKind::None
    );
    assert_eq!(
        stack_for(&Verb::FocusDirection {
            direction: Direction::Right
        }),
        StackKind::None
    );
}

#[test]
fn arrangement_undo_and_redo_restore_the_tree_exactly() {
    let (mut layout, parts) = three_column();
    let mut stacks = UndoStacks::default();
    let original = layout.clone();

    stacks
        .apply(
            &mut layout,
            Verb::Split {
                target: PaneRef::id(parts.detail),
                dir: LinearDir::Vertical,
                after: true,
                new: scratch_pane(),
            },
        )
        .unwrap();
    stacks
        .apply(
            &mut layout,
            Verb::Close {
                target: PaneRef::id(parts.navigator),
            },
        )
        .unwrap();
    let explored = layout.clone();
    assert_eq!(stacks.arrangement.done.len(), 2);

    stacks.undo_arrangement(&mut layout).unwrap();
    stacks.undo_arrangement(&mut layout).unwrap();
    assert_eq!(layout, original, "two undos got back to where we started");
    assert!(stacks.undo_arrangement(&mut layout).is_none());

    stacks.arrangement.redo(&mut layout).unwrap();
    stacks.arrangement.redo(&mut layout).unwrap();
    assert_eq!(layout, explored, "two redos got back to where we were");
}

#[test]
fn undoing_a_detach_puts_the_window_back_together() {
    let (mut layout, parts) = three_column();
    let mut stacks = UndoStacks::default();
    let original = layout.clone();

    stacks
        .apply(
            &mut layout,
            Verb::Detach {
                target: PaneRef::id(parts.detail),
            },
        )
        .unwrap();
    assert_eq!(layout.windows.len(), 2);

    stacks.undo_arrangement(&mut layout).unwrap();
    assert_eq!(
        layout, original,
        "the second window and the split are both back"
    );
}

#[test]
fn exploration_rings_are_per_pane() {
    let (mut layout, parts) = three_column();
    let mut stacks = UndoStacks::default();

    stacks
        .apply(
            &mut layout,
            Verb::SetViewKind {
                target: PaneRef::id(parts.list),
                view_kind: ViewKindId::PLOT,
            },
        )
        .unwrap();
    stacks
        .apply(
            &mut layout,
            Verb::SetViewKind {
                target: PaneRef::id(parts.detail),
                view_kind: ViewKindId::PDF,
            },
        )
        .unwrap();

    assert_eq!(stacks.exploration.len(), 2);
    assert!(stacks.arrangement.done.is_empty());

    // Undoing in the list pane leaves the detail pane's exploration alone.
    stacks.undo_exploration(&mut layout, parts.list).unwrap();
    assert_eq!(layout.pane(parts.list).unwrap().view_kind, ViewKindId::LIST);
    assert_eq!(
        layout.pane(parts.detail).unwrap().view_kind,
        ViewKindId::PDF
    );
}

#[test]
fn selection_is_exploration_and_undoing_it_restores_the_channel() {
    let (mut layout, parts) = three_column();
    let mut stacks = UndoStacks::default();
    let chosen = Uuid::from_u128(3);

    stacks
        .apply(
            &mut layout,
            Verb::Select {
                target: PaneRef::id(parts.list),
                kind: "publication".to_string(),
                ids: vec![chosen],
            },
        )
        .unwrap();
    assert_eq!(layout.channels.current(1, "publication"), Some(chosen));

    stacks.undo_exploration(&mut layout, parts.list).unwrap();
    assert_eq!(layout.channels.current(1, "publication"), None);
    assert_eq!(layout.bindings_for(parts.detail).get("item"), None);
}

#[test]
fn focus_verbs_are_not_recorded() {
    let (mut layout, parts) = three_column();
    let mut stacks = UndoStacks::default();
    stacks
        .apply(
            &mut layout,
            Verb::Focus {
                target: PaneRef::id(parts.navigator),
            },
        )
        .unwrap();
    stacks
        .apply(
            &mut layout,
            Verb::FocusDirection {
                direction: Direction::Right,
            },
        )
        .unwrap();
    assert!(stacks.arrangement.done.is_empty());
    assert!(stacks.exploration.is_empty());
}

#[test]
fn a_no_op_verb_does_not_cost_a_step() {
    let (mut layout, _) = three_column();
    let mut stacks = UndoStacks::default();
    stacks.apply(&mut layout, Verb::Restore).unwrap();
    assert!(stacks.arrangement.done.is_empty());
}

#[test]
fn a_ring_forgets_its_oldest_patch_at_capacity() {
    let (mut layout, parts) = three_column();
    let mut ring = UndoRing::new(3);
    for n in 1..=5u8 {
        let patch = layout
            .apply(Verb::SetChannel {
                target: PaneRef::id(parts.list),
                channel: ChannelId::number(n),
            })
            .unwrap();
        ring.push(patch);
    }
    assert_eq!(ring.done.len(), 3);
    // Undoing everything the ring still holds walks back three steps only.
    while ring.undo(&mut layout).is_some() {}
    assert_eq!(
        layout.pane(parts.list).unwrap().channel,
        ChannelId::number(2),
        "the ring remembered three steps, so channel 2 is as far back as it goes"
    );
}

#[test]
fn undoing_a_close_brings_the_pane_and_its_ring_back() {
    let (mut layout, parts) = three_column();
    let mut stacks = UndoStacks::default();

    stacks
        .apply(
            &mut layout,
            Verb::BindParam {
                target: PaneRef::id(parts.detail),
                name: "item".to_string(),
                source: ParamSource::Fixed {
                    item: Uuid::from_u128(11),
                },
            },
        )
        .unwrap();
    stacks
        .apply(
            &mut layout,
            Verb::Close {
                target: PaneRef::id(parts.detail),
            },
        )
        .unwrap();
    assert!(layout.pane(parts.detail).is_none());
    // The pane's exploration ring is kept: undoing the close must bring the
    // pane back with its history, which is why forgetting is explicit.
    assert!(stacks.exploration.contains_key(&parts.detail));

    stacks.undo_arrangement(&mut layout).unwrap();
    assert!(layout.pane(parts.detail).is_some());
    stacks.undo_exploration(&mut layout, parts.detail).unwrap();
    assert_eq!(
        layout
            .pane(parts.detail)
            .unwrap()
            .param("item")
            .unwrap()
            .source,
        ParamSource::Channel {
            channel: ChannelId::ONE
        }
    );
}

#[test]
fn forgetting_closed_panes_is_explicit() {
    let (mut layout, parts) = three_column();
    let mut stacks = UndoStacks::default();
    stacks
        .apply(
            &mut layout,
            Verb::SetViewKind {
                target: PaneRef::id(parts.detail),
                view_kind: ViewKindId::PDF,
            },
        )
        .unwrap();
    stacks
        .apply(
            &mut layout,
            Verb::Close {
                target: PaneRef::id(parts.detail),
            },
        )
        .unwrap();
    stacks.forget_closed_panes(&layout);
    assert!(!stacks.exploration.contains_key(&parts.detail));
}
