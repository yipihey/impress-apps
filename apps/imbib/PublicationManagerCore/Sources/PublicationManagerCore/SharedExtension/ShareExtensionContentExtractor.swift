//
//  ShareExtensionContentExtractor.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-07.
//

import Foundation
import UniformTypeIdentifiers

/// Result of extracting shared content from an extension context.
public struct SharedContent: Sendable {
    /// The shared URL
    public let url: URL

    /// The page title (from JavaScript preprocessing)
    public let pageTitle: String?

    public init(url: URL, pageTitle: String?) {
        self.url = url
        self.pageTitle = pageTitle
    }
}

/// Extracts URL and page title from share extension input items.
///
/// This class centralizes the content extraction logic used by both
/// macOS and iOS share extensions, avoiding code duplication.
public final class ShareExtensionContentExtractor {

    // MARK: - Singleton

    /// Shared instance
    public static let shared = ShareExtensionContentExtractor()

    private init() {}

    // MARK: - Public API

    /// Extract URL and page title from extension item attachments.
    ///
    /// - Parameters:
    ///   - attachments: The attachments from the extension item
    ///   - completion: Called with the extracted URL and optional page title
    public func extractContent(
        from attachments: [NSItemProvider],
        completion: @escaping (SharedContent?) -> Void
    ) {
        extractSharedContent(from: attachments) { url, title in
            if let url = url {
                completion(SharedContent(url: url, pageTitle: title))
            } else {
                completion(nil)
            }
        }
    }

    /// Queue a shared item for processing by the main app.
    ///
    /// This method handles all item types (smart search, paper, docs selection).
    ///
    /// - Parameter item: The shared item to queue
    public func queueItem(_ item: ShareExtensionService.SharedItem) {
        switch item.type {
        case .smartSearch:
            ShareExtensionService.shared.queueSmartSearch(
                url: item.url,
                name: item.name ?? "Shared Search",
                libraryID: item.libraryID
            )
        case .paper:
            ShareExtensionService.shared.queuePaperImport(
                url: item.url,
                libraryID: item.libraryID
            )
        case .docsSelection:
            ShareExtensionService.shared.queueDocsSelection(
                url: item.url,
                query: item.query ?? ""
            )
        }
    }

    // MARK: - Private Implementation

    /// Extract URL and page title from JavaScript preprocessing results
    private func extractSharedContent(
        from attachments: [NSItemProvider],
        completion: @escaping (URL?, String?) -> Void
    ) {
        // First, try to get JavaScript preprocessing results (includes page title)
        let propertyListType = "public.property-list"

        for attachment in attachments {
            if attachment.hasItemConformingToTypeIdentifier(propertyListType) {
                attachment.loadItem(forTypeIdentifier: propertyListType, options: nil) { [weak self] item, error in
                    guard let dictionary = item as? NSDictionary,
                          let results = dictionary[NSExtensionJavaScriptPreprocessingResultsKey] as? NSDictionary else {
                        // Fall back to URL-only extraction
                        self?.extractURLOnly(from: attachments, completion: completion)
                        return
                    }

                    let title = results["title"] as? String
                    let urlString = results["url"] as? String
                    let url = urlString.flatMap { URL(string: $0) }

                    completion(url, title)
                }
                return
            }
        }

        // Fall back to URL-only extraction
        extractURLOnly(from: attachments, completion: completion)
    }

    /// Fallback: Extract URL without page title (for non-browser shares)
    private func extractURLOnly(
        from attachments: [NSItemProvider],
        completion: @escaping (URL?, String?) -> Void
    ) {
        // Look for URL attachment
        let urlType = UTType.url.identifier

        for attachment in attachments {
            if attachment.hasItemConformingToTypeIdentifier(urlType) {
                attachment.loadItem(forTypeIdentifier: urlType, options: nil) { item, error in
                    if let url = item as? URL {
                        completion(url, nil)
                    } else if let urlData = item as? Data,
                              let url = URL(dataRepresentation: urlData, relativeTo: nil) {
                        completion(url, nil)
                    } else {
                        completion(nil, nil)
                    }
                }
                return
            }
        }

        // Try plain text that might be a URL
        let textType = UTType.plainText.identifier
        for attachment in attachments {
            if attachment.hasItemConformingToTypeIdentifier(textType) {
                attachment.loadItem(forTypeIdentifier: textType, options: nil) { item, error in
                    if let urlString = item as? String,
                       let url = URL(string: urlString) {
                        completion(url, nil)
                    } else {
                        completion(nil, nil)
                    }
                }
                return
            }
        }

        completion(nil, nil)
    }
}
