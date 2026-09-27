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

/// Strip `--wait` (ADR-0034 D6): `project-build` answers with a job handle;
/// with this flag the CLI streams the job's events to stderr and prints
/// `{ok, job, result}` when it ends. Without it the handle is printed after
/// the job has finished, since an inline job dies with its process.
fn take_wait(args: Vec<String>) -> (Vec<String>, bool) {
    let wait = args.iter().any(|a| a == "--wait");
    (args.into_iter().filter(|a| a != "--wait").collect(), wait)
}

fn main() {
    let (args, wait) = take_wait(std::env::args().collect());
    let app = cli::build_cli_from_inventory("imprint").about(
        "imprint service CLI — auto-generated from #[impress_service] traits in imprint-service.",
    ).after_help(
            "Exit status: 0 when the verb did what it was asked; 3 when it answered \
             `\"ok\": false` (the JSON on stdout says why); 1 when the verb could not be \
             dispatched; 2 for a bad invocation.\n\nJobs: `project-build` answers at once \
             with `{\"ok\", \"job\": {id, kind, state}}`; `--wait` streams its events to \
             stderr and prints `{ok, job, result}` when it ends.",
        );
    let matches = app.get_matches_from(args);

    match cli::dispatch_matches(&matches) {
        Ok(value) => {
            // A job handle is streamed or drained before anything prints
            // (ADR-0034 D6); a plain result passes through.
            let value = impress_store_service::job::cli_finish(value, wait);
            match serde_json::to_string_pretty(&value) {
                Ok(s) => {
                    println!("{s}");
                    // See the matching comment in `impress-cli/src/main.rs`:
                    // without this, a one-shot process can exit out from
                    // under the audit sink's writer thread and drop the
                    // `core/verb-call` row it just wrote.
                    impress_store_service::audit::flush();
                    // A refusal is not a success (review AC-F12): the verb's own
                    // `ok: false` sets the status a script tests, as in `impress`.
                    std::process::exit(impress_service_core::refusal::exit_status(&value));
                }
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
