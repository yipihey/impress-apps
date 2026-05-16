import Testing
@testable import ImpressKit
import Foundation

@Suite("SharedWorkspace Tests")
struct SharedWorkspaceTests {

    @Test("Database URL is in group container or dev fallback")
    func testDatabaseURLIsInGroupContainer() {
        let url = SharedWorkspace.databaseURL
        let path = url.path
        #expect(
            path.contains("com.impress.suite") || path.contains("impress"),
            "Expected shared workspace path, got: \(path)"
        )
        #expect(path.hasSuffix("workspace/impress.sqlite"))
    }

    @Test("Workspace directory is parent of database file")
    func testWorkspaceDirectoryIsParentOfDatabase() {
        let dbURL = SharedWorkspace.databaseURL
        let dirURL = SharedWorkspace.workspaceDirectory
        #expect(dbURL.deletingLastPathComponent().path == dirURL.path)
    }

    @Test("ensureDirectoryExists is idempotent")
    func testEnsureDirectoryExistsIsIdempotent() throws {
        // Should not throw even if called multiple times
        try SharedWorkspace.ensureDirectoryExists()
        try SharedWorkspace.ensureDirectoryExists()
        let exists = FileManager.default.fileExists(atPath: SharedWorkspace.workspaceDirectory.path)
        #expect(exists)
    }

    @Test("migrateLegacyDatabase returns false for nonexistent source")
    func testMigrateLegacyNonexistentSourceReturnsFalse() throws {
        let nonexistent = URL(fileURLWithPath: "/tmp/nonexistent_\(UUID().uuidString).sqlite")
        let migrated = try SharedWorkspace.migrateLegacyDatabase(from: nonexistent)
        #expect(migrated == false)
    }
}
