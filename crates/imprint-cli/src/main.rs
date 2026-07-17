//! `imprint` — auto-generated CLI binary.
//!
//! Subcommands are NOT hand-maintained: at startup we iterate
//! `impress_service_core::CliSubcommand::iter()` (populated by the
//! `#[impress_service]` macros in `imprint-service`) and build the clap
//! `Command` tree dynamically. The same pattern powers `imbib-cli`.
//!
//! Add a method to an `#[impress_service]` trait in `imprint-service` and
//! the corresponding subcommand appears here on the next build — no edit to
//! this file required.

use impress_service_core::cli;

// Force the linker to retain `imprint_service`'s inventory submissions.
// See the matching comment in `imbib-cli/src/main.rs` for the rationale —
// without a direct symbol reference, the `inventory::submit!` statics are
// dead-stripped from the final binary and the CLI ends up with zero
// subcommands.
#[allow(dead_code)]
const _IMPRINT_SERVICE_FORCE_LINK: fn() -> imprint_service::DefaultImprintTextService =
    imprint_service::DefaultImprintTextService::default;

// Same rationale for imprint-selftest's ImprintSelftestService inventory
// (the `run-selftest` subcommand / MCP tool).
#[allow(dead_code)]
const _IMPRINT_SELFTEST_FORCE_LINK: fn() -> imprint_selftest::DefaultImprintSelftestService =
    imprint_selftest::DefaultImprintSelftestService::default;

fn main() {
    let app = cli::build_cli_from_inventory("imprint").about(
        "imprint service CLI — auto-generated from #[impress_service] traits in imprint-service.",
    );
    let matches = app.get_matches();

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
