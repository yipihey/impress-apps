//
//  ImpartDragDropTypes.swift
//  MessageManagerCore
//
//  Drag-and-drop UTTypes and utilities for impart.
//

import Foundation
import UniformTypeIdentifiers

// MARK: - UTType Extensions

public extension UTType {
    /// Folder ID for drag-drop operations.
    static var impartFolderID: UTType {
        UTType(exportedAs: "com.impart.folder-id")
    }

    /// Message ID for drag-drop operations.
    static var impartMessageID: UTType {
        UTType(exportedAs: "com.impart.message-id")
    }

    /// Multiple message IDs for drag-drop operations.
    static var impartMessageIDs: UTType {
        UTType(exportedAs: "com.impart.message-ids")
    }

    /// Conversation ID for drag-drop operations.
    static var impartConversationID: UTType {
        UTType(exportedAs: "com.impart.conversation-id")
    }
}

// MARK: - Drag Data

/// Data for dragging a folder.
public struct FolderDragData: Codable, Sendable {
    public let folderId: UUID
    public let folderName: String
    public let accountId: UUID

    public init(folderId: UUID, folderName: String, accountId: UUID) {
        self.folderId = folderId
        self.folderName = folderName
        self.accountId = accountId
    }

    /// Encode to data for drag operation.
    public func encode() -> Data? {
        try? JSONEncoder().encode(self)
    }

    /// Decode from data in drop operation.
    public static func decode(from data: Data) -> FolderDragData? {
        try? JSONDecoder().decode(FolderDragData.self, from: data)
    }
}

/// Data for dragging messages.
public struct MessageDragData: Codable, Sendable {
    public let messageIds: [UUID]
    public let sourceFolderId: UUID?
    public let accountId: UUID

    public init(messageIds: [UUID], sourceFolderId: UUID?, accountId: UUID) {
        self.messageIds = messageIds
        self.sourceFolderId = sourceFolderId
        self.accountId = accountId
    }

    /// Encode to data for drag operation.
    public func encode() -> Data? {
        try? JSONEncoder().encode(self)
    }

    /// Decode from data in drop operation.
    public static func decode(from data: Data) -> MessageDragData? {
        try? JSONDecoder().decode(MessageDragData.self, from: data)
    }
}

/// Data for dragging a conversation.
public struct ConversationDragData: Codable, Sendable {
    public let conversationId: UUID
    public let messageIds: [UUID]
    public let accountId: UUID

    public init(conversationId: UUID, messageIds: [UUID], accountId: UUID) {
        self.conversationId = conversationId
        self.messageIds = messageIds
        self.accountId = accountId
    }

    /// Encode to data for drag operation.
    public func encode() -> Data? {
        try? JSONEncoder().encode(self)
    }

    /// Decode from data in drop operation.
    public static func decode(from data: Data) -> ConversationDragData? {
        try? JSONDecoder().decode(ConversationDragData.self, from: data)
    }
}

// MARK: - Drop Target Type

/// Types of valid drop targets.
public enum DropTargetType: Sendable {
    case folder(UUID)
    case account(UUID)
    case trash
    case archive
}

// MARK: - Drop Validation

/// Validate drop operations.
public struct DropValidator {

    /// Validate dropping folders onto a target folder.
    public static func canDropFolder(
        dragData: FolderDragData,
        onto targetFolderId: UUID,
        targetAncestors: [UUID]
    ) -> Bool {
        // Can't drop onto self
        if dragData.folderId == targetFolderId {
            return false
        }

        // Can't drop onto descendant (circular reference)
        if targetAncestors.contains(dragData.folderId) {
            return false
        }

        return true
    }

    /// Validate dropping messages onto a folder.
    public static func canDropMessages(
        dragData: MessageDragData,
        onto targetFolderId: UUID
    ) -> Bool {
        // Can't drop onto same folder
        if dragData.sourceFolderId == targetFolderId {
            return false
        }

        return true
    }

    /// Validate dropping external files.
    public static func canDropFiles(
        _ urls: [URL],
        onto targetFolderId: UUID
    ) -> Bool {
        // Check for supported file types
        let supportedExtensions = ["eml", "mbox", "msg"]
        for url in urls {
            if !supportedExtensions.contains(url.pathExtension.lowercased()) {
                return false
            }
        }
        return !urls.isEmpty
    }
}

// MARK: - Drag Preview

/// Generate previews for drag operations.
public struct DragPreviewGenerator {

    /// Generate preview text for dragging messages.
    public static func previewText(forMessageCount count: Int) -> String {
        if count == 1 {
            return "1 message"
        } else {
            return "\(count) messages"
        }
    }

    /// Generate preview text for dragging a folder.
    public static func previewText(forFolderName name: String) -> String {
        name
    }
}
