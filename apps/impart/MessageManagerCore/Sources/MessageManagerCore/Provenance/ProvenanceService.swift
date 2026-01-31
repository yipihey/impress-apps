//
//  ProvenanceService.swift
//  MessageManagerCore
//
//  Actor-based service for recording and querying provenance events.
//  Provides the Swift interface to the Rust provenance event store.
//

import Foundation
import OSLog

private let provenanceLogger = Logger(subsystem: "com.impart", category: "provenance")

// MARK: - Provenance Service

/// Actor-based service for managing provenance events.
public actor ProvenanceService {

    // MARK: - Properties

    /// In-memory event storage (will be replaced with Rust FFI when available).
    private var events: [ProvenanceEvent] = []

    /// Next sequence number.
    private var nextSequence: UInt64 = 1

    /// Index by conversation ID.
    private var eventsByConversation: [String: [Int]] = [:]

    /// Index by correlation ID.
    private var eventsByCorrelation: [String: [Int]] = [:]

    /// Index by actor ID.
    private var eventsByActor: [String: [Int]] = [:]

    // MARK: - Initialization

    public init() {}

    // MARK: - Recording Events

    /// Record a new provenance event.
    @discardableResult
    public func record(_ event: ProvenanceEvent) -> ProvenanceEvent {
        var storedEvent = event
        storedEvent.sequence = nextSequence
        nextSequence += 1

        let index = events.count
        events.append(storedEvent)

        // Update indices
        eventsByConversation[event.conversationId, default: []].append(index)

        if let correlationId = event.correlationId {
            eventsByCorrelation[correlationId, default: []].append(index)
        }

        eventsByActor[event.actorId, default: []].append(index)

        provenanceLogger.debug("Recorded event: \(event.payload.description)")

        return storedEvent
    }

    /// Record a conversation creation event.
    @discardableResult
    public func recordConversationCreated(
        conversationId: String,
        title: String,
        participants: [String],
        actorId: String
    ) -> ProvenanceEvent {
        let event = ProvenanceEvent(
            conversationId: conversationId,
            payload: .conversationCreated(title: title, participants: participants),
            actorId: actorId
        )
        return record(event)
    }

    /// Record a message sent event.
    @discardableResult
    public func recordMessageSent(
        conversationId: String,
        messageId: String,
        role: String,
        modelUsed: String?,
        contentHash: String,
        actorId: String,
        causedBy: ProvenanceEventId? = nil
    ) -> ProvenanceEvent {
        var event = ProvenanceEvent(
            conversationId: conversationId,
            payload: .messageSent(
                messageId: messageId,
                role: role,
                modelUsed: modelUsed,
                contentHash: contentHash
            ),
            actorId: actorId
        )
        if let causedBy = causedBy {
            event = event.withCausation(causedBy)
        }
        return record(event)
    }

    /// Record an artifact introduction event.
    @discardableResult
    public func recordArtifactIntroduced(
        conversationId: String,
        artifactUri: String,
        artifactType: String,
        version: String?,
        displayName: String,
        actorId: String
    ) -> ProvenanceEvent {
        let event = ProvenanceEvent(
            conversationId: conversationId,
            payload: .artifactIntroduced(
                artifactUri: artifactUri,
                artifactType: artifactType,
                version: version,
                displayName: displayName
            ),
            actorId: actorId
        )
        return record(event)
    }

    /// Record an artifact reference event.
    @discardableResult
    public func recordArtifactReferenced(
        conversationId: String,
        artifactUri: String,
        messageId: String,
        contextSnippet: String,
        actorId: String
    ) -> ProvenanceEvent {
        let event = ProvenanceEvent(
            conversationId: conversationId,
            payload: .artifactReferenced(
                artifactUri: artifactUri,
                messageId: messageId,
                contextSnippet: contextSnippet
            ),
            actorId: actorId
        )
        return record(event)
    }

    /// Record an insight.
    @discardableResult
    public func recordInsight(
        conversationId: String,
        insightId: String,
        summary: String,
        derivedFrom: [String],
        confidence: Double?,
        actorId: String
    ) -> ProvenanceEvent {
        let event = ProvenanceEvent(
            conversationId: conversationId,
            payload: .insightRecorded(
                insightId: insightId,
                summary: summary,
                derivedFrom: derivedFrom,
                confidence: confidence
            ),
            actorId: actorId
        )
        return record(event)
    }

    /// Record a decision.
    @discardableResult
    public func recordDecision(
        conversationId: String,
        decisionId: String,
        description: String,
        rationale: String,
        alternativesConsidered: [String],
        actorId: String
    ) -> ProvenanceEvent {
        let event = ProvenanceEvent(
            conversationId: conversationId,
            payload: .decisionMade(
                decisionId: decisionId,
                description: description,
                rationale: rationale,
                alternativesConsidered: alternativesConsidered
            ),
            actorId: actorId
        )
        return record(event)
    }

    // MARK: - Querying Events

    /// Get an event by ID.
    public func getEvent(_ id: ProvenanceEventId) -> ProvenanceEvent? {
        events.first { $0.id == id }
    }

    /// Get all events for a conversation.
    public func eventsForConversation(_ conversationId: String) -> [ProvenanceEvent] {
        guard let indices = eventsByConversation[conversationId] else {
            return []
        }
        return indices.map { events[$0] }
    }

    /// Get events after a sequence number.
    public func eventsAfter(sequence: UInt64) -> [ProvenanceEvent] {
        events.filter { $0.sequence > sequence }
    }

    /// Get events by correlation ID.
    public func eventsByCorrelation(_ correlationId: String) -> [ProvenanceEvent] {
        guard let indices = eventsByCorrelation[correlationId] else {
            return []
        }
        return indices.map { events[$0] }
    }

    /// Get events by actor.
    public func eventsByActor(_ actorId: String) -> [ProvenanceEvent] {
        guard let indices = eventsByActor[actorId] else {
            return []
        }
        return indices.map { events[$0] }
    }

    /// Get the current sequence number.
    public func currentSequence() -> UInt64 {
        nextSequence - 1
    }

    // MARK: - Lineage Tracing

    /// Trace the lineage of an event back to its origins.
    public func traceLineage(from eventId: ProvenanceEventId) -> [ProvenanceEvent] {
        var lineage: [ProvenanceEvent] = []
        var currentId: ProvenanceEventId? = eventId

        while let id = currentId {
            if let event = getEvent(id) {
                lineage.append(event)
                currentId = event.causationId
            } else {
                break
            }
        }

        return lineage
    }

    /// Find all events caused by a given event.
    public func traceEffects(of eventId: ProvenanceEventId) -> [ProvenanceEvent] {
        events.filter { $0.causationId == eventId }
    }

    // MARK: - Artifact Queries

    /// Get the history of an artifact.
    public func artifactHistory(_ artifactUri: String) -> [ProvenanceEvent] {
        events.filter { event in
            switch event.payload {
            case .artifactIntroduced(let uri, _, _, _),
                 .artifactReferenced(let uri, _, _),
                 .artifactMetadataUpdated(let uri, _, _, _),
                 .artifactResolved(let uri, _):
                return uri == artifactUri
            case .artifactLinked(let source, let target, _):
                return source == artifactUri || target == artifactUri
            default:
                return false
            }
        }
    }

    /// Get all artifacts introduced in a conversation.
    public func artifactsInConversation(_ conversationId: String) -> [String] {
        let conversationEvents = eventsForConversation(conversationId)
        var seen = Set<String>()
        var artifacts: [String] = []

        for event in conversationEvents {
            if case .artifactIntroduced(let uri, _, _, _) = event.payload {
                if seen.insert(uri).inserted {
                    artifacts.append(uri)
                }
            }
        }

        return artifacts
    }

    // MARK: - Decision Queries

    /// Get all decisions in a conversation.
    public func decisionsInConversation(_ conversationId: String) -> [ProvenanceEvent] {
        eventsForConversation(conversationId).filter { event in
            switch event.payload {
            case .decisionMade, .decisionRevised:
                return true
            default:
                return false
            }
        }
    }

    /// Get the history of a decision.
    public func decisionHistory(_ decisionId: String) -> [ProvenanceEvent] {
        events.filter { event in
            switch event.payload {
            case .decisionMade(let id, _, _, _),
                 .decisionRevised(let id, _, _, _):
                return id == decisionId
            default:
                return false
            }
        }
    }

    // MARK: - Insight Queries

    /// Get all insights in a conversation.
    public func insightsInConversation(_ conversationId: String) -> [ProvenanceEvent] {
        eventsForConversation(conversationId).filter { event in
            if case .insightRecorded = event.payload {
                return true
            }
            return false
        }
    }

    /// Find insights derived from a specific source.
    public func insightsDerivedFrom(_ sourceId: String) -> [ProvenanceEvent] {
        events.filter { event in
            if case .insightRecorded(_, _, let derivedFrom, _) = event.payload {
                return derivedFrom.contains(sourceId)
            }
            return false
        }
    }

    // MARK: - Statistics

    /// Get provenance statistics for a conversation.
    public func stats(forConversation conversationId: String) -> ConversationProvenanceStats {
        let conversationEvents = eventsForConversation(conversationId)

        var messageCount = 0
        var artifactUris = Set<String>()
        var decisionCount = 0
        var insightCount = 0
        var actors = Set<String>()
        var branchCount = 0

        for event in conversationEvents {
            actors.insert(event.actorId)

            switch event.payload {
            case .messageSent:
                messageCount += 1
            case .artifactIntroduced(let uri, _, _, _):
                artifactUris.insert(uri)
            case .decisionMade:
                decisionCount += 1
            case .insightRecorded:
                insightCount += 1
            case .conversationBranched:
                branchCount += 1
            default:
                break
            }
        }

        return ConversationProvenanceStats(
            totalEvents: conversationEvents.count,
            messageCount: messageCount,
            artifactCount: artifactUris.count,
            decisionCount: decisionCount,
            insightCount: insightCount,
            actorCount: actors.count,
            branchCount: branchCount
        )
    }

    // MARK: - Export/Import

    /// Export all events for a conversation as JSON.
    public func exportConversation(_ conversationId: String) throws -> Data {
        let conversationEvents = eventsForConversation(conversationId)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(conversationEvents)
    }

    /// Import events from JSON.
    public func importEvents(from data: Data) throws -> Int {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let importedEvents = try decoder.decode([ProvenanceEvent].self, from: data)

        for event in importedEvents {
            record(event)
        }

        return importedEvents.count
    }
}

// MARK: - Content Hash Utility

/// Compute a content hash for provenance tracking.
public func computeContentHash(_ content: String) -> String {
    // Use a simple hash for now; in production use SHA256
    let data = content.data(using: .utf8) ?? Data()
    var hash: UInt64 = 5381
    for byte in data {
        hash = ((hash << 5) &+ hash) &+ UInt64(byte)
    }
    return String(format: "%016llx", hash)
}
