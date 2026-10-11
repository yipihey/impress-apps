#if os(macOS)
//
//  KoineGestureTests.swift
//  ImpressLayoutTests
//
//  Pins the Swift chassis translation to the verbs Rust writes
//  (`crates/koine/tests/fixtures/gesture-verbs.json` in the pinned koine
//  checkout). A drag that becomes a different verb on one side fails here.

import XCTest

@testable import ImpressLayout

final class KoineGestureTests: XCTestCase {

    func testTheFixtureIsWhatLayoutVerbReturns() throws {
        let url = try KoineCheckout.file("crates/koine/tests/fixtures/gesture-verbs.json")
        let data = try Data(contentsOf: url)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Self.int(root["wire_version"]), 1)

        let cases = try XCTUnwrap(root["cases"] as? [[String: Any]])
        XCTAssertFalse(cases.isEmpty)
        for row in cases {
            let name = row["name"] as? String ?? "case"
            let gesture = try XCTUnwrap(Self.decodeGesture(row["gesture"]), name)
            let pane = Self.uint(row["pane"])
            let verb = gesture.layoutVerb(pane: pane)
            let produced = try Self.jsonObject(verb.flatMap(KoineGesture.document(for:)))
            let expected = try Self.jsonObject(row["verb"])
            XCTAssertEqual(produced, expected, name)
        }

        for row in try XCTUnwrap(root["tab_split"] as? [[String: Any]]) {
            let children = try XCTUnwrap(Self.ints(row["children"])).map { UInt64($0) }
            let index = try XCTUnwrap(Self.int(row["index"]))
            let placement = try XCTUnwrap(LayoutPlacement(rawValue: row["placement"] as? String ?? ""))
            let target = KoineGesture.tabSplitTarget(
                children: children, index: index, placement: placement)
            XCTAssertEqual(target.map(Int.init), Self.int(row["target"]))
        }

        for row in try XCTUnwrap(root["split_axes"] as? [[String: Any]]) {
            let placement = try XCTUnwrap(LayoutPlacement(rawValue: row["placement"] as? String ?? ""))
            let (dir, after) = KoineGesture.splitAxes(placement)
            XCTAssertEqual(dir.rawValue, row["dir"] as? String)
            XCTAssertEqual(after, Self.bool(row["after"]))
        }

        for row in try XCTUnwrap(root["tab_order"] as? [[String: Any]]) {
            let pane = try XCTUnwrap(Self.uint(row["pane"]))
            let tabs = try XCTUnwrap(row["tabs"] as? [String])
            let from = try XCTUnwrap(Self.int(row["from"]))
            let to = try XCTUnwrap(Self.int(row["to"]))
            let verb = KoineGesture.tabOrderVerb(pane: pane, tabs: tabs, from: from, to: to)
            let produced = try Self.jsonObject(verb?.verbJSON)
            let expected = try Self.jsonObject(row["verb"])
            XCTAssertEqual(produced, expected)
        }

        for row in try XCTUnwrap(root["resize"] as? [[String: Any]]) {
            let container = try XCTUnwrap(Self.uint(row["container"]))
            let shares = try XCTUnwrap(Self.doubles(row["shares"]))
            let index = try XCTUnwrap(Self.int(row["index"]))
            let before = try XCTUnwrap(Self.double(row["before"]))
            let after = try XCTUnwrap(Self.double(row["after"]))
            let produced = try Self.jsonObject(
                KoineGesture.resizeVerbJSON(
                    container: container, shares: shares, index: index, before: before, after: after))
            let expected = try Self.jsonObject(row["verb"])
            XCTAssertEqual(produced, expected)
        }

        for row in try XCTUnwrap(root["dividers"] as? [[String: Any]]) {
            let count = try XCTUnwrap(Self.int(row["child_count"]))
            let index = try XCTUnwrap(Self.int(row["index"]))
            let edge = try XCTUnwrap(KoineEdge(rawValue: row["edge"] as? String ?? ""))
            XCTAssertEqual(
                KoineGesture.dividerIndex(childCount: count, index: index, edge: edge),
                Self.int(row["divider"]))
        }
    }

    private static func decodeGesture(_ value: Any?) -> KoineGesture? {
        guard let object = value as? [String: Any], let name = object["gesture"] as? String else {
            return nil
        }
        switch name {
        case "focus":
            guard let element = decodeElement(object["element"]) else { return nil }
            return .focus(element)
        case "activate":
            guard let element = decodeElement(object["element"]) else { return nil }
            return .activate(element)
        case "secondary":
            guard let element = decodeElement(object["element"]) else { return nil }
            return .secondary(element)
        case "move":
            guard let direction = LayoutFocusDirection(rawValue: object["direction"] as? String ?? "")
            else { return nil }
            return .move(direction)
        case "drag":
            guard let element = decodeElement(object["element"]),
                  let target = decodeElement(object["target"]),
                  let placement = LayoutPlacement(rawValue: object["placement"] as? String ?? "")
            else { return nil }
            return .drag(element: element, target: target, placement: placement)
        case "resize":
            guard let element = decodeElement(object["element"]),
                  let edge = KoineEdge(rawValue: object["edge"] as? String ?? "")
            else { return nil }
            return .resize(element: element, edge: edge)
        default:
            return nil
        }
    }

    private static func decodeElement(_ value: Any?) -> KoineElement? {
        guard let object = value as? [String: Any], let kind = object["kind"] as? String else {
            return nil
        }
        switch kind {
        case "widget":
            guard let id = object["id"] as? String else { return nil }
            return .widget(id)
        case "tile":
            guard let id = uint(object["id"]) else { return nil }
            return .tile(id)
        case "focused":
            return .focused
        default:
            return nil
        }
    }

    private static func uint(_ value: Any?) -> UInt64? {
        switch value {
        case let number as Int:
            return UInt64(number)
        case let number as UInt64:
            return number
        case let number as NSNumber:
            return number.uint64Value
        default:
            return nil
        }
    }

    private static func int(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }

    private static func ints(_ value: Any?) -> [Int]? {
        (value as? [Any])?.compactMap(int)
    }

    private static func double(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private static func doubles(_ value: Any?) -> [Double]? {
        (value as? [Any])?.compactMap(double)
    }

    private static func bool(_ value: Any?) -> Bool? {
        (value as? NSNumber)?.boolValue
    }

    /// `nil` and JSON null compare equal. Numbers compare as JSON values, so
    /// `2` and `2.0` are the same share.
    private static func jsonObject(_ value: LayoutJSONValue?) throws -> NSObject {
        guard let value else { return NSNull() }
        let data = try Data(value.jsonString().utf8)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? NSObject)
    }

    private static func jsonObject(_ value: Any?) throws -> NSObject {
        if value == nil || value is NSNull { return NSNull() }
        let data = try JSONSerialization.data(withJSONObject: value!)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? NSObject)
    }
}
#endif
