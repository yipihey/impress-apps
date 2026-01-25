# Rust Migration Phase 5: Cleanup, UniFFI Integration, WASM & Fast ANN Search

You are implementing Phase 5 of the Rust core expansion for imbib. Phases 1-4 (domain models, source plugins, search/PDF, tests) should already be complete. This phase focuses on:

1. Deleting duplicate Swift code that duplicates Rust functionality
2. Completing UniFFI integration so Swift uses Rust implementations
3. Fixing any remaining Rust test failures
4. Migrating URL query builders and response parsing for WASM support
5. Adding fast approximate nearest neighbor (ANN) search with hnsw_rs
6. Preparing the codebase for a future web app that shares the Rust core

## Project Context

**imbib** is a cross-platform (macOS/iOS) scientific publication manager. The goal is to maximize code sharing for a future web app by moving all platform-agnostic logic to Rust.

**Current State:**
- Rust core (`imbib-core/`) has: BibTeX, RIS, deduplication, identifiers, text processing, search, PDF, annotations, merge, export, domain models, automation
- Swift has duplicate implementations that should be deleted
- UniFFI bindings exist but may not cover all modules
- Semantic search exists (`search/semantic.rs`) but uses O(n) brute-force similarity

**Target State (Post Phase 5):**
- No duplicate Swift code for functionality in Rust
- All Rust modules properly exposed via UniFFI
- All Rust tests passing
- URL query builders and response parsing in Rust (WASM-ready)
- Fast O(log n) similarity search with HNSW index
- Clear separation: Rust = business logic, Swift = UI + platform services

---

## Part 1: Cleanup & UniFFI Integration

### Phase 5.1: Fix Rust Test Failures

**Goal**: Ensure all Rust tests pass before making changes.

```bash
cd imbib-core && cargo test --all-features 2>&1 | head -100
```

If tests fail, identify and fix issues. Common problems:
- UniFFI symbol collisions (duplicate function exports)
- Snapshot tests needing initial generation (`cargo insta test --accept`)
- API mismatches (`add_field` vs `set_field`)

**Checkpoint:** All tests pass.

---

### Phase 5.2: Audit UniFFI Exports

**Goal**: Ensure all Rust modules are properly exposed to Swift.

Review `imbib-core/src/lib.rs`. The lib.rs should have `#[uniffi::export]` on all public functions and `uniffi::setup_scaffolding!()` at the end.

**Check for symbol collisions:**
Look for functions defined in multiple modules. Remove duplicates.

**Regenerate UniFFI bindings:**
```bash
cargo build --features native
cargo run --bin uniffi-bindgen generate --library target/debug/libimbib_core.dylib --language swift --out-dir generated/
```

**Checkpoint:** UniFFI bindings generate without errors.

---

### Phase 5.3: Identify Duplicate Swift Code

**Goal**: Find Swift code that duplicates Rust functionality.

```bash
grep -r "BibTeXParser\|RISParser\|DeduplicationService\|IdentifierExtractor" PublicationManagerCore/Sources/ --include="*.swift" -l
```

**Expected duplicates:**

| Swift File | Rust Replacement |
|------------|------------------|
| `BibTeXParser.swift` | `imbib_core::bibtex::parse` |
| `RISParser.swift` | `imbib_core::ris::parse` |
| `RISExporter.swift` | `imbib_core::ris::format_entry` |
| `DeduplicationService.swift` (core logic) | `imbib_core::deduplication` |
| `IdentifierExtractor.swift` | `imbib_core::identifiers` |
| `CiteKeyGenerator.swift` | `imbib_core::identifiers::generate_cite_key` |

---

### Phase 5.4: Create Swift Bridge Layer

**Goal**: Create thin Swift wrappers that call Rust via UniFFI.

Create `PublicationManagerCore/Sources/PublicationManagerCore/RustBridge/` with:

- `BibTeXBridge.swift` - BibTeX parsing/formatting
- `RISBridge.swift` - RIS parsing/export/conversion
- `DeduplicationBridge.swift` - Duplicate detection
- `IdentifierBridge.swift` - DOI/arXiv/ISBN extraction

Each bridge should be a simple `enum` with static methods that call the Rust functions.

---

### Phase 5.5: Update Swift Code to Use Bridges

Replace direct Swift implementations with bridge calls throughout the codebase.

---

### Phase 5.6: Delete Duplicate Swift Files

After verifying no remaining usages, delete the old Swift implementations.

**Keep files that have platform-specific code** (URLSession, Core Data, etc.).

---

### Phase 5.7-5.9: URL Builders & Response Parsing

**Goal**: Move API URL construction and response parsing to Rust for WASM support.

Create `imbib-core/src/sources/` with query builders and response parsers for:
- arXiv (XML)
- Crossref (JSON)
- ADS (JSON)
- PubMed (XML)
- Semantic Scholar (JSON)
- OpenAlex (JSON)
- DBLP (JSON)

Update Swift source plugins to use Rust for URL building and response parsing, keeping only URLSession for HTTP requests.

---

### Phase 5.10: Add WASM Feature Flag

Update `imbib-core/Cargo.toml`:

```toml
[features]
default = ["native"]
native = ["uniffi", "tokio", "pdfium-render"]
wasm = ["wasm-bindgen", "wasm-bindgen-futures", "js-sys", "web-sys"]
embeddings = ["fastembed"]

[target.'cfg(target_arch = "wasm32")'.dependencies]
wasm-bindgen = { version = "0.2", optional = true }
wasm-bindgen-futures = { version = "0.4", optional = true }
js-sys = { version = "0.3", optional = true }
web-sys = { version = "0.3", features = ["console"], optional = true }
```

Add conditional compilation in `lib.rs`:
```rust
#[cfg(feature = "native")]
uniffi::setup_scaffolding!();
```

Test WASM build:
```bash
cargo build --target wasm32-unknown-unknown --features wasm --no-default-features
```

---

## Part 2: Fast ANN Search Enhancement

### Phase 5.12: Add hnsw_rs Dependency

**Goal**: Add approximate nearest neighbor search for O(log n) similarity.

Update `Cargo.toml`:
```toml
[dependencies]
hnsw_rs = { version = "0.3", optional = true }

[features]
native = ["uniffi", "hnsw_rs"]
embeddings = ["fastembed", "hnsw_rs"]
```

---

### Phase 5.13: Create ANN Index Module

**Goal**: Implement HNSW-based similarity search.

Create `imbib-core/src/search/ann_index.rs`:

```rust
//! Approximate Nearest Neighbor index using HNSW
//!
//! Provides O(log n) similarity search for embeddings.

use hnsw_rs::prelude::*;
use serde::{Deserialize, Serialize};

/// HNSW index for fast similarity search
pub struct AnnIndex {
    hnsw: Hnsw<f32, DistCosine>,
    id_map: Vec<String>,  // index -> publication_id
}

impl AnnIndex {
    /// Create a new empty index
    pub fn new() -> Self {
        let hnsw = Hnsw::new(
            16,     // max_nb_connection (M parameter)
            10000,  // capacity
            16,     // max_layer
            200,    // ef_construction
            DistCosine,
        );
        Self {
            hnsw,
            id_map: Vec::new(),
        }
    }

    /// Add an embedding to the index
    pub fn add(&mut self, publication_id: &str, embedding: &[f32]) {
        let idx = self.id_map.len();
        self.id_map.push(publication_id.to_string());
        self.hnsw.insert((&embedding.to_vec(), idx));
    }

    /// Add multiple embeddings at once (more efficient)
    pub fn add_batch(&mut self, items: Vec<(String, Vec<f32>)>) {
        let start_idx = self.id_map.len();
        let mut data = Vec::new();
        for (i, (id, emb)) in items.iter().enumerate() {
            self.id_map.push(id.clone());
            data.push((emb.clone(), start_idx + i));
        }
        self.hnsw.parallel_insert(&data);
    }

    /// Find k most similar publications
    pub fn search(&self, query: &[f32], k: usize) -> Vec<SimilarityResult> {
        let ef_search = k * 2;  // Search beam width
        let results = self.hnsw.search(&query.to_vec(), k, ef_search);

        results.into_iter()
            .map(|neighbour| SimilarityResult {
                publication_id: self.id_map[neighbour.d_id].clone(),
                similarity: 1.0 - neighbour.distance,  // Convert distance to similarity
            })
            .collect()
    }

    /// Serialize index to bytes
    pub fn save(&self) -> Result<Vec<u8>, String> {
        bincode::serialize(&(&self.hnsw, &self.id_map))
            .map_err(|e| e.to_string())
    }

    /// Load index from bytes
    pub fn load(data: &[u8]) -> Result<Self, String> {
        let (hnsw, id_map): (Hnsw<f32, DistCosine>, Vec<String>) =
            bincode::deserialize(data)
                .map_err(|e| e.to_string())?;
        Ok(Self { hnsw, id_map })
    }
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct SimilarityResult {
    pub publication_id: String,
    pub similarity: f32,
}
```

Update `search/mod.rs`:
```rust
#[cfg(feature = "native")]
pub mod ann_index;

#[cfg(feature = "native")]
pub use ann_index::*;
```

---

### Phase 5.14: Add UniFFI Exports for ANN

Add to `lib.rs`:

```rust
#[cfg(feature = "native")]
pub use search::ann_index::{AnnIndex, SimilarityResult};

/// Find most similar publications using ANN index (fast, O(log n))
#[cfg(feature = "native")]
#[uniffi::export]
pub fn find_similar_fast(
    index: &AnnIndex,
    query_embedding: Vec<f32>,
    top_k: u32,
) -> Vec<SimilarityResult> {
    index.search(&query_embedding, top_k as usize)
}

/// Build an ANN index from embeddings
#[cfg(feature = "native")]
#[uniffi::export]
pub fn build_ann_index(
    embeddings: Vec<PublicationEmbedding>,
) -> AnnIndex {
    let mut index = AnnIndex::new();
    for emb in embeddings {
        index.add(&emb.publication_id, &emb.vector);
    }
    index
}
```

---

### Phase 5.15: Create Swift Bridge for ANN

Create `RustBridge/RustAnnIndex.swift`:

```swift
import Foundation
import imbib_core

/// Swift wrapper for Rust ANN index
public actor RustAnnIndex {
    private var index: AnnIndex?

    public init() {}

    /// Build index from publication embeddings
    public func build(from embeddings: [PublicationEmbedding]) async {
        index = buildAnnIndex(embeddings)
    }

    /// Find similar publications (O(log n))
    public func findSimilar(to embedding: [Float], topK: Int = 10) async -> [SimilarityResult] {
        guard let index = index else { return [] }
        return findSimilarFast(index: index, queryEmbedding: embedding, topK: UInt32(topK))
    }

    /// Save index to disk
    public func save(to url: URL) async throws {
        guard let index = index else { return }
        let data = try index.save()
        try data.write(to: url)
    }

    /// Load index from disk
    public func load(from url: URL) async throws {
        let data = try Data(contentsOf: url)
        index = try AnnIndex.load(data)
    }
}
```

---

### Phase 5.16: Integrate with Recommendation Engine

Add new feature type to `RecommendationTypes.swift`:
```swift
case librarySimilarity  // Semantic similarity to library centroid
```

Add to `FeatureExtractor.swift`:
```swift
features[.librarySimilarity] = await librarySimilarityScore(publication, index: annIndex)

public static func librarySimilarityScore(
    _ publication: CDPublication,
    index: RustAnnIndex
) async -> Double {
    guard let embedding = await getEmbedding(for: publication) else {
        return 0.0
    }

    // Find top 5 similar papers in library
    let similar = await index.findSimilar(to: embedding, topK: 5)

    // Average similarity to top matches
    guard !similar.isEmpty else { return 0.0 }
    let avgSim = similar.map { Double($0.similarity) }.reduce(0, +) / Double(similar.count)

    return avgSim
}
```

---

## Phase 5.11: Final Verification

**Goal**: Ensure everything works end-to-end.

```bash
# Rust tests
cd imbib-core && cargo test --all-features

# Swift build
cd .. && xcodebuild -scheme PublicationManagerCore -destination 'platform=macOS' build

# Full app build
xcodebuild -scheme imbib -destination 'platform=macOS' build
```

Run app and verify:
1. BibTeX import works
2. RIS import/export works
3. Duplicate detection works
4. Search all sources works
5. "Find similar papers" is fast with large library

---

## Verification Checklist

- [ ] `cargo test --all-features` passes
- [ ] `cargo build --features wasm --target wasm32-unknown-unknown` builds
- [ ] Swift package builds without duplicate implementations
- [ ] macOS app builds and runs
- [ ] iOS app builds and runs
- [ ] BibTeX parsing uses Rust
- [ ] RIS parsing/export uses Rust
- [ ] Deduplication uses Rust
- [ ] Identifier extraction uses Rust
- [ ] All source plugins use Rust query builders
- [ ] All source plugins use Rust response parsers
- [ ] ANN search works and is fast (< 10ms for 1000+ embeddings)
- [ ] `librarySimilarity` feature shows in recommendation score breakdown

---

## File Changes Summary

| File | Action |
|------|--------|
| `Cargo.toml` | Add `hnsw_rs`, update features |
| `search/mod.rs` | Add `pub mod ann_index;` |
| `search/ann_index.rs` | **New**: ANN index implementation |
| `lib.rs` | Export ANN functions |
| `RustBridge/RustAnnIndex.swift` | **New**: Swift wrapper |
| `FeatureExtractor.swift` | Add `librarySimilarity` feature |
| `RecommendationTypes.swift` | Add `librarySimilarity` to `FeatureType` |

---

## Summary

This phase completes the Rust migration by:

1. Ensuring all Rust tests pass
2. Creating proper Swift bridge layers
3. Deleting duplicate Swift implementations
4. Moving URL query builders to Rust (WASM-ready)
5. Moving response parsing to Rust (WASM-ready)
6. Adding WASM feature flag for future web app
7. Adding fast O(log n) ANN search with hnsw_rs
8. Integrating ANN search with the recommendation engine

After this phase, the codebase will have:
- **Rust**: All business logic (parsing, deduplication, search, identifiers, URL building, response parsing, fast similarity search)
- **Swift**: UI (SwiftUI), persistence (Core Data), sync (CloudKit), platform services (Keychain, FileManager)
- **Future WASM**: Same Rust core with JavaScript/TypeScript UI
