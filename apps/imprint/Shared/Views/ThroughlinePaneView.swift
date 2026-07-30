//
//  ThroughlinePaneView.swift
//  imprint
//
//  The throughline pane (ADR-0016): the manuscript's narrative spine with
//  per-paragraph anchor badges, an anchor editor, and a coverage footer.
//
//  Opt-in (ADR-0016 D1): this view is only mounted when the user toggles
//  the pane. For documents without a throughline it shows a single create
//  affordance and nothing else — no state, no store traffic.
//
//  Staleness is a visible state, not an error (ADR-0016 D5): badges inform,
//  they never nag and never auto-fix.
//
//  ## CROSS-PLATFORM since C1 (2026-07-30) — moved out of `macOS/Views/`
//
//  The throughline was macOS-only for a structural reason that had already been
//  removed: `ThroughlineCoordinator` and `ThroughlineModel` were de-gated in
//  wave 2 (the gate there was around the store WRITER, "pure inertia", and it
//  made the mirror silently no-op on iOS) and both files have been compiled into
//  the `imprint-iOS` target ever since. Only this VIEW stayed behind, in a
//  macOS-target directory, so iPad had the whole engine and no way to look at
//  it — an original user-reported gap.
//
//  Nothing in the body was AppKit-adjacent. The port is ONE island
//  (`BorderlessButtonMenuStyle` is macOS-only) plus one adaptation: `.help(_:)`
//  compiles on iOS but only reaches VoiceOver, and the badge legend is where
//  this pane keeps its meaning — so on iOS every badge also answers a LONG
//  PRESS with the same sentence, the established substitute for hover
//  (`CitationPaperSheet`, `IOSSourceEditorView.onCiteKeyLongPress`). This is a
//  relocation, not a redesign: no copy changed, no interaction was dropped.
//
//  The two hosts differ only in how they mount it:
//    * macOS — `ThroughlineSidePanel` in `ManuscriptSidePanels`, a column of the
//      Source tab's `HSplitView` (`ManuscriptSidePanel` is itself macOS-only;
//      the seam does not exist on iOS).
//    * iOS — a toolbar button in `IOSContentView` raising it as a sheet with
//      medium/large detents. A phone has no room for an inspector COLUMN, and a
//      third pane state would have to fight the two-state Source/Preview swipe
//      and its persisted `@AppStorage` choice.
//

import SwiftUI
import ImpressLogging

struct ThroughlinePaneView: View {
    @Binding var document: ImprintDocument
    var onNavigateToSection: ((String) -> Void)? = nil

    /// Bumped to re-derive anchor states after edits.
    @State private var derivationTick = 0
    @State private var editingSource = false
    @State private var confirmingRemoval = false

    var body: some View {
        Group {
            if document.hasThroughline {
                paneContent
            } else {
                createAffordance
            }
        }
        // Column sizing for the macOS inspector. On iOS the pane is a sheet and
        // sizes itself from the detent, so a 480 pt cap would only narrow it on
        // iPad.
        .throughlinePaneWidth()
        .accessibilityIdentifier("throughline.pane")
    }

    // MARK: - Create (explicit opt-in)

    private var createAffordance: some View {
        VStack(spacing: 12) {
            Image(systemName: "point.bottomleft.forward.to.point.topright.scurvepath")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("No throughline yet")
                .font(.headline)
            Text("A throughline is the paper's story — a short narrative kept in sync with the manuscript by agents, under your review.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Create Throughline") {
                ThroughlineCoordinator.create(in: &document)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("throughline.create")
        }
        .padding(20)
        .frame(maxHeight: .infinity)
    }

    // MARK: - Pane

    private var paneContent: some View {
        VStack(spacing: 0) {
            header
            Divider()
            proposalsSection
            if editingSource {
                sourceEditor
            } else {
                paragraphList
            }
            Divider()
            coverageFooter
        }
    }

    // MARK: - Sync proposals (Accept ⏎ / Discard — never auto-applied)

    private var proposals: [ThroughlineCoordinator.SyncProposal] {
        _ = derivationTick
        return ThroughlineCoordinator.pendingProposals(documentID: document.id)
    }

    @ViewBuilder
    private var proposalsSection: some View {
        let pending = proposals
        if !pending.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label(
                    "\(pending.count) sync proposal\(pending.count == 1 ? "" : "s") awaiting review",
                    systemImage: "tray.full")
                    .font(.caption.bold())
                ForEach(pending) { proposal in
                    proposalCard(proposal)
                }
            }
            .padding(10)
            .background(Color.accentColor.opacity(0.06))
            .accessibilityIdentifier("throughline.proposals")
            Divider()
        }
    }

    @ViewBuilder
    private func proposalCard(_ proposal: ThroughlineCoordinator.SyncProposal) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                stateBadge(proposal.direction)
                Text("<\(proposal.anchor)>")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
            }
            Text(proposal.question)
                .font(.callout)
            if let note = proposal.note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let proposed = proposal.proposedParagraph {
                Text(proposed)
                    .font(.callout)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.green.opacity(0.08)))
                    .textSelection(.enabled)
            }
            HStack {
                Button("Accept") {
                    ThroughlineCoordinator.resolveProposal(id: proposal.id, approved: true)
                    derivationTick += 1
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .keyboardShortcut(.return, modifiers: [])
                .help("Approve — the sync agent applies it and rebaselines the ledger")

                Button("Discard") {
                    ThroughlineCoordinator.resolveProposal(id: proposal.id, approved: false)
                    derivationTick += 1
                }
                .controlSize(.small)
                .keyboardShortcut(.escape, modifiers: [])
                .help("Reject — the anchor stays visibly stale; nothing changes")
                Spacer()
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.05)))
    }

    private var header: some View {
        HStack {
            Label("Throughline", systemImage: "point.bottomleft.forward.to.point.topright.scurvepath")
                .font(.headline)
            Spacer()
            Picker("", selection: $editingSource) {
                Text("Story").tag(false)
                Text("Edit").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 110)
            .help("Story shows paragraphs with sync badges; Edit is the raw Typst source")
            .accessibilityIdentifier("throughline.modePicker")

            Menu {
                Button("Remove Throughline…", role: .destructive) {
                    confirmingRemoval = true
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .throughlineMenuChrome(width: 26)
            .accessibilityIdentifier("throughline.overflow")
        }
        .confirmationDialog(
            "Remove this document's throughline?",
            isPresented: $confirmingRemoval
        ) {
            Button("Remove Throughline", role: .destructive) {
                ThroughlineCoordinator.remove(from: &document)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The sidecar files are removed on next save. Anchors and the sync ledger are deleted; the manuscript itself is untouched.")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var sourceEditor: some View {
        TextEditor(
            text: Binding(
                get: { document.throughlineSource ?? "" },
                set: { newValue in
                    document.throughlineSource = newValue
                    // The ledger is deliberately untouched — edited
                    // paragraphs surface as throughline-ahead (D5/D6).
                    // Mirroring is debounced: one store write per typing
                    // pause, throughline row only (never the sections).
                    ThroughlineCoordinator.scheduleThroughlineMirror(document: document)
                    derivationTick += 1
                }
            )
        )
        .font(.system(.body, design: .monospaced))
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier("throughline.sourceEditor")
    }

    // MARK: - Paragraphs

    private var paragraphs: [TLParagraph] {
        _ = derivationTick
        guard let source = document.throughlineSource else { return [] }
        return ThroughlineText.extractParagraphs(source)
    }

    private var assessments: [String: ThroughlineAnchorAssessment] {
        _ = derivationTick
        return Dictionary(
            ThroughlineCoordinator.anchorStates(of: document).map { ($0.label, $0) },
            uniquingKeysWith: { first, _ in first })
    }

    private var paragraphList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(paragraphs, id: \.label) { paragraph in
                    paragraphRow(paragraph)
                }
                if paragraphs.isEmpty {
                    Text("No labeled paragraphs. Add a paragraph ending in a <tl-…> label in Edit mode.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding()
                }
            }
            .padding(10)
        }
        .accessibilityIdentifier("throughline.paragraphs")
    }

    @ViewBuilder
    private func paragraphRow(_ paragraph: TLParagraph) -> some View {
        let assessment = assessments[paragraph.label]
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                stateBadge(assessment?.state ?? "unanchored")
                Text("<\(paragraph.label)>")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    // The ROW's identifier lives on this label, not on the row
                    // container: an identifier applied to a container REPLACES
                    // its children's (the same inheritance imprint's list rows
                    // rely on), which swallowed the badge and the anchor menu —
                    // the two elements a test most needs to address.
                    .accessibilityIdentifier("throughline.paragraph.\(paragraph.label)")
                Spacer()
                anchorMenu(for: paragraph)
            }
            Text(paragraph.body)
                .font(.callout)
                .textSelection(.enabled)
            if let assessment, !assessment.manuscriptAhead.isEmpty || !assessment.broken.isEmpty {
                HStack(spacing: 4) {
                    ForEach(assessment.manuscriptAhead, id: \.self) { key in
                        sectionChip(key, broken: false)
                    }
                    ForEach(assessment.broken, id: \.self) { key in
                        sectionChip(key, broken: true)
                    }
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.06)))
    }

    private func sectionChip(_ key: String, broken: Bool) -> some View {
        Button {
            onNavigateToSection?(key)
        } label: {
            Label(key, systemImage: broken ? "link.badge.plus" : "arrow.up.right")
                .font(.caption2)
                .foregroundStyle(broken ? Color.red : Color.orange)
        }
        .buttonStyle(.plain)
        .help(broken ? "Anchored section no longer resolves" : "Section changed since last sync")
        .accessibilityIdentifier("throughline.chip.\(key)")
    }

    @ViewBuilder
    private func stateBadge(_ state: String) -> some View {
        let (symbol, color, help): (String, Color, String) = {
            switch state {
            case "synced":
                return ("checkmark.circle.fill", .green, "In sync with anchored sections")
            case "manuscript-ahead":
                return ("arrow.down.circle.fill", .orange, "Anchored manuscript content changed — an update to this paragraph is owed")
            case "throughline-ahead":
                return ("arrow.up.circle.fill", .blue, "Paragraph edited — a manuscript draft is owed")
            case "manuscript-ahead+throughline-ahead":
                return ("arrow.up.arrow.down.circle.fill", .purple, "Both sides changed since the last sync")
            case "broken":
                return ("exclamationmark.triangle.fill", .red, "An anchor no longer resolves (heading renamed or removed?)")
            default:
                return ("circle.dotted", .secondary, "Not anchored to any section yet")
            }
        }()
        Image(systemName: symbol)
            .foregroundStyle(color)
            .help(help)
            .accessibilityLabel(state)
            .accessibilityIdentifier("throughline.badge.\(state)")
            // The hover adaptation: on macOS `.help` above is a tooltip; on iOS
            // it reaches VoiceOver only, and a badge whose meaning is invisible
            // is the one thing this pane cannot afford. Long press answers with
            // the same sentence — the gesture imprint-iOS already uses in place
            // of hover for cite keys.
            .throughlineLongPressLegend(state: state, help: help)
    }

    // MARK: - Anchor editing

    private func anchorMenu(for paragraph: TLParagraph) -> some View {
        let map = ThroughlineCoordinator.anchorMap(of: document)
        let anchored = Set(map.anchors[paragraph.label]?.sectionKeys ?? [])
        let sections = ThroughlineCoordinator.extractSections(of: document)
        return Menu {
            if sections.isEmpty {
                Text("No sections in manuscript")
            }
            ForEach(sections, id: \.key) { section in
                Button {
                    var keys = map.anchors[paragraph.label]?.sectionKeys ?? []
                    if anchored.contains(section.key) {
                        keys.removeAll { $0 == section.key }
                    } else {
                        keys.append(section.key)
                    }
                    ThroughlineCoordinator.setAnchor(
                        in: &document, label: paragraph.label, sectionKeys: keys)
                    derivationTick += 1
                } label: {
                    if anchored.contains(section.key) {
                        Label(section.title, systemImage: "checkmark")
                    } else {
                        Text(section.title)
                    }
                }
            }
        } label: {
            Image(systemName: "link")
                .font(.caption)
        }
        .throughlineMenuChrome(width: 30)
        .help("Anchor this paragraph to manuscript sections (baselines the sync ledger)")
        .accessibilityIdentifier("throughline.anchorMenu.\(paragraph.label)")
    }

    // MARK: - Coverage (ADR-0016 D7: a query, not a nag)

    private var coverageFooter: some View {
        let uncovered = ThroughlineCoordinator.coverage(of: document)
        return Group {
            if uncovered.isEmpty {
                Text("All sections are narrated or marked supporting.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Not in the story: \(uncovered.count) section\(uncovered.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(uncovered, id: \.self) { key in
                                Menu(key) {
                                    Button("Mark as supporting detail") {
                                        ThroughlineCoordinator.markSupporting(
                                            in: &document, sectionKey: key, supporting: true)
                                        derivationTick += 1
                                    }
                                }
                                .throughlineMenuChrome()
                                .font(.caption2)
                                .fixedSize()
                                .accessibilityIdentifier("throughline.uncovered.\(key)")
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("throughline.coverage")
    }
}

// MARK: - Platform islands
//
// Three modifiers, each an `#if` island rather than a second copy of the pane.

private extension View {

    /// macOS's borderless menu chrome. `BorderlessButtonMenuStyle` does not
    /// exist on iOS, and the platform's own menu-from-a-glyph rendering is
    /// already borderless — so iOS simply keeps the default, and the fixed
    /// width (a pointer-hit-target size) goes with it.
    @ViewBuilder
    func throughlineMenuChrome(width: CGFloat? = nil) -> some View {
        #if os(macOS)
        if let width {
            self.menuStyle(.borderlessButton).frame(width: width)
        } else {
            self.menuStyle(.borderlessButton)
        }
        #else
        self
        #endif
    }

    /// The inspector COLUMN's width, which only the macOS host has.
    @ViewBuilder
    func throughlinePaneWidth() -> some View {
        #if os(macOS)
        self.frame(minWidth: 260, idealWidth: 340, maxWidth: 480)
        #else
        self
        #endif
    }

    /// iOS: long press a badge to read what it means. macOS already answers
    /// that on hover (`.help`), so it adds nothing there.
    @ViewBuilder
    func throughlineLongPressLegend(state: String, help: String) -> some View {
        #if os(iOS)
        self.contextMenu {
            Text(state)
            Text(help)
        }
        #else
        self
        #endif
    }
}
