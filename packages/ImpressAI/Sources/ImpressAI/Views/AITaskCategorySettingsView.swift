//
//  AITaskCategorySettingsView.swift
//  ImpressAI
//
//  SwiftUI view for configuring task categories with multi-model assignments.
//

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
                            availableModels: settings.availableModels,
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
    let availableModels: [AIModelReference]
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
                    ForEach(availableModelsForComparison) { model in
                        Button(model.displayName) {
                            onAddComparison(model)
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

    private var availableModelsForComparison: [AIModelReference] {
        let excluded = Set(assignment.comparisonModels.map { $0.id })
        let primaryId = assignment.primaryModel?.id
        return availableModels.filter {
            !excluded.contains($0.id) && $0.id != primaryId
        }
    }

    @ViewBuilder
    private func modelPicker(
        selection: AIModelReference?,
        excluding: [AIModelReference],
        onChange: @escaping (AIModelReference?) -> Void
    ) -> some View {
        let excludedIds = Set(excluding.map { $0.id })
        let options = availableModels.filter { !excludedIds.contains($0.id) }

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
            Divider()
            ForEach(options) { model in
                Text(model.displayName).tag(Optional(model.id))
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
            Text(model.displayName)
                .font(.caption)
                .lineLimit(1)

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary)
        )
    }
}

// MARK: - Flow Layout

/// Simple flow layout for wrapping chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = flowLayout(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = flowLayout(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private func flowLayout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)

            if currentX + size.width > maxWidth && currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }

            positions.append(CGPoint(x: currentX, y: currentY))
            lineHeight = max(lineHeight, size.height)
            currentX += size.width + spacing
            totalWidth = max(totalWidth, currentX - spacing)
            totalHeight = currentY + lineHeight
        }

        return (CGSize(width: totalWidth, height: totalHeight), positions)
    }
}

// MARK: - Preview

#Preview("AITaskCategorySettingsView") {
    AITaskCategorySettingsView()
        .frame(width: 500, height: 600)
}
