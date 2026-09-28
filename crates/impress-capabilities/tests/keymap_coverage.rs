//! R2 keymap coverage, verb-existence half (plan-self-reflective-layer.md §
//! Registries — the keymap half, RG-4..RG-6).
//!
//! `impress-keymap` keeps no dependency on the linked inventory (RG-6: a
//! pure crate declaring chords must not reach `impress-service-core`'s
//! descriptor machinery just to check itself), so the one check that needs
//! the inventory — every `Target::Verb` binding names a real verb — lives
//! here instead, beside the other inventory-shaped tests
//! (`census.rs`, `descriptor.rs`, `effects.rs`).
//!
//! The other two coverage rules (no duplicate chord in a colliding scope;
//! a chordless binding is a palette `Command`, never a bare `Verb`) need no
//! inventory and live in `impress-keymap`'s own `#[cfg(test)]` module, next
//! to the seed data they check.

use impress_keymap::Target;
use impress_service_core::McpToolDescriptor;
use std::collections::BTreeSet;

#[test]
fn every_verb_binding_names_a_verb_in_the_linked_inventory() {
    let known: BTreeSet<&'static str> = McpToolDescriptor::iter().map(|d| d.name).collect();
    let missing: Vec<&'static str> = impress_keymap::all()
        .into_iter()
        .filter_map(|b| match b.target {
            Target::Verb(name) if !known.contains(name) => Some(name),
            _ => None,
        })
        .collect();
    assert!(
        missing.is_empty(),
        "keymap binding(s) name a verb not in the linked inventory: {missing:?} — \
         rename the binding's Target::Verb or add the verb"
    );
}

#[test]
fn imprint_commands_join_the_same_covered_union() {
    let imprint: Vec<_> = impress_keymap::all()
        .into_iter()
        .filter(|binding| binding.target.id().starts_with("imprint."))
        .collect();
    assert_eq!(
        imprint.len(),
        60,
        "all current macOS imprint chords must be seeded"
    );
    let mut ids = BTreeSet::new();
    for binding in imprint {
        assert!(matches!(binding.target, Target::Command(_)));
        assert!(ids.insert(binding.target.id()), "duplicate imprint target");
    }
}
