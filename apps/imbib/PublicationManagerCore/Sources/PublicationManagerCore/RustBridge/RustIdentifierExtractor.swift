//
//  RustIdentifierExtractor.swift
//  PublicationManagerCore
//
//  Identifier extraction backed by the Rust imbib-core library.
//  Provides fast regex-based extraction of DOIs, arXiv IDs, ISBNs from text.
//

import Foundation
import ImbibRustCore

// MARK: - Identifier Extraction Protocol

/// Protocol for identifier extraction implementations.
public protocol IdentifierExtracting: Sendable {
    /// Extract all DOIs from text
    func extractDOIs(from text: String) -> [String]

    /// Extract all arXiv IDs from text
    func extractArXivIDs(from text: String) -> [String]

    /// Extract all ISBNs from text
    func extractISBNs(from text: String) -> [String]

    /// Extract all identifiers from text with position information
    func extractAll(from text: String) -> [ExtractedIdentifierResult]
}

/// Result of identifier extraction with position information
public struct ExtractedIdentifierResult: Sendable, Equatable {
    /// Type of identifier (doi, arxiv, isbn)
    public let identifierType: String
    /// The extracted value
    public let value: String
    /// Start position in the original text
    public let startIndex: Int
    /// End position in the original text
    public let endIndex: Int

    public init(identifierType: String, value: String, startIndex: Int, endIndex: Int) {
        self.identifierType = identifierType
        self.value = value
        self.startIndex = startIndex
        self.endIndex = endIndex
    }
}

// MARK: - Identifier Extractor Factory

/// Factory for creating identifier extractors.
///
/// Only the Rust extractor remains — the Swift one was a thin adapter over the
/// hand-written regexes deleted in Stage 7, and it silently reported at most one
/// hit per kind and no ISBNs at all.
public enum IdentifierExtractorFactory {

    /// The backend actually used for identifier extraction.
    public static let backend: BibTeXParserFactory.Backend = .rust

    /// Create an extractor.
    public static func createExtractor() -> any IdentifierExtracting {
        RustIdentifierExtractor()
    }
}

// MARK: - Rust Identifier Extractor

/// Identifier extractor implementation using the Rust imbib-core library.
public struct RustIdentifierExtractor: IdentifierExtracting, Sendable {

    public init() {}

    public func extractDOIs(from text: String) -> [String] {
        extractDois(text: text)
    }

    public func extractArXivIDs(from text: String) -> [String] {
        extractArxivIds(text: text)
    }

    public func extractISBNs(from text: String) -> [String] {
        extractIsbns(text: text)
    }

    public func extractAll(from text: String) -> [ExtractedIdentifierResult] {
        let rustResults = ImbibRustCore.extractAll(text: text)
        return rustResults.map { rustResult in
            ExtractedIdentifierResult(
                identifierType: rustResult.identifierType,
                value: rustResult.value,
                startIndex: Int(rustResult.startIndex),
                endIndex: Int(rustResult.endIndex)
            )
        }
    }
}

// MARK: - Rust Identifier Validation

/// Utilities for validating identifiers using the Rust library
public enum RustIdentifierValidator {
    /// Validate a DOI
    public static func isValidDOI(_ doi: String) -> Bool {
        isValidDoi(doi: doi)
    }

    /// Validate an arXiv ID
    public static func isValidArXivID(_ arxivID: String) -> Bool {
        isValidArxivId(arxivId: arxivID)
    }

    /// Validate an ISBN
    public static func isValidISBN(_ isbn: String) -> Bool {
        isValidIsbn(isbn: isbn)
    }

    /// Normalize a DOI (lowercase, remove URL prefix)
    public static func normalizeDOI(_ doi: String) -> String {
        normalizeDoi(doi: doi)
    }
}

// MARK: - Cite Key Generation via Rust

/// Generate cite keys using the Rust library
public enum RustCiteKeyGenerator {
    /// Generate a cite key from author, year, and title
    public static func generate(author: String?, year: String?, title: String?) -> String {
        generateCiteKey(
            author: author,
            year: year,
            title: title
        )
    }

    /// Generate a unique cite key that doesn't conflict with existing keys
    /// - Parameters:
    ///   - author: Author string
    ///   - year: Publication year
    ///   - title: Publication title
    ///   - existingKeys: Set of existing cite keys to avoid conflicts with
    /// - Returns: A unique cite key string
    public static func generateUnique(
        author: String?,
        year: String?,
        title: String?,
        existingKeys: Set<String>
    ) -> String {
        generateUniqueCiteKey(
            author: author,
            year: year,
            title: title,
            existingKeys: Array(existingKeys)
        )
    }

    /// Make a cite key unique by appending a suffix if it conflicts
    /// - Parameters:
    ///   - base: The base cite key
    ///   - existingKeys: Set of existing cite keys to avoid conflicts with
    /// - Returns: A unique cite key string
    public static func makeUnique(_ base: String, existingKeys: Set<String>) -> String {
        makeCiteKeyUnique(base: base, existingKeys: Array(existingKeys))
    }
}

/// Information about Rust identifier extraction
public enum RustIdentifierInfo {
    public static var isAvailable: Bool { true }
}
