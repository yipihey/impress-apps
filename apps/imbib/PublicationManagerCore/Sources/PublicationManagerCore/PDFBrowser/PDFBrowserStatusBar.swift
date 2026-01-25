//
//  PDFBrowserStatusBar.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-06.
//

import SwiftUI

/// Status bar for the PDF browser.
///
/// Shows loading state, download progress, PDF detection alerts,
/// and error messages. Works on macOS and iOS.
#if !os(tvOS)
public struct PDFBrowserStatusBar: View {

    // MARK: - Properties

    @Bindable var viewModel: PDFBrowserViewModel

    // MARK: - Initialization

    public init(viewModel: PDFBrowserViewModel) {
        self.viewModel = viewModel
    }

    // MARK: - Body

    public var body: some View {
        HStack(spacing: 12) {
            // Left side: Status info
            statusContent

            Spacer()

            // Middle: Progress or info
            if let progress = viewModel.downloadProgress {
                downloadProgressView(progress)
            }

            // Right side: Action buttons (always visible)
            actionButtons
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.bar)
        .animation(.easeInOut(duration: 0.2), value: viewModel.detectedPDFFilename)
        .animation(.easeInOut(duration: 0.2), value: viewModel.isLoading)
    }

    // MARK: - Action Buttons

    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 8) {
            // Apply Library Proxy button
            Button {
                viewModel.retryWithProxy()
            } label: {
                Label("Apply Proxy", systemImage: "building.columns")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!viewModel.proxyEnabled || viewModel.libraryProxyURL.isEmpty || viewModel.isProxied)
            .help(proxyButtonHelp)

            // Save Page as PDF button (captures/renders the page as PDF)
            Button {
                Task {
                    await viewModel.attemptManualCapture()
                }
            } label: {
                if viewModel.isCapturing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("Save Page as PDF", systemImage: "doc.viewfinder")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(viewModel.isCapturing || viewModel.isLoading)
            .help("Capture and save the current page as PDF")

            // Save PDF button (saves detected/downloaded PDF)
            Button {
                Task {
                    await viewModel.saveDetectedPDF()
                }
            } label: {
                Label("Save PDF", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(viewModel.detectedPDFData == nil)
            .help(viewModel.detectedPDFData != nil ? "Save detected PDF to library" : "No PDF detected")
        }
    }

    private var proxyButtonHelp: String {
        if !viewModel.proxyEnabled {
            return "Library proxy not enabled in settings"
        } else if viewModel.libraryProxyURL.isEmpty {
            return "Library proxy URL not configured"
        } else if viewModel.isProxied {
            return "Already using library proxy"
        } else {
            return "Reload page through library proxy"
        }
    }

    // MARK: - Status Content

    @ViewBuilder
    private var statusContent: some View {
        if let error = viewModel.errorMessage {
            // Error state
            errorView(error)
        } else if let filename = viewModel.detectedPDFFilename {
            // PDF detected state
            pdfDetectedView(filename)
        } else if viewModel.isLoading {
            // Loading state
            loadingView
        } else {
            // Ready state
            readyView
        }
    }

    @ViewBuilder
    private var errorView: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(viewModel.errorMessage ?? "Error")
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func errorView(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Button("Dismiss") {
                viewModel.errorMessage = nil
            }
            .buttonStyle(.plain)
            .foregroundStyle(.blue)
            .font(.caption)
        }
    }

    private func pdfDetectedView(_ filename: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.fill")
                .foregroundStyle(.green)

            VStack(alignment: .leading, spacing: 2) {
                Text("PDF Detected")
                    .font(.caption.bold())
                    .foregroundStyle(.green)
                Text(filename)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Button {
                viewModel.clearDetectedPDF()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
    }

    private var loadingView: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
            Text("Loading...")
                .foregroundStyle(.secondary)
        }
    }

    private var readyView: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text("Ready")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Download Progress

    private func downloadProgressView(_ progress: Double) -> some View {
        HStack(spacing: 8) {
            ProgressView(value: progress)
                .frame(width: 100)

            Text("\(Int(progress * 100))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
    }
}

// MARK: - Compact Status (iOS)

/// Compact status indicator for iOS.
public struct PDFBrowserCompactStatus: View {

    @Bindable var viewModel: PDFBrowserViewModel

    public init(viewModel: PDFBrowserViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        Group {
            if viewModel.detectedPDFFilename != nil {
                Circle()
                    .fill(.green)
                    .frame(width: 8, height: 8)
            } else if viewModel.isLoading {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
struct PDFBrowserStatusBar_Previews: PreviewProvider {
    static var previews: some View {
        VStack {
            Text("PDFBrowserStatusBar Preview")
                .font(.headline)
            Text("(Requires mock CDPublication)")
                .foregroundStyle(.secondary)
        }
        .frame(width: 600, height: 100)
    }
}
#endif

#endif // !os(tvOS)
