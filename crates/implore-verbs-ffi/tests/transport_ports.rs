//! Pin the transport's port table (koine's `impress-app-transport`) against
//! `SiblingApp.descriptors` (CLAUDE.md's "exactly ONE authoritative port
//! table") so the Rust copy cannot drift silently the way implore's own port
//! did in 2026-07-30. The test lives here because the Swift source does not
//! exist in koine's repository. A crude grep, not a Swift parse: it asserts
//! every port number the Rust table declares appears somewhere in the Swift
//! file, which is loose but catches the failure that matters (a renumbering
//! nobody carried over).

use impress_app_transport::ports::PORTS;

#[test]
fn matches_the_swift_port_table() {
    let manifest_dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
    let swift_path = manifest_dir
        .join("../../packages/ImpressKit/Sources/ImpressKit/SiblingApp.swift")
        .canonicalize()
        .expect("SiblingApp.swift should exist relative to this crate");
    let source = std::fs::read_to_string(&swift_path).expect("read SiblingApp.swift");
    for (app, port) in PORTS {
        assert!(
            source.contains(&port.to_string()),
            "SiblingApp.swift no longer mentions {port} (the transport's port for {app}); \
             update koine's crates/impress-app-transport/src/ports.rs to match"
        );
    }
}
