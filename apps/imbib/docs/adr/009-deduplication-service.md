# ADR-009: Cross-Source Deduplication Service

## Status

Accepted

## Date

2026-01-04

## Context

The same paper appears across multiple sources with different identifiers:

| Source | Identifier | Example |
|--------|------------|---------|
| Crossref | DOI | `10.1038/nature12373` |
| arXiv | arXiv ID | `1301.3781` |
| NASA ADS | Bibcode | `2013Natur.500..415M` |
| PubMed | PMID | `23903654` |
| Semantic Scholar | S2 ID | `d0ba59a49d1eb77b76a5e67b26f6eb3aeef4d7e8` |
| OpenAlex | OpenAlex ID | `W2963479262` |

When searching across sources, users see duplicates:
- Same paper from arXiv and Crossref
- Published version and preprint
- Multiple entries cluttering results

We need to:
1. Detect duplicates in search results
2. Link equivalent identifiers
3. Present unified results with source options
4. Store identifier mappings for future lookups

## Decision

Implement a **deduplication service** with:

1. **Identifier graph**: Map between equivalent identifiers
2. **Fuzzy matching**: Title/author similarity for entries without shared IDs
3. **Canonical selection**: Choose best entry when duplicates found
4. **Merged presentation**: Show one result with multiple source options

## Rationale

### Identifier Hierarchy

DOI is the canonical identifier when available:
- Persistent and standardized
- Resolves to publisher page
- Required for published works
- Used by Crossref, the DOI authority

When DOI is unavailable (preprints, old papers):
1. arXiv ID (for physics/CS/math preprints)
2. PMID (for biomedical literature)
3. Bibcode (for astronomy)
4. Title + author fuzzy match (fallback)

### Why Build a Graph?

Simple pairwise comparison is O(n²). An identifier graph enables:
- O(1) lookup: "Is this DOI already in results?"
- Transitive dedup: If A=B and B=C, then A=C
- Persistent learning: Store mappings for future queries

### Why Fuzzy Matching?

Not all entries share identifiers:
- Preprint before DOI assigned
- Old papers without DOIs
- Conference vs journal version

Title + authors catches most remaining duplicates.

## Implementation

### Identifier Types

```swift
public enum IdentifierType: String, Codable, CaseIterable {
    case doi
    case arxiv
    case pmid
    case bibcode
    case semanticScholar
    case openAlex
    case dblp
}

public struct PaperIdentifier: Hashable, Codable, Sendable {
    public let type: IdentifierType
    public let value: String

    public init(type: IdentifierType, value: String) {
        self.type = type
        self.value = Self.normalize(value, type: type)
    }

    /// Normalize identifier format
    private static func normalize(_ value: String, type: IdentifierType) -> String {
        switch type {
        case .doi:
            // Lowercase, remove URL prefix
            return value
                .lowercased()
                .replacingOccurrences(of: "https://doi.org/", with: "")
                .replacingOccurrences(of: "http://dx.doi.org/", with: "")
        case .arxiv:
            // Remove version suffix, normalize old format
            // 1301.3781v2 → 1301.3781
            // arXiv:1301.3781 → 1301.3781
            return value
                .replacingOccurrences(of: "arXiv:", with: "")
                .replacingOccurrences(of: #"v\d+$"#, with: "", options: .regularExpression)
        case .pmid:
            // Just the number
            return value.replacingOccurrences(of: "PMID:", with: "").trimmingCharacters(in: .whitespaces)
        default:
            return value
        }
    }
}
```

### Identifier Graph

```swift
public actor IdentifierGraph {
    /// Map from any identifier to canonical ID set
    private var graph: [PaperIdentifier: Set<PaperIdentifier>] = [:]

    /// Find all known identifiers for a paper
    public func equivalentIdentifiers(for id: PaperIdentifier) -> Set<PaperIdentifier> {
        graph[id] ?? [id]
    }

    /// Link two identifiers as referring to the same paper
    public func link(_ id1: PaperIdentifier, _ id2: PaperIdentifier) {
        let set1 = graph[id1] ?? [id1]
        let set2 = graph[id2] ?? [id2]
        let merged = set1.union(set2)

        // Update all entries to point to merged set
        for id in merged {
            graph[id] = merged
        }
    }

    /// Check if two identifiers refer to the same paper
    public func areEquivalent(_ id1: PaperIdentifier, _ id2: PaperIdentifier) -> Bool {
        guard let set1 = graph[id1] else { return id1 == id2 }
        return set1.contains(id2)
    }

    /// Persist graph to disk
    public func save() async throws {
        let data = try JSONEncoder().encode(graph)
        let url = identifierGraphURL()
        try data.write(to: url)
    }

    /// Load graph from disk
    public func load() async throws {
        let url = identifierGraphURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let data = try Data(contentsOf: url)
        graph = try JSONDecoder().decode([PaperIdentifier: Set<PaperIdentifier>].self, from: data)
    }
}
```

### Search Result Deduplication

```swift
public actor DeduplicationService {
    private let identifierGraph: IdentifierGraph

    public init(identifierGraph: IdentifierGraph = .shared) {
        self.identifierGraph = identifierGraph
    }

    /// Deduplicate search results from multiple sources
    public func deduplicate(_ results: [SearchResult]) async -> [DeduplicatedResult] {
        var seen: [PaperIdentifier: DeduplicatedResult] = [:]
        var fuzzyIndex: [String: DeduplicatedResult] = [:]  // Title-based

        for result in results {
            // Extract all identifiers from this result
            let identifiers = extractIdentifiers(from: result)

            // Check if any identifier matches existing result
            var matchedResult: DeduplicatedResult?

            for id in identifiers {
                // Check exact match
                if let existing = seen[id] {
                    matchedResult = existing
                    break
                }

                // Check graph for equivalent IDs
                let equivalents = await identifierGraph.equivalentIdentifiers(for: id)
                for equiv in equivalents {
                    if let existing = seen[equiv] {
                        matchedResult = existing
                        break
                    }
                }
            }

            // Fuzzy match by title if no ID match
            if matchedResult == nil {
                let titleKey = normalizeTitleForMatching(result.title)
                if let existing = fuzzyIndex[titleKey],
                   authorsMatch(result.authors, existing.primaryResult.authors) {
                    matchedResult = existing
                }
            }

            if var existing = matchedResult {
                // Add as alternate source
                existing.alternateResults.append(result)
                existing.allIdentifiers.formUnion(identifiers)

                // Update seen map
                for id in identifiers {
                    seen[id] = existing
                }

                // Link identifiers in graph
                if let primaryID = identifiers.first,
                   let existingID = existing.allIdentifiers.first {
                    await identifierGraph.link(primaryID, existingID)
                }
            } else {
                // New unique result
                let deduped = DeduplicatedResult(
                    primaryResult: result,
                    alternateResults: [],
                    allIdentifiers: Set(identifiers)
                )

                for id in identifiers {
                    seen[id] = deduped
                }
                fuzzyIndex[normalizeTitleForMatching(result.title)] = deduped
            }
        }

        return Array(Set(seen.values))
    }

    // MARK: - Private

    private func extractIdentifiers(from result: SearchResult) -> [PaperIdentifier] {
        var ids: [PaperIdentifier] = []

        // Primary ID from the source
        switch result.sourceID {
        case "crossref":
            ids.append(PaperIdentifier(type: .doi, value: result.id))
        case "arxiv":
            ids.append(PaperIdentifier(type: .arxiv, value: result.id))
        case "pubmed":
            ids.append(PaperIdentifier(type: .pmid, value: result.id))
        case "ads":
            ids.append(PaperIdentifier(type: .bibcode, value: result.id))
        case "semantic-scholar":
            ids.append(PaperIdentifier(type: .semanticScholar, value: result.id))
        case "openalex":
            ids.append(PaperIdentifier(type: .openAlex, value: result.id))
        default:
            break
        }

        // Extract DOI from result metadata if present
        if let doi = result.doi, result.sourceID != "crossref" {
            ids.append(PaperIdentifier(type: .doi, value: doi))
        }

        // Extract arXiv ID if present
        if let arxiv = result.arxivID, result.sourceID != "arxiv" {
            ids.append(PaperIdentifier(type: .arxiv, value: arxiv))
        }

        return ids
    }

    private func normalizeTitleForMatching(_ title: String) -> String {
        title
            .lowercased()
            .replacingOccurrences(of: #"[^\w\s]"#, with: "", options: .regularExpression)
            .components(separatedBy: .whitespaces)
            .filter { $0.count > 2 }  // Remove short words
            .sorted()
            .joined(separator: " ")
    }

    private func authorsMatch(_ authors1: [String], _ authors2: [String]) -> Bool {
        // Compare first author last names
        guard let first1 = authors1.first?.components(separatedBy: " ").last?.lowercased(),
              let first2 = authors2.first?.components(separatedBy: " ").last?.lowercased() else {
            return false
        }
        return first1 == first2
    }
}
```

### Deduplicated Result Type

```swift
public struct DeduplicatedResult: Identifiable, Hashable {
    public let id: String  // UUID

    /// Primary result (highest quality source)
    public var primaryResult: SearchResult

    /// Same paper from other sources
    public var alternateResults: [SearchResult]

    /// All known identifiers
    public var allIdentifiers: Set<PaperIdentifier>

    /// All sources that have this paper
    public var sources: [String] {
        [primaryResult.sourceID] + alternateResults.map(\.sourceID)
    }

    /// Best DOI if available
    public var doi: String? {
        allIdentifiers.first { $0.type == .doi }?.value
    }

    public init(primaryResult: SearchResult, alternateResults: [SearchResult], allIdentifiers: Set<PaperIdentifier>) {
        self.id = UUID().uuidString
        self.primaryResult = primaryResult
        self.alternateResults = alternateResults
        self.allIdentifiers = allIdentifiers
    }
}
```

### Source Priority for Primary Selection

```swift
extension DeduplicationService {
    /// Select best result as primary based on source quality
    func selectPrimaryResult(from results: [SearchResult]) -> SearchResult {
        let priority: [String: Int] = [
            "crossref": 1,      // Publisher metadata, has DOI
            "pubmed": 2,        // Curated biomedical
            "ads": 3,           // Curated astronomy
            "semantic-scholar": 4,
            "openalex": 5,
            "arxiv": 6,         // Preprints, may be outdated
            "dblp": 7
        ]

        return results.min { r1, r2 in
            (priority[r1.sourceID] ?? 99) < (priority[r2.sourceID] ?? 99)
        } ?? results[0]
    }
}
```

### UI Integration

```swift
struct SearchResultRow: View {
    let result: DeduplicatedResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(result.primaryResult.title)
                .font(.headline)

            Text(result.primaryResult.authors.joined(separator: ", "))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack {
                // Show source badges
                ForEach(result.sources, id: \.self) { sourceID in
                    SourceBadge(sourceID: sourceID)
                }

                Spacer()

                // Show identifier badges
                if result.doi != nil {
                    Badge("DOI", color: .blue)
                }
                if result.allIdentifiers.contains(where: { $0.type == .arxiv }) {
                    Badge("arXiv", color: .orange)
                }
            }
        }
    }
}

struct SourceBadge: View {
    let sourceID: String

    var body: some View {
        Text(sourceID.capitalized)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.2))
            .clipShape(Capsule())
    }
}
```

## Consequences

### Positive

- Search results are cleaner (no duplicates)
- Users see all available sources for a paper
- Identifier graph improves over time
- Best metadata selected automatically

### Negative

- Fuzzy matching may have false positives/negatives
- Graph storage grows with usage
- Initial dedup adds latency to search

### Mitigations

- Conservative fuzzy matching (title + first author)
- Periodic graph pruning (remove rarely-used entries)
- Async dedup with progressive UI updates

## Alternatives Considered

### No Deduplication

Forces users to manually identify duplicates. Poor UX.

### Server-Side Deduplication

Would require our own backend to maintain a global identifier graph. Against offline-first design.

### DOI-Only Matching

Would miss preprints and older papers without DOIs. Insufficient coverage.

### Title-Only Fuzzy Matching

Too many false positives. Different papers can have similar titles.
