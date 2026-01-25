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
        // Convert entry type
        let entryType = convertRISType(rustEntry.entryType)

        // Convert tags from Rust to Swift format
        var swiftTags: [RISTagValue] = []
        for rustTag in rustEntry.tags {
            if let tag = RISTag.from(rustTag.tag) {
                swiftTags.append(RISTagValue(tag: tag, value: rustTag.value))
            }
        }

        return RISEntry(
            type: entryType,
            tags: swiftTags,
            rawRIS: rustEntry.rawRis
        )
    }

    /// Convert Rust RIS type to Swift RIS type
    private func convertRISType(_ rustType: ImbibRustCore.RisType) -> RISReferenceType {
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
        case .abst: return .ABST
        case .advs: return .ADVS
        case .art: return .ART
        case .bill: return .BILL
        case .blog: return .BLOG
        case .case: return .CASE
        case .clswk: return .CLSWK
        case .comp: return .COMP
        case .cpaper: return .CPAPER
        case .ctlg: return .CTLG
        case .data: return .DATA
        case .dbase: return .DBASE
        case .dict: return .DICT
        case .edbook: return .EDBOOK
        case .ejour: return .EJOUR
        case .encyc: return .ENCYC
        case .equa: return .EQUA
        case .figure: return .FIGURE
        case .govdoc: return .GOVDOC
        case .grant: return .GRANT
        case .hear: return .HEAR
        case .icomm: return .ICOMM
        case .inpr: return .INPR
        case .jfull: return .JFULL
        case .legal: return .LEGAL
        case .manscpt: return .MANSCPT
        case .map: return .MAP
        case .mgzn: return .MGZN
        case .mpct: return .MPCT
        case .multi: return .MULTI
        case .music: return .MUSIC
        case .pamp: return .PAMP
        case .pat: return .PAT
        case .pcomm: return .PCOMM
        case .slide: return .SLIDE
        case .sound: return .SOUND
        case .stand: return .STAND
        case .stat: return .STAT
        case .unbill: return .UNBILL
        case .video: return .VIDEO
        case .unknown: return .GEN
        // Additional types in Rust but not in Swift - map to GEN
        case .aggr, .ancient, .chart, .ebook, .echap, .ser:
            return .GEN
        }
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
        let rustType = convertToRustType(entry.type)
        let rustTags = entry.tags.map { tag in
            ImbibRustCore.RisTag(tag: tag.tag.rawValue, value: tag.value)
        }
        return ImbibRustCore.RisEntry(
            entryType: rustType,
            tags: rustTags,
            rawRis: entry.rawRIS
        )
    }

    private func convertToRustType(_ type: RISReferenceType) -> ImbibRustCore.RisType {
        switch type {
        case .JOUR: return .jour
        case .BOOK: return .book
        case .CHAP: return .chap
        case .CONF: return .conf
        case .THES: return .thes
        case .RPRT: return .rprt
        case .UNPB: return .unpb
        case .GEN: return .gen
        case .ELEC: return .elec
        case .NEWS: return .news
        case .ABST: return .abst
        case .ADVS: return .advs
        case .ART: return .art
        case .BILL: return .bill
        case .BLOG: return .blog
        case .CASE: return .case
        case .CLSWK: return .clswk
        case .COMP: return .comp
        case .CPAPER: return .cpaper
        case .CTLG: return .ctlg
        case .DATA: return .data
        case .DBASE: return .dbase
        case .DICT: return .dict
        case .EDBOOK: return .edbook
        case .EJOUR: return .ejour
        case .ENCYC: return .encyc
        case .EQUA: return .equa
        case .FIGURE: return .figure
        case .GOVDOC: return .govdoc
        case .GRANT: return .grant
        case .HEAR: return .hear
        case .ICOMM: return .icomm
        case .INPR: return .inpr
        case .JFULL: return .jfull
        case .LEGAL: return .legal
        case .MANSCPT: return .manscpt
        case .MAP: return .map
        case .MGZN: return .mgzn
        case .MPCT: return .mpct
        case .MULTI: return .multi
        case .MUSIC: return .music
        case .PAMP: return .pamp
        case .PAT: return .pat
        case .PCOMM: return .pcomm
        case .PRESS: return .gen
        case .SLIDE: return .slide
        case .SOUND: return .sound
        case .STAND: return .stand
        case .STAT: return .stat
        case .STD: return .stand
        case .UNBILL: return .unbill
        case .VIDEO: return .video
        case .WEB: return .elec
        }
    }

    private func convertBibTeXEntry(_ rustEntry: ImbibRustCore.BibTeXEntry) -> BibTeXEntry {
        var fields: [String: String] = [:]
        for field in rustEntry.fields {
            fields[field.key.lowercased()] = field.value
        }

        let entryType: String
        switch rustEntry.entryType {
        case .article: entryType = "article"
        case .book: entryType = "book"
        case .booklet: entryType = "booklet"
        case .inBook: entryType = "inbook"
        case .inCollection: entryType = "incollection"
        case .inProceedings: entryType = "inproceedings"
        case .manual: entryType = "manual"
        case .mastersThesis: entryType = "mastersthesis"
        case .misc: entryType = "misc"
        case .phdThesis: entryType = "phdthesis"
        case .proceedings: entryType = "proceedings"
        case .techReport: entryType = "techreport"
        case .unpublished: entryType = "unpublished"
        case .online: entryType = "online"
        case .software: entryType = "software"
        case .dataset: entryType = "dataset"
        case .unknown: entryType = "misc"
        }

        return BibTeXEntry(
            citeKey: rustEntry.citeKey,
            entryType: entryType,
            fields: fields,
            rawBibTeX: rustEntry.rawBibtex
        )
    }
}

/// Information about the Rust RIS library
public enum RustRISLibraryInfo {
    public static var isAvailable: Bool { true }
}
