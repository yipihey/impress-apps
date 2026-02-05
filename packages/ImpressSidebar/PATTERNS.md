# ImpressSidebar Patterns

Patterns for sidebar features that are **too domain-specific to generalize** but too common to reinvent. Copy and adapt these for each impress app.

## 1. Drop Coordinator Pattern

Sidebar drop handling requires per-app UTType validation and action routing. The structure is always the same: detect type, validate, execute.

```swift
// In your sidebar row or section:
.onDrop(
    of: acceptedTypes,
    isTargeted: $isDropTargeted
) { providers in
    handleDrop(providers: providers)
}

private func handleDrop(providers: [NSItemProvider]) -> Bool {
    for provider in providers {
        // Check each accepted type in priority order
        if provider.hasItemConformingToTypeIdentifier(UTType.myItemID.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.myItemID.identifier, options: nil) { data, _ in
                guard let data = data as? Data,
                      let idString = String(data: data, encoding: .utf8),
                      let draggedID = UUID(uuidString: idString) else { return }

                // Validate (e.g., prevent dropping onto self, cycle detection)
                guard draggedID != targetID else { return }

                Task { @MainActor in
                    // Execute the domain action
                    onMoveItem?(draggedID, targetID)
                }
            }
            return true
        }
    }
    return false
}
```

**Auto-expand on hover:** Use a targeted binding that starts a timer.

```swift
private func makeDropTargetBinding(_ id: UUID) -> Binding<Bool> {
    Binding(
        get: { state.dropTargetedItem == id },
        set: { targeted in
            state.dropTargetedItem = targeted ? id : nil
            if targeted {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if state.dropTargetedItem == id {
                        expansionState.expand(id)
                    }
                }
            }
        }
    )
}
```

## 2. SidebarState Pattern

Each app should have one `@Observable` class consolidating all sidebar state. This prevents scattered `@State` variables and makes state easier to reason about.

```swift
@MainActor @Observable
final class MySidebarState {
    // Sheet management (enum ensures mutual exclusivity)
    var activeSheet: MySidebarSheet?

    // Drop state
    var dropTargetedItem: UUID?

    // Multi-selection (use ImpressSidebar's SidebarMultiSelection)
    var itemSelection = SidebarMultiSelection<UUID>()

    // Editing state
    var renamingItem: MyItem?

    // Confirmation dialogs
    var itemToDelete: MyItem?
    var showDeleteConfirmation = false

    // Convenience methods
    func dismissSheet() { activeSheet = nil }
    func clearSelection() { itemSelection.clear() }
}

// Sheet enum with associated values
enum MySidebarSheet: Identifiable {
    case newItem
    case editItem(MyItem)
    case importPreview(data: ImportData)

    var id: String {
        switch self {
        case .newItem: return "new"
        case .editItem(let item): return "edit-\(item.id)"
        case .importPreview: return "import"
        }
    }
}
```

## 3. Tree Node Adapter Pattern

Bridge your Core Data (or other) models to `SidebarTreeNode` with lightweight adapter structs. Keep adapters in your core package so they're available to both macOS and iOS.

```swift
@MainActor
public struct MyItemNodeAdapter: SidebarTreeNode {
    private let item: CDMyItem

    public init(_ item: CDMyItem) {
        self.item = item
    }

    public var id: UUID { item.id }
    public var displayName: String { item.name }

    public var iconName: String {
        switch item.type {
        case .folder: return "folder"
        case .smart:  return "folder.badge.gearshape"
        case .system: return "tray"
        }
    }

    // Optional: custom icon color per item type
    public var iconColor: Color? {
        switch item.type {
        case .system: return .accentColor
        case .trash:  return .red
        default:      return nil  // uses default .secondary
        }
    }

    public var displayCount: Int? {
        item.itemCount > 0 ? Int(item.itemCount) : nil
    }

    public var treeDepth: Int { item.depth }
    public var hasTreeChildren: Bool { item.hasChildren }
    public var parentID: UUID? { item.parentItem?.id }
    public var childIDs: [UUID] { item.sortedChildren.map(\.id) }
    public var ancestorIDs: [UUID] { item.ancestors.map(\.id) }

    /// Expose underlying model for domain-specific operations
    public var underlyingItem: CDMyItem { item }
}

// Array convenience
extension Array where Element == CDMyItem {
    @MainActor
    func asNodeAdapters() -> [MyItemNodeAdapter] {
        map { MyItemNodeAdapter($0) }
    }
}
```

## 4. Transferable Drag Items

Each draggable sidebar item type needs a `Transferable` wrapper. The pattern is always: encode ID to data, decode in the importing closure.

```swift
// Define custom UTTypes in your Info.plist and code:
extension UTType {
    static let myItemID = UTType(exportedAs: "com.myapp.item-id")
}

// Transferable wrapper
struct MyItemDragItem: Transferable {
    let id: UUID

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .myItemID) { item in
            Data(item.id.uuidString.utf8)
        } importing: { data in
            guard let str = String(data: data, encoding: .utf8),
                  let uuid = UUID(uuidString: str) else {
                throw CocoaError(.coderInvalidValue)
            }
            return MyItemDragItem(id: uuid)
        }
    }
}

// For enum-based items (like section types):
struct SectionDragItem: Transferable {
    let section: MySectionType

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .mySectionID) { item in
            Data(item.section.rawValue.utf8)
        } importing: { data in
            guard let str = String(data: data, encoding: .utf8),
                  let section = MySectionType(rawValue: str) else {
                throw CocoaError(.coderInvalidValue)
            }
            return SectionDragItem(section: section)
        }
    }
}
```

**Using with `.itemProvider` (for legacy onInsert):**

```swift
.itemProvider {
    let provider = NSItemProvider()
    provider.registerDataRepresentation(
        forTypeIdentifier: UTType.myItemID.identifier,
        visibility: .all
    ) { completion in
        completion(Data(item.id.uuidString.utf8), nil)
        return nil
    }
    return provider
}
```

## Quick Reference: What Goes Where

| Need | Use |
|------|-----|
| Tree rendering (lines, disclosure, badge) | `GenericTreeRow` from ImpressSidebar |
| Tree flattening for ForEach | `TreeFlattener` from ImpressSidebar |
| Expand/collapse state | `TreeExpansionState` from ImpressSidebar |
| Section collapse toggle UI | `CollapsibleSection` from ImpressSidebar |
| Multi-selection with modifiers | `SidebarMultiSelection` from ImpressSidebar |
| Drag reorder in lists | `DragReorderHandler` from ImpressSidebar |
| Section order persistence | `SidebarSectionOrderStore` from ImpressSidebar |
| Section collapse persistence | `SidebarCollapsedStateStore` from ImpressSidebar |
| Drop handling logic | Copy pattern #1 above, adapt per app |
| Consolidated sidebar state | Copy pattern #2 above, adapt per app |
| Core Data to tree node bridge | Copy pattern #3 above, adapt per app |
| Drag item wrappers | Copy pattern #4 above, adapt per app |
