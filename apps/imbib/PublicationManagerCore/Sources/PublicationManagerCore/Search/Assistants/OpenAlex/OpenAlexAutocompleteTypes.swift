//
//  OpenAlexAutocompleteTypes.swift
//  PublicationManagerCore
//
//  The OpenAlex autocomplete response shapes the query assistant's
//  suggestion popover decodes (kept from the retired OpenAlex source plugin:
//  autocomplete is query assistance, not a source operation, so it has no
//  verb in the source convention).
//

import Foundation

// MARK: - OpenAlex Autocomplete

/// Entity types that support autocomplete in OpenAlex.
public enum OpenAlexEntityType: String, Sendable, CaseIterable {
    case authors
    case institutions
    case sources
    case concepts
    case topics
    case works
    case funders
    case publishers

    public var displayName: String {
        switch self {
        case .authors: return "Authors"
        case .institutions: return "Institutions"
        case .sources: return "Journals & Sources"
        case .concepts: return "Concepts"
        case .topics: return "Topics"
        case .works: return "Works"
        case .funders: return "Funders"
        case .publishers: return "Publishers"
        }
    }

    /// The filter field syntax to use when inserting this entity into a query.
    public var filterPrefix: String {
        switch self {
        case .authors: return "authorships.author.id:"
        case .institutions: return "authorships.institutions.id:"
        case .sources: return "primary_location.source.id:"
        case .concepts: return "concepts.id:"
        case .topics: return "topics.id:"
        case .works: return "cites:"
        case .funders: return "grants.funder:"
        case .publishers: return "primary_location.source.host_organization:"
        }
    }

    /// Alternative name-based filter prefix for human-readable queries.
    public var nameFilterPrefix: String? {
        switch self {
        case .authors: return "authorships.author.display_name.search:"
        case .institutions: return "authorships.institutions.display_name.search:"
        case .sources: return "primary_location.source.display_name.search:"
        case .concepts: return nil // Concepts don't have name search
        case .topics: return "topics.display_name.search:"
        case .works: return nil
        case .funders: return nil
        case .publishers: return nil
        }
    }
}

/// Response from OpenAlex autocomplete endpoint.
public struct OpenAlexAutocompleteResponse: Decodable, Sendable {
    public let results: [OpenAlexAutocompleteSuggestion]
    public let meta: OpenAlexAutocompleteMeta?
}

/// Metadata for autocomplete response.
public struct OpenAlexAutocompleteMeta: Decodable, Sendable {
    public let count: Int?
    public let dbResponseTimeMs: Int?

    enum CodingKeys: String, CodingKey {
        case count
        case dbResponseTimeMs = "db_response_time_ms"
    }
}

/// A single autocomplete suggestion from OpenAlex.
public struct OpenAlexAutocompleteSuggestion: Decodable, Sendable, Identifiable, Hashable {
    public let id: String
    public let displayName: String
    public let hint: String?
    public let citedByCount: Int?
    public let worksCount: Int?
    public let entityType: String
    public let externalId: String?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case hint
        case citedByCount = "cited_by_count"
        case worksCount = "works_count"
        case entityType = "entity_type"
        case externalId = "external_id"
    }

    /// The OpenAlex entity type as an enum.
    public var parsedEntityType: OpenAlexEntityType? {
        // Entity type comes back as singular (e.g., "author", "institution")
        // Map to our plural enum
        switch entityType.lowercased() {
        case "author": return .authors
        case "institution": return .institutions
        case "source": return .sources
        case "concept": return .concepts
        case "topic": return .topics
        case "work": return .works
        case "funder": return .funders
        case "publisher": return .publishers
        default: return nil
        }
    }

    /// Extract the OpenAlex ID from the full URL.
    /// Example: "https://openalex.org/A1234567890" -> "A1234567890"
    public var shortID: String {
        if let lastComponent = id.split(separator: "/").last {
            return String(lastComponent)
        }
        return id
    }

    /// Format for insertion into a query.
    public func queryValue(useID: Bool = true) -> String {
        if useID {
            return shortID
        } else {
            // Wrap name in quotes if it contains spaces
            if displayName.contains(" ") {
                return "\"\(displayName)\""
            }
            return displayName
        }
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public static func == (lhs: OpenAlexAutocompleteSuggestion, rhs: OpenAlexAutocompleteSuggestion) -> Bool {
        lhs.id == rhs.id
    }
}

