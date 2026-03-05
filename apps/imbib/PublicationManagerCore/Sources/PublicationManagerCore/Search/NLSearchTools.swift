//
//  NLSearchTools.swift
//  PublicationManagerCore
//
//  Foundation Models Tool conformances wrapping sciX FFI functions.
//  These allow the on-device LLM to autonomously select the right
//  sciX operation based on the user's natural language request.
//

import Foundation
import ImpressScixCore
import OSLog

#if canImport(FoundationModels)
import FoundationModels

// MARK: - Structured Output Types

/// Structured output for query translation — used with guided generation.
@available(macOS 26, iOS 26, *)
@Generable
public struct ADSQueryResult: Sendable {
    @Guide(description: "The ADS query string using field qualifiers like author:, abs:, title:, year:, object:, property:")
    public var query: String

    @Guide(description: "Brief human-readable interpretation of what the user is looking for")
    public var interpretation: String
}

// (NLSearchToolResult removed — structured output now flows through ADSQueryResult via guided generation)

// MARK: - SciX Search Tool

/// Tool that generates an ADS query string from natural language.
/// The model calls this when the user wants to search for papers by topic, author, year, etc.
@available(macOS 26, iOS 26, *)
struct SciXSearchTool: Tool {
    let name = "search_papers"
    let description = """
        Search NASA ADS/SciX for papers. Generate an ADS query string from the user's \
        natural language description. Use field qualifiers: author:"Last", abs:"keywords", \
        title:"words", year:YYYY-YYYY, object:"name", property:refereed, doctype:article. \
        Use AND/OR boolean operators. Multi-word values must be quoted.
        """

    @Generable
    struct Arguments: Sendable {
        @Guide(description: "ADS query string with appropriate field qualifiers")
        var query: String
        @Guide(description: "Brief interpretation of what was understood from the user's request")
        var interpretation: String
    }

    let apiToken: String

    func call(arguments: Arguments) async throws -> String {
        Logger.viewModels.infoCapture(
            "NLSearch tool: search_papers query='\(arguments.query)'",
            category: "nlsearch"
        )

        // Execute the search to get a count for immediate feedback
        do {
            let count = try scixCount(token: apiToken, query: arguments.query)
            return "Query: \(arguments.query)\nInterpretation: \(arguments.interpretation)\nEstimated results: \(count)"
        } catch {
            return "Query: \(arguments.query)\nInterpretation: \(arguments.interpretation)\nCount unavailable: \(error.localizedDescription)"
        }
    }
}

// MARK: - SciX Citations Tool

/// Tool for finding papers that cite a specific paper.
/// The model calls this when the user asks "papers citing X" or "what cites X".
@available(macOS 26, iOS 26, *)
struct SciXCitationsTool: Tool {
    let name = "get_citations"
    let description = """
        Get papers that cite a specific paper. Use when the user asks about papers \
        that cite or reference a known work. Requires a bibcode (e.g., "2016ApJ...826...56R") \
        or enough information to identify the paper. If you only have author+year+topic, \
        use search_papers first to find the bibcode.
        """

    @Generable
    struct Arguments: Sendable {
        @Guide(description: "The ADS bibcode of the paper whose citations to fetch")
        var bibcode: String
    }

    let apiToken: String

    func call(arguments: Arguments) async throws -> String {
        Logger.viewModels.infoCapture(
            "NLSearch tool: get_citations bibcode='\(arguments.bibcode)'",
            category: "nlsearch"
        )

        do {
            let papers = try scixFetchCitations(
                token: apiToken,
                bibcode: arguments.bibcode,
                maxResults: 200
            )
            let bibcodes = papers.map(\.bibcode)
            return """
                Found \(papers.count) papers citing \(arguments.bibcode).
                ADS query: citations(bibcode:\(arguments.bibcode))
                Bibcodes: \(bibcodes.prefix(20).joined(separator: ", "))\(papers.count > 20 ? "..." : "")
                """
        } catch {
            return "Error fetching citations: \(error.localizedDescription). Use query: citations(bibcode:\(arguments.bibcode))"
        }
    }
}

// MARK: - SciX References Tool

/// Tool for finding papers that a specific paper cites.
/// The model calls this when the user asks "what does paper X cite" or "references of X".
@available(macOS 26, iOS 26, *)
struct SciXReferencesTool: Tool {
    let name = "get_references"
    let description = """
        Get papers cited by (referenced by) a specific paper. Use when the user asks \
        about the bibliography or references of a known work.
        """

    @Generable
    struct Arguments: Sendable {
        @Guide(description: "The ADS bibcode of the paper whose references to fetch")
        var bibcode: String
    }

    let apiToken: String

    func call(arguments: Arguments) async throws -> String {
        Logger.viewModels.infoCapture(
            "NLSearch tool: get_references bibcode='\(arguments.bibcode)'",
            category: "nlsearch"
        )

        do {
            let papers = try scixFetchReferences(
                token: apiToken,
                bibcode: arguments.bibcode,
                maxResults: 200
            )
            let bibcodes = papers.map(\.bibcode)
            return """
                Found \(papers.count) papers referenced by \(arguments.bibcode).
                ADS query: references(bibcode:\(arguments.bibcode))
                Bibcodes: \(bibcodes.prefix(20).joined(separator: ", "))\(papers.count > 20 ? "..." : "")
                """
        } catch {
            return "Error fetching references: \(error.localizedDescription). Use query: references(bibcode:\(arguments.bibcode))"
        }
    }
}

// MARK: - SciX Similar Papers Tool

/// Tool for finding papers similar to a specific paper.
/// The model calls this when the user asks "papers like X" or "similar to X".
@available(macOS 26, iOS 26, *)
struct SciXSimilarTool: Tool {
    let name = "get_similar"
    let description = """
        Find papers similar in content to a specific paper. Use when the user asks \
        for papers "like", "similar to", or "related to" a known work.
        """

    @Generable
    struct Arguments: Sendable {
        @Guide(description: "The ADS bibcode of the paper to find similar papers for")
        var bibcode: String
    }

    let apiToken: String

    func call(arguments: Arguments) async throws -> String {
        Logger.viewModels.infoCapture(
            "NLSearch tool: get_similar bibcode='\(arguments.bibcode)'",
            category: "nlsearch"
        )

        do {
            let papers = try scixFetchSimilar(
                token: apiToken,
                bibcode: arguments.bibcode,
                maxResults: 200
            )
            let bibcodes = papers.map(\.bibcode)
            return """
                Found \(papers.count) papers similar to \(arguments.bibcode).
                ADS query: similar(bibcode:\(arguments.bibcode))
                Bibcodes: \(bibcodes.prefix(20).joined(separator: ", "))\(papers.count > 20 ? "..." : "")
                """
        } catch {
            return "Error fetching similar papers: \(error.localizedDescription). Use query: similar(bibcode:\(arguments.bibcode))"
        }
    }
}

// MARK: - SciX Co-reads Tool

/// Tool for finding papers frequently co-read with a specific paper.
/// The model calls this for "trending" or "what people also read" requests.
@available(macOS 26, iOS 26, *)
struct SciXCoreadsTool: Tool {
    let name = "get_coreads"
    let description = """
        Find papers that are frequently read by people who also read a specific paper. \
        Use when the user asks for "trending", "co-reads", "also read", or \
        "what else do people reading X read".
        """

    @Generable
    struct Arguments: Sendable {
        @Guide(description: "The ADS bibcode of the paper to find co-reads for")
        var bibcode: String
    }

    let apiToken: String

    func call(arguments: Arguments) async throws -> String {
        Logger.viewModels.infoCapture(
            "NLSearch tool: get_coreads bibcode='\(arguments.bibcode)'",
            category: "nlsearch"
        )

        do {
            let papers = try scixFetchCoreads(
                token: apiToken,
                bibcode: arguments.bibcode,
                maxResults: 200
            )
            let bibcodes = papers.map(\.bibcode)
            return """
                Found \(papers.count) co-read papers for \(arguments.bibcode).
                Use the bibcodes to build a query: bibcode:(\(bibcodes.prefix(10).joined(separator: " OR "))\(papers.count > 10 ? " ..." : ""))
                """
        } catch {
            return "Error fetching co-reads: \(error.localizedDescription)"
        }
    }
}

// MARK: - SciX Count Tool

/// Tool for getting result counts without fetching papers.
/// The model can call this to preview query specificity.
@available(macOS 26, iOS 26, *)
struct SciXCountTool: Tool {
    let name = "count_results"
    let description = """
        Get the number of results for an ADS query without fetching papers. \
        Use this to check if a query is too broad or too narrow before searching.
        """

    @Generable
    struct Arguments: Sendable {
        @Guide(description: "ADS query string to count results for")
        var query: String
    }

    let apiToken: String

    func call(arguments: Arguments) async throws -> String {
        Logger.viewModels.infoCapture(
            "NLSearch tool: count_results query='\(arguments.query)'",
            category: "nlsearch"
        )

        do {
            let count = try scixCount(token: apiToken, query: arguments.query)
            return "Query '\(arguments.query)' returns \(count) results."
        } catch {
            return "Error counting results: \(error.localizedDescription)"
        }
    }
}

// MARK: - Tool Factory

/// Creates all sciX tools for a Foundation Models session.
@available(macOS 26, iOS 26, *)
public enum NLSearchToolFactory {

    /// Create all sciX tools with the given API token.
    /// Returns an empty array if no token is available.
    public static func makeTools(apiToken: String) -> [any Tool] {
        [
            SciXSearchTool(apiToken: apiToken),
            SciXCitationsTool(apiToken: apiToken),
            SciXReferencesTool(apiToken: apiToken),
            SciXSimilarTool(apiToken: apiToken),
            SciXCoreadsTool(apiToken: apiToken),
            SciXCountTool(apiToken: apiToken),
        ]
    }
}

#endif
