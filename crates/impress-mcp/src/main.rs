//! impress-mcp — MCP server for local impress suite search.
//!
//! Exposes semantic search over locally indexed PDFs via the
//! Model Context Protocol (JSON-RPC 2.0 over stdio).

mod inventory_bridge;
mod providers;
mod raster;
mod reachability;
mod server;
mod surface;

// ADR-0033 D4 / plan S2: the force-link list this comment used to carry
// (fourteen `use X as _force_link_X;` lines, one per `*-service` crate) has
// moved to `crates/impress-capabilities`, the one place the
// `#[impress_service]` inventory is linked now — see that crate's module docs
// for why the linker needs a reference at all. This binary links it with
// `features = ["full"]` (Cargo.toml), so it still links every capability it
// always did; `inventory_bridge` (below) delegates to
// `impress_capabilities::descriptors()`/`call()`, and those real calls are
// themselves the reference that keeps `impress-capabilities` — and,
// transitively, everything it names — out of the linker's dead-code path.

use std::path::PathBuf;

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
    println!("  impress-mcp [--store-path PATH]");
    println!("  impress-mcp --http 127.0.0.1:PORT --token-file PATH [--store-path PATH]");
    println!("  impress-mcp --provider-docs OUTPUT_DIR [--store-path PATH]");
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
    // G7b: the perf aggregator, so `perf-service_summary` sees this
    // process's own verb spans. stdio transport has no Console to bridge
    // logs to, so unlike the FFI host this installs only the aggregator,
    // no log-forwarding layer.
    {
        use tracing_subscriber::layer::SubscriberExt;
        let subscriber =
            tracing_subscriber::registry().with(impress_service_core::pipeline::perf::layer());
        let _ = tracing::subscriber::set_global_default(subscriber);
    }
    impress_app_transport::install(true);

    let args: Vec<String> = std::env::args().collect();

    let mut store_path = std::env::var_os("IMPRESS_STORE_PATH")
        .or_else(|| std::env::var_os("IMBIB_STORE_PATH"))
        .map(PathBuf::from)
        .unwrap_or_else(default_main_store_path);

    let mut provider_docs: Option<PathBuf> = None;
    let mut http_bind: Option<String> = None;
    let mut token_file: Option<PathBuf> = None;

    // Parse CLI overrides
    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            // `sign.sh` and `apps/imbib/docs/MCP-Setup-Guide.md` both tell the
            // reader to run this, so it has to exist. It doubles as the
            // connection check the guide describes: the probes above have
            // already run, so we can report what is reachable.
            "--help" | "-h" => {
                reachability::refresh();
                print_help(&store_path);
                return Ok(());
            }
            "--version" | "-V" => {
                println!("impress-mcp {}", env!("CARGO_PKG_VERSION"));
                return Ok(());
            }
            // `--embeddings-path` retired with P3c step 1: the three
            // semantic-search tools now live in `imbib-semantic-service`,
            // reached through the `#[impress_service]` inventory rather than
            // a hand-written `ToolContext` this binary constructed itself,
            // and that service picks its own default embeddings path
            // (`SemanticState::default_embeddings_path`).
            "--provider-docs" => {
                i += 1;
                provider_docs = Some(PathBuf::from(args.get(i).ok_or("Missing value for --provider-docs")?));
            }
            "--http" => {
                i += 1;
                http_bind = Some(args.get(i).ok_or("Missing value for --http")?.clone());
            }
            "--token-file" => {
                i += 1;
                token_file = Some(PathBuf::from(args.get(i).ok_or("Missing value for --token-file")?));
            }
            "--store-path" => {
                i += 1;
                store_path = PathBuf::from(args.get(i).expect("Missing value for --store-path"));
                std::env::set_var("IMPRESS_STORE_PATH", &store_path);
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

    // The embedding stack (store + HNSW rebuild + fastembed model), and the
    // main store `imbib-semantic-service` reads for publication metadata,
    // are NOT built here. `imbib_semantic_service::SemanticState` builds them
    // on the first semantic-search call, same as before P3c step 1 moved
    // that logic out of this binary's own `ToolContext`. Building either
    // eagerly cost seconds on a large library and could reach the network
    // for the model, which made this binary unusable as a sidecar spawned at
    // app launch (impel); a store that was large, locked, or mid-WAL-recovery
    // delayed `initialize` past the client's patience.

    if let Some(out_dir) = provider_docs {
        if http_bind.is_some() || token_file.is_some() {
            return Err("--provider-docs cannot be combined with --http or --token-file".into());
        }
        providers::restore()?;
        let docs = impress_capabilities::verb_docs::render(impress_capabilities::descriptors());
        let count = docs.write_to_dir(&out_dir)?;
        eprintln!("wrote {count} reference pages to {}", out_dir.display());
        return Ok(());
    }
    if let Some(bind) = http_bind {
        let token_file = token_file.ok_or("--http requires --token-file")?;
        return providers::run_http(&bind, &token_file);
    }
    if token_file.is_some() {
        return Err("--token-file requires --http".into());
    }
    reachability::refresh();
    providers::restore()?;
    let health = impress_service_core::runtime::spawn(async {
        loop {
            // Read-only liveness probes do not mutate store rows.
            impress_service_core::registry_runtime::refresh_health().await;
            tokio::time::sleep(std::time::Duration::from_secs(5)).await;
        }
    });
    let result = server::run_server();
    health.abort();
    result
}
