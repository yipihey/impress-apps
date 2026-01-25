//
//  RustPublicationViewModel.swift
//  PublicationManagerCore
//
//  Example view model using Rust domain types via PublicationStore.
//  This demonstrates the pattern for gradually migrating to Rust types.
//

import Foundation
import ImbibRustCore

/// Example view model using Rust Publication types
///
/// This demonstrates how to use the new PublicationStore protocol
/// with Rust-generated domain types for future migrations.
@MainActor
@Observable
public final class RustPublicationViewModel {
    private let store: any PublicationStore

    public private(set) var publications: [Publication] = []
    public private(set) var isLoading = false
    public private(set) var error: Error?

    public init(store: any PublicationStore) {
        self.store = store
    }

    public func loadPublications(in library: String? = nil) async {
        isLoading = true
        defer { isLoading = false }

        do {
            publications = try await store.fetchAll(in: library)
            error = nil
        } catch {
            self.error = error
        }
    }

    public func search(query: String) async {
        isLoading = true
        defer { isLoading = false }

        do {
            publications = try await store.search(query: query)
            error = nil
        } catch {
            self.error = error
        }
    }

    /// Import publications from BibTeX or RIS content using Rust parser
    public func importPublications(from content: String) async throws {
        let result = try importAuto(content: content)

        if !result.errors.isEmpty {
            // Log errors but continue with successful imports
            for importError in result.errors {
                print("Import error: \(importError)")
            }
        }

        try await store.batchImport(result.publications)
        await loadPublications()
    }

    /// Export all publications to BibTeX format using Rust formatter
    public func exportBibtex() -> String {
        let options = defaultExportOptions()
        return exportBibtexMultiple(publications: publications, options: options)
    }

    /// Export all publications to RIS format
    public func exportRis() -> String {
        return exportRisMultiple(publications: publications)
    }

    /// Find duplicate publications using Rust deduplication
    public func findDuplicates(threshold: Double = 0.8) -> [DuplicateGroup] {
        return ImbibRustCore.findDuplicates(publications: publications, threshold: threshold)
    }

    /// Merge two publications using the specified strategy
    public func merge(
        local: Publication,
        remote: Publication,
        strategy: MergeStrategy
    ) -> ImbibRustCore.MergeResult {
        return mergePublications(local: local, remote: remote, strategy: strategy)
    }

    /// Generate a PDF filename for a publication
    public func pdfFilename(for publication: Publication) -> String {
        let options = defaultFilenameOptions()
        return ImbibRustCore.generatePdfFilename(publication: publication, options: options)
    }

    /// Validate a publication and get any issues
    public func validate(_ publication: Publication) -> [ValidationError] {
        return validatePublication(publication: publication)
    }
}
