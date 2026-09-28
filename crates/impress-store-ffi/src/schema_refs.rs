//! Rust queries are typed while existing Swift string call sites stay source
//! compatible. The generated enum supplies an opt-in canonical Swift spelling.

include!(concat!(env!("OUT_DIR"), "/schema_refs_ffi.rs"));

/// A typed Rust schema transported as the existing Swift string value.
pub type StoreSchemaRef = impress_core::SchemaRef;

#[cfg(feature = "native")]
uniffi::custom_type!(StoreSchemaRef, String);

#[cfg(feature = "native")]
impl crate::UniffiCustomTypeConverter for StoreSchemaRef {
    type Builtin = String;

    fn into_custom(value: String) -> uniffi::Result<Self> {
        // This is an existing wire boundary, like backup/sync decoding: opaque
        // names must round-trip, including rows written by a newer app.
        Ok(serde_json::from_value(serde_json::Value::String(value))?)
    }

    fn from_custom(value: Self) -> String {
        value.into()
    }
}

/// The manifest spelling of a canonical schema, for existing Swift APIs.
#[cfg_attr(feature = "native", uniffi::export)]
pub fn schema_ref_name(schema: SchemaRef) -> String {
    schema.as_core().into()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn swift_enum_covers_exactly_the_core_manifest() {
        let ffi: Vec<_> = SchemaRef::ALL
            .iter()
            .map(|schema| schema.as_core())
            .collect();
        assert_eq!(ffi, impress_core::schema::refs::ALL);
        assert_eq!(schema_ref_name(SchemaRef::ImbibLibrary), "imbib/library");
    }

    #[cfg(feature = "native")]
    #[test]
    fn native_string_boundary_preserves_an_opaque_name() {
        use crate::UniffiCustomTypeConverter;
        let spelling = "fixture/future-kind@9.0.0".to_string();
        let value = StoreSchemaRef::into_custom(spelling.clone()).unwrap();
        assert_eq!(StoreSchemaRef::from_custom(value), spelling);
    }
}
