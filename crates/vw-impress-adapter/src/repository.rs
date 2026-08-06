use std::collections::BTreeMap;
use std::sync::{Arc, RwLock};

use impress_core::item::{ActorKind, Item, Priority, Value, Visibility};
use impress_core::query::{ItemQuery, SortDescriptor};
use impress_core::reference::{EdgeType, TypedReference};
use impress_core::schemas::SOURCE_CITATION_SCHEMA;
use impress_core::source::SourceCitation;
use impress_core::sqlite_store::SqliteItemStore;
use impress_core::store::{FieldMutation, ItemStore};
use uuid::Uuid;
use vw_domain::{
    DiagnosticRepository, DiagnosticSession, KnowledgePack, RepositoryError, SessionId,
};

use crate::schemas::{
    VW_COMMAND_RECEIPT_SCHEMA, VW_CONFIGURATION_SCHEMA, VW_DIAGNOSTIC_SESSION_SCHEMA,
    VW_KNOWLEDGE_PACK_SCHEMA, VW_MEASUREMENT_SCHEMA, VW_OBSERVATION_SCHEMA,
    VW_PROCEDURE_RUN_SCHEMA, VW_VEHICLE_SCHEMA,
};

#[derive(Clone)]
pub struct ImpressDiagnosticRepository {
    store: Arc<SqliteItemStore>,
    active_pack: Arc<RwLock<KnowledgePack>>,
}

impl ImpressDiagnosticRepository {
    pub fn new(store: Arc<SqliteItemStore>, pack: KnowledgePack) -> Self {
        Self {
            store,
            active_pack: Arc::new(RwLock::new(pack)),
        }
    }

    pub fn store(&self) -> &Arc<SqliteItemStore> {
        &self.store
    }

    pub fn replace_active_pack(&self, pack: KnowledgePack) -> Result<(), RepositoryError> {
        pack.validate()
            .map_err(|error| RepositoryError::Serialization(error.to_string()))?;
        self.validate_pack_citations(&pack)?;
        self.persist_pack(&pack)?;
        *self
            .active_pack
            .write()
            .map_err(|error| RepositoryError::Storage(error.to_string()))? = pack;
        Ok(())
    }

    fn validate_pack_citations(&self, pack: &KnowledgePack) -> Result<(), RepositoryError> {
        let mut ids = std::collections::BTreeSet::new();
        for component in &pack.components {
            ids.extend(component.citation_ids.iter().map(|id| id.0.as_str()));
        }
        for hypothesis in &pack.hypotheses {
            ids.extend(hypothesis.citation_ids.iter().map(|id| id.0.as_str()));
        }
        for procedure in &pack.procedures {
            ids.extend(procedure.citation_ids.iter().map(|id| id.0.as_str()));
            ids.extend(
                procedure
                    .hazards
                    .iter()
                    .map(|hazard| hazard.citation_id.0.as_str()),
            );
            for step in &procedure.steps {
                ids.extend(step.citation_ids.iter().map(|id| id.0.as_str()));
                ids.extend(
                    step.hazards
                        .iter()
                        .map(|hazard| hazard.citation_id.0.as_str()),
                );
            }
        }
        for rule in &pack.rules {
            ids.extend(rule.citation_ids.iter().map(|id| id.0.as_str()));
        }
        for citation_id in ids {
            let uuid = parse_uuid(citation_id, "citation_id")?;
            let item = self
                .store
                .get(uuid)
                .map_err(storage)?
                .ok_or_else(|| RepositoryError::NotFound(format!("citation {citation_id}")))?;
            if item.schema != SOURCE_CITATION_SCHEMA {
                return Err(RepositoryError::Serialization(format!(
                    "{citation_id} is not a source citation"
                )));
            }
            let citation: SourceCitation = decode_data(&item)?;
            citation
                .validate()
                .map_err(|error| RepositoryError::Serialization(error.to_string()))?;
        }
        Ok(())
    }

    fn persist_pack(&self, pack: &KnowledgePack) -> Result<(), RepositoryError> {
        let id = Uuid::new_v5(
            &Uuid::from_u128(0x777e7fc8_bf11_4f40_8cc9_8a7c4667bf74),
            format!("{}@{}", pack.manifest.id, pack.manifest.version).as_bytes(),
        );
        if let Some(existing) = self.store.get(id).map_err(storage)? {
            let stored: KnowledgePack = decode_data(&existing)?;
            if stored == *pack {
                return Ok(());
            }
            return Err(RepositoryError::Serialization(format!(
                "knowledge pack {}@{} is immutable and already exists with different content",
                pack.manifest.id, pack.manifest.version
            )));
        }
        let mut payload = data_payload(
            &format!("{} {}", pack.manifest.id, pack.manifest.version),
            pack,
        )?;
        payload.insert("pack_id".into(), Value::String(pack.manifest.id.clone()));
        payload.insert(
            "pack_version".into(),
            Value::String(pack.manifest.version.clone()),
        );
        payload.insert(
            "content_hash".into(),
            Value::String(pack.manifest.content_hash.clone()),
        );
        self.store
            .insert(item(id, VW_KNOWLEDGE_PACK_SCHEMA, payload, vec![], None))
            .map_err(storage)?;
        Ok(())
    }

    pub fn replay_command(
        &self,
        command_id: &str,
    ) -> Result<Option<DiagnosticSession>, RepositoryError> {
        let id = command_receipt_id(command_id)?;
        self.store
            .get(id)
            .map_err(storage)?
            .filter(|item| item.schema == VW_COMMAND_RECEIPT_SCHEMA)
            .map(|item| decode_data(&item))
            .transpose()
    }

    pub fn record_command(
        &self,
        command_id: &str,
        session: &DiagnosticSession,
    ) -> Result<(), RepositoryError> {
        let id = command_receipt_id(command_id)?;
        if self.store.get(id).map_err(storage)?.is_some() {
            return Ok(());
        }
        let session_id = parse_uuid(&session.id.0, "session_id")?;
        let mut payload = data_payload("Command receipt", session)?;
        payload.insert("command_id".into(), Value::String(command_id.into()));
        payload.insert("session_id".into(), Value::String(session.id.0.clone()));
        self.store
            .insert(item(
                id,
                VW_COMMAND_RECEIPT_SCHEMA,
                payload,
                vec![reference(session_id, EdgeType::OperatesOn)],
                Some(session_id),
            ))
            .map_err(storage)?;
        Ok(())
    }

    fn sync_children(&self, session: &DiagnosticSession) -> Result<(), RepositoryError> {
        let parent = parse_uuid(&session.id.0, "session_id")?;
        for observation in &session.observations {
            let mut payload = data_payload("Observation", observation)?;
            payload.insert("session_id".into(), Value::String(session.id.0.clone()));
            if let Some(component) = &observation.component_key {
                payload.insert("component_key".into(), Value::String(component.clone()));
            }
            let mut references = vec![reference(parent, EdgeType::IsPartOf)];
            if let Some(superseded) = &observation.supersedes {
                references.push(reference(
                    parse_uuid(&superseded.0, "supersedes")?,
                    EdgeType::Supersedes,
                ));
            }
            self.upsert_child(
                parse_uuid(&observation.id.0, "observation_id")?,
                VW_OBSERVATION_SCHEMA,
                payload,
                references,
                parent,
            )?;
        }
        for measurement in &session.measurements {
            let mut payload = data_payload("Measurement", measurement)?;
            payload.insert("session_id".into(), Value::String(session.id.0.clone()));
            payload.insert(
                "quantity".into(),
                Value::String(measurement.quantity.clone()),
            );
            payload.insert("unit".into(), Value::String(measurement.value.unit.clone()));
            if let Some(component) = &measurement.component_key {
                payload.insert("component_key".into(), Value::String(component.clone()));
            }
            self.upsert_child(
                parse_uuid(&measurement.id.0, "measurement_id")?,
                VW_MEASUREMENT_SCHEMA,
                payload,
                vec![reference(parent, EdgeType::IsPartOf)],
                parent,
            )?;
        }
        for run in &session.procedure_runs {
            let mut payload = data_payload(&format!("Procedure {}", run.procedure_id), run)?;
            payload.insert("session_id".into(), Value::String(session.id.0.clone()));
            payload.insert(
                "procedure_id".into(),
                Value::String(run.procedure_id.clone()),
            );
            payload.insert("state".into(), json_value(&run.state)?);
            self.upsert_child(
                parse_uuid(&run.id.0, "procedure_run_id")?,
                VW_PROCEDURE_RUN_SCHEMA,
                payload,
                vec![reference(parent, EdgeType::IsPartOf)],
                parent,
            )?;
        }
        Ok(())
    }

    fn upsert_child(
        &self,
        id: Uuid,
        schema: &str,
        payload: BTreeMap<String, Value>,
        references: Vec<TypedReference>,
        parent: Uuid,
    ) -> Result<(), RepositoryError> {
        if self.store.get(id).map_err(storage)?.is_some() {
            let data = payload
                .get("data")
                .cloned()
                .ok_or_else(|| RepositoryError::Serialization("child data missing".into()))?;
            let state = payload.get("state").cloned();
            let mut mutations = vec![FieldMutation::SetPayload("data".into(), data)];
            if let Some(state) = state {
                mutations.push(FieldMutation::SetPayload("state".into(), state));
            }
            self.store.update(id, mutations).map_err(storage)?;
        } else {
            self.store
                .insert(item(id, schema, payload, references, Some(parent)))
                .map_err(storage)?;
        }
        Ok(())
    }
}

impl DiagnosticRepository for ImpressDiagnosticRepository {
    fn create_session(&self, session: &DiagnosticSession) -> Result<(), RepositoryError> {
        let session_id = parse_uuid(&session.id.0, "session_id")?;
        let vehicle_id = parse_uuid(&session.vehicle.id.0, "vehicle_id")?;
        let configuration_id = parse_uuid(&session.vehicle.configuration.id.0, "configuration_id")?;

        let mut config_payload =
            data_payload("VW vehicle configuration", &session.vehicle.configuration)?;
        config_payload.insert(
            "model_year".into(),
            Value::Int(i64::from(session.vehicle.configuration.model_year)),
        );
        config_payload.insert(
            "market".into(),
            json_value(&session.vehicle.configuration.market)?,
        );
        config_payload.insert(
            "engine_code".into(),
            Value::String(session.vehicle.configuration.engine_code.clone()),
        );
        config_payload.insert(
            "fuel_system".into(),
            Value::String(session.vehicle.configuration.fuel_system.clone()),
        );

        let mut vehicle_payload = data_payload(&session.vehicle.display_name, &session.vehicle)?;
        vehicle_payload.insert(
            "configuration_id".into(),
            Value::String(configuration_id.to_string()),
        );

        let mut session_payload = data_payload(&session.concern, session)?;
        session_payload.insert("state".into(), json_value(&session.state)?);
        session_payload.insert(
            "revision".into(),
            Value::Int(i64::try_from(session.revision).unwrap_or(i64::MAX)),
        );
        session_payload.insert("vehicle_id".into(), Value::String(vehicle_id.to_string()));
        session_payload.insert(
            "knowledge_pack".into(),
            Value::String(format!(
                "{}@{}",
                session.knowledge_pack_id, session.knowledge_pack_version
            )),
        );

        self.store
            .insert_batch(vec![
                item(
                    configuration_id,
                    VW_CONFIGURATION_SCHEMA,
                    config_payload,
                    vec![],
                    None,
                ),
                item(
                    vehicle_id,
                    VW_VEHICLE_SCHEMA,
                    vehicle_payload,
                    vec![reference(configuration_id, EdgeType::RelatesTo)],
                    None,
                ),
                item(
                    session_id,
                    VW_DIAGNOSTIC_SESSION_SCHEMA,
                    session_payload,
                    vec![reference(vehicle_id, EdgeType::OperatesOn)],
                    None,
                ),
            ])
            .map_err(storage)?;
        self.sync_children(session)
    }

    fn get_session(&self, id: &SessionId) -> Result<Option<DiagnosticSession>, RepositoryError> {
        let id = parse_uuid(&id.0, "session_id")?;
        self.store
            .get(id)
            .map_err(storage)?
            .filter(|item| item.schema == VW_DIAGNOSTIC_SESSION_SCHEMA)
            .map(|item| decode_data(&item))
            .transpose()
    }

    fn save_session(
        &self,
        session: &DiagnosticSession,
        expected_revision: u64,
    ) -> Result<(), RepositoryError> {
        let id = parse_uuid(&session.id.0, "session_id")?;
        let current = self
            .store
            .get(id)
            .map_err(storage)?
            .ok_or_else(|| RepositoryError::NotFound(session.id.0.clone()))?;
        let current_session: DiagnosticSession = decode_data(&current)?;
        if current_session.revision != expected_revision {
            return Err(RepositoryError::StaleRevision {
                expected: expected_revision,
                actual: current_session.revision,
            });
        }
        self.sync_children(session)?;
        self.store
            .update(
                id,
                vec![
                    FieldMutation::SetPayload("data".into(), json_value(session)?),
                    FieldMutation::SetPayload("state".into(), json_value(&session.state)?),
                    FieldMutation::SetPayload(
                        "revision".into(),
                        Value::Int(i64::try_from(session.revision).unwrap_or(i64::MAX)),
                    ),
                ],
            )
            .map_err(storage)
    }

    fn list_sessions(&self, limit: usize) -> Result<Vec<DiagnosticSession>, RepositoryError> {
        self.store
            .query(&ItemQuery {
                schema: Some(VW_DIAGNOSTIC_SESSION_SCHEMA.into()),
                sort: vec![SortDescriptor {
                    field: "modified".into(),
                    ascending: false,
                }],
                limit: Some(limit.min(100)),
                include_tags: false,
                include_references: false,
                ..Default::default()
            })
            .map_err(storage)?
            .iter()
            .map(decode_data)
            .collect()
    }

    fn active_knowledge_pack(&self) -> Result<KnowledgePack, RepositoryError> {
        self.active_pack
            .read()
            .map_err(|error| RepositoryError::Storage(error.to_string()))
            .map(|pack| pack.clone())
    }
}

fn item(
    id: Uuid,
    schema: &str,
    payload: BTreeMap<String, Value>,
    references: Vec<TypedReference>,
    parent: Option<Uuid>,
) -> Item {
    let now = chrono::Utc::now();
    Item {
        id,
        schema: schema.into(),
        payload,
        created: now,
        modified: now,
        author: "vw-diagnostic-service".into(),
        author_kind: ActorKind::System,
        logical_clock: 0,
        origin: None,
        canonical_id: None,
        tags: vec![],
        flag: None,
        is_read: false,
        is_starred: false,
        priority: Priority::Normal,
        visibility: Visibility::Private,
        message_type: None,
        produced_by: None,
        version: Some("1.0.0".into()),
        batch_id: None,
        references,
        parent,
    }
}

fn reference(target: Uuid, edge_type: EdgeType) -> TypedReference {
    TypedReference {
        target,
        edge_type,
        metadata: None,
    }
}

fn data_payload<T: serde::Serialize>(
    title: &str,
    data: &T,
) -> Result<BTreeMap<String, Value>, RepositoryError> {
    Ok(BTreeMap::from([
        ("title".into(), Value::String(title.into())),
        ("data".into(), json_value(data)?),
    ]))
}

fn json_value<T: serde::Serialize>(value: &T) -> Result<Value, RepositoryError> {
    serde_json::from_value(
        serde_json::to_value(value)
            .map_err(|error| RepositoryError::Serialization(error.to_string()))?,
    )
    .map_err(|error| RepositoryError::Serialization(error.to_string()))
}

fn decode_data<T: serde::de::DeserializeOwned>(item: &Item) -> Result<T, RepositoryError> {
    let value = item
        .payload
        .get("data")
        .ok_or_else(|| RepositoryError::Serialization("item has no data payload".into()))?;
    serde_json::from_value(
        serde_json::to_value(value)
            .map_err(|error| RepositoryError::Serialization(error.to_string()))?,
    )
    .map_err(|error| RepositoryError::Serialization(error.to_string()))
}

fn parse_uuid(value: &str, field: &str) -> Result<Uuid, RepositoryError> {
    Uuid::parse_str(value)
        .map_err(|error| RepositoryError::Serialization(format!("{field}: {error}")))
}

fn command_receipt_id(command_id: &str) -> Result<Uuid, RepositoryError> {
    let parsed = parse_uuid(command_id, "command_id")?;
    Ok(Uuid::new_v5(
        &Uuid::from_u128(0x7bc7a7a8_0ab8_4c2e_a1c4_38a41050c55d),
        parsed.as_bytes(),
    ))
}

fn storage(error: impress_core::store::StoreError) -> RepositoryError {
    RepositoryError::Storage(error.to_string())
}
