//! Device-local lifecycle protocol for the Impress model worker.
//!
//! The worker status is deliberately a file beside the shared database, not
//! an item in the synced graph. A phone and a laptop can legitimately observe
//! different worker reachability while still agreeing on every queued task.

use std::fs::{self, File, OpenOptions};
use std::io::{self, ErrorKind, Write};
#[cfg(unix)]
use std::os::fd::AsRawFd;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

pub const WORKER_PROTOCOL_VERSION: u32 = 1;
pub const WORKER_HEARTBEAT_INTERVAL_SECS: u64 = 5;
pub const WORKER_STALE_AFTER_SECS: u64 = 20;

const RUNTIME_DIRECTORY: &str = "runtime";
const STATUS_FILE: &str = "impel-taskd.status.json";
const LEASE_FILE: &str = "impel-taskd.lock";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WorkerLifecycleState {
    Starting,
    Settling,
    Ready,
    Stopping,
    Failed,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WorkerStatusSnapshot {
    pub protocol_version: u32,
    pub worker_id: String,
    pub pid: u32,
    pub state: WorkerLifecycleState,
    pub started_at_ms: i64,
    pub heartbeat_at_ms: i64,
    pub poll_interval_secs: u64,
    pub endpoint_id: String,
    pub last_pass_at_ms: Option<i64>,
    pub last_error: Option<String>,
    pub acquired_total: u64,
    pub completed_total: u64,
    pub suspended_total: u64,
    pub retried_total: u64,
    pub failed_total: u64,
}

impl WorkerStatusSnapshot {
    pub fn new(
        worker_id: String,
        pid: u32,
        now_ms: i64,
        poll_interval_secs: u64,
        endpoint_id: String,
    ) -> Self {
        Self {
            protocol_version: WORKER_PROTOCOL_VERSION,
            worker_id,
            pid,
            state: WorkerLifecycleState::Starting,
            started_at_ms: now_ms,
            heartbeat_at_ms: now_ms,
            poll_interval_secs,
            endpoint_id,
            last_pass_at_ms: None,
            last_error: None,
            acquired_total: 0,
            completed_total: 0,
            suspended_total: 0,
            retried_total: 0,
            failed_total: 0,
        }
    }

    pub fn is_fresh_at(&self, now_ms: i64) -> bool {
        now_ms.saturating_sub(self.heartbeat_at_ms) <= (WORKER_STALE_AFTER_SECS as i64) * 1_000
    }
}

pub fn worker_runtime_directory(workspace: impl AsRef<Path>) -> PathBuf {
    workspace.as_ref().join(RUNTIME_DIRECTORY)
}

pub fn worker_status_path(workspace: impl AsRef<Path>) -> PathBuf {
    worker_runtime_directory(workspace).join(STATUS_FILE)
}

pub fn read_worker_status(workspace: impl AsRef<Path>) -> io::Result<Option<WorkerStatusSnapshot>> {
    let path = worker_status_path(workspace);
    let bytes = match fs::read(&path) {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error),
    };
    serde_json::from_slice(&bytes).map(Some).map_err(|error| {
        io::Error::new(
            ErrorKind::InvalidData,
            format!("decode worker status {}: {error}", path.display()),
        )
    })
}

pub fn write_worker_status(
    workspace: impl AsRef<Path>,
    status: &WorkerStatusSnapshot,
) -> io::Result<()> {
    let runtime = worker_runtime_directory(workspace);
    fs::create_dir_all(&runtime)?;
    let destination = runtime.join(STATUS_FILE);
    let temporary = runtime.join(format!(".{STATUS_FILE}.{}.tmp", status.pid));
    let bytes = serde_json::to_vec(status).map_err(io::Error::other)?;

    let write_result = (|| {
        let mut file = File::create(&temporary)?;
        file.write_all(&bytes)?;
        file.sync_all()?;
        fs::rename(&temporary, &destination)
    })();
    if write_result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    write_result
}

/// Exclusive process-lifetime lock for one worker per workspace.
///
/// The lock file intentionally remains on disk. The kernel lock is released
/// automatically on crash, avoiding stale-file deletion races.
#[derive(Debug)]
pub struct WorkerLease {
    file: File,
}

impl WorkerLease {
    pub fn acquire(workspace: impl AsRef<Path>) -> io::Result<Self> {
        let runtime = worker_runtime_directory(workspace);
        fs::create_dir_all(&runtime)?;
        let path = runtime.join(LEASE_FILE);
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
                    format!("another impel-taskd worker holds {}", path.display()),
                )
            } else {
                error
            }
        })?;
        Ok(Self { file })
    }
}

impl Drop for WorkerLease {
    fn drop(&mut self) {
        let _ = unlock(&self.file);
    }
}

#[cfg(unix)]
fn try_lock_exclusive(file: &File) -> io::Result<()> {
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
fn unlock(file: &File) -> io::Result<()> {
    const LOCK_UN: i32 = 8;
    // SAFETY: `file` owns a valid descriptor for the duration of the call.
    let result = unsafe { flock(file.as_raw_fd(), LOCK_UN) };
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
    Err(io::Error::new(
        ErrorKind::Unsupported,
        "impel-taskd worker leases require a Unix host",
    ))
}

#[cfg(not(unix))]
fn unlock(_file: &File) -> io::Result<()> {
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn status_round_trips_atomically_and_reports_freshness() {
        let directory = tempfile::tempdir().unwrap();
        let mut status =
            WorkerStatusSnapshot::new("worker-a".into(), 42, 10_000, 5, "local-omlx".into());
        status.state = WorkerLifecycleState::Ready;
        status.completed_total = 3;
        write_worker_status(directory.path(), &status).unwrap();

        let decoded = read_worker_status(directory.path()).unwrap().unwrap();
        assert_eq!(decoded, status);
        assert!(decoded.is_fresh_at(29_999));
        assert!(!decoded.is_fresh_at(30_001));
    }

    #[test]
    fn lease_is_exclusive_and_released_on_drop() {
        let directory = tempfile::tempdir().unwrap();
        let first = WorkerLease::acquire(directory.path()).unwrap();
        let error = WorkerLease::acquire(directory.path()).unwrap_err();
        assert_eq!(error.kind(), ErrorKind::AlreadyExists);
        drop(first);
        WorkerLease::acquire(directory.path()).unwrap();
    }
}
