#if os(macOS)
// Chassis file — macOS-only in GUI-meld Phase 1 (iOS keeps IOSContentView).
//
//  ManuscriptSourceTab.swift
//  PublicationManagerCore
//
//  The Source tab (GUI-meld plan §4): imprint's editor stack hosted in the
//  chassis detail pane, bound to a ManuscriptEditorSession. Editor on the
//  left; an optional live compiled-PDF preview on the right (default on, ≈
//  imprint's old split-editor mode). A compile-status strip and a non-modal
//  conflict banner frame it. The session lives in the registry OUTSIDE the
//  view tree, so this view carries NO `.id()` and survives tab/selection
//  switches without losing the buffer, undo stack, or an in-flight compile.

import SwiftUI
import PDFKit
import ImpressSyntaxHighlight

public struct ManuscriptSourceTab: View {

    @State private var session: ManuscriptEditorSession
    @AppStorage("manuscript.sourceTab.showPreview") private var showPreview = true
    @AppStorage("manuscript.sourceTab.showOutline") private var showOutline = false

    public init(session: ManuscriptEditorSession) {
        _session = State(initialValue: session)
    }

    public var body: some View {
        VStack(spacing: 0) {
            if session.conflict != nil { conflictBanner }
            editorSplit
            compileStrip
        }
    }

    @ViewBuilder
    private var editorSplit: some View {
        HSplitView {
            if showOutline {
                ManuscriptOutlineRail(
                    source: session.source,
                    format: session.format,
                    onJump: { charOffset in session.cursorPosition = charOffset }
                )
                .frame(minWidth: 160, idealWidth: 200, maxWidth: 300)
            }
            editor
                .frame(minWidth: 320)
            if showPreview {
                previewPane
                    .frame(minWidth: 280)
            }
        }
    }

    private var editor: some View {
        SourceEditorView(
            source: $session.source,
            cursorPosition: $session.cursorPosition,
            syntaxMode: session.format
        )
    }

    // MARK: Preview

    @ViewBuilder
    private var previewPane: some View {
        if let data = session.vm.pdfData {
            ManuscriptPDFPreview(data: data)
        } else {
            VStack(spacing: 8) {
                if session.vm.isCompiling {
                    ProgressView()
                    Text("Compiling…").foregroundStyle(.secondary)
                } else {
                    Image(systemName: "doc")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text("No preview yet").foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Strips

    private var compileStrip: some View {
        HStack(spacing: 8) {
            if session.vm.isCompiling {
                ProgressView().controlSize(.small)
                Text("Compiling").foregroundStyle(.secondary)
            } else if let err = session.vm.compilationError, !err.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(err.components(separatedBy: .newlines).first ?? err)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            } else if session.vm.pdfData != nil {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Compiled").foregroundStyle(.secondary)
            }
            Spacer()
            Text(session.format.rawValue.capitalized)
                .font(.caption)
                .foregroundStyle(.tertiary)
            Toggle(isOn: $showOutline) {
                Image(systemName: "list.bullet.indent")
            }
            .toggleStyle(.button)
            .help("Toggle outline")
            Toggle(isOn: $showPreview) {
                Image(systemName: "sidebar.right")
            }
            .toggleStyle(.button)
            .help("Toggle preview")
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.bar)
    }

    private var conflictBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                .foregroundStyle(.orange)
            Text("This manuscript was edited elsewhere.")
                .fontWeight(.medium)
            Spacer()
            Button("Keep mine") { session.keepMine() }
            Button("Take theirs") { session.takeExternal() }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.15))
    }
}

/// A collapsible document outline for the Source tab (GUI-meld plan §4 —
/// "toggleable outline rail (jump-to-line)"). Sections come from
/// SectionExtractor; tapping one moves the editor caret to its start.
struct ManuscriptOutlineRail: View {
    let source: String
    let format: DocumentFormat
    let onJump: (Int) -> Void

    private var sections: [ExtractedSection] {
        SectionExtractor.extract(
            from: source,
            documentID: Self.stableDocID,
            format: format == .latex ? .latex : .typst
        )
    }

    // Outline doesn't persist section identity across manuscripts; a fixed
    // doc id keeps SectionExtractor's deterministic ids stable within a body.
    private static let stableDocID = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Outline")
                .font(.caption).foregroundStyle(.secondary).textCase(.uppercase)
                .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 4)
            Divider()
            if sections.isEmpty {
                Text("No sections")
                    .font(.callout).foregroundStyle(.tertiary)
                    .padding(10)
                Spacer()
            } else {
                List(sections, id: \.id) { section in
                    Button {
                        onJump(section.start)
                    } label: {
                        Text(section.title.isEmpty ? "(untitled)" : section.title)
                            .lineLimit(1)
                            .padding(.leading, CGFloat(max(0, section.level - 1)) * 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.sidebar)
            }
        }
        .background(.background)
    }
}

/// Minimal PDFKit preview for the compiled manuscript. Rebuilds its document
/// when the compiled bytes change; preserves scroll position otherwise.
struct ManuscriptPDFPreview: NSViewRepresentable {
    let data: Data

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = PDFDocument(data: data)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        // Only rebuild when the bytes actually changed (avoids scroll reset).
        if context.coordinator.lastData != data {
            view.document = PDFDocument(data: data)
            context.coordinator.lastData = data
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(lastData: data) }

    final class Coordinator {
        var lastData: Data
        init(lastData: Data) { self.lastData = lastData }
    }
}
#endif
