//
//  HelpBrowserViewModel.swift
//  PublicationManagerCore
//
//  View model for the help browser navigation.
//

import Foundation
import SwiftUI
import OSLog

private let logger = Logger(subsystem: "com.imbib.help", category: "browser")

/// View model for managing help browser state.
@MainActor
@Observable
public final class HelpBrowserViewModel {

    // MARK: - Published State

    /// All documents grouped by category.
    public private(set) var documentsByCategory: [HelpCategory: [HelpDocument]] = [:]

    /// Currently selected document ID.
    public var selectedDocumentID: String?

    /// Content of the currently selected document.
    public private(set) var currentContent: String = ""

    /// Whether the index is loading.
    public private(set) var isLoading = false

    /// Expanded categories in the sidebar.
    public var expandedCategories: Set<HelpCategory> = Set(HelpCategory.allCases)

    /// Whether to show developer documentation.
    public var showDeveloperDocs: Bool = false

    // MARK: - Initialization

    public init() {}

    // MARK: - Loading

    /// Load the help index and organize documents by category.
    public func loadIndex() async {
        guard documentsByCategory.isEmpty else { return }

        isLoading = true
        defer { isLoading = false }

        let documents = await HelpIndexService.shared.allDocuments()

        // Group documents by category
        var grouped: [HelpCategory: [HelpDocument]] = [:]
        for document in documents {
            grouped[document.category, default: []].append(document)
        }

        // Sort documents within each category
        for category in grouped.keys {
            grouped[category]?.sort { $0.sortOrder < $1.sortOrder }
        }

        documentsByCategory = grouped
        logger.info("Loaded \(documents.count) help documents in \(grouped.count) categories")
    }

    /// Get the currently selected document.
    public var selectedDocument: HelpDocument? {
        guard let id = selectedDocumentID else { return nil }
        return documentsByCategory.values.flatMap { $0 }.first { $0.id == id }
    }

    /// Get visible categories based on showDeveloperDocs setting.
    public var visibleCategories: [HelpCategory] {
        HelpCategory.allCases
            .filter { showDeveloperDocs || !$0.isDeveloperCategory }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    /// Get visible documents for a category.
    public func visibleDocuments(for category: HelpCategory) -> [HelpDocument] {
        let docs = documentsByCategory[category] ?? []
        if showDeveloperDocs {
            return docs
        }
        return docs.filter { !$0.isDeveloperDoc }
    }

    // MARK: - Navigation

    /// Select a document and load its content.
    public func selectDocument(_ document: HelpDocument) {
        selectedDocumentID = document.id
        Task {
            currentContent = await HelpIndexService.shared.loadContent(for: document)
        }
    }

    /// Select a document by ID.
    public func selectDocument(id: String) {
        guard let document = documentsByCategory.values.flatMap({ $0 }).first(where: { $0.id == id }) else {
            logger.warning("Document not found: \(id)")
            return
        }
        selectDocument(document)
    }

    /// Clear the current selection.
    public func clearSelection() {
        selectedDocumentID = nil
        currentContent = ""
    }

    /// Navigate to the next document in the current category.
    public func selectNextDocument() {
        guard let current = selectedDocument,
              let docs = documentsByCategory[current.category],
              let currentIndex = docs.firstIndex(where: { $0.id == current.id }),
              currentIndex + 1 < docs.count else { return }

        selectDocument(docs[currentIndex + 1])
    }

    /// Navigate to the previous document in the current category.
    public func selectPreviousDocument() {
        guard let current = selectedDocument,
              let docs = documentsByCategory[current.category],
              let currentIndex = docs.firstIndex(where: { $0.id == current.id }),
              currentIndex > 0 else { return }

        selectDocument(docs[currentIndex - 1])
    }

    // MARK: - Category Toggle

    /// Toggle whether a category is expanded in the sidebar.
    public func toggleCategory(_ category: HelpCategory) {
        if expandedCategories.contains(category) {
            expandedCategories.remove(category)
        } else {
            expandedCategories.insert(category)
        }
    }

    /// Check if a category is expanded.
    public func isCategoryExpanded(_ category: HelpCategory) -> Bool {
        expandedCategories.contains(category)
    }
}
