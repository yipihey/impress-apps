//
//  ManuscriptEditorInstall.swift
//  imprint
//
//  GUI-meld Phase 3: the source editor stack moved into PMC and reaches back
//  into imprint's app-specific services (AI completion, AI author-tasks,
//  citation search, LaTeX completion, collaboration presence) through
//  `ManuscriptEditorEnvironment`. This file installs imprint's concrete
//  implementations into that environment once, at app launch, so the shared
//  editor behaves exactly as it did when it lived in the imprint target.
//
//  imbib installs nothing → the same editor runs with inert AI / no citation
//  search, which is the desired graceful degradation.
//

#if os(macOS)
import AppKit
import ImbibRustCore
import PublicationManagerCore

// Conform imprint's services to the PMC capability protocols. The method
// signatures already line up, so these are empty conformances.
extension InlineCompletionService: InlineCompletionProviding {}
extension ImprintPublicationService: ManuscriptCitationSearching {}

enum ManuscriptEditorInstaller {
    /// Install imprint's editor capabilities. Idempotent; call once at launch on
    /// the main actor, before any editor window is created.
    @MainActor
    static func install() {
        let env = ManuscriptEditorEnvironment.shared

        // Inline AI ghost-text completion.
        env.inlineCompletion = InlineCompletionService.shared

        // Citation palette + cite-key hover, backed by the imbib library.
        env.citationSearch = ImprintPublicationService.shared

        // Cite keys already used in the manuscript (palette ranking boost).
        env.citedKeys = { Set(BibliographyGenerator.shared.extractedCiteKeys) }

        // AI author-tasks: enablement + display metadata + run sink.
        env.isAITaskEnabled = { AITaskPreferences.isEnabled($0) }
        env.aiTaskMetadata = { id in
            guard let action = AIContextMenuService.shared.actions.first(where: { $0.id == id }) else {
                return nil
            }
            return (action.title, action.effectiveIcon)
        }
        env.onAITaskRequested = { actionId, range in
            NotificationCenter.default.post(
                name: .runInlineAITask,
                object: nil,
                userInfo: ["actionId": actionId, "range": NSValue(range: range)]
            )
        }

        // LaTeX word completion.
        env.latexCompletions = { prefix, source, offset in
            await LaTeXCompletionProvider.shared
                .completions(for: prefix, in: source, at: offset)
                .map(\.text)
        }

        // Real-time collaboration presence cursor.
        env.presenceCursorHook = { $0.updateCollaborationCursor() }
    }
}
#endif // os(macOS)
