//
//  Phase2SettingsPersistenceTests.swift
//  PublicationManagerCoreTests
//
//  Stage 6 phase 2: the frozen persistence-key inventory of imbib (both
//  platforms), implore, impel and impart — the `ImprintSettingsPersistenceTests`
//  pattern applied to the four apps phase 2 migrated.
//
//  THE FAILURE THIS GUARDS is the only one a settings reframe can cause that is
//  both silent and irreversible. Rename an `@AppStorage` key and the app reads a
//  key nothing ever wrote, gets the code default, and the user's real preference
//  sits on disk under the old name where nothing will ever read it again. There is
//  no error, no log line, no crash. It presents as "my settings were reset" — and
//  for a theme editor or a set of API-server ports, that is a support ticket, not
//  a bug report anyone can act on. It is the same shape as the schema-ref mismatch
//  the root CLAUDE.md says has shipped five times, and it deserves the same kind
//  of referee.
//
//  Phase 2 is more exposed to this than phase 1 was, for a specific reason: four
//  of imprint's panes MOVED FILE (and target) in phase 1, which is scary but
//  mechanical. In phase 2 the panes did not move at all — what moved is which
//  file decides they exist. That makes the risk subtler rather than smaller,
//  because a factory that names the wrong pane, or a pane deleted as "superseded"
//  when it was not, changes which keys the app reads WITHOUT touching a key.
//  Freezing the key sets per file catches both.
//
//  WHY A SOURCE SCAN, and why in PMC's test bundle: `@AppStorage` keys are string
//  literals inside `View` structs, unreachable by reflection, and PMC's is the one
//  Swift suite in this repo CI actually runs (`swift test`). implore has NO unit
//  test target at all and impart has no UI test target, so for two of these four
//  apps this file is the ONLY place such an assertion can live. Same argument
//  `ChassisUTIDeclarationTests` and `SchemaRefManifestParityTests` already make.
//

import XCTest

final class Phase2SettingsPersistenceTests: XCTestCase {

    // MARK: - imbib macOS

    /// Keys imbib's macOS settings panes read, verbatim as they were before Stage
    /// 6 phase 2.
    ///
    /// Only six, across 3,998 lines of settings UI, and that is not an oversight —
    /// imbib's preferences live almost entirely in typed stores
    /// (`ThemeSettingsStore`, `PDFSettingsStore`, `ListViewSettingsStore`,
    /// `ImportExportSettingsStore`, `RecommendationSettingsStore`,
    /// `KeyboardShortcutsStore`, `AutomationSettingsStore`) and in
    /// `SyncedSettingsStore` (an `NSUbiquitousKeyValueStore` with a typed key
    /// enum). `@AppStorage` is the exception here rather than the rule, which is
    /// WHY the six are worth pinning: they are the ones with no type to protect
    /// them.
    private static let imbibMacKeys: Set<String> = [
        // GeneralSettingsTab
        "libraryLocation",
        "openPDFInExternalViewer",
        "undoHistoryMaxEntries",
        // ImportExportSettingsTab
        "autoGenerateCiteKeys",
        "defaultEntryType",
        "exportPreserveRawBibTeX",
    ]

    func testImbibMacOSSettingsPanesReadExactlyTheShippedKeys() throws {
        XCTAssertEqual(
            try Self.appStorageKeys(inDirectory: "apps/imbib/imbib/imbib/Views/Settings"),
            Self.imbibMacKeys,
            """
            The @AppStorage keys in imbib's macOS settings panes changed. A renamed \
            key silently resets every existing user's preference — it reads as \
            "settings were lost", not as a bug. If a key MUST change, migrate the \
            stored value in the same commit, then update this list.
            """)
    }

    // MARK: - imbib iOS

    /// Keys imbib-iOS's settings panes read.
    ///
    /// `IOSSettingsView.swift` itself declares NONE, before or after the reframe —
    /// it was a list host and is now a renderer host. Every key here belongs to a
    /// pane under `imbib-iOS/Views/Settings/`.
    private static let imbibIOSKeys: Set<String> = [
        // IOSImportExportSettingsView — the SAME three keys the macOS
        // Import & Export pane reads. Shared keys across two separate pane
        // implementations is exactly the arrangement that makes a rename
        // catastrophic in one place and invisible in the other.
        "autoGenerateCiteKeys",
        "defaultEntryType",
        "exportPreserveRawBibTeX",
        // IOSNotesSettingsView. NOTE these two are iOS-ONLY: imbib's macOS
        // NotesSettingsTab persists through `QuickAnnotationSettingsStore` and
        // does not read them. A genuine platform difference in PERSISTENCE, not
        // just in UI, and one of the things a shared descriptor list does NOT
        // unify — worth knowing before anyone "harmonises" the notes panes.
        "helixModeEnabled",
        "helixShowModeIndicator",
    ]

    func testImbibIOSSettingsPanesReadExactlyTheShippedKeys() throws {
        let hostKeys = try Self.appStorageKeys(
            in: "apps/imbib/imbib/imbib-iOS/Views/IOSSettingsView.swift")
        let paneKeys = try Self.appStorageKeys(
            inDirectory: "apps/imbib/imbib/imbib-iOS/Views/Settings")

        XCTAssertEqual(
            hostKeys, [],
            "the iOS settings host renders declared sections; it must not own a "
                + "preference of its own")
        XCTAssertEqual(paneKeys, Self.imbibIOSKeys)
    }

    /// The three import/export keys are read by BOTH platforms' panes, which is
    /// the property that makes them the same preference rather than two.
    ///
    /// Asserted explicitly because it is the one cross-platform key overlap in
    /// imbib, and because the reframe deleted a pane on each platform
    /// (`EnrichmentSettingsTab`, `IOSEnrichmentSettingsView`): a deletion that took
    /// the wrong pane with it would show up here as a vanished key.
    func testImbibImportExportKeysAreSharedByBothPlatforms() throws {
        let shared: Set<String> = [
            "autoGenerateCiteKeys", "defaultEntryType", "exportPreserveRawBibTeX",
        ]
        let mac = try Self.appStorageKeys(inDirectory: "apps/imbib/imbib/imbib/Views/Settings")
        let ios = try Self.appStorageKeys(
            inDirectory: "apps/imbib/imbib/imbib-iOS/Views/Settings")

        XCTAssertTrue(shared.isSubset(of: mac), "macOS lost an import/export key")
        XCTAssertTrue(shared.isSubset(of: ios), "iOS lost an import/export key")
    }

    /// imbib does NOT use the chassis appearance builtin, so it must not have
    /// acquired the builtin's key either.
    ///
    /// This is the negative half of
    /// `SettingsSurfacePhase2ContractTests.testImbibRegistersOverTheAppearanceBuiltinOnBothPlatforms`.
    /// imbib's appearance preference lives in `ThemeSettingsStore` as part of a
    /// whole theme, and the builtin writes a bare `appearanceMode` string. If an
    /// imbib pane ever started declaring `@AppStorage("appearanceMode")` it would
    /// fork the preference: the theme store and the raw key would both claim to
    /// own the light/dark choice, and whichever wrote last would win at random.
    func testImbibPanesDoNotDeclareTheBuiltinAppearanceKey() throws {
        for directory in [
            "apps/imbib/imbib/imbib/Views/Settings",
            "apps/imbib/imbib/imbib-iOS/Views/Settings",
        ] {
            XCTAssertFalse(
                try Self.appStorageKeys(inDirectory: directory).contains("appearanceMode"),
                "\(directory) declares `appearanceMode`, forking imbib's theme "
                    + "preference with the chassis builtin's key")
        }
    }

    // MARK: - implore

    /// implore's five keys — the only `@AppStorage` keys in its entire source tree.
    ///
    /// Modal-editing preferences are deliberately absent: `modalEditing.isEnabled`,
    /// `.selectedStyle` and `.showModeIndicator` belong to ImpressHelixCore's
    /// `ModalEditingSettings`, which the General pane reads THROUGH rather than
    /// declaring. Listing them here would freeze a package's keys from an app's
    /// test, which is the wrong place for that promise.
    private static let imploreKeys: Set<String> = [
        // GeneralSettingsView
        "autoLoadLastDataset",
        "showWelcomeOnLaunch",
        // RenderingSettingsView
        "pointSize",
        "antialiasing",
        "maxFPS",
    ]

    func testImploreSettingsReadExactlyTheShippedKeys() throws {
        XCTAssertEqual(
            try Self.appStorageKeys(in: "apps/implore/Implore/Sources/Views/SettingsView.swift"),
            Self.imploreKeys)
    }

    // MARK: - impel

    /// impel's nine keys.
    ///
    /// Four of these are ALSO declared in `ImpelApp.swift` and
    /// `PersonaDetailView.swift` with their own defaults, and one pair disagrees:
    /// `counselModel` defaults to `""` here and to `CounselDefaults.defaultModel`
    /// in `PersonaDetailView`. That is a pre-existing bug, not something phase 2
    /// introduced or fixed — recorded here because this is the file someone will
    /// read when they next touch these keys, and a duplicate `@AppStorage`
    /// declaration with a different default means the effective default depends on
    /// which view happens to render first.
    private static let impelKeys: Set<String> = [
        // GeneralSettingsTab
        "serverURL",
        "refreshInterval",
        // ImpelAISettingsTab
        "counselModel",
        "counselSystemPrompt",
        // CounselSettingsTab
        "counselGatewayEnabled",
        "counselSMTPPort",
        "counselIMAPPort",
        "counselMaxTurns",
        "counselPersistenceEnabled",
    ]

    func testImpelSettingsReadExactlyTheShippedKeys() throws {
        XCTAssertEqual(
            try Self.appStorageKeys(in: "apps/impel/Shared/Views/Settings/SettingsView.swift"),
            Self.impelKeys)
    }

    // MARK: - impart

    /// impart's four macOS keys.
    ///
    /// `appearanceMode` is here and must STAY here: impart's General pane has a
    /// hand-rolled clone of `ImpressTheme.AppearanceSettingsSection` over this
    /// exact key with the same three `system`/`light`/`dark` tags. Phase 2
    /// deliberately did NOT replace it with the chassis appearance builtin,
    /// because the picker is one of two controls inside General rather than a tab
    /// of its own — promoting it would move a control between tabs. The alignment
    /// is real and deferred; what this assertion buys is that the key stays the
    /// same one the builtin uses, so the deferred swap remains a pure UI change
    /// with no migration.
    private static let impartMacKeys: Set<String> = [
        // GeneralSettingsView
        "appearanceMode",
        "defaultViewMode",
        // AutomationSettingsView
        "httpAutomationEnabled",
        "httpAutomationPort",
    ]

    func testImpartSettingsReadExactlyTheShippedKeys() throws {
        XCTAssertEqual(
            try Self.appStorageKeys(in: "apps/impart/macOS/Views/Settings/ImpartSettingsScene.swift"),
            Self.impartMacKeys)
    }

    /// impart's iOS settings are UNMIGRATED, and this pins the reason so it is not
    /// mistaken for an omission.
    ///
    /// `impart-iOS` does not link PublicationManagerCore — the package is absent
    /// from that target in `apps/impart/project.yml` — so no chassis renderer can
    /// run there. Its `IOSAppearanceSettingsView` is a second hand-rolled clone of
    /// the shared appearance section over the same `appearanceMode` key, which is
    /// exactly what the builtin would replace once the target links the package.
    /// Until then the key must match macOS's, or the two platforms fork the
    /// preference.
    func testImpartIOSStillReadsTheSameAppearanceKeyAsMacOS() throws {
        let ios = try Self.appStorageKeys(
            in: "apps/impart/impart-iOS/Views/IOSContentView.swift")
        XCTAssertEqual(
            ios, ["appearanceMode"],
            "impart-iOS's settings are not on the chassis (its target does not link "
                + "PublicationManagerCore); its one preference must at least agree "
                + "with macOS's key")
    }

    // MARK: - Source access

    private static func source(of repoRelativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(repoRelativePath), encoding: .utf8)
    }

    /// Every `@AppStorage("key")` literal in a file.
    private static func appStorageKeys(in repoRelativePath: String) throws -> Set<String> {
        try keys(in: source(of: repoRelativePath))
    }

    /// Every `@AppStorage("key")` literal in every `.swift` file of a directory.
    ///
    /// Directory-wide rather than file-by-file because imbib's panes are spread
    /// over eight files, and a per-file list would have to be edited whenever a
    /// pane moved between them — which would make the test annoying for a reason
    /// that has nothing to do with persistence. The SET of keys a platform's
    /// settings read is the invariant that matters.
    private static func appStorageKeys(inDirectory repoRelativePath: String) throws -> Set<String> {
        let directory = repoRoot.appendingPathComponent(repoRelativePath)
        let contents = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        var found: Set<String> = []
        for url in contents where url.pathExtension == "swift" {
            found.formUnion(try keys(in: String(contentsOf: url, encoding: .utf8)))
        }
        XCTAssertFalse(
            contents.filter { $0.pathExtension == "swift" }.isEmpty,
            "no Swift files under \(repoRelativePath) — the path moved and this "
                + "test is now asserting nothing")
        return found
    }

    private static func keys(in text: String) throws -> Set<String> {
        let regex = try NSRegularExpression(pattern: #"@AppStorage\("([^"]+)"\)"#)
        return Set(
            regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
                .compactMap { match in
                    Range(match.range(at: 1), in: text).map { String(text[$0]) }
                })
    }

    /// Repo root, derived from this test's own path so it is location independent.
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
