//
//  CustomSurfaceTests.swift
//  PublicationManagerCoreTests
//
//  WP-X0: the custom-surface seam — registry lookup, shell-config equality
//  semantics, and the no-registry default (imbib/imprint must be unaffected).
//

import SwiftUI
import XCTest
@testable import PublicationManagerCore

#if os(macOS)
final class CustomSurfaceTests: XCTestCase {

    @MainActor
    func testRegistryLookupAndDefaultEmpty() {
        XCTAssertTrue(AppShellConfiguration.imbib.customSurfaces.isEmpty)
        XCTAssertTrue(AppShellConfiguration.imprint.customSurfaces.isEmpty)

        let registry = CustomSurfaceRegistry([
            CustomSurfaceDescriptor(
                id: "dashboard", title: "Dashboard", systemImage: "gauge",
                makeView: { AnyView(Text("dash")) }),
        ])
        XCTAssertEqual(registry["dashboard"]?.title, "Dashboard")
        XCTAssertNil(registry["nope"])
    }

    @MainActor
    func testConfigEqualityComparesSurfaceIDs() {
        let surface = CustomSurfaceDescriptor(
            id: "canvas", title: "Canvas", systemImage: "square.grid.3x3",
            makeView: { AnyView(EmptyView()) })
        let a = AppShellConfiguration(
            appID: "t", visibleSections: nil,
            defaultSection: .inbox, defaultDetailTab: .info,
            customSurfaces: CustomSurfaceRegistry([surface]))
        let b = AppShellConfiguration(
            appID: "t", visibleSections: nil,
            defaultSection: .inbox, defaultDetailTab: .info,
            customSurfaces: CustomSurfaceRegistry([surface]))
        let c = AppShellConfiguration(
            appID: "t", visibleSections: nil,
            defaultSection: .inbox, defaultDetailTab: .info)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
}
#endif
