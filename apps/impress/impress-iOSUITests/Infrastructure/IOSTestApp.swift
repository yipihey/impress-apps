//
//  IOSTestApp.swift
//  impress-iOSUITests
//
//  Launcher + anchors.
//
//  The seed flag alone, never `--ui-testing`: `--ui-testing` redirects
//  `RustStoreAdapter` to an in-memory database, while every reader impress-iOS
//  renders through (`MailStoreReader`, `FigureStoreReader`, `AgentStoreReader`)
//  opens the app group's `impress.sqlite` unconditionally. Passing both would
//  put the seeded rows and the store the app reads in two different places —
//  impart's finding, and it applies to three readers here instead of one.
//

import XCTest

enum IOSTestApp {
    static let seedArg = "--uitesting-seed"

    @discardableResult
    static func launchSeeded() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [seedArg]
        app.launch()
        return app
    }
}

/// Identifiers this suite addresses, mirrored locally rather than imported: the
/// runner must not link PublicationManagerCore (and its Rust xcframeworks) for
/// a handful of string constants.
enum ImpressA11y {
    // `sidebar.section.<SidebarSectionType.rawValue>`
    static let mailSection = "sidebar.section.mail"
    static let figuresSection = "sidebar.section.figures"
    static let agentsSection = "sidebar.section.agents"
    static let inboxSection = "sidebar.section.inbox"
    static let librariesSection = "sidebar.section.libraries"
    static let manuscriptsSection = "sidebar.section.manuscripts"
    static let flaggedSection = "sidebar.section.flagged"
    static let citedSection = "sidebar.section.citedInManuscripts"
    static let dismissedSection = "sidebar.section.dismissed"

    /// Sections the preset PERMITS but this host declares it cannot present.
    /// They must be ABSENT, not empty — that is the whole contract this suite
    /// exists to pin. It SHRANK in I2: `.inbox`, `.libraries`, `.manuscripts`,
    /// `.flagged` and `.dismissed` moved out of this list and into the visible
    /// set when the chassis grew the public iOS publication pane and the
    /// read-only manuscript pane. What is left is two kinds of absence, kept
    /// apart on purpose because they fail for different reasons:
    ///
    ///   * KIND gate (`presentableKinds`) — `.artifacts` (`ArtifactDetailView`
    ///     is a macOS-only per-type switch). Nothing renders it on iOS.
    ///   * CONTENT gate (`sectionIsAvailable`) — the four below plus
    ///     `.reviewQueue`. Their KIND is presentable now; their ROWS have no
    ///     source in this host. See `ImpressSidebarBindings
    ///     .contentGatedSections`, which this list mirrors.
    static let declaredAbsentSections = [
        // Kind gate
        "sidebar.section.artifacts",
        // Content gate
        "sidebar.section.search",
        "sidebar.section.exploration",
        "sidebar.section.scixLibraries",
        "sidebar.section.sharedWithMe",
        "sidebar.section.reviewQueue",
    ]

    // `sidebar.node.<RecordSidebarScope.scopeKey>`
    static let allMessagesNode = "sidebar.node.message.all"
    static let allFiguresNode = "sidebar.node.figure.all"
    static let allTasksNode = "sidebar.node.task.all"
    static let allManuscriptsNode = "sidebar.node.manuscript.all"
    static let inboxNode = "sidebar.node.section.inbox.publication"
    static let citedNode = "sidebar.node.section.citedInManuscripts.publication"
    static let dismissedNode = "sidebar.node.section.dismissed.publication"
    static let redFlaggedPapersNode = "sidebar.node.publication.flagged.red"
    /// Library rows carry the library's UUID, which the seed does not choose
    /// (`createLibrary` does), so this is a PREFIX match — imbib's suite
    /// anchors the same way for the same reason.
    static let libraryNodePrefix = "sidebar.node.host.publication.library."

    static let messageList = "messageList"
    static let figureList = "figureList"
    static let taskList = "taskList"
    static let publicationList = "publicationList"
    static let manuscriptList = "manuscriptList"
    static let messageDetail = "messageDetail"
    static let figureDetail = "figureDetail"
    static let taskDetail = "taskDetail"
    static let publicationDetail = "publicationDetail"
    static let manuscriptDetail = "manuscriptDetail"

    /// The lifted pane's tabs, which come from
    /// `PublicationRecordKind.descriptor.availableTabs`.
    enum DetailTabs {
        static let info = "detail.tabs.info"
        static let pdf = "detail.tabs.pdf"
        static let notes = "detail.tabs.notes"
        static let bibtex = "detail.tabs.bibtex"
        static let source = "detail.tabs.source"
    }

    static let openInImprintButton = "manuscript.openInImprint"

    static let settingsButton = "toolbar.settings"
    static let settingsContainer = "settings.container"
    static let settingsAppearanceRow = "settings.tabs.appearance"
    /// `.automation` is `.macOSOnly(requiring: [.httpAutomation])` — iOS never
    /// grants the capability, so the row must not render.
    static let settingsMacOnlyRows = ["settings.tabs.automation"]
}

/// Fixture facts, so a test never spells a seed string twice.
/// Mirrors `ImpressIOSUITestSeed`.
enum ImpressSeed {
    static let accountName = "Ada Lovelace"
    static let starredSubject = "Note G, revised"
    static let figureTitle = "Bernoulli convergence"
    static let taskTitle = "Recompute the Bernoulli table"
    static let libraryName = "Engine Papers"
    static let collectionName = "Note G"
    static let publicationTitleFragment = "Notes on the Analytical Engine"
    static let manuscriptTitle = "On the Note G Correction"
}
