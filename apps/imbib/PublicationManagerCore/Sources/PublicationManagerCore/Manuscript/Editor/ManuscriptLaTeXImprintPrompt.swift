#if os(macOS)
//
//  ManuscriptLaTeXImprintPrompt.swift
//  PublicationManagerCore
//
//  Shown in place of the compiled preview when a LaTeX manuscript is opened in
//  a host without a TeX engine (imbib). Instead of a failed-compile banner, it
//  explains the split — imbib previews Typst in-app, imprint compiles LaTeX —
//  and hands the manuscript off to imprint (same shared-store document) with
//  one click.
//

import SwiftUI

struct ManuscriptLaTeXImprintPrompt: View {
    let session: ManuscriptEditorSession

    @State private var isOpening = false
    @State private var failed = false

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.badge.gearshape")
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            Text("LaTeX compiles in imprint")
                .font(.headline)
            Text("imbib previews Typst in-app. Open this manuscript in imprint "
                + "to compile LaTeX — it edits the same document.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Button(action: open) {
                Label("Open in imprint", systemImage: "arrow.up.forward.app")
            }
            .buttonStyle(.borderedProminent)
            .disabled(isOpening)
            if failed {
                Text("Couldn't open imprint. Is it installed?")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func open() {
        isOpening = true
        let opened = ManuscriptImprintHandoff.open(manuscriptID: session.manuscriptID)
        isOpening = false
        failed = !opened
    }
}
#endif
