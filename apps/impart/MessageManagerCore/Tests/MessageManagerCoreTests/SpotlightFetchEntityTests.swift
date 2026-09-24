//
//  SpotlightFetchEntityTests.swift
//  MessageManagerCoreTests
//
//  The Spotlight provider's fetches must name entities the model has.
//
//  For an unknown entity Core Data raises an Objective-C exception rather than
//  returning an error, so `try?` does not help. The provider asked for "Thread"
//  and "ResearchConversation" while the model names "CDThread" and
//  "CDResearchConversation"; the exception fired ~90 s after every launch on the
//  main actor and left every @MainActor HTTP route hung (2026-09-24). These
//  tests execute the exact requests the provider uses against an in-memory
//  store, so a misnamed entity crashes the test run instead of the app.
//

import CoreData
import Foundation
import Testing

@testable import MessageManagerCore

@MainActor
@Suite("Spotlight fetches name real entities")
struct SpotlightFetchEntityTests {

    @Test("CDThread.fetchRequest names an entity in the model")
    func threadRequestResolves() throws {
        let model = CoreDataModelBuilder.createModel()
        let request: NSFetchRequest<CDThread> = CDThread.fetchRequest()
        let name = try #require(request.entityName)
        #expect(model.entitiesByName[name] != nil, "no entity '\(name)' in impart's model")
    }

    @Test("CDResearchConversation.fetchRequest names an entity in the model")
    func researchConversationRequestResolves() throws {
        let model = CoreDataModelBuilder.createModel()
        let request: NSFetchRequest<CDResearchConversation> = CDResearchConversation.fetchRequest()
        let name = try #require(request.entityName)
        #expect(model.entitiesByName[name] != nil, "no entity '\(name)' in impart's model")
    }

    @Test("both provider fetches execute against a store without raising")
    func providerFetchesExecute() throws {
        // A plain in-memory container over impart's real model.
        // `PersistenceController(inMemory:)` builds a CloudKit container, which a
        // `swift test` process has no entitlement for ("Unsupported feature in
        // this configuration"); the fetch path under test is the same either way.
        let container = NSPersistentContainer(
            name: "SpotlightFetchEntityTests",
            managedObjectModel: CoreDataModelBuilder.createModel())
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]
        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        if let loadError { throw loadError }
        let context = container.viewContext
        let threads: NSFetchRequest<CDThread> = CDThread.fetchRequest()
        let conversations: NSFetchRequest<CDResearchConversation> =
            CDResearchConversation.fetchRequest()
        #expect(try context.fetch(threads).isEmpty)
        #expect(try context.fetch(conversations).isEmpty)
    }
}
