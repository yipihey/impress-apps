//
//  PaperComparisonViewModel.swift
//  PublicationManagerCore
//
//  ViewModel for structured paper comparison using RAG.
//

import Foundation
import ImpressAI
import OSLog

private let logger = Logger(subsystem: "com.imbib.app", category: "paperComparison")

// MARK: - Paper Comparison ViewModel

/// Generates structured comparisons between 2-4 papers using RAG.
@MainActor
@Observable
public final class PaperComparisonViewModel {

    // MARK: - Types

    public struct ComparisonResult: Sendable {
        public let papers: [PaperInfo]
        public let comparison: String
        public let timestamp: Date
    }

    public struct PaperInfo: Identifiable, Sendable {
        public let id: UUID
        public let bibkey: String
        public let title: String
        public let authors: String
        public let year: String?
    }

    // MARK: - State

    public private(set) var result: ComparisonResult?
    public private(set) var isComparing: Bool = false
    public private(set) var errorMessage: String?

    // MARK: - Dependencies

    private let executor: AIMultiModelExecutor

    public init(executor: AIMultiModelExecutor = .shared) {
        self.executor = executor
    }

    // MARK: - Public API

    /// Compare 2-4 papers, generating a structured analysis.
    public func compare(publicationIDs: [UUID]) async {
        guard publicationIDs.count >= 2, publicationIDs.count <= 4 else {
            errorMessage = "Select 2-4 papers to compare."
            return
        }

        isComparing = true
        errorMessage = nil
        result = nil

        do {
            let store = RustStoreAdapter.shared

            // Gather paper info and content
            var papers: [PaperInfo] = []
            var contextParts: [String] = []

            for pubId in publicationIDs {
                guard let pub = store.getPublicationDetail(id: pubId) else { continue }

                let info = PaperInfo(
                    id: pubId,
                    bibkey: pub.citeKey,
                    title: pub.title,
                    authors: pub.authors.map(\.displayName).joined(separator: ", "),
                    year: pub.year.map { String($0) }
                )
                papers.append(info)

                // Build context from abstract and any available chunk text
                var content = "Title: \(pub.title)\n"
                content += "Authors: \(info.authors)\n"
                if let year = pub.year { content += "Year: \(year)\n" }
                if let abstract = pub.abstract, !abstract.isEmpty {
                    content += "Abstract: \(abstract)\n"
                }

                // Try to get chunk text from embedding store for richer context
                let embStore = RustEmbeddingStoreSession()
                if await embStore.openDefault() {
                    let chunks = await embStore.getChunks(publicationId: pubId.uuidString)
                    if !chunks.isEmpty {
                        let chunkText = chunks.prefix(5).map(\.text).joined(separator: "\n")
                        content += "Content excerpts:\n\(chunkText)\n"
                    }
                    await embStore.close()
                }

                contextParts.append("[\(pub.citeKey)] \(content)")
            }

            // Generate comparison
            let comparison = try await generateComparison(papers: papers, context: contextParts)

            result = ComparisonResult(
                papers: papers,
                comparison: comparison,
                timestamp: .now
            )

            logger.info("Paper comparison generated for \(papers.count) papers")
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Paper comparison failed: \(error.localizedDescription)")
        }

        isComparing = false
    }

    // MARK: - Private

    private func generateComparison(papers: [PaperInfo], context: [String]) async throws -> String {
        let paperList = papers.map { "[\($0.bibkey)] \($0.authors) (\($0.year ?? "n.d.")). \($0.title)" }
            .joined(separator: "\n")

        let systemPrompt = """
        You are a research assistant comparing academic papers. Provide a structured comparison using this format:

        ## Overview
        Brief summary of what these papers address.

        ## Methodology
        Compare the methods used. Cite each paper as [bibkey].

        ## Key Findings
        Compare the main results and conclusions.

        ## Agreements
        Where do these papers align?

        ## Differences
        Where do they diverge?

        ## Summary
        One-paragraph synthesis.

        Always cite papers using their BibTeX keys in square brackets. Be specific and concise.
        """

        let userMessage = """
        Compare these papers:
        \(paperList)

        Paper contents:
        \(context.joined(separator: "\n\n---\n\n"))
        """

        let request = AICompletionRequest(
            messages: [AIMessage(role: .user, text: userMessage)],
            systemPrompt: systemPrompt,
            maxTokens: 3000
        )

        let result = try await executor.executePrimary(request, categoryId: "research.compare")
        guard let response = result, let text = response.text else {
            throw RAGError.noResponse
        }
        return text
    }
}
