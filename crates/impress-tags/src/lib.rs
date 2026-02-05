//! impress-tags: Hierarchical tag models, autocomplete, and query.
//!
//! Tags represent knowledge categorization (topics, methods, domains).
//! They use hierarchical paths like `methods/sims/hydro/AMR`.
//! Tags sync across devices AND export to BibTeX as `keywords`.

#[cfg(feature = "native")]
uniffi::setup_scaffolding!();

pub mod tag;
pub mod hierarchy;
pub mod parse;
pub mod query;
pub mod autocomplete;
pub mod alias;
pub mod config;

pub use tag::*;
pub use hierarchy::*;
pub use parse::*;
pub use query::*;
pub use autocomplete::*;
pub use alias::*;
pub use config::*;
