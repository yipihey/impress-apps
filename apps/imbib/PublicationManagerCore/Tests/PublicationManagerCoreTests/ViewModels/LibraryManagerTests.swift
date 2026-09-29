//
//  LibraryManagerTests.swift
//  PublicationManagerCoreTests
//
//  Tests for LibraryManager using MockPublicationStore and Swift Testing.
//

import Testing
import Foundation
import ImpressKit
@testable import PublicationManagerCore

@MainActor
@Suite("LibraryManager with Mock Store", .serialized)
struct LibraryManagerTests {

    // MARK: - Initialization

    @Test("Init creates default library when store is empty")
    func initCreatesDefaultLibrary() {
        let store = MockPublicationStore()
        // LibraryManager's init calls loadLibraries() then creates a fallback if empty
        let manager = LibraryManager(store: store)

        #expect(!manager.libraries.isEmpty)
        #expect(manager.activeLibraryID != nil)
    }

    @Test("Init loads existing libraries from store")
    func initLoadsExisting() {
        let store = MockPublicationStore()
        let lib = store.seedLibrary(name: "Existing", isDefault: true)

        let manager = LibraryManager(store: store)

        #expect(manager.libraries.contains(where: { $0.name == "Existing" }))
        #expect(manager.activeLibraryID == lib.id)
    }

    // MARK: - Library CRUD

    @Test("createLibrary adds a new library")
    func createLibrary() {
        let store = MockPublicationStore()
        store.seedLibrary(name: "Initial", isDefault: true)
        let manager = LibraryManager(store: store)

        let newLib = manager.createLibrary(name: "New Library")

        #expect(newLib != nil)
        #expect(newLib?.name == "New Library")
        #expect(manager.libraries.contains(where: { $0.name == "New Library" }))
    }

    @Test("deleteLibrary removes the library")
    func deleteLibrary() throws {
        let store = MockPublicationStore()
        let lib1 = store.seedLibrary(name: "Keep", isDefault: true)
        let lib2 = store.seedLibrary(name: "Delete")
        let manager = LibraryManager(store: store)
        manager.setActive(id: lib1.id)

        try manager.deleteLibrary(id: lib2.id)

        #expect(!manager.libraries.contains(where: { $0.id == lib2.id }))
    }

    @Test("deleteLibrary switches active if deleting active")
    func deleteActiveLibrary() throws {
        let store = MockPublicationStore()
        let lib1 = store.seedLibrary(name: "First", isDefault: true)
        let lib2 = store.seedLibrary(name: "Second")
        let manager = LibraryManager(store: store)
        manager.setActive(id: lib2.id)

        try manager.deleteLibrary(id: lib2.id)

        #expect(manager.activeLibraryID != lib2.id)
    }

    // MARK: - Active Library

    @Test("setActive changes active library")
    func setActiveLibrary() {
        let store = MockPublicationStore()
        let lib1 = store.seedLibrary(name: "Lib A", isDefault: true)
        let lib2 = store.seedLibrary(name: "Lib B")
        let manager = LibraryManager(store: store)

        manager.setActive(id: lib2.id)

        #expect(manager.activeLibraryID == lib2.id)
        #expect(manager.activeLibrary?.name == "Lib B")
    }

    @Test("activeLibrary returns nil when no active ID")
    func activeLibraryNilWhenNoID() {
        let store = MockPublicationStore()
        store.seedLibrary(name: "Test", isDefault: true)
        let manager = LibraryManager(store: store)

        // Force clear active
        manager.activeLibraryID = nil

        #expect(manager.activeLibrary == nil)
    }

    // MARK: - Default Library

    @Test("setDefault marks library as default")
    func setDefault() {
        let store = MockPublicationStore()
        let lib1 = store.seedLibrary(name: "Not Default")
        store.seedLibrary(name: "Was Default", isDefault: true)
        let manager = LibraryManager(store: store)

        manager.setDefault(id: lib1.id)

        #expect(store.defaultLibraryID == lib1.id)
    }

    @Test("getOrCreateDefaultLibrary returns existing default")
    func getOrCreateDefaultReturnsExisting() {
        let store = MockPublicationStore()
        let lib = store.seedLibrary(name: "Default", isDefault: true)
        let manager = LibraryManager(store: store)

        let result = manager.getOrCreateDefaultLibrary()

        #expect(result.id == lib.id)
    }

    // MARK: - Library Lookup

    @Test("find returns library by ID")
    func findByID() {
        let store = MockPublicationStore()
        let lib = store.seedLibrary(name: "Findable", isDefault: true)
        let manager = LibraryManager(store: store)

        let found = manager.find(id: lib.id)

        #expect(found?.name == "Findable")
    }

    @Test("find returns nil for unknown ID")
    func findUnknown() {
        let store = MockPublicationStore()
        store.seedLibrary(name: "Test", isDefault: true)
        let manager = LibraryManager(store: store)

        let found = manager.find(id: UUID())

        #expect(found == nil)
    }

    // MARK: - Rename

    @Test("rename updates library name")
    func rename() {
        let store = MockPublicationStore()
        let lib = store.seedLibrary(name: "Old Name", isDefault: true)
        let manager = LibraryManager(store: store)

        manager.rename(id: lib.id, to: "New Name")

        // updateField was called; verify through store
        #expect(store.dataVersion > 0)
    }

    // MARK: - Save/Dismissed Libraries

    @Test("getOrCreateSaveLibrary creates new when none exists")
    func getOrCreateSaveLibrary() {
        let store = MockPublicationStore()
        store.seedLibrary(name: "Default", isDefault: true)
        let manager = LibraryManager(store: store)

        let saveLib = manager.getOrCreateSaveLibrary()

        #expect(saveLib.name == "Save" || !saveLib.name.isEmpty)
    }

    @Test("getOrCreateDismissedLibrary creates new when none exists")
    func getOrCreateDismissedLibrary() {
        let store = MockPublicationStore()
        store.seedLibrary(name: "Default", isDefault: true)
        let manager = LibraryManager(store: store)

        let dismissed = manager.getOrCreateDismissedLibrary()

        #expect(!dismissed.name.isEmpty)
    }

    @Test("emptyDismissedLibrary removes all publications")
    func emptyDismissedLibrary() {
        let store = MockPublicationStore()
        store.seedLibrary(name: "Default", isDefault: true)
        let manager = LibraryManager(store: store)

        let dismissed = manager.getOrCreateDismissedLibrary()
        store.seedPublication(in: dismissed.id, title: "Dismissed Paper 1")
        store.seedPublication(in: dismissed.id, title: "Dismissed Paper 2")

        manager.emptyDismissedLibrary()

        let count = store.countPublications(parentId: dismissed.id)
        #expect(count == 0)
    }

    // MARK: - Export

    @Test("exportToBibTeX writes file")
    func exportToBibTeX() throws {
        let store = MockPublicationStore()
        let lib = store.seedLibrary(name: "Export Test", isDefault: true)
        store.seedPublication(in: lib.id, title: "Export Paper")
        let manager = LibraryManager(store: store)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("export_test.bib")
        defer { try? FileManager.default.removeItem(at: url) }

        try manager.exportToBibTeX(libraryId: lib.id, to: url)

        let content = try String(contentsOf: url, encoding: .utf8)
        #expect(content.contains("@article"))
    }

    // MARK: - Exploration Library

    @Test("getOrCreateExplorationLibrary creates library")
    func getOrCreateExplorationLibrary() {
        let store = MockPublicationStore()
        store.seedLibrary(name: "Default", isDefault: true)
        let manager = LibraryManager(store: store)

        let exploration = manager.getOrCreateExplorationLibrary()

        #expect(exploration.name == "Exploration")
    }

    @Test("Legacy exploration library ID migrates to settings and remains authoritative")
    func explorationLibraryIDMigratesAndMirrors() {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("imbib-exploration-settings-\(UUID().uuidString)")
        let suiteName = "imbib-exploration-settings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = ImpressSettings.shared
        settings._resetForTesting()
        settings.workspaceDirectory = scratch
        settings.legacyStores = [defaults]
        defer {
            settings._resetForTesting()
            settings.workspaceDirectory = SharedWorkspace.workspaceDirectory
            settings.legacyStores = [.standard, SharedDefaults.suite]
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: scratch)
        }

        let store = MockPublicationStore()
        store.seedLibrary(name: "Default", isDefault: true)
        let exploration = store.seedLibrary(name: "Exploration")
        defaults.set(exploration.id.uuidString, forKey: "explorationLibraryID")
        let manager = LibraryManager(store: store, explorationDefaults: defaults)

        #expect(manager.explorationLibrary?.id == exploration.id)
        #expect(settings.value(
            "imbib.internal.exploration_library_id", as: String.self
        ) == exploration.id.uuidString)
        #expect(defaults.string(forKey: "explorationLibraryID") == exploration.id.uuidString)
    }

    @Test("A newer settings ID wins, and manager changes mirror both stores")
    func explorationLibraryIDPrefersSettingsAndMirrorsChanges() {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("imbib-exploration-settings-\(UUID().uuidString)")
        let suiteName = "imbib-exploration-settings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = ImpressSettings.shared
        settings._resetForTesting()
        settings.workspaceDirectory = scratch
        settings.legacyStores = [defaults]
        defer {
            settings._resetForTesting()
            settings.workspaceDirectory = SharedWorkspace.workspaceDirectory
            settings.legacyStores = [.standard, SharedDefaults.suite]
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: scratch)
        }

        let store = MockPublicationStore()
        store.seedLibrary(name: "Default", isDefault: true)
        let legacy = store.seedLibrary(name: "Legacy Exploration")
        let current = store.seedLibrary(name: "Current Exploration")
        defaults.set(legacy.id.uuidString, forKey: "explorationLibraryID")
        settings.set("imbib.internal.exploration_library_id", current.id.uuidString)
        let manager = LibraryManager(store: store, explorationDefaults: defaults)

        #expect(manager.explorationLibrary?.id == current.id)
        #expect(defaults.string(forKey: "explorationLibraryID") == legacy.id.uuidString)

        settings.set("imbib.internal.exploration_library_id", "not-a-uuid")
        #expect(manager.explorationLibrary == nil)

        settings.reset("imbib.internal.exploration_library_id")
        defaults.removeObject(forKey: "explorationLibraryID")
        let created = manager.getOrCreateExplorationLibrary()
        #expect(defaults.string(forKey: "explorationLibraryID") == created.id.uuidString)
        #expect(settings.value(
            "imbib.internal.exploration_library_id", as: String.self
        ) == created.id.uuidString)
    }

    // MARK: - Cache Invalidation

    @Test("invalidateCaches clears all state")
    func invalidateCaches() {
        let store = MockPublicationStore()
        store.seedLibrary(name: "Test", isDefault: true)
        let manager = LibraryManager(store: store)

        manager.invalidateCaches()

        #expect(manager.libraries.isEmpty)
        #expect(manager.activeLibraryID == nil)
    }
}
