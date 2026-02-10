//
//  CaptureView.swift
//  imbib
//
//  SwiftUI content for the quick capture panel.
//

import SwiftUI
import PublicationManagerCore
import UniformTypeIdentifiers

struct CaptureView: View {

    let dismiss: () -> Void

    @State private var selectedType: ArtifactType = .general
    @State private var title = ""
    @State private var sourceURL = ""
    @State private var notes = ""
    @State private var droppedFileURL: URL?
    @State private var isSaving = false
    @State private var tags: [String] = []
    @State private var tagInput = ""

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "archivebox.fill")
                    .foregroundStyle(.tint)
                Text("Quick Capture")
                    .font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Type picker
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Type")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 8) {
                            ForEach(ArtifactType.allCases, id: \.self) { type in
                                Button {
                                    selectedType = type
                                } label: {
                                    VStack(spacing: 4) {
                                        Image(systemName: type.iconName)
                                            .font(.title3)
                                        Text(type.displayName)
                                            .font(.caption2)
                                            .lineLimit(1)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                    .background(
                                        selectedType == type
                                        ? AnyShapeStyle(.tint.opacity(0.15))
                                        : AnyShapeStyle(.clear)
                                    )
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(
                                                selectedType == type ? Color.accentColor : .clear,
                                                lineWidth: 1.5
                                            )
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    // Title
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Title")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        TextField("Artifact title", text: $title)
                            .textFieldStyle(.roundedBorder)
                    }

                    // Source URL
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Source URL")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        TextField("https://...", text: $sourceURL)
                            .textFieldStyle(.roundedBorder)
                    }

                    // File drop zone
                    VStack(alignment: .leading, spacing: 4) {
                        Text("File")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        FileDropZone(fileURL: $droppedFileURL) { url in
                            applyFileMetadata(from: url)
                        }
                    }

                    // Notes
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Notes")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $notes)
                            .frame(height: 60)
                            .font(.body)
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .stroke(Color.secondary.opacity(0.2))
                            )
                    }

                    // Tags
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Tags")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        HStack {
                            TextField("Add tag...", text: $tagInput)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit {
                                    let tag = tagInput.trimmingCharacters(in: .whitespaces)
                                    if !tag.isEmpty && !tags.contains(tag) {
                                        tags.append(tag)
                                        tagInput = ""
                                    }
                                }
                        }
                        if !tags.isEmpty {
                            FlowLayout(spacing: 4) {
                                ForEach(tags, id: \.self) { tag in
                                    HStack(spacing: 2) {
                                        Text(tag)
                                            .font(.caption)
                                        Button {
                                            tags.removeAll { $0 == tag }
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .font(.caption2)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.quaternary)
                                    .clipShape(Capsule())
                                }
                            }
                        }
                    }
                }
                .padding()
            }

            Divider()

            // Footer buttons
            HStack {
                Spacer()
                Button("Save") {
                    save()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(title.isEmpty || isSaving)
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(minWidth: 480, idealWidth: 480, maxWidth: 480, minHeight: 440)
        .onAppear {
            autoPopulateFromClipboard()
        }
    }

    // MARK: - Actions

    private func autoPopulateFromClipboard() {
        #if os(macOS)
        if let string = NSPasteboard.general.string(forType: .string),
           let url = URL(string: string),
           url.scheme == "http" || url.scheme == "https" {
            sourceURL = string
            selectedType = .webpage
        }
        #endif
    }

    private func applyFileMetadata(from url: URL) {
        let metadata = ArtifactMetadataExtractor.extractFromFile(url: url)
        if title.isEmpty, let metaTitle = metadata.title {
            title = metaTitle
        }
        selectedType = metadata.artifactType
    }

    private func save() {
        guard !title.isEmpty else { return }
        isSaving = true

        let capturedTitle = title
        let capturedType = selectedType
        let capturedSourceURL = sourceURL.isEmpty ? nil : sourceURL
        let capturedNotes = notes.isEmpty ? nil : notes
        let capturedTags = tags
        let capturedFileURL = droppedFileURL

        Task { @MainActor in
            if let fileURL = capturedFileURL {
                await ArtifactImportHandler.shared.importFile(
                    at: fileURL,
                    type: capturedType,
                    title: capturedTitle,
                    notes: capturedNotes,
                    tags: capturedTags
                )
            } else {
                RustStoreAdapter.shared.createArtifact(
                    type: capturedType,
                    title: capturedTitle,
                    sourceURL: capturedSourceURL,
                    notes: capturedNotes,
                    tags: capturedTags
                )
            }
            dismiss()
        }
    }
}

// MARK: - File Drop Zone

private struct FileDropZone: View {
    @Binding var fileURL: URL?
    var onDrop: (URL) -> Void
    @State private var isTargeted = false

    var body: some View {
        Group {
            if let url = fileURL {
                HStack {
                    Image(systemName: "doc.fill")
                    Text(url.lastPathComponent)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        fileURL = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(8)
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                VStack(spacing: 4) {
                    Image(systemName: "arrow.down.doc")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text("Drop file here")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(isTargeted ? Color.accentColor.opacity(0.1) : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5]))
                        .foregroundStyle(.secondary.opacity(0.5))
                )
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async {
                    fileURL = url
                    onDrop(url)
                }
            }
            return true
        }
    }
}

// MARK: - Flow Layout

private struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(proposal: proposal, subviews: subviews)
        for (index, offset) in result.offsets.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + offset.x, y: bounds.minY + offset.y),
                proposal: .unspecified
            )
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, offsets: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var offsets: [CGPoint] = []
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
            offsets.append(CGPoint(x: currentX, y: currentY))
            lineHeight = max(lineHeight, size.height)
            currentX += size.width + spacing
        }

        return (CGSize(width: maxWidth, height: currentY + lineHeight), offsets)
    }
}
