//
//  RecordListHostTests.swift
//  PublicationManagerCoreTests
//
//  C1's regression oracle for the shared iOS list host.
//
//  The RENDERER is `#if os(iOS)`, so `swift test` (macOS) cannot instantiate it.
//  What it CAN pin is the half that was written twice as logic rather than as
//  chrome — the three-state rule and the row-identifier convention — plus the
//  structural facts that keep the split honest: the model half must not be
//  platform-gated (imprint-iOS and impart-iOS both compile it), the renderer
//  must stay iOS-gated (it uses `navigationBarTitleDisplayMode` and
//  `.topBarTrailing`), and the two adopters must not have kept a private `List`
//  behind the host.
//

import XCTest
@testable import PublicationManagerCore

final class RecordListHostTests: XCTestCase {

    // MARK: - The three-state rule

    /// A reload with rows on screen keeps the rows. impart got this right
    /// (`isLoading && rows.isEmpty`); imprint had no loading state at all, so
    /// the rule existed once and a half.
    func testLoadingNeverReplacesRowsAlreadyOnScreen() {
        XCTAssertEqual(RecordListPhase.resolve(rowCount: 12, isLoading: true), .rows)
        XCTAssertEqual(RecordListPhase.resolve(rowCount: 1, isLoading: true), .rows)
    }

    func testSpinnerOnlyForAFirstReadWithNothingToShow() {
        XCTAssertEqual(RecordListPhase.resolve(rowCount: 0, isLoading: true), .loading)
    }

    /// No rows and no read in flight is the EMPTY STATE, not a spinner — the
    /// difference between "nothing has been mirrored into this device yet" and
    /// an indefinite progress view.
    func testEmptyStateWhenNothingIsLoading() {
        XCTAssertEqual(RecordListPhase.resolve(rowCount: 0, isLoading: false), .empty)
    }

    // MARK: - The row identifier convention

    /// Both shipped UI suites match row identifiers BY PREFIX
    /// (`LibraryShellUITests.firstRowTitle`,
    /// `MailShellUITests`'s `BEGINSWITH` predicates), so the separator belongs
    /// to the prefix and the id is an uppercase `uuidString` — the form those
    /// predicates were written against.
    func testRowIdentifierIsPrefixPlusUUIDString() {
        let id = UUID(uuidString: "4E2F6A1C-0000-4000-8000-000000000001")!
        XCTAssertEqual(
            RecordListRowIdentity.identifier(prefix: "manuscriptRow.", id: id),
            "manuscriptRow.4E2F6A1C-0000-4000-8000-000000000001")
        XCTAssertEqual(
            RecordListRowIdentity.identifier(prefix: "messageRow.", id: id),
            "messageRow.4E2F6A1C-0000-4000-8000-000000000001")
    }

    // MARK: - Structural: the split stays a split

    func testModelHalfIsNotPlatformGated() throws {
        let text = try Self.source("Chassis/RecordKind/RecordListHostModel.swift")
        XCTAssertFalse(text.hasPrefix("#if os("), "the host's DATA half must compile everywhere")
    }

    func testRendererStaysIOSGated() throws {
        let text = try Self.source("Chassis/RecordKind/RecordListHostView.swift")
        XCTAssertTrue(
            text.hasPrefix("#if os(iOS)"),
            """
            RecordListHostView must stay iOS-gated: it uses \
            navigationBarTitleDisplayMode and ToolbarItemPlacement.topBarTrailing, \
            neither of which exists on macOS. If a macOS host ever wants this \
            chrome, SPLIT again — do not un-gate.
            """)
    }

    /// The adopters must not have kept their own `List` + search field behind
    /// the host — that would be the duplication with an extra hop.
    func testAdoptersDoNotHandWriteAListOrASearchField() throws {
        for relativePath in [
            "apps/imprint/imprint-iOS/Views/IOSManuscriptLibraryView.swift",
            "apps/impart/impart-iOS/Views/IOSMessageListColumn.swift",
        ] {
            let url = Self.repoRoot.appendingPathComponent(relativePath)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                // The app targets are not part of this package's checkout in
                // every build context; skip rather than fail on absence.
                continue
            }
            // CODE only. These files talk about `.recordTriageRow` in their
            // headers — describing what the shared host wires on their behalf
            // is exactly the documentation this pass wants to keep, so a raw
            // `contains` would fail on the prose it should be encouraging.
            let code = text
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { line in
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    return !trimmed.hasPrefix("//") && !trimmed.hasPrefix("*")
                }
                .joined(separator: "\n")

            XCTAssertTrue(
                code.contains("RecordListHost("),
                "\(relativePath) should render the shared host")
            XCTAssertFalse(
                code.contains("List(selection:"),
                "\(relativePath) must not hand-write a List behind the host")
            XCTAssertFalse(
                code.contains(".searchable("),
                "\(relativePath) must not hand-write the search field")
            XCTAssertFalse(
                code.contains(".recordTriageRow("),
                "\(relativePath) must not wire triage rows itself — the host does")
        }
    }

    // MARK: - Paths

    /// `<package>/Sources/PublicationManagerCore/<relativePath>`, derived from
    /// this file's own location so the test is location-independent.
    private static func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // PublicationManagerCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // package root
            .appendingPathComponent("Sources/PublicationManagerCore")
        return try String(
            contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// The repo root: this file lives at
    /// `<repo>/apps/imbib/PublicationManagerCore/Tests/PublicationManagerCoreTests/`.
    private static let repoRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // PublicationManagerCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // PublicationManagerCore
            .deletingLastPathComponent()  // imbib
            .deletingLastPathComponent()  // apps
            .deletingLastPathComponent()  // <repo>
    }()
}
