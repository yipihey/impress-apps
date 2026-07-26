import Testing
@testable import ImpelMail

@Test func emailParserBasic() {
    let raw = """
    From: user@example.com\r
    To: counsel@impress.local\r
    Subject: Find papers on dark matter\r
    Date: Thu, 06 Feb 2026 10:00:00 -0800\r
    Message-ID: <test-123@example.com>\r
    \r
    Please find the 3 most cited papers on dark matter halos from 2024.
    """

    let message = EmailParser.parse(rawData: raw, from: "user@example.com", to: ["counsel@impress.local"])

    #expect(message.subject == "Find papers on dark matter")
    #expect(message.from == "user@example.com")
    #expect(message.to == ["counsel@impress.local"])
    #expect(message.messageID == "<test-123@example.com>")
    #expect(message.body.contains("dark matter halos"))
}

@Test func intentClassification() {
    #expect(CounselIntent.classify(subject: "Find papers on X", body: "") == .findPapers)
    #expect(CounselIntent.classify(subject: "Search for literature", body: "") == .findPapers)
    #expect(CounselIntent.classify(subject: "Summarize this PDF", body: "") == .summarize)
    #expect(CounselIntent.classify(subject: "Draft a response", body: "") == .draft)
    #expect(CounselIntent.classify(subject: "Analyze the data", body: "") == .analyze)
    #expect(CounselIntent.classify(subject: "Review my manuscript", body: "") == .review)
    #expect(CounselIntent.classify(subject: "Hello", body: "What time is it?") == .general)
}

@Test func rfc2822Formatting() {
    let message = MailMessage(
        from: "counsel@impress.local",
        to: ["user@example.com"],
        subject: "Re: Test",
        body: "Hello, this is a reply."
    )

    let rfc = message.toRFC2822()
    #expect(rfc.contains("From: counsel@impress.local"))
    #expect(rfc.contains("To: user@example.com"))
    #expect(rfc.contains("Subject: Re: Test"))
    #expect(rfc.contains("MIME-Version: 1.0"))
    #expect(rfc.contains("Hello, this is a reply."))
}

@Test func counselRequestFromMessage() {
    let message = MailMessage(
        from: "researcher@uni.edu",
        to: ["counsel@impress.local"],
        subject: "Find recent papers on transformer architectures",
        body: "I need a survey of the latest work on attention mechanisms."
    )

    let request = CounselRequest(from: message)
    #expect(request.intent == .findPapers)
    #expect(request.from == "researcher@uni.edu")
    #expect(request.subject == "Find recent papers on transformer architectures")
}

@Test func counselResponseToMailMessage() {
    let response = CounselResponse(
        to: "researcher@uni.edu",
        subject: "Re: Test",
        body: "Here are your results.",
        inReplyTo: "<orig-123@uni.edu>"
    )

    let msg = response.toMailMessage()
    #expect(msg.from == "counsel@impress.local")
    #expect(msg.to == ["researcher@uni.edu"])
    #expect(msg.inReplyTo == "<orig-123@uni.edu>")
}

@Test func messageStoreBasics() async {
    let store = MessageStore()

    let reply = MailMessage(
        from: "counsel@impress.local",
        to: ["PI@impress.local"],
        subject: "Re: Test",
        body: "Here are your results."
    )

    await store.storeReply(reply)

    // IMAP side only sees replies
    let count = await store.messageCount
    #expect(count == 1)

    let fetched = await store.message(at: 1)
    #expect(fetched?.subject == "Re: Test")
}

@Test func messageStoreSeparation() async {
    let store = MessageStore()

    // PI sends to counsel (incoming)
    let outgoing = MailMessage(
        from: "PI@impress.local",
        to: ["counsel@impress.local"],
        subject: "Find papers",
        body: "Find dark matter papers"
    )
    await store.receiveIncoming(outgoing)

    // Counsel replies to PI
    let reply = MailMessage(
        from: "counsel@impress.local",
        to: ["PI@impress.local"],
        subject: "Re: Find papers",
        body: "Found 3 papers."
    )
    await store.storeReply(reply)

    // IMAP should only see the reply, not the PI's outgoing message
    let imapCount = await store.messageCount
    #expect(imapCount == 1)

    let imapMsg = await store.message(at: 1)
    #expect(imapMsg?.from == "counsel@impress.local")

    // Total count includes both
    let total = await store.totalCount
    #expect(total == 2)
}
