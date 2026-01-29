//
//  UniversalLinksHandler.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-29.
//

import Foundation
import OSLog

// MARK: - Universal Links Handler

/// Handles Universal Links for deep linking from web URLs.
///
/// Universal Links allow users to tap URLs like `https://imbib.app/doi/10.1234/paper`
/// in any app and have imbib open directly to that paper.
///
/// Setup requirements:
/// 1. Add `com.apple.developer.associated-domains` entitlement:
///    `applinks:imbib.app` or `applinks:yipihey.github.io`
/// 2. Host `apple-app-site-association` file at the domain
///
/// Supported URL patterns:
/// - `https://imbib.app/doi/{doi}` - Search/add paper by DOI
/// - `https://imbib.app/arxiv/{arxivID}` - Search/add paper by arXiv ID
/// - `https://imbib.app/paper/{uuid}` - Open paper by ID
/// - `https://imbib.app/search?q={query}` - Search for papers
///
/// Usage:
/// ```swift
/// // In imbibApp.swift onOpenURL handler
/// if let command = UniversalLinksHandler.parse(url) {
///     await UniversalLinksHandler.handle(command)
/// }
/// ```
public struct UniversalLinksHandler {

    // MARK: - Supported Hosts

    /// Hosts that should be handled as Universal Links
    public static let supportedHosts: Set<String> = [
        "imbib.app",
        "links.imbib.app",
        "yipihey.github.io"
    ]

    // MARK: - URL Commands

    /// Commands that can be parsed from Universal Links
    public enum Command: Sendable {
        case searchDOI(String)
        case searchArXiv(String)
        case openPaper(UUID)
        case search(query: String)
        case showInbox
        case showLibrary
    }

    // MARK: - Parsing

    /// Check if a URL should be handled as a Universal Link.
    ///
    /// - Parameter url: The URL to check
    /// - Returns: true if this URL should be handled by imbib
    public static func canHandle(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return supportedHosts.contains(host) || host.hasSuffix(".imbib.app")
    }

    /// Parse a Universal Link URL into a command.
    ///
    /// - Parameter url: The URL to parse
    /// - Returns: The parsed command, or nil if the URL doesn't match any pattern
    public static func parse(_ url: URL) -> Command? {
        guard canHandle(url) else { return nil }

        let path = url.path.lowercased()
        let pathComponents = path.split(separator: "/").map(String.init)

        // Handle GitHub Pages path (e.g., /imbib/doi/...)
        let effectivePath: [String]
        if pathComponents.first == "imbib" {
            effectivePath = Array(pathComponents.dropFirst())
        } else {
            effectivePath = pathComponents
        }

        guard let firstComponent = effectivePath.first else {
            // Root URL - show library
            return .showLibrary
        }

        switch firstComponent {
        case "doi":
            // /doi/10.1234/paper.id → DOI is everything after /doi/
            let doiPart = effectivePath.dropFirst().joined(separator: "/")
            guard !doiPart.isEmpty else { return nil }
            return .searchDOI(doiPart)

        case "arxiv":
            // /arxiv/2401.12345 → arXiv ID
            guard effectivePath.count >= 2 else { return nil }
            let arxivID = effectivePath[1]
            return .searchArXiv(arxivID)

        case "paper":
            // /paper/{uuid} → Open paper by UUID
            guard effectivePath.count >= 2,
                  let uuid = UUID(uuidString: effectivePath[1]) else { return nil }
            return .openPaper(uuid)

        case "search":
            // /search?q={query} → Search
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let queryItem = components.queryItems?.first(where: { $0.name == "q" }),
               let query = queryItem.value, !query.isEmpty {
                return .search(query: query)
            }
            return nil

        case "inbox":
            return .showInbox

        case "library":
            return .showLibrary

        default:
            return nil
        }
    }

    // MARK: - Handling

    /// Handle a parsed Universal Link command.
    ///
    /// This converts the command to a URL scheme command and delegates
    /// to the existing URLSchemeHandler.
    ///
    /// - Parameter command: The command to handle
    @MainActor
    public static func handle(_ command: Command) async {
        Logger.universalLinks.info("Handling Universal Link command: \(String(describing: command))")

        switch command {
        case .searchDOI(let doi):
            // Convert to imbib://add/doi/{doi} URL scheme
            if let url = URL(string: "imbib://add/doi/\(doi.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? doi)") {
                await URLSchemeHandler.shared.handle(url)
            }

        case .searchArXiv(let arxivID):
            // Convert to imbib://add/arxiv/{arxivID} URL scheme
            if let url = URL(string: "imbib://add/arxiv/\(arxivID)") {
                await URLSchemeHandler.shared.handle(url)
            }

        case .openPaper(let uuid):
            // Convert to imbib://paper/{uuid} URL scheme
            if let url = URL(string: "imbib://paper/\(uuid.uuidString)") {
                await URLSchemeHandler.shared.handle(url)
            }

        case .search(let query):
            // Convert to imbib://search?query={query} URL scheme
            if let escapedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
               let url = URL(string: "imbib://search?query=\(escapedQuery)") {
                await URLSchemeHandler.shared.handle(url)
            }

        case .showInbox:
            NotificationCenter.default.post(name: .showInbox, object: nil)

        case .showLibrary:
            NotificationCenter.default.post(name: .showLibrary, object: nil)
        }
    }
}

// MARK: - Apple App Site Association

/// Information for setting up the apple-app-site-association file.
///
/// This file must be hosted at `https://{domain}/.well-known/apple-app-site-association`
/// with content type `application/json`.
public struct AppleAppSiteAssociation {
    /// Example apple-app-site-association content.
    ///
    /// Replace TEAMID with your actual Apple Developer Team ID.
    public static let example = """
    {
        "applinks": {
            "apps": [],
            "details": [
                {
                    "appIDs": [
                        "TEAMID.com.imbib.app",
                        "TEAMID.com.imbib.app.ios"
                    ],
                    "paths": [
                        "/doi/*",
                        "/arxiv/*",
                        "/paper/*",
                        "/search",
                        "/inbox",
                        "/library"
                    ]
                }
            ]
        }
    }
    """

    /// For GitHub Pages subdomain deployment.
    public static let githubPagesExample = """
    {
        "applinks": {
            "apps": [],
            "details": [
                {
                    "appIDs": [
                        "TEAMID.com.imbib.app",
                        "TEAMID.com.imbib.app.ios"
                    ],
                    "paths": [
                        "/imbib/doi/*",
                        "/imbib/arxiv/*",
                        "/imbib/paper/*",
                        "/imbib/search",
                        "/imbib/inbox",
                        "/imbib/library"
                    ]
                }
            ]
        }
    }
    """
}

// MARK: - Logger Extension

extension Logger {
    static let universalLinks = Logger(subsystem: "com.imbib.app", category: "universal-links")
}
