import SwiftUI
#if os(macOS)
import AppKit
import ImpressHelixCore
#endif

/// Main content view with split visualization and controls
struct ContentView: View {
    @Environment(AppState.self) var appState
    @State private var generatorViewModel = GeneratorViewModel()
    @State private var libraryManager = LibraryManager.shared

    var body: some View {
        @Bindable var appState = appState
        NavigationSplitView {
            FigureSidebarView()
                .environment(appState)
                .environment(generatorViewModel)
                .environment(libraryManager)
                .accessibilityIdentifier("sidebar.container")
        } detail: {
            if let session = appState.currentSession {
                VisualizationView(session: session)
                    .accessibilityIdentifier("visualization.container")
            } else if generatorViewModel.generatedData != nil {
                GeneratedDataView(viewModel: generatorViewModel)
                    .accessibilityIdentifier("generatedData.container")
            } else {
                WelcomeView()
                    .accessibilityIdentifier("welcome.container")
            }
        }
        .navigationTitle(appState.currentSession?.name ?? "implore")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                RenderModePicker()
                    .accessibilityIdentifier("toolbar.renderModePicker")
            }
        }
        .sheet(isPresented: $appState.showingSelectionGrammar) {
            SelectionGrammarSheet()
        }
        .fileImporter(
            isPresented: $appState.showingOpenPanel,
            allowedContentTypes: [.data, .commaSeparatedText],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    Task {
                        await appState.loadDataset(url: url)
                    }
                }
            case .failure(let error):
                appState.errorMessage = error.localizedDescription
            }
        }
    }
}

/// Sidebar view with mode picker and collapsible sections
struct FigureSidebarView: View {
    @State private var sidebarMode: SidebarMode = .library

    var body: some View {
        VStack(spacing: 0) {
            // Mode picker
            Picker("Mode", selection: $sidebarMode) {
                ForEach(SidebarMode.allCases, id: \.self) { mode in
                    Label(mode.title, systemImage: mode.icon)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // Content based on mode
            switch sidebarMode {
            case .library:
                FigureLibrarySection()
            case .generators:
                GeneratorBrowserSection()
            case .diagnostics:
                DiagnosticsSection()
            }
        }
        .frame(minWidth: 240)
        .accessibilityIdentifier("sidebar.figureSidebar")
    }
}

/// Sidebar modes
enum SidebarMode: String, CaseIterable {
    case library
    case generators
    case diagnostics

    var title: String {
        switch self {
        case .library: return "Library"
        case .generators: return "Generate"
        case .diagnostics: return "Analyze"
        }
    }

    var icon: String {
        switch self {
        case .library: return "photo.on.rectangle"
        case .generators: return "waveform"
        case .diagnostics: return "chart.bar"
        }
    }
}

/// Legacy sidebar with dataset info and controls (kept for reference)
struct SidebarView: View {
    @Environment(AppState.self) var appState

    var body: some View {
        List {
            Section("Dataset") {
                if let session = appState.currentSession {
                    Label(session.name, systemImage: "chart.dots.scatter")
                } else {
                    Text("No dataset loaded")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Fields") {
                Text("X: (none)")
                    .foregroundStyle(.secondary)
                Text("Y: (none)")
                    .foregroundStyle(.secondary)
                Text("Z: (none)")
                    .foregroundStyle(.secondary)
                Text("Color: (none)")
                    .foregroundStyle(.secondary)
            }

            Section("Selection") {
                Text("0 points selected")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("sidebar.selectionCount")

                Button("Edit Selection...") {
                    appState.showSelectionGrammar()
                }
                .accessibilityIdentifier("sidebar.editSelectionButton")
            }

            Section("Statistics") {
                Text("Mean: --")
                    .foregroundStyle(.secondary)
                Text("Std Dev: --")
                    .foregroundStyle(.secondary)
                Text("Median: --")
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 200)
    }
}

/// Placeholder view for generated data visualization
struct GeneratedDataView: View {
    var viewModel: GeneratorViewModel

    var body: some View {
        VStack {
            if let summary = viewModel.dataSummary {
                VStack(spacing: 16) {
                    Image(systemName: "chart.dots.scatter")
                        .font(.system(size: 60))
                        .foregroundStyle(.secondary)

                    Text("Generated Data")
                        .font(.title)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Points:")
                            Spacer()
                            Text(summary.formattedPointCount)
                                .fontWeight(.medium)
                        }
                        HStack {
                            Text("Columns:")
                            Spacer()
                            Text("\(summary.columnCount)")
                                .fontWeight(.medium)
                        }
                        HStack {
                            Text("Fields:")
                            Spacer()
                            Text(summary.columnNames.joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding()
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))

                    Text("Visualization coming soon...")
                        .foregroundStyle(.secondary)
                }
                .padding()
            } else {
                ContentUnavailableView(
                    "No Data",
                    systemImage: "waveform.slash",
                    description: Text("Generate data using the sidebar")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Welcome view shown when no dataset is loaded
struct WelcomeView: View {
    @Environment(AppState.self) var appState

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "chart.dots.scatter")
                .font(.system(size: 80))
                .foregroundStyle(.secondary)

            Text("Welcome to implore")
                .font(.largeTitle)
                .fontWeight(.semibold)

            Text("High-performance scientific data visualization")
                .font(.title3)
                .foregroundStyle(.secondary)

            VStack(spacing: 12) {
                Text("Open a dataset to get started")
                    .foregroundStyle(.secondary)

                Button(action: { appState.showOpenPanel() }) {
                    Label("Open Dataset", systemImage: "folder")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("welcome.openButton")
            }
            .padding(.top, 20)

            VStack(alignment: .leading, spacing: 8) {
                Text("Supported formats:")
                    .font(.headline)
                    .padding(.bottom, 4)

                FormatRow(name: "HDF5", extensions: ".h5, .hdf5", icon: "doc.zipper")
                FormatRow(name: "FITS", extensions: ".fits", icon: "star")
                FormatRow(name: "CSV", extensions: ".csv, .tsv", icon: "tablecells")
                FormatRow(name: "Parquet", extensions: ".parquet", icon: "cylinder")
            }
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding(.top, 20)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct FormatRow: View {
    let name: String
    let extensions: String
    let icon: String

    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            Text(name)
                .fontWeight(.medium)
            Spacer()
            Text(extensions)
                .foregroundStyle(.secondary)
                .font(.caption)
        }
    }
}

/// Render mode picker in toolbar
struct RenderModePicker: View {
    @Environment(AppState.self) var appState

    var body: some View {
        @Bindable var appState = appState
        Picker("Mode", selection: $appState.renderMode) {
            ForEach(RenderMode.allCases, id: \.self) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: 380)
    }
}

/// Sheet for entering selection grammar with Helix modal editing support
struct SelectionGrammarSheet: View {
    @Environment(\.dismiss) var dismiss
    @State private var expression: String = ""
    @State private var errorMessage: String?

    #if os(macOS)
    @State private var helixState = HelixState()
    @AppStorage("implore.helix.isEnabled") private var helixEnabled = true
    #endif

    var body: some View {
        VStack(spacing: 20) {
            Text("Selection Grammar")
                .font(.headline)

            #if os(macOS)
            grammarEditor
            #else
            TextField("Enter selection expression", text: $expression)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .accessibilityIdentifier("selectionGrammar.expressionField")
            #endif

            if let error = errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .accessibilityIdentifier("selectionGrammar.errorMessage")
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Examples:")
                    .font(.subheadline)
                    .fontWeight(.medium)

                Group {
                    Text("x > 0 && y < 10")
                    Text("sphere([0, 0, 0], 1.5)")
                    Text("zscore(density) < 3")
                    Text("(x > 0 && y < 10) || @saved")
                }
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.escape)
                .accessibilityIdentifier("selectionGrammar.cancelButton")

                Spacer()

                Button("Apply") {
                    applySelection()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return)
                .accessibilityIdentifier("selectionGrammar.applyButton")
            }
        }
        .padding()
        .frame(width: 400)
        .accessibilityIdentifier("selectionGrammar.container")
    }

    #if os(macOS)
    @ViewBuilder
    private var grammarEditor: some View {
        GrammarEditorRepresentable(
            expression: $expression,
            helixState: helixState,
            helixEnabled: helixEnabled
        )
        .frame(height: 60)
        .font(.system(.body, design: .monospaced))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
        )
        .helixModeIndicator(
            state: helixState,
            position: .bottomRight,
            isVisible: helixEnabled,
            padding: 4
        )
        .accessibilityIdentifier("selectionGrammar.expressionField")
    }
    #endif

    private func applySelection() {
        // Parse and apply selection grammar
        dismiss()
    }
}

#if os(macOS)
/// NSTextView wrapper for grammar editing with Helix support
struct GrammarEditorRepresentable: NSViewRepresentable {
    @Binding var expression: String
    let helixState: HelixState
    let helixEnabled: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = HelixTextView()
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.backgroundColor = .textBackgroundColor
        textView.textColor = .textColor
        textView.insertionPointColor = .textColor

        // Single-line behavior
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = true

        // Set up Helix adaptor
        let adaptor = NSTextViewHelixAdaptor(textView: textView, helixState: helixState)
        adaptor.isEnabled = helixEnabled
        textView.helixAdaptor = adaptor
        context.coordinator.helixAdaptor = adaptor

        scrollView.documentView = textView
        context.coordinator.textView = textView

        // Set initial text
        textView.string = expression

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? HelixTextView else { return }

        // Update Helix enabled state
        context.coordinator.helixAdaptor?.isEnabled = helixEnabled

        // Update text if changed externally
        if textView.string != expression {
            textView.string = expression
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(expression: $expression)
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var expression: String
        weak var textView: HelixTextView?
        weak var helixAdaptor: NSTextViewHelixAdaptor?

        init(expression: Binding<String>) {
            self._expression = expression
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = textView else { return }
            expression = textView.string
        }
    }
}
#endif

#Preview {
    ContentView()
        .environment(AppState())
}
