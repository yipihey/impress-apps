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

    /// Sections the preset PERMITS but this host declares it cannot present
    /// (`presentableKinds`). They must be ABSENT, not empty — that is the whole
    /// contract this suite exists to pin.
    static let declaredAbsentSections = [
        "sidebar.section.inbox",
        "sidebar.section.libraries",
        "sidebar.section.manuscripts",
        "sidebar.section.artifacts",
        "sidebar.section.flagged",
        "sidebar.section.dismissed",
        "sidebar.section.search",
        "sidebar.section.reviewQueue",
    ]

    // `sidebar.node.<RecordSidebarScope.scopeKey>`
    static let allMessagesNode = "sidebar.node.message.all"
    static let allFiguresNode = "sidebar.node.figure.all"
    static let allTasksNode = "sidebar.node.task.all"

    static let messageList = "messageList"
    static let figureList = "figureList"
    static let taskList = "taskList"
    static let messageDetail = "messageDetail"
    static let figureDetail = "figureDetail"
    static let taskDetail = "taskDetail"

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
}
