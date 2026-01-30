//
//  PDFViewer.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-04.
//

import SwiftUI
import PDFKit
import OSLog

// MARK: - Notification Names

extension Notification.Name {
    static let pdfViewerNavigateToSelection = Notification.Name("pdfViewerNavigateToSelection")
}

// MARK: - PDF Viewer

/// Cross-platform PDF viewer using PDFKit.
///
/// Supports:
/// - Loading from file URL or data
/// - Zoom controls
/// - Page navigation
/// - Search (future)
/// - Thumbnails (future)
public struct PDFKitViewer: View {

    // MARK: - Properties

    private let source: PDFSource
    @State private var pdfDocument: PDFDocument?
    @State private var error: PDFViewerError?
    @State private var isLoading = true

    // MARK: - Initialization

    /// Create viewer for a file URL
    public init(url: URL) {
        self.source = .url(url)
    }

    /// Create viewer for PDF data
    public init(data: Data) {
        self.source = .data(data)
    }

    /// Create viewer for a linked file (resolves path relative to library)
    public init(linkedFile: CDLinkedFile, library: CDLibrary? = nil) {
        // Normalize unicode to match how PDFManager saved the file
        let normalizedPath = linkedFile.relativePath.precomposedStringWithCanonicalMapping
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("imbib")

        if let library = library {
            // Primary: container-based path (iCloud-only storage)
            let containerURL = library.containerURL.appendingPathComponent(normalizedPath)

            // Fallback: legacy path (pre-v1.3.0 downloads went to imbib/Papers/)
            let legacyURL = appSupport.appendingPathComponent(normalizedPath)

            if fileManager.fileExists(atPath: containerURL.path) {
                Logger.files.debugCapture("PDFKitViewer resolving path: \(containerURL.path)", category: "pdf")
                self.source = .url(containerURL)
            } else if fileManager.fileExists(atPath: legacyURL.path) {
                Logger.files.debugCapture("PDFKitViewer using legacy path: \(legacyURL.path)", category: "pdf")
                self.source = .url(legacyURL)
            } else if let fileData = linkedFile.fileData {
                // File not on disk but fileData exists (synced from another device via CloudKit)
                // Write to disk for this session and future use
                Logger.files.infoCapture("PDFKitViewer restoring file from CloudKit fileData: \(containerURL.lastPathComponent)", category: "pdf")
                do {
                    // Create directory if needed
                    let directoryURL = containerURL.deletingLastPathComponent()
                    if !fileManager.fileExists(atPath: directoryURL.path) {
                        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
                    }
                    try fileData.write(to: containerURL)
                    Logger.files.infoCapture("Successfully restored \(fileData.count) bytes to disk", category: "pdf")
                    self.source = .url(containerURL)
                } catch {
                    Logger.files.errorCapture("Failed to write fileData to disk: \(error.localizedDescription)", category: "pdf")
                    // Fall back to loading from data directly
                    self.source = .data(fileData)
                }
            } else {
                // File not found at either location and no fileData - use container path (will show error)
                Logger.files.warningCapture("PDFKitViewer file not found: \(containerURL.path)", category: "pdf")
                self.source = .url(containerURL)
            }
        } else {
            // No library - check default library path and legacy path
            let defaultURL = appSupport.appendingPathComponent("DefaultLibrary/\(normalizedPath)")
            let legacyURL = appSupport.appendingPathComponent(normalizedPath)

            if fileManager.fileExists(atPath: defaultURL.path) {
                self.source = .url(defaultURL)
            } else if fileManager.fileExists(atPath: legacyURL.path) {
                self.source = .url(legacyURL)
            } else if let fileData = linkedFile.fileData {
                // File not on disk but fileData exists - use data directly
                Logger.files.infoCapture("PDFKitViewer loading from CloudKit fileData (no library)", category: "pdf")
                self.source = .data(fileData)
            } else {
                self.source = .url(defaultURL)
            }
        }
    }

    // MARK: - Body

    public var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading PDF...")
            } else if let error {
                errorView(error)
            } else if let document = pdfDocument {
                PDFKitViewRepresentable(document: document)
                    .accessibilityIdentifier(AccessibilityID.Detail.PDF.viewer)
            } else {
                errorView(.documentNotLoaded)
            }
        }
        .task {
            await loadDocument()
        }
    }

    // MARK: - Loading

    private func loadDocument() async {
        isLoading = true
        error = nil

        do {
            let document = try await loadPDFDocument()
            await MainActor.run {
                self.pdfDocument = document
                self.isLoading = false
            }
        } catch let err as PDFViewerError {
            await MainActor.run {
                self.error = err
                self.isLoading = false
            }
        } catch {
            await MainActor.run {
                self.error = .loadFailed(error)
                self.isLoading = false
            }
        }
    }

    private func loadPDFDocument() async throws -> PDFDocument {
        switch source {
        case .url(let url):
            Logger.files.debugCapture("Loading PDF from: \(url.path)", category: "pdf")

            // Check if file exists
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw PDFViewerError.fileNotFound(url)
            }

            // Try to access security-scoped resource
            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing { url.stopAccessingSecurityScopedResource() }
            }

            guard let document = PDFDocument(url: url) else {
                throw PDFViewerError.invalidPDF(url)
            }

            Logger.files.infoCapture("Loaded PDF with \(document.pageCount) pages", category: "pdf")
            return document

        case .data(let data):
            Logger.files.debugCapture("Loading PDF from data (\(data.count) bytes)", category: "pdf")

            guard let document = PDFDocument(data: data) else {
                throw PDFViewerError.invalidData
            }

            Logger.files.infoCapture("Loaded PDF with \(document.pageCount) pages", category: "pdf")
            return document
        }
    }

    // MARK: - Error View

    @ViewBuilder
    private func errorView(_ error: PDFViewerError) -> some View {
        ContentUnavailableView {
            Label("Unable to Load PDF", systemImage: "exclamationmark.triangle")
        } description: {
            Text(error.localizedDescription)
        } actions: {
            Button("Try Again") {
                Task { await loadDocument() }
            }
        }
    }
}

// MARK: - PDF Source

private enum PDFSource {
    case url(URL)
    case data(Data)
}

// MARK: - PDF Viewer Error

public enum PDFViewerError: LocalizedError {
    case fileNotFound(URL)
    case invalidPDF(URL)
    case corruptPDF(URL)  // HTML or other non-PDF content saved as .pdf
    case invalidData
    case documentNotLoaded
    case loadFailed(Error)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let url):
            return "PDF file not found: \(url.lastPathComponent)"
        case .invalidPDF(let url):
            return "Invalid or corrupted PDF: \(url.lastPathComponent)"
        case .corruptPDF(let url):
            return "PDF file is corrupt (not a valid PDF): \(url.lastPathComponent)"
        case .invalidData:
            return "Invalid PDF data"
        case .documentNotLoaded:
            return "PDF document could not be loaded"
        case .loadFailed(let error):
            return "Failed to load PDF: \(error.localizedDescription)"
        }
    }
}

// MARK: - Platform-Specific PDFKit View

#if os(macOS)

/// macOS PDFKit wrapper (basic, read-only)
struct PDFKitViewRepresentable: NSViewRepresentable {
    let document: PDFDocument

    func makeNSView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.document = document
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.backgroundColor = .textBackgroundColor
        return pdfView
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        if pdfView.document !== document {
            pdfView.document = document
        }
    }
}

/// Custom PDFView subclass that can suppress context menus in annotation mode
class AnnotationModePDFView: PDFView {
    var isAnnotationMode: Bool = false

    override func menu(for event: NSEvent) -> NSMenu? {
        // Suppress context menu when in annotation mode
        if isAnnotationMode {
            return nil
        }
        return super.menu(for: event)
    }
}

/// macOS PDFKit wrapper with controls and annotation support
struct ControlledPDFKitView: NSViewRepresentable {
    let document: PDFDocument
    @Binding var currentPage: Int
    @Binding var scaleFactor: CGFloat
    @Binding var hasSelection: Bool
    var isAnnotationMode: Bool = false
    var darkModeEnabled: Bool = false
    var pdfViewRef: ((PDFView?) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> AnnotationModePDFView {
        let pdfView = AnnotationModePDFView()
        pdfView.document = document
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.backgroundColor = darkModeEnabled ? .black : .textBackgroundColor
        pdfView.isAnnotationMode = isAnnotationMode

        // Apply color inversion filter for dark mode
        if darkModeEnabled {
            applyDarkModeFilter(to: pdfView)
        }

        // Observe page changes
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.pageChanged(_:)),
            name: .PDFViewPageChanged,
            object: pdfView
        )

        // Observe scale changes
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.scaleChanged(_:)),
            name: .PDFViewScaleChanged,
            object: pdfView
        )

        // Observe selection changes for annotation support
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.selectionChanged(_:)),
            name: .PDFViewSelectionChanged,
            object: pdfView
        )

        // Observe search navigation requests
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.navigateToSelection(_:)),
            name: .pdfViewerNavigateToSelection,
            object: nil
        )

        // Observe annotation action requests
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.handleHighlight(_:)),
            name: .highlightSelection,
            object: nil
        )
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.handleUnderline(_:)),
            name: .underlineSelection,
            object: nil
        )
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.handleStrikethrough(_:)),
            name: .strikethroughSelection,
            object: nil
        )

        context.coordinator.pdfView = pdfView

        // Pass reference back to parent
        DispatchQueue.main.async {
            pdfViewRef?(pdfView)
        }

        return pdfView
    }

    /// Applies a color inversion filter for PDF dark mode reading
    private func applyDarkModeFilter(to pdfView: PDFView) {
        // Use Core Image filter to invert colors
        if let filter = CIFilter(name: "CIColorInvert") {
            pdfView.layer?.filters = [filter]
            pdfView.layer?.backgroundColor = NSColor.black.cgColor
        }
    }

    /// Removes the dark mode filter
    private func removeDarkModeFilter(from pdfView: PDFView) {
        pdfView.layer?.filters = nil
        pdfView.layer?.backgroundColor = nil
    }

    func updateNSView(_ pdfView: AnnotationModePDFView, context: Context) {
        if pdfView.document !== document {
            pdfView.document = document
        }

        // Update annotation mode
        pdfView.isAnnotationMode = isAnnotationMode

        // Update dark mode
        if darkModeEnabled {
            if pdfView.layer?.filters?.isEmpty ?? true {
                applyDarkModeFilter(to: pdfView)
            }
            pdfView.backgroundColor = .black
        } else {
            removeDarkModeFilter(from: pdfView)
            pdfView.backgroundColor = .textBackgroundColor
        }

        // Update page if changed externally
        if let page = pdfView.document?.page(at: currentPage - 1),
           pdfView.currentPage !== page {
            pdfView.go(to: page)
        }

        // Update scale if changed externally
        let targetScale = scaleFactor
        if abs(pdfView.scaleFactor - targetScale) > 0.01 {
            pdfView.scaleFactor = targetScale
        }
    }

    class Coordinator: NSObject {
        var parent: ControlledPDFKitView
        weak var pdfView: AnnotationModePDFView?

        init(_ parent: ControlledPDFKitView) {
            self.parent = parent
        }

        @objc func pageChanged(_ notification: Notification) {
            guard let pdfView = pdfView,
                  let currentPage = pdfView.currentPage,
                  let document = pdfView.document else { return }

            let pageIndex = document.index(for: currentPage)

            DispatchQueue.main.async { [weak self] in
                self?.parent.currentPage = pageIndex + 1
            }
        }

        @objc func scaleChanged(_ notification: Notification) {
            guard let pdfView = pdfView else { return }
            let scale = pdfView.scaleFactor
            DispatchQueue.main.async { [weak self] in
                self?.parent.scaleFactor = scale
            }
        }

        @objc func selectionChanged(_ notification: Notification) {
            guard let pdfView = pdfView else { return }
            let hasSelection = pdfView.currentSelection != nil

            DispatchQueue.main.async { [weak self] in
                self?.parent.hasSelection = hasSelection
            }
        }

        @objc func navigateToSelection(_ notification: Notification) {
            guard let pdfView = pdfView,
                  let selection = notification.userInfo?["selection"] as? PDFSelection else { return }

            DispatchQueue.main.async {
                pdfView.setCurrentSelection(selection, animate: true)
                pdfView.scrollSelectionToVisible(nil)
            }
        }

        // MARK: - Annotation Handlers

        @objc func handleHighlight(_ notification: Notification) {
            guard let pdfView = pdfView else { return }

            // Get color from notification or use default
            let color: HighlightColor
            if let colorName = notification.userInfo?["color"] as? String,
               let highlightColor = HighlightColor(rawValue: colorName) {
                color = highlightColor
            } else {
                color = .yellow
            }

            DispatchQueue.main.async {
                _ = AnnotationService.shared.addHighlight(to: pdfView, color: color)
                NotificationCenter.default.post(name: .annotationsDidChange, object: nil)
            }
        }

        @objc func handleUnderline(_ notification: Notification) {
            guard let pdfView = pdfView else { return }

            DispatchQueue.main.async {
                _ = AnnotationService.shared.addUnderline(to: pdfView)
                NotificationCenter.default.post(name: .annotationsDidChange, object: nil)
            }
        }

        @objc func handleStrikethrough(_ notification: Notification) {
            guard let pdfView = pdfView else { return }

            DispatchQueue.main.async {
                _ = AnnotationService.shared.addStrikethrough(to: pdfView)
                NotificationCenter.default.post(name: .annotationsDidChange, object: nil)
            }
        }
    }
}

#else

/// iOS/iPadOS PDFKit wrapper (basic, read-only)
struct PDFKitViewRepresentable: UIViewRepresentable {
    let document: PDFDocument

    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.document = document
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.backgroundColor = .systemBackground
        return pdfView
    }

    func updateUIView(_ pdfView: PDFView, context: Context) {
        if pdfView.document !== document {
            pdfView.document = document
        }
    }
}

/// Custom PDFView subclass for iOS that can suppress edit menus in annotation mode
class AnnotationModePDFViewiOS: PDFView {
    var isAnnotationMode: Bool = false

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        // In annotation mode, suppress standard edit actions (Copy, Select All, etc.)
        if isAnnotationMode {
            let suppressedActions: [Selector] = [
                #selector(copy(_:)),
                #selector(selectAll(_:)),
                #selector(cut(_:)),
                #selector(paste(_:)),
                #selector(select(_:)),
                NSSelectorFromString("_share:"),
                NSSelectorFromString("_lookup:"),
                NSSelectorFromString("_translate:"),
                NSSelectorFromString("_define:")
            ]
            if suppressedActions.contains(action) {
                return false
            }
        }
        return super.canPerformAction(action, withSender: sender)
    }

    // Also suppress the edit menu interaction on iOS 16+
    override func buildMenu(with builder: UIMenuBuilder) {
        if isAnnotationMode {
            // Remove standard edit menu items in annotation mode
            builder.remove(menu: .standardEdit)
            builder.remove(menu: .lookup)
            builder.remove(menu: .share)
        }
        super.buildMenu(with: builder)
    }
}

/// iOS PDFKit wrapper with controls and annotation support
struct ControlledPDFKitView: UIViewRepresentable {
    let document: PDFDocument
    @Binding var currentPage: Int
    @Binding var scaleFactor: CGFloat
    @Binding var hasSelection: Bool
    @Binding var canGoBack: Bool
    @Binding var canGoForward: Bool
    var isAnnotationMode: Bool = false
    var darkModeEnabled: Bool = false
    var pdfViewRef: ((PDFView?) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> AnnotationModePDFViewiOS {
        let pdfView = AnnotationModePDFViewiOS()
        pdfView.document = document
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.backgroundColor = darkModeEnabled ? .black : .systemBackground
        pdfView.isAnnotationMode = isAnnotationMode

        // Apply color inversion filter for dark mode
        if darkModeEnabled {
            applyDarkModeFilter(to: pdfView)
        }

        // Add swipe gesture for back navigation
        let swipeRight = UISwipeGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleSwipeBack(_:)))
        swipeRight.direction = .right
        swipeRight.numberOfTouchesRequired = 2  // Two-finger swipe to avoid conflicts with scrolling
        pdfView.addGestureRecognizer(swipeRight)

        // Add swipe gesture for forward navigation
        let swipeLeft = UISwipeGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleSwipeForward(_:)))
        swipeLeft.direction = .left
        swipeLeft.numberOfTouchesRequired = 2
        pdfView.addGestureRecognizer(swipeLeft)

        // Observe page changes
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.pageChanged(_:)),
            name: .PDFViewPageChanged,
            object: pdfView
        )

        // Observe scale changes
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.scaleChanged(_:)),
            name: .PDFViewScaleChanged,
            object: pdfView
        )

        // Observe selection changes for annotation support
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.selectionChanged(_:)),
            name: .PDFViewSelectionChanged,
            object: pdfView
        )

        // Observe search navigation requests
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.navigateToSelection(_:)),
            name: .pdfViewerNavigateToSelection,
            object: nil
        )

        // Observe annotation action requests
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.handleHighlight(_:)),
            name: .highlightSelection,
            object: nil
        )
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.handleUnderline(_:)),
            name: .underlineSelection,
            object: nil
        )
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.handleStrikethrough(_:)),
            name: .strikethroughSelection,
            object: nil
        )

        // Observe history changes for back/forward navigation
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.historyChanged(_:)),
            name: .PDFViewVisiblePagesChanged,
            object: pdfView
        )

        context.coordinator.pdfView = pdfView

        // Pass reference back to parent and update initial history state
        DispatchQueue.main.async {
            pdfViewRef?(pdfView)
            // Update initial back/forward state
            context.coordinator.updateHistoryState()
        }

        return pdfView
    }

    /// Applies a color inversion filter for PDF dark mode reading
    private func applyDarkModeFilter(to pdfView: PDFView) {
        // Use Core Image filter to invert colors
        if let filter = CIFilter(name: "CIColorInvert") {
            pdfView.layer.filters = [filter]
            pdfView.layer.backgroundColor = UIColor.black.cgColor
        }
    }

    /// Removes the dark mode filter
    private func removeDarkModeFilter(from pdfView: PDFView) {
        pdfView.layer.filters = nil
        pdfView.layer.backgroundColor = nil
    }

    func updateUIView(_ pdfView: AnnotationModePDFViewiOS, context: Context) {
        if pdfView.document !== document {
            pdfView.document = document
        }

        // Update annotation mode
        pdfView.isAnnotationMode = isAnnotationMode

        // Update dark mode
        if darkModeEnabled {
            if pdfView.layer.filters?.isEmpty ?? true {
                applyDarkModeFilter(to: pdfView)
            }
            pdfView.backgroundColor = .black
        } else {
            removeDarkModeFilter(from: pdfView)
            pdfView.backgroundColor = .systemBackground
        }

        // Update page if changed externally
        if let page = pdfView.document?.page(at: currentPage - 1),
           pdfView.currentPage !== page {
            pdfView.go(to: page)
        }

        // Update scale if changed externally
        let targetScale = scaleFactor
        if abs(pdfView.scaleFactor - targetScale) > 0.01 {
            pdfView.scaleFactor = targetScale
        }

        // Sync history state
        context.coordinator.updateHistoryState()
    }

    class Coordinator: NSObject {
        var parent: ControlledPDFKitView
        weak var pdfView: AnnotationModePDFViewiOS?

        init(_ parent: ControlledPDFKitView) {
            self.parent = parent
        }

        func updateHistoryState() {
            guard let pdfView = pdfView else { return }
            DispatchQueue.main.async { [weak self] in
                self?.parent.canGoBack = pdfView.canGoBack
                self?.parent.canGoForward = pdfView.canGoForward
            }
        }

        @objc func pageChanged(_ notification: Notification) {
            guard let pdfView = pdfView,
                  let currentPage = pdfView.currentPage,
                  let document = pdfView.document else { return }

            let pageIndex = document.index(for: currentPage)

            DispatchQueue.main.async { [weak self] in
                self?.parent.currentPage = pageIndex + 1
            }

            // Update history state after page change
            updateHistoryState()
        }

        @objc func scaleChanged(_ notification: Notification) {
            guard let pdfView = pdfView else { return }
            let scale = pdfView.scaleFactor
            DispatchQueue.main.async { [weak self] in
                self?.parent.scaleFactor = scale
            }
        }

        @objc func historyChanged(_ notification: Notification) {
            updateHistoryState()
        }

        @objc func handleSwipeBack(_ gesture: UISwipeGestureRecognizer) {
            guard let pdfView = pdfView, pdfView.canGoBack else { return }
            pdfView.goBack(nil)
            updateHistoryState()
        }

        @objc func handleSwipeForward(_ gesture: UISwipeGestureRecognizer) {
            guard let pdfView = pdfView, pdfView.canGoForward else { return }
            pdfView.goForward(nil)
            updateHistoryState()
        }

        @objc func selectionChanged(_ notification: Notification) {
            guard let pdfView = pdfView else { return }
            let hasSelection = pdfView.currentSelection != nil

            DispatchQueue.main.async { [weak self] in
                self?.parent.hasSelection = hasSelection
            }
        }

        @objc func navigateToSelection(_ notification: Notification) {
            guard let pdfView = pdfView,
                  let selection = notification.userInfo?["selection"] as? PDFSelection else { return }

            DispatchQueue.main.async {
                pdfView.setCurrentSelection(selection, animate: true)
                pdfView.scrollSelectionToVisible(nil)
            }
        }

        // MARK: - Annotation Handlers

        @objc func handleHighlight(_ notification: Notification) {
            guard let pdfView = pdfView else { return }

            let color: HighlightColor
            if let colorName = notification.userInfo?["color"] as? String,
               let highlightColor = HighlightColor(rawValue: colorName) {
                color = highlightColor
            } else {
                color = .yellow
            }

            DispatchQueue.main.async {
                _ = AnnotationService.shared.addHighlight(to: pdfView, color: color)
                NotificationCenter.default.post(name: .annotationsDidChange, object: nil)
            }
        }

        @objc func handleUnderline(_ notification: Notification) {
            guard let pdfView = pdfView else { return }

            DispatchQueue.main.async {
                _ = AnnotationService.shared.addUnderline(to: pdfView)
                NotificationCenter.default.post(name: .annotationsDidChange, object: nil)
            }
        }

        @objc func handleStrikethrough(_ notification: Notification) {
            guard let pdfView = pdfView else { return }

            DispatchQueue.main.async {
                _ = AnnotationService.shared.addStrikethrough(to: pdfView)
                NotificationCenter.default.post(name: .annotationsDidChange, object: nil)
            }
        }
    }
}

#endif

// MARK: - Online Paper PDF Viewer

// Note: OnlinePaperPDFViewer has been removed as part of ADR-016.
// PDFs for all papers (including search results) are now handled via PDFManager
// which downloads and stores PDFs in the library folder as linked files.

// MARK: - PDF Viewer with Controls

/// PDF viewer with toolbar controls for zoom and navigation.
public struct PDFViewerWithControls: View {

    // MARK: - Properties

    private let source: PDFSource
    private let publicationID: UUID?
    private let linkedFile: CDLinkedFile?

    /// Called when a corrupt PDF is detected (HTML content saved as .pdf)
    /// Parent can use this to delete and re-download
    public var onCorruptPDF: ((CDLinkedFile) -> Void)?

    @State private var pdfDocument: PDFDocument?
    @State private var error: PDFViewerError?
    @State private var isLoading = true
    @State private var currentPage = 1
    @State private var totalPages = 0
    /// Global zoom level - persists across paper switches via UserDefaults
    @AppStorage("global_pdf_zoom_level") private var scaleFactor: Double = 1.0
    @State private var saveTask: Task<Void, Never>?

    /// CGFloat binding for ControlledPDFKitView compatibility
    private var scaleFactorBinding: Binding<CGFloat> {
        Binding(
            get: { CGFloat(scaleFactor) },
            set: { scaleFactor = Double($0) }
        )
    }

    // Search state
    @State private var searchQuery: String = ""
    @State private var searchResults: [PDFSelection] = []
    @State private var currentSearchIndex: Int = 0
    @State private var isSearching: Bool = false
    @State private var isSearchVisible: Bool = false  // iOS: expandable search bar

    // Navigation history state (for back/forward after following links)
    @State private var canGoBack: Bool = false
    @State private var canGoForward: Bool = false

    // Annotation state
    @State private var hasSelection: Bool = false
    @State private var hasUnsavedAnnotations: Bool = false
    @State private var highlightColor: HighlightColor = .yellow
    @State private var showAnnotationToolbar: Bool = false
    @State private var selectedAnnotationTool: AnnotationTool? = nil
    @State private var pdfViewReference: PDFView? = nil

    // PDF dark mode (from settings)
    @State private var pdfDarkModeEnabled: Bool = PDFSettingsStore.loadSettingsSync().darkModeEnabled

    // iOS fullscreen state
    #if os(iOS)
    @Binding private var isFullscreen: Bool
    @State private var showBackButton: Bool = true
    @State private var hideBackButtonTask: Task<Void, Never>?
    #endif

    // MARK: - Initialization

    #if os(iOS)
    public init(url: URL, publicationID: UUID? = nil, isFullscreen: Binding<Bool> = .constant(false), onCorruptPDF: ((CDLinkedFile) -> Void)? = nil) {
        self.source = .url(url)
        self.publicationID = publicationID
        self.linkedFile = nil
        self._isFullscreen = isFullscreen
        self.onCorruptPDF = onCorruptPDF
    }

    public init(data: Data, publicationID: UUID? = nil, isFullscreen: Binding<Bool> = .constant(false)) {
        self.source = .data(data)
        self.publicationID = publicationID
        self.linkedFile = nil
        self._isFullscreen = isFullscreen
        self.onCorruptPDF = nil
    }

    public init(linkedFile: CDLinkedFile, library: CDLibrary? = nil, publicationID: UUID? = nil, isFullscreen: Binding<Bool> = .constant(false), onCorruptPDF: ((CDLinkedFile) -> Void)? = nil) {
        // Normalize unicode to match how PDFManager saved the file
        let normalizedPath = linkedFile.relativePath.precomposedStringWithCanonicalMapping
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("imbib")

        if let library = library {
            // Primary: container-based path (iCloud-only storage)
            let containerURL = library.containerURL.appendingPathComponent(normalizedPath)
            // Fallback: legacy path (pre-v1.3.0 downloads went to imbib/Papers/)
            let legacyURL = appSupport.appendingPathComponent(normalizedPath)

            if fileManager.fileExists(atPath: containerURL.path) {
                self.source = .url(containerURL)
            } else if fileManager.fileExists(atPath: legacyURL.path) {
                // Log only for legacy path usage (useful for migration tracking)
                Logger.files.debugCapture("PDFViewerWithControls using legacy path: \(legacyURL.lastPathComponent)", category: "pdf")
                self.source = .url(legacyURL)
            } else {
                Logger.files.warningCapture("PDFViewerWithControls file not found: \(containerURL.lastPathComponent)", category: "pdf")
                self.source = .url(containerURL)
            }
        } else {
            let defaultURL = appSupport.appendingPathComponent("DefaultLibrary/\(normalizedPath)")
            let legacyURL = appSupport.appendingPathComponent(normalizedPath)
            if fileManager.fileExists(atPath: defaultURL.path) {
                self.source = .url(defaultURL)
            } else if fileManager.fileExists(atPath: legacyURL.path) {
                self.source = .url(legacyURL)
            } else {
                self.source = .url(defaultURL)
            }
        }
        self.publicationID = publicationID
        self.linkedFile = linkedFile
        self._isFullscreen = isFullscreen
        self.onCorruptPDF = onCorruptPDF
    }
    #else
    public init(url: URL, publicationID: UUID? = nil, onCorruptPDF: ((CDLinkedFile) -> Void)? = nil) {
        self.source = .url(url)
        self.publicationID = publicationID
        self.linkedFile = nil
        self.onCorruptPDF = onCorruptPDF
    }

    public init(data: Data, publicationID: UUID? = nil) {
        self.source = .data(data)
        self.publicationID = publicationID
        self.linkedFile = nil
        self.onCorruptPDF = nil
    }

    public init(linkedFile: CDLinkedFile, library: CDLibrary? = nil, publicationID: UUID? = nil, onCorruptPDF: ((CDLinkedFile) -> Void)? = nil) {
        // Normalize unicode to match how PDFManager saved the file
        let normalizedPath = linkedFile.relativePath.precomposedStringWithCanonicalMapping
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("imbib")

        if let library = library {
            // Primary: container-based path (iCloud-only storage)
            let containerURL = library.containerURL.appendingPathComponent(normalizedPath)
            // Fallback: legacy path (pre-v1.3.0 downloads went to imbib/Papers/)
            let legacyURL = appSupport.appendingPathComponent(normalizedPath)

            if fileManager.fileExists(atPath: containerURL.path) {
                self.source = .url(containerURL)
            } else if fileManager.fileExists(atPath: legacyURL.path) {
                // Log only for legacy path usage (useful for migration tracking)
                Logger.files.debugCapture("PDFViewerWithControls using legacy path: \(legacyURL.lastPathComponent)", category: "pdf")
                self.source = .url(legacyURL)
            } else {
                Logger.files.warningCapture("PDFViewerWithControls file not found: \(containerURL.lastPathComponent)", category: "pdf")
                self.source = .url(containerURL)
            }
        } else {
            let defaultURL = appSupport.appendingPathComponent("DefaultLibrary/\(normalizedPath)")
            let legacyURL = appSupport.appendingPathComponent(normalizedPath)
            if fileManager.fileExists(atPath: defaultURL.path) {
                self.source = .url(defaultURL)
            } else if fileManager.fileExists(atPath: legacyURL.path) {
                self.source = .url(legacyURL)
            } else {
                self.source = .url(defaultURL)
            }
        }
        self.publicationID = publicationID
        self.linkedFile = linkedFile
        self.onCorruptPDF = onCorruptPDF
    }
    #endif

    // Toolbar position for alignment
    @AppStorage("annotationToolbarPosition") private var toolbarPositionRaw: String = "top"

    private var toolbarPosition: AnnotationToolbarPosition {
        AnnotationToolbarPosition(rawValue: toolbarPositionRaw) ?? .top
    }

    /// Padding for the toolbar based on its position
    private var toolbarPadding: EdgeInsets {
        switch toolbarPosition {
        case .top: return EdgeInsets(top: 8, leading: 0, bottom: 0, trailing: 0)
        case .bottom: return EdgeInsets(top: 0, leading: 0, bottom: 8, trailing: 0)
        case .left: return EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 0)
        case .right: return EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 8)
        }
    }

    // MARK: - Body

    public var body: some View {
        #if os(iOS)
        // iOS: Support fullscreen mode
        ZStack {
            if isFullscreen {
                fullscreenPDFView
            } else {
                normalPDFView
            }
        }
        .task {
            await loadDocument()
        }
        .onChange(of: currentPage) { _, newPage in
            schedulePositionSave()
        }
        .onChange(of: scaleFactor) { _, newScale in
            schedulePositionSave()
        }
        .onDisappear {
            savePositionImmediately()
        }
        .onReceive(NotificationCenter.default.publisher(for: .pdfSearchRequested)) { notification in
            if let query = notification.userInfo?["query"] as? String {
                // Trigger search in this PDF viewer
                searchQuery = query
                isSearchVisible = true
                performSearch()
            }
        }
        #else
        // macOS: Always show normal view
        normalPDFView
        #endif
    }

    // MARK: - Normal PDF View

    private var normalPDFView: some View {
        VStack(spacing: 0) {
            ZStack(alignment: toolbarPosition.alignment) {
                // PDF Content
                pdfContent
                    #if os(iOS)
                    // Only allow tap-to-fullscreen when NOT in annotation mode
                    // In annotation mode, taps should be handled by PDFView for text selection
                    .onTapGesture {
                        if !showAnnotationToolbar {
                            enterFullscreen()
                        }
                    }
                    #endif

                // Floating annotation toolbar
                if showAnnotationToolbar && pdfDocument != nil {
                    AnnotationToolbar(
                        selectedTool: $selectedAnnotationTool,
                        highlightColor: $highlightColor,
                        hasSelection: hasSelection,
                        onHighlight: highlightSelection,
                        onUnderline: underlineSelection,
                        onStrikethrough: strikethroughSelection,
                        onAddNote: addNoteAtSelection
                    )
                    .padding(toolbarPadding)
                }
            }

            // Toolbar
            if pdfDocument != nil {
                pdfToolbar
            }
        }
        // macOS: modifiers here since body returns normalPDFView directly
        // iOS: modifiers are on the body's ZStack to apply to both fullscreen and normal views
        #if os(macOS)
        .task {
            await loadDocument()
        }
        .onChange(of: currentPage) { _, newPage in
            schedulePositionSave()
        }
        .onChange(of: scaleFactor) { _, newScale in
            schedulePositionSave()
        }
        .onDisappear {
            savePositionImmediately()
        }
        .onReceive(NotificationCenter.default.publisher(for: .pdfPageDown)) { _ in
            pageDown()
        }
        .onReceive(NotificationCenter.default.publisher(for: .pdfPageUp)) { _ in
            pageUp()
        }
        .onReceive(NotificationCenter.default.publisher(for: .pdfScrollHalfPageDown)) { _ in
            scrollHalfPageDown()
        }
        .onReceive(NotificationCenter.default.publisher(for: .pdfScrollHalfPageUp)) { _ in
            scrollHalfPageUp()
        }
        .onReceive(NotificationCenter.default.publisher(for: .pdfZoomIn)) { _ in
            zoomIn()
        }
        .onReceive(NotificationCenter.default.publisher(for: .pdfZoomOut)) { _ in
            zoomOut()
        }
        .onReceive(NotificationCenter.default.publisher(for: .pdfActualSize)) { _ in
            resetZoom()
        }
        .onReceive(NotificationCenter.default.publisher(for: .pdfFitToWindow)) { _ in
            fitToWindow()
        }
        .onReceive(NotificationCenter.default.publisher(for: .pdfGoToPage)) { _ in
            // Future: show go-to-page dialog
        }
        #endif
    }

    // MARK: - PDF Content

    @ViewBuilder
    private var pdfContent: some View {
        if isLoading {
            ProgressView("Loading PDF...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error {
            errorView(error)
        } else if let document = pdfDocument {
            #if os(iOS)
            ControlledPDFKitView(
                document: document,
                currentPage: $currentPage,
                scaleFactor: scaleFactorBinding,
                hasSelection: $hasSelection,
                canGoBack: $canGoBack,
                canGoForward: $canGoForward,
                isAnnotationMode: showAnnotationToolbar,
                darkModeEnabled: pdfDarkModeEnabled,
                pdfViewRef: { pdfViewReference = $0 }
            )
            #else
            ControlledPDFKitView(
                document: document,
                currentPage: $currentPage,
                scaleFactor: scaleFactorBinding,
                hasSelection: $hasSelection,
                isAnnotationMode: showAnnotationToolbar,
                darkModeEnabled: pdfDarkModeEnabled,
                pdfViewRef: { pdfViewReference = $0 }
            )
            #endif
        } else {
            errorView(.documentNotLoaded)
        }
    }

    // MARK: - iOS Fullscreen Mode

    #if os(iOS)
    private var fullscreenPDFView: some View {
        ZStack(alignment: toolbarPosition.alignment) {
            // Full PDF content (centered, fills screen)
            pdfContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
                .onTapGesture {
                    // Show back button and reset hide timer
                    showBackButtonTemporarily()
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            showBackButtonTemporarily()
                        }
                )

            // Floating annotation toolbar (persists in fullscreen when annotation mode is active)
            if showAnnotationToolbar && pdfDocument != nil {
                AnnotationToolbar(
                    selectedTool: $selectedAnnotationTool,
                    highlightColor: $highlightColor,
                    hasSelection: hasSelection,
                    onHighlight: highlightSelection,
                    onUnderline: underlineSelection,
                    onStrikethrough: strikethroughSelection,
                    onAddNote: addNoteAtSelection
                )
                .padding(fullscreenToolbarPadding)
            }

            // Floating back button (top-left, always on top)
            VStack {
                HStack {
                    if showBackButton {
                        Button {
                            exitFullscreen()
                        } label: {
                            Image(systemName: "chevron.left.circle.fill")
                                .font(.system(size: 36))
                                .foregroundStyle(.white, .black.opacity(0.6))
                                .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)
                        }
                        .padding(.top, 60)  // Account for status bar
                        .padding(.leading, 20)
                        .transition(.opacity)
                    }
                    Spacer()
                }
                Spacer()
            }
        }
        .background(Color.black)
        .animation(.easeInOut(duration: 0.3), value: showBackButton)
        .onAppear {
            showBackButtonTemporarily()
        }
        .statusBarHidden(true)
    }

    /// Padding for annotation toolbar in fullscreen mode (accounts for safe areas)
    private var fullscreenToolbarPadding: EdgeInsets {
        switch toolbarPosition {
        case .top: return EdgeInsets(top: 60, leading: 16, bottom: 0, trailing: 16)
        case .bottom: return EdgeInsets(top: 0, leading: 16, bottom: 40, trailing: 16)
        case .left: return EdgeInsets(top: 60, leading: 16, bottom: 40, trailing: 0)
        case .right: return EdgeInsets(top: 60, leading: 0, bottom: 40, trailing: 16)
        }
    }

    private func enterFullscreen() {
        withAnimation(.easeInOut(duration: 0.3)) {
            isFullscreen = true
            showBackButton = true
        }
        scheduleHideBackButton()
    }

    private func exitFullscreen() {
        hideBackButtonTask?.cancel()
        withAnimation(.easeInOut(duration: 0.3)) {
            isFullscreen = false
        }
    }

    private func showBackButtonTemporarily() {
        // Cancel existing hide task
        hideBackButtonTask?.cancel()

        // Show button
        withAnimation {
            showBackButton = true
        }

        // Schedule hide
        scheduleHideBackButton()
    }

    private func scheduleHideBackButton() {
        hideBackButtonTask?.cancel()
        hideBackButtonTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation {
                    showBackButton = false
                }
            }
        }
    }
    #endif

    // MARK: - Page Navigation

    private func pageDown() {
        // Move forward approximately one screen (~10 pages for continuous scroll, or 1 page)
        let newPage = min(currentPage + 1, totalPages)
        if newPage != currentPage {
            currentPage = newPage
        }
    }

    private func pageUp() {
        // Move back approximately one screen
        let newPage = max(currentPage - 1, 1)
        if newPage != currentPage {
            currentPage = newPage
        }
    }

    #if os(macOS)
    /// Scroll down by half the visible viewport height (vim j key behavior)
    private func scrollHalfPageDown() {
        guard let pdfView = pdfViewReference,
              let scrollView = pdfView.enclosingScrollView else { return }

        let visibleHeight = scrollView.contentView.bounds.height
        var newOrigin = scrollView.contentView.bounds.origin
        newOrigin.y += visibleHeight / 2

        // Clamp to document bounds
        if let documentView = scrollView.documentView {
            let maxY = documentView.bounds.height - visibleHeight
            newOrigin.y = min(newOrigin.y, max(0, maxY))
        }

        scrollView.contentView.scroll(to: newOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Scroll up by half the visible viewport height (vim k key behavior)
    private func scrollHalfPageUp() {
        guard let pdfView = pdfViewReference,
              let scrollView = pdfView.enclosingScrollView else { return }

        let visibleHeight = scrollView.contentView.bounds.height
        var newOrigin = scrollView.contentView.bounds.origin
        newOrigin.y -= visibleHeight / 2

        // Clamp to document bounds
        newOrigin.y = max(0, newOrigin.y)

        scrollView.contentView.scroll(to: newOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
    #else
    /// iOS: Scroll down by half the visible viewport height
    private func scrollHalfPageDown() {
        // iOS PDFView doesn't expose scroll view directly in the same way
        // Use page navigation as fallback for now
        pageDown()
    }

    /// iOS: Scroll up by half the visible viewport height
    private func scrollHalfPageUp() {
        pageUp()
    }
    #endif

    private func fitToWindow() {
        // Reset to auto-scale (scaleFactor 1.0 with autoScales = true gives fit behavior)
        scaleFactor = 1.0
    }

    // MARK: - Annotation Actions

    private func highlightSelection() {
        guard let pdfView = pdfViewReference else { return }
        _ = AnnotationService.shared.addHighlight(to: pdfView, color: highlightColor)
        hasUnsavedAnnotations = true
    }

    private func underlineSelection() {
        guard let pdfView = pdfViewReference else { return }
        _ = AnnotationService.shared.addUnderline(to: pdfView)
        hasUnsavedAnnotations = true
    }

    private func strikethroughSelection() {
        guard let pdfView = pdfViewReference else { return }
        _ = AnnotationService.shared.addStrikethrough(to: pdfView)
        hasUnsavedAnnotations = true
    }

    private func addNoteAtSelection() {
        guard let pdfView = pdfViewReference else { return }
        // For now, add a note with placeholder text
        // In a full implementation, show a text input dialog
        _ = AnnotationService.shared.addTextNoteAtSelection(in: pdfView, text: "Note")
        hasUnsavedAnnotations = true
    }

    private func saveAnnotations() {
        guard let document = pdfDocument else { return }

        // Get the URL from source
        guard case .url(let url) = source else {
            Logger.files.warningCapture("Cannot save annotations: document not loaded from URL", category: "annotation")
            return
        }

        do {
            try AnnotationService.shared.save(document, to: url)
            hasUnsavedAnnotations = false
            Logger.files.infoCapture("Saved annotations to \(url.lastPathComponent)", category: "annotation")
        } catch {
            Logger.files.errorCapture("Failed to save annotations: \(error)", category: "annotation")
        }
    }

    // MARK: - Reading Position

    private func loadSavedPosition() async {
        // Note: Global zoom is handled automatically by @AppStorage
        // Only need to load per-publication page number
        guard let pubID = publicationID else { return }
        if let position = await ReadingPositionStore.shared.get(for: pubID) {
            await MainActor.run {
                if position.pageNumber >= 1 && position.pageNumber <= totalPages {
                    currentPage = position.pageNumber
                }
                Logger.files.debugCapture("Restored reading position: page \(position.pageNumber), zoom \(Int(scaleFactor * 100))%", category: "pdf")
            }
        }
    }

    private func schedulePositionSave() {
        // Cancel existing save task
        saveTask?.cancel()

        // Note: Global zoom is saved automatically by @AppStorage
        // Only schedule save for per-publication page number
        guard publicationID != nil else { return }

        // Schedule debounced save (500ms delay)
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await savePosition()
        }
    }

    private func savePositionImmediately() {
        guard publicationID != nil else { return }
        saveTask?.cancel()
        Task {
            await savePosition()
        }
    }

    private func savePosition() async {
        // Note: Global zoom is saved automatically by @AppStorage
        // Only save per-publication page number
        guard let pubID = publicationID else { return }
        let position = ReadingPosition(
            pageNumber: currentPage,
            zoomLevel: CGFloat(scaleFactor),
            lastReadDate: Date()
        )
        await ReadingPositionStore.shared.save(position, for: pubID)
    }

    // MARK: - Search

    private func performSearch() {
        guard !searchQuery.isEmpty, let document = pdfDocument else {
            searchResults = []
            currentSearchIndex = 0
            return
        }

        isSearching = true

        // Perform search (synchronous, but fast for most PDFs)
        let results = document.findString(searchQuery, withOptions: [.caseInsensitive])

        searchResults = results
        currentSearchIndex = results.isEmpty ? 0 : 0
        isSearching = false

        Logger.files.debugCapture("Search found \(results.count) results for '\(searchQuery)'", category: "pdf")

        // Navigate to first result
        if !results.isEmpty {
            navigateToSearchResult(at: 0)
        }
    }

    private func clearSearch() {
        searchQuery = ""
        searchResults = []
        currentSearchIndex = 0
    }

    private func previousSearchResult() {
        guard !searchResults.isEmpty else { return }
        if currentSearchIndex > 0 {
            currentSearchIndex -= 1
            navigateToSearchResult(at: currentSearchIndex)
        }
    }

    private func nextSearchResult() {
        guard !searchResults.isEmpty else { return }
        if currentSearchIndex < searchResults.count - 1 {
            currentSearchIndex += 1
            navigateToSearchResult(at: currentSearchIndex)
        }
    }

    private func navigateToSearchResult(at index: Int) {
        guard index >= 0, index < searchResults.count else { return }
        let selection = searchResults[index]

        // Post notification that coordinator will handle
        NotificationCenter.default.post(
            name: .pdfViewerNavigateToSelection,
            object: nil,
            userInfo: ["selection": selection]
        )
    }

    // MARK: - Toolbar

    private var pdfToolbar: some View {
        #if os(iOS)
        // iOS: Compact toolbar with essential controls, scrollable for overflow
        VStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    // Page Navigation
                    HStack(spacing: 6) {
                        Button {
                            goToPreviousPage()
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                        .disabled(currentPage <= 1)

                        Text("\(currentPage)/\(totalPages)")
                            .font(.caption)
                            .monospacedDigit()

                        Button {
                            goToNextPage()
                        } label: {
                            Image(systemName: "chevron.right")
                        }
                        .disabled(currentPage >= totalPages)
                    }

                    Divider()
                        .frame(height: 20)

                    // Zoom Controls
                    HStack(spacing: 6) {
                        Button {
                            zoomOut()
                        } label: {
                            Image(systemName: "minus.magnifyingglass")
                        }
                        .disabled(scaleFactor <= 0.25)

                        Text("\(Int(scaleFactor * 100))%")
                            .font(.caption)
                            .monospacedDigit()

                        Button {
                            zoomIn()
                        } label: {
                            Image(systemName: "plus.magnifyingglass")
                        }
                        .disabled(scaleFactor >= 4.0)
                    }

                    // Link history navigation (shown when history exists)
                    if canGoBack || canGoForward {
                        Divider()
                            .frame(height: 20)

                        HStack(spacing: 6) {
                            Button {
                                goBackInHistory()
                            } label: {
                                Image(systemName: "chevron.backward.circle")
                            }
                            .disabled(!canGoBack)

                            Button {
                                goForwardInHistory()
                            } label: {
                                Image(systemName: "chevron.forward.circle")
                            }
                            .disabled(!canGoForward)
                        }
                    }

                    Divider()
                        .frame(height: 20)

                    // Annotation controls
                    HStack(spacing: 6) {
                        Button {
                            showAnnotationToolbar.toggle()
                        } label: {
                            Image(systemName: showAnnotationToolbar ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle")
                        }

                        if hasUnsavedAnnotations {
                            Button {
                                saveAnnotations()
                            } label: {
                                Image(systemName: "square.and.arrow.down")
                                    .foregroundStyle(.orange)
                            }
                        }
                    }

                    Divider()
                        .frame(height: 20)

                    // Search toggle
                    Button {
                        withAnimation {
                            isSearchVisible.toggle()
                        }
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }

                    // Fullscreen button (allows entering fullscreen while in annotation mode)
                    Button {
                        enterFullscreen()
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }

                    // Open externally
                    if case .url(let url) = source {
                        Button {
                            openInExternalApp(url: url)
                        } label: {
                            Image(systemName: "arrow.up.forward.app")
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .scrollIndicators(.hidden)
            .background(.bar)

            // Search bar (expandable)
            if isSearchVisible {
                HStack(spacing: 8) {
                    TextField("Search in PDF...", text: $searchQuery)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            performSearch()
                        }

                    if !searchQuery.isEmpty {
                        Button {
                            clearSearch()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }

                    if !searchResults.isEmpty {
                        Text("\(currentSearchIndex + 1)/\(searchResults.count)")
                            .font(.caption)
                            .monospacedDigit()

                        Button {
                            previousSearchResult()
                        } label: {
                            Image(systemName: "chevron.up")
                        }
                        .disabled(currentSearchIndex <= 0)

                        Button {
                            nextSearchResult()
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .disabled(currentSearchIndex >= searchResults.count - 1)
                    }

                    if isSearching {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.bar)
            }
        }
        .frame(maxWidth: .infinity)
        #else
        // macOS: Full horizontal toolbar
        HStack(spacing: 16) {
            // Page Navigation
            HStack(spacing: 8) {
                Button {
                    goToPreviousPage()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(currentPage <= 1)

                Text("\(currentPage) / \(totalPages)")
                    .font(.caption)
                    .monospacedDigit()
                    .frame(minWidth: 60)

                Button {
                    goToNextPage()
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(currentPage >= totalPages)
            }

            Divider()
                .frame(height: 20)

            // Zoom Controls
            HStack(spacing: 8) {
                Button {
                    zoomOut()
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .disabled(scaleFactor <= 0.25)

                Text("\(Int(scaleFactor * 100))%")
                    .font(.caption)
                    .monospacedDigit()
                    .frame(minWidth: 50)

                Button {
                    zoomIn()
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .disabled(scaleFactor >= 4.0)

                Button {
                    resetZoom()
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
            }

            Divider()
                .frame(height: 20)

            // Search
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField("Search...", text: $searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
                    .onSubmit {
                        performSearch()
                    }

                if !searchQuery.isEmpty {
                    Button {
                        clearSearch()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                if !searchResults.isEmpty {
                    Text("\(currentSearchIndex + 1)/\(searchResults.count)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)

                    Button {
                        previousSearchResult()
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .disabled(currentSearchIndex <= 0)

                    Button {
                        nextSearchResult()
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .disabled(currentSearchIndex >= searchResults.count - 1)
                }

                if isSearching {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            Divider()
                .frame(height: 20)

            // Annotation controls
            HStack(spacing: 8) {
                // Toggle annotation toolbar
                Button {
                    showAnnotationToolbar.toggle()
                } label: {
                    Image(systemName: showAnnotationToolbar ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle")
                }
                .help(showAnnotationToolbar ? "Hide annotation toolbar" : "Show annotation toolbar")

                // Save button (shown when unsaved changes)
                if hasUnsavedAnnotations {
                    Button {
                        saveAnnotations()
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .help("Save annotations")
                }
            }

            Spacer()

            // Open in External App
            if case .url(let url) = source {
                Button {
                    openInExternalApp(url: url)
                } label: {
                    Label("Open in Preview", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
        #endif
    }

    // MARK: - Loading

    private func loadDocument() async {
        isLoading = true
        error = nil

        do {
            let document = try await loadPDFDocument()
            await MainActor.run {
                self.pdfDocument = document
                self.totalPages = document.pageCount
                self.isLoading = false
            }
            // Load saved reading position after document is ready
            await loadSavedPosition()
        } catch PDFViewerError.corruptPDF(let url) {
            // Corrupt PDF (HTML content) - trigger callback for auto-cleanup/re-download
            await MainActor.run {
                self.error = .corruptPDF(url)
                self.isLoading = false
            }
            // Trigger callback so parent can delete and re-download
            if let file = linkedFile {
                await MainActor.run {
                    onCorruptPDF?(file)
                }
            }
        } catch let err as PDFViewerError {
            await MainActor.run {
                self.error = err
                self.isLoading = false
            }
        } catch {
            await MainActor.run {
                self.error = .loadFailed(error)
                self.isLoading = false
            }
        }
    }

    private func loadPDFDocument() async throws -> PDFDocument {
        switch source {
        case .url(let url):
            Logger.files.debugCapture("Attempting to load PDF from: \(url.path)", category: "pdf")

            guard FileManager.default.fileExists(atPath: url.path) else {
                Logger.files.errorCapture("PDF file not found at: \(url.path)", category: "pdf")
                throw PDFViewerError.fileNotFound(url)
            }

            // Check file size for debugging
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? Int64 {
                Logger.files.debugCapture("PDF file size: \(size) bytes", category: "pdf")
            }

            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing { url.stopAccessingSecurityScopedResource() }
            }

            guard let document = PDFDocument(url: url) else {
                // Try to read first few bytes to diagnose
                if let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                   data.count >= 4 {
                    let headerBytes = data.prefix(4).map { String(format: "%02X", $0) }.joined(separator: " ")
                    Logger.files.errorCapture("Invalid PDF - file header bytes: \(headerBytes) (expected: 25 50 44 46 = %PDF)", category: "pdf")

                    // Check if it's HTML content (common when publisher returns error page)
                    // Look for '<' (0x3C) in first 20 bytes
                    let isHTML = data.prefix(20).contains(0x3C)
                    if isHTML {
                        Logger.files.warningCapture("Corrupt PDF appears to be HTML content - will trigger re-download", category: "pdf")
                        throw PDFViewerError.corruptPDF(url)
                    }
                }
                throw PDFViewerError.invalidPDF(url)
            }

            return document

        case .data(let data):
            Logger.files.debugCapture("Loading PDF from data (\(data.count) bytes)", category: "pdf")
            guard let document = PDFDocument(data: data) else {
                throw PDFViewerError.invalidData
            }
            return document
        }
    }

    // MARK: - Actions

    private func goToPreviousPage() {
        if currentPage > 1 {
            currentPage -= 1
        }
    }

    private func goToNextPage() {
        if currentPage < totalPages {
            currentPage += 1
        }
    }

    private func zoomIn() {
        scaleFactor = min(scaleFactor * 1.25, 4.0)
    }

    private func zoomOut() {
        scaleFactor = max(scaleFactor / 1.25, 0.25)
    }

    private func resetZoom() {
        scaleFactor = 1.0
    }

    #if os(iOS)
    private func goBackInHistory() {
        pdfViewReference?.goBack(nil)
        // Update state after navigation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            canGoBack = pdfViewReference?.canGoBack ?? false
            canGoForward = pdfViewReference?.canGoForward ?? false
        }
    }

    private func goForwardInHistory() {
        pdfViewReference?.goForward(nil)
        // Update state after navigation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            canGoBack = pdfViewReference?.canGoBack ?? false
            canGoForward = pdfViewReference?.canGoForward ?? false
        }
    }
    #endif

    private func openInExternalApp(url: URL) {
        Logger.files.infoCapture("openInExternalApp called with URL: \(url.path)", category: "pdf")

        // Determine the correct PDF URL (fix .tmp extension if needed)
        var pdfURL = url
        let needsExtensionFix = url.pathExtension.lowercased() == "tmp"
        if needsExtensionFix {
            // Replace .tmp with .pdf
            pdfURL = url.deletingPathExtension().appendingPathExtension("pdf")
            Logger.files.infoCapture("Correcting extension from .tmp to .pdf: \(pdfURL.path)", category: "pdf")
        } else if url.pathExtension.lowercased() != "pdf" {
            // Ensure it has .pdf extension
            pdfURL = url.appendingPathExtension("pdf")
        }

        // Save the PDF with any annotations to the correct path
        if let document = pdfDocument {
            do {
                try AnnotationService.shared.save(document, to: pdfURL)
                hasUnsavedAnnotations = false
                Logger.files.infoCapture("Saved PDF to: \(pdfURL.path)", category: "pdf")

                // If we changed the extension, also remove the old .tmp file and update Core Data
                if pdfURL != url && FileManager.default.fileExists(atPath: url.path) {
                    try? FileManager.default.removeItem(at: url)
                    Logger.files.infoCapture("Removed old .tmp file", category: "pdf")
                }

                // Update the CDLinkedFile's relativePath if we fixed the extension
                if needsExtensionFix, let linkedFile = linkedFile {
                    let oldPath = linkedFile.relativePath
                    let newPath = oldPath.replacingOccurrences(of: ".tmp", with: ".pdf")
                    if oldPath != newPath {
                        linkedFile.relativePath = newPath
                        linkedFile.filename = linkedFile.filename.replacingOccurrences(of: ".tmp", with: ".pdf")
                        linkedFile.fileType = "pdf"
                        PersistenceController.shared.save()
                        Logger.files.infoCapture("Updated CDLinkedFile relativePath from .tmp to .pdf", category: "pdf")
                    }
                }
            } catch {
                Logger.files.errorCapture("Failed to save PDF: \(error)", category: "pdf")
            }
        }

        Logger.files.infoCapture("Opening PDF with system default: \(pdfURL.path)", category: "pdf")

        #if os(macOS)
        NSWorkspace.shared.open(pdfURL)
        #else
        _ = FileManager_Opener.shared.openFile(pdfURL)
        #endif
    }

    // MARK: - Error View

    @ViewBuilder
    private func errorView(_ error: PDFViewerError) -> some View {
        ContentUnavailableView {
            Label("Unable to Load PDF", systemImage: "exclamationmark.triangle")
        } description: {
            Text(error.localizedDescription)
        } actions: {
            Button("Try Again") {
                Task { await loadDocument() }
            }
        }
    }
}
