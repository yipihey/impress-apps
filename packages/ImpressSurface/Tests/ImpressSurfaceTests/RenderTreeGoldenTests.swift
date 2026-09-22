//
//  RenderTreeGoldenTests.swift
//  ImpressSurfaceTests
//
//  Decodes THE SAME GOLDEN the Rust side asserts against —
//  `crates/impress-surface/tests/golden/signal-explorer.render.json` — rather
//  than a hand-written fixture copied into this package's own resources.
//
//  This deliberately follows `LayoutModelTests`
//  (`apps/imbib/PublicationManagerCore/Tests/PublicationManagerCoreTests/
//  Layout/LayoutModelTests.swift`)'s own documented reasoning rather than
//  copying the golden into `Tests/ImpressSurfaceTests/Fixtures` (which
//  `docs/plan-agent-surfaces.md`'s S7 section describes as the mechanism): a
//  copy is a SECOND statement of the wire form, maintained by whoever last
//  touched Swift, and its failure mode is not a crash — a decode error
//  swallowed into "the pane is blank" looks exactly like "there is nothing
//  to show", the schema-ref class of bug. Reading the live file means a
//  serde change on the Rust side fails THIS test, on the next `swift test`,
//  instead of silently drifting until someone notices a pane went blank.
//
//  FFI-FREE on purpose, like `LayoutModelTests`: nothing here opens a
//  `SharedSurface`, so this suite runs under a plain `swift test`.
//

import Foundation
import Testing

@testable import ImpressSurface

@Suite("RenderTree golden fixture")
struct RenderTreeGoldenTests {

    /// The repo root, five directories up from this file:
    /// `…/packages/ImpressSurface/Tests/ImpressSurfaceTests/<this>`.
    private static let repoRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // …/ImpressSurfaceTests
            .deletingLastPathComponent()  // …/Tests
            .deletingLastPathComponent()  // …/ImpressSurface
            .deletingLastPathComponent()  // …/packages
            .deletingLastPathComponent()  // repo root
    }()

    private static let goldenPath =
        "crates/impress-surface/tests/golden/signal-explorer.render.json"

    private func goldenData() throws -> Data {
        try Data(contentsOf: Self.repoRoot.appendingPathComponent(Self.goldenPath))
    }

    /// A moved test file (or a moved golden) turns every read below into a
    /// silent skip — this test exists so that shows up as a FAILURE instead.
    @Test("the golden is where this suite thinks it is")
    func goldenIsAtTheExpectedPath() throws {
        let text = try String(data: goldenData(), encoding: .utf8)
        let json = try #require(text)
        #expect(json.contains("\"focus_order\""))
        #expect(json.contains("\"kind\": \"table\""))
    }

    @Test("decodes every node kind present in the golden, and focus_order")
    func decodesEveryNodeKindAndFocusOrder() throws {
        let tree = try JSONDecoder().decode(RenderTree.self, from: goldenData())

        // `focus_order`: the two sliders, the table, the button — in
        // depth-first reading order (see the golden's own comment on
        // `crates/impress-surface/src/resolve.rs`'s `focus_order` doc).
        #expect(tree.focusOrder == ["n0.1.0", "n0.1.1", "n0.3", "n0.4"])

        guard case .column(let items) = tree.root.node else {
            Issue.record("expected the root to decode as .column")
            return
        }
        #expect(items.count == 5)

        // n0.0 — text
        guard case .text(let text) = items[0].node else {
            Issue.record("n0.0 should decode as .text"); return
        }
        #expect(text == "# Signal explorer")

        // n0.1 — row of two sliders (field)
        guard case .row(let rowItems) = items[1].node else {
            Issue.record("n0.1 should decode as .row"); return
        }
        #expect(rowItems.count == 2)
        for (index, field) in rowItems.enumerated() {
            guard case .field(let fieldSpec, let bind, let value) = field.node else {
                Issue.record("n0.1.\(index) should decode as .field"); return
            }
            #expect(fieldSpec.objectValue?["slider"] != nil)
            #expect(bind == (index == 0 ? "state.freq" : "state.bins"))
            #expect(value.doubleValue != nil)
        }
        #expect(rowItems[0].label == "Frequency")
        #expect(rowItems[1].label == "Bins")

        // n0.2 — plot
        guard case .plot(let spec) = items[2].node else {
            Issue.record("n0.2 should decode as .plot"); return
        }
        #expect(spec.objectValue?["kind"]?.stringValue == "plot-spec@1.0.0")

        // n0.3 — table
        guard case .table(let rows, let columns) = items[3].node else {
            Issue.record("n0.3 should decode as .table"); return
        }
        #expect(columns == ["title", "year"])
        #expect(rows.arrayValue?.count == 2)

        // n0.4 — button
        guard case .button(let label) = items[4].node else {
            Issue.record("n0.4 should decode as .button"); return
        }
        #expect(label == "Use these bins")
    }

    @Test("an unrecognised kind tag degrades to .placeholder, not a decode error")
    func unknownKindDegradesToPlaceholder() throws {
        let json = """
            {"id": "x", "node": {"kind": "some-future-widget", "anything": 1}}
            """
        let node = try JSONDecoder().decode(RenderNode.self, from: Data(json.utf8))
        guard case .placeholder(let unknownKind, let reason) = node.node else {
            Issue.record("unrecognised kind should decode as .placeholder")
            return
        }
        #expect(unknownKind == "some-future-widget")
        #expect(reason == nil)
    }
}
