# Modular Embedding System for Impress

## Context

The AnythingLLM analysis (§8 of the SciSciGPT comparison) concluded that **Option C — native RAG pipeline** is the right path. imbib already has ~60% of the infrastructure (EmbeddingService, RustAnnIndex, ImpressAI providers, fastembed in Rust) but lacks the chunking pipeline, neural embeddings from external providers, embedding persistence, and RAG retrieval. This design creates a modular, fast embedding system that fills those gaps and describes everything it enables.

---

## 1. Architecture Overview

```
┌──────────────────────────────────────────────────────────────────┐
│                    ImpressEmbeddings (new shared package)         │
│                                                                  │
│  ┌─────────────┐  ┌──────────────┐  ┌─────────────────────────┐ │
│  │ EmbeddingKit │  │  ChunkKit    │  │  RetrievalKit           │ │
│  │ (providers)  │  │  (pipeline)  │  │  (RAG query)            │ │
│  └──────┬──────┘  └──────┬───────┘  └──────────┬──────────────┘ │
│         │                │                      │                │
│  ┌──────▼──────────────────────────────────────▼──────────────┐ │
│  │              EmbeddingStore (persistence)                   │ │
│  └─────────────────────────┬──────────────────────────────────┘ │
└────────────────────────────┼────────────────────────────────────┘
                             │
              ┌──────────────▼──────────────┐
              │  imbib-core (Rust)           │
              │  • AnnIndex (HNSW)           │
              │  • SemanticSearch (fastembed) │
              │  • EmbeddingStore (SQLite)   │
              │  • ChunkStore (SQLite)       │
              └─────────────────────────────┘
```

**Key principle**: Embedding generation (Swift, provider-agnostic) is separated from embedding storage and search (Rust, fast). The Rust layer owns persistence and ANN search. The Swift layer owns provider selection and pipeline orchestration.

---

## 2. Module Structure

### 2.1 New Package: `packages/ImpressEmbeddings/`

A new shared Swift package that any impress app can depend on. Contains:

```
ImpressEmbeddings/
├── Sources/ImpressEmbeddings/
│   ├── Providers/
│   │   ├── EmbeddingProviderRegistry.swift    # Provider selection & config
│   │   ├── AppleNLProvider.swift              # Reuse existing from ImpressAI
│   │   ├── OllamaEmbeddingProvider.swift      # NEW: Ollama nomic-embed-text
│   │   ├── OpenAIEmbeddingProvider.swift       # NEW: text-embedding-3-small
│   │   ├── FastEmbedProvider.swift            # NEW: Bridge to Rust fastembed
│   │   └── ProviderBenchmark.swift            # Speed/quality comparison tool
│   ├── Chunking/
│   │   ├── TextChunker.swift                  # Overlapping token-based chunking
│   │   ├── PDFTextExtractor.swift             # PDFKit full-text extraction
│   │   ├── ChunkMetadata.swift                # Source location, page number, etc.
│   │   └── DocumentPipeline.swift             # PDF → text → chunks → embeddings
│   ├── Store/
│   │   ├── EmbeddingStoreProtocol.swift       # Abstract storage interface
│   │   └── RustEmbeddingStore.swift           # Bridge to Rust SQLite store
│   ├── Retrieval/
│   │   ├── RAGOrchestrator.swift              # Query → retrieve → assemble → generate
│   │   ├── ContextAssembler.swift             # Chunk selection + metadata enrichment
│   │   └── CitationFormatter.swift            # BibTeX-aware citation in responses
│   └── ImpressEmbeddings.swift                # Public API surface
```

### 2.2 Rust Extensions: `crates/imbib-core/src/search/`

Extend the existing Rust search module:

```
search/
├── ann_index.rs          # EXISTING — extend with namespace support
├── semantic.rs           # EXISTING — expose fastembed to Swift via UniFFI
├── embedding_store.rs    # NEW — SQLite persistence for embeddings + chunks
├── chunk_index.rs        # NEW — Separate HNSW index for chunk-level search
└── mod.rs                # Update exports
```

### 2.3 Existing Files to Modify

| File | Change |
|------|--------|
| `packages/ImpressAI/.../SemanticEmbeddingProvider.swift` | Extract `EmbeddingProvider` protocol → move to `ImpressEmbeddings` (re-export from ImpressAI for backwards compat) |
| `apps/imbib/.../EmbeddingService.swift` | Delegate to `ImpressEmbeddings` providers instead of inline NL/hash code |
| `crates/imbib-core/Cargo.toml` | Add `rusqlite` dependency for embedding store |
| `crates/imbib-core/src/search/semantic.rs` | Expose `SemanticSearch` to Swift via UniFFI handle API |
| `packages/impress-mcp/src/imbib/tools.ts` | Add `imbib_ask_papers` and `imbib_embed_status` tools |

---

## 3. Provider Abstraction

### 3.1 The `EmbeddingProvider` Protocol (exists, enhance)

```swift
// Already in ImpressAI, move to ImpressEmbeddings
public protocol EmbeddingProvider: Sendable {
    var id: String { get }                              // NEW: "apple-nl", "ollama", "openai", "fastembed"
    var embeddingDimension: Int { get }
    var supportsLocal: Bool { get }                     // NEW: no network required
    var estimatedMsPerEmbedding: Double { get }         // NEW: for pipeline planning
    func embed(_ text: String) async throws -> [Float]  // CHANGED: throws
    func embedBatch(_ texts: [String]) async throws -> [[Float]]
}
```

### 3.2 Providers

| Provider | Dimension | Local? | Speed | Quality | When to use |
|----------|-----------|--------|-------|---------|-------------|
| **AppleNL** (exists) | 384 | Yes | ~2ms | Moderate | Default, offline, fast startup |
| **FastEmbed** (Rust, exists unused) | 384 | Yes | ~5ms | Good | Better quality, 100MB model download |
| **Ollama** (new) | 768 | Yes | ~20ms | Very good | User has Ollama running, best local quality |
| **OpenAI** (new) | 1536/3072 | No | ~50ms | Excellent | User has API key, willing to pay for quality |

### 3.3 Provider Registry

```swift
public actor EmbeddingProviderRegistry {
    public static let shared = EmbeddingProviderRegistry()

    /// Active provider, respects user settings
    public var activeProvider: any EmbeddingProvider { get }

    /// Change provider (triggers re-embedding if dimension changes)
    public func setActiveProvider(_ id: String) async throws

    /// All registered providers with availability status
    public func availableProviders() -> [(id: String, available: Bool, reason: String?)]
}
```

**Configuration**: Stored in `UserDefaults` via `ImpressEmbeddings.Settings`:
- `embeddingProvider`: String (default: `"apple-nl"`)
- `embeddingDimension`: Int (read-only, derived from provider)
- `autoUpgradeEmbeddings`: Bool (re-embed when switching providers)

### 3.4 Dimension Handling

Different providers produce different dimensions. The system handles this:
- **HNSW index is dimension-locked** — all vectors in one index must share dimension
- **Provider changes trigger re-indexing** — the `DocumentPipeline` re-embeds all content
- **Store records model name + dimension** — enables graceful migration
- **Separate indexes per namespace** — paper-level (384) and chunk-level (varies) can differ

---

## 4. Storage Layer

### 4.1 Rust `EmbeddingStore` (new)

SQLite-backed persistence in `crates/imbib-core/src/search/embedding_store.rs`:

```rust
/// Stored embedding with metadata
#[derive(uniffi::Record)]
pub struct StoredVector {
    pub id: String,           // UUID
    pub source_id: String,    // publication_id or chunk_id
    pub source_type: String,  // "publication" or "chunk"
    pub vector: Vec<f32>,
    pub model: String,        // "apple-nl-384", "fastembed-384", "openai-1536"
    pub created_at: String,   // ISO8601
}

/// Chunk with text and location
#[derive(uniffi::Record)]
pub struct StoredChunk {
    pub id: String,
    pub publication_id: String,
    pub text: String,
    pub page_number: Option<u32>,
    pub char_offset: u32,
    pub char_length: u32,
    pub chunk_index: u32,     // position within document
}

// UniFFI exports
pub fn embedding_store_open(path: String) -> u64;
pub fn embedding_store_save_vectors(handle: u64, vectors: Vec<StoredVector>) -> bool;
pub fn embedding_store_get_vectors(handle: u64, source_id: String) -> Vec<StoredVector>;
pub fn embedding_store_save_chunks(handle: u64, chunks: Vec<StoredChunk>) -> bool;
pub fn embedding_store_get_chunks(handle: u64, publication_id: String) -> Vec<StoredChunk>;
pub fn embedding_store_delete_by_source(handle: u64, source_id: String) -> u32;
pub fn embedding_store_count(handle: u64) -> u32;
pub fn embedding_store_model_stats(handle: u64) -> Vec<ModelStats>;  // count per model
pub fn embedding_store_close(handle: u64) -> bool;
```

**Location**: `~/Library/Application Support/imbib/embeddings.sqlite`

**Why SQLite, not the existing Core Data store**: Embeddings are large binary blobs that change independently of publication metadata. Keeping them separate avoids bloating CloudKit sync, allows independent migration, and lets the Rust layer own the data directly.

### 4.2 Startup Flow (replaces ADR-022's "rebuild every launch")

```
App launch
  → Open embedding_store.sqlite
  → Load stored vectors into HNSW index  ← NEW: O(n) insert, no recomputation
  → If model mismatch (user changed provider): queue background re-embed
  → If new publications since last embed: queue incremental embed
  → Index ready in <1s for typical library (vs 2-5s before)
```

This preserves ADR-022's "local rebuild" philosophy but caches the expensive part (embedding computation). The HNSW graph is still rebuilt each launch (hnsw_rs limitation), but from stored vectors rather than recomputing embeddings.

---

## 5. Chunking Pipeline

### 5.1 `PDFTextExtractor`

```swift
public struct PDFTextExtractor {
    /// Extract full text from a PDF, preserving page boundaries.
    public static func extract(from url: URL) -> [(page: Int, text: String)]

    /// Extract text from a specific page range.
    public static func extract(from url: URL, pages: Range<Int>) -> [(page: Int, text: String)]
}
```

Uses `PDFKit` (macOS native, already a dependency). Falls back to Rust `pdfium-render` for stubborn PDFs.

### 5.2 `TextChunker`

```swift
public struct TextChunker {
    public struct Config {
        public var chunkSize: Int = 512        // tokens
        public var overlap: Int = 64           // tokens overlap between chunks
        public var respectParagraphs: Bool = true  // break at paragraph boundaries
    }

    /// Split text into overlapping chunks with metadata.
    public static func chunk(
        text: String,
        publicationId: UUID,
        pageNumber: Int?,
        config: Config = .init()
    ) -> [ChunkWithMetadata]
}

public struct ChunkWithMetadata {
    public let text: String
    public let publicationId: UUID
    public let pageNumber: Int?
    public let charOffset: Int
    public let charLength: Int
    public let chunkIndex: Int
}
```

### 5.3 `DocumentPipeline`

End-to-end: publication → PDF → text → chunks → embeddings → store + index.

```swift
public actor DocumentPipeline {
    public static let shared = DocumentPipeline()

    /// Process a single publication's PDF.
    public func process(_ publicationId: UUID, pdfURL: URL) async throws -> Int  // returns chunk count

    /// Process all unprocessed publications in a library.
    public func processLibrary(_ libraryId: UUID, progress: @escaping (Int, Int) -> Void) async throws

    /// Check processing status.
    public func status(for publicationId: UUID) -> ProcessingStatus

    public enum ProcessingStatus {
        case unprocessed
        case processing
        case complete(chunkCount: Int, model: String)
        case failed(Error)
    }
}
```

**Pipeline stages** (each can be parallelized):
1. **Extract**: `PDFTextExtractor.extract(from: pdfURL)` → `[(page, text)]`
2. **Chunk**: `TextChunker.chunk(text:)` → `[ChunkWithMetadata]`
3. **Embed**: `provider.embedBatch(chunks.map(\.text))` → `[[Float]]`
4. **Store**: `embeddingStore.saveChunks()` + `embeddingStore.saveVectors()`
5. **Index**: `chunkAnnIndex.addBatch()`

**Performance**: Process 10 papers (~200 pages) in background: ~30s with AppleNL, ~60s with fastembed, ~15s with OpenAI (network-bound).

---

## 6. Query Pipeline (RAG)

### 6.1 `RAGOrchestrator`

```swift
public actor RAGOrchestrator {
    /// Ask a question about papers in the library.
    ///
    /// - Parameters:
    ///   - question: Natural language question
    ///   - scope: Which papers to search (all, collection, specific IDs)
    ///   - maxChunks: Maximum context chunks to include
    /// - Returns: Generated answer with citations
    public func ask(
        _ question: String,
        scope: SearchScope = .library,
        maxChunks: Int = 10
    ) async throws -> RAGResponse

    public enum SearchScope {
        case library                          // all indexed papers
        case collection(UUID)                 // specific collection
        case papers([UUID])                   // specific paper IDs
    }
}
```

### 6.2 RAG Query Flow

```
User question: "What methods do these papers use for dark energy constraints?"
    │
    ├─ 1. Embed question → [Float]
    │     (using active EmbeddingProvider)
    │
    ├─ 2. ANN search → top-k chunks
    │     (chunkAnnIndex.search(), filtered by scope)
    │
    ├─ 3. Assemble context
    │     For each chunk:
    │       • Retrieve chunk text from EmbeddingStore
    │       • Look up publication metadata (title, authors, year, bibkey)
    │       • Format as: "[AuthorYear] Title\n---\n{chunk text}\n"
    │
    ├─ 4. Generate answer
    │     System prompt:
    │       "You are a research assistant. Answer using ONLY the provided excerpts.
    │        Cite papers using their BibTeX keys: [key]. If unsure, say so."
    │     User message: question + assembled context
    │     (via ImpressAI provider)
    │
    └─ 5. Return RAGResponse
          • answer: String (markdown with [bibkey] citations)
          • sources: [(publicationId, bibkey, chunkText, pageNumber, similarity)]
          • tokensUsed: Int
```

### 6.3 `RAGResponse`

```swift
public struct RAGResponse {
    public let answer: String                    // Markdown with [bibkey] citations
    public let sources: [SourceReference]        // Cited chunks with metadata
    public let question: String
    public let model: String                     // LLM used for generation
    public let embeddingModel: String            // Embedding model used
    public let retrievalTimeMs: Int
    public let generationTimeMs: Int
}

public struct SourceReference {
    public let publicationId: UUID
    public let bibkey: String
    public let title: String
    public let authors: String
    public let year: String?
    public let chunkText: String
    public let pageNumber: Int?
    public let similarity: Float
}
```

---

## 7. What This Enables

### 7.1 Immediate Capabilities (Phase 1)

| Capability | Description | Uses |
|------------|-------------|------|
| **Faster startup** | Load cached embeddings instead of recomputing | EmbeddingStore |
| **Better semantic search** | Neural embeddings via fastembed/Ollama replace word-averaging | Provider registry |
| **Provider choice** | User picks quality/speed/privacy tradeoff | Settings UI |
| **PDF full-text search** | Search inside papers, not just metadata | PDFTextExtractor + ChunkIndex |

### 7.2 RAG Capabilities (Phase 2)

| Capability | Description | Uses |
|------------|-------------|------|
| **Ask about papers** | "What methods do these papers use?" → cited answer | RAGOrchestrator |
| **Literature synthesis** | "Compare the approaches in my cosmology collection" | Multi-doc RAG with synthesis prompt |
| **Paper summarization** | Deep summaries from full text, not just abstract | Chunk retrieval + LLM |
| **Research gap identification** | "What questions remain unanswered?" | RAG with analytical prompt |
| **Concept explanation** | "Explain the CMB analysis in Smith2024" | Scoped RAG to single paper |

### 7.3 Cross-Paper Intelligence (Phase 3)

| Capability | Description | Uses |
|------------|-------------|------|
| **Concept mapping** | Automatic topic clusters from chunk embeddings | Chunk index clustering |
| **Citation context** | "How does PaperA cite PaperB?" → extract citing sentence | Chunk search + citation matching |
| **Paper comparison** | Side-by-side methodology/results comparison | Multi-doc RAG |
| **Recommendation upgrade** | `librarySimilarity` uses neural embeddings | EmbeddingService delegates to provider |
| **Reading order suggestion** | "Read these 20 papers in what order?" | Dependency graph from citation + similarity |
| **Annotation-aware search** | Search across user highlights and notes | Chunk annotations as additional source |

### 7.4 Cross-App Integration (Phase 4)

| Capability | App | Description |
|------------|-----|-------------|
| **Cite while writing** | imprint | "Find a paper supporting this claim" → RAG search → insert citation |
| **Figure-to-paper** | implore | "Which paper has a similar figure?" → multimodal embedding match |
| **Agent-driven research** | impel | `imbib_ask_papers` MCP tool for autonomous literature review |
| **Email-to-knowledge** | impart | Extract claims from email → verify against library |
| **Manuscript-bibliography coherence** | imprint ↔ imbib | Embed manuscript sections → find uncited relevant papers |

### 7.5 Agent Integration (MCP / HTTP)

New MCP tools exposed via `impress-mcp`:

```typescript
// imbib_ask_papers — RAG Q&A over paper corpus
{
  name: "imbib_ask_papers",
  input: { question: string, scope?: "library" | "collection:uuid" | "papers:uuid,uuid", maxChunks?: number },
  output: { answer: string, sources: SourceReference[], timing: { retrievalMs, generationMs } }
}

// imbib_embed_status — Check embedding pipeline status
{
  name: "imbib_embed_status",
  output: { provider: string, indexedPapers: number, indexedChunks: number, pendingPapers: number }
}

// imbib_find_similar_chunks — Low-level chunk similarity search
{
  name: "imbib_find_similar_chunks",
  input: { query: string, topK?: number, scope?: string },
  output: { chunks: { text, publicationId, bibkey, page, similarity }[] }
}
```

HTTP endpoints on port 23120:

```
GET  /api/embeddings/status          → { provider, counts, health }
POST /api/embeddings/ask             → { question, scope } → RAGResponse
POST /api/embeddings/search          → { query, topK } → chunk results
POST /api/embeddings/process         → { publicationId } → trigger processing
```

---

## 8. Migration Path

### Phase 1: Foundation (this PR)
1. Create `packages/ImpressEmbeddings/` with provider protocol + registry
2. Move `EmbeddingProvider` from ImpressAI → ImpressEmbeddings (re-export for compat)
3. Add Rust `embedding_store.rs` with SQLite persistence
4. Expose Rust `SemanticSearch` (fastembed) via UniFFI
5. Update `EmbeddingService` to use provider registry + store cached vectors
6. **Zero breaking changes** — existing consumers see no difference

### Phase 2: Chunking + RAG
1. Add `PDFTextExtractor`, `TextChunker`, `DocumentPipeline`
2. Add Rust `chunk_index.rs` (separate HNSW for chunks)
3. Add `RAGOrchestrator` with context assembly + citation formatting
4. Add MCP tools (`imbib_ask_papers`, `imbib_embed_status`)
5. Add "Ask about papers" UI panel in imbib

### Phase 3: External Providers + Cross-App
1. Add `OllamaEmbeddingProvider`, `OpenAIEmbeddingProvider`
2. Add embedding settings UI (provider picker, re-index button, status)
3. Wire imprint citation search through RAG
4. Wire impel agent access

---

## 9. Performance Targets

| Operation | Target | Method |
|-----------|--------|--------|
| Startup (cached embeddings) | <1s for 1000 papers | SQLite load → HNSW insert |
| Embed single publication | <5ms (AppleNL), <10ms (fastembed) | Provider-dependent |
| Embed batch (100 papers) | <500ms (AppleNL), <2s (fastembed) | Parallel batch API |
| PDF text extraction | <200ms per paper | PDFKit native |
| Chunk 1 paper (20 pages) | <50ms | Token-based splitting |
| Full pipeline (1 paper) | <2s (local), <5s (API) | Extract+chunk+embed+store |
| ANN search (10K chunks) | <5ms | HNSW O(log n) |
| RAG query end-to-end | <3s | Embed + search + LLM generation |
| Full library reindex (1000 papers) | <5 min background | Batched, non-blocking |

---

## 10. Critical Files

### To Create
- `packages/ImpressEmbeddings/` — new Swift package
- `crates/imbib-core/src/search/embedding_store.rs` — SQLite persistence
- `crates/imbib-core/src/search/chunk_index.rs` — chunk-level HNSW

### To Modify
- `packages/ImpressAI/Sources/ImpressAI/Embeddings/SemanticEmbeddingProvider.swift` — move protocol out
- `apps/imbib/PublicationManagerCore/Sources/PublicationManagerCore/Recommendation/EmbeddingService.swift` — delegate to registry
- `crates/imbib-core/src/search/mod.rs` — export new modules
- `crates/imbib-core/src/search/semantic.rs` — expose via UniFFI handle API
- `crates/imbib-core/Cargo.toml` — add `rusqlite`
- `packages/impress-mcp/src/imbib/tools.ts` — add RAG tools

### Existing Code to Reuse
- `EmbeddingProvider` protocol (`packages/ImpressAI/.../SemanticEmbeddingProvider.swift`)
- `AppleNLEmbeddingProvider` (`packages/ImpressAI/.../SemanticEmbeddingProvider.swift`)
- `AnnIndex` + UniFFI handle API (`crates/imbib-core/src/search/ann_index.rs`)
- `SemanticSearch` with fastembed (`crates/imbib-core/src/search/semantic.rs`)
- `StoredEmbedding` record (`crates/imbib-core/src/search/semantic.rs:205`)
- `AISearchAssistant` query expansion + summarization (`apps/imbib/.../AISearchAssistant.swift`)
- `AIMultiModelExecutor` for LLM generation (`packages/ImpressAI/.../AIMultiModelExecutor.swift`)
- `RustAnnIndexSession` Swift bridge (`apps/imbib/.../RustBridge/Search/RustAnnIndexSession.swift`)

---

## 11. Verification

### Unit Tests
- Provider registry: register, select, switch, fallback
- TextChunker: correct overlap, respects boundaries, handles empty/tiny texts
- EmbeddingStore: save/load roundtrip, model migration, deletion
- RAGOrchestrator: context assembly with correct citations

### Integration Tests
- Full pipeline: PDF → chunks → embed → store → search → retrieve
- Provider switch: change provider, verify re-indexing, verify search still works
- Startup: close app → reopen → verify index loaded from cache (not recomputed)

### Manual Verification
1. Build imbib, open library with PDFs
2. Trigger `DocumentPipeline.processLibrary()` — watch logs for chunk counts
3. Use Cmd+K semantic search — verify results include chunk-level matches
4. Use MCP tool: `imbib_ask_papers({ question: "What methods...", scope: "library" })`
5. Check HTTP: `curl http://localhost:23120/api/embeddings/status`
6. Switch provider in Settings → verify background re-indexing starts
7. Kill app → relaunch → verify <1s to index ready (cached)
