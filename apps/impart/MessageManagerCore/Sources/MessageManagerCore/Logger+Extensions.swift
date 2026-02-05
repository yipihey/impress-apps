//
//  Logger+Extensions.swift
//  MessageManagerCore
//
//  App-specific Logger categories for impart.
//  Shared capture methods and global log functions are in ImpressLogging.
//

import Foundation
import OSLog

// MARK: - Subsystem

private let subsystem = "com.imbib.impart"

// MARK: - Logger Categories

public extension Logger {

    // MARK: - Data Layer

    static let persistence = Logger(subsystem: subsystem, category: "persistence")
    static let coreData = Logger(subsystem: subsystem, category: "coredata")

    // MARK: - Accounts & Folders

    static let accounts = Logger(subsystem: subsystem, category: "accounts")
    static let folders = Logger(subsystem: subsystem, category: "folders")

    // MARK: - Messages

    static let messages = Logger(subsystem: subsystem, category: "messages")
    static let threads = Logger(subsystem: subsystem, category: "threads")
    static let conversations = Logger(subsystem: subsystem, category: "conversations")

    // MARK: - IMAP/SMTP

    static let imap = Logger(subsystem: subsystem, category: "imap")
    static let smtp = Logger(subsystem: subsystem, category: "smtp")
    static let sync = Logger(subsystem: subsystem, category: "sync")

    // MARK: - Network

    static let network = Logger(subsystem: subsystem, category: "network")

    // MARK: - Research/AI

    static let research = Logger(subsystem: subsystem, category: "research")
    static let counsel = Logger(subsystem: subsystem, category: "counsel")
    static let artifacts = Logger(subsystem: subsystem, category: "artifacts")

    // MARK: - Mbox Storage

    static let mbox = Logger(subsystem: subsystem, category: "mbox")
    static let archive = Logger(subsystem: subsystem, category: "archive")

    // MARK: - Automation

    static let automation = Logger(subsystem: subsystem, category: "automation")
    static let httpServer = Logger(subsystem: subsystem, category: "httpserver")

    // MARK: - Credentials

    static let credentials = Logger(subsystem: subsystem, category: "credentials")

    // MARK: - UI

    static let viewModels = Logger(subsystem: subsystem, category: "viewmodels")
    static let navigation = Logger(subsystem: subsystem, category: "navigation")

    // MARK: - Performance

    static let performance = Logger(subsystem: subsystem, category: "performance")

    // MARK: - Triage

    static let triage = Logger(subsystem: subsystem, category: "triage")
}

// MARK: - IMAP/SMTP Logging

public extension Logger {

    /// Log IMAP command
    func imapCommand(_ command: String, mailbox: String? = nil) {
        if let mailbox = mailbox {
            infoCapture("IMAP \(command) [\(mailbox)]", category: "imap")
        } else {
            infoCapture("IMAP \(command)", category: "imap")
        }
    }

    /// Log IMAP response
    func imapResponse(_ status: String, messages: Int? = nil) {
        if let count = messages {
            infoCapture("IMAP \(status) (\(count) messages)", category: "imap")
        } else {
            infoCapture("IMAP \(status)", category: "imap")
        }
    }

    /// Log SMTP send
    func smtpSend(to recipients: [String], subject: String) {
        let recipientList = recipients.joined(separator: ", ")
        infoCapture("SMTP SEND to: \(recipientList) - \(subject)", category: "smtp")
    }
}

// MARK: - Research/AI Logging

public extension Logger {

    /// Log AI session events
    func counselSession(_ event: String, model: String? = nil) {
        if let model = model {
            infoCapture("Counsel [\(model)] \(event)", category: "counsel")
        } else {
            infoCapture("Counsel \(event)", category: "counsel")
        }
    }

    /// Log artifact operations
    func artifactOperation(_ operation: String, uri: String) {
        infoCapture("\(operation): \(uri)", category: "artifacts")
    }
}
