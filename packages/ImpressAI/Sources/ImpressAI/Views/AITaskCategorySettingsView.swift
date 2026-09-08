//
//  AITaskCategorySettingsView.swift
//  ImpressAI
//
//  SwiftUI view for configuring task categories with multi-model assignments.
//

import ImpressFTUI
import SwiftUI

// MARK: - Main Settings View

/// Settings view for configuring AI task categories.
public struct AITaskCategorySettingsView: View {
    @State private var settings = AITaskCategorySettings.shared
    @State private var expandedRoots: Set<String> = []

    public init() {}

    public var body: some View {
        Form {
            if settings.isLoading {
                loadingSection
            } else {
                categorySection
            }
        }
        .formStyle(.grouped)
        .task {
            await settings.load()
            // Expand all roots by default
            expandedRoots = Set(settings.rootCategories.map { $0.id })
        }
    }

    // MARK: - Sections

    private var loadingSection: some View {
        Section {
            HStack {
                ProgressView()
                    .controlSize(.small)
                Text("Loading categories...")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var categorySection: some View {
        ForEach(settings.categoriesByRoot, id: \.root.id) { group in
            Section {
                DisclosureGroup(
                    isExpanded: Binding(
                        get: { expandedRoots.contains(group.root.id) },
                        set: { expanded in
                            if expanded {
                                expandedRoots.insert(group.root.id)
                            } else {
                                expandedRoots.remove(group.root.id)
                            }
                        }
                    )
                ) {
                    ForEach(group.children) { category in
                        CategoryAssignmentRow(
                            category: category,
                            assignment: settings.assignment(for: category.id),
                            modelGroups: settings.modelGroups,
                            onPrimaryModelChange: { model in
                                Task { await settings.setPrimaryModel(model, for: category.id) }
                            },
                            onAddComparison: { model in
                                Task { await settings.addComparisonModel(model, to: category.id) }
                            },
                            onRemoveComparison: { model in
                                Task { await settings.removeComparisonModel(model, from: category.id) }
                            },
                            onEnabledChange: { enabled in
                                Task { await settings.setEnabled(enabled, for: category.id) }
                            }
                        )
                    }
                } label: {
                    Label(group.root.name, systemImage: group.root.icon)
                        .font(.headline)
                }
            }
        }
    }
}

// MARK: - Category Row

/// Row view for a single category assignment.
struct CategoryAssignmentRow: View {
    let category: AITaskCategory
    let assignment: AITaskCategoryAssignment
    /// Selectable models grouped by provider (`AIModelOptions`): the host's
    /// own list where one could be discovered, and the reason a provider is
    /// not usable where it cannot serve a request.
    let modelGroups: [AIModelOptionGroup]
    let onPrimaryModelChange: (AIModelReference?) -> Void
    let onAddComparison: (AIModelReference) -> Void
    let onRemoveComparison: (AIModelReference) -> Void
    let onEnabledChange: (Bool) -> Void

    @State private var isExpanded = false
    @State private var showingModelPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header row
            HStack {
                Toggle(isOn: Binding(
                    get: { assignment.isEnabled },
                    set: onEnabledChange
                )) {
                    Label {
                        Text(category.name)
                    } icon: {
                        Image(systemName: category.icon)
                            .foregroundStyle(.secondary)
                    }
                }
                #if os(macOS)
                .toggleStyle(.checkbox)
                #endif

                Spacer()

                if assignment.isEnabled {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isExpanded.toggle()
                        }
                    } label: {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            // Expanded content
            if assignment.isEnabled && isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    // Primary model picker
                    HStack {
                        Text("Primary:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 60, alignment: .leading)

                        modelPicker(
                            selection: assignment.primaryModel,
                            excluding: assignment.comparisonModels
                        ) { model in
                            onPrimaryModelChange(model)
                        }
                        // Bounded so a long selected title truncates inside
                        // the row instead of widening it past the sheet.
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }

                    // Comparison models (if supported)
                    if category.supportsComparison {
                        comparisonSection
                    }
                }
                .padding(.leading, 24)
                .padding(.top, 4)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Comparison Section

    @ViewBuilder
    private var comparisonSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Existing comparison models
            if !assignment.comparisonModels.isEmpty {
                HStack(alignment: .top) {
                    Text("Compare:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .leading)

                    FlowLayout(spacing: 4) {
                        ForEach(assignment.comparisonModels) { model in
                            ComparisonModelChip(model: model) {
                                onRemoveComparison(model)
                            }
                        }
                    }
                }
            }

            // Add comparison button
            HStack {
                if assignment.comparisonModels.isEmpty {
                    Text("Compare:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .leading)
                } else {
                    Spacer()
                        .frame(width: 60)
                }

                Menu {
                    ForEach(comparisonGroups) { group in
                        Section(group.sectionTitle) {
                            ForEach(group.models) { model in
                                Button(model.modelName) {
                                    onAddComparison(model)
                                }
                            }
                        }
                    }
                } label: {
                    Label("Add comparison model", systemImage: "plus.circle")
                        .font(.caption)
                }
                .disabled(availableModelsForComparison.isEmpty)
            }
        }
    }

    // MARK: - Helpers

    private var availableModels: [AIModelReference] {
        modelGroups.flatMap(\.models)
    }

    /// The groups with `excluded` removed, dropping any group left empty so a
    /// provider never shows an empty heading.
    private func groups(excluding excluded: Set<String>) -> [AIModelOptionGroup] {
        // The assigned model stays listed even when its host is off, so the
        // picker never renders a selection it has no row for.
        AIModelOptions.groups(modelGroups, including: assignment.primaryModel).compactMap { group in
            let models = group.models.filter { !excluded.contains($0.id) }
            guard !models.isEmpty else { return nil }
            return AIModelOptionGroup(
                providerId: group.providerId,
                providerName: group.providerName,
                readiness: group.readiness,
                models: models,
                isDiscovered: group.isDiscovered
            )
        }
    }

    private var comparisonGroups: [AIModelOptionGroup] {
        var excluded = Set(assignment.comparisonModels.map(\.id))
        if let primaryId = assignment.primaryModel?.id { excluded.insert(primaryId) }
        return groups(excluding: excluded)
    }

    private var availableModelsForComparison: [AIModelReference] {
        comparisonGroups.flatMap(\.models)
    }

    @ViewBuilder
    private func modelPicker(
        selection: AIModelReference?,
        excluding: [AIModelReference],
        onChange: @escaping (AIModelReference?) -> Void
    ) -> some View {
        let options = groups(excluding: Set(excluding.map(\.id)))

        Picker("", selection: Binding(
            get: { selection?.id },
            set: { newId in
                if let newId = newId,
                   let model = availableModels.first(where: { $0.id == newId }) {
                    onChange(model)
                } else {
                    onChange(nil)
                }
            }
        )) {
            Text("Not configured").tag(String?.none)
            // One section per provider, usable providers first; a provider
            // that needs setup says so in its heading rather than quietly
            // offering models that cannot run.
            ForEach(options) { group in
                Section(group.sectionTitle) {
                    ForEach(group.models) { model in
                        Text(model.modelName).tag(Optional(model.id))
                    }
                }
            }
        }
        .pickerStyle(.menu)
    }
}

// MARK: - Comparison Model Chip

/// Chip view for a comparison model with remove button.
struct ComparisonModelChip: View {
    let model: AIModelReference
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            // The chip lives in a picker context that already groups by
            // provider, so it shows the model half of the name — the full
            // "oMLX — local models on this Mac - …" form made one chip wider
            // than the sheet. Middle truncation keeps both the family and the
            // quant suffix readable when even the short form is long; the
            // full name stays one hover away.
            Text(model.modelName)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .help(model.displayName)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary)
        )
    }
}

// The chips flow through ImpressFTUI's shared FlowLayout — a local copy
// lived here until 2026-09-06, carrying the same single-wide-chip overflow
// bug as the shared one. One implementation, one fix.

// MARK: - Preview

#Preview("AITaskCategorySettingsView") {
    AITaskCategorySettingsView()
        .frame(width: 500, height: 600)
}
