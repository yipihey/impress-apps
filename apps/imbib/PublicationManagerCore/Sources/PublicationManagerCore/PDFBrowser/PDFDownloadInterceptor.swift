//
//  PDFDownloadInterceptor.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-06.
//

import Foundation
import OSLog

#if canImport(WebKit)
import WebKit

/// Intercepts WKWebView downloads to detect and capture PDF files.
///
/// This class implements WKDownloadDelegate to monitor downloads initiated
/// by the web view. When a PDF is detected (either by content-type or file
/// extension), it captures the data and notifies via callback.
///
/// Usage:
/// ```swift
/// let interceptor = PDFDownloadInterceptor()
/// interceptor.onPDFDownloaded = { filename, data in
///     // Handle PDF data
/// }
/// // In WKNavigationDelegate:
/// func webView(_ webView: WKWebView, navigationAction: WKNavigationAction,
///              didBecome download: WKDownload) {
///     download.delegate = interceptor
/// }
/// ```
public final class PDFDownloadInterceptor: NSObject, WKDownloadDelegate {

    // MARK: - Callbacks

    /// Called when a PDF download completes successfully.
    /// Parameters: (filename, data)
    public var onPDFDownloaded: ((String, Data) -> Void)?

    /// Called when a download starts.
    /// Parameter: suggested filename
    public var onDownloadStarted: ((String) -> Void)?

    /// Called periodically with download progress (0.0 to 1.0).
    public var onDownloadProgress: ((Double) -> Void)?

    /// Called when a download fails.
    public var onDownloadFailed: ((Error) -> Void)?

    /// Called when a non-PDF file is downloaded.
    /// Parameters: (filename, data, mimeType)
    public var onNonPDFDownloaded: ((String, Data, String?) -> Void)?

    // MARK: - State

    /// Accumulated download data
    private var downloadData = Data()

    /// Expected content length for progress calculation
    private var expectedLength: Int64 = 0

    /// Suggested filename from server
    private var filename: String = "download.pdf"

    /// MIME type from response
    private var mimeType: String?

    /// Temporary file URL for large downloads
    private var tempFileURL: URL?

    // MARK: - Initialization

    public override init() {
        super.init()
        Logger.pdfBrowser.debug("PDFDownloadInterceptor initialized")
    }

    // MARK: - WKDownloadDelegate

    public func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String
    ) async -> URL? {
        // Reset state for new download
        downloadData = Data()
        expectedLength = response.expectedContentLength
        filename = suggestedFilename
        mimeType = response.mimeType

        Logger.pdfBrowser.info("Download started: \(suggestedFilename)")
        Logger.pdfBrowser.debug("MIME type: \(response.mimeType ?? "unknown")")
        Logger.pdfBrowser.debug("Expected length: \(self.expectedLength) bytes")

        onDownloadStarted?(suggestedFilename)

        // Always use a temp file - returning nil causes sandbox extension errors
        let tempDir = FileManager.default.temporaryDirectory
        self.tempFileURL = tempDir.appendingPathComponent(UUID().uuidString + ".pdf")
        Logger.pdfBrowser.debug("Using temp file: \(self.tempFileURL?.path ?? "nil")")
        return self.tempFileURL
    }

    public func download(_ download: WKDownload, didReceive data: Data) {
        downloadData.append(data)

        // Calculate and report progress
        if expectedLength > 0 {
            let progress = Double(downloadData.count) / Double(expectedLength)
            onDownloadProgress?(progress)
        }
    }

    public func downloadDidFinish(_ download: WKDownload) {
        let finalData: Data

        // If we used a temp file, read from it
        if let tempURL = tempFileURL {
            do {
                finalData = try Data(contentsOf: tempURL)
                // Clean up temp file
                try? FileManager.default.removeItem(at: tempURL)
                tempFileURL = nil
            } catch {
                Logger.pdfBrowser.error("Failed to read temp file: \(error.localizedDescription)")
                onDownloadFailed?(error)
                return
            }
        } else {
            finalData = downloadData
        }

        Logger.pdfBrowser.info("Download finished: \(self.filename), \(finalData.count) bytes")

        // Check if it's a PDF
        if isPDF(data: finalData, mimeType: self.mimeType, filename: self.filename) {
            Logger.pdfBrowser.info("PDF detected: \(self.filename)")
            onPDFDownloaded?(self.filename, finalData)
        } else {
            Logger.pdfBrowser.warning("Downloaded file is not a PDF: \(self.filename), MIME: \(self.mimeType ?? "unknown")")
            onNonPDFDownloaded?(self.filename, finalData, self.mimeType)
        }

        // Reset state
        downloadData = Data()
        expectedLength = 0
        mimeType = nil
    }

    public func download(
        _ download: WKDownload,
        didFailWithError error: Error,
        resumeData: Data?
    ) {
        Logger.pdfBrowser.error("Download failed: \(error.localizedDescription)")

        // Clean up temp file if used
        if let tempURL = tempFileURL {
            try? FileManager.default.removeItem(at: tempURL)
            tempFileURL = nil
        }

        onDownloadFailed?(error)

        // Reset state
        downloadData = Data()
        expectedLength = 0
        mimeType = nil
    }

    // MARK: - PDF Detection

    /// Check if data represents a PDF file.
    ///
    /// Uses multiple heuristics:
    /// 1. PDF magic bytes (%PDF)
    /// 2. MIME type
    /// 3. File extension
    private func isPDF(data: Data, mimeType: String?, filename: String) -> Bool {
        // Check magic bytes first (most reliable)
        if hasPDFMagicBytes(data) {
            return true
        }

        // Check MIME type
        if let mime = mimeType?.lowercased() {
            if mime == "application/pdf" || mime.contains("pdf") {
                return true
            }
        }

        // Check file extension
        if filename.lowercased().hasSuffix(".pdf") {
            // File claims to be PDF but doesn't have magic bytes
            // This might be an HTML error page served as .pdf
            Logger.pdfBrowser.warning("File has .pdf extension but no PDF magic bytes")
            return hasPDFMagicBytes(data) // Strict check for extension-only
        }

        return false
    }

    /// Check for PDF magic bytes: %PDF
    private func hasPDFMagicBytes(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let magic = data.prefix(4)
        // %PDF = 0x25 0x50 0x44 0x46
        return magic == Data([0x25, 0x50, 0x44, 0x46])
    }

    /// Check if data looks like HTML (common for error pages).
    public func isHTML(data: Data) -> Bool {
        guard data.count >= 1 else { return false }
        // Check for HTML-like content (< as first non-whitespace byte)
        let trimmed = data.drop { byte in
            byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D // whitespace
        }
        guard let firstByte = trimmed.first else { return false }
        return firstByte == 0x3C // '<'
    }
}

#else

// Stub for platforms without WebKit (tvOS)
public final class PDFDownloadInterceptor {
    public var onPDFDownloaded: ((String, Data) -> Void)?
    public var onDownloadStarted: ((String) -> Void)?
    public var onDownloadProgress: ((Double) -> Void)?
    public var onDownloadFailed: ((Error) -> Void)?

    public init() {
        Logger.pdfBrowser.info("PDFDownloadInterceptor: WebKit not available on this platform")
    }
}

#endif
