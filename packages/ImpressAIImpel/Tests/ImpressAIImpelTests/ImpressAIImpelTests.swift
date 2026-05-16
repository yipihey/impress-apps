//
//  ImpressAIImpelTests.swift
//  ImpressAIImpel
//
//  Tests for the ImpressAIImpel package.
//

import XCTest
@testable import ImpressAIImpel
@testable import ImpressAI

final class ImpressAIImpelTests: XCTestCase {

    func testImpelProviderMetadata() async {
        let provider = ImpelAIProvider()
        let metadata = provider.metadata

        XCTAssertEqual(metadata.id, "impel")
        XCTAssertEqual(metadata.name, "Impel Agents")
        XCTAssertEqual(metadata.category, .agent)
        XCTAssertGreaterThan(metadata.models.count, 0)
    }

    func testImpelProviderDefaultModel() async {
        let provider = ImpelAIProvider()
        let defaultModel = provider.metadata.defaultModel

        XCTAssertNotNil(defaultModel)
        XCTAssertEqual(defaultModel?.id, "impel-auto")
    }

    func testImpelProviderCredentialRequirement() async {
        let provider = ImpelAIProvider()
        let requirement = provider.metadata.credentialRequirement

        if case .custom(let fields) = requirement {
            XCTAssertEqual(fields.count, 2)
            XCTAssertTrue(fields.contains { $0.id == "endpoint" })
            XCTAssertTrue(fields.contains { $0.id == "authToken" })
        } else {
            XCTFail("Expected custom credential requirement")
        }
    }
}
