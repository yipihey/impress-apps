//
//  CoreDataModel.swift
//  MessageManagerCore
//
//  Programmatic Core Data model definition.
//  Creates the data model in code instead of using .xcdatamodeld file.
//
//  NOTE: CloudKit integration requires:
//  - All attributes must be optional OR have a default value
//  - All relationships must have inverses
//

import CoreData
import Foundation

// MARK: - Core Data Model Builder

/// Builds the Core Data model programmatically.
public enum CoreDataModelBuilder {

    /// Create the managed object model for impart.
    public static func createModel() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()

        // Create entities
        let accountEntity = createAccountEntity()
        let folderEntity = createFolderEntity()
        let messageEntity = createMessageEntity()
        let messageContentEntity = createMessageContentEntity()
        let attachmentEntity = createAttachmentEntity()
        let threadEntity = createThreadEntity()
        let conversationEntity = createConversationEntity()
        let researchConversationEntity = createResearchConversationEntity()
        let researchMessageEntity = createResearchMessageEntity()
        let artifactReferenceEntity = createArtifactReferenceEntity()
        let artifactMentionEntity = createArtifactMentionEntity()

        // Set up relationships (all must have inverses for CloudKit)
        setupAccountFolderRelationship(accountEntity, folderEntity)
        setupFolderMessageRelationship(folderEntity, messageEntity)
        setupFolderHierarchyRelationship(folderEntity)
        setupMessageContentRelationship(messageEntity, messageContentEntity)
        setupMessageAttachmentRelationship(messageEntity, attachmentEntity)
        setupThreadMessageRelationship(threadEntity, messageEntity)
        setupConversationMessageRelationship(conversationEntity, messageEntity)
        setupResearchConversationRelationships(researchConversationEntity, researchMessageEntity, artifactReferenceEntity)
        setupResearchMessageRelationships(researchMessageEntity, researchConversationEntity)
        setupArtifactRelationships(artifactReferenceEntity, artifactMentionEntity, researchConversationEntity, researchMessageEntity)

        model.entities = [
            accountEntity,
            folderEntity,
            messageEntity,
            messageContentEntity,
            attachmentEntity,
            threadEntity,
            conversationEntity,
            researchConversationEntity,
            researchMessageEntity,
            artifactReferenceEntity,
            artifactMentionEntity
        ]

        return model
    }

    // MARK: - Entity Definitions
    // All non-optional attributes MUST have default values for CloudKit

    private static func createAccountEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "CDAccount"
        entity.managedObjectClassName = "MessageManagerCore.CDAccount"

        entity.properties = [
            attribute("id", .UUIDAttributeType, defaultValue: UUID()),
            attribute("email", .stringAttributeType, defaultValue: ""),
            attribute("displayName", .stringAttributeType, defaultValue: ""),
            attribute("imapHost", .stringAttributeType, defaultValue: ""),
            attribute("imapPort", .integer16AttributeType, defaultValue: 993),
            attribute("smtpHost", .stringAttributeType, defaultValue: ""),
            attribute("smtpPort", .integer16AttributeType, defaultValue: 587),
            attribute("isEnabled", .booleanAttributeType, defaultValue: true),
            attribute("lastSyncDate", .dateAttributeType, optional: true),
            attribute("signature", .stringAttributeType, optional: true),
            attribute("keychainItemId", .stringAttributeType, defaultValue: "")
        ]

        return entity
    }

    private static func createFolderEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "CDFolder"
        entity.managedObjectClassName = "MessageManagerCore.CDFolder"

        entity.properties = [
            attribute("id", .UUIDAttributeType, defaultValue: UUID()),
            attribute("name", .stringAttributeType, defaultValue: ""),
            attribute("fullPath", .stringAttributeType, defaultValue: ""),
            attribute("roleRaw", .stringAttributeType, defaultValue: "custom"),
            attribute("unreadCount", .integer32AttributeType, defaultValue: 0),
            attribute("totalCount", .integer32AttributeType, defaultValue: 0),
            attribute("sortOrder", .integer32AttributeType, defaultValue: 0),
            attribute("isExpanded", .booleanAttributeType, defaultValue: true),
            attribute("isSubscribed", .booleanAttributeType, defaultValue: true),
            attribute("delimiter", .stringAttributeType, defaultValue: "/"),
            attribute("uidValidity", .integer64AttributeType, defaultValue: 0),
            attribute("uidNext", .integer64AttributeType, defaultValue: 0),
            attribute("highestModSeq", .integer64AttributeType, defaultValue: 0)
        ]

        return entity
    }

    private static func createMessageEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "CDMessage"
        entity.managedObjectClassName = "MessageManagerCore.CDMessage"

        entity.properties = [
            attribute("id", .UUIDAttributeType, defaultValue: UUID()),
            attribute("uid", .integer64AttributeType, defaultValue: 0),
            attribute("messageId", .stringAttributeType, optional: true),
            attribute("inReplyTo", .stringAttributeType, optional: true),
            attribute("referencesJSON", .stringAttributeType, optional: true),
            attribute("subject", .stringAttributeType, defaultValue: ""),
            attribute("fromJSON", .stringAttributeType, defaultValue: "[]"),
            attribute("toJSON", .stringAttributeType, defaultValue: "[]"),
            attribute("ccJSON", .stringAttributeType, optional: true),
            attribute("bccJSON", .stringAttributeType, optional: true),
            attribute("replyToJSON", .stringAttributeType, optional: true),
            attribute("date", .dateAttributeType, defaultValue: Date()),
            attribute("receivedDate", .dateAttributeType, optional: true),
            attribute("snippet", .stringAttributeType, defaultValue: ""),
            attribute("isRead", .booleanAttributeType, defaultValue: false),
            attribute("isStarred", .booleanAttributeType, defaultValue: false),
            attribute("isDeleted", .booleanAttributeType, defaultValue: false),
            attribute("isDraft", .booleanAttributeType, defaultValue: false),
            attribute("hasAttachments", .booleanAttributeType, defaultValue: false),
            attribute("flags", .integer64AttributeType, defaultValue: 0),
            attribute("size", .integer64AttributeType, defaultValue: 0),
            attribute("categoryRaw", .stringAttributeType, defaultValue: "conversation"),
            attribute("agentAddress", .stringAttributeType, optional: true),
            attribute("agentStatus", .stringAttributeType, optional: true)
        ]

        return entity
    }

    private static func createMessageContentEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "CDMessageContent"
        entity.managedObjectClassName = "MessageManagerCore.CDMessageContent"

        entity.properties = [
            attribute("id", .UUIDAttributeType, defaultValue: UUID()),
            attribute("textBody", .stringAttributeType, optional: true),
            attribute("htmlBody", .stringAttributeType, optional: true),
            attribute("rawData", .binaryDataAttributeType, optional: true)
        ]

        return entity
    }

    private static func createAttachmentEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "CDAttachment"
        entity.managedObjectClassName = "MessageManagerCore.CDAttachment"

        entity.properties = [
            attribute("id", .UUIDAttributeType, defaultValue: UUID()),
            attribute("filename", .stringAttributeType, defaultValue: ""),
            attribute("mimeType", .stringAttributeType, defaultValue: "application/octet-stream"),
            attribute("size", .integer64AttributeType, defaultValue: 0),
            attribute("contentId", .stringAttributeType, optional: true),
            attribute("isInline", .booleanAttributeType, defaultValue: false),
            attribute("localPath", .stringAttributeType, optional: true)
        ]

        return entity
    }

    private static func createThreadEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "CDThread"
        entity.managedObjectClassName = "MessageManagerCore.CDThread"

        entity.properties = [
            attribute("id", .UUIDAttributeType, defaultValue: UUID()),
            attribute("subject", .stringAttributeType, defaultValue: ""),
            attribute("participantsJSON", .stringAttributeType, defaultValue: "[]"),
            attribute("messageCount", .integer32AttributeType, defaultValue: 0),
            attribute("unreadCount", .integer32AttributeType, defaultValue: 0),
            attribute("latestDate", .dateAttributeType, defaultValue: Date()),
            attribute("snippet", .stringAttributeType, defaultValue: ""),
            attribute("isStarred", .booleanAttributeType, defaultValue: false)
        ]

        return entity
    }

    private static func createConversationEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "CDConversation"
        entity.managedObjectClassName = "MessageManagerCore.CDConversation"

        entity.properties = [
            attribute("id", .UUIDAttributeType, defaultValue: UUID()),
            attribute("participantsJSON", .stringAttributeType, defaultValue: "[]"),
            attribute("subject", .stringAttributeType, optional: true),
            attribute("lastActivityAt", .dateAttributeType, defaultValue: Date()),
            attribute("messageCount", .integer32AttributeType, defaultValue: 0),
            attribute("unreadCount", .integer32AttributeType, defaultValue: 0),
            attribute("isAgentConversation", .booleanAttributeType, defaultValue: false),
            attribute("agentAddress", .stringAttributeType, optional: true),
            attribute("reviewStatus", .stringAttributeType, optional: true)
        ]

        return entity
    }

    private static func createResearchConversationEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "CDResearchConversation"
        entity.managedObjectClassName = "MessageManagerCore.CDResearchConversation"

        entity.properties = [
            attribute("id", .UUIDAttributeType, defaultValue: UUID()),
            attribute("title", .stringAttributeType, defaultValue: ""),
            attribute("participantsJSON", .stringAttributeType, defaultValue: "[]"),
            attribute("createdAt", .dateAttributeType, defaultValue: Date()),
            attribute("lastActivityAt", .dateAttributeType, defaultValue: Date()),
            attribute("summaryText", .stringAttributeType, optional: true),
            attribute("isArchived", .booleanAttributeType, defaultValue: false),
            attribute("tagsJSON", .stringAttributeType, optional: true)
        ]

        return entity
    }

    private static func createResearchMessageEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "CDResearchMessage"
        entity.managedObjectClassName = "MessageManagerCore.CDResearchMessage"

        entity.properties = [
            attribute("id", .UUIDAttributeType, defaultValue: UUID()),
            attribute("conversationSequence", .integer32AttributeType, defaultValue: 0),
            attribute("senderRoleRaw", .stringAttributeType, defaultValue: "user"),
            attribute("senderId", .stringAttributeType, defaultValue: ""),
            attribute("modelUsed", .stringAttributeType, optional: true),
            attribute("contentMarkdown", .stringAttributeType, defaultValue: ""),
            attribute("sentAt", .dateAttributeType, defaultValue: Date()),
            attribute("correlationId", .stringAttributeType, optional: true),
            attribute("causationId", .UUIDAttributeType, optional: true),
            attribute("isSideConversationSynthesis", .booleanAttributeType, defaultValue: false),
            attribute("sideConversationId", .UUIDAttributeType, optional: true),
            attribute("tokenCount", .integer32AttributeType, defaultValue: 0),
            attribute("processingDurationMs", .integer32AttributeType, defaultValue: 0)
        ]

        return entity
    }

    private static func createArtifactReferenceEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "CDArtifactReference"
        entity.managedObjectClassName = "MessageManagerCore.CDArtifactReference"

        entity.properties = [
            attribute("id", .UUIDAttributeType, defaultValue: UUID()),
            attribute("uriString", .stringAttributeType, defaultValue: ""),
            attribute("typeRaw", .stringAttributeType, defaultValue: "unknown"),
            attribute("displayName", .stringAttributeType, defaultValue: ""),
            attribute("version", .stringAttributeType, optional: true),
            attribute("introducedAt", .dateAttributeType, defaultValue: Date()),
            attribute("introducedBy", .stringAttributeType, defaultValue: ""),
            attribute("metadataJSON", .stringAttributeType, optional: true)
        ]

        return entity
    }

    private static func createArtifactMentionEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "CDArtifactMention"
        entity.managedObjectClassName = "MessageManagerCore.CDArtifactMention"

        entity.properties = [
            attribute("id", .UUIDAttributeType, defaultValue: UUID()),
            attribute("artifactURI", .stringAttributeType, defaultValue: ""),
            attribute("mentionedAt", .dateAttributeType, defaultValue: Date()),
            attribute("mentionedBy", .stringAttributeType, defaultValue: ""),
            attribute("context", .stringAttributeType, optional: true)
        ]

        return entity
    }

    // MARK: - Relationship Setup
    // All relationships must have inverses for CloudKit

    private static func setupAccountFolderRelationship(_ account: NSEntityDescription, _ folder: NSEntityDescription) {
        let accountToFolders = NSRelationshipDescription()
        accountToFolders.name = "folders"
        accountToFolders.destinationEntity = folder
        accountToFolders.isOptional = true
        accountToFolders.deleteRule = .cascadeDeleteRule

        let folderToAccount = NSRelationshipDescription()
        folderToAccount.name = "account"
        folderToAccount.destinationEntity = account
        folderToAccount.maxCount = 1
        folderToAccount.isOptional = true
        folderToAccount.deleteRule = .nullifyDeleteRule

        accountToFolders.inverseRelationship = folderToAccount
        folderToAccount.inverseRelationship = accountToFolders

        account.properties.append(accountToFolders)
        folder.properties.append(folderToAccount)
    }

    private static func setupFolderMessageRelationship(_ folder: NSEntityDescription, _ message: NSEntityDescription) {
        let folderToMessages = NSRelationshipDescription()
        folderToMessages.name = "messages"
        folderToMessages.destinationEntity = message
        folderToMessages.isOptional = true
        folderToMessages.deleteRule = .cascadeDeleteRule

        let messageToFolder = NSRelationshipDescription()
        messageToFolder.name = "folder"
        messageToFolder.destinationEntity = folder
        messageToFolder.maxCount = 1
        messageToFolder.isOptional = true
        messageToFolder.deleteRule = .nullifyDeleteRule

        folderToMessages.inverseRelationship = messageToFolder
        messageToFolder.inverseRelationship = folderToMessages

        folder.properties.append(folderToMessages)
        message.properties.append(messageToFolder)
    }

    private static func setupFolderHierarchyRelationship(_ folder: NSEntityDescription) {
        let parentToChildren = NSRelationshipDescription()
        parentToChildren.name = "children"
        parentToChildren.destinationEntity = folder
        parentToChildren.isOptional = true
        parentToChildren.deleteRule = .cascadeDeleteRule

        let childToParent = NSRelationshipDescription()
        childToParent.name = "parent"
        childToParent.destinationEntity = folder
        childToParent.maxCount = 1
        childToParent.isOptional = true
        childToParent.deleteRule = .nullifyDeleteRule

        parentToChildren.inverseRelationship = childToParent
        childToParent.inverseRelationship = parentToChildren

        folder.properties.append(parentToChildren)
        folder.properties.append(childToParent)
    }

    private static func setupMessageContentRelationship(_ message: NSEntityDescription, _ content: NSEntityDescription) {
        let messageToContent = NSRelationshipDescription()
        messageToContent.name = "content"
        messageToContent.destinationEntity = content
        messageToContent.maxCount = 1
        messageToContent.isOptional = true
        messageToContent.deleteRule = .cascadeDeleteRule

        let contentToMessage = NSRelationshipDescription()
        contentToMessage.name = "message"
        contentToMessage.destinationEntity = message
        contentToMessage.maxCount = 1
        contentToMessage.isOptional = true
        contentToMessage.deleteRule = .nullifyDeleteRule

        messageToContent.inverseRelationship = contentToMessage
        contentToMessage.inverseRelationship = messageToContent

        message.properties.append(messageToContent)
        content.properties.append(contentToMessage)
    }

    private static func setupMessageAttachmentRelationship(_ message: NSEntityDescription, _ attachment: NSEntityDescription) {
        let messageToAttachments = NSRelationshipDescription()
        messageToAttachments.name = "attachments"
        messageToAttachments.destinationEntity = attachment
        messageToAttachments.isOptional = true
        messageToAttachments.deleteRule = .cascadeDeleteRule

        let attachmentToMessage = NSRelationshipDescription()
        attachmentToMessage.name = "message"
        attachmentToMessage.destinationEntity = message
        attachmentToMessage.maxCount = 1
        attachmentToMessage.isOptional = true
        attachmentToMessage.deleteRule = .nullifyDeleteRule

        messageToAttachments.inverseRelationship = attachmentToMessage
        attachmentToMessage.inverseRelationship = messageToAttachments

        message.properties.append(messageToAttachments)
        attachment.properties.append(attachmentToMessage)
    }

    private static func setupThreadMessageRelationship(_ thread: NSEntityDescription, _ message: NSEntityDescription) {
        let threadToMessages = NSRelationshipDescription()
        threadToMessages.name = "messages"
        threadToMessages.destinationEntity = message
        threadToMessages.isOptional = true
        threadToMessages.deleteRule = .nullifyDeleteRule

        let messageToThread = NSRelationshipDescription()
        messageToThread.name = "thread"
        messageToThread.destinationEntity = thread
        messageToThread.maxCount = 1
        messageToThread.isOptional = true
        messageToThread.deleteRule = .nullifyDeleteRule

        threadToMessages.inverseRelationship = messageToThread
        messageToThread.inverseRelationship = threadToMessages

        thread.properties.append(threadToMessages)
        message.properties.append(messageToThread)
    }

    private static func setupConversationMessageRelationship(_ conversation: NSEntityDescription, _ message: NSEntityDescription) {
        let convToMessages = NSRelationshipDescription()
        convToMessages.name = "messages"
        convToMessages.destinationEntity = message
        convToMessages.isOptional = true
        convToMessages.deleteRule = .nullifyDeleteRule

        let messageToConv = NSRelationshipDescription()
        messageToConv.name = "conversation"
        messageToConv.destinationEntity = conversation
        messageToConv.maxCount = 1
        messageToConv.isOptional = true
        messageToConv.deleteRule = .nullifyDeleteRule

        convToMessages.inverseRelationship = messageToConv
        messageToConv.inverseRelationship = convToMessages

        conversation.properties.append(convToMessages)
        message.properties.append(messageToConv)
    }

    private static func setupResearchConversationRelationships(
        _ researchConv: NSEntityDescription,
        _ researchMsg: NSEntityDescription,
        _ artifact: NSEntityDescription
    ) {
        // Messages relationship
        let convToMessages = NSRelationshipDescription()
        convToMessages.name = "messages"
        convToMessages.destinationEntity = researchMsg
        convToMessages.isOptional = true
        convToMessages.deleteRule = .cascadeDeleteRule

        // Artifacts relationship
        let convToArtifacts = NSRelationshipDescription()
        convToArtifacts.name = "artifacts"
        convToArtifacts.destinationEntity = artifact
        convToArtifacts.isOptional = true
        convToArtifacts.deleteRule = .nullifyDeleteRule

        // Parent/child conversation hierarchy
        let parentToChildren = NSRelationshipDescription()
        parentToChildren.name = "childConversations"
        parentToChildren.destinationEntity = researchConv
        parentToChildren.isOptional = true
        parentToChildren.deleteRule = .nullifyDeleteRule

        let childToParent = NSRelationshipDescription()
        childToParent.name = "parentConversation"
        childToParent.destinationEntity = researchConv
        childToParent.maxCount = 1
        childToParent.isOptional = true
        childToParent.deleteRule = .nullifyDeleteRule

        parentToChildren.inverseRelationship = childToParent
        childToParent.inverseRelationship = parentToChildren

        researchConv.properties.append(convToMessages)
        researchConv.properties.append(convToArtifacts)
        researchConv.properties.append(parentToChildren)
        researchConv.properties.append(childToParent)
    }

    private static func setupResearchMessageRelationships(
        _ researchMsg: NSEntityDescription,
        _ researchConv: NSEntityDescription
    ) {
        let msgToConv = NSRelationshipDescription()
        msgToConv.name = "conversation"
        msgToConv.destinationEntity = researchConv
        msgToConv.maxCount = 1
        msgToConv.isOptional = true
        msgToConv.deleteRule = .nullifyDeleteRule

        // Find the inverse from research conversation
        if let convToMessages = researchConv.properties.first(where: { $0.name == "messages" }) as? NSRelationshipDescription {
            msgToConv.inverseRelationship = convToMessages
            convToMessages.inverseRelationship = msgToConv
        }

        researchMsg.properties.append(msgToConv)
    }

    private static func setupArtifactRelationships(
        _ artifact: NSEntityDescription,
        _ mention: NSEntityDescription,
        _ researchConv: NSEntityDescription,
        _ researchMsg: NSEntityDescription
    ) {
        // Artifact to source conversation
        let artifactToConv = NSRelationshipDescription()
        artifactToConv.name = "sourceConversation"
        artifactToConv.destinationEntity = researchConv
        artifactToConv.maxCount = 1
        artifactToConv.isOptional = true
        artifactToConv.deleteRule = .nullifyDeleteRule

        // Find the inverse from research conversation
        if let convToArtifacts = researchConv.properties.first(where: { $0.name == "artifacts" }) as? NSRelationshipDescription {
            artifactToConv.inverseRelationship = convToArtifacts
            convToArtifacts.inverseRelationship = artifactToConv
        }

        // Artifact to mentions
        let artifactToMentions = NSRelationshipDescription()
        artifactToMentions.name = "mentions"
        artifactToMentions.destinationEntity = mention
        artifactToMentions.isOptional = true
        artifactToMentions.deleteRule = .cascadeDeleteRule

        let mentionToArtifact = NSRelationshipDescription()
        mentionToArtifact.name = "artifact"
        mentionToArtifact.destinationEntity = artifact
        mentionToArtifact.maxCount = 1
        mentionToArtifact.isOptional = true
        mentionToArtifact.deleteRule = .nullifyDeleteRule

        artifactToMentions.inverseRelationship = mentionToArtifact
        mentionToArtifact.inverseRelationship = artifactToMentions

        // Mention to message (with inverse)
        let mentionToMessage = NSRelationshipDescription()
        mentionToMessage.name = "message"
        mentionToMessage.destinationEntity = researchMsg
        mentionToMessage.maxCount = 1
        mentionToMessage.isOptional = true
        mentionToMessage.deleteRule = .nullifyDeleteRule

        // Create inverse: message to mentions
        let messageToMentions = NSRelationshipDescription()
        messageToMentions.name = "artifactMentions"
        messageToMentions.destinationEntity = mention
        messageToMentions.isOptional = true
        messageToMentions.deleteRule = .cascadeDeleteRule

        mentionToMessage.inverseRelationship = messageToMentions
        messageToMentions.inverseRelationship = mentionToMessage

        artifact.properties.append(artifactToConv)
        artifact.properties.append(artifactToMentions)
        mention.properties.append(mentionToArtifact)
        mention.properties.append(mentionToMessage)
        researchMsg.properties.append(messageToMentions)
    }

    // MARK: - Helpers

    private static func attribute(
        _ name: String,
        _ type: NSAttributeType,
        optional: Bool = false,
        defaultValue: Any? = nil
    ) -> NSAttributeDescription {
        let attr = NSAttributeDescription()
        attr.name = name
        attr.attributeType = type
        attr.isOptional = optional
        if let value = defaultValue {
            attr.defaultValue = value
        }
        return attr
    }
}
