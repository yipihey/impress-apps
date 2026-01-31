//
//  ArtifactMention.swift
//  MessageManagerCore
//
//  Represents a mention of an artifact within a message, including
//  the context in which it was mentioned and its relationship to the conversation.
//

import Foundation

// MARK: - Artifact Mention

/// A mention of an artifact within a specific message.
/// Captures the context and relationship of how the artifact was referenced.
public struct ArtifactMention: Identifiable, Codable, Sendable, Equatable {
    /// Unique identifier for this mention
    public let id: UUID

    /// The artifact being mentioned
    public let artifactId: UUID

    /// The artifact URI (denormalized for quick access)
    public let artifactURI: String

    /// The message containing this mention
    public let messageId: UUID

    /// The conversation containing this mention
    public let conversationId: UUID

    /// How the artifact was mentioned
    public let mentionType: ArtifactMentionType

    /// Character offset in the message content where the mention appears
    public let characterOffset: Int?

    /// Length of the mention in characters
    public let characterLength: Int?

    /// Surrounding text context (snippet around the mention)
    public let contextSnippet: String?

    /// When this mention was recorded
    public let recordedAt: Date

    /// The actor who made this mention (user or agent ID)
    public let mentionedBy: String?

    /// Whether this is the first mention of the artifact in the conversation
    public let isFirstMention: Bool

    /// Initialize a new artifact mention.
    public init(
        id: UUID = UUID(),
        artifactId: UUID,
        artifactURI: String,
        messageId: UUID,
        conversationId: UUID,
        mentionType: ArtifactMentionType,
        characterOffset: Int? = nil,
        characterLength: Int? = nil,
        contextSnippet: String? = nil,
        recordedAt: Date = Date(),
        mentionedBy: String? = nil,
        isFirstMention: Bool = false
    ) {
        self.id = id
        self.artifactId = artifactId
        self.artifactURI = artifactURI
        self.messageId = messageId
        self.conversationId = conversationId
        self.mentionType = mentionType
        self.characterOffset = characterOffset
        self.characterLength = characterLength
        self.contextSnippet = contextSnippet
        self.recordedAt = recordedAt
        self.mentionedBy = mentionedBy
        self.isFirstMention = isFirstMention
    }
}

// MARK: - Mention Extraction

/// Utility for extracting artifact mentions from message content.
public struct ArtifactMentionExtractor {
    /// Pattern for matching impress:// URIs
    private static let impressURIPattern = try! NSRegularExpression(
        pattern: #"impress://[a-zA-Z0-9_-]+/[a-zA-Z0-9/_@.-]+"#,
        options: []
    )

    /// Pattern for matching cite keys in square brackets (e.g., [Fowler2012])
    private static let citeKeyPattern = try! NSRegularExpression(
        pattern: #"\[([A-Z][a-zA-Z]*\d{4}[a-z]?)\]"#,
        options: []
    )

    /// Pattern for matching DOIs
    private static let doiPattern = try! NSRegularExpression(
        pattern: #"(?:doi:|https?://doi\.org/)(10\.\d{4,}/[^\s]+)"#,
        options: [.caseInsensitive]
    )

    /// Pattern for matching arXiv IDs
    private static let arxivPattern = try! NSRegularExpression(
        pattern: #"(?:arXiv:|https?://arxiv\.org/abs/)(\d{4}\.\d{4,5}(?:v\d+)?)"#,
        options: [.caseInsensitive]
    )

    /// Pattern for matching GitHub/GitLab URLs
    private static let gitRepoPattern = try! NSRegularExpression(
        pattern: #"https?://(?:github|gitlab)\.com/([a-zA-Z0-9_-]+)/([a-zA-Z0-9_-]+)(?:/(?:commit|tree)/([a-f0-9]+))?"#,
        options: [.caseInsensitive]
    )

    /// Context characters to include around a mention.
    public static let contextRadius = 50

    /// Extract all artifact mentions from message content.
    /// - Parameters:
    ///   - content: The message content to scan
    ///   - messageId: The ID of the containing message
    ///   - conversationId: The ID of the containing conversation
    ///   - mentionedBy: The actor making the mention
    ///   - existingArtifacts: Artifacts already in the conversation (to determine first mention)
    /// - Returns: Array of extracted mentions
    public static func extractMentions(
        from content: String,
        messageId: UUID,
        conversationId: UUID,
        mentionedBy: String?,
        existingArtifacts: Set<String> = []
    ) -> [ExtractedMention] {
        var mentions: [ExtractedMention] = []
        let nsContent = content as NSString
        let fullRange = NSRange(location: 0, length: nsContent.length)

        // Extract impress:// URIs
        let impressMatches = impressURIPattern.matches(in: content, options: [], range: fullRange)
        for match in impressMatches {
            let uri = nsContent.substring(with: match.range)
            if let artifactURI = ArtifactURI(uri: uri) {
                mentions.append(ExtractedMention(
                    uri: artifactURI,
                    range: match.range,
                    mentionType: existingArtifacts.contains(uri) ? .referenced : .introduced,
                    contextSnippet: extractContext(from: nsContent, around: match.range)
                ))
            }
        }

        // Extract cite keys in brackets
        let citeKeyMatches = citeKeyPattern.matches(in: content, options: [], range: fullRange)
        for match in citeKeyMatches {
            if match.numberOfRanges >= 2 {
                let citeKey = nsContent.substring(with: match.range(at: 1))
                let uri = ArtifactURI.paper(citeKey: citeKey)
                let isFirstMention = !existingArtifacts.contains(uri.uri)
                mentions.append(ExtractedMention(
                    uri: uri,
                    range: match.range,
                    mentionType: isFirstMention ? .introduced : .cited,
                    contextSnippet: extractContext(from: nsContent, around: match.range)
                ))
            }
        }

        // Extract DOIs
        let doiMatches = doiPattern.matches(in: content, options: [], range: fullRange)
        for match in doiMatches {
            if match.numberOfRanges >= 2 {
                let doi = nsContent.substring(with: match.range(at: 1))
                // DOIs don't map directly to impress:// URIs, but we can track them
                // In a full implementation, this would look up the cite key from DOI
                mentions.append(ExtractedMention(
                    uri: ArtifactURI(
                        type: .paper,
                        provider: "doi",
                        resourcePath: doi
                    ),
                    range: match.range,
                    mentionType: .cited,
                    contextSnippet: extractContext(from: nsContent, around: match.range)
                ))
            }
        }

        // Extract arXiv IDs
        let arxivMatches = arxivPattern.matches(in: content, options: [], range: fullRange)
        for match in arxivMatches {
            if match.numberOfRanges >= 2 {
                let arxivId = nsContent.substring(with: match.range(at: 1))
                mentions.append(ExtractedMention(
                    uri: ArtifactURI(
                        type: .paper,
                        provider: "arxiv",
                        resourcePath: arxivId
                    ),
                    range: match.range,
                    mentionType: .cited,
                    contextSnippet: extractContext(from: nsContent, around: match.range)
                ))
            }
        }

        // Extract GitHub/GitLab URLs
        let gitMatches = gitRepoPattern.matches(in: content, options: [], range: fullRange)
        for match in gitMatches {
            if match.numberOfRanges >= 3 {
                let owner = nsContent.substring(with: match.range(at: 1))
                let repo = nsContent.substring(with: match.range(at: 2))
                let commit = match.numberOfRanges >= 4 && match.range(at: 3).location != NSNotFound
                    ? nsContent.substring(with: match.range(at: 3))
                    : "HEAD"

                // Detect host from the match
                let fullMatch = nsContent.substring(with: match.range)
                let host = fullMatch.contains("gitlab") ? "gitlab.com" : "github.com"

                let uri = ArtifactURI.repository(host: host, owner: owner, repo: repo, commit: commit)
                let isFirstMention = !existingArtifacts.contains(uri.uri)
                mentions.append(ExtractedMention(
                    uri: uri,
                    range: match.range,
                    mentionType: isFirstMention ? .introduced : .referenced,
                    contextSnippet: extractContext(from: nsContent, around: match.range)
                ))
            }
        }

        return mentions
    }

    /// Extract context around a mention.
    private static func extractContext(from content: NSString, around range: NSRange) -> String {
        let start = max(0, range.location - contextRadius)
        let end = min(content.length, range.location + range.length + contextRadius)
        let contextRange = NSRange(location: start, length: end - start)
        var context = content.substring(with: contextRange)

        // Add ellipsis if truncated
        if start > 0 {
            context = "..." + context
        }
        if end < content.length {
            context = context + "..."
        }

        return context
    }
}

// MARK: - Extracted Mention

/// A mention extracted from content before being linked to stored artifacts.
public struct ExtractedMention: Sendable {
    /// The parsed artifact URI
    public let uri: ArtifactURI

    /// Range in the original content
    public let range: NSRange

    /// Determined mention type
    public let mentionType: ArtifactMentionType

    /// Context snippet around the mention
    public let contextSnippet: String?

    /// Character offset (start of range)
    public var characterOffset: Int {
        range.location
    }

    /// Character length
    public var characterLength: Int {
        range.length
    }
}

// MARK: - Mention Statistics

/// Statistics about artifact mentions in a conversation.
public struct MentionStatistics: Codable, Sendable {
    /// Total number of mentions
    public let totalMentions: Int

    /// Number of unique artifacts mentioned
    public let uniqueArtifacts: Int

    /// Breakdown by artifact type
    public let byType: [ArtifactType: Int]

    /// Breakdown by mention type
    public let byMentionType: [ArtifactMentionType: Int]

    /// Most mentioned artifacts (URI -> count)
    public let topMentioned: [(uri: String, count: Int)]

    /// Initialize from a collection of mentions.
    public init(mentions: [ArtifactMention]) {
        self.totalMentions = mentions.count

        let uniqueURIs = Set(mentions.map(\.artifactURI))
        self.uniqueArtifacts = uniqueURIs.count

        // Count by type
        var typeCount: [ArtifactType: Int] = [:]
        var mentionTypeCount: [ArtifactMentionType: Int] = [:]
        var uriCount: [String: Int] = [:]

        for mention in mentions {
            if let uri = ArtifactURI(uri: mention.artifactURI) {
                typeCount[uri.type, default: 0] += 1
            }
            mentionTypeCount[mention.mentionType, default: 0] += 1
            uriCount[mention.artifactURI, default: 0] += 1
        }

        self.byType = typeCount
        self.byMentionType = mentionTypeCount
        self.topMentioned = uriCount
            .sorted { $0.value > $1.value }
            .prefix(10)
            .map { ($0.key, $0.value) }
    }
}

// MARK: - Codable Conformance

extension MentionStatistics {
    enum CodingKeys: String, CodingKey {
        case totalMentions
        case uniqueArtifacts
        case byType
        case byMentionType
        case topMentioned
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        totalMentions = try container.decode(Int.self, forKey: .totalMentions)
        uniqueArtifacts = try container.decode(Int.self, forKey: .uniqueArtifacts)

        // Decode byType
        let typeDict = try container.decode([String: Int].self, forKey: .byType)
        var byType: [ArtifactType: Int] = [:]
        for (key, value) in typeDict {
            if let type = ArtifactType(rawValue: key) {
                byType[type] = value
            }
        }
        self.byType = byType

        // Decode byMentionType
        let mentionTypeDict = try container.decode([String: Int].self, forKey: .byMentionType)
        var byMentionType: [ArtifactMentionType: Int] = [:]
        for (key, value) in mentionTypeDict {
            if let type = ArtifactMentionType(rawValue: key) {
                byMentionType[type] = value
            }
        }
        self.byMentionType = byMentionType

        // Decode topMentioned
        let topDict = try container.decode([String: Int].self, forKey: .topMentioned)
        self.topMentioned = topDict
            .sorted { $0.value > $1.value }
            .map { ($0.key, $0.value) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(totalMentions, forKey: .totalMentions)
        try container.encode(uniqueArtifacts, forKey: .uniqueArtifacts)

        // Encode byType
        var typeDict: [String: Int] = [:]
        for (key, value) in byType {
            typeDict[key.rawValue] = value
        }
        try container.encode(typeDict, forKey: .byType)

        // Encode byMentionType
        var mentionTypeDict: [String: Int] = [:]
        for (key, value) in byMentionType {
            mentionTypeDict[key.rawValue] = value
        }
        try container.encode(mentionTypeDict, forKey: .byMentionType)

        // Encode topMentioned
        var topDict: [String: Int] = [:]
        for (uri, count) in topMentioned {
            topDict[uri] = count
        }
        try container.encode(topDict, forKey: .topMentioned)
    }
}
