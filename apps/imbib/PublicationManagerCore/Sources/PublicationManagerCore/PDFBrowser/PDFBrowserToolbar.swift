//
//  PDFBrowserToolbar.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-06.
//

import SwiftUI

/// Shared toolbar for the PDF browser.
///
/// Provides navigation controls, URL display, and action buttons.
/// Works on macOS and iOS.
#if !os(tvOS)
public struct PDFBrowserToolbar: View {

    // MARK: - Properties

    @Bindable var viewModel: PDFBrowserViewModel

    // MARK: - Initialization

    public init(viewModel: PDFBrowserViewModel) {
        self.viewModel = viewModel
    }

    // MARK: - Body

    public var body: some View {
        HStack(spacing: 12) {
            // Navigation buttons
            navigationButtons

            Divider()
                .frame(height: 20)

            // URL display
            urlDisplay

            // Action buttons
            actionButtons
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        #if os(macOS)
        .background(.bar)
        #endif
    }

    // MARK: - Navigation Buttons

    @ViewBuilder
    private var navigationButtons: some View {
        HStack(spacing: 8) {
            // Back button
            Button {
                viewModel.goBack()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.medium))
            }
            .disabled(!viewModel.canGoBack)
            .help("Go back")
            #if os(macOS)
            .buttonStyle(.borderless)
            #endif

            // Forward button
            Button {
                viewModel.goForward()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.body.weight(.medium))
            }
            .disabled(!viewModel.canGoForward)
            .help("Go forward")
            #if os(macOS)
            .buttonStyle(.borderless)
            #endif

            // Reload/Stop button
            Button {
                if viewModel.isLoading {
                    viewModel.stopLoading()
                } else {
                    viewModel.reload()
                }
            } label: {
                Image(systemName: viewModel.isLoading ? "xmark" : "arrow.clockwise")
                    .font(.body.weight(.medium))
            }
            .help(viewModel.isLoading ? "Stop loading" : "Reload")
            #if os(macOS)
            .buttonStyle(.borderless)
            #endif
        }
    }

    // MARK: - URL Display

    @ViewBuilder
    private var urlDisplay: some View {
        HStack(spacing: 4) {
            // Security indicator
            if let url = viewModel.currentURL {
                Image(systemName: url.scheme == "https" ? "lock.fill" : "lock.open.fill")
                    .font(.caption)
                    .foregroundStyle(url.scheme == "https" ? .green : .orange)
            }

            // URL text
            Text(viewModel.currentURL?.absoluteString ?? "")
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        #if os(macOS)
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        #endif
    }

    // MARK: - Action Buttons

    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 8) {
            // Try Direct PDF button (shown when a pattern is detected)
            if viewModel.suggestedPDFURL != nil {
                Button {
                    viewModel.tryDirectPDFURL()
                } label: {
                    Label("Try Direct PDF", systemImage: "arrow.right.doc.on.clipboard")
                        .font(.body)
                }
                .help("Try direct PDF URL for this publisher")
                #if os(macOS)
                .buttonStyle(.bordered)
                .tint(.accentColor)
                #endif
            }

            // Copy URL button
            Button {
                viewModel.copyURLToClipboard()
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.body)
            }
            .help("Copy URL to clipboard")
            #if os(macOS)
            .buttonStyle(.borderless)
            #endif
        }
    }
}

// MARK: - Compact Toolbar (iOS)

/// Compact toolbar for iOS navigation bar.
public struct PDFBrowserCompactToolbar: View {

    @Bindable var viewModel: PDFBrowserViewModel

    public init(viewModel: PDFBrowserViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        HStack(spacing: 16) {
            Button { viewModel.goBack() } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!viewModel.canGoBack)

            Button { viewModel.goForward() } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(!viewModel.canGoForward)

            Button {
                if viewModel.isLoading {
                    viewModel.stopLoading()
                } else {
                    viewModel.reload()
                }
            } label: {
                Image(systemName: viewModel.isLoading ? "xmark" : "arrow.clockwise")
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
struct PDFBrowserToolbar_Previews: PreviewProvider {
    static var previews: some View {
        // Preview requires a mock publication
        VStack {
            Text("PDFBrowserToolbar Preview")
                .font(.headline)
            Text("(Requires mock CDPublication)")
                .foregroundStyle(.secondary)
        }
        .frame(width: 600, height: 100)
    }
}
#endif

#endif // !os(tvOS)
