import AppKit
import SwiftUI

/// Keyboard-driven picker sheet that lists every Veusz plot tracked by the
/// current manuscript and inserts the selected one at the cursor on Enter.
///
/// Lighter than a full slash-palette: no editor text-input hooking, just a
/// modal sheet with arrow-key navigation. Opened from `ContentView` in
/// response to a menu command (Insert > Veusz Plot…).
struct InsertVeuszPlotPicker: View {
    @Binding var document: ImprintDocument
    @Environment(\.dismiss) private var dismiss

    /// Cursor offset to insert into. The host (ContentView) passes its current
    /// `cursorPosition` so the inserted snippet lands exactly where the user
    /// was typing.
    let cursorPosition: Int

    @State private var query: String = ""
    @State private var selectedIndex: Int = 0
    @FocusState private var queryFocused: Bool

    private var store: VeuszPlotStore? {
        VeuszPlotStoreRegistry.shared.store(forDocumentID: document.id)
    }

    private var allPlots: [VeuszPlotRef] {
        store?.plots ?? []
    }

    private var filteredPlots: [VeuszPlotRef] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return allPlots }
        let needle = trimmed.lowercased()
        return allPlots.filter { $0.displayName.lowercased().contains(needle) }
    }

    var body: some View {
        VStack(spacing: 0) {
            queryField
            Divider()
            if filteredPlots.isEmpty {
                emptyState
            } else {
                plotList
            }
            Divider()
            footer
        }
        .frame(width: 460, height: 420)
        .onAppear { queryFocused = true }
    }

    private var queryField: some View {
        HStack {
            Image(systemName: "chart.xyaxis.line")
                .foregroundStyle(.secondary)
            TextField("Filter plots…", text: $query)
                .textFieldStyle(.plain)
                .focused($queryFocused)
                .onSubmit(commitSelection)
                .onChange(of: query) { _, _ in selectedIndex = 0 }
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.title)
                .foregroundStyle(.secondary)
            if allPlots.isEmpty {
                Text("This manuscript has no plots yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Open the Plots Panel (⌥⌘P) to create one.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Text("No matches for \"\(query)\"")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var plotList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(filteredPlots.enumerated()), id: \.element.id) { index, plot in
                        plotRow(plot: plot, isSelected: index == selectedIndex)
                            .contentShape(Rectangle())
                            .onTapGesture { commit(plot: plot) }
                            .onHover { hover in if hover { selectedIndex = index } }
                            .id(index)
                    }
                }
            }
            .onChange(of: selectedIndex) { _, newValue in
                withAnimation(.easeOut(duration: 0.08)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
            .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
            .onKeyPress(.downArrow) { moveSelection(1); return .handled }
            .onKeyPress(.return) { commitSelection(); return .handled }
        }
    }

    private func plotRow(plot: VeuszPlotRef, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            thumbnail(for: plot)
                .frame(width: 80, height: 52)
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(plot.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? .white : .primary)
                    .lineLimit(1)
                Text(plot.renderedRelativePath)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
                    .lineLimit(1)
            }

            Spacer()
            Text(plot.exportFormat.rawValue.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(isSelected ? Color.white.opacity(0.2) : Color.secondary.opacity(0.15))
                .foregroundStyle(isSelected ? .white : .secondary)
                .clipShape(Capsule())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor : .clear)
    }

    @ViewBuilder
    private func thumbnail(for plot: VeuszPlotRef) -> some View {
        if let store,
           let url = thumbnailURL(plot: plot, in: store),
           let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .padding(2)
        } else {
            Image(systemName: "chart.xyaxis.line")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func thumbnailURL(plot: VeuszPlotRef, in store: VeuszPlotStore) -> URL? {
        let name = (plot.renderedRelativePath as NSString).lastPathComponent
        let url = store.workingDirectory.appending(path: name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text("↑↓ select · Return insert · Esc cancel")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
            Text("\(filteredPlots.count) plot\(filteredPlots.count == 1 ? "" : "s")")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Actions

    private func moveSelection(_ delta: Int) {
        let count = filteredPlots.count
        guard count > 0 else { return }
        selectedIndex = max(0, min(selectedIndex + delta, count - 1))
    }

    private func commitSelection() {
        guard !filteredPlots.isEmpty, selectedIndex < filteredPlots.count else { return }
        commit(plot: filteredPlots[selectedIndex])
    }

    private func commit(plot: VeuszPlotRef) {
        let snippet = VeuszPlotInsertion.block(for: plot, format: document.format)
        document.insertText(snippet, at: cursorPosition)
        dismiss()
    }
}
