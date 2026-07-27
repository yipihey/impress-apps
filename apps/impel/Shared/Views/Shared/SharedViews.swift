//
//  SharedViews.swift
//  impel
//
//  Cross-surface helpers: shake effect, keyboard-help sheet.
//  Moved verbatim from ContentView.swift (C0 mechanical decomposition,
//  Stage 2-C of the GUI unification) — no renames, no signature changes.
//

import SwiftUI
import ImpelCore
import ImpelMail
import CounselEngine
import ImpressKeyboard
import ImpressKit

// MARK: - Shake Effect

struct ShakeEffect: GeometryEffect {
    var shakes: Int
    var animatableData: CGFloat {
        get { CGFloat(shakes) }
        set { shakes = Int(newValue) }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let offset = sin(animatableData * .pi * 4) * 6
        return ProjectionTransform(CGAffineTransform(translationX: offset, y: 0))
    }
}

// MARK: - Keyboard Help View

struct KeyboardHelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Keyboard Shortcuts")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.escape)
            }

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                shortcutSection("Navigation", shortcuts: [
                    ("j", "Move down"),
                    ("k", "Move up"),
                ])

                shortcutSection("Escalations", shortcuts: [
                    ("1-4", "Select option"),
                ])

                shortcutSection("Suggestions", shortcuts: [
                    ("↩", "Accept suggestion"),
                    ("⎋", "Dismiss suggestion"),
                ])

                shortcutSection("App", shortcuts: [
                    ("⌘R", "Refresh"),
                    ("⌘/", "Show this help"),
                ])
            }

            Spacer()
        }
        .padding()
        .frame(width: 350, height: 400)
    }

    private func shortcutSection(_ title: String, shortcuts: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)

            ForEach(shortcuts, id: \.0) { key, action in
                HStack {
                    Text(key)
                        .font(.system(.body, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.2))
                        .cornerRadius(4)
                        .frame(width: 60, alignment: .center)

                    Text(action)
                        .foregroundStyle(.primary)

                    Spacer()
                }
            }
        }
    }
}

#Preview("Keyboard Help") {
    KeyboardHelpView()
}

