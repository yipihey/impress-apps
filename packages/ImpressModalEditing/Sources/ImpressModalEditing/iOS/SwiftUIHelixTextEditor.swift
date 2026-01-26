#if canImport(UIKit)
import SwiftUI
import UIKit

/// A SwiftUI text editor with Helix-style modal editing support for iOS.
@available(iOS 17.0, *)
public struct HelixTextEditor: View {
    @Binding var text: String
    @ObservedObject var helixState: HelixState

    /// Whether the command bar is visible (for touch input).
    @State private var showCommandBar: Bool = false

    /// Whether to show the mode indicator.
    let showModeIndicator: Bool

    /// Position of the mode indicator.
    let indicatorPosition: HelixModeIndicatorPosition

    public init(
        text: Binding<String>,
        helixState: HelixState,
        showModeIndicator: Bool = true,
        indicatorPosition: HelixModeIndicatorPosition = .bottomLeft
    ) {
        self._text = text
        self.helixState = helixState
        self.showModeIndicator = showModeIndicator
        self.indicatorPosition = indicatorPosition
    }

    public var body: some View {
        VStack(spacing: 0) {
            TextEditor(text: $text)
                .scrollContentBackground(.hidden)
                .onKeyPress { keyPress in
                    handleKeyPress(keyPress)
                }
                .overlay(alignment: indicatorPosition.alignment) {
                    if showModeIndicator {
                        HelixModeIndicator(state: helixState, position: indicatorPosition)
                            .padding(12)
                    }
                }

            if showCommandBar && helixState.mode != .insert {
                HelixCommandBar(helixState: helixState)
            }
        }
        .onTapGesture(count: 2) {
            showCommandBar.toggle()
        }
    }

    private func handleKeyPress(_ keyPress: KeyPress) -> KeyPress.Result {
        // In insert mode, only handle Escape
        if helixState.mode == .insert {
            if keyPress.key == .escape {
                helixState.setMode(.normal)
                return .handled
            }
            return .ignored
        }

        // Get the character from the key press
        guard let char = keyPress.characters.first else {
            return .ignored
        }

        var modifiers: KeyModifiers = []
        if keyPress.modifiers.contains(.shift) { modifiers.insert(.shift) }
        if keyPress.modifiers.contains(.control) { modifiers.insert(.control) }
        if keyPress.modifiers.contains(.option) { modifiers.insert(.option) }
        if keyPress.modifiers.contains(.command) { modifiers.insert(.command) }

        // Note: On iOS we don't have direct access to the underlying text view,
        // so we handle commands via the state's command publisher
        let result = helixState.keyHandler.handleKey(char, in: helixState.mode, modifiers: modifiers)

        switch result {
        case .command(let command):
            executeCommand(command)
            return .handled
        case .commands(let commands):
            for command in commands {
                executeCommand(command)
            }
            return .handled
        case .passThrough:
            return .ignored
        case .pending, .consumed:
            return .handled
        }
    }

    private func executeCommand(_ command: HelixCommand) {
        switch command {
        case .enterInsertMode:
            helixState.setMode(.insert)
        case .enterNormalMode:
            helixState.setMode(.normal)
        case .enterSelectMode:
            helixState.setMode(.select)
        case .selectAll:
            // Can't directly manipulate TextEditor selection, so we publish the command
            break
        default:
            // Other commands are published for external handling
            break
        }
        helixState.commandPublisher.send(command)
    }
}

/// A command bar for touch-based Helix command input on iOS.
@available(iOS 17.0, *)
public struct HelixCommandBar: View {
    @ObservedObject var helixState: HelixState

    public init(helixState: HelixState) {
        self.helixState = helixState
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // Mode buttons
                CommandButton(label: "i", description: "Insert") {
                    helixState.setMode(.insert)
                }

                CommandButton(label: "ESC", description: "Normal") {
                    helixState.setMode(.normal)
                }

                Divider()
                    .frame(height: 30)

                // Movement buttons
                CommandButton(label: "h", description: "Left") {
                    helixState.commandPublisher.send(.moveLeft())
                }

                CommandButton(label: "j", description: "Down") {
                    helixState.commandPublisher.send(.moveDown())
                }

                CommandButton(label: "k", description: "Up") {
                    helixState.commandPublisher.send(.moveUp())
                }

                CommandButton(label: "l", description: "Right") {
                    helixState.commandPublisher.send(.moveRight())
                }

                Divider()
                    .frame(height: 30)

                // Selection buttons
                CommandButton(label: "x", description: "Line") {
                    helixState.commandPublisher.send(.selectLine)
                }

                CommandButton(label: "%", description: "All") {
                    helixState.commandPublisher.send(.selectAll)
                }

                Divider()
                    .frame(height: 30)

                // Editing buttons
                CommandButton(label: "d", description: "Delete") {
                    helixState.commandPublisher.send(.delete)
                }

                CommandButton(label: "y", description: "Yank") {
                    helixState.commandPublisher.send(.yank)
                }

                CommandButton(label: "p", description: "Paste") {
                    helixState.commandPublisher.send(.pasteAfter)
                }

                CommandButton(label: "u", description: "Undo") {
                    helixState.commandPublisher.send(.undo)
                }
            }
            .padding(.horizontal)
        }
        .frame(height: 50)
        .background(.regularMaterial)
    }
}

/// A single command button in the command bar.
@available(iOS 17.0, *)
private struct CommandButton: View {
    let label: String
    let description: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(label)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                Text(description)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.bordered)
    }
}

#Preview {
    if #available(iOS 17.0, *) {
        HelixTextEditor(
            text: .constant("Hello, Helix!\n\nThis is a test of modal editing."),
            helixState: HelixState()
        )
    }
}
#endif
