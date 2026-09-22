//! Thin mapping between the standalone VW domain and Impress infrastructure.

pub mod photo;
pub mod repository;
pub mod schemas;
pub mod service;

pub use photo::{PhotoDescription, PhotoEvidenceStore};
pub use repository::ImpressDiagnosticRepository;
pub use schemas::{
    register_vw_schemas, VW_COMMAND_RECEIPT_SCHEMA, VW_CONFIGURATION_SCHEMA,
    VW_DIAGNOSTIC_SESSION_SCHEMA, VW_KNOWLEDGE_PACK_SCHEMA, VW_MEASUREMENT_SCHEMA,
    VW_OBSERVATION_SCHEMA, VW_PHOTO_EVIDENCE_SCHEMA, VW_PROCEDURE_RUN_SCHEMA, VW_VEHICLE_SCHEMA,
};
pub use service::{activate_default_pack, default_vw_service, DefaultVwDiagnosticService};
