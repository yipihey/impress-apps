use std::path::Path;
use std::sync::Arc;

use chrono::Utc;
use impress_core::item::{FlagState, Value};
use impress_core::query::{ItemQuery, Predicate, SortDescriptor};
use impress_core::reference::EdgeType;
use impress_core::store::{FieldMutation, ItemStore};
use impress_core::SqliteItemStore;
use uuid::Uuid;

use super::conversion;
use super::schemas;
use super::shaped_queries::*;  // includes ArtifactRow, ArtifactRelation, item_to_artifact_row

/// Error type for the store API, exposed via UniFFI.
#[derive(Debug, thiserror::Error)]
#[cfg_attr(feature = "native", derive(uniffi::Error))]
pub enum StoreApiError {
    #[error("Not found: {0}")]
    NotFound(String),
    #[error("Already exists: {0}")]
    AlreadyExists(String),
    #[error("Invalid input: {0}")]
    InvalidInput(String),
    #[error("Storage error: {0}")]
    Storage(String),
}

impl From<impress_core::StoreError> for StoreApiError {
    fn from(e: impress_core::StoreError) -> Self {
        match e {
            impress_core::StoreError::NotFound(id) => StoreApiError::NotFound(id.to_string()),
            impress_core::StoreError::AlreadyExists(id) => {
                StoreApiError::AlreadyExists(id.to_string())
            }
            impress_core::StoreError::SchemaNotFound(s) => StoreApiError::NotFound(s),
            impress_core::StoreError::Validation(msg) => StoreApiError::InvalidInput(msg),
            impress_core::StoreError::Storage(msg) => StoreApiError::Storage(msg),
        }
    }
}

/// Information returned after a mutation for undo/redo registration.
#[derive(Debug, Clone)]
#[cfg_attr(feature = "native", derive(uniffi::Record))]
pub struct UndoInfo {
    /// The operation IDs created by this mutation (as UUID strings).
    pub operation_ids: Vec<String>,
    /// If multiple operations share a batch, this is their shared batch ID.
    pub batch_id: Option<String>,
    /// Human-readable description for the Edit menu (e.g., "Star 3 Papers").
    pub description: String,
}

impl From<impress_core::UndoInfo> for UndoInfo {
    fn from(info: impress_core::UndoInfo) -> Self {
        Self {
            operation_ids: info.operation_ids.iter().map(|id| id.to_string()).collect(),
            batch_id: info.batch_id,
            description: info.description,
        }
    }
}

/// The main entry point for Swift. Wraps SqliteItemStore + SchemaRegistry.
#[cfg_attr(feature = "native", derive(uniffi::Object))]
pub struct ImbibStore {
    store: SqliteItemStore,
    #[allow(dead_code)] // Available for validation in future phases
    registry: impress_core::SchemaRegistry,
}

/// Private helpers (not exported via UniFFI).
impl ImbibStore {
    /// Apply a single mutation to multiple item IDs, grouping into a batch for undo.
    fn apply_mutation_to_ids(
        &self,
        ids: &[String],
        mutation: FieldMutation,
    ) -> Result<UndoInfo, StoreApiError> {
        use impress_core::operation::{OperationIntent, OperationSpec, OperationType, undo_description};

        let op_type: OperationType = mutation.clone().into();
        let count = ids.len();
        let description = undo_description(&op_type, count);

        if count == 1 {
            let uuid = parse_uuid(&ids[0])?;
            let info = self.store.update_with_undo(uuid, vec![mutation])?;
            return Ok(UndoInfo {
                operation_ids: info.operation_ids.iter().map(|id| id.to_string()).collect(),
                batch_id: info.batch_id,
                description,
            });
        }

        // Multiple IDs — build a batch of operation specs
        let mut specs = Vec::with_capacity(count);
        for id_str in ids {
            let uuid = parse_uuid(id_str)?;
            specs.push(OperationSpec {
                target_id: uuid,
                op_type: mutation.clone().into(),
                intent: OperationIntent::Routine,
                reason: None,
                batch_id: None, // apply_operation_batch assigns its own
                author: "user:local".into(),
                author_kind: impress_core::item::ActorKind::Human,
            });
        }

        let op_ids = self.store.apply_operation_batch(specs)?;

        // Read back the batch_id assigned by apply_operation_batch
        let batch_id = if let Some(first_id) = op_ids.first() {
            self.store.get(*first_id)?.and_then(|item| item.batch_id)
        } else {
            None
        };

        Ok(UndoInfo {
            operation_ids: op_ids.iter().map(|id| id.to_string()).collect(),
            batch_id,
            description,
        })
    }
}

#[cfg_attr(feature = "native", uniffi::export)]
impl ImbibStore {
    /// Open or create a store at the given database path.
    #[cfg_attr(feature = "native", uniffi::constructor)]
    pub fn open(path: String) -> Result<Arc<Self>, StoreApiError> {
        let store = SqliteItemStore::open(Path::new(&path))?;
        let mut registry = impress_core::SchemaRegistry::new();
        schemas::register_all(&mut registry);
        Ok(Arc::new(Self { store, registry }))
    }

    /// Open an in-memory store (for testing).
    #[cfg_attr(feature = "native", uniffi::constructor)]
    pub fn open_in_memory() -> Result<Arc<Self>, StoreApiError> {
        let store = SqliteItemStore::open_in_memory()?;
        let mut registry = impress_core::SchemaRegistry::new();
        schemas::register_all(&mut registry);
        Ok(Arc::new(Self { store, registry }))
    }

    // --- Library operations ---

    pub fn list_libraries(&self) -> Result<Vec<LibraryRow>, StoreApiError> {
        let q = ItemQuery {
            schema: Some("imbib/library".into()),
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        let mut rows = Vec::new();
        for item in &items {
            let pub_count = self.count_children(item.id, "imbib/bibliography-entry")?;
            rows.push(item_to_library_row(item, pub_count as i32));
        }
        Ok(rows)
    }

    pub fn create_library(&self, name: String) -> Result<LibraryRow, StoreApiError> {
        let item = conversion::library_to_item(&name, None, None, false, false, false);
        self.store.insert(item.clone())?;
        Ok(item_to_library_row(&item, 0))
    }

    pub fn delete_library(&self, id: String) -> Result<(), StoreApiError> {
        let uuid = parse_uuid(&id)?;
        self.store.delete(uuid)?;
        Ok(())
    }

    // --- Collection operations ---

    pub fn list_collections(
        &self,
        library_id: String,
    ) -> Result<Vec<CollectionRow>, StoreApiError> {
        let parent_uuid = parse_uuid(&library_id)?;
        let q = ItemQuery {
            schema: Some("imbib/collection".into()),
            predicates: vec![Predicate::HasParent(parent_uuid)],
            sort: vec![SortDescriptor {
                field: "payload.sort_order".into(),
                ascending: true,
            }],
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        let mut rows = Vec::new();
        for item in &items {
            let pub_count = self.count_collection_members(item.id)?;
            rows.push(item_to_collection_row(item, pub_count as i32));
        }
        Ok(rows)
    }

    pub fn create_collection(
        &self,
        name: String,
        library_id: String,
        is_smart: bool,
        query: Option<String>,
    ) -> Result<CollectionRow, StoreApiError> {
        let parent_uuid = parse_uuid(&library_id)?;
        let item = conversion::collection_to_item(
            &name,
            Some(parent_uuid),
            is_smart,
            query.as_deref(),
            None,
        );
        self.store.insert(item.clone())?;
        Ok(item_to_collection_row(&item, 0))
    }

    pub fn add_to_collection(
        &self,
        publication_ids: Vec<String>,
        collection_id: String,
    ) -> Result<UndoInfo, StoreApiError> {
        let coll_uuid = parse_uuid(&collection_id)?;
        let mut all_op_ids = Vec::new();
        let mut batch_id = None;
        for pub_id_str in &publication_ids {
            let pub_uuid = parse_uuid(pub_id_str)?;
            let info = self.store.update_with_undo(
                coll_uuid,
                vec![FieldMutation::AddReference(
                    impress_core::reference::TypedReference {
                        target: pub_uuid,
                        edge_type: EdgeType::Contains,
                        metadata: None,
                    },
                )],
            )?;
            all_op_ids.extend(info.operation_ids);
            if batch_id.is_none() {
                batch_id = info.batch_id;
            }
        }
        Ok(UndoInfo {
            operation_ids: all_op_ids.iter().map(|id| id.to_string()).collect(),
            batch_id,
            description: "Add to Collection".into(),
        })
    }

    pub fn remove_from_collection(
        &self,
        publication_ids: Vec<String>,
        collection_id: String,
    ) -> Result<UndoInfo, StoreApiError> {
        let coll_uuid = parse_uuid(&collection_id)?;
        let mut all_op_ids = Vec::new();
        let mut batch_id = None;
        for pub_id_str in &publication_ids {
            let pub_uuid = parse_uuid(pub_id_str)?;
            let info = self.store.update_with_undo(
                coll_uuid,
                vec![FieldMutation::RemoveReference(pub_uuid, EdgeType::Contains)],
            )?;
            all_op_ids.extend(info.operation_ids);
            if batch_id.is_none() {
                batch_id = info.batch_id;
            }
        }
        Ok(UndoInfo {
            operation_ids: all_op_ids.iter().map(|id| id.to_string()).collect(),
            batch_id,
            description: "Remove from Collection".into(),
        })
    }

    // --- Publication queries ---

    pub fn query_publications(
        &self,
        parent_id: String,
        sort_field: String,
        ascending: bool,
        limit: Option<u32>,
        offset: Option<u32>,
    ) -> Result<Vec<BibliographyRow>, StoreApiError> {
        let parent_uuid = parse_uuid(&parent_id)?;
        let q = ItemQuery {
            schema: Some("imbib/bibliography-entry".into()),
            predicates: vec![Predicate::HasParent(parent_uuid)],
            sort: vec![SortDescriptor {
                field: normalize_sort_field(&sort_field),
                ascending,
            }],
            limit: limit.map(|l| l as usize),
            offset: offset.map(|o| o as usize),
        };
        let items = self.store.query(&q)?;
        let tag_defs = self.load_tag_definitions()?;
        self.items_to_bibliography_rows(&items, &tag_defs)
    }

    /// Return just the UUID strings of publications in a library (skips full row conversion).
    pub fn query_publication_ids(
        &self,
        parent_id: String,
    ) -> Result<Vec<String>, StoreApiError> {
        let parent_uuid = parse_uuid(&parent_id)?;
        let q = ItemQuery {
            schema: Some("imbib/bibliography-entry".into()),
            predicates: vec![Predicate::HasParent(parent_uuid)],
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        Ok(items.iter().map(|item| item.id.to_string()).collect())
    }

    pub fn search_publications(
        &self,
        query: String,
        parent_id: Option<String>,
    ) -> Result<Vec<BibliographyRow>, StoreApiError> {
        // Search across title, author, abstract, and note fields
        let search_pred = Predicate::Or(vec![
            Predicate::Contains("title".into(), query.clone()),
            Predicate::Contains("author_text".into(), query.clone()),
            Predicate::Contains("abstract_text".into(), query.clone()),
            Predicate::Contains("note".into(), query),
        ]);
        let mut predicates = vec![search_pred];
        if let Some(pid) = parent_id {
            let parent_uuid = parse_uuid(&pid)?;
            predicates.push(Predicate::HasParent(parent_uuid));
        }
        let q = ItemQuery {
            schema: Some("imbib/bibliography-entry".into()),
            predicates,
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        let tag_defs = self.load_tag_definitions()?;
        self.items_to_bibliography_rows(&items, &tag_defs)
    }

    pub fn get_publication(&self, id: String) -> Result<Option<BibliographyRow>, StoreApiError> {
        let uuid = parse_uuid(&id)?;
        let item = self.store.get(uuid)?;
        match item {
            Some(item) => {
                let tag_defs = self.load_tag_definitions()?;
                let rows = self.items_to_bibliography_rows(&[item], &tag_defs)?;
                Ok(rows.into_iter().next())
            }
            None => Ok(None),
        }
    }

    pub fn get_flagged_publications(
        &self,
        color: Option<String>,
    ) -> Result<Vec<BibliographyRow>, StoreApiError> {
        let q = ItemQuery {
            schema: Some("imbib/bibliography-entry".into()),
            predicates: vec![Predicate::HasFlag(color)],
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        let tag_defs = self.load_tag_definitions()?;
        self.items_to_bibliography_rows(&items, &tag_defs)
    }

    // --- Publication mutations ---

    pub fn import_bibtex(
        &self,
        bibtex: String,
        library_id: String,
    ) -> Result<Vec<String>, StoreApiError> {
        let parent_uuid = parse_uuid(&library_id)?;
        let parse_result = crate::bibtex::parse(bibtex.clone())
            .map_err(|e| StoreApiError::InvalidInput(format!("BibTeX parse error: {}", e)))?;

        let mut ids = Vec::new();
        for entry in &parse_result.entries {
            let publication = crate::conversions::bibtex_entry_to_publication(entry.clone());

            // Deduplication: skip if a publication with the same DOI, arXiv ID, or bibcode
            // already exists in this library
            if self.is_duplicate_in_library(&publication, parent_uuid)? {
                continue;
            }

            let item = conversion::publication_to_item(&publication, Some(parent_uuid));
            let id = self.store.insert(item)?;
            ids.push(id.to_string());
        }
        Ok(ids)
    }

    pub fn set_read(&self, ids: Vec<String>, read: bool) -> Result<UndoInfo, StoreApiError> {
        self.apply_mutation_to_ids(&ids, FieldMutation::SetRead(read))
    }

    pub fn set_starred(&self, ids: Vec<String>, starred: bool) -> Result<UndoInfo, StoreApiError> {
        self.apply_mutation_to_ids(&ids, FieldMutation::SetStarred(starred))
    }

    pub fn set_flag(
        &self,
        ids: Vec<String>,
        color: Option<String>,
        style: Option<String>,
        length: Option<String>,
    ) -> Result<UndoInfo, StoreApiError> {
        let flag = color.map(|c| FlagState {
            color: c,
            style,
            length,
        });
        self.apply_mutation_to_ids(&ids, FieldMutation::SetFlag(flag))
    }

    pub fn add_tag(&self, ids: Vec<String>, tag_path: String) -> Result<UndoInfo, StoreApiError> {
        self.apply_mutation_to_ids(&ids, FieldMutation::AddTag(tag_path))
    }

    pub fn remove_tag(&self, ids: Vec<String>, tag_path: String) -> Result<UndoInfo, StoreApiError> {
        self.apply_mutation_to_ids(&ids, FieldMutation::RemoveTag(tag_path))
    }

    pub fn delete_publications(&self, ids: Vec<String>) -> Result<(), StoreApiError> {
        for id_str in &ids {
            let uuid = parse_uuid(id_str)?;
            self.store.delete(uuid)?;
        }
        Ok(())
    }

    pub fn update_field(
        &self,
        id: String,
        field: String,
        value: Option<String>,
    ) -> Result<UndoInfo, StoreApiError> {
        let uuid = parse_uuid(&id)?;
        let mutation = match value {
            Some(v) => FieldMutation::SetPayload(field, Value::String(v)),
            None => FieldMutation::RemovePayload(field),
        };
        Ok(self.store.update_with_undo(uuid, vec![mutation])?.into())
    }

    // --- Tag definitions ---

    pub fn list_tags(&self) -> Result<Vec<TagDisplayRow>, StoreApiError> {
        self.load_tag_definitions()
    }

    pub fn create_tag(
        &self,
        path: String,
        color_light: Option<String>,
        color_dark: Option<String>,
    ) -> Result<(), StoreApiError> {
        let leaf_name = path.rsplit('/').next().unwrap_or(&path);
        let item = conversion::tag_definition_to_item(
            leaf_name,
            &path,
            color_light.as_deref(),
            color_dark.as_deref(),
            None,
            None,
        );
        self.store.insert(item)?;
        Ok(())
    }

    // --- Export ---

    pub fn export_bibtex(&self, ids: Vec<String>) -> Result<String, StoreApiError> {
        let mut entries = Vec::new();
        for id_str in &ids {
            let uuid = parse_uuid(id_str)?;
            if let Some(item) = self.store.get(uuid)? {
                let publication = conversion::item_to_publication(&item);
                let entry = crate::domain::publication_to_bibtex(&publication);
                entries.push(entry);
            }
        }
        Ok(crate::bibtex::format_entries(entries))
    }

    pub fn export_all_bibtex(&self, library_id: String) -> Result<String, StoreApiError> {
        let parent_uuid = parse_uuid(&library_id)?;
        let q = ItemQuery {
            schema: Some("imbib/bibliography-entry".into()),
            predicates: vec![Predicate::HasParent(parent_uuid)],
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        let entries: Vec<_> = items
            .iter()
            .map(|item| {
                let publication = conversion::item_to_publication(item);
                crate::domain::publication_to_bibtex(&publication)
            })
            .collect();
        Ok(crate::bibtex::format_entries(entries))
    }

    // --- Publication detail ---

    pub fn get_publication_detail(
        &self,
        id: String,
    ) -> Result<Option<PublicationDetail>, StoreApiError> {
        let uuid = parse_uuid(&id)?;
        let item = self.store.get(uuid)?;
        match item {
            Some(item) => {
                let tag_defs = self.load_tag_definitions()?;

                // Fetch child linked files
                let lf_q = ItemQuery {
                    schema: Some("imbib/linked-file".into()),
                    predicates: vec![Predicate::HasParent(uuid)],
                    ..Default::default()
                };
                let child_lf = self.store.query(&lf_q)?;

                // Find collections that reference this publication
                let coll_q = ItemQuery {
                    schema: Some("imbib/collection".into()),
                    predicates: vec![Predicate::HasReference(EdgeType::Contains, uuid)],
                    ..Default::default()
                };
                let collections = self.store.query(&coll_q)?;
                let collection_ids: Vec<String> =
                    collections.iter().map(|c| c.id.to_string()).collect();

                let library_ids = item
                    .parent
                    .map(|p| vec![p.to_string()])
                    .unwrap_or_default();

                Ok(Some(item_to_publication_detail(
                    &item,
                    &tag_defs,
                    collection_ids,
                    library_ids,
                    &child_lf,
                )))
            }
            None => Ok(None),
        }
    }

    // --- Migration ---

    pub fn import_from_bibtex_file(
        &self,
        path: String,
        library_id: String,
    ) -> Result<u32, StoreApiError> {
        let content = std::fs::read_to_string(&path)
            .map_err(|e| StoreApiError::Storage(format!("read file: {}", e)))?;
        let ids = self.import_bibtex(content, library_id)?;
        Ok(ids.len() as u32)
    }

    // --- Undo/Redo ---

    /// Undo a single operation by ID. Returns UndoInfo for the inverse (redo) operation.
    pub fn undo_operation(&self, operation_id: String) -> Result<UndoInfo, StoreApiError> {
        let uuid = parse_uuid(&operation_id)?;
        Ok(self.store.undo_operation(uuid)?.into())
    }

    /// Undo all operations in a batch. Returns UndoInfo for the redo batch.
    pub fn undo_batch(&self, batch_id: String) -> Result<UndoInfo, StoreApiError> {
        Ok(self.store.undo_batch(&batch_id)?.into())
    }

    // --- Generic field helpers ---

    /// Delete any item by ID.
    pub fn delete_item(&self, id: String) -> Result<(), StoreApiError> {
        let uuid = parse_uuid(&id)?;
        self.store.delete(uuid)?;
        Ok(())
    }

    /// Update an integer payload field on any item.
    pub fn update_int_field(
        &self,
        id: String,
        field: String,
        value: Option<i64>,
    ) -> Result<UndoInfo, StoreApiError> {
        let uuid = parse_uuid(&id)?;
        let mutation = match value {
            Some(v) => FieldMutation::SetPayload(field, Value::Int(v)),
            None => FieldMutation::RemovePayload(field),
        };
        Ok(self.store.update_with_undo(uuid, vec![mutation])?.into())
    }

    /// Update a boolean payload field on any item.
    pub fn update_bool_field(
        &self,
        id: String,
        field: String,
        value: bool,
    ) -> Result<UndoInfo, StoreApiError> {
        let uuid = parse_uuid(&id)?;
        Ok(self.store.update_with_undo(
            uuid,
            vec![FieldMutation::SetPayload(field, Value::Bool(value))],
        )?.into())
    }

    // --- Library extensions ---

    pub fn get_library(&self, id: String) -> Result<Option<LibraryRow>, StoreApiError> {
        let uuid = parse_uuid(&id)?;
        match self.store.get(uuid)? {
            Some(item) if item.schema == "imbib/library" => {
                let pub_count = self.count_children(item.id, "imbib/bibliography-entry")?;
                Ok(Some(item_to_library_row(&item, pub_count as i32)))
            }
            _ => Ok(None),
        }
    }

    pub fn set_library_default(&self, id: String) -> Result<(), StoreApiError> {
        let uuid = parse_uuid(&id)?;
        // Unset current default(s)
        let q = ItemQuery {
            schema: Some("imbib/library".into()),
            predicates: vec![Predicate::Eq(
                "is_default".into(),
                Value::Bool(true),
            )],
            ..Default::default()
        };
        for item in self.store.query(&q)? {
            self.store.update(
                item.id,
                vec![FieldMutation::SetPayload(
                    "is_default".into(),
                    Value::Bool(false),
                )],
            )?;
        }
        // Set new default
        self.store.update(
            uuid,
            vec![FieldMutation::SetPayload(
                "is_default".into(),
                Value::Bool(true),
            )],
        )?;
        Ok(())
    }

    pub fn get_default_library(&self) -> Result<Option<LibraryRow>, StoreApiError> {
        let q = ItemQuery {
            schema: Some("imbib/library".into()),
            predicates: vec![Predicate::Eq(
                "is_default".into(),
                Value::Bool(true),
            )],
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        if let Some(item) = items.first() {
            let pub_count = self.count_children(item.id, "imbib/bibliography-entry")?;
            Ok(Some(item_to_library_row(item, pub_count as i32)))
        } else {
            Ok(None)
        }
    }

    // --- Collection extensions ---

    pub fn list_collection_members(
        &self,
        collection_id: String,
        sort_field: String,
        ascending: bool,
        limit: Option<u32>,
        offset: Option<u32>,
    ) -> Result<Vec<BibliographyRow>, StoreApiError> {
        let coll_uuid = parse_uuid(&collection_id)?;
        let coll_item = self
            .store
            .get(coll_uuid)?
            .ok_or(StoreApiError::NotFound(collection_id))?;
        let pub_ids: Vec<Uuid> = coll_item
            .references
            .iter()
            .filter(|r| r.edge_type == EdgeType::Contains)
            .map(|r| r.target)
            .collect();
        if pub_ids.is_empty() {
            return Ok(vec![]);
        }
        let tag_defs = self.load_tag_definitions()?;
        let mut items = Vec::new();
        for pub_id in &pub_ids {
            if let Some(item) = self.store.get(*pub_id)? {
                items.push(item);
            }
        }
        let mut rows = self.items_to_bibliography_rows(&items, &tag_defs)?;
        let sort_key = normalize_sort_field(&sort_field);
        rows.sort_by(|a, b| {
            let cmp = match sort_key.as_str() {
                "created" => a.date_added.cmp(&b.date_added),
                "modified" => a.date_modified.cmp(&b.date_modified),
                "payload.title" => a.title.to_lowercase().cmp(&b.title.to_lowercase()),
                "payload.author_text" => a
                    .author_string
                    .to_lowercase()
                    .cmp(&b.author_string.to_lowercase()),
                "payload.year" => a.year.cmp(&b.year),
                "payload.cite_key" => a.cite_key.cmp(&b.cite_key),
                "payload.citation_count" => a.citation_count.cmp(&b.citation_count),
                _ => a.date_added.cmp(&b.date_added),
            };
            if ascending {
                cmp
            } else {
                cmp.reverse()
            }
        });
        let start = offset.unwrap_or(0) as usize;
        let rows = rows.into_iter().skip(start);
        let rows: Vec<_> = match limit {
            Some(l) => rows.take(l as usize).collect(),
            None => rows.collect(),
        };
        Ok(rows)
    }

    // --- Linked file operations ---

    #[allow(clippy::too_many_arguments)]
    pub fn add_linked_file(
        &self,
        publication_id: String,
        filename: String,
        relative_path: Option<String>,
        file_type: Option<String>,
        file_size: i64,
        sha256: Option<String>,
        is_pdf: bool,
    ) -> Result<LinkedFileRow, StoreApiError> {
        let pub_uuid = parse_uuid(&publication_id)?;
        let item = conversion::linked_file_to_item(
            pub_uuid,
            &filename,
            relative_path.as_deref(),
            file_type.as_deref(),
            file_size,
            sha256.as_deref(),
            is_pdf,
        );
        self.store.insert(item.clone())?;
        Ok(item_to_linked_file_row(&item))
    }

    pub fn list_linked_files(
        &self,
        publication_id: String,
    ) -> Result<Vec<LinkedFileRow>, StoreApiError> {
        let pub_uuid = parse_uuid(&publication_id)?;
        let q = ItemQuery {
            schema: Some("imbib/linked-file".into()),
            predicates: vec![Predicate::HasParent(pub_uuid)],
            sort: vec![SortDescriptor {
                field: "created".into(),
                ascending: true,
            }],
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        Ok(items.iter().map(item_to_linked_file_row).collect())
    }

    pub fn get_linked_file(&self, id: String) -> Result<Option<LinkedFileRow>, StoreApiError> {
        let uuid = parse_uuid(&id)?;
        match self.store.get(uuid)? {
            Some(item) if item.schema == "imbib/linked-file" => {
                Ok(Some(item_to_linked_file_row(&item)))
            }
            _ => Ok(None),
        }
    }

    pub fn set_pdf_cloud_available(
        &self,
        id: String,
        available: bool,
    ) -> Result<(), StoreApiError> {
        let uuid = parse_uuid(&id)?;
        self.store.update(
            uuid,
            vec![FieldMutation::SetPayload(
                "pdf_cloud_available".into(),
                Value::Bool(available),
            )],
        )?;
        Ok(())
    }

    pub fn set_locally_materialized(
        &self,
        id: String,
        materialized: bool,
    ) -> Result<(), StoreApiError> {
        let uuid = parse_uuid(&id)?;
        self.store.update(
            uuid,
            vec![FieldMutation::SetPayload(
                "is_locally_materialized".into(),
                Value::Bool(materialized),
            )],
        )?;
        Ok(())
    }

    pub fn count_pdfs(&self, publication_id: String) -> Result<u32, StoreApiError> {
        let pub_uuid = parse_uuid(&publication_id)?;
        let q = ItemQuery {
            schema: Some("imbib/linked-file".into()),
            predicates: vec![
                Predicate::HasParent(pub_uuid),
                Predicate::Eq("is_pdf".into(), Value::Bool(true)),
            ],
            ..Default::default()
        };
        Ok(self.store.count(&q)? as u32)
    }

    // --- Smart search operations ---

    #[allow(clippy::too_many_arguments)]
    pub fn create_smart_search(
        &self,
        name: String,
        query: String,
        library_id: String,
        source_ids_json: Option<String>,
        max_results: i64,
        feeds_to_inbox: bool,
        auto_refresh_enabled: bool,
        refresh_interval_seconds: i64,
    ) -> Result<SmartSearchRow, StoreApiError> {
        let lib_uuid = parse_uuid(&library_id)?;
        let item = conversion::smart_search_to_item(
            &name,
            &query,
            lib_uuid,
            source_ids_json.as_deref(),
            max_results,
            feeds_to_inbox,
            auto_refresh_enabled,
            refresh_interval_seconds,
            None,
        );
        self.store.insert(item.clone())?;
        Ok(item_to_smart_search_row(&item))
    }

    pub fn list_smart_searches(
        &self,
        library_id: Option<String>,
    ) -> Result<Vec<SmartSearchRow>, StoreApiError> {
        let mut predicates = Vec::new();
        if let Some(lib_id) = library_id {
            let lib_uuid = parse_uuid(&lib_id)?;
            predicates.push(Predicate::HasParent(lib_uuid));
        }
        let q = ItemQuery {
            schema: Some("imbib/smart-search".into()),
            predicates,
            sort: vec![SortDescriptor {
                field: "payload.sort_order".into(),
                ascending: true,
            }],
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        Ok(items.iter().map(item_to_smart_search_row).collect())
    }

    pub fn get_smart_search(
        &self,
        id: String,
    ) -> Result<Option<SmartSearchRow>, StoreApiError> {
        let uuid = parse_uuid(&id)?;
        match self.store.get(uuid)? {
            Some(item) if item.schema == "imbib/smart-search" => {
                Ok(Some(item_to_smart_search_row(&item)))
            }
            _ => Ok(None),
        }
    }

    // --- Inbox & triage ---

    pub fn get_inbox_library(&self) -> Result<Option<LibraryRow>, StoreApiError> {
        let q = ItemQuery {
            schema: Some("imbib/library".into()),
            predicates: vec![Predicate::Eq("is_inbox".into(), Value::Bool(true))],
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        if let Some(item) = items.first() {
            let pub_count = self.count_children(item.id, "imbib/bibliography-entry")?;
            Ok(Some(item_to_library_row(item, pub_count as i32)))
        } else {
            Ok(None)
        }
    }

    pub fn create_inbox_library(&self, name: String) -> Result<LibraryRow, StoreApiError> {
        let item = conversion::library_to_item(&name, None, None, false, true, true);
        self.store.insert(item.clone())?;
        Ok(item_to_library_row(&item, 0))
    }

    pub fn create_muted_item(
        &self,
        mute_type: String,
        value: String,
    ) -> Result<MutedItemRow, StoreApiError> {
        let item = conversion::muted_item_to_item(&mute_type, &value);
        self.store.insert(item.clone())?;
        Ok(item_to_muted_item_row(&item))
    }

    pub fn list_muted_items(
        &self,
        mute_type: Option<String>,
    ) -> Result<Vec<MutedItemRow>, StoreApiError> {
        let mut predicates = Vec::new();
        if let Some(mt) = mute_type {
            predicates.push(Predicate::Eq("mute_type".into(), Value::String(mt)));
        }
        let q = ItemQuery {
            schema: Some("imbib/muted-item".into()),
            predicates,
            sort: vec![SortDescriptor {
                field: "created".into(),
                ascending: false,
            }],
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        Ok(items.iter().map(item_to_muted_item_row).collect())
    }

    pub fn dismiss_paper(
        &self,
        doi: Option<String>,
        arxiv_id: Option<String>,
        bibcode: Option<String>,
    ) -> Result<DismissedPaperRow, StoreApiError> {
        let item = conversion::dismissed_paper_to_item(
            doi.as_deref(),
            arxiv_id.as_deref(),
            bibcode.as_deref(),
        );
        self.store.insert(item.clone())?;
        Ok(item_to_dismissed_paper_row(&item))
    }

    pub fn is_paper_dismissed(
        &self,
        doi: Option<String>,
        arxiv_id: Option<String>,
        bibcode: Option<String>,
    ) -> Result<bool, StoreApiError> {
        let mut or_preds = Vec::new();
        if let Some(d) = doi {
            or_preds.push(Predicate::Eq("doi".into(), Value::String(d)));
        }
        if let Some(a) = arxiv_id {
            or_preds.push(Predicate::Eq("arxiv_id".into(), Value::String(a)));
        }
        if let Some(b) = bibcode {
            or_preds.push(Predicate::Eq("bibcode".into(), Value::String(b)));
        }
        if or_preds.is_empty() {
            return Ok(false);
        }
        let q = ItemQuery {
            schema: Some("imbib/dismissed-paper".into()),
            predicates: vec![Predicate::Or(or_preds)],
            limit: Some(1),
            ..Default::default()
        };
        Ok(self.store.count(&q)? > 0)
    }

    pub fn list_dismissed_papers(
        &self,
        limit: Option<u32>,
        offset: Option<u32>,
    ) -> Result<Vec<DismissedPaperRow>, StoreApiError> {
        let q = ItemQuery {
            schema: Some("imbib/dismissed-paper".into()),
            sort: vec![SortDescriptor {
                field: "created".into(),
                ascending: false,
            }],
            limit: limit.map(|l| l as usize),
            offset: offset.map(|o| o as usize),
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        Ok(items.iter().map(item_to_dismissed_paper_row).collect())
    }

    // --- Deduplication queries ---

    pub fn find_by_doi(&self, doi: String) -> Result<Vec<BibliographyRow>, StoreApiError> {
        let q = ItemQuery {
            schema: Some("imbib/bibliography-entry".into()),
            predicates: vec![Predicate::Eq("doi".into(), Value::String(doi))],
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        let tag_defs = self.load_tag_definitions()?;
        self.items_to_bibliography_rows(&items, &tag_defs)
    }

    pub fn find_by_arxiv(
        &self,
        arxiv_id: String,
    ) -> Result<Vec<BibliographyRow>, StoreApiError> {
        let q = ItemQuery {
            schema: Some("imbib/bibliography-entry".into()),
            predicates: vec![Predicate::Eq(
                "arxiv_id".into(),
                Value::String(arxiv_id),
            )],
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        let tag_defs = self.load_tag_definitions()?;
        self.items_to_bibliography_rows(&items, &tag_defs)
    }

    pub fn find_by_bibcode(
        &self,
        bibcode: String,
    ) -> Result<Vec<BibliographyRow>, StoreApiError> {
        let q = ItemQuery {
            schema: Some("imbib/bibliography-entry".into()),
            predicates: vec![Predicate::Eq(
                "bibcode".into(),
                Value::String(bibcode),
            )],
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        let tag_defs = self.load_tag_definitions()?;
        self.items_to_bibliography_rows(&items, &tag_defs)
    }

    pub fn find_by_identifiers(
        &self,
        doi: Option<String>,
        arxiv_id: Option<String>,
        bibcode: Option<String>,
        pmid: Option<String>,
    ) -> Result<Vec<BibliographyRow>, StoreApiError> {
        let mut or_preds = Vec::new();
        if let Some(d) = doi {
            or_preds.push(Predicate::Eq("doi".into(), Value::String(d)));
        }
        if let Some(a) = arxiv_id {
            or_preds.push(Predicate::Eq("arxiv_id".into(), Value::String(a)));
        }
        if let Some(b) = bibcode {
            or_preds.push(Predicate::Eq("bibcode".into(), Value::String(b)));
        }
        if let Some(p) = pmid {
            or_preds.push(Predicate::Eq("pmid".into(), Value::String(p)));
        }
        if or_preds.is_empty() {
            return Ok(vec![]);
        }
        let q = ItemQuery {
            schema: Some("imbib/bibliography-entry".into()),
            predicates: vec![Predicate::Or(or_preds)],
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        let tag_defs = self.load_tag_definitions()?;
        self.items_to_bibliography_rows(&items, &tag_defs)
    }

    /// Batch lookup: find all publications matching any of the given DOIs, arXiv IDs, or bibcodes.
    /// Single SQL query instead of N individual calls — prevents main-thread blocking during
    /// feed refresh (500 results × 30ms each = 16s → 1 query ~50ms).
    pub fn find_by_identifiers_batch(
        &self,
        dois: Vec<String>,
        arxiv_ids: Vec<String>,
        bibcodes: Vec<String>,
    ) -> Result<Vec<BibliographyRow>, StoreApiError> {
        let mut or_preds = Vec::new();
        if !dois.is_empty() {
            or_preds.push(Predicate::In(
                "doi".into(),
                dois.into_iter().map(Value::String).collect(),
            ));
        }
        if !arxiv_ids.is_empty() {
            or_preds.push(Predicate::In(
                "arxiv_id".into(),
                arxiv_ids.into_iter().map(Value::String).collect(),
            ));
        }
        if !bibcodes.is_empty() {
            or_preds.push(Predicate::In(
                "bibcode".into(),
                bibcodes.into_iter().map(Value::String).collect(),
            ));
        }
        if or_preds.is_empty() {
            return Ok(vec![]);
        }
        let q = ItemQuery {
            schema: Some("imbib/bibliography-entry".into()),
            predicates: vec![Predicate::Or(or_preds)],
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        let tag_defs = self.load_tag_definitions()?;
        self.items_to_bibliography_rows(&items, &tag_defs)
    }

    /// Remove duplicate publications within a library, keeping the oldest copy.
    ///
    /// Returns the number of duplicates removed.
    pub fn deduplicate_library(&self, library_id: String) -> Result<u32, StoreApiError> {
        let parent_uuid = parse_uuid(&library_id)?;
        let q = ItemQuery {
            schema: Some("imbib/bibliography-entry".into()),
            predicates: vec![Predicate::HasParent(parent_uuid)],
            sort: vec![SortDescriptor {
                field: "created".into(),
                ascending: true,
            }],
            ..Default::default()
        };
        let items = self.store.query(&q)?;

        let mut seen_cite_keys: std::collections::HashSet<String> = std::collections::HashSet::new();
        let mut seen_dois: std::collections::HashSet<String> = std::collections::HashSet::new();
        let mut seen_arxiv_ids: std::collections::HashSet<String> = std::collections::HashSet::new();
        let mut to_delete = Vec::new();

        for item in &items {
            let get_str = |key: &str| -> String {
                match item.payload.get(key) {
                    Some(Value::String(s)) => s.clone(),
                    _ => String::new(),
                }
            };
            let cite_key = get_str("cite_key");
            let doi = get_str("doi");
            let arxiv_id = get_str("arxiv_id");
            // Normalize arxiv_id by stripping version suffix
            let arxiv_base = if arxiv_id.contains('v') {
                arxiv_id.split('v').next().unwrap_or(&arxiv_id).to_string()
            } else {
                arxiv_id.clone()
            };

            let mut is_dup = false;
            if !doi.is_empty() && !seen_dois.insert(doi) {
                is_dup = true;
            }
            if !is_dup && !arxiv_base.is_empty() && !seen_arxiv_ids.insert(arxiv_base) {
                is_dup = true;
            }
            if !is_dup && !cite_key.is_empty() && !seen_cite_keys.insert(cite_key) {
                is_dup = true;
            }

            if is_dup {
                to_delete.push(item.id);
            }
        }

        let count = to_delete.len() as u32;
        for id in to_delete {
            self.store.delete(id)?;
        }
        Ok(count)
    }

    // --- Advanced queries ---

    pub fn query_unread(
        &self,
        parent_id: Option<String>,
    ) -> Result<Vec<BibliographyRow>, StoreApiError> {
        let mut predicates = vec![Predicate::IsRead(false)];
        if let Some(pid) = parent_id {
            predicates.push(Predicate::HasParent(parse_uuid(&pid)?));
        }
        let q = ItemQuery {
            schema: Some("imbib/bibliography-entry".into()),
            predicates,
            sort: vec![SortDescriptor {
                field: "created".into(),
                ascending: false,
            }],
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        let tag_defs = self.load_tag_definitions()?;
        self.items_to_bibliography_rows(&items, &tag_defs)
    }

    pub fn count_unread(&self, parent_id: Option<String>) -> Result<u32, StoreApiError> {
        let mut predicates = vec![Predicate::IsRead(false)];
        if let Some(pid) = parent_id {
            predicates.push(Predicate::HasParent(parse_uuid(&pid)?));
        }
        let q = ItemQuery {
            schema: Some("imbib/bibliography-entry".into()),
            predicates,
            ..Default::default()
        };
        Ok(self.store.count(&q)? as u32)
    }

    /// Count publications, optionally within a parent library. Uses SELECT COUNT(*)
    /// instead of deserializing all rows — much faster for widget badge counts.
    pub fn count_publications(&self, parent_id: Option<String>) -> Result<u32, StoreApiError> {
        let mut predicates = Vec::new();
        if let Some(pid) = parent_id {
            predicates.push(Predicate::HasParent(parse_uuid(&pid)?));
        }
        let q = ItemQuery {
            schema: Some("imbib/bibliography-entry".into()),
            predicates,
            ..Default::default()
        };
        Ok(self.store.count(&q)? as u32)
    }

    pub fn query_starred(
        &self,
        parent_id: Option<String>,
    ) -> Result<Vec<BibliographyRow>, StoreApiError> {
        let mut predicates = vec![Predicate::IsStarred(true)];
        if let Some(pid) = parent_id {
            predicates.push(Predicate::HasParent(parse_uuid(&pid)?));
        }
        let q = ItemQuery {
            schema: Some("imbib/bibliography-entry".into()),
            predicates,
            sort: vec![SortDescriptor {
                field: "created".into(),
                ascending: false,
            }],
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        let tag_defs = self.load_tag_definitions()?;
        self.items_to_bibliography_rows(&items, &tag_defs)
    }

    pub fn query_by_tag(
        &self,
        tag_path: String,
        parent_id: Option<String>,
    ) -> Result<Vec<BibliographyRow>, StoreApiError> {
        let mut predicates = vec![Predicate::HasTag(tag_path)];
        if let Some(pid) = parent_id {
            predicates.push(Predicate::HasParent(parse_uuid(&pid)?));
        }
        let q = ItemQuery {
            schema: Some("imbib/bibliography-entry".into()),
            predicates,
            sort: vec![SortDescriptor {
                field: "created".into(),
                ascending: false,
            }],
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        let tag_defs = self.load_tag_definitions()?;
        self.items_to_bibliography_rows(&items, &tag_defs)
    }

    pub fn query_recent(
        &self,
        limit: u32,
        parent_id: Option<String>,
    ) -> Result<Vec<BibliographyRow>, StoreApiError> {
        let mut predicates = Vec::new();
        if let Some(pid) = parent_id {
            predicates.push(Predicate::HasParent(parse_uuid(&pid)?));
        }
        let q = ItemQuery {
            schema: Some("imbib/bibliography-entry".into()),
            predicates,
            sort: vec![SortDescriptor {
                field: "created".into(),
                ascending: false,
            }],
            limit: Some(limit as usize),
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        let tag_defs = self.load_tag_definitions()?;
        self.items_to_bibliography_rows(&items, &tag_defs)
    }

    pub fn full_text_search(
        &self,
        query: String,
        parent_id: Option<String>,
        limit: Option<u32>,
    ) -> Result<Vec<BibliographyRow>, StoreApiError> {
        let search_pred = Predicate::Or(vec![
            Predicate::Contains("title".into(), query.clone()),
            Predicate::Contains("author_text".into(), query.clone()),
            Predicate::Contains("abstract_text".into(), query.clone()),
            Predicate::Contains("note".into(), query),
        ]);
        let mut predicates = vec![search_pred];
        if let Some(pid) = parent_id {
            predicates.push(Predicate::HasParent(parse_uuid(&pid)?));
        }
        let q = ItemQuery {
            schema: Some("imbib/bibliography-entry".into()),
            predicates,
            limit: limit.map(|l| l as usize),
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        let tag_defs = self.load_tag_definitions()?;
        self.items_to_bibliography_rows(&items, &tag_defs)
    }

    pub fn find_by_cite_key(
        &self,
        cite_key: String,
        library_id: Option<String>,
    ) -> Result<Option<BibliographyRow>, StoreApiError> {
        let mut predicates =
            vec![Predicate::Eq("cite_key".into(), Value::String(cite_key))];
        if let Some(lid) = library_id {
            predicates.push(Predicate::HasParent(parse_uuid(&lid)?));
        }
        let q = ItemQuery {
            schema: Some("imbib/bibliography-entry".into()),
            predicates,
            limit: Some(1),
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        if items.is_empty() {
            Ok(None)
        } else {
            let tag_defs = self.load_tag_definitions()?;
            let rows = self.items_to_bibliography_rows(&items, &tag_defs)?;
            Ok(rows.into_iter().next())
        }
    }

    // --- SciX library operations ---

    pub fn create_scix_library(
        &self,
        remote_id: String,
        name: String,
        description: Option<String>,
        is_public: bool,
        permission_level: String,
        owner_email: Option<String>,
    ) -> Result<SciXLibraryRow, StoreApiError> {
        let item = conversion::scix_library_to_item(
            &remote_id,
            &name,
            description.as_deref(),
            is_public,
            &permission_level,
            owner_email.as_deref(),
            None,
        );
        self.store.insert(item.clone())?;
        Ok(item_to_scix_library_row(&item, 0))
    }

    pub fn list_scix_libraries(&self) -> Result<Vec<SciXLibraryRow>, StoreApiError> {
        let q = ItemQuery {
            schema: Some("imbib/scix-library".into()),
            sort: vec![SortDescriptor {
                field: "payload.sort_order".into(),
                ascending: true,
            }],
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        let mut rows = Vec::new();
        for item in &items {
            // Count publications via Contains references (not parent), since
            // add_to_scix_library uses AddReference(Contains).
            let pub_count = item
                .references
                .iter()
                .filter(|r| r.edge_type == EdgeType::Contains)
                .count();
            rows.push(item_to_scix_library_row(item, pub_count as i32));
        }
        Ok(rows)
    }

    pub fn get_scix_library(
        &self,
        id: String,
    ) -> Result<Option<SciXLibraryRow>, StoreApiError> {
        let uuid = parse_uuid(&id)?;
        match self.store.get(uuid)? {
            Some(item) if item.schema == "imbib/scix-library" => {
                // Count publications via Contains references (not parent), since
                // add_to_scix_library uses AddReference(Contains).
                let pub_count = item
                    .references
                    .iter()
                    .filter(|r| r.edge_type == EdgeType::Contains)
                    .count();
                Ok(Some(item_to_scix_library_row(&item, pub_count as i32)))
            }
            _ => Ok(None),
        }
    }

    pub fn add_to_scix_library(
        &self,
        publication_ids: Vec<String>,
        scix_library_id: String,
    ) -> Result<(), StoreApiError> {
        let scix_uuid = parse_uuid(&scix_library_id)?;
        for pub_id_str in &publication_ids {
            let pub_uuid = parse_uuid(pub_id_str)?;
            self.store.update(
                scix_uuid,
                vec![FieldMutation::AddReference(
                    impress_core::reference::TypedReference {
                        target: pub_uuid,
                        edge_type: EdgeType::Contains,
                        metadata: None,
                    },
                )],
            )?;
        }
        Ok(())
    }

    /// Query publications linked to a SciX library via item_references (Contains edges).
    ///
    /// SciX libraries store their membership via `AddReference(Contains)` rather than
    /// parent relationships. This method uses `Predicate::ReferencedBy` to find all
    /// bibliography entries that are targets of Contains edges from the given SciX library.
    pub fn query_scix_library_publications(
        &self,
        scix_library_id: String,
        sort_field: String,
        ascending: bool,
    ) -> Result<Vec<BibliographyRow>, StoreApiError> {
        let scix_uuid = parse_uuid(&scix_library_id)?;
        let q = ItemQuery {
            schema: Some("imbib/bibliography-entry".into()),
            predicates: vec![Predicate::ReferencedBy(EdgeType::Contains, scix_uuid)],
            sort: vec![SortDescriptor {
                field: normalize_sort_field(&sort_field),
                ascending,
            }],
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        let tag_defs = self.load_tag_definitions()?;
        self.items_to_bibliography_rows(&items, &tag_defs)
    }

    /// Re-parent an item (e.g. fix orphaned smart searches whose parent was deleted).
    pub fn reparent_item(
        &self,
        id: String,
        new_parent_id: String,
    ) -> Result<(), StoreApiError> {
        let uuid = parse_uuid(&id)?;
        let parent_uuid = parse_uuid(&new_parent_id)?;
        self.store
            .update(uuid, vec![FieldMutation::SetParent(Some(parent_uuid))])?;
        Ok(())
    }

    // --- Annotation operations ---

    #[allow(clippy::too_many_arguments)]
    pub fn create_annotation(
        &self,
        linked_file_id: String,
        annotation_type: String,
        page_number: i64,
        bounds_json: Option<String>,
        color: Option<String>,
        contents: Option<String>,
        selected_text: Option<String>,
    ) -> Result<AnnotationRow, StoreApiError> {
        let file_uuid = parse_uuid(&linked_file_id)?;
        let item = conversion::annotation_to_item(
            file_uuid,
            &annotation_type,
            page_number,
            bounds_json.as_deref(),
            color.as_deref(),
            contents.as_deref(),
            selected_text.as_deref(),
        );
        self.store.insert(item.clone())?;
        Ok(item_to_annotation_row(&item))
    }

    pub fn list_annotations(
        &self,
        linked_file_id: String,
        page_number: Option<i32>,
    ) -> Result<Vec<AnnotationRow>, StoreApiError> {
        let file_uuid = parse_uuid(&linked_file_id)?;
        let mut predicates = vec![Predicate::HasParent(file_uuid)];
        if let Some(page) = page_number {
            predicates.push(Predicate::Eq(
                "page_number".into(),
                Value::Int(page as i64),
            ));
        }
        let q = ItemQuery {
            schema: Some("imbib/annotation".into()),
            predicates,
            sort: vec![SortDescriptor {
                field: "payload.page_number".into(),
                ascending: true,
            }],
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        Ok(items.iter().map(item_to_annotation_row).collect())
    }

    pub fn count_annotations(
        &self,
        linked_file_id: String,
    ) -> Result<u32, StoreApiError> {
        let file_uuid = parse_uuid(&linked_file_id)?;
        let q = ItemQuery {
            schema: Some("imbib/annotation".into()),
            predicates: vec![Predicate::HasParent(file_uuid)],
            ..Default::default()
        };
        Ok(self.store.count(&q)? as u32)
    }

    // --- Comment operations ---

    pub fn create_comment(
        &self,
        publication_id: String,
        text: String,
        author_identifier: Option<String>,
        author_display_name: Option<String>,
        parent_comment_id: Option<String>,
    ) -> Result<CommentRow, StoreApiError> {
        self.create_comment_on_item(publication_id, text, author_identifier, author_display_name, parent_comment_id)
    }

    /// Create a comment on any item (publication, artifact, or any future item type).
    pub fn create_comment_on_item(
        &self,
        item_id: String,
        text: String,
        author_identifier: Option<String>,
        author_display_name: Option<String>,
        parent_comment_id: Option<String>,
    ) -> Result<CommentRow, StoreApiError> {
        let parent_uuid = parse_uuid(&item_id)?;
        let item = conversion::comment_to_item(
            parent_uuid,
            &text,
            author_identifier.as_deref(),
            author_display_name.as_deref(),
            parent_comment_id.as_deref(),
        );
        self.store.insert(item.clone())?;
        // Look up parent schema for the returned row
        let parent_schema = self.store.get(parent_uuid)?
            .map(|p| p.schema.to_string());
        Ok(item_to_comment_row_with_schema(&item, parent_schema))
    }

    pub fn list_comments(
        &self,
        publication_id: String,
    ) -> Result<Vec<CommentRow>, StoreApiError> {
        self.list_comments_for_item(publication_id)
    }

    /// List comments for any item (publication, artifact, etc.).
    pub fn list_comments_for_item(
        &self,
        item_id: String,
    ) -> Result<Vec<CommentRow>, StoreApiError> {
        let parent_uuid = parse_uuid(&item_id)?;
        let q = ItemQuery {
            schema: Some("imbib/comment".into()),
            predicates: vec![Predicate::HasParent(parent_uuid)],
            sort: vec![SortDescriptor {
                field: "created".into(),
                ascending: true,
            }],
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        // Resolve parent schema once for all comments
        let parent_schema = self.store.get(parent_uuid)?
            .map(|p| p.schema.to_string());
        Ok(items.iter().map(|i| item_to_comment_row_with_schema(i, parent_schema.clone())).collect())
    }

    pub fn update_comment(&self, id: String, text: String) -> Result<(), StoreApiError> {
        let uuid = parse_uuid(&id)?;
        self.store.update(
            uuid,
            vec![FieldMutation::SetPayload(
                "text".into(),
                Value::String(text),
            )],
        )?;
        Ok(())
    }

    // --- Sync support operations ---

    /// Set the origin field on an item (records which device created it).
    /// Bypasses the operation log — this is metadata for sync coordination.
    pub fn set_item_origin(&self, id: String, origin: String) -> Result<(), StoreApiError> {
        let uuid = parse_uuid(&id)?;
        self.store.set_origin(uuid, &origin)?;
        Ok(())
    }

    /// Set the canonical_id field on an item (maps to CKRecord.recordID for CloudKit round-trip).
    /// Bypasses the operation log — this is metadata for sync coordination.
    pub fn set_item_canonical_id(&self, id: String, canonical_id: String) -> Result<(), StoreApiError> {
        let uuid = parse_uuid(&id)?;
        self.store.set_canonical_id(uuid, &canonical_id)?;
        Ok(())
    }

    /// Find an item by its canonical_id (for dedup on CloudKit pull).
    pub fn find_by_canonical_id(&self, canonical_id: String) -> Result<Option<String>, StoreApiError> {
        let item = self.store.find_by_canonical_id(&canonical_id)?;
        Ok(item.map(|i| i.id.to_string()))
    }

    /// List comments created since a given logical clock value (for incremental sync).
    pub fn list_comments_since(&self, item_id: String, since_clock: u64) -> Result<Vec<CommentRow>, StoreApiError> {
        let parent_uuid = parse_uuid(&item_id)?;
        let q = ItemQuery {
            schema: Some("imbib/comment".into()),
            predicates: vec![
                Predicate::HasParent(parent_uuid),
                Predicate::Gt("logical_clock".into(), Value::Int(since_clock as i64)),
            ],
            sort: vec![SortDescriptor {
                field: "created".into(),
                ascending: true,
            }],
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        Ok(items.iter().map(item_to_comment_row).collect())
    }

    // --- Assignment operations ---

    pub fn create_assignment(
        &self,
        publication_id: String,
        assignee_name: String,
        assigned_by_name: Option<String>,
        note: Option<String>,
        due_date: Option<i64>,
    ) -> Result<AssignmentRow, StoreApiError> {
        let pub_uuid = parse_uuid(&publication_id)?;
        let item = conversion::assignment_to_item(
            pub_uuid,
            &assignee_name,
            assigned_by_name.as_deref(),
            note.as_deref(),
            due_date,
        );
        self.store.insert(item.clone())?;
        Ok(item_to_assignment_row(&item))
    }

    pub fn list_assignments(
        &self,
        publication_id: Option<String>,
    ) -> Result<Vec<AssignmentRow>, StoreApiError> {
        let mut predicates = Vec::new();
        if let Some(pid) = publication_id {
            predicates.push(Predicate::HasParent(parse_uuid(&pid)?));
        }
        let q = ItemQuery {
            schema: Some("imbib/assignment".into()),
            predicates,
            sort: vec![SortDescriptor {
                field: "created".into(),
                ascending: false,
            }],
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        Ok(items.iter().map(item_to_assignment_row).collect())
    }

    // --- Activity record operations ---

    pub fn create_activity_record(
        &self,
        library_id: String,
        activity_type: String,
        actor_display_name: Option<String>,
        target_title: Option<String>,
        target_id: Option<String>,
        detail: Option<String>,
    ) -> Result<ActivityRecordRow, StoreApiError> {
        let lib_uuid = parse_uuid(&library_id)?;
        let item = conversion::activity_record_to_item(
            lib_uuid,
            &activity_type,
            actor_display_name.as_deref(),
            target_title.as_deref(),
            target_id.as_deref(),
            detail.as_deref(),
        );
        self.store.insert(item.clone())?;
        Ok(item_to_activity_record_row(&item))
    }

    pub fn list_activity_records(
        &self,
        library_id: String,
        limit: Option<u32>,
        offset: Option<u32>,
    ) -> Result<Vec<ActivityRecordRow>, StoreApiError> {
        let lib_uuid = parse_uuid(&library_id)?;
        let q = ItemQuery {
            schema: Some("imbib/activity-record".into()),
            predicates: vec![Predicate::HasParent(lib_uuid)],
            sort: vec![SortDescriptor {
                field: "created".into(),
                ascending: false,
            }],
            limit: limit.map(|l| l as usize),
            offset: offset.map(|o| o as usize),
        };
        let items = self.store.query(&q)?;
        Ok(items.iter().map(item_to_activity_record_row).collect())
    }

    pub fn clear_activity_records(
        &self,
        library_id: String,
    ) -> Result<(), StoreApiError> {
        let lib_uuid = parse_uuid(&library_id)?;
        let q = ItemQuery {
            schema: Some("imbib/activity-record".into()),
            predicates: vec![Predicate::HasParent(lib_uuid)],
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        for item in &items {
            self.store.delete(item.id)?;
        }
        Ok(())
    }

    // --- Recommendation profile operations ---

    pub fn get_recommendation_profile(
        &self,
        library_id: String,
    ) -> Result<Option<String>, StoreApiError> {
        let lib_uuid = parse_uuid(&library_id)?;
        let q = ItemQuery {
            schema: Some("imbib/recommendation-profile".into()),
            predicates: vec![Predicate::HasParent(lib_uuid)],
            limit: Some(1),
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        if let Some(item) = items.first() {
            let json = serde_json::to_string(&item.payload)
                .unwrap_or_else(|_| "{}".into());
            Ok(Some(json))
        } else {
            Ok(None)
        }
    }

    pub fn create_or_update_recommendation_profile(
        &self,
        library_id: String,
        topic_affinities_json: Option<String>,
        author_affinities_json: Option<String>,
        venue_affinities_json: Option<String>,
        training_events_json: Option<String>,
    ) -> Result<(), StoreApiError> {
        let lib_uuid = parse_uuid(&library_id)?;
        let q = ItemQuery {
            schema: Some("imbib/recommendation-profile".into()),
            predicates: vec![Predicate::HasParent(lib_uuid)],
            limit: Some(1),
            ..Default::default()
        };
        let existing = self.store.query(&q)?;
        if let Some(item) = existing.first() {
            let mut mutations = Vec::new();
            if let Some(v) = topic_affinities_json {
                mutations.push(FieldMutation::SetPayload(
                    "topic_affinities_json".into(),
                    Value::String(v),
                ));
            }
            if let Some(v) = author_affinities_json {
                mutations.push(FieldMutation::SetPayload(
                    "author_affinities_json".into(),
                    Value::String(v),
                ));
            }
            if let Some(v) = venue_affinities_json {
                mutations.push(FieldMutation::SetPayload(
                    "venue_affinities_json".into(),
                    Value::String(v),
                ));
            }
            if let Some(v) = training_events_json {
                mutations.push(FieldMutation::SetPayload(
                    "training_events_json".into(),
                    Value::String(v),
                ));
            }
            if !mutations.is_empty() {
                self.store.update(item.id, mutations)?;
            }
        } else {
            let item = conversion::recommendation_profile_to_item(
                lib_uuid,
                topic_affinities_json.as_deref(),
                author_affinities_json.as_deref(),
                venue_affinities_json.as_deref(),
                training_events_json.as_deref(),
            );
            self.store.insert(item)?;
        }
        Ok(())
    }

    pub fn delete_recommendation_profile(
        &self,
        library_id: String,
    ) -> Result<(), StoreApiError> {
        let lib_uuid = parse_uuid(&library_id)?;
        let q = ItemQuery {
            schema: Some("imbib/recommendation-profile".into()),
            predicates: vec![Predicate::HasParent(lib_uuid)],
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        for item in &items {
            self.store.delete(item.id)?;
        }
        Ok(())
    }

    // --- Tag extensions ---

    /// Delete a tag definition and remove the tag from all publications.
    pub fn delete_tag(&self, path: String) -> Result<(), StoreApiError> {
        let q = ItemQuery {
            schema: Some("imbib/tag-definition".into()),
            predicates: vec![Predicate::Eq(
                "canonical_path".into(),
                Value::String(path.clone()),
            )],
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        for item in &items {
            self.store.delete(item.id)?;
        }
        // Remove the tag from all publications that have it
        let pub_q = ItemQuery {
            schema: Some("imbib/bibliography-entry".into()),
            predicates: vec![Predicate::HasTag(path.clone())],
            ..Default::default()
        };
        let pubs = self.store.query(&pub_q)?;
        for pub_item in &pubs {
            self.store
                .update(pub_item.id, vec![FieldMutation::RemoveTag(path.clone())])?;
        }
        Ok(())
    }

    /// Update tag definition colors.
    pub fn update_tag(
        &self,
        path: String,
        color_light: Option<String>,
        color_dark: Option<String>,
    ) -> Result<(), StoreApiError> {
        let q = ItemQuery {
            schema: Some("imbib/tag-definition".into()),
            predicates: vec![Predicate::Eq(
                "canonical_path".into(),
                Value::String(path),
            )],
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        if let Some(item) = items.first() {
            let mut mutations = Vec::new();
            if let Some(cl) = color_light {
                mutations.push(FieldMutation::SetPayload(
                    "color_light".into(),
                    Value::String(cl),
                ));
            }
            if let Some(cd) = color_dark {
                mutations.push(FieldMutation::SetPayload(
                    "color_dark".into(),
                    Value::String(cd),
                ));
            }
            if !mutations.is_empty() {
                self.store.update(item.id, mutations)?;
            }
        }
        Ok(())
    }

    /// Rename a tag (definition + all assignments on publications).
    pub fn rename_tag(
        &self,
        old_path: String,
        new_path: String,
    ) -> Result<(), StoreApiError> {
        let new_leaf = new_path.rsplit('/').next().unwrap_or(&new_path);
        // Update tag definition
        let q = ItemQuery {
            schema: Some("imbib/tag-definition".into()),
            predicates: vec![Predicate::Eq(
                "canonical_path".into(),
                Value::String(old_path.clone()),
            )],
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        for item in &items {
            self.store.update(
                item.id,
                vec![
                    FieldMutation::SetPayload(
                        "canonical_path".into(),
                        Value::String(new_path.clone()),
                    ),
                    FieldMutation::SetPayload(
                        "name".into(),
                        Value::String(new_leaf.into()),
                    ),
                ],
            )?;
        }
        // Update all publications with this tag
        let pub_q = ItemQuery {
            schema: Some("imbib/bibliography-entry".into()),
            predicates: vec![Predicate::HasTag(old_path.clone())],
            ..Default::default()
        };
        let pubs = self.store.query(&pub_q)?;
        for pub_item in &pubs {
            self.store.update(
                pub_item.id,
                vec![
                    FieldMutation::RemoveTag(old_path.clone()),
                    FieldMutation::AddTag(new_path.clone()),
                ],
            )?;
        }
        Ok(())
    }

    /// List all tag definitions with publication counts.
    pub fn list_tags_with_counts(&self) -> Result<Vec<TagWithCountRow>, StoreApiError> {
        let tag_defs = self.load_tag_definitions()?;
        let mut rows = Vec::new();
        for td in &tag_defs {
            let q = ItemQuery {
                schema: Some("imbib/bibliography-entry".into()),
                predicates: vec![Predicate::HasTag(td.path.clone())],
                ..Default::default()
            };
            let count = self.store.count(&q)? as i32;
            rows.push(TagWithCountRow {
                path: td.path.clone(),
                leaf_name: td.leaf_name.clone(),
                color_light: td.color_light.clone(),
                color_dark: td.color_dark.clone(),
                publication_count: count,
            });
        }
        Ok(rows)
    }

    // --- Bulk operations ---

    pub fn move_publications(
        &self,
        ids: Vec<String>,
        to_library_id: String,
    ) -> Result<UndoInfo, StoreApiError> {
        self.apply_mutation_to_ids(&ids, FieldMutation::SetParent(Some(parse_uuid(&to_library_id)?)))
    }

    pub fn duplicate_publications(
        &self,
        ids: Vec<String>,
        to_library_id: String,
    ) -> Result<Vec<String>, StoreApiError> {
        let to_uuid = parse_uuid(&to_library_id)?;
        // Phase 1: Read all source items and prepare clones
        let mut items_to_insert = Vec::with_capacity(ids.len());
        for id_str in &ids {
            let uuid = parse_uuid(id_str)?;
            if let Some(mut item) = self.store.get(uuid)? {
                item.id = Uuid::new_v4();
                item.parent = Some(to_uuid);
                item.created = Utc::now();
                items_to_insert.push(item);
            }
        }
        if items_to_insert.is_empty() {
            return Ok(vec![]);
        }
        // Phase 2: Single-transaction batch insert
        let new_ids = self.store.insert_batch(items_to_insert)?;
        Ok(new_ids.iter().map(|id| id.to_string()).collect())
    }
    // --- Artifact operations ---

    /// Create a research artifact.
    #[allow(clippy::too_many_arguments)]
    pub fn create_artifact(
        &self,
        schema: String,
        title: String,
        source_url: Option<String>,
        notes: Option<String>,
        artifact_subtype: Option<String>,
        file_name: Option<String>,
        file_hash: Option<String>,
        file_size: Option<i64>,
        file_mime_type: Option<String>,
        capture_context: Option<String>,
        original_author: Option<String>,
        event_name: Option<String>,
        event_date: Option<String>,
        tags: Vec<String>,
    ) -> Result<ArtifactRow, StoreApiError> {
        if !schema.starts_with("impress/artifact/") {
            return Err(StoreApiError::InvalidInput(format!(
                "schema must start with 'impress/artifact/', got: {}",
                schema
            )));
        }
        let item = conversion::artifact_to_item(
            &schema,
            &title,
            source_url.as_deref(),
            notes.as_deref(),
            artifact_subtype.as_deref(),
            file_name.as_deref(),
            file_hash.as_deref(),
            file_size,
            file_mime_type.as_deref(),
            capture_context.as_deref(),
            original_author.as_deref(),
            event_name.as_deref(),
            event_date.as_deref(),
            tags,
        );
        self.store.insert(item.clone())?;
        let tag_defs = self.load_tag_definitions()?;
        Ok(item_to_artifact_row(&item, &tag_defs))
    }

    /// Get a single artifact by ID.
    pub fn get_artifact(&self, id: String) -> Result<Option<ArtifactRow>, StoreApiError> {
        let uuid = parse_uuid(&id)?;
        match self.store.get(uuid)? {
            Some(item) if item.schema.starts_with("impress/artifact/") => {
                let tag_defs = self.load_tag_definitions()?;
                Ok(Some(item_to_artifact_row(&item, &tag_defs)))
            }
            _ => Ok(None),
        }
    }

    /// List artifacts, optionally filtered by a specific schema type.
    /// If schema_filter is None, returns artifacts across all artifact schemas.
    pub fn list_artifacts(
        &self,
        schema_filter: Option<String>,
        sort_field: String,
        ascending: bool,
        limit: Option<u32>,
        offset: Option<u32>,
    ) -> Result<Vec<ArtifactRow>, StoreApiError> {
        let sort = vec![SortDescriptor {
            field: normalize_sort_field(&sort_field),
            ascending,
        }];
        let tag_defs = self.load_tag_definitions()?;

        match schema_filter {
            Some(schema) => {
                let q = ItemQuery {
                    schema: Some(schema),
                    sort,
                    limit: limit.map(|l| l as usize),
                    offset: offset.map(|o| o as usize),
                    ..Default::default()
                };
                let items = self.store.query(&q)?;
                Ok(items
                    .iter()
                    .map(|item| item_to_artifact_row(item, &tag_defs))
                    .collect())
            }
            None => {
                // Query each artifact schema and merge results
                let schemas = [
                    "impress/artifact/presentation",
                    "impress/artifact/poster",
                    "impress/artifact/dataset",
                    "impress/artifact/webpage",
                    "impress/artifact/note",
                    "impress/artifact/media",
                    "impress/artifact/code",
                    "impress/artifact/general",
                ];
                let mut all_items = Vec::new();
                for schema in &schemas {
                    let q = ItemQuery {
                        schema: Some((*schema).into()),
                        ..Default::default()
                    };
                    all_items.extend(self.store.query(&q)?);
                }
                // Sort merged results
                let sort_key = normalize_sort_field(&sort_field);
                all_items.sort_by(|a, b| {
                    let cmp = match sort_key.as_str() {
                        "created" => a.created.cmp(&b.created),
                        "payload.title" => {
                            let at = a.payload.get("title");
                            let bt = b.payload.get("title");
                            format!("{:?}", at).cmp(&format!("{:?}", bt))
                        }
                        _ => a.created.cmp(&b.created),
                    };
                    if ascending { cmp } else { cmp.reverse() }
                });
                // Apply offset/limit
                let start = offset.unwrap_or(0) as usize;
                let rows: Vec<ArtifactRow> = all_items
                    .iter()
                    .skip(start)
                    .take(limit.unwrap_or(u32::MAX) as usize)
                    .map(|item| item_to_artifact_row(item, &tag_defs))
                    .collect();
                Ok(rows)
            }
        }
    }

    /// Search artifacts by text across title, notes, source_url, and original_author.
    pub fn search_artifacts(
        &self,
        query: String,
        schema_filter: Option<String>,
    ) -> Result<Vec<ArtifactRow>, StoreApiError> {
        let search_pred = Predicate::Or(vec![
            Predicate::Contains("title".into(), query.clone()),
            Predicate::Contains("notes".into(), query.clone()),
            Predicate::Contains("source_url".into(), query.clone()),
            Predicate::Contains("original_author".into(), query),
        ]);
        // Query all items, then filter by artifact schema prefix
        let q = ItemQuery {
            schema: schema_filter,
            predicates: vec![search_pred],
            sort: vec![SortDescriptor {
                field: "created".into(),
                ascending: false,
            }],
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        let tag_defs = self.load_tag_definitions()?;
        Ok(items
            .iter()
            .filter(|item| item.schema.starts_with("impress/artifact/"))
            .map(|item| item_to_artifact_row(item, &tag_defs))
            .collect())
    }

    /// Update an artifact's fields.
    pub fn update_artifact(
        &self,
        id: String,
        title: Option<String>,
        source_url: Option<String>,
        notes: Option<String>,
        artifact_subtype: Option<String>,
        capture_context: Option<String>,
        original_author: Option<String>,
        event_name: Option<String>,
        event_date: Option<String>,
    ) -> Result<UndoInfo, StoreApiError> {
        let uuid = parse_uuid(&id)?;
        let mut mutations = Vec::new();
        if let Some(v) = title {
            mutations.push(FieldMutation::SetPayload("title".into(), Value::String(v)));
        }
        if let Some(v) = source_url {
            mutations.push(FieldMutation::SetPayload("source_url".into(), Value::String(v)));
        }
        if let Some(v) = notes {
            mutations.push(FieldMutation::SetPayload("notes".into(), Value::String(v)));
        }
        if let Some(v) = artifact_subtype {
            mutations.push(FieldMutation::SetPayload("artifact_subtype".into(), Value::String(v)));
        }
        if let Some(v) = capture_context {
            mutations.push(FieldMutation::SetPayload("capture_context".into(), Value::String(v)));
        }
        if let Some(v) = original_author {
            mutations.push(FieldMutation::SetPayload("original_author".into(), Value::String(v)));
        }
        if let Some(v) = event_name {
            mutations.push(FieldMutation::SetPayload("event_name".into(), Value::String(v)));
        }
        if let Some(v) = event_date {
            mutations.push(FieldMutation::SetPayload("event_date".into(), Value::String(v)));
        }
        if !mutations.is_empty() {
            Ok(self.store.update_with_undo(uuid, mutations)?.into())
        } else {
            Ok(UndoInfo {
                operation_ids: vec![],
                batch_id: None,
                description: "Update Artifact".into(),
            })
        }
    }

    /// Delete an artifact by ID.
    pub fn delete_artifact(&self, id: String) -> Result<(), StoreApiError> {
        let uuid = parse_uuid(&id)?;
        self.store.delete(uuid)?;
        Ok(())
    }

    /// Link an artifact to a publication via RelatesTo edge.
    pub fn link_artifact_to_publication(
        &self,
        artifact_id: String,
        publication_id: String,
    ) -> Result<UndoInfo, StoreApiError> {
        let art_uuid = parse_uuid(&artifact_id)?;
        let pub_uuid = parse_uuid(&publication_id)?;
        Ok(self.store.update_with_undo(
            art_uuid,
            vec![FieldMutation::AddReference(
                impress_core::reference::TypedReference {
                    target: pub_uuid,
                    edge_type: EdgeType::RelatesTo,
                    metadata: None,
                },
            )],
        )?.into())
    }

    /// Get relations from an artifact to other items.
    pub fn get_artifact_relations(
        &self,
        id: String,
    ) -> Result<Vec<ArtifactRelation>, StoreApiError> {
        let uuid = parse_uuid(&id)?;
        let item = self
            .store
            .get(uuid)?
            .ok_or(StoreApiError::NotFound(id))?;
        let mut relations = Vec::new();
        for reference in &item.references {
            let target_item = self.store.get(reference.target)?;
            let (target_schema, target_title) = match &target_item {
                Some(ti) => {
                    let title = match ti.payload.get("title") {
                        Some(Value::String(s)) => Some(s.clone()),
                        _ => ti.payload.get("name").and_then(|v| match v {
                            Value::String(s) => Some(s.clone()),
                            _ => None,
                        }),
                    };
                    (Some(ti.schema.clone()), title)
                }
                None => (None, None),
            };
            relations.push(ArtifactRelation {
                target_id: reference.target.to_string(),
                edge_type: format!("{:?}", reference.edge_type),
                target_schema,
                target_title,
            });
        }
        Ok(relations)
    }

    /// Count all artifacts, optionally filtered by schema.
    pub fn count_artifacts(
        &self,
        schema_filter: Option<String>,
    ) -> Result<u32, StoreApiError> {
        match schema_filter {
            Some(schema) => {
                let q = ItemQuery {
                    schema: Some(schema),
                    ..Default::default()
                };
                Ok(self.store.count(&q)? as u32)
            }
            None => {
                // Count across all artifact schemas
                let schemas = [
                    "impress/artifact/presentation",
                    "impress/artifact/poster",
                    "impress/artifact/dataset",
                    "impress/artifact/webpage",
                    "impress/artifact/note",
                    "impress/artifact/media",
                    "impress/artifact/code",
                    "impress/artifact/general",
                ];
                let mut total = 0u32;
                for schema in &schemas {
                    let q = ItemQuery {
                        schema: Some((*schema).into()),
                        ..Default::default()
                    };
                    total += self.store.count(&q)? as u32;
                }
                Ok(total)
            }
        }
    }
}

// Internal helpers (not exposed via UniFFI)
impl ImbibStore {
    /// Check whether a publication with matching DOI, arXiv ID, or bibcode already exists
    /// in the given library.
    fn is_duplicate_in_library(
        &self,
        publication: &crate::domain::Publication,
        library_id: Uuid,
    ) -> Result<bool, StoreApiError> {
        let mut or_preds = Vec::new();
        if let Some(ref doi) = publication.identifiers.doi {
            if !doi.is_empty() {
                or_preds.push(Predicate::Eq("doi".into(), Value::String(doi.clone())));
            }
        }
        if let Some(ref arxiv) = publication.identifiers.arxiv_id {
            if !arxiv.is_empty() {
                or_preds.push(Predicate::Eq(
                    "arxiv_id".into(),
                    Value::String(arxiv.clone()),
                ));
                // Also check without version suffix (e.g., "2602.08929" matches "2602.08929v1")
                let stripped = arxiv
                    .trim_end_matches(|c: char| c == 'v' || c.is_ascii_digit())
                    .to_string();
                if stripped != *arxiv && !stripped.is_empty() && stripped.ends_with('.') == false {
                    // Only add if stripping actually removed something and result is valid
                    let without_version =
                        arxiv.split('v').next().unwrap_or(arxiv).to_string();
                    if without_version != *arxiv && !without_version.is_empty() {
                        or_preds.push(Predicate::Eq(
                            "arxiv_id".into(),
                            Value::String(without_version),
                        ));
                    }
                }
            }
        }
        if let Some(ref bibcode) = publication.identifiers.bibcode {
            if !bibcode.is_empty() {
                or_preds.push(Predicate::Eq(
                    "bibcode".into(),
                    Value::String(bibcode.clone()),
                ));
            }
        }
        // Also check by cite key as a fallback
        if !publication.cite_key.is_empty() {
            or_preds.push(Predicate::Eq(
                "cite_key".into(),
                Value::String(publication.cite_key.clone()),
            ));
        }
        if or_preds.is_empty() {
            return Ok(false);
        }
        let q = ItemQuery {
            schema: Some("imbib/bibliography-entry".into()),
            predicates: vec![Predicate::HasParent(library_id), Predicate::Or(or_preds)],
            limit: Some(1),
            ..Default::default()
        };
        Ok(self.store.count(&q)? > 0)
    }

    fn count_children(&self, parent_id: Uuid, schema: &str) -> Result<usize, StoreApiError> {
        let q = ItemQuery {
            schema: Some(schema.into()),
            predicates: vec![Predicate::HasParent(parent_id)],
            ..Default::default()
        };
        Ok(self.store.count(&q)?)
    }

    fn count_collection_members(&self, collection_id: Uuid) -> Result<usize, StoreApiError> {
        // Count items referenced by this collection via Contains edges
        let item = self.store.get(collection_id)?;
        match item {
            Some(item) => Ok(item
                .references
                .iter()
                .filter(|r| r.edge_type == EdgeType::Contains)
                .count()),
            None => Ok(0),
        }
    }

    /// Load all linked-file items that are children of the given publication IDs.
    /// Returns a map from parent UUID to Vec of linked-file Items.
    fn load_linked_files_for_pubs(
        &self,
        pub_ids: &[Uuid],
    ) -> Result<std::collections::HashMap<Uuid, Vec<impress_core::item::Item>>, StoreApiError> {
        use std::collections::HashMap;
        let mut map: HashMap<Uuid, Vec<impress_core::item::Item>> = HashMap::new();
        if pub_ids.is_empty() {
            return Ok(map);
        }
        // Query all linked-file items — cheaper than per-publication queries for large batches
        let q = ItemQuery {
            schema: Some("imbib/linked-file".into()),
            ..Default::default()
        };
        let all_lf = self.store.query(&q)?;
        for lf in all_lf {
            if let Some(parent) = lf.parent {
                if pub_ids.contains(&parent) {
                    map.entry(parent).or_default().push(lf);
                }
            }
        }
        Ok(map)
    }

    /// Convert a batch of publication Items into BibliographyRows, resolving linked file status.
    fn items_to_bibliography_rows(
        &self,
        items: &[impress_core::item::Item],
        tag_defs: &[TagDisplayRow],
    ) -> Result<Vec<BibliographyRow>, StoreApiError> {
        let pub_ids: Vec<Uuid> = items.iter().map(|i| i.id).collect();
        let lf_map = self.load_linked_files_for_pubs(&pub_ids)?;
        Ok(items
            .iter()
            .map(|item| {
                let children = lf_map.get(&item.id).map(|v| v.as_slice()).unwrap_or(&[]);
                item_to_bibliography_row(item, tag_defs, children)
            })
            .collect())
    }

    fn load_tag_definitions(&self) -> Result<Vec<TagDisplayRow>, StoreApiError> {
        let q = ItemQuery {
            schema: Some("imbib/tag-definition".into()),
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        Ok(items
            .iter()
            .map(|item| {
                let payload = &item.payload;
                let path = match payload.get("canonical_path") {
                    Some(Value::String(s)) => s.clone(),
                    _ => String::new(),
                };
                let leaf_name = match payload.get("name") {
                    Some(Value::String(s)) => s.clone(),
                    _ => path.rsplit('/').next().unwrap_or("").to_string(),
                };
                let color_light = match payload.get("color_light") {
                    Some(Value::String(s)) => Some(s.clone()),
                    _ => None,
                };
                let color_dark = match payload.get("color_dark") {
                    Some(Value::String(s)) => Some(s.clone()),
                    _ => None,
                };
                TagDisplayRow {
                    path,
                    leaf_name,
                    color_light,
                    color_dark,
                }
            })
            .collect())
    }
}

fn parse_uuid(s: &str) -> Result<Uuid, StoreApiError> {
    Uuid::parse_str(s).map_err(|e| StoreApiError::InvalidInput(format!("invalid UUID: {}", e)))
}

fn normalize_sort_field(field: &str) -> String {
    match field {
        "dateAdded" | "date_added" | "created" => "created".into(),
        "dateModified" | "date_modified" | "modified" => "modified".into(),
        "title" => "payload.title".into(),
        "author" | "author_text" => "payload.author_text".into(),
        "year" => "payload.year".into(),
        "citeKey" | "cite_key" => "payload.cite_key".into(),
        "citationCount" | "citation_count" => "payload.citation_count".into(),
        f => f.into(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_store() -> Arc<ImbibStore> {
        ImbibStore::open_in_memory().unwrap()
    }

    #[test]
    fn create_and_list_libraries() {
        let store = make_store();
        let lib = store.create_library("My Library".into()).unwrap();
        assert_eq!(lib.name, "My Library");
        assert!(!lib.is_default);

        let libs = store.list_libraries().unwrap();
        assert_eq!(libs.len(), 1);
        assert_eq!(libs[0].name, "My Library");
    }

    #[test]
    fn import_bibtex_and_query() {
        let store = make_store();
        let lib = store.create_library("Test".into()).unwrap();

        let bibtex = r#"
@article{Smith2024,
    title = {Dark Matter in Galaxies},
    author = {Smith, John and Doe, Jane},
    year = {2024},
    journal = {ApJ},
}
@article{Jones2023,
    title = {Stellar Populations},
    author = {Jones, Bob},
    year = {2023},
}
"#;
        let ids = store.import_bibtex(bibtex.into(), lib.id.clone()).unwrap();
        assert_eq!(ids.len(), 2);

        let pubs = store
            .query_publications(lib.id.clone(), "created".into(), true, None, None)
            .unwrap();
        assert_eq!(pubs.len(), 2);

        // Check library count
        let libs = store.list_libraries().unwrap();
        assert_eq!(libs[0].publication_count, 2);
    }

    #[test]
    fn set_read_and_starred() {
        let store = make_store();
        let lib = store.create_library("Test".into()).unwrap();
        let bibtex = "@article{X, title={Test}}";
        let ids = store.import_bibtex(bibtex.into(), lib.id.clone()).unwrap();

        store.set_read(ids.clone(), true).unwrap();
        store.set_starred(ids.clone(), true).unwrap();

        let pub_row = store.get_publication(ids[0].clone()).unwrap().unwrap();
        assert!(pub_row.is_read);
        assert!(pub_row.is_starred);
    }

    #[test]
    fn set_and_clear_flag() {
        let store = make_store();
        let lib = store.create_library("Test".into()).unwrap();
        let bibtex = "@article{X, title={Test}}";
        let ids = store.import_bibtex(bibtex.into(), lib.id.clone()).unwrap();

        store
            .set_flag(
                ids.clone(),
                Some("red".into()),
                Some("solid".into()),
                None,
            )
            .unwrap();
        let pub_row = store.get_publication(ids[0].clone()).unwrap().unwrap();
        assert_eq!(pub_row.flag_color, Some("red".into()));
        assert_eq!(pub_row.flag_style, Some("solid".into()));

        // Get flagged
        let flagged = store.get_flagged_publications(Some("red".into())).unwrap();
        assert_eq!(flagged.len(), 1);

        // Clear flag
        store.set_flag(ids.clone(), None, None, None).unwrap();
        let pub_row2 = store.get_publication(ids[0].clone()).unwrap().unwrap();
        assert!(pub_row2.flag_color.is_none());
    }

    #[test]
    fn tag_operations() {
        let store = make_store();
        let lib = store.create_library("Test".into()).unwrap();
        let bibtex = "@article{X, title={Test}}";
        let ids = store.import_bibtex(bibtex.into(), lib.id.clone()).unwrap();

        // Create tag definition
        store
            .create_tag(
                "methods/sims".into(),
                Some("#ff0000".into()),
                Some("#cc0000".into()),
            )
            .unwrap();

        // Add tag to publication
        store
            .add_tag(ids.clone(), "methods/sims".into())
            .unwrap();

        let pub_row = store.get_publication(ids[0].clone()).unwrap().unwrap();
        assert_eq!(pub_row.tags.len(), 1);
        assert_eq!(pub_row.tags[0].path, "methods/sims");
        assert_eq!(pub_row.tags[0].color_light, Some("#ff0000".into()));

        // Remove tag
        store
            .remove_tag(ids.clone(), "methods/sims".into())
            .unwrap();
        let pub_row2 = store.get_publication(ids[0].clone()).unwrap().unwrap();
        assert_eq!(pub_row2.tags.len(), 0);
    }

    #[test]
    fn search_publications() {
        let store = make_store();
        let lib = store.create_library("Test".into()).unwrap();
        let bibtex = r#"
@article{A, title={Dark Matter Distribution}}
@article{B, title={Stellar Populations in the MW}}
"#;
        store.import_bibtex(bibtex.into(), lib.id.clone()).unwrap();

        let results = store
            .search_publications("Dark Matter".into(), Some(lib.id.clone()))
            .unwrap();
        assert_eq!(results.len(), 1);
        assert!(results[0].title.contains("Dark Matter"));
    }

    #[test]
    fn export_bibtex_round_trip() {
        let store = make_store();
        let lib = store.create_library("Test".into()).unwrap();
        let bibtex = "@article{Smith2024,\n    title = {Dark Matter},\n    year = {2024},\n}\n";
        let ids = store.import_bibtex(bibtex.into(), lib.id.clone()).unwrap();

        let exported = store.export_bibtex(ids).unwrap();
        assert!(exported.contains("Smith2024"));
        assert!(exported.contains("Dark Matter"));
    }

    #[test]
    fn collection_operations() {
        let store = make_store();
        let lib = store.create_library("Test".into()).unwrap();

        let coll = store
            .create_collection("Favorites".into(), lib.id.clone(), false, None)
            .unwrap();
        assert_eq!(coll.name, "Favorites");

        let colls = store.list_collections(lib.id.clone()).unwrap();
        assert_eq!(colls.len(), 1);
    }

    #[test]
    fn delete_publication() {
        let store = make_store();
        let lib = store.create_library("Test".into()).unwrap();
        let bibtex = "@article{X, title={Test}}";
        let ids = store.import_bibtex(bibtex.into(), lib.id.clone()).unwrap();

        store.delete_publications(ids.clone()).unwrap();
        let pub_row = store.get_publication(ids[0].clone()).unwrap();
        assert!(pub_row.is_none());
    }

    #[test]
    fn update_field() {
        let store = make_store();
        let lib = store.create_library("Test".into()).unwrap();
        let bibtex = "@article{X, title={Old Title}}";
        let ids = store.import_bibtex(bibtex.into(), lib.id.clone()).unwrap();

        store
            .update_field(ids[0].clone(), "title".into(), Some("New Title".into()))
            .unwrap();
        let pub_row = store.get_publication(ids[0].clone()).unwrap().unwrap();
        assert_eq!(pub_row.title, "New Title");
    }

    #[test]
    fn publication_detail() {
        let store = make_store();
        let lib = store.create_library("Test".into()).unwrap();
        let bibtex = "@article{Smith2024, title={A Paper}, year={2024}, doi={10.1234/test}}";
        let ids = store.import_bibtex(bibtex.into(), lib.id.clone()).unwrap();

        let detail = store
            .get_publication_detail(ids[0].clone())
            .unwrap()
            .unwrap();
        assert_eq!(detail.cite_key, "Smith2024");
        assert_eq!(detail.entry_type, "article");
        assert!(detail.fields.contains_key("title"));
        assert!(detail.fields.contains_key("doi"));
    }

    #[test]
    fn list_tags() {
        let store = make_store();
        store
            .create_tag("methods/sims".into(), Some("#ff0".into()), None)
            .unwrap();
        store
            .create_tag("topics/cosmo".into(), None, None)
            .unwrap();

        let tags = store.list_tags().unwrap();
        assert_eq!(tags.len(), 2);
    }

    // --- New method tests ---

    #[test]
    fn library_extensions() {
        let store = make_store();
        let lib = store.create_library("Test".into()).unwrap();

        let fetched = store.get_library(lib.id.clone()).unwrap().unwrap();
        assert_eq!(fetched.name, "Test");

        store.set_library_default(lib.id.clone()).unwrap();
        let default = store.get_default_library().unwrap().unwrap();
        assert_eq!(default.id, lib.id);
        assert!(default.is_default);

        // Create second library, set as default — first should be unset
        let lib2 = store.create_library("Test2".into()).unwrap();
        store.set_library_default(lib2.id.clone()).unwrap();
        let old = store.get_library(lib.id.clone()).unwrap().unwrap();
        assert!(!old.is_default);
    }

    #[test]
    fn linked_file_operations() {
        let store = make_store();
        let lib = store.create_library("Test".into()).unwrap();
        let ids = store
            .import_bibtex("@article{X, title={Test}}".into(), lib.id.clone())
            .unwrap();

        let lf = store
            .add_linked_file(
                ids[0].clone(),
                "paper.pdf".into(),
                Some("Papers/paper.pdf".into()),
                Some("pdf".into()),
                1024,
                None,
                true,
            )
            .unwrap();
        assert_eq!(lf.filename, "paper.pdf");
        assert!(lf.is_pdf);

        let files = store.list_linked_files(ids[0].clone()).unwrap();
        assert_eq!(files.len(), 1);

        let fetched = store.get_linked_file(lf.id.clone()).unwrap().unwrap();
        assert_eq!(fetched.filename, "paper.pdf");

        assert_eq!(store.count_pdfs(ids[0].clone()).unwrap(), 1);

        store
            .set_pdf_cloud_available(lf.id.clone(), true)
            .unwrap();
        let updated = store.get_linked_file(lf.id.clone()).unwrap().unwrap();
        assert!(updated.pdf_cloud_available);

        store
            .set_locally_materialized(lf.id.clone(), false)
            .unwrap();
        let updated2 = store.get_linked_file(lf.id).unwrap().unwrap();
        assert!(!updated2.is_locally_materialized);
    }

    #[test]
    fn smart_search_operations() {
        let store = make_store();
        let lib = store.create_library("Test".into()).unwrap();

        let ss = store
            .create_smart_search(
                "Dark Matter".into(),
                "dark matter galaxies".into(),
                lib.id.clone(),
                Some("[\"ADS\"]".into()),
                50,
                true,
                false,
                3600,
            )
            .unwrap();
        assert_eq!(ss.name, "Dark Matter");
        assert!(ss.feeds_to_inbox);

        let searches = store.list_smart_searches(Some(lib.id)).unwrap();
        assert_eq!(searches.len(), 1);

        let fetched = store.get_smart_search(ss.id).unwrap().unwrap();
        assert_eq!(fetched.query, "dark matter galaxies");
    }

    #[test]
    fn inbox_and_triage() {
        let store = make_store();

        // No inbox initially
        assert!(store.get_inbox_library().unwrap().is_none());

        let inbox = store.create_inbox_library("Inbox".into()).unwrap();
        assert!(inbox.is_inbox);

        let fetched = store.get_inbox_library().unwrap().unwrap();
        assert_eq!(fetched.id, inbox.id);

        // Muted items
        let muted = store
            .create_muted_item("author".into(), "Smith, John".into())
            .unwrap();
        assert_eq!(muted.mute_type, "author");

        let all_muted = store.list_muted_items(None).unwrap();
        assert_eq!(all_muted.len(), 1);

        let by_type = store
            .list_muted_items(Some("author".into()))
            .unwrap();
        assert_eq!(by_type.len(), 1);

        store.delete_item(muted.id).unwrap();
        assert_eq!(store.list_muted_items(None).unwrap().len(), 0);

        // Dismissed papers
        let dismissed = store
            .dismiss_paper(Some("10.1234/test".into()), None, None)
            .unwrap();
        assert_eq!(dismissed.doi, Some("10.1234/test".into()));

        assert!(store
            .is_paper_dismissed(Some("10.1234/test".into()), None, None)
            .unwrap());
        assert!(!store
            .is_paper_dismissed(Some("10.9999/other".into()), None, None)
            .unwrap());

        let papers = store.list_dismissed_papers(None, None).unwrap();
        assert_eq!(papers.len(), 1);
    }

    #[test]
    fn deduplication_queries() {
        let store = make_store();
        let lib = store.create_library("Test".into()).unwrap();
        let bibtex = r#"
@article{A, title={Paper A}, doi={10.1234/a}, eprint={2401.00001}, archiveprefix={arXiv}}
@article{B, title={Paper B}, doi={10.1234/b}, bibcode={2024ApJ...900....1S}}
"#;
        store.import_bibtex(bibtex.into(), lib.id).unwrap();

        let by_doi = store.find_by_doi("10.1234/a".into()).unwrap();
        assert_eq!(by_doi.len(), 1);
        assert_eq!(by_doi[0].cite_key, "A");

        let by_arxiv = store.find_by_arxiv("2401.00001".into()).unwrap();
        assert_eq!(by_arxiv.len(), 1);

        let by_bibcode = store
            .find_by_bibcode("2024ApJ...900....1S".into())
            .unwrap();
        assert_eq!(by_bibcode.len(), 1);

        let by_ids = store
            .find_by_identifiers(
                Some("10.1234/a".into()),
                None,
                Some("2024ApJ...900....1S".into()),
                None,
            )
            .unwrap();
        assert_eq!(by_ids.len(), 2);
    }

    #[test]
    fn advanced_queries() {
        let store = make_store();
        let lib = store.create_library("Test".into()).unwrap();
        let bibtex = r#"
@article{A, title={Dark Matter Distribution}, author={Smith, John}, abstract={We study DM}}
@article{B, title={Stellar Populations}, author={Jones, Bob}}
"#;
        let ids = store.import_bibtex(bibtex.into(), lib.id.clone()).unwrap();

        // All unread initially
        let unread = store.query_unread(Some(lib.id.clone())).unwrap();
        assert_eq!(unread.len(), 2);
        assert_eq!(store.count_unread(Some(lib.id.clone())).unwrap(), 2);

        // Mark one as read
        store.set_read(vec![ids[0].clone()], true).unwrap();
        assert_eq!(store.count_unread(Some(lib.id.clone())).unwrap(), 1);

        // Starred
        store.set_starred(vec![ids[0].clone()], true).unwrap();
        let starred = store.query_starred(Some(lib.id.clone())).unwrap();
        assert_eq!(starred.len(), 1);

        // By tag
        store
            .create_tag("cosmo".into(), None, None)
            .unwrap();
        store
            .add_tag(vec![ids[0].clone()], "cosmo".into())
            .unwrap();
        let by_tag = store.query_by_tag("cosmo".into(), None).unwrap();
        assert_eq!(by_tag.len(), 1);

        // Recent
        let recent = store.query_recent(1, Some(lib.id.clone())).unwrap();
        assert_eq!(recent.len(), 1);

        // Full text search
        let fts = store
            .full_text_search("Dark Matter".into(), Some(lib.id.clone()), None)
            .unwrap();
        assert_eq!(fts.len(), 1);

        // Find by cite key
        let found = store
            .find_by_cite_key("A".into(), Some(lib.id))
            .unwrap();
        assert!(found.is_some());
        assert_eq!(found.unwrap().cite_key, "A");
    }

    #[test]
    fn scix_library_operations() {
        let store = make_store();

        let scix = store
            .create_scix_library(
                "remote-123".into(),
                "My ADS Lib".into(),
                Some("A test library".into()),
                true,
                "owner".into(),
                Some("test@example.com".into()),
            )
            .unwrap();
        assert_eq!(scix.name, "My ADS Lib");
        assert!(scix.is_public);

        let all = store.list_scix_libraries().unwrap();
        assert_eq!(all.len(), 1);

        let fetched = store.get_scix_library(scix.id.clone()).unwrap().unwrap();
        assert_eq!(fetched.remote_id, "remote-123");

        store.delete_item(scix.id).unwrap();
        assert_eq!(store.list_scix_libraries().unwrap().len(), 0);
    }

    #[test]
    fn annotation_operations() {
        let store = make_store();
        let lib = store.create_library("Test".into()).unwrap();
        let ids = store
            .import_bibtex("@article{X, title={Test}}".into(), lib.id)
            .unwrap();
        let lf = store
            .add_linked_file(ids[0].clone(), "paper.pdf".into(), None, None, 0, None, true)
            .unwrap();

        let ann = store
            .create_annotation(
                lf.id.clone(),
                "highlight".into(),
                5,
                None,
                Some("#ffff00".into()),
                None,
                Some("dark matter".into()),
            )
            .unwrap();
        assert_eq!(ann.annotation_type, "highlight");
        assert_eq!(ann.page_number, 5);

        let anns = store.list_annotations(lf.id.clone(), None).unwrap();
        assert_eq!(anns.len(), 1);

        let page5 = store.list_annotations(lf.id.clone(), Some(5)).unwrap();
        assert_eq!(page5.len(), 1);

        let page1 = store.list_annotations(lf.id.clone(), Some(1)).unwrap();
        assert_eq!(page1.len(), 0);

        assert_eq!(store.count_annotations(lf.id).unwrap(), 1);
    }

    #[test]
    fn comment_operations() {
        let store = make_store();
        let lib = store.create_library("Test".into()).unwrap();
        let ids = store
            .import_bibtex("@article{X, title={Test}}".into(), lib.id)
            .unwrap();

        let comment = store
            .create_comment(
                ids[0].clone(),
                "Great paper!".into(),
                Some("user-1".into()),
                Some("Jane".into()),
                None,
            )
            .unwrap();
        assert_eq!(comment.text, "Great paper!");

        let comments = store.list_comments(ids[0].clone()).unwrap();
        assert_eq!(comments.len(), 1);

        store
            .update_comment(comment.id.clone(), "Updated comment".into())
            .unwrap();
        let updated = store.list_comments(ids[0].clone()).unwrap();
        assert_eq!(updated[0].text, "Updated comment");

        store.delete_item(comment.id).unwrap();
        assert_eq!(store.list_comments(ids[0].clone()).unwrap().len(), 0);
    }

    #[test]
    fn assignment_operations() {
        let store = make_store();
        let lib = store.create_library("Test".into()).unwrap();
        let ids = store
            .import_bibtex("@article{X, title={Test}}".into(), lib.id)
            .unwrap();

        let assignment = store
            .create_assignment(
                ids[0].clone(),
                "Alice".into(),
                Some("Bob".into()),
                Some("Read by Friday".into()),
                Some(1700000000000),
            )
            .unwrap();
        assert_eq!(assignment.assignee_name, "Alice");

        let list = store.list_assignments(Some(ids[0].clone())).unwrap();
        assert_eq!(list.len(), 1);

        store.delete_item(assignment.id).unwrap();
        assert_eq!(
            store.list_assignments(Some(ids[0].clone())).unwrap().len(),
            0
        );
    }

    #[test]
    fn activity_record_operations() {
        let store = make_store();
        let lib = store.create_library("Test".into()).unwrap();

        store
            .create_activity_record(
                lib.id.clone(),
                "added".into(),
                Some("Jane".into()),
                Some("Dark Matter Paper".into()),
                None,
                None,
            )
            .unwrap();
        store
            .create_activity_record(
                lib.id.clone(),
                "tagged".into(),
                Some("Jane".into()),
                None,
                None,
                None,
            )
            .unwrap();

        let records = store
            .list_activity_records(lib.id.clone(), None, None)
            .unwrap();
        assert_eq!(records.len(), 2);

        let limited = store
            .list_activity_records(lib.id.clone(), Some(1), None)
            .unwrap();
        assert_eq!(limited.len(), 1);

        store.clear_activity_records(lib.id.clone()).unwrap();
        assert_eq!(
            store
                .list_activity_records(lib.id, None, None)
                .unwrap()
                .len(),
            0
        );
    }

    #[test]
    fn recommendation_profile_operations() {
        let store = make_store();
        let lib = store.create_library("Test".into()).unwrap();

        assert!(store
            .get_recommendation_profile(lib.id.clone())
            .unwrap()
            .is_none());

        store
            .create_or_update_recommendation_profile(
                lib.id.clone(),
                Some("{\"cosmo\":0.8}".into()),
                None,
                None,
                None,
            )
            .unwrap();

        let profile = store
            .get_recommendation_profile(lib.id.clone())
            .unwrap()
            .unwrap();
        assert!(profile.contains("cosmo"));

        // Update existing
        store
            .create_or_update_recommendation_profile(
                lib.id.clone(),
                Some("{\"cosmo\":0.9}".into()),
                None,
                None,
                None,
            )
            .unwrap();
        let updated = store
            .get_recommendation_profile(lib.id.clone())
            .unwrap()
            .unwrap();
        assert!(updated.contains("0.9"));

        store
            .delete_recommendation_profile(lib.id.clone())
            .unwrap();
        assert!(store
            .get_recommendation_profile(lib.id)
            .unwrap()
            .is_none());
    }

    #[test]
    fn tag_extensions() {
        let store = make_store();
        let lib = store.create_library("Test".into()).unwrap();
        let ids = store
            .import_bibtex("@article{X, title={Test}}".into(), lib.id)
            .unwrap();

        store
            .create_tag("methods/sims".into(), Some("#ff0".into()), None)
            .unwrap();
        store
            .add_tag(vec![ids[0].clone()], "methods/sims".into())
            .unwrap();

        // Tags with counts
        let tags = store.list_tags_with_counts().unwrap();
        assert_eq!(tags.len(), 1);
        assert_eq!(tags[0].publication_count, 1);

        // Update tag colors
        store
            .update_tag(
                "methods/sims".into(),
                Some("#00ff00".into()),
                Some("#009900".into()),
            )
            .unwrap();
        let updated = store.list_tags().unwrap();
        assert_eq!(updated[0].color_light, Some("#00ff00".into()));

        // Rename tag
        store
            .rename_tag("methods/sims".into(), "techniques/numerical".into())
            .unwrap();
        let pub_row = store.get_publication(ids[0].clone()).unwrap().unwrap();
        assert!(pub_row.tags.iter().any(|t| t.path == "techniques/numerical"));
        assert!(!pub_row.tags.iter().any(|t| t.path == "methods/sims"));

        // Delete tag
        store.delete_tag("techniques/numerical".into()).unwrap();
        let pub_row2 = store.get_publication(ids[0].clone()).unwrap().unwrap();
        assert!(pub_row2.tags.is_empty());
        assert_eq!(store.list_tags().unwrap().len(), 0);
    }

    #[test]
    fn collection_members() {
        let store = make_store();
        let lib = store.create_library("Test".into()).unwrap();
        let bibtex = r#"
@article{A, title={Alpha}, year={2020}}
@article{B, title={Beta}, year={2024}}
"#;
        let ids = store.import_bibtex(bibtex.into(), lib.id.clone()).unwrap();

        let coll = store
            .create_collection("Favorites".into(), lib.id, false, None)
            .unwrap();
        store
            .add_to_collection(ids.clone(), coll.id.clone())
            .unwrap();

        let members = store
            .list_collection_members(coll.id.clone(), "year".into(), true, None, None)
            .unwrap();
        assert_eq!(members.len(), 2);
        // Should be sorted by year ascending: 2020 before 2024
        assert_eq!(members[0].year, Some(2020));
        assert_eq!(members[1].year, Some(2024));

        // With limit
        let limited = store
            .list_collection_members(coll.id, "year".into(), false, Some(1), None)
            .unwrap();
        assert_eq!(limited.len(), 1);
        assert_eq!(limited[0].year, Some(2024)); // descending
    }

    #[test]
    fn bulk_operations() {
        let store = make_store();
        let lib1 = store.create_library("Lib1".into()).unwrap();
        let lib2 = store.create_library("Lib2".into()).unwrap();
        let ids = store
            .import_bibtex("@article{X, title={Test}}".into(), lib1.id.clone())
            .unwrap();

        // Move
        store
            .move_publications(ids.clone(), lib2.id.clone())
            .unwrap();
        let pubs1 = store
            .query_publications(lib1.id.clone(), "created".into(), true, None, None)
            .unwrap();
        assert_eq!(pubs1.len(), 0);
        let pubs2 = store
            .query_publications(lib2.id.clone(), "created".into(), true, None, None)
            .unwrap();
        assert_eq!(pubs2.len(), 1);

        // Duplicate back
        let new_ids = store
            .duplicate_publications(ids, lib1.id.clone())
            .unwrap();
        assert_eq!(new_ids.len(), 1);
        let pubs1_after = store
            .query_publications(lib1.id, "created".into(), true, None, None)
            .unwrap();
        assert_eq!(pubs1_after.len(), 1);
        // Original still in lib2
        let pubs2_after = store
            .query_publications(lib2.id, "created".into(), true, None, None)
            .unwrap();
        assert_eq!(pubs2_after.len(), 1);
    }

    #[test]
    fn generic_helpers() {
        let store = make_store();
        let lib = store.create_library("Test".into()).unwrap();
        let ids = store
            .import_bibtex("@article{X, title={Test}}".into(), lib.id)
            .unwrap();

        // update_int_field
        store
            .update_int_field(ids[0].clone(), "citation_count".into(), Some(42))
            .unwrap();
        let pub_row = store.get_publication(ids[0].clone()).unwrap().unwrap();
        assert_eq!(pub_row.citation_count, 42);

        // update_bool_field (via linked file)
        let lf = store
            .add_linked_file(ids[0].clone(), "f.pdf".into(), None, None, 0, None, true)
            .unwrap();
        store
            .update_bool_field(lf.id.clone(), "pdf_cloud_available".into(), true)
            .unwrap();
        let updated = store.get_linked_file(lf.id.clone()).unwrap().unwrap();
        assert!(updated.pdf_cloud_available);

        // delete_item
        store.delete_item(lf.id.clone()).unwrap();
        assert!(store.get_linked_file(lf.id).unwrap().is_none());
    }

    #[test]
    fn import_bibtex_deduplication() {
        let store = make_store();
        let lib = store.create_library("Test".into()).unwrap();
        let bibtex = r#"@article{A, title={Paper A}, doi={10.1234/a}}"#;
        let ids1 = store.import_bibtex(bibtex.into(), lib.id.clone()).unwrap();
        assert_eq!(ids1.len(), 1);

        // Import again with same DOI — should be skipped
        let bibtex2 = r#"@article{B, title={Paper A copy}, doi={10.1234/a}}"#;
        let ids2 = store.import_bibtex(bibtex2.into(), lib.id.clone()).unwrap();
        assert_eq!(ids2.len(), 0);

        // Import into a different library — should NOT be deduplicated
        let lib2 = store.create_library("Other".into()).unwrap();
        let ids3 = store.import_bibtex(bibtex.into(), lib2.id).unwrap();
        assert_eq!(ids3.len(), 1);

        // Entry without identifiers — should always be imported
        let bibtex3 = r#"@article{C, title={No ID}}"#;
        let ids4 = store.import_bibtex(bibtex3.into(), lib.id).unwrap();
        assert_eq!(ids4.len(), 1);
    }

    #[test]
    fn search_publications_multi_field() {
        let store = make_store();
        let lib = store.create_library("Test".into()).unwrap();
        let bibtex = r#"
@article{A, title={Stellar Evolution}, author={Smith, John}, abstract={We study star formation}}
@article{B, title={Galaxy Mergers}, author={Jones, Bob}, note={Important paper on merging galaxies}}
@article{C, title={Dark Energy}, author={Williams, Alice}}
"#;
        store.import_bibtex(bibtex.into(), lib.id.clone()).unwrap();

        // Search by title
        let r1 = store.search_publications("Stellar".into(), Some(lib.id.clone())).unwrap();
        assert_eq!(r1.len(), 1);
        assert_eq!(r1[0].cite_key, "A");

        // Search by author
        let r2 = store.search_publications("Jones".into(), Some(lib.id.clone())).unwrap();
        assert_eq!(r2.len(), 1);
        assert_eq!(r2[0].cite_key, "B");

        // Search by abstract
        let r3 = store.search_publications("star formation".into(), Some(lib.id.clone())).unwrap();
        assert_eq!(r3.len(), 1);
        assert_eq!(r3[0].cite_key, "A");

        // Search by note
        let r4 = store.search_publications("merging galaxies".into(), Some(lib.id.clone())).unwrap();
        assert_eq!(r4.len(), 1);
        assert_eq!(r4[0].cite_key, "B");
    }

    #[test]
    fn bibliography_row_linked_file_status() {
        let store = make_store();
        let lib = store.create_library("Test".into()).unwrap();
        let ids = store
            .import_bibtex("@article{X, title={Test}}".into(), lib.id)
            .unwrap();
        let pub_id = &ids[0];

        // Before any linked files — both false
        let row = store.get_publication(pub_id.clone()).unwrap().unwrap();
        assert!(!row.has_downloaded_pdf);
        assert!(!row.has_other_attachments);

        // Add a PDF that is locally materialized
        let lf = store
            .add_linked_file(
                pub_id.clone(),
                "paper.pdf".into(),
                None,
                None,
                1024,
                None,
                true,
            )
            .unwrap();
        store
            .set_locally_materialized(lf.id.clone(), true)
            .unwrap();

        let row2 = store.get_publication(pub_id.clone()).unwrap().unwrap();
        assert!(row2.has_downloaded_pdf);
        assert!(!row2.has_other_attachments);

        // Add a non-PDF attachment
        store
            .add_linked_file(
                pub_id.clone(),
                "data.csv".into(),
                None,
                None,
                512,
                None,
                false,
            )
            .unwrap();

        let row3 = store.get_publication(pub_id.clone()).unwrap().unwrap();
        assert!(row3.has_downloaded_pdf);
        assert!(row3.has_other_attachments);
    }

    #[test]
    fn publication_detail_linked_files_and_collections() {
        let store = make_store();
        let lib = store.create_library("Test".into()).unwrap();
        let ids = store
            .import_bibtex("@article{X, title={Test}}".into(), lib.id.clone())
            .unwrap();
        let pub_id = &ids[0];

        // Add linked file
        store
            .add_linked_file(pub_id.clone(), "paper.pdf".into(), None, None, 2048, None, true)
            .unwrap();

        // Add to a collection
        let coll = store
            .create_collection("Favorites".into(), lib.id, false, None)
            .unwrap();
        store
            .add_to_collection(vec![pub_id.clone()], coll.id.clone())
            .unwrap();

        let detail = store
            .get_publication_detail(pub_id.clone())
            .unwrap()
            .unwrap();
        assert_eq!(detail.linked_files.len(), 1);
        assert_eq!(detail.linked_files[0].filename, "paper.pdf");
        assert!(detail.collections.contains(&coll.id));
        assert_eq!(detail.libraries.len(), 1);
    }

    #[test]
    fn artifact_crud() {
        let store = make_store();

        // Create artifact
        let art = store
            .create_artifact(
                "impress/artifact/presentation".into(),
                "My Talk on Dark Matter".into(),
                Some("https://example.com/talk".into()),
                Some("Great talk at AAS".into()),
                None,
                Some("talk.pdf".into()),
                None,
                Some(1024000),
                Some("application/pdf".into()),
                Some("AAS 245".into()),
                Some("Jane Doe".into()),
                Some("AAS 245".into()),
                Some("2025-01-15".into()),
                vec!["talks".into()],
            )
            .unwrap();
        assert_eq!(art.title, "My Talk on Dark Matter");
        assert_eq!(art.schema, "impress/artifact/presentation");
        assert_eq!(art.source_url, Some("https://example.com/talk".into()));
        assert_eq!(art.file_name, Some("talk.pdf".into()));
        assert_eq!(art.file_size, Some(1024000));
        assert_eq!(art.tags.len(), 1);

        // Get by ID
        let fetched = store.get_artifact(art.id.clone()).unwrap().unwrap();
        assert_eq!(fetched.title, "My Talk on Dark Matter");

        // List (all schemas)
        let all = store
            .list_artifacts(None, "created".into(), false, None, None)
            .unwrap();
        assert_eq!(all.len(), 1);

        // List (specific schema)
        let presentations = store
            .list_artifacts(
                Some("impress/artifact/presentation".into()),
                "created".into(),
                false,
                None,
                None,
            )
            .unwrap();
        assert_eq!(presentations.len(), 1);

        let notes = store
            .list_artifacts(
                Some("impress/artifact/note".into()),
                "created".into(),
                false,
                None,
                None,
            )
            .unwrap();
        assert_eq!(notes.len(), 0);

        // Search
        let results = store.search_artifacts("Dark Matter".into(), None).unwrap();
        assert_eq!(results.len(), 1);

        let no_results = store.search_artifacts("quantum".into(), None).unwrap();
        assert_eq!(no_results.len(), 0);

        // Update
        store
            .update_artifact(
                art.id.clone(),
                Some("Updated Talk Title".into()),
                None,
                None,
                None,
                None,
                None,
                None,
                None,
            )
            .unwrap();
        let updated = store.get_artifact(art.id.clone()).unwrap().unwrap();
        assert_eq!(updated.title, "Updated Talk Title");

        // Count
        let count = store.count_artifacts(None).unwrap();
        assert_eq!(count, 1);

        let pres_count = store
            .count_artifacts(Some("impress/artifact/presentation".into()))
            .unwrap();
        assert_eq!(pres_count, 1);

        // Delete
        store.delete_artifact(art.id.clone()).unwrap();
        assert!(store.get_artifact(art.id).unwrap().is_none());
        assert_eq!(store.count_artifacts(None).unwrap(), 0);
    }

    #[test]
    fn artifact_link_to_publication() {
        let store = make_store();
        let lib = store.create_library("Test".into()).unwrap();

        let bibtex = r#"@article{Smith2024, title={Dark Matter}, author={Smith}, year={2024}}"#;
        let pub_ids = store.import_bibtex(bibtex.into(), lib.id.clone()).unwrap();
        assert_eq!(pub_ids.len(), 1);

        let art = store
            .create_artifact(
                "impress/artifact/note".into(),
                "Notes on Dark Matter Paper".into(),
                None,
                Some("Key findings from Smith2024".into()),
                None, None, None, None, None, None, None, None, None,
                vec![],
            )
            .unwrap();

        // Link artifact to publication
        store
            .link_artifact_to_publication(art.id.clone(), pub_ids[0].clone())
            .unwrap();

        // Verify relation
        let relations = store.get_artifact_relations(art.id).unwrap();
        assert_eq!(relations.len(), 1);
        assert_eq!(relations[0].target_id, pub_ids[0]);
        assert_eq!(relations[0].target_title, Some("Dark Matter".into()));
    }

    #[test]
    fn artifact_invalid_schema_rejected() {
        let store = make_store();
        let result = store.create_artifact(
            "imbib/bibliography-entry".into(),
            "Should Fail".into(),
            None, None, None, None, None, None, None, None, None, None, None,
            vec![],
        );
        assert!(result.is_err());
    }
}
