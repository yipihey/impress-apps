//! Content-addressed blob storage for large manuscript bodies — a thin,
//! string-typed face over the workspace's ONE CAS, `impress_core::blobs`
//! (ADR-0030 D3).
//!
//! The layout (`<root>/<sha256 hex>`, atomic tmp+rename, immutable once
//! written) is exactly what this file implemented on its own before the
//! project work; section bodies, manuscript snapshots, project binaries and
//! build outputs now share the directory instead of each crate keeping a
//! sibling. This wrapper keeps the `&str`/`String` API the section and
//! throughline stores were written against and maps I/O failures to
//! `ServiceError::BlobIo`.
//!
//! - Bodies whose UTF-8 byte length is `> LARGE_BODY_THRESHOLD` are written
//!   content-addressed; the body field in SQLite is left empty and
//!   `content_hash` records the digest.
//! - Smaller bodies stay inline in SQLite.

use std::path::{Path, PathBuf};

use crate::error::ServiceError;

/// Sections whose body exceeds this size (in UTF-8 bytes) are stored
/// content-addressed; smaller bodies are inlined into the SQLite payload.
///
/// Mirrors the Swift constant `largeBodyThreshold` in `ImprintStoreAdapter`.
pub const LARGE_BODY_THRESHOLD: usize = 65_536; // 64 KiB

/// On-disk content-addressed blob store (text face over the shared CAS).
#[derive(Debug, Clone)]
pub struct BlobStore {
    inner: impress_core::blobs::BlobStore,
}

impl BlobStore {
    /// Construct a new blob store rooted at `root`.
    ///
    /// The directory is **not** created here; `put` and `ensure_dir` do that
    /// lazily so that read-only access doesn't have to perform mkdir.
    pub fn new<P: Into<PathBuf>>(root: P) -> Self {
        Self {
            inner: impress_core::blobs::BlobStore::new(root),
        }
    }

    /// The shared store itself, for callers that hold bytes rather than text.
    pub fn inner(&self) -> &impress_core::blobs::BlobStore {
        &self.inner
    }

    /// Path to the blob with the given hex SHA-256 digest.
    pub fn path_for(&self, hex_digest: &str) -> PathBuf {
        self.inner.path_for(hex_digest)
    }

    /// Path to the blob root directory.
    pub fn root(&self) -> &Path {
        self.inner.root()
    }

    /// Hex SHA-256 of a UTF-8 string. Matches the digest used by the Swift
    /// `sha256Hex` helper so the two implementations interoperate on the same
    /// blob directory.
    pub fn sha256_hex(body: &str) -> String {
        impress_core::blobs::sha256_hex_bytes(body.as_bytes())
    }

    /// Decide whether a body should be stored content-addressed.
    pub fn should_offload(body: &str) -> bool {
        body.len() > LARGE_BODY_THRESHOLD
    }

    /// Ensure the root directory exists. Idempotent.
    pub fn ensure_dir(&self) -> Result<(), ServiceError> {
        self.inner
            .ensure_dir()
            .map_err(|source| ServiceError::BlobIo {
                path: self.inner.root().to_path_buf(),
                source,
            })
    }

    /// Store `body` content-addressed; return its hex digest. A blob with the
    /// same digest is left in place — content-addressed storage is immutable.
    pub fn put(&self, body: &str) -> Result<String, ServiceError> {
        self.inner
            .put(body.as_bytes())
            .map_err(|source| ServiceError::BlobIo {
                path: self.inner.path_for(&Self::sha256_hex(body)),
                source,
            })
    }

    /// Read the blob with the given hex digest, if it exists.
    ///
    /// Returns `None` if no blob with that digest is present (callers treat a
    /// missing blob like a section with an empty body — we never panic just
    /// because content has been pruned).
    pub fn get(&self, hex_digest: &str) -> Result<Option<String>, ServiceError> {
        let path = self.path_for(hex_digest);
        match self.inner.get(hex_digest) {
            Ok(Some(bytes)) => {
                String::from_utf8(bytes)
                    .map(Some)
                    .map_err(|e| ServiceError::BlobIo {
                        path,
                        source: std::io::Error::new(std::io::ErrorKind::InvalidData, e),
                    })
            }
            Ok(None) => Ok(None),
            Err(source) => Err(ServiceError::BlobIo { path, source }),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
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

    #[test]
    fn the_shared_cas_sees_what_the_text_face_wrote() {
        let dir = TempDir::new().unwrap();
        let store = BlobStore::new(dir.path());
        let digest = store.put("shared").unwrap();
        assert_eq!(
            store.inner().get(&digest).unwrap().as_deref(),
            Some(&b"shared"[..])
        );
    }
}
