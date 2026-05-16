import Foundation

/// Singleton registry mapping document UUIDs to their live `VeuszPlotStore`.
///
/// The Plots panel creates a store per open document and registers it here so
/// the HTTP API / App Intents / MCP layer can resolve a plot operation back to
/// the store that owns it without holding a SwiftUI binding.
///
/// Lifecycle: ContentView calls `register(_:for:)` when the inspector becomes
/// available and `unregister(documentID:)` on document close. Strong references
/// — ContentView is responsible for the cleanup call (`.onDisappear`).
@MainActor
final class VeuszPlotStoreRegistry {

    static let shared = VeuszPlotStoreRegistry()

    private var stores: [UUID: VeuszPlotStore] = [:]

    private init() {}

    func register(_ store: VeuszPlotStore, for documentID: UUID) {
        stores[documentID] = store
    }

    func unregister(documentID: UUID) {
        stores.removeValue(forKey: documentID)
    }

    func store(forDocumentID documentID: UUID) -> VeuszPlotStore? {
        stores[documentID]
    }

    /// Every store currently tracked (used by intents like "list all Veusz plots").
    var allStores: [VeuszPlotStore] {
        Array(stores.values)
    }

    /// Look up the store that owns a given plot ID. O(open documents) — fine
    /// for the workloads we expect (a handful of docs at a time).
    func store(owningPlotID plotID: UUID) -> VeuszPlotStore? {
        stores.values.first { store in
            store.plots.contains(where: { $0.id == plotID })
        }
    }
}
