//
//  PDFBrowserViewModel.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-06.
//

import Foundation
import OSLog

#if canImport(WebKit)
import WebKit
#endif

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Platform-agnostic view model for the PDF browser.
///
/// This view model manages the state of an interactive web browser session
/// for downloading PDFs from publishers. It works on macOS and iOS (not tvOS).
///
/// The platform-specific view (NSViewRepresentable or UIViewRepresentable)
/// sets the `webView` reference and calls update methods from WKNavigationDelegate.
@Observable
@MainActor
public final class PDFBrowserViewModel {

    // MARK: - State

    /// Current URL displayed in the browser
    public var currentURL: URL?

    /// Page title from the web view
    public var pageTitle: String = ""

    /// Whether the page is currently loading
    public var isLoading: Bool = true

    /// Whether the browser can navigate back
    public var canGoBack: Bool = false

    /// Whether the browser can navigate forward
    public var canGoForward: Bool = false

    /// Download progress (0.0 to 1.0)
    public var downloadProgress: Double?

    /// Data of a detected PDF download
    public var detectedPDFData: Data?

    /// Filename of a detected PDF download
    public var detectedPDFFilename: String?

    /// Error message to display
    public var errorMessage: String?

    // MARK: - Context

    /// The publication we're fetching a PDF for
    public let publication: CDPublication

    /// The URL to load initially
    public let initialURL: URL

    /// The library ID for context
    public let libraryID: UUID

    // MARK: - Callbacks

    /// Called when a PDF is captured and should be saved
    public var onPDFCaptured: ((Data) async -> Void)?

    /// Called when the browser should be dismissed
    public var onDismiss: (() -> Void)?

    /// Called when manual capture is requested (platform view implements actual capture)
    public var onManualCaptureRequested: (() async -> Void)?

    /// Whether a manual capture is in progress
    public var isCapturing: Bool = false

    // MARK: - Proxy Settings

    /// Library proxy URL from settings (empty if not configured)
    public var libraryProxyURL: String = ""

    /// Whether proxy is enabled in settings
    public var proxyEnabled: Bool = false

    /// Whether we're currently viewing a proxied URL
    public var isProxied: Bool = false

    // MARK: - Direct PDF Detection

    /// Suggested direct PDF URL based on current page
    public var suggestedPDFURL: URL?

    /// Whether we've already tried the suggested PDF URL
    private var triedPDFURLs: Set<URL> = []

    // MARK: - WebView Reference

    #if canImport(WebKit)
    /// Reference to the WKWebView (set by platform-specific view)
    public weak var webView: WKWebView?
    #endif

    // MARK: - Initialization

    public init(publication: CDPublication, initialURL: URL, libraryID: UUID) {
        self.publication = publication
        self.initialURL = initialURL
        self.libraryID = libraryID
        self.currentURL = initialURL

        Logger.pdfBrowser.info("PDFBrowserViewModel initialized for: \(publication.title ?? "Unknown")")
        Logger.pdfBrowser.info("Starting URL: \(initialURL.absoluteString)")
    }

    // MARK: - Navigation Actions

    /// Navigate back in browser history
    public func goBack() {
        #if canImport(WebKit)
        guard let webView = webView, webView.canGoBack else { return }
        webView.goBack()
        Logger.pdfBrowser.info("Navigating back")
        #endif
    }

    /// Navigate forward in browser history
    public func goForward() {
        #if canImport(WebKit)
        guard let webView = webView, webView.canGoForward else { return }
        webView.goForward()
        Logger.pdfBrowser.info("Navigating forward")
        #endif
    }

    /// Reload the current page
    public func reload() {
        #if canImport(WebKit)
        webView?.reload()
        Logger.pdfBrowser.info("Reloading page")
        #endif
    }

    /// Stop loading the current page
    public func stopLoading() {
        #if canImport(WebKit)
        webView?.stopLoading()
        Logger.pdfBrowser.info("Stopped loading")
        #endif
    }

    // MARK: - Clipboard

    /// Copy the current URL to the system clipboard
    public func copyURLToClipboard() {
        guard let url = currentURL else {
            Logger.pdfBrowser.warning("No URL to copy")
            return
        }

        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        Logger.pdfBrowser.info("URL copied to clipboard (macOS): \(url.absoluteString)")
        #elseif canImport(UIKit)
        UIPasteboard.general.string = url.absoluteString
        Logger.pdfBrowser.info("URL copied to clipboard (iOS): \(url.absoluteString)")
        #endif
    }

    // MARK: - Proxy

    /// Reload the current URL with library proxy applied.
    ///
    /// This allows users to retry access through their institutional proxy
    /// when they encounter paywalls or access denied pages.
    public func retryWithProxy() {
        #if canImport(WebKit)
        guard let currentURL = currentURL,
              proxyEnabled,
              !libraryProxyURL.isEmpty,
              !isProxied else {
            Logger.pdfBrowser.warning("Cannot retry with proxy: proxy not configured or already proxied")
            return
        }

        let proxiedURLString = libraryProxyURL + currentURL.absoluteString
        guard let proxiedURL = URL(string: proxiedURLString) else {
            Logger.pdfBrowser.error("Failed to create proxied URL from: \(proxiedURLString)")
            return
        }

        isProxied = true
        webView?.load(URLRequest(url: proxiedURL))
        Logger.pdfBrowser.info("Retrying with proxy: \(proxiedURLString)")
        #endif
    }

    // MARK: - PDF Capture

    /// Manually attempt to capture current page content as PDF.
    ///
    /// This is a fallback for when automatic PDF detection fails.
    /// Uses WKWebView.createPDF() to render the current page.
    public func attemptManualCapture() async {
        guard !isCapturing else {
            Logger.pdfBrowser.warning("Manual capture already in progress")
            return
        }

        isCapturing = true
        Logger.pdfBrowser.info("Manual capture requested for: \(self.currentURL?.absoluteString ?? "unknown")")

        await onManualCaptureRequested?()

        isCapturing = false
    }

    /// Save the detected PDF to the library and close the browser
    public func saveDetectedPDF() async {
        guard let data = detectedPDFData else {
            Logger.pdfBrowser.warning("No PDF data to save")
            return
        }

        Logger.pdfBrowser.info("Saving detected PDF: \(self.detectedPDFFilename ?? "unknown"), \(data.count) bytes")

        await onPDFCaptured?(data)

        // Clear the detected PDF
        detectedPDFData = nil
        detectedPDFFilename = nil

        Logger.pdfBrowser.info("PDF saved successfully, closing browser")

        // Auto-close the browser window after saving
        dismiss()
    }

    /// Called when a PDF is detected by the download interceptor
    public func pdfDetected(filename: String, data: Data) {
        detectedPDFFilename = filename
        detectedPDFData = data
        downloadProgress = nil

        Logger.pdfBrowser.info("PDF detected: \(filename), \(data.count) bytes")
    }

    /// Clear any detected PDF without saving
    public func clearDetectedPDF() {
        detectedPDFData = nil
        detectedPDFFilename = nil
        Logger.pdfBrowser.info("Cleared detected PDF")
    }

    // MARK: - State Updates (called by platform view coordinator)

    #if canImport(WebKit)
    /// Update all state from the web view
    public func updateFromWebView(_ webView: WKWebView) {
        currentURL = webView.url
        pageTitle = webView.title ?? ""
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
    }
    #endif

    /// Update state after navigation completes
    public func navigationDidFinish(url: URL?, title: String?) {
        currentURL = url
        pageTitle = title ?? ""
        isLoading = false
        errorMessage = nil

        #if canImport(WebKit)
        canGoBack = webView?.canGoBack ?? false
        canGoForward = webView?.canGoForward ?? false
        #endif

        if let url = url {
            Logger.pdfBrowser.browserNavigation("Loaded", url: url)

            // Check if we can detect a direct PDF URL and auto-navigate
            autoNavigateToDirectPDF(from: url)
        }
    }

    // MARK: - Direct PDF URL Detection

    /// Try to navigate directly to the suggested PDF URL (manual trigger)
    public func tryDirectPDFURL() {
        #if canImport(WebKit)
        guard let pdfURL = suggestedPDFURL else {
            Logger.pdfBrowser.warning("No suggested PDF URL available")
            return
        }

        triedPDFURLs.insert(pdfURL)
        suggestedPDFURL = nil
        webView?.load(URLRequest(url: pdfURL))
        Logger.pdfBrowser.info("Trying direct PDF URL (manual): \(pdfURL.absoluteString)")
        #endif
    }

    /// Auto-navigate to direct PDF URL when pattern is detected
    private func autoNavigateToDirectPDF(from url: URL) {
        #if canImport(WebKit)
        // Don't auto-navigate if we've already tried this pattern
        guard let pdfURL = Self.directPDFURL(for: url),
              !triedPDFURLs.contains(pdfURL) else {
            suggestedPDFURL = nil
            return
        }

        // Mark as tried and navigate automatically
        triedPDFURLs.insert(pdfURL)
        suggestedPDFURL = nil  // No need to show button since we're auto-navigating

        Logger.pdfBrowser.info("Auto-navigating to direct PDF URL: \(pdfURL.absoluteString)")
        webView?.load(URLRequest(url: pdfURL))
        #endif
    }

    /// Publisher-specific PDF URL patterns
    ///
    /// Many publishers use predictable URL patterns for PDFs:
    /// - IOP Science: /article/DOI → /article/DOI/pdf
    /// - APS (Physical Review): /abstract/DOI → /pdf/DOI
    /// - Nature: /articles/ID → /articles/ID.pdf
    /// - MNRAS/Oxford: /article/DOI → /article-pdf/DOI
    /// - A&A/EDP Sciences: /articles/DOI → /articles/DOI/pdf
    ///
    /// Note: Patterns also handle proxied URLs (e.g., nature-com.proxy.edu)
    public static func directPDFURL(for articleURL: URL) -> URL? {
        let urlString = articleURL.absoluteString
        let host = articleURL.host?.lowercased() ?? ""
        let path = articleURL.path

        // Helper to check if host matches a publisher (direct or proxied)
        // Proxies often use hyphenated hostnames: nature.com → nature-com.proxy.edu
        func hostMatches(_ publisher: String) -> Bool {
            let hyphenated = publisher.replacingOccurrences(of: ".", with: "-")
            return host.contains(publisher) || host.contains(hyphenated)
        }

        // IOP Science: iopscience.iop.org/article/DOI → iopscience.iop.org/article/DOI/pdf
        if hostMatches("iopscience.iop.org") && path.hasPrefix("/article/") && !path.hasSuffix("/pdf") {
            return URL(string: urlString + "/pdf")
        }

        // APS (Physical Review): journals.aps.org/*/abstract/DOI → journals.aps.org/*/pdf/DOI
        if hostMatches("journals.aps.org") && path.contains("/abstract/") {
            let pdfPath = path.replacingOccurrences(of: "/abstract/", with: "/pdf/")
            var components = URLComponents(url: articleURL, resolvingAgainstBaseURL: false)
            components?.path = pdfPath
            return components?.url
        }

        // Nature: nature.com/articles/ID → nature.com/articles/ID.pdf
        if hostMatches("nature.com") && path.hasPrefix("/articles/") && !path.hasSuffix(".pdf") {
            return URL(string: urlString + ".pdf")
        }

        // Oxford Academic (MNRAS, etc.): Try appending /pdf to article URL
        // Oxford's PDF URLs have extra path components we can't derive,
        // but appending /pdf to the article URL often redirects correctly
        if hostMatches("academic.oup.com") && path.contains("/article/") && !path.contains("/article-pdf/") && !path.hasSuffix("/pdf") {
            return URL(string: urlString + "/pdf")
        }

        // A&A / EDP Sciences: aanda.org/articles/DOI → aanda.org/articles/DOI/pdf
        if hostMatches("aanda.org") && path.hasPrefix("/articles/") && !path.hasSuffix("/pdf") {
            return URL(string: urlString + "/pdf")
        }

        // Science (AAAS): science.org/doi/... → science.org/doi/pdf/...
        if hostMatches("science.org") && path.hasPrefix("/doi/") && !path.contains("/doi/pdf/") {
            let pdfPath = path.replacingOccurrences(of: "/doi/", with: "/doi/pdf/")
            var components = URLComponents(url: articleURL, resolvingAgainstBaseURL: false)
            components?.path = pdfPath
            return components?.url
        }

        // Wiley: onlinelibrary.wiley.com/doi/... → onlinelibrary.wiley.com/doi/pdfdirect/...
        if hostMatches("onlinelibrary.wiley.com") && path.hasPrefix("/doi/") && !path.contains("/doi/pdfdirect/") && !path.contains("/doi/pdf/") {
            let pdfPath = path.replacingOccurrences(of: "/doi/", with: "/doi/pdfdirect/")
            var components = URLComponents(url: articleURL, resolvingAgainstBaseURL: false)
            components?.path = pdfPath
            return components?.url
        }

        // AIP (Journal of Chemical Physics, etc.): pubs.aip.org/*/article/... → append /pdf
        if hostMatches("pubs.aip.org") && path.contains("/article/") && !path.hasSuffix("/pdf") {
            return URL(string: urlString + "/pdf")
        }

        // Annual Reviews: annualreviews.org/doi/... → annualreviews.org/doi/pdf/...
        if hostMatches("annualreviews.org") && path.hasPrefix("/doi/") && !path.contains("/doi/pdf/") {
            let pdfPath = path.replacingOccurrences(of: "/doi/", with: "/doi/pdf/")
            var components = URLComponents(url: articleURL, resolvingAgainstBaseURL: false)
            components?.path = pdfPath
            return components?.url
        }

        // PNAS: pnas.org/doi/... → pnas.org/doi/pdf/...
        if hostMatches("pnas.org") && path.hasPrefix("/doi/") && !path.contains("/doi/pdf/") {
            let pdfPath = path.replacingOccurrences(of: "/doi/", with: "/doi/pdf/")
            var components = URLComponents(url: articleURL, resolvingAgainstBaseURL: false)
            components?.path = pdfPath
            return components?.url
        }

        // Royal Society: royalsocietypublishing.org/doi/... → royalsocietypublishing.org/doi/pdf/...
        if hostMatches("royalsocietypublishing.org") && path.hasPrefix("/doi/") && !path.contains("/doi/pdf/") {
            let pdfPath = path.replacingOccurrences(of: "/doi/", with: "/doi/pdf/")
            var components = URLComponents(url: articleURL, resolvingAgainstBaseURL: false)
            components?.path = pdfPath
            return components?.url
        }

        return nil
    }

    /// Update state when navigation starts
    public func navigationDidStart() {
        isLoading = true
        errorMessage = nil
    }

    /// Update state when navigation fails
    public func navigationDidFail(error: Error) {
        isLoading = false
        errorMessage = error.localizedDescription

        Logger.pdfBrowser.error("Navigation failed: \(error.localizedDescription)")
    }

    /// Update download progress
    public func updateDownloadProgress(_ progress: Double) {
        downloadProgress = progress
    }

    /// Called when download starts
    public func downloadDidStart(filename: String) {
        downloadProgress = 0
        Logger.pdfBrowser.info("Download started: \(filename)")
    }

    /// Called when download fails
    public func downloadDidFail(error: Error) {
        downloadProgress = nil
        errorMessage = "Download failed: \(error.localizedDescription)"

        Logger.pdfBrowser.error("Download failed: \(error.localizedDescription)")
    }

    // MARK: - Dismiss

    /// Dismiss the browser window
    public func dismiss() {
        Logger.pdfBrowser.info("Dismissing browser")
        onDismiss?()
    }
}
