//
//  AISearchAssistantTests.swift
//  PublicationManagerCoreTests
//
//  Tests for AISearchAssistant functionality.
//

import XCTest
@testable import PublicationManagerCore
@testable import ImpressAI

// MARK: - Test Helpers

/// Creates a mock response for testing
private func createMockResponse(text: String) -> AIModelExecutionResult {
    let response = AICompletionResponse(
        id: UUID().uuidString,
        content: [.text(text)],
        model: "mock-model"
    )

    return AIModelExecutionResult(
        modelReference: AIModelReference(providerId: "mock", modelId: "mock-model", displayName: "Mock Model"),
        status: .completed,
        response: response,
        duration: 0.1,
        startTime: Date()
    )
}

// MARK: - JSON Parsing Tests

/// Tests for JSON extraction and parsing logic used by AISearchAssistant.
/// These tests verify the parsing behavior without requiring a real AI backend.
final class AISearchAssistantParsingTests: XCTestCase {

    // MARK: - Query Expansion JSON Parsing

    func testQueryExpansionJSON_ValidJSON() throws {
        let jsonString = """
        {
            "original": "machine learning",
            "synonyms": ["ML", "statistical learning"],
            "related": ["deep learning", "neural networks"],
            "specific": ["supervised learning", "reinforcement learning"],
            "broader": ["artificial intelligence", "computer science"],
            "suggested_queries": ["machine learning algorithms", "deep learning models"]
        }
        """

        let data = jsonString.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(QueryExpansionJSONTestHelper.self, from: data)

        XCTAssertEqual(decoded.original, "machine learning")
        XCTAssertEqual(decoded.synonyms, ["ML", "statistical learning"])
        XCTAssertEqual(decoded.related, ["deep learning", "neural networks"])
        XCTAssertEqual(decoded.specific, ["supervised learning", "reinforcement learning"])
        XCTAssertEqual(decoded.broader, ["artificial intelligence", "computer science"])
        XCTAssertEqual(decoded.suggested_queries, ["machine learning algorithms", "deep learning models"])
    }

    func testQueryExpansionJSON_PartialFields() throws {
        let jsonString = """
        {
            "synonyms": ["ML"],
            "suggested_queries": ["query 1"]
        }
        """

        let data = jsonString.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(QueryExpansionJSONTestHelper.self, from: data)

        XCTAssertNil(decoded.original)
        XCTAssertEqual(decoded.synonyms, ["ML"])
        XCTAssertNil(decoded.related)
        XCTAssertEqual(decoded.suggested_queries, ["query 1"])
    }

    // MARK: - Paper Summary JSON Parsing

    func testPaperSummaryJSON_ValidJSON() throws {
        let jsonString = """
        {
            "brief_summary": "This paper introduces a novel approach.",
            "key_findings": ["Finding 1", "Finding 2"],
            "methodology": "Experimental analysis",
            "relevance": "High impact"
        }
        """

        let data = jsonString.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(PaperSummaryJSONTestHelper.self, from: data)

        XCTAssertEqual(decoded.brief_summary, "This paper introduces a novel approach.")
        XCTAssertEqual(decoded.key_findings, ["Finding 1", "Finding 2"])
        XCTAssertEqual(decoded.methodology, "Experimental analysis")
        XCTAssertEqual(decoded.relevance, "High impact")
    }

    func testPaperSummaryJSON_MinimalFields() throws {
        let jsonString = """
        {
            "brief_summary": "Summary only"
        }
        """

        let data = jsonString.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(PaperSummaryJSONTestHelper.self, from: data)

        XCTAssertEqual(decoded.brief_summary, "Summary only")
        XCTAssertNil(decoded.key_findings)
        XCTAssertNil(decoded.methodology)
        XCTAssertNil(decoded.relevance)
    }

    // MARK: - Paper Suggestion JSON Parsing

    func testPaperSuggestionJSON_ValidArray() throws {
        let jsonString = """
        [
            {
                "title": "Related Paper 1",
                "authors": "Smith, John",
                "year": 2023,
                "relevance": "Extends the original work"
            },
            {
                "title": "Related Paper 2",
                "authors": "Doe, Jane",
                "year": 2022,
                "relevance": "Similar methodology"
            }
        ]
        """

        let data = jsonString.data(using: .utf8)!
        let decoded = try JSONDecoder().decode([PaperSuggestionJSONTestHelper].self, from: data)

        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].title, "Related Paper 1")
        XCTAssertEqual(decoded[0].authors, "Smith, John")
        XCTAssertEqual(decoded[0].year, 2023)
        XCTAssertEqual(decoded[0].relevance, "Extends the original work")
        XCTAssertEqual(decoded[1].title, "Related Paper 2")
    }

    func testPaperSuggestionJSON_MinimalEntry() throws {
        let jsonString = """
        [
            {
                "title": "Paper Title Only"
            }
        ]
        """

        let data = jsonString.data(using: .utf8)!
        let decoded = try JSONDecoder().decode([PaperSuggestionJSONTestHelper].self, from: data)

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].title, "Paper Title Only")
        XCTAssertNil(decoded[0].authors)
        XCTAssertNil(decoded[0].year)
        XCTAssertNil(decoded[0].relevance)
    }

    // MARK: - JSON Extraction Tests

    func testExtractJSON_ObjectFromProse() {
        let text = """
        Here is your response:
        {
            "key": "value"
        }
        That's all!
        """

        let extracted = extractJSONFromText(text)

        XCTAssertEqual(extracted, """
        {
            "key": "value"
        }
        """)
    }

    func testExtractJSON_ArrayFromProse() {
        // Note: The extraction logic prefers {} over [] when both are present
        // since it checks for { first. This test uses array-only content.
        let text = """
        Results:
        ["item1", "item2", "item3"]
        End of results.
        """

        let extracted = extractJSONFromText(text)

        XCTAssertEqual(extracted, "[\"item1\", \"item2\", \"item3\"]")
    }

    func testExtractJSON_NestedBraces() {
        let text = """
        {
            "synonyms": ["term with {braces}"],
            "nested": {"inner": "value"}
        }
        """

        let extracted = extractJSONFromText(text)

        // Should extract from first { to last }
        XCTAssertTrue(extracted.hasPrefix("{"))
        XCTAssertTrue(extracted.hasSuffix("}"))
        XCTAssertTrue(extracted.contains("nested"))
    }

    func testExtractJSON_NoJSON() {
        let text = "This is plain text with no JSON."

        let extracted = extractJSONFromText(text)

        // Should return original text when no JSON found
        XCTAssertEqual(extracted, text)
    }

    // MARK: - BibTeX Cleanup Tests

    func testBibTeXCleanup_RemovesMarkdownFences() {
        let input = """
        ```bibtex
        @article{Test2023,
            author = {Author},
            title = {Title}
        }
        ```
        """

        let cleaned = cleanBibTeXResponse(input)

        XCTAssertFalse(cleaned.contains("```bibtex"))
        XCTAssertFalse(cleaned.contains("```"))
        XCTAssertTrue(cleaned.contains("@article{Test2023"))
    }

    func testBibTeXCleanup_HandlesCleanInput() {
        let input = """
        @article{Test2023,
            author = {Author},
            title = {Title}
        }
        """

        let cleaned = cleanBibTeXResponse(input)

        XCTAssertTrue(cleaned.contains("@article{Test2023"))
    }

    func testBibTeXCleanup_TrimsWhitespace() {
        let input = "   \n\n@article{Test}   \n\n"

        let cleaned = cleanBibTeXResponse(input)

        XCTAssertEqual(cleaned, "@article{Test}")
    }

    // MARK: - Helper Functions

    /// Extracts JSON from text (mirrors AISearchAssistant's private method)
    private func extractJSONFromText(_ text: String) -> String {
        if let start = text.firstIndex(of: "{"),
           let end = text.lastIndex(of: "}") {
            return String(text[start...end])
        }
        if let start = text.firstIndex(of: "["),
           let end = text.lastIndex(of: "]") {
            return String(text[start...end])
        }
        return text
    }

    /// Cleans BibTeX response (mirrors AISearchAssistant's cleanup logic)
    private func cleanBibTeXResponse(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "```bibtex", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - JSON Decoding Test Helpers

/// Mirror of QueryExpansionJSON for testing
private struct QueryExpansionJSONTestHelper: Decodable {
    let original: String?
    let synonyms: [String]?
    let related: [String]?
    let specific: [String]?
    let broader: [String]?
    let suggested_queries: [String]?
}

/// Mirror of PaperSummaryJSON for testing
private struct PaperSummaryJSONTestHelper: Decodable {
    let brief_summary: String?
    let key_findings: [String]?
    let methodology: String?
    let relevance: String?
}

/// Mirror of PaperSuggestionJSON for testing
private struct PaperSuggestionJSONTestHelper: Decodable {
    let title: String
    let authors: String?
    let year: Int?
    let relevance: String?
}

// MARK: - Result Type Tests

final class AISearchAssistantResultTypesTests: XCTestCase {

    func testQueryExpansionResult_Initialization() {
        let result = QueryExpansionResult(
            originalQuery: "test",
            synonyms: ["syn1", "syn2"],
            relatedConcepts: ["related"],
            specificTopics: ["specific"],
            broaderTopics: ["broader"],
            suggestedQueries: ["query1"]
        )

        XCTAssertEqual(result.originalQuery, "test")
        XCTAssertEqual(result.synonyms.count, 2)
        XCTAssertEqual(result.relatedConcepts.count, 1)
    }

    func testPaperSummary_Initialization() {
        let summary = PaperSummary(
            title: "Test Paper",
            briefSummary: "A brief summary.",
            keyFindings: ["Finding 1", "Finding 2"],
            methodology: "Experimental",
            relevance: "High"
        )

        XCTAssertEqual(summary.title, "Test Paper")
        XCTAssertEqual(summary.briefSummary, "A brief summary.")
        XCTAssertEqual(summary.keyFindings.count, 2)
        XCTAssertEqual(summary.methodology, "Experimental")
        XCTAssertEqual(summary.relevance, "High")
    }

    func testPaperSuggestion_Identifiable() {
        let suggestion = PaperSuggestion(
            title: "Unique Title",
            authors: "Author Name",
            year: 2023,
            relevance: "Relevant"
        )

        XCTAssertEqual(suggestion.id, "Unique Title")
    }

    func testPaperSuggestion_OptionalFields() {
        let suggestion = PaperSuggestion(
            title: "Title Only",
            authors: nil,
            year: nil,
            relevance: nil
        )

        XCTAssertEqual(suggestion.title, "Title Only")
        XCTAssertNil(suggestion.authors)
        XCTAssertNil(suggestion.year)
        XCTAssertNil(suggestion.relevance)
    }
}

// MARK: - Error Tests

final class AISearchErrorTests: XCTestCase {

    func testNoResponseError_Description() {
        let error = AISearchError.noResponse

        XCTAssertEqual(error.errorDescription, "No response from AI provider")
    }

    func testParseError_Description() {
        let error = AISearchError.parseError("Invalid format")

        XCTAssertEqual(error.errorDescription, "Failed to parse response: Invalid format")
    }

    func testNotConfiguredError_Description() {
        let error = AISearchError.notConfigured

        XCTAssertEqual(error.errorDescription, "AI is not configured. Please add an API key in Settings.")
    }
}
