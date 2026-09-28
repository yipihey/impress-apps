import ImpressKeyboard
import SwiftUI

/// The menu bar and ⌘/ reference read the same registry as Settings ▸ Keyboard.
struct ShortcutsHelpView: View {
    var body: some View {
        KeymapSettingsView(appID: "imprint")
    }
}
