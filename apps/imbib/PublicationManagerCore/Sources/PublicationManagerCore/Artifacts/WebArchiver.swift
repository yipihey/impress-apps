//
//  WebArchiver.swift
//  PublicationManagerCore
//
//  Archives webpages for offline viewing within artifact capture.
//

import Foundation
import OSLog
#if canImport(WebKit)
import WebKit
#endif

/// Result of a web archive operation.
nonisolated public struct WebArchiveResult: Sendable {
    public let archivePath: URL
    public let title: String?
    public let byteSize: Int64
}

/// Archives webpages as .webarchive files for offline viewing.
///
/// Uses WKWebView to load the page and create a web archive that includes
/// HTML and inline resources (CSS, images) in a single file.
public actor WebArchiver {

    public static let shared = WebArchiver()

    /// The base directory for artifact file storage.
    nonisolated private var artifactStorageURL: URL {
        let groupContainer = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.impress.suite"
        )
        let base = groupContainer ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("artifacts", isDirectory: true)
    }

    /// Archive a webpage for an artifact.
    ///
    /// Creates a .webarchive file in the artifact's storage directory.
    /// This method loads the page in an off-screen WKWebView and captures
    /// the rendered page with its resources.
    ///
    /// - Parameters:
    ///   - url: The URL to archive
    ///   - artifactID: The artifact ID (used for storage path)
    /// - Returns: The archive result, or nil if archiving failed
    @MainActor
    public func archive(url: URL, artifactID: UUID) async -> WebArchiveResult? {
        #if canImport(WebKit) && os(macOS)
        let destDir = artifactStorageURL.appendingPathComponent(artifactID.uuidString, isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        } catch {
            Logger.library.errorCapture("WebArchiver: Failed to create directory: \(error)", category: "artifacts")
            return nil
        }

        let archivePath = destDir.appendingPathComponent("page.webarchive")

        do {
            let data = try await loadAndArchive(url: url)

            try data.write(to: archivePath)
            let byteSize = Int64(data.count)

            Logger.library.infoCapture(
                "WebArchiver: Archived \(url.absoluteString) (\(ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file)))",
                category: "artifacts"
            )

            // Try to extract title from the archive
            let title = extractTitle(from: data)

            return WebArchiveResult(archivePath: archivePath, title: title, byteSize: byteSize)
        } catch {
            Logger.library.errorCapture("WebArchiver: Failed to archive \(url.absoluteString): \(error)", category: "artifacts")
            return nil
        }
        #else
        Logger.library.infoCapture("WebArchiver: Not available on this platform", category: "artifacts")
        return nil
        #endif
    }

    /// Check if an archived page exists for an artifact.
    nonisolated public func archiveURL(for artifactID: UUID) -> URL? {
        let path = artifactStorageURL
            .appendingPathComponent(artifactID.uuidString, isDirectory: true)
            .appendingPathComponent("page.webarchive")
        return FileManager.default.fileExists(atPath: path.path) ? path : nil
    }

    // MARK: - Private

    #if canImport(WebKit) && os(macOS)
    /// Load a URL in an off-screen WKWebView and create a web archive.
    @MainActor
    private func loadAndArchive(url: URL) async throws -> Data {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1024, height: 768), configuration: config)

        // Load the URL and wait for navigation to complete
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let delegate = NavigationDelegate(continuation: continuation)
            webView.navigationDelegate = delegate
            webView.load(URLRequest(url: url))

            // Hold a strong reference to the delegate
            objc_setAssociatedObject(webView, "delegate", delegate, .OBJC_ASSOCIATION_RETAIN)
        }

        // Small delay for any final resource loads
        try await Task.sleep(for: .milliseconds(500))

        // Create web archive
        return try await withCheckedThrowingContinuation { continuation in
            webView.createWebArchiveData { result in
                continuation.resume(with: result)
            }
        }
    }

    /// Extract the page title from web archive data (plist format).
    private nonisolated func extractTitle(from data: Data) -> String? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let mainResource = plist["WebMainResource"] as? [String: Any],
              let htmlData = mainResource["WebResourceData"] as? Data,
              let html = String(data: htmlData, encoding: .utf8) else {
            return nil
        }

        // Simple <title> extraction
        if let titleRange = html.range(of: "<title>"),
           let endRange = html.range(of: "</title>", range: titleRange.upperBound..<html.endIndex) {
            let title = String(html[titleRange.upperBound..<endRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return title.isEmpty ? nil : title
        }
        return nil
    }
    #endif
}

// MARK: - Navigation Delegate

#if canImport(WebKit) && os(macOS)
/// Simple navigation delegate that resolves a continuation when page load completes.
private final class NavigationDelegate: NSObject, WKNavigationDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<Void, Error>?
    private let timeout: TimeInterval = 15

    init(continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
        super.init()

        // Timeout after 15 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.continuation?.resume()
            self?.continuation = nil
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
#endif
