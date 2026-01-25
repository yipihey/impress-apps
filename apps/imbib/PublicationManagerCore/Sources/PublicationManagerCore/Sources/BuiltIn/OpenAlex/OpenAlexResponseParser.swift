//
//  OpenAlexResponseParser.swift
//  PublicationManagerCore
//
//  Parses OpenAlex API responses into domain types.
//

import Foundation

// MARK: - OpenAlex Response Parser

/// Parses OpenAlex API responses into domain types.
public enum OpenAlexResponseParser {

    // MARK: - Parse Search Response

    /// Parse search response JSON into SearchResult array.
    public static func parseSearchResponse(_ data: Data) throws -> [SearchResult] {
        let decoder = JSONDecoder()
        let response = try decoder.decode(OpenAlexSearchResponse.self, from: data)
        return response.results.compactMap { work in
            convertWorkToSearchResult(work)
        }
    }

    /// Parse a single work response.
    public static func parseWork(_ data: Data) throws -> OpenAlexWork {
        let decoder = JSONDecoder()
        return try decoder.decode(OpenAlexWork.self, from: data)
    }

    /// Parse search response and return metadata.
    public static func parseSearchResponseWithMeta(_ data: Data) throws -> (results: [SearchResult], meta: OpenAlexMeta) {
        let decoder = JSONDecoder()
        let response = try decoder.decode(OpenAlexSearchResponse.self, from: data)
        let results = response.results.compactMap { work in
            convertWorkToSearchResult(work)
        }
        return (results, response.meta)
    }

    // MARK: - Convert Work to SearchResult

    /// Convert an OpenAlex work to a SearchResult.
    public static func convertWorkToSearchResult(_ work: OpenAlexWork) -> SearchResult? {
        // Get the title
        guard let title = work.title ?? work.displayName, !title.isEmpty else {
            return nil
        }

        // Extract OpenAlex ID (short form like "W1234567890")
        let openAlexID = extractOpenAlexID(from: work.id)

        // Get authors
        let authors = work.authorships?.compactMap { authorship -> String? in
            authorship.author.displayName
        } ?? []

        // Get venue from primary location
        let venue = work.primaryLocation?.source?.displayName

        // Get abstract
        let abstract = decodeInvertedIndexAbstract(work.abstractInvertedIndex)

        // Build PDF links
        let pdfLinks = buildPDFLinks(from: work)

        // Web URL (landing page)
        let webURL: URL?
        if let landingPage = work.primaryLocation?.landingPageUrl {
            webURL = URL(string: landingPage)
        } else if let doi = work.doi {
            // Fall back to DOI resolver
            let cleanDOI = doi.hasPrefix("https://doi.org/") ? String(doi.dropFirst(16)) : doi
            webURL = URL(string: "https://doi.org/\(cleanDOI)")
        } else {
            // Fall back to OpenAlex page
            webURL = URL(string: "https://openalex.org/works/\(openAlexID)")
        }

        // Extract DOI (clean format without https://doi.org/)
        let doi = cleanDOI(work.doi)

        // Extract PMID (clean format)
        let pmid = cleanPMID(work.ids?.pmid)

        return SearchResult(
            id: openAlexID,
            sourceID: "openalex",
            title: title,
            authors: authors,
            year: work.publicationYear,
            venue: venue,
            abstract: abstract,
            doi: doi,
            arxivID: nil,  // OpenAlex doesn't provide arXiv IDs directly
            pmid: pmid,
            bibcode: nil,
            semanticScholarID: nil,
            openAlexID: openAlexID,
            pdfLinks: pdfLinks,
            webURL: webURL
        )
    }

    // MARK: - Convert Work to PaperStub

    /// Convert an OpenAlex work to a PaperStub for references/citations.
    public static func convertWorkToPaperStub(_ work: OpenAlexWork) -> PaperStub? {
        guard let title = work.title ?? work.displayName, !title.isEmpty else {
            return nil
        }

        let openAlexID = extractOpenAlexID(from: work.id)
        let authors = work.authorships?.compactMap { $0.author.displayName } ?? []
        let doi = cleanDOI(work.doi)
        let abstract = decodeInvertedIndexAbstract(work.abstractInvertedIndex)

        return PaperStub(
            id: openAlexID,
            title: title,
            authors: authors,
            year: work.publicationYear,
            venue: work.primaryLocation?.source?.displayName,
            doi: doi,
            arxivID: nil,
            citationCount: work.citedByCount,
            referenceCount: work.referencedWorksCount,
            isOpenAccess: work.openAccess?.isOa,
            abstract: abstract
        )
    }

    // MARK: - Abstract Decoding

    /// Decode inverted index abstract to plain text.
    ///
    /// OpenAlex stores abstracts as inverted indexes for compression:
    /// `{"word1": [0, 5], "word2": [1, 3]}` means word1 is at positions 0 and 5, word2 at 1 and 3.
    public static func decodeInvertedIndexAbstract(_ invertedIndex: [String: [Int]]?) -> String? {
        guard let invertedIndex = invertedIndex, !invertedIndex.isEmpty else {
            return nil
        }

        // Build array of (word, position) pairs
        var wordPositions: [(word: String, position: Int)] = []
        for (word, positions) in invertedIndex {
            for position in positions {
                wordPositions.append((word, position))
            }
        }

        // Sort by position
        wordPositions.sort { $0.position < $1.position }

        // Join words with spaces
        let words = wordPositions.map { $0.word }
        let abstract = words.joined(separator: " ")

        // Clean up the abstract
        return cleanAbstract(abstract)
    }

    /// Clean up abstract text (fix spacing around punctuation, etc.)
    private static func cleanAbstract(_ text: String) -> String {
        var result = text

        // Fix common spacing issues
        result = result.replacingOccurrences(of: " .", with: ".")
        result = result.replacingOccurrences(of: " ,", with: ",")
        result = result.replacingOccurrences(of: " :", with: ":")
        result = result.replacingOccurrences(of: " ;", with: ";")
        result = result.replacingOccurrences(of: " ?", with: "?")
        result = result.replacingOccurrences(of: " !", with: "!")
        result = result.replacingOccurrences(of: "( ", with: "(")
        result = result.replacingOccurrences(of: " )", with: ")")
        result = result.replacingOccurrences(of: "[ ", with: "[")
        result = result.replacingOccurrences(of: " ]", with: "]")
        result = result.replacingOccurrences(of: " - ", with: "-")  // hyphens in compounds
        result = result.replacingOccurrences(of: "  ", with: " ")  // double spaces

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - PDF Links

    /// Build PDF links from OpenAlex locations.
    public static func buildPDFLinks(from work: OpenAlexWork) -> [PDFLink] {
        var links: [PDFLink] = []
        var seenURLs: Set<String> = []

        // Helper to add link if URL is valid and not duplicate
        func addLink(urlString: String?, type: PDFLinkType) {
            guard let urlString = urlString,
                  !seenURLs.contains(urlString),
                  let url = URL(string: urlString) else {
                return
            }
            seenURLs.insert(urlString)
            links.append(PDFLink(url: url, type: type, sourceID: "openalex"))
        }

        // Priority 1: Best OA location (usually the most accessible free version)
        if let bestOA = work.bestOaLocation {
            addLink(urlString: bestOA.pdfUrl, type: .preprint)
        }

        // Priority 2: All OA locations
        if let locations = work.locations {
            for location in locations {
                guard location.isOa == true else { continue }

                // Determine type based on source type and version
                let type: PDFLinkType
                if location.source?.type == "repository" {
                    type = .preprint
                } else if location.isPublished == true {
                    type = .publisher
                } else if location.isAccepted == true {
                    type = .author
                } else {
                    type = .preprint
                }

                addLink(urlString: location.pdfUrl, type: type)
            }
        }

        // Priority 3: Primary location (may be paywalled)
        if let primary = work.primaryLocation {
            if primary.pdfUrl != nil {
                let type: PDFLinkType = primary.isOa == true ? .publisher : .publisher
                addLink(urlString: primary.pdfUrl, type: type)
            }
        }

        // Priority 4: DOI link as fallback (redirects to publisher)
        if links.isEmpty, let doi = work.doi {
            let cleanedDOI = doi.hasPrefix("https://doi.org/") ? String(doi.dropFirst(16)) : doi
            if let url = URL(string: "https://doi.org/\(cleanedDOI)") {
                links.append(PDFLink(url: url, type: .publisher, sourceID: "openalex"))
            }
        }

        return links
    }

    // MARK: - Identifier Extraction

    /// Extract short OpenAlex ID from full URL.
    /// Input: "https://openalex.org/W1234567890"
    /// Output: "W1234567890"
    public static func extractOpenAlexID(from url: String) -> String {
        if url.hasPrefix("https://openalex.org/") {
            return String(url.dropFirst(21))
        }
        // Already a short ID
        return url
    }

    /// Clean DOI (remove https://doi.org/ prefix if present).
    public static func cleanDOI(_ doi: String?) -> String? {
        guard let doi = doi, !doi.isEmpty else { return nil }
        if doi.hasPrefix("https://doi.org/") {
            return String(doi.dropFirst(16))
        }
        return doi
    }

    /// Clean PMID (remove https://pubmed.ncbi.nlm.nih.gov/ prefix if present).
    public static func cleanPMID(_ pmid: String?) -> String? {
        guard let pmid = pmid, !pmid.isEmpty else { return nil }
        if pmid.hasPrefix("https://pubmed.ncbi.nlm.nih.gov/") {
            return String(pmid.dropFirst(32))
        }
        return pmid
    }

    // MARK: - BibTeX Generation

    /// Generate BibTeX entry from OpenAlex work.
    public static func generateBibTeX(from work: OpenAlexWork) -> BibTeXEntry? {
        guard let title = work.title ?? work.displayName else { return nil }

        // Determine entry type
        let entryType = work.type?.bibtexType ?? "article"

        // Generate cite key: LastNameYearTitleWord
        let citeKey = generateCiteKey(
            authors: work.authorships?.compactMap { $0.author.displayName } ?? [],
            year: work.publicationYear,
            title: title
        )

        // Build fields
        var fields: [String: String] = [:]

        fields["title"] = title

        // Authors in BibTeX format: "Last1, First1 and Last2, First2"
        if let authorships = work.authorships, !authorships.isEmpty {
            let authorNames = authorships.compactMap { authorship -> String? in
                let name = authorship.author.displayName
                // Try to reformat as "Last, First"
                return reformatAuthorName(name)
            }
            fields["author"] = authorNames.joined(separator: " and ")
        }

        if let year = work.publicationYear {
            fields["year"] = String(year)
        }

        if let venue = work.primaryLocation?.source?.displayName {
            if entryType == "article" {
                fields["journal"] = venue
            } else if entryType == "inproceedings" {
                fields["booktitle"] = venue
            }
        }

        if let biblio = work.biblio {
            if let volume = biblio.volume {
                fields["volume"] = volume
            }
            if let issue = biblio.issue {
                fields["number"] = issue
            }
            if let pages = biblio.pages {
                fields["pages"] = pages
            }
        }

        if let doi = cleanDOI(work.doi) {
            fields["doi"] = doi
        }

        // Add abstract if available
        if let abstract = decodeInvertedIndexAbstract(work.abstractInvertedIndex) {
            fields["abstract"] = abstract
        }

        // Add OpenAlex URL
        let openAlexID = extractOpenAlexID(from: work.id)
        fields["openalex"] = "https://openalex.org/\(openAlexID)"

        // Add keywords
        if let keywords = work.keywords, !keywords.isEmpty {
            let keywordNames = keywords.map { $0.displayName }
            fields["keywords"] = keywordNames.joined(separator: ", ")
        }

        return BibTeXEntry(
            citeKey: citeKey,
            entryType: entryType,
            fields: fields,
            rawBibTeX: nil
        )
    }

    /// Generate a cite key from author, year, and title.
    private static func generateCiteKey(authors: [String], year: Int?, title: String) -> String {
        // Get first author's last name
        var key = ""
        if let firstAuthor = authors.first {
            // Extract last name (handle "First Last" and "Last, First" formats)
            if firstAuthor.contains(",") {
                key = firstAuthor.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces) ?? ""
            } else {
                key = firstAuthor.components(separatedBy: " ").last ?? ""
            }
            // Clean up: remove non-alphanumeric characters
            key = key.components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
        }

        // Add year
        if let year = year {
            key += String(year)
        }

        // Add first significant word from title
        let stopWords = Set(["a", "an", "the", "of", "and", "or", "in", "on", "for", "with", "to", "from"])
        let titleWords = title.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !stopWords.contains($0) }
        if let firstWord = titleWords.first {
            key += firstWord.capitalized
        }

        return key.isEmpty ? "unknown" : key
    }

    /// Reformat author name to "Last, First" format.
    private static func reformatAuthorName(_ name: String) -> String {
        // If already in "Last, First" format, return as-is
        if name.contains(",") {
            return name
        }

        // Split "First Last" and reformat
        let parts = name.split(separator: " ").map(String.init)
        guard parts.count >= 2 else { return name }

        let lastName = parts.last ?? ""
        let firstNames = parts.dropLast().joined(separator: " ")
        return "\(lastName), \(firstNames)"
    }

    // MARK: - RIS Generation

    /// Generate RIS entry from OpenAlex work.
    public static func generateRIS(from work: OpenAlexWork) -> RISEntry? {
        guard let title = work.title ?? work.displayName else { return nil }

        // Determine RIS type
        let risType: RISReferenceType
        if let type = work.type {
            switch type {
            case .article, .peerReview, .editorial, .erratum, .letter, .review:
                risType = .JOUR
            case .book, .monograph:
                risType = .BOOK
            case .bookChapter, .bookPart, .referenceEntry:
                risType = .CHAP
            case .proceedings:
                risType = .CONF
            case .dissertation:
                risType = .THES
            case .report:
                risType = .RPRT
            case .dataset:
                risType = .DATA
            default:
                risType = .GEN
            }
        } else {
            risType = .JOUR
        }

        var tags: [(RISTag, String)] = []

        tags.append((.TI, title))

        // Authors
        if let authorships = work.authorships {
            for authorship in authorships {
                tags.append((.AU, authorship.author.displayName))
            }
        }

        // Year and date
        if let year = work.publicationYear {
            tags.append((.PY, String(year)))
        }
        if let date = work.publicationDate {
            tags.append((.DA, date))
        }

        // Journal/venue
        if let venue = work.primaryLocation?.source?.displayName {
            tags.append((.JF, venue))
        }

        // Volume/issue/pages
        if let biblio = work.biblio {
            if let volume = biblio.volume {
                tags.append((.VL, volume))
            }
            if let issue = biblio.issue {
                tags.append((.IS, issue))
            }
            if let firstPage = biblio.firstPage {
                tags.append((.SP, firstPage))
            }
            if let lastPage = biblio.lastPage {
                tags.append((.EP, lastPage))
            }
        }

        // DOI
        if let doi = cleanDOI(work.doi) {
            tags.append((.DO, doi))
        }

        // Abstract
        if let abstract = decodeInvertedIndexAbstract(work.abstractInvertedIndex) {
            tags.append((.AB, abstract))
        }

        // Keywords
        if let keywords = work.keywords {
            for keyword in keywords {
                tags.append((.KW, keyword.displayName))
            }
        }

        // URL
        let openAlexID = extractOpenAlexID(from: work.id)
        tags.append((.UR, "https://openalex.org/\(openAlexID)"))

        return RISEntry(type: risType, tags: tags, rawRIS: nil)
    }
}
