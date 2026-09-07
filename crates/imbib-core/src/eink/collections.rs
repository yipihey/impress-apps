//! The library/collection tree, read once per sync.
//!
//! A collection's tree parent is the payload `parent_id`; `item.parent` is
//! the owning library (the two-axis trap imbib's CLAUDE.md warns about).
//! This index walks `parent_id` only.

use std::collections::HashMap;

use impress_core::collection_ops::{self, IMBIB_COLLECTION};

use crate::unified::store_api::{ImbibStore, StoreApiError};

#[derive(Debug, Clone)]
struct Node {
    name: String,
    parent_id: Option<String>,
    container_id: Option<String>,
}

/// Every collection, keyed by id.
#[derive(Debug, Clone, Default)]
pub struct CollectionIndex {
    nodes: HashMap<String, Node>,
    /// Library id → (name, is_inbox).
    libraries: HashMap<String, (String, bool)>,
}

impl CollectionIndex {
    pub fn load(store: &ImbibStore) -> Result<Self, StoreApiError> {
        let rows = collection_ops::list_tree_in(&store.store, &IMBIB_COLLECTION, None)?;
        let nodes = rows
            .into_iter()
            .map(|row| {
                (
                    row.id.clone(),
                    Node {
                        name: row.name,
                        parent_id: row.parent_id,
                        container_id: row.container_id,
                    },
                )
            })
            .collect();
        let libraries = store
            .list_libraries()?
            .into_iter()
            .map(|library| (library.id.to_lowercase(), (library.name, library.is_inbox)))
            .collect();
        Ok(Self { nodes, libraries })
    }

    /// The chain of names from a top-level collection down to `id`.
    pub fn chain(&self, id: &str) -> Vec<String> {
        let mut chain = Vec::new();
        let mut current = Some(id.to_lowercase());
        let mut guard = 0;
        while let Some(node_id) = current {
            let Some(node) = self.nodes.get(&node_id) else {
                break;
            };
            chain.push(node.name.clone());
            current = node.parent_id.as_ref().map(|p| p.to_lowercase());
            guard += 1;
            if guard > 64 {
                break;
            }
        }
        chain.reverse();
        chain
    }

    /// The library a collection belongs to.
    pub fn library_of(&self, id: &str) -> Option<&str> {
        self.nodes
            .get(&id.to_lowercase())
            .and_then(|node| node.container_id.as_deref())
    }

    pub fn library_name(&self, library_id: &str) -> Option<&str> {
        self.libraries
            .get(&library_id.to_lowercase())
            .map(|(name, _)| name.as_str())
    }

    pub fn library_is_inbox(&self, library_id: &str) -> bool {
        self.libraries
            .get(&library_id.to_lowercase())
            .map(|(_, inbox)| *inbox)
            .unwrap_or(false)
    }

    /// Every collection path a publication is filed under, sorted so the
    /// first is the deterministic mirror target.
    pub fn paths_for(&self, collection_ids: &[String]) -> Vec<Vec<String>> {
        let mut paths: Vec<Vec<String>> = collection_ids
            .iter()
            .map(|id| self.chain(id))
            .filter(|chain| !chain.is_empty())
            .collect();
        paths.sort();
        paths.dedup();
        paths
    }
}

impl ImbibStore {
    /// The ids of the collections that contain a publication.
    pub fn eink_collection_ids_for(
        &self,
        publication_id: &str,
    ) -> Result<Vec<String>, StoreApiError> {
        Ok(collection_ops::collections_containing_ids(
            &self.store,
            &IMBIB_COLLECTION,
            publication_id,
        )?)
    }
}
