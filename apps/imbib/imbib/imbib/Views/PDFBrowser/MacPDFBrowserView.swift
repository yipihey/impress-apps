//
//  MacPDFBrowserView.swift
//  imbib
//
//  Created by Claude on 2026-01-06.
//

#if os(macOS)
import SwiftUI
import WebKit
import PublicationManagerCore
import OSLog

// MARK: - Main Browser View

/// macOS-specific PDF browser view with WKWebView.
///
/// Provides full browser functionality for navigating publisher
/// authentication flows and capturing PDFs.
struct MacPDFBrowserView: View {

    // MARK: - Properties

    @Bindable var viewModel: PDFBrowserViewModel
    @Environment(\.dismiss) private var dismiss

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Header with publication info
            publicationHeader

            Divider()

            // Toolbar
            PDFBrowserToolbar(viewModel: viewModel)

            Divider()

            // WebView
            MacWebViewRepresentable(viewModel: viewModel)

            // Status bar
            PDFBrowserStatusBar(viewModel: viewModel)
        }
        .frame(minWidth: 900, minHeight: 700)
        .onDisappear {
            viewModel.onDismiss?()
        }
    }

    // MARK: - Publication Header

    @ViewBuilder
    private var publicationHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.publication.title ?? "Unknown Title")
                    .font(.headline)
                    .lineLimit(1)

                let authors = viewModel.publication.authorString
                if !authors.isEmpty {
                    Text(authors)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Button("Done") {
                dismiss()
            }
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

// MARK: - Custom WKWebView with Context Menu

/// Custom WKWebView that adds "Save PDF to Library" to the right-click context menu.
///
/// This provides a reliable fallback when automatic PDF detection fails.
/// If the user can see "Open with Preview" in the native context menu, they can
/// also use our "Save PDF to Library" option.
class PDFBrowserWebView: WKWebView {

    /// Reference to the view model for triggering PDF save actions
    weak var viewModel: PDFBrowserViewModel?

    /// Reference to the coordinator for accessing fetch helpers
    weak var coordinator: MacWebViewRepresentable.Coordinator?

    // MARK: - Context Menu Customization

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)

        // Add separator before our custom items
        menu.addItem(NSMenuItem.separator())

        // "Save PDF to Library" - fetches current URL and saves if it's a PDF
        let saveItem = NSMenuItem(
            title: "Save PDF to Library",
            action: #selector(savePDFToLibrary(_:)),
            keyEquivalent: ""
        )
        saveItem.target = self
        menu.addItem(saveItem)

        // "Capture Page as PDF" - renders the full page as PDF (like print to PDF)
        let captureItem = NSMenuItem(
            title: "Capture Page as PDF",
            action: #selector(capturePageAsPDF(_:)),
            keyEquivalent: ""
        )
        captureItem.target = self
        menu.addItem(captureItem)
    }

    // MARK: - Context Menu Actions

    @objc private func savePDFToLibrary(_ sender: Any?) {
        guard let url = self.url else {
            Logger.pdfBrowser.warning("Save PDF: No URL available")
            return
        }

        Logger.pdfBrowser.info("Context menu: Save PDF to Library from \(url.absoluteString)")

        Task { @MainActor in
            await fetchAndSavePDF(from: url)
        }
    }

    @objc private func capturePageAsPDF(_ sender: Any?) {
        Logger.pdfBrowser.info("Context menu: Capture Page as PDF")

        Task { @MainActor in
            await viewModel?.attemptManualCapture()
        }
    }

    // MARK: - PDF Fetch

    /// Fetch the current URL with cookies and save if it's a PDF
    @MainActor
    private func fetchAndSavePDF(from url: URL) async {
        guard let viewModel = viewModel else {
            Logger.pdfBrowser.error("Save PDF: No viewModel")
            return
        }

        // Show that we're working
        viewModel.isCapturing = true
        defer { viewModel.isCapturing = false }

        do {
            let data = try await fetchWithCookies(url: url)

            // Check if it's a PDF by magic bytes
            if isPDF(data: data) {
                let filename = generateFilename(from: url)
                viewModel.detectedPDFFilename = filename
                viewModel.detectedPDFData = data
                Logger.pdfBrowser.info("Context menu: PDF saved - \(filename), \(data.count) bytes")
            } else {
                // URLSession got HTML instead of PDF - try WebKit download
                Logger.pdfBrowser.info("Context menu: URLSession returned non-PDF, trying WebKit download...")
                print("🔶 [ContextMenu] URLSession returned non-PDF, trying WebKit download...")

                // Use coordinator's WebKit download method
                if let coordinator = self.coordinator {
                    await coordinator.triggerWebKitDownload(url: url)
                    // Wait for download to complete
                    try? await Task.sleep(nanoseconds: 3_000_000_000)  // 3 seconds

                    if viewModel.detectedPDFData != nil {
                        Logger.pdfBrowser.info("Context menu: WebKit download succeeded!")
                        print("🔶 [ContextMenu] WebKit download succeeded!")
                    } else {
                        let preview = String(data: data.prefix(100), encoding: .utf8) ?? "binary"
                        Logger.pdfBrowser.warning("Context menu: Not a PDF. Preview: \(preview.prefix(50))")
                        viewModel.errorMessage = "Current page is not a PDF (server returned HTML)"
                    }
                } else {
                    let preview = String(data: data.prefix(100), encoding: .utf8) ?? "binary"
                    Logger.pdfBrowser.warning("Context menu: Not a PDF. Preview: \(preview.prefix(50))")
                    viewModel.errorMessage = "Current page is not a PDF"
                }
            }
        } catch {
            Logger.pdfBrowser.error("Context menu: Fetch failed - \(error.localizedDescription)")
            viewModel.errorMessage = "Failed to fetch PDF: \(error.localizedDescription)"
        }
    }

    /// Fetch URL data using cookies from the webView's data store
    private func fetchWithCookies(url: URL) async throws -> Data {
        let dataStore = self.configuration.websiteDataStore
        let cookies = await dataStore.httpCookieStore.allCookies()

        let config = URLSessionConfiguration.default
        config.httpCookieStorage = HTTPCookieStorage()
        for cookie in cookies {
            config.httpCookieStorage?.setCookie(cookie)
        }

        config.httpAdditionalHeaders = [
            "Accept": "application/pdf,*/*",
            "User-Agent": self.value(forKey: "userAgent") as? String ?? "Mozilla/5.0"
        ]

        let session = URLSession(configuration: config)
        Logger.pdfBrowser.debug("Fetching with \(cookies.count) cookies")

        let (data, response) = try await session.data(from: url)

        if let httpResponse = response as? HTTPURLResponse {
            Logger.pdfBrowser.debug("Response: \(httpResponse.statusCode), type: \(httpResponse.mimeType ?? "unknown")")
        }

        return data
    }

    /// Check if data starts with PDF magic bytes (%PDF)
    private func isPDF(data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        return data.prefix(4) == Data([0x25, 0x50, 0x44, 0x46])  // %PDF
    }

    /// Generate a filename for the PDF
    private func generateFilename(from url: URL) -> String {
        let lastComponent = url.lastPathComponent
        if lastComponent.lowercased().hasSuffix(".pdf") {
            return lastComponent
        }
        if !lastComponent.isEmpty && lastComponent != "/" {
            return "\(lastComponent).pdf"
        }

        // Fall back to publication info if available
        if let pub = viewModel?.publication {
            let author = pub.authorString.split(separator: ",").first.map(String.init) ?? "Unknown"
            let year = pub.year > 0 ? "\(pub.year)" : "NoYear"
            let titleWord = pub.title?.split(separator: " ").first.map(String.init) ?? "Document"
            return "\(author)_\(year)_\(titleWord).pdf"
        }

        return "document.pdf"
    }
}

// MARK: - WebView Representable

/// NSViewRepresentable wrapper for WKWebView.
struct MacWebViewRepresentable: NSViewRepresentable {

    @Bindable var viewModel: PDFBrowserViewModel

    // MARK: - NSViewRepresentable

    func makeNSView(context: Context) -> WKWebView {
        Logger.pdfBrowser.info("Creating PDFBrowserWebView for PDF browser")

        // Get configuration with shared process pool for cookie persistence
        let config = PDFBrowserSession.shared.webViewConfiguration()

        // Enable developer extras for debugging
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")

        // Use custom subclass that adds context menu items
        let webView = PDFBrowserWebView(frame: .zero, configuration: config)
        webView.viewModel = viewModel  // Set reference for context menu actions
        webView.coordinator = context.coordinator
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true

        // Enable text selection and standard Edit menu commands
        webView.allowsLinkPreview = true

        // Make webView first responder to enable copy/paste
        DispatchQueue.main.async {
            webView.window?.makeFirstResponder(webView)
        }

        // Store reference in view model
        viewModel.webView = webView

        // Wire up manual capture callback
        let coordinator = context.coordinator
        viewModel.onManualCaptureRequested = {
            await coordinator.captureCurrentContent()
        }

        // Load initial URL
        Logger.pdfBrowser.info("Loading initial URL: \(viewModel.initialURL.absoluteString)")
        webView.load(URLRequest(url: viewModel.initialURL))

        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        // No updates needed - state flows through coordinator
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {

        let viewModel: PDFBrowserViewModel
        let interceptor: PDFDownloadInterceptor

        // Track current download
        private var downloadData = Data()
        private var downloadFilename: String = ""
        private var downloadExpectedLength: Int64 = 0
        private var downloadTempFileURL: URL?

        // Track redirect chain for debugging
        private var redirectChain: [URL] = []

        init(viewModel: PDFBrowserViewModel) {
            self.viewModel = viewModel
            self.interceptor = PDFDownloadInterceptor()
            super.init()

            // Wire up interceptor callbacks
            interceptor.onPDFDownloaded = { [weak self] filename, data in
                Task { @MainActor in
                    self?.viewModel.detectedPDFFilename = filename
                    self?.viewModel.detectedPDFData = data
                    Logger.pdfBrowser.info("PDF detected: \(filename), \(data.count) bytes")
                }
            }

            interceptor.onDownloadProgress = { [weak self] progress in
                Task { @MainActor in
                    self?.viewModel.downloadProgress = progress
                }
            }

            interceptor.onDownloadFailed = { [weak self] error in
                Task { @MainActor in
                    self?.viewModel.errorMessage = "Download failed: \(error.localizedDescription)"
                    self?.viewModel.downloadProgress = nil
                }
            }
        }

        // MARK: - Public Download Trigger

        /// Trigger a download using WKWebView's session.
        /// Called from PDFBrowserWebView context menu when URLSession fails.
        @MainActor
        func triggerWebKitDownload(url: URL) async {
            guard let webView = viewModel.webView else {
                Logger.pdfBrowser.error("[triggerWebKitDownload] No webView available")
                return
            }
            await startWebKitDownload(webView: webView, url: url)
        }

        // MARK: - WKNavigationDelegate

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            Task { @MainActor in
                viewModel.isLoading = true
                viewModel.updateFromWebView(webView)
                Logger.pdfBrowser.browserNavigation("Started", url: webView.url ?? viewModel.initialURL)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // These calls must be outside Task to avoid priority inversion warnings
            webView.window?.makeFirstResponder(webView)
            Logger.pdfBrowser.browserNavigation("Finished", url: webView.url ?? viewModel.initialURL)

            // Log redirect chain for debugging
            if !redirectChain.isEmpty {
                Logger.pdfBrowser.info("=== REDIRECT CHAIN ===")
                for (index, url) in redirectChain.enumerated() {
                    Logger.pdfBrowser.info("[\(index)] \(url.absoluteString)")
                }
                Logger.pdfBrowser.info("Final URL: \(webView.url?.absoluteString ?? "nil")")
                Logger.pdfBrowser.info("=== END REDIRECT CHAIN ===")
            }
            // Clear for next navigation
            let chainCopy = redirectChain
            redirectChain = []

            Task { @MainActor in
                print("🔵 [Coordinator] didFinish Task started for URL: \(webView.url?.absoluteString ?? "nil")")
                viewModel.updateFromWebView(webView)
                // Call navigationDidFinish which triggers auto-navigation to PDF URLs
                viewModel.navigationDidFinish(url: webView.url, title: webView.title)

                // Fast path: If URL looks like a PDF, immediately try to fetch it
                if let url = webView.url {
                    let isPDFURL = self.looksLikePDFURL(url)
                    print("🔵 [Coordinator] looksLikePDFURL(\(url.path.suffix(30))...) = \(isPDFURL)")
                    if isPDFURL {
                        print("🔵 [Coordinator] URL looks like PDF, trying immediate fetch")
                        await self.immediatePDFFetch(webView: webView, url: url)
                        // If we got the PDF, we're done
                        if self.viewModel.detectedPDFData != nil {
                            print("🔵 [Coordinator] Immediate fetch succeeded! Data size: \(self.viewModel.detectedPDFData?.count ?? 0)")
                            return
                        }
                        print("🔵 [Coordinator] Immediate fetch did not get PDF")
                    }
                }

                print("🔵 [Coordinator] Calling checkForPDFContent")
                checkForPDFContent(webView)

                // Proactive PDF check - fetch URL and check magic bytes
                // Run immediately, then schedule retries to catch slow-loading PDFs
                print("🔵 [Coordinator] Calling proactivePDFCheck")
                await proactivePDFCheck(webView, redirectChain: chainCopy, attempt: 1)
                print("🔵 [Coordinator] proactivePDFCheck returned, detectedPDFData: \(self.viewModel.detectedPDFData != nil)")
            }
        }

        /// Immediately fetch a URL that looks like a PDF (fast path for /pdf URLs)
        @MainActor
        private func immediatePDFFetch(webView: WKWebView, url: URL) async {
            print("🟢 [ImmediateFetch] Starting for: \(url.absoluteString)")

            do {
                let data = try await fetchPDFWithWebViewCookies(url: url, webView: webView)
                print("🟢 [ImmediateFetch] Fetched \(data.count) bytes")

                if isPDF(data: data) {
                    print("🟢 [ImmediateFetch] ✓ Valid PDF detected!")
                    let filename = generateFilename(from: url)
                    viewModel.detectedPDFFilename = filename
                    viewModel.detectedPDFData = data
                } else {
                    let magicBytes = data.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " ")
                    print("🟢 [ImmediateFetch] ✗ Not a PDF. Magic bytes: \(magicBytes)")

                    // If it's HTML, try with explicit Accept header
                    if data.prefix(1) == Data([0x3C]) {
                        print("🟢 [ImmediateFetch] Got HTML, trying with Accept: application/pdf")
                        let pdfData = try await fetchPDFWithExplicitAccept(url: url, webView: webView)
                        if isPDF(data: pdfData) {
                            print("🟢 [ImmediateFetch] ✓ Got PDF with explicit Accept header!")
                            let filename = generateFilename(from: url)
                            viewModel.detectedPDFFilename = filename
                            viewModel.detectedPDFData = pdfData
                        }
                    }
                }
            } catch {
                print("🟢 [ImmediateFetch] ✗ Fetch failed: \(error.localizedDescription)")
            }
        }

        /// Proactively check if the loaded content is a PDF by fetching and checking magic bytes.
        /// This catches cases where WebKit detected a PDF but our response handler didn't.
        ///
        /// - Parameters:
        ///   - webView: The WKWebView displaying content
        ///   - redirectChain: URLs from the redirect chain
        ///   - attempt: Current attempt number (1-based). Will retry up to 4 times with increasing delays.
        @MainActor
        private func proactivePDFCheck(_ webView: WKWebView, redirectChain: [URL], attempt: Int = 1) async {
            Logger.pdfBrowser.info("[ProactiveCheck] ENTERED - attempt \(attempt)")

            let maxAttempts = 4
            let delaysMs = [0, 1000, 2000, 3000]  // Delays before each attempt

            // Skip if we already detected a PDF
            guard viewModel.detectedPDFData == nil else {
                Logger.pdfBrowser.info("[ProactiveCheck] Skipped - PDF already detected")
                return
            }

            guard let url = webView.url else {
                Logger.pdfBrowser.info("[ProactiveCheck] Skipped - no URL")
                return
            }

            // Wait before this attempt (except for first attempt)
            if attempt > 1 && attempt <= delaysMs.count {
                let delay = delaysMs[attempt - 1]
                Logger.pdfBrowser.debug("Waiting \(delay)ms before attempt \(attempt)...")
                try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)

                // Check again if PDF was detected during the wait
                guard viewModel.detectedPDFData == nil else {
                    Logger.pdfBrowser.debug("PDF detected during wait, skipping attempt \(attempt)")
                    return
                }
            }

            Logger.pdfBrowser.info("=== PROACTIVE PDF CHECK (attempt \(attempt) of \(maxAttempts)) ===")
            Logger.pdfBrowser.info("Checking URL: \(url.absoluteString)")

            // Check 1: Detect if WebKit is displaying a native PDF using plugin detection
            let isNativeDisplay = await detectWebKitNativePDFDisplay(webView)
            if isNativeDisplay {
                Logger.pdfBrowser.info("✓ WebKit native PDF display detected!")
                print("🔷 [ProactiveCheck] WebKit IS showing a PDF natively!")

                // First try: fetch with explicit PDF Accept header (works for some servers)
                do {
                    let data = try await fetchPDFWithExplicitAccept(url: url, webView: webView)
                    if isPDF(data: data) {
                        Logger.pdfBrowser.info("✓ PROACTIVE CHECK FOUND PDF (native display)!")
                        let filename = generateFilename(from: url)
                        viewModel.detectedPDFFilename = filename
                        viewModel.detectedPDFData = data
                        Logger.pdfBrowser.info("=== END PROACTIVE PDF CHECK (SUCCESS) ===")
                        return
                    } else {
                        print("🔷 [ProactiveCheck] URLSession returned non-PDF data, trying WKWebView download...")
                        // URLSession can't access authenticated session - use WebKit's download instead
                        // This uses the same session that displayed the PDF
                        await startWebKitDownload(webView: webView, url: url)
                        // Give download time to complete
                        try? await Task.sleep(nanoseconds: 2_000_000_000)  // 2 seconds
                        if viewModel.detectedPDFData != nil {
                            print("🔷 [ProactiveCheck] WKWebView download succeeded!")
                            Logger.pdfBrowser.info("=== END PROACTIVE PDF CHECK (SUCCESS via WebKit download) ===")
                            return
                        }
                    }
                } catch {
                    Logger.pdfBrowser.debug("Native PDF fetch failed: \(error.localizedDescription)")
                    print("🔷 [ProactiveCheck] URLSession fetch failed, trying WKWebView download...")
                    // Fallback: try WebKit download
                    await startWebKitDownload(webView: webView, url: url)
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if viewModel.detectedPDFData != nil {
                        print("🔷 [ProactiveCheck] WKWebView download succeeded!")
                        Logger.pdfBrowser.info("=== END PROACTIVE PDF CHECK (SUCCESS via WebKit download) ===")
                        return
                    }
                }
            }

            // Check 2: Try fetching the current URL with cookies
            do {
                let data = try await fetchPDFWithWebViewCookies(url: url, webView: webView)

                Logger.pdfBrowser.info("Fetched \(data.count) bytes")

                // Check magic bytes
                if isPDF(data: data) {
                    Logger.pdfBrowser.info("✓ PROACTIVE CHECK FOUND PDF!")
                    let filename = generateFilename(from: url)
                    viewModel.detectedPDFFilename = filename
                    viewModel.detectedPDFData = data
                    Logger.pdfBrowser.info("=== END PROACTIVE PDF CHECK (SUCCESS) ===")
                    return
                } else {
                    // Log what we got instead
                    let magicBytes = data.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " ")
                    Logger.pdfBrowser.info("✗ Not a PDF. Magic bytes: \(magicBytes)")

                    // If it looks like HTML, log a preview
                    if data.prefix(1) == Data([0x3C]) {  // '<'
                        if let preview = String(data: data.prefix(200), encoding: .utf8) {
                            Logger.pdfBrowser.info("Content preview (HTML?): \(preview.prefix(100))")
                        }
                    }
                }
            } catch {
                Logger.pdfBrowser.info("✗ Fetch failed: \(error.localizedDescription)")
            }

            // Check 3: Try with explicit PDF Accept header (content negotiation)
            if looksLikePDFURL(url) {
                Logger.pdfBrowser.info("URL looks like PDF, trying explicit Accept: application/pdf")
                do {
                    let data = try await fetchPDFWithExplicitAccept(url: url, webView: webView)
                    if isPDF(data: data) {
                        Logger.pdfBrowser.info("✓ FOUND PDF with explicit Accept header!")
                        let filename = generateFilename(from: url)
                        viewModel.detectedPDFFilename = filename
                        viewModel.detectedPDFData = data
                        Logger.pdfBrowser.info("=== END PROACTIVE PDF CHECK (SUCCESS) ===")
                        return
                    }
                } catch {
                    Logger.pdfBrowser.debug("Explicit Accept fetch failed: \(error.localizedDescription)")
                }
            }

            // Check 4: Try other URLs in the redirect chain
            for chainURL in redirectChain where chainURL != url {
                Logger.pdfBrowser.info("Trying redirect chain URL: \(chainURL.absoluteString)")
                do {
                    let data = try await fetchPDFWithWebViewCookies(url: chainURL, webView: webView)
                    if isPDF(data: data) {
                        Logger.pdfBrowser.info("✓ FOUND PDF in redirect chain!")
                        let filename = generateFilename(from: chainURL)
                        viewModel.detectedPDFFilename = filename
                        viewModel.detectedPDFData = data
                        Logger.pdfBrowser.info("=== END PROACTIVE PDF CHECK (SUCCESS from chain) ===")
                        return
                    }
                } catch {
                    Logger.pdfBrowser.debug("Chain URL fetch failed: \(error.localizedDescription)")
                }
            }

            Logger.pdfBrowser.info("=== END PROACTIVE PDF CHECK (attempt \(attempt) - no PDF found) ===")

            // Schedule retry if we haven't exceeded max attempts
            if attempt < maxAttempts {
                Logger.pdfBrowser.info("Scheduling retry attempt \(attempt + 1) of \(maxAttempts)...")
                await proactivePDFCheck(webView, redirectChain: redirectChain, attempt: attempt + 1)
            } else {
                Logger.pdfBrowser.info("All \(maxAttempts) attempts completed - PDF not detected automatically")
                Logger.pdfBrowser.info("User can still right-click and choose 'Save PDF to Library' if a PDF is visible")
            }
        }

        /// Detect if WebKit is displaying a PDF using its native PDF plugin.
        /// Safari/WebKit uses a specific DOM structure for native PDF display.
        private func detectWebKitNativePDFDisplay(_ webView: WKWebView) async -> Bool {
            let script = """
            (function() {
                // Check 1: Safari's PDF plugin creates a minimal DOM with embed element
                var embed = document.querySelector('embed[type="application/pdf"]');
                if (embed) return true;

                // Check 2: Safari's PDF plugin element might not have type set
                // but takes up the full viewport
                var embeds = document.getElementsByTagName('embed');
                if (embeds.length === 1) {
                    var embed = embeds[0];
                    var rect = embed.getBoundingClientRect();
                    // If embed covers most of the viewport, it's likely a PDF
                    if (rect.width > window.innerWidth * 0.9 &&
                        rect.height > window.innerHeight * 0.9) {
                        return true;
                    }
                }

                // Check 3: Chrome/Edge PDF plugin uses shadow DOM with pdf-viewer
                if (document.querySelector('pdf-viewer') ||
                    document.querySelector('embed#plugin')) {
                    return true;
                }

                // Check 4: Very minimal body (Safari PDF display)
                if (document.body && document.body.children.length <= 2) {
                    var text = document.body.innerText || '';
                    // Native PDF viewers have almost no text content
                    if (text.trim().length < 50) {
                        return true;
                    }
                }

                // Check 5: Check if the page has no significant HTML structure
                // (common for native PDF display)
                var html = document.documentElement.outerHTML;
                if (html.length < 1000) {
                    return true;
                }

                return false;
            })()
            """

            do {
                let result = try await webView.evaluateJavaScript(script)
                let isNative = result as? Bool ?? false
                Logger.pdfBrowser.debug("Native PDF display detection: \(isNative)")
                print("🔷 Native PDF display detection: \(isNative)")
                return isNative
            } catch {
                Logger.pdfBrowser.debug("Native PDF detection script failed: \(error.localizedDescription)")
                return false
            }
        }

        /// Start a download using WKWebView's internal download mechanism.
        /// This uses WebKit's existing session state (cookies, auth) which URLSession can't access.
        ///
        /// When proxy authentication is session-bound (not just cookie-based), only WebKit
        /// can access the authenticated content. This method triggers a download through
        /// WebKit, capturing the PDF data via WKDownloadDelegate.
        @MainActor
        private func startWebKitDownload(webView: WKWebView, url: URL) async {
            print("🔷 [WebKitDownload] Starting download for: \(url.absoluteString)")
            Logger.pdfBrowser.info("[WebKitDownload] Starting download via WKWebView.startDownload")

            var request = URLRequest(url: url)
            // Set Accept header to prefer PDF
            request.setValue("application/pdf,*/*", forHTTPHeaderField: "Accept")

            // Use WKWebView's startDownload API (macOS 11.3+, iOS 14.5+)
            // This downloads through WebKit's session, preserving auth state
            let download = await webView.startDownload(using: request)
            download.delegate = self
            print("🔷 [WebKitDownload] Download started successfully")
            Logger.pdfBrowser.info("[WebKitDownload] Download initiated")
        }

        /// Fetch URL with explicit Accept: application/pdf header.
        /// This handles content negotiation where servers return different formats based on Accept header.
        private func fetchPDFWithExplicitAccept(url: URL, webView: WKWebView) async throws -> Data {
            let dataStore = webView.configuration.websiteDataStore
            let cookies = await dataStore.httpCookieStore.allCookies()

            let config = URLSessionConfiguration.default
            config.httpCookieStorage = HTTPCookieStorage()
            for cookie in cookies {
                config.httpCookieStorage?.setCookie(cookie)
            }

            // Explicitly request PDF format
            config.httpAdditionalHeaders = [
                "Accept": "application/pdf",
                "User-Agent": webView.value(forKey: "userAgent") as? String ?? "Mozilla/5.0"
            ]

            let session = URLSession(configuration: config)

            Logger.pdfBrowser.debug("Fetching with explicit Accept: application/pdf and \(cookies.count) cookies")

            let (data, response) = try await session.data(from: url)

            if let httpResponse = response as? HTTPURLResponse {
                Logger.pdfBrowser.debug("Response status: \(httpResponse.statusCode), content-type: \(httpResponse.mimeType ?? "unknown")")
            }

            return data
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            Task { @MainActor in
                viewModel.isLoading = false
                viewModel.errorMessage = error.localizedDescription
                Logger.pdfBrowser.error("Navigation failed: \(error.localizedDescription)")
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            Task { @MainActor in
                viewModel.isLoading = false
                // Ignore cancelled navigations (user clicked another link)
                if (error as NSError).code != NSURLErrorCancelled {
                    viewModel.errorMessage = error.localizedDescription
                    Logger.pdfBrowser.error("Provisional navigation failed: \(error.localizedDescription)")
                }
            }
        }

        func webView(_ webView: WKWebView,
                    decidePolicyFor navigationAction: WKNavigationAction,
                    decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {

            // Track redirect chain for debugging
            if let url = navigationAction.request.url {
                redirectChain.append(url)
                Logger.pdfBrowser.debug("Navigation action: \(navigationAction.navigationType.rawValue) -> \(url.absoluteString)")
            }

            // Check if this is a download request
            if navigationAction.shouldPerformDownload {
                decisionHandler(.download)
                return
            }

            // Check for PDF content type hint in URL
            if let url = navigationAction.request.url {
                if looksLikePDFURL(url) {
                    Logger.pdfBrowser.info("Detected PDF URL pattern, initiating download: \(url.absoluteString)")
                    decisionHandler(.download)
                    return
                }
            }

            decisionHandler(.allow)
        }

        /// Check if URL looks like it points to a PDF based on common patterns
        private func looksLikePDFURL(_ url: URL) -> Bool {
            let urlString = url.absoluteString.lowercased()
            let path = url.path.lowercased()

            // Direct .pdf extension
            if urlString.hasSuffix(".pdf") || path.hasSuffix(".pdf") {
                return true
            }

            // Path ending in /pdf (IOP Science, many publishers)
            if path.hasSuffix("/pdf") {
                return true
            }

            // Common PDF path patterns used by publishers
            // e.g., /pdf/10.1103/..., /pdfft/..., /doi/pdf/...
            let pdfPathPatterns = [
                "/pdf/",           // APS, many publishers
                "/pdfft/",         // Some publishers
                "/doi/pdf/",       // Wiley, others
                "/pdfdirect/",     // Elsevier
                "/article/pdf/",   // Various
                "/fulltext/pdf/",  // Various
                "/download",       // SPIE, many publishers (case-insensitive)
                "/getpdf",         // Some publishers
                "/fetchpdf",       // Some publishers
                "/viewpdf",        // Some publishers
                "/epdf/",          // Nature, Springer
            ]

            for pattern in pdfPathPatterns {
                if path.contains(pattern) {
                    return true
                }
            }

            // Check query parameters for download hints
            if let query = url.query?.lowercased() {
                // PDF format specified
                if query.contains("format=pdf") || query.contains("type=pdf") {
                    return true
                }
                // Download with PDF hint
                if query.contains("pdf") && query.contains("download") {
                    return true
                }
                // DOI in query often indicates a paper download
                if query.contains("doi") || query.contains("urlid") {
                    // Could be a PDF download endpoint
                    return true
                }
            }

            return false
        }

        func webView(_ webView: WKWebView,
                    decidePolicyFor navigationResponse: WKNavigationResponse,
                    decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            let url = navigationResponse.response.url
            let mimeType = navigationResponse.response.mimeType?.lowercased() ?? ""
            let expectedLength = navigationResponse.response.expectedContentLength

            // === DIAGNOSTIC LOGGING ===
            print("🟡 === RESPONSE ANALYSIS ===")
            print("🟡 URL: \(url?.absoluteString ?? "nil")")
            print("🟡 MIME type: \(mimeType.isEmpty ? "EMPTY" : mimeType)")
            print("🟡 Expected length: \(expectedLength)")
            print("🟡 isForMainFrame: \(navigationResponse.isForMainFrame)")
            print("🟡 looksLikePDFURL: \(url.map { looksLikePDFURL($0) } ?? false)")

            if let httpResponse = navigationResponse.response as? HTTPURLResponse {
                Logger.pdfBrowser.info("HTTP Status: \(httpResponse.statusCode)")
                // Log key headers
                let keyHeaders = ["Content-Type", "Content-Disposition", "Content-Length", "X-Content-Type-Options"]
                for header in keyHeaders {
                    if let value = httpResponse.allHeaderFields[header] {
                        Logger.pdfBrowser.info("Header[\(header)]: \(String(describing: value))")
                    }
                }
            }
            Logger.pdfBrowser.info("=== END RESPONSE ANALYSIS ===")

            // Check if response is a PDF by MIME type
            if mimeType == "application/pdf" || mimeType == "application/x-pdf" {
                Logger.pdfBrowser.info("Response is PDF (by MIME), downloading: \(url?.absoluteString ?? "unknown")")
                decisionHandler(.download)
                return
            }

            // Check Content-Disposition header for attachment
            if let httpResponse = navigationResponse.response as? HTTPURLResponse {
                if let contentDisposition = httpResponse.allHeaderFields["Content-Disposition"] as? String {
                    if contentDisposition.contains("attachment") {
                        Logger.pdfBrowser.info("Response has attachment disposition, downloading")
                        decisionHandler(.download)
                        return
                    }
                    // Check if filename in Content-Disposition ends with .pdf
                    if contentDisposition.lowercased().contains(".pdf") {
                        Logger.pdfBrowser.info("Response has PDF filename in Content-Disposition, downloading")
                        decisionHandler(.download)
                        return
                    }
                }

                // Check Content-Type header directly (sometimes mimeType doesn't match)
                if let contentType = httpResponse.allHeaderFields["Content-Type"] as? String {
                    let ctLower = contentType.lowercased()
                    if ctLower.contains("application/pdf") || ctLower.contains("application/x-pdf") {
                        Logger.pdfBrowser.info("Response is PDF (by Content-Type header), downloading")
                        decisionHandler(.download)
                        return
                    }
                }
            }

            // If URL pattern suggests PDF and response is binary/octet-stream, try downloading
            if let url = url, looksLikePDFURL(url) {
                if mimeType == "application/octet-stream" || mimeType.isEmpty {
                    Logger.pdfBrowser.info("URL suggests PDF and response is binary, attempting download: \(url.absoluteString)")
                    decisionHandler(.download)
                    return
                }
            }

            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
            download.delegate = self
            Logger.pdfBrowser.info("Navigation became download")
        }

        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
            download.delegate = self
            Logger.pdfBrowser.info("Response became download")
        }

        // MARK: - WKDownloadDelegate

        func download(_ download: WKDownload,
                     decideDestinationUsing response: URLResponse,
                     suggestedFilename: String) async -> URL? {
            downloadFilename = suggestedFilename
            downloadExpectedLength = response.expectedContentLength
            downloadData = Data()

            Logger.pdfBrowser.browserDownload("Started", filename: suggestedFilename)

            Task { @MainActor in
                viewModel.downloadProgress = 0
            }

            // Always use a temp file - returning nil causes sandbox extension errors
            let tempDir = FileManager.default.temporaryDirectory
            self.downloadTempFileURL = tempDir.appendingPathComponent(UUID().uuidString + ".download")
            Logger.pdfBrowser.debug("Using temp file: \(self.downloadTempFileURL?.path ?? "nil")")
            return self.downloadTempFileURL
        }

        func download(_ download: WKDownload, didReceive data: Data) {
            downloadData.append(data)
            if downloadExpectedLength > 0 {
                let progress = Double(downloadData.count) / Double(downloadExpectedLength)
                Task { @MainActor in
                    viewModel.downloadProgress = progress
                }
            }
        }

        func downloadDidFinish(_ download: WKDownload) {
            // Read data from temp file (WKDownload writes directly to file, not via didReceive)
            let finalData: Data
            if let tempURL = downloadTempFileURL {
                do {
                    finalData = try Data(contentsOf: tempURL)
                    // Clean up temp file
                    try? FileManager.default.removeItem(at: tempURL)
                    downloadTempFileURL = nil
                } catch {
                    Logger.pdfBrowser.error("Failed to read temp file: \(error.localizedDescription)")
                    Task { @MainActor in
                        viewModel.errorMessage = "Failed to read downloaded file"
                        viewModel.downloadProgress = nil
                    }
                    return
                }
            } else {
                // Fallback to in-memory data (shouldn't happen with current code)
                finalData = downloadData
            }

            Logger.pdfBrowser.browserDownload("Finished", filename: downloadFilename, bytes: finalData.count)

            // Check if it's a PDF
            if isPDF(data: finalData) {
                Task { @MainActor in
                    viewModel.detectedPDFFilename = downloadFilename
                    viewModel.detectedPDFData = finalData
                    viewModel.downloadProgress = nil
                }
            } else {
                // Log diagnostic info to help debug why it's not a PDF
                logDownloadDiagnostics(data: finalData, filename: downloadFilename)

                Task { @MainActor in
                    viewModel.errorMessage = "Downloaded file is not a PDF"
                    viewModel.downloadProgress = nil
                }
            }

            downloadData = Data()
        }

        /// Log detailed diagnostics when a download is not recognized as PDF
        private func logDownloadDiagnostics(data: Data, filename: String) {
            // Magic bytes (first 16 bytes in hex)
            let magicBytes = data.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")

            // Check if it looks like HTML
            let isHTML = data.prefix(1) == Data([0x3C]) // starts with '<'
            let isHTMLDoctype = String(data: data.prefix(15), encoding: .utf8)?.uppercased().contains("DOCTYPE") ?? false

            // Try to get text preview if it's text-based
            var textPreview = ""
            if let text = String(data: data.prefix(500), encoding: .utf8) {
                textPreview = text
                    .replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "\r", with: " ")
                    .prefix(200)
                    .description
            }

            Logger.pdfBrowser.warning("Download is not a PDF - Diagnostics:")
            Logger.pdfBrowser.warning("  Filename: \(filename)")
            Logger.pdfBrowser.warning("  Size: \(data.count) bytes")
            Logger.pdfBrowser.warning("  Magic bytes: \(magicBytes)")
            Logger.pdfBrowser.warning("  Looks like HTML: \(isHTML || isHTMLDoctype)")

            if !textPreview.isEmpty {
                Logger.pdfBrowser.warning("  Content preview: \(textPreview)")
            }

            // Expected PDF magic: 25 50 44 46 (%PDF)
            Logger.pdfBrowser.warning("  Expected PDF magic: 25 50 44 46 (%PDF)")
        }

        func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
            Logger.pdfBrowser.error("Download failed: \(error.localizedDescription)")

            // Clean up temp file if used
            if let tempURL = downloadTempFileURL {
                try? FileManager.default.removeItem(at: tempURL)
                downloadTempFileURL = nil
            }

            Task { @MainActor in
                viewModel.errorMessage = "Download failed: \(error.localizedDescription)"
                viewModel.downloadProgress = nil
            }
            downloadData = Data()
        }

        // MARK: - WKUIDelegate

        func webView(_ webView: WKWebView,
                    createWebViewWith configuration: WKWebViewConfiguration,
                    for navigationAction: WKNavigationAction,
                    windowFeatures: WKWindowFeatures) -> WKWebView? {
            // Handle target="_blank" links by loading in current view
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
            }
            return nil
        }

        // MARK: - Manual Capture

        /// Capture the current page as a PDF using WebKit's print-to-PDF functionality.
        ///
        /// This renders the webpage as a PDF. For regular HTML pages, it captures the
        /// full scrollable content. For pages displaying native PDFs, users should use
        /// "Save PDF to Library" instead (which fetches the actual PDF file).
        @MainActor
        func captureCurrentContent() async {
            guard let webView = viewModel.webView else {
                Logger.pdfBrowser.error("Manual capture failed: no webView")
                viewModel.errorMessage = "Browser not ready"
                return
            }

            guard let url = webView.url else {
                Logger.pdfBrowser.error("Manual capture failed: no URL")
                viewModel.errorMessage = "No URL to capture"
                return
            }

            Logger.pdfBrowser.info("Capturing full page as PDF for: \(url.absoluteString)")

            // Check if this is a native PDF - if so, suggest using "Save PDF to Library" instead
            let isNativePDF = await checkIfNativePDF(webView)
            if isNativePDF {
                Logger.pdfBrowser.info("Page is native PDF - attempting direct fetch instead of capture")
                // For native PDFs, try to fetch the actual PDF file
                do {
                    let data = try await fetchPDFWithWebViewCookies(url: url, webView: webView)
                    if isPDF(data: data) {
                        let filename = generateFilename(from: url)
                        viewModel.detectedPDFFilename = filename
                        viewModel.detectedPDFData = data
                        Logger.pdfBrowser.info("Native PDF fetch successful: \(filename), \(data.count) bytes")
                        return
                    }
                } catch {
                    Logger.pdfBrowser.warning("Native PDF fetch failed, falling back to page capture: \(error.localizedDescription)")
                }
            }

            // Get the full document dimensions for complete page capture
            let dimensions = await getFullPageDimensions(webView)
            Logger.pdfBrowser.debug("Page dimensions: \(dimensions.width) x \(dimensions.height)")

            // Render the full page as PDF
            do {
                let pdfConfig = WKPDFConfiguration()

                // Set rect to capture full scrollable content if we got valid dimensions
                if dimensions.height > 0 && dimensions.width > 0 {
                    pdfConfig.rect = CGRect(x: 0, y: 0, width: dimensions.width, height: dimensions.height)
                }

                let pdfData = try await webView.pdf(configuration: pdfConfig)

                if isPDF(data: pdfData) {
                    let filename = generateFilename(from: url, suffix: "_capture")
                    viewModel.detectedPDFFilename = filename
                    viewModel.detectedPDFData = pdfData
                    Logger.pdfBrowser.info("Page capture successful: \(filename), \(pdfData.count) bytes")
                } else {
                    logDownloadDiagnostics(data: pdfData, filename: "page-capture")
                    viewModel.errorMessage = "Could not capture page as PDF"
                }
            } catch {
                Logger.pdfBrowser.error("Page capture failed: \(error.localizedDescription)")
                viewModel.errorMessage = "Could not capture page: \(error.localizedDescription)"
            }
        }

        /// Check if the current page is displaying a native PDF (document.contentType)
        private func checkIfNativePDF(_ webView: WKWebView) async -> Bool {
            let script = """
            (function() {
                return document.contentType === 'application/pdf' ||
                       document.contentType === 'application/x-pdf';
            })()
            """

            do {
                let result = try await webView.evaluateJavaScript(script)
                return result as? Bool ?? false
            } catch {
                return false
            }
        }

        /// Get the full scrollable dimensions of the page
        private func getFullPageDimensions(_ webView: WKWebView) async -> (width: CGFloat, height: CGFloat) {
            let script = """
            (function() {
                // Get the maximum scrollable dimensions
                var body = document.body;
                var html = document.documentElement;

                var height = Math.max(
                    body.scrollHeight, body.offsetHeight, body.clientHeight,
                    html.scrollHeight, html.offsetHeight, html.clientHeight
                );

                var width = Math.max(
                    body.scrollWidth, body.offsetWidth, body.clientWidth,
                    html.scrollWidth, html.offsetWidth, html.clientWidth
                );

                return { width: width, height: height };
            })()
            """

            do {
                let result = try await webView.evaluateJavaScript(script)
                if let dict = result as? [String: Any],
                   let width = dict["width"] as? Double,
                   let height = dict["height"] as? Double {
                    return (CGFloat(width), CGFloat(height))
                }
            } catch {
                Logger.pdfBrowser.warning("Could not get page dimensions: \(error.localizedDescription)")
            }

            // Return zeros to use default behavior
            return (0, 0)
        }

        /// Generate a filename for the captured PDF.
        /// - Parameters:
        ///   - url: The URL to derive filename from
        ///   - suffix: Optional suffix to add before .pdf (e.g., "_capture")
        private func generateFilename(from url: URL?, suffix: String = "") -> String {
            // Try to get filename from URL path
            if let url = url {
                let lastComponent = url.lastPathComponent
                if lastComponent.lowercased().hasSuffix(".pdf") {
                    if suffix.isEmpty {
                        return lastComponent
                    } else {
                        // Insert suffix before .pdf
                        let baseName = String(lastComponent.dropLast(4))
                        return "\(baseName)\(suffix).pdf"
                    }
                }
                if !lastComponent.isEmpty && lastComponent != "/" {
                    return "\(lastComponent)\(suffix).pdf"
                }
            }

            // Fall back to publication info
            let pub = viewModel.publication
            let authorStr = pub.authorString
            let author = authorStr.split(separator: ",").first.map(String.init) ?? "Unknown"
            let year = pub.year > 0 ? "\(pub.year)" : "NoYear"
            let titleWord = pub.title?.split(separator: " ").first.map(String.init) ?? "Document"

            return "\(author)_\(year)_\(titleWord)\(suffix).pdf"
        }

        // MARK: - Helpers

        private func isPDF(data: Data) -> Bool {
            guard data.count >= 4 else { return false }
            let magic = data.prefix(4)
            return magic == Data([0x25, 0x50, 0x44, 0x46])  // %PDF
        }

        private func checkForPDFContent(_ webView: WKWebView) {
            // Run comprehensive PDF detection with multiple checks
            let pdfDetectionScript = """
            (function() {
                var result = { type: 'none', urls: [] };

                // Check 1: Document content type (most reliable when available)
                if (document.contentType === 'application/pdf' ||
                    document.contentType === 'application/x-pdf') {
                    result.type = 'contentType';
                    result.urls.push(window.location.href);
                    return JSON.stringify(result);
                }

                // Check 2: embed elements with PDF type
                var embeds = document.querySelectorAll('embed[type="application/pdf"], embed[type="application/x-pdf"]');
                if (embeds.length >= 1) {
                    result.type = 'embed';
                    for (var i = 0; i < embeds.length; i++) {
                        if (embeds[i].src) result.urls.push(embeds[i].src);
                    }
                    return JSON.stringify(result);
                }

                // Check 3: object elements with PDF type
                var objects = document.querySelectorAll('object[type="application/pdf"], object[type="application/x-pdf"]');
                if (objects.length >= 1) {
                    result.type = 'object';
                    for (var i = 0; i < objects.length; i++) {
                        if (objects[i].data) result.urls.push(objects[i].data);
                    }
                    return JSON.stringify(result);
                }

                // Check 4: PDF.js viewer detection
                if (document.querySelector('#viewer.pdfViewer') ||
                    document.querySelector('.pdfViewer')) {
                    result.type = 'pdfjs';
                    result.urls.push(window.location.href);
                    return JSON.stringify(result);
                }

                // Check 5: Look for PDF viewer plugin element
                var plugins = document.querySelectorAll('[class*="pdf"][class*="viewer"], [id*="pdf"][id*="viewer"]');
                if (plugins.length >= 1) {
                    result.type = 'plugin';
                    result.urls.push(window.location.href);
                    return JSON.stringify(result);
                }

                // Check 6: Collect ALL iframe src URLs for content-type probing
                // This is critical for sites like IEEE that load PDFs in iframes
                var iframes = document.querySelectorAll('iframe');
                var iframeUrls = [];
                for (var i = 0; i < iframes.length; i++) {
                    var src = iframes[i].src;
                    if (src && src.length > 0 && !src.startsWith('about:') && !src.startsWith('javascript:')) {
                        iframeUrls.push(src);
                    }
                }
                if (iframeUrls.length > 0) {
                    result.type = 'iframe_candidate';
                    result.urls = iframeUrls;
                    return JSON.stringify(result);
                }

                // Check 7: Very minimal page that might be native PDF display
                // Safari displays PDFs with very minimal DOM
                if (document.body.children.length <= 2) {
                    var bodyText = document.body.innerText || '';
                    // Native PDF views have almost no text content
                    if (bodyText.length < 100) {
                        result.type = 'minimal';
                        result.urls.push(window.location.href);
                        return JSON.stringify(result);
                    }
                }

                return JSON.stringify(result);
            })()
            """

            webView.evaluateJavaScript(pdfDetectionScript) { [weak self] result, error in
                guard let self = self else { return }

                guard let jsonString = result as? String,
                      let jsonData = jsonString.data(using: .utf8),
                      let detection = try? JSONDecoder().decode(PDFDetectionResult.self, from: jsonData) else {
                    Logger.pdfBrowser.warning("PDF detection script failed: \(error?.localizedDescription ?? "parse error")")
                    return
                }

                Logger.pdfBrowser.info("PDF detection result: type=\(detection.type), urls=\(detection.urls)")

                switch detection.type {
                case "contentType", "embed", "object", "pdfjs", "plugin", "minimal":
                    // These types indicate we found a PDF - try to capture it
                    if let url = detection.urls.first.flatMap({ URL(string: $0) }) {
                        Logger.pdfBrowser.info("Page detected as PDF (\(detection.type)), attempting capture from: \(url.absoluteString)")
                        self.captureInlinePDF(webView, pdfURL: url)
                    } else {
                        self.captureInlinePDF(webView, pdfURL: webView.url)
                    }

                case "iframe_candidate":
                    // We found iframes - probe each one to check if it's a PDF
                    Logger.pdfBrowser.info("Found \(detection.urls.count) iframe(s), probing for PDF content")
                    self.probeURLsForPDF(detection.urls, webView: webView)

                default:
                    // No PDF detected yet - check URL pattern
                    if let url = webView.url, self.looksLikePDFURL(url) {
                        Logger.pdfBrowser.info("URL pattern suggests PDF, attempting capture: \(url.absoluteString)")
                        self.captureInlinePDF(webView, pdfURL: url)
                        return
                    }

                    // Schedule a retry after delay - some PDFs take time to render
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                        self?.checkForPDFContentRetry(webView)
                    }
                }
            }
        }

        /// Simple struct for decoding PDF detection results
        private struct PDFDetectionResult: Decodable {
            let type: String
            let urls: [String]
        }

        /// Probe a list of URLs to find which one is a PDF (by checking Content-Type via HEAD request)
        private func probeURLsForPDF(_ urlStrings: [String], webView: WKWebView) {
            Task {
                // Get cookies from WKWebView for authenticated requests
                let dataStore = webView.configuration.websiteDataStore
                let cookies = await dataStore.httpCookieStore.allCookies()

                let config = URLSessionConfiguration.default
                config.httpCookieStorage = HTTPCookieStorage()
                for cookie in cookies {
                    config.httpCookieStorage?.setCookie(cookie)
                }
                config.httpAdditionalHeaders = [
                    "Accept": "application/pdf,*/*",
                    "User-Agent": await MainActor.run { webView.value(forKey: "userAgent") as? String } ?? "Mozilla/5.0"
                ]

                let session = URLSession(configuration: config)

                for urlString in urlStrings {
                    guard let url = URL(string: urlString) else { continue }

                    Logger.pdfBrowser.debug("Probing URL for PDF: \(urlString)")

                    do {
                        var request = URLRequest(url: url)
                        request.httpMethod = "HEAD"

                        let (_, response) = try await session.data(for: request)

                        if let httpResponse = response as? HTTPURLResponse {
                            let contentType = httpResponse.mimeType?.lowercased() ?? ""
                            Logger.pdfBrowser.debug("  Content-Type: \(contentType)")

                            if contentType == "application/pdf" || contentType == "application/x-pdf" {
                                Logger.pdfBrowser.info("Found PDF at iframe URL: \(urlString)")
                                await MainActor.run {
                                    self.captureInlinePDF(webView, pdfURL: url)
                                }
                                return
                            }
                        }
                    } catch {
                        Logger.pdfBrowser.debug("  HEAD request failed: \(error.localizedDescription)")
                        // Try GET request - some servers don't support HEAD
                        do {
                            let (data, response) = try await session.data(from: url)

                            // Check by Content-Type header
                            if let httpResponse = response as? HTTPURLResponse {
                                let contentType = httpResponse.mimeType?.lowercased() ?? ""
                                if contentType == "application/pdf" || contentType == "application/x-pdf" {
                                    Logger.pdfBrowser.info("Found PDF at iframe URL (via GET): \(urlString)")
                                    if self.isPDF(data: data) {
                                        let filename = self.generateFilename(from: url)
                                        await MainActor.run {
                                            self.viewModel.detectedPDFFilename = filename
                                            self.viewModel.detectedPDFData = data
                                        }
                                        return
                                    }
                                }
                            }

                            // Check by magic bytes
                            if self.isPDF(data: data) {
                                Logger.pdfBrowser.info("Found PDF at iframe URL (by magic bytes): \(urlString)")
                                let filename = self.generateFilename(from: url)
                                await MainActor.run {
                                    self.viewModel.detectedPDFFilename = filename
                                    self.viewModel.detectedPDFData = data
                                }
                                return
                            }
                        } catch {
                            Logger.pdfBrowser.debug("  GET request also failed: \(error.localizedDescription)")
                        }
                    }
                }

                Logger.pdfBrowser.info("No PDF found in \(urlStrings.count) iframe URL(s)")
            }
        }

        /// Retry PDF detection (single retry after initial check)
        private func checkForPDFContentRetry(_ webView: WKWebView) {
            // Only retry if we haven't already detected a PDF
            guard viewModel.detectedPDFData == nil else { return }

            // Quick check for minimal DOM that might be native PDF
            let quickCheckScript = """
            (function() {
                if (document.contentType === 'application/pdf') return 'pdf';
                if (document.body.children.length <= 2) return 'minimal';
                return 'none';
            })()
            """

            webView.evaluateJavaScript(quickCheckScript) { [weak self] result, _ in
                guard let self = self else { return }

                let detection = result as? String ?? "none"
                if detection != "none" {
                    Logger.pdfBrowser.info("Retry detected PDF (\(detection)), attempting capture")
                    self.captureInlinePDF(webView, pdfURL: webView.url)
                }
            }
        }

        private func captureInlinePDF(_ webView: WKWebView, pdfURL: URL?) {
            // For inline PDFs, we need to fetch the data
            guard let url = pdfURL ?? webView.url else { return }

            Task {
                do {
                    // Try to fetch using a session that shares cookies with the webView
                    // This helps with authenticated/proxied PDFs
                    let data = try await fetchPDFWithWebViewCookies(url: url, webView: webView)

                    if isPDF(data: data) {
                        let filename = generateFilename(from: url)
                        await MainActor.run {
                            viewModel.detectedPDFFilename = filename
                            viewModel.detectedPDFData = data
                        }
                        Logger.pdfBrowser.info("Captured inline PDF: \(filename), \(data.count) bytes")
                    } else {
                        Logger.pdfBrowser.warning("Fetched content is not a PDF")
                        logDownloadDiagnostics(data: data, filename: url.lastPathComponent)
                    }
                } catch {
                    Logger.pdfBrowser.error("Failed to capture inline PDF: \(error.localizedDescription)")
                }
            }
        }

        /// Fetch PDF data using cookies from the WKWebView's data store
        private func fetchPDFWithWebViewCookies(url: URL, webView: WKWebView) async throws -> Data {
            // Get cookies from WKWebView's data store
            let dataStore = webView.configuration.websiteDataStore
            let cookies = await dataStore.httpCookieStore.allCookies()

            // Create a URLSession configuration with these cookies
            let config = URLSessionConfiguration.default
            config.httpCookieStorage = HTTPCookieStorage()
            for cookie in cookies {
                config.httpCookieStorage?.setCookie(cookie)
            }

            // Also set common headers that might be needed
            config.httpAdditionalHeaders = [
                "Accept": "application/pdf,*/*",
                "User-Agent": webView.value(forKey: "userAgent") as? String ?? "Mozilla/5.0"
            ]

            let session = URLSession(configuration: config)

            Logger.pdfBrowser.debug("Fetching PDF with \(cookies.count) cookies from webView")

            let (data, response) = try await session.data(from: url)

            // Log response info for debugging
            if let httpResponse = response as? HTTPURLResponse {
                Logger.pdfBrowser.debug("Response status: \(httpResponse.statusCode), content-type: \(httpResponse.mimeType ?? "unknown")")
            }

            return data
        }
    }
}

// MARK: - Preview

#if DEBUG
struct MacPDFBrowserView_Previews: PreviewProvider {
    static var previews: some View {
        Text("MacPDFBrowserView requires CDPublication")
            .frame(width: 800, height: 600)
    }
}
#endif

#endif // os(macOS)
