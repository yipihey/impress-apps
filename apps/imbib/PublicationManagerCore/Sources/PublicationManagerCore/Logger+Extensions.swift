//
//  Logger+Extensions.swift
//  PublicationManagerCore
//

import Foundation
import OSLog

// MARK: - Subsystem

private let subsystem = "com.imbib"

// MARK: - Category Names

/// Maps Logger instances to their category names for LogStore capture
private var loggerCategories: [ObjectIdentifier: String] = [:]

// MARK: - Logger Categories

public extension Logger {

    // MARK: - Data Layer

    static let persistence = Logger(subsystem: subsystem, category: "persistence")
    static let library = Logger(subsystem: subsystem, category: "library")
    static let smartSearch = Logger(subsystem: subsystem, category: "smartsearch")

    // MARK: - Inbox

    static let inbox = Logger(subsystem: subsystem, category: "inbox")

    // MARK: - BibTeX

    static let bibtex = Logger(subsystem: subsystem, category: "bibtex")

    // MARK: - Sources & Search

    static let sources = Logger(subsystem: subsystem, category: "sources")
    static let search = Logger(subsystem: subsystem, category: "search")
    static let network = Logger(subsystem: subsystem, category: "network")
    static let rateLimiter = Logger(subsystem: subsystem, category: "ratelimit")
    static let deduplication = Logger(subsystem: subsystem, category: "dedup")

    // MARK: - Enrichment

    static let enrichment = Logger(subsystem: subsystem, category: "enrichment")

    // MARK: - Credentials

    static let credentials = Logger(subsystem: subsystem, category: "credentials")

    // MARK: - Files

    static let files = Logger(subsystem: subsystem, category: "files")

    // MARK: - PDF Browser

    static let pdfBrowser = Logger(subsystem: subsystem, category: "pdfbrowser")

    // MARK: - Sync

    static let sync = Logger(subsystem: subsystem, category: "sync")

    // MARK: - UI

    static let viewModels = Logger(subsystem: subsystem, category: "viewmodels")
    static let navigation = Logger(subsystem: subsystem, category: "navigation")

    // MARK: - Performance

    static let performance = Logger(subsystem: subsystem, category: "performance")

    // MARK: - Share Extension

    static let shareExtension = Logger(subsystem: subsystem, category: "shareext")

    // MARK: - Settings

    static let settings = Logger(subsystem: subsystem, category: "settings")
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

// MARK: - PDF Browser Logging

public extension Logger {

    /// Log browser navigation events
    func browserNavigation(_ action: String, url: URL) {
        infoCapture("\(action): \(url.absoluteString)", category: "pdfbrowser")
    }

    /// Log download events
    func browserDownload(_ event: String, filename: String? = nil, bytes: Int? = nil) {
        var message = event
        if let filename = filename {
            message += " - \(filename)"
        }
        if let bytes = bytes {
            message += " (\(bytes) bytes)"
        }
        infoCapture(message, category: "pdfbrowser")
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
