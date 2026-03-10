//
//  URLSchemeHandler.swift
//  imprint
//
//  Created by Claude on 2026-01-27.
//

import Foundation
import SwiftUI
import ImpressLogging
import os.log

// MARK: - URL Scheme Handler

/// Handles incoming URL scheme requests for imprint.
///
/// Supported URL schemes:
/// - `imprint://open?imbibManuscript={citeKey}&documentUUID={uuid}` - Open a document linked to an imbib manuscript
/// - `imprint://create?title={title}&template={template}` - Create a new document
/// - `imprint://annotations?documentUUID={uuid}` - Show annotation count from imbib
public actor URLSchemeHandler {

    // MARK: - Singleton

    public static let shared = URLSchemeHandler()

    // MARK: - Properties

    /// Callback when a document should be opened
    @MainActor public var onOpenDocument: ((UUID, String?) -> Void)?

    /// Callback when a new document should be created
    @MainActor public var onCreateDocument: ((String, String?) -> Void)?

    /// Callback when annotation count should be displayed
    @MainActor public var onShowAnnotations: ((UUID, Int) -> Void)?

    // MARK: - URL Handling

    /// Handles an incoming URL.
    ///
    /// - Parameter url: The URL to handle
    /// - Returns: True if the URL was handled
    @discardableResult
    public func handleURL(_ url: URL) async -> Bool {
        guard url.scheme == "imprint" else {
            Logger.urlScheme.warningCapture("Unknown scheme: \(url.scheme ?? "nil")", category: "url-scheme")
            return false
        }

        guard let host = url.host else {
            Logger.urlScheme.warningCapture("No host in URL: \(url)", category: "url-scheme")
            return false
        }

        switch host {
        case "open":
            return await handleOpenURL(url)
        case "create":
            return await handleCreateURL(url)
        case "annotations":
            return await handleAnnotationsURL(url)
        default:
            Logger.urlScheme.warningCapture("Unknown command: \(host)", category: "url-scheme")
            return false
        }
    }

    // MARK: - Open Command

    /// Handles `imprint://open?imbibManuscript={citeKey}&documentUUID={uuid}`
    private func handleOpenURL(_ url: URL) async -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else {
            Logger.urlScheme.errorCapture("Invalid open URL: \(url)", category: "url-scheme")
            return false
        }

        let imbibManuscript = queryItems.first { $0.name == "imbibManuscript" }?.value
        guard let uuidString = queryItems.first(where: { $0.name == "documentUUID" })?.value,
              let documentUUID = UUID(uuidString: uuidString) else {
            Logger.urlScheme.errorCapture("Missing or invalid documentUUID in open URL", category: "url-scheme")
            return false
        }

        Logger.urlScheme.infoCapture("Opening document UUID=\(documentUUID) for imbib manuscript=\(imbibManuscript ?? "unknown")", category: "url-scheme")

        await MainActor.run {
            onOpenDocument?(documentUUID, imbibManuscript)
        }

        // Post notification for observers
        await MainActor.run {
            NotificationCenter.default.post(
                name: .imprintOpenDocumentRequest,
                object: nil,
                userInfo: [
                    "documentUUID": documentUUID,
                    "imbibManuscript": imbibManuscript as Any
                ]
            )
        }

        return true
    }

    // MARK: - Create Command

    /// Handles `imprint://create?title={title}&template={template}`
    private func handleCreateURL(_ url: URL) async -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else {
            Logger.urlScheme.errorCapture("Invalid create URL: \(url)", category: "url-scheme")
            return false
        }

        let title = queryItems.first { $0.name == "title" }?.value ?? "Untitled"
        let template = queryItems.first { $0.name == "template" }?.value

        Logger.urlScheme.infoCapture("Creating new document: title=\(title), template=\(template ?? "default")", category: "url-scheme")

        await MainActor.run {
            onCreateDocument?(title, template)
        }

        // Post notification
        await MainActor.run {
            NotificationCenter.default.post(
                name: .imprintCreateDocumentRequest,
                object: nil,
                userInfo: [
                    "title": title,
                    "template": template as Any
                ]
            )
        }

        return true
    }

    // MARK: - Annotations Command

    /// Handles `imprint://annotations?documentUUID={uuid}`
    ///
    /// This is called by imbib to provide annotation counts via pasteboard.
    private func handleAnnotationsURL(_ url: URL) async -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems,
              let uuidString = queryItems.first(where: { $0.name == "documentUUID" })?.value,
              let documentUUID = UUID(uuidString: uuidString) else {
            Logger.urlScheme.errorCapture("Invalid annotations URL: \(url)", category: "url-scheme")
            return false
        }

        // Read annotation count from pasteboard (set by imbib)
        let count = readAnnotationCountFromPasteboard()

        Logger.urlScheme.infoCapture("Received annotation count=\(count) for document=\(documentUUID)", category: "url-scheme")

        await MainActor.run {
            onShowAnnotations?(documentUUID, count)
        }

        // Post notification
        await MainActor.run {
            NotificationCenter.default.post(
                name: .imprintAnnotationCountReceived,
                object: nil,
                userInfo: [
                    "documentUUID": documentUUID,
                    "count": count
                ]
            )
        }

        return true
    }

    // MARK: - Pasteboard

    private func readAnnotationCountFromPasteboard() -> Int {
        #if os(macOS)
        guard let string = NSPasteboard.general.string(forType: .string),
              let count = Int(string) else {
            return 0
        }
        return count
        #else
        guard let string = UIPasteboard.general.string,
              let count = Int(string) else {
            return 0
        }
        return count
        #endif
    }
}

// MARK: - Notification Names

public extension Notification.Name {
    /// Posted when a document open request is received via URL scheme
    static let imprintOpenDocumentRequest = Notification.Name("imprintOpenDocumentRequest")

    /// Posted when a create document request is received via URL scheme
    static let imprintCreateDocumentRequest = Notification.Name("imprintCreateDocumentRequest")

    /// Posted when annotation count is received from imbib
    static let imprintAnnotationCountReceived = Notification.Name("imprintAnnotationCountReceived")
}

// MARK: - URL Generation

public extension URLSchemeHandler {

    /// Generates a URL for opening an imbib manuscript's linked document.
    ///
    /// - Parameters:
    ///   - documentUUID: The imprint document UUID
    ///   - imbibManuscript: The imbib manuscript cite key (optional)
    /// - Returns: The URL to open the document
    static func openURL(
        documentUUID: UUID,
        imbibManuscript: String? = nil
    ) -> URL? {
        var components = URLComponents()
        components.scheme = "imprint"
        components.host = "open"

        var queryItems = [
            URLQueryItem(name: "documentUUID", value: documentUUID.uuidString)
        ]

        if let manuscript = imbibManuscript {
            queryItems.append(URLQueryItem(name: "imbibManuscript", value: manuscript))
        }

        components.queryItems = queryItems
        return components.url
    }

    /// Generates a URL for requesting imbib annotations.
    ///
    /// This opens imbib to the annotations view for the linked manuscript.
    ///
    /// - Parameter citeKey: The imbib manuscript cite key
    /// - Returns: The URL to open imbib annotations
    static func imbibAnnotationsURL(citeKey: String) -> URL? {
        var components = URLComponents()
        components.scheme = "imbib"
        components.host = "paper"
        components.path = "/\(citeKey)/annotations"
        return components.url
    }
}

// MARK: - Platform Imports

#if os(macOS)
import AppKit
#else
import UIKit
#endif
