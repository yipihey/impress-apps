// R3 migrates imprint's portable preferences into the shared registry.
// Pin the GUI's canonical keys here; ImpressKit's ImprintSettingsMigrationTests
// exercise their old UserDefaults values through the native bridge, including
// readback after reopen and preservation of the original values.

import XCTest

final class ImprintSettingsPersistenceTests: XCTestCase {

    // MARK: - The frozen key inventory

    private static let portablePaneKeys: Set<String> = [
        "imprint.general.default_edit_mode",
        "imprint.general.auto_save_interval",
        "imprint.general.create_backups",
        "imprint.general.auto_compile",
        "imprint.general.compile_debounce_ms",
        "imprint.general.preview_format",
        "imprint.editor.font_size",
        "imprint.editor.font_family",
        "imprint.editor.show_line_numbers",
        "imprint.editor.highlight_current_line",
        "imprint.editor.wrap_lines",
        "imprint.documents.validate_crdt_on_open",
        "imprint.documents.auto_backup_before_migration",
    ]

    /// Keys the panes that stayed in `macOS/Views/SettingsView.swift` read.
    private static let macOSPaneKeys: Set<String> = [
        // ExportSettingsView
        "defaultExportFormat",
        "defaultJournalTemplate",
        "includeBibliography",
    ]

    /// The appearance key. Its pane is now the CHASSIS builtin
    /// (`AppearanceSettingsPane`), which reads it as an
    /// `ImpressTheme.AppearanceMode` — a `String`-backed enum whose cases are
    /// `system`/`light`/`dark`, i.e. the exact three tag values imprint's
    /// hand-written picker wrote. Same key, same values, so an existing
    /// preference reads back unchanged.
    private static let appearanceKey = "appearanceMode"

    // MARK: - Assertions

    func testPortableImprintPanesReadCanonicalRegistryKeys() throws {
        let path = "apps/imprint/Shared/Settings/ImprintSettingsPanes.swift"
        XCTAssertEqual(try Self.impressSettingKeys(in: path), Self.portablePaneKeys)
        XCTAssertTrue(try Self.appStorageKeys(in: path).isEmpty,
                      "migrated controls must not keep a second UserDefaults reader")
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
    ///
    /// UPDATED (ADR-0022 X2, D9 finding 5). The claim is unchanged; the
    /// artifact that proves it moved. imprint used to APPLY the key with an
    /// 18-line `AppearanceModifier` in `Shared/ImprintApp.swift` and a fourth
    /// inline copy in `ImprintIOSApp.swift`, so the honest check was "does each
    /// of those two files still declare `@AppStorage("appearanceMode")`". Both
    /// copies are deleted; `ImpressTheme.withAppearance()` is the one
    /// application on both platforms. So the READER assertion is now made once,
    /// against the shared modifier, and each platform is checked for the thing
    /// that can actually regress: that it still CALLS it. An imprint scene that
    /// drops `.withAppearance()` is exactly the "control that does nothing"
    /// this test was written to catch, and dropping it is now the only way to
    /// get there.
    func testAppearanceKeyIsStillTheOneBothPlatformsApply() throws {
        let paneKeys = try Self.appStorageKeys(
            in: "apps/imprint/Shared/Settings/ImprintSettingsPanes.swift")
        XCTAssertFalse(
            paneKeys.contains(Self.appearanceKey),
            "the appearance pane is a chassis builtin now; a second declaration forks it")

        let declaration = "@AppStorage(\"\(Self.appearanceKey)\")"

        // The ONE application, shared by every app in the suite.
        let sharedModifier = try Self.source(
            of: "packages/ImpressTheme/Sources/ImpressTheme/AppearanceModifier.swift")
        XCTAssertTrue(
            sharedModifier.contains("public static let storageKey = \"\(Self.appearanceKey)\""),
            "ImpressTheme's AppearanceModifier must still read `\(Self.appearanceKey)`")
        // Through `@AppStorage`, so a settings write lands live rather than at
        // next launch. It reads the CONSTANT asserted above rather than a
        // fourth copy of the literal, which is why this is not `declaration`.
        XCTAssertTrue(
            sharedModifier.contains("@AppStorage(AppearanceModifier.storageKey)"),
            "…and must read it through @AppStorage, so a settings write lands live")

        // Both imprint platforms must still CALL it. This is the assertion that
        // can regress: deleting the call is silent, and the app just stops
        // honouring the preference.
        XCTAssertTrue(
            try Self.source(of: "apps/imprint/Shared/ImprintApp.swift")
                .contains(".withAppearance()"),
            "macOS imprint must apply the shared appearance modifier")
        XCTAssertTrue(
            try Self.source(of: "apps/imprint/imprint-iOS/ImprintIOSApp.swift")
                .contains(".withAppearance()"),
            "iOS must APPLY the key the new settings screen writes, or the "
                + "Appearance row is a control that does nothing")

        // Neither may re-grow a private APPLICATION of the key. Note what is
        // NOT asserted: imprint's `ImprintApp` still declares
        // `@AppStorage("appearanceMode")` and legitimately so — that property
        // backs the View ▸ Appearance menu, which WRITES the preference (⌃⌘D,
        // "all dark / all light"). Reading and writing the key is fine and is
        // the point of a shared key. What must not come back is a second
        // string→ColorScheme mapping, which is the actual finding.
        for path in [
            "apps/imprint/Shared/ImprintApp.swift",
            "apps/imprint/imprint-iOS/ImprintIOSApp.swift",
        ] {
            let source = try Self.source(of: path)
            XCTAssertFalse(
                source.contains("struct AppearanceModifier"),
                "\(path) must not re-declare AppearanceModifier — ImpressTheme owns it")
            XCTAssertFalse(
                source.contains("func withAppearance()"),
                "\(path) must not re-declare withAppearance() — ImpressTheme owns it")
        }

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
        let portable = try Self.impressSettingKeys(
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

    private static func impressSettingKeys(in repoRelativePath: String) throws -> Set<String> {
        let text = try source(of: repoRelativePath)
        let regex = try NSRegularExpression(pattern: #"@ImpressSetting\("([^"]+)"\)"#)
        return Set(regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range(at: 1), in: text).map { String(text[$0]) } })
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
