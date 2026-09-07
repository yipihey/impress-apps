//
//  EInkTriageContractTests.swift
//  PublicationManagerCoreTests
//
//  The verb side of the reMarkable USB mirror (ADR-025, P6): which kind can
//  mirror, which key does it, and that the published grammar says so. These
//  are the regression oracle for docs/chassis-capability-matrix.md's new
//  Mirror column and docs/keyboard-grammar.md's `e` / ⌃⌘E rows.
//

import ImpressKeyboard
import XCTest
@testable import PublicationManagerCore

final class EInkTriageContractTests: XCTestCase {

    // MARK: Capability

    /// The publication kind is the ONE kind that can mirror — the engine
    /// sends its PDF/ePUB and the mirror rows hang off its records. Every
    /// other shipped descriptor must say no, or `TriageMenu` would offer a
    /// verb the store cannot honour.
    func testOnlyPublicationsCanMirrorToEink() {
        XCTAssertTrue(PublicationRecordKind.descriptor.triage.canMirrorToEink)
        for descriptor in BuiltinRecordKinds.all where descriptor.id != PublicationRecordKind.descriptor.id {
            XCTAssertFalse(descriptor.triage.canMirrorToEink, "\(descriptor.id) must not declare canMirrorToEink")
        }
        // The default for a kind that says nothing is "cannot".
        XCTAssertFalse(TriageCapabilities().canMirrorToEink)
    }

    /// Capability says "can ever"; row state says "applies now". A nil
    /// `isMirrored` is how a host hides the verb while no device in
    /// individual mode is configured.
    func testRowStateGatesTheVerbAndPhrasesIt() {
        let hidden = TriageRowState(isStarred: false, isDismissed: false)
        XCTAssertNil(hidden.isMirrored)
        XCTAssertEqual(hidden.mirrorToggleLabel, EInkMirrorState.mirrorVerb)

        let unmirrored = TriageRowState(isStarred: false, isDismissed: false, isMirrored: false)
        XCTAssertEqual(unmirrored.mirrorToggleLabel, "Mirror to reMarkable")

        let onTablet = TriageRowState(
            isStarred: false, isDismissed: false,
            isMirrored: true, mirrorMenuVerb: EInkMirrorState.uploaded.menuVerb)
        XCTAssertEqual(onTablet.mirrorToggleLabel, "Remove from reMarkable")

        let genericMirrored = TriageRowState(isStarred: false, isDismissed: false, isMirrored: true)
        XCTAssertEqual(genericMirrored.mirrorToggleLabel, "Remove from reMarkable")
    }

    // MARK: Keyboard grammar

    /// `e` is the suite-wide single key for the mirror toggle; it was
    /// unbound before, so nothing else may have claimed it.
    func testTheSingleKeyIsE() {
        XCTAssertEqual(TriageKeyGrammar.characterBindings["e"], .toggleEinkMirror)
        XCTAssertEqual(TriageKeyGrammar.command(forCharacters: "e"), .toggleEinkMirror)
        XCTAssertEqual(
            TriageKeyGrammar.characterBindings.filter { $0.value == .toggleEinkMirror }.count, 1,
            "exactly one key maps to the mirror toggle")
    }

    /// imbib's profile carries both the guarded `e` and the ⌃⌘E chord under
    /// stable ids (user remaps are stored against the id).
    func testImbibProfileBindsBothTheKeyAndTheChord() {
        let bindings = KeyboardShortcutsSettings.defaults.bindings
        guard let vim = bindings.first(where: { $0.id == "toggleEInkMirrorVim" }) else {
            return XCTFail("toggleEInkMirrorVim missing from the profile")
        }
        XCTAssertEqual(vim.key, .character("e"))
        XCTAssertEqual(vim.modifiers, .none)
        XCTAssertEqual(vim.notificationName, "toggleEInkMirror")

        guard let chord = bindings.first(where: { $0.id == "toggleEInkMirror" }) else {
            return XCTFail("toggleEInkMirror missing from the profile")
        }
        XCTAssertEqual(chord.key, .character("e"))
        XCTAssertEqual(chord.modifiers, [.control, .command])
        XCTAssertEqual(chord.notificationName, "toggleEInkMirror")
    }

    // MARK: Published grammar

    /// docs/keyboard-grammar.md is the human-readable mirror of the table;
    /// both rows must be there (rule 3 of that document).
    func testTheKeyboardGrammarDocumentsBothBindings() throws {
        let doc = try Self.source(of: "docs/keyboard-grammar.md")
        let lines = doc.components(separatedBy: "\n")
        XCTAssertTrue(
            lines.contains { $0.hasPrefix("| e |") && $0.contains("toggleEinkMirror") },
            "keyboard-grammar.md lacks the `e` row for TriageKeyGrammar.toggleEinkMirror")
        XCTAssertTrue(
            lines.contains { $0.hasPrefix("| ⌃⌘E |") },
            "keyboard-grammar.md lacks the ⌃⌘E row")
    }

    /// The capability matrix's descriptor contract carries the Mirror column
    /// with publication ✅ — the DoD surface for `canMirrorToEink`.
    func testTheCapabilityMatrixHasTheMirrorColumn() throws {
        let doc = try Self.source(of: "docs/chassis-capability-matrix.md")
        XCTAssertTrue(doc.contains("| Tag | Mirror |"), "descriptor contract table lacks the Mirror column")
        XCTAssertTrue(doc.contains("PUT /api/papers/eink"), "matrix does not record the eink routes")
    }

    // MARK: - Helpers

    /// Repo root: …/apps/imbib/PublicationManagerCore/Tests/PublicationManagerCoreTests/EInk/<this>
    private static let repoRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // EInk
            .deletingLastPathComponent()   // PublicationManagerCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // PublicationManagerCore
            .deletingLastPathComponent()   // imbib
            .deletingLastPathComponent()   // apps
            .deletingLastPathComponent()   // repo root
    }()

    private static func source(of relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
