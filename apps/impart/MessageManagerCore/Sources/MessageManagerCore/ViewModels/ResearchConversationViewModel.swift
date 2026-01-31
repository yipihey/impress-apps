//
//  ResearchConversationViewModel.swift
//  MessageManagerCore
//
//  SwiftUI view model for research conversations.
//  Manages state for research conversation UI.
//

import Combine
import Foundation
import OSLog

private let viewModelLogger = Logger(subsystem: "com.impart", category: "research-vm")

// MARK: - Research Conversation View Model

/// View model for a research conversation.
@MainActor
public final class ResearchConversationViewModel: ObservableObject {

    // MARK: - Published Properties

    /// The current conversation.
    @Published public var conversation: ResearchConversation?

    /// Messages in the conversation.
    @Published public var messages: [ResearchMessage] = []

    /// Currently attached artifacts.
    @Published public var attachedArtifacts: [ArtifactReference] = []

    /// Current message input.
    @Published public var messageInput: String = ""

    /// Whether a message is being sent.
    @Published public var isSending: Bool = false

    /// Whether the conversation is loading.
    @Published public var isLoading: Bool = false

    /// Error message if any.
    @Published public var errorMessage: String?

    /// Timeline items for display (messages + side conversation markers).
    @Published public var timelineItems: [TimelineItem] = []

    /// Statistics about the conversation.
    @Published public var stats: ResearchConversationSummary?

    /// Streaming content for real-time AI response display.
    @Published public var streamingContent: String = ""

    /// Whether we are currently receiving a streaming response.
    @Published public var isStreaming: Bool = false

    // MARK: - Private Properties

    private let persistenceController: PersistenceController
    private let provenanceService: ProvenanceService
    private let artifactService: ArtifactService
    private let repository: ResearchConversationRepository
    private var counselSession: CounselSession?
    private let userId: String

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization

    /// Initialize with dependencies.
    public init(
        persistenceController: PersistenceController,
        provenanceService: ProvenanceService,
        artifactService: ArtifactService,
        userId: String
    ) {
        self.persistenceController = persistenceController
        self.provenanceService = provenanceService
        self.artifactService = artifactService
        self.repository = ResearchConversationRepository(persistenceController: persistenceController)
        self.userId = userId
    }

    // MARK: - Conversation Management

    /// Create a new research conversation.
    public func createConversation(
        title: String,
        counselModel: String = "opus4.5"
    ) async {
        isLoading = true
        errorMessage = nil

        let newConversation = ResearchConversation(
            title: title,
            participants: [userId, "counsel-\(counselModel)@impart.local"]
        )

        // Record creation in provenance
        await provenanceService.recordConversationCreated(
            conversationId: newConversation.id.uuidString,
            title: title,
            participants: newConversation.participants,
            actorId: userId
        )

        // Persist the new conversation
        do {
            try await repository.save(newConversation)
            viewModelLogger.info("Persisted new conversation: \(newConversation.id)")
        } catch {
            viewModelLogger.error("Failed to persist conversation: \(error.localizedDescription)")
        }

        // Create counsel session
        counselSession = CounselSession(
            conversationId: newConversation.id,
            configuration: counselModel == "opus4.5" ? .research : CounselConfiguration(model: counselModel),
            persistenceController: persistenceController,
            provenanceService: provenanceService,
            artifactService: artifactService,
            userId: userId
        )

        conversation = newConversation
        messages = []
        timelineItems = []
        attachedArtifacts = []
        isLoading = false

        viewModelLogger.info("Created new research conversation: \(title)")
    }

    /// Load an existing conversation from persistence.
    public func loadConversation(id: UUID) async {
        isLoading = true
        errorMessage = nil

        do {
            // Fetch conversation from repository
            guard let loadedConversation = try await repository.fetchConversation(id: id) else {
                errorMessage = "Conversation not found"
                isLoading = false
                return
            }

            // Fetch messages
            let loadedMessages = try await repository.fetchMessages(for: id)

            // Set up counsel session
            let counselModel = extractCounselModel(from: loadedConversation.participants)
            counselSession = CounselSession(
                conversationId: id,
                configuration: counselModel == "opus4.5" ? .research : CounselConfiguration(model: counselModel),
                persistenceController: persistenceController,
                provenanceService: provenanceService,
                artifactService: artifactService,
                userId: userId
            )

            // Restore history to counsel session
            for message in loadedMessages {
                await counselSession?.restoreHistoryMessage(message)
            }

            // Update state on main actor
            conversation = loadedConversation
            messages = loadedMessages
            timelineItems = loadedMessages.map { .message($0) }

            // Load attached artifacts for this conversation
            let artifacts = try await artifactService.getArtifacts(forConversation: id)
            attachedArtifacts = artifacts
            await counselSession?.attach(artifacts: artifacts)

            updateStats()
            viewModelLogger.info("Loaded conversation \(id) with \(loadedMessages.count) messages")

        } catch {
            errorMessage = "Failed to load conversation: \(error.localizedDescription)"
            viewModelLogger.error("Failed to load conversation: \(error.localizedDescription)")
        }

        isLoading = false
    }

    /// Extract counsel model from participants list.
    private func extractCounselModel(from participants: [String]) -> String {
        for participant in participants {
            if participant.hasPrefix("counsel-") && participant.hasSuffix("@impart.local") {
                let model = participant
                    .replacingOccurrences(of: "counsel-", with: "")
                    .replacingOccurrences(of: "@impart.local", with: "")
                return model
            }
        }
        return "opus4.5" // Default
    }

    // MARK: - Messaging

    /// Send a message to the counsel with streaming response.
    public func sendMessage() async {
        guard !messageInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        guard let session = counselSession else {
            errorMessage = "No active counsel session"
            return
        }

        guard let conversationId = conversation?.id else {
            errorMessage = "No active conversation"
            return
        }

        let message = messageInput
        messageInput = ""
        isSending = true
        isStreaming = true
        streamingContent = ""
        errorMessage = nil

        // Add user message to timeline
        let userMessage = ResearchMessage(
            conversationId: conversationId,
            sequence: messages.count + 1,
            senderRole: .human,
            senderId: userId,
            contentMarkdown: message
        )
        messages.append(userMessage)
        timelineItems.append(.message(userMessage))

        // Persist user message
        do {
            try await repository.saveMessage(userMessage, to: conversationId)
            viewModelLogger.debug("Persisted user message: \(userMessage.id)")
        } catch {
            viewModelLogger.error("Failed to persist user message: \(error.localizedDescription)")
        }

        do {
            // Send to counsel with streaming
            let response = try await session.sendStreaming(
                message: message,
                artifacts: attachedArtifacts
            ) { [weak self] partialText in
                // Update streaming content on main actor
                Task { @MainActor in
                    self?.streamingContent = partialText
                }
            }

            // Streaming complete - add final counsel response to timeline
            let counselMessage = ResearchMessage(
                conversationId: conversationId,
                sequence: messages.count + 1,
                senderRole: .counsel,
                senderId: "counsel-\(response.modelUsed)@impart.local",
                modelUsed: response.modelUsed,
                contentMarkdown: response.content,
                tokenCount: response.tokenCount,
                processingDurationMs: response.processingDurationMs,
                mentionedArtifactURIs: response.mentionedArtifacts
            )
            messages.append(counselMessage)
            timelineItems.append(.message(counselMessage))

            // Persist counsel message
            do {
                try await repository.saveMessage(counselMessage, to: conversationId)
                viewModelLogger.debug("Persisted counsel message: \(counselMessage.id)")
            } catch {
                viewModelLogger.error("Failed to persist counsel message: \(error.localizedDescription)")
            }

            // Update conversation stats
            updateStats()

            viewModelLogger.info("Received counsel response (\(response.tokenCount) tokens)")

        } catch {
            errorMessage = "Failed to send message: \(error.localizedDescription)"
            viewModelLogger.error("Failed to send message: \(error.localizedDescription)")
        }

        isStreaming = false
        streamingContent = ""
        isSending = false
    }

    /// Send a message without streaming (for compatibility).
    public func sendMessageNonStreaming() async {
        guard !messageInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        guard let session = counselSession else {
            errorMessage = "No active counsel session"
            return
        }

        guard let conversationId = conversation?.id else {
            errorMessage = "No active conversation"
            return
        }

        let message = messageInput
        messageInput = ""
        isSending = true
        errorMessage = nil

        // Add user message to timeline
        let userMessage = ResearchMessage(
            conversationId: conversationId,
            sequence: messages.count + 1,
            senderRole: .human,
            senderId: userId,
            contentMarkdown: message
        )
        messages.append(userMessage)
        timelineItems.append(.message(userMessage))

        // Persist user message
        do {
            try await repository.saveMessage(userMessage, to: conversationId)
            viewModelLogger.debug("Persisted user message: \(userMessage.id)")
        } catch {
            viewModelLogger.error("Failed to persist user message: \(error.localizedDescription)")
        }

        do {
            // Send to counsel and get response (non-streaming)
            let response = try await session.send(
                message: message,
                artifacts: attachedArtifacts
            )

            // Add counsel response to timeline
            let counselMessage = ResearchMessage(
                conversationId: conversationId,
                sequence: messages.count + 1,
                senderRole: .counsel,
                senderId: "counsel-\(response.modelUsed)@impart.local",
                modelUsed: response.modelUsed,
                contentMarkdown: response.content,
                tokenCount: response.tokenCount,
                processingDurationMs: response.processingDurationMs,
                mentionedArtifactURIs: response.mentionedArtifacts
            )
            messages.append(counselMessage)
            timelineItems.append(.message(counselMessage))

            // Persist counsel message
            do {
                try await repository.saveMessage(counselMessage, to: conversationId)
                viewModelLogger.debug("Persisted counsel message: \(counselMessage.id)")
            } catch {
                viewModelLogger.error("Failed to persist counsel message: \(error.localizedDescription)")
            }

            // Update conversation stats
            updateStats()

            viewModelLogger.info("Received counsel response (\(response.tokenCount) tokens)")

        } catch {
            errorMessage = "Failed to send message: \(error.localizedDescription)"
            viewModelLogger.error("Failed to send message: \(error.localizedDescription)")
        }

        isSending = false
    }

    // MARK: - Artifact Management

    /// Attach a paper artifact.
    public func attachPaper(citeKey: String) async {
        do {
            let artifact = try await artifactService.getOrCreatePaper(
                citeKey: citeKey,
                introducedBy: userId,
                sourceConversationId: conversation?.id
            )

            if !attachedArtifacts.contains(where: { $0.uriString == artifact.uriString }) {
                attachedArtifacts.append(artifact)
                await counselSession?.attach(artifacts: [artifact])
                viewModelLogger.info("Attached paper: \(citeKey)")
            }
        } catch {
            errorMessage = "Failed to attach paper: \(error.localizedDescription)"
        }
    }

    /// Attach a repository artifact.
    public func attachRepository(
        host: String,
        owner: String,
        repo: String,
        commit: String
    ) async {
        do {
            let artifact = try await artifactService.getOrCreateRepository(
                host: host,
                owner: owner,
                repo: repo,
                commit: commit,
                introducedBy: userId,
                sourceConversationId: conversation?.id
            )

            if !attachedArtifacts.contains(where: { $0.uriString == artifact.uriString }) {
                attachedArtifacts.append(artifact)
                await counselSession?.attach(artifacts: [artifact])
                viewModelLogger.info("Attached repository: \(owner)/\(repo)")
            }
        } catch {
            errorMessage = "Failed to attach repository: \(error.localizedDescription)"
        }
    }

    /// Detach an artifact.
    public func detachArtifact(uri: String) async {
        attachedArtifacts.removeAll { $0.uriString == uri }
        await counselSession?.detach(artifactURI: uri)
    }

    // MARK: - Branching

    /// Branch the conversation from a specific message.
    public func branchConversation(
        fromMessage messageId: UUID,
        title: String
    ) async {
        guard let parentConversation = conversation else {
            errorMessage = "No active conversation to branch from"
            return
        }

        // Record the branch in provenance
        await provenanceService.record(ProvenanceEvent(
            conversationId: parentConversation.id.uuidString,
            payload: .conversationBranched(
                fromMessageId: messageId.uuidString,
                reason: "User initiated branch",
                branchTitle: title
            ),
            actorId: userId
        ))

        // Create the new branch conversation
        let branchConversation = ResearchConversationBuilder(title: title)
            .with(participants: parentConversation.participants)
            .asBranch(of: parentConversation.id)
            .build()

        // TODO: Save to persistence and switch to branch

        viewModelLogger.info("Created branch conversation: \(title)")
    }

    // MARK: - Private Helpers

    private func updateStats() {
        guard let conv = conversation else { return }

        let humanCount = messages.filter { $0.isFromHuman }.count
        let counselCount = messages.filter { $0.isFromCounsel }.count
        let totalTokens = messages.compactMap(\.tokenCount).reduce(0, +)

        let duration: TimeInterval
        if let first = messages.first, let last = messages.last {
            duration = last.sentAt.timeIntervalSince(first.sentAt)
        } else {
            duration = 0
        }

        stats = ResearchConversationSummary(
            messageCount: messages.count,
            humanMessageCount: humanCount,
            counselMessageCount: counselCount,
            artifactCount: attachedArtifacts.count,
            paperCount: attachedArtifacts.filter { $0.type == .paper }.count,
            repositoryCount: attachedArtifacts.filter { $0.type == .repository }.count,
            totalTokens: totalTokens,
            duration: duration,
            branchCount: 0 // Would be fetched from persistence
        )
    }
}

// MARK: - Preview Support

#if DEBUG
public extension ResearchConversationViewModel {
    /// Create a preview instance with mock data.
    static var preview: ResearchConversationViewModel {
        let vm = ResearchConversationViewModel(
            persistenceController: PersistenceController.preview,
            provenanceService: ProvenanceService(),
            artifactService: ArtifactService(persistenceController: PersistenceController.preview),
            userId: "preview@example.com"
        )

        vm.conversation = ResearchConversation(
            title: "Surface Code Discussion",
            participants: ["preview@example.com", "counsel-opus4.5@impart.local"]
        )

        vm.messages = [
            ResearchMessage(
                conversationId: vm.conversation!.id,
                sequence: 1,
                senderRole: .human,
                senderId: "preview@example.com",
                contentMarkdown: "Let's discuss the Fowler 2012 surface code paper."
            ),
            ResearchMessage(
                conversationId: vm.conversation!.id,
                sequence: 2,
                senderRole: .counsel,
                senderId: "counsel-opus4.5@impart.local",
                modelUsed: "opus4.5",
                contentMarkdown: "The Fowler et al. 2012 paper on surface codes is foundational...",
                tokenCount: 150,
                processingDurationMs: 1200
            )
        ]

        vm.timelineItems = vm.messages.map { .message($0) }

        return vm
    }
}
#endif
