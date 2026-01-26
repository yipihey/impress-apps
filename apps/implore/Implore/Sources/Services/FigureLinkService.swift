import Foundation
import SwiftUI

/// Service for managing figure links between implore and imprint.
///
/// This service handles URL scheme communication and shared container
/// management for cross-app figure synchronization.
@MainActor
public final class FigureLinkService: ObservableObject {
    /// Shared instance
    public static let shared = FigureLinkService()

    /// App group identifier for shared container
    public static let appGroupIdentifier = "group.com.impress.shared"

    /// Currently pending link requests
    @Published public private(set) var pendingLinks: [PendingLink] = []

    /// Whether linking is available (imprint is installed)
    @Published public private(set) var isLinkingAvailable: Bool = false

    private init() {
        checkLinkingAvailability()
    }

    /// Check if imprint is available for linking
    private func checkLinkingAvailability() {
        #if os(macOS)
        if let url = URL(string: "imprint://") {
            isLinkingAvailable = NSWorkspace.shared.urlForApplication(toOpen: url) != nil
        }
        #endif
    }

    /// Handle incoming URL
    public func handleURL(_ url: URL) -> Bool {
        guard url.scheme == "implore" else { return false }

        switch url.host {
        case "unlink-figure":
            return handleUnlinkFigure(url)
        case "request-update":
            return handleRequestUpdate(url)
        default:
            return false
        }
    }

    /// Unlink a figure from an imprint document
    private func handleUnlinkFigure(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let figureId = components.queryItems?.first(where: { $0.name == "figure" })?.value,
              let documentId = components.queryItems?.first(where: { $0.name == "document" })?.value else {
            return false
        }

        // TODO: Implement unlink in library manager
        print("Unlink figure \(figureId) from document \(documentId)")
        return true
    }

    /// Handle update request from imprint
    private func handleRequestUpdate(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let figureId = components.queryItems?.first(where: { $0.name == "figure" })?.value else {
            return false
        }

        // TODO: Regenerate and sync figure
        print("Update requested for figure \(figureId)")
        return true
    }

    /// Request linking a figure to an imprint document
    public func requestLink(figureId: String, documentId: String, label: String) {
        guard isLinkingAvailable else { return }

        var components = URLComponents()
        components.scheme = "imprint"
        components.host = "link-figure"
        components.queryItems = [
            URLQueryItem(name: "figure", value: figureId),
            URLQueryItem(name: "document", value: documentId),
            URLQueryItem(name: "label", value: label)
        ]

        if let url = components.url {
            #if os(macOS)
            NSWorkspace.shared.open(url)
            #endif
        }
    }

    /// Request imprint to update a linked figure
    public func requestImprintUpdate(figureId: String) {
        guard isLinkingAvailable else { return }

        var components = URLComponents()
        components.scheme = "imprint"
        components.host = "update-figure"
        components.queryItems = [
            URLQueryItem(name: "figure", value: figureId)
        ]

        if let url = components.url {
            #if os(macOS)
            NSWorkspace.shared.open(url)
            #endif
        }
    }

    /// Get the shared container URL
    public var sharedContainerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier)
    }

    /// Get the figures directory in the shared container
    public var figuresDirectoryURL: URL? {
        sharedContainerURL?.appendingPathComponent("figures", isDirectory: true)
    }

    /// Ensure the shared figures directory exists
    public func ensureFiguresDirectory() throws {
        guard let figuresURL = figuresDirectoryURL else {
            throw FigureLinkError.noSharedContainer
        }

        try FileManager.default.createDirectory(at: figuresURL, withIntermediateDirectories: true)
    }

    /// Export a figure to the shared container
    public func exportFigure(id: String, pngData: Data, metadata: [String: Any]) throws {
        try ensureFiguresDirectory()
        guard let figuresURL = figuresDirectoryURL else {
            throw FigureLinkError.noSharedContainer
        }

        // Write PNG
        let pngURL = figuresURL.appendingPathComponent("\(id).png")
        try pngData.write(to: pngURL)

        // Write metadata JSON
        let metadataURL = figuresURL.appendingPathComponent("\(id).json")
        let jsonData = try JSONSerialization.data(withJSONObject: metadata, options: .prettyPrinted)
        try jsonData.write(to: metadataURL)
    }
}

/// Pending link request
public struct PendingLink: Identifiable {
    public let id: String
    public let figureId: String
    public let documentId: String
    public let label: String
    public let requestedAt: Date
}

/// Errors for figure linking
public enum FigureLinkError: LocalizedError {
    case noSharedContainer
    case figureNotFound
    case exportFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noSharedContainer:
            return "Shared container not available. Please ensure app group entitlement is configured."
        case .figureNotFound:
            return "Figure not found in library."
        case .exportFailed(let reason):
            return "Failed to export figure: \(reason)"
        }
    }
}
