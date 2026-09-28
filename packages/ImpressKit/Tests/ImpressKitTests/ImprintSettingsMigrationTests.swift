import XCTest
@testable import ImpressKit

@MainActor
final class ImprintSettingsMigrationTests: XCTestCase {
    /// Every portable control migrated in R3: real legacy values pass through
    /// the same native registry as the GUI, survive reopening, and remain in
    /// UserDefaults for older app builds.
    func testPortablePreferencesMigrateWithoutRemovingOrOverwritingLegacyValues() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("imprint-settings-migration-\(UUID().uuidString)")
        let suiteName = "imprint-settings-migration-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let settings = ImpressSettings.shared
        settings._resetForTesting()
        settings.workspaceDirectory = scratch
        settings.legacyStores = [suite]
        defer {
            settings._resetForTesting()
            settings.workspaceDirectory = SharedWorkspace.workspaceDirectory
            settings.legacyStores = [.standard, SharedDefaults.suite]
            suite.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: scratch)
        }
        let strings = [
            ("imprint.general.default_edit_mode", "defaultEditMode", "direct_pdf"),
            ("imprint.general.preview_format", "imprint.previewFormat", "svg"),
            ("imprint.editor.font_family", "editorFontFamily", "Menlo"),
        ]
        let integers = [
            ("imprint.general.auto_save_interval", "autoSaveInterval", 120),
            ("imprint.general.compile_debounce_ms", "imprint.compileDebounceMs", 700),
            ("imprint.editor.font_size", "editorFontSize", 18),
        ]
        let booleans = [
            ("imprint.general.create_backups", "createBackups"),
            ("imprint.general.auto_compile", "imprint.autoCompile"),
            ("imprint.editor.show_line_numbers", "showLineNumbers"),
            ("imprint.editor.highlight_current_line", "highlightCurrentLine"),
            ("imprint.editor.wrap_lines", "wrapLines"),
            ("imprint.documents.validate_crdt_on_open", "validateCRDTOnOpen"),
            ("imprint.documents.auto_backup_before_migration", "autoBackupBeforeMigration"),
        ]
        for (_, legacy, value) in strings { suite.set(value, forKey: legacy) }
        for (_, legacy, value) in integers { suite.set(value, forKey: legacy) }
        for (_, legacy) in booleans { suite.set(false, forKey: legacy) }

        for _ in 0..<2 {
            for (key, legacy, value) in strings {
                XCTAssertEqual(settings.record(key)?.legacy, [legacy], key)
                XCTAssertEqual(settings.value(key, as: String.self), value, key)
                XCTAssertEqual(suite.string(forKey: legacy), value, legacy)
                XCTAssertEqual(settings.record(key)?.source, "stored", key)
            }
            for (key, legacy, value) in integers {
                XCTAssertEqual(settings.record(key)?.legacy, [legacy], key)
                XCTAssertEqual(settings.value(key, as: Int.self), value, key)
                XCTAssertEqual(suite.integer(forKey: legacy), value, legacy)
                XCTAssertEqual(settings.record(key)?.source, "stored", key)
            }
            for (key, legacy) in booleans {
                XCTAssertEqual(settings.record(key)?.legacy, [legacy], key)
                XCTAssertFalse(settings.value(key, as: Bool.self), key)
                XCTAssertNotNil(suite.object(forKey: legacy), legacy)
                XCTAssertFalse(suite.bool(forKey: legacy), legacy)
                XCTAssertEqual(settings.record(key)?.source, "stored", key)
            }
            settings._resetForTesting()
        }
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: scratch.appendingPathComponent("settings/app-imprint.json").path))
        settings.set("imprint.editor.font_size", 20)
        settings._resetForTesting()
        XCTAssertEqual(settings.value("imprint.editor.font_size", as: Int.self), 20)
        XCTAssertEqual(suite.integer(forKey: "editorFontSize"), 18,
                       "the canonical value wins after migration; the old value remains intact")
    }
}
