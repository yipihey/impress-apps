//! The workspace's ONE content-addressed blob store (ADR-0030 D3).
//!
//! Layout: `<root>/<sha256 hex>` — a flat directory of immutable files named
//! by their digest, which is exactly what `imprint-service::blob_store` wrote
//! for large section bodies under `<workspace>/content`. Moving the type here
//! lets manuscript snapshots (`manuscript_ops`' `blob:sha256:` refs), section
//! bodies, project binaries (`manuscript-file.blob_ref`) and build outputs
//! share one directory instead of each crate inventing a sibling.
//!
//! Writes are atomic (tmp + rename in the same directory) and idempotent — a
//! digest that already exists is never rewritten, because by definition the
//! bytes are the same.

use std::fs::{self, File};
use std::io::{self, Write as _};
use std::path::{Path, PathBuf};

use sha2::{Digest, Sha256};

/// The prefix a payload uses to point at a blob: `blob:sha256:<hex>`.
pub const BLOB_REF_PREFIX: &str = "blob:sha256:";

/// The directory name under the workspace root.
pub const BLOB_DIR_NAME: &str = "content";

/// Hex SHA-256 of `bytes`.
pub fn sha256_hex_bytes(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    hasher
        .finalize()
        .iter()
        .map(|b| format!("{:02x}", b))
        .collect()
}

/// `blob:sha256:<hex>` for a digest.
pub fn blob_ref(hex_digest: &str) -> String {
    format!("{BLOB_REF_PREFIX}{hex_digest}")
}

/// The digest inside a `blob:sha256:<hex>` ref, if `s` is one.
pub fn parse_blob_ref(s: &str) -> Option<&str> {
    s.strip_prefix(BLOB_REF_PREFIX)
        .filter(|h| !h.is_empty() && h.chars().all(|c| c.is_ascii_hexdigit()))
}

#[derive(Debug, Clone)]
pub struct BlobStore {
    root: PathBuf,
}

impl BlobStore {
    /// A store rooted at `root`. Nothing is created until the first write.
    pub fn new<P: Into<PathBuf>>(root: P) -> Self {
        Self { root: root.into() }
    }

    /// The conventional store for a workspace: `<workspace>/content`.
    pub fn for_workspace(workspace_root: &Path) -> Self {
        Self::new(workspace_root.join(BLOB_DIR_NAME))
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    pub fn path_for(&self, hex_digest: &str) -> PathBuf {
        self.root.join(hex_digest)
    }

    pub fn ensure_dir(&self) -> io::Result<()> {
        fs::create_dir_all(&self.root)
    }

    /// Store `bytes`; returns the hex digest. Existing blobs are left alone.
    pub fn put(&self, bytes: &[u8]) -> io::Result<String> {
        self.ensure_dir()?;
        let digest = sha256_hex_bytes(bytes);
        let final_path = self.path_for(&digest);
        if final_path.exists() {
            return Ok(digest);
        }
        let tmp = self
            .root
            .join(format!("{}.tmp.{}.{}", digest, std::process::id(), nonce()));
        {
            let mut f = File::create(&tmp)?;
            f.write_all(bytes)?;
            f.sync_all()?;
        }
        match fs::rename(&tmp, &final_path) {
            Ok(()) => Ok(digest),
            Err(e) => {
                let _ = fs::remove_file(&tmp);
                // A concurrent writer may have landed the same digest first —
                // that is success, not a failure.
                if final_path.exists() {
                    Ok(digest)
                } else {
                    Err(e)
                }
            }
        }
    }

    /// The bytes for a digest, or `None` when the blob is absent (pruned, or
    /// written on another device and not yet synced).
    pub fn get(&self, hex_digest: &str) -> io::Result<Option<Vec<u8>>> {
        match fs::read(self.path_for(hex_digest)) {
            Ok(bytes) => Ok(Some(bytes)),
            Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(e),
        }
    }

    /// `get` for a `blob:sha256:` ref.
    pub fn get_ref(&self, blob_ref: &str) -> io::Result<Option<Vec<u8>>> {
        match parse_blob_ref(blob_ref) {
            Some(digest) => self.get(digest),
            None => Ok(None),
        }
    }

    pub fn contains(&self, hex_digest: &str) -> bool {
        self.path_for(hex_digest).exists()
    }
}

fn nonce() -> u64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos() as u64)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn put_is_content_addressed_and_idempotent() {
        let dir = tempfile::tempdir().unwrap();
        let store = BlobStore::new(dir.path().join("content"));
        let a = store.put(b"hello").unwrap();
        let b = store.put(b"hello").unwrap();
        assert_eq!(a, b);
        assert_eq!(a, sha256_hex_bytes(b"hello"));
        assert_eq!(store.get(&a).unwrap().as_deref(), Some(&b"hello"[..]));
        assert_eq!(
            store.get_ref(&blob_ref(&a)).unwrap().as_deref(),
            Some(&b"hello"[..])
        );
        assert_eq!(store.get("00").unwrap(), None);
        assert_eq!(
            fs::read_dir(store.root()).unwrap().count(),
            1,
            "no temp files left"
        );
    }

    #[test]
    fn refs_parse_strictly() {
        assert_eq!(parse_blob_ref("blob:sha256:abc123"), Some("abc123"));
        assert_eq!(parse_blob_ref("blob:sha256:"), None);
        assert_eq!(parse_blob_ref("blob:sha256:not hex"), None);
        assert_eq!(parse_blob_ref("abc123"), None);
    }
}
