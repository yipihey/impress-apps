//! Writes imbib's App Intents from the linked verb inventory (koine
//! docs/plan-koine-trust.md TR-D14): an `AppIntent` per imbib verb that
//! declares `intent(…)`, an `AppEntity` per kind with `entity(lookup)` and
//! `entity(search)` verbs. The files are committed;
//! `scripts/check-app-intents.sh` regenerates them and fails on a diff.
//!
//! imbib keeps its hand-written `AppShortcutsProvider` (an app has one), so
//! the generated provider is left out; the hand-written one lists the
//! generated intents it offers.

use std::path::PathBuf;

use impress_service_core::call;
use koine_app_intents::{generate, AppInfo};

/// Where the imbib files go, under the repository root.
const IMBIB_DIR: &str =
    "apps/imbib/PublicationManagerCore/Sources/PublicationManagerCore/VerbIntents";

fn main() {
    impress_capabilities::force_link();
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..");
    let verbs: Vec<_> = call::descriptors()
        .filter(|verb| verb.service().starts_with("imbib-"))
        .collect();
    let mut app = AppInfo::impress("Imbib");
    app.shortcuts = false;
    app.imports = vec!["ImbibVerbsFFI".into()];
    let generated = generate(&verbs, &app);
    let dir = root.join(IMBIB_DIR);
    if dir.exists() {
        std::fs::remove_dir_all(&dir).expect("clear the generated directory");
    }
    std::fs::create_dir_all(&dir).expect("create the generated directory");
    for (name, text) in &generated.files {
        std::fs::write(dir.join(name), text).expect("write a generated file");
    }
    println!("wrote {} file(s) to {IMBIB_DIR}", generated.files.len());
    for (verb, why) in &generated.skipped {
        println!("skipped {verb}: {why}");
    }
}
