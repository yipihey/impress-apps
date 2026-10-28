//! `imbib-host`: imbib served by koine-host, drawn by koine-web.
//!
//! ```text
//! imbib-host --port 23127 --web-dir <koine>/target/dx/koine-web/release/web/public
//! imbib-host --window --web-dir <bundle>       # a native window on the Mac
//! imbib-host verbs | grep imbib-                # what it serves
//! imbib-host call imbib-library-service_list-libraries '{}'
//! ```
//!
//! The flags are koine-host's (`--help`). Without `--store` it opens the
//! suite's SQLite library, not koine-host's `dir:` default.

use std::process::ExitCode;

fn main() -> ExitCode {
    imbib_host::link();
    let explicit_store = std::env::args().any(|a| a == "--store" || a.starts_with("--store="));
    koine_host::cli::main_configured(
        "imbib",
        |config| {
            if !explicit_store {
                config.store_url = imbib_host::default_store_url();
            }
            config.packages.push(imbib_host::package::package());
        },
        |_, _, _| imbib_host::layer_imbib_secrets(),
    )
}
