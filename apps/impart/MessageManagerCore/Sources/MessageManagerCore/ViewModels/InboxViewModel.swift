//
//  InboxViewModel.swift
//  MessageManagerCore
//
//  View model for the inbox/message list view.
//  Supports view modes, triage actions, and AI agent integration.
//

import Foundation
import Observation
import OSLog

private let inboxLogger = Logger(subsystem: "com.imbib.impart", category: "inbox")

// MARK: - Inbox View Model

/// View model for displaying messages in a mailbox.
@MainActor @Observable
public final class InboxViewModel {

    // MARK: - Published State

    /// Currently selected account.
    public var selectedAccount: Account?

    /// Currently selected mailbox.
    public var selectedMailbox: Mailbox?

    /// Selected account ID.
    public var selectedAccountId: UUID?

    /// Messages in the current mailbox.
    public private(set) var messages: [Message] = []

    /// Threads in the current mailbox (when threading is enabled).
    public private(set) var threads: [Thread] = []

    /// Accounts available.
    public private(set) var accounts: [Account] = []

    /// Currently selected conversation (for chat view).
    public var selectedConversation: CDConversation?

    /// Selected message IDs.
    public var selectedMessageIds: Set<UUID> = []

    /// Whether messages are currently loading.
    public private(set) var isLoading = false

    /// Whether an AI agent is currently processing.
    public private(set) var isAgentProcessing = false

    /// Current error message, if any.
    public private(set) var errorMessage: String?

    /// Whether to show messages as threads.
    public var showAsThreads = true

    /// Current search query.
    public var searchQuery = ""

    /// Current sort order.
    public var sortOrder: SortOrder = .dateDescending

    /// Total unread count across all accounts.
    public var totalUnreadCount: Int {
        messages.filter { !$0.isRead }.count
    }

    /// Current account email (for chat view).
    public var currentAccountEmail: String? {
        selectedAccount?.email
    }

    // MARK: - Private Properties

    private let persistence: PersistenceController
    private let triageService: MessageTriageService
    private let folderManager: FolderManager
    private let syncService: SyncService

    // MARK: - Initialization

    public init(persistence: PersistenceController, syncService: SyncService? = nil) {
        self.persistence = persistence
        self.triageService = MessageTriageService(persistenceController: persistence)
        self.folderManager = FolderManager(persistenceController: persistence)
        self.syncService = syncService ?? SyncService(persistence: persistence)
    }

    /// Convenience initializer using shared persistence controller.
    public init() {
        self.persistence = .shared
        self.triageService = MessageTriageService()
        self.folderManager = FolderManager()
        self.syncService = SyncService(persistence: .shared)
    }

    // MARK: - Actions

    /// Load messages for the selected mailbox.
    public func loadMessages() async {
        guard let mailbox = selectedMailbox else {
            messages = []
            threads = []
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            // Fetch messages from Core Data
            messages = try await fetchMessagesFromStore(mailbox: mailbox)

            // Thread messages if enabled
            if showAsThreads {
                threads = await threadMessages(messages)
            } else {
                threads = []
            }

            inboxLogger.info("Loaded \(self.messages.count) messages from \(mailbox.name)")
        } catch {
            errorMessage = error.localizedDescription
            inboxLogger.error("Failed to load messages: \(error.localizedDescription)")
        }

        isLoading = false
    }

    /// Refresh messages from the server.
    public func refresh() async {
        guard let account = selectedAccount, let mailbox = selectedMailbox else { return }

        isLoading = true
        errorMessage = nil

        do {
            // Sync from server
            let newMessages = try await syncService.syncMessages(
                for: account,
                mailbox: mailbox
            )

            // Reload from store
            messages = try await fetchMessagesFromStore(mailbox: mailbox)

            if showAsThreads {
                threads = await threadMessages(messages)
            } else {
                threads = []
            }

            inboxLogger.info("Refreshed \(mailbox.name) with \(newMessages.count) messages")
        } catch {
            errorMessage = error.localizedDescription
            inboxLogger.error("Failed to refresh: \(error.localizedDescription)")
        }

        isLoading = false
    }

    // MARK: - Private Helpers

    private func fetchMessagesFromStore(mailbox: Mailbox) async throws -> [Message] {
        try await persistence.performBackgroundTask { context in
            let request = CDMessage.fetchRequest()
            request.predicate = NSPredicate(format: "folder.fullPath == %@", mailbox.fullPath)
            request.sortDescriptors = [NSSortDescriptor(keyPath: \CDMessage.date, ascending: false)]

            let cdMessages = try context.fetch(request)
            return cdMessages.map { $0.toMessage() }
        }
    }

    private func threadMessages(_ messages: [Message]) async -> [Thread] {
        // Convert to Rust envelopes and thread using JWZ algorithm
        // For now, group by subject prefix as a simple alternative
        var threadDict: [String: [Message]] = [:]

        for message in messages {
            let normalizedSubject = normalizeSubject(message.subject)
            threadDict[normalizedSubject, default: []].append(message)
        }

        return threadDict.map { (subject, msgs) in
            let sortedMsgs = msgs.sorted { $0.date < $1.date }
            let allParticipants = Set(sortedMsgs.flatMap { $0.from + $0.to + $0.cc })

            return Thread(
                subject: sortedMsgs.first?.subject ?? subject,
                participants: Array(allParticipants),
                messageCount: sortedMsgs.count,
                unreadCount: sortedMsgs.filter { !$0.isRead }.count,
                latestDate: sortedMsgs.last?.date ?? Date(),
                snippet: sortedMsgs.last?.snippet ?? "",
                messageIds: sortedMsgs.map(\.id)
            )
        }.sorted { $0.latestDate > $1.latestDate }
    }

    private func normalizeSubject(_ subject: String) -> String {
        var normalized = subject.lowercased()
        // Remove common prefixes
        let prefixes = ["re:", "fwd:", "fw:", "re[", "fwd["]
        for prefix in prefixes {
            while normalized.hasPrefix(prefix) {
                normalized = String(normalized.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                // Handle numbered replies like "Re[2]:"
                if prefix.last == "[", let endBracket = normalized.firstIndex(of: "]") {
                    let afterBracket = normalized.index(after: endBracket)
                    if afterBracket < normalized.endIndex && normalized[afterBracket] == ":" {
                        normalized = String(normalized[normalized.index(after: afterBracket)...]).trimmingCharacters(in: .whitespaces)
                    }
                }
            }
        }
        return normalized
    }

    /// Mark messages as read.
    public func markAsRead(_ messageIds: [UUID]) async {
        // TODO: Update local and sync to server
        for i in messages.indices where messageIds.contains(messages[i].id) {
            // messages[i].isRead = true (would need mutable copy)
        }
    }

    /// Mark messages as unread.
    public func markAsUnread(_ messageIds: [UUID]) async {
        // TODO: Update local and sync to server
    }

    /// Star/unstar messages.
    public func toggleStar(_ messageIds: [UUID]) async {
        // TODO: Update local and sync to server
    }

    /// Move messages to another mailbox.
    public func move(_ messageIds: [UUID], to mailbox: Mailbox) async {
        // TODO: Update local and sync to server
    }

    /// Delete messages (move to trash).
    public func delete(_ messageIds: [UUID]) async {
        // TODO: Move to trash or permanently delete
    }

    /// Archive messages.
    public func archive(_ messageIds: [UUID]) async {
        // TODO: Move to archive folder
    }

    // MARK: - Filtering

    /// Filtered messages based on search query.
    public var filteredMessages: [Message] {
        guard !searchQuery.isEmpty else { return sortedMessages }

        let query = searchQuery.lowercased()
        return sortedMessages.filter { message in
            message.subject.lowercased().contains(query) ||
            message.fromDisplayString.lowercased().contains(query) ||
            message.snippet.lowercased().contains(query)
        }
    }

    /// Sorted messages based on current sort order.
    public var sortedMessages: [Message] {
        switch sortOrder {
        case .dateDescending:
            return messages.sorted { $0.date > $1.date }
        case .dateAscending:
            return messages.sorted { $0.date < $1.date }
        case .senderAscending:
            return messages.sorted { $0.fromDisplayString < $1.fromDisplayString }
        case .senderDescending:
            return messages.sorted { $0.fromDisplayString > $1.fromDisplayString }
        case .subjectAscending:
            return messages.sorted { $0.subject < $1.subject }
        case .subjectDescending:
            return messages.sorted { $0.subject > $1.subject }
        }
    }

    /// Unread message count.
    public var unreadCount: Int {
        messages.filter { !$0.isRead }.count
    }

    /// Get unread count for a specific account.
    public func unreadCount(for accountId: UUID) -> Int? {
        // TODO: Implement per-account unread count
        return nil
    }

    // MARK: - View Mode Actions

    /// Toggle between view modes.
    public func toggleViewMode() {
        // Handled by ViewModeState in the view
    }

    /// Send a reply in chat view.
    public func sendReply(_ text: String) async {
        // TODO: Implement send reply
        inboxLogger.info("Sending reply: \(text.prefix(50))...")
    }

    // MARK: - Triage Actions

    /// Dismiss (archive) messages.
    public func dismissMessages(ids: Set<UUID>, currentSelection: UUID?) async -> MessageTriageResult {
        let orderedIds = sortedMessages.map(\.id)
        return await triageService.dismiss(ids: ids, from: orderedIds, currentSelection: currentSelection)
    }

    /// Save messages.
    public func saveMessages(ids: Set<UUID>, currentSelection: UUID?) async -> MessageTriageResult {
        let orderedIds = sortedMessages.map(\.id)
        return await triageService.save(ids: ids, from: orderedIds, currentSelection: currentSelection)
    }

    /// Toggle star on messages.
    public func toggleStar(for ids: Set<UUID>) async {
        let orderedIds = sortedMessages.map(\.id)
        _ = await triageService.toggleStar(ids: ids, from: orderedIds)
    }

    /// Toggle star on a single message.
    public func toggleStar(for id: UUID) async {
        await toggleStar(for: [id])
    }

    /// Mark messages as read.
    public func markAsRead(ids: Set<UUID>) async {
        _ = await triageService.markRead(ids: ids)
    }

    /// Mark messages as unread.
    public func markAsUnread(ids: Set<UUID>) async {
        _ = await triageService.markUnread(ids: ids)
    }

    // MARK: - Folder Actions

    /// Create a new folder.
    public func createFolder(name: String, parent: UUID?) async {
        guard let accountId = selectedAccountId else { return }
        do {
            _ = try await folderManager.createFolder(name: name, parent: parent, accountId: accountId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Rename a folder.
    public func renameFolder(_ id: UUID, to name: String) async {
        do {
            try await folderManager.renameFolder(id, to: name)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Move a folder.
    public func moveFolder(_ id: UUID, to parentId: UUID?) async {
        do {
            try await folderManager.moveFolder(id, to: parentId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Delete a folder.
    public func deleteFolder(_ id: UUID) async {
        do {
            try await folderManager.deleteFolder(id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Move messages to a folder.
    public func moveMessages(_ ids: [UUID], to folderId: UUID) async {
        let orderedIds = sortedMessages.map(\.id)
        _ = await triageService.moveToFolder(
            ids: Set(ids),
            folderId: folderId,
            from: orderedIds,
            currentSelection: selectedMessageIds.first
        )
    }
}

// MARK: - Sort Order

/// Message list sort order.
public enum SortOrder: String, CaseIterable, Sendable {
    case dateDescending = "date_desc"
    case dateAscending = "date_asc"
    case senderAscending = "sender_asc"
    case senderDescending = "sender_desc"
    case subjectAscending = "subject_asc"
    case subjectDescending = "subject_desc"

    public var displayName: String {
        switch self {
        case .dateDescending: return "Newest First"
        case .dateAscending: return "Oldest First"
        case .senderAscending: return "Sender (A-Z)"
        case .senderDescending: return "Sender (Z-A)"
        case .subjectAscending: return "Subject (A-Z)"
        case .subjectDescending: return "Subject (Z-A)"
        }
    }

    public var iconName: String {
        switch self {
        case .dateDescending, .senderDescending, .subjectDescending:
            return "arrow.down"
        case .dateAscending, .senderAscending, .subjectAscending:
            return "arrow.up"
        }
    }
}
