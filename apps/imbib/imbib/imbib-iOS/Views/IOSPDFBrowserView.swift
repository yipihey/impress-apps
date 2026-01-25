//
//  IOSPDFBrowserView.swift
//  imbib-iOS
//
//  Created by Claude on 2026-01-07.
//

import SwiftUI
import WebKit
import PublicationManagerCore
import OSLog

private let browserLogger = Logger(subsystem: "com.imbib.app", category: "pdf-browser")

/// iOS PDF browser presented as a full-screen modal.
///
/// Allows users to navigate to publisher sites to download PDFs that require
/// authentication, CAPTCHAs, or multi-step access.
struct IOSPDFBrowserView: View {
    @Environment(\.dismiss) private var dismiss

    let publication: CDPublication
    let library: CDLibrary?
    let onPDFSaved: (() -> Void)?

    @State private var viewModel: PDFBrowserViewModel?
    @State private var showShareSheet = false
    @State private var urlToShare: URL?

    var body: some View {
        NavigationStack {
            Group {
                if let viewModel = viewModel {
                    browserContent(viewModel: viewModel)
                } else {
                    ProgressView("Loading...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Download PDF")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                if let viewModel = viewModel {
                    ToolbarItem(placement: .topBarTrailing) {
                        HStack(spacing: 16) {
                            // Navigation
                            Button {
                                viewModel.goBack()
                            } label: {
                                Image(systemName: "chevron.left")
                            }
                            .disabled(!viewModel.canGoBack)

                            Button {
                                viewModel.goForward()
                            } label: {
                                Image(systemName: "chevron.right")
                            }
                            .disabled(!viewModel.canGoForward)

                            Button {
                                viewModel.reload()
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }

                            // Share/Copy URL
                            Button {
                                if let url = viewModel.currentURL {
                                    urlToShare = url
                                    showShareSheet = true
                                }
                            } label: {
                                Image(systemName: "square.and.arrow.up")
                            }

                            // Manual save
                            Button {
                                Task {
                                    await viewModel.onManualCaptureRequested?()
                                }
                            } label: {
                                Image(systemName: "square.and.arrow.down")
                            }
                        }
                    }
                }
            }
            .sheet(isPresented: $showShareSheet) {
                if let url = urlToShare {
                    ShareSheet(items: [url])
                }
            }
            .task {
                await setupViewModel()
            }
        }
    }

    // MARK: - Browser Content

    @ViewBuilder
    private func browserContent(viewModel: PDFBrowserViewModel) -> some View {
        VStack(spacing: 0) {
            // Browser
            IOSWebView(viewModel: viewModel)

            // Status bar
            if viewModel.isLoading || viewModel.detectedPDFData != nil {
                statusBar(viewModel: viewModel)
            }
        }
        .onChange(of: viewModel.detectedPDFData) { _, data in
            if let data = data {
                savePDF(data)
            }
        }
    }

    // MARK: - Status Bar

    private func statusBar(viewModel: PDFBrowserViewModel) -> some View {
        HStack {
            if viewModel.isLoading {
                ProgressView()
                    .controlSize(.small)
                Text("Loading...")
                    .font(.caption)
            } else if viewModel.detectedPDFData != nil {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("PDF detected! Saving...")
                    .font(.caption)
            }

            Spacer()

            if let url = viewModel.currentURL {
                Text(url.host ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Setup

    private func setupViewModel() async {
        // Get the browser URL for this publication
        guard let url = await getBrowserURL() else {
            browserLogger.warning("No browser URL available for publication")
            return
        }

        browserLogger.info("Loading browser URL: \(url.absoluteString)")

        let vm = PDFBrowserViewModel(
            publication: publication,
            initialURL: url,
            libraryID: library?.id ?? UUID()
        )

        vm.onPDFCaptured = { data in
            savePDF(data)
        }

        vm.onDismiss = {
            dismiss()
        }

        viewModel = vm
    }

    private func getBrowserURL() async -> URL? {
        // Try registered providers first
        if let url = await BrowserURLProviderRegistry.shared.browserURL(for: publication) {
            return url
        }

        // Fall back to DOI resolver
        if let doi = publication.doi {
            return URL(string: "https://doi.org/\(doi)")
        }

        return nil
    }

    // MARK: - Save PDF

    private func savePDF(_ data: Data) {
        browserLogger.info("Saving PDF (\(data.count) bytes)")

        Task {
            do {
                // Save via PDFManager
                try PDFManager.shared.importPDF(
                    data: data,
                    for: publication,
                    in: library
                )

                browserLogger.info("PDF saved successfully")

                await MainActor.run {
                    onPDFSaved?()
                    dismiss()
                }
            } catch {
                browserLogger.error("Failed to save PDF: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - iOS WebView

struct IOSWebView: UIViewRepresentable {
    let viewModel: PDFBrowserViewModel

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()  // Persistent cookies

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true

        context.coordinator.webView = webView

        // Set the webView on the viewModel
        Task { @MainActor in
            viewModel.webView = webView
        }

        // Load the initial URL
        let request = URLRequest(url: viewModel.initialURL)
        webView.load(request)

        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // Updates handled by view model
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        let viewModel: PDFBrowserViewModel
        weak var webView: WKWebView?

        init(viewModel: PDFBrowserViewModel) {
            self.viewModel = viewModel
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            Task { @MainActor in
                viewModel.isLoading = true
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in
                viewModel.isLoading = false
                viewModel.currentURL = webView.url
                viewModel.canGoBack = webView.canGoBack
                viewModel.canGoForward = webView.canGoForward
                viewModel.pageTitle = webView.title ?? ""

                // Check if current page is a PDF
                if let url = webView.url, url.pathExtension.lowercased() == "pdf" {
                    downloadPDF(from: url)
                }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            Task { @MainActor in
                viewModel.isLoading = false
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
        ) {
            // Check for PDF content type
            if let mimeType = navigationResponse.response.mimeType,
               mimeType.lowercased() == "application/pdf" {
                // Allow the navigation and download the PDF
                decisionHandler(.allow)
                downloadPDF(from: navigationResponse.response.url)
                return
            }

            decisionHandler(.allow)
        }

        private func downloadPDF(from url: URL?) {
            guard let url = url else { return }

            Task {
                do {
                    let (data, _) = try await URLSession.shared.data(from: url)

                    // Verify it's a PDF
                    if data.prefix(4).elementsEqual([0x25, 0x50, 0x44, 0x46]) {  // %PDF
                        await MainActor.run {
                            viewModel.detectedPDFData = data
                            viewModel.detectedPDFFilename = url.lastPathComponent
                        }
                    }
                } catch {
                    browserLogger.error("Failed to download PDF: \(error.localizedDescription)")
                }
            }
        }
    }
}

// MARK: - Share Sheet

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Preview

#Preview {
    IOSPDFBrowserView(
        publication: CDPublication(),
        library: nil,
        onPDFSaved: nil
    )
}
