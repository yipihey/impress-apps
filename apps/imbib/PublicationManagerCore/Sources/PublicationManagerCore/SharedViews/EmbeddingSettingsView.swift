//
//  EmbeddingSettingsView.swift
//  PublicationManagerCore
//
//  Settings view for embedding provider selection, indexing status, and controls.
//

import SwiftUI
import ImpressAI
import ImpressEmbeddings
import ImpressLogging
import OSLog

// MARK: - Embedding Settings View

/// Settings view for configuring the embedding system.
///
/// Allows users to:
/// - See current embedding provider and indexing status
/// - Trigger re-indexing of unprocessed papers
/// - View per-model statistics
public struct EmbeddingSettingsView: View {

    // MARK: - State

    @State private var embeddingStatus = EmbeddingStatusInfo()
    @State private var isLoadingStatus = false
    @State private var isIndexing = false
    @State private var indexingProgress: String = ""

    // MARK: - Body

    public init() {}

    public var body: some View {
        AISettingsView {
            // Status Section
            Section {
                LabeledContent("Provider") {
                    Text(embeddingStatus.providerName)
                        .foregroundStyle(.secondary)
                }

                LabeledContent("Dimension") {
                    Text("\(embeddingStatus.dimension)")
                        .foregroundStyle(.secondary)
                }

                // Two tiers, never collapsed into one number: every paper
                // gets a metadata vector when the index is built, while the
                // full-text tier needs a downloaded PDF to chunk. Reporting
                // only the second made a fully embedded library read as
                // unindexed.
                tierRow(
                    "Metadata Indexed",
                    indexed: embeddingStatus.indexedPapers,
                    total: embeddingStatus.totalPapers)
                tierRow(
                    "Full Text Indexed",
                    indexed: embeddingStatus.chunkedPapers,
                    total: embeddingStatus.totalPapers)

                LabeledContent("Chunks Stored") {
                    Text("\(embeddingStatus.chunkCount)")
                        .foregroundStyle(.secondary)
                }

                LabeledContent("Vectors Stored") {
                    Text("\(embeddingStatus.vectorCount)")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Embedding Index Status")
            } footer: {
                Text(statusFooter)
            }

            // Model Statistics
            if !embeddingStatus.modelStats.isEmpty {
                Section {
                    ForEach(embeddingStatus.modelStats, id: \.model) { stat in
                        LabeledContent(stat.model) {
                            Text("\(stat.vectorCount) vectors (\(stat.dimension)d)")
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Model Statistics")
                }
            }

            // Actions Section
            Section {
                Button {
                    Task { await indexUnprocessed() }
                } label: {
                    HStack {
                        if isIndexing {
                            ProgressView()
                                .controlSize(.small)
                            Text(indexingProgress.isEmpty ? "Indexing..." : indexingProgress)
                        } else {
                            Label("Index Unprocessed Papers", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                }
                // Gated on the full-text tier: that is the one this button
                // advances, and it is never complete while papers lack a PDF.
                .disabled(isIndexing || embeddingStatus.chunkedPapers >= embeddingStatus.totalPapers)

                Button("Re-index All Papers", role: .destructive) {
                    Task { await reindexAll() }
                }
                .disabled(isIndexing)
            } header: {
                Text("Actions")
            } footer: {
                Text("Re-indexing all papers will clear existing embeddings and rebuild the index from scratch.")
            }
        }
        .navigationTitle("Search & AI")
        .task {
            await loadStatus()
        }
    }

    // MARK: - Actions

    private func loadStatus() async {
        isLoadingStatus = true
        defer { isLoadingStatus = false }

        // Ensure the embedding provider is registered so we can query it
        await EmbeddingService.shared.registerProviderIfNeeded()

        let store = RustEmbeddingStoreSession()
        let opened = await store.openDefault()
        guard opened else { return }

        let status = await store.indexStatus()
        let stats = await store.modelStats()
        await store.close()

        // Count total publications across all non-special libraries
        let libraries = RustStoreAdapter.shared.listLibraries().filter { lib in
            let name = lib.name.lowercased()
            return name != "dismissed" && name != "exploration"
        }
        var totalPubs = 0
        for lib in libraries {
            totalPubs += RustStoreAdapter.shared.queryPublications(parentId: lib.id).count
        }

        // The in-memory ANN index is built lazily per app session, so it is
        // 0 on a fresh launch; the persisted vector count is the durable
        // answer and only wins when it is larger.
        let hasIndex = await EmbeddingService.shared.hasIndex
        let sessionIndexCount = hasIndex ? await EmbeddingService.shared.indexedCount() : 0

        // Query the active provider dynamically
        let registry = EmbeddingProviderRegistry.shared
        let providerId = await registry.activeProvider?.id
        let providerName = Self.displayName(for: providerId)
        let dimension = await registry.activeDimension

        embeddingStatus = EmbeddingStatusInfo(
            providerName: providerName,
            dimension: dimension,
            indexedPapers: max(Int(status?.indexedPublications ?? 0), sessionIndexCount),
            chunkedPapers: Int(status?.chunkedPublications ?? 0),
            totalPapers: totalPubs,
            vectorCount: Int(status?.vectorCount ?? 0),
            chunkCount: Int(status?.chunkCount ?? 0),
            modelStats: stats.map { EmbeddingModelStatInfo(model: $0.model, vectorCount: Int($0.vectorCount), dimension: Int($0.dimension)) }
        )
        Logger.embeddingService.infoCapture(
            "Display: embedding index — metadata \(embeddingStatus.indexedPapers)/\(totalPubs), full text \(embeddingStatus.chunkedPapers)/\(totalPubs), \(embeddingStatus.vectorCount) vectors",
            category: "embeddings"
        )
    }

    /// One tier's row: "73 of 2,987", or "All 2,987" once the tier covers the
    /// library. The count can exceed the total — the index also holds papers
    /// since moved to Dismissed, which the total deliberately excludes — and
    /// "3,040 of 2,987" reads as a bug rather than as completeness.
    @ViewBuilder
    private func tierRow(_ title: String, indexed: Int, total: Int) -> some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                Text(indexed >= total && total > 0 ? "All \(total)" : "\(indexed) of \(total)")
                    .foregroundStyle(.secondary)
                if total > 0 {
                    ProgressView(value: min(Double(indexed) / Double(total), 1.0))
                        .frame(width: 60)
                }
            }
        }
    }

    /// Says which tier is short, because "N papers not indexed" was read as a
    /// failed reindex when the metadata tier was in fact complete.
    private var statusFooter: String {
        guard embeddingStatus.totalPapers > 0 else { return "No papers to index yet." }
        var lines: [String] = []
        let metadataMissing = embeddingStatus.totalPapers - embeddingStatus.indexedPapers
        if metadataMissing > 0 {
            lines.append("\(metadataMissing) papers have no metadata embedding yet.")
        } else {
            lines.append("Every paper has a metadata embedding, so semantic search covers the whole library.")
        }
        let fullTextMissing = embeddingStatus.totalPapers - embeddingStatus.chunkedPapers
        if fullTextMissing > 0 {
            lines.append("Full-text indexing needs a downloaded PDF; \(fullTextMissing) papers have none stored, and indexing skips them.")
        }
        return lines.joined(separator: " ")
    }

    private func indexUnprocessed() async {
        isIndexing = true
        indexingProgress = "Building metadata index..."
        defer {
            isIndexing = false
            indexingProgress = ""
        }

        await EmbeddingService.shared.ensureIndexReady()

        indexingProgress = "Indexing PDF content..."
        await EmbeddingService.shared.indexChunksForUnprocessedPublications()

        await loadStatus()
    }

    private func reindexAll() async {
        isIndexing = true
        indexingProgress = "Clearing existing index..."
        defer {
            isIndexing = false
            indexingProgress = ""
        }

        let store = RustEmbeddingStoreSession()
        let opened = await store.openDefault()
        if opened {
            _ = await store.clearAll()
            await store.close()
        }

        indexingProgress = "Rebuilding metadata index..."
        await EmbeddingService.shared.forceRebuild()

        indexingProgress = "Indexing PDF content..."
        await EmbeddingService.shared.indexChunksForUnprocessedPublications()

        await loadStatus()
    }

    private static func displayName(for providerId: String?) -> String {
        switch providerId {
        case "apple-contextual": return "Apple Contextual Embeddings"
        case "apple-nl": return "Apple Natural Language"
        case "fastembed": return "FastEmbed (MiniLM)"
        case "ollama": return "Ollama"
        case "openai": return "OpenAI"
        case let id?: return id
        case nil: return "Not configured"
        }
    }
}

// MARK: - Supporting Types

struct EmbeddingStatusInfo {
    var providerName: String = "Not configured"
    var dimension: Int = 0
    /// Papers with a metadata (title/abstract) vector.
    var indexedPapers: Int = 0
    /// Papers with at least one full-text chunk from a stored PDF.
    var chunkedPapers: Int = 0
    var totalPapers: Int = 0
    var vectorCount: Int = 0
    var chunkCount: Int = 0
    var modelStats: [EmbeddingModelStatInfo] = []
}

struct EmbeddingModelStatInfo {
    let model: String
    let vectorCount: Int
    let dimension: Int
}

// MARK: - Embedding Status Toolbar Indicator

/// A small toolbar status indicator for embedding indexing state.
public struct EmbeddingStatusIndicator: View {
    @State private var indexedCount: Int = 0
    @State private var totalCount: Int = 0
    @State private var isBuilding: Bool = false

    public init() {}

    public var body: some View {
        Group {
            if isBuilding {
                ProgressView()
                    .controlSize(.small)
                    .help("Embedding index is building...")
            } else if totalCount > 0 && indexedCount < totalCount {
                Image(systemName: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.yellow)
                    .help("Embeddings: \(indexedCount)/\(totalCount) papers indexed")
            } else if totalCount > 0 {
                Image(systemName: "checkmark.circle")
                    .font(.caption2)
                    .foregroundStyle(.green)
                    .help("Embeddings: all \(totalCount) papers indexed")
            }
        }
        .task {
            await refreshStatus()
        }
    }

    private func refreshStatus() async {
        let hasIndex = await EmbeddingService.shared.hasIndex
        if hasIndex {
            indexedCount = await EmbeddingService.shared.indexedCount()
        }
        let libraries = RustStoreAdapter.shared.listLibraries().filter { lib in
            let name = lib.name.lowercased()
            return name != "dismissed" && name != "exploration"
        }
        var count = 0
        for lib in libraries {
            count += RustStoreAdapter.shared.queryPublications(parentId: lib.id).count
        }
        totalCount = count
    }
}
