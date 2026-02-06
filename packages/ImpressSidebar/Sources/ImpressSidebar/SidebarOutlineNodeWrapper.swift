//
//  SidebarOutlineNodeWrapper.swift
//  ImpressSidebar
//
//  NSObject wrapper for tree node UUIDs, used as NSOutlineView item objects.
//  Provides stable identity via isEqual/hash for efficient outline view updates.
//

#if os(macOS)
import Foundation

/// Wrapper object used as NSOutlineView's `item` parameter.
///
/// NSOutlineView requires `NSObject` items with stable identity. This wrapper
/// holds a UUID and overrides `isEqual`/`hash` so that outline view can match
/// items across reloads.
public final class SidebarOutlineNodeWrapper: NSObject {
    public let id: UUID

    public init(id: UUID) {
        self.id = id
        super.init()
    }

    public override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? SidebarOutlineNodeWrapper else { return false }
        return id == other.id
    }

    public override var hash: Int {
        id.hashValue
    }
}
#endif
