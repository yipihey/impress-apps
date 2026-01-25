//
//  DropTargetModifier.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-16.
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Drop Target Modifier

/// A view modifier that provides consistent drop target styling and handling.
///
/// Provides visual feedback for:
/// - Valid drop target (blue border + badge)
/// - PDF on library (doc.badge.plus icon)
/// - File on publication (paperclip icon)
/// - Invalid drop (red X badge)
/// - Processing (spinner)
public struct DropTargetModifier: ViewModifier {

    // MARK: - Properties

    let target: DropTarget
    let coordinator: DragDropCoordinator

    @State private var isTargeted = false
    @State private var validation: DropValidation = .invalid

    // MARK: - Body

    public func body(content: Content) -> some View {
        content
            .overlay(alignment: .trailing) {
                if isTargeted {
                    dropBadge
                        .padding(.trailing, 4)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .background {
                if isTargeted && validation.isValid {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.accentColor.opacity(0.15))
                }
            }
            .overlay {
                if isTargeted {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(
                            validation.isValid ? Color.accentColor : Color.red,
                            lineWidth: 2
                        )
                }
            }
            .onDrop(of: DragDropCoordinator.acceptedTypes, isTargeted: $isTargeted) { providers, location in
                // Create a synthetic DragDropInfo
                let info = DragDropInfo(providers: providers)

                Task {
                    await coordinator.performDrop(info, target: target)
                }

                return true
            }
            .onChange(of: isTargeted) { _, newValue in
                if newValue {
                    coordinator.currentTarget = target
                    // Validate on enter
                    // Note: We can't get full DropInfo here, so we use basic validation
                } else {
                    if coordinator.currentTarget == target {
                        coordinator.currentTarget = nil
                    }
                }
            }
            .animation(.easeInOut(duration: 0.15), value: isTargeted)
    }

    // MARK: - Badge View

    @ViewBuilder
    private var dropBadge: some View {
        if coordinator.isProcessing {
            ProgressView()
                .scaleEffect(0.6)
        } else if validation.isValid {
            HStack(spacing: 4) {
                if let icon = validation.badgeIcon {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                }
                if let text = validation.badgeText {
                    Text(text)
                        .font(.caption2)
                        .fontWeight(.medium)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.accentColor, in: Capsule())
        } else {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.system(size: 14))
        }
    }
}

// MARK: - Lightweight Drop Info

/// A lightweight drop info container for use with the modifier.
/// Named with prefix to avoid conflict with SwiftUI.DropInfo.
public struct DragDropInfo: Sendable {
    public let providers: [NSItemProvider]

    public init(providers: [NSItemProvider]) {
        self.providers = providers
    }

    public func hasItemsConforming(to types: [UTType]) -> Bool {
        for provider in providers {
            for type in types {
                if provider.hasItemConformingToTypeIdentifier(type.identifier) {
                    return true
                }
            }
        }
        return false
    }

    public func itemProviders(for types: [UTType]) -> [NSItemProvider] {
        providers.filter { provider in
            types.contains { type in
                provider.hasItemConformingToTypeIdentifier(type.identifier)
            }
        }
    }
}

// MARK: - View Extension

public extension View {

    /// Apply drop target styling and handling to a view.
    ///
    /// - Parameters:
    ///   - target: The drop target type
    ///   - coordinator: The drag-drop coordinator
    /// - Returns: Modified view with drop handling
    func dropTarget(_ target: DropTarget, coordinator: DragDropCoordinator) -> some View {
        modifier(DropTargetModifier(target: target, coordinator: coordinator))
    }

    /// Apply library drop target for sidebar items.
    ///
    /// - Parameters:
    ///   - libraryID: The library UUID
    ///   - coordinator: The drag-drop coordinator
    /// - Returns: Modified view with drop handling
    func libraryDropTarget(libraryID: UUID, coordinator: DragDropCoordinator) -> some View {
        dropTarget(.library(libraryID: libraryID), coordinator: coordinator)
    }

    /// Apply collection drop target for sidebar items.
    ///
    /// - Parameters:
    ///   - collectionID: The collection UUID
    ///   - libraryID: The owning library UUID
    ///   - coordinator: The drag-drop coordinator
    /// - Returns: Modified view with drop handling
    func collectionDropTarget(collectionID: UUID, libraryID: UUID, coordinator: DragDropCoordinator) -> some View {
        dropTarget(.collection(collectionID: collectionID, libraryID: libraryID), coordinator: coordinator)
    }

    /// Apply publication drop target for attaching files.
    ///
    /// - Parameters:
    ///   - publicationID: The publication UUID
    ///   - libraryID: Optional library UUID
    ///   - coordinator: The drag-drop coordinator
    /// - Returns: Modified view with drop handling
    func publicationDropTarget(publicationID: UUID, libraryID: UUID?, coordinator: DragDropCoordinator) -> some View {
        dropTarget(.publication(publicationID: publicationID, libraryID: libraryID), coordinator: coordinator)
    }
}

// MARK: - Sidebar Drop Target View

/// A wrapper view for sidebar items that provides drop target styling.
///
/// Use this for items in the sidebar that should accept drops.
public struct SidebarDropTargetView<Content: View>: View {

    let target: DropTarget
    @ObservedObject var coordinator: DragDropCoordinator
    let content: () -> Content

    @State private var isTargeted = false

    public init(
        target: DropTarget,
        coordinator: DragDropCoordinator,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.target = target
        self.coordinator = coordinator
        self.content = content
    }

    public var body: some View {
        HStack(spacing: 0) {
            content()

            Spacer()

            // Badge when targeted
            if isTargeted {
                dropBadge
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isTargeted ? Color.accentColor.opacity(0.2) : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isTargeted ? Color.accentColor : .clear, lineWidth: 2)
        )
        .contentShape(Rectangle())
        .onDrop(of: DragDropCoordinator.acceptedTypes, isTargeted: $isTargeted) { providers in
            let info = DragDropInfo(providers: providers)
            Task {
                await coordinator.performDrop(info, target: target)
            }
            return true
        }
        .animation(.easeInOut(duration: 0.15), value: isTargeted)
    }

    @ViewBuilder
    private var dropBadge: some View {
        if coordinator.isProcessing {
            ProgressView()
                .scaleEffect(0.5)
        } else {
            Image(systemName: "plus.circle.fill")
                .foregroundStyle(.green)
                .font(.system(size: 14))
        }
    }
}
