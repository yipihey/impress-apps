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

    /// The publication to act on
    public let publication: CDPublication

    /// Callback when citation action is triggered
    public var onAddCitation: (() -> Void)?

    /// Callback when "convert to manuscript" is triggered
    public var onConvertToManuscript: (() -> Void)?

    /// Callback when "view manuscripts citing this" is triggered
    public var onViewCitingManuscripts: (() -> Void)?

    // MARK: - Initialization

    public init(
        publication: CDPublication,
        onAddCitation: (() -> Void)? = nil,
        onConvertToManuscript: (() -> Void)? = nil,
        onViewCitingManuscripts: (() -> Void)? = nil
    ) {
        self.publication = publication
        self.onAddCitation = onAddCitation
        self.onConvertToManuscript = onConvertToManuscript
        self.onViewCitingManuscripts = onViewCitingManuscripts
    }

    // MARK: - Body

    public var body: some View {
        Group {
            if publication.isManuscript {
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
                    .fetchManuscriptsCiting(publication)
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
            // Show citation count
            let citationCount = publication.citedPublicationCount
            if citationCount > 0 {
                Button {
                    // This would navigate to citations view
                } label: {
                    Label(
                        "\(citationCount) Citation\(citationCount == 1 ? "" : "s")",
                        systemImage: "quote.bubble"
                    )
                }
                .disabled(true) // Informational only in context menu
            }

            // Status submenu
            Menu {
                ForEach(ManuscriptStatus.allCases, id: \.self) { status in
                    Button {
                        publication.updateManuscriptStatus(to: status)
                        PersistenceController.shared.save()
                    } label: {
                        if publication.manuscriptStatus == status {
                            Label(status.displayName, systemImage: "checkmark")
                        } else {
                            Text(status.displayName)
                        }
                    }
                }
            } label: {
                if let status = publication.manuscriptStatus {
                    Label("Status: \(status.displayName)", systemImage: status.systemImage)
                } else {
                    Label("Set Status", systemImage: "flag")
                }
            }

            Divider()

            // Remove manuscript status
            Button(role: .destructive) {
                publication.removeManuscriptStatus()
                PersistenceController.shared.save()
            } label: {
                Label("Remove Manuscript Status", systemImage: "xmark.circle")
            }
        }
    }
}

// MARK: - Quick Citation Menu

/// A simplified menu for quickly adding a paper to a manuscript.
public struct QuickCitationMenu: View {

    // MARK: - Properties

    /// The publication to cite
    public let publication: CDPublication

    /// Available manuscripts
    @State private var manuscripts: [CDPublication] = []

    // MARK: - Initialization

    public init(publication: CDPublication) {
        self.publication = publication
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
                            if manuscript.cites(publication) {
                                Image(systemName: "checkmark")
                            }
                            Text(manuscript.title ?? "Untitled")
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

    private func toggleCitation(_ manuscript: CDPublication) {
        if manuscript.cites(publication) {
            manuscript.removeCitation(publication)
        } else {
            manuscript.addCitation(publication)
        }
        PersistenceController.shared.save()
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

    /// The publication to convert
    public let publication: CDPublication

    /// Dismiss action
    @Environment(\.dismiss) private var dismiss

    /// Target journal/venue
    @State private var targetJournal = ""

    /// Initial status
    @State private var initialStatus: ManuscriptStatus = .drafting

    /// Notes
    @State private var notes = ""

    // MARK: - Initialization

    public init(publication: CDPublication) {
        self.publication = publication
    }

    // MARK: - Body

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(publication.title ?? "Untitled")
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
        publication.convertToManuscript(targetJournal: targetJournal.isEmpty ? nil : targetJournal)
        publication.manuscriptStatus = initialStatus
        if !notes.isEmpty {
            publication.manuscriptNotes = notes
        }
        PersistenceController.shared.save()
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
