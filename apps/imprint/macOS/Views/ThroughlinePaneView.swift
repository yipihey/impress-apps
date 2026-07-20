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

#if os(macOS)
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
        .frame(minWidth: 260, idealWidth: 340, maxWidth: 480)
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

            Menu {
                Button("Remove Throughline…", role: .destructive) {
                    confirmingRemoval = true
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 26)
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
        .menuStyle(.borderlessButton)
        .frame(width: 30)
        .help("Anchor this paragraph to manuscript sections (baselines the sync ledger)")
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
                                .menuStyle(.borderlessButton)
                                .font(.caption2)
                                .fixedSize()
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif // os(macOS)
