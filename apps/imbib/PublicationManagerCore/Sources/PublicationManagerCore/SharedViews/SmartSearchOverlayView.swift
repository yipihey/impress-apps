//
//  SmartSearchOverlayView.swift
//  PublicationManagerCore
//
//  Spotlight-style overlay for the new Cmd+S Smart Search.
//  Replaces NLSearchOverlayView. Single text input, intelligent routing,
//  inline candidate list, explicit Add — no auto-import to Exploration.
//

import SwiftUI
import OSLog

#if os(macOS)

public struct SmartSearchOverlayView: View {

    @Binding var isPresented: Bool

    @Environment(SmartSearchService.self) private var service

    @State private var inputText: String = ""
    @State private var showHelp: Bool = false
    @FocusState private var isInputFocused: Bool

    public init(isPresented: Binding<Bool>) {
        self._isPresented = isPresented
    }

    public var body: some View {
        ZStack {
            Color.black.opacity(0.3)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            VStack(spacing: 0) {
                headerBar
                Divider()
                inputField
                if showHelp { helpView; Divider() }
                Divider()
                stateContent
                if hasCandidates { footerBar }
            }
            .frame(width: 640)
            .frame(maxHeight: 560)
            .fixedSize(horizontal: false, vertical: true)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
            .onKeyPress(.escape) {
                if showHelp { showHelp = false; return .handled }
                dismiss(); return .handled
            }
            .onKeyPress(.return) {
                if isInputFocused, !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    submit(); return .handled
                }
                if hasCandidates {
                    addSelected(); return .handled
                }
                return .ignored
            }
            .onKeyPress(.downArrow) {
                if hasCandidates { moveHighlight(by: 1); return .handled }
                return .ignored
            }
            .onKeyPress(.upArrow) {
                if hasCandidates { moveHighlight(by: -1); return .handled }
                return .ignored
            }
            .onKeyPress(.space) {
                if hasCandidates, isInputFocused == false {
                    toggleHighlighted(); return .handled
                }
                return .ignored
            }
        }
        .onAppear {
            if !service.lastInput.isEmpty {
                inputText = service.lastInput
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isInputFocused = true
            }
        }
        .onChange(of: inputText) { _, new in
            service.updateInput(new)
        }
        .onChange(of: service.state) { _, new in
            // Auto-dismiss after .added toast.
            if case .added = new {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    dismiss()
                }
            }
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var headerBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkle.magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.title3)
            Text("Smart Search").font(.headline)

            if let chip = classificationChip {
                Text(chip)
                    .font(.caption2)
                    .fontWeight(.medium)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.15))
                    .foregroundStyle(.primary.opacity(0.8))
                    .clipShape(Capsule())
            }

            Spacer()

            Button { showHelp.toggle() } label: {
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(showHelp ? .purple : .secondary)
            }
            .buttonStyle(.plain)
            .help("Smart Search help")

            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var classificationChip: String? {
        if case .classified(let intent) = service.state {
            return intent.label
        }
        return nil
    }

    // MARK: - Input

    @ViewBuilder
    private var inputField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)

            TextField(
                "DOI · arXiv id · pasted reference · au:Smith abs:dark · or just type what you remember",
                text: $inputText,
                axis: .vertical
            )
            .lineLimit(1...6)
            .textFieldStyle(.plain)
            .font(.title3)
            .focused($isInputFocused)
            .onSubmit { submit() }

            if isWorking {
                ProgressView().controlSize(.small)
            } else if !inputText.isEmpty {
                Button {
                    inputText = ""
                    service.reset()
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - State content

    @ViewBuilder
    private var stateContent: some View {
        switch service.state {
        case .idle:
            idleHints
        case .classified:
            EmptyView()
        case .parsing:
            spinnerView("Parsing reference…")
        case .rewriting:
            spinnerView("Building query…")
        case .resolving(let detail):
            spinnerView(detail)
        case .candidates(let list):
            candidatesList(list)
        case .batch(let blocks):
            batchList(blocks)
        case .empty(let reason):
            emptyView(reason)
        case .error(let msg):
            errorView(msg)
        case .adding(let count):
            spinnerView("Adding \(count) paper\(count == 1 ? "" : "s")…")
        case .added(let count):
            addedView(count)
        }
    }

    @ViewBuilder
    private func spinnerView(_ message: String) -> some View {
        VStack(spacing: 8) {
            ProgressView().controlSize(.regular)
            Text(message).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    @ViewBuilder
    private var idleHints: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Try:")
                .font(.caption)
                .foregroundStyle(.tertiary)
            FlowChips(items: [
                "Abel, T. et al. 2002, Science, 295, 93",
                "10.1126/science.295.5552.93",
                #"au:"Riess" abs:"dark energy" year:2020-2025"#,
                "first stars Abel science"
            ]) { example in
                inputText = example
                submit()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func candidatesList(_ list: [SmartSearchCandidate]) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(list) { c in
                    candidateRow(c, highlighted: service.highlightedCandidateID == c.id)
                        .background(
                            service.highlightedCandidateID == c.id
                                ? Color.accentColor.opacity(0.15)
                                : Color.clear
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            service.highlightedCandidateID = c.id
                            toggleSelected(c.id)
                        }
                    Divider()
                }
            }
        }
        .frame(maxHeight: 320)
    }

    @ViewBuilder
    private func candidateRow(_ c: SmartSearchCandidate, highlighted: Bool) -> some View {
        let isSelected = service.selectedCandidateIDs.contains(c.id)
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: c.alreadyInLibrary != nil
                  ? "books.vertical.fill"
                  : (isSelected ? "checkmark.square.fill" : "square"))
                .foregroundStyle(c.alreadyInLibrary != nil
                                 ? AnyShapeStyle(.secondary)
                                 : (isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary)))
                .frame(width: 18, height: 18)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(c.title)
                    .font(.callout)
                    .lineLimit(2)
                    .foregroundStyle(.primary)
                HStack(spacing: 6) {
                    if !c.authors.isEmpty {
                        Text(c.authors.prefix(3).joined(separator: ", ") + (c.authors.count > 3 ? " et al." : ""))
                            .lineLimit(1)
                    }
                    if let y = c.year {
                        Text("·").foregroundStyle(.tertiary)
                        Text(String(y))
                    }
                    if let v = c.venue, !v.isEmpty {
                        Text("·").foregroundStyle(.tertiary)
                        Text(v).lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    badge(c.sourceLabel)
                    if let conf = c.confidence {
                        confidenceBadge(conf)
                    }
                    if c.alreadyInLibrary != nil {
                        Text("In library")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15))
                            .clipShape(Capsule())
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Color.accentColor.opacity(0.12))
            .foregroundStyle(.primary.opacity(0.85))
            .clipShape(Capsule())
    }

    private func confidenceBadge(_ confidence: Double) -> some View {
        let pct = Int((confidence * 100).rounded())
        let color: Color = confidence >= 0.7 ? .green : (confidence >= 0.4 ? .orange : .secondary)
        return Text("\(pct)%")
            .font(.caption2)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    @ViewBuilder
    private func batchList(_ blocks: [SmartSearchBlock]) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(blocks) { block in
                    batchRow(block)
                    Divider()
                }
            }
        }
        .frame(maxHeight: 360)
    }

    @ViewBuilder
    private func batchRow(_ block: SmartSearchBlock) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(block.raw)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            switch block.status {
            case .pending:
                Text("Pending…").font(.caption2).foregroundStyle(.tertiary)
            case .parsing:
                HStack(spacing: 4) { ProgressView().controlSize(.mini); Text("Parsing…") }
                    .font(.caption2).foregroundStyle(.secondary)
            case .resolving:
                HStack(spacing: 4) { ProgressView().controlSize(.mini); Text("Resolving…") }
                    .font(.caption2).foregroundStyle(.secondary)
            case .resolved(let cand):
                candidateRow(cand, highlighted: false)
            case .candidates(let list):
                ForEach(list.prefix(3)) { c in
                    candidateRow(c, highlighted: false)
                        .background(
                            service.selectedBatchCandidates[block.id] == c.id
                                ? Color.accentColor.opacity(0.10)
                                : Color.clear
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            service.selectedBatchCandidates[block.id] = c.id
                        }
                }
            case .notFound(let reason):
                Text("Not found: \(reason)").font(.caption2).foregroundStyle(.orange)
            case .error(let msg):
                Text("Error: \(msg)").font(.caption2).foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func emptyView(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                Text("No matches").font(.callout).fontWeight(.medium)
            }
            Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            Button("Search as Free Text") {
                service.updateInput(inputText)
                service.submit()
            }
            .buttonStyle(.bordered).controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    @ViewBuilder
    private func errorView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Search failed").font(.callout).fontWeight(.medium)
            }
            Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            Button("Try Again") { submit() }
                .buttonStyle(.bordered).controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    @ViewBuilder
    private func addedView(_ count: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text("Added \(count) paper\(count == 1 ? "" : "s")")
                .font(.callout).fontWeight(.medium)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }

    // MARK: - Footer (Add bar)

    @ViewBuilder
    private var footerBar: some View {
        HStack(spacing: 8) {
            Text(footerCountText)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Add Selected") { addSelected() }
                .keyboardShortcut(.return, modifiers: [.command])
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(footerSelectedCount == 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private var footerCountText: String {
        let n = footerSelectedCount
        return "\(n) selected · ⏎ to add · Space to toggle · ↑↓ to move"
    }

    private var footerSelectedCount: Int {
        switch service.state {
        case .candidates(let list):
            return list.filter { service.selectedCandidateIDs.contains($0.id) && $0.alreadyInLibrary == nil }.count
        case .batch:
            return service.selectedBatchCandidates.count
        default:
            return 0
        }
    }

    // MARK: - Help

    @ViewBuilder
    private var helpView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Smart Search Help").font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.purple)
            Group {
                helpRow("paste a reference", #"Abel, T. et al. 2002, Science, 295, 93"#)
                helpRow("identifier (DOI/arXiv/bibcode)", "10.1126/science.295.5552.93")
                helpRow("ADS fielded query", #"au:"Riess" abs:"dark energy" year:2020-2025"#)
                helpRow("free text", "first stars Abel science")
                helpRow("paste a bibliography", "(blank-line, [n], or \\bibitem separated)")
            }
            HStack(spacing: 4) {
                Text("⏎").fontWeight(.medium); Text("submit / add")
                Text("·"); Text("Space").fontWeight(.medium); Text("toggle")
                Text("·"); Text("↑↓").fontWeight(.medium); Text("move")
                Text("·"); Text("Esc").fontWeight(.medium); Text("close")
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.tertiary)
        }
        .font(.system(size: 10, design: .monospaced))
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private func helpRow(_ kind: String, _ example: String) -> some View {
        HStack(alignment: .top) {
            Text(kind).foregroundStyle(.secondary).frame(width: 200, alignment: .leading)
            Text(example).foregroundStyle(.primary).lineLimit(1)
        }
    }

    // MARK: - Actions

    private func submit() {
        service.updateInput(inputText)
        service.submit()
    }

    private func addSelected() {
        // Default-select highlighted row if user hasn't picked anything.
        if case .candidates(let list) = service.state,
           service.selectedCandidateIDs.isEmpty,
           let h = service.highlightedCandidateID,
           list.contains(where: { $0.id == h }) {
            service.selectedCandidateIDs = [h]
        }
        service.addSelected()
    }

    private func dismiss() {
        service.cancel()
        isPresented = false
    }

    private func moveHighlight(by delta: Int) {
        guard case .candidates(let list) = service.state, !list.isEmpty else { return }
        guard let current = service.highlightedCandidateID,
              let idx = list.firstIndex(where: { $0.id == current }) else {
            service.highlightedCandidateID = list.first?.id
            return
        }
        let nextIdx = max(0, min(list.count - 1, idx + delta))
        service.highlightedCandidateID = list[nextIdx].id
    }

    private func toggleSelected(_ id: String) {
        if service.selectedCandidateIDs.contains(id) {
            service.selectedCandidateIDs.remove(id)
        } else {
            service.selectedCandidateIDs.insert(id)
        }
    }

    private func toggleHighlighted() {
        guard let id = service.highlightedCandidateID else { return }
        toggleSelected(id)
    }

    // MARK: - Helpers

    private var hasCandidates: Bool {
        switch service.state {
        case .candidates(let l) where !l.isEmpty: return true
        case .batch(let b) where !b.isEmpty: return true
        default: return false
        }
    }

    private var isWorking: Bool {
        switch service.state {
        case .parsing, .rewriting, .resolving, .adding: return true
        default: return false
        }
    }
}

// MARK: - Flow chip layout

private struct FlowChips: View {
    let items: [String]
    let action: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items, id: \.self) { item in
                Button {
                    action(item)
                } label: {
                    Text(item)
                        .font(.caption)
                        .lineLimit(1)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.10))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

#endif
