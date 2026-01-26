//
//  RustBibTeXParser.swift
//  PublicationManagerCore
//
//  BibTeX parser backed by the Rust imbib-core library.
//

import Foundation
import ImbibRustCore

// MARK: - Rust BibTeX Parser

/// BibTeX parser implementation using the Rust imbib-core library.
public struct RustBibTeXParser: BibTeXParsing, Sendable {

    private let expandMacros: Bool
    private let resolveCrossrefs: Bool
    private let decodeLaTeX: Bool

    public init(
        expandMacros: Bool = true,
        resolveCrossrefs: Bool = true,
        decodeLaTeX: Bool = true
    ) {
        self.expandMacros = expandMacros
        self.resolveCrossrefs = resolveCrossrefs
        self.decodeLaTeX = decodeLaTeX
    }

    // MARK: - BibTeXParsing Protocol

    public func parse(_ content: String) throws -> [BibTeXItem] {
        let result = try bibtexParse(input: content)

        var items: [BibTeXItem] = []

        // Convert preambles
        for preamble in result.preambles {
            items.append(.preamble(preamble))
        }

        // Convert string macros
        for (name, value) in result.strings {
            items.append(.stringMacro(name: name, value: value))
        }

        // Convert entries
        for rustEntry in result.entries {
            let swiftEntry = convertEntry(rustEntry, rawContent: content)
            items.append(.entry(swiftEntry))
        }

        // Apply crossref resolution if enabled
        if resolveCrossrefs {
            items = resolveCrossrefInheritance(items)
        }

        return items
    }

    public func parseEntries(_ content: String) throws -> [BibTeXEntry] {
        try parse(content).compactMap { item in
            if case .entry(let entry) = item { return entry }
            return nil
        }
    }

    public func parseEntry(_ content: String) throws -> BibTeXEntry {
        let rustEntry = try bibtexParseEntry(input: content)
        return convertEntry(rustEntry, rawContent: content)
    }

    // MARK: - Type Conversion

    /// Convert a Rust BibTeXEntry to a Swift BibTeXEntry
    private func convertEntry(_ rustEntry: ImbibRustCore.BibTeXEntry, rawContent: String) -> PublicationManagerCore.BibTeXEntry {
        BibTeXEntryConversions.fromRust(rustEntry, decodeLaTeX: decodeLaTeX)
    }

    // MARK: - Crossref Resolution

    private func resolveCrossrefInheritance(_ items: [BibTeXItem]) -> [BibTeXItem] {
        var lookup: [String: BibTeXEntry] = [:]
        for item in items {
            if case .entry(let entry) = item {
                lookup[entry.citeKey.lowercased()] = entry
            }
        }

        return items.map { item in
            guard case .entry(let entry) = item else { return item }
            guard let crossref = entry.fields["crossref"],
                  let parent = lookup[crossref.lowercased()] else {
                return item
            }

            var inheritedFields = parent.fields
            for (key, value) in entry.fields {
                inheritedFields[key] = value
            }

            let newEntry = BibTeXEntry(
                citeKey: entry.citeKey,
                entryType: entry.entryType,
                fields: inheritedFields,
                rawBibTeX: entry.rawBibTeX
            )
            return .entry(newEntry)
        }
    }
}

// MARK: - Rust Library Info

/// Information about the Rust library
public enum RustLibraryInfo {
    public static var isAvailable: Bool { true }
    public static var version: String { ImbibRustCore.version() }
    public static func hello() -> String { ImbibRustCore.helloFromRust() }
}
