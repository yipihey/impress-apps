#if os(macOS)
// Chassis file — macOS-only in GUI-meld Phase 1 (iOS keeps IOSContentView).
//
//  MarkdownPreviewTab.swift
//  PublicationManagerCore
//
//  The Preview surface for `format: markdown` manuscripts (WS2): renders the
//  LIVE editor buffer with MarkdownUI — no compile step, no artifact. The
//  session is @Observable, so typing in the Source tab re-renders here
//  immediately (debounce is unnecessary at MarkdownUI render cost).
//

import MarkdownUI
import SwiftUI

struct MarkdownPreviewTab: View {
    let session: ManuscriptEditorSession

    var body: some View {
        ScrollView {
            Markdown(session.source)
                .markdownTheme(.gitHub)
                .textSelection(.enabled)
                .frame(maxWidth: 720, alignment: .leading)
                .padding(24)
                .frame(maxWidth: .infinity)
        }
        .background(Color(NSColor.textBackgroundColor))
    }
}
#endif
