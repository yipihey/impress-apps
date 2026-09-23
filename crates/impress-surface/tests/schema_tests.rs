//! `schemars::schema_for!(SurfaceSpec)` serialises, and mentions every node
//! kind — so `surface_schema` (S4) can hand an agent a real JSON Schema
//! document without it reading this crate's source. Compiled only under the
//! `schema` feature (`cargo test -p impress-surface --features schema`).

#![cfg(feature = "schema")]

use impress_surface::SurfaceSpec;
use schemars::schema_for;

#[test]
fn the_surface_spec_schema_serialises() {
    let schema = schema_for!(SurfaceSpec);
    let json = serde_json::to_string_pretty(&schema).expect("schema serialises to JSON");
    assert!(!json.is_empty());
}

#[test]
fn the_schema_mentions_every_node_kind() {
    let schema = schema_for!(SurfaceSpec);
    let json = serde_json::to_string(&schema).expect("schema serialises to JSON");
    for kind in impress_surface::spec::NODE_KIND_NAMES {
        assert!(
            json.contains(kind),
            "generated schema does not mention node kind '{kind}'"
        );
    }
}

#[test]
fn the_schema_mentions_every_action_kind() {
    let schema = schema_for!(SurfaceSpec);
    let json = serde_json::to_string(&schema).expect("schema serialises to JSON");
    for kind in ["set", "call", "publish", "emit", "open", "refresh"] {
        assert!(
            json.contains(kind),
            "generated schema does not mention action kind '{kind}'"
        );
    }
}
