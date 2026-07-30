#if os(macOS)
//
//  MarkdownPreviewTab+Session.swift
//  PublicationManagerCore
//
//  The macOS half of the markdown preview split. `MarkdownPreviewTab.swift` is
//  the cross-platform renderer; this is the one thing that could not go in it:
//  an entry point taking a `ManuscriptEditorSession`, which is macOS-only.
//
//  It is not just a type adapter. Reading `session.source` HERE — inside this
//  view's body — is what keeps the @Observable dependency on the buffer scoped
//  to the preview. Passing `session.source` from the call sites instead would
//  register the read against `ManuscriptSourceTab`'s body, and every keystroke
//  would re-evaluate the whole Source tab, `SourceEditorView`'s
//  `updateNSView` included.
//

import SwiftUI

struct MarkdownPreviewTab: View {
    let session: ManuscriptEditorSession

    var body: some View {
        MarkdownSourcePreview(source: session.source)
    }
}
#endif
