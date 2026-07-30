//! Store overviews — the data behind the MCP *resources* (ADR-0022 D5 / G6).
//!
//! Everything else in this crate is a tool: an agent calls it with arguments
//! and gets an answer. These two are the other half of the MCP surface — a
//! client *fetches* them, unprompted, to find out what is in the store before
//! it asks anything. `impress-mcp` serves them at `impress://store/schemas`
//! and `impress://store/collections`, next to `impress://guide`.
//!
//! They live here, not in `impress-mcp`, for one reason: the store knowledge
//! belongs beside the services that already hold it, and a plain function over
//! an injected `&SqliteItemStore` is testable against a temp database, which
//! the MCP server's process-wide singleton is not.
//!
//! Neither is a service method. A resource is not a verb, and ADR-0022 D5's
//! rule ("only service-backed ops are exposed") is about the *tool* surface —
//! adding a `list_schemas` tool that duplicates a resource would be exactly
//! the two-definitions-of-one-capability drift the Rust-first rule exists to
//! prevent. `list_items` is the tool for reading rows; these describe the
//! shape of the store around them.

use impress_core::collection_ops;
use impress_core::registry::SchemaRegistry;
use impress_core::schemas::register_core_schemas;
use impress_core::sqlite_store::SqliteItemStore;
use impress_core::store::StoreError;
use serde::{Deserialize, Serialize};

use crate::collection_service::{binding_for, BINDING_NAMES};

// ---------------------------------------------------------------------------
// impress://store/schemas
// ---------------------------------------------------------------------------

/// One record kind, as the store actually holds it.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SchemaRow {
    /// The exact string to pass to `store-query-service_list-items`, and the
    /// one `store-query-service_search-all` reports on every hit.
    pub schema_ref: String,
    /// Human name from the registry; absent for a kind the registry does not
    /// know about.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub version: Option<String>,
    /// The schema this one extends, if any — its fields apply too.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub inherits: Option<String>,
    /// False when the store holds rows of a kind `impress-core` never
    /// registered. That is not an error — apps write their own kinds — but it
    /// means no field list and no validation, so it is stated rather than
    /// hidden.
    pub registered: bool,
    /// Live count of rows of this kind.
    pub item_count: u32,
    /// Payload field names declared by this schema (not including inherited
    /// ones — follow `inherits` for those). Empty for unregistered kinds.
    pub fields: Vec<String>,
}

/// Every record kind in the store, with live counts.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SchemaOverview {
    /// The `impress.sqlite` these counts came from — the same file the tools
    /// mutate, so `--store-path` is visible rather than assumed.
    pub store_path: String,
    /// Rows of every kind, all schemas.
    pub total_items: u32,
    /// Kinds that have at least one row first (most populous first), then the
    /// registered-but-empty ones alphabetically. What is *in* the store leads;
    /// what could be is still listed.
    pub schemas: Vec<SchemaRow>,
    pub note: String,
}

/// Every registered schema plus every kind the store actually holds, with
/// per-kind counts read live.
pub fn schema_overview(
    store: &SqliteItemStore,
    store_path: &str,
) -> Result<SchemaOverview, StoreError> {
    let counts: Vec<(String, i64)> = store.query_raw(
        "SELECT schema_ref, COUNT(*) FROM items GROUP BY schema_ref",
        &[],
        |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?)),
    )?;

    let mut registry = SchemaRegistry::new();
    register_core_schemas(&mut registry);
    let mut registered: Vec<&impress_core::schema::Schema> = registry.list();
    registered.sort_by(|a, b| a.id.cmp(&b.id));

    let count_of = |schema_ref: &str| -> u32 {
        counts
            .iter()
            .find(|(r, _)| r == schema_ref)
            .map(|(_, n)| (*n).max(0) as u32)
            .unwrap_or(0)
    };

    let mut rows: Vec<SchemaRow> = registered
        .iter()
        .map(|schema| SchemaRow {
            schema_ref: schema.id.clone(),
            name: Some(schema.name.clone()),
            version: Some(schema.version.clone()),
            inherits: schema.inherits.clone(),
            registered: true,
            item_count: count_of(&schema.id),
            fields: schema.fields.iter().map(|f| f.name.clone()).collect(),
        })
        .collect();

    // Kinds the store holds that the registry has never heard of — imbib's
    // `imbib/collection`, an app's private kind, a schema from a newer build.
    // Omitting them would make this resource lie about what `list_items` can
    // browse, which is the one thing it exists to answer.
    for (schema_ref, n) in &counts {
        if !rows.iter().any(|r| &r.schema_ref == schema_ref) {
            rows.push(SchemaRow {
                schema_ref: schema_ref.clone(),
                name: None,
                version: None,
                inherits: None,
                registered: false,
                item_count: (*n).max(0) as u32,
                fields: vec![],
            });
        }
    }

    // Populous kinds first — that is the order someone browsing wants — then
    // schema_ref for a stable tiebreak, so the resource does not churn.
    rows.sort_by(|a, b| {
        b.item_count
            .cmp(&a.item_count)
            .then_with(|| a.schema_ref.cmp(&b.schema_ref))
    });

    Ok(SchemaOverview {
        store_path: store_path.to_string(),
        total_items: counts.iter().map(|(_, n)| (*n).max(0) as u32).sum(),
        schemas: rows,
        note: "Pass a `schema_ref` to store-query-service_list-items to browse one kind, or \
               an empty string for every kind; store-query-service_get-item opens one row. \
               `registered: false` means impress-core has no schema for that kind — the rows \
               are still readable, there is just no declared field list."
            .to_string(),
    })
}

// ---------------------------------------------------------------------------
// impress://store/collections
// ---------------------------------------------------------------------------

/// One collection, with its live member count.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CollectionNode {
    pub id: String,
    pub name: String,
    /// Parent COLLECTION id, or null for a root. Build the tree from this.
    pub parent_id: Option<String>,
    pub sort_order: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub kind_scope: Option<String>,
    pub member_count: u32,
}

/// One hierarchy: the `binding` name a tool takes, and its whole tree.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BindingTree {
    /// The exact `binding` argument every `collection-service_*` tool takes.
    pub binding: String,
    /// The `schema_ref` this hierarchy's collection rows are ACTUALLY stored
    /// under right now. Normally the legacy one; once the store has converged
    /// on `collection@1.0.0` (ADR-0022 WP G7) every binding reports
    /// `collection` and the hierarchy is told apart by `kind_scope`.
    pub schema_ref: String,
    pub collection_count: u32,
    pub collections: Vec<CollectionNode>,
    /// Set only when this one hierarchy could not be read. The other three
    /// still answer — a single broken binding must not blank the resource.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

/// All four collection hierarchies at once.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CollectionsOverview {
    pub store_path: String,
    pub bindings: Vec<BindingTree>,
    pub note: String,
}

/// The four bindings' trees, flat per binding, with member counts.
pub fn collection_overview(store: &SqliteItemStore, store_path: &str) -> CollectionsOverview {
    let mut bindings = Vec::with_capacity(BINDING_NAMES.len());

    for name in BINDING_NAMES {
        let binding = match binding_for(name) {
            Ok(b) => b,
            // Unreachable unless BINDING_NAMES and binding_for drift apart,
            // which is exactly when saying so beats a silent omission.
            Err(e) => {
                bindings.push(BindingTree {
                    binding: name.to_string(),
                    schema_ref: String::new(),
                    collection_count: 0,
                    collections: vec![],
                    error: Some(e),
                });
                continue;
            }
        };

        // Resolved against the convergence marker, so the resource describes
        // where the rows really live rather than where they used to.
        let stored_schema_ref = collection_ops::resolve(store, &binding)
            .map(|r| r.schema_ref)
            .unwrap_or(binding.schema_ref)
            .to_string();

        let rows = match collection_ops::list_tree(store, &binding) {
            Ok(rows) => rows,
            Err(e) => {
                bindings.push(BindingTree {
                    binding: name.to_string(),
                    schema_ref: stored_schema_ref,
                    collection_count: 0,
                    collections: vec![],
                    error: Some(e.to_string()),
                });
                continue;
            }
        };

        let ids: Vec<String> = rows.iter().map(|r| r.id.clone()).collect();
        // A count failure loses the counts, not the tree: knowing a collection
        // exists is most of the value here.
        let counts = collection_ops::member_counts(store, &binding, &ids).unwrap_or_default();

        let collections: Vec<CollectionNode> = rows
            .into_iter()
            .enumerate()
            .map(|(i, row)| CollectionNode {
                id: row.id,
                name: row.name,
                parent_id: row.parent_id,
                sort_order: row.sort_order,
                kind_scope: row.kind_scope,
                member_count: counts.get(i).copied().unwrap_or(0),
            })
            .collect();

        bindings.push(BindingTree {
            binding: name.to_string(),
            schema_ref: stored_schema_ref,
            collection_count: collections.len() as u32,
            collections,
            error: None,
        });
    }

    CollectionsOverview {
        store_path: store_path.to_string(),
        bindings,
        note: "Every collection-service_* tool takes one of these `binding` values. Nesting is \
               `parent_id` (null = root), NOT the envelope parent. Members are listed by \
               collection-service_member-counts and changed by _add-members / _remove-members; \
               deleting a collection never deletes its members."
            .to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::collection_service::{CollectionService, DefaultCollectionService};
    use crate::test_support::{make_item_named, test_store};

    #[test]
    fn schema_overview_counts_what_the_store_holds_and_names_what_it_could() {
        let store = test_store();
        make_item_named(&store, "manuscript", "Draft I");
        make_item_named(&store, "manuscript", "Draft II");
        make_item_named(&store, "figure", "Panel A");
        // A kind impress-core never registered — apps write these.
        make_item_named(&store, "imbib/collection", "Reading");

        let out = schema_overview(&store, "/tmp/impress.sqlite").expect("overview");
        assert_eq!(out.store_path, "/tmp/impress.sqlite");
        assert_eq!(out.total_items, 4);

        let row = |r: &str| -> SchemaRow {
            out.schemas
                .iter()
                .find(|s| s.schema_ref == r)
                .unwrap_or_else(|| panic!("{r} missing from {:?}", out.schemas))
                .clone()
        };

        let manuscript = row("manuscript");
        assert_eq!(manuscript.item_count, 2);
        assert!(manuscript.registered);
        assert!(
            manuscript.fields.contains(&"title".to_string()),
            "a registered kind must publish its field names: {:?}",
            manuscript.fields
        );
        assert_eq!(row("figure").item_count, 1);

        // Unregistered kinds are listed, honestly labelled — omitting them
        // would make the resource lie about what list_items can browse.
        let unregistered = row("imbib/collection");
        assert!(!unregistered.registered);
        assert_eq!(unregistered.item_count, 1);
        assert!(unregistered.fields.is_empty());

        // Registered-but-empty kinds are still discoverable. (`task@1.0.0` is
        // the canonical spelling since ADR-0022 C4 unified the three task-ref
        // spellings; the bare `task` registration was deleted with them.)
        let empty = row("task@1.0.0");
        assert!(empty.registered);
        assert_eq!(empty.item_count, 0);

        // Populous first.
        assert_eq!(out.schemas[0].schema_ref, "manuscript");
        assert!(out
            .schemas
            .windows(2)
            .all(|w| w[0].item_count >= w[1].item_count));
    }

    #[test]
    fn schema_overview_is_empty_but_valid_on_a_fresh_store() {
        let store = test_store();
        let out = schema_overview(&store, "/tmp/x.sqlite").expect("overview");
        assert_eq!(out.total_items, 0);
        assert!(
            out.schemas.iter().all(|s| s.item_count == 0),
            "an empty store has no rows"
        );
        assert!(
            out.schemas.len() > 10,
            "the registered kinds are still worth naming: {}",
            out.schemas.len()
        );
    }

    #[tokio::test]
    async fn collection_overview_covers_all_four_bindings_with_counts() {
        let store = test_store();
        let svc = DefaultCollectionService::with_store(store.clone());

        let created = svc
            .create("generic".into(), "Mixed".into(), None, Some("any".into()))
            .await;
        let mixed = created.collection.expect("created").id;
        let paper = make_item_named(&store, "imbib/bibliography-entry", "Zwicky 1933");
        let figure = make_item_named(&store, "figure", "Rotation curve");
        let added = svc
            .add_members("generic".into(), mixed.clone(), vec![paper, figure])
            .await;
        assert!(added.ok, "{}", added.message);

        let out = collection_overview(&store, "/tmp/impress.sqlite");
        let names: Vec<&str> = out.bindings.iter().map(|b| b.binding.as_str()).collect();
        assert_eq!(
            names,
            vec!["imbib", "manuscript", "figure", "generic"],
            "every binding a tool accepts must appear, in the documented order"
        );
        assert!(
            out.bindings.iter().all(|b| b.error.is_none()),
            "{:?}",
            out.bindings
        );

        let generic = out.bindings.last().unwrap();
        assert_eq!(generic.schema_ref, "collection");
        assert_eq!(generic.collection_count, 1);
        let node = &generic.collections[0];
        assert_eq!(node.id, mixed);
        assert_eq!(node.name, "Mixed");
        assert!(node.parent_id.is_none(), "a root has no parent");
        assert_eq!(node.kind_scope.as_deref(), Some("any"));
        assert_eq!(node.member_count, 2, "counts are live, and mixed-kind");

        // The hierarchies a user has not touched are empty, not missing.
        assert!(out
            .bindings
            .iter()
            .filter(|b| b.binding != "generic")
            .all(|b| b.collections.is_empty()));
    }

    #[tokio::test]
    async fn collection_overview_reports_nesting_so_a_tree_can_be_rebuilt() {
        let store = test_store();
        let svc = DefaultCollectionService::with_store(store.clone());
        let root = svc
            .create("imbib".into(), "Reading".into(), None, None)
            .await
            .collection
            .expect("root")
            .id;
        let child = svc
            .create("imbib".into(), "Queue".into(), Some(root.clone()), None)
            .await
            .collection
            .expect("child")
            .id;

        let out = collection_overview(&store, "/tmp/impress.sqlite");
        let imbib = out
            .bindings
            .iter()
            .find(|b| b.binding == "imbib")
            .expect("imbib binding");
        assert_eq!(imbib.collection_count, 2);
        let found = imbib
            .collections
            .iter()
            .find(|c| c.id == child)
            .expect("the child");
        assert_eq!(
            found.parent_id.as_deref(),
            Some(root.as_str()),
            "nesting travels through parent_id, which is how a client rebuilds the tree"
        );
    }
}
