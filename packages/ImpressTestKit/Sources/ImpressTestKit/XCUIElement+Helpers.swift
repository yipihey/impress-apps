//
//  XCUIElement+Helpers.swift
//  ImpressTestKit
//
//  Shared XCUIElement helpers for UI testing across impress apps.
//

import XCTest

// MARK: - XCUIApplication Extensions

extension XCUIApplication {
    /// Finds an element by its accessibility identifier
    public func element(id: String) -> XCUIElement {
        descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// Subscript access to elements by accessibility identifier
    public subscript(id: String) -> XCUIElement {
        element(id: id)
    }
}

// MARK: - XCUIElement Extensions

extension XCUIElement {
    /// Finds a descendant element by its accessibility identifier
    public func descendant(id: String) -> XCUIElement {
        descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// Waits for the element to exist and returns self for chaining
    @discardableResult
    public func waitForExistenceAndReturn(timeout: TimeInterval = 5) -> XCUIElement {
        _ = waitForExistence(timeout: timeout)
        return self
    }

    /// Taps the element after waiting for it to exist
    public func tapWhenReady(timeout: TimeInterval = 5) {
        XCTAssertTrue(waitForExistence(timeout: timeout), "Element \(identifier) did not appear")
        tap()
    }

    /// Types text into the element after waiting for it to exist
    public func typeTextWhenReady(_ text: String, timeout: TimeInterval = 5) {
        XCTAssertTrue(waitForExistence(timeout: timeout), "Element \(identifier) did not appear")
        tap()
        typeText(text)
    }

    /// Clears existing text and types new text
    public func clearAndTypeText(_ text: String) {
        tap()
        if let stringValue = value as? String, !stringValue.isEmpty {
            let deleteString = String(repeating: XCUIKeyboardKey.delete.rawValue, count: stringValue.count)
            typeText(deleteString)
        }
        typeText(text)
    }

    /// Wait for element to become hittable
    @discardableResult
    public func waitUntilHittable(timeout: TimeInterval = 5) -> Bool {
        let predicate = NSPredicate(format: "isHittable == true")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        return result == .completed
    }

    /// Wait for element to disappear
    @discardableResult
    public func waitForDisappearance(timeout: TimeInterval = 5) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        return result == .completed
    }

    /// Check if element contains specific text
    public func containsText(_ text: String) -> Bool {
        if let value = value as? String {
            return value.contains(text)
        }
        return label.contains(text)
    }
}
