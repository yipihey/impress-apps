//
//  ImbibSearchPresenter.swift
//  PublicationManagerCore
//
//  Shared presentation state for imbib's flagship search workflows.
//

import Foundation
import OSLog

/// Testable state machine for presenting Cmd+F and Cmd+S search surfaces.
///
/// App shells own an instance and bind their overlays/covers to the computed
/// workflow state. Entry points should call `perform(_:)` with a typed action
/// instead of toggling independent booleans.
@MainActor
@Observable
public final class ImbibSearchPresenter {

    /// The currently presented search workflow, if any.
    public private(set) var presentedWorkflow: ImbibSearchWorkflow?

    /// The scope used when the local find palette is presented.
    public private(set) var localFindContext: SearchContext = .global

    public init() {}

    public var isLocalFindPresented: Bool {
        presentedWorkflow == .localFind
    }

    public var isOnlineSourceSearchPresented: Bool {
        presentedWorkflow == .onlineSourceSearch
    }

    /// Present the workflow described by a typed action.
    public func perform(_ action: ImbibSearchAction) {
        switch action.workflow {
        case .localFind:
            if localFindContext != action.context {
                localFindContext = action.context
            }
            if presentedWorkflow != .localFind {
                presentedWorkflow = .localFind
            }
            Logger.search.infoCapture(
                "Presenting local find from \(action.source.rawValue) with context \(action.context.stableActionID)",
                category: "search"
            )

        case .onlineSourceSearch:
            if presentedWorkflow != .onlineSourceSearch {
                presentedWorkflow = .onlineSourceSearch
            }
            Logger.search.infoCapture(
                "Presenting online source search from \(action.source.rawValue)",
                category: "search"
            )
        }
    }

    /// Dismiss the current search workflow.
    ///
    /// Passing a workflow only dismisses when that workflow is currently shown,
    /// which keeps stale overlay bindings from closing a newer search surface.
    public func dismiss(_ workflow: ImbibSearchWorkflow? = nil) {
        if let workflow, presentedWorkflow != workflow {
            return
        }
        if presentedWorkflow != nil {
            presentedWorkflow = nil
        }
    }
}
