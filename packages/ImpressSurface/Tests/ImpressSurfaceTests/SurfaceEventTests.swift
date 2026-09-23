//
//  SurfaceEventTests.swift
//  ImpressSurfaceTests
//
//  `SurfaceEvent` must encode with EXACTLY the three keys
//  `impress_surface::spec::Event` has (`widget`, `kind`, `value`) — the JSON
//  `SurfaceView` hands to `SharedSurface.dispatch(surfaceId:pane:eventJson:)`,
//  which decodes it as that Rust type on the far side.
//

import Foundation
import Testing

@testable import ImpressSurface

@Suite("SurfaceEvent encoding")
struct SurfaceEventTests {

    @Test("encodes exactly the three Rust field names")
    func encodesTheThreeRustFields() throws {
        let event = SurfaceEvent(widget: "n0.1.1", kind: .change, value: .int(40))
        let data = try JSONEncoder().encode(event)
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(Set(object.keys) == ["widget", "kind", "value"])
        #expect(object["widget"] as? String == "n0.1.1")
        #expect(object["kind"] as? String == "change")
        #expect(object["value"] as? Int == 40)
    }

    @Test("every EventKind matches Rust's snake_case spelling")
    func eventKindSpellings() {
        #expect(SurfaceEvent.Kind.change.rawValue == "change")
        #expect(SurfaceEvent.Kind.click.rawValue == "click")
        #expect(SurfaceEvent.Kind.select.rawValue == "select")
        #expect(SurfaceEvent.Kind.submit.rawValue == "submit")
    }

    @Test("value defaults to null, matching Event's #[serde(default)] on value")
    func valueDefaultsToNull() throws {
        let event = SurfaceEvent(widget: "btn", kind: .click)
        let data = try JSONEncoder().encode(event)
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["value"] is NSNull)
    }

    @Test("a select event's array-of-strings value round-trips")
    func selectValueRoundTrips() throws {
        let event = SurfaceEvent(
            widget: "papers-table", kind: .select,
            value: .array([.string("a"), .string("b")]))
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(SurfaceEvent.self, from: data)
        #expect(decoded == event)
        #expect(decoded.value.arrayValue?.compactMap(\.stringValue) == ["a", "b"])
    }
}
