//
//  KoineStyleTests.swift
//  ImpressSurfaceTests
//
//  Pins Swift's slot table to the vocabulary Rust writes
//  (`crates/koine/tests/fixtures/style-vocabulary.json`). A kind or a default
//  that drifts fails here, on `swift test`, rather than painting a line
//  template as a color.
//

import Foundation
import Testing

@testable import ImpressSurface

@Suite("Koine style sheet")
struct KoineStyleTests {


    private struct Vocabulary: Decodable {
        let wireVersion: Int
        let frontends: [String: Frontend]
        let placeholders: [String]
        let spacing: Bounds
        let tokens: [String: [String]]
    }

    private struct Frontend: Decodable {
        let slots: [Slot]
    }

    private struct Slot: Decodable {
        let name: String
        let kind: String
        let `default`: String
    }

    private struct Bounds: Decodable {
        let min: Int
        let max: Int
    }

    @Test("Swift's table matches the committed vocabulary, slot for slot")
    func swiftTableMatchesTheVocabularyFile() throws {
        let url = try KoineCheckout.file("crates/koine/tests/fixtures/style-vocabulary.json")
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let vocabulary = try decoder.decode(Vocabulary.self, from: data)

        #expect(vocabulary.wireVersion == 1)
        #expect(vocabulary.placeholders == KoineStyleSheet.placeholders)
        #expect(vocabulary.tokens["color"] == KoineStyleSheet.colorTokens)
        #expect(vocabulary.tokens["font"] == KoineStyleSheet.fontTokens)
        #expect(vocabulary.spacing.min == 0)
        #expect(vocabulary.spacing.max == KoineStyleSheet.spacingMax)
        #expect(Set(vocabulary.frontends.keys) == Set(KoineStyleSheet.frontendIDs))

        for frontend in KoineStyleSheet.frontendIDs {
            let fileSlots = try #require(vocabulary.frontends[frontend]).slots
            let local = try #require(KoineStyleSheet.slots(frontend: frontend))
            #expect(fileSlots.map(\.name) == local.map(\.name))
            for (fileSlot, localSlot) in zip(fileSlots, local) {
                #expect(fileSlot.kind == localSlot.kind.rawValue)
                #expect(fileSlot.default == localSlot.defaultValue)
            }
        }
    }

    @Test("set refuses an unknown slot and a value of the wrong kind")
    func setRefusesUnknownSlotAndWrongKind() throws {
        var book = KoineStyleBook()
        #expect(throws: KoineStyleError.self) {
            try book.set(frontend: "swift", slot: "grid", raw: "8")
        }
        #expect(throws: KoineStyleError.self) {
            try book.set(frontend: "swift", slot: "button", raw: "button {label}")
        }
        let swift = try #require(book.sheet(frontend: "swift"))
        #expect(swift.value("button") == "automatic")
        #expect(swift.color("button") == nil)
        #expect(swift.spacing("column") == 8)

        try book.set(frontend: "swift", slot: "button", raw: "accent")
        #expect(book.sheet(frontend: "swift")?.value("button") == "accent")
        try book.reset(frontend: "swift", slot: "button")
        #expect(book.sheet(frontend: "swift")?.value("button") == "automatic")

        try book.set(frontend: "tui", slot: "button", raw: "[{label}]")
        #expect(throws: KoineStyleError.self) {
            try book.set(frontend: "tui", slot: "column", raw: "wide")
        }
        #expect(book.sheet(frontend: "tui")?.value("column") == "2")
        #expect(throws: KoineStyleError.self) {
            try book.set(frontend: "web", slot: "button", raw: "accent")
        }
    }

    @Test("a text sheet is not what Swift paints")
    func aTextSheetIsNotPainted() {
        let tui = KoineStyleSheet.make(KoineStyleSheet.tuiID)
        #expect(tui.paintedBySwift.frontend == KoineStyleSheet.swiftID)
        #expect(tui.paintedBySwift.value("button") == "automatic")
        #expect(tui.color("button") == nil)
    }

    @Test("a partial style file keeps the other slots at their defaults")
    func partialFileFillsDefaults() throws {
        let url = try KoineCheckout.file("crates/koine/tests/fixtures/style-file.json")
        let book = try KoineStyleFile.book(from: Data(contentsOf: url))
        let swift = try #require(book.sheet(frontend: "swift"))
        #expect(swift.value("button") == "accent")
        #expect(swift.value("text") == "title")
        #expect(swift.value("column") == "8")
        #expect(swift.value("focus") == "automatic")
        let tui = try #require(book.sheet(frontend: "tui"))
        #expect(tui.value("button") == "[{label}]")
        #expect(tui.value("focus") == ">")

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("koine-style-\(UUID().uuidString)", isDirectory: true)
        let file = KoineStyleFile.url(workspace: directory)
        try KoineStyleFile.save(book, to: file)
        let loaded = try KoineStyleFile.load(from: file).get()
        #expect(loaded.sheet(frontend: "swift")?.value("button") == "accent")
        #expect(loaded.sheet(frontend: "tui")?.value("column") == "2")
        try? FileManager.default.removeItem(at: directory)
    }
}
