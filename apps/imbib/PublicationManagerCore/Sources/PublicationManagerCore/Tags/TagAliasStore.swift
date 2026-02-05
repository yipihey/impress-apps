//
//  TagAliasStore.swift
//  PublicationManagerCore
//

import Foundation

/// Persistent store for tag aliases — keyboard shortcuts that expand to full tag paths.
///
/// Example: alias `amr` → `methods/sims/hydro/AMR`
@MainActor
@Observable
public final class TagAliasStore {

    public static let shared = TagAliasStore()

    private static let defaultsKey = "com.imbib.tagAliases"

    /// Current alias → path mappings.
    public private(set) var aliases: [String: String] = [:]

    private init() {
        load()
        seedExampleIfNeeded()
    }

    /// Resolve an alias to its full tag path. Returns nil if no alias matches.
    public func resolve(_ input: String) -> String? {
        aliases[input.lowercased()]
    }

    /// Add or update an alias.
    public func add(alias: String, path: String) {
        let key = alias.lowercased().trimmingCharacters(in: .whitespaces)
        let value = path.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty && !value.isEmpty else { return }
        aliases[key] = value
        save()
    }

    /// Remove an alias.
    public func remove(alias: String) {
        aliases.removeValue(forKey: alias.lowercased())
        save()
    }

    /// All aliases sorted alphabetically by alias name.
    public var sortedAliases: [(alias: String, path: String)] {
        aliases.sorted { $0.key < $1.key }.map { (alias: $0.key, path: $0.value) }
    }

    // MARK: - Seeding

    /// Seed an example alias for first-time users. Only runs if UserDefaults
    /// has never been written for this key (so deleting all aliases won't re-seed).
    private func seedExampleIfNeeded() {
        guard aliases.isEmpty,
              UserDefaults.standard.object(forKey: Self.defaultsKey) == nil else { return }
        aliases["amr"] = "methods/hydro/amr"
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let dict = UserDefaults.standard.dictionary(forKey: Self.defaultsKey) as? [String: String] else {
            return
        }
        aliases = dict
    }

    private func save() {
        UserDefaults.standard.set(aliases, forKey: Self.defaultsKey)
    }
}
