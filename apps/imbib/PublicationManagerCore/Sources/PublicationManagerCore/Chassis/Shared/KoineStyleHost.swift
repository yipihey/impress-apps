//
//  KoineStyleHost.swift
//  PublicationManagerCore
//
//  Loads `<workspace>/settings/koine-style.json` and puts the Swift sheet in
//  `\.koineStyle`, which `SurfaceView` reads on both platforms. The same
//  session is what the editor writes, so a change in the settings page
//  repaints a generated pane that is open in this window.
//
//  macOS opens the editor from View ▸ Edit Style… (⌥⌘Y). iOS opens it from
//  the settings sheet. Both are this host.
//

import ImpressKit
import ImpressLogging
import ImpressSurface
import SwiftUI

@MainActor
@Observable
public final class KoineStyleSession {
    public var book = KoineStyleBook()
    public var frontend = KoineStyleSheet.swiftID
    public var problem: String?
    public var editorPresented = false
    public let fileURL: URL

    public init(fileURL: URL = KoineStyleFile.url(workspace: SharedWorkspace.workspaceDirectory)) {
        self.fileURL = fileURL
    }

    /// The sheet `SurfaceView` paints. A text sheet is never applied here.
    public var swiftSheet: KoineStyleSheet {
        book.sheet(frontend: KoineStyleSheet.swiftID) ?? .swiftDefault
    }

    public func load() {
        switch KoineStyleFile.load(from: fileURL) {
        case .success(let loaded):
            book = loaded
            problem = nil
        case .failure(let error):
            problem = error.errorDescription
            logWarning("koine style: \(error.errorDescription ?? "unreadable")", category: "surface")
        }
    }

    public func store(_ updated: KoineStyleBook) {
        book = updated
        do {
            try KoineStyleFile.save(updated, to: fileURL)
            problem = nil
        } catch {
            problem = error.localizedDescription
            logWarning("koine style: save failed — \(error)", category: "surface")
        }
    }
}

private struct KoineStyleSessionKey: EnvironmentKey {
    static let defaultValue: KoineStyleSession? = nil
}

extension EnvironmentValues {
    var koineStyleSession: KoineStyleSession? {
        get { self[KoineStyleSessionKey.self] }
        set { self[KoineStyleSessionKey.self] = newValue }
    }
}

public struct KoineStyleHost<Content: View>: View {
    @State private var session = KoineStyleSession()
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        @Bindable var session = session
        content
            .environment(\.koineStyleSession, session)
            .environment(\.koineStyle, session.swiftSheet)
            .task { session.load() }
            .onReceive(NotificationCenter.default.publisher(for: .editKoineStyle)) { _ in
                session.editorPresented = true
            }
            .sheet(isPresented: $session.editorPresented) {
                NavigationStack {
                    KoineStyleSettingsPage()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { session.editorPresented = false }
                            }
                        }
                }
                #if os(macOS)
                .frame(minWidth: 560, minHeight: 520)
                #endif
            }
    }
}

extension View {
    /// Load the koine style file and paint generated surfaces with the Swift sheet.
    public func koineStyleHost() -> some View {
        KoineStyleHost { self }
    }
}

struct KoineStyleSettingsPage: View {
    @Environment(\.koineStyleSession) private var session
    @State private var standalone = KoineStyleSession()
    @State private var loadedStandalone = false

    var body: some View {
        page(session ?? standalone)
            .task {
                guard session == nil, !loadedStandalone else { return }
                loadedStandalone = true
                standalone.load()
            }
    }

    private func page(_ session: KoineStyleSession) -> some View {
        @Bindable var session = session
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(
                    "Swift fonts and colors apply in this app. The text sheet is what the terminal reads from the same file."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Picker("Frontend", selection: $session.frontend) {
                    Text("Swift").tag(KoineStyleSheet.swiftID)
                    Text("Text").tag(KoineStyleSheet.tuiID)
                }
                .pickerStyle(.segmented)
                if let problem = session.problem {
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                KoineStyleEditor(book: $session.book, frontend: session.frontend) { updated in
                    session.store(updated)
                }
                .id(session.frontend)
            }
            .padding(16)
        }
        .navigationTitle("Style")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .accessibilityIdentifier("settings.koineStyle.page")
    }
}
