//
//  ManuscriptSidePanels.swift
//  imprint
//
//  Panels Phase A/B/C: imprint's flanking inspector panels contributed into the
//  shared PMC Source tab via `ManuscriptEditorEnvironment.sidePanels`. Each
//  conforms to PMC's `ManuscriptSidePanel` and builds its view from the
//  `ManuscriptPanelContext` (or, for document-coupled panels, from a
//  `PanelManuscriptBridge`). imbib installs none → no inspector.
//

#if os(macOS)
import AppKit
import SwiftUI
import PublicationManagerCore
import ImpressPublicationUI
import ImpressKit
import ImprintCore
import ImpressLogging

// MARK: - Throughline (hard — needs an ImprintDocument bridge)

struct ThroughlineSidePanel: ManuscriptSidePanel {
    let id = "throughline"
    let label = "Throughline"
    let systemImage = "text.line.first.and.arrowtriangle.forward"

    func makeView(_ context: ManuscriptPanelContext) -> AnyView {
        AnyView(ThroughlinePanelHost(context: context))
    }
}

/// Hosts `ThroughlinePaneView`, which binds `$document: ImprintDocument`.
/// A per-manuscript `PanelManuscriptBridge` supplies that document from the
/// store and keeps its `source` synced with the live editor. Navigation
/// resolves the section slug to a caret offset (mirrors ContentView).
private struct ThroughlinePanelHost: View {
    let context: ManuscriptPanelContext
    @State private var bridge: PanelManuscriptBridge

    init(context: ManuscriptPanelContext) {
        self.context = context
        _bridge = State(initialValue: PanelBridgeRegistry.shared.bridge(for: context.manuscriptID))
    }

    var body: some View {
        ThroughlinePaneView(
            document: Binding(get: { bridge.doc }, set: { bridge.doc = $0 }),
            onNavigateToSection: { slug in navigate(to: slug) }
        )
        .onAppear { bridge.syncSource(context.source.wrappedValue) }
        .onChange(of: context.source.wrappedValue) { _, latest in bridge.syncSource(latest) }
    }

    private func navigate(to slug: String) {
        for section in ThroughlineCoordinator.extractSections(of: bridge.doc)
        where section.key == slug {
            let src = bridge.doc.source
            if let range = src.range(of: "= \(section.title)") ?? src.range(of: section.title) {
                context.jumpToChar(src.distance(from: src.startIndex, to: range.lowerBound))
            }
            return
        }
    }
}

// MARK: - Presentation storyboard

struct PresentationStoryboardSidePanel: ManuscriptSidePanel {
    let id = "storyboard"
    let label = "Storyboard"
    let systemImage = "rectangle.grid.1x2"

    func makeView(_ context: ManuscriptPanelContext) -> AnyView {
        AnyView(PresentationStoryboardPanel(context: context))
    }
}

/// Graphical slide order over the live Typst buffer. Each card is backed by a
/// stable `#slide(id:, beat:)[…]` block; drops call the Rust structural editor
/// and assign the slide to the destination throughline beat in one source edit.
private struct PresentationStoryboardPanel: View {
    let context: ManuscriptPanelContext
    @State private var bridge: PanelManuscriptBridge
    @State private var selectedSlideID: String?
    @State private var mutationError: String?

    init(context: ManuscriptPanelContext) {
        self.context = context
        _bridge = State(initialValue: PanelBridgeRegistry.shared.bridge(for: context.manuscriptID))
    }

    private var outline: FfiPresentationOutline {
        extractPresentationSlides(source: context.source.wrappedValue)
    }

    private var slides: [FfiPresentationSlide] { outline.slides }

    private var paragraphs: [TLParagraph] {
        ThroughlineText.extractParagraphs(bridge.doc.throughlineSource ?? "")
    }

    private var assessments: [String: ThroughlineAnchorAssessment] {
        Dictionary(
            uniqueKeysWithValues: ThroughlineCoordinator.anchorStates(of: bridge.doc)
                .map { ($0.label, $0) })
    }

    private var groups: [StoryboardBeatGroup] {
        let knownLabels = Set(paragraphs.map(\.label))
        var result = paragraphs.map { paragraph in
            StoryboardBeatGroup(
                id: paragraph.label,
                title: paragraph.body,
                slides: slides.filter { $0.beat == paragraph.label },
                isKnownBeat: true)
        }
        let unknownLabels = Set(slides.compactMap(\.beat)).subtracting(knownLabels).sorted()
        result.append(contentsOf: unknownLabels.map { label in
            StoryboardBeatGroup(
                id: label,
                title: "Unknown throughline beat",
                slides: slides.filter { $0.beat == label },
                isKnownBeat: false)
        })
        let unassigned = slides.filter { $0.beat == nil }
        if !unassigned.isEmpty || result.isEmpty {
            result.append(
                StoryboardBeatGroup(
                    id: StoryboardBeatGroup.unassignedID,
                    title: bridge.doc.hasThroughline
                        ? "Title, transition, backup, or unassigned slides"
                        : "Create a throughline to organize slides by story beat",
                    slides: unassigned,
                    isKnownBeat: false))
        }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if context.format != .typst {
                unavailable
            } else if let error = outline.error {
                diagnostic(error)
            } else if slides.isEmpty {
                emptyState
            } else {
                storyboard
            }
        }
        .onAppear { bridge.syncSource(context.source.wrappedValue) }
        .onChange(of: context.source.wrappedValue) { _, latest in
            bridge.syncSource(latest)
            logInfo(
                "Storyboard display: \(extractPresentationSlides(source: latest).slides.count) slides",
                category: "presentation")
        }
        .accessibilityIdentifier("presentation.storyboard")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label("Storyboard", systemImage: "rectangle.grid.1x2")
                .font(.headline)
            Spacer()
            Text("\(slides.count) slides")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var storyboard: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if context.svgPages.count != slides.count {
                    Label(
                        "Compiled pages do not yet match slide blocks; thumbnails will catch up after compile.",
                        systemImage: "clock.arrow.circlepath")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let mutationError {
                    diagnostic(mutationError)
                }
                ForEach(groups) { group in
                    beatSection(group)
                }
            }
            .padding(10)
        }
    }

    private func beatSection(_ group: StoryboardBeatGroup) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            beatHeader(group)
                .contentShape(.rect)
                .draggable("beat:\(group.id)")
                .dropDestination(for: String.self) { items, _ in
                    guard let moving = items.first else { return false }
                    if moving.hasPrefix("beat:") {
                        return moveBeat(
                            String(moving.dropFirst("beat:".count)),
                            before: group.id)
                    }
                    return moveSlide(
                        moving,
                        before: group.slides.first?.id,
                        intoBeat: group.assignableBeat)
                }
            if group.slides.isEmpty {
                Text("Drop a slide here")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 6))
            } else {
                ForEach(group.slides, id: \.id) { slide in
                    slideCard(slide, group: group)
                }
            }
        }
    }

    private func beatHeader(_ group: StoryboardBeatGroup) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            beatStateIcon(group.id)
            VStack(alignment: .leading, spacing: 1) {
                Text(group.displayLabel)
                    .font(.caption.monospaced().bold())
                Text(group.title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Text("\(group.slides.count)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }

    private func slideCard(
        _ slide: FfiPresentationSlide,
        group: StoryboardBeatGroup
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Button {
                selectedSlideID = slide.id
                context.jumpToChar(Int(slide.startUtf16))
            } label: {
                StoryboardThumbnail(
                    svg: context.svgPages.element(at: Int(slide.orderIndex)),
                    number: Int(slide.orderIndex) + 1)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(
                                selectedSlideID == slide.id ? Color.accentColor : .clear,
                                lineWidth: 2)
                    }
            }
            .buttonStyle(.plain)
            .draggable(slide.id)
            .dropDestination(for: String.self) { items, _ in
                guard let moving = items.first else { return false }
                return moveSlide(moving, before: slide.id, intoBeat: group.assignableBeat)
            }

            HStack(spacing: 5) {
                Text(slide.title ?? slide.id)
                    .font(.caption)
                    .lineLimit(1)
                Spacer()
                Button {
                    moveEarlier(slide.id)
                } label: {
                    Label("Move slide earlier", systemImage: "arrow.up")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .disabled(slide.orderIndex == 0)
                Button {
                    moveLater(slide.id)
                } label: {
                    Label("Move slide later", systemImage: "arrow.down")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .disabled(Int(slide.orderIndex) + 1 >= slides.count)
            }
        }
        .padding(7)
        .background(.secondary.opacity(0.06), in: .rect(cornerRadius: 8))
        .accessibilityIdentifier("presentation.slide.\(slide.id)")
    }

    @ViewBuilder
    private func beatStateIcon(_ label: String) -> some View {
        if let assessment = assessments[label] {
            Image(systemName: assessment.orderAhead
                ? "arrow.up.arrow.down.circle.fill"
                : assessment.state == "synced" ? "checkmark.circle.fill" : "circle.dotted")
                .foregroundStyle(assessment.orderAhead ? .blue : assessment.state == "synced" ? .green : .secondary)
                .help(assessment.orderAhead
                    ? "Narrative order changed; manuscript sync review is owed"
                    : assessment.state)
        } else {
            Image(systemName: "circle.dotted").foregroundStyle(.secondary)
        }
    }

    private func moveEarlier(_ id: String) {
        guard let index = slides.firstIndex(where: { $0.id == id }), index > 0 else { return }
        let target = slides[index - 1]
        _ = moveSlide(id, before: target.id, intoBeat: target.beat)
    }

    private func moveLater(_ id: String) {
        guard let index = slides.firstIndex(where: { $0.id == id }), index + 1 < slides.count else {
            return
        }
        let nextIndex = index + 2
        let before = nextIndex < slides.count ? slides[nextIndex].id : nil
        let destinationBeat = slides[index + 1].beat
        _ = moveSlide(id, before: before, intoBeat: destinationBeat)
    }

    @discardableResult
    private func moveBeat(_ label: String, before targetLabel: String) -> Bool {
        guard label != targetLabel,
              let movingGroup = groups.first(where: { $0.id == label }),
              let targetIndex = groups.firstIndex(where: { $0.id == targetLabel }) else {
            return false
        }
        let targetSlideID = groups[targetIndex...]
            .lazy.flatMap(\.slides).first?.id
        guard ThroughlineCoordinator.reorderParagraph(
            in: &bridge.doc, label: label, beforeLabel: targetLabel) else {
            return false
        }

        var working = context.source.wrappedValue
        for slide in movingGroup.slides {
            let mutation = reorderPresentationSlide(
                source: working, slideId: slide.id, beforeSlideId: targetSlideID)
            if let error = mutation.error {
                mutationError = error
                return false
            }
            working = mutation.source
        }
        if working != context.source.wrappedValue {
            context.source.wrappedValue = working
            logInfo(
                "Storyboard save: moved beat <\(label)> with \(movingGroup.slides.count) slides",
                category: "presentation")
        }
        mutationError = nil
        return true
    }

    @discardableResult
    private func moveSlide(_ id: String, before target: String?, intoBeat beat: String?) -> Bool {
        let original = context.source.wrappedValue
        logInfo(
            "Storyboard mutation: slide=\(id) before=\(target ?? "end") beat=\(beat ?? "unassigned")",
            category: "presentation")
        var working = original
        let assigned = setPresentationSlideBeat(source: working, slideId: id, beat: beat ?? "")
        if let error = assigned.error {
            mutationError = error
            logWarning("Storyboard save failed: \(error)", category: "presentation")
            return false
        }
        working = assigned.source
        let moved = reorderPresentationSlide(source: working, slideId: id, beforeSlideId: target)
        if let error = moved.error {
            mutationError = error
            logWarning("Storyboard save failed: \(error)", category: "presentation")
            return false
        }
        guard moved.source != original else { return false }
        context.source.wrappedValue = moved.source
        selectedSlideID = id
        mutationError = nil
        logInfo("Storyboard save: source buffer updated", category: "presentation")
        logInfo(
            "Storyboard display: \(extractPresentationSlides(source: moved.source).slides.count) slides",
            category: "presentation")
        return true
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.stack.badge.plus")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("No structural slides")
                .font(.headline)
            Text("Wrap each page in an explicit slide block so imprint can reorder source safely.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("#slide(id: \"motivation\", beat: \"tl-why\")[ … ]")
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var unavailable: some View {
        ContentUnavailableView(
            "Typst presentations only",
            systemImage: "rectangle.stack",
            description: Text("The storyboard edits explicit Typst slide blocks."))
    }

    private func diagnostic(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct StoryboardBeatGroup: Identifiable {
    static let unassignedID = "__unassigned__"
    let id: String
    let title: String
    let slides: [FfiPresentationSlide]
    let isKnownBeat: Bool

    var displayLabel: String { id == Self.unassignedID ? "Unassigned" : "<\(id)>" }
    var assignableBeat: String? { id == Self.unassignedID ? nil : id }
}

private struct StoryboardThumbnail: View {
    let svg: String?
    let number: Int
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color.white
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                VStack(spacing: 5) {
                    Image(systemName: "rectangle.on.rectangle")
                        .foregroundStyle(.tertiary)
                    Text("Slide \(number)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(.rect(cornerRadius: 6))
        .shadow(color: .black.opacity(0.14), radius: 2, y: 1)
        .task(id: svg) {
            image = svg
                .flatMap { $0.data(using: .utf8) }
                .flatMap(NSImage.init(data:))
        }
    }
}

private extension Array {
    func element(at index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - AI Assistant (easy — no ImprintDocument)

struct AIAssistantSidePanel: ManuscriptSidePanel {
    let id = "ai"
    let label = "AI Assistant"
    let systemImage = "sparkles"

    func makeView(_ context: ManuscriptPanelContext) -> AnyView {
        AnyView(AIAssistantPanelHost(context: context))
    }
}

/// Wraps `AIChatSidebar`, which needs a `@Binding` selectedText — seeded from
/// the context's current selection.
private struct AIAssistantPanelHost: View {
    let context: ManuscriptPanelContext
    @State private var selectedText: String

    init(context: ManuscriptPanelContext) {
        self.context = context
        _selectedText = State(initialValue: context.selectedText)
    }

    var body: some View {
        AIChatSidebar(
            selectedText: $selectedText,
            documentSource: context.source,
            onInsertText: context.insertAtCursor
        )
        // Keep the chat's "selected text" seed fresh as the editor selection
        // changes (the context is rebuilt on selection change).
        .onChange(of: context.selectedText) { _, new in selectedText = new }
    }
}

// MARK: - Veusz Plots (hardest — ImprintDocument plots round-trip)

struct VeuszSidePanel: ManuscriptSidePanel {
    let id = "veusz"
    let label = "Plots"
    let systemImage = "chart.xyaxis.line"

    func makeView(_ context: ManuscriptPanelContext) -> AnyView {
        AnyView(VeuszPanelHost(context: context))
    }
}

/// Hosts `VeuszPlotsPanel` bound to the per-manuscript bridge document. The
/// panel persists `.vsz` files to the working directory itself (via its own
/// `VeuszPlotStore`/`VeuszService`); plot insertion posts
/// `VeuszPlotInsertion.notificationName`, which we route to the chassis editor
/// through `ctx.insertAtCursor` (the legacy `VeuszWiringModifier` inserted into
/// the ImprintDocument instead).
private struct VeuszPanelHost: View {
    let context: ManuscriptPanelContext
    @State private var bridge: PanelManuscriptBridge

    init(context: ManuscriptPanelContext) {
        self.context = context
        _bridge = State(initialValue: PanelBridgeRegistry.shared.bridge(for: context.manuscriptID))
    }

    var body: some View {
        VeuszPlotsPanel(document: Binding(get: { bridge.doc }, set: { bridge.doc = $0 }))
            .onAppear { bridge.refreshPlots() }
            .onReceive(NotificationCenter.default.publisher(for: VeuszPlotInsertion.notificationName)) { note in
                guard let info = note.userInfo,
                      let snippet = info["snippet"] as? String else { return }
                if let target = info["documentID"] as? UUID, target != context.manuscriptID { return }
                context.insertAtCursor(snippet)
            }
    }
}

// MARK: - Paper preview (easiest — view already in a shared package)

struct PaperPreviewSidePanel: ManuscriptSidePanel {
    let id = "paper"
    let label = "Paper"
    let systemImage = "doc.text.magnifyingglass"

    func makeView(_ context: ManuscriptPanelContext) -> AnyView {
        AnyView(PaperPreviewPanelHost())
    }
}

/// Observes `.openPaperPanel` (posted by the editor's cite-key click/hover) and
/// renders `PaperDetailPanel` for that publication, or a placeholder.
private struct PaperPreviewPanelHost: View {
    @State private var publicationID: String?

    var body: some View {
        Group {
            if let publicationID {
                PaperDetailPanel(
                    publicationID: publicationID,
                    dataSource: ImprintPublicationService.shared,
                    onClose: { self.publicationID = nil },
                    onOpenInImbib: { citeKey in
                        if let url = ImpressURL.openPaper(citeKey: citeKey).url {
                            NSWorkspace.shared.open(url)
                        }
                    }
                )
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 28)).foregroundStyle(.tertiary)
                    Text("Click a citation to preview the paper")
                        .font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openPaperPanel)) { note in
            if let id = note.userInfo?["publicationID"] as? String {
                publicationID = id
            }
        }
    }
}
#endif
