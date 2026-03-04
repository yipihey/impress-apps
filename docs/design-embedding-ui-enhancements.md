# Embedding-Powered UI Enhancements for imbib

## Overview

Six UI enhancements built on top of the modular embedding system (ImpressEmbeddings + Rust storage layer). Each exposes embedding capabilities to researchers through natural interaction patterns.

---

## E1: "Ask About Papers" — Conversational RAG Panel

**Impact: Highest** — entirely new capability.

A chat-style sidebar (320pt, right side) where researchers ask natural language questions and get cited answers with [bibkey] references.

### Architecture
```
User question → EmbeddingService.embedText() → ChunkIndex.search()
  → Assemble context with pub metadata → LLM generation → [bibkey] citations
```

### Key Files
- `RAGChatViewModel.swift` — orchestrates embed → search → assemble → generate pipeline
- `RAGChatPanel.swift` — sidebar UI with chat bubbles, scope selector, source cards
- Scope support: Library, Collection(UUID), or Papers([UUID])

### UX
- Trigger: Cmd+Shift+A or toolbar button
- Source cards below each answer show cited passages with page numbers
- Suggested starter questions in empty state
- Clickable [bibkey] references navigate to the paper

---

## E2: Chunk-Level Semantic Search in Cmd+K

**Impact: Very High** — upgrades the most-used search surface.

The GlobalSearchViewModel now runs three parallel searches: FTS + semantic + **chunk-level**. Chunk results appear as "Passage" match type badges with snippet previews showing the matching text and page number.

### Architecture
```
Cmd+K query → parallel:
  1. FTS (Tantivy)
  2. Semantic (publication embedding)
  3. Chunk (EmbeddingStore → ChunkIndex → text snippets)  ← NEW
```

### Key Files
- `GlobalSearchViewModel.swift` — added `performChunkSearch()` and `ChunkPassageResult`
- `GlobalSearchTypes.swift` — added `.passage` match type with "Passage" label and `text.page` icon

### Scoring
- FTS results: base 100 + score + field boosts
- Chunk/passage results: similarity × 50 (ranks between semantic-only and FTS)
- Snippet falls back to chunk text when no FTS snippet available

---

## E3: Neural "Find Similar" in InfoTab

**Impact: High** — upgrades existing button with content-based similarity.

Added `EmbeddingService.findSimilarByContent(to:)` which computes a centroid from all chunk embeddings of a paper, then searches the publication-level ANN index. Falls back to metadata-based similarity for unindexed papers.

### Key Files
- `EmbeddingService.swift` — new `findSimilarByContent(to:topK:)` method
- Also added `embedText(_:)` (public wrapper for `computeTextEmbedding`) and `forceRebuild()`

---

## E4: Embedding Settings & Status

**Impact: High** — infrastructure visibility and user control.

New "Search & AI" settings tab showing:
- Current provider and dimension
- Papers indexed (with progress bar)
- Chunks and vectors stored
- Per-model statistics
- "Index Unprocessed" and "Re-index All" actions

Plus `EmbeddingStatusIndicator` — a small toolbar widget showing indexing state.

### Key Files
- `EmbeddingSettingsView.swift` — Form-based settings view
- `SettingsView.swift` — added `.searchAI` tab with "brain" icon under Content section

---

## E5: Paper Comparison View

**Impact: Medium-High** — unique scholarly capability.

Select 2-4 papers → structured comparison generated via LLM with:
- Overview, Methodology, Key Findings, Agreements, Differences, Summary
- Each claim cites [bibkey]
- Enriched with chunk content from embedding store when available

### Key Files
- `PaperComparisonViewModel.swift` — drives comparison via scoped LLM generation
- `PaperComparisonView.swift` — sheet view with paper list + markdown comparison

---

## E6: Smart Collection Summaries

**Impact: Medium** — passive intelligence.

`CollectionSummaryService` generates 2-3 sentence summaries for collections describing themes, methods, and time span. Cached in memory, invalidated when papers change.

### Key Files
- `CollectionSummaryService.swift` — singleton actor with cache + generation

---

## Shared Infrastructure Added

### Rust-Swift Bridge Sessions
- `RustChunkIndexSession.swift` — actor wrapping chunk_index UniFFI exports
- `RustEmbeddingStoreSession.swift` — actor wrapping embedding_store UniFFI exports

Both follow the established `RustAnnIndexSession` pattern: handle-based, actor-isolated, with proper deinit cleanup.

---

## Implementation Order

1. **E4** (Settings) — visibility into the system
2. **E3** (Find Similar) — upgrade existing button
3. **E2** (Cmd+K chunks) — upgrade existing search
4. **E1** (RAG Panel) — flagship new feature
5. **E5** (Comparison) — new structured analysis
6. **E6** (Summaries) — passive intelligence
