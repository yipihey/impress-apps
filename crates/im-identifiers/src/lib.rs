// Allow manual modulo checks since .is_multiple_of() is nightly-only
#![allow(clippy::manual_is_multiple_of)]

//! # im-identifiers
//!
//! Extract, validate, and resolve academic publication identifiers.
//!
//! ## Supported Identifiers
//!
//! - **DOI** — Digital Object Identifier (e.g., `10.1038/nature12373`)
//! - **arXiv** — Preprint identifiers, old and new formats (e.g., `2301.12345`, `hep-th/9901001`)
//! - **ISBN** — International Standard Book Number, ISBN-10 and ISBN-13 with checksum validation
//! - **PMID** — PubMed identifier
//! - **Bibcode** — NASA ADS bibcode
//!
//! ## Quick Start
//!
//! ```rust
//! use im_identifiers::{extract_dois, extract_arxiv_ids, is_valid_doi, generate_cite_key};
//!
//! // Extract identifiers from text
//! let dois = extract_dois("See doi:10.1038/nature12373 for details".into());
//! assert_eq!(dois, vec!["10.1038/nature12373"]);
//!
//! let arxiv = extract_arxiv_ids("New paper: arXiv:2301.12345v2".into());
//! assert_eq!(arxiv, vec!["2301.12345v2"]);
//!
//! // Validate identifiers
//! assert!(is_valid_doi("10.1038/nature12373".into()));
//!
//! // Generate citation keys
//! let key = generate_cite_key(
//!     Some("Einstein, Albert".into()),
//!     Some("1905".into()),
//!     Some("On the Electrodynamics of Moving Bodies".into()),
//! );
//! assert_eq!(key, "Einstein1905Electrodynamics");
//! ```

pub mod cite_key;
pub mod extractors;
pub mod mcp;
pub mod resolver;
pub mod validators;

#[cfg(feature = "python")]
pub mod python;

pub use cite_key::*;
pub use extractors::*;
pub use resolver::*;
pub use validators::*;
