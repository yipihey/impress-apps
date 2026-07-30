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
use impress_smart_search_service as _force_link_smart_search_service;
#[allow(unused_imports)]
use impress_store_service as _force_link_store_service;
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

/// Usage plus a live connection check. Tool counts come from the same
/// enumeration `tools/list` uses, so what this prints is what a client sees —
/// including the withholding of namespaces whose app is closed.
fn print_help(store_path: &std::path::Path) {
    let r = reachability::current();
    let say = |name: &str, up: bool| {
        println!(
            "  {name:<8} {}",
            if up { "reachable" } else { "not running" }
        );
    };
    println!("impress-mcp — the MCP server for the impress suite");
    println!();
    println!("USAGE");
    println!("  impress-mcp [--store-path PATH] [--embeddings-path PATH]");
    println!("  impress-mcp --help | --version");
    println!();
    println!("Speaks MCP over stdio; it is launched by a client, not run by hand.");
    println!("Setup: apps/imbib/docs/MCP-Setup-Guide.md");
    println!();
    println!("CONNECTION CHECK");
    say("imbib", r.imbib);
    say("imprint", r.imprint);
    say("implore", r.implore);
    say("impart", r.impart);
    println!();
    println!("  tools exposed now:  {}", server::exposed_tool_count());
    println!("  tools total:        {}", server::total_tool_count());
    println!("  (tools for an app that is not running are withheld from");
    println!("   tools/list; set IMPRESS_MCP_LIST_ALL=1 to see all of them)");
    println!();
    println!("  store: {}", store_path.display());
    if !store_path.exists() {
        println!("         MISSING — falling back to the HTTP backend only");
    }
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
            // `sign.sh` and `apps/imbib/docs/MCP-Setup-Guide.md` both tell the
            // reader to run this, so it has to exist. It doubles as the
            // connection check the guide describes: the probes above have
            // already run, so we can report what is reachable.
            "--help" | "-h" => {
                print_help(&store_path);
                return Ok(());
            }
            "--version" | "-V" => {
                println!("impress-mcp {}", env!("CARGO_PKG_VERSION"));
                return Ok(());
            }
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

    // The store-generic services (collections, triage) open the shared store
    // themselves rather than going through an app, so point them at the same
    // path this server was given — otherwise `--store-path` would mean one
    // thing for search and another for every collection mutation. Recorded,
    // not opened: the store opens lazily on the first such call, so clients
    // that never touch it pay nothing.
    let _ = impress_store_service::set_store_path(&store_path);

    // The embedding stack (store + HNSW rebuild + fastembed model) is NOT
    // built here. It is built on the first semantic-search call — see
    // `ToolContext::semantic`. Building it eagerly cost seconds on a large
    // library and could reach the network for the model, which made this
    // binary unusable as a sidecar spawned at app launch (impel). Clients
    // that only use the `#[impress_service]` inventory tools never pay it.

    // The store is NOT opened here. It is opened on first use — see
    // `ToolContext::main_store`. Opening it eagerly meant that a store which
    // was large, locked, or mid-WAL-recovery delayed startup past the client's
    // patience, and because this happens before `run_server` the client got no
    // `initialize` response at all. Protocol setup, `tools/list` and every
    // store-independent call must work regardless of the store's state.

    let ctx = ToolContext::deferred(embeddings_path, store_path);

    server::run_server(ctx)
}
