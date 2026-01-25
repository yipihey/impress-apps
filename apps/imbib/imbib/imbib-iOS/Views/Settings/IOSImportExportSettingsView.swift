//
//  IOSImportExportSettingsView.swift
//  imbib-iOS
//
//  Created by Claude on 2026-01-17.
//

import SwiftUI
import PublicationManagerCore

/// iOS settings view for import and export options.
struct IOSImportExportSettingsView: View {

    // MARK: - State

    @AppStorage("autoGenerateCiteKeys") private var autoGenerateCiteKeys: Bool = true
    @AppStorage("defaultEntryType") private var defaultEntryType: String = "article"
    @AppStorage("exportPreserveRawBibTeX") private var exportPreserveRawBibTeX: Bool = true

    // Entry types for picker
    private let entryTypes = [
        "article",
        "book",
        "inproceedings",
        "incollection",
        "phdthesis",
        "mastersthesis",
        "techreport",
        "unpublished",
        "misc"
    ]

    // MARK: - Body

    var body: some View {
        List {
            importSection
            exportSection
        }
        .navigationTitle("Import/Export")
    }

    // MARK: - Import Section

    private var importSection: some View {
        Section {
            Toggle("Auto-Generate Cite Keys", isOn: $autoGenerateCiteKeys)

            Picker("Default Entry Type", selection: $defaultEntryType) {
                ForEach(entryTypes, id: \.self) { type in
                    Text(type.capitalized).tag(type)
                }
            }
        } header: {
            Text("Import")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("When auto-generate is enabled, cite keys are created in the format: LastName + Year + TitleWord (e.g., Einstein1905Electrodynamics)")
                Text("Default entry type is used when creating new entries without a specified type.")
            }
        }
    }

    // MARK: - Export Section

    private var exportSection: some View {
        Section {
            Toggle("Preserve Raw BibTeX", isOn: $exportPreserveRawBibTeX)
        } header: {
            Text("Export")
        } footer: {
            Text("When enabled, exports use the original BibTeX formatting when available. This preserves custom formatting and fields not recognized by imbib.")
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        IOSImportExportSettingsView()
    }
}
