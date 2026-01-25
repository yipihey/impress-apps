//
//  PDFBrowserSession.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-06.
//

import Foundation
import OSLog

#if canImport(WebKit)
import WebKit

/// Manages persistent browser sessions for PDF downloads.
///
/// This class provides a shared WKWebViewConfiguration that persists cookies
/// and session data between browser instances. This reduces the need to
/// re-authenticate with publishers.
///
/// Usage:
/// ```swift
/// let config = PDFBrowserSession.shared.webViewConfiguration()
/// let webView = WKWebView(frame: .zero, configuration: config)
/// ```
@MainActor
public final class PDFBrowserSession {

    // MARK: - Shared Instance

    public static let shared = PDFBrowserSession()

    // MARK: - Properties

    /// The website data store (uses default persistent store)
    private let dataStore: WKWebsiteDataStore

    // MARK: - Initialization

    private init() {
        // Use the default (persistent) data store
        // This stores cookies, local storage, etc. between sessions
        self.dataStore = WKWebsiteDataStore.default()

        Logger.pdfBrowser.info("PDFBrowserSession initialized with persistent storage")
    }

    // MARK: - Configuration

    /// Get a WKWebViewConfiguration with persistent storage.
    ///
    /// All web views created with this configuration will share cookies
    /// and session data, reducing re-authentication needs.
    public func webViewConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()

        // Use default persistent data store
        config.websiteDataStore = dataStore

        // Enable JavaScript (required for most publisher sites)
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = true
        config.defaultWebpagePreferences = preferences

        // Configure content rules (allow all by default for publisher sites)
        config.limitsNavigationsToAppBoundDomains = false

        Logger.pdfBrowser.debug("Created web view configuration")

        return config
    }

    // MARK: - Session Management

    /// Clear all browser session data (cookies, cache, local storage).
    ///
    /// Call this if the user wants to start fresh or log out of all publishers.
    public func clearSession() async {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let date = Date(timeIntervalSince1970: 0)

        await dataStore.removeData(ofTypes: types, modifiedSince: date)

        Logger.pdfBrowser.info("Browser session cleared (all cookies and cache removed)")
    }

    /// Clear only cookies (preserve cache for performance).
    public func clearCookies() async {
        let types: Set<String> = [WKWebsiteDataTypeCookies]
        let date = Date(timeIntervalSince1970: 0)

        await dataStore.removeData(ofTypes: types, modifiedSince: date)

        Logger.pdfBrowser.info("Browser cookies cleared")
    }

    /// Clear cache only (preserve cookies for authentication).
    public func clearCache() async {
        let types: Set<String> = [
            WKWebsiteDataTypeDiskCache,
            WKWebsiteDataTypeMemoryCache
        ]
        let date = Date(timeIntervalSince1970: 0)

        await dataStore.removeData(ofTypes: types, modifiedSince: date)

        Logger.pdfBrowser.info("Browser cache cleared")
    }

    /// Get all cookies (for debugging).
    public func getAllCookies() async -> [HTTPCookie] {
        let cookies = await dataStore.httpCookieStore.allCookies()
        Logger.pdfBrowser.debug("Retrieved \(cookies.count) cookies")
        return cookies
    }

    /// Get cookies for a specific domain.
    public func getCookies(for domain: String) async -> [HTTPCookie] {
        let allCookies = await getAllCookies()
        let domainCookies = allCookies.filter { cookie in
            cookie.domain.contains(domain) || domain.contains(cookie.domain)
        }
        Logger.pdfBrowser.debug("Retrieved \(domainCookies.count) cookies for domain: \(domain)")
        return domainCookies
    }

    /// Check if we have any cookies for a domain (indicates previous login).
    public func hasCookies(for domain: String) async -> Bool {
        let cookies = await getCookies(for: domain)
        return !cookies.isEmpty
    }
}

#else

// Stub for platforms without WebKit (tvOS)
@MainActor
public final class PDFBrowserSession {
    public static let shared = PDFBrowserSession()

    private init() {
        Logger.pdfBrowser.info("PDFBrowserSession: WebKit not available on this platform")
    }

    public func clearSession() async {
        // No-op on tvOS
    }
}

#endif
