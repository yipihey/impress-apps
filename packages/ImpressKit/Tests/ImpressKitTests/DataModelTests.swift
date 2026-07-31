import Testing
import Foundation
@testable import ImpressKit

@Suite("ImpressKit Data Models")
struct DataModelTests {

    // MARK: - SiblingApp

    @Test("SiblingApp has 6 apps")
    func siblingAppCount() {
        // Six since 2026-07-30 (ADR-0022 D9: the `impress` shell shipped).
        #expect(SiblingApp.allCases.count == 6)
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

    // MARK: - SiblingAppDescriptor table

    @Test("SiblingApp descriptor table covers every app exactly once")
    func descriptorTableCoversEveryApp() {
        #expect(SiblingApp.descriptors.count == SiblingApp.allCases.count)
        let ids = SiblingApp.descriptors.map(\.id)
        #expect(Set(ids).count == SiblingApp.descriptors.count)
        for app in SiblingApp.allCases {
            // Would `preconditionFailure` if a row were missing.
            #expect(app.descriptor.id == app)
        }
    }

    @Test("SiblingApp accessors agree with the descriptor table")
    func accessorsMatchTable() {
        for row in SiblingApp.descriptors {
            #expect(row.id.bundleID == row.bundleID)
            #expect(row.id.urlScheme == row.urlScheme)
            #expect(row.id.httpPort == row.httpPort)
            #expect(row.id.displayName == row.displayName)
            #expect(row.id.systemImage == row.systemImage)
        }
    }

    /// Every app has a glyph, and no two apps share one. `SidebarComposition`
    /// draws five of these side by side in impress's sidebar, so a duplicate is
    /// two groups a user cannot tell apart at a glance — and an empty string is
    /// an SF Symbol lookup that renders nothing at all.
    @Test("SiblingApp glyphs are present and distinct")
    func glyphsArePresentAndDistinct() {
        for row in SiblingApp.descriptors {
            #expect(!row.systemImage.isEmpty)
        }
        let glyphs = SiblingApp.descriptors.map(\.systemImage)
        #expect(Set(glyphs).count == glyphs.count)
    }

    @Test("SiblingApp reverse lookups round-trip")
    func reverseLookups() {
        for app in SiblingApp.allCases {
            #expect(SiblingApp.app(forBundleID: app.bundleID) == app)
            #expect(SiblingApp.app(forURLScheme: app.urlScheme) == app)
            #expect(SiblingApp.app(forHTTPPort: app.httpPort) == app)
        }
        #expect(SiblingApp.app(forBundleID: "com.example.nope") == nil)
        #expect(SiblingApp.app(forURLScheme: "nope") == nil)
        #expect(SiblingApp.app(forHTTPPort: 1) == nil)
    }

    @Test("SiblingApp bundle IDs are unique")
    func uniqueBundleIDs() {
        let ids = SiblingApp.allCases.map(\.bundleID)
        #expect(Set(ids).count == SiblingApp.allCases.count)
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
