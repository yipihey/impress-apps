//
//  AnnotationDeepLinkView.swift
//  imprint
//
//  Created by Claude on 2026-01-27.
//

import SwiftUI
import os.log

// MARK: - Annotation Deep Link View

/// A sidebar view component that links to imbib annotations.
///
/// Shows:
/// - Annotation count badge
/// - "View PDF Annotations" button that opens imbib
/// - Recent annotation preview
public struct AnnotationDeepLinkView: View {

    // MARK: - Properties

    /// The document being edited
    let document: ImprintDocument

    /// Annotation count from imbib (updated via URL callback)
    @State private var annotationCount: Int = 0

    /// Whether annotations are loading
    @State private var isLoading = false

    /// Error message if imbib unavailable
    @State private var errorMessage: String?

    private let logger = Logger(subsystem: "com.imbib.imprint", category: "Annotations")

    // MARK: - Body

    public var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                // Header with badge
                HStack {
                    Label("PDF Annotations", systemImage: "highlighter")
                        .font(.headline)

                    Spacer()

                    if annotationCount > 0 {
                        annotationBadge
                    }
                }

                Divider()

                // Description
                Text("View and manage annotations on the compiled PDF in imbib.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // View Annotations button
                Button {
                    openImbibAnnotations()
                } label: {
                    HStack {
                        Image(systemName: "arrow.up.forward.app")
                        Text("View in imbib")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!hasLinkedManuscript)

                // Error or help text
                if let error = errorMessage {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                } else if !hasLinkedManuscript {
                    Text("Link this document to an imbib manuscript to view annotations.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(4)
        }
        .onAppear {
            refreshAnnotationCount()
        }
        .onReceive(NotificationCenter.default.publisher(for: .imprintAnnotationCountReceived)) { notification in
            handleAnnotationCountNotification(notification)
        }
    }

    // MARK: - Subviews

    private var annotationBadge: some View {
        Text("\(annotationCount)")
            .font(.caption2.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Color.orange)
            .foregroundStyle(.white)
            .clipShape(Capsule())
    }

    // MARK: - Computed Properties

    private var hasLinkedManuscript: Bool {
        document.linkedImbibManuscriptID != nil
    }

    private var linkedCiteKey: String? {
        // In a real implementation, we'd look up the cite key from the manuscript ID
        // For now, we derive it from document title
        guard hasLinkedManuscript else { return nil }
        return document.title
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
    }

    // MARK: - Actions

    private func openImbibAnnotations() {
        guard let citeKey = linkedCiteKey else {
            errorMessage = "No linked manuscript"
            return
        }

        guard let url = URLSchemeHandler.imbibAnnotationsURL(citeKey: citeKey) else {
            errorMessage = "Failed to create URL"
            return
        }

        logger.info("Opening imbib annotations for \(citeKey)")

        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif

        errorMessage = nil
    }

    private func refreshAnnotationCount() {
        guard hasLinkedManuscript else {
            annotationCount = 0
            return
        }

        // Request annotation count from imbib via URL scheme
        // imbib will respond by calling back with imprint://annotations?documentUUID=...&count=...
        isLoading = true

        // In a real implementation, we'd request this from imbib
        // For now, we simulate a response
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.isLoading = false
        }
    }

    private func handleAnnotationCountNotification(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let docUUID = userInfo["documentUUID"] as? UUID,
              docUUID == document.id,
              let count = userInfo["count"] as? Int else {
            return
        }

        annotationCount = count
        logger.info("Received annotation count: \(count)")
    }
}

// MARK: - Annotation Preview

/// Shows a preview of recent annotations.
struct AnnotationPreviewView: View {
    let annotations: [AnnotationPreview]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(annotations.prefix(3)) { annotation in
                HStack(spacing: 8) {
                    Rectangle()
                        .fill(annotation.color)
                        .frame(width: 3)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(annotation.text)
                            .font(.caption)
                            .lineLimit(2)

                        Text("Page \(annotation.page)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

/// A preview of an annotation from imbib.
struct AnnotationPreview: Identifiable {
    let id = UUID()
    let text: String
    let page: Int
    let color: Color
    let type: AnnotationType

    enum AnnotationType {
        case highlight
        case underline
        case note
        case strikethrough
    }
}

// MARK: - Annotation Summary

/// Shows annotation statistics for the linked manuscript.
struct AnnotationSummaryView: View {
    let highlightCount: Int
    let noteCount: Int
    let underlineCount: Int

    var body: some View {
        HStack(spacing: 16) {
            annotationStat(count: highlightCount, icon: "highlighter", color: .yellow)
            annotationStat(count: noteCount, icon: "note.text", color: .blue)
            annotationStat(count: underlineCount, icon: "underline", color: .green)
        }
    }

    private func annotationStat(count: Int, icon: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .foregroundStyle(color)
            Text("\(count)")
                .font(.caption.monospacedDigit())
        }
    }
}

// MARK: - Platform Imports

#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - Preview

#Preview("Annotation Deep Link") {
    AnnotationDeepLinkView(document: ImprintDocument())
        .frame(width: 280)
        .padding()
}

#Preview("Annotation Preview") {
    AnnotationPreviewView(annotations: [
        AnnotationPreview(text: "This is an important point about methodology", page: 5, color: .yellow, type: .highlight),
        AnnotationPreview(text: "Need to verify this citation", page: 8, color: .blue, type: .note),
        AnnotationPreview(text: "Key finding", page: 12, color: .green, type: .underline)
    ])
    .padding()
}

#Preview("Annotation Summary") {
    AnnotationSummaryView(highlightCount: 12, noteCount: 5, underlineCount: 3)
        .padding()
}
