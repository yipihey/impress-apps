//
//  SidebarSectionPersistenceTests.swift
//  ImpressSidebar
//
//  Tests for generic sidebar section persistence stores.
//

import Foundation
import Testing
@testable import ImpressSidebar

// MARK: - Test Section Type

enum TestSection: String, CaseIterable, Codable, Hashable {
    case alpha
    case beta
    case gamma
    case delta
}

// MARK: - Order Store Tests

@Suite("SidebarSectionOrderStore")
struct SidebarSectionOrderStoreTests {

    /// Generate unique keys per test to avoid cross-test pollution
    private func uniqueKey() -> String {
        "test_order_\(UUID().uuidString)"
    }

    @Test("Returns default order when no data saved")
    func testDefaultOrder() async {
        let key = uniqueKey()
        let store = SidebarSectionOrderStore<TestSection>(
            key: key,
            defaultOrder: TestSection.allCases
        )
        let order = await store.order()
        #expect(order == [.alpha, .beta, .gamma, .delta])
        UserDefaults.standard.removeObject(forKey: key)
    }

    @Test("Saves and loads order")
    func testSaveAndLoad() async {
        let key = uniqueKey()
        let store = SidebarSectionOrderStore<TestSection>(
            key: key,
            defaultOrder: TestSection.allCases
        )

        let newOrder: [TestSection] = [.delta, .gamma, .beta, .alpha]
        await store.save(newOrder)

        // Create a new store to verify persistence
        let store2 = SidebarSectionOrderStore<TestSection>(
            key: key,
            defaultOrder: TestSection.allCases
        )
        let loaded = await store2.order()
        #expect(loaded == newOrder)
        UserDefaults.standard.removeObject(forKey: key)
    }

    @Test("Synchronous load returns saved order")
    func testLoadSync() async {
        let key = uniqueKey()
        let store = SidebarSectionOrderStore<TestSection>(
            key: key,
            defaultOrder: TestSection.allCases
        )
        let newOrder: [TestSection] = [.gamma, .alpha, .delta, .beta]
        await store.save(newOrder)

        let syncLoaded = store.loadSync()
        #expect(syncLoaded == newOrder)
        UserDefaults.standard.removeObject(forKey: key)
    }

    @Test("Reset returns default order")
    func testReset() async {
        let key = uniqueKey()
        let store = SidebarSectionOrderStore<TestSection>(
            key: key,
            defaultOrder: TestSection.allCases
        )
        await store.save([.delta, .gamma, .beta, .alpha])
        await store.reset()

        let order = await store.order()
        #expect(order == TestSection.allCases)
        UserDefaults.standard.removeObject(forKey: key)
    }

    @Test("Fills in missing sections from app updates")
    func testFillsMissingSections() async {
        let key = uniqueKey()
        // Simulate an older save that's missing .delta
        let oldOrder: [TestSection] = [.beta, .alpha, .gamma]
        if let data = try? JSONEncoder().encode(oldOrder) {
            UserDefaults.standard.set(data, forKey: key)
        }

        let store = SidebarSectionOrderStore<TestSection>(
            key: key,
            defaultOrder: TestSection.allCases
        )
        let order = await store.order()
        // Should have beta, alpha, gamma in their saved order, with delta appended
        #expect(order == [.beta, .alpha, .gamma, .delta])
        UserDefaults.standard.removeObject(forKey: key)
    }
}

// MARK: - Collapsed State Store Tests

@Suite("SidebarCollapsedStateStore")
struct SidebarCollapsedStateStoreTests {

    private func uniqueKey() -> String {
        "test_collapsed_\(UUID().uuidString)"
    }

    @Test("Returns empty set when no data saved")
    func testDefaultEmpty() async {
        let key = uniqueKey()
        let store = SidebarCollapsedStateStore<TestSection>(key: key)
        let collapsed = await store.collapsedSections()
        #expect(collapsed.isEmpty)
        UserDefaults.standard.removeObject(forKey: key)
    }

    @Test("Toggle adds and removes sections")
    func testToggle() async {
        let key = uniqueKey()
        let store = SidebarCollapsedStateStore<TestSection>(key: key)

        let after1 = await store.toggle(.alpha)
        #expect(after1 == [.alpha])

        let after2 = await store.toggle(.beta)
        #expect(after2 == [.alpha, .beta])

        let after3 = await store.toggle(.alpha)
        #expect(after3 == [.beta])

        UserDefaults.standard.removeObject(forKey: key)
    }

    @Test("Save and load collapsed state")
    func testSaveAndLoad() async {
        let key = uniqueKey()
        let store = SidebarCollapsedStateStore<TestSection>(key: key)
        let state: Set<TestSection> = [.beta, .delta]
        await store.save(state)

        let store2 = SidebarCollapsedStateStore<TestSection>(key: key)
        let loaded = await store2.collapsedSections()
        #expect(loaded == state)
        UserDefaults.standard.removeObject(forKey: key)
    }

    @Test("isCollapsed reflects state")
    func testIsCollapsed() async {
        let key = uniqueKey()
        let store = SidebarCollapsedStateStore<TestSection>(key: key)
        await store.save([.gamma])

        let gammaCollapsed = await store.isCollapsed(.gamma)
        let alphaCollapsed = await store.isCollapsed(.alpha)
        #expect(gammaCollapsed == true)
        #expect(alphaCollapsed == false)
        UserDefaults.standard.removeObject(forKey: key)
    }

    @Test("Synchronous load returns saved state")
    func testLoadSync() async {
        let key = uniqueKey()
        let store = SidebarCollapsedStateStore<TestSection>(key: key)
        await store.save([.alpha, .gamma])

        let syncLoaded = store.loadSync()
        #expect(syncLoaded == [.alpha, .gamma])
        UserDefaults.standard.removeObject(forKey: key)
    }
}
