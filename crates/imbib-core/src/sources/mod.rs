//! Source plugins for fetching publications from online databases.
//!
//! ADS/SciX parsing has been moved to scix-client-ffi (UniFFI bindings for the
//! scix-client crate). The Swift layer calls scix-client-ffi directly for all
//! ADS/SciX HTTP operations and parsing.

#[cfg(feature = "native")]
pub mod arxiv;
pub mod crossref;
pub mod pubmed;
pub mod traits;

#[cfg(feature = "native")]
pub use arxiv::*;
pub use crossref::*;
pub use pubmed::*;
pub use traits::*;
