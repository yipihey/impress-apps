//
//  Logger+Extensions.swift
//  MessageManagerCore
//
//  OSLog extensions with automatic capture to in-app LogStore.
//

import Foundation
import OSLog

// Note: LogLevel and LogStore are defined in Logging/LogStore.swift
// and are part of the same module, so no explicit import is needed.

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

// MARK: - Capturing Log Methods

public extension Logger {

    /// Log debug message and capture to LogStore
    func debugCapture(_ message: String, category: String) {
        debug("\(message)")
        captureToStore(level: .debug, category: category, message: message)
    }

    /// Log info message and capture to LogStore
    func infoCapture(_ message: String, category: String) {
        info("\(message)")
        captureToStore(level: .info, category: category, message: message)
    }

    /// Log warning message and capture to LogStore
    func warningCapture(_ message: String, category: String) {
        warning("\(message)")
        captureToStore(level: .warning, category: category, message: message)
    }

    /// Log error message and capture to LogStore
    func errorCapture(_ message: String, category: String) {
        error("\(message)")
        captureToStore(level: .error, category: category, message: message)
    }

    private func captureToStore(level: LogLevel, category: String, message: String) {
        Task { @MainActor in
            LogStore.shared.log(level: level, category: category, message: message)
        }
    }
}

// MARK: - Convenience Methods

public extension Logger {

    func entering(function: String = #function, category: String = "trace") {
        debugCapture("→ \(function)", category: category)
    }

    func exiting(function: String = #function, category: String = "trace") {
        debugCapture("← \(function)", category: category)
    }

    func httpRequest(_ method: String, url: URL) {
        infoCapture("HTTP \(method) \(url.absoluteString)", category: "network")
    }

    func httpResponse(_ statusCode: Int, url: URL, bytes: Int? = nil) {
        if let bytes = bytes {
            infoCapture("HTTP \(statusCode) \(url.absoluteString) (\(bytes) bytes)", category: "network")
        } else {
            infoCapture("HTTP \(statusCode) \(url.absoluteString)", category: "network")
        }
    }
}

// MARK: - Global Logging Functions

/// Convenience functions for logging with automatic capture

public func logDebug(_ message: String, category: String = "app") {
    Logger.viewModels.debugCapture(message, category: category)
}

public func logInfo(_ message: String, category: String = "app") {
    Logger.viewModels.infoCapture(message, category: category)
}

public func logWarning(_ message: String, category: String = "app") {
    Logger.viewModels.warningCapture(message, category: category)
}

public func logError(_ message: String, category: String = "app") {
    Logger.viewModels.errorCapture(message, category: category)
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

// MARK: - Performance Timing

public extension Logger {

    /// Log a performance timing measurement
    func timing(_ operation: String, milliseconds: Double, count: Int? = nil) {
        let ms = String(format: "%.1f", milliseconds)
        if let count = count {
            infoCapture("⏱ \(operation): \(ms)ms (\(count) items)", category: "performance")
        } else {
            infoCapture("⏱ \(operation): \(ms)ms", category: "performance")
        }
    }
}

/// Measure execution time of a synchronous block
public func measureTime<T>(_ operation: String, count: Int? = nil, _ block: () -> T) -> T {
    let start = CFAbsoluteTimeGetCurrent()
    let result = block()
    let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
    Logger.performance.timing(operation, milliseconds: elapsed, count: count)
    return result
}

/// Measure execution time of an async block
public func measureTimeAsync<T>(_ operation: String, count: Int? = nil, _ block: () async -> T) async -> T {
    let start = CFAbsoluteTimeGetCurrent()
    let result = await block()
    let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
    Logger.performance.timing(operation, milliseconds: elapsed, count: count)
    return result
}
