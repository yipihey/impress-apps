//! `imbib` — auto-generated CLI binary.
//!
//! Subcommands are NOT hand-maintained: at startup we iterate
//! `impress_service_core::CliSubcommand::iter()` (populated by the
//! `#[impress_service]` macros in `imbib-service`) and build the clap
//! `Command` tree dynamically. The same pattern powers `imprint-cli`.
//!
//! Add a method to an `#[impress_service]` trait in `imbib-service` and
//! the corresponding subcommand appears here on the next build — no edit to
//! this file required.

use impress_service_core::cli;

// Force the linker to retain `imbib_service`'s inventory submissions. The
// `inventory` crate registers descriptors via static items inside a
// `submit!` block; if no symbol from `imbib_service` is referenced from the
// final binary, the linker dead-strips those statics and the CLI ends up
// with zero subcommands. Touching any public symbol (here: the
// trait-default struct) keeps the entire crate alive.
#[allow(dead_code)]
const _IMBIB_SERVICE_FORCE_LINK: fn() -> imbib_service::DefaultImbibTextService =
    imbib_service::DefaultImbibTextService::default;

fn main() {
    let app = cli::build_cli_from_inventory("imbib").about(
        "imbib service CLI — auto-generated from #[impress_service] traits in imbib-service.",
    );
    let matches = app.get_matches();

    match cli::dispatch_matches(&matches) {
        Ok(value) => {
            // Pretty-print so library users / tests can grep the output.
            match serde_json::to_string_pretty(&value) {
                Ok(s) => println!("{s}"),
                Err(e) => {
                    eprintln!("error: failed to serialize result: {e}");
                    std::process::exit(2);
                }
            }
        }
        Err(e) => {
            eprintln!("error: {e}");
            std::process::exit(1);
        }
    }
}
