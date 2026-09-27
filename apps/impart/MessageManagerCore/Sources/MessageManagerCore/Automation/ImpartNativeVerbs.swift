import Foundation
import ImpartVerbsFFI
import ImpressAutomation
import ImpressLogging

public extension Notification.Name {
    static let impartResearchConversationsDidChange = Notification.Name("impartResearchConversationsDidChange")
}

/// The app-owned implementation of `impart-service`. All research mutations
/// complete before the callback answers; no operation is queued as a success.
final class NativeImpartHost: ImpartNativeCallbacks, @unchecked Sendable {
    private let repository: ResearchConversationRepository
    private let provenance: ProvenanceService

    init(repository: ResearchConversationRepository, provenance: ProvenanceService) {
        self.repository = repository
        self.provenance = provenance
    }

    func invoke(method: String, argsJson: String) async -> NativeCallResult {
        guard let data = argsJson.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return failure(400, "invalid-argument", "Invalid native arguments")
        }

        do {
            switch method {
            case "status":
                return success(["running": true, "detail": "impart native backend is running"])

            case "get_logs":
                let requested = args["limit"] as? Int ?? 50
                let limit = max(1, min(requested == 0 ? 50 : requested, 1_000))
                let levels = (args["level"] as? String)?.split(separator: ",").map { String($0) }
                let logs: [[String: Any]] = await MainActor.run {
                    LogStore.shared.entries
                        .filter { levels == nil || levels?.contains($0.level.rawValue) == true }
                        .suffix(limit)
                        .map {
                            ["timestamp": ISO8601DateFormatter().string(from: $0.timestamp),
                             "level": $0.level.rawValue, "category": $0.category,
                             "message": $0.message]
                        }
                }
                return success(logs)

            case "list_conversations":
                let requested = args["limit"] as? Int ?? 20
                let limit = max(1, min(requested == 0 ? 20 : requested, 1_000))
                let includeArchived = args["include_archived"] as? Bool ?? false
                let records = try await repository.fetchConversations(includeArchived: includeArchived)
                    .prefix(limit).map(conversationRecord)
                return success(records)

            case "get_conversation":
                let id = try requiredUUID(args, "conversation_id")
                if let conversation = try await repository.fetchConversation(id: id) {
                    return success(conversationRecord(conversation))
                }
                return success(NSNull())

            case "create_conversation":
                let title = try requiredString(args, "title")
                logInfo("Creating native research conversation", category: "research-native")
                let conversation = ResearchConversation(
                    title: title, participants: [], summaryText: args["summary"] as? String)
                try await repository.save(conversation)
                logInfo("Saved native research conversation \(conversation.id)", category: "research-native")
                await changed()
                return success(conversationRecord(conversation))

            case "update_conversation":
                let id = try requiredUUID(args, "conversation_id")
                guard var conversation = try await repository.fetchConversation(id: id) else {
                    return failure(404, "not-found", "Research conversation was not found")
                }
                let title = args["title"] as? String
                let summary = args["summary"] as? String
                guard title != nil || summary != nil else {
                    return failure(400, "invalid-argument", "No conversation fields were provided")
                }
                if let title { conversation.title = title }
                if let summary { conversation.summaryText = summary }
                conversation.lastActivityAt = Date()
                logInfo("Updating native research conversation \(id)", category: "research-native")
                try await repository.save(conversation)
                logInfo("Saved native research conversation update \(id)", category: "research-native")
                await changed()
                return success(true)

            case "add_message":
                let id = try requiredUUID(args, "conversation_id")
                let content = try requiredString(args, "content")
                let rawRole = (args["role"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let role: ResearchSenderRole
                let sender: String
                switch rawRole {
                case nil, "user", "human": role = .human; sender = "user"
                case "system": role = .system; sender = "system"
                default: role = .counsel; sender = rawRole ?? "assistant"
                }
                logInfo("Appending native research message to \(id)", category: "research-native")
                let message: ResearchMessage
                do {
                    message = try await repository.appendMessage(
                        to: id, content: content, senderRole: role, senderId: sender)
                } catch RepositoryError.conversationNotFound {
                    return failure(404, "not-found", "Research conversation was not found")
                }
                logInfo("Saved native research message \(message.id) to \(id)", category: "research-native")
                await changed()
                return success(messageRecord(message))

            case "record_decision":
                let id = try requiredUUID(args, "conversation_id")
                let decision = try requiredString(args, "decision")
                guard try await repository.fetchConversation(id: id) != nil else {
                    return failure(404, "not-found", "Research conversation was not found")
                }
                // Existing provenance is process-local. Do not masquerade as
                // a durable Core Data decision or invent a message.
                logInfo("Recording process-local decision for \(id)", category: "research-native")
                let event = await provenance.recordDecision(
                    conversationId: id.uuidString, decisionId: UUID().uuidString,
                    description: decision, rationale: args["rationale"] as? String ?? "",
                    alternativesConsidered: [], actorId: "automation")
                let stored = await provenance.eventsForConversation(id.uuidString)
                    .contains { $0.id == event.id }
                if stored { logInfo("Recorded decision provenance for \(id)", category: "research-native") }
                return success(stored)

            case "record_artifact":
                let id = try requiredUUID(args, "conversation_id")
                let title = try requiredString(args, "title")
                let reference = try requiredString(args, "reference")
                guard let uri = ArtifactURI(uri: reference) else {
                    return failure(400, "invalid-argument", "Reference must be an impress:// artifact URI")
                }
                if let kind = args["kind"] as? String, kind != uri.type.rawValue {
                    return failure(400, "invalid-argument", "Artifact kind does not match its URI")
                }
                logInfo("Recording native artifact for \(id)", category: "research-native")
                try await repository.recordArtifact(uri: uri, title: title, in: id)
                logInfo("Saved native artifact relationship for \(id)", category: "research-native")
                _ = await provenance.recordArtifactIntroduced(
                    conversationId: id.uuidString, artifactUri: reference,
                    artifactType: uri.type.rawValue, version: uri.version,
                    displayName: title, actorId: "automation")
                await changed()
                return success(true)

            case "branch_conversation":
                let id = try requiredUUID(args, "conversation_id")
                let title = try requiredString(args, "title")
                guard let parent = try await repository.fetchConversation(id: id) else {
                    return failure(404, "not-found", "Research conversation was not found")
                }
                // The verb has no fromMessageId. Link a new child to the
                // source and copy participants; do not invent a branch point.
                let branch = ResearchConversation(
                    title: title, participants: parent.participants, parentConversationId: id)
                logInfo("Branching native research conversation \(id)", category: "research-native")
                try await repository.save(branch)
                logInfo("Saved native research branch \(branch.id) from \(id)", category: "research-native")
                await changed()
                return success(conversationRecord(branch))

            default:
                return failure(404, "not-found", "Unknown impart native method")
            }
        } catch let error as NativeArgumentError {
            return failure(400, "invalid-argument", error.localizedDescription)
        } catch {
            return failure(500, "internal", error.localizedDescription)
        }
    }

    private func changed() async {
        await MainActor.run {
            NotificationCenter.default.post(name: .impartResearchConversationsDidChange, object: nil)
        }
    }
}

private enum NativeArgumentError: LocalizedError {
    case missing(String)
    var errorDescription: String? {
        switch self { case .missing(let name): return "Missing or invalid \(name)" }
    }
}

private func requiredString(_ args: [String: Any], _ key: String) throws -> String {
    guard let value = args[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw NativeArgumentError.missing(key)
    }
    return value
}

private func requiredUUID(_ args: [String: Any], _ key: String) throws -> UUID {
    guard let value = args[key] as? String, let id = UUID(uuidString: value) else {
        throw NativeArgumentError.missing(key)
    }
    return id
}

private func conversationRecord(_ conversation: ResearchConversation) -> [String: Any] {
    let formatter = ISO8601DateFormatter()
    return ["id": conversation.id.uuidString, "title": conversation.title,
            "summary": conversation.summaryText ?? NSNull(),
            "message_count": conversation.messageCount,
            "created_at": formatter.string(from: conversation.createdAt),
            "updated_at": formatter.string(from: conversation.lastActivityAt),
            "archived": conversation.isArchived]
}

private func messageRecord(_ message: ResearchMessage) -> [String: Any] {
    let role = message.senderRole == .counsel ? message.senderId :
        (message.senderRole == .human ? "user" : "system")
    return ["id": message.id.uuidString, "role": role,
     "content": message.contentMarkdown,
     "created_at": ISO8601DateFormatter().string(from: message.sentAt)]
}

private func success(_ value: Any) -> NativeCallResult {
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
          let json = String(data: data, encoding: .utf8) else {
        return failure(500, "internal", "Could not encode native response")
    }
    return NativeCallResult(status: 200, bodyJson: json)
}

private func failure(_ status: UInt16, _ code: String, _ message: String) -> NativeCallResult {
    let body = ["code": code, "message": message]
    let data = try? JSONSerialization.data(withJSONObject: body)
    return NativeCallResult(status: status, bodyJson: data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}")
}

public enum ImpartNativeVerbs {
    @MainActor static private(set) var activeRepository: ResearchConversationRepository?
    @MainActor static private(set) var activePersistence: PersistenceController?

    /// Register the native backend before starting the HTTP automation route.
    @MainActor public static func install(persistence: PersistenceController = .shared) {
        let repository = ResearchConversationRepository(persistenceController: persistence)
        registerNativeBackend(callback: NativeImpartHost(repository: repository, provenance: .shared))
        activeRepository = repository
        activePersistence = persistence
        VerbAutomationRoutes.registerDomainDispatcher(services: ["impart-service"]) {
            name, argsJSON, callerJSON in
            let result = await dispatchVerb(name: name, argsJson: argsJSON, callerJson: callerJSON)
            return VerbDispatchResponse(status: Int(result.status), bodyJSON: result.bodyJson)
        }
    }
}
