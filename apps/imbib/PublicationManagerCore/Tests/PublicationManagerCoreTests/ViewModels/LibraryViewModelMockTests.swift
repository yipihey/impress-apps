//
//  LibraryViewModelMockTests.swift
//  PublicationManagerCoreTests
//
//  Tests for LibraryViewModel using MockPublicationStore and Swift Testing.
//

import Testing
import Foundation
@testable import PublicationManagerCore

@MainActor
@Suite("LibraryViewModel with Mock Store")
struct LibraryViewModelMockTests {

    // MARK: - Initial State

    @Test("Initial state is empty and not loading")
    func initialState() {
        let store = MockPublicationStore()
        let vm = LibraryViewModel(store: store)

        #expect(vm.publicationRows.isEmpty)
        #expect(vm.papers.isEmpty)
        #expect(!vm.isLoading)
        #expect(vm.error == nil)
        #expect(vm.searchQuery == "")
        #expect(vm.sortOrder == .dateAdded)
        #expect(!vm.sortAscending)
        #expect(vm.selectedPublications.isEmpty)
    }

    // MARK: - Loading Publications

    @Test("loadPublications fetches from mock store")
    func loadPublications() async {
        let store = MockPublicationStore()
        let lib = store.seedLibrary(name: "Test", isDefault: true)
        store.seedPublication(in: lib.id, title: "Paper A", year: 2020)
        store.seedPublication(in: lib.id, title: "Paper B", year: 2023)
        store.seedPublication(in: lib.id, title: "Paper C", year: 2021)

        let vm = LibraryViewModel(libraryID: lib.id, store: store)
        await vm.loadPublications()

        #expect(vm.publicationRows.count == 3)
        #expect(!vm.isLoading)
    }

    @Test("loadPublications respects sort order")
    func loadPublicationsSorted() async {
        let store = MockPublicationStore()
        let lib = store.seedLibrary(name: "Test")
        store.seedPublication(in: lib.id, title: "Alpha Paper", year: 2020)
        store.seedPublication(in: lib.id, title: "Beta Paper", year: 2023)
        store.seedPublication(in: lib.id, title: "Gamma Paper", year: 2021)

        let vm = LibraryViewModel(libraryID: lib.id, store: store)
        vm.sortOrder = .title
        vm.sortAscending = true

        // Wait for the Task triggered by sortOrder didSet
        try? await Task.sleep(for: .milliseconds(100))

        let titles = vm.publicationRows.map(\.title)
        #expect(titles == ["Alpha Paper", "Beta Paper", "Gamma Paper"])
    }

    // MARK: - Selection

    @Test("toggleSelection adds and removes")
    func toggleSelection() {
        let store = MockPublicationStore()
        let vm = LibraryViewModel(store: store)
        let id = UUID()

        vm.toggleSelection(id: id)
        #expect(vm.selectedPublications.contains(id))

        vm.toggleSelection(id: id)
        #expect(!vm.selectedPublications.contains(id))
    }

    @Test("selectAll selects all loaded publications")
    func selectAll() async {
        let store = MockPublicationStore()
        let lib = store.seedLibrary(name: "Test")
        let p1 = store.seedPublication(in: lib.id, title: "Paper 1")
        let p2 = store.seedPublication(in: lib.id, title: "Paper 2")

        let vm = LibraryViewModel(libraryID: lib.id, store: store)
        await vm.loadPublications()

        vm.selectAll()

        #expect(vm.selectedPublications.count == 2)
        #expect(vm.selectedPublications.contains(p1.id))
        #expect(vm.selectedPublications.contains(p2.id))
    }

    @Test("clearSelection empties set")
    func clearSelection() {
        let store = MockPublicationStore()
        let vm = LibraryViewModel(store: store)

        vm.selectedPublications = [UUID(), UUID(), UUID()]
        vm.clearSelection()

        #expect(vm.selectedPublications.isEmpty)
    }

    // MARK: - Lookup

    @Test("publication(for:) returns row data by ID")
    func publicationLookup() async {
        let store = MockPublicationStore()
        let lib = store.seedLibrary(name: "Test")
        let paper = store.seedPublication(in: lib.id, title: "Lookup Target")

        let vm = LibraryViewModel(libraryID: lib.id, store: store)
        await vm.loadPublications()

        let found = vm.publication(for: paper.id)
        #expect(found?.title == "Lookup Target")
    }

    @Test("publication(for:) falls back to store for unknown ID")
    func publicationLookupFallback() {
        let store = MockPublicationStore()
        let lib = store.seedLibrary(name: "Test")
        let paper = store.seedPublication(in: lib.id, title: "Not Loaded")

        let vm = LibraryViewModel(libraryID: UUID(), store: store) // Different library
        let found = vm.publication(for: paper.id)
        #expect(found?.title == "Not Loaded")
    }

    // MARK: - Search

    @Test("searchQuery filters publications")
    func searchQueryFilters() async {
        let store = MockPublicationStore()
        let lib = store.seedLibrary(name: "Test")
        store.seedPublication(in: lib.id, title: "Dark Matter Detection")
        store.seedPublication(in: lib.id, title: "Exoplanet Discovery")
        store.seedPublication(in: lib.id, title: "Dark Energy Survey")

        let vm = LibraryViewModel(libraryID: lib.id, store: store)
        await vm.loadPublications()

        vm.searchQuery = "Dark"

        // Wait for search Task
        try? await Task.sleep(for: .milliseconds(100))

        #expect(vm.publicationRows.count == 2)
        #expect(vm.publicationRows.allSatisfy { $0.title.contains("Dark") })
    }

    @Test("Clearing search restores all publications")
    func clearSearchRestoresAll() async {
        let store = MockPublicationStore()
        let lib = store.seedLibrary(name: "Test")
        store.seedPublication(in: lib.id, title: "Paper A")
        store.seedPublication(in: lib.id, title: "Paper B")

        let vm = LibraryViewModel(libraryID: lib.id, store: store)
        await vm.loadPublications()

        vm.searchQuery = "Paper A"
        try? await Task.sleep(for: .milliseconds(100))
        #expect(vm.publicationRows.count == 1)

        vm.searchQuery = ""
        try? await Task.sleep(for: .milliseconds(100))
        #expect(vm.publicationRows.count == 2)
    }

    // MARK: - Import

    @Test("importBibTeX imports entries and reloads")
    func importBibTeX() async throws {
        let store = MockPublicationStore()
        let lib = store.seedLibrary(name: "Test")

        let vm = LibraryViewModel(libraryID: lib.id, store: store)

        let bibtex = """
        @article{Test2024,
            author = {Test Author},
            title = {Test Paper},
            year = {2024}
        }
        """

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test.bib")
        try bibtex.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let count = try await vm.importBibTeX(from: url)

        #expect(count == 1)
        #expect(store.importBibTeXCallCount == 1)
        #expect(vm.publicationRows.count == 1)
    }

    // MARK: - Delete

    @Test("deleteSelected removes selected publications")
    func deleteSelected() async {
        let store = MockPublicationStore()
        let lib = store.seedLibrary(name: "Test")
        let p1 = store.seedPublication(in: lib.id, title: "Keep")
        let p2 = store.seedPublication(in: lib.id, title: "Delete")

        let vm = LibraryViewModel(libraryID: lib.id, store: store)
        await vm.loadPublications()
        vm.selectedPublications = [p2.id]

        await vm.deleteSelected()

        #expect(vm.selectedPublications.isEmpty)
        #expect(store.deletePublicationsCallCount == 1)
        #expect(vm.publicationRows.count == 1)
        #expect(vm.publicationRows.first?.title == "Keep")
    }

    // MARK: - Read Status

    @Test("markAsRead updates read status via store")
    func markAsRead() async {
        let store = MockPublicationStore()
        let lib = store.seedLibrary(name: "Test")
        let paper = store.seedPublication(in: lib.id, title: "Unread", isRead: false)

        let vm = LibraryViewModel(libraryID: lib.id, store: store)
        await vm.markAsRead(id: paper.id)

        #expect(store.setReadCallCount == 1)
        let updated = store.publications[paper.id]
        #expect(updated?.isRead == true)
    }

    @Test("unreadCount returns count of unread papers")
    func unreadCount() {
        let store = MockPublicationStore()
        let lib = store.seedLibrary(name: "Test")
        store.seedPublication(in: lib.id, title: "Read", isRead: true)
        store.seedPublication(in: lib.id, title: "Unread 1", isRead: false)
        store.seedPublication(in: lib.id, title: "Unread 2", isRead: false)

        let vm = LibraryViewModel(libraryID: lib.id, store: store)
        #expect(vm.unreadCount() == 2)
    }

    // MARK: - Export

    @Test("exportAll returns BibTeX for all publications in library")
    func exportAll() async {
        let store = MockPublicationStore()
        let lib = store.seedLibrary(name: "Test")
        store.seedPublication(in: lib.id, title: "Paper 1")
        store.seedPublication(in: lib.id, title: "Paper 2")

        let vm = LibraryViewModel(libraryID: lib.id, store: store)
        let result = vm.exportAll()

        #expect(result.contains("@article"))
        #expect(!result.isEmpty)
    }

    @Test("exportSelected returns BibTeX only for selected")
    func exportSelected() async {
        let store = MockPublicationStore()
        let lib = store.seedLibrary(name: "Test")
        let p1 = store.seedPublication(in: lib.id, title: "Selected Paper")
        store.seedPublication(in: lib.id, title: "Other Paper")

        let vm = LibraryViewModel(libraryID: lib.id, store: store)
        vm.selectedPublications = [p1.id]

        let result = vm.exportSelected()
        #expect(result.contains("Selected Paper"))
    }

    // MARK: - Collection Operations

    @Test("addToCollection delegates to store")
    func addToCollection() {
        let store = MockPublicationStore()
        let lib = store.seedLibrary(name: "Test")
        let p1 = store.seedPublication(in: lib.id, title: "Paper")
        let col = store.createCollection(name: "My Collection", libraryId: lib.id)!

        let vm = LibraryViewModel(libraryID: lib.id, store: store)
        vm.addToCollection([p1.id], collectionId: col.id)

        let members = store.collectionMembers[col.id] ?? []
        #expect(members.contains(p1.id))
    }

    @Test("movePublications moves to target library")
    func movePublications() {
        let store = MockPublicationStore()
        let lib1 = store.seedLibrary(name: "Source")
        let lib2 = store.seedLibrary(name: "Target")
        let paper = store.seedPublication(in: lib1.id, title: "Moving Paper")

        let vm = LibraryViewModel(libraryID: lib1.id, store: store)
        vm.addToLibrary([paper.id], libraryId: lib2.id)

        #expect(store.movePublicationsCallCount == 1)
        #expect(store.libraryPublications[lib2.id]?.contains(paper.id) == true)
    }
}
