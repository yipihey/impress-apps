//! Test-only decoder for stored schema names, including deliberately opaque
//! names used by compatibility and property tests. Production callers use
//! manifest-generated `schema::refs` or fallible `FromStr` instead.

pub fn decode(name: impl AsRef<str>) -> impress_core::SchemaRef {
    serde_json::from_value(serde_json::Value::String(name.as_ref().to_owned()))
        .expect("fixture schema name must deserialize")
}
