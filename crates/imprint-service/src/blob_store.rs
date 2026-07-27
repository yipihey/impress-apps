//! Content-addressed blob storage for large manuscript bodies.
//!
//! Ports the inline-vs-CAS decision made by the Swift `ImprintStoreAdapter`
//! (file `apps/imprint/Packages/ImprintCore/Sources/ImprintCore/ImprintStoreAdapter.swift`):
//!
//! - Bodies whose UTF-8 byte length is `> LARGE_BODY_THRESHOLD` are written to a
//!   file named after their SHA-256 hex digest under `<root>/`. The body field
//!   in SQLite is left empty and `content_hash` records the digest.
//! - Smaller bodies stay inline in SQLite.
//!
//! Writes are atomic: we write to `<hash>.tmp.<pid>.<nonce>` and `rename` into
//! place. Existing blobs with the same digest are not overwritten — they are by
//! definition immutable.

use std::fs::{self, File};
use std::io::Write as _;
use std::path::{Path, PathBuf};

use sha2::{Digest, Sha256};

use crate::error::ServiceError;

/// Sections whose body exceeds this size (in UTF-8 bytes) are stored
/// content-addressed; smaller bodies are inlined into the SQLite payload.
///
/// Mirrors the Swift constant `largeBodyThreshold` in `ImprintStoreAdapter`.
pub const LARGE_BODY_THRESHOLD: usize = 65_536; // 64 KiB

/// On-disk content-addressed blob store.
///
/// `root` is a directory; blob files live directly inside it, named by their
/// hex-encoded SHA-256 digest. The directory is created lazily on first write.
#[derive(Debug, Clone)]
pub struct BlobStore {
    root: PathBuf,
}

impl BlobStore {
    /// Construct a new blob store rooted at `root`.
    ///
    /// The directory is **not** created here; `put` and `ensure_dir` do that
    /// lazily so that read-only access doesn't have to perform mkdir.
    pub fn new<P: Into<PathBuf>>(root: P) -> Self {
        Self { root: root.into() }
    }

    /// Path to the blob with the given hex SHA-256 digest.
    pub fn path_for(&self, hex_digest: &str) -> PathBuf {
        self.root.join(hex_digest)
    }

    /// Path to the blob root directory.
    pub fn root(&self) -> &Path {
        &self.root
    }

    /// Hex SHA-256 of a UTF-8 string. Matches the digest used by the Swift
    /// `sha256Hex` helper so the two implementations interoperate on the same
    /// blob directory.
    pub fn sha256_hex(body: &str) -> String {
        let mut hasher = Sha256::new();
        hasher.update(body.as_bytes());
        let digest = hasher.finalize();
        hex::encode(digest)
    }

    /// Decide whether a body should be stored content-addressed.
    pub fn should_offload(body: &str) -> bool {
        body.len() > LARGE_BODY_THRESHOLD
    }

    /// Ensure the root directory exists. Idempotent.
    pub fn ensure_dir(&self) -> Result<(), ServiceError> {
        fs::create_dir_all(&self.root).map_err(|source| ServiceError::BlobIo {
            path: self.root.clone(),
            source,
        })
    }

    /// Store `body` content-addressed; return its hex digest.
    ///
    /// If a blob with the same digest already exists on disk it is left in
    /// place (content-addressed storage is immutable). Otherwise the body is
    /// written atomically via a temp file + rename.
    pub fn put(&self, body: &str) -> Result<String, ServiceError> {
        self.ensure_dir()?;
        let hex_digest = Self::sha256_hex(body);
        let final_path = self.path_for(&hex_digest);

        if final_path.exists() {
            return Ok(hex_digest);
        }

        // Use a temp file in the same directory so the rename is atomic
        // (POSIX `rename(2)` requires both paths to be on the same filesystem).
        let tmp_path = self
            .root
            .join(format!("{}.tmp.{}", hex_digest, std::process::id()));
        {
            let mut f = File::create(&tmp_path).map_err(|source| ServiceError::BlobIo {
                path: tmp_path.clone(),
                source,
            })?;
            f.write_all(body.as_bytes())
                .map_err(|source| ServiceError::BlobIo {
                    path: tmp_path.clone(),
                    source,
                })?;
            f.sync_all().map_err(|source| ServiceError::BlobIo {
                path: tmp_path.clone(),
                source,
            })?;
        }

        fs::rename(&tmp_path, &final_path).map_err(|source| ServiceError::BlobIo {
            path: final_path,
            source,
        })?;
        Ok(hex_digest)
    }

    /// Read the blob with the given hex digest, if it exists.
    ///
    /// Returns `None` if no blob with that digest is present (callers treat a
    /// missing blob like a section with an empty body — we never panic just
    /// because content has been pruned).
    pub fn get(&self, hex_digest: &str) -> Result<Option<String>, ServiceError> {
        let path = self.path_for(hex_digest);
        match fs::read_to_string(&path) {
            Ok(s) => Ok(Some(s)),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(source) => Err(ServiceError::BlobIo { path, source }),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    #[test]
    fn sha256_matches_known_digest() {
        // SHA-256 of "hello" is 2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824
        assert_eq!(
            BlobStore::sha256_hex("hello"),
            "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        );
    }

    #[test]
    fn should_offload_threshold() {
        let small = "x".repeat(LARGE_BODY_THRESHOLD);
        let big = "x".repeat(LARGE_BODY_THRESHOLD + 1);
        assert!(!BlobStore::should_offload(&small));
        assert!(BlobStore::should_offload(&big));
    }

    #[test]
    fn put_and_get_roundtrip() {
        let dir = TempDir::new().unwrap();
        let store = BlobStore::new(dir.path());
        let body = "= Heading\n\nSome content.";

        let digest = store.put(body).unwrap();
        assert_eq!(digest.len(), 64); // hex SHA-256
        assert!(store.path_for(&digest).exists());

        let got = store.get(&digest).unwrap();
        assert_eq!(got.as_deref(), Some(body));
    }

    #[test]
    fn put_is_idempotent() {
        let dir = TempDir::new().unwrap();
        let store = BlobStore::new(dir.path());
        let body = "repeat me";
        let d1 = store.put(body).unwrap();
        let d2 = store.put(body).unwrap();
        assert_eq!(d1, d2);

        // Mutating the file then re-putting should not overwrite (CAS is
        // immutable; same digest = same content guaranteed by SHA-256).
        let path = store.path_for(&d1);
        let original_meta = fs::metadata(&path).unwrap();
        let _ = store.put(body).unwrap();
        let after_meta = fs::metadata(&path).unwrap();
        assert_eq!(
            original_meta.modified().unwrap(),
            after_meta.modified().unwrap(),
            "second put should be a no-op"
        );
    }

    #[test]
    fn get_missing_returns_none() {
        let dir = TempDir::new().unwrap();
        let store = BlobStore::new(dir.path());
        let got = store.get("0".repeat(64).as_str()).unwrap();
        assert!(got.is_none());
    }
}
