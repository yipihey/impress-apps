//! Mirroring papers to an e-ink tablet and importing what comes back.
//!
//! The tablet is reached through `impress-remarkable` (today: the USB web
//! interface, which needs no credential). Everything that decides *what*
//! happens lives here, in Rust, so the same engine serves the app, the CLI
//! and the MCP tools:
//!
//! * [`config`] — the device record and the mirror-state vocabulary;
//! * [`store`] — the `imbib/eink-device` and `imbib/eink-mirror` rows on
//!   [`crate::unified::store_api::ImbibStore`], including the list-row marker;
//! * [`paths`] — where a linked file lives on disk, mirrored from the Swift
//!   `AttachmentManager` ladder, so a headless process finds the same PDF.
//!
//! The planner, transport and import modules build on these.

pub mod apply;
pub mod collections;
pub mod config;
pub mod folders;
pub mod import;
pub mod naming;
pub mod paths;
pub mod planner;
pub mod status;
pub mod store;
pub mod transport;

pub use apply::import_publication;
pub use apply::{
    run_sync, EinkImportSink, EinkSyncReport, ImportHandoff, ImportOutcome, ImportedDocument,
    NoopSink, SyncOptions,
};
pub use config::{
    EinkDeviceConfig, FolderStrategy, MirrorMode, MirrorState, UploadFormat, DEFAULT_ROOT_FOLDER,
    SCHEMA_DEVICE, SCHEMA_MIRROR, TRANSPORT_USB_WEB,
};
pub use folders::{FolderMap, FolderNeed};
pub use import::{
    EinkDocumentImportOutcome, EinkOcrJob, EinkUnmatchedDocument, ImportDocumentRequest,
    StoreImportSink,
};
pub use planner::{PlanSummary, SyncPlan};
pub use status::{EinkCounts, EinkStatus};
pub use store::{
    EinkAwaitingSource, EinkDeviceConfigInput, EinkDeviceRow, EinkLocalSource, EinkMarkOutcome,
    EinkMirrorRow, EinkRowState,
};
pub use transport::{EinkError, EinkTransport, MockTransport, UsbWebTransport};
