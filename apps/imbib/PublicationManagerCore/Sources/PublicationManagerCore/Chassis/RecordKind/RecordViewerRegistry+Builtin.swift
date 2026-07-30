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

    /// The factories `RecordViewerRegistry.builtin` is built from on macOS.
    static let macOSBuiltinFactories: [RecordViewerFactory] = [
        RecordViewerFactory(
            kind: .figure,
            makeSectionView: { context in
                guard let scope = context.scope(as: FigureListScope.self) else {
                    return AnyView(EmptyView())
                }
                return AnyView(FigureSectionView(scope: scope).id(scope))
            }
        ),
        RecordViewerFactory(
            kind: .message,
            makeSectionView: { context in
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
