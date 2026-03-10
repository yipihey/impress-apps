import OSLog

extension Logger {
    // Compilation & Rendering
    static let compilation = Logger(subsystem: "com.imprint.app", category: "compilation")
    static let typstRender = Logger(subsystem: "com.imprint.app", category: "typst")
    static let latexProject = Logger(subsystem: "com.imprint.app", category: "latex-project")
    static let synctex = Logger(subsystem: "com.imprint.app", category: "synctex")
    static let texDistribution = Logger(subsystem: "com.imprint.app", category: "tex-distribution")
    static let latexFormatter = Logger(subsystem: "com.imprint.app", category: "latex-formatter")
    static let latexCompletion = Logger(subsystem: "com.imprint.app", category: "latex-completion")

    // Persistence & Documents
    static let persistence = Logger(subsystem: "com.imprint.app", category: "persistence")
    static let documents = Logger(subsystem: "com.imprint.app", category: "documents")
    static let backup = Logger(subsystem: "com.imprint.app", category: "backup")
    static let bookmarks = Logger(subsystem: "com.imprint.app", category: "bookmarks")
    static let metadataCache = Logger(subsystem: "com.imprint.app", category: "metadata-cache")
    static let crdt = Logger(subsystem: "com.imprint.app", category: "crdt")
    static let folders = Logger(subsystem: "com.imprint.app", category: "folders")
    static let sharedStore = Logger(subsystem: "com.imprint.app", category: "shared-store")

    // Collaboration & Sharing
    static let collaboration = Logger(subsystem: "com.imprint.app", category: "collaboration")
    static let sharing = Logger(subsystem: "com.imprint.app", category: "sharing")
    static let handoff = Logger(subsystem: "com.imprint.app", category: "handoff")

    // AI & Integration
    static let ai = Logger(subsystem: "com.imprint.app", category: "ai")
    static let inlineCompletion = Logger(subsystem: "com.imprint.app", category: "inline-completion")
    static let imbibIntegration = Logger(subsystem: "com.imprint.app", category: "imbib")
    static let comments = Logger(subsystem: "com.imprint.app", category: "comments")

    // Infrastructure
    static let httpServer = Logger(subsystem: "com.imprint.app", category: "http-server")
    static let httpRouter = Logger(subsystem: "com.imprint.app", category: "http-router")
    static let urlScheme = Logger(subsystem: "com.imprint.app", category: "url-scheme")
    static let editor = Logger(subsystem: "com.imprint.app", category: "editor")
    static let spotlight = Logger(subsystem: "com.imprint.app", category: "spotlight")

    // iOS
    static let dictation = Logger(subsystem: "com.imprint.app", category: "dictation")
    static let sketch = Logger(subsystem: "com.imprint.app", category: "sketch")
}
