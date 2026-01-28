import SwiftUI

/// Editor for creating or modifying templates with live preview
struct TemplateEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var templateService = TemplateService.shared

    // Template properties
    @State private var templateId: String
    @State private var templateName: String
    @State private var templateDescription: String
    @State private var typstSource: String
    @State private var latexPreamble: String

    // Page layout
    @State private var pageSize: String = "a4"
    @State private var columns: Int = 1
    @State private var fontSize: Double = 11
    @State private var marginTop: Double = 25
    @State private var marginRight: Double = 25
    @State private var marginBottom: Double = 25
    @State private var marginLeft: Double = 25

    // UI state
    @State private var previewPDF: Data?
    @State private var isCompiling = false
    @State private var compileError: String?
    @State private var showingPreview = true

    private let isNewTemplate: Bool

    init(template: Template? = nil) {
        if let template = template {
            _templateId = State(initialValue: template.metadata.id)
            _templateName = State(initialValue: template.metadata.name)
            _templateDescription = State(initialValue: template.metadata.description)
            _typstSource = State(initialValue: template.typstSource)
            _latexPreamble = State(initialValue: template.latexPreamble ?? "")
            _pageSize = State(initialValue: template.metadata.pageDefaults.size)
            _columns = State(initialValue: template.metadata.pageDefaults.columns)
            _fontSize = State(initialValue: template.metadata.pageDefaults.fontSize)
            _marginTop = State(initialValue: template.metadata.pageDefaults.marginTop)
            _marginRight = State(initialValue: template.metadata.pageDefaults.marginRight)
            _marginBottom = State(initialValue: template.metadata.pageDefaults.marginBottom)
            _marginLeft = State(initialValue: template.metadata.pageDefaults.marginLeft)
            isNewTemplate = false
        } else {
            _templateId = State(initialValue: "custom-\(UUID().uuidString.prefix(8).lowercased())")
            _templateName = State(initialValue: "Custom Template")
            _templateDescription = State(initialValue: "")
            _typstSource = State(initialValue: Self.defaultTypstSource)
            _latexPreamble = State(initialValue: "")
            _pageSize = State(initialValue: "a4")
            _columns = State(initialValue: 1)
            _fontSize = State(initialValue: 11)
            _marginTop = State(initialValue: 25)
            _marginRight = State(initialValue: 25)
            _marginBottom = State(initialValue: 25)
            _marginLeft = State(initialValue: 25)
            isNewTemplate = true
        }
    }

    var body: some View {
        NavigationSplitView {
            settingsSidebar
        } detail: {
            editorContent
        }
        .frame(minWidth: 1000, minHeight: 700)
        .toolbar {
            ToolbarItemGroup(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Toggle(isOn: $showingPreview) {
                    Label("Preview", systemImage: "eye")
                }
                .toggleStyle(.button)

                Button("Compile") {
                    Task { await compilePreview() }
                }
                .keyboardShortcut("r", modifiers: .command)

                Button(isNewTemplate ? "Create" : "Save") {
                    saveTemplate()
                }
                .buttonStyle(.borderedProminent)
                .disabled(templateName.isEmpty)
            }
        }
    }

    // MARK: - Settings Sidebar

    private var settingsSidebar: some View {
        Form {
            Section("Template Info") {
                TextField("Name", text: $templateName)
                TextField("ID", text: $templateId)
                    .disabled(!isNewTemplate)
                    .foregroundColor(isNewTemplate ? .primary : .secondary)
                TextField("Description", text: $templateDescription, axis: .vertical)
                    .lineLimit(3...6)
            }

            Section("Page Layout") {
                Picker("Paper Size", selection: $pageSize) {
                    Text("A4").tag("a4")
                    Text("A5").tag("a5")
                    Text("US Letter").tag("letter")
                }

                Picker("Columns", selection: $columns) {
                    Text("Single").tag(1)
                    Text("Two").tag(2)
                }

                HStack {
                    Text("Font Size")
                    Spacer()
                    TextField("", value: $fontSize, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                    Text("pt")
                }
            }

            Section("Margins (mm)") {
                marginField("Top", value: $marginTop)
                marginField("Right", value: $marginRight)
                marginField("Bottom", value: $marginBottom)
                marginField("Left", value: $marginLeft)
            }

            Section("LaTeX Export") {
                TextEditor(text: $latexPreamble)
                    .font(.system(.caption, design: .monospaced))
                    .frame(height: 100)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 250, maxWidth: 300)
    }

    private func marginField(_ label: String, value: Binding<Double>) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("", value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 60)
        }
    }

    // MARK: - Editor Content

    private var editorContent: some View {
        HSplitView {
            // Source editor
            VStack(spacing: 0) {
                HStack {
                    Text("Template Source (Typst)")
                        .font(.headline)
                    Spacer()
                    Text("\(typstSource.count) characters")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color(nsColor: .controlBackgroundColor))

                TextEditor(text: $typstSource)
                    .font(.system(.body, design: .monospaced))
            }
            .frame(minWidth: 400)

            // Preview
            if showingPreview {
                VStack(spacing: 0) {
                    HStack {
                        Text("Preview")
                            .font(.headline)
                        Spacer()
                        if isCompiling {
                            ProgressView()
                                .scaleEffect(0.7)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(Color(nsColor: .controlBackgroundColor))

                    previewContent
                }
                .frame(minWidth: 300)
            }
        }
    }

    @ViewBuilder
    private var previewContent: some View {
        if let error = compileError {
            VStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle)
                    .foregroundColor(.orange)
                Text("Compilation Error")
                    .font(.headline)
                ScrollView {
                    Text(error)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .controlBackgroundColor))
        } else if previewPDF != nil {
            TemplatePreviewPlaceholder(message: "PDF preview generated successfully")
        } else {
            ContentUnavailableView(
                "No Preview",
                systemImage: "doc.text",
                description: Text("Press ⌘R to compile a preview")
            )
        }
    }

    // MARK: - Actions

    private func compilePreview() async {
        isCompiling = true
        compileError = nil

        // Create a sample document using the template
        let sampleDocument = """
        \(typstSource)

        #show: article.with(
          title: "Sample Document",
          authors: (
            (name: "Jane Smith", affiliation: 1),
            (name: "John Doe", affiliation: 2),
          ),
          abstract: [
            This is a sample abstract to preview the template formatting.
            It demonstrates how the document will look when rendered.
          ],
        )

        = Introduction

        This is sample content to preview the template. Lorem ipsum dolor sit amet,
        consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore et
        dolore magna aliqua.

        == Background

        Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut
        aliquip ex ea commodo consequat.

        = Methods

        Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore
        eu fugiat nulla pariatur.

        = Results

        The equation $E = m c^2$ is fundamental to physics.

        = Conclusion

        Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia
        deserunt mollit anim id est laborum.
        """

        #if canImport(ImprintRustCore)
        // Compile using Rust
        await Task.detached {
            // Use the Typst compiler
        }.value
        #endif

        // For now, just simulate compilation
        try? await Task.sleep(nanoseconds: 500_000_000)

        isCompiling = false
    }

    private func saveTemplate() {
        // TODO: Save template to user templates directory
        print("Saving template: \(templateId)")
        dismiss()
    }

    // MARK: - Default Source

    private static let defaultTypstSource = """
    // Custom Template
    // Edit this template to create your own document style

    #let article(
      title: none,
      authors: (),
      affiliations: (),
      abstract: none,
      keywords: (),
      body
    ) = {
      // Page setup
      set page(
        paper: "a4",
        margin: (top: 2.5cm, bottom: 2.5cm, left: 2.5cm, right: 2.5cm),
      )

      // Typography
      set text(font: "New Computer Modern", size: 11pt)
      set par(justify: true, leading: 0.65em)

      // Headings
      set heading(numbering: "1.1")
      show heading.where(level: 1): it => {
        v(1em)
        text(size: 14pt, weight: "bold", it)
        v(0.5em)
      }

      // Title block
      if title != none {
        align(center)[
          #text(size: 18pt, weight: "bold", title)
          #v(1em)
          #for (i, author) in authors.enumerate() {
            if type(author) == str { author } else {
              author.name
              if "affiliation" in author { super(str(author.affiliation)) }
            }
            if i < authors.len() - 1 { ", " }
          }
        ]
        v(2em)
      }

      // Abstract
      if abstract != none {
        block(width: 100%, inset: (left: 2em, right: 2em))[
          #text(weight: "bold")[Abstract.] #abstract
        ]
        v(1em)
      }

      // Body
      body
    }
    """
}

/// Simple placeholder for PDF preview in template editor
struct TemplatePreviewPlaceholder: View {
    let message: String

    var body: some View {
        VStack {
            Image(systemName: "doc.text")
                .font(.largeTitle)
                .foregroundColor(.secondary)
            Text(message)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

#Preview {
    TemplateEditorView()
}
