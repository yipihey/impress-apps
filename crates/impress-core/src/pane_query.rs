//! The pane query algebra (ADR-0031 D2).
//!
//! The algebra's *types* — [`PaneQuery`] and everything it is built from —
//! live in [`impress_pane_query`], and the compiler that lowers a query onto
//! the item protocol (with its [`invalidation`] module) lives in
//! [`impress_pane_query_compile`] (docs/plan-koine-host.md H-D2, tested there
//! on the memory store). Both are re-exported below so every
//! `impress_core::pane_query::X` path keeps resolving. What stays here is
//! what is NOT product-neutral:
//!
//! - [`builtin_manifest`], the chassis's built-in [`KindManifest`] — domain
//!   data, because it names impress's own schema refs, not a property of the
//!   algebra a standalone host would share. The compiler takes the manifest
//!   as a parameter, so a bespoke app passes its own;
//! - the tests that run a compiled query against `SqliteItemStore` and the
//!   real `collection_ops` edges.
//!
//! # Entry points
//!
//! [`compile`] is the whole surface; [`compile_with`] is the same thing plus a
//! [`SubtreeResolver`], which [`Scope::CollectionSubtree`] needs because the
//! collection tree lives in the store and the compiler is pure.
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

use std::collections::BTreeMap;

// Every algebra type, re-exported so `impress_core::pane_query::X` keeps
// resolving for existing callers (ADR-0033 D7's compatibility rule). `ItemId`
// is deliberately NOT re-exported: it would collide with `crate::item::ItemId`
// and there is nothing to gain — the two are the same `Uuid` alias (see
// `impress_pane_query`'s module docs). `EdgeType` is deliberately NOT
// re-exported either: it is a distinct type from `crate::reference::EdgeType`
// and no path in this crate should resolve `pane_query::EdgeType` ambiguously.
pub use impress_pane_query::{
    params_in, Bindings, Direction, Filter, ItemRef, KindManifest, PaneQuery, PaneQueryError,
    ParamDecl, ParamName, RecordKindId, RelationWalk, Scope, SortKey,
};

// The compiler and the invalidation rules (H-D2), moved to koine.
pub use impress_pane_query_compile::{
    compile, compile_with, invalidation, CompiledQuery, SubtreeResolver,
};

/// The chassis's built-in record kinds.
///
/// The references below are generated from the `canonical` table of
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
        (
            "publication",
            vec![crate::schema::refs::IMBIB_BIBLIOGRAPHY_ENTRY],
        ),
        ("manuscript", vec![crate::schema::refs::MANUSCRIPT]),
        ("figure", vec![crate::schema::refs::FIGURE]),
        (
            "message",
            vec![
                crate::schema::refs::EMAIL_MESSAGE,
                crate::schema::refs::CHAT_MESSAGE,
            ],
        ),
        ("task", vec![crate::schema::refs::TASK]),
        ("agent-run", vec![crate::schema::refs::AGENT_RUN]),
        (
            "artifact",
            vec![
                crate::schema::refs::IMPRESS_ARTIFACT_CODE,
                crate::schema::refs::IMPRESS_ARTIFACT_DATASET,
                crate::schema::refs::IMPRESS_ARTIFACT_GENERAL,
                crate::schema::refs::IMPRESS_ARTIFACT_MEDIA,
                crate::schema::refs::IMPRESS_ARTIFACT_NOTE,
                crate::schema::refs::IMPRESS_ARTIFACT_POSTER,
                crate::schema::refs::IMPRESS_ARTIFACT_PRESENTATION,
                crate::schema::refs::IMPRESS_ARTIFACT_WEBPAGE,
            ],
        ),
        // Navigable kinds the sidebar itself is made of. `collection`
        // spans the generic kernel schema and the three legacy bindings
        // (ADR-0022 D2 dual mode): a collection pane must find both
        // sides of the `collections.unified` flip.
        (
            "collection",
            vec![
                crate::schema::refs::COLLECTION,
                crate::schema::refs::IMBIB_COLLECTION,
                crate::schema::refs::MANUSCRIPT_COLLECTION,
                crate::schema::refs::FIGURE_COLLECTION,
            ],
        ),
        ("library", vec![crate::schema::refs::IMBIB_LIBRARY]),
        // ADR-0033 D1: a surface pane's query is `item(id)` of this kind, so
        // `surface_show` (impress-surface-service, S4) can compile a query
        // naming it the same way every other detail pane names its kind.
        ("surface", vec![crate::schema::refs::IMPRESS_UI_SURFACE]),
    ]
    .into_iter()
    .map(|(kind, refs)| {
        (
            kind.to_string(),
            refs.into_iter().map(String::from).collect(),
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
// Store-backed: the compiled query run against real rows
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(all(test, feature = "sqlite"))]
mod store_tests {
    use super::*;
    use crate::collection_ops::{self, GENERIC_COLLECTION};
    use crate::item::{Item, ItemId, Priority, Value, Visibility};
    use crate::reference::{EdgeType, TypedReference};
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
            schema: crate::SchemaRef::from_stored(schema_of_row.to_owned()),
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
