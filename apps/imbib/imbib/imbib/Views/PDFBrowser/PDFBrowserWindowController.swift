//
//  PDFBrowserWindowController.swift
//  imbib
//
//  Created by Claude on 2026-01-06.
//

#if os(macOS)
import SwiftUI
import AppKit
import PublicationManagerCore
import OSLog

// MARK: - Window Controller

/// Manages PDF browser window lifecycle.
///
/// Usage:
/// ```swift
/// let viewModel = PDFBrowserViewModel(publication: pub, initialURL: url, libraryID: id)
/// viewModel.onPDFCaptured = { data in
///     try? await PDFManager.shared.importPDF(data: data, for: pub)
/// }
/// await PDFBrowserWindowController.shared.openWindow(with: viewModel)
/// ```
@MainActor
public final class PDFBrowserWindowController {

    // MARK: - Shared Instance

    public static let shared = PDFBrowserWindowController()

    // MARK: - Properties

    /// Currently open browser windows keyed by publication ID
    private var windows: [UUID: NSWindow] = [:]

    /// View models for each window
    private var viewModels: [UUID: PDFBrowserViewModel] = [:]

    // MARK: - Initialization

    private init() {
        Logger.pdfBrowser.info("PDFBrowserWindowController initialized")
    }

    // MARK: - Public API

    /// Open a PDF browser window for a publication.
    ///
    /// If a window is already open for this publication, it will be brought to front.
    ///
    /// - Parameter viewModel: The view model containing publication and URL info
    public func openWindow(with viewModel: PDFBrowserViewModel) {
        let publicationID = viewModel.publication.objectID.uriRepresentation().hashValue
        let windowKey = UUID(uuidString: String(format: "%08X-0000-0000-0000-000000000000", publicationID)) ?? UUID()

        // Check for existing window
        if let existingWindow = windows[windowKey] {
            Logger.pdfBrowser.info("Bringing existing browser window to front")
            existingWindow.makeKeyAndOrderFront(nil)
            return
        }

        Logger.pdfBrowser.info("Creating new browser window for: \(viewModel.publication.title ?? "Unknown")")

        // Create the SwiftUI view
        let browserView = MacPDFBrowserView(viewModel: viewModel)
            .frame(minWidth: 900, minHeight: 700)

        // Create hosting controller
        let hostingController = NSHostingController(rootView: browserView)

        // Create window
        let window = NSWindow(contentViewController: hostingController)
        window.title = "PDF Browser - \(viewModel.publication.title ?? "Unknown")"
        window.setContentSize(NSSize(width: 1000, height: 800))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.minSize = NSSize(width: 800, height: 600)
        window.center()

        // Set window delegate to track close
        let delegate = WindowDelegate(windowKey: windowKey, controller: self)
        window.delegate = delegate
        objc_setAssociatedObject(window, "delegate", delegate, .OBJC_ASSOCIATION_RETAIN)

        // Store references
        windows[windowKey] = window
        viewModels[windowKey] = viewModel

        // Set up dismiss callback
        viewModel.onDismiss = { [weak self, windowKey] in
            Task { @MainActor in
                self?.closeWindow(key: windowKey)
            }
        }

        // Show window
        window.makeKeyAndOrderFront(nil)

        Logger.pdfBrowser.info("Browser window opened")
    }

    /// Close the browser window for a publication.
    ///
    /// - Parameter publication: The publication whose window should be closed
    public func closeWindow(for publication: CDPublication) {
        let publicationID = publication.objectID.uriRepresentation().hashValue
        let windowKey = UUID(uuidString: String(format: "%08X-0000-0000-0000-000000000000", publicationID)) ?? UUID()
        closeWindow(key: windowKey)
    }

    /// Close all browser windows.
    public func closeAllWindows() {
        for window in windows.values {
            window.close()
        }
        windows.removeAll()
        viewModels.removeAll()
        Logger.pdfBrowser.info("All browser windows closed")
    }

    /// Check if a window is open for a publication.
    public func hasOpenWindow(for publication: CDPublication) -> Bool {
        let publicationID = publication.objectID.uriRepresentation().hashValue
        let windowKey = UUID(uuidString: String(format: "%08X-0000-0000-0000-000000000000", publicationID)) ?? UUID()
        return windows[windowKey] != nil
    }

    // MARK: - Private

    fileprivate func closeWindow(key: UUID) {
        if let window = windows[key] {
            window.close()
        }
        windows.removeValue(forKey: key)
        viewModels.removeValue(forKey: key)
        Logger.pdfBrowser.info("Browser window closed")
    }

    fileprivate func windowDidClose(key: UUID) {
        windows.removeValue(forKey: key)
        viewModels.removeValue(forKey: key)
        Logger.pdfBrowser.info("Browser window closed via delegate")
    }
}

// MARK: - Window Delegate

private class WindowDelegate: NSObject, NSWindowDelegate {

    let windowKey: UUID
    weak var controller: PDFBrowserWindowController?

    init(windowKey: UUID, controller: PDFBrowserWindowController) {
        self.windowKey = windowKey
        self.controller = controller
    }

    func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            controller?.windowDidClose(key: windowKey)
        }
    }
}

// MARK: - Convenience Extension

public extension PDFBrowserWindowController {

    /// Open a PDF browser for a publication, resolving the best URL automatically.
    ///
    /// - Parameters:
    ///   - publication: The publication to find PDFs for
    ///   - libraryID: The library ID for PDF import
    ///   - onPDFCaptured: Callback when a PDF is captured
    ///
    /// Note: The browser does NOT apply library proxy to the initial URL. The proxy
    /// prefix approach is for programmatic downloads. In the browser, users authenticate
    /// naturally via institutional login pages, and the WKWebView maintains session cookies.
    func openBrowser(
        for publication: CDPublication,
        libraryID: UUID,
        onPDFCaptured: @escaping (Data) async -> Void
    ) async {
        // Get best URL from registry
        let url = await BrowserURLProviderRegistry.shared.browserURL(for: publication)

        guard let startURL = url else {
            Logger.pdfBrowser.warning("No browser URL found for publication")
            return
        }

        // Note: We intentionally do NOT apply the library proxy here.
        // The proxy prefix approach (e.g., "https://proxy.library.edu/login?url=...")
        // is meant for programmatic downloads. In the browser, users authenticate
        // via the publisher's login page, and the WKWebView handles cookies/sessions.
        // The ADS link gateway (ui.adsabs.harvard.edu) redirects to the publisher,
        // where the user can authenticate with their institutional credentials.

        Logger.pdfBrowser.info("Opening browser with URL: \(startURL.absoluteString)")

        // Create view model
        let viewModel = PDFBrowserViewModel(
            publication: publication,
            initialURL: startURL,
            libraryID: libraryID
        )

        // Load proxy settings so user can retry with proxy if needed
        let settings = await PDFSettingsStore.shared.settings
        viewModel.libraryProxyURL = settings.libraryProxyURL
        viewModel.proxyEnabled = settings.proxyEnabled

        viewModel.onPDFCaptured = onPDFCaptured

        // Open window
        openWindow(with: viewModel)
    }

    /// Open a PDF browser for a publication with a specific URL.
    ///
    /// Use this when you want to open a specific PDF source URL rather than
    /// auto-resolving the best URL.
    ///
    /// - Parameters:
    ///   - publication: The publication context
    ///   - startURL: The specific URL to open
    ///   - libraryID: The library ID for PDF import
    ///   - onPDFCaptured: Callback when a PDF is captured
    func openBrowser(
        for publication: CDPublication,
        startURL: URL,
        libraryID: UUID,
        onPDFCaptured: @escaping (Data) async -> Void
    ) async {
        Logger.pdfBrowser.info("Opening browser with specific URL: \(startURL.absoluteString)")

        // Create view model with the specific URL
        let viewModel = PDFBrowserViewModel(
            publication: publication,
            initialURL: startURL,
            libraryID: libraryID
        )

        // Load proxy settings so user can retry with proxy if needed
        let settings = await PDFSettingsStore.shared.settings
        viewModel.libraryProxyURL = settings.libraryProxyURL
        viewModel.proxyEnabled = settings.proxyEnabled

        viewModel.onPDFCaptured = onPDFCaptured

        // Open window
        openWindow(with: viewModel)
    }
}

#endif // os(macOS)
