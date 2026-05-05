//
//  ImprintSidebarSections.swift
//  imprint
//
//  Sidebar section definitions, persistence, UTTypes, and Transferable drag items.
//

import Foundation
import SwiftUI
import UniformTypeIdentifiers
import ImpressSidebar

// MARK: - Section Enum

public enum ImprintSidebarSection: String, CaseIterable, Hashable, Codable, Sendable, SidebarSection {
    case workspace = "workspace"
    case recentDocuments = "recentDocuments"

    public var displayName: String {
        switch self {
        case .workspace: return "Projects"
        case .recentDocuments: return "Recent Documents"
        }
    }

    public var icon: String {
        switch self {
        case .workspace: return "folder"
        case .recentDocuments: return "clock"
        }
    }
}

// MARK: - Section Stores

extension ImprintSidebarSection {
    /// Persisted section ordering
    static let orderStore = SidebarSectionOrderStore<ImprintSidebarSection>(
        key: "imprint.sidebar.sectionOrder",
        defaultOrder: ImprintSidebarSection.allCases
    )

    /// Persisted collapse state
    static let collapsedStore = SidebarCollapsedStateStore<ImprintSidebarSection>(
        key: "imprint.sidebar.collapsedSections"
    )
}

// MARK: - Custom UTTypes for Drag-and-Drop

extension UTType {
    /// UTType for dragging folder IDs within the sidebar
    static let imprintFolderID = UTType(exportedAs: "com.imbib.imprint.folder-id")

    /// UTType for dragging sidebar section headers
    static let imprintSidebarSectionID = UTType(exportedAs: "com.imbib.imprint.sidebar-section-id")

    /// UTType for dragging document references between folders
    static let imprintDocRefID = UTType(exportedAs: "com.imbib.imprint.doc-ref-id")
}

// MARK: - Folder Drag Item

struct FolderDragItem: Transferable {
    let id: UUID

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(contentType: .imprintFolderID) { item in
            item.id.uuidString.data(using: .utf8) ?? Data()
        } importing: { data in
            guard let string = String(data: data, encoding: .utf8),
                  let uuid = UUID(uuidString: string) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return FolderDragItem(id: uuid)
        }
    }
}

// MARK: - Document Reference Drag Item

/// Payload dropped on a folder to move the corresponding
/// `CDDocumentReference` into that folder.
///
/// The drag carries two pieces of state:
/// - The UTI `com.imbib.imprint.doc-ref-id` on NSPasteboard, so NSOutlineView
///   recognizes it as an accepted external drop.
/// - The UUID in the in-process `DocRefDragSession` singleton, which the
///   drop handler reads as the source of truth.
///
/// Why the extra store: SwiftUI's `.draggable(Transferable)` on macOS uses
/// `NSItemProvider`'s lazy data mechanism even when the Transferable declares
/// a `DataRepresentation`. Reading that data from the NSPasteboard inside an
/// NSOutlineView drop handler returns nil — the data would only be
/// retrievable via an async `loadDataRepresentation` call that the
/// synchronous NSOutlineView drop handler can't await. The session singleton
/// sidesteps the whole NSItemProvider/NSPasteboard interop rough edge.
struct DocRefDragItem: Transferable {
    let id: UUID

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(contentType: .imprintDocRefID) { item in
            // When SwiftUI asks us to serialize for the pasteboard, pin the
            // id into the drag session — the drop handler reads it from
            // there because NSPasteboard can't hand us this data back on macOS.
            DocRefDragSession.shared.begin(refID: item.id)
            return item.id.uuidString.data(using: .utf8) ?? Data()
        } importing: { data in
            guard let string = String(data: data, encoding: .utf8),
                  let uuid = UUID(uuidString: string) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return DocRefDragItem(id: uuid)
        }
    }
}

/// Tracks which CDDocumentReference is currently being dragged, as a
/// workaround for macOS's lazy-NSItemProvider pasteboard mechanics. See
/// `DocRefDragItem` docs for rationale.
///
/// Not `@MainActor` — the Transferable's DataRepresentation closure runs
/// on arbitrary threads. A lock synchronizes the tiny state.
final class DocRefDragSession: @unchecked Sendable {
    static let shared = DocRefDragSession()
    private init() {}

    private let lock = NSLock()
    private var _activeRefID: UUID?
    private var _beganAt: Date?

    /// The id of the ref currently being dragged, or nil if no drag is active.
    /// Safe for read-only checks (e.g. "do we need to call `begin` again?").
    var activeRefID: UUID? {
        lock.lock(); defer { lock.unlock() }
        return _activeRefID
    }

    /// Record the start of a drag for the given ref id.
    func begin(refID: UUID) {
        lock.lock(); defer { lock.unlock() }
        _activeRefID = refID
        _beganAt = Date()
    }

    /// Consume the stored id and clear the session. Returns nil if nothing
    /// is pinned or the pin is older than `maxAgeSeconds` (stale/aborted drag).
    func consume(maxAgeSeconds: TimeInterval = 30) -> UUID? {
        lock.lock(); defer { lock.unlock() }
        defer {
            _activeRefID = nil
            _beganAt = nil
        }
        guard let id = _activeRefID, let began = _beganAt else { return nil }
        if Date().timeIntervalSince(began) > maxAgeSeconds { return nil }
        return id
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        _activeRefID = nil
        _beganAt = nil
    }
}

// MARK: - Section Drag Item

struct SectionDragItem: Transferable {
    let type: ImprintSidebarSection

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(contentType: .imprintSidebarSectionID) { item in
            SectionDragReorder.encode(item.type)
        } importing: { data in
            guard let type = SectionDragReorder.decode(data, as: ImprintSidebarSection.self) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return SectionDragItem(type: type)
        }
    }
}
