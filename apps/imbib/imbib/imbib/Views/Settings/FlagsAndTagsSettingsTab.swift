//
//  FlagsAndTagsSettingsTab.swift
//  imbib
//

import SwiftUI
import PublicationManagerCore
import ImpressFTUI

/// Settings tab for configuring flag appearance and tag display options.
struct FlagsAndTagsSettingsTab: View {

    // MARK: - State

    @State private var settings = ListViewSettings()
    @State private var isLoading = true
    @State private var tagTree: String = ""

    // Tag alias state
    @State private var newAliasName = ""
    @State private var newAliasPath = ""
    @State private var selectedAlias: String?
    @State private var showAddAlias = false

    // Tag path autocomplete state
    @State private var tagAutocomplete: TagAutocompleteService?
    @State private var pathCompletions: [TagCompletion] = []
    @State private var selectedCompletionIndex: Int = 0

    // MARK: - Body

    var body: some View {
        Form {
            Section("Flags") {
                Toggle("Show flag stripe on list rows", isOn: $settings.showFlagStripe)
                    .help("Show a colored vertical stripe at the leading edge of flagged publications")

                Text("Flag papers using the context menu or by pressing **f** in the list view.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                HStack(spacing: 16) {
                    flagSwatch("Red", color: .red)
                    flagSwatch("Amber", color: .orange)
                    flagSwatch("Blue", color: .blue)
                    flagSwatch("Gray", color: .gray)
                }
                .padding(.vertical, 4)
            }

            Section("Tags") {
                tagDisplayStylePicker

                Picker("Tag path style", selection: $settings.tagPathStyle) {
                    ForEach(TagPathStyle.allCases, id: \.self) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .help("How tag paths are shown in text labels and chips")

                Text("Tag papers using the context menu or by pressing **t** in the list view. Press **T** to remove tags.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Tag Aliases") {
                Text("Create shortcuts that expand to full tag paths when tagging papers.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                aliasListView
            }

            Section("Keyword Import") {
                Toggle("Auto-import keywords as tags", isOn: $settings.importKeywordsAsTags)
                    .help("When importing papers from BibTeX or search results, automatically create tags from keywords/categories")

                if settings.importKeywordsAsTags {
                    HStack {
                        Text("Tag prefix")
                        TextField("e.g. keywords", text: $settings.keywordTagPrefix)
                            .textFieldStyle(.roundedBorder)
                    }
                    .help("Optional prefix prepended to imported tags (e.g., \"keywords\" → \"keywords/dark matter\")")

                    Text("Leave prefix empty to import keywords as top-level tags.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Tag Hierarchy") {
                if tagTree.isEmpty {
                    Text("No tags defined yet.")
                        .foregroundStyle(.secondary)
                        .italic()
                } else {
                    Text(tagTree)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
            }

            Section("Filter Syntax") {
                Text("Press **/** in the list view to open the filter bar. Supported syntax:")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 4) {
                    filterSyntaxRow("flag:red", "Papers with red flag")
                    filterSyntaxRow("flag:*", "Any flagged paper")
                    filterSyntaxRow("-flag:*", "Unflagged papers")
                    filterSyntaxRow("tags:methods", "Papers tagged methods (or children)")
                    filterSyntaxRow("tags:a+b", "Papers with both tags")
                    filterSyntaxRow("unread", "Unread papers")
                    filterSyntaxRow("\"dark matter\"", "Exact phrase search")
                }
                .padding(.vertical, 2)
            }

            Section {
                Button("Reset Display Settings") {
                    Task {
                        await ListViewSettingsStore.shared.reset()
                        settings = await ListViewSettingsStore.shared.settings
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .padding(.horizontal)
        .task {
            settings = await ListViewSettingsStore.shared.settings
            tagTree = await TagManagementService.shared.tagTree()
            isLoading = false
        }
        .onChange(of: settings) { _, newSettings in
            guard !isLoading else { return }
            Task {
                await ListViewSettingsStore.shared.update(newSettings)
            }
        }
    }

    // MARK: - Components

    private func flagSwatch(_ name: String, color: Color) -> some View {
        VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 3)
                .fill(color)
                .frame(width: 4, height: 28)
            Text(name)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var tagDisplayStylePicker: some View {
        Picker("Tag display", selection: tagDisplayStyleBinding) {
            Text("Hidden").tag(TagStyleOption.hidden)
            Text("Dots").tag(TagStyleOption.dots)
            Text("Text labels").tag(TagStyleOption.text)
            Text("Hybrid").tag(TagStyleOption.hybrid)
        }
        .help("How tags are shown on publication list rows")
    }

    private func filterSyntaxRow(_ syntax: String, _ description: String) -> some View {
        HStack(spacing: 8) {
            Text(syntax)
                .font(.system(.caption, design: .monospaced))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 3))
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Alias List

    private var aliasListView: some View {
        let aliases = TagAliasStore.shared.sortedAliases

        return VStack(spacing: 0) {
            // Column headers
            HStack(spacing: 0) {
                Text("Alias")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 90, alignment: .leading)
                Text("Tag Path")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)

            Divider()

            // Alias rows
            if aliases.isEmpty {
                Text("No aliases defined.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 48)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(aliases, id: \.alias) { entry in
                            HStack(spacing: 0) {
                                Text(entry.alias)
                                    .font(.system(.body, design: .monospaced))
                                    .frame(width: 90, alignment: .leading)
                                Text(entry.path)
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(
                                selectedAlias == entry.alias
                                    ? Color.accentColor.opacity(0.15)
                                    : Color.clear
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedAlias = entry.alias
                            }
                        }
                    }
                }
                .frame(minHeight: 30, maxHeight: 150)
            }

            Divider()

            // +/- toolbar
            HStack(spacing: 0) {
                Button {
                    showAddAlias = true
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 24, height: 18)
                }
                .popover(isPresented: $showAddAlias) {
                    addAliasPopover
                }

                Divider()
                    .frame(height: 14)

                Button {
                    if let alias = selectedAlias {
                        TagAliasStore.shared.remove(alias: alias)
                        selectedAlias = nil
                    }
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 24, height: 18)
                }
                .disabled(selectedAlias == nil)

                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(Color(nsColor: .separatorColor))
        )
    }

    @ViewBuilder
    private var addAliasPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Tag Alias")
                .font(.headline)

            LabeledContent("Alias") {
                TextField("shortcut", text: $newAliasName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
            }

            LabeledContent("Path") {
                VStack(alignment: .leading, spacing: 0) {
                    TextField("methods/hydro/amr", text: $newAliasPath)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                        .onChange(of: newAliasPath) { _, newValue in
                            if let service = tagAutocomplete {
                                pathCompletions = service.complete(newValue, limit: 6)
                                selectedCompletionIndex = 0
                            }
                        }
                        .onKeyPress(.upArrow) {
                            guard !pathCompletions.isEmpty else { return .ignored }
                            selectedCompletionIndex = max(0, selectedCompletionIndex - 1)
                            return .handled
                        }
                        .onKeyPress(.downArrow) {
                            guard !pathCompletions.isEmpty else { return .ignored }
                            selectedCompletionIndex = min(pathCompletions.count - 1, selectedCompletionIndex + 1)
                            return .handled
                        }
                        .onKeyPress(.tab) {
                            guard !pathCompletions.isEmpty else { return .ignored }
                            let completion = pathCompletions[selectedCompletionIndex]
                            newAliasPath = completion.path
                            pathCompletions = []
                            return .handled
                        }

                    if !pathCompletions.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(pathCompletions.enumerated()), id: \.element.id) { index, completion in
                                HStack(spacing: 6) {
                                    completionDot(for: completion)
                                    Text(completion.path)
                                        .font(.system(.caption, design: .monospaced))
                                        .lineLimit(1)
                                    Spacer()
                                    if completion.useCount > 0 {
                                        Text("\(completion.useCount)")
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(
                                    index == selectedCompletionIndex
                                        ? Color.accentColor.opacity(0.15)
                                        : Color.clear
                                )
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    newAliasPath = completion.path
                                    pathCompletions = []
                                }
                            }
                        }
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(Color(nsColor: .separatorColor))
                        )
                        .frame(width: 220)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    newAliasName = ""
                    newAliasPath = ""
                    pathCompletions = []
                    showAddAlias = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Add") {
                    TagAliasStore.shared.add(alias: newAliasName, path: newAliasPath)
                    newAliasName = ""
                    newAliasPath = ""
                    pathCompletions = []
                    showAddAlias = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    newAliasName.trimmingCharacters(in: .whitespaces).isEmpty ||
                    newAliasPath.trimmingCharacters(in: .whitespaces).isEmpty
                )
            }
        }
        .padding()
        .frame(width: 360)
        .onAppear {
            if tagAutocomplete == nil {
                tagAutocomplete = TagAutocompleteService(persistenceController: PersistenceController.shared)
            }
        }
    }

    @ViewBuilder
    private func completionDot(for completion: TagCompletion) -> some View {
        let data = TagDisplayData(
            id: completion.id,
            path: completion.path,
            leaf: completion.leaf,
            colorLight: completion.colorLight,
            colorDark: completion.colorDark
        )
        TagDot(tag: data)
    }

    // Simplified binding for the picker since TagDisplayStyle has associated values
    private var tagDisplayStyleBinding: Binding<TagStyleOption> {
        Binding(
            get: {
                switch settings.tagDisplayStyle {
                case .hidden: return .hidden
                case .dots: return .dots
                case .text: return .text
                case .hybrid: return .hybrid
                }
            },
            set: { newOption in
                switch newOption {
                case .hidden: settings.tagDisplayStyle = .hidden
                case .dots: settings.tagDisplayStyle = .dots(maxVisible: 5)
                case .text: settings.tagDisplayStyle = .text
                case .hybrid: settings.tagDisplayStyle = .hybrid(maxVisible: 5)
                }
            }
        )
    }
}

// Simple enum for picker (TagDisplayStyle has associated values)
private enum TagStyleOption: String, CaseIterable {
    case hidden, dots, text, hybrid
}
