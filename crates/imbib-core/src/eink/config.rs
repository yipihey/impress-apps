//! The device record and the mirror-state vocabulary.

use std::collections::BTreeMap;

use impress_core::item::{Item, Value};

/// Exact store spellings; the store matches `schema_ref` by equality.
pub const SCHEMA_DEVICE: &str = "imbib/eink-device";
pub const SCHEMA_MIRROR: &str = "imbib/eink-mirror";
/// The transport every device this engine ships uses today.
pub const TRANSPORT_USB_WEB: &str = "usb-web";
/// The folder at the top of the tablet that holds everything imbib sends.
pub const DEFAULT_ROOT_FOLDER: &str = "imbib";

/// Whether every paper with a local PDF/ePUB goes to the tablet, or only the
/// ones the user marks. The list-row marker exists only in the second mode.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MirrorMode {
    All,
    Individual,
}

impl MirrorMode {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::All => "all",
            Self::Individual => "individual",
        }
    }

    pub fn parse(value: &str) -> Option<Self> {
        match value.trim().to_ascii_lowercase().as_str() {
            "all" | "everything" => Some(Self::All),
            "individual" | "marked" | "chosen" => Some(Self::Individual),
            _ => None,
        }
    }
}

/// How folders that do not exist on the tablet get made. The USB web
/// interface has no folder-creation endpoint; `Rmdoc` uploads a folder
/// archive (works only if the firmware honours it — established by the P0
/// spike), `Checklist` asks the user to create them by hand and holds the
/// affected papers in `awaiting_folder` meanwhile.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FolderStrategy {
    Rmdoc,
    Checklist,
}

impl FolderStrategy {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Rmdoc => "rmdoc",
            Self::Checklist => "checklist",
        }
    }

    pub fn parse(value: &str) -> Option<Self> {
        match value.trim().to_ascii_lowercase().as_str() {
            "rmdoc" => Some(Self::Rmdoc),
            "checklist" | "manual" => Some(Self::Checklist),
            _ => None,
        }
    }
}

/// How a paper is sent. `Rmdoc` wraps the file in a reMarkable archive so
/// the tablet keeps the exact name; `Pdf` uploads the bare file, which the
/// tablet names `<file>.pdf`. (P0 spike, Paper Pro firmware 3.x: the
/// archive's name is honoured, its id and parent are not.)
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UploadFormat {
    Rmdoc,
    Pdf,
}

impl UploadFormat {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Rmdoc => "rmdoc",
            Self::Pdf => "pdf",
        }
    }

    pub fn parse(value: &str) -> Option<Self> {
        match value.trim().to_ascii_lowercase().as_str() {
            "rmdoc" | "archive" => Some(Self::Rmdoc),
            "pdf" | "plain" | "file" => Some(Self::Pdf),
            _ => None,
        }
    }
}

/// One publication's state on one device.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum MirrorState {
    /// Marked (or in scope) with a local source; waiting for a sync.
    Queued,
    /// Marked, but no PDF/ePUB is on this Mac yet; the app fetches it.
    AwaitingSource,
    /// The target folder does not exist on the tablet yet.
    AwaitingFolder,
    /// On the tablet, matching the local file.
    Uploaded,
    /// On the tablet, but the local file changed since the upload. Never
    /// re-sent automatically: the tablet copy carries the user's ink.
    Stale,
    /// Was on the tablet; the user deleted it there. Never re-sent unless
    /// asked to.
    RemovedOnDevice,
    /// The last attempt failed; `last_error` says why.
    Failed,
    /// Replaced by a newer copy (after "Update on tablet").
    Superseded,
    /// The user un-marked it after it was uploaded; the tablet copy stays
    /// (nothing can delete over USB) and imbib stops touching it.
    Unmarked,
}

impl MirrorState {
    pub const ALL: [MirrorState; 9] = [
        Self::Queued,
        Self::AwaitingSource,
        Self::AwaitingFolder,
        Self::Uploaded,
        Self::Stale,
        Self::RemovedOnDevice,
        Self::Failed,
        Self::Superseded,
        Self::Unmarked,
    ];

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Queued => "queued",
            Self::AwaitingSource => "awaiting_source",
            Self::AwaitingFolder => "awaiting_folder",
            Self::Uploaded => "uploaded",
            Self::Stale => "stale",
            Self::RemovedOnDevice => "removed_on_device",
            Self::Failed => "failed",
            Self::Superseded => "superseded",
            Self::Unmarked => "unmarked",
        }
    }

    pub fn parse(value: &str) -> Option<Self> {
        Self::ALL
            .iter()
            .copied()
            .find(|state| state.as_str() == value.trim())
    }

    /// Whether a list row shows a marker for this state.
    pub fn shows_marker(self) -> bool {
        !matches!(self, Self::Superseded | Self::Unmarked)
    }

    /// Whether a copy is (as far as imbib knows) on the tablet.
    pub fn is_on_tablet(self) -> bool {
        matches!(self, Self::Uploaded | Self::Stale | Self::Unmarked)
    }

    /// Whether the user's mark is still in force.
    pub fn is_marked(self) -> bool {
        !matches!(self, Self::Unmarked)
    }
}

/// A device as the store holds it.
#[derive(Debug, Clone, PartialEq)]
pub struct EinkDeviceConfig {
    pub id: String,
    pub name: String,
    pub transport: String,
    pub base_url: String,
    pub mirror_mode: MirrorMode,
    pub root_folder_name: String,
    pub mirror_collections: bool,
    pub include_library_level: bool,
    pub include_inbox: bool,
    pub folder_strategy: FolderStrategy,
    pub upload_format: UploadFormat,
    pub auto_fetch_source: bool,
    pub import_annotated_pdf: bool,
    pub import_rmdoc: bool,
    pub import_highlights: bool,
    pub import_ink: bool,
    pub import_typed_text: bool,
    pub run_ocr: bool,
    pub auto_import_on_connect: bool,
    pub enabled: bool,
    pub last_sync_at_ms: Option<i64>,
    pub last_seen_at_ms: Option<i64>,
    pub sync_started_at_ms: Option<i64>,
    pub last_error: Option<String>,
}

impl EinkDeviceConfig {
    /// A reMarkable reached over USB, with the defaults the plan names.
    pub fn usb_web(id: impl Into<String>, name: impl Into<String>) -> Self {
        Self {
            id: id.into(),
            name: name.into(),
            transport: TRANSPORT_USB_WEB.into(),
            base_url: impress_remarkable::usb_web::DEFAULT_BASE_URL.into(),
            mirror_mode: MirrorMode::Individual,
            root_folder_name: DEFAULT_ROOT_FOLDER.into(),
            mirror_collections: true,
            include_library_level: true,
            include_inbox: false,
            folder_strategy: FolderStrategy::Checklist,
            upload_format: UploadFormat::Rmdoc,
            auto_fetch_source: true,
            import_annotated_pdf: true,
            import_rmdoc: true,
            import_highlights: true,
            import_ink: true,
            import_typed_text: true,
            run_ocr: true,
            auto_import_on_connect: true,
            enabled: true,
            last_sync_at_ms: None,
            last_seen_at_ms: None,
            sync_started_at_ms: None,
            last_error: None,
        }
    }

    pub fn is_individual(&self) -> bool {
        self.mirror_mode == MirrorMode::Individual
    }

    pub fn from_item(item: &Item) -> Self {
        let p = &item.payload;
        let defaults = Self::usb_web(item.id.to_string(), "");
        Self {
            id: item.id.to_string(),
            name: str_of(p, "name").unwrap_or_default(),
            transport: str_of(p, "transport").unwrap_or(defaults.transport),
            base_url: str_of(p, "base_url")
                .filter(|url| !url.is_empty())
                .unwrap_or(defaults.base_url),
            mirror_mode: str_of(p, "mirror_mode")
                .and_then(|value| MirrorMode::parse(&value))
                .unwrap_or(defaults.mirror_mode),
            root_folder_name: str_of(p, "root_folder_name")
                .filter(|name| !name.trim().is_empty())
                .unwrap_or(defaults.root_folder_name),
            mirror_collections: bool_or(p, "mirror_collections", defaults.mirror_collections),
            include_library_level: bool_or(
                p,
                "include_library_level",
                defaults.include_library_level,
            ),
            include_inbox: bool_or(p, "include_inbox", defaults.include_inbox),
            folder_strategy: str_of(p, "folder_strategy")
                .and_then(|value| FolderStrategy::parse(&value))
                .unwrap_or(defaults.folder_strategy),
            upload_format: str_of(p, "upload_format")
                .and_then(|value| UploadFormat::parse(&value))
                .unwrap_or(defaults.upload_format),
            auto_fetch_source: bool_or(p, "auto_fetch_source", defaults.auto_fetch_source),
            import_annotated_pdf: bool_or(p, "import_annotated_pdf", defaults.import_annotated_pdf),
            import_rmdoc: bool_or(p, "import_rmdoc", defaults.import_rmdoc),
            import_highlights: bool_or(p, "import_highlights", defaults.import_highlights),
            import_ink: bool_or(p, "import_ink", defaults.import_ink),
            import_typed_text: bool_or(p, "import_typed_text", defaults.import_typed_text),
            run_ocr: bool_or(p, "run_ocr", defaults.run_ocr),
            auto_import_on_connect: bool_or(
                p,
                "auto_import_on_connect",
                defaults.auto_import_on_connect,
            ),
            enabled: bool_or(p, "enabled", defaults.enabled),
            last_sync_at_ms: int_of(p, "last_sync_at_ms"),
            last_seen_at_ms: int_of(p, "last_seen_at_ms"),
            sync_started_at_ms: int_of(p, "sync_started_at_ms"),
            last_error: str_of(p, "last_error"),
        }
    }

    pub fn to_payload(&self) -> BTreeMap<String, Value> {
        let mut p = BTreeMap::new();
        p.insert("name".into(), Value::String(self.name.clone()));
        p.insert("transport".into(), Value::String(self.transport.clone()));
        p.insert("base_url".into(), Value::String(self.base_url.clone()));
        p.insert(
            "mirror_mode".into(),
            Value::String(self.mirror_mode.as_str().into()),
        );
        p.insert(
            "root_folder_name".into(),
            Value::String(self.root_folder_name.clone()),
        );
        p.insert(
            "mirror_collections".into(),
            Value::Bool(self.mirror_collections),
        );
        p.insert(
            "include_library_level".into(),
            Value::Bool(self.include_library_level),
        );
        p.insert("include_inbox".into(), Value::Bool(self.include_inbox));
        p.insert(
            "folder_strategy".into(),
            Value::String(self.folder_strategy.as_str().into()),
        );
        p.insert(
            "upload_format".into(),
            Value::String(self.upload_format.as_str().into()),
        );
        p.insert(
            "auto_fetch_source".into(),
            Value::Bool(self.auto_fetch_source),
        );
        p.insert(
            "import_annotated_pdf".into(),
            Value::Bool(self.import_annotated_pdf),
        );
        p.insert("import_rmdoc".into(), Value::Bool(self.import_rmdoc));
        p.insert(
            "import_highlights".into(),
            Value::Bool(self.import_highlights),
        );
        p.insert("import_ink".into(), Value::Bool(self.import_ink));
        p.insert(
            "import_typed_text".into(),
            Value::Bool(self.import_typed_text),
        );
        p.insert("run_ocr".into(), Value::Bool(self.run_ocr));
        p.insert(
            "auto_import_on_connect".into(),
            Value::Bool(self.auto_import_on_connect),
        );
        p.insert("enabled".into(), Value::Bool(self.enabled));
        if let Some(ms) = self.last_sync_at_ms {
            p.insert("last_sync_at_ms".into(), Value::Int(ms));
        }
        if let Some(ms) = self.last_seen_at_ms {
            p.insert("last_seen_at_ms".into(), Value::Int(ms));
        }
        if let Some(ms) = self.sync_started_at_ms {
            p.insert("sync_started_at_ms".into(), Value::Int(ms));
        }
        if let Some(error) = &self.last_error {
            p.insert("last_error".into(), Value::String(error.clone()));
        }
        p
    }
}

pub(crate) fn str_of(payload: &BTreeMap<String, Value>, key: &str) -> Option<String> {
    match payload.get(key) {
        Some(Value::String(s)) => Some(s.clone()),
        _ => None,
    }
}

pub(crate) fn int_of(payload: &BTreeMap<String, Value>, key: &str) -> Option<i64> {
    match payload.get(key) {
        Some(Value::Int(i)) => Some(*i),
        Some(Value::Float(f)) => Some(*f as i64),
        _ => None,
    }
}

pub(crate) fn bool_or(payload: &BTreeMap<String, Value>, key: &str, default: bool) -> bool {
    match payload.get(key) {
        Some(Value::Bool(b)) => *b,
        Some(Value::Int(i)) => *i != 0,
        _ => default,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn states_round_trip_through_their_spellings() {
        for state in MirrorState::ALL {
            assert_eq!(MirrorState::parse(state.as_str()), Some(state));
        }
        assert_eq!(MirrorState::parse("bogus"), None);
        assert!(!MirrorState::Unmarked.shows_marker());
        assert!(!MirrorState::Superseded.shows_marker());
        assert!(MirrorState::AwaitingSource.shows_marker());
        assert!(MirrorState::Stale.is_on_tablet());
        assert!(!MirrorState::Queued.is_on_tablet());
    }

    #[test]
    fn a_device_round_trips_through_its_payload() {
        let mut config = EinkDeviceConfig::usb_web("dev-1", "Paper Pro");
        config.mirror_mode = MirrorMode::All;
        config.folder_strategy = FolderStrategy::Rmdoc;
        config.last_sync_at_ms = Some(42);
        let item = crate::unified::conversion::bare_item(
            uuid::Uuid::new_v4(),
            SCHEMA_DEVICE,
            config.to_payload(),
        );
        let back = EinkDeviceConfig::from_item(&item);
        assert_eq!(back.name, "Paper Pro");
        assert_eq!(back.mirror_mode, MirrorMode::All);
        assert_eq!(back.folder_strategy, FolderStrategy::Rmdoc);
        assert_eq!(back.last_sync_at_ms, Some(42));
        assert_eq!(back.root_folder_name, DEFAULT_ROOT_FOLDER);
        assert!(back.enabled);
    }

    #[test]
    fn missing_payload_keys_fall_back_to_defaults() {
        let mut payload = BTreeMap::new();
        payload.insert("name".into(), Value::String("Old row".into()));
        let item =
            crate::unified::conversion::bare_item(uuid::Uuid::new_v4(), SCHEMA_DEVICE, payload);
        let config = EinkDeviceConfig::from_item(&item);
        assert_eq!(config.mirror_mode, MirrorMode::Individual);
        assert_eq!(
            config.base_url,
            impress_remarkable::usb_web::DEFAULT_BASE_URL
        );
        assert!(config.mirror_collections);
        assert_eq!(config.folder_strategy, FolderStrategy::Checklist);
    }
}
