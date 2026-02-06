//
//  SectionDragReorder.swift
//  ImpressSidebar
//
//  Shared drag-reorder logic for sidebar section headers.
//  Encode/decode section rawValues, reorder arrays, and handle drops.
//

import Foundation
import SwiftUI

// MARK: - Section Drag Reorder Logic

/// Shared helpers for sidebar section drag-reorder operations.
///
/// Eliminates duplicated encode/decode/reorder logic across impress apps.
///
/// **Usage:**
/// ```swift
/// // In your drop handler:
/// SectionDragReorder.handleDrop(
///     providers: providers,
///     typeIdentifier: UTType.mySectionID.identifier,
///     targetSection: targetSection,
///     currentOrder: sectionOrder
/// ) { newOrder in
///     sectionOrder = newOrder
///     await MySection.orderStore.save(newOrder)
/// }
/// ```
public enum SectionDragReorder {

    /// Encode a section's rawValue to Data for drag-and-drop.
    public static func encode<S: SidebarSection>(_ section: S) -> Data {
        section.rawValue.data(using: .utf8) ?? Data()
    }

    /// Decode a section from drag-and-drop Data.
    public static func decode<S: SidebarSection>(_ data: Data, as type: S.Type) -> S? {
        guard let string = String(data: data, encoding: .utf8) else { return nil }
        return S(rawValue: string)
    }

    /// Reorder sections array, moving `dragged` to the position of `target`.
    ///
    /// Returns the new order, or `nil` if no change was needed (same section or not found).
    public static func reorder<S: SidebarSection>(
        _ order: [S],
        moving dragged: S,
        to target: S
    ) -> [S]? {
        guard dragged != target else { return nil }

        var reordered = order
        guard let sourceIndex = reordered.firstIndex(of: dragged),
              reordered.firstIndex(of: target) != nil else { return nil }

        reordered.remove(at: sourceIndex)
        // Re-find the target after removal (index may have shifted)
        let insertIndex = reordered.firstIndex(of: target) ?? reordered.endIndex
        reordered.insert(dragged, at: insertIndex)

        return reordered
    }

    /// Handle a full section drop from NSItemProvider.
    ///
    /// Decodes the dragged section, reorders the array, and calls the completion closure.
    /// Returns `true` if the drop was accepted (provider had matching type).
    @MainActor
    @discardableResult
    public static func handleDrop<S: SidebarSection>(
        providers: [NSItemProvider],
        typeIdentifier: String,
        targetSection: S,
        currentOrder: [S],
        completion: @MainActor @escaping ([S]) -> Void
    ) -> Bool {
        guard let provider = providers.first,
              provider.hasItemConformingToTypeIdentifier(typeIdentifier) else {
            return false
        }

        provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
            guard let data = data,
                  let dragged = decode(data, as: S.self),
                  let newOrder = reorder(currentOrder, moving: dragged, to: targetSection) else { return }

            Task { @MainActor in
                completion(newOrder)
            }
        }
        return true
    }
}

// MARK: - Section Drop Indicator Line

/// Blue insertion line shown above section headers during drag reordering.
public struct SectionDropIndicatorLine: View {
    public init() {}

    public var body: some View {
        Rectangle()
            .fill(Color.accentColor)
            .frame(height: 2)
            .padding(.horizontal, 4)
    }
}

// MARK: - Binding Extension for Drop Targeting

extension Binding {
    /// Creates a `Binding<Bool>` that maps optional equality to per-item targeting.
    ///
    /// Replaces duplicated `sectionDropTargetBinding(for:)` in both apps.
    ///
    /// **Usage:**
    /// ```swift
    /// .onDrop(
    ///     of: [.mySectionID],
    ///     isTargeted: .optionalEquality(source: $dropTarget, equals: section)
    /// ) { ... }
    /// ```
    public static func optionalEquality<T: Equatable>(
        source: Binding<T?>,
        equals value: T
    ) -> Binding<Bool> where Value == Bool {
        Binding<Bool>(
            get: { source.wrappedValue == value },
            set: { isTargeted in
                if isTargeted {
                    source.wrappedValue = value
                } else if source.wrappedValue == value {
                    source.wrappedValue = nil
                }
            }
        )
    }
}

// MARK: - Preview

#Preview("Section Drop Indicator") {
    VStack(spacing: 20) {
        Text("Section Header Above")
            .padding(.horizontal)
        SectionDropIndicatorLine()
        Text("Section Header Below")
            .padding(.horizontal)
    }
    .frame(width: 250)
    .padding()
}
