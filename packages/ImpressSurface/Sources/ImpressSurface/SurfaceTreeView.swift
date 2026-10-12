//
//  SurfaceTreeView.swift
//  ImpressSurface
//
//  Draws `RenderKind.tree`: the visible outline Rust already nested,
//  filtered by the expanded ids and flattened (`impress_surface::tree::build`).
//  Like the rest of this package it holds no decision of its own — every
//  gesture becomes a raw `SurfaceEvent` (values in `SurfaceTreeLogic`) and
//  `impress_surface::reduce` decides, on the far side of
//  `SharedSurface.dispatch`, whether the tree has a handler for it. The tree
//  never changes its data itself; a rename that no `on_rename` handles
//  simply snaps back to the label Rust sent.
//
//  What each cell of the chassis capability matrix is here
//  (docs/chassis-capability-matrix.md § "Surface tree node"):
//
//  - select        a row selected in the `List` -> `select [id]` (ids in
//                  drawing order; an empty selection sends nothing)
//  - open          a double-click on the row -> `activate [id]`
//  - context menu  `.contextMenu`: "Rename", then one entry per label in
//                  `actions` -> `menu {"id", "action"}`
//  - rename        the context-menu "Rename" swaps the label for a
//                  `TextField`; Return commits `rename {"id", "label"}`,
//                  Escape (or leaving the field) cancels. Always offered: the
//                  render tree does not say whether `on_rename` exists, and
//                  an unhandled rename is ignored.
//  - delete        macOS: Delete (`.onDeleteCommand`) -> `delete [ids]` of
//                  the selection. iOS has no equivalent command; a "Delete"
//                  entry in `actions` is the path there.
//  - drag / drop   only when the tree is `movable`: a row drags as its key
//                  text and a drop ON a row sends `move {"ids": [dragged],
//                  "to": <row id>, "index": 0}`. There are NO gap drops
//                  (between rows, or to the root): a row is only ever made a
//                  child, never a sibling at a position.
//  - counts        `count`, in secondary colour after the label
//  - disclosure    the chevron sends `change` with the whole expanded list
//                  with this id added or removed (`SurfaceTreeLogic.toggled`)
//
//  j / k are the chassis's (`.keyboardGuarded` in `SurfaceView`); the `List`
//  moves its own selection with the arrow keys. Ids reach the wire as the
//  JSON value the row had, a string as a string and a number as a number —
//  the view keeps a `key -> id` table rather than round-tripping through text.
//

import SwiftUI
import UniformTypeIdentifiers

/// One drawn row: the node and the text the `List` knows it by.
private struct SurfaceTreeRow: Identifiable, Hashable {
    let id: String
    let node: SurfaceTreeNode
}

struct SurfaceTreeView: View {
    let id: String
    let nodes: [SurfaceTreeNode]
    let expanded: [SurfaceJSONValue]
    let actions: [String]
    let movable: Bool
    let focusedWidgetID: FocusState<String?>.Binding
    let onEvent: (SurfaceEvent) -> Void

    @State private var selection = Set<String>()
    /// The key of the row being renamed, if any.
    @State private var renaming: String?
    @State private var renameDraft = ""
    @State private var renameHadFocus = false
    @State private var dropTarget: String?
    @FocusState private var renameFocused: Bool

    private var rows: [SurfaceTreeRow] {
        nodes.map { SurfaceTreeRow(id: SurfaceTreeLogic.key(for: $0.id), node: $0) }
    }

    var body: some View {
        list
            .listStyle(.sidebar)
            .focused(focusedWidgetID, equals: id)
            // Inside the column's `ScrollView` a `List` has no intrinsic
            // height (see the `list` case in `SurfaceNodeView`).
            .frame(minHeight: 240)
            .onChange(of: selection) { _, newValue in
                let ids = SurfaceTreeLogic.orderedIDs(keys: newValue, in: nodes)
                guard !ids.isEmpty else { return }
                onEvent(SurfaceTreeLogic.selectEvent(widget: id, ids: ids))
            }
    }

    @ViewBuilder
    private var list: some View {
        #if os(macOS)
        List(rows, selection: $selection) { row in
            rowView(row)
        }
        .onDeleteCommand {
            let ids = SurfaceTreeLogic.orderedIDs(keys: selection, in: nodes)
            guard !ids.isEmpty else { return }
            onEvent(SurfaceTreeLogic.deleteEvent(widget: id, ids: ids))
        }
        #else
        List(rows, selection: $selection) { row in
            rowView(row)
        }
        #endif
    }

    // MARK: Row

    @ViewBuilder
    private func rowView(_ row: SurfaceTreeRow) -> some View {
        let node = row.node
        let content = HStack(spacing: 4) {
            disclosure(node)
            if renaming == row.id {
                renameField(row)
            } else {
                Text(node.label)
                    .lineLimit(1)
            }
            Spacer()
            if let count = node.count {
                Text(count.displayText)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, CGFloat(node.depth) * 14)
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .background(dropTarget == row.id ? Color.accentColor.opacity(0.25) : Color.clear)
        .onTapGesture(count: 2) {
            onEvent(SurfaceTreeLogic.activateEvent(widget: id, id: node.id))
        }
        .contextMenu {
            Button("Rename") {
                renameDraft = node.label
                renameHadFocus = false
                renaming = row.id
            }
            ForEach(actions, id: \.self) { label in
                Button(label) {
                    onEvent(SurfaceTreeLogic.menuEvent(widget: id, id: node.id, action: label))
                }
            }
        }
        if movable {
            content
                .onDrag { NSItemProvider(object: row.id as NSString) }
                .onDrop(
                    of: [UTType.text],
                    isTargeted: Binding<Bool>(
                        get: { dropTarget == row.id },
                        set: { targeted in
                            if targeted {
                                dropTarget = row.id
                            } else if dropTarget == row.id {
                                dropTarget = nil
                            }
                        })
                ) { providers in
                    drop(providers, onto: node.id)
                }
        } else {
            content
        }
    }

    private func disclosure(_ node: SurfaceTreeNode) -> some View {
        Group {
            if node.hasChildren {
                Button {
                    let next = SurfaceTreeLogic.toggled(
                        expanded, id: node.id, currentlyExpanded: node.expanded)
                    onEvent(SurfaceTreeLogic.changeEvent(widget: id, expanded: next))
                } label: {
                    Image(systemName: node.expanded ? "chevron.down" : "chevron.right")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(node.expanded ? "Collapse" : "Expand")
            } else {
                Color.clear
            }
        }
        .frame(width: 14)
    }

    // MARK: Rename

    private func renameField(_ row: SurfaceTreeRow) -> some View {
        TextField("", text: $renameDraft)
            .textFieldStyle(.plain)
            .focused($renameFocused)
            .onAppear { renameFocused = true }
            .onSubmit { commitRename(row) }
            .onKeyPress(keys: [.escape]) { _ in
                cancelRename()
                return .handled
            }
            #if os(macOS)
            // An `NSTextField` takes Escape as `cancelOperation:`, which
            // SwiftUI delivers here rather than as a key press.
            .onExitCommand { cancelRename() }
            #endif
            .onChange(of: renameFocused) { _, focused in
                // Leaving the field cancels, but only once it had focus: the
                // context menu closing can briefly hand focus back to the list.
                if focused {
                    renameHadFocus = true
                } else if renameHadFocus {
                    cancelRename()
                }
            }
    }

    private func commitRename(_ row: SurfaceTreeRow) {
        let widget = id
        let target = row.node.id
        let label = SurfaceTreeLogic.committedLabel(draft: renameDraft, original: row.node.label)
        cancelRename()
        guard let label else { return }
        onEvent(SurfaceTreeLogic.renameEvent(widget: widget, id: target, label: label))
    }

    private func cancelRename() {
        renaming = nil
        renameHadFocus = false
    }

    // MARK: Drop

    /// A drop of one of this tree's own rows ON a row: the dragged row's key
    /// is looked up in the visible nodes, so text from anywhere else matches
    /// nothing and is refused.
    private func drop(_ providers: [NSItemProvider], onto target: SurfaceJSONValue) -> Bool {
        guard let provider = providers.first, provider.canLoadObject(ofClass: String.self) else {
            return false
        }
        let widget = id
        let table = SurfaceTreeLogic.idsByKey(nodes)
        let send = onEvent
        _ = provider.loadObject(ofClass: String.self) { text, _ in
            guard let text, let dragged = table[text], dragged != target else { return }
            DispatchQueue.main.async {
                send(
                    SurfaceTreeLogic.moveEvent(
                        widget: widget, ids: [dragged], to: target, index: 0))
            }
        }
        return true
    }
}

// MARK: - Graph

/// `RenderKind.graph`. `SurfaceHooks.renderPlot` takes a `plot-spec@1.0.0`
/// document, not SVG text and not a graph spec, so there is nothing in the
/// hooks to hand the drawing to: this shows a labelled placeholder with the
/// node count. A host that wants the drawing adds an SVG hook (the `svg` is
/// already in the render tree).
struct SurfaceGraphView: View {
    let spec: SurfaceJSONValue
    let svg: String

    private var nodeCount: Int { spec["nodes"]?.arrayValue?.count ?? 0 }

    var body: some View {
        Label(
            nodeCount == 1 ? "Graph, 1 node" : "Graph, \(nodeCount) nodes",
            systemImage: "point.3.connected.trianglepath.dotted"
        )
        .foregroundStyle(.secondary)
        .padding(8)
    }
}
