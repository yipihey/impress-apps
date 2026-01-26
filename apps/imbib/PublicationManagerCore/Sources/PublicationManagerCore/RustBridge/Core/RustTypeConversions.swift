//
//  RustTypeConversions.swift
//  PublicationManagerCore
//
//  Shared type conversions between Rust (ImbibRustCore) and Swift types.
//  Eliminates duplication across RustBibTeXParser, RustRISParser,
//  RustDeduplication, and UnifiedFormatConverter.
//

import Foundation
import ImbibRustCore

// MARK: - BibTeX Entry Type Conversions

/// Extensions for converting between Swift and Rust BibTeX entry types
public enum BibTeXEntryTypeConversions {

    /// Convert a Swift entry type string to Rust BibTeXEntryType
    public static func toRust(_ entryType: String) -> ImbibRustCore.BibTeXEntryType {
        switch entryType.lowercased() {
        case "article": return .article
        case "book": return .book
        case "booklet": return .booklet
        case "inbook": return .inBook
        case "incollection": return .inCollection
        case "inproceedings", "conference": return .inProceedings
        case "manual": return .manual
        case "mastersthesis": return .mastersThesis
        case "misc": return .misc
        case "phdthesis": return .phdThesis
        case "proceedings": return .proceedings
        case "techreport": return .techReport
        case "unpublished": return .unpublished
        case "online": return .online
        case "software": return .software
        case "dataset": return .dataset
        default: return .unknown
        }
    }

    /// Convert a Rust BibTeXEntryType to Swift entry type string
    public static func fromRust(_ rustType: ImbibRustCore.BibTeXEntryType) -> String {
        switch rustType {
        case .article: return "article"
        case .book: return "book"
        case .booklet: return "booklet"
        case .inBook: return "inbook"
        case .inCollection: return "incollection"
        case .inProceedings: return "inproceedings"
        case .manual: return "manual"
        case .mastersThesis: return "mastersthesis"
        case .misc: return "misc"
        case .phdThesis: return "phdthesis"
        case .proceedings: return "proceedings"
        case .techReport: return "techreport"
        case .unpublished: return "unpublished"
        case .online: return "online"
        case .software: return "software"
        case .dataset: return "dataset"
        case .unknown: return "misc"
        }
    }
}

// MARK: - BibTeX Entry Conversions

/// Extensions for converting between Swift and Rust BibTeX entries
public enum BibTeXEntryConversions {

    /// Convert a Swift BibTeXEntry to Rust BibTeXEntry
    public static func toRust(_ entry: BibTeXEntry) -> ImbibRustCore.BibTeXEntry {
        let rustType = BibTeXEntryTypeConversions.toRust(entry.entryType)
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

    /// Convert a Rust BibTeXEntry to Swift BibTeXEntry
    public static func fromRust(_ rustEntry: ImbibRustCore.BibTeXEntry, decodeLaTeX: Bool = false) -> BibTeXEntry {
        var fields: [String: String] = [:]
        for field in rustEntry.fields {
            var value = field.value
            if decodeLaTeX {
                value = LaTeXDecoder.decode(value)
            }
            fields[field.key.lowercased()] = value
        }

        let entryType = BibTeXEntryTypeConversions.fromRust(rustEntry.entryType)

        return BibTeXEntry(
            citeKey: rustEntry.citeKey,
            entryType: entryType,
            fields: fields,
            rawBibTeX: rustEntry.rawBibtex
        )
    }
}

// MARK: - RIS Type Conversions

/// Extensions for converting between Swift and Rust RIS types
public enum RISTypeConversions {

    /// Convert a Rust RisType to Swift RISReferenceType
    public static func fromRust(_ rustType: ImbibRustCore.RisType) -> RISReferenceType {
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

    /// Convert a Swift RISReferenceType to Rust RisType
    public static func toRust(_ type: RISReferenceType) -> ImbibRustCore.RisType {
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
}

// MARK: - RIS Entry Conversions

/// Extensions for converting between Swift and Rust RIS entries
public enum RISEntryConversions {

    /// Convert a Swift RISEntry to Rust RisEntry
    public static func toRust(_ entry: RISEntry) -> ImbibRustCore.RisEntry {
        let rustType = RISTypeConversions.toRust(entry.type)
        let rustTags = entry.tags.map { tag in
            ImbibRustCore.RisTag(tag: tag.tag.rawValue, value: tag.value)
        }
        return ImbibRustCore.RisEntry(
            entryType: rustType,
            tags: rustTags,
            rawRis: entry.rawRIS
        )
    }

    /// Convert a Rust RisEntry to Swift RISEntry
    public static func fromRust(_ rustEntry: ImbibRustCore.RisEntry) -> RISEntry {
        let swiftType = RISTypeConversions.fromRust(rustEntry.entryType)
        let swiftTags = rustEntry.tags.compactMap { tag -> RISTagValue? in
            guard let risTag = RISTag.from(tag.tag) else { return nil }
            return RISTagValue(tag: risTag, value: tag.value)
        }
        return RISEntry(type: swiftType, tags: swiftTags, rawRIS: rustEntry.rawRis)
    }
}
