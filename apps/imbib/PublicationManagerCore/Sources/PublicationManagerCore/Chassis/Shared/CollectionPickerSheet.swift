//
//  CollectionPickerSheet.swift
//  PublicationManagerCore
//
//  The "which collection?" step behind Paper ▸ Move to Collection… (⌃⌘M) and
//  Paper ▸ Add to Collection… (⌘L). Both menu items posted a notification
//  nothing observed, and the list had no way to ask for a collection from the
//  keyboard at all — the only paths into a collection were a sidebar drop and
//  the iOS organise menu. This sheet asks; the verbs it hands the answer to
//  already existed (`PublicationListMutations.moveToCollection`, the drop's
//  sequence, and `RustStoreAdapter.addToCollection`, the row actions' add).
//
//  Keyboard-first: the filter field has focus, ↑/↓ move the selection, ⏎
//  picks, ⎋ cancels.
//

import SwiftUI

/// A collection the selection can be filed into.
public struct CollectionTarget: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let libraryID: UUID
    /// "Library ▸ Parent ▸ Collection" — what the sheet shows and filters on.
    public let path: String

    /// Every non-smart collection of `libraries`, as targets sorted by path.
    ///
    /// Pure over its input so the rules are testable without a store: a smart
    /// collection is a query, not a place to put a paper, and a collection's
    /// path follows payload `parent_id` (`CollectionModel.parentID`), never
    /// the owning library (apps/imbib/CLAUDE.md, "Collection tree parent").
    public static func targets(
        libraries: [(id: UUID, name: String, collections: [CollectionModel])]
    ) -> [CollectionTarget] {
        var result: [CollectionTarget] = []
        for library in libraries {
            let byID = Dictionary(
                library.collections.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for collection in library.collections where !collection.isSmart {
                var names = [collection.name]
                var seen: Set<UUID> = [collection.id]
                var parent = collection.parentID
                while let pid = parent, let p = byID[pid], seen.insert(pid).inserted {
                    names.insert(p.name, at: 0)
                    parent = p.parentID
                }
                result.append(CollectionTarget(
                    id: collection.id,
                    libraryID: library.id,
                    path: ([library.name] + names).joined(separator: " ▸ ")))
            }
        }
        return result.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }

    /// The targets the store has now: every user library's collections —
    /// not Inbox, Dismissed or Exploration, which are triage places rather
    /// than filing ones.
    @MainActor
    public static func current(libraryManager: LibraryManager) -> [CollectionTarget] {
        let store = RustStoreAdapter.shared
        var excluded = Set<UUID>()
        for special in [libraryManager.dismissedLibrary, libraryManager.explorationLibrary] {
            if let special { excluded.insert(special.id) }
        }
        let libraries = store.listLibraries()
            .filter { !$0.isInbox && !excluded.contains($0.id) }
            .map { ($0.id, $0.name, store.listCollections(libraryId: $0.id)) }
        return targets(libraries: libraries)
    }
}

/// What the list asked the sheet for: the rows (captured when the menu item
/// fired, never re-read from `@State`) and the verb.
struct CollectionPickRequest: Identifiable {
    enum Verb { case move, add }
    let id = UUID()
    let verb: Verb
    let publicationIDs: [UUID]
    let targets: [CollectionTarget]
}

struct CollectionPickerSheet: View {
    let request: CollectionPickRequest
    let onPick: (CollectionTarget) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selection: UUID?
    @FocusState private var filterFocused: Bool

    private var title: String {
        let n = request.publicationIDs.count
        let papers = n == 1 ? "1 paper" : "\(n) papers"
        switch request.verb {
        case .move: return "Move \(papers) to Collection"
        case .add: return "Add \(papers) to Collection"
        }
    }

    private var actionLabel: String { request.verb == .move ? "Move" : "Add" }

    private var visible: [CollectionTarget] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return request.targets }
        return request.targets.filter { $0.path.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            TextField("Filter collections", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($filterFocused)
                .onKeyPress(.downArrow) { step(1) }
                .onKeyPress(.upArrow) { step(-1) }
                .onSubmit(pick)
            if request.targets.isEmpty {
                Text("No collections yet. Create one in the sidebar first.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(visible, selection: $selection) { target in
                    Text(target.path)
                        .tag(target.id)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            selection = target.id
                            pick()
                        }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(actionLabel, action: pick)
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen == nil)
            }
        }
        .padding(16)
        .frame(minWidth: 420, minHeight: 360)
        .onAppear {
            selection = visible.first?.id
            filterFocused = true
        }
        .onChange(of: query) { _, _ in
            if !visible.contains(where: { $0.id == selection }) {
                selection = visible.first?.id
            }
        }
    }

    private var chosen: CollectionTarget? {
        visible.first { $0.id == selection }
    }

    private func step(_ delta: Int) -> KeyPress.Result {
        let rows = visible
        guard !rows.isEmpty else { return .handled }
        let index = rows.firstIndex { $0.id == selection } ?? (delta > 0 ? -1 : rows.count)
        selection = rows[min(max(index + delta, 0), rows.count - 1)].id
        return .handled
    }

    private func pick() {
        guard let target = chosen else { return }
        dismiss()
        onPick(target)
    }
}
