//
//  CollectionSummaryService.swift
//  PublicationManagerCore
//
//  Generates and caches AI summaries for paper collections.
//

import Foundation
import ImpressAI
import OSLog

private let logger = Logger(subsystem: "com.imbib.app", category: "collectionSummary")

// MARK: - Collection Summary Service

/// Generates and caches AI-powered summaries for paper collections.
///
/// Each collection gets a short summary describing key themes, methods,
/// and chronological scope. Summaries are cached and recomputed when
/// papers are added or removed.
@MainActor
@Observable
public final class CollectionSummaryService {

    // MARK: - Singleton

    public static let shared = CollectionSummaryService()

    // MARK: - Types

    public struct CollectionSummary: Sendable {
        public let collectionId: UUID
        public let summary: String
        public let paperCount: Int
        public let generatedAt: Date
    }

    // MARK: - State

    private var cache: [UUID: CollectionSummary] = [:]
    private var generatingFor: Set<UUID> = []

    // MARK: - Dependencies

    private let executor: AIMultiModelExecutor

    public init(executor: AIMultiModelExecutor = .shared) {
        self.executor = executor
    }

    // MARK: - Public API

    /// Get a cached summary for a collection, or nil if not yet generated.
    public func summary(for collectionId: UUID) -> CollectionSummary? {
        cache[collectionId]
    }

    /// Whether a summary is currently being generated for this collection.
    public func isGenerating(for collectionId: UUID) -> Bool {
        generatingFor.contains(collectionId)
    }

    /// Generate or refresh a summary for a collection.
    public func generateSummary(for collectionId: UUID) async {
        guard !generatingFor.contains(collectionId) else { return }
        generatingFor.insert(collectionId)
        defer { generatingFor.remove(collectionId) }

        let store = RustStoreAdapter.shared
        let members = store.listCollectionMembers(collectionId: collectionId)

        guard !members.isEmpty else {
            cache[collectionId] = CollectionSummary(
                collectionId: collectionId,
                summary: "Empty collection.",
                paperCount: 0,
                generatedAt: .now
            )
            return
        }

        // Build context from member papers
        var paperDescriptions: [String] = []
        for member in members.prefix(30) {
            if let pub = store.getPublicationDetail(id: member.id) {
                var desc = "\(pub.citeKey): \(pub.title)"
                if let abstract = pub.abstract, !abstract.isEmpty {
                    desc += " — \(String(abstract.prefix(200)))"
                }
                if let year = pub.year { desc += " (\(year))" }
                paperDescriptions.append(desc)
            }
        }

        guard !paperDescriptions.isEmpty else { return }

        do {
            let summaryText = try await generateSummaryText(
                paperCount: members.count,
                descriptions: paperDescriptions
            )

            cache[collectionId] = CollectionSummary(
                collectionId: collectionId,
                summary: summaryText,
                paperCount: members.count,
                generatedAt: .now
            )

            logger.info("Generated summary for collection \(collectionId.uuidString): \(members.count) papers")
        } catch {
            logger.error("Failed to generate collection summary: \(error.localizedDescription)")
        }
    }

    /// Invalidate cached summary for a collection (call when papers change).
    public func invalidate(collectionId: UUID) {
        cache.removeValue(forKey: collectionId)
    }

    /// Invalidate all cached summaries.
    public func invalidateAll() {
        cache.removeAll()
    }

    // MARK: - Private

    private func generateSummaryText(paperCount: Int, descriptions: [String]) async throws -> String {
        let systemPrompt = """
        You are a research librarian. Given a list of papers in a collection, write a 2-3 sentence summary describing:
        1. The main themes or research areas covered
        2. The methodological approaches (if apparent)
        3. The time span of the work

        Be concise and informative. Do not list papers — synthesize. Write in present tense.
        """

        let userMessage = """
        Summarize this collection of \(paperCount) papers:

        \(descriptions.joined(separator: "\n"))
        """

        let request = AICompletionRequest(
            messages: [AIMessage(role: .user, text: userMessage)],
            systemPrompt: systemPrompt,
            maxTokens: 300
        )

        let result = try await executor.executePrimary(request, categoryId: "research.summarize")
        guard let response = result, let text = response.text else {
            throw RAGError.noResponse
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
