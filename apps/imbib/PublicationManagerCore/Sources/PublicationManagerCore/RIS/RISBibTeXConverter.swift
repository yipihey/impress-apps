//
//  RISBibTeXConverter.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-04.
//

import Foundation
import OSLog

// MARK: - RIS ↔ BibTeX Converter

/// Bidirectional converter between RIS and BibTeX formats.
public enum RISBibTeXConverter {

    private static let logger = Logger(subsystem: "PublicationManagerCore", category: "RISBibTeXConverter")

    // MARK: - RIS → BibTeX

    /// Convert an RIS entry to BibTeX entry.
    /// - Parameter entry: The RIS entry to convert
    /// - Returns: Equivalent BibTeX entry
    public static func toBibTeX(_ entry: RISEntry) -> BibTeXEntry {
        var fields: [String: String] = [:]

        // Combine authors with " and " separator
        let authors = entry.authors
        if !authors.isEmpty {
            fields["author"] = authors.joined(separator: " and ")
        }

        // Combine editors with " and " separator
        let editors = entry.editors
        if !editors.isEmpty {
            fields["editor"] = editors.joined(separator: " and ")
        }

        // Map title
        if let title = entry.title {
            fields["title"] = title
        }

        // Map year
        if let year = entry.year {
            fields["year"] = String(year)
        }

        // Map journal/booktitle based on entry type
        if let secondaryTitle = entry.secondaryTitle {
            switch entry.type {
            case .JOUR, .EJOUR, .MGZN, .NEWS:
                fields["journal"] = secondaryTitle
            case .CHAP, .CONF, .CPAPER:
                fields["booktitle"] = secondaryTitle
            default:
                // Use journal as default for secondary title
                fields["journal"] = secondaryTitle
            }
        }

        // Map volume
        if let volume = entry.volume {
            fields["volume"] = volume
        }

        // Map issue/number
        if let issue = entry.issue {
            fields["number"] = issue
        }

        // Map pages (combine SP and EP)
        if let pages = entry.pages {
            fields["pages"] = pages
        }

        // Map DOI
        if let doi = entry.doi {
            fields["doi"] = doi
        }

        // Map abstract
        if let abstract = entry.abstract {
            fields["abstract"] = abstract
        }

        // Map keywords (combine with comma)
        let keywords = entry.keywords
        if !keywords.isEmpty {
            fields["keywords"] = keywords.joined(separator: ", ")
        }

        // Map URL (first one)
        if let url = entry.url {
            fields["url"] = url
        }

        // Map publisher
        if let publisher = entry.publisher {
            fields["publisher"] = publisher
        }

        // Map address/place
        if let place = entry.place {
            fields["address"] = place
        }

        // Map ISSN/ISBN based on type
        if let issn = entry.issn {
            switch entry.type {
            case .BOOK, .CHAP, .EDBOOK:
                fields["isbn"] = issn
            default:
                fields["issn"] = issn
            }
        }

        // Map notes
        if let notes = entry.notes {
            fields["note"] = notes
        }

        // Map additional fields from tags
        for tagValue in entry.tags {
            switch tagValue.tag {
            case .T3:  // Series title
                if fields["series"] == nil {
                    fields["series"] = tagValue.value
                }
            case .ET:  // Edition
                if fields["edition"] == nil {
                    fields["edition"] = tagValue.value
                }
            case .LA:  // Language
                if fields["language"] == nil {
                    fields["language"] = tagValue.value
                }
            case .M3:  // Type of work
                if fields["type"] == nil {
                    fields["type"] = tagValue.value
                }
            default:
                break
            }
        }

        // Generate cite key
        let citeKey = generateCiteKey(from: entry)

        return BibTeXEntry(
            citeKey: citeKey,
            entryType: entry.type.bibTeXEquivalent,
            fields: fields
        )
    }

    // MARK: - BibTeX → RIS

    /// Convert a BibTeX entry to RIS entry.
    /// - Parameter entry: The BibTeX entry to convert
    /// - Returns: Equivalent RIS entry
    public static func toRIS(_ entry: BibTeXEntry) -> RISEntry {
        var tags: [RISTagValue] = []

        // Map entry type
        let risType = RISReferenceType.from(bibTeXType: entry.entryType)

        // Split authors into separate AU tags
        for author in entry.authorList {
            tags.append(RISTagValue(tag: .AU, value: author))
        }

        // Map editors
        if let editorString = entry["editor"] {
            let editors = editorString.components(separatedBy: " and ").map { $0.trimmingCharacters(in: .whitespaces) }
            for editor in editors {
                tags.append(RISTagValue(tag: .A2, value: editor))
            }
        }

        // Map title
        if let title = entry.title {
            tags.append(RISTagValue(tag: .TI, value: title))
        }

        // Map year
        if let year = entry.year {
            tags.append(RISTagValue(tag: .PY, value: year))
        }

        // Map journal/booktitle to T2/JF
        if let journal = entry.journal {
            tags.append(RISTagValue(tag: .JF, value: journal))
            tags.append(RISTagValue(tag: .T2, value: journal))
        } else if let booktitle = entry.booktitle {
            tags.append(RISTagValue(tag: .T2, value: booktitle))
        }

        // Map volume
        if let volume = entry["volume"] {
            tags.append(RISTagValue(tag: .VL, value: volume))
        }

        // Map number
        if let number = entry["number"] {
            tags.append(RISTagValue(tag: .IS, value: number))
        }

        // Map pages (split into SP and EP)
        if let pages = entry["pages"] {
            let parts = pages.components(separatedBy: CharacterSet(charactersIn: "-–—"))
            if parts.count >= 2 {
                tags.append(RISTagValue(tag: .SP, value: parts[0].trimmingCharacters(in: .whitespaces)))
                tags.append(RISTagValue(tag: .EP, value: parts[1].trimmingCharacters(in: .whitespaces)))
            } else if parts.count == 1 {
                tags.append(RISTagValue(tag: .SP, value: parts[0].trimmingCharacters(in: .whitespaces)))
            }
        }

        // Map DOI
        if let doi = entry.doi {
            tags.append(RISTagValue(tag: .DO, value: doi))
        }

        // Map abstract
        if let abstract = entry.abstract {
            tags.append(RISTagValue(tag: .AB, value: abstract))
        }

        // Map keywords (split by comma or semicolon)
        if let keywords = entry["keywords"] {
            let keywordList = keywords.components(separatedBy: CharacterSet(charactersIn: ",;"))
            for keyword in keywordList {
                let trimmed = keyword.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    tags.append(RISTagValue(tag: .KW, value: trimmed))
                }
            }
        }

        // Map URL
        if let url = entry.url {
            tags.append(RISTagValue(tag: .UR, value: url))
        }

        // Map publisher
        if let publisher = entry["publisher"] {
            tags.append(RISTagValue(tag: .PB, value: publisher))
        }

        // Map address
        if let address = entry["address"] {
            tags.append(RISTagValue(tag: .CY, value: address))
        }

        // Map ISSN or ISBN
        if let issn = entry["issn"] {
            tags.append(RISTagValue(tag: .SN, value: issn))
        } else if let isbn = entry["isbn"] {
            tags.append(RISTagValue(tag: .SN, value: isbn))
        }

        // Map note
        if let note = entry["note"] {
            tags.append(RISTagValue(tag: .N1, value: note))
        }

        // Map series
        if let series = entry["series"] {
            tags.append(RISTagValue(tag: .T3, value: series))
        }

        // Map edition
        if let edition = entry["edition"] {
            tags.append(RISTagValue(tag: .ET, value: edition))
        }

        // Map language
        if let language = entry["language"] {
            tags.append(RISTagValue(tag: .LA, value: language))
        }

        // Map cite key to ID
        tags.append(RISTagValue(tag: .ID, value: entry.citeKey))

        return RISEntry(type: risType, tags: tags)
    }

    // MARK: - Batch Conversion

    /// Convert multiple RIS entries to BibTeX entries.
    public static func toBibTeX(_ entries: [RISEntry]) -> [BibTeXEntry] {
        entries.map { toBibTeX($0) }
    }

    /// Convert multiple BibTeX entries to RIS entries.
    public static func toRIS(_ entries: [BibTeXEntry]) -> [RISEntry] {
        entries.map { toRIS($0) }
    }

    // MARK: - Cite Key Generation

    /// Generate a cite key from an RIS entry.
    private static func generateCiteKey(from entry: RISEntry) -> String {
        // If entry has an ID, use it
        if let id = entry.referenceID, !id.isEmpty {
            return id
        }

        // Otherwise, generate: LastName + Year + FirstTitleWord
        var parts: [String] = []

        // First author last name
        if let firstAuthor = entry.authors.first {
            let lastName = extractLastName(from: firstAuthor)
            if !lastName.isEmpty {
                parts.append(lastName)
            }
        }

        // Year
        if let year = entry.year {
            parts.append(String(year))
        }

        // First significant word of title
        if let title = entry.title {
            let titleWord = extractFirstSignificantWord(from: title)
            if !titleWord.isEmpty {
                parts.append(titleWord)
            }
        }

        if parts.isEmpty {
            return "unknown"
        }

        return parts.joined()
    }

    /// Extract last name from author string.
    private static func extractLastName(from author: String) -> String {
        let trimmed = author.trimmingCharacters(in: .whitespaces)

        // Handle "Last, First" format
        if trimmed.contains(",") {
            let parts = trimmed.components(separatedBy: ",")
            return sanitizeForCiteKey(parts[0].trimmingCharacters(in: .whitespaces))
        }

        // Handle "First Last" format
        let parts = trimmed.components(separatedBy: " ")
        if let last = parts.last {
            return sanitizeForCiteKey(last)
        }

        return sanitizeForCiteKey(trimmed)
    }

    /// Extract first significant word from title.
    private static func extractFirstSignificantWord(from title: String) -> String {
        let stopWords: Set<String> = ["a", "an", "the", "on", "in", "of", "for", "to", "with", "and", "or"]

        let words = title
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }

        for word in words {
            let lowercased = word.lowercased()
            if !stopWords.contains(lowercased) && word.count > 2 {
                return sanitizeForCiteKey(word.capitalized)
            }
        }

        // Fall back to first word
        if let first = words.first {
            return sanitizeForCiteKey(first.capitalized)
        }

        return ""
    }

    /// Sanitize a string for use in cite key.
    private static func sanitizeForCiteKey(_ input: String) -> String {
        input
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }
}

// MARK: - Convenience Extensions

extension RISEntry {
    /// Convert this RIS entry to BibTeX.
    public func toBibTeX() -> BibTeXEntry {
        RISBibTeXConverter.toBibTeX(self)
    }
}

extension BibTeXEntry {
    /// Convert this BibTeX entry to RIS.
    public func toRIS() -> RISEntry {
        RISBibTeXConverter.toRIS(self)
    }
}

extension Array where Element == RISEntry {
    /// Convert all RIS entries to BibTeX.
    public func toBibTeX() -> [BibTeXEntry] {
        RISBibTeXConverter.toBibTeX(self)
    }
}

extension Array where Element == BibTeXEntry {
    /// Convert all BibTeX entries to RIS.
    public func toRIS() -> [RISEntry] {
        RISBibTeXConverter.toRIS(self)
    }
}
