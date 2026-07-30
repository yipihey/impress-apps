//
//  ImprintSettingsPersistenceTests.swift
//  PublicationManagerCoreTests
//
//  Stage 6 phase 1: the guard on the ONLY thing a settings reframe can break
//  invisibly — the persistence keys.
//
//  imprint's settings panes moved file in Stage 6, and four of them moved
//  across a TARGET boundary (into `apps/imprint/Shared/Settings/`, so
//  imprint-iOS compiles them); every pane's `Form { … }.formStyle(.grouped)
//  .padding()` became the chassis's `SettingsForm { … }`. None of that can
//  change behaviour.
//
//  RENAMING AN `@AppStorage` KEY CAN, and it does so silently and
//  irreversibly: the app reads a key nothing has ever written, gets the code
//  default, and the user's real preference sits on disk under the old name
//  where nothing will read it again. It looks exactly like "my settings were
//  reset" — no error, no log line. This is the same failure shape as the
//  schema-ref mismatch the root CLAUDE.md says has shipped five times, and it
//  deserves the same kind of referee.
//
//  WHY A SOURCE SCAN, and why HERE:
//
//  * `@AppStorage` keys are not reachable by reflection, and the panes are
//    `View` structs whose property wrappers cannot be enumerated. The string
//    literal is the artifact; reading it is the honest instrument. (Same
//    instrument `ChassisCrossPlatformContractTests` uses for its structural
//    half.)
//  * It lives in PMC's test target, walking up to the repo root, because that
//    is the one Swift test suite in this repo that CI actually runs
//    (`swift test`) — imprint's own `imprintTests` bundle is not in any
//    workflow, and running it locally would launch imprint.app. The pattern is
//    established: `ChassisUTIDeclarationTests` and `SchemaRefManifestParityTests`
//    both read app-level files from here for the same reason.
//

import XCTest

final class ImprintSettingsPersistenceTests: XCTestCase {

    // MARK: - The frozen key inventory

    /// Keys the four PORTABLE panes read, exactly as they appeared in
    /// `apps/imprint/macOS/Views/SettingsView.swift` before the move.
    private static let portablePaneKeys: Set<String> = [
        // GeneralSettingsView
        "defaultEditMode",
        "autoSaveInterval",
        "createBackups",
        "imprint.autoCompile",
        "imprint.compileDebounceMs",
        "imprint.previewFormat",
        // EditorSettingsView. The `modalEditing.*` keys are NOT here: they
        // belong to ImpressHelixCore's `ModalEditingSettings`, which the pane
        // reads through rather than declaring.
        "editorFontSize",
        "editorFontFamily",
        "showLineNumbers",
        "highlightCurrentLine",
        "wrapLines",
        // DocumentHealthSettingsView
        "validateCRDTOnOpen",
        "autoBackupBeforeMigration",
        // AccountSettingsView declares none (iCloud token only).
    ]

    /// Keys the panes that stayed in `macOS/Views/SettingsView.swift` read.
    private static let macOSPaneKeys: Set<String> = [
        // ExportSettingsView
        "defaultExportFormat",
        "defaultJournalTemplate",
        "includeBibliography",
        // AutomationSettingsView
        "httpAutomationEnabled",
        "httpAutomationPort",
    ]

    /// The appearance key. Its pane is now the CHASSIS builtin
    /// (`AppearanceSettingsPane`), which reads it as an
    /// `ImpressTheme.AppearanceMode` — a `String`-backed enum whose cases are
    /// `system`/`light`/`dark`, i.e. the exact three tag values imprint's
    /// hand-written picker wrote. Same key, same values, so an existing
    /// preference reads back unchanged.
    private static let appearanceKey = "appearanceMode"

    // MARK: - Assertions

    func testPortableImprintPanesReadExactlyTheShippedKeys() throws {
        let found = try Self.appStorageKeys(
            in: "apps/imprint/Shared/Settings/ImprintSettingsPanes.swift")
        XCTAssertEqual(
            found, Self.portablePaneKeys,
            """
            The @AppStorage keys in imprint's portable settings panes changed. \
            A renamed key silently resets every existing user's preference — it \
            reads as "settings were lost", not as a bug. If a key MUST change, \
            migrate the stored value in the same commit, then update this list.
            """)
    }

    func testMacOSOnlyImprintPanesReadExactlyTheShippedKeys() throws {
        let found = try Self.appStorageKeys(in: "apps/imprint/macOS/Views/SettingsView.swift")
        XCTAssertEqual(found, Self.macOSPaneKeys)
    }

    /// The appearance key moved OUT of imprint entirely (into the chassis
    /// builtin). Assert imprint no longer declares it in a pane — a second
    /// declaration would fork the preference — and that BOTH platforms still
    /// apply that key, which is what makes the new Appearance row do something
    /// on iOS instead of nothing.
    func testAppearanceKeyIsStillTheOneBothPlatformsApply() throws {
        let paneKeys = try Self.appStorageKeys(
            in: "apps/imprint/Shared/Settings/ImprintSettingsPanes.swift")
        XCTAssertFalse(
            paneKeys.contains(Self.appearanceKey),
            "the appearance pane is a chassis builtin now; a second declaration forks it")

        let declaration = "@AppStorage(\"\(Self.appearanceKey)\")"
        XCTAssertTrue(
            try Self.source(of: "apps/imprint/Shared/ImprintApp.swift").contains(declaration),
            "macOS's AppearanceModifier must still read `\(Self.appearanceKey)`")
        XCTAssertTrue(
            try Self.source(of: "apps/imprint/imprint-iOS/ImprintIOSApp.swift")
                .contains(declaration),
            "iOS must APPLY the key the new settings screen writes, or the "
                + "Appearance row is a control that does nothing")
        XCTAssertTrue(
            try Self.source(
                of: "apps/imbib/PublicationManagerCore/Sources/PublicationManagerCore"
                    + "/Chassis/Settings/SettingsSectionRegistry.swift")
                .contains(declaration),
            "the chassis builtin appearance pane must WRITE the same key")
    }

    /// The app-specific panes were REGISTERED, not rewritten. This pins that
    /// their key sets are untouched by the reframe — the claim "we only changed
    /// the frame" made checkable.
    func testAppSpecificPaneKeysAreUntouchedByTheReframe() throws {
        XCTAssertEqual(
            try Self.appStorageKeys(in: "apps/imprint/macOS/Views/LaTeXSettingsView.swift"),
            [
                "imprint.latex.defaultEngine",
                "imprint.latex.autoCompile",
                "imprint.latex.compileDebounceMs",
                "imprint.latex.shellEscape",
                "imprint.latex.showBoxWarnings",
            ])
        XCTAssertEqual(
            try Self.appStorageKeys(in: "apps/imprint/macOS/Views/ImbibSettingsView.swift"),
            ["showCitedPapersSidebar", "autoSyncBibliography", "bibliographyFileName"])
        // AITasksSettingsView persists through `AITaskPreferences` (raw
        // UserDefaults), not @AppStorage — assert its two keys directly.
        let aiTasks = try Self.source(of: "apps/imprint/macOS/Views/AITasksSettingsView.swift")
        XCTAssertTrue(aiTasks.contains("\"imprint.ai.disabledTasks\""))
        XCTAssertTrue(aiTasks.contains("\"imprint.ai.promptOverrides\""))
    }

    /// Every key the iOS settings screen can WRITE must be declared in a file
    /// the iOS target compiles. A key declared only in `macOS/` is a row that
    /// cannot exist on iOS; a key the iOS screen writes into a store macOS
    /// never reads would be a silent fork of the preference.
    func testEveryKeyReachableFromTheIOSScreenLivesInASharedFile() throws {
        // The iOS screen renders appearance (chassis) + the four portable panes.
        let portable = try Self.appStorageKeys(
            in: "apps/imprint/Shared/Settings/ImprintSettingsPanes.swift")
        let macOnly = try Self.appStorageKeys(
            in: "apps/imprint/macOS/Views/SettingsView.swift")
        XCTAssertTrue(
            portable.isDisjoint(with: macOnly),
            "a key declared in BOTH a shared pane and a macOS-only pane has two "
                + "owners; whichever renders last wins and the other's defaults lie")
    }

    // MARK: - Source access

    private static func source(of repoRelativePath: String) throws -> String {
        try String(
            contentsOf: repoRoot.appendingPathComponent(repoRelativePath), encoding: .utf8)
    }

    /// Every `@AppStorage("key")` literal in a file.
    private static func appStorageKeys(in repoRelativePath: String) throws -> Set<String> {
        let text = try source(of: repoRelativePath)
        let regex = try NSRegularExpression(pattern: #"@AppStorage\("([^"]+)"\)"#)
        return Set(
            regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
                .compactMap { match in
                    Range(match.range(at: 1), in: text).map { String(text[$0]) }
                })
    }

    /// Repo root, derived from this test's own path so it is location
    /// independent (the `ChassisUTIDeclarationTests` pattern).
    private static let repoRoot: URL = {
        URL(fileURLWithPath: #filePath)          // …/Tests/PublicationManagerCoreTests/<this>
            .deletingLastPathComponent()          // …/Tests/PublicationManagerCoreTests
            .deletingLastPathComponent()          // …/Tests
            .deletingLastPathComponent()          // …/PublicationManagerCore
            .deletingLastPathComponent()          // …/imbib
            .deletingLastPathComponent()          // …/apps
            .deletingLastPathComponent()          // repo root
    }()
}
