//
//  WoSResponseParser.swift
//  PublicationManagerCore
//
//  Converts Web of Science API responses to domain types.
//

import Foundation

// MARK: - WoS Response Parser

/// Parser for Web of Science API responses.
public enum WoSResponseParser {

    // MARK: - Search Results

    /// Parse search response to SearchResult array.
    public static func parseSearchResults(from data: Data) throws -> (results: [SearchResult], totalFound: Int) {
        let decoder = JSONDecoder()
        let response = try decoder.decode(WoSSearchResponse.self, from: data)

        let results = response.queryResult.records?.map { record in
            searchResult(from: record)
        } ?? []

        return (results, response.queryResult.recordsFound)
    }

    /// Convert a single WoS record to SearchResult.
    public static func searchResult(from record: WoSRecord) -> SearchResult {
        // Extract authors
        let authors: [String] = record.names?.authors?.map { author -> String in
            // Prefer "Last, First" format
            if let lastName = author.lastName, let firstName = author.firstName {
                return "\(lastName), \(firstName)"
            }
            return author.displayName
        } ?? []

        // Build PDF links
        var pdfLinks: [PDFLink] = []
        if let doi = record.identifiers?.doi,
           let url = URL(string: "https://doi.org/\(doi)") {
            pdfLinks.append(PDFLink(url: url, type: .publisher, sourceID: "wos"))
        }

        // Web URL for the record
        var webURL: URL?
        if let recordLink = record.links?.record {
            webURL = URL(string: recordLink)
        }

        return SearchResult(
            id: record.ut,
            sourceID: "wos",
            title: record.title.value,
            authors: authors,
            year: record.source?.publishYear,
            venue: record.source?.sourceTitle,
            abstract: nil,  // Abstract requires separate fetch
            doi: record.identifiers?.doi,
            arxivID: nil,
            pmid: record.identifiers?.pmid,
            bibcode: nil,
            pdfLinks: pdfLinks,
            webURL: webURL,
            bibtexURL: nil
        )
    }

    // MARK: - Paper Stubs (for References/Citations)

    /// Parse references response to PaperStub array.
    public static func parseReferences(from data: Data) throws -> [PaperStub] {
        let decoder = JSONDecoder()
        let response = try decoder.decode(WoSReferencesResponse.self, from: data)

        return response.queryResult.references?.compactMap { ref in
            // References have limited data
            guard let title = ref.citedTitle, !title.isEmpty else {
                return nil
            }

            let authors: [String] = {
                if let author = ref.citedAuthor {
                    return [author]
                }
                return []
            }()

            let year: Int? = {
                if let yearStr = ref.year {
                    return Int(yearStr)
                }
                return nil
            }()

            return PaperStub(
                id: ref.uid ?? ref.doi ?? UUID().uuidString,
                title: title,
                authors: authors,
                year: year,
                venue: ref.citedWork,
                doi: ref.doi
            )
        } ?? []
    }

    /// Parse citing articles response to PaperStub array.
    public static func parseCitingArticles(from data: Data) throws -> [PaperStub] {
        let decoder = JSONDecoder()
        let response = try decoder.decode(WoSCitingResponse.self, from: data)

        return response.queryResult.records?.map { record in
            paperStub(from: record)
        } ?? []
    }

    /// Parse related records response to PaperStub array.
    public static func parseRelatedRecords(from data: Data) throws -> [PaperStub] {
        let decoder = JSONDecoder()
        let response = try decoder.decode(WoSRelatedResponse.self, from: data)

        return response.relatedRecords?.map { record in
            paperStub(from: record)
        } ?? []
    }

    /// Convert a WoS record to PaperStub.
    private static func paperStub(from record: WoSRecord) -> PaperStub {
        let authors: [String] = record.names?.authors?.map { author -> String in
            if let lastName = author.lastName, let firstName = author.firstName {
                return "\(lastName), \(firstName)"
            }
            return author.displayName
        } ?? []

        return PaperStub(
            id: record.ut,
            title: record.title.value,
            authors: authors,
            year: record.source?.publishYear,
            venue: record.source?.sourceTitle,
            doi: record.identifiers?.doi,
            citationCount: record.citations?.count
        )
    }

    // MARK: - BibTeX Generation

    /// Generate a BibTeX entry from a WoS record.
    public static func generateBibTeX(from record: WoSRecord) -> BibTeXEntry {
        // Determine entry type
        let entryType = WoSEntryType(wosType: record.types?.first ?? "article").bibtexType

        // Generate cite key: LastNameYearFirstWord
        let firstAuthorLastName = record.names?.authors?.first.flatMap { author in
            author.lastName ?? author.displayName.components(separatedBy: ",").first
        }?.replacingOccurrences(of: " ", with: "") ?? "Unknown"

        let year = record.source?.publishYear ?? 0
        let titleWord = record.title.value
            .components(separatedBy: .whitespaces)
            .first { $0.count > 3 && !["the", "a", "an", "of", "in", "on", "for", "and", "with"].contains($0.lowercased()) }?
            .filter { $0.isLetter }
            .capitalized ?? "Paper"

        let citeKey = "\(firstAuthorLastName)\(year)\(titleWord)"

        // Build fields
        var fields: [String: String] = [:]

        fields["title"] = record.title.value

        // Authors
        if let authors = record.names?.authors {
            let authorStrings = authors.map { author in
                if let lastName = author.lastName, let firstName = author.firstName {
                    return "\(lastName), \(firstName)"
                }
                return author.displayName
            }
            fields["author"] = authorStrings.joined(separator: " and ")
        }

        // Journal info
        if let source = record.source {
            if let journal = source.sourceTitle {
                fields["journal"] = journal
            }
            if let pubYear = source.publishYear {
                fields["year"] = String(pubYear)
            }
            if let volume = source.volume {
                fields["volume"] = volume
            }
            if let issue = source.issue {
                fields["number"] = issue
            }
            if let pages = source.pages?.range {
                fields["pages"] = pages
            }
            if let month = source.publishMonth {
                fields["month"] = month.lowercased()
            }
        }

        // Identifiers
        if let doi = record.identifiers?.doi {
            fields["doi"] = doi
        }
        if let issn = record.identifiers?.issn {
            fields["issn"] = issn
        }

        // Keywords
        if let keywords = record.keywords?.authorKeywords {
            fields["keywords"] = keywords.joined(separator: ", ")
        }

        // WoS-specific
        fields["wos-uid"] = record.uid
        fields["wos-ut"] = record.ut

        // Build raw BibTeX string
        let rawBibTeX = buildRawBibTeX(entryType: entryType, citeKey: citeKey, fields: fields)

        return BibTeXEntry(
            citeKey: citeKey,
            entryType: entryType,
            fields: fields,
            rawBibTeX: rawBibTeX
        )
    }

    // MARK: - RIS Generation

    /// Generate an RIS entry from a WoS record.
    public static func generateRIS(from record: WoSRecord) -> RISEntry {
        let risTypeStr = WoSEntryType(wosType: record.types?.first ?? "article").risType
        let risType = RISReferenceType(rawValue: risTypeStr) ?? .JOUR

        var tagValues: [(RISTag, String)] = []

        tagValues.append((.TI, record.title.value))

        // Authors
        if let authors = record.names?.authors {
            for author in authors {
                let authorName: String
                if let lastName = author.lastName, let firstName = author.firstName {
                    authorName = "\(lastName), \(firstName)"
                } else {
                    authorName = author.displayName
                }
                tagValues.append((.AU, authorName))
            }
        }

        // Source info
        if let source = record.source {
            if let journal = source.sourceTitle {
                tagValues.append((.JO, journal))
                tagValues.append((.T2, journal))
            }
            if let pubYear = source.publishYear {
                tagValues.append((.PY, String(pubYear)))
            }
            if let volume = source.volume {
                tagValues.append((.VL, volume))
            }
            if let issue = source.issue {
                tagValues.append((.IS, issue))
            }
            if let pages = source.pages {
                if let begin = pages.begin {
                    tagValues.append((.SP, begin))
                }
                if let end = pages.end {
                    tagValues.append((.EP, end))
                }
            }
        }

        // Identifiers
        if let doi = record.identifiers?.doi {
            tagValues.append((.DO, doi))
        }
        if let issn = record.identifiers?.issn {
            tagValues.append((.SN, issn))
        }

        // Keywords
        if let keywords = record.keywords?.authorKeywords {
            for keyword in keywords {
                tagValues.append((.KW, keyword))
            }
        }

        // WoS-specific - use custom field for UID
        tagValues.append((.C1, record.uid))

        // Build raw RIS string
        let rawRIS = buildRawRISFromTags(type: risType, tags: tagValues)

        return RISEntry(
            type: risType,
            tags: tagValues,
            rawRIS: rawRIS
        )
    }

    // MARK: - Helper Methods

    private static func buildRawBibTeX(entryType: String, citeKey: String, fields: [String: String]) -> String {
        var lines: [String] = []
        lines.append("@\(entryType){\(citeKey),")

        let sortedFields = fields.sorted { $0.key < $1.key }
        for (index, field) in sortedFields.enumerated() {
            let isLast = index == sortedFields.count - 1
            let comma = isLast ? "" : ","
            lines.append("  \(field.key) = {\(field.value)}\(comma)")
        }

        lines.append("}")
        return lines.joined(separator: "\n")
    }

    private static func buildRawRISFromTags(type: RISReferenceType, tags: [(RISTag, String)]) -> String {
        var lines: [String] = []

        // TY must be first
        lines.append("TY  - \(type.rawValue)")

        // Add all other tags
        for (tag, value) in tags {
            lines.append("\(tag.rawValue)  - \(value)")
        }

        // ER must be last
        lines.append("ER  -")
        return lines.joined(separator: "\n")
    }

    // MARK: - Abstract Extraction

    /// Extract abstract from a detailed record response.
    public static func extractAbstract(from data: Data) throws -> String? {
        let decoder = JSONDecoder()
        let response = try decoder.decode(WoSRecordDetailResponse.self, from: data)

        return response.static?.fullrecord_metadata?.abstracts?.abstractText?.first?.value
    }

    // MARK: - Error Parsing

    /// Parse an error response from WoS API.
    public static func parseError(from data: Data) -> WoSError? {
        let decoder = JSONDecoder()
        return try? decoder.decode(WoSErrorResponse.self, from: data).error
    }
}
