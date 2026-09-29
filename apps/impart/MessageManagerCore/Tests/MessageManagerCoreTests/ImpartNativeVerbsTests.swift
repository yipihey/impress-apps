import Foundation
import ImpartVerbsFFI
import ImpressAutomation
import Testing
@testable import MessageManagerCore

@Suite("Impart native verb backend", .serialized)
struct ImpartNativeVerbsTests {
    @MainActor @Test("Concurrent native appends persist distinct ordered sequences")
    func concurrentMessageAppends() async throws {
        let persistence = PersistenceController(inMemory: true)
        let repository = ResearchConversationRepository(persistenceController: persistence)
        let conversation = ResearchConversation(title: "Concurrent append", participants: [])
        try await repository.save(conversation)
        let host = NativeImpartHost(repository: repository, provenance: ProvenanceService())
        let count = 24
        let payloads = try (0..<count).map { index in
            let data = try JSONSerialization.data(withJSONObject: [
                "conversation_id": conversation.id.uuidString,
                "content": "Message \(index)", "role": "user"
            ])
            return String(decoding: data, as: UTF8.self)
        }

        let replies = await withTaskGroup(of: (UInt16, String).self) { group in
            for payload in payloads {
                group.addTask {
                    let reply = await host.invoke(method: "add_message", argsJson: payload)
                    return (reply.status, reply.bodyJson)
                }
            }
            var replies: [(UInt16, String)] = []
            for await reply in group { replies.append(reply) }
            return replies
        }
        #expect(replies.count == count)
        #expect(replies.allSatisfy { $0.0 == 200 })
        let returnedIDs = try replies.map { _, body in
            let value = try #require(JSONSerialization.jsonObject(
                with: Data(body.utf8)) as? [String: Any])
            return try #require(value["id"] as? String)
        }
        #expect(Set(returnedIDs).count == count)

        // Read from a new Core Data context, independent of the writer and
        // of the repository's own message fetch, to verify saved order.
        let persisted = try await persistence.performBackgroundTask { context in
            let request = CDResearchMessage.fetchRequest()
            request.predicate = NSPredicate(
                format: "conversation.id == %@", conversation.id as CVarArg)
            request.sortDescriptors = [
                NSSortDescriptor(key: "conversationSequence", ascending: true)
            ]
            return try context.fetch(request).map {
                (id: $0.id.uuidString, sequence: Int($0.conversationSequence), content: $0.contentMarkdown)
            }
        }
        #expect(persisted.count == count)
        #expect(persisted.map(\.sequence) == Array(1...count))
        #expect(Set(persisted.map(\.id)) == Set(returnedIDs))
        #expect(Set(persisted.map(\.content)) == Set((0..<count).map { "Message \($0)" }))
    }

    @MainActor @Test("Research writes persist and return real IDs; invalid input refuses")
    func researchOperations() async throws {
        let persistence = PersistenceController(inMemory: true)
        let repository = ResearchConversationRepository(persistenceController: persistence)
        let provenance = ProvenanceService()
        let host = NativeImpartHost(repository: repository, provenance: provenance)

        func call(_ method: String, _ args: [String: Any]) async throws -> (Int, Any) {
            let data = try JSONSerialization.data(withJSONObject: args)
            let reply = await host.invoke(method: method, argsJson: String(decoding: data, as: UTF8.self))
            let body = try JSONSerialization.jsonObject(
                with: Data(reply.bodyJson.utf8), options: [.fragmentsAllowed])
            return (Int(reply.status), body)
        }

        let (createStatus, created) = try await call("create_conversation", ["title": "Research plan"])
        #expect(createStatus == 200)
        let createdRecord = try #require(created as? [String: Any])
        let id = try #require(createdRecord["id"] as? String)
        let uuid = try #require(UUID(uuidString: id))
        #expect(try await repository.fetchConversation(id: uuid)?.title == "Research plan")

        let (listStatus, listed) = try await call("list_conversations", ["limit": 10, "include_archived": false])
        #expect(listStatus == 200)
        let listEnvelope = try #require(listed as? [String: Any])
        let listRows = try #require(listEnvelope["conversations"] as? [[String: Any]])
        #expect(listEnvelope["total"] as? Int == 1)
        #expect(listRows.contains { $0["id"] as? String == id })
        let (readStatus, read) = try await call("get_conversation", ["conversation_id": id])
        #expect(readStatus == 200)
        #expect((read as? [String: Any])?["id"] as? String == id)

        let (messageStatus, added) = try await call("add_message", [
            "conversation_id": id, "content": "Check the methods", "role": "assistant"
        ])
        #expect(messageStatus == 200)
        let message = try #require(added as? [String: Any])
        #expect(UUID(uuidString: try #require(message["id"] as? String)) != nil)
        #expect(message["role"] as? String == "assistant")
        #expect(try await repository.fetchMessages(for: uuid).count == 1)
        // The existing Core Data model stores sideConversationId as a UUID
        // attribute. Non-nil readback guards against an undeclared relationship.
        let sideConversationID = UUID()
        try await repository.saveMessage(
            ResearchMessage(
                conversationId: uuid, sequence: 2, senderRole: .system,
                senderId: "system", contentMarkdown: "Branch summary",
                sideConversationId: sideConversationID),
            to: uuid)
        let persistedMessages = try await repository.fetchMessages(for: uuid)
        #expect(persistedMessages.last?.sideConversationId == sideConversationID)

        let (updateStatus, updated) = try await call("update_conversation", [
            "conversation_id": id, "summary": "New summary"
        ])
        #expect(updateStatus == 200)
        #expect(updated as? Bool == true)
        #expect(try await repository.fetchConversation(id: uuid)?.summaryText == "New summary")

        let (artifactStatus, artifactResult) = try await call("record_artifact", [
            "conversation_id": id, "title": "Reference paper", "kind": "paper",
            "reference": "impress://imbib/papers/example"
        ])
        #expect(artifactStatus == 200)
        #expect(artifactResult as? Bool == true)
        #expect(try await repository.getStatistics(for: uuid)?.artifactCount == 1)
        let backedArtifact = try await persistence.performBackgroundTask { context in
            let request = CDArtifactReference.fetchRequest()
            request.predicate = NSPredicate(format: "sourceConversation.id == %@", uuid as CVarArg)
            let value = try context.fetch(request).first
            return (value?.uriString, value?.typeRaw, value?.sourceConversation?.id)
        }
        #expect(backedArtifact.0 == "impress://imbib/papers/example")
        #expect(backedArtifact.1 == "paper")
        #expect(backedArtifact.2 == uuid)
        let displayedArtifacts = try await ArtifactService(persistenceController: persistence)
            .getArtifacts(forConversation: uuid)
        #expect(displayedArtifacts.first?.sourceConversationId == uuid)

        let (branchStatus, branched) = try await call("branch_conversation", [
            "conversation_id": id, "title": "Alternative"
        ])
        #expect(branchStatus == 200)
        let branchID = try #require((branched as? [String: Any])?["id"] as? String)
        let branch = try await repository.fetchConversation(id: try #require(UUID(uuidString: branchID)))
        #expect(branch?.parentConversationId == uuid)

        let (decisionStatus, decisionResult) = try await call("record_decision", [
            "conversation_id": id, "decision": "Use this method", "rationale": "Better fit"
        ])
        #expect(decisionStatus == 200)
        #expect(decisionResult as? Bool == true)
        #expect(await provenance.eventsForConversation(id).count >= 1)

        let (failureStatus, _) = try await call("record_artifact", [
            "conversation_id": id, "title": "No URI"
        ])
        #expect(failureStatus == 400)
    }

    @MainActor @Test("Retired conversation reads leave generated list and detail verbs available")
    func conversationReadParity() async throws {
        let persistence = PersistenceController(inMemory: true)
        let repository = ResearchConversationRepository(persistenceController: persistence)
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let parent = ResearchConversation(
            title: "Control thread", participants: ["researcher@example.org"],
            createdAt: baseDate, lastActivityAt: baseDate,
            summaryText: "Controls", tags: ["methods"])
        let child = ResearchConversation(
            title: "Branch read fixture", participants: ["researcher@example.org", "counsel-opus@impart.local"],
            createdAt: baseDate.addingTimeInterval(10),
            lastActivityAt: baseDate.addingTimeInterval(70),
            summaryText: "A distinctive detail", tags: ["analysis", "draft"],
            parentConversationId: parent.id)
        let archived = ResearchConversation(
            title: "Archived fixture", participants: [],
            createdAt: baseDate.addingTimeInterval(20),
            lastActivityAt: baseDate.addingTimeInterval(90), isArchived: true)
        try await repository.save(parent)
        try await repository.save(child)
        try await repository.save(archived)
        try await repository.saveMessage(
            ResearchMessage(
                conversationId: child.id, sequence: 1, senderRole: .human,
                senderId: "researcher@example.org", contentMarkdown: "Question",
                sentAt: baseDate.addingTimeInterval(20)),
            to: child.id)
        try await repository.saveMessage(
            ResearchMessage(
                conversationId: child.id, sequence: 2, senderRole: .counsel,
                senderId: "counsel-opus@impart.local", modelUsed: "opus",
                contentMarkdown: "Evidence", sentAt: baseDate.addingTimeInterval(80),
                tokenCount: 13, processingDurationMs: 840),
            to: child.id)
        let artifactURI = try #require(ArtifactURI(uri: "impress://imbib/papers/read-proof"))
        try await repository.recordArtifact(uri: artifactURI, title: "Read proof", in: child.id)

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("impart-p5c4-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let databasePath = tempRoot.appendingPathComponent("impress.sqlite").path
        let callback = NativeImpartHost(repository: repository, provenance: ProvenanceService())
        #expect(registerNativeBackend(databasePath: databasePath, callback: callback) == nil)

        let router = ImpartHTTPRouter()
        await router.configureAll(
            persistenceController: persistence,
            syncService: SyncService(persistence: persistence),
            researchRepository: repository,
            artifactResolver: ArtifactResolver(),
            provenanceService: ProvenanceService())

        func generated(_ verb: String, _ args: [String: Any]) async throws -> Any {
            let argsData = try JSONSerialization.data(withJSONObject: args)
            let result = await dispatchVerb(
                name: "impart-service_\(verb)",
                argsJson: String(decoding: argsData, as: UTF8.self),
                callerJson: #"{"kind":"app","name":"impart"}"#)
            #expect(result.status == 200, "Response: \(result.bodyJson)")
            return try JSONSerialization.jsonObject(
                with: Data(result.bodyJson.utf8), options: [.fragmentsAllowed])
        }

        let retiredListResponse = await router.route(HTTPRequest(
            method: "GET", path: "/api/research/conversations",
            queryParams: ["limit": "1", "offset": "0", "includeArchived": "false"]))
        #expect(retiredListResponse.status == 404)

        let listArgs: [String: Any] = [
            "limit": 1, "include_archived": false, "offset": 0,
        ]
        let generatedList = try #require(await generated("list-conversations", listArgs) as? [String: Any])
        let generatedRows = try #require(generatedList["conversations"] as? [[String: Any]])
        #expect(generatedList["total"] as? Int == 2)
        #expect(generatedRows.count == 1)
        #expect(generatedList["offset"] as? Int == 0)
        #expect(generatedList["limit"] as? Int == 1)
        #expect(generatedList["include_archived"] as? Bool == false)
        let firstPageID = try #require(generatedRows.first?["id"] as? String)

        let retiredListPageResponse = await router.route(HTTPRequest(
            method: "GET", path: "/api/research/conversations",
            queryParams: ["limit": "1", "offset": "1", "includeArchived": "false"]))
        #expect(retiredListPageResponse.status == 404)
        let generatedSecondPage = try #require(await generated("list-conversations", [
            "limit": 1, "include_archived": false, "offset": 1
        ]) as? [String: Any])
        let generatedSecondRows = try #require(generatedSecondPage["conversations"] as? [[String: Any]])
        #expect(generatedSecondPage["total"] as? Int == 2)
        #expect(generatedSecondRows.count == 1)
        #expect(generatedSecondRows.first?["id"] as? String != firstPageID)

        let retiredArchivedListResponse = await router.route(HTTPRequest(
            method: "GET", path: "/api/research/conversations",
            queryParams: ["limit": "10", "offset": "0", "includeArchived": "true"]))
        #expect(retiredArchivedListResponse.status == 404)
        let generatedArchived = try #require(await generated("list-conversations", [
            "limit": 10, "include_archived": true, "offset": 0
        ]) as? [String: Any])
        #expect(generatedArchived["total"] as? Int == 3)

        let filtered = try #require(await generated("list-conversations", [
            "limit": 20, "include_archived": false, "offset": 0, "query": "distinctive"
        ]) as? [String: Any])
        #expect(filtered["total"] as? Int == 1)
        #expect(filtered["query"] as? String == "distinctive")
        let filteredRows = try #require(filtered["conversations"] as? [[String: Any]])
        #expect(filteredRows.first?["title"] as? String == "Branch read fixture")

        let retiredDetailResponse = await router.route(HTTPRequest(
            method: "GET", path: "/api/research/conversations/\(child.id.uuidString)"))
        #expect(retiredDetailResponse.status == 404)
        let generatedConversation = try #require(await generated("get-conversation", [
            "conversation_id": child.id.uuidString
        ]) as? [String: Any])
        #expect((generatedConversation["id"] as? String)?.lowercased() == child.id.uuidString.lowercased())
        #expect(generatedConversation["title"] as? String == "Branch read fixture")
        #expect(generatedConversation["participants"] as? [String]
            == ["researcher@example.org", "counsel-opus@impart.local"])
        #expect(generatedConversation["tags"] as? [String] == ["analysis", "draft"])
        #expect(generatedConversation["parent_conversation_id"] as? String
            == parent.id.uuidString)
        #expect(generatedConversation["last_activity_at"] as? String != nil)
        #expect(generatedConversation["summary_text"] as? String == "A distinctive detail")

        let generatedMessages = try #require(generatedConversation["messages"] as? [[String: Any]])
        #expect(generatedMessages.count == 2)
        #expect(generatedMessages.first?["sequence"] as? Int == 1)
        #expect(generatedMessages.first?["content_markdown"] as? String == "Question")
        #expect(generatedMessages.last?["sequence"] as? Int == 2)
        #expect(generatedMessages.last?["content_markdown"] as? String == "Evidence")
        let generatedStatistics = try #require(generatedConversation["statistics"] as? [String: Any])
        #expect(generatedStatistics["message_count"] as? Int == 2)
        #expect(generatedStatistics["human_message_count"] as? Int == 1)
        #expect(generatedStatistics["counsel_message_count"] as? Int == 1)
        #expect(generatedStatistics["total_tokens"] as? Int == 13)
        #expect(generatedStatistics["artifact_count"] as? Int == 1)

        let missingID = UUID()
        let missingArgs = try JSONSerialization.data(withJSONObject: [
            "conversation_id": missingID.uuidString
        ])
        let generatedMissing = await dispatchVerb(
            name: "impart-service_get-conversation",
            argsJson: String(decoding: missingArgs, as: UTF8.self),
            callerJson: #"{"kind":"app","name":"impart"}"#)
        let missingRefusal = try #require(JSONSerialization.jsonObject(
            with: Data(generatedMissing.bodyJson.utf8)) as? [String: Any])
        #expect(missingRefusal["ok"] as? Bool == false)
        #expect(missingRefusal["code"] as? String == "not-found")
    }
}
