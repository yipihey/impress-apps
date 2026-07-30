//
//  IOSAccessibility.swift
//  imbib-iOSUITests
//
//  Accessibility-identifier anchors used by the iOS UI tests.
//
//  These mirror the *public* constants in
//  `PublicationManagerCore/Accessibility/AccessibilityIdentifiers.swift`
//  (enum `AccessibilityID`). They are duplicated here — rather than importing
//  PublicationManagerCore into the UI-test bundle — so the test runner stays
//  lightweight and does not link the entire app core (and its Rust FFI
//  xcframework) into a separate test process. If the shared identifiers change,
//  update these to match; the tests will fail loudly if an anchor disappears.
//

import Foundation

enum IOSA11y {

    enum Sidebar {
        static let settingsButton = "sidebar.settingsButton"
        static let newLibraryButton = "sidebar.newLibraryButton"
    }

    enum Settings {
        // IOSSettingsView tab anchors.
        static let sourcesTab = "settings.tabs.sources"
        static let doneButton = "settings.doneButton"
    }

    enum Detail {
        enum Tabs {
            static let info = "detail.tabs.info"
        }
    }

    enum Dialog {
        enum Library {
            static let nameField = "dialog.library.nameField"
            static let cancelButton = "dialog.library.cancelButton"
            static let createButton = "dialog.library.createButton"
        }
    }
}

/// Well-known seed data (see `imbibApp.seedUITestDataIfNeeded`).
enum IOSSeed {
    static let libraryName = "Test Library"
    /// A distinctive fragment of the first seeded publication's title.
    static let firstPublicationTitleFragment = "Electrodynamics"
    /// The seeded root collection; it holds ONLY the first publication, so a
    /// scoped list can be told apart from the whole library.
    static let collectionName = "Relativity"
    /// The seeded nested child of `collectionName` — the tree, not just a row.
    static let nestedCollectionName = "Special"
    /// A fragment of the publication that is NOT filed in `collectionName`
    /// (and is the flagged one).
    static let unfiledPublicationTitleFragment = "Radial Velocity"
}
