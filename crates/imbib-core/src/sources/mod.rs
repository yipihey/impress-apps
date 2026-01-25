//! Source plugins for fetching publications from online databases

pub mod ads;
#[cfg(feature = "native")]
pub mod arxiv;
pub mod crossref;
pub mod pubmed;
pub mod traits;

pub use ads::*;
#[cfg(feature = "native")]
pub use arxiv::*;
pub use crossref::*;
pub use pubmed::*;
pub use traits::*;
