//
//  ManagedObjects.swift
//  MessageManagerCore
//
//  Core Data managed objects for impart email client.
//  Follows imbib's CDCollection pattern for hierarchical folders.
//

import CoreData
import Foundation

// EmailAddress is defined in MessageTypes.swift

// MARK: - Message Category

/// Message categorization for view modes.
public enum MessageCategory: String, Codable, Sendable {
    case conversation   // Back-and-forth, ≤5 recipients
    case broadcast      // One-to-many, newsletters, mailing lists
    case agent          // From/to AI agent addresses
}

// MARK: - Folder Role

/// System folder roles.
public enum FolderRole: String, Codable, CaseIterable, Sendable {
    case inbox
    case sent
    case drafts
    case trash
    case archive
    case spam
    case custom
    case agents         // Special folder for AI agent conversations
}

// MARK: - CDAccount

@objc(CDAccount)
public class CDAccount: NSManagedObject, Identifiable {
    @NSManaged private var primitiveId: UUID?

    public var id: UUID {
        get {
            willAccessValue(forKey: "id")
            defer { didAccessValue(forKey: "id") }
            if let existingId = primitiveId {
                return existingId
            }
            let newId = UUID()
            primitiveId = newId
            return newId
        }
        set {
            willChangeValue(forKey: "id")
            primitiveId = newValue
            didChangeValue(forKey: "id")
        }
    }

    @NSManaged public var email: String
    @NSManaged public var displayName: String
    @NSManaged public var imapHost: String
    @NSManaged public var imapPort: Int16
    @NSManaged public var smtpHost: String
    @NSManaged public var smtpPort: Int16
    @NSManaged public var isEnabled: Bool
    @NSManaged public var lastSyncDate: Date?
    @NSManaged public var signature: String?
    @NSManaged public var keychainItemId: String

    // Relationships
    @NSManaged public var folders: Set<CDFolder>?
}

// MARK: - CDFolder

/// Hierarchical folder for organizing messages.
/// Follows imbib's CDCollection pattern for tree structure.
@objc(CDFolder)
public class CDFolder: NSManagedObject, Identifiable {
    @NSManaged private var primitiveId: UUID?

    public var id: UUID {
        get {
            willAccessValue(forKey: "id")
            defer { didAccessValue(forKey: "id") }
            if let existingId = primitiveId {
                return existingId
            }
            let newId = UUID()
            primitiveId = newId
            return newId
        }
        set {
            willChangeValue(forKey: "id")
            primitiveId = newValue
            didChangeValue(forKey: "id")
        }
    }

    @NSManaged public var name: String
    @NSManaged public var fullPath: String
    @NSManaged public var roleRaw: String
    @NSManaged public var isSystemFolder: Bool
    @NSManaged public var isVirtualFolder: Bool     // Smart folders with predicates
    @NSManaged public var predicate: String?        // NSPredicate format for smart folders
    @NSManaged public var messageCount: Int32
    @NSManaged public var unreadCount: Int32
    @NSManaged public var dateCreated: Date?
    @NSManaged public var sortOrder: Int16

    // Hierarchy (like CDCollection)
    @NSManaged public var parentFolder: CDFolder?
    @NSManaged public var childFolders: Set<CDFolder>?

    // Relationships
    @NSManaged public var account: CDAccount?
    @NSManaged public var messages: Set<CDMessage>?
}

// MARK: - CDFolder Helpers

public extension CDFolder {

    /// Folder role enum accessor.
    var role: FolderRole {
        get { FolderRole(rawValue: roleRaw) ?? .custom }
        set { roleRaw = newValue.rawValue }
    }

    /// Parse predicate string to NSPredicate.
    var nsPredicate: NSPredicate? {
        guard isVirtualFolder,
              let predicateString = predicate,
              !predicateString.isEmpty else {
            return nil
        }
        return NSPredicate(format: predicateString)
    }

    // MARK: - Hierarchy Helpers (ported from CDCollection)

    /// Depth of this folder in the hierarchy (0 = root, 1 = first level child, etc.)
    var depth: Int {
        var d = 0
        var current = parentFolder
        while current != nil {
            d += 1
            current = current?.parentFolder
        }
        return d
    }

    /// Whether this folder has any child folders.
    var hasChildren: Bool {
        !(childFolders?.isEmpty ?? true)
    }

    /// Sorted child folders by name.
    var sortedChildren: [CDFolder] {
        (childFolders ?? []).sorted { $0.name < $1.name }
    }

    /// All ancestor folders from root to parent.
    var ancestors: [CDFolder] {
        var result: [CDFolder] = []
        var current = parentFolder
        while let c = current {
            result.insert(c, at: 0)
            current = c.parentFolder
        }
        return result
    }

    /// Check if this folder is an ancestor of another folder.
    func isAncestor(of folder: CDFolder) -> Bool {
        folder.ancestors.contains { $0.id == self.id }
    }

    /// Check if reparenting to a new parent would create a cycle.
    func canReparent(to newParent: CDFolder?) -> Bool {
        guard let newParent = newParent else { return true }
        // Can't be your own parent
        if newParent.id == self.id { return false }
        // Can't reparent to a descendant
        return !isAncestor(of: newParent)
    }
}

// MARK: - CDMessage

@objc(CDMessage)
public class CDMessage: NSManagedObject, Identifiable {
    @NSManaged private var primitiveId: UUID?

    public var id: UUID {
        get {
            willAccessValue(forKey: "id")
            defer { didAccessValue(forKey: "id") }
            if let existingId = primitiveId {
                return existingId
            }
            let newId = UUID()
            primitiveId = newId
            return newId
        }
        set {
            willChangeValue(forKey: "id")
            primitiveId = newValue
            didChangeValue(forKey: "id")
        }
    }

    @NSManaged public var uid: Int32
    @NSManaged public var messageId: String?        // Message-ID header
    @NSManaged public var inReplyTo: String?
    @NSManaged public var referencesJSON: String?   // JSON array of Message-IDs
    @NSManaged public var subject: String
    @NSManaged public var snippet: String
    @NSManaged public var fromJSON: String          // JSON array of addresses
    @NSManaged public var toJSON: String
    @NSManaged public var ccJSON: String?
    @NSManaged public var bccJSON: String?
    @NSManaged public var date: Date
    @NSManaged public var receivedDate: Date
    @NSManaged public var isRead: Bool
    @NSManaged public var isStarred: Bool
    @NSManaged public var isDismissed: Bool         // Triage: dismissed/archived
    @NSManaged public var isSaved: Bool             // Triage: explicitly saved
    @NSManaged public var hasAttachments: Bool
    @NSManaged public var labelsJSON: String?       // JSON array of labels
    @NSManaged public var categoryRaw: String?      // MessageCategory raw value
    @NSManaged public var isFromAgent: Bool         // From AI agent address
    @NSManaged public var isToAgent: Bool           // To AI agent address

    // Relationships
    @NSManaged public var folder: CDFolder?
    @NSManaged public var thread: CDThread?
    @NSManaged public var conversation: CDConversation?
    @NSManaged public var content: CDMessageContent?
}

// MARK: - CDMessage Helpers

public extension CDMessage {

    /// Message category enum accessor.
    var category: MessageCategory? {
        get { categoryRaw.flatMap { MessageCategory(rawValue: $0) } }
        set { categoryRaw = newValue?.rawValue }
    }

    /// Decode from addresses.
    var fromAddresses: [EmailAddress] {
        guard let data = fromJSON.data(using: .utf8),
              let addresses = try? JSONDecoder().decode([EmailAddress].self, from: data) else {
            return []
        }
        return addresses
    }

    /// Decode to addresses.
    var toAddresses: [EmailAddress] {
        guard let data = toJSON.data(using: .utf8),
              let addresses = try? JSONDecoder().decode([EmailAddress].self, from: data) else {
            return []
        }
        return addresses
    }

    /// Decode cc addresses.
    var ccAddresses: [EmailAddress] {
        guard let data = ccJSON?.data(using: .utf8),
              let addresses = try? JSONDecoder().decode([EmailAddress].self, from: data) else {
            return []
        }
        return addresses
    }

    /// Decode bcc addresses.
    var bccAddresses: [EmailAddress] {
        guard let data = bccJSON?.data(using: .utf8),
              let addresses = try? JSONDecoder().decode([EmailAddress].self, from: data) else {
            return []
        }
        return addresses
    }

    /// Decode references.
    var references: [String] {
        guard let data = referencesJSON?.data(using: .utf8),
              let refs = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return refs
    }

    /// Decode labels.
    var labels: [String] {
        guard let data = labelsJSON?.data(using: .utf8),
              let labels = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return labels
    }

    /// Total recipient count (to + cc + bcc).
    var recipientCount: Int {
        toAddresses.count + ccAddresses.count + bccAddresses.count
    }

    /// Display string for From field.
    var fromDisplayString: String {
        fromAddresses.first?.displayString ?? "Unknown"
    }

    /// Convert to Message DTO.
    func toMessage() -> Message {
        Message(
            id: id,
            accountId: folder?.account?.id ?? UUID(),
            mailboxId: folder?.id ?? UUID(),
            uid: UInt32(uid),
            messageId: messageId,
            inReplyTo: inReplyTo,
            references: references,
            subject: subject,
            from: fromAddresses,
            to: toAddresses,
            cc: ccAddresses,
            bcc: bccAddresses,
            date: date,
            receivedDate: receivedDate,
            snippet: snippet,
            isRead: isRead,
            isStarred: isStarred,
            hasAttachments: hasAttachments,
            labels: labels
        )
    }
}

// MARK: - CDMessageContent

/// Lazy-loaded message body and attachments.
@objc(CDMessageContent)
public class CDMessageContent: NSManagedObject, Identifiable {
    @NSManaged private var primitiveId: UUID?

    public var id: UUID {
        get {
            willAccessValue(forKey: "id")
            defer { didAccessValue(forKey: "id") }
            if let existingId = primitiveId {
                return existingId
            }
            let newId = UUID()
            primitiveId = newId
            return newId
        }
        set {
            willChangeValue(forKey: "id")
            primitiveId = newValue
            didChangeValue(forKey: "id")
        }
    }

    @NSManaged public var textBody: String?
    @NSManaged public var htmlBody: String?

    // Relationships
    @NSManaged public var message: CDMessage?
    @NSManaged public var attachments: Set<CDAttachment>?
}

// MARK: - CDAttachment

@objc(CDAttachment)
public class CDAttachment: NSManagedObject, Identifiable {
    @NSManaged private var primitiveId: UUID?

    public var id: UUID {
        get {
            willAccessValue(forKey: "id")
            defer { didAccessValue(forKey: "id") }
            if let existingId = primitiveId {
                return existingId
            }
            let newId = UUID()
            primitiveId = newId
            return newId
        }
        set {
            willChangeValue(forKey: "id")
            primitiveId = newValue
            didChangeValue(forKey: "id")
        }
    }

    @NSManaged public var filename: String
    @NSManaged public var mimeType: String
    @NSManaged public var size: Int64
    @NSManaged public var contentId: String?
    @NSManaged public var isInline: Bool
    @NSManaged public var data: Data?

    // Relationships
    @NSManaged public var content: CDMessageContent?
}

// MARK: - CDThread

/// JWZ-algorithm conversation thread.
@objc(CDThread)
public class CDThread: NSManagedObject, Identifiable {
    @NSManaged private var primitiveId: UUID?

    public var id: UUID {
        get {
            willAccessValue(forKey: "id")
            defer { didAccessValue(forKey: "id") }
            if let existingId = primitiveId {
                return existingId
            }
            let newId = UUID()
            primitiveId = newId
            return newId
        }
        set {
            willChangeValue(forKey: "id")
            primitiveId = newValue
            didChangeValue(forKey: "id")
        }
    }

    @NSManaged public var subject: String
    @NSManaged public var latestDate: Date
    @NSManaged public var participantsJSON: String? // JSON array of addresses

    // Relationships
    @NSManaged public var messages: Set<CDMessage>?
    @NSManaged public var account: CDAccount?
}

// MARK: - CDThread Helpers

public extension CDThread {

    /// Message count in thread.
    var messageCount: Int {
        messages?.count ?? 0
    }

    /// Unread count in thread.
    var unreadCount: Int {
        messages?.filter { !$0.isRead }.count ?? 0
    }

    /// Whether thread has unread messages.
    var hasUnread: Bool {
        unreadCount > 0
    }

    /// Sorted messages by date (oldest first).
    var sortedMessages: [CDMessage] {
        (messages ?? []).sorted { $0.date < $1.date }
    }

    /// Decode participants.
    var participants: [EmailAddress] {
        guard let data = participantsJSON?.data(using: .utf8),
              let addresses = try? JSONDecoder().decode([EmailAddress].self, from: data) else {
            return []
        }
        return addresses
    }

    /// Display string for participants.
    var participantsDisplayString: String {
        participants.prefix(3).map(\.displayString).joined(separator: ", ")
    }

    /// Latest message snippet.
    var latestSnippet: String {
        sortedMessages.last?.snippet ?? ""
    }
}

// MARK: - CDConversation

/// Chat-style conversation grouping (by participants hash).
@objc(CDConversation)
public class CDConversation: NSManagedObject, Identifiable {
    @NSManaged private var primitiveId: UUID?

    public var id: UUID {
        get {
            willAccessValue(forKey: "id")
            defer { didAccessValue(forKey: "id") }
            if let existingId = primitiveId {
                return existingId
            }
            let newId = UUID()
            primitiveId = newId
            return newId
        }
        set {
            willChangeValue(forKey: "id")
            primitiveId = newValue
            didChangeValue(forKey: "id")
        }
    }

    @NSManaged public var participantsHash: String  // Hash of sorted participant emails
    @NSManaged public var participantsJSON: String  // JSON array of addresses
    @NSManaged public var latestDate: Date
    @NSManaged public var isAgentConversation: Bool // Contains AI agent

    // Relationships
    @NSManaged public var messages: Set<CDMessage>?
    @NSManaged public var account: CDAccount?
}

// MARK: - CDConversation Helpers

public extension CDConversation {

    /// Message count in conversation.
    var messageCount: Int {
        messages?.count ?? 0
    }

    /// Unread count in conversation.
    var unreadCount: Int {
        messages?.filter { !$0.isRead }.count ?? 0
    }

    /// Sorted messages by date (oldest first for chat display).
    var sortedMessages: [CDMessage] {
        (messages ?? []).sorted { $0.date < $1.date }
    }

    /// Decode participants.
    var participants: [EmailAddress] {
        guard let data = participantsJSON.data(using: .utf8),
              let addresses = try? JSONDecoder().decode([EmailAddress].self, from: data) else {
            return []
        }
        return addresses
    }

    /// Display name for the conversation (other participants).
    func displayName(excludingEmail: String) -> String {
        let others = participants.filter { $0.email.lowercased() != excludingEmail.lowercased() }
        if others.isEmpty {
            return participants.first?.displayString ?? "Unknown"
        }
        return others.prefix(3).map(\.displayString).joined(separator: ", ")
    }

    /// Latest message snippet.
    var latestSnippet: String {
        sortedMessages.last?.snippet ?? ""
    }

    /// Compute participants hash from email addresses.
    static func computeParticipantsHash(from emails: [String]) -> String {
        let sorted = emails.map { $0.lowercased() }.sorted()
        let joined = sorted.joined(separator: ",")
        // Simple hash - in production use SHA256
        return String(joined.hashValue)
    }
}

// MARK: - ============================================================
// MARK: - Research Conversation Platform (Phase 3+)
// MARK: - ============================================================

// MARK: - Sender Role

/// Role of a message sender in a research conversation.
public enum ResearchSenderRole: String, Codable, Sendable {
    case human      // Human user
    case counsel    // AI counsel agent
    case system     // System-generated message
}

// MARK: - CDResearchConversation

/// Research dialogue container with full provenance tracking.
/// Supports branching for side conversations and topic exploration.
@objc(CDResearchConversation)
public class CDResearchConversation: NSManagedObject, Identifiable {
    @NSManaged private var primitiveId: UUID?

    public var id: UUID {
        get {
            willAccessValue(forKey: "id")
            defer { didAccessValue(forKey: "id") }
            if let existingId = primitiveId {
                return existingId
            }
            let newId = UUID()
            primitiveId = newId
            return newId
        }
        set {
            willChangeValue(forKey: "id")
            primitiveId = newValue
            didChangeValue(forKey: "id")
        }
    }

    /// Title of the research conversation
    @NSManaged public var title: String

    /// JSON array of participant identifiers (e.g., ["user@...", "counsel-opus4.5@..."])
    @NSManaged public var participantsJSON: String

    /// When this conversation was created
    @NSManaged public var createdAt: Date

    /// Last activity timestamp (updated on each message)
    @NSManaged public var lastActivityAt: Date

    /// AI-generated summary of the conversation
    @NSManaged public var summaryText: String?

    /// Whether this conversation is archived
    @NSManaged public var isArchived: Bool

    /// Tags for organization (JSON array)
    @NSManaged public var tagsJSON: String?

    /// Conversation mode (interactive, planning, review, archival)
    @NSManaged public var mode: String

    /// Planning session ID for grouping related planning conversations
    @NSManaged public var planningSessionId: UUID?

    // Relationships
    /// Parent conversation if this is a branch/side conversation
    @NSManaged public var parentConversation: CDResearchConversation?

    /// Child conversations (branches)
    @NSManaged public var childConversations: Set<CDResearchConversation>?

    /// Messages in this conversation
    @NSManaged public var messages: Set<CDResearchMessage>?

    /// Artifacts referenced in this conversation
    @NSManaged public var artifacts: Set<CDArtifactReference>?
}

// MARK: - CDResearchConversation Helpers

public extension CDResearchConversation {

    /// Message count.
    var messageCount: Int {
        messages?.count ?? 0
    }

    /// Messages sorted by sequence.
    var sortedMessages: [CDResearchMessage] {
        (messages ?? []).sorted { $0.conversationSequence < $1.conversationSequence }
    }

    /// Decode participants.
    var participants: [String] {
        guard let data = participantsJSON.data(using: .utf8),
              let list = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return list
    }

    /// Set participants.
    func setParticipants(_ participants: [String]) {
        if let data = try? JSONEncoder().encode(participants),
           let json = String(data: data, encoding: .utf8) {
            participantsJSON = json
        }
    }

    /// Decode tags.
    var tags: [String] {
        guard let data = tagsJSON?.data(using: .utf8),
              let list = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return list
    }

    /// Set tags.
    func setTags(_ tags: [String]) {
        if let data = try? JSONEncoder().encode(tags),
           let json = String(data: data, encoding: .utf8) {
            tagsJSON = json
        }
    }

    /// Whether this is a side/branch conversation.
    var isSideConversation: Bool {
        parentConversation != nil
    }

    /// Depth in conversation hierarchy (0 = root).
    var depth: Int {
        var d = 0
        var current = parentConversation
        while current != nil {
            d += 1
            current = current?.parentConversation
        }
        return d
    }

    /// Get the root conversation.
    var rootConversation: CDResearchConversation {
        var current: CDResearchConversation = self
        while let parent = current.parentConversation {
            current = parent
        }
        return current
    }

    /// Latest message in the conversation.
    var latestMessage: CDResearchMessage? {
        sortedMessages.last
    }

    /// Latest snippet for preview.
    var latestSnippet: String {
        latestMessage?.contentMarkdown.prefix(100).description ?? ""
    }

    /// Conversation mode enum accessor.
    var conversationMode: ConversationMode {
        get { ConversationMode(rawValue: mode) ?? .interactive }
        set { mode = newValue.rawValue }
    }
}

// MARK: - CDResearchMessage

/// Individual message in a research conversation with full provenance.
@objc(CDResearchMessage)
public class CDResearchMessage: NSManagedObject, Identifiable {
    @NSManaged private var primitiveId: UUID?

    public var id: UUID {
        get {
            willAccessValue(forKey: "id")
            defer { didAccessValue(forKey: "id") }
            if let existingId = primitiveId {
                return existingId
            }
            let newId = UUID()
            primitiveId = newId
            return newId
        }
        set {
            willChangeValue(forKey: "id")
            primitiveId = newValue
            didChangeValue(forKey: "id")
        }
    }

    /// Sequence number within the conversation (for ordering)
    @NSManaged public var conversationSequence: Int32

    /// Role of the sender (human, counsel, system)
    @NSManaged public var senderRoleRaw: String

    /// Sender identifier (user email or agent address)
    @NSManaged public var senderId: String

    /// AI model used if this is a counsel message (e.g., "opus4.5", "sonnet4")
    @NSManaged public var modelUsed: String?

    /// Message content in Markdown format
    @NSManaged public var contentMarkdown: String

    /// When this message was sent
    @NSManaged public var sentAt: Date

    /// Correlation ID for linking to provenance events
    @NSManaged public var correlationId: String?

    /// ID of the message that caused this response (for counsel replies)
    @NSManaged public var causationId: UUID?

    /// Whether this is a synthesis of a side conversation
    @NSManaged public var isSideConversationSynthesis: Bool

    /// Token count if from AI
    @NSManaged public var tokenCount: Int32

    /// Processing duration in milliseconds (for AI messages)
    @NSManaged public var processingDurationMs: Int32

    /// Message intent (converse, execute, result, proposal, approval, plan, error)
    @NSManaged public var intent: String

    // Relationships
    /// The conversation containing this message
    @NSManaged public var conversation: CDResearchConversation?

    /// Side conversation details (expandable agent-to-agent exchange)
    @NSManaged public var sideConversation: CDResearchConversation?

    /// Artifact mentions in this message
    @NSManaged public var artifactMentions: Set<CDArtifactMention>?
}

// MARK: - CDResearchMessage Helpers

public extension CDResearchMessage {

    /// Sender role enum accessor.
    var senderRole: ResearchSenderRole {
        get { ResearchSenderRole(rawValue: senderRoleRaw) ?? .human }
        set { senderRoleRaw = newValue.rawValue }
    }

    /// Whether this message is from an AI counsel.
    var isFromCounsel: Bool {
        senderRole == .counsel
    }

    /// Whether this message has a side conversation that can be expanded.
    var hasSideConversation: Bool {
        sideConversation != nil
    }

    /// Get artifact URIs mentioned in this message.
    var mentionedArtifactURIs: [String] {
        (artifactMentions ?? []).map(\.artifactURI).compactMap { $0 }
    }

    /// Get a preview snippet of the content.
    var snippet: String {
        String(contentMarkdown.prefix(200))
    }

    /// Message intent enum accessor.
    var messageIntent: MessageIntent {
        get { MessageIntent(rawValue: intent) ?? .converse }
        set { intent = newValue.rawValue }
    }
}

// MARK: - CDArtifactReference

/// Versioned external resource reference for research conversations.
/// Supports papers, repositories, datasets, documents, and other artifacts.
@objc(CDArtifactReference)
public class CDArtifactReference: NSManagedObject, Identifiable {
    @NSManaged private var primitiveId: UUID?

    public var id: UUID {
        get {
            willAccessValue(forKey: "id")
            defer { didAccessValue(forKey: "id") }
            if let existingId = primitiveId {
                return existingId
            }
            let newId = UUID()
            primitiveId = newId
            return newId
        }
        set {
            willChangeValue(forKey: "id")
            primitiveId = newValue
            didChangeValue(forKey: "id")
        }
    }

    /// The impress:// URI (e.g., "impress://imbib/papers/Fowler2012")
    @NSManaged public var uri: String?

    /// Artifact type raw value (paper, repository, dataset, etc.)
    @NSManaged public var artifactType: String?

    /// Human-readable display name
    @NSManaged public var displayName: String?

    /// Version identifier (git SHA, timestamp, version number)
    @NSManaged public var versionIdentifier: String?

    /// Additional metadata as JSON
    @NSManaged public var metadataJSON: String?

    /// When this reference was created
    @NSManaged public var createdAt: Date?

    /// Who/what introduced this reference
    @NSManaged public var introducedBy: String?

    /// Conversation where this was first introduced
    @NSManaged public var sourceConversationId: UUID?

    /// Message where this was first introduced
    @NSManaged public var sourceMessageId: UUID?

    /// Whether the artifact content has been resolved/verified
    @NSManaged public var isResolved: Bool

    /// Last time this artifact was accessed
    @NSManaged public var lastAccessedAt: Date?

    /// Security-scoped bookmark data for external directories
    @NSManaged public var bookmarkData: Data?

    // Relationships
    /// Conversations that reference this artifact
    @NSManaged public var conversations: Set<CDResearchConversation>?

    /// Mentions of this artifact
    @NSManaged public var mentions: Set<CDArtifactMention>?
}

// MARK: - CDArtifactReference Helpers

public extension CDArtifactReference {

    /// Get the artifact type enum.
    var type: ArtifactType {
        guard let raw = artifactType else { return .unknown }
        return ArtifactType(rawValue: raw) ?? .unknown
    }

    /// Set the artifact type.
    func setType(_ type: ArtifactType) {
        artifactType = type.rawValue
    }

    /// Decode metadata.
    var metadata: ArtifactMetadata? {
        guard let data = metadataJSON?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ArtifactMetadata.self, from: data)
    }

    /// Set metadata.
    func setMetadata(_ metadata: ArtifactMetadata) {
        if let data = try? JSONEncoder().encode(metadata),
           let json = String(data: data, encoding: .utf8) {
            metadataJSON = json
        }
    }

    /// Convert to ArtifactReference DTO.
    func toArtifactReference() -> ArtifactReference {
        ArtifactReference(
            id: id,
            uri: ArtifactURI(uri: uri ?? "") ?? ArtifactURI(type: .unknown, provider: "unknown", resourcePath: ""),
            displayName: displayName ?? "Unknown",
            createdAt: createdAt ?? Date(),
            introducedBy: introducedBy,
            sourceConversationId: sourceConversationId,
            sourceMessageId: sourceMessageId,
            metadata: metadata,
            isResolved: isResolved,
            lastAccessedAt: lastAccessedAt
        )
    }

    /// Mention count.
    var mentionCount: Int {
        mentions?.count ?? 0
    }
}

// MARK: - CDArtifactMention

/// A mention of an artifact within a research message.
/// Captures context and relationship of how the artifact was referenced.
@objc(CDArtifactMention)
public class CDArtifactMention: NSManagedObject, Identifiable {
    @NSManaged private var primitiveId: UUID?

    public var id: UUID {
        get {
            willAccessValue(forKey: "id")
            defer { didAccessValue(forKey: "id") }
            if let existingId = primitiveId {
                return existingId
            }
            let newId = UUID()
            primitiveId = newId
            return newId
        }
        set {
            willChangeValue(forKey: "id")
            primitiveId = newValue
            didChangeValue(forKey: "id")
        }
    }

    /// The artifact being mentioned
    @NSManaged public var artifactId: UUID?

    /// The artifact URI (denormalized for quick access)
    @NSManaged public var artifactURI: String?

    /// The message containing this mention
    @NSManaged public var messageId: UUID?

    /// The conversation containing this mention
    @NSManaged public var conversationId: UUID?

    /// How the artifact was mentioned (introduced, referenced, cited, etc.)
    @NSManaged public var mentionTypeRaw: String?

    /// Character offset in the message content
    @NSManaged public var characterOffset: Int32

    /// Length of the mention in characters
    @NSManaged public var characterLength: Int32

    /// Surrounding text context
    @NSManaged public var contextSnippet: String?

    /// When this mention was recorded
    @NSManaged public var recordedAt: Date?

    /// The actor who made this mention
    @NSManaged public var mentionedBy: String?

    /// Whether this is the first mention in the conversation
    @NSManaged public var isFirstMention: Bool

    // Relationships
    /// The artifact being mentioned
    @NSManaged public var artifact: CDArtifactReference?

    /// The message containing this mention
    @NSManaged public var message: CDResearchMessage?
}

// MARK: - CDArtifactMention Helpers

public extension CDArtifactMention {

    /// Get the mention type enum.
    var mentionType: ArtifactMentionType {
        guard let raw = mentionTypeRaw else { return .referenced }
        return ArtifactMentionType(rawValue: raw) ?? .referenced
    }

    /// Set the mention type.
    func setMentionType(_ type: ArtifactMentionType) {
        mentionTypeRaw = type.rawValue
    }

    /// Convert to ArtifactMention DTO.
    func toArtifactMention() -> ArtifactMention {
        ArtifactMention(
            id: id,
            artifactId: artifactId ?? UUID(),
            artifactURI: artifactURI ?? "",
            messageId: messageId ?? UUID(),
            conversationId: conversationId ?? UUID(),
            mentionType: mentionType,
            characterOffset: Int(characterOffset),
            characterLength: Int(characterLength),
            contextSnippet: contextSnippet,
            recordedAt: recordedAt ?? Date(),
            mentionedBy: mentionedBy,
            isFirstMention: isFirstMention
        )
    }
}

// MARK: - Fetch Request Extensions

public extension CDArtifactReference {
    @nonobjc class func fetchRequest() -> NSFetchRequest<CDArtifactReference> {
        NSFetchRequest<CDArtifactReference>(entityName: "CDArtifactReference")
    }
}

public extension CDArtifactMention {
    @nonobjc class func fetchRequest() -> NSFetchRequest<CDArtifactMention> {
        NSFetchRequest<CDArtifactMention>(entityName: "CDArtifactMention")
    }
}

public extension CDResearchConversation {
    @nonobjc class func fetchRequest() -> NSFetchRequest<CDResearchConversation> {
        NSFetchRequest<CDResearchConversation>(entityName: "CDResearchConversation")
    }
}

public extension CDResearchMessage {
    @nonobjc class func fetchRequest() -> NSFetchRequest<CDResearchMessage> {
        NSFetchRequest<CDResearchMessage>(entityName: "CDResearchMessage")
    }

    /// Convert to ResearchMessage DTO.
    func toDTO() -> ResearchMessage {
        ResearchMessage(
            id: id,
            conversationId: conversation?.id ?? UUID(),
            sequence: Int(conversationSequence),
            senderRole: senderRole,
            senderId: senderId,
            modelUsed: modelUsed,
            contentMarkdown: contentMarkdown,
            sentAt: sentAt,
            correlationId: correlationId,
            causationId: causationId,
            isSideConversationSynthesis: isSideConversationSynthesis,
            sideConversationId: sideConversation?.id,
            tokenCount: tokenCount > 0 ? Int(tokenCount) : nil,
            processingDurationMs: processingDurationMs > 0 ? Int(processingDurationMs) : nil,
            mentionedArtifactURIs: mentionedArtifactURIs
        )
    }
}

public extension CDResearchConversation {
    /// Convert to ResearchConversation DTO.
    func toDTO() -> ResearchConversation {
        ResearchConversation(
            id: id,
            title: title,
            participants: participants,
            createdAt: createdAt,
            lastActivityAt: lastActivityAt,
            summaryText: summaryText,
            isArchived: isArchived,
            tags: tags,
            parentConversationId: parentConversation?.id,
            messageCount: messageCount,
            latestSnippet: latestSnippet.isEmpty ? nil : latestSnippet
        )
    }
}
