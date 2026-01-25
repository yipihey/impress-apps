import SwiftUI

/// Main application entry point for imprint
///
/// imprint is a collaborative academic writing application that uses:
/// - Typst for fast, beautiful document rendering
/// - Automerge CRDT for conflict-free real-time collaboration
/// - imbib integration for citation management
@main
struct ImprintApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        // Document-based app for .imprint files
        DocumentGroup(newDocument: ImprintDocument()) { file in
            ContentView(document: file.$document)
                .environmentObject(appState)
        }
        .commands {
            // Edit menu additions
            CommandGroup(after: .textEditing) {
                Button("Insert Citation...") {
                    NotificationCenter.default.post(name: .insertCitation, object: nil)
                }
                .keyboardShortcut("K", modifiers: [.command, .shift])

                Divider()

                Button("Compile to PDF") {
                    NotificationCenter.default.post(name: .compileDocument, object: nil)
                }
                .keyboardShortcut("B", modifiers: [.command])
            }

            // View menu additions
            CommandGroup(after: .sidebar) {
                Picker("Edit Mode", selection: $appState.editMode) {
                    Text("Direct PDF").tag(EditMode.directPdf)
                    Text("Split View").tag(EditMode.splitView)
                    Text("Text Only").tag(EditMode.textOnly)
                }
                .keyboardShortcut(.tab)
            }

            // Format menu
            CommandMenu("Format") {
                Button("Bold") {
                    NotificationCenter.default.post(name: .formatBold, object: nil)
                }
                .keyboardShortcut("B", modifiers: [.command])

                Button("Italic") {
                    NotificationCenter.default.post(name: .formatItalic, object: nil)
                }
                .keyboardShortcut("I", modifiers: [.command])

                Divider()

                Menu("Heading") {
                    Button("Heading 1") {
                        NotificationCenter.default.post(name: .insertHeading, object: 1)
                    }
                    .keyboardShortcut("1", modifiers: [.command, .option])

                    Button("Heading 2") {
                        NotificationCenter.default.post(name: .insertHeading, object: 2)
                    }
                    .keyboardShortcut("2", modifiers: [.command, .option])

                    Button("Heading 3") {
                        NotificationCenter.default.post(name: .insertHeading, object: 3)
                    }
                    .keyboardShortcut("3", modifiers: [.command, .option])
                }
            }

            // Document menu
            CommandMenu("Document") {
                Button("Export to LaTeX...") {
                    NotificationCenter.default.post(name: .exportLatex, object: nil)
                }
                .keyboardShortcut("E", modifiers: [.command, .shift])

                Button("Export Bibliography...") {
                    NotificationCenter.default.post(name: .exportBibliography, object: nil)
                }

                Divider()

                Button("Version History...") {
                    NotificationCenter.default.post(name: .showVersionHistory, object: nil)
                }
                .keyboardShortcut("H", modifiers: [.command, .option])

                Divider()

                Button("Share...") {
                    NotificationCenter.default.post(name: .shareDocument, object: nil)
                }
                .keyboardShortcut("S", modifiers: [.command, .shift])
            }
        }

        // Settings window
        #if os(macOS)
        Settings {
            SettingsView()
        }
        #endif
    }
}

// MARK: - App State

/// Global application state
@MainActor
class AppState: ObservableObject {
    /// Current edit mode (cycles with Tab)
    @Published var editMode: EditMode = .splitView

    /// Whether the citation picker is showing
    @Published var showingCitationPicker = false

    /// Whether version history is showing
    @Published var showingVersionHistory = false
}

/// Editing modes for imprint
enum EditMode: String, CaseIterable {
    /// Direct PDF manipulation (WYSIWYG-like)
    case directPdf = "direct_pdf"

    /// Split view with source and preview
    case splitView = "split_view"

    /// Text only (focus mode)
    case textOnly = "text_only"

    /// Cycle to the next mode
    mutating func cycle() {
        switch self {
        case .directPdf: self = .splitView
        case .splitView: self = .textOnly
        case .textOnly: self = .directPdf
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let insertCitation = Notification.Name("insertCitation")
    static let compileDocument = Notification.Name("compileDocument")
    static let formatBold = Notification.Name("formatBold")
    static let formatItalic = Notification.Name("formatItalic")
    static let insertHeading = Notification.Name("insertHeading")
    static let exportLatex = Notification.Name("exportLatex")
    static let exportBibliography = Notification.Name("exportBibliography")
    static let showVersionHistory = Notification.Name("showVersionHistory")
    static let shareDocument = Notification.Name("shareDocument")
}
