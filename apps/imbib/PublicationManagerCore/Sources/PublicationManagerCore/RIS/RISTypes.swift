//
//  RISTypes.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-04.
//

import Foundation

// MARK: - RIS Reference Type

/// RIS reference types (TY tag values).
/// Based on the RIS specification from EndNote and common extensions.
public enum RISReferenceType: String, CaseIterable, Sendable, Equatable {
    // Common types
    case JOUR   // Journal Article
    case BOOK   // Book
    case CHAP   // Book Chapter
    case CONF   // Conference Proceeding
    case THES   // Thesis/Dissertation
    case RPRT   // Report
    case UNPB   // Unpublished Work
    case GEN    // Generic
    case ELEC   // Electronic Source
    case NEWS   // Newspaper Article

    // Extended types
    case ABST   // Abstract
    case ADVS   // Audiovisual Material
    case ART    // Art Work
    case BILL   // Bill
    case BLOG   // Blog
    case CASE   // Legal Case
    case CLSWK  // Classical Work
    case COMP   // Computer Program
    case CPAPER // Conference Paper
    case CTLG   // Catalog
    case DATA   // Dataset
    case DBASE  // Online Database
    case DICT   // Dictionary
    case EDBOOK // Edited Book
    case EJOUR  // Electronic Journal
    case ENCYC  // Encyclopedia
    case EQUA   // Equation
    case FIGURE // Figure
    case GOVDOC // Government Document
    case GRANT  // Grant
    case HEAR   // Hearing
    case ICOMM  // Internet Communication
    case INPR   // In Press
    case JFULL  // Journal (Full)
    case LEGAL  // Legal Rule/Regulation
    case MANSCPT // Manuscript
    case MAP    // Map
    case MGZN   // Magazine Article
    case MPCT   // Motion Picture
    case MULTI  // Online Multimedia
    case MUSIC  // Music Score
    case PAMP   // Pamphlet
    case PAT    // Patent
    case PCOMM  // Personal Communication
    case PRESS  // Press Release
    case SLIDE  // Slide
    case SOUND  // Sound Recording
    case STAND  // Standard
    case STAT   // Statute
    case STD    // Standard (alternate)
    case UNBILL // Unenacted Bill
    case VIDEO  // Video Recording
    case WEB    // Web Page

    /// Display name for the reference type.
    public var displayName: String {
        switch self {
        case .JOUR: return "Journal Article"
        case .BOOK: return "Book"
        case .CHAP: return "Book Chapter"
        case .CONF: return "Conference Proceeding"
        case .THES: return "Thesis/Dissertation"
        case .RPRT: return "Report"
        case .UNPB: return "Unpublished Work"
        case .GEN: return "Generic"
        case .ELEC: return "Electronic Source"
        case .NEWS: return "Newspaper Article"
        case .ABST: return "Abstract"
        case .ADVS: return "Audiovisual Material"
        case .ART: return "Art Work"
        case .BILL: return "Bill"
        case .BLOG: return "Blog"
        case .CASE: return "Legal Case"
        case .CLSWK: return "Classical Work"
        case .COMP: return "Computer Program"
        case .CPAPER: return "Conference Paper"
        case .CTLG: return "Catalog"
        case .DATA: return "Dataset"
        case .DBASE: return "Online Database"
        case .DICT: return "Dictionary"
        case .EDBOOK: return "Edited Book"
        case .EJOUR: return "Electronic Journal"
        case .ENCYC: return "Encyclopedia"
        case .EQUA: return "Equation"
        case .FIGURE: return "Figure"
        case .GOVDOC: return "Government Document"
        case .GRANT: return "Grant"
        case .HEAR: return "Hearing"
        case .ICOMM: return "Internet Communication"
        case .INPR: return "In Press"
        case .JFULL: return "Journal (Full)"
        case .LEGAL: return "Legal Rule/Regulation"
        case .MANSCPT: return "Manuscript"
        case .MAP: return "Map"
        case .MGZN: return "Magazine Article"
        case .MPCT: return "Motion Picture"
        case .MULTI: return "Online Multimedia"
        case .MUSIC: return "Music Score"
        case .PAMP: return "Pamphlet"
        case .PAT: return "Patent"
        case .PCOMM: return "Personal Communication"
        case .PRESS: return "Press Release"
        case .SLIDE: return "Slide"
        case .SOUND: return "Sound Recording"
        case .STAND: return "Standard"
        case .STAT: return "Statute"
        case .STD: return "Standard (alternate)"
        case .UNBILL: return "Unenacted Bill"
        case .VIDEO: return "Video Recording"
        case .WEB: return "Web Page"
        }
    }

    /// Equivalent BibTeX entry type.
    public var bibTeXEquivalent: String {
        switch self {
        case .JOUR, .EJOUR, .MGZN, .NEWS: return "article"
        case .BOOK, .EDBOOK, .CLSWK: return "book"
        case .CHAP: return "incollection"
        case .CONF, .CPAPER: return "inproceedings"
        case .THES: return "phdthesis"
        case .RPRT, .GOVDOC: return "techreport"
        case .UNPB, .MANSCPT, .INPR: return "unpublished"
        case .PAT: return "patent"
        case .COMP: return "software"
        case .WEB, .ELEC, .BLOG, .DBASE: return "online"
        default: return "misc"
        }
    }

    /// Create from BibTeX entry type.
    public static func from(bibTeXType: String) -> RISReferenceType {
        switch bibTeXType.lowercased() {
        case "article": return .JOUR
        case "book": return .BOOK
        case "incollection", "inbook": return .CHAP
        case "inproceedings", "conference": return .CONF
        case "phdthesis": return .THES
        case "mastersthesis": return .THES
        case "techreport": return .RPRT
        case "unpublished": return .UNPB
        case "manual": return .GEN
        case "proceedings": return .CONF
        case "patent": return .PAT
        case "software": return .COMP
        case "online", "electronic": return .ELEC
        case "misc": return .GEN
        default: return .GEN
        }
    }
}

// MARK: - RIS Tag

/// RIS tag identifiers.
/// Based on the RIS specification with common extensions.
public enum RISTag: String, CaseIterable, Sendable, Equatable {
    // Required tags
    case TY     // Reference type (required, must be first)
    case ER     // End of record (required, must be last)

    // Author tags (repeatable)
    case AU     // Primary author
    case A1     // Primary author (alternate)
    case A2     // Secondary author (editor)
    case A3     // Tertiary author (series editor)
    case A4     // Subsidiary author

    // Title tags
    case TI     // Primary title
    case T1     // Primary title (alternate)
    case T2     // Secondary title (journal, book title)
    case T3     // Tertiary title (series)
    case BT     // Book title
    case CT     // Caption title
    case ST     // Short title

    // Date tags
    case PY     // Publication year
    case Y1     // Primary date
    case Y2     // Access date
    case DA     // Date

    // Volume/issue/pages
    case VL     // Volume
    case IS     // Issue number
    case SP     // Start page
    case EP     // End page

    // Identifiers
    case DO     // DOI
    case SN     // ISSN/ISBN
    case AN     // Accession number
    case ID     // Reference ID

    // URLs
    case UR     // URL (repeatable)
    case L1     // File attachment 1
    case L2     // File attachment 2
    case L3     // Related records
    case L4     // Image(s)
    case LK     // Website link

    // Abstract/notes
    case AB     // Abstract
    case N1     // Notes
    case N2     // Abstract (alternate)

    // Keywords
    case KW     // Keywords (repeatable)

    // Publisher/source
    case PB     // Publisher
    case CY     // Place published (city)
    case AD     // Author address
    case PP     // Publishing place

    // Other fields
    case ET     // Edition
    case LA     // Language
    case M1     // Miscellaneous 1
    case M2     // Miscellaneous 2
    case M3     // Type of work
    case OP     // Original publication
    case RI     // Reviewed item
    case RN     // Research notes
    case RP     // Reprint status
    case SE     // Section
    case C1     // Custom 1
    case C2     // Custom 2
    case C3     // Custom 3
    case C4     // Custom 4
    case C5     // Custom 5
    case C6     // Custom 6
    case C7     // Custom 7
    case C8     // Custom 8
    case CA     // Caption
    case CN     // Call number
    case DB     // Database
    case DP     // Database provider
    case ED     // Editor
    case J1     // Journal abbreviation 1
    case J2     // Journal abbreviation 2
    case JA     // Journal abbreviation
    case JF     // Journal full name
    case JO     // Journal name
    case NV     // Number of volumes
    case U1     // User-defined 1
    case U2     // User-defined 2
    case U3     // User-defined 3
    case U4     // User-defined 4
    case U5     // User-defined 5

    /// Whether this tag can appear multiple times in a record.
    public var allowsMultiple: Bool {
        switch self {
        case .AU, .A1, .A2, .A3, .A4, .KW, .UR, .L1, .L2, .L3, .L4:
            return true
        default:
            return false
        }
    }

    /// Whether this tag is required.
    public var isRequired: Bool {
        self == .TY || self == .ER
    }

    /// Display name for the tag.
    public var displayName: String {
        switch self {
        case .TY: return "Reference Type"
        case .ER: return "End of Record"
        case .AU, .A1: return "Author"
        case .A2: return "Editor"
        case .A3: return "Series Editor"
        case .A4: return "Subsidiary Author"
        case .TI, .T1: return "Title"
        case .T2: return "Secondary Title"
        case .T3: return "Series Title"
        case .BT: return "Book Title"
        case .CT: return "Caption Title"
        case .ST: return "Short Title"
        case .PY, .Y1: return "Year"
        case .Y2: return "Access Date"
        case .DA: return "Date"
        case .VL: return "Volume"
        case .IS: return "Issue"
        case .SP: return "Start Page"
        case .EP: return "End Page"
        case .DO: return "DOI"
        case .SN: return "ISSN/ISBN"
        case .AN: return "Accession Number"
        case .ID: return "Reference ID"
        case .UR: return "URL"
        case .L1, .L2, .L3, .L4: return "File Attachment"
        case .LK: return "Website Link"
        case .AB, .N2: return "Abstract"
        case .N1: return "Notes"
        case .KW: return "Keyword"
        case .PB: return "Publisher"
        case .CY, .PP: return "Place Published"
        case .AD: return "Author Address"
        case .ET: return "Edition"
        case .LA: return "Language"
        case .JF, .JO: return "Journal Name"
        case .JA, .J1, .J2: return "Journal Abbreviation"
        default: return rawValue
        }
    }

    /// Corresponding BibTeX field name, if applicable.
    public var bibTeXField: String? {
        switch self {
        case .AU, .A1: return "author"
        case .A2, .ED: return "editor"
        case .TI, .T1: return "title"
        case .T2, .JF, .JO: return "journal"
        case .BT: return "booktitle"
        case .T3: return "series"
        case .PY, .Y1: return "year"
        case .VL: return "volume"
        case .IS: return "number"
        case .SP, .EP: return nil  // Combined into "pages"
        case .DO: return "doi"
        case .SN: return nil  // Could be "issn" or "isbn"
        case .UR: return "url"
        case .AB, .N2: return "abstract"
        case .N1: return "note"
        case .KW: return "keywords"
        case .PB: return "publisher"
        case .CY, .PP: return "address"
        case .ET: return "edition"
        case .LA: return "language"
        default: return nil
        }
    }

    /// Create from raw string value (case-insensitive).
    public static func from(_ rawValue: String) -> RISTag? {
        RISTag(rawValue: rawValue.uppercased())
    }
}

// MARK: - RIS Tag Value

/// A single tag-value pair in an RIS entry.
public struct RISTagValue: Sendable, Equatable {
    public let tag: RISTag
    public let value: String

    public init(tag: RISTag, value: String) {
        self.tag = tag
        self.value = value
    }
}

// MARK: - RIS Entry

/// A single RIS bibliographic entry.
public struct RISEntry: Sendable, Equatable, Identifiable {

    /// Unique identifier (reference ID if available, otherwise generated).
    public var id: String {
        referenceID ?? _generatedID
    }

    private let _generatedID: String

    /// Reference type (required).
    public var type: RISReferenceType

    /// All tags in order (preserves duplicates for repeatable tags).
    public var tags: [RISTagValue]

    /// Original raw RIS text for round-trip preservation.
    public var rawRIS: String?

    // MARK: - Initialization

    public init(
        type: RISReferenceType,
        tags: [RISTagValue] = [],
        rawRIS: String? = nil
    ) {
        self.type = type
        self.tags = tags
        self.rawRIS = rawRIS
        self._generatedID = UUID().uuidString
    }

    /// Initialize with tag tuples for convenience.
    public init(
        type: RISReferenceType,
        tags: [(RISTag, String)],
        rawRIS: String? = nil
    ) {
        self.type = type
        self.tags = tags.map { RISTagValue(tag: $0.0, value: $0.1) }
        self.rawRIS = rawRIS
        self._generatedID = UUID().uuidString
    }

    // MARK: - Convenience Accessors

    /// Get first value for a tag.
    public func firstValue(for tag: RISTag) -> String? {
        tags.first { $0.tag == tag }?.value
    }

    /// Get all values for a tag (for repeatable tags).
    public func allValues(for tag: RISTag) -> [String] {
        tags.filter { $0.tag == tag }.map(\.value)
    }

    /// Reference ID (ID tag).
    public var referenceID: String? {
        firstValue(for: .ID)
    }

    /// Primary title.
    public var title: String? {
        firstValue(for: .TI) ?? firstValue(for: .T1)
    }

    /// All authors (AU and A1 tags combined).
    public var authors: [String] {
        allValues(for: .AU) + allValues(for: .A1)
    }

    /// All editors (A2 and ED tags combined).
    public var editors: [String] {
        allValues(for: .A2) + allValues(for: .ED)
    }

    /// Publication year.
    public var year: Int? {
        guard let yearString = firstValue(for: .PY) ?? firstValue(for: .Y1) else {
            return nil
        }
        // RIS date format: YYYY/MM/DD/other info
        let components = yearString.components(separatedBy: "/")
        if let first = components.first {
            return Int(first.trimmingCharacters(in: .whitespaces))
        }
        return Int(yearString.trimmingCharacters(in: .whitespaces))
    }

    /// Secondary title (journal name or book title).
    public var secondaryTitle: String? {
        firstValue(for: .T2) ?? firstValue(for: .JF) ?? firstValue(for: .JO)
    }

    /// Volume.
    public var volume: String? {
        firstValue(for: .VL)
    }

    /// Issue number.
    public var issue: String? {
        firstValue(for: .IS)
    }

    /// Start page.
    public var startPage: String? {
        firstValue(for: .SP)
    }

    /// End page.
    public var endPage: String? {
        firstValue(for: .EP)
    }

    /// Combined page range (e.g., "100-115").
    public var pages: String? {
        guard let sp = startPage else { return nil }
        guard let ep = endPage else { return sp }
        return "\(sp)-\(ep)"
    }

    /// DOI.
    public var doi: String? {
        firstValue(for: .DO)
    }

    /// Abstract.
    public var abstract: String? {
        firstValue(for: .AB) ?? firstValue(for: .N2)
    }

    /// All keywords.
    public var keywords: [String] {
        allValues(for: .KW)
    }

    /// All URLs.
    public var urls: [String] {
        allValues(for: .UR)
    }

    /// Primary URL.
    public var url: String? {
        firstValue(for: .UR)
    }

    /// Publisher.
    public var publisher: String? {
        firstValue(for: .PB)
    }

    /// Place published.
    public var place: String? {
        firstValue(for: .CY) ?? firstValue(for: .PP)
    }

    /// ISSN or ISBN.
    public var issn: String? {
        firstValue(for: .SN)
    }

    /// Notes.
    public var notes: String? {
        firstValue(for: .N1)
    }

    // MARK: - Mutating Methods

    /// Add a tag value.
    public mutating func addTag(_ tag: RISTag, value: String) {
        tags.append(RISTagValue(tag: tag, value: value))
    }

    /// Set a tag value (replaces existing if not repeatable, appends if repeatable).
    public mutating func setTag(_ tag: RISTag, value: String) {
        if tag.allowsMultiple {
            tags.append(RISTagValue(tag: tag, value: value))
        } else {
            // Remove existing and append new
            tags.removeAll { $0.tag == tag }
            tags.append(RISTagValue(tag: tag, value: value))
        }
    }

    /// Remove all occurrences of a tag.
    public mutating func removeTag(_ tag: RISTag) {
        tags.removeAll { $0.tag == tag }
    }
}

// MARK: - RIS Item

/// An item parsed from RIS content (entry or comment).
public enum RISItem: Sendable, Equatable {
    case entry(RISEntry)
    case comment(String)
}

// MARK: - RIS Error

/// Errors that can occur during RIS parsing or export.
public enum RISError: Error, LocalizedError, Sendable {
    case missingTypeTag
    case missingEndTag
    case invalidTag(String)
    case invalidReferenceType(String)
    case emptyContent
    case parseError(String)

    public var errorDescription: String? {
        switch self {
        case .missingTypeTag:
            return "RIS entry is missing TY (type) tag"
        case .missingEndTag:
            return "RIS entry is missing ER (end) tag"
        case .invalidTag(let tag):
            return "Invalid RIS tag: \(tag)"
        case .invalidReferenceType(let type):
            return "Invalid RIS reference type: \(type)"
        case .emptyContent:
            return "RIS content is empty"
        case .parseError(let message):
            return "RIS parse error: \(message)"
        }
    }
}
