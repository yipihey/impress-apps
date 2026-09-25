//
//  SurfaceFieldLogicTests.swift
//  ImpressSurfaceTests
//
//  When a field's value leaves `SurfaceView` (plan wave 7, T3):
//  - typed values go out before another widget's action (SK-K3);
//  - a select or date field sends nothing the person did not choose (SK-K12).
//

import Foundation
import Testing

@testable import ImpressSurface

@MainActor
@Suite("Surface field values")
struct SurfaceFieldLogicTests {

    // MARK: SK-K3 — typed values are not lost

    @Test("a click goes out after the change of every field typed into and not yet sent")
    func clickFlushesTypedDraftsFirst() {
        let book = SurfaceDraftBook()
        book.stage("name", .string("Ada"))
        book.stage("count", .double(3))
        let events = book.outgoing(SurfaceEvent(widget: "go", kind: .click))
        #expect(
            events == [
                SurfaceEvent(widget: "name", kind: .change, value: .string("Ada")),
                SurfaceEvent(widget: "count", kind: .change, value: .double(3)),
                SurfaceEvent(widget: "go", kind: .click),
            ])
        // Sent once: the next click carries nothing extra.
        #expect(book.outgoing(SurfaceEvent(widget: "go", kind: .click)).count == 1)
    }

    @Test("a select and a submit flush drafts too; a change goes alone and spends its own draft")
    func selectAndSubmitFlushChangeDoesNot() {
        let book = SurfaceDraftBook()
        book.stage("q", .string("dark matter"))
        #expect(book.outgoing(SurfaceEvent(widget: "t", kind: .select, value: .array([]))).count == 2)

        book.stage("q", .string("halo"))
        let change = SurfaceEvent(widget: "q", kind: .change, value: .string("halo"))
        #expect(book.outgoing(change) == [change])
        #expect(!book.has("q"))

        book.stage("q", .string("halos"))
        #expect(book.outgoing(SurfaceEvent(widget: "q", kind: .submit)).map(\.kind) == [.change, .submit])
    }

    @Test("editing a field back to its stored value leaves nothing to send")
    func typingBackTheStoredValueIsNotADraft() {
        let stored = SurfaceJSONValue.string("Ada")
        #expect(SurfaceFieldLogic.textDraft("Ada", stored: stored) == nil)
        #expect(SurfaceFieldLogic.textDraft("Ad", stored: stored) == .string("Ad"))
        let book = SurfaceDraftBook()
        book.stage("name", SurfaceFieldLogic.textDraft("Ad", stored: stored))
        book.stage("name", SurfaceFieldLogic.textDraft("Ada", stored: stored))
        #expect(!book.has("name"))
    }

    @Test("a number draft is sent only when it parses and differs")
    func numberDrafts() {
        #expect(SurfaceFieldLogic.numberDraft("17", stored: .int(12)) == .double(17))
        #expect(SurfaceFieldLogic.numberDraft(" 12 ", stored: .int(12)) == nil)
        #expect(SurfaceFieldLogic.numberDraft("twelve", stored: .int(12)) == nil)
        #expect(SurfaceFieldLogic.numberSeed(.int(12)) == "12")
        #expect(SurfaceFieldLogic.numberSeed(.double(0.25)) == "0.25")
        #expect(SurfaceFieldLogic.numberSeed(.null) == "")
    }

    // MARK: SK-K12 — nothing the person did not choose

    @Test("a select bound to null seeds to nothing chosen, not the first option")
    func selectNullChoosesNothing() {
        let seed = SurfaceFieldLogic.selectSeed(.null)
        #expect(seed == "")
        #expect(!SurfaceFieldLogic.selectShouldEmit(seed, stored: .null))
        #expect(SurfaceFieldLogic.selectShouldEmit("linear", stored: .null))
        #expect(!SurfaceFieldLogic.selectShouldEmit("log", stored: .string("log")))
    }

    @Test("an agent's date-only value is read as that calendar day and is not re-sent")
    func dateOnlyValueIsADay() throws {
        var calendar = Calendar(identifier: .gregorian)
        // West of UTC, where midnight UTC is still the previous day.
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let stored = SurfaceJSONValue.string("2026-09-25")
        let seed = try #require(SurfaceFieldLogic.parseDate(stored, calendar: calendar))
        let parts = calendar.dateComponents([.year, .month, .day], from: seed)
        #expect(parts.year == 2026 && parts.month == 9 && parts.day == 25)
        // Seeding from the stored value is never a change.
        #expect(!SurfaceFieldLogic.dateShouldEmit(seed, stored: stored, calendar: calendar))
        // A day the person picks goes out in the agent's own shape.
        let picked = try #require(calendar.date(byAdding: .day, value: 1, to: seed))
        #expect(SurfaceFieldLogic.dateShouldEmit(picked, stored: stored, calendar: calendar))
        #expect(SurfaceFieldLogic.dateString(picked, like: stored, calendar: calendar) == "2026-09-26")
    }

    @Test("a full ISO-8601 date-time is accepted and kept in that shape")
    func fullDateTimeValue() throws {
        let stored = SurfaceJSONValue.string("2026-09-25T10:00:00Z")
        let date = try #require(SurfaceFieldLogic.parseDate(stored))
        #expect(!SurfaceFieldLogic.dateShouldEmit(date, stored: stored))
        #expect(SurfaceFieldLogic.dateString(date, like: stored).hasSuffix("Z"))
        #expect(SurfaceFieldLogic.parseDate(.string("2026-09-25T10:00:00.123Z")) != nil)
        #expect(SurfaceFieldLogic.parseDate(.string("not a date")) == nil)
        #expect(SurfaceFieldLogic.parseDate(.null) == nil)
    }
}
