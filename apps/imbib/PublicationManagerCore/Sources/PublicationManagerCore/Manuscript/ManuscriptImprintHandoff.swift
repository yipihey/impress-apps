#if os(macOS)
//
//  ManuscriptImprintHandoff.swift
//  PublicationManagerCore
//
//  One place that opens a manuscript in imprint, so every entry point (the
//  list's context menu, the Source-tab "compile in imprint" affordance) uses
//  the same URL and can't drift.
//
//  imbib and imprint share the unified store (ADR-023), so the manuscript
//  already exists on the imprint side under the SAME UUID — there is no
//  separate imprint document to create or bridge. The handoff simply asks
//  imprint to open that manuscript's editor by UUID; imprint's URL handler
//  posts `.openManuscriptInEditor`, which opens the editor window.
//

import AppKit
import Foundation

@MainActor
public enum ManuscriptImprintHandoff {

    /// Open `manuscriptID` in imprint (launching it if needed). Returns `false`
    /// only if the URL could not be handed to the workspace.
    @discardableResult
    public static func open(manuscriptID: UUID) -> Bool {
        guard let url = URL(string: "imprint://open?manuscript=\(manuscriptID.uuidString)")
        else { return false }
        return NSWorkspace.shared.open(url)
    }
}
#endif
