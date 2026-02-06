//
//  SidebarSection.swift
//  ImpressSidebar
//
//  Protocol for sidebar section enums used with shared drag-reorder and header components.
//

import Foundation

/// Protocol for sidebar section enums used with shared drag-reorder and header components.
///
/// Each impress app defines its own enum conforming to this protocol:
/// ```swift
/// enum MySidebarSection: String, CaseIterable, Hashable, Codable, Sendable {
///     case inbox, library, search
///     var displayName: String { ... }
///     var icon: String { ... }
/// }
/// extension MySidebarSection: SidebarSection {}
/// ```
///
/// The protocol unifies the contract that `DraggableSectionHeader`, `SectionDragReorder`,
/// and `SidebarSectionPersistence` depend on.
public protocol SidebarSection: RawRepresentable, CaseIterable, Hashable, Codable, Sendable
    where RawValue == String
{
    /// Human-readable name for display in section headers.
    var displayName: String { get }

    /// SF Symbol name for the section icon.
    var icon: String { get }
}
