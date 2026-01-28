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

    @State private var citeKeySettings = CiteKeyFormatSettings.default
    @State private var showFormatHelp = false

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
            citeKeyFormatSection
            importSection
            exportSection
        }
        .navigationTitle("Import/Export")
        .task {
            citeKeySettings = await ImportExportSettingsStore.shared.citeKeyFormatSettings
        }
        .sheet(isPresented: $showFormatHelp) {
            IOSCiteKeyFormatHelpView()
        }
    }

    // MARK: - Cite Key Format Section

    private var citeKeyFormatSection: some View {
        Section {
            // Preset picker
            Picker("Format Preset", selection: $citeKeySettings.preset) {
                ForEach(CiteKeyFormatPreset.allCases, id: \.self) { preset in
                    Text(preset.displayName).tag(preset)
                }
            }
            .onChange(of: citeKeySettings.preset) { _, newValue in
                Task {
                    await ImportExportSettingsStore.shared.updateCiteKeyFormatPreset(newValue)
                }
            }

            // Custom format field (only when custom is selected)
            if citeKeySettings.preset == .custom {
                HStack {
                    TextField("Format", text: $citeKeySettings.customFormat)
                        .fontDesign(.monospaced)
                        .autocapitalization(.none)
                        .onChange(of: citeKeySettings.customFormat) { _, newValue in
                            Task {
                                await ImportExportSettingsStore.shared.updateCiteKeyCustomFormat(newValue)
                            }
                        }

                    Button {
                        showFormatHelp = true
                    } label: {
                        Image(systemName: "questionmark.circle")
                    }
                }
            }

            // Preview
            HStack {
                Text("Preview")
                Spacer()
                Text(citeKeyPreview)
                    .fontDesign(.monospaced)
                    .foregroundStyle(.secondary)
            }

            // Lowercase toggle
            Toggle("Generate Lowercase", isOn: $citeKeySettings.lowercase)
                .onChange(of: citeKeySettings.lowercase) { _, newValue in
                    Task {
                        await ImportExportSettingsStore.shared.updateCiteKeyLowercase(newValue)
                    }
                }
        } header: {
            Text("Cite Key Format")
        } footer: {
            if citeKeySettings.preset != .custom {
                Text("Format: \(citeKeySettings.preset.formatString)")
            }
        }
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
                Text("When auto-generate is enabled, cite keys are created using the format above for entries with missing or ADS-style cite keys.")
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

    // MARK: - Helpers

    private var citeKeyPreview: String {
        let generator = FormatBasedCiteKeyGenerator(settings: citeKeySettings)
        var preview = generator.preview()
        if citeKeySettings.lowercase {
            preview = preview.lowercased()
        }
        return preview
    }
}

// MARK: - iOS Cite Key Format Help View

struct IOSCiteKeyFormatHelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(citeKeyFormatSpecifiers) { spec in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(spec.specifier)
                                    .fontDesign(.monospaced)
                                    .foregroundStyle(.blue)
                                Spacer()
                                Text(spec.example)
                                    .fontDesign(.monospaced)
                                    .foregroundStyle(.secondary)
                            }
                            Text(spec.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text("Format Specifiers")
                } footer: {
                    Text("Example: %a%Y%t produces Smith2024Machine")
                }

                Section {
                    ForEach(CiteKeyFormatPreset.allCases.filter { $0 != .custom }, id: \.self) { preset in
                        HStack {
                            Text(preset.displayName)
                            Spacer()
                            VStack(alignment: .trailing) {
                                Text(preset.formatString)
                                    .fontDesign(.monospaced)
                                    .foregroundStyle(.blue)
                                Text(preset.preview)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Preset Formats")
                }
            }
            .navigationTitle("Cite Key Format Help")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        IOSImportExportSettingsView()
    }
}
