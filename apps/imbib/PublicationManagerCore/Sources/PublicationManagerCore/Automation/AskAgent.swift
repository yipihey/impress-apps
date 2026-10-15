//
//  AskAgent.swift
//  PublicationManagerCore
//
//  View ▸ Ask an Agent… (⌃⌥⌘A, `imbib.view.ask_agent`). The sheet and the
//  desk calls live in ImpressAutomation (`AgentDesk.swift`); this names the
//  notification for the app target, which does not import that package, and
//  fixes the app id the request carries — `imbib`, whose layout focus and
//  selection become the question's context.
//

import SwiftUI
import ImpressAutomation

public extension Notification.Name {
    /// Show the "Ask an Agent" sheet (⌃⌥⌘A).
    static let showAskAgent = Notification.Name.impressAskAgent
}

public extension View {
    /// imbib's "Ask an Agent" sheet, opened by `.showAskAgent`.
    func imbibAskAgentSheet() -> some View {
        askAgentSheet(app: "imbib")
    }
}
