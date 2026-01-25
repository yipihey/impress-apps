//
//  UnifiedFormatConverter.swift
//  PublicationManagerCore
//
//  Unified format conversion service backed by the Rust imbib-core library.
//  Provides a single entry point for all format conversions.
//

import Foundation
import ImbibRustCore

// MARK: - Format Type

/// Supported bibliographic formats
public enum BibliographicFormat: String, CaseIterable, Sendable {
    case bibtex = "BibTeX"
    case ris = "RIS"
}

// MARK: - Unified Format Converter

/// Unified service for converting between bibliographic formats.
/// Selects the best available backend (Rust or Swift) automatically.
public enum UnifiedFormatConverter {

    // MARK: - Backend Selection

    /// Whether to prefer Rust backend when available
    public static var preferRustBackend: Bool = true

    // MARK: - Parsing

    /// Parse BibTeX content into entries
    public static func parseBibTeX(_ content: String) throws -> [BibTeXEntry] {
        let parser = BibTeXParserFactory.createParser()
        return try parser.parseEntries(content)
    }

    /// Parse RIS content into entries
    public static func parseRIS(_ content: String) throws -> [RISEntry] {
        let parser = RISParserFactory.createParser()
        return try parser.parse(content)
    }

    /// Auto-detect format and parse
    public static func parse(_ content: String) throws -> [BibTeXEntry] {
        let format = detectFormat(content)

        switch format {
        case .bibtex:
            return try parseBibTeX(content)
        case .ris:
            let risEntries = try parseRIS(content)
            return risEntries.map { convertRISToBibTeX($0) }
        }
    }

    // MARK: - Format Detection

    /// Detect the bibliographic format of content
    public static func detectFormat(_ content: String) -> BibliographicFormat {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)

        // RIS starts with "TY  - " (type tag)
        if trimmed.hasPrefix("TY  -") || trimmed.contains("\nTY  -") {
            return .ris
        }

        // BibTeX starts with @ followed by entry type
        if trimmed.hasPrefix("@") || trimmed.contains("\n@") {
            return .bibtex
        }

        // Default to BibTeX
        return .bibtex
    }

    // MARK: - Conversion

    /// Convert RIS entry to BibTeX entry using the best available backend
    public static func convertRISToBibTeX(_ risEntry: RISEntry) -> BibTeXEntry {
        if preferRustBackend {
            return RustRISParser().toBibTeX(risEntry)
        }
        return RISBibTeXConverter.toBibTeX(risEntry)
    }

    /// Convert BibTeX entry to RIS entry using the best available backend
    public static func convertBibTeXToRIS(_ bibEntry: BibTeXEntry) -> RISEntry {
        if preferRustBackend {
            let rustEntry = convertToRustBibTeX(bibEntry)
            let rustRIS = ImbibRustCore.risFromBibtex(entry: rustEntry)
            return convertFromRustRIS(rustRIS)
        }
        return RISBibTeXConverter.toRIS(bibEntry)
    }

    /// Convert RIS content directly to BibTeX string
    public static func risToBibTeXString(_ risContent: String) throws -> String {
        let risEntries = try parseRIS(risContent)
        let bibEntries = risEntries.map { convertRISToBibTeX($0) }
        return BibTeXExporter().export(bibEntries)
    }

    /// Convert BibTeX content directly to RIS string
    public static func bibTeXToRISString(_ bibtexContent: String) throws -> String {
        let bibEntries = try parseBibTeX(bibtexContent)
        let risEntries = bibEntries.map { convertBibTeXToRIS($0) }
        return RISExporter().export(risEntries)
    }

    // MARK: - Batch Conversion

    /// Convert multiple BibTeX entries to RIS
    public static func convertBibTeXToRIS(_ entries: [BibTeXEntry]) -> [RISEntry] {
        entries.map { convertBibTeXToRIS($0) }
    }

    /// Convert multiple RIS entries to BibTeX
    public static func convertRISToBibTeX(_ entries: [RISEntry]) -> [BibTeXEntry] {
        entries.map { convertRISToBibTeX($0) }
    }
}

// MARK: - Private Helpers

extension UnifiedFormatConverter {

    static func convertToRustBibTeX(_ entry: BibTeXEntry) -> ImbibRustCore.BibTeXEntry {
        let rustType: ImbibRustCore.BibTeXEntryType
        switch entry.entryType.lowercased() {
        case "article": rustType = .article
        case "book": rustType = .book
        case "booklet": rustType = .booklet
        case "inbook": rustType = .inBook
        case "incollection": rustType = .inCollection
        case "inproceedings", "conference": rustType = .inProceedings
        case "manual": rustType = .manual
        case "mastersthesis": rustType = .mastersThesis
        case "misc": rustType = .misc
        case "phdthesis": rustType = .phdThesis
        case "proceedings": rustType = .proceedings
        case "techreport": rustType = .techReport
        case "unpublished": rustType = .unpublished
        case "online": rustType = .online
        case "software": rustType = .software
        case "dataset": rustType = .dataset
        default: rustType = .unknown
        }

        let fields = entry.fields.map { key, value in
            ImbibRustCore.BibTeXField(key: key, value: value)
        }

        return ImbibRustCore.BibTeXEntry(
            citeKey: entry.citeKey,
            entryType: rustType,
            fields: fields,
            rawBibtex: entry.rawBibTeX
        )
    }

    static func convertFromRustRIS(_ rustEntry: ImbibRustCore.RisEntry) -> RISEntry {
        let swiftType = convertRISType(rustEntry.entryType)
        let swiftTags = rustEntry.tags.compactMap { tag -> RISTagValue? in
            guard let risTag = RISTag.from(tag.tag) else { return nil }
            return RISTagValue(tag: risTag, value: tag.value)
        }
        return RISEntry(type: swiftType, tags: swiftTags, rawRIS: rustEntry.rawRis)
    }

    static func convertRISType(_ rustType: ImbibRustCore.RisType) -> RISReferenceType {
        switch rustType {
        case .jour: return .JOUR
        case .book: return .BOOK
        case .chap: return .CHAP
        case .conf: return .CONF
        case .thes: return .THES
        case .rprt: return .RPRT
        case .unpb: return .UNPB
        case .gen: return .GEN
        case .elec: return .ELEC
        case .news: return .NEWS
        default: return .GEN
        }
    }
}
