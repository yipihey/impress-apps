import SwiftUI

/// Sidebar view for multi-file LaTeX projects.
/// Shows the project file tree with indicators for main file and error status.
struct LaTeXProjectSidebarView: View {
    let projectFiles: [URL]
    let mainFileURL: URL?
    let onSelectFile: (URL) -> Void

    var body: some View {
        Section("Project Files") {
            ForEach(projectFiles, id: \.absoluteString) { fileURL in
                Button {
                    onSelectFile(fileURL)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: iconName(for: fileURL))
                            .foregroundStyle(iconColor(for: fileURL))
                            .frame(width: 16)

                        Text(fileURL.lastPathComponent)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        if fileURL == mainFileURL {
                            Text("main")
                                .font(.caption2)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(.blue.opacity(0.15), in: Capsule())
                                .foregroundStyle(.blue)
                        }

                        Spacer()
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func iconName(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "tex": return "doc.text"
        case "bib": return "books.vertical"
        case "sty", "cls": return "gearshape"
        case "bst": return "list.bullet"
        default: return "doc"
        }
    }

    private func iconColor(for url: URL) -> Color {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "tex": return .blue
        case "bib": return .orange
        case "sty", "cls": return .purple
        default: return .secondary
        }
    }
}

#Preview {
    List {
        LaTeXProjectSidebarView(
            projectFiles: [
                URL(fileURLWithPath: "/tmp/main.tex"),
                URL(fileURLWithPath: "/tmp/intro.tex"),
                URL(fileURLWithPath: "/tmp/methods.tex"),
                URL(fileURLWithPath: "/tmp/refs.bib"),
            ],
            mainFileURL: URL(fileURLWithPath: "/tmp/main.tex"),
            onSelectFile: { _ in }
        )
    }
    .listStyle(.sidebar)
    .frame(width: 220, height: 300)
}
