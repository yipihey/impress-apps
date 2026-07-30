//
//  MarkdownPreviewTab.swift
//  PublicationManagerCore
//
//  THE markdown preview surface, for every platform: the Preview tab of a
//  `format: markdown` manuscript on macOS and the `.renderedMarkdown` case of
//  `IOSManuscriptPreviewView` on iOS both render through this one view.
//
//  It renders the LIVE editor buffer with MarkdownUI — no compile step, no
//  artifact — so it re-renders as the user types (debounce is unnecessary at
//  MarkdownUI render cost).
//
//  There used to be two of these: this file, `#if os(macOS)`-gated for a single
//  `Color(NSColor.textBackgroundColor)`, and `IOSMarkdownPreviewView`, a copy of
//  the same ScrollView/Markdown/theme stack differing only in that colour and
//  4pt of padding. The colour is now a shared `ImpressTheme` token, so the gate
//  — and the copy — are gone.
//
//  Note what is NOT here: `ManuscriptEditorSession`. The session is macOS-only,
//  so per the chassis rule (a macOS-only symbol means SPLIT the file, never
//  re-gate it) the session-taking entry point lives in the gated companion
//  `MarkdownPreviewTab+Session.swift`. That companion also owns the @Observable
//  observation boundary: it reads `session.source` in ITS body, so a keystroke
//  invalidates the preview rather than the whole Source tab.
//

import ImpressTheme
import MarkdownUI
import SwiftUI

public struct MarkdownSourcePreview: View {
    /// The live editor buffer. A plain value, not a session: this view renders
    /// what it is given and knows nothing about who observes what.
    let source: String

    public init(source: String) {
        self.source = source
    }

    public var body: some View {
        ScrollView {
            Markdown(source)
                .markdownTheme(.gitHub)
                .textSelection(.enabled)
                .frame(maxWidth: 720, alignment: .leading)
                .padding(24)
                .frame(maxWidth: .infinity)
        }
        .background(Color.platformTextBackground)
    }
}
