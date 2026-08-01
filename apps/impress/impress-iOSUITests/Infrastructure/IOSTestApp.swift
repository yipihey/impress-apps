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
///
/// I3 GROUPED THEM ALL. impress's sidebar is now a `SidebarComposition`: one
/// collapsible group per sibling app, each rendering that app's OWN preset. So
/// every identifier below carries the app whose sidebar the row belongs to —
/// `sidebar.section.<app>.<section>`, `sidebar.node.<app>.<scopeKey>` — and
/// that is not decoration. The composed sidebar has TWO rows called Flagged
/// (imbib's, listing publications; imprint's, listing manuscripts) and renders
/// Cited in Manuscripts twice with the identical scope, so an unqualified
/// identifier resolves to whichever XCUITest reaches first. Qualifying it is
/// also what lets a test PROVE the user's report is closed: the assertion
/// "`sidebar.node.imprint.manuscript.flagged.red` exists" is precisely the row
/// the flat sidebar could not have.
///
/// The five sibling apps do NOT group; their suites keep the unqualified
/// identifiers and were untouched by this change.
enum ImpressA11y {

    // MARK: Groups — `sidebar.group.<appID>`

    static let imbibGroup = "sidebar.group.imbib"
    static let imprintGroup = "sidebar.group.imprint"
    static let imploreGroup = "sidebar.group.implore"
    static let impelGroup = "sidebar.group.impel"
    static let impartGroup = "sidebar.group.impart"

    /// Every group, in `SiblingApp.descriptors` order — the order
    /// `SidebarComposition.impress` derives from the one table.
    static let allGroups = [
        imbibGroup, imprintGroup, imploreGroup, impelGroup, impartGroup,
    ]

    /// The bare app ids, for asserting that no row escapes its group.
    static let appIDs = ["imbib", "imprint", "implore", "impel", "impart"]

    /// A disclosure header's accessibility VALUE — `RecordSidebarView
    /// .collapsedValue` / `.expandedValue`, mirrored here like every other
    /// anchor. It is the only reliable read of "is this group open": a lazy
    /// `List` publishes only the rows on screen, so "does it show any rows"
    /// answers `false` for an expanded group scrolled past.
    static let collapsed = "collapsed"
    static let expanded = "expanded"

    // MARK: Sections — `sidebar.section.<appID>.<SidebarSectionType.rawValue>`

    static let mailSection = "sidebar.section.impart.mail"
    static let figuresSection = "sidebar.section.implore.figures"
    static let agentsSection = "sidebar.section.impel.agents"
    static let inboxSection = "sidebar.section.imbib.inbox"
    static let librariesSection = "sidebar.section.imbib.libraries"
    static let manuscriptsSection = "sidebar.section.imprint.journal"
    static let imbibFlaggedSection = "sidebar.section.imbib.flagged"
    /// Tags is declared by every preset and BOUND PER APP — imbib's to
    /// `.publication`, impart's to `.message` — so the composed sidebar has
    /// five of them over five vocabularies, exactly like Flagged.
    static let imbibTagsSection = "sidebar.section.imbib.tags"
    static let impartTagsSection = "sidebar.section.impart.tags"
    static let imprintFlaggedSection = "sidebar.section.imprint.flagged"
    static let imbibDismissedSection = "sidebar.section.imbib.dismissed"
    static let imprintDismissedSection = "sidebar.section.imprint.dismissed"

    /// Sections a group's preset PERMITS but this host declares it cannot
    /// present. They must be ABSENT, not empty — that is the whole contract
    /// this suite exists to pin.
    ///
    /// All six belong to the IMBIB group, which is the composition's honest
    /// answer to "why is Search missing": Search is imbib's section, so its
    /// absence is a statement about impress-iOS's imbib group and nowhere else.
    /// Two kinds of absence, kept apart because they fail for different reasons:
    ///
    ///   * KIND gate (`presentableKinds`) — `.artifacts` (`ArtifactDetailView`
    ///     is a macOS-only per-type switch). Nothing renders it on iOS.
    ///   * CONTENT gate (`sectionIsAvailable`) — the five below. Their KIND is
    ///     presentable; their ROWS have no source in this host. See
    ///     `ImpressSidebarBindings.contentGatedSections`, which this mirrors.
    static let declaredAbsentSections = [
        // Kind gate
        "sidebar.section.imbib.artifacts",
        // Content gate
        "sidebar.section.imbib.search",
        "sidebar.section.imbib.exploration",
        "sidebar.section.imbib.scixLibraries",
        "sidebar.section.imbib.sharedWithMe",
        "sidebar.section.imbib.reviewQueue",
    ]

    // MARK: Nodes — `sidebar.node.<appID>.<RecordSidebarScope.scopeKey>`

    static let allMessagesNode = "sidebar.node.impart.message.all"
    static let allFiguresNode = "sidebar.node.implore.figure.all"
    static let allTasksNode = "sidebar.node.impel.task.all"
    static let allManuscriptsNode = "sidebar.node.imprint.manuscript.all"
    static let inboxNode = "sidebar.node.imbib.section.inbox.publication"
    static let dismissedNode = "sidebar.node.imbib.section.dismissed.publication"

    /// THE per-group Flagged pair — the two rows the flat sidebar collapsed
    /// into one. imbib's Flagged binds `.publication` (`AppShellConfiguration
    /// .imbib.sectionBindings`); imprint's binds `.manuscript`. Same section
    /// type, same colour, different kind, different list.
    static let redFlaggedPapersNode = "sidebar.node.imbib.publication.flagged.red"
    static let redFlaggedManuscriptsNode = "sidebar.node.imprint.manuscript.flagged.red"
    /// imprint dismisses by STATUS CHANGE where imbib dismisses by library
    /// move, so the two groups' Dismissed rows differ in scope shape as well as
    /// in kind — the semantics travel with the group.
    static let dismissedManuscriptsNode = "sidebar.node.imprint.manuscript.status.dismissed"

    /// Cited in Manuscripts is declared by BOTH presets, so it renders in both
    /// groups with the SAME scope. Two doors, one destination — and the two
    /// identifiers are what keep them separately addressable.
    static let imbibCitedNode = "sidebar.node.imbib.section.citedInManuscripts.publication"
    static let imprintCitedNode = "sidebar.node.imprint.section.citedInManuscripts.publication"

    /// TAG rows — `sidebar.node.imbib.publication.tag.<full path>`. The row's
    /// LABEL is the leaf; the identifier carries the whole path, because that
    /// is the row's identity (`reading/queue` and `writing/queue` must not
    /// collide). `readingTagNode` is the one no record carries: it exists only
    /// because the tree materialises interior paths.
    static let readingTagNode = "sidebar.node.imbib.publication.tag.reading"
    static let readingQueueTagNode = "sidebar.node.imbib.publication.tag.reading/queue"
    static let readingDoneTagNode = "sidebar.node.imbib.publication.tag.reading/done"
    static let grantsTagNode = "sidebar.node.imbib.publication.tag.grants"
    /// impart's Tags section reads the MESSAGE vocabulary, so this row can only
    /// exist if the per-app binding is honoured.
    static let messageTagNode = "sidebar.node.impart.message.tag.engine"

    /// The filter field inside the imbib group's Tags section —
    /// `sidebar.tagFilter.<group>.<section>`, the identifier on the TEXT FIELD
    /// rather than on `FilterInput`'s container, because automation types into
    /// the field.
    static let imbibTagFilterField = "sidebar.tagFilter.imbib.tags"

    /// Library rows carry the library's UUID, which the seed does not choose
    /// (`createLibrary` does), so this is a PREFIX match — imbib's suite
    /// anchors the same way for the same reason.
    static let libraryNodePrefix = "sidebar.node.imbib.host.publication.library."

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
    static let secondPublicationTitleFragment = "On the Bernoulli Numbers"
    static let manuscriptTitle = "On the Note G Correction"

    /// The tag fixture. `tagParent` is carried by NO record — it is the shared
    /// prefix of the two leaves, and both halves of the tag contract are
    /// visible only through it: a row for it at all means the tree materialises
    /// interior paths, and a non-empty list under it means matching is
    /// descendant-inclusive.
    static let tagParent = "reading"
    static let tagQueue = "reading/queue"
    static let tagDone = "reading/done"
    static let tagGrants = "grants"
}
