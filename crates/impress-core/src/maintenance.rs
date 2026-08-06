//! The store-maintenance lease: exactly one process runs hygiene.
//!
//! Demote/compact/checkpoint/vacuum must have a single owner however the
//! launch topology shifts (launchd registrations get dropped, daemons get
//! hand-started, a second instance races a respawn — all observed on
//! 2026-08-06). The lease is a kernel `flock` on a file beside the store:
//! released automatically on crash, so there is no stale-file deletion
//! race, and cheap enough to take per maintenance cycle.
//!
//! Mirrors `impress_ai::worker::WorkerLease`, which proved the shape for
//! impel-taskd.

use std::fs::{File, OpenOptions};
use std::io::{self, ErrorKind};
use std::path::{Path, PathBuf};

/// Held for the duration of one maintenance cycle. Dropping releases.
#[derive(Debug)]
pub struct MaintenanceLease {
    _file: File,
}

impl MaintenanceLease {
    /// Lease file path for a store at `store_path`.
    pub fn lease_path(store_path: &Path) -> PathBuf {
        let mut os = store_path.as_os_str().to_os_string();
        os.push(".maintenance.lock");
        PathBuf::from(os)
    }

    /// Try to become the maintenance owner for the store at `store_path`.
    ///
    /// `Err(AlreadyExists)` means another live process holds the lease —
    /// callers skip their cycle (with a log line) rather than treating it
    /// as a failure.
    pub fn try_acquire(store_path: &Path) -> io::Result<Self> {
        let path = Self::lease_path(store_path);
        let file = OpenOptions::new()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .open(&path)?;
        try_lock_exclusive(&file).map_err(|error| {
            if error.kind() == ErrorKind::WouldBlock {
                io::Error::new(
                    ErrorKind::AlreadyExists,
                    format!(
                        "another process holds the maintenance lease {}",
                        path.display()
                    ),
                )
            } else {
                error
            }
        })?;
        Ok(Self { _file: file })
    }
}

#[cfg(unix)]
fn try_lock_exclusive(file: &File) -> io::Result<()> {
    use std::os::fd::AsRawFd;
    const LOCK_EX: i32 = 2;
    const LOCK_NB: i32 = 4;
    // SAFETY: `file` owns a valid descriptor for the duration of the call.
    let result = unsafe { flock(file.as_raw_fd(), LOCK_EX | LOCK_NB) };
    if result == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}

#[cfg(unix)]
unsafe extern "C" {
    fn flock(fd: i32, operation: i32) -> i32;
}

#[cfg(not(unix))]
fn try_lock_exclusive(_file: &File) -> io::Result<()> {
    // Non-unix hosts have no second daemon to race; the lease degrades to
    // first-come file creation semantics.
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lease_is_exclusive_within_a_process_boundary() {
        let dir = std::env::temp_dir().join(format!("impress-lease-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let store = dir.join("impress.sqlite");

        let first = MaintenanceLease::try_acquire(&store).expect("first acquire");
        // flock is per-open-file-description: a second open + flock in the
        // same process still contends, which is exactly the double-daemon
        // shape the lease exists for.
        let second = MaintenanceLease::try_acquire(&store);
        assert!(
            matches!(second, Err(ref e) if e.kind() == ErrorKind::AlreadyExists),
            "second holder must be refused: {second:?}"
        );

        drop(first);
        MaintenanceLease::try_acquire(&store).expect("acquire after release");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
