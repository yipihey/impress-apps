//
//  CitationGraphService.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-02-03.
//

import Foundation
import CoreData
import OSLog

// MARK: - Citation Graph Types

/// A node in the citation graph representing a paper.
public struct CitationNode: Identifiable, Hashable, Sendable {
    public let id: String  // DOI or other unique identifier
    public let title: String
    public let authors: [String]
    public let year: Int?
    public let citeKey: String?
    /// Whether this paper is in the library
    public let isInLibrary: Bool
    /// Number of connections (citations + references) within the graph
    public var connectionCount: Int = 0

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public static func == (lhs: CitationNode, rhs: CitationNode) -> Bool {
        lhs.id == rhs.id
    }
}

/// A directed edge in the citation graph.
public struct CitationEdge: Identifiable, Hashable, Sendable {
    public let id: String
    /// The citing paper
    public let sourceID: String
    /// The cited paper
    public let targetID: String

    public init(sourceID: String, targetID: String) {
        self.id = "\(sourceID)->\(targetID)"
        self.sourceID = sourceID
        self.targetID = targetID
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public static func == (lhs: CitationEdge, rhs: CitationEdge) -> Bool {
        lhs.id == rhs.id
    }
}

/// The complete citation graph for a library.
public struct CitationGraph: Sendable {
    public var nodes: [String: CitationNode]
    public var edges: Set<CitationEdge>

    /// Papers frequently cited by library papers but not in the library.
    public var suggestedPapers: [CitationNode] {
        nodes.values
            .filter { !$0.isInLibrary && $0.connectionCount >= 2 }
            .sorted { $0.connectionCount > $1.connectionCount }
    }

    /// Papers in the library sorted by how connected they are.
    public var mostConnected: [CitationNode] {
        nodes.values
            .filter { $0.isInLibrary }
            .sorted { $0.connectionCount > $1.connectionCount }
    }

    public init() {
        self.nodes = [:]
        self.edges = []
    }
}

// MARK: - Citation Graph Service

/// Service for building citation graphs from library publications.
///
/// Fetches citation relationships between papers using enrichment data
/// (references/citations from OpenAlex, ADS, etc.) and builds a directed
/// graph of internal citations within a library. Also identifies "missing
/// links" - frequently cited papers not yet in the library.
@MainActor
public final class CitationGraphService {

    public static let shared = CitationGraphService()

    private let persistenceController: PersistenceController

    /// Whether a graph build is in progress
    public private(set) var isBuilding = false

    /// Progress (0.0 to 1.0) of the current build
    public private(set) var progress: Double = 0

    public init(persistenceController: PersistenceController = .shared) {
        self.persistenceController = persistenceController
    }

    // MARK: - Graph Building

    /// Build a citation graph for all publications in a library.
    ///
    /// For each paper with enrichment data, adds edges from the paper to its
    /// references (if also in the library) and from its citations (if in the
    /// library) to it. Papers cited by multiple library papers but not in the
    /// library appear as "suggested papers".
    ///
    /// - Parameter library: The library to build the graph for
    /// - Returns: The citation graph
    public func buildGraph(for library: CDLibrary) async -> CitationGraph {
        guard !isBuilding else { return CitationGraph() }
        isBuilding = true
        progress = 0
        defer {
            isBuilding = false
            progress = 1.0
        }

        let publications = Array(library.publications ?? [])
        guard !publications.isEmpty else { return CitationGraph() }

        Logger.viewModels.info("CitationGraphService: building graph for \(publications.count) publications")

        var graph = CitationGraph()

        // Build lookup of library papers by identifier
        var doiLookup: [String: CDPublication] = [:]
        var openAlexLookup: [String: CDPublication] = [:]

        for pub in publications {
            let nodeID = nodeIdentifier(for: pub)

            // Add library paper as node
            graph.nodes[nodeID] = CitationNode(
                id: nodeID,
                title: pub.title ?? "Untitled",
                authors: pub.sortedAuthors.map(\.familyName),
                year: pub.year > 0 ? Int(pub.year) : nil,
                citeKey: pub.citeKey,
                isInLibrary: true
            )

            if let doi = pub.doi?.lowercased() {
                doiLookup[doi] = pub
            }
            if let oaID = pub.openAlexID {
                openAlexLookup[oaID] = pub
            }
        }

        // Process enrichment data for each publication
        let total = Double(publications.count)
        for (index, pub) in publications.enumerated() {
            progress = Double(index) / total
            let sourceID = nodeIdentifier(for: pub)

            // Check stored enrichment for references
            if let refsJSON = pub.fields["_enrichment_references"],
               let refs = decodeStubs(refsJSON) {
                for ref in refs {
                    addEdge(
                        from: sourceID,
                        to: ref,
                        doiLookup: doiLookup,
                        graph: &graph
                    )
                }
            }

            // Check stored enrichment for citations (papers that cite this one)
            if let citesJSON = pub.fields["_enrichment_citations"],
               let cites = decodeStubs(citesJSON) {
                for cite in cites {
                    addCitationEdge(
                        citingNode: stubToNode(cite),
                        citedByID: sourceID,
                        graph: &graph
                    )
                }
            }

            // Also use referenceCount/citationCount from enrichment
            // and referencedWorks from OpenAlex (stored as comma-separated IDs)
            if let refWorksStr = pub.fields["_openalex_referenced_works"] {
                let refWorkIDs = refWorksStr.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                for refID in refWorkIDs {
                    guard !refID.isEmpty else { continue }
                    // Check if this referenced work is in our library
                    if let refPub = openAlexLookup[refID] {
                        let targetID = nodeIdentifier(for: refPub)
                        let edge = CitationEdge(sourceID: sourceID, targetID: targetID)
                        if graph.edges.insert(edge).inserted {
                            graph.nodes[sourceID]?.connectionCount += 1
                            graph.nodes[targetID]?.connectionCount += 1
                        }
                    }
                }
            }
        }

        let internalEdges = graph.edges.count
        let externalNodes = graph.nodes.values.filter { !$0.isInLibrary }.count
        Logger.viewModels.info("CitationGraphService: built graph with \(graph.nodes.count) nodes (\(externalNodes) external), \(internalEdges) edges")

        return graph
    }

    // MARK: - Helpers

    /// Get a stable identifier for a publication (prefer DOI).
    private func nodeIdentifier(for pub: CDPublication) -> String {
        if let doi = pub.doi?.lowercased(), !doi.isEmpty {
            return "doi:\(doi)"
        }
        if let oaID = pub.openAlexID, !oaID.isEmpty {
            return "oa:\(oaID)"
        }
        if let arxiv = pub.arxivID, !arxiv.isEmpty {
            return "arxiv:\(arxiv)"
        }
        return "id:\(pub.id.uuidString)"
    }

    /// Get a stable identifier for a PaperStub.
    private func stubIdentifier(_ stub: PaperStub) -> String {
        if let doi = stub.doi?.lowercased(), !doi.isEmpty {
            return "doi:\(doi)"
        }
        if let arxiv = stub.arxivID?.lowercased(), !arxiv.isEmpty {
            return "arxiv:\(arxiv)"
        }
        return "stub:\(stub.id)"
    }

    /// Convert a PaperStub to a CitationNode.
    private func stubToNode(_ stub: PaperStub) -> CitationNode {
        CitationNode(
            id: stubIdentifier(stub),
            title: stub.title,
            authors: stub.authors,
            year: stub.year,
            citeKey: nil,
            isInLibrary: false
        )
    }

    /// Add an edge from a library paper to a referenced stub.
    private func addEdge(
        from sourceID: String,
        to stub: PaperStub,
        doiLookup: [String: CDPublication],
        graph: inout CitationGraph
    ) {
        let targetID: String
        let isInLibrary: Bool

        // Check if the referenced paper is in our library
        if let doi = stub.doi?.lowercased(), let libPub = doiLookup[doi] {
            targetID = nodeIdentifier(for: libPub)
            isInLibrary = true
        } else {
            targetID = stubIdentifier(stub)
            isInLibrary = false
        }

        // Ensure target node exists
        if graph.nodes[targetID] == nil {
            graph.nodes[targetID] = CitationNode(
                id: targetID,
                title: stub.title,
                authors: stub.authors,
                year: stub.year,
                citeKey: nil,
                isInLibrary: isInLibrary
            )
        }

        // Add edge
        let edge = CitationEdge(sourceID: sourceID, targetID: targetID)
        if graph.edges.insert(edge).inserted {
            graph.nodes[sourceID]?.connectionCount += 1
            graph.nodes[targetID]?.connectionCount += 1
        }
    }

    /// Add a citation edge (citing paper -> cited paper).
    private func addCitationEdge(
        citingNode: CitationNode,
        citedByID: String,
        graph: inout CitationGraph
    ) {
        // Ensure citing node exists
        if graph.nodes[citingNode.id] == nil {
            graph.nodes[citingNode.id] = citingNode
        }

        // Add edge: citing paper -> this library paper
        let edge = CitationEdge(sourceID: citingNode.id, targetID: citedByID)
        if graph.edges.insert(edge).inserted {
            graph.nodes[citingNode.id]?.connectionCount += 1
            graph.nodes[citedByID]?.connectionCount += 1
        }
    }

    /// Decode PaperStub array from JSON string.
    private func decodeStubs(_ json: String) -> [PaperStub]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([PaperStub].self, from: data)
    }
}
