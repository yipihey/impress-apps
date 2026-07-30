//
//  RISParsingFactory.swift
//  PublicationManagerCore
//
//  Protocol and factory for RIS parsing backends.
//  Allows switching between Swift and Rust implementations.
//

import Foundation

// MARK: - RIS Parsing Protocol

/// Protocol for RIS parsing implementations.
/// Both the Swift native parser and the Rust-backed parser conform to this protocol.
public protocol RISParsing: Sendable {
    /// Parse RIS content into entries
    func parse(_ content: String) throws -> [RISEntry]

    /// Parse a single entry from string
    func parseEntry(_ content: String) throws -> RISEntry
}

// MARK: - Default Implementation

public extension RISParsing {
    func parseEntry(_ content: String) throws -> RISEntry {
        let entries = try parse(content)
        guard let entry = entries.first else {
            throw RISError.parseError("No entry found")
        }
        return entry
    }
}

// MARK: - Parser Factory

/// Factory for creating RIS parsers.
///
/// Only the Rust parser (`imbib-core::ris`) remains; the Swift `RISParser` was
/// deleted in Stage 7 after the golden corpus proved parity. ADR-013 made RIS
/// first-class, so it gets the same single-implementation treatment as BibTeX.
public enum RISParserFactory {

    /// The backend actually used for RIS parsing.
    public static let backend: BibTeXParserFactory.Backend = .rust

    /// Create a parser.
    public static func createParser() -> any RISParsing {
        RustRISParser()
    }
}
