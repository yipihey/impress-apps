//! impress-mcp — MCP server for local impress suite search.
//!
//! Exposes semantic search over locally indexed PDFs via the
//! Model Context Protocol (JSON-RPC 2.0 over stdio).

mod inventory_bridge;
mod raster;
mod reachability;
mod server;
mod store;
mod tools;

// Phase 3B: force the linker to retain the `inventory::submit!` entries
// that the service crates register at static-init time. Without an
// explicit reference, dead-code elimination on rlib-only deps can drop
// the entire crate (and its `ctor`-style submissions with it).
#[allow(unused_imports)]
use imbib_service as _force_link_imbib_service;
#[allow(unused_imports)]
use impart_service as _force_link_impart_service;
#[allow(unused_imports)]
use implore_service as _force_link_implore_service;
#[allow(unused_imports)]
use impress_bridges_service as _force_link_bridges;
#[allow(unused_imports)]
use imprint_selftest as _force_link_imprint_selftest;
#[allow(unused_imports)]
use imprint_service as _force_link_imprint_service;

use std::path::PathBuf;
use tools::ToolContext;

fn default_embeddings_path() -> PathBuf {
    dirs::data_dir()
        .expect("Could not determine data directory")
        .join("imbib/embeddings.sqlite")
}

fn default_main_store_path() -> PathBuf {
    dirs::home_dir()
        .expect("Could not determine home directory")
        .join("Library/Group Containers/QG3MEYVHMS.com.impress.suite/workspace/impress.sqlite")
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    // Phase A/B/C: try the HTTP backend first (lets us drive the live store
    // through the running imbib macOS app, bypassing macOS TCC restrictions
    // on the sandboxed group container). Falls back silently to SQLite.
    // The probes double as a reachability record: tools that only work while
    // their app is running are withheld from tools/list when it is not, rather
    // than advertised and answering with an empty list.
    let imbib = imbib_service_http::maybe_install_http_backend();
    // Phase E: same dance for imprint (port 23121).
    let imprint = imprint_service_http::maybe_install_http_backend();
    let implore = implore_service_http::maybe_install_http_backend();
    let impart = impart_service_http::maybe_install_http_backend();
    reachability::record(reachability::Reachable {
        imbib,
        imprint,
        implore,
        impart,
    });

    let args: Vec<String> = std::env::args().collect();

    let mut embeddings_path = default_embeddings_path();
    let mut store_path = default_main_store_path();

    // Parse CLI overrides
    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--embeddings-path" => {
                i += 1;
                embeddings_path =
                    PathBuf::from(args.get(i).expect("Missing value for --embeddings-path"));
            }
            "--store-path" => {
                i += 1;
                store_path = PathBuf::from(args.get(i).expect("Missing value for --store-path"));
            }
            _ => {
                eprintln!("Unknown argument: {}", args[i]);
                std::process::exit(1);
            }
        }
        i += 1;
    }

    // The embedding stack (store + HNSW rebuild + fastembed model) is NOT
    // built here. It is built on the first semantic-search call — see
    // `ToolContext::semantic`. Building it eagerly cost seconds on a large
    // library and could reach the network for the model, which made this
    // binary unusable as a sidecar spawned at app launch (impel). Clients
    // that only use the `#[impress_service]` inventory tools never pay it.

    // Open main store (optional — metadata enrichment degrades gracefully)
    let main_store = if store_path.exists() {
        match store::open_main_store(&store_path) {
            Ok(conn) => {
                eprintln!("impress-mcp: main store opened at {}", store_path.display());
                Some(conn)
            }
            Err(e) => {
                eprintln!("impress-mcp: warning: could not open main store: {}", e);
                None
            }
        }
    } else {
        eprintln!(
            "impress-mcp: main store not found at {}, metadata enrichment disabled",
            store_path.display()
        );
        None
    };

    eprintln!("impress-mcp: ready (semantic search deferred until first use)");

    let ctx = ToolContext::deferred(embeddings_path, main_store);

    server::run_server(ctx)
}
