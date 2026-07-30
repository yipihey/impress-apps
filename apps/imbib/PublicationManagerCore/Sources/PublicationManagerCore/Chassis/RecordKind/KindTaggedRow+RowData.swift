// Chassis CONTRACT file — CROSS-PLATFORM (macOS + iOS): the per-kind row
// structs these initializers name (FigureRowData, MessageRowData, TaskRowData,
// AgentRunRowData, ManuscriptRowData) went cross-platform in Stage 2a, so the
// convenience initializers travel with them.
// Chassis file — macOS-only: the per-kind row structs these initializers name
// (FigureRowData, MessageRowData, TaskRowData, AgentRunRowData,
// ManuscriptRowData) are each declared in a macOS-gated chassis file.
//
//  KindTaggedRow+RowData.swift
//  PublicationManagerCore
//
//  Split out of KindTaggedRow.swift in the iOS foundation pass. Verbatim —
//  these are the "fix the kind tag" one-liners over the generic
//  `init(kind:item:)`, which stayed cross-platform with the row type.
//

import Foundation
import ImpressMailStyle

public extension KindTaggedRow {

    @MainActor
    init(figure: FigureRowData) { self.init(kind: .figure, item: figure) }

    @MainActor
    init(message: MessageRowData) { self.init(kind: .message, item: message) }

    @MainActor
    init(task: TaskRowData) { self.init(kind: .task, item: task) }

    @MainActor
    init(agentRun: AgentRunRowData) { self.init(kind: .agentRun, item: agentRun) }

    @MainActor
    init(manuscript: ManuscriptRowData) { self.init(kind: .manuscript, item: manuscript) }
}
