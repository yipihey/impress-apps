//
//  RemarkableConflictView.swift
//  PublicationManagerCore
//
//  Conflict resolution UI for reMarkable annotation sync.
//  ADR-019: reMarkable Tablet Integration
//

import SwiftUI

// MARK: - Conflict Model

/// Represents a conflict between local and reMarkable annotations.
public struct RemarkableConflict: Identifiable, Sendable {
    public let id = UUID()
    public let documentID: String
    public let publicationTitle: String
    public let localModified: Date
    public let remoteModified: Date
    public let localAnnotationCount: Int
    public let remoteAnnotationCount: Int

    public init(
        documentID: String,
        publicationTitle: String,
        localModified: Date,
        remoteModified: Date,
        localAnnotationCount: Int,
        remoteAnnotationCount: Int
    ) {
        self.documentID = documentID
        self.publicationTitle = publicationTitle
        self.localModified = localModified
        self.remoteModified = remoteModified
        self.localAnnotationCount = localAnnotationCount
        self.remoteAnnotationCount = remoteAnnotationCount
    }
}

// MARK: - Conflict Resolution View

/// View for resolving annotation conflicts between imbib and reMarkable.
///
/// Displays a side-by-side comparison with options to:
/// - Keep imbib annotations (discard reMarkable changes)
/// - Keep reMarkable annotations (overwrite local)
/// - Merge both (keep all annotations from both sources)
public struct RemarkableConflictView: View {

    // MARK: - Properties

    let conflict: RemarkableConflict
    let onResolve: (ConflictResolution) -> Void

    @Environment(\.dismiss) private var dismiss

    // MARK: - Body

    public init(conflict: RemarkableConflict, onResolve: @escaping (ConflictResolution) -> Void) {
        self.conflict = conflict
        self.onResolve = onResolve
    }

    public var body: some View {
        VStack(spacing: 24) {
            // Header
            headerView

            // Description
            Text("The annotations for \"\(conflict.publicationTitle)\" have been modified both in imbib and on your reMarkable.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            // Side-by-side comparison
            comparisonView

            // Resolution options
            resolutionButtons

            // Cancel button
            Button("Cancel") {
                dismiss()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(24)
        #if os(macOS)
        .frame(width: 500, height: 450)
        #endif
    }

    // MARK: - Header

    private var headerView: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.orange)

            Text("Annotation Conflict")
                .font(.title2.bold())
        }
    }

    // MARK: - Comparison View

    private var comparisonView: some View {
        HStack(alignment: .top, spacing: 20) {
            // imbib side
            ConflictSideView(
                title: "imbib",
                icon: "doc.text.fill",
                iconColor: .blue,
                date: conflict.localModified,
                annotationCount: conflict.localAnnotationCount
            )

            // Divider
            Rectangle()
                .fill(.quaternary)
                .frame(width: 1)

            // reMarkable side
            ConflictSideView(
                title: "reMarkable",
                icon: "tablet.landscape",
                iconColor: .orange,
                date: conflict.remoteModified,
                annotationCount: conflict.remoteAnnotationCount
            )
        }
        .padding()
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Resolution Buttons

    private var resolutionButtons: some View {
        VStack(spacing: 12) {
            // Keep imbib
            Button {
                onResolve(.preferLocal)
                dismiss()
            } label: {
                Label("Keep imbib annotations", systemImage: "arrow.left")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            // Keep reMarkable
            Button {
                onResolve(.preferRemarkable)
                dismiss()
            } label: {
                Label("Keep reMarkable annotations", systemImage: "arrow.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            // Merge both
            Button {
                onResolve(.keepBoth)
                dismiss()
            } label: {
                Label("Merge all annotations", systemImage: "arrow.triangle.merge")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .controlSize(.large)
    }
}

// MARK: - Conflict Side View

/// Shows one side of the conflict comparison.
private struct ConflictSideView: View {
    let title: String
    let icon: String
    let iconColor: Color
    let date: Date
    let annotationCount: Int

    var body: some View {
        VStack(spacing: 12) {
            // Icon and title
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.title)
                    .foregroundStyle(iconColor)

                Text(title)
                    .font(.headline)
            }

            Divider()

            // Stats
            VStack(spacing: 8) {
                // Annotation count
                HStack {
                    Image(systemName: "pencil.and.scribble")
                        .foregroundStyle(.secondary)
                    Text("\(annotationCount) annotation\(annotationCount == 1 ? "" : "s")")
                }
                .font(.subheadline)

                // Modified date
                HStack {
                    Image(systemName: "clock")
                        .foregroundStyle(.secondary)
                    Text(date, style: .relative)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Conflict Alert Modifier

/// Modifier to present a conflict resolution sheet.
public struct ConflictAlertModifier: ViewModifier {
    @Binding var conflict: RemarkableConflict?
    let onResolve: (ConflictResolution) -> Void

    public func body(content: Content) -> some View {
        content
            .sheet(item: $conflict) { conflict in
                RemarkableConflictView(conflict: conflict, onResolve: onResolve)
            }
    }
}

public extension View {
    /// Present a conflict resolution sheet when a conflict is detected.
    func remarkableConflictAlert(
        conflict: Binding<RemarkableConflict?>,
        onResolve: @escaping (ConflictResolution) -> Void
    ) -> some View {
        modifier(ConflictAlertModifier(conflict: conflict, onResolve: onResolve))
    }
}

// MARK: - Preview

#if DEBUG
struct RemarkableConflictView_Previews: PreviewProvider {
    static var previews: some View {
        RemarkableConflictView(
            conflict: RemarkableConflict(
                documentID: "test-123",
                publicationTitle: "A Study of Machine Learning Approaches",
                localModified: Date().addingTimeInterval(-3600),
                remoteModified: Date().addingTimeInterval(-1800),
                localAnnotationCount: 5,
                remoteAnnotationCount: 3
            ),
            onResolve: { _ in }
        )
    }
}
#endif
