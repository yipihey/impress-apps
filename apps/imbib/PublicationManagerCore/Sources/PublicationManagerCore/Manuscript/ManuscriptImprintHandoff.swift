//
//  ManuscriptImprintHandoff.swift
//  PublicationManagerCore
//
//  One place that opens a manuscript in imprint, so every entry point (the
//  list's context menu, the Source-tab "compile in imprint" affordance, the
//  read-only iOS pane's Edit affordance) uses the same URL and can't drift.
//
//  imbib and imprint share the unified store (ADR-023), so the manuscript
//  already exists on the imprint side under the SAME UUID — there is no
//  separate imprint document to create or bridge. The handoff simply asks
//  imprint to open that manuscript's editor by UUID; imprint's URL handler
//  posts `.openManuscriptInEditor`, which opens the editor window.
//
//  CROSS-PLATFORM since I2. It was `#if os(macOS)` for one `NSWorkspace` call —
//  the same shape as the two detail panes ADR-0022 D9 found gated for one
//  AppKit line each. The read-only iOS manuscript pane hands typst manuscripts
//  off to imprint rather than shipping a compiler, so the handoff had to exist
//  on the platform doing the handing off.
//
//  The URL spelling is `imprint://open?manuscript=<uuid>` and NOT
//  `ImpressURL.openDocument(id:)`'s `imprint://open/document/<uuid>`. That is a
//  real disagreement in the suite's URL grammar, deliberately not resolved
//  here: imprint's own handler — on both platforms — parses the QUERY form, so
//  changing this line would break a working handoff to fix a docs
//  inconsistency. Recorded in docs/chassis-capability-matrix.md instead.
//

import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
public enum ManuscriptImprintHandoff {

    /// The URL that opens `manuscriptID` in imprint.
    public static func url(manuscriptID: UUID) -> URL? {
        URL(string: "imprint://open?manuscript=\(manuscriptID.uuidString)")
    }

    /// Open `manuscriptID` in imprint (launching it if needed). Returns `false`
    /// only if the URL could not be handed to the system.
    ///
    /// On iOS the answer is optimistic: `UIApplication.open` reports
    /// asynchronously, so callers must not read `true` as "imprint opened it".
    @discardableResult
    public static func open(manuscriptID: UUID) -> Bool {
        guard let url = url(manuscriptID: manuscriptID) else { return false }
        #if os(macOS)
        return NSWorkspace.shared.open(url)
        #else
        guard UIApplication.shared.canOpenURL(url) else { return false }
        UIApplication.shared.open(url)
        return true
        #endif
    }

    /// Whether this device has something registered for imprint's scheme.
    ///
    /// iOS answers honestly (`canOpenURL`, which needs `imprint` in the host's
    /// `LSApplicationQueriesSchemes`); macOS always says yes, because
    /// `NSWorkspace.open` on a missing app fails visibly rather than silently
    /// and the affordance should stay.
    public static var isAvailable: Bool {
        #if os(macOS)
        return true
        #else
        guard let url = url(manuscriptID: UUID()) else { return false }
        return UIApplication.shared.canOpenURL(url)
        #endif
    }
}
