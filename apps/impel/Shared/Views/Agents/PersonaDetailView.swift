//
//  PersonaDetailView.swift
//  impel
//
//  Persona detail (counsel model/prompt editors + request activity).
//  Moved verbatim from ContentView.swift (C0 mechanical decomposition,
//  Stage 2-C of the GUI unification) — no renames, no signature changes.
//

import SwiftUI
import ImpelCore
import ImpelMail
import CounselEngine
import ImpressKeyboard
import ImpressKit

// MARK: - Persona Detail View

struct PersonaDetailView: View {
    let persona: Persona
    @EnvironmentObject var mailGateway: MailGatewayState
    @AppStorage("counselSystemPrompt") private var counselSystemPrompt = ""
    @AppStorage("counselModel") private var counselModelRaw = CounselDefaults.defaultModel
    @State private var editedPrompt = ""
    @State private var hasLoaded = false
    @State private var expandedThreadID: String?
    @State private var showAllRequests = false

    private var isCounsel: Bool { persona.id == "counsel" }

    private var selectedModelDescription: String {
        CounselModel(rawValue: counselModelRaw)?.description ?? ""
    }

    /// The effective prompt: for counsel, use the persisted value; for others, show the persona's built-in prompt.
    private var effectivePrompt: String {
        if isCounsel {
            return counselSystemPrompt.isEmpty ? CounselDefaults.systemPrompt : counselSystemPrompt
        }
        return persona.systemPrompt
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                HStack(spacing: 12) {
                    Image(systemName: persona.systemImage)
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                        .frame(width: 48, height: 48)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(.rect(cornerRadius: 10))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(persona.name)
                            .font(.title2)
                            .fontWeight(.semibold)

                        Text(persona.roleDescription)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if persona.builtin {
                        Text("Built-in")
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.blue.opacity(0.15))
                            .foregroundStyle(.blue)
                            .clipShape(.rect(cornerRadius: 4))
                    }
                }

                Divider()

                // Metadata
                HStack(spacing: 24) {
                    metadataItem("Archetype", value: persona.archetype.displayName)
                    metadataItem("Working Style", value: persona.behavior.workingStyle.displayName)

                    if !isCounsel {
                        metadataItem("Model", value: persona.model.model)
                    }
                }

                // Model picker for counsel
                if isCounsel {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Model")
                            .font(.headline)

                        Picker("Model", selection: $counselModelRaw) {
                            ForEach(CounselModel.allCases) { model in
                                VStack(alignment: .leading) {
                                    Text(model.displayName)
                                }
                                .tag(model.rawValue)
                            }
                        }
                        .pickerStyle(.radioGroup)

                        Text(selectedModelDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                // System Prompt
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("System Prompt")
                            .font(.headline)

                        Spacer()

                        if isCounsel && editedPrompt != CounselDefaults.systemPrompt {
                            Button("Reset to Default") {
                                editedPrompt = CounselDefaults.systemPrompt
                                counselSystemPrompt = ""
                            }
                            .controlSize(.small)
                        }
                    }

                    if isCounsel {
                        TextEditor(text: $editedPrompt)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 200)
                            .padding(8)
                            .background(Color.secondary.opacity(0.06))
                            .clipShape(.rect(cornerRadius: 8))
                            .onChange(of: editedPrompt) { _, newValue in
                                if newValue == CounselDefaults.systemPrompt {
                                    counselSystemPrompt = ""
                                } else {
                                    counselSystemPrompt = newValue
                                }
                            }
                    } else {
                        Text(persona.systemPrompt)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.secondary.opacity(0.06))
                            .clipShape(.rect(cornerRadius: 8))
                    }
                }

                // Domain
                if !persona.domain.primaryDomains.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Domains")
                            .font(.headline)

                        FlowLayout(spacing: 6) {
                            ForEach(persona.domain.primaryDomains, id: \.self) { domain in
                                Text(domain)
                                    .font(.caption)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.purple.opacity(0.12))
                                    .clipShape(.rect(cornerRadius: 4))
                            }
                        }
                    }
                }

                // Behavior Notes
                if !persona.behavior.notes.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Behavior Notes")
                            .font(.headline)

                        ForEach(persona.behavior.notes, id: \.self) { note in
                            Label(note, systemImage: "circle.fill")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .labelStyle(SmallBulletLabelStyle())
                        }
                    }
                }

                // Counsel request activity
                if isCounsel {
                    Divider()

                    counselActivitySection
                }
            }
            .padding()
        }
        .navigationTitle(persona.name)
        .onAppear {
            if !hasLoaded {
                editedPrompt = effectivePrompt
                hasLoaded = true
            }
        }
    }

    // MARK: - Counsel Activity

    @ViewBuilder
    private var counselActivitySection: some View {
        let threads = mailGateway.counselThreads
        let workingCount = threads.filter { $0.status == .working }.count
        let completedCount = threads.filter { $0.status == .completed }.count
        let failedCount = threads.filter { $0.status == .failed }.count

        // Stats bar
        VStack(alignment: .leading, spacing: 12) {
            Text("Request Activity")
                .font(.headline)

            HStack(spacing: 16) {
                counselStatPill(
                    "\(threads.count)",
                    label: "total",
                    color: .secondary
                )

                if workingCount > 0 {
                    counselStatPill(
                        "\(workingCount)",
                        label: "working",
                        color: .purple,
                        pulse: true
                    )
                }

                counselStatPill(
                    "\(completedCount)",
                    label: "completed",
                    color: .green
                )

                if failedCount > 0 {
                    counselStatPill(
                        "\(failedCount)",
                        label: "failed",
                        color: .red
                    )
                }

                Spacer()
            }
        }

        // Recent requests
        if threads.isEmpty {
            HStack {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "envelope.open")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text("No requests yet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Send an email to counsel@impress.local")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 24)
                Spacer()
            }
        } else {
            let visibleThreads = showAllRequests ? threads : Array(threads.prefix(20))

            VStack(alignment: .leading, spacing: 2) {
                ForEach(visibleThreads, id: \.id) { thread in
                    counselRequestRow(thread)
                }
            }
            .background(Color.secondary.opacity(0.04))
            .clipShape(.rect(cornerRadius: 8))

            if threads.count > 20 && !showAllRequests {
                Button("Show all \(threads.count) requests") {
                    showAllRequests = true
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func counselStatPill(_ value: String, label: String, color: Color, pulse: Bool = false) -> some View {
        HStack(spacing: 4) {
            Text(value)
                .font(.system(.callout, weight: .semibold))
                .foregroundStyle(color)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.1))
        .clipShape(.rect(cornerRadius: 6))
        .symbolEffect(.pulse, isActive: pulse)
    }

    @ViewBuilder
    private func counselRequestRow(_ thread: CounselThread) -> some View {
        let isExpanded = expandedThreadID == thread.id

        VStack(alignment: .leading, spacing: 0) {
            // Row header — clickable
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    expandedThreadID = isExpanded ? nil : thread.id
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: counselStatusIcon(thread.status))
                        .foregroundColor(counselStatusColor(thread.status))
                        .symbolEffect(.pulse, isActive: thread.status == .working)
                        .frame(width: 20)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(thread.request.subject)
                            .font(.body)
                            .lineLimit(1)
                            .foregroundStyle(.primary)

                        HStack(spacing: 6) {
                            Text(thread.request.intent.rawValue)
                                .font(.caption2)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.purple.opacity(0.15))
                                .clipShape(.rect(cornerRadius: 3))

                            Text(thread.request.from)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        Text(thread.status.rawValue)
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        Text(thread.createdAt, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Expanded inline detail
            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    // Request body
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Request", systemImage: "envelope")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(thread.request.body)
                            .font(.callout)
                            .textSelection(.enabled)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.secondary.opacity(0.06))
                            .clipShape(.rect(cornerRadius: 6))
                    }

                    // Working spinner
                    if thread.status == .working {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Processing...")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Response body
                    if let response = thread.response {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("Response", systemImage: "text.bubble")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(response.body)
                                .font(.callout)
                                .textSelection(.enabled)
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.green.opacity(0.06))
                                .clipShape(.rect(cornerRadius: 6))
                        }
                    }

                    // Failed state
                    if thread.status == .failed {
                        Label("This request failed to process.", systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if thread.id != mailGateway.counselThreads.last?.id {
                Divider()
                    .padding(.leading, 40)
            }
        }
    }

    private func counselStatusIcon(_ status: CounselThreadStatus) -> String {
        switch status {
        case .received: return "envelope.badge"
        case .acknowledged: return "checkmark.circle"
        case .working: return "gearshape.2"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    private func counselStatusColor(_ status: CounselThreadStatus) -> Color {
        switch status {
        case .received: return .blue
        case .acknowledged: return .orange
        case .working: return .purple
        case .completed: return .green
        case .failed: return .red
        }
    }

    private func metadataItem(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.callout)
        }
    }
}

/// Simple bullet-point label style with a small dot.
private struct SmallBulletLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            configuration.icon
                .font(.system(size: 4))
                .foregroundStyle(.secondary)
            configuration.title
        }
    }
}

/// A simple flow layout for wrapping chips.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: .unspecified
            )
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            totalHeight = y + rowHeight
        }

        return (CGSize(width: maxWidth, height: totalHeight), positions)
    }
}
