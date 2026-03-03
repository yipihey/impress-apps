import Testing
import Foundation
@testable import ImpressKit

@Suite("ImpressKit Data Models")
struct DataModelTests {

    // MARK: - SiblingApp

    @Test("SiblingApp has 5 apps")
    func siblingAppCount() {
        #expect(SiblingApp.allCases.count == 5)
    }

    @Test("SiblingApp bundle IDs are non-empty")
    func bundleIDs() {
        for app in SiblingApp.allCases {
            #expect(!app.bundleID.isEmpty)
        }
    }

    @Test("SiblingApp URL schemes match raw values")
    func urlSchemes() {
        for app in SiblingApp.allCases {
            #expect(app.urlScheme == app.rawValue)
        }
    }

    @Test("SiblingApp HTTP ports are in expected range")
    func httpPorts() {
        for app in SiblingApp.allCases {
            #expect(app.httpPort >= 23120)
            #expect(app.httpPort <= 23130)
        }
    }

    @Test("SiblingApp HTTP ports are unique")
    func uniquePorts() {
        let ports = SiblingApp.allCases.map(\.httpPort)
        #expect(Set(ports).count == SiblingApp.allCases.count)
    }

    @Test("SiblingApp Codable round-trip")
    func siblingAppCodable() throws {
        for app in SiblingApp.allCases {
            let data = try JSONEncoder().encode(app)
            let decoded = try JSONDecoder().decode(SiblingApp.self, from: data)
            #expect(decoded == app)
        }
    }

    // MARK: - ImpressPaperRef

    @Test("ImpressPaperRef stores all fields")
    func paperRefInit() {
        let id = UUID()
        let ref = ImpressPaperRef(id: id, citeKey: "Einstein1905", title: "On the Electrodynamics", doi: "10.1002/andp.19053221004")
        #expect(ref.id == id)
        #expect(ref.citeKey == "Einstein1905")
        #expect(ref.title == "On the Electrodynamics")
        #expect(ref.doi == "10.1002/andp.19053221004")
    }

    @Test("ImpressPaperRef Codable round-trip")
    func paperRefCodable() throws {
        let ref = ImpressPaperRef(id: UUID(), citeKey: "Test2024", title: "Title", doi: "10.1234/test")
        let data = try JSONEncoder().encode(ref)
        let decoded = try JSONDecoder().decode(ImpressPaperRef.self, from: data)
        #expect(decoded == ref)
    }

    @Test("ImpressPaperRef optional fields default to nil")
    func paperRefDefaults() {
        let ref = ImpressPaperRef(id: UUID(), citeKey: "Key")
        #expect(ref.title == nil)
        #expect(ref.doi == nil)
    }
}
