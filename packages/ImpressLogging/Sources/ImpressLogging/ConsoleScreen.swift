#if os(iOS)
//
//  ConsoleScreen.swift
//  ImpressLogging
//
//  The iOS RENDERER for the shared console (Stage 5b, 2026-07-30).
//
//  Split out for the reason `IOSSettingsScreen` is split out from
//  `MacSettingsSceneContent`: presentation is platform-shaped even when the
//  content is not. macOS opens `ConsoleView` in a `Window` (⌘⇧C); iOS presents
//  it as a sheet, which needs a `NavigationStack`, an inline title and a Done
//  button that dismisses the sheet its own column raised.
//
//  The CONTENT is `ConsoleView` — the same filters, the same list, the same
//  export, and the Performance tab iOS never had.
//

import SwiftUI

/// The console as an iOS sheet.
///
/// ```swift
/// .sheet(isPresented: $showConsole) { ConsoleScreen(appName: "imbib") }
/// ```
public struct ConsoleScreen: View {

    private let appName: String

    @Environment(\.dismiss) private var dismiss

    /// - Parameter appName: parameterizes the export filename
    ///   (`<appName>-log-<ISO8601>.txt`), exactly as on macOS.
    public init(appName: String = "impress") {
        self.appName = appName
    }

    public var body: some View {
        NavigationStack {
            ConsoleView(appName: appName)
                .navigationTitle("Console")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}
#endif
