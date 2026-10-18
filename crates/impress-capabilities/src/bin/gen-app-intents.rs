//! Writes the apps' App Intents from the linked verb inventory (koine
//! docs/plan-koine-trust.md TR-D14): per app, an `AppIntent` per verb of its
//! services that declares `intent(…)`, and an `AppEntity` per kind with
//! `entity(lookup)` and `entity(search)` verbs. The files are committed;
//! `scripts/check-app-intents.sh` regenerates them and fails on a diff.
//!
//! Each app keeps its hand-written `AppShortcutsProvider` (an app has one),
//! so the generated provider is left out; imbib's lists the generated
//! intents it offers. imprint's and implore's providers live in their Core
//! packages, which do not see the app target the generated files are in.

use std::path::PathBuf;

use impress_service_core::call;
use koine_app_intents::{generate, AppInfo};

/// An app: its type prefix, the prefix its services' names share, its verbs
/// FFI module, and where its files go under the repository root.
struct App {
    prefix: &'static str,
    services: &'static str,
    ffi: &'static str,
    dir: &'static str,
}

const APPS: &[App] = &[
    App {
        prefix: "Imbib",
        services: "imbib-",
        ffi: "ImbibVerbsFFI",
        dir: "apps/imbib/PublicationManagerCore/Sources/ImbibAppIntents/VerbIntents",
    },
    App {
        prefix: "Imprint",
        services: "imprint-",
        ffi: "ImprintVerbsFFI",
        dir: "apps/imprint/Shared/VerbIntents",
    },
    App {
        prefix: "Implore",
        services: "implore-",
        ffi: "ImploreVerbsFFI",
        dir: "apps/implore/Implore/Sources/VerbIntents",
    },
];

fn main() {
    impress_capabilities::force_link();
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..");
    for app in APPS {
        let verbs: Vec<_> = call::descriptors()
            .filter(|verb| verb.service().starts_with(app.services))
            .collect();
        let mut info = AppInfo::impress(app.prefix);
        info.shortcuts = false;
        info.imports = vec![app.ffi.into()];
        let generated = generate(&verbs, &info);
        let dir = root.join(app.dir);
        if dir.exists() {
            std::fs::remove_dir_all(&dir).expect("clear the generated directory");
        }
        std::fs::create_dir_all(&dir).expect("create the generated directory");
        for (name, text) in &generated.files {
            std::fs::write(dir.join(name), text).expect("write a generated file");
        }
        println!("wrote {} file(s) to {}", generated.files.len(), app.dir);
        for (verb, why) in &generated.skipped {
            println!("skipped {verb}: {why}");
        }
    }
}
