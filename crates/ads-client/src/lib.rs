//! # ads-client
//!
//! A Rust client for the NASA ADS (Astrophysics Data System) / SciX API.
//!
//! Provides:
//! - **Library**: Async API client for search, export, metrics, libraries, and more
//! - **CLI**: `ads` binary for terminal use
//! - **MCP server**: `ads-mcp` binary for AI agent integration via JSON-RPC
//!
//! ## Quick Start
//!
//! ```no_run
//! # async fn example() -> ads_client::error::Result<()> {
//! use ads_client::AdsClient;
//!
//! // Create client from ADS_API_TOKEN environment variable
//! let client = AdsClient::from_env()?;
//!
//! // Search for papers
//! let results = client.search("author:\"Einstein\" year:1905", 10).await?;
//! for paper in &results.papers {
//!     println!("{} ({}) - {}", paper.title, paper.year.unwrap_or(0), paper.bibcode);
//! }
//!
//! // Export as BibTeX
//! let bibtex = client.export_bibtex(&["2023ApJ...123..456A"]).await?;
//! println!("{}", bibtex);
//! # Ok(())
//! # }
//! ```
//!
//! ## Query Builder
//!
//! ```
//! use ads_client::QueryBuilder;
//!
//! let query = QueryBuilder::new()
//!     .author("Weinberg")
//!     .and()
//!     .title("cosmological constant")
//!     .and()
//!     .property("refereed")
//!     .build();
//! ```

pub mod client;
pub mod error;
pub mod export;
pub mod libraries;
pub mod links;
pub mod metrics;
pub mod network;
pub mod objects;
pub mod parse;
pub mod query;
pub mod rate_limit;
pub mod references;
pub mod search;
pub mod types;

#[cfg(feature = "mcp")]
pub mod mcp;

// Re-export key types at the crate root.
pub use client::AdsClient;
pub use error::AdsError;
pub use query::QueryBuilder;
pub use types::*;
