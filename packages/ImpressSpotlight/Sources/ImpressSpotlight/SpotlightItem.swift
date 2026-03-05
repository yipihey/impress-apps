import CoreSpotlight
import Foundation

// MARK: - SpotlightItem Protocol

/// Any item that can be indexed in system Spotlight.
///
/// Each app provides lightweight structs conforming to this protocol
/// to describe how its domain objects appear in Spotlight results.
public protocol SpotlightItem: Sendable {
    /// The unique identifier for this item (must match the domain object's UUID).
    var spotlightID: UUID { get }

    /// The Spotlight domain identifier (e.g. "com.impress.paper").
    var spotlightDomain: String { get }

    /// The attribute set describing this item's metadata for Spotlight.
    var spotlightAttributeSet: CSSearchableItemAttributeSet { get }
}

// MARK: - SpotlightItemProvider Protocol

/// Provides items from an app's data layer for Spotlight indexing.
///
/// Each app creates a concrete type conforming to this protocol.
/// The `SpotlightSyncCoordinator` uses it to gather items for
/// initial rebuild and incremental updates.
public protocol SpotlightItemProvider: Sendable {
    /// The Spotlight domain this provider manages (e.g. "com.impress.paper").
    var domain: String { get }

    /// Returns all item IDs currently in the data store.
    func allItemIDs() async -> Set<UUID>

    /// Converts a batch of IDs into SpotlightItems for indexing.
    func spotlightItems(for ids: [UUID]) async -> [any SpotlightItem]
}

// MARK: - Domain Constants

/// Well-known Spotlight domain identifiers for impress apps.
public enum SpotlightDomain {
    public static let paper = "com.impress.paper"
    public static let document = "com.impress.document"
    public static let figure = "com.impress.figure"
    public static let conversation = "com.impress.conversation"
    public static let task = "com.impress.task"
}
