//
//  BibTeXParsingFactory.swift
//  PublicationManagerCore
//
//  Protocol and factory for BibTeX parsing backends.
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
///
/// There is exactly one BibTeX parser now: the Rust one in `im-bibtex`. The
/// hand-written Swift parser was deleted in Stage 7 once
/// `crates/imbib-core/tests/golden_parity.rs` proved the Rust parser reproduced
/// its behaviour over the whole fixture corpus. The factory survives because
/// call sites read better through it, and because it is the seam where parse
/// options are chosen.
public enum BibTeXParserFactory {

    /// Backend identifier, retained for the bridges that still have two
    /// implementations (e.g. `DeduplicationScorerFactory`).
    public enum Backend: String, CaseIterable, Sendable {
        case swift = "Swift"
        case rust = "Rust"
    }

    /// The backend actually used for BibTeX parsing.
    public static let backend: Backend = .rust

    /// Create a parser.
    public static func createParser(
        expandMacros: Bool = true,
        resolveCrossrefs: Bool = true,
        decodeLaTeX: Bool = true
    ) -> any BibTeXParsing {
        RustBibTeXParser(
            expandMacros: expandMacros,
            resolveCrossrefs: resolveCrossrefs,
            decodeLaTeX: decodeLaTeX
        )
    }
}
