//
//  ImpressEmbeddings.swift
//  ImpressEmbeddings
//
//  Modular embedding system for the impress research suite.
//
//  Provides:
//  - Provider-agnostic embedding protocol (Apple NL, fastembed, Ollama, OpenAI)
//  - Provider registry with hot-swapping and dimension management
//  - PDF text extraction (PDFKit native)
//  - Overlapping text chunking with page-accurate metadata
//  - Document processing pipeline (PDF → chunks → embeddings)
//  - RAG context assembly with BibTeX-aware citation formatting
//
//  Architecture:
//  - Swift layer: provider selection, pipeline orchestration
//  - Rust layer (imbib-core): HNSW index, SQLite persistence, fastembed model
//  - Connected via UniFFI handle-based API
//
//  See docs/design-modular-embedding-system.md for full architecture.
//

// MARK: - Re-exports

// Providers
@_exported import struct Foundation.UUID

// Public API is exposed through the individual source files:
//
// Providers/
//   EmbeddingProvider.swift     — protocol + errors
//   EmbeddingProviderRegistry   — provider management
//
// Chunking/
//   TextChunker.swift           — text → overlapping chunks
//   PDFTextExtractor.swift      — PDF → page text
//   DocumentPipeline.swift      — end-to-end processing
//
// Retrieval/
//   RAGOrchestrator.swift       — query types, responses, context assembly
