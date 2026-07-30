//
//  SettingsSurfacePhase2ContractTests.swift
//  PublicationManagerCoreTests
//
//  Stage 6 phase 2: the frozen settings inventories of the four apps phase 1 left
//  alone — imbib (both platforms), implore, impel, impart.
//
//  WHY A SECOND FILE rather than more cases in `SettingsSurfaceContractTests`:
//  that file is phase 1's oracle for imprint and for the registry's own
//  semantics, and it is the file a reviewer opens to ask "what did phase 1
//  promise". Phase 2's promise is different in kind — it is "these four apps'
//  SHIPPED surfaces did not change" — so it gets its own oracle, and phase 1's
//  stays readable as what it is.
//
//  WHAT THESE TESTS ARE FOR. A settings reframe has exactly two ways to do damage
//  and neither shows up as a crash:
//
//   1. A pane silently moves, is renamed, loses its icon, or disappears. On macOS
//      that is a REGRESSION the migration explicitly forbade (visual equivalence),
//      and nothing in the type system notices, because "the tabs are in the right
//      order" used to be a fact about the literal order of statements in a
//      `TabView` body and is now a fact about integers in a preset. The frozen
//      inventories below are the replacement for the compiler's non-opinion.
//   2. An accessibility identifier changes, which breaks UI suites in another
//      target that CI may not even run — a green `swift test` and a broken
//      `imbibUITests`. Identifiers are asserted here, in the suite that does run.
//
//  A frozen inventory is a deliberately annoying test: any intentional change to
//  an app's settings surface must edit it. That is the point. It is the same
//  bargain `SettingsSectionID`'s string rawValue makes — exhaustiveness moves from
//  the compiler to tests, so the tests have to actually be exhaustive.
//

import XCTest
@testable import PublicationManagerCore

final class SettingsSurfacePhase2ContractTests: XCTestCase {

    // MARK: - imbib: the frozen macOS sidebar

    /// The sixteen panes of imbib's macOS Settings scene, in shipped order, with
    /// shipped titles, SF Symbols and group headers.
    ///
    /// Verbatim from the `SettingsTab` enum and the sidebar `List` that
    /// `apps/imbib/imbib/imbib/Views/Settings/SettingsView.swift` had before Stage
    /// 6 — four parallel `switch`es (displayName, icon, helpText) plus a `List`
    /// body, reduced to one row per pane here.
    private static let imbibMacInventory:
        [(id: String, title: String, symbol: String, group: String)] = [
            ("general", "General", "gear", "General"),
            ("appearance", "Appearance", "paintbrush", "General"),
            ("viewing", "Viewing", "eye", "General"),
            ("flagsAndTags", "Flags & Tags", "flag", "Content"),
            ("notes", "Notes", "note.text", "Content"),
            ("pdf", "PDF", "doc.richtext", "Content"),
            ("sources", "Sources", "globe", "Content"),
            ("enrichment", "Enrichment", "arrow.triangle.2.circlepath", "Content"),
            ("searchAI", "Search & AI", "brain", "Content"),
            ("inbox", "Inbox", "tray", "Inbox & Feeds"),
            ("recommendations", "Recommendations", "sparkles", "Inbox & Feeds"),
            ("sync", "Sync", "icloud", "Sync & Backup"),
            ("eink", "E-Ink Devices", "rectangle.portrait", "Sync & Backup"),
            ("importExport", "Import & Export", "arrow.up.arrow.down", "Import & Export"),
            ("shortcuts", "Keyboard Shortcuts", "keyboard", "System"),
            ("advanced", "Advanced", "gearshape.2", "System"),
        ]

    func testImbibPresetIsTheFrozenSixteenPaneSidebar() {
        let rendered = AppSettingsConfiguration.imbib.sections(on: .macOS)

        XCTAssertEqual(
            rendered.count, Self.imbibMacInventory.count,
            "imbib's macOS Settings scene shipped 16 panes. Adding or removing one "
                + "is a redesign of a surface the Stage 6 migration promised to leave "
                + "visually equivalent — if it is intentional, say so here.")

        for (actual, expected) in zip(rendered, Self.imbibMacInventory) {
            XCTAssertEqual(actual.id.rawValue, expected.id)
            XCTAssertEqual(actual.title, expected.title, "title of \(expected.id)")
            XCTAssertEqual(actual.systemImage, expected.symbol, "symbol of \(expected.id)")
            XCTAssertEqual(
                actual.group?.rawValue, expected.group,
                "sidebar group of \(expected.id)")
        }
    }

    /// The tooltip on every macOS sidebar row. These were `SettingsTab.helpText`
    /// and are now `descriptor.subtitle`, which is the SAME string rendered three
    /// ways (macOS `.help()`, iOS caption, nothing in a `TabView`). A reframe that
    /// dropped them would lose real UI silently, because a missing tooltip is
    /// invisible until you hover.
    func testEveryImbibMacPaneKeepsItsShippedTooltip() {
        let expected: [String: String] = [
            "general": "App preferences",
            "appearance": "Theme and colors",
            "viewing": "List display options",
            "flagsAndTags": "Flag colors and tag display settings",
            "notes": "Note editor settings",
            "sources": "API keys for online sources",
            "pdf": "PDF download settings",
            "enrichment": "Citation sources and metadata enrichment",
            "searchAI": "Embedding provider and search intelligence",
            "inbox": "Feed subscriptions and mute rules",
            "recommendations": "Configure transparent recommendation engine",
            "sync": "iCloud sync settings",
            "eink": "reMarkable, Supernote, and Kindle Scribe integration",
            "importExport": "File format options",
            "shortcuts": "Customize keyboard shortcuts",
            "advanced": "Developer tools and advanced settings",
        ]
        for descriptor in AppSettingsConfiguration.imbib.sections(on: .macOS) {
            XCTAssertEqual(
                descriptor.subtitle, expected[descriptor.id.rawValue],
                "tooltip of \(descriptor.id)")
        }
    }

    /// The six sidebar headers and their exact membership.
    ///
    /// Asserted separately from the flat inventory because grouping is DERIVED
    /// (`sectionGroups` bands contiguous runs; group order is the order of each
    /// group's first member) and a derivation deserves its own oracle. This is the
    /// test that would fail if someone gave a section an order that lands it
    /// outside its own band.
    func testImbibMacSidebarBandsAreTheSixShippedHeaders() {
        let bands = AppSettingsConfiguration.imbib.sectionGroups(on: .macOS)
        let actual = bands.map { band in
            (band.title, band.sections.map(\.id.rawValue))
        }
        let expected: [(String?, [String])] = [
            ("General", ["general", "appearance", "viewing"]),
            ("Content", ["flagsAndTags", "notes", "pdf", "sources", "enrichment", "searchAI"]),
            ("Inbox & Feeds", ["inbox", "recommendations"]),
            ("Sync & Backup", ["sync", "eink"]),
            ("Import & Export", ["importExport"]),
            ("System", ["shortcuts", "advanced"]),
        ]

        XCTAssertEqual(actual.count, expected.count, "number of sidebar groups")
        for (actualBand, expectedBand) in zip(actual, expected) {
            XCTAssertEqual(actualBand.0, expectedBand.0)
            XCTAssertEqual(actualBand.1, expectedBand.1, "members of \(expectedBand.0 ?? "-")")
        }
    }

    // MARK: - imbib: iOS

    /// imbib-iOS renders eighteen sections from the same preset.
    ///
    /// This is the reconciliation phase 2 exists for. Before it, imbib-iOS's rows
    /// were a hand-written `List` that no macOS code could read, and the two
    /// surfaces had drifted in BOTH directions — iOS had PDF Storage, a top-level
    /// Library Backup and a standalone Automation pane; macOS had Flags & Tags,
    /// E-Ink and Search & AI. Neither list knew about the other. Now one
    /// declaration produces both, and the differences are `availability`.
    func testImbibIOSSurfaceIsTheDeclaredElevenPlusSevenIOSSections() {
        let ios = AppSettingsConfiguration.imbib.sections(on: .iOS).map(\.id.rawValue)

        XCTAssertEqual(
            ios,
            [
                // shared with macOS (11)
                "appearance", "viewing",
                // iOS-only, interleaved so its band stays contiguous
                "smartSearch",
                "notes", "pdf",
                "pdfStorage",
                "sources", "enrichment",
                "inbox", "recommendations",
                "sync",
                "backup",
                "importExport",
                "shortcuts",
                "automation",
                "advanced",
                "console", "help", "about",
            ])

        let macOnly = Set(AppSettingsConfiguration.imbib.sections(on: .macOS).map(\.id.rawValue))
            .subtracting(ios)
        XCTAssertEqual(
            macOnly, ["general", "flagsAndTags", "searchAI", "eink"],
            "the four imbib panes that do not reach iOS. Each must keep naming a "
                + "REASON in its availability, not just a platform list.")
    }

    /// iOS's bands, including the three headers imbib-iOS's hand-written screen
    /// used ("Developer", "Help & Support", "About") which macOS has no analogue
    /// for — they were menus there.
    func testImbibIOSBandsCoverBothPlatformsHeadersWithoutDuplication() {
        let bands = AppSettingsConfiguration.imbib.sectionGroups(on: .iOS)
        XCTAssertEqual(
            bands.map(\.title),
            [
                "General", "Content", "Inbox & Feeds", "Sync & Backup",
                "Import & Export", "System", "Developer", "Help & Support", "About",
            ])
        // "Sync & Backup" is the interesting one: [sync, backup] on iOS and
        // [sync, eink] on macOS, from one declaration.
        XCTAssertEqual(
            bands.first { $0.title == "Sync & Backup" }?.sections.map(\.id.rawValue),
            ["sync", "backup"])
    }

    // MARK: - Grouping is a derivation, so pin its one failure mode

    /// A group's members must be CONTIGUOUS in the rendered order on EVERY
    /// platform, or `sectionGroups` emits two bands with the same header — a
    /// duplicated sidebar heading, which looks like a rendering bug and is
    /// actually a declaration bug.
    ///
    /// Per platform independently, because filtering changes what is adjacent: a
    /// group whose members are contiguous on macOS can be split on iOS the moment
    /// a macOS-only section sits between two of them. That is exactly the mistake
    /// this test caught while imbib's preset was being written — `backup` was
    /// declared after `advanced`, which rendered "Sync & Backup" twice on iOS.
    func testEveryGroupedPresetKeepsItsGroupsContiguousOnEveryPlatform() {
        for preset in AppSettingsConfiguration.allPresets {
            for platform in SettingsPlatform.allCases {
                let bands = preset.sectionGroups(on: platform)
                let titles = bands.compactMap(\.group)
                XCTAssertEqual(
                    titles.count, Set(titles).count,
                    """
                    \(preset.appID) on \(platform.rawValue) renders the same group \
                    header more than once, so some group's sections are not \
                    contiguous in `order` after availability filtering. Fix the \
                    ORDERS (give the stray section a value inside its group's \
                    run), not the renderer.
                    """)
            }
        }
    }

    // MARK: - The three small apps, frozen

    func testImplorePresetIsTheFrozenFiveTabInventory() {
        assertInventory(
            of: .implore, on: .macOS,
            equals: [
                ("general", "General", "gear"),
                ("rendering", "Rendering", "paintbrush"),
                ("colormaps", "Colormaps", "paintpalette"),
                ("keyboard", "Keyboard", "keyboard"),
                ("spotlight", "Spotlight", "magnifyingglass"),
            ])
    }

    func testImpelPresetIsTheFrozenThreeTabInventory() {
        assertInventory(
            of: .impel, on: .macOS,
            equals: [
                ("general", "General", "gear"),
                ("ai", "AI", "brain"),
                ("counsel", "Counsel", "envelope"),
            ])
    }

    func testImpartPresetIsTheFrozenSixTabInventory() {
        assertInventory(
            of: .impart, on: .macOS,
            equals: [
                ("accounts", "Accounts", "person.crop.circle"),
                ("ai", "AI", "brain.head.profile"),
                ("general", "General", "gearshape"),
                ("keyboard", "Keyboard", "keyboard"),
                ("automation", "Automation", "terminal"),
                ("spotlight", "Spotlight", "magnifyingglass"),
            ])
    }

    /// implore's tabs carry accessibility identifiers; impel's and impart's never
    /// did. Adopting the renderer GIVES all three the `settings.tabs.<id>`
    /// identifier for free, and for implore that must be the string it already
    /// shipped — `imploreUITests` addresses tabs by title today, but its
    /// `ImploreAccessibilityID.Settings` enum names these, and a rename would
    /// quietly invalidate the enum.
    func testImploreTabIdentifiersAreTheOnesItShipped() {
        XCTAssertEqual(
            AppSettingsConfiguration.implore.sections(on: .macOS)
                .map(\.accessibilityIdentifier),
            [
                "settings.tabs.general",
                "settings.tabs.rendering",
                "settings.tabs.colormaps",
                "settings.tabs.keyboard",
                "settings.tabs.spotlight",
            ])
    }

    /// imbib's identifiers, which shipped in
    /// `PMC/Accessibility/AccessibilityIdentifiers.swift` and are consumed by
    /// `imbibUITests` and `imbib-iOSUITests`.
    ///
    /// `shortcuts` is the one that matters: imbib's Swift case was
    /// `keyboardShortcuts` and its tab is labelled "Keyboard Shortcuts", but the
    /// shipped identifier is `settings.tabs.shortcuts`. Deriving the id from the
    /// case name instead of the identifier would have renamed it.
    func testImbibSectionIdentifiersMatchTheShippedAccessibilityConstants() {
        let byID = Dictionary(
            uniqueKeysWithValues: AppSettingsConfiguration.imbib.sections.map {
                ($0.id.rawValue, $0.accessibilityIdentifier)
            })

        XCTAssertEqual(byID["shortcuts"], AccessibilityID.Settings.Tabs.shortcuts)
        XCTAssertEqual(byID["general"], AccessibilityID.Settings.Tabs.general)
        XCTAssertEqual(byID["appearance"], AccessibilityID.Settings.Tabs.appearance)
        XCTAssertEqual(byID["viewing"], AccessibilityID.Settings.Tabs.viewing)
        XCTAssertEqual(byID["pdf"], AccessibilityID.Settings.Tabs.pdf)
        XCTAssertEqual(byID["notes"], AccessibilityID.Settings.Tabs.notes)
        XCTAssertEqual(byID["sources"], AccessibilityID.Settings.Tabs.sources)
        XCTAssertEqual(byID["enrichment"], AccessibilityID.Settings.Tabs.enrichment)
        XCTAssertEqual(byID["inbox"], AccessibilityID.Settings.Tabs.inbox)
        XCTAssertEqual(byID["importExport"], AccessibilityID.Settings.Tabs.importExport)
        XCTAssertEqual(byID["recommendations"], AccessibilityID.Settings.Tabs.recommendations)
        XCTAssertEqual(byID["sync"], AccessibilityID.Settings.Tabs.sync)
        XCTAssertEqual(byID["backup"], AccessibilityID.Settings.Tabs.backup)
        XCTAssertEqual(byID["advanced"], AccessibilityID.Settings.Tabs.advanced)
    }

    // MARK: - Cross-preset invariants

    /// Declaration order must equal sort order for EVERY preset, not just
    /// imprint's. Phase 1 asserts this for one preset; the same argument (two
    /// representations of one truth) applies to five.
    func testEveryPresetDeclarationOrderMatchesSortOrder() {
        for preset in AppSettingsConfiguration.allPresets {
            XCTAssertEqual(
                preset.sections.map(\.order), preset.sections.map(\.order).sorted(),
                "\(preset.appID)'s sections are stored out of `order`")
            XCTAssertEqual(
                Set(preset.sections.map(\.id)).count, preset.sections.count,
                "\(preset.appID) declares a duplicate section id")
        }
    }

    /// Every preset's `defaultSection` must survive availability filtering on the
    /// platform(s) it renders on — otherwise the renderer silently falls back and
    /// the declared default is a lie.
    func testEveryPresetDefaultSectionIsAvailableWhereItRenders() {
        for preset in AppSettingsConfiguration.allPresets {
            guard let fallback = preset.defaultSection else { continue }
            let macOS = preset.sections(on: .macOS).map(\.id)
            XCTAssertTrue(
                macOS.contains(fallback),
                "\(preset.appID)'s default section `\(fallback)` is filtered out on macOS")
        }
    }

    /// A section reachable on iOS must not require a capability iOS lacks. This is
    /// tautological given `isSatisfied`, which is why it is asserted at the
    /// PRESET level: it catches the authoring mistake of writing
    /// `platforms: [.macOS, .iOS]` with `requirements: [.localToolchain]` and
    /// concluding from a green build that the iOS row exists. It does not.
    func testNoPresetPromisesAnIOSSectionThatNeedsAMacCapability() {
        for preset in AppSettingsConfiguration.allPresets {
            for section in preset.sections where section.availability.platforms.contains(.iOS) {
                XCTAssertTrue(
                    section.availability.requirements.isEmpty,
                    """
                    \(preset.appID)'s `\(section.id)` lists .iOS but requires \
                    \(section.availability.requirements.map(\.rawValue).sorted()), \
                    which `SettingsHostCapabilities.iOS` never grants — so the row \
                    will never render and the declaration reads as if it does.
                    """)
            }
        }
    }

    /// Phase 2 must not have turned any preset's appID into a name no shell knows.
    /// Phase 1 asserts this for imprint; here it is for all five, which is what
    /// makes `allPresets` worth having.
    func testEveryPhase2PresetAppIDMatchesAShellPreset() {
        let shellIDs = Set(
            [AppShellConfiguration.imbib, .imprint, .implore, .impart, .impel, .impress]
                .map(\.appID))
        for preset in AppSettingsConfiguration.allPresets {
            XCTAssertTrue(
                shellIDs.contains(preset.appID),
                "settings preset `\(preset.appID)` names an app with no shell preset; "
                    + "the two `Chassis/` preset families must agree on which apps exist")
        }
    }

    // MARK: - Every declared pane has a factory (source scan)

    /// A descriptor with no factory renders as an "unregistered" warning tab. The
    /// runtime says so and `unresolvedSections` is the test-time check — but
    /// `unresolvedSections` cannot be called from here, because the factories live
    /// in APP TARGETS that PMC's test bundle does not link (deliberately: that is
    /// the whole `CustomSurface` rule).
    ///
    /// So the instrument is a source scan, for the same reason
    /// `ImprintSettingsPersistenceTests` uses one: the artifact that has to be
    /// true is a string literal in a file, and reading the file is the honest way
    /// to check it. What this catches is the realistic mistake — adding a
    /// descriptor to a preset and forgetting the factory, or vice versa — which is
    /// otherwise found by a user opening a blank pane.
    func testEveryAppRegistersAFactoryForEveryPaneItDeclares() throws {
        try assertFactoryCoverage(
            preset: .imbib, platform: .macOS,
            factorySource: "apps/imbib/imbib/imbib/Views/Settings/SettingsView.swift",
            alsoRegisteredElsewhere: ["enrichment"],
            builtinsRelied: [])
        try assertFactoryCoverage(
            preset: .imbib, platform: .iOS,
            factorySource: "apps/imbib/imbib/imbib-iOS/Views/IOSSettingsView.swift",
            alsoRegisteredElsewhere: ["enrichment"],
            builtinsRelied: [])
        try assertFactoryCoverage(
            preset: .implore, platform: .macOS,
            factorySource: "apps/implore/Implore/Sources/Views/SettingsView.swift",
            alsoRegisteredElsewhere: [],
            builtinsRelied: ["spotlight"])
        try assertFactoryCoverage(
            preset: .impel, platform: .macOS,
            factorySource: "apps/impel/Shared/Views/Settings/SettingsView.swift",
            alsoRegisteredElsewhere: [],
            builtinsRelied: [])
        try assertFactoryCoverage(
            preset: .impart, platform: .macOS,
            factorySource: "apps/impart/macOS/Views/ContentView.swift",
            alsoRegisteredElsewhere: [],
            builtinsRelied: ["spotlight"])
    }

    /// The portable imbib panes are registered in PMC, once, for both platforms —
    /// so neither app target should ALSO register them. A double registration is
    /// not a crash (last wins) but it silently re-forks the pane the shared file
    /// exists to unfork.
    func testImbibPortablePanesAreRegisteredOnlyInTheSharedFile() throws {
        let portable = try Self.registeredSections(
            in: "apps/imbib/PublicationManagerCore/Sources/PublicationManagerCore"
                + "/Settings/ImbibPortableSettingsSections.swift")
        XCTAssertEqual(portable, ["enrichment"])

        for appFile in [
            "apps/imbib/imbib/imbib/Views/Settings/SettingsView.swift",
            "apps/imbib/imbib/imbib-iOS/Views/IOSSettingsView.swift",
        ] {
            XCTAssertTrue(
                try Self.registeredSections(in: appFile).isDisjoint(with: portable),
                "\(appFile) re-registers a pane that `ImbibPortableSettingsSections` "
                    + "already declares for both platforms")
        }
    }

    /// imbib REPLACES the chassis appearance builtin on both platforms, and that
    /// is load-bearing rather than incidental: imbib's Appearance pane is a theme
    /// editor, and if a refactor ever deleted these registrations the app would
    /// silently fall back to the builtin's three-way System/Light/Dark picker —
    /// losing named themes, accent colours and font scale, with no error.
    func testImbibRegistersOverTheAppearanceBuiltinOnBothPlatforms() throws {
        for appFile in [
            "apps/imbib/imbib/imbib/Views/Settings/SettingsView.swift",
            "apps/imbib/imbib/imbib-iOS/Views/IOSSettingsView.swift",
        ] {
            XCTAssertTrue(
                try Self.registeredSections(in: appFile).contains("appearance"),
                "\(appFile) must register its own appearance pane over the builtin")
        }
    }

    /// The reverse claim for the apps that DO adopt a builtin: implore's and
    /// impart's Spotlight tab bodies were `Form { SpotlightSettingsSection() }`
    /// verbatim, so neither may register a factory for it — a hand-written one
    /// would re-fork the wrapper the builtin exists to share.
    func testImploreAndImpartTakeSpotlightFromTheChassisBuiltin() throws {
        for appFile in [
            "apps/implore/Implore/Sources/Views/SettingsView.swift",
            "apps/impart/macOS/Views/ContentView.swift",
        ] {
            XCTAssertFalse(
                try Self.registeredSections(in: appFile).contains("spotlight"),
                "\(appFile) should take Spotlight from `SettingsSectionRegistry.builtin`")
        }
        XCTAssertTrue(
            SettingsSectionRegistry.builtin.registeredSections.contains(.spotlight))
    }

    // MARK: - Helpers

    private func assertInventory(
        of preset: AppSettingsConfiguration,
        on platform: SettingsPlatform,
        equals expected: [(id: String, title: String, symbol: String)],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let rendered = preset.sections(on: platform)
        XCTAssertEqual(
            rendered.count, expected.count,
            "\(preset.appID) tab count", file: file, line: line)
        for (actual, want) in zip(rendered, expected) {
            XCTAssertEqual(actual.id.rawValue, want.id, file: file, line: line)
            XCTAssertEqual(
                actual.title, want.title, "title of \(want.id)", file: file, line: line)
            XCTAssertEqual(
                actual.systemImage, want.symbol, "symbol of \(want.id)",
                file: file, line: line)
        }
    }

    /// Compare a preset's platform sections against the ids an app file registers.
    ///
    /// - Parameters:
    ///   - alsoRegisteredElsewhere: ids supplied by a shared registration file.
    ///   - builtinsRelied: ids the app deliberately takes from the chassis.
    private func assertFactoryCoverage(
        preset: AppSettingsConfiguration,
        platform: SettingsPlatform,
        factorySource: String,
        alsoRegisteredElsewhere: Set<String>,
        builtinsRelied: Set<String>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let declared = Set(preset.sections(on: platform).map(\.id.rawValue))
        let registered = try Self.registeredSections(in: factorySource)
        let covered = registered.union(alsoRegisteredElsewhere).union(builtinsRelied)

        XCTAssertTrue(
            declared.subtracting(covered).isEmpty,
            """
            \(preset.appID) on \(platform.rawValue) declares panes with no factory: \
            \(declared.subtracting(covered).sorted()). Each renders as an \
            "No content is registered" warning tab.
            """,
            file: file, line: line)

        XCTAssertTrue(
            registered.subtracting(declared).isEmpty,
            """
            \(factorySource) registers factories for sections \(preset.appID) does \
            not declare on \(platform.rawValue): \
            \(registered.subtracting(declared).sorted()). A factory nothing \
            declares is dead code that reads as a shipped pane.
            """,
            file: file, line: line)
    }

    /// Every `SettingsSectionFactory(section: .foo)` id in a file.
    private static func registeredSections(in repoRelativePath: String) throws -> Set<String> {
        let text = try source(of: repoRelativePath)
        let regex = try NSRegularExpression(
            pattern: #"SettingsSectionFactory\(\s*section:\s*\.(\w+)"#)
        return Set(
            regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
                .compactMap { match in
                    Range(match.range(at: 1), in: text).map { String(text[$0]) }
                })
    }

    private static func source(of repoRelativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(repoRelativePath), encoding: .utf8)
    }

    /// Repo root from this test's own path — the `ChassisUTIDeclarationTests`
    /// pattern, so the suite is location independent.
    private static let repoRoot: URL = {
        URL(fileURLWithPath: #filePath)   // …/Tests/PublicationManagerCoreTests/Settings/<this>
            .deletingLastPathComponent()   // …/Settings
            .deletingLastPathComponent()   // …/PublicationManagerCoreTests
            .deletingLastPathComponent()   // …/Tests
            .deletingLastPathComponent()   // …/PublicationManagerCore
            .deletingLastPathComponent()   // …/imbib
            .deletingLastPathComponent()   // …/apps
            .deletingLastPathComponent()   // repo root
    }()
}
