import Testing
@testable import CounselEngine

@Test func databaseCreation() throws {
    let db = try CounselDatabase(inMemory: true)
    let conversations = try db.fetchAllConversations()
    #expect(conversations.isEmpty)
}

@Test func conversationPersistence() throws {
    let db = try CounselDatabase(inMemory: true)

    let conversation = CounselConversation(
        subject: "Test subject",
        participantEmail: "test@example.com"
    )
    try db.createConversation(conversation)

    let fetched = try db.fetchConversation(id: conversation.id)
    #expect(fetched != nil)
    #expect(fetched?.subject == "Test subject")
}

@Test func messagePersistence() throws {
    let db = try CounselDatabase(inMemory: true)

    let conversation = CounselConversation(
        subject: "Test",
        participantEmail: "test@example.com"
    )
    try db.createConversation(conversation)

    let message = CounselMessage(
        conversationID: conversation.id,
        role: .user,
        content: "Hello counsel",
        emailMessageID: "<test@example.com>",
        tokenCount: 5
    )
    try db.addMessage(message)

    let messages = try db.fetchMessages(conversationID: conversation.id)
    #expect(messages.count == 1)
    #expect(messages.first?.content == "Hello counsel")

    // Verify conversation was updated
    let updated = try db.fetchConversation(id: conversation.id)
    #expect(updated?.messageCount == 1)
    #expect(updated?.totalTokensUsed == 5)
}

@Test func toolExecutionPersistence() throws {
    let db = try CounselDatabase(inMemory: true)

    let conversation = CounselConversation(
        subject: "Test",
        participantEmail: "test@example.com"
    )
    try db.createConversation(conversation)

    let execution = CounselToolExecution(
        conversationID: conversation.id,
        toolName: "imbib_search_library",
        toolInput: "{\"q\": \"dark matter\"}",
        toolOutput: "{\"papers\": []}",
        durationMs: 150
    )
    try db.addToolExecution(execution)

    let executions = try db.fetchToolExecutions(conversationID: conversation.id)
    #expect(executions.count == 1)
    #expect(executions.first?.toolName == "imbib_search_library")
}

@Test func emailThreadResolution() throws {
    let db = try CounselDatabase(inMemory: true)

    let conversation = CounselConversation(
        subject: "Find papers",
        participantEmail: "pi@impress.local"
    )
    try db.createConversation(conversation)

    let message = CounselMessage(
        conversationID: conversation.id,
        role: .user,
        content: "Find papers on dark matter",
        emailMessageID: "<msg1@impress.local>"
    )
    try db.addMessage(message)

    // Should find conversation by email message ID
    let found = try db.fetchConversationByEmailMessageID("<msg1@impress.local>")
    #expect(found?.id == conversation.id)

    // Should not find by unknown ID
    let notFound = try db.fetchConversationByEmailMessageID("<unknown@example.com>")
    #expect(notFound == nil)
}

@Test func messageSearch() throws {
    let db = try CounselDatabase(inMemory: true)

    let conversation = CounselConversation(
        subject: "Test",
        participantEmail: "test@example.com"
    )
    try db.createConversation(conversation)

    try db.addMessage(CounselMessage(
        conversationID: conversation.id,
        role: .user,
        content: "Find papers on quantum computing"
    ))
    try db.addMessage(CounselMessage(
        conversationID: conversation.id,
        role: .assistant,
        content: "I found 5 papers about quantum computing"
    ))
    try db.addMessage(CounselMessage(
        conversationID: conversation.id,
        role: .user,
        content: "Now search for dark matter"
    ))

    let results = try db.searchMessages(query: "quantum")
    #expect(results.count == 2)

    let darkMatter = try db.searchMessages(query: "dark matter")
    #expect(darkMatter.count == 1)
}
