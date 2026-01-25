//
//  SearchFormQueryBuilder.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-14.
//

import Foundation

// MARK: - Query Logic

/// Boolean logic for combining search terms
public enum QueryLogic: String, CaseIterable, Sendable {
    case and = "AND"
    case or = "OR"

    public var displayName: String {
        rawValue
    }
}

// MARK: - ADS Database

/// ADS database/collection selector
public enum ADSDatabase: String, CaseIterable, Sendable {
    case astronomy
    case physics
    case arxiv
    case all

    public var displayName: String {
        switch self {
        case .astronomy: return "Astronomy"
        case .physics: return "Physics"
        case .arxiv: return "arXiv Preprints"
        case .all: return "All Databases"
        }
    }

    /// Convert database selection to source IDs
    public var sourceIDs: [String] {
        switch self {
        case .astronomy, .physics, .all:
            return ["ads"]  // ADS handles database filtering via query
        case .arxiv:
            return ["arxiv", "ads"]  // Search both arXiv directly and ADS
        }
    }
}

// MARK: - Search Form Query Builder

/// Builds ADS query strings from form inputs
public enum SearchFormQueryBuilder {

    // MARK: - Classic Form Query

    /// Build an ADS query from classic form fields
    public static func buildClassicQuery(
        authors: String,
        objects: String,
        titleWords: String,
        titleLogic: QueryLogic,
        abstractWords: String,
        abstractLogic: QueryLogic,
        yearFrom: Int?,
        yearTo: Int?,
        database: ADSDatabase = .all,
        refereedOnly: Bool = false,
        articlesOnly: Bool = false
    ) -> String {
        var parts: [String] = []

        // Authors: each line becomes author:"..."
        let authorLines = authors
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        if !authorLines.isEmpty {
            let authorQueries = authorLines.map { "author:\"\($0)\"" }
            parts.append(authorQueries.joined(separator: " AND "))
        }

        // Objects (SIMBAD/NED object names)
        let trimmedObjects = objects.trimmingCharacters(in: .whitespaces)
        if !trimmedObjects.isEmpty {
            parts.append("object:\"\(trimmedObjects)\"")
        }

        // Title words
        let trimmedTitle = titleWords.trimmingCharacters(in: .whitespaces)
        if !trimmedTitle.isEmpty {
            let words = trimmedTitle
                .split(separator: " ")
                .map(String.init)
                .filter { !$0.isEmpty }

            if words.count == 1 {
                parts.append("title:\(words[0])")
            } else if !words.isEmpty {
                let joined = words.joined(separator: " \(titleLogic.rawValue) ")
                parts.append("title:(\(joined))")
            }
        }

        // Abstract/Keywords words
        let trimmedAbstract = abstractWords.trimmingCharacters(in: .whitespaces)
        if !trimmedAbstract.isEmpty {
            let words = trimmedAbstract
                .split(separator: " ")
                .map(String.init)
                .filter { !$0.isEmpty }

            if words.count == 1 {
                parts.append("abs:\(words[0])")
            } else if !words.isEmpty {
                let joined = words.joined(separator: " \(abstractLogic.rawValue) ")
                parts.append("abs:(\(joined))")
            }
        }

        // Year range
        if let from = yearFrom, let to = yearTo {
            if from == to {
                parts.append("year:\(from)")
            } else {
                parts.append("year:\(from)-\(to)")
            }
        } else if let from = yearFrom {
            parts.append("year:\(from)-")
        } else if let to = yearTo {
            parts.append("year:-\(to)")
        }

        // Database filter (ADS uses collection: prefix)
        switch database {
        case .astronomy:
            parts.append("collection:astronomy")
        case .physics:
            parts.append("collection:physics")
        case .arxiv:
            parts.append("property:eprint")
        case .all:
            break  // No filter needed
        }

        // Refereed filter (peer-reviewed papers only)
        if refereedOnly {
            parts.append("property:refereed")
        }

        // Articles filter (journal articles only, excludes proceedings, etc.)
        if articlesOnly {
            parts.append("doctype:article")
        }

        return parts.joined(separator: " ")
    }

    // MARK: - Paper Form Query

    /// Build an ADS query from paper identifier fields
    public static func buildPaperQuery(
        bibcode: String,
        doi: String,
        arxivID: String
    ) -> String {
        var parts: [String] = []

        let trimmedBibcode = bibcode.trimmingCharacters(in: .whitespaces)
        if !trimmedBibcode.isEmpty {
            parts.append("bibcode:\(trimmedBibcode)")
        }

        let trimmedDOI = doi.trimmingCharacters(in: .whitespaces)
        if !trimmedDOI.isEmpty {
            parts.append("doi:\(trimmedDOI)")
        }

        let trimmedArxiv = arxivID.trimmingCharacters(in: .whitespaces)
        if !trimmedArxiv.isEmpty {
            // Handle both old (astro-ph/0702089) and new (1108.0669) arXiv formats
            parts.append("arXiv:\(trimmedArxiv)")
        }

        // Use OR to find paper matching any identifier
        return parts.joined(separator: " OR ")
    }

    // MARK: - Validation

    /// Check if classic form has any search criteria
    public static func isClassicFormEmpty(
        authors: String,
        objects: String,
        titleWords: String,
        abstractWords: String,
        yearFrom: Int?,
        yearTo: Int?
    ) -> Bool {
        let hasAuthors = !authors.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasObjects = !objects.trimmingCharacters(in: .whitespaces).isEmpty
        let hasTitle = !titleWords.trimmingCharacters(in: .whitespaces).isEmpty
        let hasAbstract = !abstractWords.trimmingCharacters(in: .whitespaces).isEmpty
        let hasYear = yearFrom != nil || yearTo != nil

        return !hasAuthors && !hasObjects && !hasTitle && !hasAbstract && !hasYear
    }

    /// Check if paper form has any identifier
    public static func isPaperFormEmpty(
        bibcode: String,
        doi: String,
        arxivID: String
    ) -> Bool {
        let hasBibcode = !bibcode.trimmingCharacters(in: .whitespaces).isEmpty
        let hasDOI = !doi.trimmingCharacters(in: .whitespaces).isEmpty
        let hasArxiv = !arxivID.trimmingCharacters(in: .whitespaces).isEmpty

        return !hasBibcode && !hasDOI && !hasArxiv
    }

    // MARK: - arXiv Advanced Query

    /// Build an arXiv API query from advanced form fields
    public static func buildArXivAdvancedQuery(
        searchTerms: [ArXivSearchTerm],
        categories: Set<String>,
        includeCrossListed: Bool,
        dateFilter: ArXivDateFilter,
        sortBy: ArXivSortBy
    ) -> String {
        var parts: [String] = []

        // Build search terms with operators
        for (index, term) in searchTerms.enumerated() {
            let trimmed = term.term.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            let fieldQuery: String
            if term.field == .all {
                // For "all fields", just use the term directly
                fieldQuery = trimmed
            } else {
                // Wrap multi-word terms in quotes
                let formattedTerm = trimmed.contains(" ") ? "\"\(trimmed)\"" : trimmed
                fieldQuery = "\(term.field.rawValue):\(formattedTerm)"
            }

            if index == 0 || parts.isEmpty {
                parts.append(fieldQuery)
            } else {
                parts.append("\(term.logicOperator.rawValue) \(fieldQuery)")
            }
        }

        // Add category filter
        if !categories.isEmpty {
            let sortedCategories = categories.sorted()
            let catQuery = sortedCategories.map { "cat:\($0)" }.joined(separator: " OR ")
            if categories.count > 1 {
                parts.append("(\(catQuery))")
            } else {
                parts.append(catQuery)
            }
        }

        // Add date filter
        switch dateFilter {
        case .allDates:
            break  // No filter needed

        case .pastMonths(let months):
            // Calculate date range
            let calendar = Calendar.current
            let now = Date()
            if let fromDate = calendar.date(byAdding: .month, value: -months, to: now) {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyyMMdd"
                let fromStr = formatter.string(from: fromDate)
                let toStr = formatter.string(from: now)
                parts.append("submittedDate:[\(fromStr) TO \(toStr)]")
            }

        case .specificYear(let year):
            parts.append("submittedDate:[\(year)0101 TO \(year)1231]")

        case .dateRange(let from, let to):
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd"
            let fromStr = from.map { formatter.string(from: $0) } ?? "*"
            let toStr = to.map { formatter.string(from: $0) } ?? "*"
            if fromStr != "*" || toStr != "*" {
                parts.append("submittedDate:[\(fromStr) TO \(toStr)]")
            }
        }

        return parts.joined(separator: " ")
    }

    // MARK: - Group Feed Author Query

    /// Build an arXiv API query for a single author in specific categories.
    ///
    /// This is used by group feeds to search for papers by individual authors
    /// within the selected arXiv categories.
    ///
    /// - Parameters:
    ///   - author: The author name to search for
    ///   - categories: Set of arXiv category IDs (e.g., "astro-ph.GA", "hep-th")
    ///   - includeCrossListed: Whether to include papers cross-listed to the categories
    /// - Returns: An arXiv API query string
    public static func buildArXivAuthorCategoryQuery(
        author: String,
        categories: Set<String>,
        includeCrossListed: Bool
    ) -> String {
        var parts: [String] = []

        // Author query
        let trimmedAuthor = author.trimmingCharacters(in: .whitespaces)
        if !trimmedAuthor.isEmpty {
            // Wrap multi-word names in quotes
            let formattedAuthor = trimmedAuthor.contains(" ") ? "\"\(trimmedAuthor)\"" : trimmedAuthor
            parts.append("au:\(formattedAuthor)")
        }

        // Category filter
        if !categories.isEmpty {
            let sortedCategories = categories.sorted()
            let catQuery = sortedCategories.map { "cat:\($0)" }.joined(separator: " OR ")
            if categories.count > 1 {
                parts.append("(\(catQuery))")
            } else {
                parts.append(catQuery)
            }
        }

        // Combine with AND
        if parts.count > 1 {
            return parts.joined(separator: " AND ")
        } else {
            return parts.joined(separator: " ")
        }
    }
}
