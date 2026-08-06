//! `impress` — auto-generated CLI binary for the store-generic services.
//!
//! The suite already had `imbib` and `imprint` CLIs, but the services in
//! `impress-store-service` — collections, triage, store query, docs import —
//! belong to no app, and so had no CLI host: `impress-mcp` was the only binary
//! linking their inventory, which meant the only way to reach them was an MCP
//! client. This binary closes that gap the same way the others do: iterate
//! `impress_service_core::CliSubcommand::iter()` and build the clap `Command`
//! tree at startup, so adding a method to an `#[impress_service]` trait in
//! `impress-store-service` grows this CLI on the next build with no edit here.
//!
//! ## `--store-path`
//!
//! These services open the shared `impress.sqlite` directly, so which store
//! they open is the single most important thing about an invocation. It is
//! parsed here rather than left to clap because it is *global* — it applies to
//! every subcommand, and clap's inventory-built tree has no place for a global
//! argument. `IMPRESS_STORE_PATH` does the same job for a whole shell session.
//!
//! ```text
//! impress --store-path /path/to/impress.sqlite import-directory \
//!     --source-dir ./docs --collection ADRs --pattern 'ADR-*.md' --dry-run
//! ```

use impress_service_core::cli;

// Force the linker to retain `impress_store_service`'s inventory submissions.
// The `inventory` crate registers descriptors via static items inside a
// `submit!` block; with no direct symbol reference the linker dead-strips
// them and the CLI ends up with zero subcommands. See the matching comments
// in `imbib-cli` and `imprint-cli`.
#[allow(dead_code)]
const _STORE_SERVICE_FORCE_LINK: fn() -> impress_store_service::DefaultCollectionService =
    impress_store_service::DefaultCollectionService::new;
#[allow(dead_code)]
const _AI_SERVICE_FORCE_LINK: fn(serde_json::Value) -> impress_service_core::ServiceFuture =
    impress_ai_service::__impress_ImpressAiService_list_models_invoke;
#[allow(dead_code)]
const _DOCS_IMPORT_FORCE_LINK: fn() -> impress_store_service::DefaultDocsImportService =
    impress_store_service::DefaultDocsImportService::new;
#[allow(dead_code)]
const _SMART_SEARCH_FORCE_LINK: fn() -> impress_smart_search_service::DefaultSmartSearchService =
    impress_smart_search_service::DefaultSmartSearchService::default;
#[allow(dead_code)]
const _PARSERS_FORCE_LINK: fn() -> impress_parsers_service::DefaultParsersService =
    impress_parsers_service::DefaultParsersService::default;

/// Refuse to run against a store we cannot reach.
///
/// `store_instance()` deliberately falls back to an empty in-memory store when
/// the real one will not open, so that one bad path cannot abort a long-lived
/// MCP session. For a one-shot CLI that is the wrong trade: the user gets
/// `ok: true, total: 0` from a read and a cheerful "Imported 23 documents"
/// from a write that went nowhere. The most common cause on macOS is not a
/// typo — the shared store lives in an app-group container, and a terminal
/// without Full Disk Access is refused by TCC with the file appearing not to
/// exist at all.
fn assert_store_reachable(path: &std::path::Path) {
    // An existing store must be openable for reading.
    if path.is_file() {
        if let Err(e) = std::fs::File::open(path) {
            eprintln!("error: cannot open the store at {}: {e}", path.display());
            std::process::exit(2);
        }
        return;
    }
    // Otherwise the directory must be listable — which is what TCC denies,
    // and what makes a protected path look merely absent.
    let dir = path.parent().unwrap_or_else(|| std::path::Path::new("."));
    if let Err(e) = std::fs::read_dir(dir) {
        eprintln!(
            "error: cannot reach the store directory {}: {e}\n\
             hint: the shared store lives in a macOS app-group container. Grant your terminal \
             Full Disk Access (System Settings > Privacy & Security > Full Disk Access) and \
             run this again.",
            dir.display()
        );
        std::process::exit(2);
    }
}

/// Strip a leading `--store-path PATH` (or `--store-path=PATH`) from the
/// argument list and point the services at it. Returns the remaining args for
/// clap, which never sees the flag.
fn take_store_path(args: Vec<String>) -> Vec<String> {
    let mut out = Vec::with_capacity(args.len());
    let mut iter = args.into_iter();
    while let Some(arg) = iter.next() {
        if let Some(value) = arg.strip_prefix("--store-path=") {
            assert_store_reachable(std::path::Path::new(value));
            let _ = impress_store_service::set_store_path(value);
            continue;
        }
        if arg == "--store-path" {
            match iter.next() {
                Some(value) => {
                    assert_store_reachable(std::path::Path::new(&value));
                    let _ = impress_store_service::set_store_path(&value);
                }
                None => {
                    eprintln!("error: --store-path requires a path");
                    std::process::exit(2);
                }
            }
            continue;
        }
        out.push(arg);
    }
    out
}

fn main() {
    let args = take_store_path(std::env::args().collect());

    let app = cli::build_cli_from_inventory("impress")
        .about(
            "impress store CLI — auto-generated from the #[impress_service] traits in \
             impress-store-service. Operates on the shared impress.sqlite directly, with \
             every app closed.",
        )
        .after_help(
            "Global: --store-path <PATH> (or IMPRESS_STORE_PATH) selects the store; the \
             default is the app-group container.",
        );
    let matches = app.get_matches_from(args);

    match cli::dispatch_matches(&matches) {
        Ok(value) => match serde_json::to_string_pretty(&value) {
            Ok(s) => println!("{s}"),
            Err(e) => {
                eprintln!("error: failed to serialize result: {e}");
                std::process::exit(2);
            }
        },
        Err(e) => {
            eprintln!("error: {e}");
            std::process::exit(1);
        }
    }
}
