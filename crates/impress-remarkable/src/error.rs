use std::fmt;

pub type Result<T> = std::result::Result<T, Error>;

/// Failures a caller has to tell the researcher apart: an unreachable tablet
/// is a different problem from a wrong password, and both are different from
/// a key that changed underneath us.
#[derive(Debug, thiserror::Error)]
pub enum Error {
    /// Nothing answered, or the address is wrong. Usually the tablet asleep.
    #[error("{host} did not answer on port {port}: {detail}")]
    Unreachable {
        host: String,
        port: u16,
        detail: String,
    },
    /// The tablet answered but rejected the password.
    #[error("{host} rejected the password for user {username}")]
    Authentication { host: String, username: String },
    /// The host key differs from the one that was pinned.
    #[error("the host key for {host} changed (expected {expected}, saw {actual}) — refusing to send the password")]
    HostKeyChanged {
        host: String,
        expected: String,
        actual: String,
    },
    /// SSH transport or SFTP failure once authenticated.
    #[error("{operation} failed on {host}: {detail}")]
    Transport {
        host: String,
        operation: String,
        detail: String,
    },
    /// The tablet is reachable but does not look like a reMarkable.
    #[error("{host} does not look like a reMarkable: {detail}")]
    NotARemarkable { host: String, detail: String },
    /// A document id that is not on the tablet.
    #[error("no document {id} on {host}")]
    DocumentNotFound { host: String, id: String },
    /// Local filesystem failure while writing a download.
    #[error("could not write {path}: {detail}")]
    Io { path: String, detail: String },
    /// An upload was accepted but the tablet filed it somewhere else than
    /// the folder that was listed just before — the caller must not record
    /// the id under the wrong parent.
    #[error("{host} filed document {id} under {actual_parent:?} instead of {expected_parent:?}")]
    Misplaced {
        host: String,
        id: String,
        expected_parent: String,
        actual_parent: String,
    },
    /// The tablet answered nothing within the time the caller allowed.
    #[error("{operation} on {host} timed out")]
    Timeout { host: String, operation: String },
    /// A `.rmdoc` archive that is not a zip, or lacks the files it needs.
    #[error("not a reMarkable archive: {detail}")]
    Archive { detail: String },
    /// A stroke or metadata file whose bytes do not follow the format.
    #[error("{path}: {detail}")]
    Format { path: String, detail: String },
}

impl Error {
    pub(crate) fn transport(host: &str, operation: &str, detail: impl fmt::Display) -> Self {
        Self::Transport {
            host: host.to_string(),
            operation: operation.to_string(),
            detail: detail.to_string(),
        }
    }
}
