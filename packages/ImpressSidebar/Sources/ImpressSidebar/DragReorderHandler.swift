//
//  DragReorderHandler.swift
//  ImpressSidebar
//
//  Generic drag-reorder logic for sidebar sections, libraries, and other ordered lists.
//

#if os(macOS)
import AppKit
#endif
import Foundation

/// Generic handler for drag-reorder operations in sidebar lists.
///
/// Encapsulates the index math for `.onInsert(of:perform:)` that accounts for
/// source removal when calculating the destination index.
///
/// **Usage:**
/// ```swift
/// .onInsert(of: [.libraryID]) { index, providers in
///     DragReorderHandler.handleInsert(
///         at: index,
///         providers: providers,
///         typeIdentifier: UTType.libraryID.identifier,
///         items: libraries,
///         extractID: { data in
///             String(data: data, encoding: .utf8).flatMap(UUID.init(uuidString:))
///         },
///         completion: { reordered in
///             // Persist new order
///         }
///     )
/// }
/// ```
public enum DragReorderHandler {

    /// Handle an `.onInsert` drag-reorder operation.
    ///
    /// Decodes the dragged item's ID from the provider, finds it in the items array,
    /// calculates the correct destination index (accounting for removal), and calls
    /// the completion with the reordered array.
    ///
    /// - Parameters:
    ///   - targetIndex: The insertion index from `.onInsert`
    ///   - providers: The `NSItemProvider` array from `.onInsert`
    ///   - typeIdentifier: The UTType identifier string to load from the provider
    ///   - items: The current ordered array of items
    ///   - extractID: Closure to extract the item's ID from the provider's data
    ///   - completion: Called on MainActor with the reordered array
    @MainActor
    public static func handleInsert<Item: Identifiable>(
        at targetIndex: Int,
        providers: [NSItemProvider],
        typeIdentifier: String,
        items: [Item],
        extractID: @Sendable @escaping (Data) -> Item.ID?,
        completion: @MainActor @Sendable @escaping ([Item]) -> Void
    ) {
        guard let provider = providers.first else { return }

        provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
            guard let data = data,
                  let draggedID = extractID(data) else { return }

            Task { @MainActor in
                var reordered = items
                guard let sourceIndex = reordered.firstIndex(where: { $0.id == draggedID }) else { return }

                let destinationIndex = sourceIndex < targetIndex ? targetIndex - 1 : targetIndex
                let clampedDestination = max(0, min(destinationIndex, reordered.count - 1))

                let item = reordered.remove(at: sourceIndex)
                reordered.insert(item, at: clampedDestination)

                completion(reordered)
            }
        }
    }

    /// Calculate the correct destination index for a reorder operation.
    ///
    /// When an item is removed from `sourceIndex` and inserted at `targetIndex`,
    /// the actual destination needs adjustment if the source was before the target.
    ///
    /// - Parameters:
    ///   - sourceIndex: The current index of the item being moved
    ///   - targetIndex: The raw insertion index
    ///   - count: The total number of items (used for clamping)
    /// - Returns: The correct destination index after removal
    public static func adjustedDestination(sourceIndex: Int, targetIndex: Int, count: Int) -> Int {
        let adjusted = sourceIndex < targetIndex ? targetIndex - 1 : targetIndex
        return max(0, min(adjusted, count - 1))
    }
}
