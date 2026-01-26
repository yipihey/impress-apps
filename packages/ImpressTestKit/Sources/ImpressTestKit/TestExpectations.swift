//
//  TestExpectations.swift
//  ImpressTestKit
//
//  Reusable predicates and expectations for UI testing.
//

import XCTest

// MARK: - Predicate Builders

/// Common predicates for UI testing
public enum TestPredicates {

    /// Element exists
    public static var exists: NSPredicate {
        NSPredicate(format: "exists == true")
    }

    /// Element does not exist
    public static var notExists: NSPredicate {
        NSPredicate(format: "exists == false")
    }

    /// Element is hittable (visible and interactive)
    public static var hittable: NSPredicate {
        NSPredicate(format: "isHittable == true")
    }

    /// Element is not hittable
    public static var notHittable: NSPredicate {
        NSPredicate(format: "isHittable == false")
    }

    /// Element is enabled
    public static var enabled: NSPredicate {
        NSPredicate(format: "isEnabled == true")
    }

    /// Element is disabled
    public static var disabled: NSPredicate {
        NSPredicate(format: "isEnabled == false")
    }

    /// Element is selected
    public static var selected: NSPredicate {
        NSPredicate(format: "isSelected == true")
    }

    /// Element has specific label
    public static func label(_ value: String) -> NSPredicate {
        NSPredicate(format: "label == %@", value)
    }

    /// Element label contains text
    public static func labelContains(_ text: String) -> NSPredicate {
        NSPredicate(format: "label CONTAINS %@", text)
    }

    /// Element has specific value
    public static func value(_ value: String) -> NSPredicate {
        NSPredicate(format: "value == %@", value)
    }

    /// Element count equals
    public static func count(_ count: Int) -> NSPredicate {
        NSPredicate(format: "count == %d", count)
    }

    /// Element count greater than
    public static func countGreaterThan(_ count: Int) -> NSPredicate {
        NSPredicate(format: "count > %d", count)
    }
}

// MARK: - XCUIElement Query Extensions

extension XCUIElementQuery {

    /// Wait for the query to match a specific count
    @discardableResult
    public func waitForCount(_ expectedCount: Int, timeout: TimeInterval = 5) -> Bool {
        let predicate = NSPredicate(format: "count == %d", expectedCount)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        return result == .completed
    }

    /// Wait for at least one element to exist
    @discardableResult
    public func waitForAnyElement(timeout: TimeInterval = 5) -> Bool {
        return waitForCount(1, timeout: timeout) || count > 0
    }
}

// MARK: - Assertion Helpers

/// Assertion helpers for cleaner test code
public enum TestAssertions {

    /// Assert element exists with custom message
    public static func assertExists(
        _ element: XCUIElement,
        message: String? = nil,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            element.exists,
            message ?? "Expected element '\(element.identifier)' to exist",
            file: file,
            line: line
        )
    }

    /// Assert element does not exist with custom message
    public static func assertNotExists(
        _ element: XCUIElement,
        message: String? = nil,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        XCTAssertFalse(
            element.exists,
            message ?? "Expected element '\(element.identifier)' to not exist",
            file: file,
            line: line
        )
    }

    /// Assert element is hittable with custom message
    public static func assertHittable(
        _ element: XCUIElement,
        message: String? = nil,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            element.isHittable,
            message ?? "Expected element '\(element.identifier)' to be hittable",
            file: file,
            line: line
        )
    }

    /// Assert element has specific text value
    public static func assertValue(
        _ element: XCUIElement,
        equals expected: String,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        let actual = element.value as? String ?? ""
        XCTAssertEqual(
            actual,
            expected,
            "Expected element '\(element.identifier)' to have value '\(expected)', got '\(actual)'",
            file: file,
            line: line
        )
    }

    /// Assert element has specific label
    public static func assertLabel(
        _ element: XCUIElement,
        equals expected: String,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            element.label,
            expected,
            "Expected element '\(element.identifier)' to have label '\(expected)', got '\(element.label)'",
            file: file,
            line: line
        )
    }

    /// Assert element count equals expected
    public static func assertCount(
        _ query: XCUIElementQuery,
        equals expected: Int,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            query.count,
            expected,
            "Expected \(expected) elements, found \(query.count)",
            file: file,
            line: line
        )
    }
}
