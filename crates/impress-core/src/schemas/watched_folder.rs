//! Watched folders and the files they discover (ADR-0023 D2/D4).
//!
//! Two schemas, because a watched folder and a discovered file are two
//! different lifetimes:
//!
//! * [`WATCHED_FOLDER_SCHEMA`] — the folder itself. ADR-0023 D2: "a watched
//!   folder is a feed" — a security-scoped bookmark, the kind it ingests,
//!   whether it is enabled, and what the last scan found. One row per folder
//!   the user added; it outlives every file in it.
//! * [`WATCHED_FILE_SCHEMA`] — one row per file that folder has ever
//!   discovered. ADR-0023 D4: the row is an *index entry*, not a copy. It
//!   carries the path, a content hash and an mtime, and when the file vanishes
//!   it is marked `missing` — **never deleted**, because a file the user moved
//!   is not a file the user retracted, and the entries it produced still exist.
//!
//! # Why the file row exists at all, for both ingest units
//!
//! ADR-0023 D3 splits ingest into `file` (imprint/implore/impart — the file IS
//! the record) and `entries` (imbib — the file is a *container* that fans out
//! to publication rows). It is tempting to give only the `file` unit a
//! bookkeeping row and let the `entries` unit tag its publications with a
//! source path. That fails the one question a re-scan has to answer: *which
//! rows did this file produce, so I can tell what a deletion took with it?*
//! Answering it from the publication side means scanning every publication in
//! the library for a matching provenance string on every scan.
//!
//! So both units get the same file row, and the produced ids hang off it
//! (`produced_ids`). For the `file` unit that array has one element — the
//! record the file became. For the `entries` unit it has one element per entry
//! the importer emitted. The re-scan diff, the missing sweep and the
//! "what did this take with it" query are then unit-agnostic, which is what
//! lets one Rust path serve four apps.
//!
//! `produced_ids` is written by a SEPARATE verb
//! (`DocsImportService::record_produced_rows`), not by discovery: W0 owns the
//! file-level bookkeeping, and the fan-out through imbib's real importer is
//! W2's wiring. The seam is the array.

use crate::reference::EdgeType;
use crate::registry::SchemaRegistry;
use crate::schema::{FieldDef, FieldType, Schema};

/// The canonical watched-folder ref. VERSIONED, exactly as ADR-0023 D2 names
/// it — copy this spelling, never a sibling call site (root CLAUDE.md,
/// "Definition of done — schema refs").
pub const WATCHED_FOLDER_SCHEMA: &str = "watched-folder@1.0.0";

/// The canonical discovered-file ref. Versioned for the same reason its parent
/// is: this row's shape is the provenance contract W2–W5 build on, and a v2
/// that changes it must be able to coexist with v1 rows in a live store.
pub const WATCHED_FILE_SCHEMA: &str = "watched-file@1.0.0";

// ── Vocabularies ─────────────────────────────────────────────────────────────

/// A discovered file whose path is still on disk with the recorded hash.
pub const FILE_STATE_PRESENT: &str = "present";

/// A discovered file whose path is gone. ADR-0023 D4: kept and flagged, never
/// deleted.
pub const FILE_STATE_MISSING: &str = "missing";

/// Every legal `watched-file.state`.
pub const FILE_STATES: [&str; 2] = [FILE_STATE_PRESENT, FILE_STATE_MISSING];

/// Spotlight indexes this volume; discovery is live (`NSMetadataQuery`).
pub const VOLUME_STATE_INDEXED: &str = "indexed";

/// Spotlight does not index this volume, but FSEvents + a walk can. ADR-0023
/// D6: the folder row *states* this rather than rendering an honest zero.
pub const VOLUME_STATE_UNINDEXED: &str = "unindexed";

/// Neither live query nor event stream is available (a network mount): the
/// folder declares itself scan-on-demand.
pub const VOLUME_STATE_SCAN_ON_DEMAND: &str = "scan-on-demand";

/// The bookmark did not resolve — the volume is unmounted or access was
/// revoked. Distinct from "indexed and empty", which is the whole point of D6.
pub const VOLUME_STATE_UNAVAILABLE: &str = "unavailable";

/// Every legal `watched-folder.volume_state`.
pub const VOLUME_STATES: [&str; 4] = [
    VOLUME_STATE_INDEXED,
    VOLUME_STATE_UNINDEXED,
    VOLUME_STATE_SCAN_ON_DEMAND,
    VOLUME_STATE_UNAVAILABLE,
];

// ── Schemas ──────────────────────────────────────────────────────────────────

/// Schema for the `watched-folder@1.0.0` item type (ADR-0023 D2).
pub fn watched_folder_schema() -> Schema {
    Schema {
        id: WATCHED_FOLDER_SCHEMA.into(),
        name: "Watched Folder".into(),
        version: "1.0.0".into(),
        fields: vec![
            described(
                required_string("path"),
                "Absolute POSIX path of the watched directory, as last resolved. \
                 REQUIRED even when a bookmark is present: a bookmark is opaque \
                 to every non-Apple caller (the CLI, MCP, a test), and a folder \
                 row that can only be read by AppKit is not a store row.",
            ),
            described(
                optional_string("bookmark_base64"),
                "Base64 of the security-scoped bookmark that persists directory \
                 access across launches (ADR-0023 D6). Absent on rows created by \
                 the CLI/MCP, which have no sandbox to escape. Base64 rather than \
                 a blob column because `Value` has no bytes variant — the same \
                 convention `manuscript.import_source` uses for \
                 `original_path_bookmark_base64`.",
            ),
            described(
                required_string("kind_scope"),
                "Record kind this folder ingests: \"publication\", \"manuscript\", \
                 \"figure\" or \"message\" — the same vocabulary as \
                 `collection.kind_scope`, and the key into the record kind's \
                 `FileDiscoveryCapability` (ADR-0023 D1). The ingest UNIT and the \
                 watched file types are NOT stored here: they are derived from \
                 that capability, which is the one authority for both.",
            ),
            described(
                optional_string("display_name"),
                "Sidebar label. Absent means the folder's last path component.",
            ),
            described(
                field("enabled", FieldType::Bool, false),
                "False pauses discovery without forgetting the folder or its \
                 file rows. Absent is read as true.",
            ),
            described(
                field("recursive", FieldType::Bool, false),
                "Whether discovery descends into subdirectories. Absent is read \
                 as true — a Spotlight scope is recursive by nature, so opting \
                 OUT is the unusual choice that has to be written down.",
            ),
            described(
                optional_string("volume_state"),
                "Declared platform capability of this folder's volume (ADR-0023 \
                 D6): \"indexed\" | \"unindexed\" | \"scan-on-demand\" | \
                 \"unavailable\". The folder row must never render an unindexed \
                 volume as \"0 files\"; this field is what lets it say so instead.",
            ),
            described(
                optional_string("last_scan_at"),
                "ISO-8601 completion time of the last finished scan. Absent means \
                 never scanned — which a UI must distinguish from \"scanned, found \
                 nothing\".",
            ),
            described(
                field("last_scan_file_count", FieldType::Int, false),
                "Files present at the end of the last scan.",
            ),
            described(
                field("last_scan_new_count", FieldType::Int, false),
                "Files the last scan saw for the first time.",
            ),
            described(
                field("last_scan_changed_count", FieldType::Int, false),
                "Files whose content hash changed during the last scan.",
            ),
            described(
                field("last_scan_missing_count", FieldType::Int, false),
                "Files the last scan marked missing (present before, absent now).",
            ),
            described(
                field("last_scan_duration_ms", FieldType::Int, false),
                "Wall-clock duration of the last scan, for the D7 burst budget.",
            ),
        ],
        // NO edges, deliberately. The folder→file relation is the ENVELOPE
        // (`item.parent` on the file row) plus payload `watched_folder_id`, not
        // a `Contains` edge: an edge lives on its SOURCE item, so materialising
        // one would mean a write to the folder row for every file discovered —
        // the exact per-row cost ADR-0023 D7's write gate exists to avoid. A
        // declared edge nothing writes is the same trap as a schema nothing
        // writes, so it is not declared.
        expected_edges: vec![],
        inherits: None,
    }
}

/// Schema for the `watched-file@1.0.0` item type (ADR-0023 D4).
pub fn watched_file_schema() -> Schema {
    Schema {
        id: WATCHED_FILE_SCHEMA.into(),
        name: "Watched File".into(),
        version: "1.0.0".into(),
        fields: vec![
            described(
                required_string("watched_folder_id"),
                "Lowercase UUID of the `watched-folder@1.0.0` row that discovered \
                 this file — the PROVENANCE. Required: a file row with no folder \
                 is unreachable by every query this schema exists to answer.",
            ),
            described(
                required_string("path"),
                "Absolute POSIX path of the file. Half of the deterministic id \
                 key, so it is stable for as long as the file is.",
            ),
            described(
                required_string("content_hash"),
                "SHA-256 hex of the file's bytes. The re-scan diff is a comparison \
                 of this field, not of mtime: mtime moves when a backup tool \
                 touches a file, and a hash does not.",
            ),
            described(
                required_string("state"),
                "\"present\" | \"missing\". ADR-0023 D4: a vanished file's row is \
                 marked, never deleted — the rows it produced are still real, and \
                 a moved file is not a retracted one.",
            ),
            described(
                required_string("kind_scope"),
                "Denormalised from the folder so \"every discovered .bib in the \
                 store\" is one query instead of a join. The folder remains the \
                 authority; this is a copy that discovery rewrites on every scan.",
            ),
            described(
                optional_string("mtime"),
                "ISO-8601 filesystem modification time as last observed. \
                 Informational — the change test is the hash.",
            ),
            described(
                field("size_bytes", FieldType::Int, false),
                "File size in bytes as last observed.",
            ),
            described(
                optional_string("bookmark_base64"),
                "Base64 of a per-FILE security-scoped bookmark, for reference-in-place \
                 records that must reopen the file after a relaunch (ADR-0023 D4). \
                 Absent for entry-unit ingest, where the file is only ever read \
                 through the folder's bookmark.",
            ),
            described(
                optional_string("first_seen_at"),
                "ISO-8601 time this file was first discovered. Never rewritten.",
            ),
            described(
                optional_string("last_seen_at"),
                "ISO-8601 time this file was last observed present.",
            ),
            described(
                optional_string("missing_since"),
                "ISO-8601 time the file was first found absent. Cleared when it \
                 comes back, so a file that returns does not read as a stale \
                 tombstone.",
            ),
            described(
                field("produced_ids", FieldType::StringArray, false),
                "Lowercase UUIDs of the store rows this file produced — one entry \
                 per publication for `entries`-unit ingest, exactly one (the record \
                 the file became) for `file`-unit. THIS IS THE W2 SEAM: discovery \
                 never writes it, `record_produced_rows` does, after the app's real \
                 importer has run. Absent means \"not ingested yet\"; empty means \
                 \"ingested and produced nothing\", and those are different facts.",
            ),
            described(
                optional_string("produced_at"),
                "ISO-8601 time `produced_ids` was last written. Absent ⇒ the \
                 fan-out has never run for this file.",
            ),
            described(
                optional_string("produced_for_hash"),
                "The `content_hash` this file had when `produced_ids` was written. \
                 `produced_for_hash != content_hash` is the exact test for \"the \
                 file changed since its last import\" — and it is a CONTENT \
                 comparison rather than a timestamp one on purpose: \
                 `iso8601_now` has one-second resolution, so an edit and an \
                 import inside the same second would compare equal and the \
                 re-import would silently never be queued.",
            ),
        ],
        // Produced rows hang off the file: `DerivedFrom` is the graph spelling
        // of `produced_ids`, written by the same seam.
        expected_edges: vec![EdgeType::DerivedFrom],
        inherits: None,
    }
}

/// Register the ADR-0023 watched-folder pair.
pub fn register_watched_folder_schemas(registry: &mut SchemaRegistry) {
    registry
        .register(watched_folder_schema())
        .expect("watched-folder@1.0.0 schema registration");
    registry
        .register(watched_file_schema())
        .expect("watched-file@1.0.0 schema registration");
}

fn required_string(name: &str) -> FieldDef {
    FieldDef {
        name: name.into(),
        field_type: FieldType::String,
        required: true,
        description: None,
    }
}

fn optional_string(name: &str) -> FieldDef {
    FieldDef {
        name: name.into(),
        field_type: FieldType::String,
        required: false,
        description: None,
    }
}

fn field(name: &str, field_type: FieldType, required: bool) -> FieldDef {
    FieldDef {
        name: name.into(),
        field_type,
        required,
        description: None,
    }
}

fn described(mut def: FieldDef, description: &str) -> FieldDef {
    def.description = Some(description.into());
    def
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn both_schemas_register() {
        let mut reg = SchemaRegistry::new();
        register_watched_folder_schemas(&mut reg);
        assert!(reg.get(WATCHED_FOLDER_SCHEMA).is_some());
        assert!(reg.get(WATCHED_FILE_SCHEMA).is_some());
    }

    /// The ids ARE the refs writers emit. A rename here without a
    /// `schema-refs.json` edit is caught by `tests/schema_ref_manifest.rs`; a
    /// rename that forgets the constants is caught right here.
    #[test]
    fn ids_are_the_canonical_versioned_refs() {
        assert_eq!(watched_folder_schema().id, "watched-folder@1.0.0");
        assert_eq!(watched_file_schema().id, "watched-file@1.0.0");
        assert_eq!(WATCHED_FOLDER_SCHEMA, watched_folder_schema().id);
        assert_eq!(WATCHED_FILE_SCHEMA, watched_file_schema().id);
    }

    #[test]
    fn folder_required_fields_are_the_two_that_identify_it() {
        let s = watched_folder_schema();
        let required: Vec<&str> = s
            .fields
            .iter()
            .filter(|f| f.required)
            .map(|f| f.name.as_str())
            .collect();
        assert_eq!(
            required,
            vec!["path", "kind_scope"],
            "a folder with no path cannot be scanned and one with no kind_scope \
             cannot resolve a FileDiscoveryCapability"
        );
    }

    /// D2's list, field by field: bookmark-or-path, kind scope, enabled,
    /// last-scan stats. Named individually so dropping one is a test failure
    /// rather than a silently smaller row.
    #[test]
    fn folder_carries_every_field_d2_names() {
        let s = watched_folder_schema();
        let names: Vec<&str> = s.fields.iter().map(|f| f.name.as_str()).collect();
        for key in [
            "path",
            "bookmark_base64",
            "kind_scope",
            "enabled",
            "last_scan_at",
            "last_scan_file_count",
            "last_scan_new_count",
            "last_scan_changed_count",
            "last_scan_missing_count",
            "last_scan_duration_ms",
        ] {
            assert!(names.contains(&key), "D2 names {key:?}");
        }
        // D6's declared degraded state, which is what stops an unindexed volume
        // rendering as an honest-looking zero.
        assert!(names.contains(&"volume_state"));
    }

    /// The folder must NOT restate what the capability declares. ADR-0023 D1:
    /// "Where the authority already lives elsewhere it is referenced, not
    /// restated" — the watched file types and the ingest unit are derived from
    /// the kind's `FileDiscoveryCapability`, so a column for either here would
    /// be a second authority that can disagree with the first.
    #[test]
    fn folder_does_not_restate_the_capability() {
        let s = watched_folder_schema();
        let names: Vec<&str> = s.fields.iter().map(|f| f.name.as_str()).collect();
        for forbidden in [
            "ingest_unit",
            "extensions",
            "file_extensions",
            "utis",
            "uti",
        ] {
            assert!(
                !names.contains(&forbidden),
                "{forbidden:?} is derived from the record kind's \
                 FileDiscoveryCapability (ADR-0023 D1); storing it here creates a \
                 second authority"
            );
        }
    }

    #[test]
    fn file_required_fields_are_the_provenance_quartet() {
        let s = watched_file_schema();
        let required: Vec<&str> = s
            .fields
            .iter()
            .filter(|f| f.required)
            .map(|f| f.name.as_str())
            .collect();
        assert_eq!(
            required,
            vec![
                "watched_folder_id",
                "path",
                "content_hash",
                "state",
                "kind_scope"
            ]
        );
    }

    /// D4's semantics in one assertion: there is a `state` field and `missing`
    /// is one of its values, because the alternative to marking is deleting and
    /// D4 forbids deleting.
    #[test]
    fn file_state_vocabulary_is_present_and_missing() {
        assert_eq!(FILE_STATES, ["present", "missing"]);
        let s = watched_file_schema();
        let state = s
            .fields
            .iter()
            .find(|f| f.name == "state")
            .expect("state field");
        assert!(state.required);
        assert_eq!(state.field_type, FieldType::String);
    }

    /// The W2 seam is an ARRAY, not a single id: an `entries`-unit `.bib`
    /// produces many rows and a `file`-unit manuscript produces one, and the
    /// re-scan diff must not care which.
    #[test]
    fn produced_ids_is_a_string_array_and_optional() {
        let s = watched_file_schema();
        let produced = s
            .fields
            .iter()
            .find(|f| f.name == "produced_ids")
            .expect("produced_ids field");
        assert_eq!(produced.field_type, FieldType::StringArray);
        assert!(
            !produced.required,
            "absent means 'not ingested yet' and empty means 'ingested, produced \
             nothing' — a required field could not tell those apart"
        );
    }

    #[test]
    fn volume_state_vocabulary_is_the_four_d6_names() {
        assert_eq!(
            VOLUME_STATES,
            ["indexed", "unindexed", "scan-on-demand", "unavailable"]
        );
    }

    /// The folder declares NO edges (the relation is `item.parent` on the file
    /// row — see the schema comment), and the file declares the one edge the
    /// W2 seam materialises.
    #[test]
    fn only_the_file_declares_an_edge() {
        assert!(
            watched_folder_schema().expected_edges.is_empty(),
            "a Contains edge would cost a folder write per discovered file"
        );
        assert_eq!(
            watched_file_schema().expected_edges,
            vec![EdgeType::DerivedFrom]
        );
    }

    /// Missing-detection is filesystem-verified, not stamp-and-sweep: a scan
    /// generation token on the file row would mean a write per file per scan,
    /// which would make an unchanged re-scan cost N writes instead of zero.
    /// If a token ever reappears here, the zero-write idempotency claim in
    /// `import_discovered`'s docs has quietly stopped being true.
    #[test]
    fn no_per_file_scan_token_field() {
        for s in [watched_folder_schema(), watched_file_schema()] {
            assert!(
                !s.fields.iter().any(|f| f.name == "last_scan_token"),
                "{}: a scan token costs a write per file per scan",
                s.id
            );
        }
    }

    #[test]
    fn schemas_serde_round_trip() {
        for s in [watched_folder_schema(), watched_file_schema()] {
            let json = serde_json::to_string_pretty(&s).unwrap();
            let back: Schema = serde_json::from_str(&json).unwrap();
            assert_eq!(s, back);
        }
    }
}
