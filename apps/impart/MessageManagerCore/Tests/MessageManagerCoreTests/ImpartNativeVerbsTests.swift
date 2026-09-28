import Foundation
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
        #expect((listed as? [[String: Any]])?.contains { $0["id"] as? String == id } == true)
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
}
