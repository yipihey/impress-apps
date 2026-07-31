#if os(macOS)
// Chassis file — macOS-only: the BUILTIN viewer factories, and only those.
// Each one constructs a chassis section view (`FigureSectionView`,
// `MessageSectionView`, `AgentSectionView`) that is AppKit-adjacent today, so
// the list cannot exist on iOS — but the REGISTRY can, and does
// (`RecordViewerRegistry.swift`, cross-platform since Stage 2a).
//
//  RecordViewerRegistry+Builtin.swift
//  PublicationManagerCore
//
//  Split out of RecordViewerRegistry.swift in the Stage-2a cross-platform
//  pass, following the `CustomSurface.swift` precedent (registry is data, the
//  builtin tier is the one gated piece). Verbatim — each factory still
//  reproduces its former `SectionContentView` construction site, `.id(scope)`
//  included (the imbib CLAUDE.md `.id(source.id)` rule).
//

import SwiftUI

extension RecordViewerRegistry {

    /// A watched `file`-unit folder's pane, when the scope names one
    /// (ADR-0023 W4).
    ///
    /// Checked BEFORE the kind's own list scope, and returning nil otherwise,
    /// so the arm is a prefix rather than a branch: the folder's route is a
    /// `RecordSidebarScope.host` key that `FigureListScope` / `MessageListScope`
    /// correctly decline to parse (they own their kind's RECORD subsets, and a
    /// watched folder is not one). Without this the row would resolve to the
    /// factory's `EmptyView()` fallback — a selectable sidebar row that opens
    /// nothing, which is the exact failure the registry's "degrade quietly"
    /// default is otherwise right about.
    @MainActor
    private static func watchedFilesPane(
        _ context: RecordSectionContext, kind: RecordKindID
    ) -> AnyView? {
        guard case .host(.some(kind), let key) = context.scope,
            case .folder(let folderID)? = WatchedFolderRoute(key: key)
        else { return nil }
        return AnyView(
            WatchedFilesPane(folderID: folderID, kindScope: kind.rawValue)
                .id(key))
    }

    /// The factories `RecordViewerRegistry.builtin` is built from on macOS.
    static let macOSBuiltinFactories: [RecordViewerFactory] = [
        RecordViewerFactory(
            kind: .figure,
            makeSectionView: { context in
                if let pane = watchedFilesPane(context, kind: .figure) { return pane }
                guard let scope = context.scope(as: FigureListScope.self) else {
                    return AnyView(EmptyView())
                }
                return AnyView(FigureSectionView(scope: scope).id(scope))
            }
        ),
        RecordViewerFactory(
            kind: .message,
            makeSectionView: { context in
                if let pane = watchedFilesPane(context, kind: .message) { return pane }
                guard let scope = context.scope(as: MessageListScope.self) else {
                    return AnyView(EmptyView())
                }
                return AnyView(MessageSectionView(scope: scope).id(scope))
            }
        ),
        // Tasks and runs share ONE section view — the scope decides which
        // schema it lists (AgentRecordListWrapper), so both kinds resolve to
        // the same factory shape rather than the section growing a branch.
        RecordViewerFactory(
            kind: .task,
            makeSectionView: { context in
                guard let scope = context.scope(as: AgentListScope.self) else {
                    return AnyView(EmptyView())
                }
                return AnyView(AgentSectionView(scope: scope).id(scope))
            }
        ),
        RecordViewerFactory(
            kind: .agentRun,
            makeSectionView: { context in
                guard let scope = context.scope(as: AgentListScope.self) else {
                    return AnyView(EmptyView())
                }
                return AnyView(AgentSectionView(scope: scope).id(scope))
            }
        ),
    ]
}
#endif
