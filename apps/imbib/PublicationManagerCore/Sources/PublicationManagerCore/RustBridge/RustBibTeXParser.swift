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
        // Macro expansion and crossref inheritance are resolved in Rust. They
        // used to be re-implemented on this side of the bridge, which is how
        // the import path and the editor path ended up disagreeing about
        // `month = sep`.
        let result = try bibtexParseWithOptions(
            input: content,
            expandMacros: expandMacros,
            resolveCrossrefs: resolveCrossrefs
        )

        var items: [BibTeXItem] = []

        // Convert preambles
        for preamble in result.preambles {
            items.append(.preamble(preamble))
        }

        // Convert string macros
        for (name, value) in result.strings {
            items.append(.stringMacro(name: name, value: value))
        }

        // Convert @comment blocks (the exporter re-emits them)
        for comment in result.comments {
            items.append(.comment(comment))
        }

        // Convert entries
        for rustEntry in result.entries {
            let swiftEntry = convertEntry(rustEntry, rawContent: content)
            items.append(.entry(swiftEntry))
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

}

// MARK: - Rust Library Info

/// Information about the Rust library
public enum RustLibraryInfo {
    public static var isAvailable: Bool { true }
    public static var version: String { ImbibRustCore.version() }
    public static func hello() -> String { ImbibRustCore.helloFromRust() }
}
