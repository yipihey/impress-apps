//! `imbib-host`: imbib served by koine-host, drawn by koine-web.
//!
//! ```text
//! imbib-host --port 23127 --web-dir <koine>/target/dx/koine-web/release/web/public
//! imbib-host --window --web-dir <bundle>       # a native window on the Mac
//! imbib-host verbs | grep imbib-                # what it serves
//! imbib-host call imbib-library-service_list-libraries '{}'
//! ```
//!
//! Inside "imbib Web.app" a bare launch takes the bundle's arguments
//! ([`imbib_host::bundle`]). The flags are koine-host's (`--help`). Without `--store` it opens the
//! suite's SQLite library, not koine-host's `dir:` default.

use std::process::ExitCode;

fn main() -> ExitCode {
    if let Some(mut command) = imbib_host::bundle::relaunch() {
        use std::os::unix::process::CommandExt;
        let error = command.exec();
        eprintln!("imbib-host: cannot relaunch with the bundle's arguments: {error}");
        return ExitCode::FAILURE;
    }
    imbib_host::bundle::restore_home();
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
        |_, served, _| {
            imbib_host::layer_imbib_secrets();
            match served.waker() {
                Some(waker) => imbib_host::elsewhere::listen(waker),
                None => tracing::warn!(target: "koine-host",
                    "the store has no feed; pages will not redraw on any write"),
            }
        },
    )
}
