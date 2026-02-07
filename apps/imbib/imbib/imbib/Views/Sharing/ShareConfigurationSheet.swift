//
//  ShareConfigurationSheet.swift
//  imbib
//
//  Created by Claude on 2026-02-06.
//

#if os(macOS)
import SwiftUI
import CloudKit
import PublicationManagerCore

/// Configuration sheet shown before sharing via iCloud.
/// Lets users choose what content to include and handles the CloudKit sharing flow.
struct ShareConfigurationSheet: View {
    let item: ShareableItem
    @Environment(\.dismiss) private var dismiss

    @AppStorage("sharing.includeNotes") private var includeNotes = true
    @AppStorage("sharing.includePDFs") private var includePDFs = false
    @AppStorage("sharing.includeFlags") private var includeFlags = true
    @AppStorage("sharing.includeTags") private var includeTags = true

    @State private var isSharing = false
    @State private var shareError: String?
    @State private var showCloudKitSheet = false
    @State private var activeShare: CKShare?
    @State private var sharedLibrary: CDLibrary?

    private var isCloudKitEnabled: Bool {
        PersistenceController.shared.isCloudKitEnabled
    }

    private var itemName: String {
        switch item {
        case .library(let lib): return lib.displayName
        case .collection(let col): return col.name
        }
    }

    private var itemIcon: String {
        switch item {
        case .library: return "books.vertical"
        case .collection: return "folder"
        }
    }

    private var publicationCount: Int {
        switch item {
        case .library(let lib): return lib.publications?.filter({ !$0.isDeleted }).count ?? 0
        case .collection(let col): return col.matchingPublicationCount
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: itemIcon)
                    .font(.title)
                    .foregroundStyle(.secondary)

                Text(itemName)
                    .font(.headline)

                Text("\(publicationCount) papers")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 20)
            .padding(.bottom, 16)

            Divider()

            // Content toggles
            VStack(spacing: 0) {
                toggleRow(
                    label: "Papers",
                    icon: "doc.text",
                    isOn: .constant(true),
                    disabled: true,
                    caption: "Always included"
                )

                Divider().padding(.leading, 36)

                toggleRow(
                    label: "Notes",
                    icon: "note.text",
                    isOn: $includeNotes
                )

                Divider().padding(.leading, 36)

                toggleRow(
                    label: "Flags",
                    icon: "flag",
                    isOn: $includeFlags
                )

                Divider().padding(.leading, 36)

                toggleRow(
                    label: "Tags",
                    icon: "tag",
                    isOn: $includeTags
                )

                Divider().padding(.leading, 36)

                toggleRow(
                    label: "PDFs",
                    icon: "doc.richtext",
                    isOn: $includePDFs,
                    caption: "Large files; CloudKit has a 50 MB limit per record"
                )
            }
            .padding(.vertical, 8)

            // iCloud unavailable banner
            if !isCloudKitEnabled {
                Divider()

                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.icloud")
                        .foregroundStyle(.orange)
                    Text("Sign in to iCloud in System Settings to share libraries.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }

            // Error banner
            if let shareError {
                Divider()

                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                    Text(shareError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }

            Divider()

            // Buttons
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Share") {
                    performShare()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isCloudKitEnabled || isSharing)
            }
            .padding(16)
        }
        .frame(width: 340)
        .sheet(isPresented: $showCloudKitSheet) {
            if let share = activeShare, let library = sharedLibrary {
                let containerID = PersistenceController.shared.configuration.cloudKitContainerIdentifier
                    ?? "iCloud.com.imbib.app"
                let ckContainer = CKContainer(identifier: containerID)
                CloudKitSharingView(
                    share: share,
                    container: ckContainer,
                    library: library
                )
            }
        }
    }

    private func toggleRow(
        label: String,
        icon: String,
        isOn: Binding<Bool>,
        disabled: Bool = false,
        caption: String? = nil
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .frame(width: 20)
                .foregroundStyle(disabled ? .tertiary : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .foregroundStyle(disabled ? .secondary : .primary)
                if let caption {
                    Text(caption)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            Toggle("", isOn: isOn)
                .labelsHidden()
                .disabled(disabled)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private func performShare() {
        let options = ShareOptions(
            includeNotes: includeNotes,
            includePDFs: includePDFs,
            includeFlags: includeFlags,
            includeTags: includeTags
        )
        isSharing = true
        shareError = nil

        Task {
            do {
                let result: (CDLibrary, CKShare)
                switch item {
                case .library(let library):
                    result = try await CloudKitSharingService.shared.shareLibrary(library, options: options)
                case .collection(let collection):
                    result = try await CloudKitSharingService.shared.shareCollection(collection, options: options)
                }
                sharedLibrary = result.0
                activeShare = result.1
                isSharing = false
                showCloudKitSheet = true
            } catch {
                shareError = error.localizedDescription
                isSharing = false
            }
        }
    }
}
#endif
