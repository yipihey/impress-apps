import AppKit
import ImpressLogging
import OSLog
import SwiftUI

/// Side panel that lists every Veusz plot tracked by the current manuscript.
///
/// Bound to the document so creating/deleting/re-rendering a plot flows back
/// into `ImprintDocument.plots` and `ImprintDocument.figureFiles` and is
/// persisted on the next save.
///
/// Placement: this is a freestanding view; embed it wherever the host app
/// needs (sidebar section, inspector tab, separate window). Internally it
/// owns a `VeuszPlotStore` keyed on the document's UUID, so swapping the
/// `document` binding to a new document re-initializes the store.
struct VeuszPlotsPanel: View {
    @Binding var document: ImprintDocument

    @State private var store: VeuszPlotStore?
    @State private var initializationError: String?
    @State private var newPlotName: String = ""
    @State private var showingNewPlotPrompt = false
    /// Reflects `VeuszService.isHelperScriptInstalled` so the install banner
    /// can disappear as soon as the one-time grant + script write completes.
    @State private var helperInstalled = VeuszService.isHelperScriptInstalled

    private var documentFormat: DocumentFormat { document.format }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !VeuszService.isInstalled {
                veuszMissingBanner
                Divider()
            } else if !helperInstalled {
                helperMissingBanner
                Divider()
            }
            content
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .task(id: document.id) { await rebuildStoreIfNeeded() }
        .onDisappear {
            if let store {
                VeuszPlotStoreRegistry.shared.unregister(documentID: store.documentID)
            }
        }
        .alert("Veusz Setup", isPresented: .constant(initializationError != nil)) {
            Button("OK") { initializationError = nil }
        } message: {
            Text(initializationError ?? "")
        }
        .sheet(isPresented: $showingNewPlotPrompt) { newPlotSheet }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Plots")
                .font(.headline)
            Spacer()
            Button {
                newPlotName = ""
                showingNewPlotPrompt = true
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("New plot")
            .disabled(store == nil)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let store {
            if store.plots.isEmpty {
                emptyState
            } else {
                plotList(store: store)
            }
        } else if let initializationError {
            errorState(message: initializationError)
        } else {
            ProgressView().padding()
        }
    }

    private func plotList(store: VeuszPlotStore) -> some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 12)], spacing: 12) {
                ForEach(store.plots) { plot in
                    VeuszPlotTile(
                        plot: plot,
                        thumbnailURL: thumbnailURL(for: plot, in: store),
                        onEdit: { _ = store.openInVeusz(plotID: plot.id) },
                        onRerender: { Task { await store.rerender(plotID: plot.id) } },
                        onReveal: { revealInFinder(plot: plot, in: store) },
                        onInsert: { postInsert(plot: plot) },
                        onChangeFormat: { newFormat in
                            Task { await store.setFormat(plotID: plot.id, to: newFormat) }
                        },
                        onDelete: { store.deletePlot(plot.id) }
                    )
                }
            }
            .padding(12)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No plots yet")
                .font(.headline)
            Text("Create a Veusz plot to track its `.vsz` source and its rendered SVG alongside this manuscript.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button("New Plot…") {
                newPlotName = ""
                showingNewPlotPrompt = true
            }
            .buttonStyle(.borderedProminent)
            .disabled(!VeuszService.isInstalled)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func errorState(message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    private var veuszMissingBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Veusz isn't installed")
                    .font(.subheadline.bold())
                Text("Install Veusz.app to edit and render plots.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Link("Install", destination: URL(string: "https://veusz.github.io/")!)
                .font(.caption)
        }
        .padding(10)
        .background(Color.orange.opacity(0.08))
    }

    /// Shown once, when Veusz is present on the machine but the sandboxed
    /// app hasn't yet been granted permission to install its NSUserUnixTask
    /// wrapper script. Clicking "Install Helper" opens an NSOpenPanel
    /// pre-targeted at ~/Library/Application Scripts/<bundle>/ — the user
    /// just confirms with "Grant Access" and the script gets written.
    private var helperMissingBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "gear.badge")
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("One-time setup needed")
                    .font(.subheadline.bold())
                Text("Imprint runs Veusz via a helper script. macOS asks for a one-time folder grant before installing it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Install Helper…") {
                Task { await installHelper() }
            }
            .font(.caption)
        }
        .padding(10)
        .background(Color.blue.opacity(0.08))
    }

    private func installHelper() async {
        do {
            if (try await VeuszService.installHelperScript()) != nil {
                helperInstalled = VeuszService.isHelperScriptInstalled
            }
        } catch {
            initializationError = "Helper install failed: \(error.localizedDescription)"
        }
    }

    // MARK: - New plot sheet

    private var newPlotSheet: some View {
        VStack(spacing: 16) {
            Text("New Veusz Plot")
                .font(.headline)
            TextField("Plot name", text: $newPlotName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit { commitNewPlot() }
            HStack {
                Button("Cancel") { showingNewPlotPrompt = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Create") { commitNewPlot() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(newPlotName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .frame(width: 280)
        }
        .padding(20)
    }

    private func commitNewPlot() {
        guard let store else { return }
        let name = newPlotName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        showingNewPlotPrompt = false
        // SVG is native for Typst; LaTeX (pdfLaTeX) has no native SVG path
        // and would otherwise require --shell-escape + Inkscape via the
        // `svg` package, so default new plots in .tex documents to PDF.
        // Users can still change per-plot format from the tile menu.
        let defaultFormat: VeuszPlotRef.ExportFormat = (document.format == .latex) ? .pdf : .svg
        Task {
            do {
                let plot = try await store.createPlot(name: name, format: defaultFormat)
                _ = store.openInVeusz(plotID: plot.id)
            } catch {
                initializationError = error.localizedDescription
            }
        }
    }

    // MARK: - Helpers

    private func rebuildStoreIfNeeded() async {
        if store?.documentID == document.id { return }

        // Unregister any prior store before swapping (document switched).
        if let previous = store {
            VeuszPlotStoreRegistry.shared.unregister(documentID: previous.documentID)
        }

        let docID = document.id
        let plots = document.plots
        let figureFiles = document.figureFiles
        do {
            let docBinding = $document
            let newStore = try VeuszPlotStore(
                documentID: docID,
                initialPlots: plots,
                initialFigureFiles: figureFiles,
                renderer: VeuszService(),
                onChange: { snapshot in
                    docBinding.wrappedValue.plots = snapshot.plots
                    docBinding.wrappedValue.figureFiles = snapshot.figureFiles
                }
            )
            store = newStore
            VeuszPlotStoreRegistry.shared.register(newStore, for: docID)
            initializationError = nil
        } catch {
            initializationError = "Couldn't initialize plot store: \(error.localizedDescription)"
            Logger.veusz.errorCapture("Plot store init failed: \(error.localizedDescription)", category: "veusz")
        }
    }

    private func thumbnailURL(for plot: VeuszPlotRef, in store: VeuszPlotStore) -> URL? {
        let name = (plot.renderedRelativePath as NSString).lastPathComponent
        let url = store.workingDirectory.appending(path: name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func revealInFinder(plot: VeuszPlotRef, in store: VeuszPlotStore) {
        let name = (plot.sourceRelativePath as NSString).lastPathComponent
        let url = store.workingDirectory.appending(path: name)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func postInsert(plot: VeuszPlotRef) {
        let snippet = VeuszPlotInsertion.block(for: plot, format: documentFormat)
        NotificationCenter.default.post(
            name: VeuszPlotInsertion.notificationName,
            object: nil,
            userInfo: [
                "plotID": plot.id,
                "snippet": snippet,
                "documentID": document.id,
            ]
        )
    }
}

// MARK: - Plot tile

private struct VeuszPlotTile: View {
    let plot: VeuszPlotRef
    let thumbnailURL: URL?
    let onEdit: () -> Void
    let onRerender: () -> Void
    let onReveal: () -> Void
    let onInsert: () -> Void
    let onChangeFormat: (VeuszPlotRef.ExportFormat) -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            thumbnail
                .frame(maxWidth: .infinity)
                .frame(height: 120)
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
                )

            HStack(spacing: 6) {
                statusDot
                Text(plot.displayName)
                    .font(.subheadline)
                    .lineLimit(1)
                Spacer()
                Menu {
                    Button("Insert at Cursor", action: onInsert)
                    Button("Edit in Veusz", action: onEdit)
                    Button("Re-render Now", action: onRerender)
                    Menu("Format") {
                        ForEach(VeuszPlotRef.ExportFormat.allCases, id: \.self) { format in
                            Button {
                                onChangeFormat(format)
                            } label: {
                                if format == plot.exportFormat {
                                    Label(format.rawValue.uppercased(), systemImage: "checkmark")
                                } else {
                                    Text(format.rawValue.uppercased())
                                }
                            }
                        }
                    }
                    Button("Reveal in Finder", action: onReveal)
                    Divider()
                    Button("Delete", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .padding(8)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contextMenu {
            Button("Insert at Cursor", action: onInsert)
            Button("Edit in Veusz", action: onEdit)
            Button("Re-render Now", action: onRerender)
            Button("Reveal in Finder", action: onReveal)
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        }
        .onTapGesture(count: 2, perform: onEdit)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let thumbnailURL, let image = NSImage(contentsOf: thumbnailURL) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .padding(4)
        } else {
            VStack(spacing: 4) {
                Image(systemName: "chart.xyaxis.line")
                    .font(.title)
                    .foregroundStyle(.secondary)
                Text("No preview")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusDot: some View {
        let color: Color
        let tooltip: String
        switch plot.renderStatus {
        case .idle:
            color = plot.lastRenderedAt != nil ? .green : .gray
            tooltip = plot.lastRenderedAt.map { "Rendered \($0.formatted(.relative(presentation: .named)))" } ?? "Not rendered"
        case .rendering:
            color = .blue
            tooltip = "Rendering…"
        case .stale:
            color = .yellow
            tooltip = "Source modified since last render"
        case .failed(let message):
            color = .red
            tooltip = "Render failed: \(message)"
        }
        return Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .help(tooltip)
    }
}
