//
//  OpenAlexTypes.swift
//  PublicationManagerCore
//
//  Types for parsing OpenAlex API responses.
//  Based on OpenAlex API v1 (https://docs.openalex.org)
//

import Foundation

// MARK: - OpenAlex Search Response

/// Top-level response from OpenAlex works search endpoint.
public struct OpenAlexSearchResponse: Decodable, Sendable {
    public let meta: OpenAlexMeta
    public let results: [OpenAlexWork]
    public let groupBy: [OpenAlexGroupBy]?

    enum CodingKeys: String, CodingKey {
        case meta
        case results
        case groupBy = "group_by"
    }
}

/// Metadata about the search response.
public struct OpenAlexMeta: Decodable, Sendable {
    public let count: Int
    public let dbResponseTimeMs: Int?
    public let page: Int?
    public let perPage: Int?
    public let nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case count
        case dbResponseTimeMs = "db_response_time_ms"
        case page
        case perPage = "per_page"
        case nextCursor = "next_cursor"
    }
}

/// Group-by facet result.
public struct OpenAlexGroupBy: Decodable, Sendable {
    public let key: String
    public let keyDisplayName: String?
    public let count: Int

    enum CodingKeys: String, CodingKey {
        case key
        case keyDisplayName = "key_display_name"
        case count
    }
}

// MARK: - OpenAlex Work

/// A scholarly work in OpenAlex.
public struct OpenAlexWork: Decodable, Sendable {
    public let id: String
    public let doi: String?
    public let title: String?
    public let displayName: String?
    public let publicationYear: Int?
    public let publicationDate: String?
    public let type: OpenAlexWorkType?
    public let typeCrossref: String?
    public let language: String?

    // Identifiers
    public let ids: OpenAlexIDs?

    // Bibliographic data
    public let authorships: [OpenAlexAuthorship]?
    public let primaryLocation: OpenAlexLocation?
    public let locations: [OpenAlexLocation]?
    public let bestOaLocation: OpenAlexLocation?

    // Open access info
    public let openAccess: OpenAlexOpenAccess?

    // Citation data
    public let citedByCount: Int?
    public let citedByPercentileYear: OpenAlexPercentile?
    public let biblio: OpenAlexBiblio?
    public let referencedWorksCount: Int?
    public let referencedWorks: [String]?
    public let relatedWorks: [String]?

    // Abstract (stored as inverted index for compression)
    public let abstractInvertedIndex: [String: [Int]]?

    // Classification
    public let topics: [OpenAlexTopicScore]?
    public let keywords: [OpenAlexKeyword]?
    public let concepts: [OpenAlexConceptScore]?
    public let mesh: [OpenAlexMeSH]?
    public let sustainableDevelopmentGoals: [OpenAlexSDG]?

    // Funding
    public let grants: [OpenAlexGrant]?

    // Metrics
    public let countsByYear: [OpenAlexCountsByYear]?
    public let citedByApiUrl: String?
    public let updatedDate: String?
    public let createdDate: String?

    enum CodingKeys: String, CodingKey {
        case id
        case doi
        case title
        case displayName = "display_name"
        case publicationYear = "publication_year"
        case publicationDate = "publication_date"
        case type
        case typeCrossref = "type_crossref"
        case language
        case ids
        case authorships
        case primaryLocation = "primary_location"
        case locations
        case bestOaLocation = "best_oa_location"
        case openAccess = "open_access"
        case citedByCount = "cited_by_count"
        case citedByPercentileYear = "cited_by_percentile_year"
        case biblio
        case referencedWorksCount = "referenced_works_count"
        case referencedWorks = "referenced_works"
        case relatedWorks = "related_works"
        case abstractInvertedIndex = "abstract_inverted_index"
        case topics
        case keywords
        case concepts
        case mesh
        case sustainableDevelopmentGoals = "sustainable_development_goals"
        case grants
        case countsByYear = "counts_by_year"
        case citedByApiUrl = "cited_by_api_url"
        case updatedDate = "updated_date"
        case createdDate = "created_date"
    }
}

// MARK: - OpenAlex IDs

/// Various identifiers for a work.
public struct OpenAlexIDs: Decodable, Sendable {
    public let openalex: String?
    public let doi: String?
    public let pmid: String?
    public let pmcid: String?
    public let mag: String?  // Microsoft Academic Graph

    enum CodingKeys: String, CodingKey {
        case openalex
        case doi
        case pmid
        case pmcid
        case mag
    }
}

// MARK: - OpenAlex Authorship

/// Authorship information including affiliations.
public struct OpenAlexAuthorship: Decodable, Sendable {
    public let authorPosition: String?
    public let author: OpenAlexAuthor
    public let institutions: [OpenAlexInstitution]?
    public let countries: [String]?
    public let isCorresponding: Bool?
    public let rawAuthorName: String?
    public let rawAffiliationStrings: [String]?

    enum CodingKeys: String, CodingKey {
        case authorPosition = "author_position"
        case author
        case institutions
        case countries
        case isCorresponding = "is_corresponding"
        case rawAuthorName = "raw_author_name"
        case rawAffiliationStrings = "raw_affiliation_strings"
    }
}

/// Author information.
public struct OpenAlexAuthor: Decodable, Sendable {
    public let id: String?
    public let displayName: String
    public let orcid: String?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case orcid
    }
}

// MARK: - OpenAlex Institution

/// Institution (university, company, etc.).
public struct OpenAlexInstitution: Decodable, Sendable {
    public let id: String?
    public let displayName: String?
    public let ror: String?  // Research Organization Registry ID
    public let countryCode: String?
    public let type: String?
    public let lineage: [String]?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case ror
        case countryCode = "country_code"
        case type
        case lineage
    }
}

// MARK: - OpenAlex Location

/// Where the work is hosted (journal, repository, etc.).
public struct OpenAlexLocation: Decodable, Sendable {
    public let isOa: Bool?
    public let landingPageUrl: String?
    public let pdfUrl: String?
    public let source: OpenAlexVenue?
    public let license: String?
    public let licenseId: String?
    public let version: String?
    public let isAccepted: Bool?
    public let isPublished: Bool?

    enum CodingKeys: String, CodingKey {
        case isOa = "is_oa"
        case landingPageUrl = "landing_page_url"
        case pdfUrl = "pdf_url"
        case source
        case license
        case licenseId = "license_id"
        case version
        case isAccepted = "is_accepted"
        case isPublished = "is_published"
    }
}

/// Source (journal, repository, conference) where a work is published.
public struct OpenAlexVenue: Decodable, Sendable {
    public let id: String?
    public let displayName: String?
    public let issn: [String]?
    public let issnL: String?
    public let isOa: Bool?
    public let isInDoaj: Bool?
    public let hostOrganization: String?
    public let hostOrganizationName: String?
    public let hostOrganizationLineage: [String]?
    public let hostOrganizationLineageNames: [String]?
    public let type: String?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case issn
        case issnL = "issn_l"
        case isOa = "is_oa"
        case isInDoaj = "is_in_doaj"
        case hostOrganization = "host_organization"
        case hostOrganizationName = "host_organization_name"
        case hostOrganizationLineage = "host_organization_lineage"
        case hostOrganizationLineageNames = "host_organization_lineage_names"
        case type
    }
}

// MARK: - OpenAlex Open Access

/// Open access status information.
public struct OpenAlexOpenAccess: Decodable, Sendable {
    public let isOa: Bool
    public let oaStatus: OpenAlexOAStatus?
    public let oaUrl: String?
    public let anyRepositoryHasFulltext: Bool?

    enum CodingKeys: String, CodingKey {
        case isOa = "is_oa"
        case oaStatus = "oa_status"
        case oaUrl = "oa_url"
        case anyRepositoryHasFulltext = "any_repository_has_fulltext"
    }
}

/// Open access status values.
public enum OpenAlexOAStatus: String, Decodable, Sendable {
    case gold       // Published in OA journal
    case green      // Self-archived in repository
    case hybrid     // OA in subscription journal
    case bronze     // Free to read but not open license
    case closed     // Not freely accessible
    case diamond    // OA journal with no APCs

    public var displayName: String {
        switch self {
        case .gold: return "Gold OA"
        case .green: return "Green OA"
        case .hybrid: return "Hybrid OA"
        case .bronze: return "Bronze OA"
        case .closed: return "Closed Access"
        case .diamond: return "Diamond OA"
        }
    }

    /// Convert to the common OpenAccessStatus enum used in enrichment
    public var enrichmentStatus: OpenAccessStatus {
        switch self {
        case .gold: return .gold
        case .green: return .green
        case .hybrid: return .hybrid
        case .bronze: return .bronze
        case .closed: return .closed
        case .diamond: return .gold  // Map diamond to gold for now
        }
    }
}

// MARK: - OpenAlex Biblio

/// Bibliographic details.
public struct OpenAlexBiblio: Decodable, Sendable {
    public let volume: String?
    public let issue: String?
    public let firstPage: String?
    public let lastPage: String?

    enum CodingKeys: String, CodingKey {
        case volume
        case issue
        case firstPage = "first_page"
        case lastPage = "last_page"
    }

    /// Pages in standard format (e.g., "100-120")
    public var pages: String? {
        if let first = firstPage, let last = lastPage {
            return "\(first)-\(last)"
        }
        return firstPage
    }
}

// MARK: - OpenAlex Percentile

/// Citation percentile information.
public struct OpenAlexPercentile: Decodable, Sendable {
    public let min: Double?
    public let max: Double?
}

// MARK: - OpenAlex Topics

/// Topic classification with score.
public struct OpenAlexTopicScore: Decodable, Sendable {
    public let id: String
    public let displayName: String
    public let score: Double?
    public let subfield: OpenAlexDehydratedTopic?
    public let field: OpenAlexDehydratedTopic?
    public let domain: OpenAlexDehydratedTopic?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case score
        case subfield
        case field
        case domain
    }
}

/// Dehydrated topic (ID and name only).
public struct OpenAlexDehydratedTopic: Decodable, Sendable {
    public let id: String
    public let displayName: String

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
    }
}

/// Keyword extracted from the work.
public struct OpenAlexKeyword: Decodable, Sendable {
    public let id: String?
    public let displayName: String
    public let score: Double?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case score
    }
}

/// Legacy concept classification with score.
public struct OpenAlexConceptScore: Decodable, Sendable {
    public let id: String
    public let wikidata: String?
    public let displayName: String
    public let level: Int?
    public let score: Double?

    enum CodingKeys: String, CodingKey {
        case id
        case wikidata
        case displayName = "display_name"
        case level
        case score
    }
}

/// MeSH term.
public struct OpenAlexMeSH: Decodable, Sendable {
    public let descriptorUi: String
    public let descriptorName: String
    public let qualifierUi: String?
    public let qualifierName: String?
    public let isMajorTopic: Bool?

    enum CodingKeys: String, CodingKey {
        case descriptorUi = "descriptor_ui"
        case descriptorName = "descriptor_name"
        case qualifierUi = "qualifier_ui"
        case qualifierName = "qualifier_name"
        case isMajorTopic = "is_major_topic"
    }
}

/// Sustainable Development Goal classification.
public struct OpenAlexSDG: Decodable, Sendable {
    public let id: String
    public let displayName: String
    public let score: Double?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case score
    }
}

// MARK: - OpenAlex Grant

/// Funding grant information.
public struct OpenAlexGrant: Decodable, Sendable {
    public let funder: String?
    public let funderDisplayName: String?
    public let awardId: String?

    enum CodingKeys: String, CodingKey {
        case funder
        case funderDisplayName = "funder_display_name"
        case awardId = "award_id"
    }
}

// MARK: - OpenAlex Counts By Year

/// Citation counts per year.
public struct OpenAlexCountsByYear: Decodable, Sendable {
    public let year: Int
    public let citedByCount: Int

    enum CodingKeys: String, CodingKey {
        case year
        case citedByCount = "cited_by_count"
    }
}

// MARK: - OpenAlex Work Type

/// Types of scholarly works.
public enum OpenAlexWorkType: String, Decodable, Sendable, CaseIterable {
    case article
    case bookChapter = "book-chapter"
    case dissertation
    case book
    case dataset
    case paratext
    case other
    case referenceEntry = "reference-entry"
    case report
    case peerReview = "peer-review"
    case standard
    case editorial
    case erratum
    case letter
    case proceedings = "proceedings-article"
    case monograph
    case review
    case bookPart = "book-part"
    case component
    case grant
    case libguides
    case supplementaryMaterials = "supplementary-materials"

    public var displayName: String {
        switch self {
        case .article: return "Article"
        case .bookChapter: return "Book Chapter"
        case .dissertation: return "Dissertation"
        case .book: return "Book"
        case .dataset: return "Dataset"
        case .paratext: return "Paratext"
        case .other: return "Other"
        case .referenceEntry: return "Reference Entry"
        case .report: return "Report"
        case .peerReview: return "Peer Review"
        case .standard: return "Standard"
        case .editorial: return "Editorial"
        case .erratum: return "Erratum"
        case .letter: return "Letter"
        case .proceedings: return "Proceedings"
        case .monograph: return "Monograph"
        case .review: return "Review"
        case .bookPart: return "Book Part"
        case .component: return "Component"
        case .grant: return "Grant"
        case .libguides: return "LibGuides"
        case .supplementaryMaterials: return "Supplementary Materials"
        }
    }

    public var bibtexType: String {
        switch self {
        case .article, .peerReview, .editorial, .erratum, .letter, .review:
            return "article"
        case .book, .monograph:
            return "book"
        case .bookChapter, .bookPart, .referenceEntry:
            return "incollection"
        case .proceedings:
            return "inproceedings"
        case .dissertation:
            return "phdthesis"
        case .report:
            return "techreport"
        case .dataset, .paratext, .other, .standard, .component, .grant, .libguides, .supplementaryMaterials:
            return "misc"
        }
    }

    public var risType: String {
        switch self {
        case .article, .peerReview, .editorial, .erratum, .letter, .review:
            return "JOUR"
        case .book, .monograph:
            return "BOOK"
        case .bookChapter, .bookPart, .referenceEntry:
            return "CHAP"
        case .proceedings:
            return "CONF"
        case .dissertation:
            return "THES"
        case .report:
            return "RPRT"
        case .dataset:
            return "DATA"
        case .paratext, .other, .standard, .component, .grant, .libguides, .supplementaryMaterials:
            return "GEN"
        }
    }
}

// MARK: - OpenAlex Query Fields

/// Known filter fields for OpenAlex search.
public enum OpenAlexFilterField: String, Sendable, CaseIterable {
    case title = "title.search"
    case abstract = "abstract.search"
    case displayName = "display_name.search"
    case defaultSearch = "default.search"
    case author = "authorships.author.display_name.search"
    case authorID = "authorships.author.id"
    case authorORCID = "authorships.author.orcid"
    case institution = "authorships.institutions.display_name.search"
    case institutionID = "authorships.institutions.id"
    case institutionROR = "authorships.institutions.ror"
    case institutionCountry = "authorships.institutions.country_code"
    case publicationYear = "publication_year"
    case fromPublicationDate = "from_publication_date"
    case toPublicationDate = "to_publication_date"
    case sourceDisplayName = "primary_location.source.display_name.search"
    case sourceID = "primary_location.source.id"
    case doi = "doi"
    case pmid = "ids.pmid"
    case pmcid = "ids.pmcid"
    case openAlexID = "ids.openalex"
    case type = "type"
    case isOA = "open_access.is_oa"
    case oaStatus = "open_access.oa_status"
    case hasDOI = "has_doi"
    case hasAbstract = "has_abstract"
    case hasFulltext = "has_fulltext"
    case hasPDF = "has_pdf_url"
    case hasORCID = "has_orcid"
    case hasReferences = "has_references"
    case citedByCount = "cited_by_count"
    case referencedWorksCount = "referenced_works_count"
    case topicID = "topics.id"
    case topicDisplayName = "topics.display_name.search"
    case conceptID = "concepts.id"
    case funderID = "grants.funder"
    case grantAwardID = "grants.award_id"
    case language = "language"
    case cites = "cites"
    case citedBy = "cited_by"
    case relatedTo = "related_to"

    public var displayName: String {
        switch self {
        case .title: return "Title"
        case .abstract: return "Abstract"
        case .displayName: return "Display Name"
        case .defaultSearch: return "Default Search"
        case .author: return "Author Name"
        case .authorID: return "Author ID"
        case .authorORCID: return "Author ORCID"
        case .institution: return "Institution"
        case .institutionID: return "Institution ID"
        case .institutionROR: return "Institution ROR"
        case .institutionCountry: return "Institution Country"
        case .publicationYear: return "Publication Year"
        case .fromPublicationDate: return "From Date"
        case .toPublicationDate: return "To Date"
        case .sourceDisplayName: return "Journal/Source"
        case .sourceID: return "Source ID"
        case .doi: return "DOI"
        case .pmid: return "PubMed ID"
        case .pmcid: return "PMC ID"
        case .openAlexID: return "OpenAlex ID"
        case .type: return "Work Type"
        case .isOA: return "Is Open Access"
        case .oaStatus: return "OA Status"
        case .hasDOI: return "Has DOI"
        case .hasAbstract: return "Has Abstract"
        case .hasFulltext: return "Has Full Text"
        case .hasPDF: return "Has PDF URL"
        case .hasORCID: return "Has ORCID"
        case .hasReferences: return "Has References"
        case .citedByCount: return "Citation Count"
        case .referencedWorksCount: return "Reference Count"
        case .topicID: return "Topic ID"
        case .topicDisplayName: return "Topic"
        case .conceptID: return "Concept ID"
        case .funderID: return "Funder ID"
        case .grantAwardID: return "Grant Award ID"
        case .language: return "Language"
        case .cites: return "Cites Work"
        case .citedBy: return "Cited By Work"
        case .relatedTo: return "Related To Work"
        }
    }

    public var example: String {
        switch self {
        case .title: return "title.search:neural network"
        case .abstract: return "abstract.search:machine learning"
        case .displayName: return "display_name.search:quantum"
        case .defaultSearch: return "default.search:climate change"
        case .author: return "authorships.author.display_name.search:Einstein"
        case .authorID: return "authorships.author.id:A1234567890"
        case .authorORCID: return "authorships.author.orcid:0000-0001-2345-6789"
        case .institution: return "authorships.institutions.display_name.search:MIT"
        case .institutionID: return "authorships.institutions.id:I1234567890"
        case .institutionROR: return "authorships.institutions.ror:https://ror.org/01abcde99"
        case .institutionCountry: return "authorships.institutions.country_code:US"
        case .publicationYear: return "publication_year:2023 or publication_year:2020-2024"
        case .fromPublicationDate: return "from_publication_date:2023-01-01"
        case .toPublicationDate: return "to_publication_date:2023-12-31"
        case .sourceDisplayName: return "primary_location.source.display_name.search:Nature"
        case .sourceID: return "primary_location.source.id:S1234567890"
        case .doi: return "doi:10.1038/nature12373"
        case .pmid: return "ids.pmid:12345678"
        case .pmcid: return "ids.pmcid:PMC1234567"
        case .openAlexID: return "ids.openalex:W1234567890"
        case .type: return "type:article"
        case .isOA: return "open_access.is_oa:true"
        case .oaStatus: return "open_access.oa_status:gold"
        case .hasDOI: return "has_doi:true"
        case .hasAbstract: return "has_abstract:true"
        case .hasFulltext: return "has_fulltext:true"
        case .hasPDF: return "has_pdf_url:true"
        case .hasORCID: return "has_orcid:true"
        case .hasReferences: return "has_references:true"
        case .citedByCount: return "cited_by_count:>100"
        case .referencedWorksCount: return "referenced_works_count:>10"
        case .topicID: return "topics.id:T1234567890"
        case .topicDisplayName: return "topics.display_name.search:Machine Learning"
        case .conceptID: return "concepts.id:C1234567890"
        case .funderID: return "grants.funder:F1234567890"
        case .grantAwardID: return "grants.award_id:1234567"
        case .language: return "language:en"
        case .cites: return "cites:W1234567890"
        case .citedBy: return "cited_by:W1234567890"
        case .relatedTo: return "related_to:W1234567890"
        }
    }
}
