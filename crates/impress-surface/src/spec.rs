//! The `SurfaceSpec` vocabulary (ADR-0033 D3; `docs/plan-agent-surfaces.md`
//! "The vocabulary (normative)" is the one definition — this module implements it
//! exactly, and notes every place it had to fill a gap).
//!
//! # Wire shapes
//!
//! Every serde shape below is chosen to match the plan's worked example byte for
//! byte (as JSON *values*; key order is never significant — `serde_json::Value`'s
//! map is a `BTreeMap` in this workspace, so it can't be anyway). Two patterns
//! recur:
//!
//! - **Externally-tagged struct variants** (`Action`, most widget bodies' own
//!   sub-enums) — Rust's default enum representation already matches the plan:
//!   `Action::Set { path, value }` serializes as `{"set": {"path": …, "value": …}}`.
//! - **Untagged-by-shape** (`Source`) — the plan's `sources` entries carry no tag
//!   key at all (`{"verb": "…", "args": {…}}`, not `{"verb": {"verb": …}}`), so
//!   [`Source`] is `#[serde(untagged)]` and the variant is picked by which fields
//!   are present.
//!
//! [`Node`] is neither: its tag key (`column`, `field`, …) sits beside sibling keys
//! that are common to every kind (`id`, `label`, `help`, `when`) *and* sibling keys
//! that belong only to one kind (`bind`, `on_change`, `on_submit`, all `field`-only
//! in every example the plan gives). No combination of `#[serde(tag/flatten)]`
//! expresses "one required tag key plus a closed set of sibling keys, with an
//! unrecognized tag key kept rather than rejected" — so [`Node`] hand-writes
//! `Serialize`/`Deserialize` against `serde_json::Value` directly. See the crate
//! docs for why the "unrecognized tag key kept" half of that matters.

use std::collections::BTreeMap;

use serde::de::Error as DeError;
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use serde_json::{Map, Value};

// `PaneQuery`/`ParamDecl` are spelled once, in the pane-query algebra. See the
// Cargo.toml comment on the `impress-core` dependency for why this crate imports
// them from `impress_core::pane_query` rather than a not-yet-populated sibling.
pub use impress_core::pane_query::{PaneQuery, ParamDecl};

/// The one `surface` version this crate understands. [`validate::validate`]
/// (`crate::validate`) checks a spec's [`SurfaceSpec::surface`] field against it.
pub const SURFACE_VERSION: &str = "1.0";

// ─────────────────────────────────────────────────────────────────────────────
// SurfaceSpec
// ─────────────────────────────────────────────────────────────────────────────

/// A stored, declarative UI document (ADR-0033 D1). This is the whole of what an
/// agent authors and what `impress-surface-service` renders and reduces.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
pub struct SurfaceSpec {
    /// Always [`SURFACE_VERSION`] for a spec this crate accepts; carried as a
    /// plain string (not an enum) so a newer or older version is a *validation*
    /// finding, not a parse failure — the same choice `PaneQuery` and the layout
    /// tree make about their own version fields.
    pub surface: String,
    pub name: String,
    #[serde(default)]
    pub params: Vec<ParamDecl>,
    /// State is not `Option`: a spec with no `state` key means "no fields", which
    /// is the empty object, not null. `default_state` gives the same value a
    /// hand-written `"state": {}` would.
    #[serde(default = "default_state")]
    pub state: Value,
    #[serde(default)]
    pub sources: BTreeMap<String, Source>,
    pub root: Node,
}

fn default_state() -> Value {
    Value::Object(Map::new())
}

// ─────────────────────────────────────────────────────────────────────────────
// Sources
// ─────────────────────────────────────────────────────────────────────────────

/// Where a value a node can reference comes from. See the module docs for why
/// this is `#[serde(untagged)]` rather than externally tagged like [`Action`].
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum Source {
    Value {
        value: Value,
    },
    Verb {
        verb: String,
        #[serde(default)]
        args: Value,
    },
    Query {
        query: PaneQuery,
    },
}

#[cfg(feature = "schema")]
impl schemars::JsonSchema for Source {
    fn schema_name() -> String {
        "Source".to_string()
    }

    fn json_schema(gen: &mut schemars::gen::SchemaGenerator) -> schemars::schema::Schema {
        // `#[serde(untagged)]` has no single canonical JSON Schema shape schemars
        // can derive without picking a representation for us, so this schema is
        // documentation rather than a machine-checkable `oneOf`: an object shaped
        // like exactly one of the three variants below. `surface_schema` (S4)
        // pairs this with a worked example, which is where an authoring agent
        // actually learns the shape.
        let mut schema = schemars::schema::SchemaObject {
            instance_type: Some(schemars::schema::InstanceType::Object.into()),
            ..Default::default()
        };
        schema.metadata().description = Some(
            "One of: {\"value\": <json>} | {\"verb\": <name>, \"args\": <object>} | \
             {\"query\": <PaneQuery>}. Untagged: the variant is chosen by which keys \
             are present, never by an explicit tag."
                .to_string(),
        );
        let _ = gen; // no sub-schemas to register; kept for signature parity
        schemars::schema::Schema::Object(schema)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Actions
// ─────────────────────────────────────────────────────────────────────────────

/// What a handler (`on_click`, `on_select`, …) does. Externally tagged: Rust's
/// default enum representation already matches the plan's `{"set": {…}}` shape.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
#[serde(rename_all = "snake_case")]
pub enum Action {
    /// Write `value` (template-resolved) to `path` (a literal `state.…` path,
    /// never a template itself — see [`validate::validate`]'s `bind`/`set` check).
    Set { path: String, value: Value },
    /// Call a verb through the host's `#[impress_service]` inventory. `reduce`
    /// never runs this itself (it is pure); it resolves `args`'s templates and
    /// returns [`crate::reduce::Effect::Call`] for the runtime to execute.
    Call {
        verb: String,
        #[serde(default)]
        args: Value,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        into: Option<String>,
    },
    /// Publish a selection on the pane's channel. `ids` is a literal path (like
    /// `bind`), not a template; absent, it defaults to `event.value` at reduce
    /// time — the plan's own example (`{"on_select": [{"publish": {}}]}`) relies
    /// on exactly that default.
    Publish {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        ids: Option<String>,
    },
    /// Emit a named event to the agent (a `impress/ui/surface-event` row).
    Emit { name: String, payload: Value },
    /// Open a query in a pane. `query` is kept as an opaque JSON value (not typed
    /// `PaneQuery` directly) because the vocabulary gives no worked example and a
    /// template-resolved id computed from state has nowhere to live inside
    /// `PaneQuery::scope`'s typed `ItemRef` otherwise; the runtime parses it as a
    /// `PaneQuery` once every template in it has been resolved, the same as
    /// `plot.spec` is an opaque `plot-spec@1.0.0` payload until imprint-core reads
    /// it.
    Open {
        query: Value,
        view_kind: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        target: Option<String>,
    },
    /// Re-run a named source even though its resolved args have not changed.
    Refresh { source: String },
}

// ─────────────────────────────────────────────────────────────────────────────
// Events and `when`
// ─────────────────────────────────────────────────────────────────────────────

/// What the renderer reports happened. `widget` is a node id — author-given or
/// auto-derived, [`node_id`] computes both the same way `resolve` and `reduce` do.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
pub struct Event {
    pub widget: String,
    pub kind: EventKind,
    #[serde(default)]
    pub value: Value,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
#[serde(rename_all = "snake_case")]
pub enum EventKind {
    Change,
    Click,
    Select,
    Submit,
}

/// A node's visibility condition: truthy at `path` when `equals` is absent, or
/// exactly `equals` when it is present.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
pub struct When {
    pub path: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub equals: Option<Value>,
}

// ─────────────────────────────────────────────────────────────────────────────
// Widget bodies
// ─────────────────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
pub struct Grid {
    pub columns: u32,
    #[serde(default)]
    pub items: Vec<Node>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
pub struct Section {
    pub title: String,
    #[serde(default)]
    pub collapsed: bool,
    pub body: Box<Node>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
pub struct Tab {
    pub title: String,
    pub body: Node,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
pub struct Table {
    pub rows: Value,
    pub columns: Vec<String>,
    #[serde(default)]
    pub on_select: Vec<Action>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
pub struct ListWidget {
    pub rows: Value,
    #[serde(default)]
    pub on_select: Vec<Action>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
pub struct Plot {
    /// A `plot-spec@1.0.0` payload (ADR-0033 "Defaults"), opaque here — this
    /// crate never renders pixels.
    pub spec: Value,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
pub struct Image {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub blob: Option<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub url: Option<Value>,
}

/// The `field` widget's inner tag (`field: { text|number|slider|select|toggle|date:
/// options } `). The vocabulary gives one worked example of `options`
/// (slider's `{min, max, step}`) and no schema for the rest, so every variant
/// carries an opaque `Value` rather than a hand-invented, unverifiable struct per
/// kind — the smallest thing that round-trips the one example the plan gives and
/// leaves room for the others. [`validate::validate`] checks the one documented
/// invariant (`select`'s `options` must be non-empty) directly against the value.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
#[serde(rename_all = "snake_case")]
pub enum FieldKind {
    Text(Value),
    Number(Value),
    Slider(Value),
    Select(Value),
    Toggle(Value),
    Date(Value),
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
pub struct Button {
    pub label: String,
    #[serde(default)]
    pub on_click: Vec<Action>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
pub struct Status {
    pub level: String,
    pub message: Value,
}

// ─────────────────────────────────────────────────────────────────────────────
// Node
// ─────────────────────────────────────────────────────────────────────────────

/// One node-kind tag plus its payload. `log`/`kv` carry their `lines`/`pairs`
/// payload directly as `Value` (no wrapper struct) since each is a single opaque
/// field; every other widget with more than one field gets a named body struct
/// above so its fields have real names in the schema and in code.
#[derive(Debug, Clone, PartialEq)]
pub enum NodeKind {
    Column(Vec<Node>),
    Row(Vec<Node>),
    Grid(Grid),
    Section(Section),
    Tabs(Vec<Tab>),
    /// Markdown, or a single `{{path}}` template — same representation either way
    /// (see `template.rs`); resolved with [`crate::template::Template`].
    Text(String),
    Table(Table),
    List(ListWidget),
    Plot(Plot),
    Image(Image),
    Field(FieldKind),
    Button(Button),
    Status(Status),
    Log(Value),
    Kv(Value),
    Divider,
    Spacer,
    /// A tag key this build does not recognize. Carries the raw key and its raw
    /// value so [`crate::resolve::resolve`] can degrade it to a placeholder node
    /// instead of the whole spec failing to load (ADR-0033 "Defaults").
    Unknown {
        kind: String,
        node: Value,
    },
}

/// The names of every closed node kind, in the order the vocabulary lists them.
/// Used by the manual `JsonSchema` impl below and by `schema_tests` (see
/// `tests/spec_round_trip.rs`) to assert the generated schema mentions each one.
pub const NODE_KIND_NAMES: &[&str] = &[
    "column", "row", "grid", "section", "tabs", "text", "table", "list", "plot", "image", "field",
    "button", "status", "log", "kv", "divider", "spacer",
];

/// A surface node: the common keys plus exactly one node-kind key (D3). See the
/// module docs for why `Serialize`/`Deserialize` are hand-written rather than
/// derived.
#[derive(Debug, Clone, PartialEq)]
pub struct Node {
    pub id: Option<String>,
    pub label: Option<String>,
    pub help: Option<String>,
    pub when: Option<When>,
    /// `field`-only in every example the plan gives (`bind: state.path`), but not
    /// restricted to `field` at the type level — a node of any other kind simply
    /// never has one, and nothing reads it if present. Keeping it a plain sibling
    /// field (rather than nesting it inside [`NodeKind::Field`]'s payload) is what
    /// lets it sit beside the `field` tag key in the JSON exactly as the plan
    /// shows it, with the same flatten-free `Node` machinery every other kind
    /// uses.
    pub bind: Option<String>,
    /// Runs after a `change` event sets `bind`'s path (`field` only). The plan
    /// does not show `on_change` in its worked example, only describes its
    /// behaviour in prose ("a field change sets its bind path and then runs
    /// on_change if any") — modelled the same way as `bind`, for the same reason.
    pub on_change: Vec<Action>,
    /// Runs on a `submit` event, or is a no-op if empty — the plan gives no
    /// worked example of this either; modelled like `on_change`.
    pub on_submit: Vec<Action>,
    pub kind: NodeKind,
}

impl Node {
    /// A leaf node of the given kind with no common keys set.
    pub fn leaf(kind: NodeKind) -> Self {
        Node {
            id: None,
            label: None,
            help: None,
            when: None,
            bind: None,
            on_change: Vec::new(),
            on_submit: Vec::new(),
            kind,
        }
    }

    pub fn with_id(mut self, id: impl Into<String>) -> Self {
        self.id = Some(id.into());
        self
    }

    pub fn with_label(mut self, label: impl Into<String>) -> Self {
        self.label = Some(label.into());
        self
    }

    pub fn with_help(mut self, help: impl Into<String>) -> Self {
        self.help = Some(help.into());
        self
    }

    pub fn with_when(mut self, when: When) -> Self {
        self.when = Some(when);
        self
    }

    pub fn with_bind(mut self, bind: impl Into<String>) -> Self {
        self.bind = Some(bind.into());
        self
    }

    pub fn with_on_change(mut self, actions: Vec<Action>) -> Self {
        self.on_change = actions;
        self
    }

    pub fn with_on_submit(mut self, actions: Vec<Action>) -> Self {
        self.on_submit = actions;
        self
    }

    /// The node's direct children, for the tree walkers in `validate`, `resolve`
    /// and `reduce`. Every container kind lists its bodies; every widget kind is a
    /// leaf.
    pub fn children(&self) -> Vec<&Node> {
        match &self.kind {
            NodeKind::Column(items) | NodeKind::Row(items) => items.iter().collect(),
            NodeKind::Grid(g) => g.items.iter().collect(),
            NodeKind::Section(s) => vec![s.body.as_ref()],
            NodeKind::Tabs(tabs) => tabs.iter().map(|t| &t.body).collect(),
            _ => Vec::new(),
        }
    }

    /// The node-kind tag as it appears in JSON (`"column"`, `"field"`, … or the
    /// raw key of an [`NodeKind::Unknown`]).
    pub fn kind_name(&self) -> &str {
        match &self.kind {
            NodeKind::Column(_) => "column",
            NodeKind::Row(_) => "row",
            NodeKind::Grid(_) => "grid",
            NodeKind::Section(_) => "section",
            NodeKind::Tabs(_) => "tabs",
            NodeKind::Text(_) => "text",
            NodeKind::Table(_) => "table",
            NodeKind::List(_) => "list",
            NodeKind::Plot(_) => "plot",
            NodeKind::Image(_) => "image",
            NodeKind::Field(_) => "field",
            NodeKind::Button(_) => "button",
            NodeKind::Status(_) => "status",
            NodeKind::Log(_) => "log",
            NodeKind::Kv(_) => "kv",
            NodeKind::Divider => "divider",
            NodeKind::Spacer => "spacer",
            NodeKind::Unknown { kind, .. } => kind.as_str(),
        }
    }

    fn to_value(&self) -> Value {
        let mut map = Map::new();
        if let Some(id) = &self.id {
            map.insert("id".to_string(), Value::String(id.clone()));
        }
        if let Some(label) = &self.label {
            map.insert("label".to_string(), Value::String(label.clone()));
        }
        if let Some(help) = &self.help {
            map.insert("help".to_string(), Value::String(help.clone()));
        }
        if let Some(when) = &self.when {
            map.insert(
                "when".to_string(),
                serde_json::to_value(when).unwrap_or(Value::Null),
            );
        }
        if let Some(bind) = &self.bind {
            map.insert("bind".to_string(), Value::String(bind.clone()));
        }
        if !self.on_change.is_empty() {
            map.insert(
                "on_change".to_string(),
                serde_json::to_value(&self.on_change).unwrap_or(Value::Null),
            );
        }
        if !self.on_submit.is_empty() {
            map.insert(
                "on_submit".to_string(),
                serde_json::to_value(&self.on_submit).unwrap_or(Value::Null),
            );
        }
        let (key, value) = self.kind.to_entry();
        map.insert(key, value);
        Value::Object(map)
    }

    fn from_value(value: Value) -> Result<Node, String> {
        let mut obj = match value {
            Value::Object(m) => m,
            other => return Err(format!("a surface node must be a JSON object, got {other}")),
        };
        let id = take_string(&mut obj, "id")?;
        let label = take_string(&mut obj, "label")?;
        let help = take_string(&mut obj, "help")?;
        let when = take_field::<When>(&mut obj, "when")?;
        let bind = take_string(&mut obj, "bind")?;
        let on_change = take_actions(&mut obj, "on_change")?;
        let on_submit = take_actions(&mut obj, "on_submit")?;

        let keys: Vec<String> = obj.keys().cloned().collect();
        let kind = if keys.len() == 1 {
            let key = keys.into_iter().next().expect("len checked above");
            let raw = obj.remove(&key).expect("key just listed from this map");
            parse_kind(&key, raw)
        } else {
            // Zero or several remaining keys is not a shape any kind recognizes
            // (every real kind is exactly one key by construction); kept as
            // `Unknown` with an empty tag rather than rejected outright, for the
            // same forward-compatibility reason a single unrecognized key is.
            NodeKind::Unknown {
                kind: String::new(),
                node: Value::Object(obj),
            }
        };

        Ok(Node {
            id,
            label,
            help,
            when,
            bind,
            on_change,
            on_submit,
            kind,
        })
    }
}

impl NodeKind {
    fn to_entry(&self) -> (String, Value) {
        match self {
            NodeKind::Column(items) => (
                "column".to_string(),
                Value::Array(items.iter().map(Node::to_value).collect()),
            ),
            NodeKind::Row(items) => (
                "row".to_string(),
                Value::Array(items.iter().map(Node::to_value).collect()),
            ),
            NodeKind::Grid(g) => (
                "grid".to_string(),
                serde_json::to_value(g).unwrap_or(Value::Null),
            ),
            NodeKind::Section(s) => (
                "section".to_string(),
                serde_json::to_value(s).unwrap_or(Value::Null),
            ),
            NodeKind::Tabs(tabs) => (
                "tabs".to_string(),
                serde_json::to_value(tabs).unwrap_or(Value::Null),
            ),
            NodeKind::Text(t) => ("text".to_string(), Value::String(t.clone())),
            NodeKind::Table(t) => (
                "table".to_string(),
                serde_json::to_value(t).unwrap_or(Value::Null),
            ),
            NodeKind::List(l) => (
                "list".to_string(),
                serde_json::to_value(l).unwrap_or(Value::Null),
            ),
            NodeKind::Plot(p) => (
                "plot".to_string(),
                serde_json::to_value(p).unwrap_or(Value::Null),
            ),
            NodeKind::Image(i) => (
                "image".to_string(),
                serde_json::to_value(i).unwrap_or(Value::Null),
            ),
            NodeKind::Field(f) => (
                "field".to_string(),
                serde_json::to_value(f).unwrap_or(Value::Null),
            ),
            NodeKind::Button(b) => (
                "button".to_string(),
                serde_json::to_value(b).unwrap_or(Value::Null),
            ),
            NodeKind::Status(s) => (
                "status".to_string(),
                serde_json::to_value(s).unwrap_or(Value::Null),
            ),
            NodeKind::Log(v) => ("log".to_string(), v.clone()),
            NodeKind::Kv(v) => ("kv".to_string(), v.clone()),
            NodeKind::Divider => ("divider".to_string(), Value::Object(Map::new())),
            NodeKind::Spacer => ("spacer".to_string(), Value::Object(Map::new())),
            NodeKind::Unknown { kind, node } => (kind.clone(), node.clone()),
        }
    }
}

fn parse_kind(key: &str, raw: Value) -> NodeKind {
    let parsed: Option<NodeKind> = match key {
        "column" => serde_json::from_value::<Vec<Node>>(raw.clone())
            .ok()
            .map(NodeKind::Column),
        "row" => serde_json::from_value::<Vec<Node>>(raw.clone())
            .ok()
            .map(NodeKind::Row),
        "grid" => serde_json::from_value::<Grid>(raw.clone())
            .ok()
            .map(NodeKind::Grid),
        "section" => serde_json::from_value::<Section>(raw.clone())
            .ok()
            .map(NodeKind::Section),
        "tabs" => serde_json::from_value::<Vec<Tab>>(raw.clone())
            .ok()
            .map(NodeKind::Tabs),
        "text" => serde_json::from_value::<String>(raw.clone())
            .ok()
            .map(NodeKind::Text),
        "table" => serde_json::from_value::<Table>(raw.clone())
            .ok()
            .map(NodeKind::Table),
        "list" => serde_json::from_value::<ListWidget>(raw.clone())
            .ok()
            .map(NodeKind::List),
        "plot" => serde_json::from_value::<Plot>(raw.clone())
            .ok()
            .map(NodeKind::Plot),
        "image" => serde_json::from_value::<Image>(raw.clone())
            .ok()
            .map(NodeKind::Image),
        "field" => serde_json::from_value::<FieldKind>(raw.clone())
            .ok()
            .map(NodeKind::Field),
        "button" => serde_json::from_value::<Button>(raw.clone())
            .ok()
            .map(NodeKind::Button),
        "status" => serde_json::from_value::<Status>(raw.clone())
            .ok()
            .map(NodeKind::Status),
        "log" => Some(NodeKind::Log(raw.clone())),
        "kv" => Some(NodeKind::Kv(raw.clone())),
        "divider" => Some(NodeKind::Divider),
        "spacer" => Some(NodeKind::Spacer),
        _ => None,
    };
    parsed.unwrap_or(NodeKind::Unknown {
        kind: key.to_string(),
        node: raw,
    })
}

fn take_string(obj: &mut Map<String, Value>, key: &str) -> Result<Option<String>, String> {
    match obj.remove(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(s)) => Ok(Some(s)),
        Some(other) => Err(format!("`{key}` must be a string, got {other}")),
    }
}

fn take_field<T: serde::de::DeserializeOwned>(
    obj: &mut Map<String, Value>,
    key: &str,
) -> Result<Option<T>, String> {
    match obj.remove(key) {
        None | Some(Value::Null) => Ok(None),
        Some(v) => serde_json::from_value(v)
            .map(Some)
            .map_err(|e| format!("`{key}`: {e}")),
    }
}

fn take_actions(obj: &mut Map<String, Value>, key: &str) -> Result<Vec<Action>, String> {
    match obj.remove(key) {
        None | Some(Value::Null) => Ok(Vec::new()),
        Some(v) => serde_json::from_value(v).map_err(|e| format!("`{key}`: {e}")),
    }
}

impl Serialize for Node {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        self.to_value().serialize(serializer)
    }
}

impl<'de> Deserialize<'de> for Node {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let value = Value::deserialize(deserializer)?;
        Node::from_value(value).map_err(DeError::custom)
    }
}

#[cfg(feature = "schema")]
impl schemars::JsonSchema for Node {
    fn schema_name() -> String {
        "Node".to_string()
    }

    fn json_schema(gen: &mut schemars::gen::SchemaGenerator) -> schemars::schema::Schema {
        // See the module docs: no combination of `#[serde(tag/flatten)]` models
        // "one required tag key from a closed set, plus per-kind sibling keys,
        // with an unrecognized tag key kept rather than rejected", so this is
        // documentation (mirroring `Source`'s manual impl) rather than a
        // machine-checked `oneOf`. `schema_tests` asserts every kind name below
        // appears in the generated text.
        let mut schema = schemars::schema::SchemaObject {
            instance_type: Some(schemars::schema::InstanceType::Object.into()),
            ..Default::default()
        };
        schema.metadata().description = Some(format!(
            "A surface node: the common keys id/label/help/when, the field-only \
             keys bind/on_change/on_submit, and exactly one node-kind key — one \
             of: {}. A key this build does not recognize is kept as \
             `{{kind}}: {{node}}` rather than rejected (ADR-0033 default).",
            NODE_KIND_NAMES.join(", ")
        ));
        // The returned schema is deliberately loose (see above), but every
        // per-kind body type is still a real, derived `JsonSchema` — this
        // registers each one into `gen`'s definitions (the side effect
        // `subschema_for` exists for) so an agent reading the generated
        // document, or `schema_tests::the_schema_mentions_every_action_kind`,
        // finds `Action`'s real shape rather than nothing at all. The `$ref`s
        // returned here are discarded on purpose; `Node`'s own shape stays the
        // textual description above.
        let _ = gen.subschema_for::<Grid>();
        let _ = gen.subschema_for::<Section>();
        let _ = gen.subschema_for::<Tab>();
        let _ = gen.subschema_for::<Table>();
        let _ = gen.subschema_for::<ListWidget>();
        let _ = gen.subschema_for::<Plot>();
        let _ = gen.subschema_for::<Image>();
        let _ = gen.subschema_for::<FieldKind>();
        let _ = gen.subschema_for::<Button>();
        let _ = gen.subschema_for::<Status>();
        let _ = gen.subschema_for::<Action>();
        let _ = gen.subschema_for::<When>();
        schemars::schema::Schema::Object(schema)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Node ids
// ─────────────────────────────────────────────────────────────────────────────

/// The effective id of a node at `path` (its 0-based child index at every level,
/// root first): the author's [`Node::id`] if given, else `n` followed by the path
/// joined with `.` — `n0.2.1` is the root's third child's second child, matching
/// the plan's own example verbatim. [`crate::resolve::resolve`] and
/// [`crate::reduce::reduce`] both call this (never their own copy), so a widget id
/// a renderer reports in an [`Event`] always finds the same node `resolve` gave it.
pub fn node_id(node: &Node, path: &[usize]) -> String {
    match &node.id {
        Some(id) => id.clone(),
        None => {
            let mut s = String::from("n");
            for (i, p) in path.iter().enumerate() {
                if i > 0 {
                    s.push('.');
                }
                s.push_str(&p.to_string());
            }
            s
        }
    }
}

/// Every node in the tree, depth-first, paired with its effective id
/// ([`node_id`]). The root's path is `[0]` (id `n0` when unnamed).
pub fn walk_with_ids(root: &Node) -> Vec<(String, &Node)> {
    fn go<'a>(node: &'a Node, path: Vec<usize>, out: &mut Vec<(String, &'a Node)>) {
        out.push((node_id(node, &path), node));
        for (i, child) in node.children().into_iter().enumerate() {
            let mut child_path = path.clone();
            child_path.push(i);
            go(child, child_path, out);
        }
    }
    let mut out = Vec::new();
    go(root, vec![0], &mut out);
    out
}
