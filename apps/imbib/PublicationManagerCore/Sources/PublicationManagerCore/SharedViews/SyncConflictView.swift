//
//  SyncConflictView.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-16.
//

import SwiftUI
import CoreData

// MARK: - Sync Conflict List View

/// Shows all pending sync conflicts
public struct SyncConflictListView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @State private var conflictQueue = SyncConflictQueue.shared

    public init() {}

    public var body: some View {
        NavigationStack {
            List {
                if conflictQueue.pendingConflicts.isEmpty {
                    ContentUnavailableView(
                        "No Conflicts",
                        systemImage: "checkmark.circle",
                        description: Text("All sync conflicts have been resolved")
                    )
                } else {
                    ForEach(conflictQueue.pendingConflicts) { conflict in
                        NavigationLink(value: conflict) {
                            SyncConflictRow(conflict: conflict)
                        }
                    }
                }
            }
            .navigationTitle("Sync Conflicts")
            .navigationDestination(for: SyncConflict.self) { conflict in
                SyncConflictDetailView(conflict: conflict)
            }
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    if !conflictQueue.pendingConflicts.isEmpty {
                        Button("Resolve All") {
                            resolveAllAutomatically()
                        }
                    }
                }
            }
        }
    }

    private func resolveAllAutomatically() {
        Task {
            for conflict in conflictQueue.pendingConflicts {
                switch conflict {
                case .citeKey(let c):
                    // Use first suggested resolution (rename incoming)
                    if let firstResolution = c.suggestedResolutions.first {
                        try? await conflictQueue.resolveCiteKeyConflict(
                            c,
                            with: firstResolution,
                            context: viewContext
                        )
                    }
                case .pdf:
                    // Keep local by default
                    break
                }
            }
        }
    }
}

// MARK: - Sync Conflict Row

struct SyncConflictRow: View {
    let conflict: SyncConflict

    var body: some View {
        HStack {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .font(.title2)

            VStack(alignment: .leading, spacing: 4) {
                Text(conflict.title)
                    .font(.headline)

                Text(conflict.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                Text("Detected \(conflict.detectedAt, style: .relative) ago")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }

    private var iconName: String {
        switch conflict {
        case .citeKey: return "key.fill"
        case .pdf: return "doc.fill"
        }
    }

    private var iconColor: Color {
        switch conflict {
        case .citeKey: return .orange
        case .pdf: return .red
        }
    }
}

// MARK: - Sync Conflict Detail View

struct SyncConflictDetailView: View {
    let conflict: SyncConflict
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss
    @State private var isResolving = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                VStack(alignment: .leading, spacing: 8) {
                    Label(conflict.title, systemImage: iconName)
                        .font(.title2.bold())

                    Text(conflict.description)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 12))

                // Conflict-specific content
                switch conflict {
                case .citeKey(let c):
                    CiteKeyConflictContent(
                        conflict: c,
                        onResolve: resolveConflict
                    )
                case .pdf(let c):
                    PDFConflictContent(
                        conflict: c,
                        onResolve: resolvePDFConflict
                    )
                }

                // Error message
                if let error = errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }
            .padding()
        }
        .navigationTitle("Resolve Conflict")
        .disabled(isResolving)
        .overlay {
            if isResolving {
                ProgressView("Resolving...")
                    .padding()
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var iconName: String {
        switch conflict {
        case .citeKey: return "key.fill"
        case .pdf: return "doc.fill"
        }
    }

    private func resolveConflict(_ resolution: CiteKeyResolution) {
        guard case .citeKey(let c) = conflict else { return }

        isResolving = true
        errorMessage = nil

        Task {
            do {
                try await SyncConflictQueue.shared.resolveCiteKeyConflict(
                    c,
                    with: resolution,
                    context: viewContext
                )
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isResolving = false
        }
    }

    private func resolvePDFConflict(_ resolution: PDFConflictResolution) {
        guard case .pdf(let c) = conflict else { return }

        isResolving = true
        errorMessage = nil

        Task {
            do {
                try await SyncConflictQueue.shared.resolvePDFConflict(
                    c,
                    with: resolution,
                    context: viewContext
                )
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isResolving = false
        }
    }
}

// MARK: - Cite Key Conflict Content

struct CiteKeyConflictContent: View {
    let conflict: CiteKeyConflict
    let onResolve: (CiteKeyResolution) -> Void

    @Environment(\.managedObjectContext) private var viewContext
    @State private var incomingPublication: CDPublication?
    @State private var existingPublication: CDPublication?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Publication previews
            HStack(alignment: .top, spacing: 16) {
                // Incoming
                PublicationPreviewCard(
                    title: "Incoming",
                    publication: incomingPublication,
                    highlight: .blue
                )

                // Existing
                PublicationPreviewCard(
                    title: "Existing",
                    publication: existingPublication,
                    highlight: .orange
                )
            }

            Divider()

            // Resolution options
            Text("Choose a Resolution")
                .font(.headline)

            ForEach(conflict.suggestedResolutions) { resolution in
                Button {
                    onResolve(resolution)
                } label: {
                    HStack {
                        Text(resolution.description)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
        .onAppear {
            loadPublications()
        }
    }

    private func loadPublications() {
        let incomingRequest = NSFetchRequest<CDPublication>(entityName: "Publication")
        incomingRequest.predicate = NSPredicate(format: "id == %@", conflict.incomingPublicationID as CVarArg)

        let existingRequest = NSFetchRequest<CDPublication>(entityName: "Publication")
        existingRequest.predicate = NSPredicate(format: "id == %@", conflict.existingPublicationID as CVarArg)

        incomingPublication = try? viewContext.fetch(incomingRequest).first
        existingPublication = try? viewContext.fetch(existingRequest).first
    }
}

// MARK: - Publication Preview Card

struct PublicationPreviewCard: View {
    let title: String
    let publication: CDPublication?
    let highlight: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.bold())
                .foregroundStyle(highlight)

            if let pub = publication {
                Text(pub.title ?? "No title")
                    .font(.subheadline.bold())
                    .lineLimit(2)

                Text(pub.authorString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if pub.year > 0 {
                    Text(String(pub.year))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text("Key: \(pub.citeKey)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            } else {
                Text("Publication not found")
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(highlight.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(highlight.opacity(0.3), lineWidth: 1)
        )
    }
}

// MARK: - PDF Conflict Content

struct PDFConflictContent: View {
    let conflict: PDFConflict
    let onResolve: (PDFConflictResolution) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // File info
            GroupBox("Local File") {
                VStack(alignment: .leading, spacing: 4) {
                    Text(conflict.localFilePath)
                        .font(.caption.monospaced())

                    Text("Modified: \(conflict.localModifiedDate, style: .date)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            GroupBox("Remote File") {
                VStack(alignment: .leading, spacing: 4) {
                    Text(conflict.remoteFilePath)
                        .font(.caption.monospaced())

                    Text("Modified: \(conflict.remoteModifiedDate, style: .date)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            // Resolution options
            Text("Choose a Resolution")
                .font(.headline)

            Button {
                onResolve(.keepLocal)
            } label: {
                ResolutionOptionRow(
                    title: "Keep Local",
                    description: "Discard remote changes",
                    icon: "checkmark.circle"
                )
            }
            .buttonStyle(.plain)

            Button {
                onResolve(.keepRemote)
            } label: {
                ResolutionOptionRow(
                    title: "Keep Remote",
                    description: "Replace local with remote",
                    icon: "arrow.down.circle"
                )
            }
            .buttonStyle(.plain)

            Button {
                onResolve(.keepBoth)
            } label: {
                ResolutionOptionRow(
                    title: "Keep Both",
                    description: "Save remote as a conflict copy",
                    icon: "doc.on.doc"
                )
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Resolution Option Row

struct ResolutionOptionRow: View {
    let title: String
    let description: String
    let icon: String

    var body: some View {
        HStack {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.blue)
                .frame(width: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.bold())

                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(Color.secondary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Sync Conflict Badge

/// Badge showing number of pending conflicts (for toolbar/sidebar)
public struct SyncConflictBadge: View {
    @State private var conflictQueue = SyncConflictQueue.shared

    public init() {}

    public var body: some View {
        if conflictQueue.hasConflicts {
            Text("\(conflictQueue.conflictCount)")
                .font(.caption2.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.red)
                .clipShape(Capsule())
        }
    }
}

// MARK: - Sync Status View

/// Shows current sync status with icon
public struct SyncStatusView: View {
    @State private var syncStatus: SyncService.SyncStatus = .notSynced

    public init() {}

    public var body: some View {
        HStack(spacing: 4) {
            Image(systemName: syncStatus.icon)

            Text(syncStatus.description)
                .font(.caption)
        }
        .foregroundStyle(.secondary)
        .task {
            syncStatus = await SyncService.shared.syncStatus
        }
    }
}
