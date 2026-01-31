//
//  MessageManagerCoreTests.swift
//  MessageManagerCoreTests
//
//  Tests for MessageManagerCore.
//

import Testing
@testable import MessageManagerCore

// MARK: - Account Tests

@Suite("Account Types")
struct AccountTypeTests {

    @Test("Email provider detection")
    func testEmailProviderDetection() {
        #expect(EmailProvider.detect(from: "user@gmail.com") == .gmail)
        #expect(EmailProvider.detect(from: "user@outlook.com") == .outlook)
        #expect(EmailProvider.detect(from: "user@icloud.com") == .icloud)
        #expect(EmailProvider.detect(from: "user@fastmail.com") == .fastmail)
        #expect(EmailProvider.detect(from: "user@example.com") == .custom)
    }

    @Test("IMAP settings presets")
    func testIMAPPresets() {
        let gmail = IMAPSettings.gmail(email: "user@gmail.com")
        #expect(gmail.host == "imap.gmail.com")
        #expect(gmail.port == 993)
        #expect(gmail.security == .tls)

        let outlook = IMAPSettings.outlook(email: "user@outlook.com")
        #expect(outlook.host == "outlook.office365.com")
    }

    @Test("SMTP settings presets")
    func testSMTPPresets() {
        let gmail = SMTPSettings.gmail(email: "user@gmail.com")
        #expect(gmail.host == "smtp.gmail.com")
        #expect(gmail.port == 587)
        #expect(gmail.security == .starttls)
    }
}

// MARK: - Mailbox Tests

@Suite("Mailbox Types")
struct MailboxTypeTests {

    @Test("Mailbox role detection from name")
    func testRoleDetectionFromName() {
        #expect(MailboxRole.detect(from: "INBOX") == .inbox)
        #expect(MailboxRole.detect(from: "Drafts") == .drafts)
        #expect(MailboxRole.detect(from: "Sent Mail") == .sent)
        #expect(MailboxRole.detect(from: "Trash") == .trash)
        #expect(MailboxRole.detect(from: "Spam") == .spam)
        #expect(MailboxRole.detect(from: "Custom Folder") == .custom)
    }

    @Test("Mailbox role detection from IMAP flags")
    func testRoleDetectionFromFlags() {
        #expect(MailboxRole.detect(from: "Sent", flags: ["\\Sent"]) == .sent)
        #expect(MailboxRole.detect(from: "Deleted", flags: ["\\Trash"]) == .trash)
        #expect(MailboxRole.detect(from: "Junk E-mail", flags: ["\\Junk"]) == .spam)
    }

    @Test("Gmail mailbox role detection")
    func testGmailRoleDetection() {
        #expect(MailboxRole.detect(from: "[Gmail]/Sent Mail") == .sent)
        #expect(MailboxRole.detect(from: "[Gmail]/Trash") == .trash)
        #expect(MailboxRole.detect(from: "[Gmail]/Spam") == .spam)
        #expect(MailboxRole.detect(from: "[Gmail]/All Mail") == .archive)
    }
}

// MARK: - Message Tests

@Suite("Message Types")
struct MessageTypeTests {

    @Test("Email address display string")
    func testEmailAddressDisplay() {
        let addressWithName = EmailAddress(name: "John Doe", email: "john@example.com")
        #expect(addressWithName.displayString == "John Doe")
        #expect(addressWithName.fullDisplayString == "John Doe <john@example.com>")

        let addressWithoutName = EmailAddress(email: "john@example.com")
        #expect(addressWithoutName.displayString == "john@example.com")
        #expect(addressWithoutName.fullDisplayString == "john@example.com")
    }

    @Test("Draft message reply creation")
    func testReplyCreation() {
        let original = Message(
            accountId: UUID(),
            mailboxId: UUID(),
            uid: 1,
            messageId: "<original@example.com>",
            subject: "Hello",
            from: [EmailAddress(name: "Sender", email: "sender@example.com")],
            to: [EmailAddress(email: "me@example.com")],
            date: Date()
        )

        let reply = DraftMessage.reply(to: original, accountId: original.accountId)
        #expect(reply.subject == "Re: Hello")
        #expect(reply.to.first?.email == "sender@example.com")
        #expect(reply.inReplyTo == "<original@example.com>")
    }

    @Test("Draft message forward creation")
    func testForwardCreation() {
        let original = Message(
            accountId: UUID(),
            mailboxId: UUID(),
            uid: 1,
            subject: "Hello",
            from: [EmailAddress(name: "Sender", email: "sender@example.com")],
            to: [EmailAddress(email: "me@example.com")],
            date: Date()
        )

        let forward = DraftMessage.forward(message: original, accountId: original.accountId)
        #expect(forward.subject == "Fwd: Hello")
        #expect(forward.to.isEmpty)
    }
}

// MARK: - Attachment Tests

@Suite("Attachment Types")
struct AttachmentTypeTests {

    @Test("Attachment icon names")
    func testAttachmentIcons() {
        let pdf = Attachment(filename: "document.pdf", mimeType: "application/pdf", size: 1024)
        #expect(pdf.iconName == "doc.fill")

        let image = Attachment(filename: "photo.jpg", mimeType: "image/jpeg", size: 2048)
        #expect(image.iconName == "photo.fill")

        let zip = Attachment(filename: "archive.zip", mimeType: "application/zip", size: 4096)
        #expect(zip.iconName == "doc.zipper")
    }

    @Test("Attachment size display")
    func testAttachmentSizeDisplay() {
        let small = Attachment(filename: "small.txt", mimeType: "text/plain", size: 512)
        #expect(!small.displaySize.isEmpty)

        let large = Attachment(filename: "large.bin", mimeType: "application/octet-stream", size: 10_485_760)
        #expect(large.displaySize.contains("MB") || large.displaySize.contains("10"))
    }
}
