//! Publisher PDF resolution: the rule table and the landing-page HTML parsers.
//!
//! Stage 7 item 9. Ported from `PMC/Publishers/{PublisherRule,DefaultRules,
//! PublisherHTMLParsers}.swift`; the Swift files are now shims over the FFI in
//! `crate::parsers_ffi`. `PublisherRegistry` (the actor) stays Swift — it is
//! a `.shared` singleton whose only job is lifetime and an optional user JSON
//! overlay, and its lookup now calls [`rules::rule_for_doi`].
//!
//! See `docs/parser-batch-swift-rust-split.md` for the three drifted
//! Swift copies of the rule table this port retires and why the parsers stayed
//! regex rather than becoming a DOM parse.

pub mod foundation_url;
pub mod html;
pub mod rules;

pub use html::{parse, parser_id, PARSER_IDS};
pub use rules::{
    rule_for_doi, rule_for_id, rules_for_doi, CaptchaRisk, PublisherRule, DEFAULT_RULES,
};
