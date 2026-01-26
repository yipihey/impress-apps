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
/// Controls which backend (Swift or Rust) is used.
public enum RISParserFactory {

    /// Current backend selection.
    /// Defaults to Rust. Change this to switch between implementations.
    public static var currentBackend: BibTeXParserFactory.Backend = .rust

    /// Create a parser using the current backend
    public static func createParser() -> any RISParsing {
        switch currentBackend {
        case .swift:
            return RISParser()
        case .rust:
            return RustRISParser()
        }
    }
}

// MARK: - Swift Parser Conformance

extension RISParser: RISParsing {}
