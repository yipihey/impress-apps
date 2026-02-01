//
//  BibTeXFieldNames.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-29.
//

import Foundation

/// Standard BibTeX field names as constants to prevent typos
/// and enable IDE autocomplete across the codebase.
public enum BibTeXFieldNames {

    // MARK: - Core Fields

    public static let author = "author"
    public static let title = "title"
    public static let year = "year"

    // MARK: - Venue Fields

    public static let journal = "journal"
    public static let booktitle = "booktitle"
    public static let publisher = "publisher"

    // MARK: - Article Fields

    public static let volume = "volume"
    public static let number = "number"
    public static let pages = "pages"

    // MARK: - Identifiers

    public static let doi = "doi"
    public static let url = "url"
    public static let isbn = "isbn"
    public static let issn = "issn"
    public static let eprint = "eprint"
    public static let arxivid = "arxivid"
    public static let bibcode = "bibcode"
    public static let pmid = "pmid"
    public static let archiveprefix = "archiveprefix"
    public static let adsurl = "adsurl"

    // MARK: - Metadata

    public static let abstract = "abstract"
    public static let keywords = "keywords"
    public static let note = "note"
    public static let editor = "editor"
    public static let series = "series"
    public static let edition = "edition"
    public static let address = "address"
    public static let month = "month"
    public static let language = "language"

    // MARK: - Entry Type Specific

    public static let type = "type"
    public static let institution = "institution"
    public static let school = "school"
    public static let organization = "organization"
    public static let chapter = "chapter"
    public static let howpublished = "howpublished"

    // MARK: - BibDesk Extensions

    public static let bdskFilePrefix = "bdsk-file-"
    public static let bdskUrlPrefix = "bdsk-url-"

    // MARK: - Field Groups

    /// Fields that should appear first in exported BibTeX, in order
    public static let defaultFieldOrder: [String] = [
        author, title, journal, booktitle,
        year, month, volume, number, pages,
        publisher, address, edition,
        editor, series, chapter, type,
        school, institution, organization,
        doi, url, eprint, arxivid,
        isbn, issn, pmid, bibcode,
        abstract, keywords, note
    ]

    /// Numeric fields that don't need braces in BibTeX output
    public static let numericFields: Set<String> = [
        year, volume, number, pages
    ]

    /// Scalar fields for merge operations (last-writer-wins)
    public static let scalarFields: [String] = [
        title, year, abstract, doi, url, "entryType", "rawBibTeX", "rawFields",
        "citationCount", "referenceCount", "enrichmentSource", "enrichmentDate",
        "originalSourceID", "pdfLinksJSON", "webURL", "semanticScholarID", "openAlexID",
        "arxivIDNormalized", "bibcodeNormalized", "isRead", "dateRead", "isStarred",
        "hasPDFDownloaded", "pdfDownloadDate", "dateAddedToInbox"
    ]
}

// MARK: - Type Alias for Convenience

public typealias BibField = BibTeXFieldNames
