//
//  EverythingExportOptionsView.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-29.
//

import SwiftUI

// MARK: - Everything Export Options View

/// SwiftUI view for configuring Everything export options.
public struct EverythingExportOptionsView: View {
    @Binding public var options: EverythingExportOptions

    @State private var includeFiles: Bool
    @State private var includeBibTeX: Bool
    @State private var includeExploration: Bool
    @State private var includeTriageHistory: Bool
    @State private var includeMutedItems: Bool
    @State private var useFileSizeLimit: Bool
    @State private var maxFileSizeMB: Double

    public init(options: Binding<EverythingExportOptions>) {
        self._options = options
        let opts = options.wrappedValue
        self._includeFiles = State(initialValue: opts.includeFiles)
        self._includeBibTeX = State(initialValue: opts.includeBibTeX)
        self._includeExploration = State(initialValue: opts.includeExploration)
        self._includeTriageHistory = State(initialValue: opts.includeTriageHistory)
        self._includeMutedItems = State(initialValue: opts.includeMutedItems)
        self._useFileSizeLimit = State(initialValue: opts.maxFileSize != nil)
        self._maxFileSizeMB = State(initialValue: Double(opts.maxFileSize ?? 50_000_000) / 1_000_000)
    }

    public var body: some View {
        Form {
            Section {
                Toggle("Include PDF files", isOn: $includeFiles)
                    .help("Include PDF and other file attachments in the export")

                if includeFiles {
                    Toggle("Limit file size", isOn: $useFileSizeLimit)

                    if useFileSizeLimit {
                        HStack {
                            Text("Maximum file size:")
                            Slider(value: $maxFileSizeMB, in: 1...100, step: 1)
                            Text("\(Int(maxFileSizeMB)) MB")
                                .frame(width: 50, alignment: .trailing)
                        }
                    }
                }

                Toggle("Include BibTeX", isOn: $includeBibTeX)
                    .help("Include BibTeX data for each publication")
            } header: {
                Text("File Attachments")
            }

            Section {
                Toggle("Include read/starred status", isOn: $includeTriageHistory)
                    .help("Preserve read and starred status for papers")

                Toggle("Include muted items", isOn: $includeMutedItems)
                    .help("Export muted authors, venues, and categories")
            } header: {
                Text("Triage History")
            }

            Section {
                Toggle("Include Exploration library", isOn: $includeExploration)
                    .help("Exploration is device-specific and usually not included in backups")
            } header: {
                Text("System Libraries")
            } footer: {
                Text("The Exploration library contains papers discovered through citation/reference exploration. It's typically device-specific and not synced between devices.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: includeFiles) { updateOptions() }
        .onChange(of: includeBibTeX) { updateOptions() }
        .onChange(of: includeExploration) { updateOptions() }
        .onChange(of: includeTriageHistory) { updateOptions() }
        .onChange(of: includeMutedItems) { updateOptions() }
        .onChange(of: useFileSizeLimit) { updateOptions() }
        .onChange(of: maxFileSizeMB) { updateOptions() }
    }

    private func updateOptions() {
        let maxFileSize: Int?
        if useFileSizeLimit && includeFiles {
            maxFileSize = Int(maxFileSizeMB * 1_000_000)
        } else {
            maxFileSize = nil
        }

        options = EverythingExportOptions(
            includeFiles: includeFiles,
            includeBibTeX: includeBibTeX,
            maxFileSize: maxFileSize,
            includeExploration: includeExploration,
            includeTriageHistory: includeTriageHistory,
            includeMutedItems: includeMutedItems
        )
    }
}

// MARK: - Export Format Picker

/// Picker for choosing between Library and Everything export formats.
public struct ExportFormatPicker: View {
    public enum ExportFormat: String, CaseIterable, Identifiable {
        case library = "Library"
        case everything = "Everything"

        public var id: String { rawValue }

        public var description: String {
            switch self {
            case .library:
                return "Export a single library with its collections and publications"
            case .everything:
                return "Complete backup including all libraries, feeds, and triage history"
            }
        }

        public var icon: String {
            switch self {
            case .library:
                return "books.vertical"
            case .everything:
                return "archivebox"
            }
        }
    }

    @Binding public var selectedFormat: ExportFormat

    public init(selectedFormat: Binding<ExportFormat>) {
        self._selectedFormat = selectedFormat
    }

    public var body: some View {
        Picker("Export Format", selection: $selectedFormat) {
            ForEach(ExportFormat.allCases) { format in
                HStack {
                    Image(systemName: format.icon)
                    Text(format.rawValue)
                }
                .tag(format)
            }
        }
        .pickerStyle(.segmented)

        Text(selectedFormat.description)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

#if DEBUG
struct EverythingExportOptionsView_Previews: PreviewProvider {
    static var previews: some View {
        EverythingExportOptionsView(options: .constant(.default))
            .frame(width: 400, height: 400)
    }
}
#endif
