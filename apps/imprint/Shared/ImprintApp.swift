#if os(macOS)
import SwiftUI

// MARK: - Appearance Modifier

/// View modifier that applies user's color scheme preference
struct AppearanceModifier: ViewModifier {
    @AppStorage("appearanceMode") private var appearanceMode = "system"

    private var colorScheme: ColorScheme? {
        switch appearanceMode {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    func body(content: Content) -> some View {
        content.preferredColorScheme(colorScheme)
    }
}

extension View {
    /// Apply user's appearance preference (system/light/dark)
    func withAppearance() -> some View {
        modifier(AppearanceModifier())
    }
}

/// Main application entry point for imprint (macOS)
///
/// imprint is a collaborative academic writing application that uses:
/// - Typst for fast, beautiful document rendering
/// - Automerge CRDT for conflict-free real-time collaboration
/// - imbib integration for citation management
@main
struct ImprintApp: App {
    @StateObject private var appState = AppState()

    /// Whether running in UI testing mode
    private static let isUITesting = CommandLine.arguments.contains("--ui-testing")

    /// Whether to reset app state
    private static let shouldResetState = CommandLine.arguments.contains("--reset-state")

    /// Whether to load sample document
    private static let useSampleDocument = CommandLine.arguments.contains("--sample-document")

    init() {
        // Configure app for testing if needed
        if Self.isUITesting {
            configureForUITesting()
        }

        // Start HTTP automation server for AI/MCP integration
        Task {
            await ImprintHTTPServer.shared.start()
        }
    }

    private func configureForUITesting() {
        // Reset user defaults if requested
        if Self.shouldResetState {
            if let bundleID = Bundle.main.bundleIdentifier {
                UserDefaults.standard.removePersistentDomain(forName: bundleID)

                // Also clear the Saved Application State to prevent window restoration
                if let libraryURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first {
                    let savedStateURL = libraryURL
                        .appendingPathComponent("Saved Application State")
                        .appendingPathComponent("\(bundleID).savedState")
                    try? FileManager.default.removeItem(at: savedStateURL)
                }
            }
        }

        // Disable window restoration for testing
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")

        // Disable animations for faster testing
        UITestingSupport.disableAnimations()
    }

    var body: some Scene {
        // Document-based app for .imprint files
        DocumentGroup(newDocument: Self.createInitialDocument()) { file in
            ContentView(document: file.$document)
                .environmentObject(appState)
                .withAppearance()
                .onAppear {
                    // In UI testing mode, auto-create an untitled document if none open
                    if Self.isUITesting {
                        UITestingSupport.ensureDocumentOpen()
                    }

                    // Register document with HTTP API registry
                    DocumentRegistry.shared.register(file.document, fileURL: file.fileURL)
                }
                .onDisappear {
                    // Unregister document when closed
                    DocumentRegistry.shared.unregister(file.document, fileURL: file.fileURL)
                }
                .onChange(of: file.document) { _, newDoc in
                    // Update registry when document changes
                    DocumentRegistry.shared.register(newDoc, fileURL: file.fileURL)
                }
                .onOpenURL { url in
                    Task {
                        await URLSchemeHandler.shared.handleURL(url)
                    }
                }
        }
        .commands {
            // Edit menu additions
            CommandGroup(after: .textEditing) {
                Button("Insert Citation...") {
                    NotificationCenter.default.post(name: .insertCitation, object: nil)
                }
                .keyboardShortcut("K", modifiers: [.command, .shift])

                Button("Add Comment...") {
                    NotificationCenter.default.post(name: .addCommentAtSelection, object: nil)
                }
                .keyboardShortcut("C", modifiers: [.command, .shift])

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

                Divider()

                Button(appState.isFocusMode ? "Exit Focus Mode" : "Focus Mode") {
                    NotificationCenter.default.post(name: .toggleFocusMode, object: nil)
                }
                .keyboardShortcut("F", modifiers: [.command, .shift])

                Divider()

                Button(appState.showingAIAssistant ? "Hide AI Assistant" : "Show AI Assistant") {
                    NotificationCenter.default.post(name: .toggleAIAssistant, object: nil)
                }
                .keyboardShortcut(".", modifiers: [.command])

                Button(appState.showingComments ? "Hide Comments" : "Show Comments") {
                    NotificationCenter.default.post(name: .toggleCommentsSidebar, object: nil)
                }
                .keyboardShortcut("K", modifiers: [.command, .option])
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

    /// Whether focus mode is active (distraction-free editing)
    @Published var isFocusMode = false

    /// Whether the AI assistant sidebar is visible
    @Published var showingAIAssistant = false

    /// Whether the comments sidebar is visible
    @Published var showingComments = false

    /// Currently selected text (for AI actions)
    @Published var selectedText = ""

    /// Currently selected text range (for comments)
    @Published var selectedRange: NSRange?
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

    /// SF Symbol name for the mode
    var iconName: String {
        switch self {
        case .directPdf: return "doc.richtext"
        case .splitView: return "rectangle.split.2x1"
        case .textOnly: return "doc.text"
        }
    }

    /// Help text for toolbar tooltip
    var helpText: String {
        switch self {
        case .directPdf: return "Direct PDF Mode"
        case .splitView: return "Split View Mode"
        case .textOnly: return "Text Only Mode"
        }
    }

    /// Accessibility identifier for UI testing
    var accessibilityIdentifier: String {
        switch self {
        case .directPdf: return "toolbar.mode.directPdf"
        case .splitView: return "toolbar.mode.splitView"
        case .textOnly: return "toolbar.mode.textOnly"
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
    static let toggleFocusMode = Notification.Name("toggleFocusMode")
    static let toggleAIAssistant = Notification.Name("toggleAIAssistant")
    static let toggleCommentsSidebar = Notification.Name("toggleCommentsSidebar")
    static let addCommentAtSelection = Notification.Name("addCommentAtSelection")
}

// MARK: - UI Testing Support

extension ImprintApp {
    /// Create the initial document based on launch arguments
    static func createInitialDocument() -> ImprintDocument {
        if useSampleDocument {
            return ImprintDocument.sampleDocument()
        }
        return ImprintDocument()
    }
}

/// Helpers for UI testing mode
enum UITestingSupport {
    /// Disable animations for faster test execution
    static func disableAnimations() {
        #if os(macOS)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
        }
        #endif
    }

    /// Ensure at least one document window is open for testing
    static func ensureDocumentOpen() {
        #if os(macOS)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            // If no windows are open, create a new document
            if NSApplication.shared.windows.filter({ $0.isVisible }).isEmpty {
                NSDocumentController.shared.newDocument(nil)
            }
        }
        #endif
    }
}

// MARK: - Sample Document

extension ImprintDocument {
    /// Create a sample document for testing
    static func sampleDocument() -> ImprintDocument {
        var doc = ImprintDocument()
        doc.source = """
        = Sample Document

        This is a sample document for UI testing.

        == Introduction

        Lorem ipsum dolor sit amet, consectetur adipiscing elit.

        == Methods

        The methodology involves several steps:

        + First step
        + Second step
        + Third step

        == Results

        The equation $E = m c^2$ is fundamental to physics.

        == Conclusion

        In conclusion, this sample document demonstrates basic Typst features.
        """
        return doc
    }
}
#endif // os(macOS)
