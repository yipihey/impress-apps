//
//  ImprintIOSApp.swift
//  imprint-iOS
//
//  Created by Claude on 2026-01-27.
//

import SwiftUI
import ImprintCore
import PublicationManagerCore

// MARK: - imprint iOS App

@main
struct ImprintIOSApp: App {

    // MARK: - Properties

    /// State for handling incoming URLs
    @State private var pendingURL: URL?

    init() {
        // Citation seam. WITHOUT THIS, `ManuscriptCompileController`
        // .assembleBibliography finds no `citationSearch` and returns nil, so
        // the virtual `bibliography.bib` is never written — every real
        // manuscript with `@citeKey` references fails to compile on iOS while
        // compiling fine on macOS. macOS installs its own provider from
        // `macOS/ManuscriptEditorInstall.swift`, and imbib-iOS installs this
        // very service; imprint-iOS installed nothing, because imprint's
        // startup wiring lives in files the iOS target does not compile
        // (`Shared/ImprintApp.swift` is `#if os(macOS)` end to end).
        //
        // The same seam backs the citation picker's search.
        ManuscriptEditorEnvironment.shared.citationSearch = ImbibCitationSearchService.shared

        Self.seedUITestDataIfNeeded()
    }

    // MARK: - UI test fixtures

    /// Seed a manuscript that cites a paper, and the paper it cites.
    ///
    /// `--ui-testing` puts BOTH adapters on in-memory stores, so a UI test that
    /// merely launches the app finds an empty library and every citation lookup
    /// misses — `LibraryShellUITests` skips half its assertions for exactly this
    /// reason. Seeding here (the pattern imbib-iOS already uses in
    /// `imbibApp.seedUITestDataIfNeeded`) makes a citation test hermetic instead
    /// of dependent on whatever is on the developer's simulator.
    ///
    /// Both stores must be seeded: `ImbibCitationSearchService` (which resolves
    /// cite keys) reads `RustStoreAdapter`'s handle, while the manuscript list
    /// and the citation picker read `ManuscriptStoreAdapter`'s — under
    /// `--ui-testing` those are two separate in-memory databases.
    @MainActor
    static func seedUITestDataIfNeeded() {
        guard UITestingEnvironment.isUITesting,
              UITestingEnvironment.shouldSeedTestData else { return }

        let library = RustStoreAdapter.shared.listLibraries().first
            ?? RustStoreAdapter.shared.createLibrary(name: "Test Library")
        if let library {
            RustStoreAdapter.shared.setLibraryDefault(id: library.id)
            // Rust owns BibTeX parsing; never hand-build publication rows.
            _ = RustStoreAdapter.shared.importBibTeX(Self.seedBibTeX, libraryId: library.id)
        }

        try? ManuscriptStoreAdapter.shared.createManuscript(
            title: "Citation Long Press Fixture",
            format: .typst,
            body: Self.seedManuscriptBody,
            authors: ["Test Author"]
        )
    }

    /// One resolvable key (`Einstein1905`) — long-pressing it must show the
    /// paper — and one that is deliberately absent (`Missing2099`), so the
    /// unresolved-citation copy is testable too.
    private static let seedBibTeX = """
    @article{Einstein1905,
      author = {Albert Einstein},
      title = {Zur Elektrodynamik bewegter Körper},
      journal = {Annalen der Physik},
      volume = {322},
      pages = {891--921},
      year = {1905},
      doi = {10.1002/andp.19053221004},
      abstract = {That light is always propagated in empty space with a definite
      velocity c which is independent of the state of motion of the emitting body.}
    }
    """

    /// The citations lead each line on purpose: a UI test long-presses at a
    /// point offset from the text view's origin, and a token at a predictable
    /// column is the difference between testing the gesture and testing the
    /// text layout engine.
    private static let seedManuscriptBody = """
    @Einstein1905 introduces the two postulates of special relativity.

    @Missing2099 is a cite key that is deliberately absent from the library.

    = Special Relativity
    """

    // MARK: - Body

    var body: some Scene {
        // Store-backed manuscripts app (GUI-meld Phase 8): a manuscript
        // library fronts the editor rather than the system document browser,
        // so imprint-iOS reads/writes the same unified store as imbib and
        // macOS imprint. URL handling + outline-snapshot upkeep live inside
        // the library view.
        WindowGroup {
            // `WindowGroup` does not populate `\.undoManager` on iOS the way
            // `DocumentGroup` did — see IOSUndoSupport.swift. This restores
            // both the environment value and the responder-chain manager that
            // shake-to-undo needs.
            IOSManuscriptLibraryView()
                .undoEnabled()
        }
    }
}

// MARK: - Configuration

extension ImprintIOSApp {
    /// Configure app-wide keyboard shortcuts
    /// Note: Keyboard shortcuts are handled by SwiftUI's .keyboardShortcut() modifier
    static func configureKeyboardShortcuts() {
        // No additional configuration needed - shortcuts are declarative in SwiftUI
    }
}
