#if os(macOS)
import Foundation
import XCTest
@testable import PublicationManagerCore

final class SidebarCapabilityMatrixTests: XCTestCase {
    /// The node enum's exhaustive `kind` switch makes a new case a compile
    /// error; CaseIterable then makes its capability row part of this golden.
    /// The table is a projection of the same policy the outline uses, not a
    /// second, hand-maintained inventory of expected node names.
    func testEverySidebarNodeKindHasTheDocumentedOutlineCapabilities() throws {
        let rendered = (["| Node kind | Drag | Drop | Rename | Delete |",
                         "|---|---|---|---|---|"]
            + ImbibSidebarNodeKind.allCases.map { kind in
                let cells: [String]
                switch kind.outlineCapabilityPolicy {
                case .recordBinding:
                    cells = Array(repeating: "binding", count: 4)
                case .fixed(let capabilities):
                    cells = [capabilities.contains(.draggable),
                             capabilities.contains(.droppable),
                             capabilities.contains(.renamable),
                             capabilities.contains(.deletable)]
                        .map { $0 ? "yes" : "no" }
                }
                return "| `\(kind.rawValue)` | \(cells.joined(separator: " | ")) |"
            }).joined(separator: "\n")

        let relativePath = "docs/chassis-capability-matrix.md"
        let fileManager = FileManager.default
        let start = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let ancestors = sequence(first: start, next: { url -> URL? in
            let parent = url.deletingLastPathComponent()
            return parent.path == url.path ? nil : parent
        })
        let documentURL = try XCTUnwrap(ancestors
            .map { $0.appendingPathComponent(relativePath) }
            .first { fileManager.fileExists(atPath: $0.path) })
        let document = try String(contentsOf: documentURL, encoding: .utf8)
        let begin = "<!-- sidebar-node-capabilities:begin -->\n"
        let end = "\n<!-- sidebar-node-capabilities:end -->"
        let afterBegin = try XCTUnwrap(document.range(of: begin)).upperBound
        let beforeEnd = try XCTUnwrap(document.range(of: end, range: afterBegin..<document.endIndex)).lowerBound
        XCTAssertEqual(String(document[afterBegin..<beforeEnd]), rendered,
                       "Regenerate the outline capability table from ImbibSidebarNodeKind.allCases")
    }

    func testSectionAndFolderPoliciesPreserveTheirDistinctRoutes() {
        XCTAssertEqual(ImbibSidebarNodeType.section(.inbox).kind, .sectionInbox)
        XCTAssertEqual(ImbibSidebarNodeType.section(.libraries).kind, .section)
        XCTAssertEqual(ImbibSidebarNodeType.recordFolder(
            bindingID: "manuscript", folderID: "example").kind, .recordFolder)
        if case .recordBinding = ImbibSidebarNodeKind.recordFolder.outlineCapabilityPolicy {
            // The binding, rather than this enum, decides whether a folder can
            // be reorganised. The golden names that dynamic policy explicitly.
        } else {
            XCTFail("recordFolder must retain its binding-dependent capabilities")
        }
    }
}
#endif
