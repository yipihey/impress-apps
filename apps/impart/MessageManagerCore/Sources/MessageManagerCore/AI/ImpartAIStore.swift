//
//  ImpartAIStore.swift
//  MessageManagerCore
//
//  Native-UI gateway to the shared Rust AI graph. This owns no model process
//  and no second database: iOS can create/read synced messages through the
//  same API even when the oMLX host is unreachable.
//

import Foundation
import ImpressAI
import ImpressKit
import ImpressLogging
@preconcurrency import ImpressRustCore
import OSLog
import UniformTypeIdentifiers

private let aiStoreLog = Logger(subsystem: "com.impart.app", category: "ai-store")

// UniFFI currently emits value-only records without `Sendable`. Every stored
// field in these projections is an immutable-copy-safe Swift value; declaring
// the boundary explicitly keeps actor crossings honest until the generator
// grows native Sendable emission.
extension AiAttachmentRow: @retroactive @unchecked Sendable {}
extension AiConversationRow: @retroactive @unchecked Sendable {}
extension AiConversationView: @retroactive @unchecked Sendable {}
extension AiMessageRow: @retroactive @unchecked Sendable {}
extension AiModelHostStatus: @retroactive @unchecked Sendable {}
extension AiModelRow: @retroactive @unchecked Sendable {}
extension AiWorkerStatus: @retroactive @unchecked Sendable {}
extension AiTaskRow: @retroactive @unchecked Sendable {}
extension AiToolOption: @retroactive @unchecked Sendable {}

public struct ImpartQueuedAITurn: Sendable, Equatable {
    public let conversationID: UUID
    public let messageID: UUID
    public let taskID: UUID
}

public struct ImpartAIAttachment: Sendable, Equatable {
    public let itemID: UUID
    public let mimeType: String
    public let sha256: String
    public let fileName: String?
    public let byteLength: Int
}

/// Async-only boundary used by future macOS and iOS conversation views.
public actor ImpartAIStore {
    public static let shared = ImpartAIStore()

    private var rustStore: SharedAiStore?
    private let storage: Storage
    private let credentialManager: AICredentialManager

    public init() {
        storage = .shared
        credentialManager = .shared
    }

    /// Explicit storage is primarily useful to previews and tests. Production
    /// surfaces use ``shared`` so every Impress app opens the same graph/CAS.
    public init(
        databaseURL: URL,
        blobDirectory: URL,
        actor: String = "user:impart",
        credentialManager: AICredentialManager = .shared
    ) {
        storage = .explicit(
            databasePath: databaseURL.path,
            blobRoot: blobDirectory.path,
            actor: actor)
        self.credentialManager = credentialManager
    }

    private func handle() throws -> SharedAiStore {
        if let rustStore { return rustStore }
        let opened: SharedAiStore
        switch storage {
        case .shared:
            try SharedWorkspace.ensureDirectoryExists()
            opened = try SharedAiStore.open(
                databasePath: SharedWorkspace.databasePath,
                blobRoot: SharedWorkspace.aiBlobDirectory.path,
                actor: "user:impart")
        case .explicit(let databasePath, let blobRoot, let actor):
            try FileManager.default.createDirectory(
                atPath: blobRoot, withIntermediateDirectories: true)
            opened = try SharedAiStore.open(
                databasePath: databasePath,
                blobRoot: blobRoot,
                actor: actor)
        }
        rustStore = opened
        aiStoreLog.infoCapture("Opened AI graph and CAS", category: "ai-store")
        return opened
    }

    public func createConversation(
        title: String,
        model: String,
        provider: String = "omlx",
        systemPrompt: String? = nil,
        temperature: Double = 0.2,
        maxTokens: UInt32 = 2048,
        thinking: Bool = false,
        webAccess: Bool = false,
        enabledTools: [String] = []
    ) throws -> UUID {
        aiStoreLog.infoCapture(
            "Mutation: creating AI conversation with provider \(provider) and model \(model)",
            category: "ai-store")
        let id = try handle().createConversation(draft: AiConversationDraft(
            title: title,
            summary: nil,
            systemPrompt: systemPrompt,
            provider: provider,
            model: model,
            temperature: temperature,
            maxTokens: maxTokens,
            thinking: thinking,
            webAccess: webAccess,
            enabledTools: enabledTools))
        guard let uuid = UUID(uuidString: id) else {
            throw ImpartAIStoreError.invalidIdentifier(id)
        }
        aiStoreLog.infoCapture(
            "Save: created AI conversation \(id)", category: "ai-store")
        return uuid
    }

    /// Display-ready rows shaped by Rust. Native views render these directly;
    /// they never decode canonical item payloads or reconstruct counts.
    public func conversations(includeArchived: Bool = false) throws -> [AiConversationRow] {
        let rows = try handle().conversationRows(includeArchived: includeArchived)
        aiStoreLog.debugCapture(
            "Display: loaded \(rows.count) AI conversation rows", category: "ai-store")
        return rows
    }

    /// Complete declarative screen projection: conversation, messages, task
    /// state, attachments, and tool choices all come from the Rust core.
    public func conversation(id: UUID) throws -> AiConversationView {
        let view = try handle().conversationView(
            conversationId: id.uuidString.lowercased())
        aiStoreLog.debugCapture(
            "Display: loaded AI conversation \(id.uuidString) with \(view.messages.count) messages",
            category: "ai-store")
        return view
    }

    public func toolOptions(enabledTools: [String] = []) throws -> [AiToolOption] {
        try handle().toolOptions(enabledTools: enabledTools)
    }

    /// Device-local model-host state shaped by Rust. Endpoint/token remain in
    /// the suite keychain and are never written to the synced item graph.
    public func configuredModelHostStatus() async throws -> AiModelHostStatus {
        let providerID = OpenAICompatibleProvider.providerId
        let endpoint = await credentialManager.retrieve(for: providerID, field: "endpoint")
            ?? OpenAICompatibleProvider.defaultEndpoint.absoluteString
        let apiKey = await credentialManager.retrieve(for: providerID, field: "apiKey")
        aiStoreLog.infoCapture(
            "Discovery: inspecting configured oMLX host (endpoint)", category: "ai-host")
        let status = try handle().inspectOmlxHost(endpoint: endpoint, apiKey: apiKey)
        aiStoreLog.infoCapture(
            "Display: oMLX host is (status.state) with (status.models.count) models",
            category: "ai-host")
        return status
    }

    /// Device-local worker health shaped by Rust from the exclusive heartbeat
    /// protocol. This never changes or pollutes the synced conversation graph.
    public func modelWorkerStatus() throws -> AiWorkerStatus {
        let status = try handle().modelWorkerStatus()
        aiStoreLog.infoCapture(
            "Display: Impress model worker is \(status.state)", category: "ai-worker")
        return status
    }

    public func queueUserTurn(
        conversationID: UUID,
        body: String,
        attachmentIDs: [UUID] = []
    ) throws -> ImpartQueuedAITurn {
        aiStoreLog.infoCapture(
            "Mutation: queueing AI turn for \(conversationID.uuidString) with \(attachmentIDs.count) attachments",
            category: "ai-store")
        let queued = try handle().queueUserTurn(
            conversationId: conversationID.uuidString.lowercased(),
            body: body,
            attachmentIds: attachmentIDs.map { $0.uuidString.lowercased() })
        guard let conversationID = UUID(uuidString: queued.conversationId),
              let messageID = UUID(uuidString: queued.messageId),
              let taskID = UUID(uuidString: queued.taskId)
        else {
            throw ImpartAIStoreError.invalidIdentifier(queued.taskId)
        }
        aiStoreLog.infoCapture(
            "Save: queued AI turn \(taskID.uuidString) for \(conversationID.uuidString)",
            category: "ai-store")
        return ImpartQueuedAITurn(
            conversationID: conversationID, messageID: messageID, taskID: taskID)
    }

    public func setEnabledTools(_ tools: [String], conversationID: UUID) throws {
        aiStoreLog.infoCapture(
            "Mutation: setting \(tools.count) AI tools for \(conversationID.uuidString)",
            category: "ai-store")
        try handle().setEnabledTools(
            conversationId: conversationID.uuidString.lowercased(), enabledTools: tools)
        aiStoreLog.infoCapture(
            "Save: updated AI tools for \(conversationID.uuidString)", category: "ai-store")
    }

    public func setConversationModel(_ model: String, conversationID: UUID) throws {
        aiStoreLog.infoCapture(
            "Mutation: setting AI model for \(conversationID.uuidString) to \(model)",
            category: "ai-store")
        try handle().setConversationModel(
            conversationId: conversationID.uuidString.lowercased(), model: model)
        aiStoreLog.infoCapture(
            "Save: updated AI model for \(conversationID.uuidString)", category: "ai-store")
    }

    public func setConversationTitle(_ title: String, conversationID: UUID) throws {
        aiStoreLog.infoCapture(
            "Mutation: renaming AI conversation \(conversationID.uuidString)",
            category: "ai-store")
        try handle().setConversationTitle(
            conversationId: conversationID.uuidString.lowercased(), title: title)
        aiStoreLog.infoCapture(
            "Save: renamed AI conversation \(conversationID.uuidString)", category: "ai-store")
    }

    @discardableResult
    public func suggestConversationTitle(conversationID: UUID) throws -> UUID {
        aiStoreLog.infoCapture(
            "Mutation: queueing local-model title suggestion for \(conversationID.uuidString)",
            category: "ai-store")
        let taskID = try handle().queueTitleSuggestion(
            conversationId: conversationID.uuidString.lowercased())
        guard let taskUUID = UUID(uuidString: taskID) else {
            throw ImpartAIStoreError.invalidIdentifier(taskID)
        }
        aiStoreLog.infoCapture(
            "Save: queued title suggestion \(taskID)", category: "ai-store")
        return taskUUID
    }

    public func ingestAttachment(
        data: Data,
        mimeType: String,
        fileName: String? = nil
    ) throws -> ImpartAIAttachment {
        aiStoreLog.infoCapture(
            "Mutation: ingesting AI attachment \(fileName ?? mimeType) (\(data.count) bytes)",
            category: "ai-store")
        let attachment = try handle().ingestBlob(
            bytes: data, mimeType: mimeType, fileName: fileName)
        guard let itemID = UUID(uuidString: attachment.itemId) else {
            throw ImpartAIStoreError.invalidIdentifier(attachment.itemId)
        }
        aiStoreLog.infoCapture(
            "Save: stored AI attachment \(attachment.sha256) (\(data.count) bytes)",
            category: "ai-store")
        return ImpartAIAttachment(
            itemID: itemID,
            mimeType: attachment.mimeType,
            sha256: attachment.sha256,
            fileName: attachment.fileName,
            byteLength: data.count)
    }

    /// Platform file-access adapter. Hashing, CAS placement, and graph metadata
    /// remain inside Rust's `ingest_blob` command.
    public func ingestAttachment(fileURL: URL) throws -> ImpartAIAttachment {
        let accessed = fileURL.startAccessingSecurityScopedResource()
        defer {
            if accessed { fileURL.stopAccessingSecurityScopedResource() }
        }
        let values = try fileURL.resourceValues(forKeys: [.contentTypeKey])
        let mimeType = values.contentType?.preferredMIMEType ?? "application/octet-stream"
        return try ingestAttachment(
            data: Data(contentsOf: fileURL, options: .mappedIfSafe),
            mimeType: mimeType,
            fileName: fileURL.lastPathComponent)
    }

    public func taskProgressJSON(taskID: UUID) throws -> String {
        try handle().taskProgressJson(taskId: taskID.uuidString.lowercased())
    }

    public func taskState(taskID: UUID) throws -> String {
        try handle().taskState(taskId: taskID.uuidString.lowercased())
    }

    public func runProvenanceJSON(runID: UUID) throws -> String {
        try handle().runProvenanceJson(runId: runID.uuidString.lowercased())
    }

    /// Explicit migration entry point; never runs during launch. The caller
    /// first presents the dry-run report, then invokes again with `dryRun=false`.
    public func migrateLocalModels(databaseURL: URL, dryRun: Bool = true) throws -> String {
        try handle().migrateLocalmodelsJson(
            sourceDatabasePath: databaseURL.path, dryRun: dryRun)
    }
}

private extension ImpartAIStore {
    enum Storage: Sendable {
        case shared
        case explicit(databasePath: String, blobRoot: String, actor: String)
    }
}

public enum ImpartAIStoreError: Error, LocalizedError {
    case invalidIdentifier(String)

    public var errorDescription: String? {
        switch self {
        case .invalidIdentifier(let value):
            return "The Rust AI store returned an invalid identifier: \(value)"
        }
    }
}
