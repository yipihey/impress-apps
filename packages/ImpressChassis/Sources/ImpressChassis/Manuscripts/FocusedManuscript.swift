// Chassis CONTRACT file — CROSS-PLATFORM (macOS + iOS): a `FocusedValueKey`
// declaration — pure SwiftUI focus plumbing.
//
//  FocusedManuscript.swift
//  ImpressChassis (lifted out of PublicationManagerCore by C5)
//
//  Scene-focused manuscript identity. Both manuscript hosts publish it —
//  ManuscriptSectionView (chassis list|detail split) and imprint's standalone
//  ManuscriptEditorView — so app menu commands (File ▸ Export…) always act on
//  the manuscript of the FRONTMOST window, replacing the retired
//  NotificationCenter export posts that nothing observed.

import SwiftUI

public struct FocusedManuscriptIDKey: FocusedValueKey {
    public typealias Value = UUID
}

public extension FocusedValues {
    /// The manuscript shown/selected in the currently focused scene.
    var focusedManuscriptID: UUID? {
        get { self[FocusedManuscriptIDKey.self] }
        set { self[FocusedManuscriptIDKey.self] = newValue }
    }
}
