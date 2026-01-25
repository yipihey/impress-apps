//
//  SciXLibraryServiceTests.swift
//  PublicationManagerCoreTests
//
//  Created by Claude on 2026-01-09.
//

import XCTest
@testable import PublicationManagerCore

final class SciXLibraryServiceTests: XCTestCase {

    // MARK: - Type Tests

    func testSciXLibraryMetadata_decoding() throws {
        let json = """
        {
            "id": "abc123",
            "name": "My Research Papers",
            "description": "Papers on gravitational waves",
            "permission": "owner",
            "num_documents": 42,
            "date_created": "2024-01-15T10:30:00Z",
            "date_last_modified": "2024-06-20T14:22:00Z",
            "public": false,
            "owner": "researcher@university.edu"
        }
        """

        let data = json.data(using: .utf8)!
        let metadata = try JSONDecoder().decode(SciXLibraryMetadata.self, from: data)

        XCTAssertEqual(metadata.id, "abc123")
        XCTAssertEqual(metadata.name, "My Research Papers")
        XCTAssertEqual(metadata.description, "Papers on gravitational waves")
        XCTAssertEqual(metadata.permission, "owner")
        XCTAssertEqual(metadata.num_documents, 42)
        XCTAssertFalse(metadata.public)
        XCTAssertEqual(metadata.owner, "researcher@university.edu")
    }

    func testSciXLibraryListResponse_decoding() throws {
        let json = """
        {
            "libraries": [
                {
                    "id": "lib1",
                    "name": "First Library",
                    "description": null,
                    "permission": "read",
                    "num_documents": 10,
                    "date_created": "2024-01-01T00:00:00Z",
                    "date_last_modified": "2024-01-01T00:00:00Z",
                    "public": true,
                    "owner": "alice@example.com"
                },
                {
                    "id": "lib2",
                    "name": "Second Library",
                    "description": "Shared papers",
                    "permission": "write",
                    "num_documents": 25,
                    "date_created": "2024-02-01T00:00:00Z",
                    "date_last_modified": "2024-03-01T00:00:00Z",
                    "public": false,
                    "owner": "bob@example.com"
                }
            ]
        }
        """

        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(SciXLibraryListResponse.self, from: data)

        XCTAssertEqual(response.libraries.count, 2)
        XCTAssertEqual(response.libraries[0].id, "lib1")
        XCTAssertEqual(response.libraries[0].name, "First Library")
        XCTAssertEqual(response.libraries[1].id, "lib2")
        XCTAssertEqual(response.libraries[1].permission, "write")
    }

    func testSciXCreateLibraryRequest_encoding() throws {
        let request = SciXCreateLibraryRequest(
            name: "New Library",
            description: "A test library",
            isPublic: true,
            bibcodes: ["2024ApJ...123A...1X", "2024MNRAS.456..789Y"]
        )

        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["name"] as? String, "New Library")
        XCTAssertEqual(json["description"] as? String, "A test library")
        XCTAssertEqual(json["public"] as? Bool, true)
        XCTAssertEqual((json["bibcode"] as? [String])?.count, 2)
    }

    func testSciXModifyDocumentsRequest_encoding() throws {
        let request = SciXModifyDocumentsRequest(
            bibcodes: ["2024ApJ...123A...1X"],
            action: .add
        )

        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["action"] as? String, "add")
        XCTAssertEqual((json["bibcode"] as? [String])?.first, "2024ApJ...123A...1X")
    }

    // MARK: - Error Tests

    func testSciXLibraryError_descriptions() {
        let errors: [(SciXLibraryError, String)] = [
            (.unauthorized, "Invalid or missing SciX API key"),
            (.forbidden, "You don't have permission to access this library"),
            (.notFound, "Library not found"),
            (.rateLimited, "Too many requests. Please try again later."),
            (.noAPIKey, "No SciX API key configured. Add your key in Settings."),
        ]

        for (error, expectedMessage) in errors {
            XCTAssertEqual(error.localizedDescription, expectedMessage)
        }
    }

    func testSciXLibraryError_isRetryable() {
        XCTAssertTrue(SciXLibraryError.rateLimited.isRetryable)
        XCTAssertTrue(SciXLibraryError.serverError(500).isRetryable)
        XCTAssertFalse(SciXLibraryError.unauthorized.isRetryable)
        XCTAssertFalse(SciXLibraryError.forbidden.isRetryable)
        XCTAssertFalse(SciXLibraryError.noAPIKey.isRetryable)
    }

    // MARK: - Permission Tests

    func testSciXPermission_level() {
        let ownerPerm = SciXPermission(email: "owner@test.com", permission: "owner")
        let adminPerm = SciXPermission(email: "admin@test.com", permission: "admin")
        let writePerm = SciXPermission(email: "writer@test.com", permission: "write")
        let readPerm = SciXPermission(email: "reader@test.com", permission: "read")

        XCTAssertEqual(ownerPerm.level, .owner)
        XCTAssertEqual(adminPerm.level, .admin)
        XCTAssertEqual(writePerm.level, .write)
        XCTAssertEqual(readPerm.level, .read)
    }
}
