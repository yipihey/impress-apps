//
//  IOSTestApp.swift
//  impart-iOSUITests
//
//  Launcher + anchors for impart's first iOS UI tests (Stage 5c).
//
//  The launch flags differ from imbib's on purpose. imbib passes
//  `["--ui-testing", "--uitesting-seed"]` because `--ui-testing` redirects its
//  store facade to an in-memory database, which is what makes its run hermetic.
//  impart's mail READER (`MailStoreReader`) has no such redirect — it always
//  opens the app group's `impress.sqlite` — so `--ui-testing` would put the
//  seeded rows and the store the app reads in two different places. impart
//  therefore passes the SEED flag alone, and the seed writes the simulator's real
//  app-group store (see `ImpartIOSUITestSeed`'s header).
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

/// The identifiers this suite addresses, mirrored locally rather than imported:
/// the runner must not link PublicationManagerCore (and its Rust xcframework)
/// for four string constants.
enum ImpartA11y {
    /// `sidebar.section.<SidebarSectionType.rawValue>` — emitted by
    /// `RecordSidebarView`'s section header.
    static let mailSection = "sidebar.section.mail"
    /// `sidebar.node.<RecordSidebarScope.scopeKey>`. All Inboxes is
    /// `.all(.message)`, whose scopeKey is `"<kind>.all"`.
    static let allInboxesNode = "sidebar.node.message.all"
    /// Host-scope account rows and `.folder(.message, id)` rows carry ids that
    /// embed a store UUID, so tests match them by PREFIX.
    static let accountNodePrefix = "sidebar.node.host.message.mail.account."
    static let folderNodePrefix = "sidebar.node.message.folder."

    static let messageList = "messageList"
    static let messageRowPrefix = "messageRow."
    static let messageDetail = "messageDetail"

    static let settingsButton = "toolbar.settings"
    static let settingsDone = "settings.done"
    static let settingsContainer = "settings.container"
    /// `settings.tabs.<SettingsSectionID.rawValue>` — the SAME identifier the
    /// macOS tab carries.
    static let settingsGeneralRow = "settings.tabs.general"
    static let settingsAccountsRow = "settings.tabs.accounts"
    /// Rows that must NOT be on iOS: their sections are `.macOSOnly()`.
    static let settingsMacOnlyRows = [
        "settings.tabs.ai", "settings.tabs.keyboard",
        "settings.tabs.automation", "settings.tabs.spotlight",
    ]
}

/// Fixture facts, so a test never spells a seed string twice.
enum ImpartSeed {
    static let accountName = "Ada Lovelace"
    static let inboxFolder = "INBOX"
    static let customFolder = "Newsletters"
    static let starredSubject = "The Bernoulli number table"
    static let threadSubjectFragment = "Analytical Engine"
    static let threadMemberCount = 3
}
