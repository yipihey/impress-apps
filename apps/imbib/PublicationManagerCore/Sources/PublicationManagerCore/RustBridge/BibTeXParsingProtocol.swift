//
//  BibTeXParsingProtocol.swift
//  PublicationManagerCore
//
//  Protocol abstraction for BibTeX parsing backends.
//  Allows switching between Swift and Rust implementations.
//

import Foundation

// MARK: - BibTeX Parsing Protocol

/// Protocol for BibTeX parsing implementations.
/// Both the Swift native parser and the Rust-backed parser conform to this protocol.
public protocol BibTeXParsing: Sendable {
    /// Parse BibTeX content into items (entries, macros, preambles, comments)
    func parse(_ content: String) throws -> [BibTeXItem]

    /// Parse and return only entries
    func parseEntries(_ content: String) throws -> [BibTeXEntry]

    /// Parse a single entry from string
    func parseEntry(_ content: String) throws -> BibTeXEntry
}

// MARK: - Default Implementation

public extension BibTeXParsing {
    func parseEntries(_ content: String) throws -> [BibTeXEntry] {
        try parse(content).compactMap { item in
            if case .entry(let entry) = item { return entry }
            return nil
        }
    }

    func parseEntry(_ content: String) throws -> BibTeXEntry {
        let entries = try parseEntries(content)
        guard let entry = entries.first else {
            throw BibTeXError.parseError(line: 1, message: "No entry found")
        }
        return entry
    }
}

// MARK: - Parser Factory

/// Factory for creating BibTeX parsers.
/// Controls which backend (Swift or Rust) is used.
public enum BibTeXParserFactory {

    /// The backend to use for BibTeX parsing
    public enum Backend: String, CaseIterable, Sendable {
        case swift = "Swift"
        case rust = "Rust"
    }

    /// Current backend selection.
    /// Defaults to Rust. Change this to switch between implementations.
    public static var currentBackend: Backend = .rust

    /// Create a parser using the current backend
    public static func createParser(
        expandMacros: Bool = true,
        resolveCrossrefs: Bool = true,
        decodeLaTeX: Bool = true
    ) -> any BibTeXParsing {
        switch currentBackend {
        case .swift:
            return BibTeXParser(
                expandMacros: expandMacros,
                resolveCrossrefs: resolveCrossrefs,
                decodeLaTeX: decodeLaTeX
            )
        case .rust:
            return RustBibTeXParser(
                expandMacros: expandMacros,
                resolveCrossrefs: resolveCrossrefs,
                decodeLaTeX: decodeLaTeX
            )
        }
    }
}

// MARK: - Swift Parser Conformance

extension BibTeXParser: BibTeXParsing {}
