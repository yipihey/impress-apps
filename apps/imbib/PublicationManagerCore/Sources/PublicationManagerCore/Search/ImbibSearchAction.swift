//
//  ImbibSearchAction.swift
//  PublicationManagerCore
//
//  Declarative actions for imbib's flagship search workflows.
//

import Foundation

// MARK: - Search Workflow

/// The top-level search workflows imbib exposes to users and agents.
public enum ImbibSearchWorkflow: String, CaseIterable, Identifiable, Sendable {
    /// Cmd+F: find papers, notes, and PDF passages already in the local store.
    case localFind
    /// Cmd+S: search online publication sources and add reviewed candidates.
    case onlineSourceSearch

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .localFind:
            return "Find in Library"
        case .onlineSourceSearch:
            return "Search Online Sources"
        }
    }

    public var commandTitle: String {
        switch self {
        case .localFind:
            return "Global Search"
        case .onlineSourceSearch:
            return "Smart Search (AI)"
        }
    }

    public var shortcut: String {
        switch self {
        case .localFind:
            return "⌘F"
        case .onlineSourceSearch:
            return "⌘S"
        }
    }

    public var searchesLocalStore: Bool {
        self == .localFind
    }

    public var usesOnlineSources: Bool {
        self == .onlineSourceSearch
    }

    public var presentationID: String {
        switch self {
        case .localFind:
            return "global-search-palette"
        case .onlineSourceSearch:
            return "smart-search-overlay"
        }
    }

    public var legacyNotificationName: Notification.Name {
        switch self {
        case .localFind:
            return .showGlobalSearch
        case .onlineSourceSearch:
            return .showNLSearch
        }
    }
}

// MARK: - Search Action Source

/// Where a search action originated.
public enum ImbibSearchActionSource: String, Sendable {
    case keyboardShortcut
    case menuCommand
    case commandPalette
    case toolbarButton
    case automation
    case notificationBridge
}

// MARK: - Search Action

/// A typed request to present one of imbib's search workflows.
public struct ImbibSearchAction: Identifiable, Equatable, Sendable {
    public let workflow: ImbibSearchWorkflow
    public let source: ImbibSearchActionSource
    public let context: SearchContext

    public init(
        workflow: ImbibSearchWorkflow,
        source: ImbibSearchActionSource,
        context: SearchContext = .global
    ) {
        self.workflow = workflow
        self.source = source
        self.context = context
    }

    public var id: String {
        "\(workflow.rawValue):\(context.stableActionID)"
    }

    public var commandID: String {
        switch workflow {
        case .localFind:
            return "globalSearch"
        case .onlineSourceSearch:
            return "nlSearch"
        }
    }

    public var notificationName: Notification.Name {
        .performSearchAction
    }

    public var shouldDismissOtherSearchOverlays: Bool {
        true
    }

    public static func localFind(
        context: SearchContext = .global,
        source: ImbibSearchActionSource
    ) -> Self {
        Self(workflow: .localFind, source: source, context: context)
    }

    public static func onlineSourceSearch(
        source: ImbibSearchActionSource
    ) -> Self {
        Self(workflow: .onlineSourceSearch, source: source, context: .global)
    }

    /// Posts the typed action while preserving a small userInfo payload for
    /// legacy observers and diagnostics.
    public func post(center: NotificationCenter = .default) {
        center.post(
            name: notificationName,
            object: self,
            userInfo: [
                "workflow": workflow.rawValue,
                "source": source.rawValue,
                "context": context.stableActionID
            ]
        )
    }

    /// Decodes a typed action from a notification.
    public static func from(_ notification: Notification) -> Self? {
        if let action = notification.object as? Self {
            return action
        }

        guard
            let rawWorkflow = notification.userInfo?["workflow"] as? String,
            let workflow = ImbibSearchWorkflow(rawValue: rawWorkflow)
        else {
            return nil
        }

        let source: ImbibSearchActionSource
        if let rawSource = notification.userInfo?["source"] as? String,
           let decoded = ImbibSearchActionSource(rawValue: rawSource) {
            source = decoded
        } else {
            source = .notificationBridge
        }

        return Self(workflow: workflow, source: source)
    }
}

// MARK: - Stable IDs

public extension SearchContext {
    /// A stable, compact identity for route/action tests and diagnostics.
    var stableActionID: String {
        switch self {
        case .global:
            return "global"
        case .library(let id, _):
            return "library-\(id.uuidString)"
        case .collection(let id, _):
            return "collection-\(id.uuidString)"
        case .smartSearch(let id, _):
            return "smartSearch-\(id.uuidString)"
        case .publication(let id, _):
            return "publication-\(id.uuidString)"
        case .pdf(let id, _):
            return "pdf-\(id.uuidString)"
        }
    }
}
