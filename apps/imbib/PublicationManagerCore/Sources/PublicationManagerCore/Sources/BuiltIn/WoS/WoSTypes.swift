//
//  WoSTypes.swift
//  PublicationManagerCore
//
//  Types for parsing Web of Science API responses.
//  Based on Web of Science Starter API v2.
//

import Foundation

// MARK: - WoS Search Response

/// Top-level response from WoS search endpoint.
public struct WoSSearchResponse: Decodable, Sendable {
    public let queryResult: WoSQueryResult
}

/// Query result container with metadata and records.
public struct WoSQueryResult: Decodable, Sendable {
    public let queryId: String?
    public let recordsSearched: Int
    public let recordsFound: Int
    public let records: [WoSRecord]?
}

// MARK: - WoS Record

/// A single Web of Science record.
public struct WoSRecord: Decodable, Sendable {
    public let uid: String
    public let title: WoSTitle
    public let types: [String]?
    public let sourceTypes: [String]?
    public let source: WoSJournalSource?
    public let names: WoSNames?
    public let links: WoSLinks?
    public let citations: WoSCitationInfo?
    public let identifiers: WoSIdentifiers?
    public let keywords: WoSKeywords?

    /// UT (Unique Title) identifier extracted from uid
    public var ut: String {
        // uid format: "WOS:000123456789012"
        if uid.hasPrefix("WOS:") {
            return String(uid.dropFirst(4))
        }
        return uid
    }
}

// MARK: - WoS Title

public struct WoSTitle: Decodable, Sendable {
    public let value: String
}

// MARK: - WoS Source (Journal Info)

public struct WoSJournalSource: Decodable, Sendable {
    public let sourceTitle: String?
    public let publishYear: Int?
    public let publishMonth: String?
    public let volume: String?
    public let issue: String?
    public let pages: WoSPages?
    public let articleNo: String?
}

public struct WoSPages: Decodable, Sendable {
    public let range: String?
    public let begin: String?
    public let end: String?
    public let count: Int?
}

// MARK: - WoS Names (Authors)

public struct WoSNames: Decodable, Sendable {
    public let authors: [WoSAuthor]?
    public let inventors: [WoSAuthor]?
}

public struct WoSAuthor: Decodable, Sendable {
    public let displayName: String
    public let wosStandard: String?
    public let firstName: String?
    public let lastName: String?
    public let orcid: String?
    public let researcherId: String?
}

// MARK: - WoS Links

public struct WoSLinks: Decodable, Sendable {
    public let record: String?
    public let references: String?
    public let related: String?
}

// MARK: - WoS Citation Info

public struct WoSCitationInfo: Decodable, Sendable {
    public let count: Int?
}

// MARK: - WoS Identifiers

public struct WoSIdentifiers: Decodable, Sendable {
    public let doi: String?
    public let issn: String?
    public let eissn: String?
    public let isbn: String?
    public let pmid: String?
}

// MARK: - WoS Keywords

public struct WoSKeywords: Decodable, Sendable {
    public let authorKeywords: [String]?
    public let keywordsPlus: [String]?
}

// MARK: - WoS Abstract Response

/// Response from fetching a single record with abstract.
public struct WoSRecordDetailResponse: Decodable, Sendable {
    public let uid: String
    public let title: WoSTitle
    public let types: [String]?
    public let sourceTypes: [String]?
    public let source: WoSJournalSource?
    public let names: WoSNames?
    public let links: WoSLinks?
    public let citations: WoSCitationInfo?
    public let identifiers: WoSIdentifiers?
    public let keywords: WoSKeywords?
    public let `static`: WoSStaticData?
}

public struct WoSStaticData: Decodable, Sendable {
    public let fullrecord_metadata: WoSFullRecordMetadata?
}

public struct WoSFullRecordMetadata: Decodable, Sendable {
    public let abstracts: WoSAbstracts?
}

public struct WoSAbstracts: Decodable, Sendable {
    public let abstractText: [WoSAbstractText]?

    enum CodingKeys: String, CodingKey {
        case abstractText = "abstract"
    }
}

public struct WoSAbstractText: Decodable, Sendable {
    public let value: String
}

// MARK: - WoS References Response

/// Response from the references endpoint.
public struct WoSReferencesResponse: Decodable, Sendable {
    public let queryResult: WoSReferencesQueryResult
}

public struct WoSReferencesQueryResult: Decodable, Sendable {
    public let queryId: String?
    public let recordsFound: Int
    public let references: [WoSReference]?
}

public struct WoSReference: Decodable, Sendable {
    public let uid: String?
    public let citedTitle: String?
    public let citedWork: String?
    public let citedAuthor: String?
    public let year: String?
    public let page: String?
    public let volume: String?
    public let doi: String?
}

// MARK: - WoS Citing Articles Response

/// Response from the citing articles endpoint.
public struct WoSCitingResponse: Decodable, Sendable {
    public let queryResult: WoSQueryResult
}

// MARK: - WoS Related Records Response

/// Response from the related records endpoint.
public struct WoSRelatedResponse: Decodable, Sendable {
    public let relatedRecords: [WoSRecord]?
}

// MARK: - WoS BibTeX Response

/// BibTeX export response from WoS.
public struct WoSBibTeXResponse: Decodable, Sendable {
    public let bibtex: String
}

// MARK: - WoS RIS Response

/// RIS export response from WoS.
public struct WoSRISResponse: Decodable, Sendable {
    public let ris: String
}

// MARK: - WoS Error Response

/// Error response from WoS API.
public struct WoSErrorResponse: Decodable, Sendable {
    public let error: WoSError
}

public struct WoSError: Decodable, Sendable {
    public let code: String
    public let message: String
}

// MARK: - WoS Entry Type Mapping

/// Maps WoS document types to BibTeX entry types.
public enum WoSEntryType: String, Sendable {
    case article = "Article"
    case review = "Review"
    case book = "Book"
    case bookChapter = "Book Chapter"
    case proceedings = "Proceedings Paper"
    case editorial = "Editorial Material"
    case letter = "Letter"
    case correction = "Correction"
    case meeting = "Meeting Abstract"
    case news = "News Item"
    case dataSet = "Data Set"
    case other

    public init(wosType: String) {
        switch wosType.lowercased() {
        case "article": self = .article
        case "review": self = .review
        case "book": self = .book
        case "book chapter": self = .bookChapter
        case "proceedings paper": self = .proceedings
        case "editorial material": self = .editorial
        case "letter": self = .letter
        case "correction": self = .correction
        case "meeting abstract": self = .meeting
        case "news item": self = .news
        case "data set": self = .dataSet
        default: self = .other
        }
    }

    public var bibtexType: String {
        switch self {
        case .article, .review, .editorial, .letter, .correction, .news:
            return "article"
        case .book:
            return "book"
        case .bookChapter:
            return "incollection"
        case .proceedings, .meeting:
            return "inproceedings"
        case .dataSet:
            return "misc"
        case .other:
            return "article"
        }
    }

    public var risType: String {
        switch self {
        case .article, .review, .editorial, .letter, .correction, .news:
            return "JOUR"
        case .book:
            return "BOOK"
        case .bookChapter:
            return "CHAP"
        case .proceedings, .meeting:
            return "CONF"
        case .dataSet:
            return "DATA"
        case .other:
            return "GEN"
        }
    }
}

// MARK: - WoS Query Fields

/// Known query field codes for WoS advanced search.
public enum WoSQueryField: String, Sendable, CaseIterable {
    case topic = "TS"           // Topic search (title, abstract, keywords)
    case title = "TI"           // Title
    case author = "AU"          // Author
    case authorIdentifier = "AI" // Author identifier (ORCID, etc.)
    case groupAuthor = "GP"     // Group author
    case doi = "DO"             // DOI
    case year = "PY"            // Publication year
    case source = "SO"          // Source (journal name)
    case address = "AD"         // Address
    case organization = "OG"    // Organization
    case fundingAgency = "FO"   // Funding agency
    case grantNumber = "FG"     // Funding grant number
    case publicationType = "DT" // Document type
    case language = "LA"        // Language
    case accessionNumber = "UT" // UT (Unique Title)

    public var displayName: String {
        switch self {
        case .topic: return "Topic"
        case .title: return "Title"
        case .author: return "Author"
        case .authorIdentifier: return "Author ID"
        case .groupAuthor: return "Group Author"
        case .doi: return "DOI"
        case .year: return "Year"
        case .source: return "Journal"
        case .address: return "Address"
        case .organization: return "Organization"
        case .fundingAgency: return "Funding Agency"
        case .grantNumber: return "Grant Number"
        case .publicationType: return "Document Type"
        case .language: return "Language"
        case .accessionNumber: return "Accession Number"
        }
    }

    /// Example usage for this field
    public var example: String {
        switch self {
        case .topic: return "TS=quantum computing"
        case .title: return "TI=neural network"
        case .author: return "AU=Einstein, Albert"
        case .authorIdentifier: return "AI=0000-0001-2345-6789"
        case .groupAuthor: return "GP=ATLAS Collaboration"
        case .doi: return "DO=10.1038/nature12373"
        case .year: return "PY=2020 or PY=2020-2024"
        case .source: return "SO=Nature"
        case .address: return "AD=Stanford University"
        case .organization: return "OG=MIT"
        case .fundingAgency: return "FO=NSF"
        case .grantNumber: return "FG=1234567"
        case .publicationType: return "DT=Article"
        case .language: return "LA=English"
        case .accessionNumber: return "UT=000123456789012"
        }
    }
}
