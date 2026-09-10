//! `manuscript-file@1.0.0` — one file of a manuscript's project tree (ADR-0030 D1).
//!
//! A manuscript is a project: a tree of files whose entry is the manuscript row
//! itself (`body_content` is the entry file's text) and whose every OTHER file
//! is one of these rows, **parent = the manuscript**. `HasParent` lists the
//! tree, deleting the manuscript cascades, undo snapshots include it.
//!
//! Text files keep their bytes inline in `content` (Automerge-backed through
//! the same collab machinery as the body — ADR-0030 D3); binaries and text over
//! `INLINE_TEXT_LIMIT` are `blob:sha256:<hex>` refs into the workspace CAS
//! (`crate::blobs`). Every row carries `content_hash` and `size` regardless.
//!
//! Row ids are deterministic — `uuid_v5(NS, "<manuscript>|<path>")` — so a
//! re-import, a second device and a watched working copy agree on identity
//! without a query (the rule ADR-0023 uses for `watched-file`).
//!
//! Roles are the ONE vocabulary shared with the bundle manifest
//! (`BundleEntryRole`): a revision archive is the serialisation of a tree,
//! never a second description of it.

use crate::reference::EdgeType;
use crate::registry::SchemaRegistry;
use crate::schema::{FieldDef, FieldType, Schema};
use uuid::Uuid;

/// The schema ref, versioned like `manuscript-change@1.0.0`.
pub const MANUSCRIPT_FILE_SCHEMA_REF: &str = "manuscript-file@1.0.0";

/// Namespace for the deterministic row id. Frozen: changing it orphans every
/// existing file row (the store matches by id, so nothing errors — the tree
/// just reads as empty).
pub const MANUSCRIPT_FILE_ID_NAMESPACE: Uuid = Uuid::from_bytes([
    0x3a, 0x7e, 0x0c, 0x51, 0x9d, 0x2b, 0x4f, 0x8a, 0xb6, 0x1e, 0x5c, 0x94, 0x2d, 0x7f, 0xa0, 0x63,
]);

/// Text at or below this many UTF-8 bytes stays inline in `content`; above
/// it (and every binary) goes to the CAS as a `blob:sha256:` ref.
pub const INLINE_TEXT_LIMIT: usize = 1024 * 1024;

/// `kind` values.
pub const FILE_KIND_TEXT: &str = "text";
pub const FILE_KIND_BINARY: &str = "binary";

/// `role` values — the bundle manifest's vocabulary, one string each. `main`
/// is deliberately absent: the entry is the manuscript row, never a file row.
pub const FILE_ROLES: &[&str] = &[
    "chapter",
    "bibliography",
    "figure",
    "figure-source",
    "data",
    "style",
    "aux",
    "supplement",
    "output",
];

/// The deterministic id of the row for `path` under `manuscript`.
pub fn manuscript_file_id(manuscript: Uuid, path: &str) -> Uuid {
    Uuid::new_v5(
        &MANUSCRIPT_FILE_ID_NAMESPACE,
        format!("{}|{}", manuscript, path).as_bytes(),
    )
}

pub fn manuscript_file_schema() -> Schema {
    Schema {
        id: MANUSCRIPT_FILE_SCHEMA_REF.into(),
        name: "Manuscript File".into(),
        version: "1.0.0".into(),
        fields: vec![
            FieldDef {
                name: "path".into(),
                field_type: FieldType::String,
                required: true,
                description: Some(
                    "POSIX-relative path inside the project (forward slashes, no `..`, \
                     no leading `/`). Unique per manuscript."
                        .into(),
                ),
            },
            FieldDef {
                name: "role".into(),
                field_type: FieldType::String,
                required: true,
                description: Some(
                    "chapter | bibliography | figure | figure-source | data | style | aux | \
                     supplement | output — the bundle manifest's vocabulary."
                        .into(),
                ),
            },
            FieldDef {
                name: "kind".into(),
                field_type: FieldType::String,
                required: true,
                description: Some("text | binary.".into()),
            },
            FieldDef {
                name: "format".into(),
                field_type: FieldType::String,
                required: false,
                description: Some(
                    "Text files: the grammar (typst | latex | markdown | bibtex | plot-spec | \
                     python | json | csv | …) from the extension table."
                        .into(),
                ),
            },
            FieldDef {
                name: "content".into(),
                field_type: FieldType::String,
                required: false,
                description: Some(
                    "Inline UTF-8 text (text files at or below INLINE_TEXT_LIMIT). Empty when \
                     the bytes are in `blob_ref`."
                        .into(),
                ),
            },
            FieldDef {
                name: "blob_ref".into(),
                field_type: FieldType::String,
                required: false,
                description: Some(
                    "`blob:sha256:<hex>` into the workspace CAS — binaries and large text.".into(),
                ),
            },
            FieldDef {
                name: "content_hash".into(),
                field_type: FieldType::String,
                required: true,
                description: Some("SHA-256 hex of the file's bytes, always present.".into()),
            },
            FieldDef {
                name: "size".into(),
                field_type: FieldType::Int,
                required: true,
                description: Some("Byte length.".into()),
            },
            FieldDef {
                name: "mime_type".into(),
                field_type: FieldType::String,
                required: false,
                description: None,
            },
            FieldDef {
                name: "derived_from".into(),
                field_type: FieldType::String,
                required: false,
                description: Some(
                    "For a `figure`/`output` produced by a step: the `figure-source` path that \
                     makes it (ADR-0030 D6)."
                        .into(),
                ),
            },
            FieldDef {
                name: "derived_from_hash".into(),
                field_type: FieldType::String,
                required: false,
                description: Some(
                    "The step's input hash (source bytes, input bytes, build_json) this output \
                     was last built from; the graph reports the output stale when it moves."
                        .into(),
                ),
            },
            FieldDef {
                name: "build_json".into(),
                field_type: FieldType::String,
                required: false,
                description: Some(
                    "`figure-source` only: `{runner, outputs[], inputs[], args{}}` — runner is \
                     impress-plot | implore | veusz | shell."
                        .into(),
                ),
            },
            FieldDef {
                name: "bib_source_json".into(),
                field_type: FieldType::String,
                required: false,
                description: Some(
                    "`bibliography` only: a projection spec `{kind: cited | collection | \
                     library | keys, …}` resolved through imbib at materialisation (D7). Absent \
                     = the row's `content` is literal BibTeX."
                        .into(),
                ),
            },
            FieldDef {
                name: "external_path".into(),
                field_type: FieldType::String,
                required: false,
                description: Some(
                    "Reference-in-place (ADR-0023): the file on disk is authoritative and the \
                     row is an index entry."
                        .into(),
                ),
            },
            FieldDef {
                name: "modified_ms".into(),
                field_type: FieldType::Int,
                required: false,
                description: None,
            },
        ],
        expected_edges: vec![EdgeType::IsPartOf],
        inherits: None,
    }
}

pub fn register_manuscript_file_schema(registry: &mut SchemaRegistry) {
    registry
        .register(manuscript_file_schema())
        .expect("manuscript-file schema registration");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn registers_versioned() {
        let mut reg = SchemaRegistry::new();
        register_manuscript_file_schema(&mut reg);
        let s = reg.get(MANUSCRIPT_FILE_SCHEMA_REF).expect("registered");
        assert_eq!(s.version, "1.0.0");
        for name in ["path", "role", "kind", "content_hash", "size"] {
            let f = s.fields.iter().find(|f| f.name == name).unwrap();
            assert!(f.required, "{name} is required");
        }
    }

    #[test]
    fn ids_are_deterministic_and_path_sensitive() {
        let m = Uuid::new_v4();
        assert_eq!(
            manuscript_file_id(m, "chapters/intro.tex"),
            manuscript_file_id(m, "chapters/intro.tex")
        );
        assert_ne!(
            manuscript_file_id(m, "chapters/intro.tex"),
            manuscript_file_id(m, "chapters/Intro.tex")
        );
        assert_ne!(
            manuscript_file_id(m, "a.bib"),
            manuscript_file_id(Uuid::new_v4(), "a.bib")
        );
    }

    #[test]
    fn main_is_not_a_file_role() {
        assert!(
            !FILE_ROLES.contains(&"main"),
            "the entry is the manuscript row"
        );
    }
}
