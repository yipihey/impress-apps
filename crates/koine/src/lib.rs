//! Koine is the speech the impress frontends share.
//!
//! A verb and its arguments become one document. [`surface`] turns that
//! document into a [`surface::RenderTree`]. A frontend is a mapping of that
//! tree: SwiftUI in `ImpressSurface`, plain text in `koine-tui`. The mapping
//! holds no logic of its own. Anything that computes is a verb.
//!
//! This crate is the name and the public face. The grammar still lives in the
//! crates it re-exports, so existing callers keep their paths. The repository
//! cut that would publish koine on its own is `docs/plan-koine-separation.md`.

pub use impress_layout as layout;
pub use impress_pane_query as pane_query;
pub use impress_surface as surface;
pub use impress_verb_surface as verb_surface;

#[cfg(test)]
mod tests {
    #[test]
    fn the_grammar_is_reachable_under_one_name() {
        let spec = crate::surface::example_paper_triage();
        let tree = crate::surface::resolve(
            &spec,
            &serde_json::json!({}),
            &serde_json::json!({}),
            &serde_json::json!({}),
        );
        assert!(!tree.root.id.is_empty());
    }
}
