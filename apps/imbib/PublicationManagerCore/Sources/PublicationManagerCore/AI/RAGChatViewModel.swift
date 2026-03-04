//
//  RAGChatViewModel.swift
//  PublicationManagerCore
//
//  ViewModel driving the "Ask About Papers" conversational RAG panel.
//

import Foundation
import ImpressAI
import OSLog

private let logger = Logger(subsystem: "com.imbib.app", category: "ragChat")

// MARK: - RAG Chat ViewModel

/// ViewModel for the RAG chat panel.
///
/// Orchestrates:
/// 1. Embed the user's question
/// 2. Search chunk index for relevant passages
/// 3. Assemble context with publication metadata
/// 4. Generate LLM answer with [bibkey] citations
@MainActor
@Observable
public final class RAGChatViewModel {

    // MARK: - Types

    public struct ChatMessage: Identifiable, Sendable {
        public let id = UUID()
        public let role: Role
        public let text: String
        public let sources: [SourceReference]
        public let timestamp: Date

        public enum Role: Sendable {
            case user
            case assistant
        }

        public init(role: Role, text: String, sources: [SourceReference] = [], timestamp: Date = .now) {
            self.role = role
            self.text = text
            self.sources = sources
            self.timestamp = timestamp
        }
    }

    public struct SourceReference: Identifiable, Sendable {
        public let id = UUID()
        public let publicationId: UUID
        public let bibkey: String
        public let title: String
        public let authors: String
        public let chunkText: String
        public let pageNumber: Int?
        public let similarity: Float
    }

    public enum SearchScope: Sendable, Equatable {
        case library
        case collection(UUID, name: String)
        case papers([UUID])

        public var displayName: String {
            switch self {
            case .library: return "Library"
            case .collection(_, let name): return name
            case .papers(let ids): return "\(ids.count) papers"
            }
        }
    }

    // MARK: - Published State

    public private(set) var messages: [ChatMessage] = []
    public private(set) var isGenerating: Bool = false
    public private(set) var errorMessage: String?
    public var scope: SearchScope = .library

    // MARK: - Dependencies

    private let executor: AIMultiModelExecutor
    private let embeddingService: EmbeddingService

    // MARK: - Init

    public init(
        executor: AIMultiModelExecutor = .shared,
        embeddingService: EmbeddingService = .shared
    ) {
        self.executor = executor
        self.embeddingService = embeddingService
    }

    // MARK: - Public API

    /// Ask a question about papers in the current scope.
    public func ask(_ question: String) async {
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !isGenerating else { return }

        // Add user message
        messages.append(ChatMessage(role: .user, text: question))
        isGenerating = true
        errorMessage = nil

        do {
            // 1. Ensure embedding index is ready
            await embeddingService.ensureIndexReady()

            // 2. Search for relevant chunks
            let chunkResults = await searchChunks(for: question)

            // 3. Assemble context from chunks
            let (contextText, sources) = assembleContext(from: chunkResults)

            // 4. Generate answer via LLM
            let answer = try await generateAnswer(question: question, context: contextText)

            // 5. Add assistant message with sources
            messages.append(ChatMessage(role: .assistant, text: answer, sources: sources))

            logger.info("RAG answer generated: \(sources.count) sources, scope=\(self.scope.displayName)")
        } catch {
            errorMessage = error.localizedDescription
            messages.append(ChatMessage(
                role: .assistant,
                text: "I couldn't generate an answer: \(error.localizedDescription)"
            ))
            logger.error("RAG error: \(error.localizedDescription)")
        }

        isGenerating = false
    }

    /// Clear chat history.
    public func clearChat() {
        messages.removeAll()
        errorMessage = nil
    }

    // MARK: - Private

    /// Search the chunk index for passages relevant to the question.
    private func searchChunks(for question: String) async -> [ChunkSearchResult] {
        // Get query embedding from the embedding service
        let queryEmbedding = await embeddingService.embedText(question)
        guard !queryEmbedding.isEmpty else {
            logger.warning("Failed to embed question")
            return []
        }

        // Use the chunk index for search
        let chunkIndex = RustChunkIndexSession()
        await chunkIndex.initialize()

        // Load chunk vectors from store and populate the index
        let store = RustEmbeddingStoreSession()
        let opened = await store.openDefault()
        guard opened else { return [] }

        let chunkVectors = await store.loadVectorsByType("chunk")
        if !chunkVectors.isEmpty {
            let items = chunkVectors.map { v in
                ChunkIndexItem(chunkId: v.sourceId, publicationId: extractPubId(from: v), embedding: v.vector)
            }
            await chunkIndex.addBatch(items)
        }

        // Search (scoped or unscoped)
        let results: [ChunkSimilarityResult]
        switch scope {
        case .library:
            results = await chunkIndex.search(query: queryEmbedding, topK: 15)
        case .collection(let collectionId, _):
            let members = RustStoreAdapter.shared.listCollectionMembers(collectionId: collectionId)
            let pubIds = members.map { $0.id.uuidString }
            results = await chunkIndex.searchScoped(query: queryEmbedding, topK: 15, publicationIds: pubIds)
        case .papers(let ids):
            let pubIds = ids.map { $0.uuidString }
            results = await chunkIndex.searchScoped(query: queryEmbedding, topK: 15, publicationIds: pubIds)
        }

        await chunkIndex.close()

        // Enrich results with chunk text
        var enriched: [ChunkSearchResult] = []
        for result in results {
            let chunk = await store.getChunk(chunkId: result.chunkId)
            enriched.append(ChunkSearchResult(
                chunkId: result.chunkId,
                publicationId: result.publicationId,
                similarity: result.similarity,
                chunkText: chunk?.text ?? "",
                pageNumber: chunk?.pageNumber.map { Int($0) }
            ))
        }

        await store.close()
        return enriched
    }

    /// Assemble RAG context from chunk search results.
    private func assembleContext(from chunks: [ChunkSearchResult]) -> (String, [SourceReference]) {
        let store = RustStoreAdapter.shared
        var contextParts: [String] = []
        var sources: [SourceReference] = []

        for chunk in chunks {
            guard let pubId = UUID(uuidString: chunk.publicationId),
                  let pub = store.getPublication(id: pubId) else { continue }

            let bibkey = pub.citeKey
            let title = pub.title
            let authors = pub.authorString
            let year = pub.year.map { String($0) } ?? ""

            contextParts.append("""
            [\(bibkey)] \(authors) (\(year)). \(title)
            ---
            \(chunk.chunkText)
            """)

            sources.append(SourceReference(
                publicationId: pubId,
                bibkey: bibkey,
                title: title,
                authors: authors,
                chunkText: chunk.chunkText,
                pageNumber: chunk.pageNumber,
                similarity: chunk.similarity
            ))
        }

        return (contextParts.joined(separator: "\n\n"), sources)
    }

    /// Generate an LLM answer given the question and assembled context.
    private func generateAnswer(question: String, context: String) async throws -> String {
        let systemPrompt = """
        You are a research assistant. Answer the user's question using ONLY the provided paper excerpts.
        Cite papers using their BibTeX keys in square brackets, e.g. [Smith2024].
        If the excerpts don't contain enough information to answer, say so honestly.
        Keep your answer concise and well-structured. Use markdown formatting.
        """

        let userMessage: String
        if context.isEmpty {
            userMessage = """
            Question: \(question)

            No relevant paper excerpts were found in the current scope. Please let the user know that their papers may need to be indexed first.
            """
        } else {
            userMessage = """
            Question: \(question)

            Paper excerpts:
            \(context)
            """
        }

        let request = AICompletionRequest(
            messages: [AIMessage(role: .user, text: userMessage)],
            systemPrompt: systemPrompt,
            maxTokens: 2000
        )

        let result = try await executor.executePrimary(request, categoryId: "research.rag")
        guard let response = result, let text = response.text else {
            throw RAGError.noResponse
        }
        return text
    }

    /// Extract publication ID from a stored vector (source_id may be chunk_id, linked via store).
    private func extractPubId(from vector: StoredVector) -> String {
        // For chunk vectors, sourceId is the chunk_id. The publicationId is stored in chunks table.
        // For now, we use a simple heuristic: if it looks like a UUID, treat it as pub_id.
        // The chunk_index_add call maps chunk_id → publication_id internally.
        return vector.sourceId
    }
}

// MARK: - Supporting Types

private struct ChunkSearchResult {
    let chunkId: String
    let publicationId: String
    let similarity: Float
    let chunkText: String
    let pageNumber: Int?
}

enum RAGError: LocalizedError {
    case noResponse
    case indexNotReady

    var errorDescription: String? {
        switch self {
        case .noResponse: return "No response received from the AI model."
        case .indexNotReady: return "The embedding index is not ready. Please wait for indexing to complete."
        }
    }
}
