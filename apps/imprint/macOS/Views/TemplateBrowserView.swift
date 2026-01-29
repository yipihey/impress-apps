import SwiftUI

/// Browse and manage document templates
struct TemplateBrowserView: View {
    private var templateService = TemplateService.shared
    @State private var selectedCategory: TemplateCategory = .all
    @State private var searchQuery = ""
    @State private var selectedTemplateId: String?
    @State private var showingTemplateEditor = false

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationSplitView {
            sidebar
        } content: {
            templateGrid
        } detail: {
            if let templateId = selectedTemplateId {
                TemplateDetailView(templateId: templateId)
            } else {
                ContentUnavailableView(
                    "Select a Template",
                    systemImage: "doc.text",
                    description: Text("Choose a template from the list to see details")
                )
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .searchable(text: $searchQuery, prompt: "Search templates")
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selectedCategory) {
            Section("Categories") {
                ForEach(TemplateCategory.allCases) { category in
                    Label(category.displayName, systemImage: category.systemImage)
                        .tag(category)
                }
            }

            Section("Actions") {
                Button {
                    showingTemplateEditor = true
                } label: {
                    Label("Create Custom Template", systemImage: "plus")
                }
                .buttonStyle(.plain)

                Button {
                    // TODO: Import template
                } label: {
                    Label("Import Template...", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 200)
        .sheet(isPresented: $showingTemplateEditor) {
            TemplateEditorView()
        }
    }

    // MARK: - Template Grid

    private var templateGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 250), spacing: 16)], spacing: 16) {
                ForEach(filteredTemplates) { template in
                    TemplateCard(template: template, isSelected: selectedTemplateId == template.id)
                        .onTapGesture {
                            selectedTemplateId = template.id
                        }
                }
            }
            .padding()
        }
        .frame(minWidth: 400)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay {
            if filteredTemplates.isEmpty {
                ContentUnavailableView.search(text: searchQuery)
            }
        }
    }

    // MARK: - Filtering

    private var filteredTemplates: [TemplateMetadata] {
        var templates = selectedCategory == .all
            ? templateService.templates
            : templateService.templates(for: selectedCategory)

        if !searchQuery.isEmpty {
            templates = templates.filter { template in
                template.name.localizedCaseInsensitiveContains(searchQuery) ||
                template.description.localizedCaseInsensitiveContains(searchQuery) ||
                template.tags.contains { $0.localizedCaseInsensitiveContains(searchQuery) }
            }
        }

        return templates.sorted { $0.name < $1.name }
    }
}

/// Card view for a single template
struct TemplateCard: View {
    let template: TemplateMetadata
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Template icon and category badge
            HStack {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(categoryColor.opacity(0.15))
                        .frame(width: 44, height: 44)

                    Image(systemName: template.category.systemImage)
                        .font(.title2)
                        .foregroundStyle(categoryColor)
                }

                Spacer()

                if template.isBuiltin {
                    Text("Built-in")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.2))
                        .clipShape(.rect(cornerRadius: 4))
                }
            }

            // Template name
            Text(template.name)
                .font(.headline)
                .lineLimit(2)

            // Publisher or category
            Text(template.displayCategory)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            // Tags
            if !template.tags.isEmpty {
                HStack(spacing: 4) {
                    ForEach(template.tags.prefix(3), id: \.self) { tag in
                        Text(tag)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.1))
                            .foregroundStyle(Color.accentColor)
                            .clipShape(.rect(cornerRadius: 4))
                    }
                }
            }
        }
        .padding()
        .background(isSelected ? Color.accentColor.opacity(0.1) : Color(nsColor: .controlBackgroundColor))
        .clipShape(.rect(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: isSelected ? 2 : 1)
        )
        .shadow(color: .black.opacity(0.05), radius: 2, x: 0, y: 1)
    }

    private var categoryColor: Color {
        switch template.category {
        case .journal: return .blue
        case .conference: return .purple
        case .thesis: return .green
        case .report: return .orange
        case .custom: return .gray
        case .all: return .primary
        }
    }
}

#Preview {
    TemplateBrowserView()
}
