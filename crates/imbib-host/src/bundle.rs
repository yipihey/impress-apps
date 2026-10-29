//! Launched as "imbib Web.app": the arguments the bundle cannot pass.
//!
//! LaunchServices starts `Contents/MacOS/imbib-host` with no arguments, so
//! a bare launch from inside a bundle re-executes itself (same pid, so the
//! Dock keeps its icon) with what `run.sh` would have passed: the native
//! window, the page from `Contents/Resources/web`, the suite's port for
//! imbib Web (`SiblingApp.Services.imbibWebPort`, 23127), and the log in
//! `~/Library/Logs/Impress/imbib-web.log`, since a Finder launch has no terminal.
//! Any argument at all, or a binary outside a bundle, runs as given.

use std::path::{Path, PathBuf};
use std::process::Command;

/// imbib Web's port in the suite's table
/// (`packages/ImpressKit/.../SiblingApp.swift`, `Services.imbibWebPort`).
pub const PORT: u16 = 23127;

/// The command a bare launch from a bundle becomes, or `None` to run as
/// given.
pub fn relaunch() -> Option<Command> {
    let mut args = std::env::args_os().skip(1);
    // Old LaunchServices passed a process serial number; nothing else.
    if args.any(|a| !a.to_string_lossy().starts_with("-psn_")) {
        return None;
    }
    let exe = std::env::current_exe().ok()?;
    let web = resources_of(&exe)?.join("web");
    let mut command = Command::new(&exe);
    command
        .arg("--window")
        .arg("--port")
        .arg(PORT.to_string())
        .arg("--web-dir")
        .arg(web);
    if std::env::var_os("RUST_LOG").is_none() {
        command.env("RUST_LOG", "warn,koine-host=info,sources=info,feeds=info");
    }
    if let Some(log) = log_file() {
        if let Ok(out) = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&log)
        {
            if let Ok(err) = out.try_clone() {
                command.stdout(out).stderr(err);
            }
        }
    }
    Some(command)
}

/// `<bundle>/Contents/Resources` when `exe` is `<bundle>/Contents/MacOS/<name>`.
fn resources_of(exe: &Path) -> Option<PathBuf> {
    let macos = exe.parent()?;
    let contents = macos.parent()?;
    (macos.file_name()? == "MacOS" && contents.file_name()? == "Contents")
        .then(|| contents.join("Resources"))
}

fn log_file() -> Option<PathBuf> {
    let logs = PathBuf::from(std::env::var_os("HOME")?).join("Library/Logs/Impress");
    std::fs::create_dir_all(&logs).ok()?;
    Some(logs.join("imbib-web.log"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_a_binary_in_contents_macos_has_bundle_resources() {
        assert_eq!(
            resources_of(Path::new("/A/imbib Web.app/Contents/MacOS/imbib-host")),
            Some(PathBuf::from("/A/imbib Web.app/Contents/Resources"))
        );
        assert_eq!(
            resources_of(Path::new("/repo/target/release/imbib-host")),
            None
        );
    }
}
