//! Citation management module.
//!
//! This module is organized into submodules:
//!
//! - [`provider`]: the existing trait-based citation provider/chain abstraction
//!   used by imprint's CRDT document layer to resolve citations against
//!   pluggable sources (local library, web APIs, etc.).
//! - [`extract`]: regex-based extraction of cite keys from manuscript source
//!   (Typst `@key`, LaTeX `\cite{key}` and its variants). Ported from Swift
//!   `BibliographyGenerator.extractCiteKeys` and `CitationUsageTracker`.
//! - [`hit`]: "which cite key is under this caret / touch point?", derived from
//!   [`extract`] so the editors' hover / long-press affordances cannot drift
//!   from the canonical scanner.
//! - [`usage`]: aggregation index that groups extracted cite-key usages by
//!   key, exposing first-use position and duplicate counts. Ported from
//!   `CitationUsageTracker`.
//! - [`project`]: filtering/sorting/grouping primitives for projecting a set
//!   of resolved citations into a presentation order. Ported from Swift
//!   `BibliographyProjector`.

pub mod compose;
pub mod extract;
pub mod hit;
pub mod project;
pub mod provider;
pub mod usage;

// Preserve the previous flat re-exports from the old `citations.rs` so
// downstream callers (which `use imprint_core::citations::*`) still see the
// provider types.
pub use compose::*;
pub use extract::*;
pub use hit::*;
pub use project::*;
pub use provider::*;
pub use usage::*;
