//! ADS query normalization — re-exported from [`impress_smart_search`].
//!
//! This module used to hold a full 790-line port of Swift
//! `ADSQueryNormalizer.swift`, reachable only from
//! `tests/search_property_tests.rs`. Meanwhile *two byte-identical Swift
//! copies* of the same rules did the actual work (one in the
//! `ImpressSmartSearch` package, one in `PublicationManagerCore`), and the
//! Rust twin had already drifted: its boolean-operator rule folded Swift's
//! zero-width lookaround into consuming character classes, so
//! `"and or not"` normalized to `"AND or NOT"` — it silently skipped every
//! second operator. Nothing noticed, because nothing called it.
//!
//! All three are now one implementation in `impress-smart-search`, pinned by a
//! golden corpus captured from Swift. This module stays as a re-export so the
//! existing property tests and any `imbib_core::search::ads_normalizer::…`
//! callers keep working.

pub use impress_smart_search::ads_normalizer::normalize;
pub use impress_smart_search::types::NormalizationResult;
