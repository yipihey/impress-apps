//! A text performance of a [`koine::surface::RenderTree`].
//!
//! [`render`] walks the tree and writes one line per node. [`TextFrontend::key`]
//! turns j/k/Enter into an [`koine::surface::Event`] for the focused widget.
//! Neither function decides what the event means. [`koine::surface::reduce`]
//! does that, the same way the Swift renderer forwards a click.

use koine::surface::{Event, EventKind, RenderKind, RenderNode, RenderTree};
use serde_json::Value;

/// A key this frontend understands. Anything else is ignored.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Key {
    /// Next focusable widget (`j`).
    Down,
    /// Previous focusable widget (`k`).
    Up,
    /// Activate the focused widget (`Enter`).
    Activate,
}

/// One text performance of a tree: a cursor into [`RenderTree::focus_order`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TextFrontend {
    focus: usize,
}

impl Default for TextFrontend {
    fn default() -> Self {
        Self::new()
    }
}

impl TextFrontend {
    pub fn new() -> Self {
        Self { focus: 0 }
    }

    /// The focused widget id, when the tree has a focus order.
    pub fn focused_id<'a>(&self, tree: &'a RenderTree) -> Option<&'a str> {
        tree.focus_order.get(self.focus).map(String::as_str)
    }

    /// The tree as lines. The focused widget's line starts with `>`.
    pub fn render(&self, tree: &RenderTree) -> String {
        let focused = self.focused_id(tree);
        let mut lines = Vec::new();
        write_node(&tree.root, 0, focused, &mut lines);
        lines.join("\n")
    }

    /// Move the cursor, or build the event Enter would send.
    ///
    /// `Down` and `Up` return `None`: they change which widget is focused and
    /// do not tell the grammar anything happened. `Activate` returns a `click`
    /// on the focused id. An empty focus order activates nothing.
    pub fn key(&mut self, tree: &RenderTree, key: Key) -> Option<Event> {
        let n = tree.focus_order.len();
        if n == 0 {
            return None;
        }
        self.focus = self.focus.min(n - 1);
        match key {
            Key::Down => {
                self.focus = (self.focus + 1) % n;
                None
            }
            Key::Up => {
                self.focus = (self.focus + n - 1) % n;
                None
            }
            Key::Activate => Some(Event {
                widget: tree.focus_order[self.focus].clone(),
                kind: EventKind::Click,
                value: Value::Null,
            }),
        }
    }
}

/// [`TextFrontend::render`] on a fresh cursor.
pub fn render(tree: &RenderTree) -> String {
    TextFrontend::new().render(tree)
}

fn write_node(node: &RenderNode, depth: usize, focused: Option<&str>, out: &mut Vec<String>) {
    let marker = if focused == Some(node.id.as_str()) {
        ">"
    } else {
        " "
    };
    let indent = "  ".repeat(depth);
    out.push(format!("{marker}{indent}{}", line_of(node)));
    for child in children_of(node) {
        write_node(child, depth + 1, focused, out);
    }
}

fn line_of(node: &RenderNode) -> String {
    match &node.node {
        RenderKind::Column { .. } => "column".into(),
        RenderKind::Row { .. } => "row".into(),
        RenderKind::Grid { columns, .. } => format!("grid {columns}"),
        RenderKind::Section {
            title, collapsed, ..
        } => {
            format!(
                "section {title}{}",
                if *collapsed { " (collapsed)" } else { "" }
            )
        }
        RenderKind::Tabs { tabs } => format!("tabs {}", tabs.len()),
        RenderKind::Text { text } => format!("text {text}"),
        RenderKind::Table { columns, .. } => format!("table {}", columns.join(",")),
        RenderKind::List { .. } => "list".into(),
        RenderKind::Plot { .. } => "plot".into(),
        RenderKind::Image { .. } => "image".into(),
        RenderKind::Field { value, .. } => format!("field {value}"),
        RenderKind::Button { label } => format!("button {label}"),
        RenderKind::Status { level, message } => format!("status {level}: {message}"),
        RenderKind::Log { .. } => "log".into(),
        RenderKind::Kv { .. } => "kv".into(),
        RenderKind::Divider => "divider".into(),
        RenderKind::Spacer => "spacer".into(),
        RenderKind::Placeholder {
            unknown_kind,
            reason,
            ..
        } => {
            let kind = unknown_kind.as_deref().unwrap_or("placeholder");
            match reason {
                Some(reason) => format!("placeholder {kind}: {reason}"),
                None => format!("placeholder {kind}"),
            }
        }
    }
}

fn children_of(node: &RenderNode) -> Vec<&RenderNode> {
    match &node.node {
        RenderKind::Column { items }
        | RenderKind::Row { items }
        | RenderKind::Grid { items, .. } => items.iter().collect(),
        RenderKind::Section { body, .. } => vec![body.as_ref()],
        RenderKind::Tabs { tabs } => tabs.iter().map(|tab| &tab.body).collect(),
        _ => Vec::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use koine::surface::resolve;

    #[test]
    fn a_resolved_surface_renders_as_text_and_enter_names_the_focused_widget() {
        let spec = koine::surface::example_paper_triage();
        let tree = resolve(
            &spec,
            &serde_json::json!({}),
            &serde_json::json!({}),
            &serde_json::json!({}),
        );
        let mut frontend = TextFrontend::new();
        let text = frontend.render(&tree);
        assert!(
            text.contains("column")
                || text.contains("text")
                || text.contains("button")
                || text.contains("table")
                || text.contains("list"),
            "{text}"
        );
        assert!(text.lines().any(|line| line.starts_with('>')), "{text}");

        let first = frontend.focused_id(&tree).unwrap().to_string();
        assert!(frontend.key(&tree, Key::Down).is_none());
        if tree.focus_order.len() > 1 {
            assert_ne!(frontend.focused_id(&tree), Some(first.as_str()));
        }
        frontend.key(&tree, Key::Up);
        assert_eq!(frontend.focused_id(&tree), Some(first.as_str()));

        let event = frontend
            .key(&tree, Key::Activate)
            .expect("a focused widget");
        assert_eq!(event.widget, first);
        assert_eq!(event.kind, EventKind::Click);
    }
}
