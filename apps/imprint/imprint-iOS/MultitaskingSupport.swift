//
//  MultitaskingSupport.swift
//  imprint-iOS
//
//  Created by Claude on 2026-01-27.
//

import UIKit
import SwiftUI

// MARK: - Scene Delegate

/// Scene delegate for managing imprint's multitasking support.
///
/// Supports:
/// - Split View (side-by-side with another app)
/// - Slide Over (floating window)
/// - Stage Manager (iPadOS 16+, resizable windows)
/// - Multiple windows of the same document
class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }

        // Configure window
        let window = UIWindow(windowScene: windowScene)

        // Handle user activity for handoff
        if let userActivity = connectionOptions.userActivities.first {
            handleUserActivity(userActivity, in: window)
        } else if let urlContext = connectionOptions.urlContexts.first {
            handleURLContext(urlContext, in: window)
        } else {
            showDefaultContent(in: window)
        }

        self.window = window
        window.makeKeyAndVisible()

        // Configure for Stage Manager if available
        configureForStageManager(windowScene)
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let context = URLContexts.first else { return }

        Task {
            await URLSchemeHandler.shared.handleURL(context.url)
        }
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        // Handle handoff from macOS imprint
        handleUserActivity(userActivity, in: window)
    }

    func stateRestorationActivity(for scene: UIScene) -> NSUserActivity? {
        // Return activity for state restoration/handoff
        return createCurrentActivity()
    }

    func windowScene(
        _ windowScene: UIWindowScene,
        didUpdate previousCoordinateSpace: UICoordinateSpace,
        interfaceOrientation previousInterfaceOrientation: UIInterfaceOrientation,
        traitCollection previousTraitCollection: UITraitCollection
    ) {
        // Handle window resize for Stage Manager
        updateLayoutForWindowSize(windowScene.coordinateSpace.bounds.size)
    }

    // MARK: - Content Setup

    private func showDefaultContent(in window: UIWindow?) {
        // Show document picker for new window
        let contentView = DocumentBrowserView()
        window?.rootViewController = UIHostingController(rootView: contentView)
    }

    private func handleUserActivity(_ activity: NSUserActivity, in window: UIWindow?) {
        // Handle handoff document
        guard activity.activityType == "com.imbib.imprint.document",
              let documentURL = activity.userInfo?["documentURL"] as? URL else {
            showDefaultContent(in: window)
            return
        }

        // Open the document
        openDocument(at: documentURL, in: window)
    }

    private func handleURLContext(_ context: UIOpenURLContext, in window: UIWindow?) {
        Task {
            await URLSchemeHandler.shared.handleURL(context.url)
        }
        showDefaultContent(in: window)
    }

    private func openDocument(at url: URL, in window: UIWindow?) {
        // TODO: Open document at URL
        showDefaultContent(in: window)
    }

    // MARK: - Stage Manager

    private func configureForStageManager(_ windowScene: UIWindowScene) {
        // Set minimum and maximum window sizes for Stage Manager
        if #available(iOS 16.0, *) {
            let geometryPreferences = UIWindowScene.GeometryPreferences.iOS(
                interfaceOrientations: .all
            )
            windowScene.requestGeometryUpdate(geometryPreferences)

            // Set size restrictions
            windowScene.sizeRestrictions?.minimumSize = CGSize(width: 320, height: 480)
            windowScene.sizeRestrictions?.maximumSize = CGSize(width: 2000, height: 2000)
        }
    }

    private func updateLayoutForWindowSize(_ size: CGSize) {
        // Notify views of size change for responsive layout
        NotificationCenter.default.post(
            name: .windowSizeDidChange,
            object: nil,
            userInfo: ["size": size]
        )
    }

    // MARK: - Handoff

    private func createCurrentActivity() -> NSUserActivity {
        let activity = NSUserActivity(activityType: "com.imbib.imprint.document")
        activity.title = "imprint Document"
        activity.isEligibleForHandoff = true
        activity.isEligibleForSearch = false
        activity.isEligibleForPublicIndexing = false

        // Add document info if available
        // TODO: Add current document URL

        return activity
    }
}

// MARK: - Document Browser View

/// A document browser for opening and creating imprint documents.
struct DocumentBrowserView: View {
    @State private var showingFilePicker = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "doc.text.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.secondary)

                Text("imprint")
                    .font(.largeTitle.bold())

                Text("Academic writing, reimagined")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Spacer().frame(height: 24)

                Button {
                    // Create new document
                } label: {
                    Label("New Document", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    showingFilePicker = true
                } label: {
                    Label("Open Document", systemImage: "folder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .padding(40)
            .navigationTitle("Welcome")
            .fileImporter(
                isPresented: $showingFilePicker,
                allowedContentTypes: [.init(filenameExtension: "imprint")!],
                allowsMultipleSelection: false
            ) { result in
                // Handle file selection
            }
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    /// Posted when the window size changes (Stage Manager)
    static let windowSizeDidChange = Notification.Name("windowSizeDidChange")
}

// MARK: - Multitasking Environment

/// Environment key for current window size class
struct MultitaskingEnvironmentKey: EnvironmentKey {
    static let defaultValue = MultitaskingMode.fullScreen
}

/// Current multitasking mode
enum MultitaskingMode {
    case fullScreen
    case splitView
    case slideOver
    case stageManager

    /// Whether the app has limited width
    var isCompact: Bool {
        switch self {
        case .slideOver, .splitView:
            return true
        case .fullScreen, .stageManager:
            return false
        }
    }
}

extension EnvironmentValues {
    var multitaskingMode: MultitaskingMode {
        get { self[MultitaskingEnvironmentKey.self] }
        set { self[MultitaskingEnvironmentKey.self] = newValue }
    }
}

// MARK: - Adaptive Layout Modifier

/// A view modifier that adapts layout based on multitasking mode.
struct AdaptiveLayoutModifier: ViewModifier {
    @Environment(\.horizontalSizeClass) var horizontalSizeClass
    @Environment(\.verticalSizeClass) var verticalSizeClass

    func body(content: Content) -> some View {
        content
            .environment(\.multitaskingMode, currentMode)
    }

    private var currentMode: MultitaskingMode {
        switch (horizontalSizeClass, verticalSizeClass) {
        case (.compact, .regular):
            return .slideOver
        case (.compact, .compact):
            return .splitView
        case (.regular, .compact):
            return .splitView
        default:
            return .fullScreen
        }
    }
}

extension View {
    /// Applies adaptive layout based on multitasking mode.
    func adaptiveLayout() -> some View {
        modifier(AdaptiveLayoutModifier())
    }
}

// MARK: - Preview

#Preview("Document Browser") {
    DocumentBrowserView()
}
