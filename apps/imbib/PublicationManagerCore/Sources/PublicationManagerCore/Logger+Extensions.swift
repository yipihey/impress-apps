//
//  Logger+Extensions.swift
//  PublicationManagerCore
//
//  App-specific Logger categories for imbib.
//  Shared capture methods and global log functions are in ImpressLogging.
//

import Foundation
import OSLog

// MARK: - Subsystem

private let subsystem = "com.imbib"

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
