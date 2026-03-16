import SwiftUI
import ImpressTheme

/// Scrollable undo history timeline with click-to-jump.
public struct UndoHistoryView: View {
    @MainActor let store: UndoHistoryStore
    let onUndo: () -> Void
    let onRedo: () -> Void

    @MainActor
    public init(
        store: UndoHistoryStore = .shared,
        onUndo: @escaping () -> Void = {},
        onRedo: @escaping () -> Void = {}
    ) {
        self.store = store
        self.onUndo = onUndo
        self.onRedo = onRedo
    }

    public var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            historyList
        }
        .frame(minWidth: 280, minHeight: 200)
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack {
            Button {
                onUndo()
            } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
                    .labelStyle(.titleAndIcon)
            }
            .disabled(!store.canUndo)
            .buttonStyle(.borderless)

            Button {
                onRedo()
            } label: {
                Label("Redo", systemImage: "arrow.uturn.forward")
                    .labelStyle(.titleAndIcon)
            }
            .disabled(!store.canRedo)
            .buttonStyle(.borderless)

            Spacer()

            Button("Clear") {
                store.clear()
            }
            .buttonStyle(.borderless)
            .disabled(store.entries.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - History List

    private var historyList: some View {
        ScrollViewReader { proxy in
            List {
                // Session start marker
                sessionStartRow

                // Entries from oldest to newest
                ForEach(Array(store.entries.enumerated()), id: \.element.id) { index, entry in
                    historyRow(entry: entry, index: index)
                        .id(entry.id)
                }
            }
            .listStyle(.plain)
            .onChange(of: store.currentIndex) { _, _ in
                scrollToCurrent(proxy: proxy)
            }
            .onAppear {
                scrollToCurrent(proxy: proxy)
            }
        }
    }

    // MARK: - Rows

    private var sessionStartRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "circle.fill")
                .font(.system(size: 6))
                .foregroundStyle(.secondary)
            Text("Session Start")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 2)
        .listRowSeparator(.hidden)
        .opacity(store.currentIndex == -1 ? 1.0 : 0.5)
        .listRowBackground(store.currentIndex == -1 ? Color.accentColor.opacity(0.12) : Color.clear)
    }

    private func historyRow(entry: UndoHistoryEntry, index: Int) -> some View {
        let isCurrent = index == store.currentIndex
        let isPast = index <= store.currentIndex  // can be undone
        let isFuture = index > store.currentIndex  // can be redone

        return Button {
            let steps = store.jumpToState(
                index: index,
                performUndo: onUndo,
                performRedo: onRedo
            )
            _ = steps
        } label: {
            HStack(spacing: 8) {
                // State indicator
                Image(systemName: isCurrent ? "circle.inset.filled" : "circle")
                    .font(.system(size: 6))
                    .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)

                // Agent badge
                if entry.authorKind == .agent {
                    Image(systemName: "cpu")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                // Action name
                Text(entry.actionName)
                    .font(.subheadline)
                    .fontWeight(isCurrent ? .semibold : .regular)
                    .lineLimit(1)

                Spacer()

                // Undo/redo indicator
                if isPast && !isCurrent {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                } else if isFuture {
                    Image(systemName: "arrow.uturn.forward")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }

                // Timestamp
                Text(entry.timestamp, style: .time)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .opacity(isFuture ? 0.5 : 1.0)
        .listRowSeparator(.hidden)
        .listRowBackground(isCurrent ? Color.accentColor.opacity(0.12) : Color.clear)
    }

    private func scrollToCurrent(proxy: ScrollViewProxy) {
        if store.currentIndex >= 0, store.currentIndex < store.entries.count {
            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo(store.entries[store.currentIndex].id, anchor: .center)
            }
        }
    }
}
