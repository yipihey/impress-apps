//
//  ManuscriptContextMenuActions.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-19.
//

import SwiftUI

// MARK: - Manuscript Context Menu Actions (ADR-021)

/// Context menu actions for manuscript-related operations on publications.
public struct ManuscriptContextMenuActions: View {

    // MARK: - Properties

    /// The publication ID to act on
    public let publicationID: UUID

    /// Callback when citation action is triggered
    public var onAddCitation: (() -> Void)?

    /// Callback when "convert to manuscript" is triggered
    public var onConvertToManuscript: (() -> Void)?

    /// Callback when "view manuscripts citing this" is triggered
    public var onViewCitingManuscripts: (() -> Void)?

    /// Callback when "Open in imprint" is triggered
    public var onOpenInImprint: (() -> Void)?

    /// Callback when "Link imprint Document" is triggered
    public var onLinkImprintDocument: (() -> Void)?

    // MARK: - Initialization

    public init(
        publicationID: UUID,
        onAddCitation: (() -> Void)? = nil,
        onConvertToManuscript: (() -> Void)? = nil,
        onViewCitingManuscripts: (() -> Void)? = nil,
        onOpenInImprint: (() -> Void)? = nil,
        onLinkImprintDocument: (() -> Void)? = nil
    ) {
        self.publicationID = publicationID
        self.onAddCitation = onAddCitation
        self.onConvertToManuscript = onConvertToManuscript
        self.onViewCitingManuscripts = onViewCitingManuscripts
        self.onOpenInImprint = onOpenInImprint
        self.onLinkImprintDocument = onLinkImprintDocument
    }

    // MARK: - Computed

    private var store: RustStoreAdapter { RustStoreAdapter.shared }

    private var detail: PublicationModel? {
        store.getPublicationDetail(id: publicationID)
    }

    private var isManuscript: Bool {
        detail?.fields[ManuscriptMetadataKey.status.rawValue] != nil
    }

    private var manuscriptStatus: ManuscriptStatus? {
        guard let statusStr = detail?.fields[ManuscriptMetadataKey.status.rawValue] else { return nil }
        return ManuscriptStatus(rawValue: statusStr)
    }

    private var hasLinkedImprintDocument: Bool {
        guard let d = detail else { return false }
        return d.fields[ManuscriptMetadataKey.imprintDocumentUUID.rawValue] != nil
    }

    private var citedPublicationCount: Int {
        guard let d = detail else { return 0 }
        return ManuscriptCollectionManager.parseCitedIDs(from: d.fields).count
    }

    // MARK: - Body

    public var body: some View {
        Group {
            if isManuscript {
                manuscriptActions
            } else {
                publicationActions
            }
        }
    }

    // MARK: - Publication Actions

    /// Actions for regular publications (not manuscripts)
    private var publicationActions: some View {
        Group {
            // Add as citation to a manuscript
            if onAddCitation != nil {
                Button {
                    onAddCitation?()
                } label: {
                    Label("Add to Manuscript...", systemImage: "doc.badge.plus")
                }
            }

            // Convert to manuscript
            if onConvertToManuscript != nil {
                Button {
                    onConvertToManuscript?()
                } label: {
                    Label("Convert to Manuscript", systemImage: "doc.text")
                }
            }

            // View manuscripts citing this paper
            if onViewCitingManuscripts != nil {
                let citingCount = ManuscriptCollectionManager.shared
                    .fetchManuscriptsCiting(publicationID)
                    .count

                if citingCount > 0 {
                    Button {
                        onViewCitingManuscripts?()
                    } label: {
                        Label(
                            "Cited in \(citingCount) Manuscript\(citingCount == 1 ? "" : "s")",
                            systemImage: "doc.text.magnifyingglass"
                        )
                    }
                }
            }
        }
    }

    // MARK: - Manuscript Actions

    /// Actions for manuscripts
    private var manuscriptActions: some View {
        Group {
            // imprint integration actions
            imprintActions

            Divider()

            // Show citation count
            let citCount = citedPublicationCount
            if citCount > 0 {
                Button {
                    // This would navigate to citations view
                } label: {
                    Label(
                        "\(citCount) Citation\(citCount == 1 ? "" : "s")",
                        systemImage: "quote.bubble"
                    )
                }
                .disabled(true) // Informational only in context menu
            }

            // Status submenu
            Menu {
                ForEach(ManuscriptStatus.allCases, id: \.self) { status in
                    Button {
                        store.updateField(id: publicationID, field: ManuscriptMetadataKey.status.rawValue, value: status.rawValue)
                    } label: {
                        if manuscriptStatus == status {
                            Label(status.displayName, systemImage: "checkmark")
                        } else {
                            Text(status.displayName)
                        }
                    }
                }
            } label: {
                if let status = manuscriptStatus {
                    Label("Status: \(status.displayName)", systemImage: status.systemImage)
                } else {
                    Label("Set Status", systemImage: "flag")
                }
            }

            Divider()

            // Remove manuscript status
            Button(role: .destructive) {
                store.updateField(id: publicationID, field: ManuscriptMetadataKey.status.rawValue, value: nil)
            } label: {
                Label("Remove Manuscript Status", systemImage: "xmark.circle")
            }
        }
    }

    // MARK: - imprint Actions

    /// Actions for imprint integration
    @ViewBuilder
    private var imprintActions: some View {
        if hasLinkedImprintDocument {
            // Open in imprint
            Button {
                onOpenInImprint?()
            } label: {
                Label("Open in imprint", systemImage: "doc.text.fill")
            }

            // Unlink action (in submenu to prevent accidents)
            Menu {
                Button(role: .destructive) {
                    store.updateField(id: publicationID, field: ManuscriptMetadataKey.imprintDocumentUUID.rawValue, value: nil)
                    store.updateField(id: publicationID, field: ManuscriptMetadataKey.imprintDocumentPath.rawValue, value: nil)
                    store.updateField(id: publicationID, field: ManuscriptMetadataKey.imprintBookmarkData.rawValue, value: nil)
                } label: {
                    Label("Unlink Document", systemImage: "link.badge.minus")
                }
            } label: {
                Label("imprint Document", systemImage: "ellipsis.circle")
            }
        } else {
            // Link imprint document
            Button {
                onLinkImprintDocument?()
            } label: {
                Label("Link imprint Document...", systemImage: "link.badge.plus")
            }

            // Create new imprint document
            Button {
                onLinkImprintDocument?()
            } label: {
                Label("Create imprint Document...", systemImage: "doc.badge.plus")
            }
        }
    }
}

// MARK: - Quick Citation Menu

/// A simplified menu for quickly adding a paper to a manuscript.
public struct QuickCitationMenu: View {

    // MARK: - Properties

    /// The publication ID to cite
    public let publicationID: UUID

    /// Available manuscripts (as row data)
    @State private var manuscripts: [PublicationRowData] = []

    // MARK: - Initialization

    public init(publicationID: UUID) {
        self.publicationID = publicationID
    }

    // MARK: - Body

    public var body: some View {
        Menu {
            if manuscripts.isEmpty {
                Text("No manuscripts available")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(manuscripts, id: \.id) { manuscript in
                    Button {
                        toggleCitation(manuscript)
                    } label: {
                        HStack {
                            if manuscriptCites(manuscript.id, publication: publicationID) {
                                Image(systemName: "checkmark")
                            }
                            Text(manuscript.title)
                        }
                    }
                }
            }

            Divider()

            Button {
                // Show full citation sheet
            } label: {
                Label("More Options...", systemImage: "ellipsis")
            }
        } label: {
            Label("Add to Manuscript", systemImage: "doc.badge.plus")
        }
        .onAppear {
            loadManuscripts()
        }
    }

    // MARK: - Actions

    private func loadManuscripts() {
        manuscripts = ManuscriptCollectionManager.shared.fetchActiveManuscripts()
    }

    private func manuscriptCites(_ manuscriptID: UUID, publication pubID: UUID) -> Bool {
        let store = RustStoreAdapter.shared
        guard let detail = store.getPublicationDetail(id: manuscriptID) else { return false }
        let citedIDs = ManuscriptCollectionManager.parseCitedIDs(from: detail.fields)
        return citedIDs.contains(pubID)
    }

    private func toggleCitation(_ manuscript: PublicationRowData) {
        let store = RustStoreAdapter.shared
        guard let detail = store.getPublicationDetail(id: manuscript.id) else { return }
        var citedIDs = ManuscriptCollectionManager.parseCitedIDs(from: detail.fields)

        if citedIDs.contains(publicationID) {
            citedIDs.remove(publicationID)
        } else {
            citedIDs.insert(publicationID)
        }

        let encoded = ManuscriptCollectionManager.encodeCitedIDs(citedIDs)
        store.updateField(id: manuscript.id, field: ManuscriptMetadataKey.citedPublicationIDs.rawValue, value: encoded)
    }
}

// MARK: - Manuscript Status Picker

/// A picker for changing manuscript status.
public struct ManuscriptStatusPicker: View {

    // MARK: - Properties

    /// The manuscript to update
    @Binding public var status: ManuscriptStatus?

    /// Callback when status changes
    public var onChange: ((ManuscriptStatus?) -> Void)?

    // MARK: - Initialization

    public init(
        status: Binding<ManuscriptStatus?>,
        onChange: ((ManuscriptStatus?) -> Void)? = nil
    ) {
        self._status = status
        self.onChange = onChange
    }

    // MARK: - Body

    public var body: some View {
        Picker("Status", selection: $status) {
            Text("None").tag(nil as ManuscriptStatus?)
            Divider()
            ForEach(ManuscriptStatus.allCases, id: \.self) { status in
                Label(status.displayName, systemImage: status.systemImage)
                    .tag(status as ManuscriptStatus?)
            }
        }
        .onChange(of: status) { _, newValue in
            onChange?(newValue)
        }
    }
}

// MARK: - Manuscript Status Badge

/// A badge showing manuscript status with color coding.
public struct ManuscriptStatusBadge: View {

    /// The status to display
    public let status: ManuscriptStatus

    /// Size variant
    public var size: BadgeSize = .regular

    public enum BadgeSize {
        case compact
        case regular
        case large
    }

    public init(status: ManuscriptStatus, size: BadgeSize = .regular) {
        self.status = status
        self.size = size
    }

    public var body: some View {
        Label(status.displayName, systemImage: status.systemImage)
            .font(fontSize)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(status.color.opacity(0.2))
            .foregroundStyle(status.color)
            .clipShape(Capsule())
    }

    private var fontSize: Font {
        switch size {
        case .compact: return .caption2
        case .regular: return .caption
        case .large: return .subheadline
        }
    }

    private var horizontalPadding: CGFloat {
        switch size {
        case .compact: return 6
        case .regular: return 8
        case .large: return 12
        }
    }

    private var verticalPadding: CGFloat {
        switch size {
        case .compact: return 2
        case .regular: return 4
        case .large: return 6
        }
    }
}

// MARK: - Convert to Manuscript Sheet

/// A sheet for converting a publication to a manuscript.
public struct ConvertToManuscriptSheet: View {

    // MARK: - Properties

    /// The publication ID to convert
    public let publicationID: UUID

    /// Dismiss action
    @Environment(\.dismiss) private var dismiss

    /// Target journal/venue
    @State private var targetJournal = ""

    /// Initial status
    @State private var initialStatus: ManuscriptStatus = .drafting

    /// Notes
    @State private var notes = ""

    // MARK: - Computed

    private var title: String {
        RustStoreAdapter.shared.getPublicationDetail(id: publicationID)?.title ?? "Untitled"
    }

    // MARK: - Initialization

    public init(publicationID: UUID) {
        self.publicationID = publicationID
    }

    // MARK: - Body

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(title)
                        .font(.headline)
                } header: {
                    Text("Converting")
                }

                Section {
                    TextField("Journal/Venue", text: $targetJournal)
                        .textContentType(.organizationName)

                    Picker("Initial Status", selection: $initialStatus) {
                        ForEach(ManuscriptStatus.allCases, id: \.self) { status in
                            Label(status.displayName, systemImage: status.systemImage)
                                .tag(status)
                        }
                    }
                } header: {
                    Text("Manuscript Details")
                }

                Section {
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                } header: {
                    Text("Notes")
                }
            }
            .navigationTitle("Convert to Manuscript")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Convert") {
                        convertToManuscript()
                        dismiss()
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 400, minHeight: 300)
        #endif
    }

    // MARK: - Actions

    private func convertToManuscript() {
        let store = RustStoreAdapter.shared
        store.updateField(id: publicationID, field: ManuscriptMetadataKey.status.rawValue, value: initialStatus.rawValue)
        if !targetJournal.isEmpty {
            store.updateField(id: publicationID, field: ManuscriptMetadataKey.targetJournal.rawValue, value: targetJournal)
        }
        if !notes.isEmpty {
            store.updateField(id: publicationID, field: ManuscriptMetadataKey.notes.rawValue, value: notes)
        }
    }
}

// MARK: - Preview

#Preview("Status Badge") {
    VStack(spacing: 12) {
        ForEach(ManuscriptStatus.allCases, id: \.self) { status in
            HStack {
                ManuscriptStatusBadge(status: status, size: .compact)
                ManuscriptStatusBadge(status: status, size: .regular)
                ManuscriptStatusBadge(status: status, size: .large)
            }
        }
    }
    .padding()
}

#Preview("Status Picker") {
    struct PreviewWrapper: View {
        @State var status: ManuscriptStatus? = .drafting

        var body: some View {
            Form {
                ManuscriptStatusPicker(status: $status)
            }
        }
    }
    return PreviewWrapper()
}
