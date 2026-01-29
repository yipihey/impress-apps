import SwiftUI

/// Detailed view of a template with preview and actions
struct TemplateDetailView: View {
    let templateId: String

    var templateService = TemplateService.shared
    @State private var showingEditor = false
    @State private var showingPreview = false

    private var template: Template? {
        templateService.getTemplate(id: templateId)
    }

    private var metadata: TemplateMetadata? {
        templateService.templates.first { $0.id == templateId }
    }

    var body: some View {
        if let metadata = metadata {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    headerSection(metadata)
                    Divider()
                    infoSection(metadata)

                    if let journal = metadata.journal {
                        Divider()
                        journalSection(journal)
                    }

                    Divider()
                    pageLayoutSection(metadata.pageDefaults)

                    if !metadata.tags.isEmpty {
                        Divider()
                        tagsSection(metadata.tags)
                    }

                    Divider()
                    actionsSection(metadata)
                }
                .padding(24)
            }
            .frame(minWidth: 300)
            .sheet(isPresented: $showingEditor) {
                if let template = template {
                    TemplateEditorView(template: template)
                }
            }
        } else {
            ContentUnavailableView(
                "Template Not Found",
                systemImage: "doc.questionmark",
                description: Text("The selected template could not be loaded")
            )
        }
    }

    // MARK: - Sections

    private func headerSection(_ metadata: TemplateMetadata) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(categoryColor(metadata.category).opacity(0.15))
                        .frame(width: 56, height: 56)

                    Image(systemName: metadata.category.systemImage)
                        .font(.title)
                        .foregroundStyle(categoryColor(metadata.category))
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(metadata.name)
                        .font(.title2)
                        .fontWeight(.semibold)

                    HStack(spacing: 8) {
                        Text("v\(metadata.version)")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if metadata.isBuiltin {
                            Label("Built-in", systemImage: "checkmark.seal.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                    }
                }

                Spacer()
            }

            Text(metadata.description)
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }

    private func infoSection(_ metadata: TemplateMetadata) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Information")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    Text("Category")
                        .foregroundStyle(.secondary)
                    Text(metadata.category.displayName)
                }
                GridRow {
                    Text("Author")
                        .foregroundStyle(.secondary)
                    Text(metadata.author)
                }
                GridRow {
                    Text("License")
                        .foregroundStyle(.secondary)
                    Text(metadata.license)
                }
            }
            .font(.callout)
        }
    }

    private func journalSection(_ journal: JournalInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Journal Information")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    Text("Publisher")
                        .foregroundStyle(.secondary)
                    Text(journal.publisher)
                }
                if let issn = journal.issn {
                    GridRow {
                        Text("ISSN")
                            .foregroundStyle(.secondary)
                        Text(issn)
                    }
                }
                if let latexClass = journal.latexClass {
                    GridRow {
                        Text("LaTeX Class")
                            .foregroundStyle(.secondary)
                        Text(latexClass)
                            .font(.system(.callout, design: .monospaced))
                    }
                }
                if let url = journal.url {
                    GridRow {
                        Text("Website")
                            .foregroundStyle(.secondary)
                        Link(url, destination: URL(string: url)!)
                    }
                }
            }
            .font(.callout)
        }
    }

    private func pageLayoutSection(_ defaults: PageDefaults) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Page Layout")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    Text("Paper Size")
                        .foregroundStyle(.secondary)
                    Text(defaults.size.uppercased())
                }
                GridRow {
                    Text("Margins")
                        .foregroundStyle(.secondary)
                    Text("\(Int(defaults.marginTop))mm / \(Int(defaults.marginRight))mm / \(Int(defaults.marginBottom))mm / \(Int(defaults.marginLeft))mm")
                }
                GridRow {
                    Text("Columns")
                        .foregroundStyle(.secondary)
                    Text("\(defaults.columns)")
                }
                GridRow {
                    Text("Font Size")
                        .foregroundStyle(.secondary)
                    Text("\(Int(defaults.fontSize))pt")
                }
            }
            .font(.callout)
        }
    }

    private func tagsSection(_ tags: [String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tags")
                .font(.headline)

            FlowLayout(spacing: 8) {
                ForEach(tags, id: \.self) { tag in
                    Text(tag)
                        .font(.callout)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.1))
                        .foregroundStyle(Color.accentColor)
                        .clipShape(.rect(cornerRadius: 6))
                }
            }
        }
    }

    private func actionsSection(_ metadata: TemplateMetadata) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Actions")
                .font(.headline)

            HStack(spacing: 12) {
                Button {
                    applyTemplate()
                } label: {
                    Label("Use Template", systemImage: "doc.badge.plus")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    showingEditor = true
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .buttonStyle(.bordered)

                Button {
                    exportTemplate()
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)

                Spacer()

                if !metadata.isBuiltin {
                    Button(role: .destructive) {
                        deleteTemplate()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    // MARK: - Actions

    private func applyTemplate() {
        // TODO: Apply template to current document or create new
        print("Apply template: \(templateId)")
    }

    private func exportTemplate() {
        // TODO: Export template as .imprintTemplate
        print("Export template: \(templateId)")
    }

    private func deleteTemplate() {
        // TODO: Delete user template
        print("Delete template: \(templateId)")
    }

    private func categoryColor(_ category: TemplateCategory) -> Color {
        switch category {
        case .journal: return .blue
        case .conference: return .purple
        case .thesis: return .green
        case .report: return .orange
        case .custom: return .gray
        case .all: return .primary
        }
    }
}

/// A simple flow layout for tags
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)

        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private func arrangeSubviews(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0

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
        }

        let totalHeight = currentY + lineHeight
        return (CGSize(width: maxWidth, height: totalHeight), positions)
    }
}

#Preview {
    TemplateDetailView(templateId: "mnras")
        .frame(width: 400, height: 600)
}
