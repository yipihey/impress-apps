//
//  RustRISParser.swift
//  PublicationManagerCore
//
//  RIS parser backed by the Rust imbib-core library.
//

import Foundation
import ImbibRustCore

// MARK: - Rust RIS Parser

/// RIS parser implementation using the Rust imbib-core library.
public struct RustRISParser: RISParsing, Sendable {

    public init() {}

    // MARK: - RISParsing Protocol

    public func parse(_ content: String) throws -> [RISEntry] {
        do {
            let rustEntries = try risParse(input: content)
            return rustEntries.map { convertEntry($0) }
        } catch {
            throw RISError.parseError("Rust parser error: \(error)")
        }
    }

    public func parseEntry(_ content: String) throws -> RISEntry {
        let entries = try parse(content)
        guard let entry = entries.first else {
            throw RISError.parseError("No entry found")
        }
        return entry
    }

    // MARK: - Type Conversion

    /// Convert a Rust RISEntry to a Swift RISEntry
    private func convertEntry(_ rustEntry: ImbibRustCore.RisEntry) -> RISEntry {
        RISEntryConversions.fromRust(rustEntry)
    }
}

// MARK: - RIS to BibTeX Conversion via Rust

/// Extension to add Rust-based conversion methods
public extension RustRISParser {
    /// Convert an RIS entry to BibTeX using the Rust library
    func toBibTeX(_ entry: RISEntry) -> BibTeXEntry {
        let rustEntry = convertToRustEntry(entry)
        let rustBibTeX = risToBibtex(entry: rustEntry)
        return convertBibTeXEntry(rustBibTeX)
    }

    /// Convert RIS content directly to BibTeX entries
    func parseAsBibTeX(_ content: String) throws -> [BibTeXEntry] {
        let entries = try parse(content)
        return entries.map { toBibTeX($0) }
    }

    // MARK: - Private Helpers

    private func convertToRustEntry(_ entry: RISEntry) -> ImbibRustCore.RisEntry {
        RISEntryConversions.toRust(entry)
    }

    private func convertBibTeXEntry(_ rustEntry: ImbibRustCore.BibTeXEntry) -> BibTeXEntry {
        BibTeXEntryConversions.fromRust(rustEntry)
    }
}

/// Information about the Rust RIS library
public enum RustRISLibraryInfo {
    public static var isAvailable: Bool { true }
}
