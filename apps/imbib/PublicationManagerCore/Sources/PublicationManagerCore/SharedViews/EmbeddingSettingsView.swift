//
//  EmbeddingSettingsView.swift
//  PublicationManagerCore
//
//  Settings view for embedding provider selection, indexing status, and controls.
//

import SwiftUI
import ImpressEmbeddings

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
        Form {
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

                LabeledContent("Papers Indexed") {
                    HStack(spacing: 6) {
                        Text("\(embeddingStatus.indexedPapers) of \(embeddingStatus.totalPapers)")
                            .foregroundStyle(.secondary)
                        if embeddingStatus.totalPapers > 0 {
                            let pct = Double(embeddingStatus.indexedPapers) / Double(embeddingStatus.totalPapers)
                            ProgressView(value: pct)
                                .frame(width: 60)
                        }
                    }
                }

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
                if embeddingStatus.indexedPapers < embeddingStatus.totalPapers {
                    Text("\(embeddingStatus.totalPapers - embeddingStatus.indexedPapers) papers have not been indexed yet.")
                } else if embeddingStatus.totalPapers > 0 {
                    Text("All papers are indexed.")
                }
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
                .disabled(isIndexing || embeddingStatus.indexedPapers >= embeddingStatus.totalPapers)

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
        .formStyle(.grouped)
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

        let vectorCount = await store.vectorCount()
        let chunkCount = await store.chunkCount()
        let chunkedPubs = await store.chunkedPublicationCount()
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

        let hasIndex = await EmbeddingService.shared.hasIndex
        let indexCount = hasIndex ? await EmbeddingService.shared.indexedCount() : 0

        // Query the active provider dynamically
        let registry = EmbeddingProviderRegistry.shared
        let providerId = await registry.activeProvider?.id
        let providerName = Self.displayName(for: providerId)
        let dimension = await registry.activeDimension

        embeddingStatus = EmbeddingStatusInfo(
            providerName: providerName,
            dimension: dimension,
            indexedPapers: max(Int(chunkedPubs), indexCount),
            totalPapers: totalPubs,
            vectorCount: Int(vectorCount),
            chunkCount: Int(chunkCount),
            modelStats: stats.map { EmbeddingModelStatInfo(model: $0.model, vectorCount: Int($0.vectorCount), dimension: Int($0.dimension)) }
        )
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
    var indexedPapers: Int = 0
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
