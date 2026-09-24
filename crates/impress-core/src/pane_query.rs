//! The pane query algebra (ADR-0031 D2).
//!
//! The algebra's *types* — [`PaneQuery`] and everything it is built from —
//! now live in [`impress_pane_query`], free of impress-core's domain modules
//! (ADR-0033 D7), and are re-exported below so every existing
//! `impress_core::pane_query::X` path keeps resolving. What stays here is
//! everything that is NOT pure algebra:
//!
//! - [`compile`] / [`compile_with`], the one place the algebra becomes a
//!   [`crate::query::ItemQuery`] — so every schema ref the store is asked
//!   for is spelled once, here, and a misspelled ref is a compile-time error
//!   of the algebra rather than a silently empty pane (the ADR-0022
//!   schema-ref invariant, `schema-refs.json`);
//! - [`builtin_manifest`], the chassis's built-in [`KindManifest`] — domain
//!   data, because it names impress's own schema refs, not a property of the
//!   algebra a standalone host would share;
//! - [`invalidation`], which reads a compiled query's dependencies against a
//!   live [`crate::event::StoreMutation`].
//!
//! # Entry points
//!
//! [`compile`] is the whole surface; [`compile_with`] is the same thing plus a
//! [`SubtreeResolver`], which [`Scope::CollectionSubtree`] needs because the
//! collection tree lives in the store and this compiler is pure.
//!
//! # Empty is not an error, and an error is not empty
//!
//! Two failure modes are deliberately kept apart. A query that is WRONG —
//! an unknown kind, a required parameter with no value, a parameter declared
//! as the wrong kind — returns a typed [`PaneQueryError`] the pane renders as
//! a reason. A query that is merely UNFILLED — an optional parameter with no
//! value yet, which is every detail pane before the first selection —
//! compiles to a query that matches nothing (`In("id", [])`, which
//! `sql_query` renders as the constant `0`). Neither ever degrades to "no
//! predicate", because a dropped predicate shows the user every row in the
//! store and calls it a result.
//!
//! This module holds the compiler. The types, the manifest's shape and their
//! pure tests are in `impress-pane-query` (work package S0 of
//! `docs/plan-agent-surfaces.md`, moved out of the original single module
//! from work package L0 of `docs/plan-layout-tree.md`).

use std::collections::BTreeMap;

use crate::item::ItemId;
use crate::query::ItemQuery;
use crate::reference::EdgeType;

// Every algebra type, re-exported so `impress_core::pane_query::X` keeps
// resolving for existing callers (ADR-0033 D7's compatibility rule). `ItemId`
// is deliberately NOT re-exported: it would collide with `crate::item::ItemId`
// above, and there is nothing to gain — the two are the same `Uuid` alias
// (see `impress_pane_query`'s module docs). `EdgeType` is deliberately NOT
// re-exported either: it is a distinct type from `crate::reference::EdgeType`
// and this module converts between them at the compiler boundary, so no path
// in this crate should resolve `pane_query::EdgeType` ambiguously.
pub use impress_pane_query::{
    params_in, Bindings, Direction, Filter, ItemRef, KindManifest, PaneQuery, PaneQueryError,
    ParamDecl, ParamName, RecordKindId, RelationWalk, Scope, SortKey,
};

/// The chassis's built-in record kinds.
///
/// Every string below is copied from the `canonical` table of
/// `schema-refs.json` — which is also where the seven Swift
/// `RecordKindDescriptor`s get theirs (`BuiltinRecordKinds.swift`). The
/// store matches `items.schema_ref` by EXACT EQUALITY, so a ref spelled
/// differently here than by its writer returns zero rows forever, silently,
/// looking exactly like "the user has no data yet". There is no naming
/// convention to infer: bare (`manuscript`), namespaced
/// (`imbib/bibliography-entry`) and versioned (`task@1.0.0`) refs all
/// appear below and are all correct for their kind.
///
/// This is domain data, not algebra — a standalone host builds its own
/// [`KindManifest`] from its own schema refs the same way (ADR-0033 D7).
///
/// `manifest_refs_are_canonical` pins every entry to `schema-refs.json`.
pub fn builtin_manifest() -> KindManifest {
    let kinds: BTreeMap<RecordKindId, Vec<String>> = [
        // The seven chassis descriptors (BuiltinRecordKinds.swift).
        ("publication", vec!["imbib/bibliography-entry"]),
        ("manuscript", vec!["manuscript"]),
        ("figure", vec!["figure"]),
        ("message", vec!["email-message", "chat-message"]),
        ("task", vec!["task@1.0.0"]),
        ("agent-run", vec!["agent-run@1.0.0"]),
        (
            "artifact",
            vec![
                "impress/artifact/code",
                "impress/artifact/dataset",
                "impress/artifact/general",
                "impress/artifact/media",
                "impress/artifact/note",
                "impress/artifact/poster",
                "impress/artifact/presentation",
                "impress/artifact/webpage",
            ],
        ),
        // Navigable kinds the sidebar itself is made of. `collection`
        // spans the generic kernel schema and the three legacy bindings
        // (ADR-0022 D2 dual mode): a collection pane must find both
        // sides of the `collections.unified` flip.
        (
            "collection",
            vec![
                "collection",
                "imbib/collection",
                "manuscript-collection",
                "figure-collection",
            ],
        ),
        ("library", vec!["imbib/library"]),
        // ADR-0033 D1: a surface pane's query is `item(id)` of this kind, so
        // `surface_show` (impress-surface-service, S4) can compile a query
        // naming it the same way every other detail pane names its kind.
        ("surface", vec!["impress/ui/surface@1.0.0"]),
    ]
    .into_iter()
    .map(|(kind, refs)| {
        (
            kind.to_string(),
            refs.into_iter().map(str::to_string).collect(),
        )
    })
    .collect();
    // A library holds its papers two ways: as envelope children, and by a
    // `Contains` edge from the library (a paper parented to Save that is in
    // the Inbox, for one). The legacy library list reads both
    // (`imbib_core::unified::store_api::in_library_predicate`), so a library
    // pane must too. Figure and mail folders file by the envelope parent
    // alone (`collection_ops::Membership::EnvelopeParent`; impart writes a
    // message's mailbox as its parent), so they are not listed.
    let contains_members = [("library", vec!["publication"])]
        .into_iter()
        .map(|(kind, members)| {
            (
                kind.to_string(),
                members.into_iter().map(str::to_string).collect(),
            )
        })
        .collect();
    KindManifest {
        kinds,
        contains_members,
    }
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
    /// Everything this compiled query depends on, as
    /// [`invalidation::Invalidation::is_affected_by`] consumes it.
    ///
    /// `schema_refs` above is the documented invalidation key and remains
    /// true as far as it goes, but it is not the whole dependency: a relation
    /// walk and a collection scope also change when an EDGE is added or
    /// removed, and the mutation that moves that edge carries the schema ref
    /// of the *collection* (or of the citing manuscript), which is routinely
    /// outside the pane's own `schema_refs`. A publication list scoped to a
    /// collection would never notice a paper being filed into it. This field
    /// is the rest of the key: edges, parents, fixed ids and whether the pane
    /// reads the full-text index.
    pub invalidation: invalidation::Invalidation,
}

/// Expands a collection id into that collection and every collection beneath
/// it, for [`Scope::CollectionSubtree`].
///
/// A trait rather than a store handle so the compiler stays pure and
/// available without the `sqlite` feature: the caller reads the tree (with
/// `collection_ops::list_tree`, or from a sidebar model it already holds) and
/// hands the compiler the ids.
///
/// `root` itself may be included or left out — the compiler always queries it,
/// because a subtree contains its own root and a resolver that returns only
/// descendants would otherwise silently drop the folder's own members.
pub trait SubtreeResolver {
    fn subtree(&self, root: ItemId) -> Vec<ItemId>;
}

impl<F> SubtreeResolver for F
where
    F: Fn(ItemId) -> Vec<ItemId>,
{
    fn subtree(&self, root: ItemId) -> Vec<ItemId> {
        self(root)
    }
}

/// The resolver [`compile`] uses: no store, so a subtree degrades to the one
/// collection named. Documented rather than hidden — a pane compiled without a
/// resolver shows the folder's own members, not its descendants'.
struct RootOnly;

impl SubtreeResolver for RootOnly {
    fn subtree(&self, root: ItemId) -> Vec<ItemId> {
        vec![root]
    }
}

/// Compile a pane query against the manifest with the given bindings.
///
/// [`Scope::CollectionSubtree`] needs the collection tree, which this
/// signature has no way to read, so it compiles as [`Scope::Collection`]
/// (members of the named collection only). Use [`compile_with`] and supply a
/// [`SubtreeResolver`] when descendants matter.
pub fn compile(
    query: &PaneQuery,
    decls: &[ParamDecl],
    bindings: &Bindings,
    manifest: &KindManifest,
) -> Result<CompiledQuery, PaneQueryError> {
    compiler::compile(query, decls, bindings, manifest, &RootOnly)
}

/// [`compile`], with a resolver for [`Scope::CollectionSubtree`].
pub fn compile_with(
    query: &PaneQuery,
    decls: &[ParamDecl],
    bindings: &Bindings,
    manifest: &KindManifest,
    resolver: &dyn SubtreeResolver,
) -> Result<CompiledQuery, PaneQueryError> {
    compiler::compile(query, decls, bindings, manifest, resolver)
}

mod compiler {
    //! The one place the algebra becomes an [`ItemQuery`] (ADR-0031 D2).
    //!
    //! Every schema ref the store is asked for comes from the
    //! [`KindManifest`]; no ref is ever spelled at a call site.

    use super::invalidation::Invalidation;
    use super::*;
    use crate::item::Value;
    use crate::query::{Predicate, SortDescriptor};

    /// The journal schema. Excluded from the `assume_schema_rare` planner hint
    /// because operation rows ARE most of the table — the hint would trade a
    /// fast sort-index walk for probe-and-sort-everything (see
    /// [`ItemQuery::assume_schema_rare`]).
    const OPERATION_SCHEMA_REF: &str = "core/operation";

    /// The column FTS routes through. `sql_query` turns `Contains` on any
    /// `items_fts`-backed field into `items_fts MATCH ?`, which is unqualified
    /// — it searches every indexed column (title, author, abstract, note,
    /// body), which is what a pane's text box means. This is the same index
    /// `search_ops::search_all` reads; that kernel exists to BUCKET hits by
    /// kind, which a single-kind pane query does not need.
    const FTS_FIELD: &str = "title";

    /// Envelope timestamp columns, stored as epoch milliseconds.
    const TIMESTAMP_FIELDS: [&str; 2] = ["created", "modified"];

    /// A predicate that matches nothing. `sql_query` compiles an empty `In`
    /// to the constant `0`, so this is the algebra's FALSE.
    fn matches_nothing() -> Predicate {
        Predicate::In("id".to_string(), Vec::new())
    }

    /// What an [`ItemRef`] resolved to. `Unbound` is not an error: an optional
    /// parameter with no value renders an empty pane (ADR-0031 D3), never a
    /// pane showing everything.
    enum Resolved {
        Id(ItemId),
        Unbound,
    }

    fn resolve(
        r: &ItemRef,
        decls: &[ParamDecl],
        bindings: &Bindings,
    ) -> Result<Resolved, PaneQueryError> {
        match r {
            ItemRef::Id { id } => Ok(Resolved::Id(*id)),
            ItemRef::Param { name } => match bindings.get(name) {
                Some(id) => Ok(Resolved::Id(id)),
                None => {
                    // An UNDECLARED parameter is optional: ADR-0031 D3 makes
                    // required-ness a property the view kind declares, so a
                    // query naming a blank nobody declared degrades to the
                    // empty state rather than failing the pane.
                    let required = decls
                        .iter()
                        .find(|d| &d.name == name)
                        .map(|d| d.required)
                        .unwrap_or(false);
                    if required {
                        Err(PaneQueryError::UnboundParam { name: name.clone() })
                    } else {
                        Ok(Resolved::Unbound)
                    }
                }
            },
        }
    }

    /// Which end of a [`Filter::DateRange`] a bound is. It matters only for a
    /// DATE-ONLY bound: a user who types `2026-01-31` as the upper bound means
    /// "through the 31st", so the day is INCLUDED. Midnight on both ends would
    /// make a single-day range (`from == to`) match nothing at all.
    #[derive(Clone, Copy)]
    enum Bound {
        /// Lower bound: a date-only value is midnight UTC that morning.
        From,
        /// Upper bound: a date-only value is the last millisecond of that day.
        To,
    }

    /// ISO-8601 → epoch milliseconds, for the envelope timestamp columns.
    ///
    /// A value that names a TIME is taken literally at both ends; only a
    /// date-only value is widened by [`Bound`].
    fn iso_to_millis(field: &str, raw: &str, bound: Bound) -> Result<i64, PaneQueryError> {
        let invalid = || PaneQueryError::InvalidDate {
            field: field.to_string(),
            value: raw.to_string(),
        };
        if let Ok(dt) = chrono::DateTime::parse_from_rfc3339(raw) {
            return Ok(dt.timestamp_millis());
        }
        if let Ok(naive) = chrono::NaiveDateTime::parse_from_str(raw, "%Y-%m-%dT%H:%M:%S") {
            return Ok(naive.and_utc().timestamp_millis());
        }
        if let Ok(date) = chrono::NaiveDate::parse_from_str(raw, "%Y-%m-%d") {
            let time = match bound {
                Bound::From => date.and_hms_milli_opt(0, 0, 0, 0),
                Bound::To => date.and_hms_milli_opt(23, 59, 59, 999),
            };
            return Ok(time.ok_or_else(invalid)?.and_utc().timestamp_millis());
        }
        Err(invalid())
    }

    fn date_bound(field: &str, raw: &str, bound: Bound) -> Result<Value, PaneQueryError> {
        if TIMESTAMP_FIELDS.contains(&field) {
            Ok(Value::Int(iso_to_millis(field, raw, bound)?))
        } else {
            // A payload date field holds whatever its writer wrote — ISO-8601
            // strings, which compare lexicographically in the right order.
            Ok(Value::String(raw.to_string()))
        }
    }

    pub fn compile(
        query: &PaneQuery,
        decls: &[ParamDecl],
        bindings: &Bindings,
        manifest: &KindManifest,
        resolver: &dyn SubtreeResolver,
    ) -> Result<CompiledQuery, PaneQueryError> {
        // ── Kinds → schema refs ──────────────────────────────────────────
        let kinds: Vec<RecordKindId> = if query.kinds.is_empty() {
            manifest.kinds.keys().cloned().collect()
        } else {
            query.kinds.clone()
        };
        if kinds.is_empty() {
            return Err(PaneQueryError::NoKinds);
        }

        let mut schema_refs: Vec<String> = Vec::new();
        for kind in &kinds {
            let refs = manifest
                .schema_refs(kind)
                .ok_or_else(|| PaneQueryError::UnknownKind { kind: kind.clone() })?;
            for r in refs {
                if !schema_refs.contains(r) {
                    schema_refs.push(r.clone());
                }
            }
        }

        // ── Static parameter checks ──────────────────────────────────────
        //
        // A scope parameter DECLARED as the wrong kind can never agree with
        // the scope, bound or not, so this runs before the bindings are
        // consulted. Which kind is expected depends on the scope:
        //
        // | scope                          | the parameter names            | expected      |
        // |--------------------------------|--------------------------------|---------------|
        // | `Item`                         | a row of the queried kind      | the query's   |
        // | `Collection`/`CollectionSubtree` | the containing collection    | `collection`  |
        // | `Parent`                       | the owning library (or folder) | `library`     |
        //
        // `Item` is checked only when the query names ONE kind: a
        // heterogeneous pane has no single expectation to report. `Parent`
        // ALSO accepts `collection`, because a figure folder collects its
        // members through the envelope parent (`collection_ops`
        // `Membership::EnvelopeParent`) — the message names `library` because
        // that is the ordinary case.
        let scope_expectation: Option<(&ParamName, RecordKindId, &[&str])> = match &query.scope {
            Scope::Item {
                id: ItemRef::Param { name },
            } if kinds.len() == 1 => Some((name, kinds[0].clone(), &[])),
            Scope::Collection {
                id: ItemRef::Param { name },
            }
            | Scope::CollectionSubtree {
                id: ItemRef::Param { name },
            } => Some((name, "collection".to_string(), &[])),
            Scope::Parent {
                id: ItemRef::Param { name },
            } => Some((name, "library".to_string(), &["collection"])),
            _ => None,
        };
        if let Some((name, expected, also_accepted)) = scope_expectation {
            if let Some(decl) = decls.iter().find(|d| &d.name == name) {
                if decl.kind != expected && !also_accepted.contains(&decl.kind.as_str()) {
                    return Err(PaneQueryError::ParamKindMismatch {
                        name: name.clone(),
                        expected,
                        actual: decl.kind.clone(),
                    });
                }
            }
        }

        let mut predicates: Vec<Predicate> = Vec::new();
        let mut single_item: Option<ItemId> = None;
        let mut matches_no_rows = false;
        // The dependency set, accumulated in lockstep with the predicates so
        // that there is exactly ONE place a scope or a walk is interpreted.
        // A second pass over the `PaneQuery` would re-resolve every `ItemRef`
        // and could disagree with the predicates it is supposed to describe —
        // which is the drift mode this whole layer exists to remove.
        let mut inv = Invalidation::default();

        // ── Scope ────────────────────────────────────────────────────────
        match &query.scope {
            Scope::All => {}
            Scope::Collection { id } => match resolve(id, decls, bindings)? {
                // Membership is a `Contains` edge FROM the collection TO the
                // member (`collection_ops::member_query`), so members are the
                // edge's TARGETS: `ReferencedBy(Contains, collection)`.
                Resolved::Id(c) => {
                    predicates.push(Predicate::ReferencedBy(EdgeType::Contains, c));
                    inv.depend_on_edge(EdgeType::Contains, c);
                    inv.depend_on_item(c);
                }
                Resolved::Unbound => matches_no_rows = true,
            },
            Scope::CollectionSubtree { id } => match resolve(id, decls, bindings)? {
                Resolved::Id(root) => {
                    // The resolver's order is kept (a tree walk reads
                    // top-down), so this dedups by membership rather than by
                    // sorting — `Vec::dedup` would only catch neighbours.
                    let mut ids: Vec<ItemId> = vec![root];
                    for id in resolver.subtree(root) {
                        if !ids.contains(&id) {
                            ids.push(id);
                        }
                    }
                    for c in &ids {
                        inv.depend_on_edge(EdgeType::Contains, *c);
                        inv.depend_on_item(*c);
                    }
                    let mut edges: Vec<Predicate> = ids
                        .into_iter()
                        .map(|c| Predicate::ReferencedBy(EdgeType::Contains, c))
                        .collect();
                    if edges.len() == 1 {
                        predicates.push(edges.remove(0));
                    } else {
                        predicates.push(Predicate::Or(edges));
                    }
                }
                Resolved::Unbound => matches_no_rows = true,
            },
            Scope::Parent { id } => match resolve(id, decls, bindings)? {
                Resolved::Id(p) => {
                    // The parent's declared kind, when a declaration names
                    // one; a literal id leaves it to the manifest to infer.
                    let declared = match id {
                        ItemRef::Param { name } => decls
                            .iter()
                            .find(|d| &d.name == name)
                            .map(|d| d.kind.as_str()),
                        ItemRef::Id { .. } => None,
                    };
                    if manifest.parent_includes_contains(declared, &kinds) {
                        predicates.push(Predicate::Or(vec![
                            Predicate::HasParent(p),
                            Predicate::ReferencedBy(EdgeType::Contains, p),
                        ]));
                        inv.depend_on_edge(EdgeType::Contains, p);
                    } else {
                        predicates.push(Predicate::HasParent(p));
                    }
                    inv.depend_on_parent(p);
                    inv.depend_on_item(p);
                }
                Resolved::Unbound => matches_no_rows = true,
            },
            Scope::Item { id } => match resolve(id, decls, bindings)? {
                Resolved::Id(i) => {
                    inv.narrowed = true;
                    // `items.id` is the lowercase hyphenated UUID text the
                    // store writes with `Uuid::to_string()`.
                    predicates.push(Predicate::Eq("id".into(), Value::String(i.to_string())));
                    single_item = Some(i);
                    inv.depend_on_item(i);
                }
                Resolved::Unbound => {
                    // Narrowed to an empty set of ids: nothing can change it
                    // until the binding does, and that is a recompile.
                    inv.narrowed = true;
                    matches_no_rows = true;
                }
            },
        }

        // ── Filters ──────────────────────────────────────────────────────
        for filter in &query.filters {
            match filter {
                Filter::Flag { color } => predicates.push(Predicate::HasFlag(color.clone())),
                Filter::Starred { starred } => predicates.push(Predicate::IsStarred(*starred)),
                Filter::Read { read } => predicates.push(Predicate::IsRead(*read)),
                Filter::Status { status } => predicates.push(Predicate::Eq(
                    // `triage_ops::STATUS_FIELD` — a payload string on every
                    // kind, not an envelope column.
                    "payload.status".into(),
                    Value::String(status.clone()),
                )),
                Filter::Tag { path } => predicates.push(Predicate::HasTag(path.clone())),
                Filter::DateRange { field, from, to } => {
                    if let Some(from) = from {
                        predicates.push(Predicate::Gte(
                            field.clone(),
                            date_bound(field, from, Bound::From)?,
                        ));
                    }
                    if let Some(to) = to {
                        predicates.push(Predicate::Lte(
                            field.clone(),
                            date_bound(field, to, Bound::To)?,
                        ));
                    }
                }
            }
        }

        // ── Text ─────────────────────────────────────────────────────────
        if let Some(text) = query.text.as_deref() {
            let trimmed = text.trim();
            if !trimmed.is_empty() {
                predicates.push(Predicate::Contains(
                    FTS_FIELD.to_string(),
                    trimmed.to_string(),
                ));
                inv.text = true;
            }
        }

        // ── Relation walk ────────────────────────────────────────────────
        if let Some(walk) = &query.relation {
            match resolve(&walk.from, decls, bindings)? {
                Resolved::Id(from) => {
                    // `walk.edge` is the algebra's `impress_pane_query::EdgeType`
                    // (ADR-0033 D7); everything downstream — the predicate and
                    // the invalidation dependency — wants this crate's native
                    // `EdgeType`, so the boundary conversion happens once, here.
                    let edge: EdgeType = walk.edge.clone().into();
                    inv.depend_on_edge(edge.clone(), from);
                    inv.depend_on_item(from);
                    predicates.push(match walk.direction {
                        // `ReferencedBy(e, s)` = `id IN (SELECT target_id … source_id = s)`
                        // — the items `from` points at (papers a manuscript cites).
                        Direction::Outgoing => Predicate::ReferencedBy(edge, from),
                        // `HasReference(e, t)` = `id IN (SELECT source_id … target_id = t)`
                        // — the items pointing at `from` (manuscripts citing a paper).
                        Direction::Incoming => Predicate::HasReference(edge, from),
                    });
                }
                Resolved::Unbound => matches_no_rows = true,
            }
        }

        if matches_no_rows {
            predicates.push(matches_nothing());
            single_item = None;
        }

        // ── Schema constraint ────────────────────────────────────────────
        // One ref goes on `ItemQuery::schema` (the indexed column comparison);
        // several become `In("schema_ref", …)`, because `schema` holds exactly
        // one and dropping the others would widen the pane silently.
        let schema = if schema_refs.len() == 1 {
            Some(schema_refs[0].clone())
        } else {
            predicates.push(Predicate::In(
                "schema_ref".into(),
                schema_refs.iter().cloned().map(Value::String).collect(),
            ));
            None
        };

        let assume_schema_rare = schema.as_deref().is_some_and(|s| s != OPERATION_SCHEMA_REF);

        let item_query = ItemQuery {
            schema,
            predicates,
            sort: query
                .sort
                .iter()
                .map(|s| SortDescriptor {
                    field: s.field.clone(),
                    ascending: !s.descending,
                })
                .collect(),
            limit: query.limit.map(|l| l as usize),
            offset: None,
            include_tags: true,
            include_references: true,
            assume_schema_rare,
        };

        inv.schema_refs = schema_refs.clone();

        Ok(CompiledQuery {
            item_query,
            schema_refs,
            single_item,
            invalidation: inv,
        })
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Manifest ↔ schema-refs.json
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod manifest_tests {
    use super::*;
    use std::collections::BTreeSet;

    /// A container the manifest widens, and every member kind it lists, is
    /// a kind the manifest maps: a typo here would silently leave a library
    /// pane parent-only.
    #[test]
    fn contains_members_name_known_kinds() {
        let m = builtin_manifest();
        assert_eq!(
            m.contains_members.get("library"),
            Some(&vec!["publication".to_string()])
        );
        for (container, members) in &m.contains_members {
            assert!(m.kinds.contains_key(container), "{container}");
            for member in members {
                assert!(m.kinds.contains_key(member), "{container} → {member}");
            }
        }
    }

    /// Repo root, from this crate's manifest dir (`<root>/crates/impress-core`)
    /// — the same derivation `tests/support/schema_ref_manifest_support.rs`
    /// uses, so the test is location-independent.
    fn repo_root() -> std::path::PathBuf {
        std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .and_then(|p| p.parent())
            .expect("crate dir should be <repo>/crates/impress-core")
            .to_path_buf()
    }

    fn canonical_refs() -> BTreeSet<String> {
        let path = repo_root().join("schema-refs.json");
        let text = std::fs::read_to_string(&path)
            .unwrap_or_else(|e| panic!("read {}: {e}", path.display()));
        let manifest: serde_json::Value =
            serde_json::from_str(&text).unwrap_or_else(|e| panic!("parse {}: {e}", path.display()));
        manifest["canonical"]
            .as_object()
            .expect("schema-refs.json `canonical` must be an object")
            .keys()
            .cloned()
            .collect()
    }

    /// The whole point of the manifest: every ref it hands the store is a
    /// spelling something actually writes. A ref that drifts from
    /// `schema-refs.json` matches zero rows forever, silently, and looks
    /// exactly like "the user has no data yet".
    #[test]
    fn manifest_refs_are_canonical() {
        let canonical = canonical_refs();
        for (kind, refs) in &builtin_manifest().kinds {
            assert!(!refs.is_empty(), "kind {kind:?} declares no schema refs");
            for r in refs {
                assert!(
                    canonical.contains(r),
                    "kind {kind:?} names schema ref {r:?}, which is not in \
                     schema-refs.json `canonical`. The store matches \
                     schema_ref by EXACT EQUALITY: copy the spelling from the \
                     manifest, never from a sibling call site."
                );
            }
        }
    }

    #[test]
    fn builtin_carries_the_chassis_kinds_and_the_navigable_ones() {
        let m = builtin_manifest();
        let kinds: Vec<&str> = m.kinds.keys().map(String::as_str).collect();
        assert_eq!(
            kinds,
            vec![
                "agent-run",
                "artifact",
                "collection",
                "figure",
                "library",
                "manuscript",
                "message",
                "publication",
                "surface",
                "task",
            ]
        );
        // Spot-check each shape of ref: namespaced, bare, versioned, multi.
        assert_eq!(
            m.schema_refs("publication").unwrap(),
            ["imbib/bibliography-entry"]
        );
        assert_eq!(m.schema_refs("manuscript").unwrap(), ["manuscript"]);
        assert_eq!(m.schema_refs("task").unwrap(), ["task@1.0.0"]);
        assert_eq!(
            m.schema_refs("message").unwrap(),
            ["email-message", "chat-message"]
        );
        assert_eq!(m.schema_refs("artifact").unwrap().len(), 8);
        assert_eq!(
            m.schema_refs("surface").unwrap(),
            ["impress/ui/surface@1.0.0"]
        );
    }

    #[test]
    fn every_ref_maps_back_to_exactly_one_kind() {
        let m = builtin_manifest();
        let mut seen: BTreeSet<&str> = BTreeSet::new();
        for (kind, refs) in &m.kinds {
            for r in refs {
                assert!(seen.insert(r.as_str()), "{r:?} claimed by two kinds");
                assert_eq!(m.kind_for_schema_ref(r), Some(kind.as_str()));
            }
        }
        assert_eq!(m.kind_for_schema_ref("core/operation"), None);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Compiler
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod compiler_tests {
    use super::*;
    use crate::item::Value;
    use crate::query::{Predicate, SortDescriptor};
    use uuid::Uuid;

    fn manifest() -> KindManifest {
        builtin_manifest()
    }

    fn ok(query: &PaneQuery) -> CompiledQuery {
        compile(query, &[], &Bindings::new(), &manifest()).expect("compiles")
    }

    fn kinds(k: &[&str]) -> Vec<RecordKindId> {
        k.iter().map(|s| (*s).to_string()).collect()
    }

    // ── The sidebar, as queries ──────────────────────────────────────────
    //
    // ADR-0031 D2's claim is that every navigable node the chassis ships
    // today is a value in this algebra. This table is that claim, checked.

    struct Node {
        name: &'static str,
        query: PaneQuery,
        decls: Vec<ParamDecl>,
        bindings: Bindings,
        refs: Vec<&'static str>,
    }

    fn sidebar_nodes() -> Vec<Node> {
        let library = Uuid::new_v4();
        let dismissed_library = Uuid::new_v4();
        let collection = Uuid::new_v4();
        let folder = Uuid::new_v4();
        let manuscript = Uuid::new_v4();
        let paper = Uuid::new_v4();

        let manuscript_decl = ParamDecl {
            name: "manuscript".into(),
            kind: "manuscript".into(),
            required: false,
        };
        let paper_decl = ParamDecl {
            name: "paper".into(),
            kind: "publication".into(),
            required: false,
        };

        vec![
            Node {
                name: "Inbox — publications in a library",
                query: PaneQuery {
                    kinds: kinds(&["publication"]),
                    scope: Scope::Parent {
                        id: ItemRef::Id { id: library },
                    },
                    filters: vec![Filter::Read { read: false }],
                    sort: vec![SortKey {
                        field: "created".into(),
                        descending: true,
                    }],
                    ..Default::default()
                },
                decls: vec![],
                bindings: Bindings::new(),
                refs: vec!["imbib/bibliography-entry"],
            },
            Node {
                name: "Libraries — the library rows themselves",
                query: PaneQuery {
                    kinds: kinds(&["library"]),
                    ..Default::default()
                },
                decls: vec![],
                bindings: Bindings::new(),
                refs: vec!["imbib/library"],
            },
            Node {
                name: "A publication collection",
                query: PaneQuery {
                    kinds: kinds(&["publication"]),
                    scope: Scope::Collection {
                        id: ItemRef::Id { id: collection },
                    },
                    ..Default::default()
                },
                decls: vec![],
                bindings: Bindings::new(),
                refs: vec!["imbib/bibliography-entry"],
            },
            Node {
                name: "Collections — the collection rows themselves",
                query: PaneQuery {
                    kinds: kinds(&["collection"]),
                    scope: Scope::Parent {
                        id: ItemRef::Id { id: library },
                    },
                    ..Default::default()
                },
                decls: vec![],
                bindings: Bindings::new(),
                refs: vec![
                    "collection",
                    "imbib/collection",
                    "manuscript-collection",
                    "figure-collection",
                ],
            },
            Node {
                name: "Flagged publications",
                query: PaneQuery {
                    kinds: kinds(&["publication"]),
                    filters: vec![Filter::Flag { color: None }],
                    ..Default::default()
                },
                decls: vec![],
                bindings: Bindings::new(),
                refs: vec!["imbib/bibliography-entry"],
            },
            Node {
                name: "Flagged red messages",
                query: PaneQuery {
                    kinds: kinds(&["message"]),
                    filters: vec![Filter::Flag {
                        color: Some("red".into()),
                    }],
                    ..Default::default()
                },
                decls: vec![],
                bindings: Bindings::new(),
                refs: vec!["email-message", "chat-message"],
            },
            Node {
                name: "Starred — every kind",
                query: PaneQuery {
                    filters: vec![Filter::Starred { starred: true }],
                    ..Default::default()
                },
                decls: vec![],
                bindings: Bindings::new(),
                refs: vec![
                    "agent-run@1.0.0",
                    "impress/artifact/code",
                    "impress/artifact/dataset",
                    "impress/artifact/general",
                    "impress/artifact/media",
                    "impress/artifact/note",
                    "impress/artifact/poster",
                    "impress/artifact/presentation",
                    "impress/artifact/webpage",
                    "collection",
                    "imbib/collection",
                    "manuscript-collection",
                    "figure-collection",
                    "figure",
                    "imbib/library",
                    "manuscript",
                    "email-message",
                    "chat-message",
                    "imbib/bibliography-entry",
                    "impress/ui/surface@1.0.0",
                    "task@1.0.0",
                ],
            },
            Node {
                name: "Dismissed manuscripts (payload status)",
                query: PaneQuery {
                    kinds: kinds(&["manuscript"]),
                    filters: vec![Filter::Status {
                        status: "dismissed".into(),
                    }],
                    ..Default::default()
                },
                decls: vec![],
                bindings: Bindings::new(),
                refs: vec!["manuscript"],
            },
            Node {
                // imbib dismisses a paper by MOVING it to the Dismissed
                // library, never by writing `status` (triage_ops module docs).
                name: "Dismissed publications (the dismissed library)",
                query: PaneQuery {
                    kinds: kinds(&["publication"]),
                    scope: Scope::Parent {
                        id: ItemRef::Id {
                            id: dismissed_library,
                        },
                    },
                    ..Default::default()
                },
                decls: vec![],
                bindings: Bindings::new(),
                refs: vec!["imbib/bibliography-entry"],
            },
            Node {
                name: "Cited in this manuscript",
                query: PaneQuery {
                    kinds: kinds(&["publication"]),
                    relation: Some(RelationWalk {
                        edge: EdgeType::Cites.into(),
                        from: ItemRef::Param {
                            name: "manuscript".into(),
                        },
                        direction: Direction::Outgoing,
                    }),
                    ..Default::default()
                },
                decls: vec![manuscript_decl.clone()],
                bindings: Bindings::new().with("manuscript", manuscript),
                refs: vec!["imbib/bibliography-entry"],
            },
            Node {
                name: "Manuscripts citing this paper",
                query: PaneQuery {
                    kinds: kinds(&["manuscript"]),
                    relation: Some(RelationWalk {
                        edge: EdgeType::Cites.into(),
                        from: ItemRef::Param {
                            name: "paper".into(),
                        },
                        direction: Direction::Incoming,
                    }),
                    ..Default::default()
                },
                decls: vec![paper_decl],
                bindings: Bindings::new().with("paper", paper),
                refs: vec!["manuscript"],
            },
            Node {
                name: "Manuscripts folder and everything under it",
                query: PaneQuery {
                    kinds: kinds(&["manuscript"]),
                    scope: Scope::CollectionSubtree {
                        id: ItemRef::Id { id: folder },
                    },
                    ..Default::default()
                },
                decls: vec![],
                bindings: Bindings::new(),
                refs: vec!["manuscript"],
            },
            Node {
                name: "All messages",
                query: PaneQuery {
                    kinds: kinds(&["message"]),
                    ..Default::default()
                },
                decls: vec![],
                bindings: Bindings::new(),
                refs: vec!["email-message", "chat-message"],
            },
            Node {
                name: "All tasks",
                query: PaneQuery {
                    kinds: kinds(&["task"]),
                    sort: vec![SortKey {
                        field: "payload.title".into(),
                        descending: false,
                    }],
                    limit: Some(200),
                    ..Default::default()
                },
                decls: vec![],
                bindings: Bindings::new(),
                refs: vec!["task@1.0.0"],
            },
            Node {
                name: "Agent runs",
                query: PaneQuery {
                    kinds: kinds(&["agent-run"]),
                    ..Default::default()
                },
                decls: vec![],
                bindings: Bindings::new(),
                refs: vec!["agent-run@1.0.0"],
            },
            Node {
                name: "Figures",
                query: PaneQuery {
                    kinds: kinds(&["figure"]),
                    ..Default::default()
                },
                decls: vec![],
                bindings: Bindings::new(),
                refs: vec!["figure"],
            },
            Node {
                name: "Artifacts",
                query: PaneQuery {
                    kinds: kinds(&["artifact"]),
                    ..Default::default()
                },
                decls: vec![],
                bindings: Bindings::new(),
                refs: vec![
                    "impress/artifact/code",
                    "impress/artifact/dataset",
                    "impress/artifact/general",
                    "impress/artifact/media",
                    "impress/artifact/note",
                    "impress/artifact/poster",
                    "impress/artifact/presentation",
                    "impress/artifact/webpage",
                ],
            },
            Node {
                name: "Search — text over one kind",
                query: PaneQuery {
                    kinds: kinds(&["publication"]),
                    text: Some("dark matter".into()),
                    ..Default::default()
                },
                decls: vec![],
                bindings: Bindings::new(),
                refs: vec!["imbib/bibliography-entry"],
            },
            Node {
                name: "Detail pane — one publication",
                query: PaneQuery {
                    kinds: kinds(&["publication"]),
                    scope: Scope::Item {
                        id: ItemRef::Param {
                            name: "item".into(),
                        },
                    },
                    ..Default::default()
                },
                decls: vec![ParamDecl {
                    name: "item".into(),
                    kind: "publication".into(),
                    required: false,
                }],
                bindings: Bindings::new().with("item", paper),
                refs: vec!["imbib/bibliography-entry"],
            },
        ]
    }

    #[test]
    fn every_sidebar_node_compiles_to_the_expected_schema_refs() {
        for node in sidebar_nodes() {
            let compiled = compile(&node.query, &node.decls, &node.bindings, &manifest())
                .unwrap_or_else(|e| panic!("{}: {e}", node.name));
            assert_eq!(
                compiled.schema_refs, node.refs,
                "{}: schema refs",
                node.name
            );
            // One ref goes on `schema`; several must become an `In` — never
            // be dropped, which would silently widen the pane to every kind.
            if node.refs.len() == 1 {
                assert_eq!(
                    compiled.item_query.schema.as_deref(),
                    Some(node.refs[0]),
                    "{}: single ref belongs on ItemQuery::schema",
                    node.name
                );
                assert!(
                    compiled.item_query.assume_schema_rare,
                    "{}: a single non-operation schema takes the planner hint",
                    node.name
                );
            } else {
                assert!(
                    compiled.item_query.schema.is_none(),
                    "{}: multi-ref queries leave `schema` empty",
                    node.name
                );
                let expected: Vec<Value> = node
                    .refs
                    .iter()
                    .map(|r| Value::String((*r).to_string()))
                    .collect();
                assert!(
                    compiled
                        .item_query
                        .predicates
                        .contains(&Predicate::In("schema_ref".into(), expected)),
                    "{}: multi-ref queries need In(schema_ref, …)",
                    node.name
                );
                assert!(
                    !compiled.item_query.assume_schema_rare,
                    "{}: the planner hint only applies to a single schema",
                    node.name
                );
            }
            // Nothing in the table is an accidentally-empty query.
            assert!(
                !compiled
                    .item_query
                    .predicates
                    .contains(&Predicate::In("id".into(), vec![])),
                "{}: compiled to a matches-nothing query",
                node.name
            );
        }
    }

    #[test]
    fn scopes_compile_to_the_documented_predicates() {
        let id = Uuid::new_v4();

        // Membership is a Contains edge FROM the collection TO the member,
        // so members are the edge's targets.
        let c = ok(&PaneQuery {
            kinds: kinds(&["publication"]),
            scope: Scope::Collection {
                id: ItemRef::Id { id },
            },
            ..Default::default()
        });
        assert_eq!(
            c.item_query.predicates,
            vec![Predicate::ReferencedBy(EdgeType::Contains, id)]
        );

        let p = ok(&PaneQuery {
            kinds: kinds(&["publication"]),
            scope: Scope::Parent {
                id: ItemRef::Id { id },
            },
            ..Default::default()
        });
        // Publications under a parent are a library's papers, which the
        // manifest says a library also holds by a Contains edge
        // (`in_library_predicate`'s membership).
        assert_eq!(
            p.item_query.predicates,
            vec![Predicate::Or(vec![
                Predicate::HasParent(id),
                Predicate::ReferencedBy(EdgeType::Contains, id),
            ])]
        );

        let i = ok(&PaneQuery {
            kinds: kinds(&["publication"]),
            scope: Scope::Item {
                id: ItemRef::Id { id },
            },
            ..Default::default()
        });
        assert_eq!(
            i.item_query.predicates,
            vec![Predicate::Eq("id".into(), Value::String(id.to_string()))]
        );
        assert_eq!(i.single_item, Some(id));
    }

    /// A Parent scope takes the parent's `Contains` targets only when the
    /// parent is a container the manifest lists (a library) and the pane
    /// queries only its listed members (publications). Figure and mail
    /// folders stay envelope-parent only.
    #[test]
    fn a_parent_scope_takes_contains_edges_only_under_a_library() {
        let id = Uuid::new_v4();
        let widened = vec![Predicate::Or(vec![
            Predicate::HasParent(id),
            Predicate::ReferencedBy(EdgeType::Contains, id),
        ])];
        let parent_only = vec![Predicate::HasParent(id)];
        let query = |k: &[&str], r: ItemRef| PaneQuery {
            kinds: kinds(k),
            scope: Scope::Parent { id: r },
            ..Default::default()
        };
        let literal = ItemRef::Id { id };
        let param = ItemRef::Param {
            name: "parent".into(),
        };
        let declared = |kind: &str, q: &PaneQuery| {
            compile(
                q,
                &[ParamDecl {
                    name: "parent".into(),
                    kind: kind.into(),
                    required: true,
                }],
                &Bindings::new().with("parent", id),
                &manifest(),
            )
            .expect("compiles")
        };

        // A literal id: the parent's kind is inferred from the members.
        let library = ok(&query(&["publication"], literal.clone()));
        assert_eq!(library.item_query.predicates, widened);
        assert_eq!(library.invalidation.edges, vec![(EdgeType::Contains, id)]);
        assert_eq!(library.invalidation.parents, vec![id]);
        for folder in [
            &["figure"][..],
            &["message"],
            &["publication", "figure"],
            &[],
        ] {
            // A kind with several schema refs adds its `In` after the scope.
            let c = ok(&query(folder, literal.clone()));
            assert_eq!(c.item_query.predicates[..1], parent_only[..], "{folder:?}");
            assert!(c.invalidation.edges.is_empty(), "{folder:?}");
        }

        // A declared parameter: its kind decides.
        let q = query(&["publication"], param.clone());
        assert_eq!(declared("library", &q).item_query.predicates, widened);
        assert_eq!(
            declared("collection", &q).item_query.predicates,
            parent_only
        );
        let figures = query(&["figure"], param);
        assert_eq!(
            declared("library", &figures).item_query.predicates,
            parent_only
        );
        assert_eq!(
            declared("collection", &figures).item_query.predicates,
            parent_only
        );
    }

    #[test]
    fn a_subtree_without_a_resolver_is_just_the_collection() {
        let root = Uuid::new_v4();
        let c = ok(&PaneQuery {
            kinds: kinds(&["manuscript"]),
            scope: Scope::CollectionSubtree {
                id: ItemRef::Id { id: root },
            },
            ..Default::default()
        });
        assert_eq!(
            c.item_query.predicates,
            vec![Predicate::ReferencedBy(EdgeType::Contains, root)]
        );
    }

    #[test]
    fn a_subtree_with_a_resolver_ors_every_descendant() {
        let root = Uuid::new_v4();
        let child = Uuid::new_v4();
        let grandchild = Uuid::new_v4();
        let expanded = vec![root, child, grandchild];
        let resolver = move |_: ItemId| expanded.clone();
        let c = compile_with(
            &PaneQuery {
                kinds: kinds(&["manuscript"]),
                scope: Scope::CollectionSubtree {
                    id: ItemRef::Id { id: root },
                },
                ..Default::default()
            },
            &[],
            &Bindings::new(),
            &manifest(),
            &resolver,
        )
        .expect("compiles");
        assert_eq!(
            c.item_query.predicates,
            vec![Predicate::Or(vec![
                Predicate::ReferencedBy(EdgeType::Contains, root),
                Predicate::ReferencedBy(EdgeType::Contains, child),
                Predicate::ReferencedBy(EdgeType::Contains, grandchild),
            ])]
        );
    }

    /// A resolver that forgets to include its own root would otherwise drop
    /// the folder's own members — the commonest case.
    #[test]
    fn a_resolver_that_omits_the_root_still_gets_the_root() {
        let root = Uuid::new_v4();
        let child = Uuid::new_v4();
        let resolver = move |_: ItemId| vec![child];
        let c = compile_with(
            &PaneQuery {
                kinds: kinds(&["manuscript"]),
                scope: Scope::CollectionSubtree {
                    id: ItemRef::Id { id: root },
                },
                ..Default::default()
            },
            &[],
            &Bindings::new(),
            &manifest(),
            &resolver,
        )
        .expect("compiles");
        assert_eq!(
            c.item_query.predicates,
            vec![Predicate::Or(vec![
                Predicate::ReferencedBy(EdgeType::Contains, root),
                Predicate::ReferencedBy(EdgeType::Contains, child),
            ])]
        );
    }

    #[test]
    fn filters_compile_to_their_predicates() {
        let c = ok(&PaneQuery {
            kinds: kinds(&["manuscript"]),
            filters: vec![
                Filter::Flag {
                    color: Some("red".into()),
                },
                Filter::Starred { starred: true },
                Filter::Read { read: false },
                Filter::Status {
                    status: "dismissed".into(),
                },
                Filter::Tag {
                    path: "methods/sims".into(),
                },
            ],
            ..Default::default()
        });
        assert_eq!(
            c.item_query.predicates,
            vec![
                Predicate::HasFlag(Some("red".into())),
                Predicate::IsStarred(true),
                Predicate::IsRead(false),
                Predicate::Eq("payload.status".into(), Value::String("dismissed".into())),
                Predicate::HasTag("methods/sims".into()),
            ]
        );
    }

    #[test]
    fn a_date_range_on_an_envelope_column_compiles_to_epoch_millis() {
        let c = ok(&PaneQuery {
            kinds: kinds(&["manuscript"]),
            filters: vec![Filter::DateRange {
                field: "created".into(),
                from: Some("2026-01-01T00:00:00Z".into()),
                to: Some("2026-02-01".into()),
            }],
            ..Default::default()
        });
        assert_eq!(
            c.item_query.predicates,
            vec![
                Predicate::Gte("created".into(), Value::Int(1_767_225_600_000)),
                // Date-only UPPER bound = the last millisecond of that day.
                Predicate::Lte("created".into(), Value::Int(1_769_990_399_999)),
            ]
        );
    }

    /// `from == to` on a single day must match that day, not nothing — which
    /// is what midnight on both ends would have given.
    #[test]
    fn a_single_day_range_covers_that_whole_day() {
        let c = ok(&PaneQuery {
            kinds: kinds(&["manuscript"]),
            filters: vec![Filter::DateRange {
                field: "modified".into(),
                from: Some("2026-02-01".into()),
                to: Some("2026-02-01".into()),
            }],
            ..Default::default()
        });
        let (from, to) = match c.item_query.predicates.as_slice() {
            [Predicate::Gte(_, Value::Int(f)), Predicate::Lte(_, Value::Int(t))] => (*f, *t),
            other => panic!("unexpected predicates: {other:?}"),
        };
        assert_eq!(from, 1_769_904_000_000, "midnight UTC on the 1st");
        assert_eq!(to, 1_769_990_399_999, "23:59:59.999 UTC on the 1st");
        assert_eq!(to - from, 86_399_999, "one whole day, inclusive");
    }

    /// A bound that names a TIME is taken literally at both ends — only a
    /// date-only upper bound is widened.
    #[test]
    fn a_timed_upper_bound_is_not_rolled_to_end_of_day() {
        let c = ok(&PaneQuery {
            kinds: kinds(&["manuscript"]),
            filters: vec![Filter::DateRange {
                field: "created".into(),
                from: None,
                to: Some("2026-02-01T00:00:00Z".into()),
            }],
            ..Default::default()
        });
        assert_eq!(
            c.item_query.predicates,
            vec![Predicate::Lte(
                "created".into(),
                Value::Int(1_769_904_000_000)
            )]
        );
    }

    #[test]
    fn a_date_range_on_a_payload_field_stays_a_string() {
        let c = ok(&PaneQuery {
            kinds: kinds(&["manuscript"]),
            filters: vec![Filter::DateRange {
                field: "payload.due".into(),
                from: Some("2026-01-01".into()),
                to: None,
            }],
            ..Default::default()
        });
        assert_eq!(
            c.item_query.predicates,
            vec![Predicate::Gte(
                "payload.due".into(),
                Value::String("2026-01-01".into())
            )]
        );
    }

    #[test]
    fn a_malformed_envelope_date_is_a_typed_error_not_a_silent_match_all() {
        let err = compile(
            &PaneQuery {
                kinds: kinds(&["manuscript"]),
                filters: vec![Filter::DateRange {
                    field: "modified".into(),
                    from: Some("last tuesday".into()),
                    to: None,
                }],
                ..Default::default()
            },
            &[],
            &Bindings::new(),
            &manifest(),
        )
        .expect_err("malformed date");
        assert!(matches!(
            err,
            PaneQueryError::InvalidDate { ref field, ref value }
                if field == "modified" && value == "last tuesday"
        ));
    }

    #[test]
    fn text_routes_through_the_fts_predicate() {
        let c = ok(&PaneQuery {
            kinds: kinds(&["publication"]),
            text: Some("  dark matter  ".into()),
            ..Default::default()
        });
        assert_eq!(
            c.item_query.predicates,
            vec![Predicate::Contains("title".into(), "dark matter".into())]
        );
    }

    #[test]
    fn a_blank_text_term_adds_no_predicate() {
        let c = ok(&PaneQuery {
            kinds: kinds(&["publication"]),
            text: Some("   ".into()),
            ..Default::default()
        });
        assert!(c.item_query.predicates.is_empty());
    }

    #[test]
    fn relation_directions_pick_the_matching_edge_predicate() {
        let from = Uuid::new_v4();
        let outgoing = ok(&PaneQuery {
            kinds: kinds(&["publication"]),
            relation: Some(RelationWalk {
                edge: EdgeType::Cites.into(),
                from: ItemRef::Id { id: from },
                direction: Direction::Outgoing,
            }),
            ..Default::default()
        });
        assert_eq!(
            outgoing.item_query.predicates,
            vec![Predicate::ReferencedBy(EdgeType::Cites, from)]
        );

        let incoming = ok(&PaneQuery {
            kinds: kinds(&["manuscript"]),
            relation: Some(RelationWalk {
                edge: EdgeType::Cites.into(),
                from: ItemRef::Id { id: from },
                direction: Direction::Incoming,
            }),
            ..Default::default()
        });
        assert_eq!(
            incoming.item_query.predicates,
            vec![Predicate::HasReference(EdgeType::Cites, from)]
        );
    }

    #[test]
    fn sort_and_limit_carry_over() {
        let c = ok(&PaneQuery {
            kinds: kinds(&["publication"]),
            sort: vec![
                SortKey {
                    field: "created".into(),
                    descending: true,
                },
                SortKey {
                    field: "payload.title".into(),
                    descending: false,
                },
            ],
            limit: Some(50),
            ..Default::default()
        });
        assert_eq!(
            c.item_query.sort,
            vec![
                SortDescriptor {
                    field: "created".into(),
                    ascending: false,
                },
                SortDescriptor {
                    field: "payload.title".into(),
                    ascending: true,
                },
            ]
        );
        assert_eq!(c.item_query.limit, Some(50));
        assert!(c.item_query.include_tags && c.item_query.include_references);
    }

    // ── Typed failures ───────────────────────────────────────────────────

    #[test]
    fn an_unknown_kind_is_a_typed_error() {
        let err = compile(
            &PaneQuery {
                kinds: kinds(&["publiction"]),
                ..Default::default()
            },
            &[],
            &Bindings::new(),
            &manifest(),
        )
        .expect_err("unknown kind");
        assert_eq!(
            err,
            PaneQueryError::UnknownKind {
                kind: "publiction".into()
            }
        );
    }

    #[test]
    fn an_unbound_required_param_is_a_typed_error() {
        let err = compile(
            &PaneQuery {
                kinds: kinds(&["publication"]),
                scope: Scope::Collection {
                    id: ItemRef::Param {
                        name: "collection".into(),
                    },
                },
                ..Default::default()
            },
            &[ParamDecl {
                name: "collection".into(),
                kind: "collection".into(),
                required: true,
            }],
            &Bindings::new(),
            &manifest(),
        )
        .expect_err("unbound required param");
        assert_eq!(
            err,
            PaneQueryError::UnboundParam {
                name: "collection".into()
            }
        );
    }

    #[test]
    fn a_param_declared_as_the_wrong_kind_is_a_typed_error() {
        let err = compile(
            &PaneQuery {
                kinds: kinds(&["publication"]),
                scope: Scope::Item {
                    id: ItemRef::Param {
                        name: "item".into(),
                    },
                },
                ..Default::default()
            },
            &[ParamDecl {
                name: "item".into(),
                kind: "manuscript".into(),
                required: false,
            }],
            &Bindings::new().with("item", Uuid::new_v4()),
            &manifest(),
        )
        .expect_err("kind mismatch");
        assert_eq!(
            err,
            PaneQueryError::ParamKindMismatch {
                name: "item".into(),
                expected: "publication".into(),
                actual: "manuscript".into(),
            }
        );
    }

    /// A collection scope's parameter names the COLLECTION, not a row inside
    /// it — a pane wired to a `publication` channel there would silently show
    /// the collections containing nothing.
    #[test]
    fn a_collection_param_declared_as_the_wrong_kind_is_a_typed_error() {
        for scope in [
            Scope::Collection {
                id: ItemRef::Param {
                    name: "folder".into(),
                },
            },
            Scope::CollectionSubtree {
                id: ItemRef::Param {
                    name: "folder".into(),
                },
            },
        ] {
            let err = compile(
                &PaneQuery {
                    kinds: kinds(&["publication"]),
                    scope,
                    ..Default::default()
                },
                &[ParamDecl {
                    name: "folder".into(),
                    kind: "publication".into(),
                    required: false,
                }],
                &Bindings::new().with("folder", Uuid::new_v4()),
                &manifest(),
            )
            .expect_err("kind mismatch");
            assert_eq!(
                err,
                PaneQueryError::ParamKindMismatch {
                    name: "folder".into(),
                    expected: "collection".into(),
                    actual: "publication".into(),
                }
            );
        }
    }

    #[test]
    fn a_collection_param_declared_as_a_collection_is_accepted() {
        let id = Uuid::new_v4();
        let c = compile(
            &PaneQuery {
                kinds: kinds(&["publication"]),
                scope: Scope::Collection {
                    id: ItemRef::Param {
                        name: "folder".into(),
                    },
                },
                ..Default::default()
            },
            &[ParamDecl {
                name: "folder".into(),
                kind: "collection".into(),
                required: true,
            }],
            &Bindings::new().with("folder", id),
            &manifest(),
        )
        .expect("compiles");
        assert_eq!(
            c.item_query.predicates,
            vec![Predicate::ReferencedBy(EdgeType::Contains, id)]
        );
    }

    #[test]
    fn a_parent_param_declared_as_neither_library_nor_collection_is_a_typed_error() {
        let err = compile(
            &PaneQuery {
                kinds: kinds(&["publication"]),
                scope: Scope::Parent {
                    id: ItemRef::Param {
                        name: "library".into(),
                    },
                },
                ..Default::default()
            },
            &[ParamDecl {
                name: "library".into(),
                kind: "manuscript".into(),
                required: false,
            }],
            &Bindings::new().with("library", Uuid::new_v4()),
            &manifest(),
        )
        .expect_err("kind mismatch");
        assert_eq!(
            err,
            PaneQueryError::ParamKindMismatch {
                name: "library".into(),
                expected: "library".into(),
                actual: "manuscript".into(),
            }
        );
    }

    /// A figure folder collects its members through the envelope parent
    /// (`collection_ops` `Membership::EnvelopeParent`), so a `collection`
    /// parameter on a `Parent` scope is legitimate.
    #[test]
    fn a_parent_param_may_name_a_collection_as_well_as_a_library() {
        for kind in ["library", "collection"] {
            let id = Uuid::new_v4();
            let c = compile(
                &PaneQuery {
                    kinds: kinds(&["figure"]),
                    scope: Scope::Parent {
                        id: ItemRef::Param {
                            name: "container".into(),
                        },
                    },
                    ..Default::default()
                },
                &[ParamDecl {
                    name: "container".into(),
                    kind: kind.into(),
                    required: false,
                }],
                &Bindings::new().with("container", id),
                &manifest(),
            )
            .unwrap_or_else(|e| panic!("{kind}: {e}"));
            assert_eq!(c.item_query.predicates, vec![Predicate::HasParent(id)]);
        }
    }

    /// The mismatch check needs ONE kind to disagree with; a heterogeneous
    /// pane has no single expectation to report.
    #[test]
    fn a_multi_kind_item_scope_does_not_check_the_param_kind() {
        let id = Uuid::new_v4();
        let c = compile(
            &PaneQuery {
                kinds: kinds(&["publication", "manuscript"]),
                scope: Scope::Item {
                    id: ItemRef::Param {
                        name: "item".into(),
                    },
                },
                ..Default::default()
            },
            &[ParamDecl {
                name: "item".into(),
                kind: "figure".into(),
                required: false,
            }],
            &Bindings::new().with("item", id),
            &manifest(),
        )
        .expect("compiles");
        assert_eq!(c.single_item, Some(id));
    }

    #[test]
    fn an_unbound_optional_param_compiles_to_an_empty_result() {
        let c = compile(
            &PaneQuery {
                kinds: kinds(&["publication"]),
                scope: Scope::Item {
                    id: ItemRef::Param {
                        name: "item".into(),
                    },
                },
                ..Default::default()
            },
            &[ParamDecl {
                name: "item".into(),
                kind: "publication".into(),
                required: false,
            }],
            &Bindings::new(),
            &manifest(),
        )
        .expect("compiles to an empty pane, not an error");
        assert_eq!(c.single_item, None);
        assert!(c
            .item_query
            .predicates
            .contains(&Predicate::In("id".into(), vec![])));
    }

    #[test]
    fn an_undeclared_param_is_optional() {
        let c = compile(
            &PaneQuery {
                kinds: kinds(&["publication"]),
                scope: Scope::Collection {
                    id: ItemRef::Param {
                        name: "nobody-declared-me".into(),
                    },
                },
                ..Default::default()
            },
            &[],
            &Bindings::new(),
            &manifest(),
        )
        .expect("compiles");
        assert!(c
            .item_query
            .predicates
            .contains(&Predicate::In("id".into(), vec![])));
    }

    #[test]
    fn an_empty_manifest_has_no_kinds_to_offer() {
        let err = compile(
            &PaneQuery::default(),
            &[],
            &Bindings::new(),
            &KindManifest::default(),
        )
        .expect_err("no kinds");
        assert_eq!(err, PaneQueryError::NoKinds);
    }

    #[test]
    fn errors_round_trip_through_serde() {
        for err in [
            PaneQueryError::UnknownKind {
                kind: "nope".into(),
            },
            PaneQueryError::UnboundParam { name: "x".into() },
            PaneQueryError::ParamKindMismatch {
                name: "x".into(),
                expected: "publication".into(),
                actual: "manuscript".into(),
            },
            PaneQueryError::NoKinds,
            PaneQueryError::InvalidDate {
                field: "created".into(),
                value: "soon".into(),
            },
        ] {
            let json = serde_json::to_string(&err).unwrap();
            assert_eq!(serde_json::from_str::<PaneQueryError>(&json).unwrap(), err);
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Store-backed: the compiled query run against real rows
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(all(test, feature = "sqlite"))]
mod store_tests {
    use super::*;
    use crate::collection_ops::{self, GENERIC_COLLECTION};
    use crate::item::{Item, Priority, Value, Visibility};
    use crate::reference::TypedReference;
    use crate::sqlite_store::SqliteItemStore;
    use crate::store::ItemStore;
    use std::collections::BTreeMap;

    fn open() -> SqliteItemStore {
        SqliteItemStore::open_in_memory().expect("open in-memory store")
    }

    fn insert(
        store: &SqliteItemStore,
        schema_of_row: &str,
        title: &str,
        refs: Vec<TypedReference>,
    ) -> ItemId {
        let now = chrono::Utc::now();
        let mut payload: BTreeMap<String, Value> = BTreeMap::new();
        payload.insert("title".into(), Value::String(title.into()));
        let item = Item {
            id: uuid::Uuid::new_v4(),
            schema: schema_of_row.into(),
            payload,
            created: now,
            modified: now,
            author: store.default_author.clone(),
            author_kind: store.default_author_kind,
            logical_clock: 0,
            origin: None,
            canonical_id: None,
            tags: vec![],
            flag: None,
            is_read: false,
            is_starred: false,
            priority: Priority::None,
            visibility: Visibility::Private,
            message_type: None,
            produced_by: None,
            version: None,
            batch_id: None,
            references: refs,
            parent: None,
        };
        store.insert(item).expect("insert")
    }

    fn publication(store: &SqliteItemStore, title: &str) -> ItemId {
        insert(store, "imbib/bibliography-entry", title, vec![])
    }

    fn run(store: &SqliteItemStore, compiled: &CompiledQuery) -> Vec<ItemId> {
        let mut ids: Vec<ItemId> = store
            .query(&compiled.item_query)
            .expect("query runs")
            .into_iter()
            .map(|i| i.id)
            .collect();
        ids.sort();
        ids
    }

    fn sorted(mut ids: Vec<ItemId>) -> Vec<ItemId> {
        ids.sort();
        ids
    }

    fn compiled(query: &PaneQuery) -> CompiledQuery {
        compile(query, &[], &Bindings::new(), &builtin_manifest()).expect("compiles")
    }

    /// The direction claim, proved against the collection kernel rather than
    /// asserted: `add_members` writes the edge, the compiler reads it back.
    #[test]
    fn collection_scope_returns_the_members_the_kernel_filed() {
        let store = open();
        let a = publication(&store, "Member A");
        let b = publication(&store, "Member B");
        let outsider = publication(&store, "Not a member");

        let collection =
            collection_ops::create(&store, &GENERIC_COLLECTION, "Reading", None, None, None)
                .expect("create collection");
        collection_ops::add_members(
            &store,
            &GENERIC_COLLECTION,
            &collection.id,
            &[a.to_string(), b.to_string()],
        )
        .expect("add members");

        let id: ItemId = collection.id.parse().expect("uuid");
        let c = compiled(&PaneQuery {
            kinds: vec!["publication".into()],
            scope: Scope::Collection {
                id: ItemRef::Id { id },
            },
            ..Default::default()
        });
        assert_eq!(run(&store, &c), sorted(vec![a, b]));
        assert!(!run(&store, &c).contains(&outsider));
    }

    #[test]
    fn collection_subtree_scope_reaches_descendant_collections() {
        let store = open();
        let top_member = publication(&store, "Filed at the top");
        let deep_member = publication(&store, "Filed two levels down");
        let elsewhere = publication(&store, "Filed nowhere");

        let top = collection_ops::create(&store, &GENERIC_COLLECTION, "Top", None, None, None)
            .expect("create top");
        let mid = collection_ops::create(
            &store,
            &GENERIC_COLLECTION,
            "Mid",
            Some(&top.id),
            None,
            None,
        )
        .expect("create mid");
        let leaf = collection_ops::create(
            &store,
            &GENERIC_COLLECTION,
            "Leaf",
            Some(&mid.id),
            None,
            None,
        )
        .expect("create leaf");
        collection_ops::add_members(
            &store,
            &GENERIC_COLLECTION,
            &top.id,
            &[top_member.to_string()],
        )
        .expect("file top member");
        collection_ops::add_members(
            &store,
            &GENERIC_COLLECTION,
            &leaf.id,
            &[deep_member.to_string()],
        )
        .expect("file deep member");

        let root: ItemId = top.id.parse().expect("uuid");
        let query = PaneQuery {
            kinds: vec!["publication".into()],
            scope: Scope::CollectionSubtree {
                id: ItemRef::Id { id: root },
            },
            ..Default::default()
        };

        // Without a resolver, a subtree is the folder's own members only.
        let shallow = compiled(&query);
        assert_eq!(run(&store, &shallow), vec![top_member]);
        assert!(!run(&store, &shallow).contains(&elsewhere));

        // With one built from the real tree, the descendants come too.
        let tree = collection_ops::list_tree(&store, &GENERIC_COLLECTION).expect("tree");
        let resolver = move |start: ItemId| {
            let mut out = vec![start];
            let mut i = 0;
            while i < out.len() {
                let parent = out[i].to_string();
                for row in &tree {
                    if row.parent_id.as_deref() == Some(parent.as_str()) {
                        if let Ok(id) = row.id.parse::<ItemId>() {
                            if !out.contains(&id) {
                                out.push(id);
                            }
                        }
                    }
                }
                i += 1;
            }
            out
        };
        let deep = compile_with(
            &query,
            &[],
            &Bindings::new(),
            &builtin_manifest(),
            &resolver,
        )
        .expect("compiles");
        assert_eq!(run(&store, &deep), sorted(vec![top_member, deep_member]));
    }

    /// Both directions of one real `Cites` edge. Getting these backwards is
    /// invisible in a unit test and shows up as an empty "cited in" pane.
    #[test]
    fn a_cites_edge_resolves_in_both_directions() {
        let store = open();
        let paper = publication(&store, "The cited paper");
        let _unrelated = publication(&store, "An uncited paper");
        let manuscript = insert(
            &store,
            "manuscript",
            "The citing manuscript",
            vec![TypedReference {
                target: paper,
                edge_type: EdgeType::Cites,
                metadata: None,
            }],
        );

        // Papers this manuscript cites.
        let outgoing = compiled(&PaneQuery {
            kinds: vec!["publication".into()],
            relation: Some(RelationWalk {
                edge: EdgeType::Cites.into(),
                from: ItemRef::Id { id: manuscript },
                direction: Direction::Outgoing,
            }),
            ..Default::default()
        });
        assert_eq!(run(&store, &outgoing), vec![paper]);

        // Manuscripts citing this paper.
        let incoming = compiled(&PaneQuery {
            kinds: vec!["manuscript".into()],
            relation: Some(RelationWalk {
                edge: EdgeType::Cites.into(),
                from: ItemRef::Id { id: paper },
                direction: Direction::Incoming,
            }),
            ..Default::default()
        });
        assert_eq!(run(&store, &incoming), vec![manuscript]);
    }

    /// A kind that spans two refs must find BOTH — this is the `In` path, and
    /// dropping it would silently return every kind in the store.
    #[test]
    fn a_multi_ref_kind_finds_every_one_of_its_refs_and_nothing_else() {
        let store = open();
        let email = insert(&store, "email-message", "An email", vec![]);
        let chat = insert(&store, "chat-message", "A chat", vec![]);
        let _paper = publication(&store, "Not a message");

        let c = compiled(&PaneQuery {
            kinds: vec!["message".into()],
            ..Default::default()
        });
        assert_eq!(run(&store, &c), sorted(vec![email, chat]));
    }

    #[test]
    fn item_scope_returns_exactly_that_row() {
        let store = open();
        let a = publication(&store, "A");
        let _b = publication(&store, "B");
        let c = compiled(&PaneQuery {
            kinds: vec!["publication".into()],
            scope: Scope::Item {
                id: ItemRef::Id { id: a },
            },
            ..Default::default()
        });
        assert_eq!(c.single_item, Some(a));
        assert_eq!(run(&store, &c), vec![a]);
    }

    #[test]
    fn parent_scope_returns_the_library_the_rows_are_filed_in() {
        let store = open();
        let library = insert(&store, "imbib/library", "Main", vec![]);
        let other = insert(&store, "imbib/library", "Other", vec![]);
        let mine = publication(&store, "Filed here");
        let theirs = publication(&store, "Filed there");
        store
            .update(
                mine,
                vec![crate::store::FieldMutation::SetParent(Some(library))],
            )
            .expect("file");
        store
            .update(
                theirs,
                vec![crate::store::FieldMutation::SetParent(Some(other))],
            )
            .expect("file");

        let c = compiled(&PaneQuery {
            kinds: vec!["publication".into()],
            scope: Scope::Parent {
                id: ItemRef::Id { id: library },
            },
            ..Default::default()
        });
        assert_eq!(run(&store, &c), vec![mine]);
    }

    /// A library holds a paper by parent or by a `Contains` edge from the
    /// library (a paper parented to Save that is also in the Inbox). The
    /// library pane lists both; a paper merely parented elsewhere is not in it.
    #[test]
    fn a_library_pane_lists_its_contains_linked_papers_too() {
        let store = open();
        let parented = publication(&store, "Parented here");
        let linked = publication(&store, "Parented elsewhere, linked here");
        let elsewhere = publication(&store, "Parented elsewhere only");
        let library = insert(
            &store,
            "imbib/library",
            "Inbox",
            vec![TypedReference {
                target: linked,
                edge_type: EdgeType::Contains,
                metadata: None,
            }],
        );
        let save = insert(&store, "imbib/library", "Save", vec![]);
        for (paper, parent) in [(parented, library), (linked, save), (elsewhere, save)] {
            store
                .update(
                    paper,
                    vec![crate::store::FieldMutation::SetParent(Some(parent))],
                )
                .expect("file");
        }

        let c = compiled(&PaneQuery {
            kinds: vec!["publication".into()],
            scope: Scope::Parent {
                id: ItemRef::Id { id: library },
            },
            ..Default::default()
        });
        assert_eq!(run(&store, &c), sorted(vec![parented, linked]));
    }

    /// A figure folder files by the envelope parent alone
    /// (`collection_ops::Membership::EnvelopeParent`), so a `Contains` edge
    /// from the folder does not put a figure in it.
    #[test]
    fn a_figure_folder_pane_is_still_its_envelope_children() {
        let store = open();
        let filed = insert(&store, "figure", "Filed", vec![]);
        let linked = insert(&store, "figure", "Only linked", vec![]);
        let folder = insert(
            &store,
            "figure-collection",
            "Folder",
            vec![TypedReference {
                target: linked,
                edge_type: EdgeType::Contains,
                metadata: None,
            }],
        );
        store
            .update(
                filed,
                vec![crate::store::FieldMutation::SetParent(Some(folder))],
            )
            .expect("file");

        let c = compiled(&PaneQuery {
            kinds: vec!["figure".into()],
            scope: Scope::Parent {
                id: ItemRef::Id { id: folder },
            },
            ..Default::default()
        });
        assert_eq!(
            c.item_query.predicates,
            vec![crate::query::Predicate::HasParent(folder)]
        );
        assert_eq!(run(&store, &c), vec![filed]);
    }

    #[test]
    fn a_status_filter_finds_the_dismissed_rows() {
        let store = open();
        let live = insert(&store, "manuscript", "Live", vec![]);
        let dead = insert(&store, "manuscript", "Dismissed", vec![]);
        crate::triage_ops::set_status(
            &store,
            &dead.to_string(),
            Some(crate::triage_ops::STATUS_DISMISSED),
        )
        .expect("set status");

        let c = compiled(&PaneQuery {
            kinds: vec!["manuscript".into()],
            filters: vec![Filter::Status {
                status: "dismissed".into(),
            }],
            ..Default::default()
        });
        assert_eq!(run(&store, &c), vec![dead]);
        assert!(!run(&store, &c).contains(&live));
    }

    #[test]
    fn a_text_term_runs_through_the_fts_index() {
        let store = open();
        let hit = publication(&store, "Scaling relations in dark matter haloes");
        let _miss = publication(&store, "Stellar populations of dwarf galaxies");

        let c = compiled(&PaneQuery {
            kinds: vec!["publication".into()],
            text: Some("dark matter".into()),
            ..Default::default()
        });
        assert_eq!(run(&store, &c), vec![hit]);
    }

    /// The bug this whole compiler exists to prevent, run end to end: an
    /// unbound optional parameter must return NOTHING, not everything — and
    /// `x IN ()` must not be a SQL syntax error while doing it.
    #[test]
    fn an_unbound_optional_param_returns_no_rows_rather_than_all_of_them() {
        let store = open();
        let _a = publication(&store, "A");
        let _b = publication(&store, "B");

        let c = compile(
            &PaneQuery {
                kinds: vec!["publication".into()],
                scope: Scope::Item {
                    id: ItemRef::Param {
                        name: "item".into(),
                    },
                },
                ..Default::default()
            },
            &[ParamDecl {
                name: "item".into(),
                kind: "publication".into(),
                required: false,
            }],
            &Bindings::new(),
            &builtin_manifest(),
        )
        .expect("compiles");
        assert!(run(&store, &c).is_empty());
    }

    #[test]
    fn sort_and_limit_reach_the_store() {
        let store = open();
        let _a = publication(&store, "First");
        let _b = publication(&store, "Second");
        let _c = publication(&store, "Third");

        let c = compiled(&PaneQuery {
            kinds: vec!["publication".into()],
            sort: vec![SortKey {
                field: "payload.title".into(),
                descending: false,
            }],
            limit: Some(2),
            ..Default::default()
        });
        let titles: Vec<String> = store
            .query(&c.item_query)
            .expect("query")
            .into_iter()
            .filter_map(|i| match i.payload.get("title") {
                Some(Value::String(s)) => Some(s.clone()),
                _ => None,
            })
            .collect();
        assert_eq!(titles, vec!["First".to_string(), "Second".to_string()]);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Incremental invalidation (work package L4)
// ─────────────────────────────────────────────────────────────────────────────

pub mod invalidation {
    //! What a compiled pane query depends on, and whether a given store
    //! mutation can have changed its result (ADR-0031 D9).
    //!
    //! D9's prerequisite sentence: *"The prerequisite Rust work is
    //! incremental query results from the event bus, so a pane re-runs only
    //! when a mutation touches its query; without that, every mutation
    //! re-runs every pane and the startup render-loop invariant is re-tripped
    //! at scale."* That invariant is the 60–90 s startup delay every impress
    //! background service carries: a `.storeDidMutate` fan-out during the
    //! first seconds of launch compounds into a perpetual render loop. A
    //! twenty-pane window that re-queries on every mutation is the same
    //! failure with a different trigger.
    //!
    //! # The key is not just the schema ref
    //!
    //! [`CompiledQuery::schema_refs`] is the documented invalidation key and
    //! it is right for the ordinary case: a mutation on
    //! `imbib/bibliography-entry` cannot change a pane that queries
    //! `manuscript`. But two of the algebra's five scopes, and its relation
    //! walk, depend on things a schema ref does not name:
    //!
    //! | dependency | changed by | the mutation's schema ref is |
    //! |---|---|---|
    //! | collection membership | `Contains` edge add / remove | the **collection**'s |
    //! | subtree membership | ditto, plus the folder tree moving | the collection's |
    //! | `Scope::Parent` | an item being re-parented | the moved item's |
    //! | relation walk | a `Cites` edge add / remove | the **citing** item's |
    //!
    //! A publication list scoped to a collection has `schema_refs =
    //! ["imbib/bibliography-entry"]`; filing a paper into that collection
    //! targets the COLLECTION row (`collection_ops` writes membership as a
    //! `Contains` edge from the collection to the member), so the mutation
    //! carries `imbib/collection` and the schema-ref test says "cannot affect
    //! this pane". It affects it completely. [`Invalidation`] is the rest of
    //! the key.
    //!
    //! # Conservative by construction
    //!
    //! Every rule below errs toward `true`. A pane that re-runs when it did
    //! not have to costs one query; a pane that fails to re-run shows the
    //! user rows that are no longer true and gives no sign of it — the same
    //! silent-wrongness class as a misspelled schema ref. So an
    //! undeterminable schema ref is treated as matching (this is also what
    //! `SqliteItemStore::emit` does with a schemaless event), and a mutation
    //! on an id the query names literally invalidates whatever its schema.

    use super::{CompiledQuery, EdgeType, ItemId};
    use crate::event::{MutationKind, StoreMutation};
    use serde::{Deserialize, Serialize};

    /// Everything a compiled query depends on.
    ///
    /// Built by [`super::compile`] in lockstep with the predicates it
    /// describes and carried on [`CompiledQuery::invalidation`], so the
    /// dependency set can never disagree with the query it belongs to.
    #[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
    pub struct Invalidation {
        /// Every schema ref the query can return, from the kind manifest.
        /// A create / update / delete on one of these can change the result.
        #[serde(default)]
        pub schema_refs: Vec<String>,
        /// `(edge type, item)` pairs the result is computed over: the
        /// `Contains` edge of a collection or subtree scope, and the walked
        /// edge of a relation walk. An edge of this type touching this item
        /// — at either end — can change the result.
        #[serde(default)]
        pub edges: Vec<(EdgeType, ItemId)>,
        /// The parents a `Scope::Parent` query selects under. An item moving
        /// into or out of one of these changes the result.
        #[serde(default)]
        pub parents: Vec<ItemId>,
        /// Every item the query names literally: the `Scope::Item` id and
        /// every fixed or bound id in any other position (the collection, the
        /// parent, the relation anchor). Mutating one of these can change
        /// the result whatever its schema — the compiled `ItemQuery` sets
        /// `include_references: true`, so the pane's rows carry their edges
        /// and their parent, not only their payload.
        #[serde(default)]
        pub items: Vec<ItemId>,
        /// The query's result is confined to the ids in [`Self::items`]:
        /// `Scope::Item`, whose whole population is one named row.
        ///
        /// Under it the schema-ref rule does not apply. A detail pane over
        /// one paper carries `imbib/bibliography-entry` in `schema_refs`
        /// because that is the kind it returns, but it can never show a
        /// second row, so every OTHER publication's edits are noise — and
        /// the detail pane is the one pane every window has, re-rendering
        /// the most expensive view in the suite. Rules 2 to 5 still apply,
        /// so the pane's own row, and the collection / parent / relation
        /// anchor it is computed from, still wake it.
        ///
        /// It is set for an UNBOUND `Scope::Item` too — the detail pane
        /// before the first selection, which compiles to "matches nothing"
        /// and stays empty until its binding changes, and a binding change
        /// is a recompile rather than an invalidation.
        #[serde(default)]
        pub narrowed: bool,
        /// The query reads the full-text index, so any content change on one
        /// of `schema_refs` can change the result.
        ///
        /// Today this is subsumed by the schema-ref rule, because
        /// [`MutationKind::Updated`] does not carry the field list and every
        /// update on a matching schema ref already invalidates. It is
        /// recorded anyway because it is the discriminator the *opposite*
        /// refinement needs: once an update says which fields moved, a pane
        /// with `text == false` can skip payload-only churn, and a pane with
        /// `text == true` cannot.
        #[serde(default)]
        pub text: bool,
    }

    impl Invalidation {
        /// Record a dependency on edges of `edge` touching `item`.
        pub(super) fn depend_on_edge(&mut self, edge: EdgeType, item: ItemId) {
            let pair = (edge, item);
            if !self.edges.contains(&pair) {
                self.edges.push(pair);
            }
        }

        /// Record a dependency on `Scope::Parent` membership under `parent`.
        pub(super) fn depend_on_parent(&mut self, parent: ItemId) {
            if !self.parents.contains(&parent) {
                self.parents.push(parent);
            }
        }

        /// Record a dependency on the row `item` itself.
        pub(super) fn depend_on_item(&mut self, item: ItemId) {
            if !self.items.contains(&item) {
                self.items.push(item);
            }
        }

        /// Whether `m` can have changed this query's result.
        ///
        /// The rules, in order, each of them a *sufficient* condition:
        ///
        /// 1. a create / update / delete whose schema ref is in
        ///    [`Self::schema_refs`] — the ordinary case, and the one rule
        ///    [`Self::narrowed`] switches off;
        /// 2. any mutation of an id in [`Self::items`], whatever its schema —
        ///    the detail pane's own row, and the collection / parent /
        ///    relation anchor the query is computed from;
        /// 3. a parent change whose old or new parent is in
        ///    [`Self::parents`] — an item moving into or out of the pane;
        /// 4. a reference add / remove whose edge type AND one endpoint match
        ///    an [`Self::edges`] entry — membership and relation walks;
        /// 5. an update to a row that is an [`Self::edges`] anchor — renaming
        ///    a collection does not change its membership, but a folder move
        ///    changes what a subtree scope resolves to, and the compiler
        ///    cannot tell those apart from here;
        /// 6. an undeterminable schema ref on a create / update / delete —
        ///    conservative, and the same stance the event bus already takes.
        ///
        /// Anything else is `false`. In particular a mutation on kind A never
        /// re-runs a pane scoped to kind B, which is the property L4 exists
        /// to establish.
        pub fn is_affected_by(&self, m: &StoreMutation) -> bool {
            // Rule 2 — an id the query names literally, whatever its schema.
            if self.items.contains(&m.item_id) {
                return true;
            }

            match &m.kind {
                MutationKind::Created | MutationKind::Updated | MutationKind::Deleted => {
                    // Rule 5 — the anchor row of an edge dependency.
                    if self.edges.iter().any(|(_, anchor)| *anchor == m.item_id) {
                        return true;
                    }
                    // Rules 1 and 6 — unless the query is narrowed to the
                    // ids rule 2 just checked, in which case no third row
                    // of this kind exists to matter.
                    if self.narrowed {
                        return false;
                    }
                    match &m.schema_ref {
                        None => true,
                        Some(s) => self.schema_refs.iter().any(|r| r == s),
                    }
                }
                // Rule 3. A re-parent is NOT also a rule-1 match: an item
                // moving between two libraries neither of which this pane
                // selects cannot change what this pane shows, even though the
                // moved item is of the pane's kind.
                MutationKind::ParentChanged { old, new } => self
                    .parents
                    .iter()
                    .any(|p| Some(*p) == *old || Some(*p) == *new),
                // Rule 4. Both endpoints are checked because a walk may be
                // `Outgoing` (the anchor is the edge's source) or `Incoming`
                // (the anchor is its target), and collection membership is an
                // edge FROM the collection.
                MutationKind::ReferenceAdded {
                    edge,
                    source,
                    target,
                }
                | MutationKind::ReferenceRemoved {
                    edge,
                    source,
                    target,
                } => self
                    .edges
                    .iter()
                    .any(|(e, anchor)| e == edge && (anchor == source || anchor == target)),
            }
        }
    }

    /// The function spelling of [`CompiledQuery::invalidation`].
    ///
    /// The field is authoritative — it is computed inside `compile`, where
    /// the scopes are already resolved and cannot be re-read differently.
    /// This exists so a call site that reads as "get the invalidation for
    /// this query" can say so.
    pub fn invalidation_for(compiled: &CompiledQuery) -> &Invalidation {
        &compiled.invalidation
    }

    /// The per-pane registry L3's `layout-service` and L5's FFI hold: which
    /// subscribers depend on what, and which of them a mutation wakes.
    ///
    /// Keyed by whatever the caller uses to name a pane — `TileId` in
    /// `impress-layout`, a `String` by default.
    ///
    /// # Why a linear scan
    ///
    /// A schema-ref index would only narrow rule 1. Rules 2 to 5 are keyed
    /// on item ids and edge types, so a mutation would still have to visit
    /// every subscriber that names any item — which, for a window of
    /// sidebar, list and detail panes, is all of them. A window holds tens
    /// of panes, not thousands, and the scan is a few comparisons per pane.
    /// Insertion order is preserved so that the affected set is
    /// deterministic, which is what makes the tests readable.
    #[derive(Debug, Clone)]
    pub struct QuerySubscriptions<K = String> {
        entries: Vec<(K, Invalidation)>,
    }

    impl<K> Default for QuerySubscriptions<K> {
        fn default() -> Self {
            Self {
                entries: Vec::new(),
            }
        }
    }

    impl<K: Clone + PartialEq> QuerySubscriptions<K> {
        pub fn new() -> Self {
            Self::default()
        }

        /// Register (or replace) the dependency set for `key`. Returns the
        /// previous one, if the pane was already subscribed — a pane whose
        /// query is retyped re-registers rather than accumulating.
        pub fn insert(&mut self, key: K, invalidation: Invalidation) -> Option<Invalidation> {
            match self.entries.iter_mut().find(|(k, _)| *k == key) {
                Some(slot) => Some(std::mem::replace(&mut slot.1, invalidation)),
                None => {
                    self.entries.push((key, invalidation));
                    None
                }
            }
        }

        /// Register a pane from its compiled query.
        pub fn insert_compiled(
            &mut self,
            key: K,
            compiled: &CompiledQuery,
        ) -> Option<Invalidation> {
            self.insert(key, compiled.invalidation.clone())
        }

        /// Drop a pane's subscription (the pane was closed).
        pub fn remove(&mut self, key: &K) -> Option<Invalidation> {
            let idx = self.entries.iter().position(|(k, _)| k == key)?;
            Some(self.entries.remove(idx).1)
        }

        pub fn get(&self, key: &K) -> Option<&Invalidation> {
            self.entries.iter().find(|(k, _)| k == key).map(|(_, i)| i)
        }

        pub fn len(&self) -> usize {
            self.entries.len()
        }

        pub fn is_empty(&self) -> bool {
            self.entries.is_empty()
        }

        pub fn keys(&self) -> impl Iterator<Item = &K> {
            self.entries.iter().map(|(k, _)| k)
        }

        /// The subscribers `m` wakes, in registration order.
        pub fn affected_by(&self, m: &StoreMutation) -> Vec<K> {
            self.entries
                .iter()
                .filter(|(_, inv)| inv.is_affected_by(m))
                .map(|(k, _)| k.clone())
                .collect()
        }

        /// [`Self::affected_by`] over a batch, deduplicated: a batch of
        /// operations wakes each pane once, which is the point — coalescing
        /// here is what keeps a 500-row triage sweep from being 500 re-runs
        /// of every pane.
        pub fn affected_by_all<'a>(
            &self,
            mutations: impl IntoIterator<Item = &'a StoreMutation>,
        ) -> Vec<K> {
            let mut out: Vec<K> = Vec::new();
            let mutations: Vec<&StoreMutation> = mutations.into_iter().collect();
            for (key, inv) in &self.entries {
                if mutations.iter().any(|m| inv.is_affected_by(m)) {
                    out.push(key.clone());
                }
            }
            out
        }
    }
}

#[cfg(test)]
mod invalidation_tests {
    //! Table-driven, because the interesting content of L4 is a truth table
    //! and the only way to read a truth table is as one.

    use super::invalidation::{invalidation_for, Invalidation, QuerySubscriptions};
    use super::*;
    use crate::event::{MutationKind, StoreMutation};
    use uuid::Uuid;

    const PUBLICATION: &str = "imbib/bibliography-entry";
    const MANUSCRIPT: &str = "manuscript";
    const COLLECTION: &str = "imbib/collection";

    fn compiled(query: &PaneQuery) -> CompiledQuery {
        compile(query, &[], &Bindings::new(), &builtin_manifest()).expect("compiles")
    }

    fn inv(query: &PaneQuery) -> Invalidation {
        compiled(query).invalidation
    }

    fn mutation(id: ItemId, schema: &str, kind: MutationKind) -> StoreMutation {
        StoreMutation::new(id, Some(schema.to_string()), kind)
    }

    fn kinds(k: &[&str]) -> Vec<RecordKindId> {
        k.iter().map(|s| (*s).to_string()).collect()
    }

    // ── What compile records ─────────────────────────────────────────────

    #[test]
    fn a_kind_scoped_pane_depends_on_its_schema_refs_and_nothing_else() {
        let i = inv(&PaneQuery {
            kinds: kinds(&["publication"]),
            ..Default::default()
        });
        assert_eq!(i.schema_refs, vec![PUBLICATION.to_string()]);
        assert!(i.edges.is_empty());
        assert!(i.parents.is_empty());
        assert!(i.items.is_empty());
        assert!(!i.text);
        assert!(!i.narrowed, "a kind-scoped list is not narrowed to ids");
    }

    #[test]
    fn only_an_item_scope_is_narrowed() {
        let id = Uuid::new_v4();
        let scoped = |scope: Scope| {
            inv(&PaneQuery {
                kinds: kinds(&["publication"]),
                scope,
                ..Default::default()
            })
        };
        assert!(
            scoped(Scope::Item {
                id: ItemRef::Id { id }
            })
            .narrowed
        );
        // A collection names a fixed id too, but its population is that
        // collection's members — unbounded, so rule 1 has to keep applying.
        for scope in [
            Scope::All,
            Scope::Collection {
                id: ItemRef::Id { id },
            },
            Scope::CollectionSubtree {
                id: ItemRef::Id { id },
            },
            Scope::Parent {
                id: ItemRef::Id { id },
            },
        ] {
            assert!(!scoped(scope.clone()).narrowed, "{scope:?}");
        }
    }

    #[test]
    fn a_collection_pane_depends_on_the_contains_edge_and_on_the_collection_row() {
        let c = Uuid::new_v4();
        let i = inv(&PaneQuery {
            kinds: kinds(&["publication"]),
            scope: Scope::Collection {
                id: ItemRef::Id { id: c },
            },
            ..Default::default()
        });
        assert_eq!(i.edges, vec![(EdgeType::Contains, c)]);
        assert_eq!(i.items, vec![c]);
    }

    #[test]
    fn a_subtree_pane_depends_on_every_collection_the_resolver_named() {
        let root = Uuid::new_v4();
        let child = Uuid::new_v4();
        let grandchild = Uuid::new_v4();
        let resolver = |r: ItemId| {
            assert_eq!(r, root);
            vec![root, child, grandchild]
        };
        let c = compile_with(
            &PaneQuery {
                kinds: kinds(&["publication"]),
                scope: Scope::CollectionSubtree {
                    id: ItemRef::Id { id: root },
                },
                ..Default::default()
            },
            &[],
            &Bindings::new(),
            &builtin_manifest(),
            &resolver,
        )
        .expect("compiles");
        assert_eq!(
            c.invalidation.edges,
            vec![
                (EdgeType::Contains, root),
                (EdgeType::Contains, child),
                (EdgeType::Contains, grandchild),
            ]
        );
    }

    #[test]
    fn a_parent_pane_depends_on_the_parent() {
        let lib = Uuid::new_v4();
        let i = inv(&PaneQuery {
            kinds: kinds(&["publication"]),
            scope: Scope::Parent {
                id: ItemRef::Id { id: lib },
            },
            ..Default::default()
        });
        assert_eq!(i.parents, vec![lib]);
        assert_eq!(i.items, vec![lib]);
    }

    #[test]
    fn a_relation_walk_depends_on_its_edge_type_in_both_directions() {
        let manuscript = Uuid::new_v4();
        for direction in [Direction::Outgoing, Direction::Incoming] {
            let i = inv(&PaneQuery {
                kinds: kinds(&["publication"]),
                relation: Some(RelationWalk {
                    edge: EdgeType::Cites.into(),
                    from: ItemRef::Id { id: manuscript },
                    direction,
                }),
                ..Default::default()
            });
            assert_eq!(
                i.edges,
                vec![(EdgeType::Cites, manuscript)],
                "{direction:?}"
            );
        }
    }

    #[test]
    fn a_text_pane_records_that_it_reads_the_index() {
        assert!(
            inv(&PaneQuery {
                kinds: kinds(&["publication"]),
                text: Some("dark matter".into()),
                ..Default::default()
            })
            .text
        );
        // Whitespace is not a search term, and the compiler drops it from
        // the predicates — the dependency has to agree.
        assert!(
            !inv(&PaneQuery {
                kinds: kinds(&["publication"]),
                text: Some("   ".into()),
                ..Default::default()
            })
            .text
        );
    }

    #[test]
    fn an_unbound_parameter_records_no_dependency() {
        // The pane compiles to "matches nothing" (ADR-0031 D3), and nothing
        // is exactly what can change it: there is no collection yet.
        let i = inv(&PaneQuery {
            kinds: kinds(&["publication"]),
            scope: Scope::Collection {
                id: ItemRef::Param {
                    name: "collection".into(),
                },
            },
            ..Default::default()
        });
        assert!(i.edges.is_empty());
        assert!(i.items.is_empty());
    }

    #[test]
    fn a_bound_parameter_records_the_id_it_resolved_to() {
        let c = Uuid::new_v4();
        let compiled = compile(
            &PaneQuery {
                kinds: kinds(&["publication"]),
                scope: Scope::Collection {
                    id: ItemRef::Param {
                        name: "collection".into(),
                    },
                },
                ..Default::default()
            },
            &[ParamDecl {
                name: "collection".into(),
                kind: "collection".into(),
                required: false,
            }],
            &Bindings::new().with("collection", c),
            &builtin_manifest(),
        )
        .expect("compiles");
        assert_eq!(compiled.invalidation.edges, vec![(EdgeType::Contains, c)]);
        assert_eq!(invalidation_for(&compiled).items, vec![c]);
    }

    // ── The truth table ──────────────────────────────────────────────────

    struct Case {
        name: &'static str,
        invalidation: Invalidation,
        mutation: StoreMutation,
        affected: bool,
    }

    #[test]
    fn is_affected_by_truth_table() {
        let collection = Uuid::new_v4();
        let other_collection = Uuid::new_v4();
        let library = Uuid::new_v4();
        let other_library = Uuid::new_v4();
        let manuscript = Uuid::new_v4();
        let paper = Uuid::new_v4();
        let unrelated = Uuid::new_v4();

        let publications = || PaneQuery {
            kinds: kinds(&["publication"]),
            ..Default::default()
        };
        let in_collection = || PaneQuery {
            kinds: kinds(&["publication"]),
            scope: Scope::Collection {
                id: ItemRef::Id { id: collection },
            },
            ..Default::default()
        };
        let in_library = || PaneQuery {
            kinds: kinds(&["publication"]),
            scope: Scope::Parent {
                id: ItemRef::Id { id: library },
            },
            ..Default::default()
        };
        let one_paper = || PaneQuery {
            kinds: kinds(&["publication"]),
            scope: Scope::Item {
                id: ItemRef::Id { id: paper },
            },
            ..Default::default()
        };
        let cited_by = || PaneQuery {
            kinds: kinds(&["publication"]),
            relation: Some(RelationWalk {
                edge: EdgeType::Cites.into(),
                from: ItemRef::Id { id: manuscript },
                direction: Direction::Outgoing,
            }),
            ..Default::default()
        };
        let manuscripts = || PaneQuery {
            kinds: kinds(&["manuscript"]),
            ..Default::default()
        };

        let cases = vec![
            // ── Rule 1: the schema ref ───────────────────────────────────
            Case {
                name: "a new publication invalidates the publication list",
                invalidation: inv(&publications()),
                mutation: mutation(unrelated, PUBLICATION, MutationKind::Created),
                affected: true,
            },
            Case {
                name: "an updated publication invalidates the publication list",
                invalidation: inv(&publications()),
                mutation: mutation(unrelated, PUBLICATION, MutationKind::Updated),
                affected: true,
            },
            Case {
                name: "a deleted publication invalidates the publication list",
                invalidation: inv(&publications()),
                mutation: mutation(unrelated, PUBLICATION, MutationKind::Deleted),
                affected: true,
            },
            // THE negative case the plan names (L4's row of the WP table):
            // "a mutation on kind A does not re-run a pane scoped to kind B".
            Case {
                name: "a manuscript mutation does NOT invalidate a publication pane",
                invalidation: inv(&publications()),
                mutation: mutation(unrelated, MANUSCRIPT, MutationKind::Created),
                affected: false,
            },
            Case {
                name: "a publication mutation does NOT invalidate a manuscript pane",
                invalidation: inv(&manuscripts()),
                mutation: mutation(unrelated, PUBLICATION, MutationKind::Updated),
                affected: false,
            },
            Case {
                name: "an operation-journal row does NOT invalidate a publication pane",
                invalidation: inv(&publications()),
                mutation: mutation(unrelated, "core/operation", MutationKind::Created),
                affected: false,
            },
            // ── Rule 2: an id the query names ────────────────────────────
            Case {
                name: "the detail pane's own row, updated",
                invalidation: inv(&one_paper()),
                mutation: mutation(paper, PUBLICATION, MutationKind::Updated),
                affected: true,
            },
            Case {
                name: "the detail pane's own row, deleted",
                invalidation: inv(&one_paper()),
                mutation: mutation(paper, PUBLICATION, MutationKind::Deleted),
                affected: true,
            },
            // The `narrowed` refinement. An `Item`-scope pane carries its
            // kind's schema refs because that is what it returns, but it can
            // never show a second row, so rule 1 is switched off for it —
            // and the detail pane is the one pane every window has, hosting
            // the most expensive view in the suite.
            Case {
                name: "another publication does NOT invalidate a narrowed pane",
                invalidation: inv(&one_paper()),
                mutation: mutation(unrelated, PUBLICATION, MutationKind::Updated),
                affected: false,
            },
            Case {
                name: "a narrowed pane still wakes for an edge at its own row",
                invalidation: inv(&one_paper()),
                mutation: mutation(
                    paper,
                    PUBLICATION,
                    MutationKind::ReferenceAdded {
                        edge: EdgeType::Cites,
                        source: paper,
                        target: unrelated,
                    },
                ),
                affected: true,
            },
            // An unbound detail pane is narrowed to the EMPTY set: it
            // compiles to "matches nothing" and stays empty until its
            // binding changes, and a binding change is a recompile rather
            // than an invalidation.
            Case {
                name: "a narrowed pane with no binding yet wakes for nothing",
                invalidation: inv(&PaneQuery {
                    kinds: kinds(&["publication"]),
                    scope: Scope::Item {
                        id: ItemRef::Param {
                            name: "item".into(),
                        },
                    },
                    ..Default::default()
                }),
                mutation: mutation(unrelated, PUBLICATION, MutationKind::Created),
                affected: false,
            },
            // ── Rule 5: the anchor row, whatever its schema ──────────────
            Case {
                name: "the scoped collection row itself, updated (a move may \
                       change what the subtree resolves to)",
                invalidation: inv(&in_collection()),
                mutation: mutation(collection, COLLECTION, MutationKind::Updated),
                affected: true,
            },
            Case {
                name: "a DIFFERENT collection row does NOT invalidate the pane",
                invalidation: inv(&in_collection()),
                mutation: mutation(other_collection, COLLECTION, MutationKind::Updated),
                affected: false,
            },
            // ── Rule 4: edges ────────────────────────────────────────────
            Case {
                name: "filing a paper into the scoped collection",
                invalidation: inv(&in_collection()),
                mutation: mutation(
                    collection,
                    COLLECTION,
                    MutationKind::ReferenceAdded {
                        edge: EdgeType::Contains,
                        source: collection,
                        target: unrelated,
                    },
                ),
                affected: true,
            },
            Case {
                name: "unfiling a paper from the scoped collection",
                invalidation: inv(&in_collection()),
                mutation: mutation(
                    collection,
                    COLLECTION,
                    MutationKind::ReferenceRemoved {
                        edge: EdgeType::Contains,
                        source: collection,
                        target: unrelated,
                    },
                ),
                affected: true,
            },
            Case {
                name: "filing into ANOTHER collection does not invalidate",
                invalidation: inv(&in_collection()),
                mutation: mutation(
                    other_collection,
                    COLLECTION,
                    MutationKind::ReferenceAdded {
                        edge: EdgeType::Contains,
                        source: other_collection,
                        target: unrelated,
                    },
                ),
                affected: false,
            },
            Case {
                name: "the RIGHT anchor with the WRONG edge type does not invalidate",
                invalidation: inv(&in_collection()),
                mutation: mutation(
                    collection,
                    COLLECTION,
                    MutationKind::ReferenceAdded {
                        edge: EdgeType::RelatesTo,
                        source: unrelated,
                        target: unrelated,
                    },
                ),
                affected: true, // rule 5: the anchor row is `collection`
            },
            Case {
                name: "the right edge type at the anchor's TARGET end invalidates",
                invalidation: inv(&cited_by()),
                mutation: mutation(
                    unrelated,
                    MANUSCRIPT,
                    MutationKind::ReferenceAdded {
                        edge: EdgeType::Cites,
                        source: unrelated,
                        target: manuscript,
                    },
                ),
                affected: true,
            },
            Case {
                name: "a Cites edge between two strangers does not invalidate the walk",
                invalidation: inv(&cited_by()),
                mutation: mutation(
                    unrelated,
                    MANUSCRIPT,
                    MutationKind::ReferenceAdded {
                        edge: EdgeType::Cites,
                        source: unrelated,
                        target: other_collection,
                    },
                ),
                affected: false,
            },
            Case {
                name: "a Contains edge does not invalidate a Cites walk",
                invalidation: inv(&cited_by()),
                mutation: mutation(
                    manuscript,
                    MANUSCRIPT,
                    MutationKind::ReferenceAdded {
                        edge: EdgeType::Contains,
                        source: manuscript,
                        target: unrelated,
                    },
                ),
                affected: true, // rule 5 again: `manuscript` is the anchor row
            },
            // ── Rule 3: parents ──────────────────────────────────────────
            Case {
                name: "a paper moved INTO the scoped library",
                invalidation: inv(&in_library()),
                mutation: mutation(
                    unrelated,
                    PUBLICATION,
                    MutationKind::ParentChanged {
                        old: Some(other_library),
                        new: Some(library),
                    },
                ),
                affected: true,
            },
            Case {
                name: "a paper moved OUT of the scoped library",
                invalidation: inv(&in_library()),
                mutation: mutation(
                    unrelated,
                    PUBLICATION,
                    MutationKind::ParentChanged {
                        old: Some(library),
                        new: None,
                    },
                ),
                affected: true,
            },
            Case {
                name: "a move between two libraries this pane does not select — \
                       and of the pane's OWN kind, which rule 1 would have \
                       caught if a re-parent were an ordinary update",
                invalidation: inv(&in_library()),
                mutation: mutation(
                    unrelated,
                    PUBLICATION,
                    MutationKind::ParentChanged {
                        old: Some(other_library),
                        new: Some(other_collection),
                    },
                ),
                affected: false,
            },
            Case {
                name: "a re-parent does not invalidate an unscoped kind pane",
                invalidation: inv(&publications()),
                mutation: mutation(
                    unrelated,
                    PUBLICATION,
                    MutationKind::ParentChanged {
                        old: None,
                        new: Some(library),
                    },
                ),
                affected: false,
            },
            // ── Rule 6: undeterminable schema ────────────────────────────
            Case {
                name: "a schemaless delete is conservatively taken as affecting",
                invalidation: inv(&publications()),
                mutation: StoreMutation::new(unrelated, None, MutationKind::Deleted),
                affected: true,
            },
        ];

        for case in cases {
            assert_eq!(
                case.invalidation.is_affected_by(&case.mutation),
                case.affected,
                "{}",
                case.name
            );
        }
    }

    #[test]
    fn a_multi_ref_kind_matches_every_one_of_its_refs() {
        // `message` spans email and chat; a pane over it must wake for both.
        let i = inv(&PaneQuery {
            kinds: kinds(&["message"]),
            ..Default::default()
        });
        for r in ["email-message", "chat-message"] {
            assert!(
                i.is_affected_by(&mutation(Uuid::new_v4(), r, MutationKind::Created)),
                "{r}"
            );
        }
        assert!(!i.is_affected_by(&mutation(
            Uuid::new_v4(),
            PUBLICATION,
            MutationKind::Created
        )));
    }

    #[test]
    fn an_unkinded_pane_wakes_for_every_kind_in_the_manifest() {
        let i = inv(&PaneQuery::default());
        for r in [PUBLICATION, MANUSCRIPT, COLLECTION, "task@1.0.0"] {
            assert!(
                i.is_affected_by(&mutation(Uuid::new_v4(), r, MutationKind::Created)),
                "{r}"
            );
        }
        // Still not the journal: `core/operation` is in no kind's manifest
        // entry, and an operation row per mutation would be the render loop
        // D9 warns about, exactly.
        assert!(!i.is_affected_by(&mutation(
            Uuid::new_v4(),
            "core/operation",
            MutationKind::Created
        )));
    }

    #[test]
    fn invalidation_serde_round_trip() {
        let i = inv(&PaneQuery {
            kinds: kinds(&["publication"]),
            scope: Scope::Collection {
                id: ItemRef::Id { id: Uuid::new_v4() },
            },
            text: Some("dark matter".into()),
            ..Default::default()
        });
        let json = serde_json::to_string(&i).expect("serialize");
        let back: Invalidation = serde_json::from_str(&json).expect("deserialize");
        assert_eq!(i, back);
    }

    // ── The registry ─────────────────────────────────────────────────────

    #[test]
    fn subscriptions_return_only_the_affected_panes() {
        let collection = Uuid::new_v4();
        let paper = Uuid::new_v4();

        let mut subs: QuerySubscriptions<&'static str> = QuerySubscriptions::new();
        subs.insert(
            "sidebar",
            inv(&PaneQuery {
                kinds: kinds(&["collection"]),
                ..Default::default()
            }),
        );
        subs.insert(
            "list",
            inv(&PaneQuery {
                kinds: kinds(&["publication"]),
                scope: Scope::Collection {
                    id: ItemRef::Id { id: collection },
                },
                ..Default::default()
            }),
        );
        subs.insert(
            "detail",
            inv(&PaneQuery {
                kinds: kinds(&["publication"]),
                scope: Scope::Item {
                    id: ItemRef::Id { id: paper },
                },
                ..Default::default()
            }),
        );
        subs.insert(
            "manuscripts",
            inv(&PaneQuery {
                kinds: kinds(&["manuscript"]),
                ..Default::default()
            }),
        );
        assert_eq!(subs.len(), 4);

        // Filing a paper into the open collection: the sidebar (the
        // collection row is of kind `collection`) and the list wake; the
        // detail pane and the manuscript pane do not.
        let filed = mutation(
            collection,
            COLLECTION,
            MutationKind::ReferenceAdded {
                edge: EdgeType::Contains,
                source: collection,
                target: paper,
            },
        );
        assert_eq!(subs.affected_by(&filed), vec!["list"]);

        // Editing the selected paper: the list (kind match) and the detail
        // pane (its own row), not the sidebar, not the manuscripts.
        let edited = mutation(paper, PUBLICATION, MutationKind::Updated);
        assert_eq!(subs.affected_by(&edited), vec!["list", "detail"]);

        // A manuscript save wakes only the manuscript pane.
        let saved = mutation(Uuid::new_v4(), MANUSCRIPT, MutationKind::Updated);
        assert_eq!(subs.affected_by(&saved), vec!["manuscripts"]);

        // A batch wakes each pane once, in registration order.
        assert_eq!(
            subs.affected_by_all([&filed, &edited, &saved]),
            vec!["list", "detail", "manuscripts"]
        );
    }

    #[test]
    fn re_registering_a_pane_replaces_its_dependency_set() {
        let a = Uuid::new_v4();
        let b = Uuid::new_v4();
        let mut subs: QuerySubscriptions<&'static str> = QuerySubscriptions::new();
        let first = inv(&PaneQuery {
            kinds: kinds(&["publication"]),
            scope: Scope::Item {
                id: ItemRef::Id { id: a },
            },
            ..Default::default()
        });
        assert!(subs.insert("detail", first.clone()).is_none());
        let previous = subs.insert_compiled(
            "detail",
            &compiled(&PaneQuery {
                kinds: kinds(&["publication"]),
                scope: Scope::Item {
                    id: ItemRef::Id { id: b },
                },
                ..Default::default()
            }),
        );
        assert_eq!(previous, Some(first));
        assert_eq!(subs.len(), 1, "a retyped pane does not accumulate");
        assert_eq!(subs.get(&"detail").expect("registered").items, vec![b]);
        assert_eq!(subs.keys().copied().collect::<Vec<_>>(), vec!["detail"]);

        // A closed pane stops waking.
        assert!(subs.remove(&"detail").is_some());
        assert!(subs.is_empty());
        assert!(subs
            .affected_by(&mutation(b, PUBLICATION, MutationKind::Updated))
            .is_empty());
    }
}
