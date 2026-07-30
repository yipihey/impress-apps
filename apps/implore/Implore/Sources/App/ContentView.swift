//
//  ContentView.swift
//  implore
//
//  Stage 4a (declarative-chassis campaign): the pre-chassis shell that once
//  lived here — `ContentView` (NavigationSplitView root), `FigureSidebarView`,
//  `SidebarMode`, `SidebarView`, `SelectionGrammarSheet`,
//  `GrammarEditorRepresentable` and the vim-navigation handler — was deleted.
//  `ImploreChassisRoot` has been the app's only `WindowGroup` root since Stage
//  2-B (see ImploreApp.swift), so none of it was reachable.
//
//  What REMAINS here is live: these four views are declared in this file but
//  consumed by the chassis, not by the retired shell —
//    * `GeneratedDataView`  → ImploreChassisRoot's GenerateSurface + ImploreCanvasStack
//    * `WelcomeView`        → ImploreChassisRoot's ImploreCanvasStack (empty state)
//    * `FormatRow`          → WelcomeView's supported-formats list
//    * `RenderModePicker`   → CanvasWindowView's toolbar
//  The file keeps its name for now so the deletion stays a pure deletion; a
//  follow-up may rename it to match its surviving contents.
//

import SwiftUI

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

                FormatRow(name: "NPZ", extensions: ".npz (RG volumes)", icon: "cube")
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
