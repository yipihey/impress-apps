import Foundation
import ImpressAutomation
import Testing
@testable import PublicationManagerCore

@Suite("Imbib native verb callback")
struct ImbibNativeVerbsTests {
    @Test func manuscriptTemplatesReturnActualCatalogue() async throws {
        let router = HTTPAutomationRouter()
        let result = await router.invokeNativeVerb(method: "list_templates", argsJSON: "{}")
        #expect(result.status == 200)
        let data = Data(result.bodyJson.utf8)
        let templates = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(!templates.isEmpty)
        #expect(templates.allSatisfy { ($0["id"] as? String)?.isEmpty == false })
    }

    @Test func invalidNativeArgumentsRefuseWithoutOpeningAStore() async throws {
        let router = HTTPAutomationRouter()
        let malformed = await router.invokeNativeVerb(method: "get_notes", argsJSON: "{")
        #expect(malformed.status == 400)
        let missing = await router.invokeNativeVerb(
            method: "get_manuscript", argsJSON: #"{"manuscript_id":"not-a-uuid"}"#)
        #expect(missing.status == 400)
        let body = try #require(JSONSerialization.jsonObject(with: Data(missing.bodyJson.utf8)) as? [String: Any])
        #expect(body["code"] as? String == "invalid-args")
    }

    @MainActor
    @Test func libraryFileDeletionUsesScratchContainersAndUnlinkOnlyKeepsFiles() async throws {
        let settings = AutomationSettingsStore.shared
        let wasEnabled = await settings.isEnabled
        await settings.setEnabled(true)
        do {
            let store = RustStoreAdapter.shared
            let suffix = UUID().uuidString
            let unlinkLibrary = try #require(store.createLibrary(name: "Unlink-only \(suffix)"))
            let unlinkContainers = LibraryManager.allContainerURLs(for: unlinkLibrary.id)
            defer {
                for url in unlinkContainers { try? FileManager.default.removeItem(at: url) }
            }
            for directory in unlinkContainers {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try Data("scratch".utf8).write(to: directory.appendingPathComponent("fixture.txt"))
            }

            let router = HTTPAutomationRouter()
            let unlink = await router.route(HTTPRequest(
                method: "DELETE",
                path: "/api/libraries/\(unlinkLibrary.id.uuidString)",
                queryParams: ["deleteFiles": "false"]
            ))
            #expect(unlink.status == 200)
            #expect(unlinkContainers.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })

            let cleanupLibrary = try #require(store.createLibrary(name: "Cleanup-only \(suffix)"))
            let cleanupContainers = LibraryManager.allContainerURLs(for: cleanupLibrary.id)
            defer {
                for url in cleanupContainers { try? FileManager.default.removeItem(at: url) }
            }
            for directory in cleanupContainers {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try Data("scratch".utf8).write(to: directory.appendingPathComponent("fixture.txt"))
            }
            let cleaned = await router.invokeNativeVerb(
                method: "delete_library",
                argsJSON: "{\"id\":\"\(cleanupLibrary.id.uuidString)\",\"delete_files\":true}"
            )
            #expect(cleaned.status == 200)
            #expect(cleaned.bodyJson == "true")
            #expect(cleanupContainers.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
            #expect(store.getLibrary(id: cleanupLibrary.id) == nil)

            let batchLibraries = try (0..<2).map { index in
                try #require(store.createLibrary(name: "Batch cleanup \(index) \(suffix)"))
            }
            let batchContainers = batchLibraries.flatMap { LibraryManager.allContainerURLs(for: $0.id) }
            defer {
                for url in batchContainers { try? FileManager.default.removeItem(at: url) }
            }
            for directory in batchContainers {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try Data("scratch".utf8).write(to: directory.appendingPathComponent("fixture.txt"))
            }
            let ids = batchLibraries.map { "\"\($0.id.uuidString)\"" }.joined(separator: ",")
            let batch = await router.invokeNativeVerb(
                method: "delete_libraries",
                argsJSON: "{\"ids\":[\(ids)],\"delete_files\":true}"
            )
            #expect(batch.status == 200)
            #expect(batch.bodyJson == "2")
            #expect(batchContainers.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
            #expect(batchLibraries.allSatisfy { store.getLibrary(id: $0.id) == nil })

            let preflightLibrary = try #require(store.createLibrary(name: "Batch preflight \(suffix)"))
            let preflightContainers = LibraryManager.allContainerURLs(for: preflightLibrary.id)
            defer {
                for url in preflightContainers { try? FileManager.default.removeItem(at: url) }
            }
            for directory in preflightContainers {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try Data("scratch".utf8).write(to: directory.appendingPathComponent("fixture.txt"))
            }
            let preflight = await router.invokeNativeVerb(
                method: "delete_libraries",
                argsJSON: "{\"ids\":[\"\(preflightLibrary.id.uuidString)\",\"\(UUID().uuidString)\"],\"delete_files\":true}"
            )
            #expect(preflight.status == 500)
            #expect(store.getLibrary(id: preflightLibrary.id) != nil)
            #expect(preflightContainers.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        } catch {
            await settings.setEnabled(wasEnabled)
            throw error
        }
        await settings.setEnabled(wasEnabled)
    }

    @MainActor
    @Test func identifierImportPreservesDuplicateAndUnsupportedPerPaperOutcomes() async throws {
        let settings = AutomationSettingsStore.shared
        let wasEnabled = await settings.isEnabled
        await settings.setEnabled(true)
        do {
            let store = RustStoreAdapter.shared
            let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10)
            let citeKey = "NativeImport\(suffix)"
            let library = try #require(store.createLibrary(name: "Native import \(suffix)"))
            let paperIDs = store.importBibTeX(
                "@article{\(citeKey), title={Native import fixture}, author={Doe, Jane}, year={2026}}",
                libraryId: library.id)
            #expect(paperIDs.count == 1)
            let paperID = try #require(paperIDs.first)
            let collection = try #require(store.createCollection(name: "Import target \(suffix)", libraryId: library.id))

            let router = HTTPAutomationRouter()
            let result = await router.invokeNativeVerb(
                method: "import_identifiers",
                argsJSON: """
                {"identifiers":["\(citeKey)","unsupported-\(suffix)"],"library_id":"\(library.id)","collection_id":"\(collection.id)","download_pdfs":false}
                """
            )
            #expect(result.status == 200)
            let body = try #require(JSONSerialization.jsonObject(with: Data(result.bodyJson.utf8)) as? [String: Any])
            #expect((body["added"] as? [Any])?.isEmpty == true)
            #expect(body["duplicates"] as? [String] == [citeKey])
            let failed = try #require(body["failed"] as? [String: String])
            #expect(failed["unsupported-\(suffix)"]?.isEmpty == false)
            #expect(store.listCollections(forPublication: paperID).contains { $0.id == collection.id })
        } catch {
            await settings.setEnabled(wasEnabled)
            throw error
        }
        await settings.setEnabled(wasEnabled)
    }

    @MainActor
    @Test func recentActivityFiltersMembershipBeforeApplyingLimit() async throws {
        let store = RustStoreAdapter.shared // in-memory under XCTest
        let inside = try #require(store.createLibrary(name: "Recent inside \(UUID())"))
        let outside = try #require(store.createLibrary(name: "Recent outside \(UUID())"))
        let unique = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let insideID = try #require(store.importBibTeX(
            "@article{Inside\(unique), title={Inside activity}}", libraryId: inside.id).first)
        let outsideID = try #require(store.importBibTeX(
            "@article{Outside\(unique), title={Outside activity}}", libraryId: outside.id).first)
        store.recordRecentView(id: insideID)
        try await Task.sleep(nanoseconds: 10_000_000)
        store.recordRecentView(id: outsideID)

        let router = HTTPAutomationRouter()
        let unfiltered = await router.invokeNativeVerb(
            method: "recent_activity", argsJSON: #"{"limit":1}"#)
        let global = try #require(JSONSerialization.jsonObject(with: Data(unfiltered.bodyJson.utf8)) as? [[String: Any]])
        #expect((global.first?["id"] as? String).flatMap(UUID.init(uuidString:)) == outsideID)

        let filtered = await router.invokeNativeVerb(
            method: "recent_activity",
            argsJSON: "{\"limit\":1,\"parent_id\":\"\(inside.id.uuidString)\"}")
        #expect(filtered.status == 200)
        let papers = try #require(JSONSerialization.jsonObject(with: Data(filtered.bodyJson.utf8)) as? [[String: Any]])
        #expect(papers.count == 1)
        #expect((papers.first?["id"] as? String).flatMap(UUID.init(uuidString:)) == insideID)

        let invalid = await router.invokeNativeVerb(
            method: "recent_activity", argsJSON: #"{"limit":1,"parent_id":"not-a-uuid"}"#)
        #expect(invalid.status == 400)
    }

    @Test func retiredImbibAliasesAreNotRouted() async {
        let router = HTTPAutomationRouter()
        let bibtex = await router.route(HTTPRequest(method: "GET", path: "/api/export",
                                                       queryParams: ["keys": "Key2026"]))
        #expect(bibtex.status == 404)
        let ris = await router.route(HTTPRequest(method: "GET", path: "/api/export",
                                                    queryParams: ["keys": "Key2026", "format": "ris"]))
        #expect(ris.status != 404, "RIS export remains an app-only HTTP capability")
        let library = await router.route(HTTPRequest(method: "POST", path: "/api/libraries",
                                                        body: #"{"name":"Retired alias"}"#))
        #expect(library.status == 404)
        let undo = await router.route(HTTPRequest(method: "GET", path: "/api/undo/recent"))
        #expect(undo.status == 404)
        let scix = await router.route(HTTPRequest(method: "GET", path: "/api/scix-libraries"))
        #expect(scix.status == 404)
        let scixMutation = await router.route(HTTPRequest(
            method: "POST", path: "/api/scix-libraries/\(UUID())/papers",
            body: #"{"publication_ids":[]}"#))
        #expect(scixMutation.status == 404)
    }

    @Test func resolverCandidatesRefuseInsteadOfBecomingCleanMiss() throws {
        let ambiguous = HTTPAutomationRouter.nativeResolveIdentifierResult(.json([
            "status": "ok", "via": "external-candidates",
            "candidates": [["title": "Candidate", "identifier": "doi:10.1/example"]]
        ]))
        #expect(ambiguous.status == 409)
        let refusal = try #require(JSONSerialization.jsonObject(with: Data(ambiguous.bodyJson.utf8)) as? [String: Any])
        #expect(refusal["code"] as? String == "ambiguous-identifier")

        let duplicate = HTTPAutomationRouter.nativeResolveIdentifierResult(.json([
            "status": "ok", "via": "duplicate", "duplicates": ["Existing2026"]
        ]))
        #expect(duplicate.status == 409)

        let miss = HTTPAutomationRouter.nativeResolveIdentifierResult(.json([
            "status": "ok", "via": "not-found", "reason": "no match"
        ]))
        #expect(miss.status == 200)
        #expect(miss.bodyJson == "null")

        let found = HTTPAutomationRouter.nativeResolveIdentifierResult(.json([
            "status": "ok", "via": "local-identifier", "paper": ["citeKey": "Found2026"]
        ]))
        #expect(found.status == 200)
        #expect(found.bodyJson == #""Found2026""#)
    }

    @Test func downloadedIDsBecomeCountAndMissingCountRefuses() {
        let downloaded = HTTPAutomationRouter.nativeDownloadPDFResult(.json([
            "status": "ok", "downloaded": ["paper-a", "paper-b"],
            "alreadyHad": ["paper-c"], "failed": [] as [String]
        ]))
        #expect(downloaded.status == 200)
        #expect(downloaded.bodyJson == "2")

        let missing = HTTPAutomationRouter.nativeDownloadPDFResult(.json(["status": "ok"]))
        #expect(missing.status == 500)
    }
}
