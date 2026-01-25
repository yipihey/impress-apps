import SwiftUI

/// Main content view with split visualization and controls
struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            if let session = appState.currentSession {
                VisualizationView(session: session)
            } else {
                WelcomeView()
            }
        }
        .navigationTitle(appState.currentSession?.name ?? "implore")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                RenderModePicker()
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

/// Sidebar with dataset info and controls
struct SidebarView: View {
    @EnvironmentObject var appState: AppState

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

                Button("Edit Selection...") {
                    appState.showSelectionGrammar()
                }
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

/// Welcome view shown when no dataset is loaded
struct WelcomeView: View {
    @EnvironmentObject var appState: AppState

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
    @EnvironmentObject var appState: AppState

    var body: some View {
        Picker("Mode", selection: $appState.renderMode) {
            ForEach(RenderMode.allCases, id: \.self) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: 280)
    }
}

/// Sheet for entering selection grammar
struct SelectionGrammarSheet: View {
    @Environment(\.dismiss) var dismiss
    @State private var expression: String = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 20) {
            Text("Selection Grammar")
                .font(.headline)

            TextField("Enter selection expression", text: $expression)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))

            if let error = errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
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

                Spacer()

                Button("Apply") {
                    applySelection()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return)
            }
        }
        .padding()
        .frame(width: 400)
    }

    private func applySelection() {
        // Parse and apply selection grammar
        dismiss()
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
}
