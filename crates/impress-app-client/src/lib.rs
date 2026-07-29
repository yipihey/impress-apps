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

/// Build a loopback HTTP client that cannot panic and never consults the
/// system proxy configuration.
///
/// Two reasons, both real failures:
///
/// * **Panic in a sandbox.** `reqwest`'s default builder asks macOS for the
///   system proxy settings, which goes through `SCDynamicStore::create`. In a
///   filesystem-sandboxed process that aborts, so `.build().expect(...)` took
///   the whole MCP server down before it could answer `initialize` — the
///   client is constructed during the startup app probes.
/// * **Pointless.** Every one of these clients talks to `127.0.0.1`. A proxy
///   is never the right route to a loopback port, so `no_proxy()` is also the
///   correct configuration, not merely the safe one.
///
/// Falls back to a default client if a builder somehow still fails, so a
/// transport problem surfaces as a request error rather than a dead process.
pub fn loopback_http_client(builder: reqwest::ClientBuilder) -> reqwest::Client {
    builder
        .no_proxy()
        .build()
        .unwrap_or_else(|_| reqwest::Client::new())
}

pub mod error;
pub mod imbib;
pub mod imprint;
pub(crate) mod transport;

pub use error::{AppClientError, Result};
pub use imbib::ImbibClient;
pub use imprint::{ImprintClient, ImprintServerInfo};
pub use transport::ServerInfo;
