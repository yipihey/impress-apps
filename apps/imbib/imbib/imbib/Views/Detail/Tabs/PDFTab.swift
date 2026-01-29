//
//  PDFTab.swift
//  imbib
//
//  Extracted from DetailView.swift
//

import SwiftUI
import PublicationManagerCore
import CoreData
import OSLog
#if os(macOS)
import AppKit
#endif

private let logger = Logger(subsystem: "com.imbib.app", category: "pdftab")

// MARK: - PDF Download Error

enum PDFDownloadError: LocalizedError {
    case noActiveLibrary
    case downloadFailed(String)
    case publisherNotAvailable
    case noPDFAvailable

    var errorDescription: String? {
        switch self {
        case .noActiveLibrary:
            return "No active library for PDF import"
        case .downloadFailed(let reason):
            return "Download failed: \(reason)"
        case .publisherNotAvailable:
            return "Publisher PDF not available for direct download. Use the browser to access the publisher page."
        case .noPDFAvailable:
            return "No PDF source available for this paper."
        }
    }
}

// MARK: - PDF Tab

struct PDFTab: View {
    let paper: any PaperRepresentable
    let publication: CDPublication?
    @Binding var selectedTab: DetailTab
    var isMultiSelection: Bool = false  // Disable auto-download when multiple papers selected

    @Environment(LibraryManager.self) private var libraryManager
    @State private var linkedFile: CDLinkedFile?
    @State private var isDownloading = false
    @State private var downloadError: Error?
    @State private var hasRemotePDF = false
    @State private var checkPDFTask: Task<Void, Never>?
    @State private var showFileImporter = false
    @State private var isCheckingPDF = true  // Start in loading state
    @State private var browserFallbackURL: URL?  // URL to open in browser when publisher PDF fails

    // PDF dark mode setting
    @State private var pdfDarkModeEnabled: Bool = PDFSettingsStore.loadSettingsSync().darkModeEnabled

    var body: some View {
        Group {
            // ADR-016: All papers are now CDPublication
            if let linked = linkedFile, let pub = publication {
                // Has linked PDF file - show viewer only (no notes panel)
                pdfViewerOnly(linked: linked, pub: pub)
                    .id(pub.id)  // Force view recreation when paper changes to reset @State
            } else if isCheckingPDF {
                // Loading state while checking for PDFs
                ProgressView("Checking for PDF...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isDownloading {
                downloadingView
            } else if let error = downloadError {
                errorView(error)
            } else if hasRemotePDF {
                // No local PDF but remote available - show download prompt
                noPDFLibraryView
            } else {
                // No PDF available anywhere
                noPDFView
            }
        }
        .onAppear {
            // Trigger initial PDF check on first appearance
            resetAndCheckPDF()
        }
        .onChange(of: selectedTab) { oldTab, newTab in
            // Only check PDF when switching TO the PDF tab
            if newTab == .pdf {
                resetAndCheckPDF()
            }
        }
        .onChange(of: paper.id) { _, _ in
            // Only check PDF if the PDF tab is currently visible
            if selectedTab == .pdf {
                resetAndCheckPDF()
            }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }
        .onReceive(NotificationCenter.default.publisher(for: .pdfImportedFromBrowser)) { notification in
            // Refresh when PDF is imported from browser for this publication
            if let objectID = notification.object as? NSManagedObjectID,
               objectID == publication?.objectID {
                resetAndCheckPDF()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .syncedSettingsDidChange)) { notification in
            // Refresh dark mode setting when it changes
            Task {
                pdfDarkModeEnabled = await PDFSettingsStore.shared.settings.darkModeEnabled
            }
        }
    }

    // MARK: - PDF Viewer Only (no notes panel)

    @ViewBuilder
    private func pdfViewerOnly(linked: CDLinkedFile, pub: CDPublication) -> some View {
        PDFViewerWithControls(
            linkedFile: linked,
            library: libraryManager.activeLibrary,
            publicationID: pub.id,
            onCorruptPDF: { corruptFile in
                Task {
                    await handleCorruptPDF(corruptFile)
                }
            }
        )
        .background(pdfDarkModeEnabled ? Color.black : Color.clear)
        .onAppear {
            // Start Handoff activity for reading this PDF
            HandoffService.shared.startReading(
                publicationID: pub.id,
                citeKey: pub.citeKey,
                title: pub.title ?? "Untitled",
                page: 1,
                zoom: 1.0
            )
        }
        .onDisappear {
            // Stop Handoff activity when leaving PDF view
            HandoffService.shared.stopReading()
        }
    }

    // MARK: - Subviews

    private var downloadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Downloading PDF...")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ error: Error) -> some View {
        ContentUnavailableView {
            Label("Download Failed", systemImage: "exclamationmark.triangle")
        } description: {
            VStack(spacing: 8) {
                Text(error.localizedDescription)

                // Show the attempted URL for browser fallback (clickable to open in system browser)
                if let fallbackURL = browserFallbackURL {
                    Text("Publisher URL:")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    #if os(macOS)
                    Button {
                        NSWorkspace.shared.open(fallbackURL)
                    } label: {
                        Text(fallbackURL.absoluteString)
                            .font(.caption)
                            .foregroundStyle(.blue)
                            .underline()
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .multilineTextAlignment(.center)
                    }
                    .buttonStyle(.plain)
                    .help("Click to open in Safari")
                    #else
                    Link(destination: fallbackURL) {
                        Text(fallbackURL.absoluteString)
                            .font(.caption)
                            .foregroundStyle(.blue)
                            .underline()
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                    #endif
                }
            }
        } actions: {
            // Show "Open in Browser" as primary action when we have a fallback URL
            if let fallbackURL = browserFallbackURL {
                #if os(macOS)
                Button("Open in Browser") {
                    Task { await openPDFBrowserWithURL(fallbackURL) }
                }
                .buttonStyle(.borderedProminent)
                .help("Open publisher page in built-in browser to download PDF")
                #endif

                Button("Retry") {
                    Task { await downloadPDF() }
                }
                .buttonStyle(.bordered)
                .help("Retry PDF download")
            } else {
                Button("Retry") {
                    Task { await downloadPDF() }
                }
                .buttonStyle(.borderedProminent)
                .help("Retry PDF download")

                #if os(macOS)
                Button("Open in Browser") {
                    Task { await openPDFBrowser() }
                }
                .buttonStyle(.bordered)
                .help("Open publisher page to download PDF interactively")
                #endif
            }

            Button("Add PDF...") {
                showFileImporter = true
            }
            .buttonStyle(.bordered)
            .help("Attach a local PDF file")
        }
    }

    private var noPDFLibraryView: some View {
        ContentUnavailableView {
            Label("PDF Available", systemImage: "doc.richtext")
        } description: {
            Text("Download from online source or add a local file.")
        } actions: {
            Button("Download PDF") {
                Task { await downloadPDF() }
            }
            .buttonStyle(.borderedProminent)
            .help("Download PDF from online source")

            #if os(macOS)
            Button("Open in Browser") {
                Task { await openPDFBrowser() }
            }
            .buttonStyle(.bordered)
            .help("Open publisher page to download PDF interactively")
            #endif

            Button("Add PDF...") {
                showFileImporter = true
            }
            .buttonStyle(.bordered)
            .help("Attach a local PDF file")
        }
    }

    private var noPDFView: some View {
        ContentUnavailableView(
            "No PDF",
            systemImage: "doc.richtext",
            description: Text("No PDF is available for this paper.")
        )
    }

    // MARK: - Actions

    private func resetAndCheckPDF() {
        let start = CFAbsoluteTimeGetCurrent()
        Logger.files.infoCapture("[PDFTab] resetAndCheckPDF started", category: "pdf")

        checkPDFTask?.cancel()

        linkedFile = nil
        downloadError = nil
        browserFallbackURL = nil
        isDownloading = false
        hasRemotePDF = false
        isCheckingPDF = true  // Show loading state

        checkPDFTask = Task {
            Logger.files.infoCapture("[PDFTab] checking publication...", category: "pdf")

            // ADR-016: All papers are now CDPublication
            guard let pub = publication else {
                Logger.files.warningCapture("[PDFTab] publication is NIL!", category: "pdf")
                await MainActor.run { isCheckingPDF = false }
                return
            }

            Logger.files.infoCapture("[PDFTab] pub='\(pub.citeKey)', checking linkedFiles...", category: "pdf")

            // Check for linked PDF files
            let linkedFiles = pub.linkedFiles ?? []
            Logger.files.infoCapture("[PDFTab] linkedFiles count = \(linkedFiles.count)", category: "pdf")
            for (i, file) in linkedFiles.enumerated() {
                Logger.files.infoCapture("[PDFTab] linkedFile[\(i)]: \(file.filename), isPDF=\(file.isPDF), path=\(file.relativePath)", category: "pdf")
            }

            if let firstPDF = linkedFiles.first(where: { $0.isPDF }) ?? linkedFiles.first {
                Logger.files.infoCapture("[PDFTab] Found local PDF: \(firstPDF.filename)", category: "pdf")
                await MainActor.run {
                    linkedFile = firstPDF
                    isCheckingPDF = false
                    let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
                    Logger.files.infoCapture("[PDFTab] \(String(format: "%.1f", elapsed))ms (found local PDF)", category: "pdf")
                }
                return
            }

            Logger.files.infoCapture("[PDFTab] No local PDF found, checking remote...", category: "pdf")

            // No local PDF - check if remote PDF is available
            // Check multiple sources: PDFURLResolver, pdfLinks, arxivID from fields
            let resolverHasPDF = PDFURLResolver.hasPDF(publication: pub)
            let hasPdfLinks = !pub.pdfLinks.isEmpty
            let hasArxivID = pub.arxivID != nil
            let hasEprint = pub.fields["eprint"] != nil
            let hasRemote = resolverHasPDF || hasPdfLinks || hasArxivID || hasEprint

            // Debug logging for PDF availability
            let arxivVal = pub.arxivID ?? "nil"
            let eprintVal = pub.fields["eprint"] ?? "nil"
            Logger.files.infoCapture("[PDFTab] PDF check: resolver=\(resolverHasPDF), pdfLinks=\(hasPdfLinks) (\(pub.pdfLinks.count)), arxivID=\(hasArxivID) (\(arxivVal)), eprint=\(hasEprint) (\(eprintVal)), result=\(hasRemote)", category: "pdf")

            // Log pdfLinks details if present
            for (i, link) in pub.pdfLinks.enumerated() {
                let sourceID = link.sourceID ?? "nil"
                Logger.files.infoCapture("[PDFTab] pdfLink[\(i)]: \(link.url.absoluteString) type=\(String(describing: link.type)) source=\(sourceID)", category: "pdf")
            }

            // Log fields if no PDF found
            if !hasRemote {
                let fieldKeys = pub.fields.keys.sorted().joined(separator: ", ")
                Logger.files.warningCapture("[PDFTab] No PDF available. Fields: [\(fieldKeys)]", category: "pdf")
            }

            await MainActor.run {
                hasRemotePDF = hasRemote
                isCheckingPDF = false  // Done checking
            }

            // Auto-download if setting enabled AND remote PDF available AND not multi-selection
            // When multiple papers are selected, don't auto-download - user can use "Download PDFs" menu
            let settings = await PDFSettingsStore.shared.settings
            if settings.autoDownloadEnabled && hasRemote && !isMultiSelection {
                Logger.files.infoCapture("[PDFTab] auto-downloading PDF...", category: "pdf")
                await downloadPDF()
            } else if isMultiSelection && hasRemote {
                Logger.files.infoCapture("[PDFTab] Skipping auto-download (multi-selection mode)", category: "pdf")
            }

            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
            Logger.files.infoCapture("[PDFTab] \(String(format: "%.1f", elapsed))ms (autoDownload=\(settings.autoDownloadEnabled))", category: "pdf")
        }
    }

    private func downloadPDF() async {
        logger.info("[PDFTab] downloadPDF() called - starting download attempt")

        guard let pub = publication else {
            logger.warning("[PDFTab] downloadPDF() FAILED: publication is nil")
            return
        }
        logger.info("[PDFTab] downloadPDF() - publication: \(pub.citeKey)")

        // Use resolveWithDetails to get full resolution info (including browser fallback)
        let settings = await PDFSettingsStore.shared.settings
        let resolution = PDFURLResolver.resolveWithDetails(for: pub, settings: settings)

        // Store browser fallback URL if resolution failed but we have an attempted URL
        await MainActor.run {
            browserFallbackURL = resolution.attemptedURL
        }

        guard let resolvedURL = resolution.url else {
            // Log detailed info about what identifiers were available
            logger.warning("[PDFTab] downloadPDF() FAILED: No URL resolved")
            logger.info("[PDFTab]   pdfLinks: \(pub.pdfLinks.map { $0.url.absoluteString })")
            logger.info("[PDFTab]   arxivID: \(pub.arxivID ?? "nil")")
            logger.info("[PDFTab]   eprint: \(pub.fields["eprint"] ?? "nil")")
            logger.info("[PDFTab]   bibcode: \(pub.bibcodeNormalized ?? "nil")")
            logger.info("[PDFTab]   doi: \(pub.doi ?? "nil")")

            // Always show an error when resolution fails
            await MainActor.run {
                if let attemptedURL = resolution.attemptedURL {
                    logger.info("[PDFTab]   Browser fallback URL available: \(attemptedURL.absoluteString)")
                    downloadError = PDFDownloadError.publisherNotAvailable

                    // Auto-open the built-in browser when resolution fails but we have a fallback URL
                    #if os(macOS)
                    Task {
                        await openPDFBrowserWithURL(attemptedURL)
                    }
                    #endif
                } else {
                    logger.info("[PDFTab]   No browser fallback URL available")
                    downloadError = PDFDownloadError.noPDFAvailable
                }
            }
            return
        }

        // Log if this is a fallback resolution
        if resolution.isFallback {
            logger.info("[PDFTab] Using fallback source: \(resolution.sourceType?.rawValue ?? "unknown") (preferred: \(resolution.preferredSourceType.rawValue))")
        }

        logger.info("[PDFTab] Downloading PDF from: \(resolvedURL.absoluteString)")

        isDownloading = true
        downloadError = nil
        browserFallbackURL = nil  // Clear since we found a URL to try

        do {
            // Download to temp location
            logger.info("[PDFTab] Starting URLSession download...")
            let (tempURL, response) = try await URLSession.shared.download(from: resolvedURL)

            // Log HTTP response details
            if let httpResponse = response as? HTTPURLResponse {
                let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "unknown"
                let contentLength = httpResponse.value(forHTTPHeaderField: "Content-Length") ?? "unknown"
                logger.info("[PDFTab] Download response: HTTP \(httpResponse.statusCode), Content-Type: \(contentType), Content-Length: \(contentLength)")
                if httpResponse.statusCode != 200 {
                    logger.warning("[PDFTab] Non-200 HTTP status! Headers: \(httpResponse.allHeaderFields)")
                }
            } else {
                logger.info("[PDFTab] Download complete (non-HTTP response)")
            }

            // Validate it's actually a PDF (check for %PDF header)
            let fileHandle = try FileHandle(forReadingFrom: tempURL)
            let header = fileHandle.readData(ofLength: 100) // Read more for debugging
            try fileHandle.close()

            // Log header bytes for debugging
            let headerHex = header.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " ")
            logger.info("[PDFTab] PDF validation - first 16 bytes: \(headerHex)")

            guard header.count >= 4,
                  header[0] == 0x25, // %
                  header[1] == 0x50, // P
                  header[2] == 0x44, // D
                  header[3] == 0x46  // F
            else {
                // Not a valid PDF - likely HTML error page
                logger.warning("[PDFTab] Downloaded file is NOT a valid PDF (expected %PDF header)")

                // Log what we actually received (helpful for diagnosing HTML error pages)
                if let headerString = String(data: header, encoding: .utf8) {
                    logger.warning("[PDFTab] Received content preview: \(headerString)")
                }

                try? FileManager.default.removeItem(at: tempURL)
                throw PDFDownloadError.downloadFailed("Downloaded file is not a valid PDF")
            }

            logger.info("[PDFTab] PDF header validation PASSED")

            // Import into library using PDFManager
            guard let library = libraryManager.activeLibrary else {
                logger.error("[PDFTab] No active library for PDF import")
                throw PDFDownloadError.noActiveLibrary
            }

            logger.info("[PDFTab] Importing PDF via PDFManager...")
            try AttachmentManager.shared.importPDF(from: tempURL, for: pub, in: library)
            logger.info("[PDFTab] PDF import SUCCESS")

            // Clean up temp file
            try? FileManager.default.removeItem(at: tempURL)

            await MainActor.run {
                logger.info("[PDFTab] PDF downloaded and imported successfully - refreshing view")
                resetAndCheckPDF()
            }
        } catch {
            logger.error("[PDFTab] Download/import FAILED: \(error.localizedDescription)")
            logger.error("[PDFTab]   Error type: \(type(of: error))")
            if let urlError = error as? URLError {
                logger.error("[PDFTab]   URLError code: \(urlError.code.rawValue)")
            }
            await MainActor.run {
                downloadError = error
                // Store the failed URL as browser fallback so user can try in browser
                browserFallbackURL = resolvedURL

                // Auto-open the built-in browser when download fails
                #if os(macOS)
                Task {
                    await openPDFBrowserWithURL(resolvedURL)
                }
                #endif
            }
        }

        await MainActor.run {
            isDownloading = false
            logger.info("[PDFTab] downloadPDF() complete - isDownloading=false, error=\(downloadError?.localizedDescription ?? "nil")")
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first, let pub = publication else { return }

            Task {
                do {
                    // Import PDF using PDFManager
                    guard let library = libraryManager.activeLibrary else {
                        logger.error("[PDFTab] No active library for PDF import")
                        return
                    }

                    // Import the PDF - PDFManager takes CDPublication directly
                    try AttachmentManager.shared.importPDF(from: url, for: pub, in: library)

                    // Refresh to show the new PDF
                    await MainActor.run {
                        resetAndCheckPDF()
                    }

                    logger.info("[PDFTab] PDF imported successfully")
                } catch {
                    logger.error("[PDFTab] PDF import failed: \(error.localizedDescription)")
                    await MainActor.run {
                        downloadError = error
                    }
                }
            }

        case .failure(let error):
            logger.error("[PDFTab] File import failed: \(error.localizedDescription)")
            downloadError = error
        }
    }

    #if os(macOS)
    private func openPDFBrowser() async {
        guard let pub = publication else { return }
        guard let library = libraryManager.activeLibrary else { return }

        await PDFBrowserWindowController.shared.openBrowser(
            for: pub,
            libraryID: library.id
        ) { [weak libraryManager] data in
            // This is called when user saves the detected PDF
            guard let library = libraryManager?.activeLibrary else { return }
            do {
                try AttachmentManager.shared.importPDF(data: data, for: pub, in: library)
                logger.info("[PDFTab] PDF imported from browser successfully")

                // Post notification to refresh PDF view
                await MainActor.run {
                    NotificationCenter.default.post(name: .pdfImportedFromBrowser, object: pub.objectID)
                }
            } catch {
                logger.error("[PDFTab] Failed to import PDF from browser: \(error)")
            }
        }
    }

    /// Open the built-in PDF browser with a specific URL (used for fallback URLs)
    private func openPDFBrowserWithURL(_ url: URL) async {
        guard let pub = publication else { return }
        guard let library = libraryManager.activeLibrary else { return }

        logger.info("[PDFTab] Opening built-in browser with fallback URL: \(url.absoluteString)")

        await PDFBrowserWindowController.shared.openBrowser(
            for: pub,
            startURL: url,
            libraryID: library.id
        ) { [weak libraryManager] data in
            // This is called when user saves the detected PDF
            guard let library = libraryManager?.activeLibrary else { return }
            do {
                try AttachmentManager.shared.importPDF(data: data, for: pub, in: library)
                logger.info("[PDFTab] PDF imported from browser successfully")

                // Post notification to refresh PDF view
                await MainActor.run {
                    NotificationCenter.default.post(name: .pdfImportedFromBrowser, object: pub.objectID)
                }
            } catch {
                logger.error("[PDFTab] Failed to import PDF from browser: \(error)")
            }
        }
    }
    #endif

    private func handleCorruptPDF(_ corruptFile: CDLinkedFile) async {
        logger.warning("[PDFTab] Corrupt PDF detected, attempting recovery: \(corruptFile.filename)")

        do {
            // 1. Delete corrupt file from disk and Core Data
            try AttachmentManager.shared.delete(corruptFile, in: libraryManager.activeLibrary)

            // 2. Reset state and trigger re-download
            await MainActor.run {
                linkedFile = nil
                resetAndCheckPDF()  // Will see no local PDF and try to download
            }

            logger.info("[PDFTab] Corrupt PDF cleanup complete, re-downloading...")
        } catch {
            logger.error("[PDFTab] Failed to clean up corrupt PDF: \(error)")
            await MainActor.run {
                downloadError = error
            }
        }
    }
}
