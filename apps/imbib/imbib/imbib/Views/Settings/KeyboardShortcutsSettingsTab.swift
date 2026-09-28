import ImpressKeyboard
import SwiftUI

/// Imbib's own registry bindings; other apps have their own window scopes.
struct KeyboardShortcutsSettingsTab: View {
    var body: some View {
        KeymapSettingsView(appID: "imbib")
    }
}

#Preview {
    KeyboardShortcutsSettingsTab()
        .frame(width: 600, height: 500)
}
