import Foundation

/// Helix editor style implementation.
///
/// Helix is a selection-first modal editor inspired by Kakoune.
/// Key differences from Vim:
/// - Selection is primary (select first, then operate)
/// - Multiple cursors support
/// - Tree-sitter integration for syntax-aware selections
public struct HelixStyle: EditorStyle {
    public typealias Mode = HelixMode
    public typealias Command = HelixCommand
    public typealias State = HelixState
    public typealias Handler = HelixKeyHandler

    public static let identifier: EditorStyleIdentifier = .helix

    public init() {}

    @MainActor
    public func createState() -> HelixState {
        HelixState()
    }

    @MainActor
    public func createKeyHandler() -> HelixKeyHandler {
        HelixKeyHandler()
    }
}

// MARK: - HelixMode conformance to EditorMode

extension HelixMode: EditorMode {
    public var allowsTextInput: Bool {
        self == .insert
    }
}

// MARK: - HelixCommand conformance to EditorCommand

// Note: EditorCommand conformance is declared here but extendsSelection
// and isRepeatable are already defined in HelixCommand.swift
// Hashable conformance is now in HelixCommand.swift itself
extension HelixCommand: EditorCommand {}
