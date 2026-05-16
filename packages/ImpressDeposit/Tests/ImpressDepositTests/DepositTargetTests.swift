import XCTest
@testable import ImpressDeposit

final class DepositTargetTests: XCTestCase {

    // MARK: - Artifact construction

    func testDepositArtifact_minimal() {
        let file = DepositFile(filename: "paper.pdf", body: .data(Data("hello".utf8), mimeType: "application/pdf"))
        let artifact = DepositArtifact(title: "A Title", file: file)
        XCTAssertEqual(artifact.title, "A Title")
        XCTAssertTrue(artifact.authors.isEmpty)
        XCTAssertNil(artifact.license)
    }

    func testDepositArtifact_full() {
        let file = DepositFile(filename: "data.csv", body: .data(Data(), mimeType: "text/csv"))
        let artifact = DepositArtifact(
            title: "FAIR Trial",
            description: "Test artifact",
            authors: [
                DepositAuthor(name: "Abel, Tom", orcid: "0000-0002-5969-1251", affiliation: "Stanford"),
                DepositAuthor(name: "Co-Author")
            ],
            license: "CC-BY-4.0",
            keywords: ["fair", "research"],
            file: file,
            community: "impress"
        )
        XCTAssertEqual(artifact.authors.count, 2)
        XCTAssertEqual(artifact.license, "CC-BY-4.0")
        XCTAssertEqual(artifact.keywords, ["fair", "research"])
        XCTAssertEqual(artifact.community, "impress")
    }

    // MARK: - UploadProgress

    func testUploadProgress_fraction() {
        XCTAssertEqual(UploadProgress(phase: .uploading, bytesSent: 50, totalBytes: 100).fractionComplete, 0.5)
        XCTAssertEqual(UploadProgress(phase: .creatingRecord).fractionComplete, 0.0)
        XCTAssertEqual(UploadProgress(phase: .uploading, bytesSent: 0, totalBytes: 0).fractionComplete, 0.0)
    }

    // MARK: - Zenodo basics

    func testZenodoTarget_metadata() {
        let target = ZenodoDepositTarget(token: "test-token")
        XCTAssertEqual(target.id, "zenodo")
        XCTAssertEqual(target.displayName, "Zenodo")
        XCTAssertEqual(target.apiRoot.absoluteString, "https://zenodo.org/api")
        if case .apiToken(let label, _) = target.credentialRequirement {
            XCTAssertEqual(label, "Personal Access Token")
        } else {
            XCTFail("Expected apiToken credential requirement")
        }
    }

    func testZenodoTarget_sandboxRoot() {
        let target = ZenodoDepositTarget(apiRoot: ZenodoDepositTarget.sandboxRoot, token: "test")
        XCTAssertTrue(target.apiRoot.absoluteString.contains("sandbox.zenodo.org"))
    }

    func testZenodoTarget_rejectsEmptyToken() async {
        let target = ZenodoDepositTarget(token: "")
        let file = DepositFile(filename: "x.txt", body: .data(Data(), mimeType: "text/plain"))
        let artifact = DepositArtifact(title: "x", file: file)
        do {
            _ = try await target.deposit(artifact: artifact) { _ in }
            XCTFail("Expected missingCredential error")
        } catch DepositError.missingCredential {
            // expected
        } catch {
            XCTFail("Expected missingCredential; got \(error)")
        }
    }
}
