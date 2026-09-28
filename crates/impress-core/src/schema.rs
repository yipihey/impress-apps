use std::{borrow::Cow, fmt, str::FromStr};

use serde::{Deserialize, Serialize};

use crate::reference::EdgeType;

/// A schema name. Source code uses the manifest-generated [`refs`] constants.
///
/// The constructor is private: a misspelt literal cannot become a query's
/// schema through `into()`. Explicit [`FromStr`] parsing requires a manifest
/// name. Serialization boundaries (rows, backups, sync, and the existing Swift
/// string API) preserve opaque names, so a newer writer or an old backup cannot
/// make unrelated rows unreadable. This is a construction guard, not a claim
/// that every wire value is canonical. Opaque names own their bytes; canonical
/// constants borrow static strings and never allocate.
///
/// ```compile_fail
/// let schema: impress_core::SchemaRef = "manuscript-sectoin".into();
/// ```
/// ```compile_fail
/// let schema = impress_core::SchemaRef("manuscript");
/// ```
#[repr(transparent)]
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize)]
#[serde(transparent)]
pub struct SchemaRef(Cow<'static, str>);

impl SchemaRef {
    const fn canonical(value: &'static str) -> Self {
        Self(Cow::Borrowed(value))
    }

    pub const fn as_str(&self) -> &str {
        match &self.0 {
            Cow::Borrowed(value) => value,
            Cow::Owned(value) => value.as_str(),
        }
    }

    /// Decode an existing row without losing an opaque schema name. Keep this
    /// boundary inside the store; new code must name a manifest constant.
    pub(crate) fn from_stored(value: String) -> Self {
        Self::lookup(&value).unwrap_or(Self(Cow::Owned(value)))
    }

    fn lookup(value: &str) -> Option<Self> {
        refs::ALL
            .binary_search_by(|schema| schema.as_str().cmp(value))
            .ok()
            .map(|index| refs::ALL[index].clone())
    }
}

/// A dynamic schema name was not declared in the suite manifest.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[error("unknown schema reference: {0}")]
pub struct UnknownSchemaRef(pub String);

impl FromStr for SchemaRef {
    type Err = UnknownSchemaRef;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        Self::lookup(value).ok_or_else(|| UnknownSchemaRef(value.to_owned()))
    }
}

impl<'de> Deserialize<'de> for SchemaRef {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        String::deserialize(deserializer).map(Self::from_stored)
    }
}

impl fmt::Display for SchemaRef {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

impl AsRef<str> for SchemaRef {
    fn as_ref(&self) -> &str {
        self.as_str()
    }
}

impl From<&SchemaRef> for SchemaRef {
    fn from(value: &SchemaRef) -> Self {
        value.clone()
    }
}

impl From<SchemaRef> for String {
    fn from(value: SchemaRef) -> Self {
        value.0.into_owned()
    }
}

impl std::ops::Deref for SchemaRef {
    type Target = str;
    fn deref(&self) -> &str {
        self.as_str()
    }
}

impl std::borrow::Borrow<str> for SchemaRef {
    fn borrow(&self) -> &str {
        self.as_str()
    }
}

#[cfg(feature = "sqlite")]
impl rusqlite::ToSql for SchemaRef {
    fn to_sql(&self) -> rusqlite::Result<rusqlite::types::ToSqlOutput<'_>> {
        self.as_str().to_sql()
    }
}

/// Canonical vocabulary generated from the root `schema-refs.json`.
pub mod refs {
    use super::SchemaRef;
    include!(concat!(env!("OUT_DIR"), "/schema_refs.rs"));
}

/// Manifest spellings for metadata and legacy wire/SQL boundaries. Store
/// queries use [`refs`]; this module also serves crates below the store which
/// cannot depend on its types without a cycle.
pub mod names {
    include!(concat!(env!("OUT_DIR"), "/schema_ref_names.rs"));
}

/// A field definition within a schema.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct FieldDef {
    pub name: String,
    pub field_type: FieldType,
    pub required: bool,
    pub description: Option<String>,
}

/// Supported field types for schema definitions.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum FieldType {
    String,
    Int,
    Float,
    Bool,
    DateTime,
    StringArray,
    Object,
}

/// Schema definition — describes what fields an item type has.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Schema {
    pub id: SchemaRef,
    pub name: String,
    pub version: String,
    pub fields: Vec<FieldDef>,
    pub expected_edges: Vec<EdgeType>,
    pub inherits: Option<SchemaRef>,
}

#[cfg(test)]
mod tests {
    use super::*;

    // Unknown fixture names represent historical rows; production construction
    // remains restricted to manifest refs or fallible parsing.
    fn fixture_schema(name: &str) -> SchemaRef {
        SchemaRef::from_stored(name.to_owned())
    }

    #[test]
    fn schema_serde_round_trip() {
        let schema = Schema {
            id: crate::schema::refs::BIBLIOGRAPHY_ENTRY,
            name: "Bibliography Entry".into(),
            version: "1.0.0".into(),
            fields: vec![
                FieldDef {
                    name: "title".into(),
                    field_type: FieldType::String,
                    required: true,
                    description: Some("The title of the publication".into()),
                },
                FieldDef {
                    name: "citation_count".into(),
                    field_type: FieldType::Int,
                    required: false,
                    description: None,
                },
                FieldDef {
                    name: "authors".into(),
                    field_type: FieldType::StringArray,
                    required: true,
                    description: None,
                },
            ],
            expected_edges: vec![EdgeType::Cites, EdgeType::Attaches],
            inherits: None,
        };
        let json = serde_json::to_string_pretty(&schema).unwrap();
        let back: Schema = serde_json::from_str(&json).unwrap();
        assert_eq!(schema, back);
    }

    #[test]
    fn schema_with_inheritance() {
        let base = Schema {
            id: fixture_schema("research-item"),
            name: "Research Item".into(),
            version: "1.0.0".into(),
            fields: vec![FieldDef {
                name: "abstract".into(),
                field_type: FieldType::String,
                required: false,
                description: None,
            }],
            expected_edges: vec![],
            inherits: None,
        };
        let child = Schema {
            id: fixture_schema("preprint"),
            name: "Preprint".into(),
            version: "1.0.0".into(),
            fields: vec![FieldDef {
                name: "arxiv_id".into(),
                field_type: FieldType::String,
                required: true,
                description: None,
            }],
            expected_edges: vec![EdgeType::Supersedes],
            inherits: Some(base.id.clone()),
        };
        let json = serde_json::to_string(&child).unwrap();
        let back: Schema = serde_json::from_str(&json).unwrap();
        assert_eq!(child, back);
        assert_eq!(back.inherits, Some(fixture_schema("research-item")));
    }
}
