//
//  ArtifactBadgeView.swift
//  impart
//
//  Badge showing attached artifact with type indicator.
//

import SwiftUI
import MessageManagerCore

struct ArtifactBadgeView: View {
    let artifact: DirectoryArtifact
    var onRemove: (() -> Void)?
    var onOpen: (() -> Void)?

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .foregroundStyle(.blue)

            Text(artifact.name)
                .lineLimit(1)

            if isHovering {
                HStack(spacing: 4) {
                    if let onOpen = onOpen {
                        Button {
                            onOpen()
                        } label: {
                            Image(systemName: "arrow.up.forward.square")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .help("Open in Finder")
                    }

                    if let onRemove = onRemove {
                        Button {
                            onRemove()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .help("Remove")
                    }
                }
            }
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary)
        .clipShape(Capsule())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }
}

// MARK: - Generic Artifact Badge

/// Badge view for any artifact type (not just directories).
struct GenericArtifactBadgeView: View {
    let type: ArtifactType
    let name: String
    var onTap: (() -> Void)?

    var body: some View {
        Button {
            onTap?()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: type.iconName)
                    .foregroundStyle(iconColor)

                Text(name)
                    .lineLimit(1)
            }
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var iconColor: Color {
        switch type {
        case .externalDirectory: return .blue
        case .imprintManuscript: return .purple
        case .imbibPublication: return .orange
        case .managedDirectory: return .green
        case .file: return .gray
        case .paper: return .orange
        case .document: return .purple
        case .repository: return .cyan
        case .dataset: return .teal
        case .robot: return .pink
        case .stream: return .mint
        case .externalUrl: return .blue
        case .unknown: return .secondary
        }
    }
}

// MARK: - Artifact List Item

/// List row for artifacts in a detail view.
struct ArtifactListRow: View {
    let artifact: DirectoryArtifact
    var isAccessing: Bool = false
    var onOpen: (() -> Void)?
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .font(.title2)
                .foregroundStyle(.blue)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(artifact.name)
                    .fontWeight(.medium)

                HStack(spacing: 8) {
                    if isAccessing {
                        Label("Active", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }

                    Text("Added \(artifact.createdAt, style: .relative)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if let onOpen = onOpen {
                Button("Open", systemImage: "arrow.up.forward.square") {
                    onOpen()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if let onRemove = onRemove {
                Button {
                    onRemove()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Preview

#Preview("Badge") {
    HStack {
        ArtifactBadgeView(
            artifact: DirectoryArtifact(
                id: UUID(),
                name: "my-project",
                bookmarkData: Data(),
                createdAt: Date(),
                lastAccessedAt: Date()
            ),
            onRemove: {},
            onOpen: {}
        )

        GenericArtifactBadgeView(
            type: .imprintManuscript,
            name: "Research Paper"
        )

        GenericArtifactBadgeView(
            type: .repository,
            name: "github/project"
        )
    }
    .padding()
}

#Preview("List Row") {
    List {
        ArtifactListRow(
            artifact: DirectoryArtifact(
                id: UUID(),
                name: "impress-apps",
                bookmarkData: Data(),
                createdAt: Date().addingTimeInterval(-3600),
                lastAccessedAt: Date()
            ),
            isAccessing: true,
            onOpen: {},
            onRemove: {}
        )

        ArtifactListRow(
            artifact: DirectoryArtifact(
                id: UUID(),
                name: "another-project",
                bookmarkData: Data(),
                createdAt: Date().addingTimeInterval(-86400),
                lastAccessedAt: Date()
            ),
            isAccessing: false,
            onOpen: {},
            onRemove: {}
        )
    }
    .frame(width: 400, height: 200)
}
