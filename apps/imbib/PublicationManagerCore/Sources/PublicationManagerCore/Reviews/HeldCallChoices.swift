//
//  HeldCallChoices.swift
//  PublicationManagerCore
//
//  Approve a held call only in part (koine plan-koine-trust TR-D7): pick
//  which of its targets to approve, or run one of its alternative verbs
//  instead. Approve-all and reject stay with the row that hosts this view.
//
//  Shared by imbib's review queue and imprint's throughline held-call cards
//  (via imprint's PMC re-export file); each passes its own verbs FFI.
//

import SwiftUI
import ImpressFTUI
import ImpressLogging
import OSLog

public struct HeldCallChoices: View {
    let pendingCallID: String
    let targets: [ReviewCallTarget]
    let dispatch: HeldCallReview.Dispatch
    let compact: Bool
    let onActed: () -> Void

    /// Targets the person unticked; every target starts ticked.
    @State private var unticked: Set<String> = []
    /// What review-service_show says, once it answered.
    @State private var options: HeldCallOptions?
    @State private var busy = false
    @State private var errorMessage: String?

    public init(
        pendingCallID: String,
        targets: [ReviewCallTarget],
        dispatch: @escaping HeldCallReview.Dispatch,
        compact: Bool = false,
        onActed: @escaping () -> Void
    ) {
        self.pendingCallID = pendingCallID
        self.targets = targets
        self.dispatch = dispatch
        self.compact = compact
        self.onActed = onActed
    }

    /// The live targets when show answered some, else the review's snapshot.
    private var shownTargets: [ReviewCallTarget] {
        if let live = options?.targets, !live.isEmpty {
            // Keep the snapshot's titles where the live row has none.
            let titles = Dictionary(targets.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            return live.map { target in
                guard target.title?.isEmpty ?? true, let known = titles[target.id] else { return target }
                return ReviewCallTarget(
                    id: target.id, argument: target.argument ?? known.argument,
                    kind: target.kind ?? known.kind, title: known.title)
            }
        }
        return targets
    }

    private var selectedIDs: [String] {
        shownTargets.map(\.id).filter { !unticked.contains($0) }
    }

    /// A call that already moved (ran, rejected, expired) offers nothing.
    private var stillPending: Bool { options?.isPending ?? true }

    public var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 6) {
            if stillPending {
                if shownTargets.count > 1 {
                    targetPicker
                }
                if let alternatives = options?.alternatives, !alternatives.isEmpty {
                    alternativeButtons(alternatives)
                }
            }
            if let errorMessage {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    Button("OK") {
                        self.errorMessage = nil
                        onActed()
                    }
                    .controlSize(.mini)
                }
            }
        }
        .disabled(busy)
        .task(id: pendingCallID) { await loadOptions() }
    }

    // MARK: - Targets

    @ViewBuilder
    private var targetPicker: some View {
        let all = shownTargets
        let picked = selectedIDs.count
        VStack(alignment: .leading, spacing: 2) {
            if !compact {
                Text("Approve only some of these")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(all) { target in
                let on = !unticked.contains(target.id)
                Button {
                    if on { unticked.insert(target.id) } else { unticked.remove(target.id) }
                } label: {
                    Label(target.displayName, systemImage: on ? "checkmark.square.fill" : "square")
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.plain)
                .help(target.id)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
            Button {
                approve(only: selectedIDs, instead: nil)
            } label: {
                Label(
                    compact ? "Approve \(picked) of \(all.count)" : "Approve selected (\(picked) of \(all.count))",
                    systemImage: "checkmark.circle")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(picked == 0 || picked == all.count)
            .help("Run the held call on the ticked records only")
        }
    }

    // MARK: - Alternatives

    @ViewBuilder
    private func alternativeButtons(_ alternatives: [String]) -> some View {
        FlowLayout(spacing: 6) {
            ForEach(alternatives, id: \.self) { alternative in
                Button {
                    approve(only: nil, instead: alternative)
                } label: {
                    Text("\(HeldCallReview.displayName(ofVerb: alternative)) instead")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Run \(alternative) on the same arguments instead of the held call")
            }
        }
    }

    // MARK: - Verbs

    private func loadOptions() async {
        let id = pendingCallID
        do {
            options = try await HeldCallReview.show(pendingCallID: id, dispatch: dispatch)
        } catch {
            Logger.library.warningCapture(
                "Held call \(id) options unavailable: \(error.localizedDescription)",
                category: "reviews")
            // Approve-all still works through the review; say why partial
            // approval is missing rather than hiding it.
            if shownTargets.count > 1 {
                errorMessage = "Partial approval unavailable: \(error.localizedDescription)"
            }
        }
    }

    private func approve(only: [String]?, instead: String?) {
        // Capture before the async hop (never read @State in deferred work).
        let id = pendingCallID
        let dispatch = self.dispatch
        let onActed = self.onActed
        busy = true
        errorMessage = nil
        Logger.library.infoCapture(
            "Held call \(id) approve only=\(only?.count ?? -1) instead=\(instead ?? "-")",
            category: "reviews")
        Task { @MainActor in
            do {
                try await HeldCallReview.approve(
                    pendingCallID: id, only: only, instead: instead, dispatch: dispatch)
                busy = false
                onActed()
            } catch {
                Logger.library.errorCapture(
                    "Held call \(id) approval failed: \(error.localizedDescription)",
                    category: "reviews")
                busy = false
                errorMessage = error.localizedDescription
            }
        }
    }
}
