//! `ImbibUndoService` — exposes the imbib undo stack.

use std::sync::Arc;

use imbib_core::unified::store_api::ImbibStore;
use impress_service_core::async_trait;
use impress_service_macros::{impress_service, impress_service_impl};
use serde::{Deserialize, Serialize};

use crate::library_service::MutationResult;
use crate::store_singleton::store_instance;

#[allow(unused_imports)]
use impress_service_macros::impress_method;

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct UndoGroupRecord {
    #[serde(alias = "operationId", alias = "operationID", default)]
    pub operation_id: String,
    #[serde(alias = "batchId", alias = "batchID", default)]
    pub batch_id: Option<String>,
    #[serde(alias = "operationCount", default)]
    pub operation_count: u32,
    #[serde(default)]
    pub description: String,
    #[serde(default)]
    pub timestamp: i64,
}

impl From<&imbib_core::unified::store_api::UndoGroupRow> for UndoGroupRecord {
    fn from(r: &imbib_core::unified::store_api::UndoGroupRow) -> Self {
        Self {
            operation_id: r.operation_id.clone(),
            batch_id: r.batch_id.clone(),
            operation_count: r.operation_count,
            description: r.description.clone(),
            timestamp: r.timestamp,
        }
    }
}

#[impress_service]
pub trait ImbibUndoService: Send + Sync + 'static {
    /// List the most recent undoable operation groups, newest first.
    #[impress_method]
    async fn recent_undo_groups(&self, max_entries: u32) -> Vec<UndoGroupRecord>;
    /// Undo a single operation by id.
    #[impress_method]
    async fn undo_operation(&self, operation_id: String) -> MutationResult;
    /// Undo all operations sharing a batch id.
    #[impress_method]
    async fn undo_batch(&self, batch_id: String) -> MutationResult;
}

#[derive(Clone)]
pub struct DefaultImbibUndoService { store: Arc<ImbibStore> }
impl DefaultImbibUndoService { pub fn new(store: Arc<ImbibStore>) -> Self { Self { store } } }

fn log(m: &str, e: impl std::fmt::Display) { eprintln!("[imbib-undo-service] {m}: {e}"); }

#[async_trait::async_trait]
impl ImbibUndoService for DefaultImbibUndoService {
    async fn recent_undo_groups(&self, max_entries: u32) -> Vec<UndoGroupRecord> {
        let n = if max_entries == 0 { 25 } else { max_entries };
        self.store.recent_undo_groups(n)
            .map(|rs| rs.iter().map(UndoGroupRecord::from).collect::<Vec<_>>())
            .unwrap_or_else(|e| { log("recent_undo_groups", e); vec![] })
    }
    async fn undo_operation(&self, operation_id: String) -> MutationResult {
        match self.store.undo_operation(operation_id) {
            Ok(info) => MutationResult { affected_count: info.operation_ids.len() as u32, ok: true },
            Err(e) => { log("undo_operation", e); MutationResult { affected_count: 0, ok: false } }
        }
    }
    async fn undo_batch(&self, batch_id: String) -> MutationResult {
        match self.store.undo_batch(batch_id) {
            Ok(info) => MutationResult { affected_count: info.operation_ids.len() as u32, ok: true },
            Err(e) => { log("undo_batch", e); MutationResult { affected_count: 0, ok: false } }
        }
    }
}

impress_service_impl! {
    service = ImbibUndoService,
    impl = DefaultImbibUndoService,
    instance = || crate::backend::undo_service_instance(),
    methods = [
        recent_undo_groups(max_entries: u32) -> Vec<UndoGroupRecord>,
        undo_operation(operation_id: String) -> MutationResult,
        undo_batch(batch_id: String) -> MutationResult,
    ],
}
