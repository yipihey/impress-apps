//
//  CitationGraphView.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-02-03.
//

import SwiftUI
import CoreData
import CoreGraphics
import OSLog

// MARK: - Citation Graph View

/// Interactive citation graph visualization for a library.
///
/// Shows papers as nodes and citation relationships as edges.
/// Nodes are positioned using a simple force-directed layout.
/// Library papers are highlighted; external "missing link" papers
/// are shown dimmed with a count badge.
public struct CitationGraphView: View {
    let library: CDLibrary

    @State private var graph = CitationGraph()
    @State private var isLoading = false
    @State private var positions: [String: CGPoint] = [:]
    @State private var selectedNodeID: String?
    @State private var showSuggestedOnly = false
    @Environment(\.dismiss) private var dismiss

    public init(library: CDLibrary) {
        self.library = library
    }

    public var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Building citation graph...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if graph.nodes.isEmpty {
                    ContentUnavailableView(
                        "No Citation Data",
                        systemImage: "point.3.connected.trianglepath.dotted",
                        description: Text("Enrich papers with citation data to see the graph. Use the References tab on any paper to fetch citation information.")
                    )
                } else {
                    graphContent
                }
            }
            .navigationTitle("Citation Graph")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }

                if !graph.nodes.isEmpty {
                    ToolbarItem(placement: .automatic) {
                        Toggle("Suggestions", isOn: $showSuggestedOnly)
                            .toggleStyle(.button)
                    }
                }
            }
            .task {
                await loadGraph()
            }
        }
    }

    @ViewBuilder
    private var graphContent: some View {
        VStack(spacing: 0) {
            // Stats bar
            statsBar

            if showSuggestedOnly {
                suggestedPapersView
            } else {
                graphCanvasView
            }
        }
    }

    // MARK: - Stats Bar

    private var statsBar: some View {
        HStack(spacing: 16) {
            Label("\(graph.nodes.values.filter { $0.isInLibrary }.count) papers", systemImage: "doc.fill")
            Label("\(graph.edges.count) citations", systemImage: "arrow.right")
            Label("\(graph.suggestedPapers.count) suggested", systemImage: "lightbulb")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: - Graph Canvas

    private var graphCanvasView: some View {
        ScrollView([.horizontal, .vertical]) {
            ZStack {
                // Edges
                ForEach(Array(graph.edges), id: \.id) { edge in
                    if let from = positions[edge.sourceID],
                       let to = positions[edge.targetID] {
                        Path { path in
                            path.move(to: from)
                            path.addLine(to: to)
                        }
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
                    }
                }

                // Nodes
                ForEach(Array(graph.nodes.values), id: \.id) { node in
                    if let position = positions[node.id] {
                        nodeView(node)
                            .position(position)
                    }
                }
            }
            .frame(width: canvasSize.width, height: canvasSize.height)
        }
    }

    @ViewBuilder
    private func nodeView(_ node: CitationNode) -> some View {
        let isSelected = selectedNodeID == node.id
        let radius: CGFloat = node.isInLibrary ? max(8, CGFloat(node.connectionCount) * 3 + 6) : 5

        Circle()
            .fill(node.isInLibrary ? Color.accentColor : Color.secondary.opacity(0.4))
            .frame(width: radius * 2, height: radius * 2)
            .overlay {
                if isSelected || (node.isInLibrary && node.connectionCount >= 3) {
                    Text(shortTitle(node.title))
                        .font(.system(size: 9))
                        .lineLimit(2)
                        .frame(width: 80)
                        .offset(y: radius + 12)
                }
            }
            .onTapGesture {
                selectedNodeID = selectedNodeID == node.id ? nil : node.id
            }
    }

    // MARK: - Suggested Papers

    private var suggestedPapersView: some View {
        List {
            suggestedSection
            connectedSection
        }
    }

    @ViewBuilder
    private var suggestedSection: some View {
        let suggested = Array(graph.suggestedPapers.prefix(20))
        if suggested.isEmpty {
            Section {
                Text("No suggested papers found. Enrich more papers with citation data to discover connections.")
                    .foregroundStyle(.secondary)
            }
        } else {
            Section("Frequently Cited — Not in Library") {
                ForEach(suggested, id: \.id) { node in
                    SuggestedNodeRow(node: node)
                }
            }
        }
    }

    @ViewBuilder
    private var connectedSection: some View {
        let connected = Array(graph.mostConnected.prefix(10))
        Section("Most Connected in Library") {
            ForEach(connected, id: \.id) { node in
                ConnectedNodeRow(node: node)
            }
        }
    }

    // MARK: - Layout

    private var canvasSize: CGSize {
        let count = graph.nodes.count
        let side = max(600, CGFloat(count) * 8)
        return CGSize(width: side, height: side)
    }

    /// Simple force-directed layout positioning.
    private func computeLayout() {
        let nodes = Array(graph.nodes.values)
        guard !nodes.isEmpty else { return }

        let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        var pos: [String: CGPoint] = [:]

        // Initial placement: library papers in center circle, externals on outer ring
        let libraryNodes = nodes.filter { $0.isInLibrary }
        let externalNodes = nodes.filter { !$0.isInLibrary }

        let innerRadius = canvasSize.width * 0.25
        let outerRadius = canvasSize.width * 0.4

        for (i, node) in libraryNodes.enumerated() {
            let angle = CGFloat(2.0 * Double.pi * Double(i) / Double(max(1, libraryNodes.count)))
            pos[node.id] = CGPoint(
                x: center.x + innerRadius * CoreGraphics.cos(angle),
                y: center.y + innerRadius * CoreGraphics.sin(angle)
            )
        }

        for (i, node) in externalNodes.enumerated() {
            let angle = CGFloat(2.0 * Double.pi * Double(i) / Double(max(1, externalNodes.count)))
            pos[node.id] = CGPoint(
                x: center.x + outerRadius * CoreGraphics.cos(angle),
                y: center.y + outerRadius * CoreGraphics.sin(angle)
            )
        }

        // Simple force iterations to separate overlapping nodes
        let iterations = 50
        for _ in 0..<iterations {
            for node in nodes {
                guard var p = pos[node.id] else { continue }

                // Repulsion from other nodes
                for other in nodes where other.id != node.id {
                    guard let otherPos = pos[other.id] else { continue }
                    let dx = p.x - otherPos.x
                    let dy = p.y - otherPos.y
                    let dist = max(1, sqrt(dx * dx + dy * dy))

                    if dist < 40 {
                        let force = 20 / dist
                        p.x += dx / dist * force
                        p.y += dy / dist * force
                    }
                }

                // Attraction along edges
                for edge in graph.edges {
                    let neighborID: String?
                    if edge.sourceID == node.id { neighborID = edge.targetID }
                    else if edge.targetID == node.id { neighborID = edge.sourceID }
                    else { neighborID = nil }

                    if let nID = neighborID, let nPos = pos[nID] {
                        let dx = nPos.x - p.x
                        let dy = nPos.y - p.y
                        let dist = max(1, sqrt(dx * dx + dy * dy))
                        if dist > 80 {
                            let force: CGFloat = 0.01
                            p.x += dx * force
                            p.y += dy * force
                        }
                    }
                }

                // Keep within bounds
                p.x = max(20, min(canvasSize.width - 20, p.x))
                p.y = max(20, min(canvasSize.height - 20, p.y))

                pos[node.id] = p
            }
        }

        positions = pos
    }

    // MARK: - Data Loading

    private func loadGraph() async {
        isLoading = true
        graph = await CitationGraphService.shared.buildGraph(for: library)
        computeLayout()
        isLoading = false
    }

    // MARK: - Helpers

    private func shortTitle(_ title: String) -> String {
        if title.count <= 30 { return title }
        let words = title.split(separator: " ")
        var result = ""
        for word in words {
            if result.count + word.count > 28 { break }
            if !result.isEmpty { result += " " }
            result += word
        }
        return result + "..."
    }
}

// MARK: - Extracted Row Views

private struct SuggestedNodeRow: View {
    let node: CitationNode

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(node.title)
                .font(.body)
                .lineLimit(2)

            HStack {
                if let year = node.year {
                    Text(String(year))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !node.authors.isEmpty {
                    Text(Array(node.authors.prefix(3)).joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Label("\(node.connectionCount)", systemImage: "link")
                    .font(.caption.bold())
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct ConnectedNodeRow: View {
    let node: CitationNode

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(node.title)
                    .font(.body)
                    .lineLimit(1)
                if let key = node.citeKey {
                    Text(key)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text("\(node.connectionCount)")
                .font(.caption.bold())
                .foregroundStyle(Color.accentColor)
        }
    }
}
