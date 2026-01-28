//
//  IOSContentView.swift
//  imprint-iOS
//
//  Created by Claude on 2026-01-27.
//

import SwiftUI

// MARK: - iOS Content View

/// Main content view for imprint on iOS/iPadOS.
///
/// Provides an adaptive layout that works on both iPhone and iPad:
/// - iPhone: Full-screen editor with toolbar
/// - iPad: Split view with editor and preview, supports multitasking
struct IOSContentView: View {

    // MARK: - Properties

    /// The document being edited
    @Binding var document: ImprintDocument

    /// Whether to show the preview panel (iPad)
    @State private var showPreview = true

    /// Whether to show the toolbar
    @State private var showToolbar = true

    /// Current editor selection
    @State private var selection: NSRange?

    /// Environment
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    // MARK: - Body

    var body: some View {
        GeometryReader { geometry in
            if horizontalSizeClass == .regular && geometry.size.width > 600 {
                // iPad layout: Split view
                iPadLayout
            } else {
                // iPhone layout: Full screen editor
                iPhoneLayout
            }
        }
        .toolbar {
            toolbarContent
        }
    }

    // MARK: - iPad Layout

    private var iPadLayout: some View {
        HStack(spacing: 0) {
            // Editor
            IOSSourceEditorView(
                text: $document.source,
                selection: $selection
            )
            .frame(minWidth: 300)

            if showPreview {
                Divider()

                // Preview
                IOSPDFPreviewView(document: document)
                    .frame(minWidth: 300)
            }
        }
    }

    // MARK: - iPhone Layout

    private var iPhoneLayout: some View {
        IOSSourceEditorView(
            text: $document.source,
            selection: $selection
        )
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Leading items
        ToolbarItemGroup(placement: .topBarLeading) {
            // Document title
            Text(document.title)
                .font(.headline)
        }

        // Trailing items
        ToolbarItemGroup(placement: .topBarTrailing) {
            // Insert citation
            Button {
                // TODO: Show citation picker
            } label: {
                Image(systemName: "quote.bubble")
            }
            .keyboardShortcut("k", modifiers: [.command, .shift])

            // Toggle preview (iPad only)
            if horizontalSizeClass == .regular {
                Button {
                    withAnimation {
                        showPreview.toggle()
                    }
                } label: {
                    Image(systemName: showPreview ? "rectangle.righthalf.inset.filled" : "rectangle.split.2x1")
                }
            }

            // More menu
            Menu {
                Button {
                    // TODO: Export PDF
                } label: {
                    Label("Export PDF", systemImage: "arrow.down.doc")
                }

                Button {
                    // TODO: Share
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }

                Divider()

                Button {
                    // TODO: Document settings
                } label: {
                    Label("Document Settings", systemImage: "doc.badge.gearshape")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }

        // Bottom bar items
        ToolbarItemGroup(placement: .bottomBar) {
            // Undo/Redo
            HStack(spacing: 16) {
                Button {
                    // TODO: Undo
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }

                Button {
                    // TODO: Redo
                } label: {
                    Image(systemName: "arrow.uturn.forward")
                }
            }

            Spacer()

            // Formatting quick actions
            HStack(spacing: 16) {
                Button {
                    insertFormatting("*", "*")
                } label: {
                    Image(systemName: "bold")
                }
                .keyboardShortcut("b", modifiers: .command)

                Button {
                    insertFormatting("_", "_")
                } label: {
                    Image(systemName: "italic")
                }
                .keyboardShortcut("i", modifiers: .command)

                Button {
                    insertFormatting("`", "`")
                } label: {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                }
            }

            Spacer()

            // Dictation button
            Button {
                // TODO: Start dictation
            } label: {
                Image(systemName: "mic")
            }
        }
    }

    // MARK: - Actions

    private func insertFormatting(_ prefix: String, _ suffix: String) {
        // TODO: Insert formatting around selection
    }
}

// MARK: - Preview

#Preview("iPhone") {
    NavigationStack {
        IOSContentView(document: .constant(ImprintDocument()))
    }
    .previewDevice("iPhone 15 Pro")
}

#Preview("iPad") {
    NavigationStack {
        IOSContentView(document: .constant(ImprintDocument()))
    }
    .previewDevice("iPad Pro (12.9-inch)")
}
