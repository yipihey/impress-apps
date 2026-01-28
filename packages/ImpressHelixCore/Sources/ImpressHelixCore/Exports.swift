//
//  Exports.swift
//  ImpressHelixCore
//
//  Re-exports the UniFFI-generated Swift bindings and Swift wrapper types.
//

// Re-export all public types from the generated bindings
@_exported import struct Foundation.Data

// The generated bindings are in impress_helix.swift in this same module.
// All public types (FfiHelixEditor, FfiHelixMode, etc.) are automatically
// available to consumers of this module.

// Type aliases for cleaner Swift API
public typealias HelixMode = FfiHelixMode
public typealias KeyModifiers = FfiKeyModifiers
public typealias KeyResult = FfiKeyResult
public typealias SpaceCommand = FfiSpaceCommand
public typealias TextRange = FfiTextRange
public typealias Motion = FfiMotion
public typealias HelixCommand = FfiHelixCommand
public typealias TextObject = FfiTextObject
public typealias TextObjectModifier = FfiTextObjectModifier
public typealias WhichKeyItem = FfiWhichKeyItem

// Convenience extensions
extension FfiHelixMode {
    /// Display name for UI
    public var displayName: String {
        switch self {
        case .normal: return "NORMAL"
        case .insert: return "INSERT"
        case .select: return "SELECT"
        }
    }
}

extension FfiKeyModifiers {
    /// No modifiers
    public static let none = FfiKeyModifiers(shift: false, control: false, alt: false)
}

#if canImport(AppKit)
import AppKit

extension FfiKeyModifiers {
    /// Create modifiers from AppKit event flags
    public init(eventFlags: NSEvent.ModifierFlags) {
        self.init(
            shift: eventFlags.contains(.shift),
            control: eventFlags.contains(.control),
            alt: eventFlags.contains(.option)
        )
    }
}
#endif
