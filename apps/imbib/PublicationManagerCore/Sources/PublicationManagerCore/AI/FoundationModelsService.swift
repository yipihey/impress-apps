//
//  FoundationModelsService.swift
//  PublicationManagerCore
//
//  On-device structured output via Apple Intelligence (@Generable constrained decoding).
//
//  This service is intentionally separate from AIProviderManager / AIMultiModelExecutor:
//  - @Generable only works with LanguageModelSession directly
//  - These features are Apple-only by design (on-device, private, free)
//  - Callers receive optionals; nil means "Apple Intelligence unavailable"
//
//  Available features:
//  1. Auto-tag classification — classify papers on import (field, paperType, tags)
//  2. Inbox scoring rationale — explain why a paper was recommended
//  3. RAG answer with citations — structured answer + chunk IDs actually used
//

import Foundation
import OSLog

#if canImport(FoundationModels)
import FoundationModels
#endif

private let logger = Logger(subsystem: "com.imbib.app", category: "foundationModels")

// MARK: - Generable Schemas

#if canImport(FoundationModels)

/// Classification of a paper's research field and type, plus keyword tags.
@available(macOS 26, iOS 26, *)
@Generable
public struct PaperClassification {
    @Guide(
        description: "Primary research discipline of this paper",
        .anyOf([
            "machine learning", "artificial intelligence", "computer vision",
            "natural language processing", "robotics", "systems",
            "astrophysics", "physics", "chemistry", "biology", "medicine",
            "mathematics", "statistics", "social science", "economics", "other"
        ])
    )
    public var field: String

    @Guide(
        description: "Type of research contribution",
        .anyOf(["empirical", "theoretical", "review", "methods", "dataset", "position"])
    )
    public var paperType: String

    @Guide(
        description: "Confidence that this classification is correct (0 = uncertain, 1 = very confident)",
        .range(0.0...1.0)
    )
    public var confidence: Double

    @Guide(description: "2 to 4 specific lowercase keyword tags describing the paper's topic and methods")
    public var tags: [String]
}

/// Natural-language rationale for why a paper was recommended.
@available(macOS 26, iOS 26, *)
@Generable
public struct InboxScoringRationale {
    @Guide(description: "Primary reason this paper was recommended, in one clear sentence")
    public var primaryReason: String

    @Guide(
        description: "How closely this paper matches the user's recent reading interests",
        .range(0.0...1.0)
    )
    public var topicMatch: Double

    @Guide(
        description: "Estimated relevance to the user's research focus",
        .anyOf(["core", "adjacent", "peripheral"])
    )
    public var relevanceCategory: String
}

/// Structured RAG answer with explicit list of which chunk IDs were actually used.
@available(macOS 26, iOS 26, *)
@Generable
public struct RAGAnswer {
    @Guide(description: "Answer to the user's question, using markdown formatting with [bibkey] citations")
    public var answer: String

    @Guide(description: "BibTeX keys of papers whose excerpts were directly used to construct this answer")
    public var citedBibkeys: [String]
}

#endif  // canImport(FoundationModels)

// MARK: - FoundationModelsService

/// Actor providing Apple Intelligence @Generable structured output for imbib features.
///
/// Call sites degrade gracefully when Apple Intelligence is unavailable by checking
/// the returned optional. The service creates a new `LanguageModelSession` per call
/// (sessions are lightweight and per-task context is appropriate here).
@available(macOS 26, iOS 26, *)
public actor FoundationModelsService {

    // MARK: - Singleton

    public static let shared = FoundationModelsService()

    private init() {}

    // MARK: - Availability

    /// Whether Apple Intelligence is available on this device.
    public var isAvailable: Bool {
        #if canImport(FoundationModels)
        return SystemLanguageModel.default.isAvailable
        #else
        return false
        #endif
    }

    // MARK: - Auto-Tag Classification

    /// Classify a paper's field, type, and keyword tags from its title and abstract.
    ///
    /// - Returns: A `PaperClassification`, or `nil` when Apple Intelligence is unavailable.
    ///            Tags should only be applied when `confidence >= 0.7`.
    public func classifyPaper(title: String, abstract: String?) async -> PaperClassification? {
        #if canImport(FoundationModels)
        guard SystemLanguageModel.default.isAvailable else { return nil }

        let abstractText = abstract.map { "Abstract: \($0)" } ?? "(no abstract available)"
        let prompt = """
        Classify this research paper.

        Title: \(title)
        \(abstractText)
        """

        do {
            let session = LanguageModelSession()
            let result = try await session.respond(
                to: Prompt(prompt),
                generating: PaperClassification.self
            )
            logger.info("Classified '\(title.prefix(50))': field=\(result.content.field) type=\(result.content.paperType) confidence=\(result.content.confidence, format: .fixed(precision: 2)) tags=\(result.content.tags)")
            return result.content
        } catch {
            logger.warning("classifyPaper failed: \(error.localizedDescription)")
            return nil
        }
        #else
        return nil
        #endif
    }

    // MARK: - Inbox Scoring Rationale

    /// Generate a natural-language rationale explaining why a paper was recommended.
    ///
    /// - Parameters:
    ///   - title: Paper title
    ///   - topFeatures: Top scoring feature names and their contribution values
    ///   - topicContext: Brief description of the user's reading interests
    /// - Returns: A rationale, or `nil` when Apple Intelligence is unavailable.
    public func explainRecommendation(
        title: String,
        topFeatures: [(name: String, contribution: Double)],
        topicContext: String
    ) async -> InboxScoringRationale? {
        #if canImport(FoundationModels)
        guard SystemLanguageModel.default.isAvailable else { return nil }

        let featureList = topFeatures.prefix(3).map { f in
            "- \(f.name): \(String(format: "%.2f", f.contribution))"
        }.joined(separator: "\n")

        let prompt = """
        Explain why this paper was recommended to a researcher.

        Paper: \(title)

        Recommendation signals that contributed to this paper's ranking:
        \(featureList)

        User's recent reading context: \(topicContext)
        """

        do {
            let session = LanguageModelSession()
            let result = try await session.respond(
                to: Prompt(prompt),
                generating: InboxScoringRationale.self
            )
            logger.info("Rationale for '\(title.prefix(40))': \(result.content.relevanceCategory)")
            return result.content
        } catch {
            logger.warning("explainRecommendation failed: \(error.localizedDescription)")
            return nil
        }
        #else
        return nil
        #endif
    }

    // MARK: - RAG Answer with Citations

    /// Generate a structured RAG answer that explicitly identifies which papers were cited.
    ///
    /// - Parameters:
    ///   - question: The user's question
    ///   - context: Assembled paper excerpts (already formatted with [bibkey] headers)
    /// - Returns: A `RAGAnswer` with answer text and cited bibkeys, or `nil` when unavailable.
    public func extractRAGAnswer(question: String, context: String) async -> RAGAnswer? {
        #if canImport(FoundationModels)
        guard SystemLanguageModel.default.isAvailable else { return nil }
        guard !context.isEmpty else { return nil }

        let prompt = """
        Answer the question using ONLY the provided paper excerpts.
        Cite papers using their BibTeX keys in square brackets, e.g. [Smith2024].
        Also report which bibkeys you actually used in your answer.
        Keep your answer concise and well-structured.

        Question: \(question)

        Paper excerpts:
        \(context)
        """

        do {
            let session = LanguageModelSession()
            let result = try await session.respond(
                to: Prompt(prompt),
                generating: RAGAnswer.self
            )
            logger.info("RAG answer: \(result.content.citedBibkeys.count) cited papers")
            return result.content
        } catch {
            logger.warning("extractRAGAnswer failed: \(error.localizedDescription)")
            return nil
        }
        #else
        return nil
        #endif
    }
}

// MARK: - Availability Stub for < macOS 26

// FoundationModelsService is @available(macOS 26) so callers on earlier platforms
// can't reference it. If you need a pre-26 call site, guard with #available.
