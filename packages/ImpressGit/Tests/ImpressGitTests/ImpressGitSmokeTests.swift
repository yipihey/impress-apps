import Testing
import Foundation
@testable import ImpressGit

// This target previously had no `Tests/ImpressGitTests` directory even though
// `Package.swift` declared the test target. SwiftPM then collapsed the whole
// `Sources/ImpressGit` tree into the test target, producing an
// "overlapping sources" resolution error that blocked every local app build
// via xcodebuild. This file gives the declared test target a real home.
@Suite("ImpressGit Smoke")
struct ImpressGitSmokeTests {

    @Test("FileState raw values are stable")
    func fileStateRawValues() {
        #expect(FileState.modified.rawValue == "Modified")
        #expect(FileState.added.rawValue == "Added")
        #expect(FileState.deleted.rawValue == "Deleted")
    }

    @Test("FileStatus round-trips through Codable")
    func fileStatusCodable() throws {
        let status = FileStatus(path: "README.md", status: .modified)
        let data = try JSONEncoder().encode(status)
        let decoded = try JSONDecoder().decode(FileStatus.self, from: data)
        #expect(decoded.path == "README.md")
        #expect(decoded.status == .modified)
    }
}
