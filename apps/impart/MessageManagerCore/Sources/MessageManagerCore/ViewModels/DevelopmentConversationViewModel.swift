//
//  DevelopmentConversationViewModel.swift
//  MessageManagerCore
//
//  View model for development conversations with planning mode support.
//  Supports both email (thread-based) and chat (linear) view modes.
//

import Foundation
import Observation
import OSLog

// MARK: - View Display Mode

/// View display mode for conversations.
public enum ConversationViewMode: String, CaseIterable, Sendable {
    /// Thread-based view (planning sessions as separate threads)
    case email

    /// Linear chat view (with optional threading for planning)
    case chat

    public var displayName: String {
        switch self {
        case .email: return "Threads"
        case .chat: return "Chat"
        }
    }

    public var iconName: String {
        switch self {
        case .email: return "envelope.open"
        case .chat: return "bubble.left.and.bubble.right"
        }
    }
}

// MARK: - Development Conversation View Model

/// View model for development conversations with email/chat view mode support.
@MainActor @Observable
public final class DevelopmentConversationViewModel {

    // MARK: - Published State

    /// Current view mode (email vs chat)
    public var viewMode: ConversationViewMode = .chat

    /// All conversations
    public private(set) var conversations: [DevelopmentConversation] = []

    /// Selected conversation
    public var selectedConversation: DevelopmentConversation? {
        didSet {
            if let conversation = selectedConversation {
                Task {
                    await loadConversationDetails(conversation)
                }
            } else {
                messages = []
                planningSessions = []
                attachedArtifacts = []
            }
        }
    }

    /// Messages in selected conversation
    public private(set) var messages: [DevelopmentMessage] = []

    /// Planning sessions for selected conversation (email view)
    public private(set) var planningSessions: [DevelopmentConversation] = []

    /// Currently attached directory artifacts
    public private(set) var attachedArtifacts: [DirectoryArtifact] = []

    /// Whether loading
    public private(set) var isLoading = false

    /// Error message
    public private(set) var errorMessage: String?

    // MARK: - Filter State

    /// Mode filter for conversation list
    public var modeFilter: ConversationMode?

    /// Whether to include archived conversations
    public var includeArchived = false

    // MARK: - Private

    private let service: DevelopmentConversationService
    private let artifactManager: DirectoryArtifactManager

    // MARK: - Initialization

    public init(
        service: DevelopmentConversationService? = nil,
        artifactManager: DirectoryArtifactManager = .shared
    ) {
        self.service = service ?? DevelopmentConversationService()
        self.artifactManager = artifactManager
    }

    // MARK: - Load Operations

    /// Load conversations from the database.
    public func loadConversations() async {
        isLoading = true
        errorMessage = nil

        do {
            conversations = try await service.fetchConversations(
                mode: modeFilter,
                includeArchived: includeArchived
            )
        } catch {
            errorMessage = error.localizedDescription
            Logger.viewModels.error("Failed to load conversations: \(error.localizedDescription)")
        }

        isLoading = false
    }

    /// Load details for a conversation.
    private func loadConversationDetails(_ conversation: DevelopmentConversation) async {
        isLoading = true
        errorMessage = nil

        do {
            async let fetchedMessages = service.fetchMessages(for: conversation.id)
            async let fetchedSessions = service.fetchPlanningSessions(for: conversation.id)
            async let fetchedArtifacts = service.fetchArtifacts(for: conversation.id)

            messages = try await fetchedMessages
            planningSessions = try await fetchedSessions
            attachedArtifacts = try await fetchedArtifacts
        } catch {
            errorMessage = error.localizedDescription
            Logger.viewModels.error("Failed to load conversation details: \(error.localizedDescription)")
        }

        isLoading = false
    }

    // MARK: - Conversation Actions

    /// Create a new conversation.
    /// - Parameters:
    ///   - title: Conversation title
    ///   - mode: Conversation mode
    ///   - artifact: Optional initial directory artifact
    public func createConversation(
        title: String,
        mode: ConversationMode = .interactive,
        artifact: DirectoryArtifact? = nil
    ) async {
        errorMessage = nil

        do {
            let id = try await service.createConversation(
                title: title,
                mode: mode,
                artifact: artifact
            )

            // Reload and select the new conversation
            await loadConversations()

            if let conversation = conversations.first(where: { $0.id == id }) {
                selectedConversation = conversation
            }

            Logger.viewModels.info("Created conversation: \(title)")
        } catch {
            errorMessage = error.localizedDescription
            Logger.viewModels.error("Failed to create conversation: \(error.localizedDescription)")
        }
    }

    /// Start a planning session in the selected conversation.
    /// - Parameter title: Planning session title
    public func startPlanningSession(title: String) async {
        guard let conversation = selectedConversation else { return }
        errorMessage = nil

        do {
            _ = try await service.startPlanningSession(
                conversationId: conversation.id,
                title: title
            )

            // Reload planning sessions
            planningSessions = try await service.fetchPlanningSessions(for: conversation.id)

            Logger.viewModels.info("Started planning session: \(title)")
        } catch {
            errorMessage = error.localizedDescription
            Logger.viewModels.error("Failed to start planning session: \(error.localizedDescription)")
        }
    }

    /// Archive the selected conversation.
    public func archiveSelectedConversation() async {
        guard let conversation = selectedConversation else { return }
        errorMessage = nil

        do {
            try await service.archiveConversation(conversation.id)
            await loadConversations()
            selectedConversation = nil

            Logger.viewModels.info("Archived conversation: \(conversation.title)")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Delete the selected conversation.
    public func deleteSelectedConversation() async {
        guard let conversation = selectedConversation else { return }
        errorMessage = nil

        do {
            // Stop accessing any artifacts
            for artifact in attachedArtifacts {
                await artifactManager.stopAccessing(artifact)
            }

            try await service.deleteConversation(conversation.id)
            await loadConversations()
            selectedConversation = nil

            Logger.viewModels.info("Deleted conversation: \(conversation.title)")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Message Actions

    /// Send a message to the selected conversation.
    /// - Parameters:
    ///   - content: Message content (Markdown)
    ///   - intent: Message intent
    public func sendMessage(
        content: String,
        intent: MessageIntent = .converse
    ) async {
        guard let conversation = selectedConversation else { return }
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        errorMessage = nil

        do {
            _ = try await service.addMessage(
                to: conversation.id,
                content: content,
                role: .human,
                intent: intent
            )

            // Reload messages
            messages = try await service.fetchMessages(for: conversation.id)
        } catch {
            errorMessage = error.localizedDescription
            Logger.viewModels.error("Failed to send message: \(error.localizedDescription)")
        }
    }

    // MARK: - Artifact Actions

    /// Attach an external directory to the selected conversation.
    /// - Parameter url: The directory URL (must have user permission)
    public func attachDirectory(url: URL) async {
        guard let conversation = selectedConversation else { return }
        errorMessage = nil

        do {
            let artifact = try DirectoryArtifact(url: url)
            try await service.attachArtifact(to: conversation.id, artifact: artifact)
            attachedArtifacts.append(artifact)

            Logger.viewModels.info("Attached directory: \(url.lastPathComponent)")
        } catch {
            errorMessage = error.localizedDescription
            Logger.viewModels.error("Failed to attach directory: \(error.localizedDescription)")
        }
    }

    /// Remove an artifact from the selected conversation.
    /// - Parameter artifact: The artifact to remove
    public func removeArtifact(_ artifact: DirectoryArtifact) async {
        guard let conversation = selectedConversation else { return }
        errorMessage = nil

        do {
            await artifactManager.stopAccessing(artifact)
            try await service.removeArtifact(from: conversation.id, artifactId: artifact.id)
            attachedArtifacts.removeAll { $0.id == artifact.id }

            Logger.viewModels.info("Removed artifact: \(artifact.name)")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Start accessing an artifact's directory.
    /// - Parameter artifact: The artifact to access
    /// - Returns: The URL if access was granted
    public func startAccessingArtifact(_ artifact: DirectoryArtifact) async -> URL? {
        await artifactManager.startAccessing(artifact)
    }

    /// Stop accessing an artifact's directory.
    /// - Parameter artifact: The artifact to stop accessing
    public func stopAccessingArtifact(_ artifact: DirectoryArtifact) async {
        await artifactManager.stopAccessing(artifact)
    }

    // MARK: - View Mode Helpers

    /// Threads for email view (main conversation + planning sessions).
    public var emailThreads: [EmailThread] {
        guard let conversation = selectedConversation else { return [] }

        var threads: [EmailThread] = []

        // Main conversation thread
        threads.append(EmailThread(
            id: conversation.id,
            subject: conversation.title,
            mode: conversation.mode,
            messageCount: conversation.messageCount,
            latestDate: conversation.lastActivityAt,
            isPlanning: false
        ))

        // Planning session threads
        for session in planningSessions {
            threads.append(EmailThread(
                id: session.id,
                subject: "Planning: \(session.title)",
                mode: session.mode,
                messageCount: session.messageCount,
                latestDate: session.lastActivityAt,
                isPlanning: true
            ))
        }

        return threads.sorted { $0.latestDate > $1.latestDate }
    }

    /// Whether to show threading in chat view.
    public var shouldShowChatThreading: Bool {
        messages.count > 1 && selectedConversation?.mode == .planning
    }

    /// Messages grouped by intent for display.
    public var groupedMessages: [[DevelopmentMessage]] {
        guard !messages.isEmpty else { return [] }

        var groups: [[DevelopmentMessage]] = []
        var currentGroup: [DevelopmentMessage] = []
        var currentIntent: MessageIntent?

        for message in messages {
            if message.intent != currentIntent && !currentGroup.isEmpty {
                groups.append(currentGroup)
                currentGroup = []
            }
            currentGroup.append(message)
            currentIntent = message.intent
        }

        if !currentGroup.isEmpty {
            groups.append(currentGroup)
        }

        return groups
    }

    // MARK: - Selection

    /// Select a conversation by ID.
    /// - Parameter id: Conversation ID
    public func selectConversation(id: UUID) {
        selectedConversation = conversations.first { $0.id == id }
    }

    /// Clear the current selection.
    public func clearSelection() {
        selectedConversation = nil
    }
}

// MARK: - Email Thread

/// Thread representation for email view.
public struct EmailThread: Identifiable, Sendable {
    public let id: UUID
    public let subject: String
    public let mode: ConversationMode
    public let messageCount: Int
    public let latestDate: Date
    public let isPlanning: Bool

    public init(
        id: UUID,
        subject: String,
        mode: ConversationMode,
        messageCount: Int,
        latestDate: Date,
        isPlanning: Bool
    ) {
        self.id = id
        self.subject = subject
        self.mode = mode
        self.messageCount = messageCount
        self.latestDate = latestDate
        self.isPlanning = isPlanning
    }
}
