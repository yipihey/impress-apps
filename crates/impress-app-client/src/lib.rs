//! Typed HTTP client for the impress macOS apps' automation APIs.
//!
//! The macOS apps (imbib, imprint, …) each run a local HTTP server on a
//! loopback port that mirrors their service API. This crate provides a
//! Rust-side client so other Rust code (the MCP server, CLI, future TUI)
//! can drive the apps without needing direct filesystem access to the
//! sandboxed group container.
//!
//! Why: macOS TCC blocks shell-launched binaries from reading
//! `~/Library/Group Containers/group.com.impress.suite/...` even with the
//! correct app-groups entitlement (Files & Folders TCC category needs a
//! GUI prompt that stdio binaries can't trigger). Going through the
//! running app's HTTP API sidesteps this entirely AND ensures writes are
//! observed by the live app + CloudKit sync engines.

pub mod error;
pub mod imbib;
pub mod imprint;
pub(crate) mod transport;

pub use error::{AppClientError, Result};
pub use imbib::ImbibClient;
pub use imprint::{ImprintClient, ImprintServerInfo};
pub use transport::ServerInfo;
