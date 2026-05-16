import SwiftUI

/// View modifier that wires the Veusz plots inspector + insertion picker into
/// a document window.
///
/// Extracted out of `ContentView.body` so the document body's type-check
/// complexity stays within bounds. Bundles four behaviors:
///   1. The plots inspector panel (`appState.showingVeuszPlots`)
///   2. The plot-picker sheet (Cmd+Shift+I)
///   3. A NotificationCenter listener for `.presentVeuszPlotPicker`
///   4. A NotificationCenter listener for `VeuszPlotInsertion.notificationName`
///      that inserts the rendered snippet at the cursor.
struct VeuszWiringModifier: ViewModifier {
    @Binding var document: ImprintDocument
    let cursorPosition: Int
    @Binding var showingVeuszPlotPicker: Bool

    @Environment(AppState.self) private var appState

    func body(content: Content) -> some View {
        @Bindable var appState = appState
        return content
            .inspector(isPresented: $appState.showingVeuszPlots) {
                VeuszPlotsPanel(document: $document)
                    .inspectorColumnWidth(min: 240, ideal: 300, max: 480)
            }
            .sheet(isPresented: $showingVeuszPlotPicker) {
                InsertVeuszPlotPicker(document: $document, cursorPosition: cursorPosition)
            }
            .onReceive(NotificationCenter.default.publisher(for: .presentVeuszPlotPicker)) { _ in
                showingVeuszPlotPicker = true
            }
            .onReceive(NotificationCenter.default.publisher(for: VeuszPlotInsertion.notificationName)) { notification in
                guard
                    let userInfo = notification.userInfo,
                    let snippet = userInfo["snippet"] as? String
                else { return }
                if let targetID = userInfo["documentID"] as? UUID, targetID != document.id {
                    return
                }
                document.insertText(snippet, at: cursorPosition)
            }
    }
}
