//! The pane query algebra (ADR-0031 D2).
//!
//! A pane shows the result of a [`PaneQuery`]: a small, closed algebra over the
//! shared store. It is deliberately not a language. Kinds, a scope, filters, a
//! text term, one relation walk and a sort — and any position that names an
//! item may instead name a **parameter** (`$name`) that is filled at
//! resolution time from a channel, a fixed item, or the view kind's default
//! (ADR-0031 D3).
//!
//! The algebra compiles to [`crate::query::ItemQuery`] in exactly one place,
//! [`compile`], from the [`KindManifest`] — so every schema ref the store is
//! asked for is spelled once, here, and a misspelled ref is a compile-time
//! error of the algebra rather than a silently empty pane (the ADR-0022
//! schema-ref invariant, `schema-refs.json`).
//!
//! What the algebra cannot express is **materialized first**: explorations,
//! online search results, smart searches, joins and aggregations become items
//! or collections in the store, and a pane queries those. Growing the algebra
//! is an ADR amendment.
//!
//! This module holds the types. The compiler, the manifest builder and the
//! tests are in the same module (work package L0 of `docs/plan-layout-tree.md`).

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::item::ItemId;
use crate::query::ItemQuery;
use crate::reference::EdgeType;

/// A record-kind identifier as the chassis spells it: `publication`,
/// `manuscript`, `figure`, `message`, `task`, `agent-run`, `artifact`,
/// `collection`. The manifest maps each to its canonical schema refs.
pub type RecordKindId = String;

/// A parameter name inside a query (`item`, `manuscript`, `colormap`, …).
pub type ParamName = String;

/// A position that names an item: either a literal id or a parameter to be
/// filled at resolution time.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
#[serde(tag = "ref", rename_all = "kebab-case")]
pub enum ItemRef {
    /// A literal item id.
    Id {
        #[cfg_attr(feature = "schema", schemars(with = "String"))]
        id: ItemId,
    },
    /// A parameter, filled from [`Bindings`] when the query is compiled.
    Param { name: ParamName },
}

/// What population the query draws from.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
#[serde(tag = "scope", rename_all = "kebab-case")]
pub enum Scope {
    /// Every item of the requested kinds.
    #[default]
    All,
    /// Members of one collection (a `Contains` edge from the collection).
    Collection { id: ItemRef },
    /// Members of a collection and of every collection beneath it.
    CollectionSubtree { id: ItemRef },
    /// Items whose envelope parent is this library / account / folder.
    Parent { id: ItemRef },
    /// Exactly one item. The detail pane's scope.
    Item { id: ItemRef },
}

/// A filter over the envelope fields every kind carries.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
#[serde(tag = "filter", rename_all = "kebab-case")]
pub enum Filter {
    /// Carries a flag; `color` narrows to one colour.
    Flag {
        color: Option<String>,
    },
    Starred {
        starred: bool,
    },
    Read {
        read: bool,
    },
    /// Payload `status` equals this value (`dismissed`, `archived`, `draft`, …).
    Status {
        status: String,
    },
    /// Carries this tag path (or a descendant of it).
    Tag {
        path: String,
    },
    /// A payload or envelope field within a date range (ISO-8601 strings).
    DateRange {
        field: String,
        from: Option<String>,
        to: Option<String>,
    },
}

/// One relation walk: the items reachable from `from` over `edge`, in the
/// stated direction.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
pub struct RelationWalk {
    pub edge: EdgeType,
    pub from: ItemRef,
    /// `Outgoing`: items `from` points at (papers a manuscript cites).
    /// `Incoming`: items pointing at `from` (manuscripts citing a paper).
    pub direction: Direction,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
#[serde(rename_all = "kebab-case")]
pub enum Direction {
    Outgoing,
    Incoming,
}

/// Sort key. `field` is an envelope or `payload.` path, as in
/// [`crate::query::SortDescriptor`].
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
pub struct SortKey {
    pub field: String,
    #[serde(default)]
    pub descending: bool,
}

/// The query a pane shows. See the module docs.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
pub struct PaneQuery {
    /// Record kinds to include. Empty means every kind the manifest knows.
    #[serde(default)]
    pub kinds: Vec<RecordKindId>,
    #[serde(default)]
    pub scope: Scope,
    #[serde(default)]
    pub filters: Vec<Filter>,
    /// Full-text term over `items_fts`.
    #[serde(default)]
    pub text: Option<String>,
    #[serde(default)]
    pub relation: Option<RelationWalk>,
    #[serde(default)]
    pub sort: Vec<SortKey>,
    #[serde(default)]
    pub limit: Option<u32>,
}

/// A parameter declaration on a pane: what kind of item fills it and whether
/// the view kind can render without it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
pub struct ParamDecl {
    pub name: ParamName,
    pub kind: RecordKindId,
    #[serde(default)]
    pub required: bool,
}

/// Resolved parameter values at compile time: name → item id. A parameter the
/// query names but the bindings lack is unbound; whether that is an error
/// depends on its [`ParamDecl::required`].
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
pub struct Bindings {
    #[cfg_attr(feature = "schema", schemars(with = "BTreeMap<String, String>"))]
    pub values: BTreeMap<ParamName, ItemId>,
}

impl Bindings {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn with(mut self, name: impl Into<ParamName>, id: ItemId) -> Self {
        self.values.insert(name.into(), id);
        self
    }

    pub fn get(&self, name: &str) -> Option<ItemId> {
        self.values.get(name).copied()
    }
}

/// The one place record kinds are mapped to the schema refs the store matches
/// by exact equality. Built from the same canonical spellings as
/// `schema-refs.json` and the Swift `RecordKindDescriptor`s; the test suite
/// pins it to both.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct KindManifest {
    /// kind id → canonical schema refs (a kind may span several, e.g.
    /// `message` = `email-message` + `chat-message`).
    pub kinds: BTreeMap<RecordKindId, Vec<String>>,
}

impl KindManifest {
    pub fn schema_refs(&self, kind: &str) -> Option<&[String]> {
        self.kinds.get(kind).map(Vec::as_slice)
    }

    pub fn kind_for_schema_ref(&self, schema_ref: &str) -> Option<&str> {
        self.kinds
            .iter()
            .find(|(_, refs)| refs.iter().any(|r| r == schema_ref))
            .map(|(k, _)| k.as_str())
    }
}

/// Why a query did not compile. Every variant is a *typed* failure: the pane
/// renders its empty state with the reason, never an empty list that looks
/// like "no data yet".
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, thiserror::Error)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
#[serde(tag = "error", rename_all = "kebab-case")]
pub enum PaneQueryError {
    #[error("unknown record kind '{kind}'")]
    UnknownKind { kind: RecordKindId },
    #[error("parameter '{name}' is required but unbound")]
    UnboundParam { name: ParamName },
    #[error("parameter '{name}' is bound to a {actual} but the query needs a {expected}")]
    ParamKindMismatch {
        name: ParamName,
        expected: RecordKindId,
        actual: RecordKindId,
    },
    #[error("query has no kinds and the manifest is empty")]
    NoKinds,
}

/// Compiled form: the store query plus, when the query is a single-kind
/// `Item` scope, the id it resolved to (so a detail pane can short-circuit).
#[derive(Debug, Clone, PartialEq)]
pub struct CompiledQuery {
    pub item_query: ItemQuery,
    /// Every schema ref the compiled query can touch. This is what incremental
    /// invalidation (L4) keys on: a mutation whose schema ref is not in this
    /// set cannot change the result.
    pub schema_refs: Vec<String>,
    /// The single item, when `scope` was `Item` and resolved.
    pub single_item: Option<ItemId>,
}

/// Compile a pane query against the manifest with the given bindings.
///
/// Implemented in work package L0. Until then this is the contract.
pub fn compile(
    query: &PaneQuery,
    decls: &[ParamDecl],
    bindings: &Bindings,
    manifest: &KindManifest,
) -> Result<CompiledQuery, PaneQueryError> {
    compiler::compile(query, decls, bindings, manifest)
}

/// The names of every parameter the query mentions, in first-use order.
pub fn params_in(query: &PaneQuery) -> Vec<ParamName> {
    let mut out: Vec<ParamName> = Vec::new();
    let mut push = |r: &ItemRef| {
        if let ItemRef::Param { name } = r {
            if !out.contains(name) {
                out.push(name.clone());
            }
        }
    };
    match &query.scope {
        Scope::All => {}
        Scope::Collection { id }
        | Scope::CollectionSubtree { id }
        | Scope::Parent { id }
        | Scope::Item { id } => push(id),
    }
    if let Some(walk) = &query.relation {
        push(&walk.from);
    }
    out
}

mod compiler {
    //! Filled in by L0. The stub keeps the crate compiling so the layout crate
    //! (L1) can build against the types in parallel.
    use super::*;

    pub fn compile(
        _query: &PaneQuery,
        _decls: &[ParamDecl],
        _bindings: &Bindings,
        _manifest: &KindManifest,
    ) -> Result<CompiledQuery, PaneQueryError> {
        Err(PaneQueryError::NoKinds)
    }
}

#[cfg(test)]
mod contract_tests {
    use super::*;
    use uuid::Uuid;

    #[test]
    fn params_are_listed_in_first_use_order_without_duplicates() {
        let q = PaneQuery {
            scope: Scope::Collection {
                id: ItemRef::Param {
                    name: "collection".into(),
                },
            },
            relation: Some(RelationWalk {
                edge: EdgeType::Cites,
                from: ItemRef::Param {
                    name: "manuscript".into(),
                },
                direction: Direction::Outgoing,
            }),
            ..Default::default()
        };
        assert_eq!(params_in(&q), vec!["collection", "manuscript"]);
    }

    #[test]
    fn query_serde_round_trip() {
        let q = PaneQuery {
            kinds: vec!["publication".into()],
            scope: Scope::Item {
                id: ItemRef::Id { id: Uuid::nil() },
            },
            filters: vec![
                Filter::Flag { color: None },
                Filter::Starred { starred: true },
            ],
            text: Some("dark matter".into()),
            relation: None,
            sort: vec![SortKey {
                field: "modified".into(),
                descending: true,
            }],
            limit: Some(50),
        };
        let json = serde_json::to_string(&q).unwrap();
        let back: PaneQuery = serde_json::from_str(&json).unwrap();
        assert_eq!(q, back);
    }
}
